{ Quake 1 player movement physics, ported from the NetQuake server
  (sv_user.c, sv_phys.c) and the movement parts of QuakeC client.qc:
  ground friction and acceleration, air control (bunny hopping and strafe
  jumping), swimming, water jumps, gravity, sliding and stair stepping
  against the BSP clipping hulls. All coordinates are Quake coordinates. }
unit QuakePhysics;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math,
  CastleVectors,
  QuakeBsp;

type
  { One frame of player input (usercmd_t), in Quake units per second }
  TQuakeUserCmd = record
    ForwardMove, SideMove, UpMove: Single;
    Jump: Boolean;
  end;

  { A brush entity the player collides with (door, plat, button...) }
  TQuakeSolidModel = record
    ModelIndex: Integer;
    Offset: TVector3; { how far it moved from where the map placed it }
  end;

  { A solid box the player collides with (monster), absolute coordinates }
  TQuakeSolidBox = record
    Mins, Maxs: TVector3;
  end;

  TQuakePlayerPhysics = class
  private
    FBsp: TQuakeBsp;
    FTime: Single;
    FOldOrigin: TVector3;
    FWishSpeed: Single;
    function TraceBox(const BoxMins, BoxMaxs, Start, Stop: TVector3): TQuakeTrace;
    function TestPosition: Boolean;
    procedure CheckWater;
    procedure CheckWaterJump(const Forward: TVector3);
    procedure PlayerJump;
    procedure UserFriction(const Dt: Single);
    procedure Accelerate(const WishDir: TVector3; const WishSpeed, Dt: Single);
    procedure AirAccelerate(WishVeloc: TVector3; const Dt: Single);
    procedure AirMove(const Cmd: TQuakeUserCmd; const Yaw, Pitch, Dt: Single);
    procedure WaterMove(const Cmd: TQuakeUserCmd; const Yaw, Pitch, Dt: Single);
    procedure WaterJumpMove;
    procedure CheckStuck;
    function FlyMove(const Dt: Single; out StepTrace: TQuakeTrace): Integer;
    function PushEntity(const Push: TVector3): TQuakeTrace;
    procedure WalkMove(const Dt: Single);
    procedure Frame(const Cmd: TQuakeUserCmd; const Yaw, Pitch, Dt: Single);
    procedure AddTouched(const Entity: Integer);
  public
    Origin: TVector3;
    Velocity: TVector3;
    Mins, Maxs: TVector3;
    ViewHeight: Single;
    OnGround: Boolean;
    { What the player stands on: BSP model index (0 = world), -2 = a box, -1 = nothing }
    GroundEntity: Integer;
    WaterLevel: Integer; { 0 dry, 1 feet, 2 waist, 3 eyes }
    WaterType: Integer;  { CONTENTS_xxx of the liquid }
    InWaterJump: Boolean;
    JumpReleased: Boolean;
    TeleportTime: Single; { no backwards movement and water jump timeout }
    MoveDir: TVector3;    { water jump push }

    { Colliders besides the world, refreshed by the caller every frame }
    SolidModels: array of TQuakeSolidModel;
    SolidBoxes: array of TQuakeSolidBox;

    { Events of the last Move call, for sounds and damage }
    Jumped: Boolean;
    { Brush entities (BSP model indexes) the player ran into (SV_Impact) }
    Touched: array of Integer;
    { Vertical speed when the player landed (jump_flag in QuakeC), 0 when not landed }
    LandingSpeed: Single;

    constructor Create;

    { Map to collide with (nil disables physics) }
    property Bsp: TQuakeBsp read FBsp write FBsp;
    property Time: Single read FTime;

    { Place the player, e.g. at a spawn point or teleporter destination }
    procedure Teleport(const AOrigin: TVector3);

    { Run the physics for SecondsPassed. Yaw and Pitch are the view angles in
      degrees (Quake convention: yaw 0 = +X, pitch > 0 looks down). }
    procedure Move(const Cmd: TQuakeUserCmd; const Yaw, Pitch, SecondsPassed: Single);

    { Trace the player box from Start to Stop against world, brush entities
      and boxes (SV_Move). PointTrace = True traces a point (hull 0). }
    function Trace(const Start, Stop: TVector3; const PointTrace: Boolean = False;
      const IgnoreBoxes: Boolean = False): TQuakeTrace;

    function EyePosition: TVector3;
  end;

const
  { Server cvars with their Quake defaults }
  SvGravity = 800.0;
  SvMaxSpeed = 320.0;
  SvAccelerate = 10.0;
  SvFriction = 4.0;
  SvStopSpeed = 100.0;
  SvEdgeFriction = 2.0;
  SvMaxVelocity = 2000.0;
  StepSize = 18.0;
  { Client move speeds (cl_forwardspeed etc. with "always run") }
  ClForwardSpeed = 400.0;
  ClBackSpeed = 400.0;
  ClSideSpeed = 350.0;
  ClUpSpeed = 200.0;

implementation

const
  StopEpsilon = 0.1;
  DistEpsilon = 0.03125;
  MaxClipPlanes = 5;
  { Physics runs in steps no longer than this, so jumps do not depend on frame rate }
  MaxStep = 1.0 / 72.0;

procedure AngleVectors(const Yaw, Pitch: Single; out Forward, Right, Up: TVector3);
var
  SY, CY, SP, CP: Single;
begin
  SinCos(DegToRad(Yaw), SY, CY);
  SinCos(DegToRad(Pitch), SP, CP);
  Forward := Vector3(CP * CY, CP * SY, -SP);
  Right := Vector3(SY, -CY, 0);
  Up := Vector3(SP * CY, SP * SY, CP);
end;

function ClipVelocity(const InVel, Normal: TVector3; const Overbounce: Single): TVector3;
var
  Backoff: Single;
  I: Integer;
begin
  Backoff := TVector3.DotProduct(InVel, Normal) * Overbounce;
  Result := InVel - Normal * Backoff;
  for I := 0 to 2 do
    if (Result.Data[I] > -StopEpsilon) and (Result.Data[I] < StopEpsilon) then
      Result.Data[I] := 0;
end;

{ TQuakePlayerPhysics }

constructor TQuakePlayerPhysics.Create;
begin
  inherited Create;
  Mins := Vector3(-16, -16, -24);
  Maxs := Vector3(16, 16, 32);
  ViewHeight := 22;
  JumpReleased := True;
  GroundEntity := -1;
  WaterType := CONTENTS_EMPTY;
end;

function TQuakePlayerPhysics.EyePosition: TVector3;
begin
  Result := Origin + Vector3(0, 0, ViewHeight);
end;

procedure TQuakePlayerPhysics.Teleport(const AOrigin: TVector3);
begin
  Origin := AOrigin;
  FOldOrigin := AOrigin;
  Velocity := TVector3.Zero;
  OnGround := False;
  GroundEntity := -1;
  InWaterJump := False;
end;

function TQuakePlayerPhysics.TraceBox(const BoxMins, BoxMaxs, Start, Stop: TVector3): TQuakeTrace;
var
  I: Integer;
  D1, D2, F, EnterFrac, LeaveFrac: Single;
  Sign: Integer;
  PlaneN: TVector3;
  HitNormal: TVector3;
  StartOut, EndOut: Boolean;
begin
  { Segment against an axis aligned box already expanded by the mover size
    (SV_HullForBox), backing off DistEpsilon like the hull traces }
  FillChar(Result, SizeOf(Result), 0);
  Result.Fraction := 1;
  Result.EndPos := Stop;
  Result.Entity := -1;
  EnterFrac := -1;
  LeaveFrac := 1;
  StartOut := False;
  EndOut := False;
  HitNormal := TVector3.Zero;

  for I := 0 to 2 do
    for Sign := 0 to 1 do
    begin
      PlaneN := TVector3.Zero;
      if Sign = 0 then
      begin
        PlaneN.Data[I] := 1;
        D1 := Start.Data[I] - BoxMaxs.Data[I];
        D2 := Stop.Data[I] - BoxMaxs.Data[I];
      end else
      begin
        PlaneN.Data[I] := -1;
        D1 := BoxMins.Data[I] - Start.Data[I];
        D2 := BoxMins.Data[I] - Stop.Data[I];
      end;
      if D1 > 0 then
        StartOut := True;
      if D2 > 0 then
        EndOut := True;
      if (D1 > 0) and (D2 >= D1) then
        Exit; { completely in front of this face }
      if (D1 <= 0) and (D2 <= 0) then
        Continue;
      if D1 > D2 then
      begin
        { entering }
        F := (D1 - DistEpsilon) / (D1 - D2);
        if F > EnterFrac then
        begin
          EnterFrac := F;
          HitNormal := PlaneN;
        end;
      end else
      begin
        { leaving }
        F := (D1 + DistEpsilon) / (D1 - D2);
        if F < LeaveFrac then
          LeaveFrac := F;
      end;
    end;

  if not StartOut then
  begin
    Result.StartSolid := True;
    Result.AllSolid := not EndOut;
    Exit;
  end;
  if (EnterFrac < LeaveFrac) and (EnterFrac > -1) then
  begin
    Result.Fraction := Max(0, EnterFrac);
    Result.EndPos := Start + (Stop - Start) * Result.Fraction;
    Result.PlaneNormal := HitNormal;
    Result.Entity := -2;
  end;
end;

function TQuakePlayerPhysics.Trace(const Start, Stop: TVector3; const PointTrace: Boolean;
  const IgnoreBoxes: Boolean): TQuakeTrace;
var
  Hull, I: Integer;
  T: TQuakeTrace;
  BoxMins, BoxMaxs: TVector3;

  procedure Combine;
  begin
    { SV_ClipToLinks: keep the closest hit, remember starting in solid }
    if T.AllSolid or T.StartSolid or (T.Fraction < Result.Fraction) then
    begin
      if Result.StartSolid then
      begin
        Result := T;
        Result.StartSolid := True;
      end else
        Result := T;
    end else
    if T.StartSolid then
      Result.StartSolid := True;
  end;

begin
  if PointTrace then
    Hull := 0
  else
    Hull := FBsp.HullForSize(Mins, Maxs);

  Result := FBsp.TraceHull(Hull, 0, TVector3.Zero, Start, Stop);
  if (Result.Fraction < 1) or Result.StartSolid then
    Result.Entity := 0;
  if Result.AllSolid then
    Exit;

  for I := 0 to High(SolidModels) do
  begin
    T := FBsp.TraceHull(Hull, SolidModels[I].ModelIndex, SolidModels[I].Offset, Start, Stop);
    if (T.Fraction < 1) or T.StartSolid then
      T.Entity := SolidModels[I].ModelIndex;
    Combine;
  end;

  if not IgnoreBoxes then
    for I := 0 to High(SolidBoxes) do
    begin
      if PointTrace then
      begin
        BoxMins := SolidBoxes[I].Mins;
        BoxMaxs := SolidBoxes[I].Maxs;
      end else
      begin
        BoxMins := SolidBoxes[I].Mins - Maxs;
        BoxMaxs := SolidBoxes[I].Maxs - Mins;
      end;
      T := TraceBox(BoxMins, BoxMaxs, Start, Stop);
      Combine;
    end;
end;

function TQuakePlayerPhysics.TestPosition: Boolean;
begin
  { True when the player box at Origin is inside something (SV_TestEntityPosition) }
  Result := Trace(Origin, Origin).StartSolid;
end;

procedure TQuakePlayerPhysics.CheckWater;
var
  P: TVector3;
  Cont: Integer;
begin
  { SV_CheckWater: sample feet, waist and eyes }
  WaterLevel := 0;
  WaterType := CONTENTS_EMPTY;
  P := Origin;
  P.Z := Origin.Z + Mins.Z + 1;
  Cont := FBsp.PointContents(P);
  if (Cont <= CONTENTS_WATER) and (Cont > CONTENTS_SKY) then
  begin
    WaterType := Cont;
    WaterLevel := 1;
    P.Z := Origin.Z + (Mins.Z + Maxs.Z) * 0.5;
    Cont := FBsp.PointContents(P);
    if (Cont <= CONTENTS_WATER) and (Cont > CONTENTS_SKY) then
    begin
      WaterLevel := 2;
      P.Z := Origin.Z + ViewHeight;
      Cont := FBsp.PointContents(P);
      if (Cont <= CONTENTS_WATER) and (Cont > CONTENTS_SKY) then
        WaterLevel := 3;
    end;
  end;
end;

procedure TQuakePlayerPhysics.CheckWaterJump(const Forward: TVector3);
var
  Start, Stop, Fwd: TVector3;
  T: TQuakeTrace;
begin
  { CheckWaterJump (client.qc): wall at the waist and free space at the eyes
    means the player can climb out }
  Fwd := Vector3(Forward.X, Forward.Y, 0);
  if Fwd.IsPerfectlyZero then
    Exit;
  Fwd := Fwd.Normalize;
  Start := Origin;
  Start.Z := Start.Z + 8;
  Stop := Start + Fwd * 24;
  T := Trace(Start, Stop, True, True);
  if T.Fraction < 1 then
  begin
    Start.Z := Start.Z + Maxs.Z - 8;
    Stop := Start + Fwd * 24;
    MoveDir := T.PlaneNormal * -50;
    T := Trace(Start, Stop, True, True);
    if T.Fraction = 1 then
    begin
      InWaterJump := True;
      Velocity.Z := 225;
      JumpReleased := False;
      TeleportTime := FTime + 2;
    end;
  end;
end;

procedure TQuakePlayerPhysics.PlayerJump;
begin
  { PlayerJump (client.qc) }
  if InWaterJump then
    Exit;
  if WaterLevel >= 2 then
  begin
    { Swimming up }
    case WaterType of
      CONTENTS_WATER: Velocity.Z := 100;
      CONTENTS_SLIME: Velocity.Z := 80;
      else Velocity.Z := 50;
    end;
    Exit;
  end;
  if not OnGround then
    Exit;
  if not JumpReleased then
    Exit; { don't pogo stick }
  JumpReleased := False;
  OnGround := False;
  Velocity.Z := Velocity.Z + 270;
  Jumped := True;
end;

procedure TQuakePlayerPhysics.UserFriction(const Dt: Single);
var
  Speed, NewSpeed, Control, Friction: Single;
  Start, Stop: TVector3;
  T: TQuakeTrace;
begin
  Speed := Sqrt(Sqr(Velocity.X) + Sqr(Velocity.Y));
  if Speed = 0 then
    Exit;

  { If the leading edge is over a dropoff, increase friction }
  Start := Vector3(Origin.X + Velocity.X / Speed * 16, Origin.Y + Velocity.Y / Speed * 16,
    Origin.Z + Mins.Z);
  Stop := Start;
  Stop.Z := Start.Z - 34;
  T := Trace(Start, Stop, True, True);
  if T.Fraction = 1 then
    Friction := SvFriction * SvEdgeFriction
  else
    Friction := SvFriction;

  if Speed < SvStopSpeed then
    Control := SvStopSpeed
  else
    Control := Speed;
  NewSpeed := Max(0, Speed - Dt * Control * Friction) / Speed;
  Velocity := Velocity * NewSpeed;
end;

procedure TQuakePlayerPhysics.Accelerate(const WishDir: TVector3; const WishSpeed, Dt: Single);
var
  CurrentSpeed, AddSpeed, AccelSpeed: Single;
begin
  CurrentSpeed := TVector3.DotProduct(Velocity, WishDir);
  AddSpeed := WishSpeed - CurrentSpeed;
  if AddSpeed <= 0 then
    Exit;
  AccelSpeed := Min(SvAccelerate * Dt * WishSpeed, AddSpeed);
  Velocity := Velocity + WishDir * AccelSpeed;
end;

procedure TQuakePlayerPhysics.AirAccelerate(WishVeloc: TVector3; const Dt: Single);
var
  WishSpd, CurrentSpeed, AddSpeed, AccelSpeed: Single;
begin
  { Only 30 units/s of wanted speed count in the air, but acceleration uses the
    full wish speed: turning while strafing keeps adding speed (strafe jumping) }
  WishSpd := WishVeloc.Length;
  if WishSpd = 0 then
    Exit;
  WishVeloc := WishVeloc / WishSpd;
  if WishSpd > 30 then
    WishSpd := 30;
  CurrentSpeed := TVector3.DotProduct(Velocity, WishVeloc);
  AddSpeed := WishSpd - CurrentSpeed;
  if AddSpeed <= 0 then
    Exit;
  AccelSpeed := Min(SvAccelerate * FWishSpeed * Dt, AddSpeed);
  Velocity := Velocity + WishVeloc * AccelSpeed;
end;

procedure TQuakePlayerPhysics.AirMove(const Cmd: TQuakeUserCmd; const Yaw, Pitch, Dt: Single);
var
  Forward, Right, Up, WishVel, WishDir: TVector3;
  FMove, SMove, WishSpeed: Single;
begin
  { SV_AirMove: the player model pitch is a third of the view pitch }
  AngleVectors(Yaw, Pitch / 3, Forward, Right, Up);
  FMove := Cmd.ForwardMove;
  SMove := Cmd.SideMove;
  { Hack to not let you back into a teleporter }
  if (FTime < TeleportTime) and (FMove < 0) then
    FMove := 0;

  WishVel := Forward * FMove + Right * SMove;
  WishVel.Z := 0;
  WishSpeed := WishVel.Length;
  if WishSpeed > 0 then
    WishDir := WishVel / WishSpeed
  else
    WishDir := TVector3.Zero;
  if WishSpeed > SvMaxSpeed then
  begin
    WishVel := WishVel * (SvMaxSpeed / WishSpeed);
    WishSpeed := SvMaxSpeed;
  end;
  FWishSpeed := WishSpeed;

  if OnGround then
  begin
    UserFriction(Dt);
    Accelerate(WishDir, WishSpeed, Dt);
  end else
    AirAccelerate(WishVel, Dt);
end;

procedure TQuakePlayerPhysics.WaterMove(const Cmd: TQuakeUserCmd; const Yaw, Pitch, Dt: Single);
var
  Forward, Right, Up, WishVel: TVector3;
  WishSpeed, Speed, NewSpeed, AddSpeed, AccelSpeed: Single;
begin
  { SV_WaterMove: full view pitch, so looking down swims down }
  AngleVectors(Yaw, Pitch, Forward, Right, Up);
  WishVel := Forward * Cmd.ForwardMove + Right * Cmd.SideMove;
  if (Cmd.ForwardMove = 0) and (Cmd.SideMove = 0) and (Cmd.UpMove = 0) then
    WishVel.Z := WishVel.Z - 60 { drift towards bottom }
  else
    WishVel.Z := WishVel.Z + Cmd.UpMove;

  WishSpeed := WishVel.Length;
  if WishSpeed > SvMaxSpeed then
  begin
    WishVel := WishVel * (SvMaxSpeed / WishSpeed);
    WishSpeed := SvMaxSpeed;
  end;
  WishSpeed := WishSpeed * 0.7;

  { Water friction }
  Speed := Velocity.Length;
  if Speed > 0 then
  begin
    NewSpeed := Max(0, Speed - Dt * Speed * SvFriction);
    Velocity := Velocity * (NewSpeed / Speed);
  end else
    NewSpeed := 0;

  { Water acceleration }
  if WishSpeed = 0 then
    Exit;
  AddSpeed := WishSpeed - NewSpeed;
  if AddSpeed <= 0 then
    Exit;
  WishVel := WishVel.Normalize;
  AccelSpeed := Min(SvAccelerate * WishSpeed * Dt, AddSpeed);
  Velocity := Velocity + WishVel * AccelSpeed;
end;

procedure TQuakePlayerPhysics.WaterJumpMove;
begin
  { SV_WaterJump }
  if (FTime > TeleportTime) or (WaterLevel = 0) then
  begin
    InWaterJump := False;
    TeleportTime := 0;
  end;
  Velocity.X := MoveDir.X;
  Velocity.Y := MoveDir.Y;
end;

procedure TQuakePlayerPhysics.CheckStuck;
var
  Org: TVector3;
  X, Y, Z: Integer;
begin
  { SV_CheckStuck }
  if not TestPosition then
  begin
    FOldOrigin := Origin;
    Exit;
  end;
  Org := Origin;
  Origin := FOldOrigin;
  if not TestPosition then
    Exit;
  for Z := 0 to 17 do
    for X := -1 to 1 do
      for Y := -1 to 1 do
      begin
        Origin := Org + Vector3(X, Y, Z);
        if not TestPosition then
          Exit;
      end;
  Origin := Org; { player is stuck }
end;

function TQuakePlayerPhysics.FlyMove(const Dt: Single; out StepTrace: TQuakeTrace): Integer;
var
  BumpCount, NumPlanes, I, J: Integer;
  OriginalVelocity, PrimalVelocity, NewVelocity, Dir, Stop: TVector3;
  Planes: array[0..MaxClipPlanes - 1] of TVector3;
  TimeLeft, D: Single;
  T: TQuakeTrace;
begin
  { SV_FlyMove: slide along up to 4 planes. Result bits: 1 = floor, 2 = wall/step }
  Result := 0;
  FillChar(StepTrace, SizeOf(StepTrace), 0);
  OriginalVelocity := Velocity;
  PrimalVelocity := Velocity;
  NumPlanes := 0;
  TimeLeft := Dt;

  for BumpCount := 0 to 3 do
  begin
    if Velocity.IsPerfectlyZero then
      Break;
    Stop := Origin + Velocity * TimeLeft;
    T := Trace(Origin, Stop);

    if T.AllSolid then
    begin
      { Trapped in another solid }
      Velocity := TVector3.Zero;
      Exit(3);
    end;

    if T.Fraction > 0 then
    begin
      { Actually covered some distance }
      Origin := T.EndPos;
      OriginalVelocity := Velocity;
      NumPlanes := 0;
    end;

    if T.Fraction = 1 then
      Break; { moved the entire distance }

    if T.PlaneNormal.Z > 0.7 then
    begin
      Result := Result or 1; { floor }
      OnGround := True;
      GroundEntity := T.Entity;
    end;
    if T.PlaneNormal.Z = 0 then
    begin
      Result := Result or 2; { step }
      StepTrace := T;
    end;

    AddTouched(T.Entity);

    TimeLeft := TimeLeft - TimeLeft * T.Fraction;

    { Clipped to another plane }
    if NumPlanes >= MaxClipPlanes then
    begin
      Velocity := TVector3.Zero;
      Exit(3);
    end;
    Planes[NumPlanes] := T.PlaneNormal;
    Inc(NumPlanes);

    { Modify OriginalVelocity so it parallels all of the clip planes }
    I := 0;
    while I < NumPlanes do
    begin
      NewVelocity := ClipVelocity(OriginalVelocity, Planes[I], 1);
      J := 0;
      while J < NumPlanes do
      begin
        if (J <> I) and (TVector3.DotProduct(NewVelocity, Planes[J]) < 0) then
          Break; { not ok }
        Inc(J);
      end;
      if J = NumPlanes then
        Break;
      Inc(I);
    end;

    if I <> NumPlanes then
      Velocity := NewVelocity { go along this plane }
    else
    begin
      { Go along the crease }
      if NumPlanes <> 2 then
      begin
        Velocity := TVector3.Zero;
        Exit(7);
      end;
      Dir := TVector3.CrossProduct(Planes[0], Planes[1]);
      D := TVector3.DotProduct(Dir, Velocity);
      Velocity := Dir * D;
    end;

    { If velocity is against the original velocity, stop dead
      to avoid tiny oscillations in sloping corners }
    if TVector3.DotProduct(Velocity, PrimalVelocity) <= 0 then
    begin
      Velocity := TVector3.Zero;
      Exit;
    end;
  end;
end;

function TQuakePlayerPhysics.PushEntity(const Push: TVector3): TQuakeTrace;
begin
  Result := Trace(Origin, Origin + Push);
  Origin := Result.EndPos;
end;

procedure TQuakePlayerPhysics.WalkMove(const Dt: Single);
var
  OldOnGround: Boolean;
  OldOrg, OldVel, NoStepOrg, NoStepVel, UpMove, DownMove: TVector3;
  Clip: Integer;
  StepTrace, DownTrace: TQuakeTrace;
begin
  { SV_WalkMove: slide, and if blocked by a step, try going up and over it }
  OldOnGround := OnGround;
  OnGround := False;
  GroundEntity := -1;
  OldOrg := Origin;
  OldVel := Velocity;

  Clip := FlyMove(Dt, StepTrace);
  if (Clip and 2) = 0 then
    Exit; { move didn't block on a step }
  if (not OldOnGround) and (WaterLevel = 0) then
    Exit; { don't stair up while jumping }
  if InWaterJump then
    Exit;

  NoStepOrg := Origin;
  NoStepVel := Velocity;

  { Try moving up and forward to go up a step }
  Origin := OldOrg;
  UpMove := Vector3(0, 0, StepSize);
  DownMove := Vector3(0, 0, -StepSize + OldVel.Z * Dt);

  PushEntity(UpMove);
  Velocity := Vector3(OldVel.X, OldVel.Y, 0);
  FlyMove(Dt, StepTrace);

  { Move down }
  DownTrace := PushEntity(DownMove);
  if DownTrace.PlaneNormal.Z > 0.7 then
  begin
    OnGround := True;
    GroundEntity := DownTrace.Entity;
  end else
  begin
    { If the push down didn't end up on good ground, use the move without
      the step up. This happens near wall / slope combinations. }
    Origin := NoStepOrg;
    Velocity := NoStepVel;
  end;
end;

procedure TQuakePlayerPhysics.Frame(const Cmd: TQuakeUserCmd; const Yaw, Pitch, Dt: Single);
var
  Forward, Right, Up: TVector3;
  WasOnGround: Boolean;
  FallSpeed: Single;
  I: Integer;
begin
  FTime := FTime + Dt;

  { PlayerPreThink (client.qc) }
  CheckWater;
  if WaterLevel = 2 then
  begin
    AngleVectors(Yaw, 0, Forward, Right, Up);
    CheckWaterJump(Forward);
  end;
  if Cmd.Jump then
    PlayerJump
  else
    JumpReleased := True;

  { SV_ClientThink }
  if InWaterJump then
    WaterJumpMove
  else
  if WaterLevel >= 2 then
    WaterMove(Cmd, Yaw, Pitch, Dt)
  else
    AirMove(Cmd, Yaw, Pitch, Dt);

  { SV_Physics_Client, MOVETYPE_WALK }
  for I := 0 to 2 do
    Velocity.Data[I] := EnsureRange(Velocity.Data[I], -SvMaxVelocity, SvMaxVelocity);
  CheckWater;
  if (WaterLevel <= 1) and not InWaterJump then
    Velocity.Z := Velocity.Z - SvGravity * Dt;
  CheckStuck;

  WasOnGround := OnGround;
  FallSpeed := Velocity.Z;
  WalkMove(Dt);
  CheckWater;

  { PlayerPostThink: remember how fast we were falling when we landed }
  if OnGround and not WasOnGround then
    LandingSpeed := Min(LandingSpeed, FallSpeed);
end;

procedure TQuakePlayerPhysics.AddTouched(const Entity: Integer);
var
  E: Integer;
begin
  if Entity <= 0 then
    Exit; { world and boxes do not react to touch }
  for E in Touched do
    if E = Entity then
      Exit;
  SetLength(Touched, Length(Touched) + 1);
  Touched[High(Touched)] := Entity;
end;

procedure TQuakePlayerPhysics.Move(const Cmd: TQuakeUserCmd; const Yaw, Pitch, SecondsPassed: Single);
var
  Remaining, Dt: Single;
begin
  Jumped := False;
  LandingSpeed := 0;
  SetLength(Touched, 0);
  if FBsp = nil then
    Exit;
  Remaining := Min(SecondsPassed, 0.1); { like host_frametime, never more than 0.1 }
  while Remaining > 0 do
  begin
    Dt := Min(Remaining, MaxStep);
    Frame(Cmd, Yaw, Pitch, Dt);
    Remaining := Remaining - Dt;
  end;
end;

end.
