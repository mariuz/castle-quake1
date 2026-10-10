{ Monster glue: the TQuakeMonsterEnv implementation the monsters see, traces, steps, sight, noise, their attacks.
  Part of the QuakeWorld unit (included from quakeworld.pas). }

type
  { Gives monsters access to the world (traces, the player, missiles) }
  TWorldMonsterEnv = class(TQuakeMonsterEnv)
  private
    FWorld: TQuakeWorld;
  public
    constructor Create(const AWorld: TQuakeWorld);
    function Time: Single; override;
    function PlayerOrigin: TVector3; override;
    function PlayerVelocity: TVector3; override;
    function PlayerAlive: Boolean; override;
    function CanSeePlayer(const M: TQuakeMonster): Boolean; override;
    function CanSeeMonster(const M, Other: TQuakeMonster): Boolean; override;
    function SightEntity(const M: TQuakeMonster): TQuakeMonster; override;
    function PlayerHostile: Boolean; override;
    function MoveStep(const M: TQuakeMonster; const Move: TVector3): Boolean; override;
    function TossStep(const M: TQuakeMonster; const Dt: Single; out HitPlayer: Boolean;
      out HitMonster: TQuakeMonster): Boolean; override;
    procedure DamagePlayer(const M: TQuakeMonster; const Damage: Single); override;
    procedure DamageMonster(const M, Victim: TQuakeMonster; const Damage: Single); override;
    procedure FireBullets(const M: TQuakeMonster; const Count: Integer; const Spread: Single;
      const Aim: TVector3); override;
    procedure LaunchMissile(const M: TQuakeMonster; const Kind: TMonsterAttack;
      const Org, Vel: TVector3); override;
    procedure CastLightning(const M: TQuakeMonster; const Aim: TVector3); override;
  end;

constructor TWorldMonsterEnv.Create(const AWorld: TQuakeWorld);
begin
  inherited Create;
  FWorld := AWorld;
end;

function TWorldMonsterEnv.Time: Single;
begin
  Result := FWorld.FTime;
end;

function TWorldMonsterEnv.PlayerOrigin: TVector3;
begin
  Result := FWorld.FPhys.Origin;
end;

function TWorldMonsterEnv.PlayerVelocity: TVector3;
begin
  Result := FWorld.FPhys.Velocity;
end;

function TWorldMonsterEnv.PlayerAlive: Boolean;
begin
  Result := not FWorld.FPlayerDead and not FWorld.FIntermission;
end;

function TWorldMonsterEnv.CanSeePlayer(const M: TQuakeMonster): Boolean;
begin
  Result := FWorld.MonsterCanSeePlayer(M);
end;

function TWorldMonsterEnv.CanSeeMonster(const M, Other: TQuakeMonster): Boolean;
begin
  Result := FWorld.MonsterCanSeeMonster(M, Other);
end;

function TWorldMonsterEnv.SightEntity(const M: TQuakeMonster): TQuakeMonster;
begin
  Result := FWorld.MonsterSightEntity(M);
end;

function TWorldMonsterEnv.PlayerHostile: Boolean;
begin
  Result := FWorld.FTime < FWorld.FShowHostile;
end;

function TWorldMonsterEnv.MoveStep(const M: TQuakeMonster; const Move: TVector3): Boolean;
begin
  Result := FWorld.MonsterMoveStep(M, Move);
end;

function TWorldMonsterEnv.TossStep(const M: TQuakeMonster; const Dt: Single;
  out HitPlayer: Boolean; out HitMonster: TQuakeMonster): Boolean;
begin
  Result := FWorld.MonsterTossStep(M, Dt, HitPlayer, HitMonster);
end;

procedure TWorldMonsterEnv.DamagePlayer(const M: TQuakeMonster; const Damage: Single);
begin
  FWorld.DamagePlayer(Max(1, Round(Damage)), FWorld.FHud);
end;

procedure TWorldMonsterEnv.DamageMonster(const M, Victim: TQuakeMonster; const Damage: Single);
begin
  FWorld.DamageMonster(Victim, Damage, M.Origin, M);
end;

procedure TWorldMonsterEnv.FireBullets(const M: TQuakeMonster; const Count: Integer;
  const Spread: Single; const Aim: TVector3);
begin
  FWorld.MonsterFireBullets(M, Count, Spread, Aim);
end;

procedure TWorldMonsterEnv.LaunchMissile(const M: TQuakeMonster; const Kind: TMonsterAttack;
  const Org, Vel: TVector3);
begin
  FWorld.MonsterLaunch(M, Kind, Org, Vel);
end;

procedure TWorldMonsterEnv.CastLightning(const M: TQuakeMonster; const Aim: TVector3);
begin
  FWorld.MonsterLightning(M, Aim);
end;

function TQuakeWorld.PointContents(const P: TVector3): Integer;
begin
  if FBsp <> nil then
    Result := FBsp.PointContentsCge(P)
  else
    Result := CONTENTS_EMPTY;
end;



{ Monsters }

function TQuakeWorld.MonsterTrace(const M: TQuakeMonster; const Start, Stop: TVector3): TQuakeTrace;
var
  Hull, I: Integer;
  ClipOffset, BoxMins, BoxMaxs: TVector3;
  T: TQuakeTrace;
  Other: TQuakeMonster;

  procedure Combine(const Entity: Integer);
  begin
    if T.AllSolid or T.StartSolid or (T.Fraction < Result.Fraction) then
    begin
      if (T.Fraction < 1) or T.StartSolid then
        T.Entity := Entity;
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
  { SV_Move for a monster box: the hull that fits its size, offset by
    clip_mins - mins (SV_HullForEntity), then brush entities, other monsters
    and the player }
  Hull := FBsp.HullForSize(M.Def.Mins, M.Def.Maxs);
  ClipOffset := FBsp.HullClipMins(Hull) - M.Def.Mins;
  Result := FBsp.TraceHull(Hull, 0, ClipOffset, Start, Stop);
  if (Result.Fraction < 1) or Result.StartSolid then
    Result.Entity := 0;
  if Result.AllSolid then
    Exit;

  for I := 0 to High(FPhys.SolidModels) do
  begin
    T := FBsp.TraceHull(Hull, FPhys.SolidModels[I].ModelIndex,
      FPhys.SolidModels[I].Offset + ClipOffset, Start, Stop);
    Combine(FPhys.SolidModels[I].ModelIndex);
  end;

  for I := 0 to FMonsters.Count - 1 do
  begin
    Other := FMonsters[I];
    if (Other <> M) and MonsterBounds(Other, BoxMins, BoxMaxs) then
    begin
      T := TraceSegmentBox(BoxMins - M.Def.Maxs, BoxMaxs - M.Def.Mins, Start, Stop);
      Combine(MonsterEntityBase - I);
    end;
  end;

  if not FPlayerDead then
  begin
    PlayerBox(BoxMins, BoxMaxs);
    T := TraceSegmentBox(BoxMins - M.Def.Maxs, BoxMaxs - M.Def.Mins, Start, Stop);
    Combine(-3);
  end;
end;

function TQuakeWorld.MonsterCheckBottom(const M: TQuakeMonster): Boolean;
var
  AMins, AMaxs, Start, Stop: TVector3;
  T: TQuakeTrace;
  X, Y: Integer;
  Mid: Single;
begin
  { SV_CheckBottom: is there ground under all four corners? }
  AMins := M.Origin + M.Def.Mins;
  AMaxs := M.Origin + M.Def.Maxs;
  Start.Z := AMins.Z - 1;
  Result := True;
  for X := 0 to 1 do
    for Y := 0 to 1 do
    begin
      if X = 0 then Start.X := AMins.X else Start.X := AMaxs.X;
      if Y = 0 then Start.Y := AMins.Y else Start.Y := AMaxs.Y;
      if FBsp.PointContents(Start) <> CONTENTS_SOLID then
        Result := False;
    end;
  if Result then
    Exit;

  { Real check: the corners must be within a step of the middle }
  Start := Vector3((AMins.X + AMaxs.X) * 0.5, (AMins.Y + AMaxs.Y) * 0.5, AMins.Z);
  Stop := Start - Vector3(0, 0, 2 * StepSize);
  T := FPhys.Trace(Start, Stop, True, True);
  if T.Fraction = 1 then
    Exit(False);
  Mid := T.EndPos.Z;
  for X := 0 to 1 do
    for Y := 0 to 1 do
    begin
      if X = 0 then Start.X := AMins.X else Start.X := AMaxs.X;
      if Y = 0 then Start.Y := AMins.Y else Start.Y := AMaxs.Y;
      Stop.X := Start.X;
      Stop.Y := Start.Y;
      T := FPhys.Trace(Start, Stop, True, True);
      if (T.Fraction = 1) or (Mid - T.EndPos.Z > StepSize) then
        Exit(False);
    end;
  Result := True;
end;

function TQuakeWorld.MonsterMoveStep(const M: TQuakeMonster; const Move: TVector3): Boolean;
var
  OldOrg, NewOrg, Stop: TVector3;
  T: TQuakeTrace;
  Dz: Single;
  Cont: Integer;
begin
  Result := False;
  if FBsp = nil then
    Exit;
  OldOrg := M.Origin;

  if M.Def.Move in [mmFly, mmSwim] then
  begin
    { Fliers and swimmers keep a little above the player (SV_movestep) }
    NewOrg := OldOrg + Move;
    if not FPlayerDead then
    begin
      Dz := OldOrg.Z - FPhys.Origin.Z;
      if Dz > 40 then
        NewOrg.Z := NewOrg.Z - Min(8, Dz - 40)
      else if Dz < 30 then
        NewOrg.Z := NewOrg.Z + Min(8, 30 - Dz);
    end;
    T := MonsterTrace(M, OldOrg, NewOrg);
    if T.Fraction < 1 then
    begin
      { Try again without the height change }
      NewOrg.Z := OldOrg.Z + Move.Z;
      T := MonsterTrace(M, OldOrg, NewOrg);
      if T.Fraction < 1 then
        Exit;
    end;
    if M.Def.Move = mmSwim then
    begin
      Cont := FBsp.PointContents(T.EndPos);
      if not ((Cont <= CONTENTS_WATER) and (Cont > CONTENTS_SKY)) then
        Exit; { fish stay in the water }
    end;
    M.Origin := T.EndPos;
    Exit(True);
  end;

  { Walkers: push up a step, trace down two steps }
  NewOrg := OldOrg + Move;
  NewOrg.Z := NewOrg.Z + StepSize;
  Stop := NewOrg;
  Stop.Z := Stop.Z - StepSize * 2;
  T := MonsterTrace(M, NewOrg, Stop);
  if T.AllSolid then
    Exit;
  if T.StartSolid then
  begin
    NewOrg.Z := NewOrg.Z - StepSize;
    T := MonsterTrace(M, NewOrg, Stop);
    if T.AllSolid or T.StartSolid then
      Exit;
  end;
  if T.Fraction = 1 then
    Exit; { walked off an edge }

  M.Origin := T.EndPos;
  if not MonsterCheckBottom(M) then
  begin
    M.Origin := OldOrg;
    Exit;
  end;
  Result := True;
end;

function TQuakeWorld.MonsterTossStep(const M: TQuakeMonster; const Dt: Single;
  out HitPlayer: Boolean; out HitMonster: TQuakeMonster): Boolean;
var
  T: TQuakeTrace;
begin
  { MOVETYPE_TOSS for leaps: gravity, slide on walls, stop on floors }
  HitPlayer := False;
  HitMonster := nil;
  Result := False;
  if FBsp = nil then
    Exit(True);
  M.Velocity.Z := M.Velocity.Z - SvGravity * Dt;
  T := MonsterTrace(M, M.Origin, M.Origin + M.Velocity * Dt);
  if T.AllSolid then
    Exit(True);
  M.Origin := T.EndPos;
  if T.Fraction < 1 then
  begin
    HitPlayer := T.Entity = -3;
    if (T.Entity <= MonsterEntityBase) and (MonsterEntityBase - T.Entity < FMonsters.Count) then
      HitMonster := FMonsters[MonsterEntityBase - T.Entity];
    M.Velocity := ClipVelocity(M.Velocity, T.PlaneNormal, 1);
    if T.PlaneNormal.Z > 0.7 then
      Result := True;
  end;
end;

procedure TQuakeWorld.MonsterDropToFloor(const M: TQuakeMonster);
var
  T: TQuakeTrace;
begin
  { droptofloor: monsters are placed above the floor in the map }
  T := MonsterTrace(M, M.Origin, M.Origin - Vector3(0, 0, 256));
  if (T.Fraction < 1) and not T.AllSolid and not T.StartSolid then
    M.Origin := T.EndPos;
end;

function TQuakeWorld.MonsterCanSeePlayer(const M: TQuakeMonster): Boolean;
begin
  { visible(): line from the monster's eyes to the player's eyes, only
    world geometry and brush entities block it }
  if (FBsp = nil) or FPlayerDead or FIntermission then
    Exit(False);
  Result := FPhys.Trace(M.Origin + Vector3(0, 0, 25), FPhys.EyePosition, True, True).Fraction = 1;
end;

function TQuakeWorld.MonsterCanSeeMonster(const M, Other: TQuakeMonster): Boolean;
begin
  if FBsp = nil then
    Exit(False);
  Result := FPhys.Trace(M.Origin + Vector3(0, 0, 25), Other.Origin + Vector3(0, 0, 25),
    True, True).Fraction = 1;
end;

function TQuakeWorld.MonsterSightEntity(const M: TQuakeMonster): TQuakeMonster;
const
  SightRange = 1000;
var
  Other: TQuakeMonster;
begin
  { sight_entity: a monster that has just found the player wakes up the
    monsters that can see it }
  for Other in FMonsters do
    if (Other <> M) and Other.JustSpottedPlayer and
       (PointsDistance(M.Origin, Other.Origin) < SightRange) and
       MonsterCanSeeMonster(M, Other) then
      Exit(Other);
  Result := nil;
end;

procedure TQuakeWorld.PropagateNoise;
const
  HearRange = 1000;
var
  M: TQuakeMonster;
  Eye: TVector3;
  PlayerLeaf: Integer;
begin
  { Gunfire wakes idle monsters nearby whose leaf is in the player's PVS
    (sound travels through open doorways, not through walls) and that are
    not shut off by a closed door }
  FShowHostile := FTime + 1;
  if FBsp = nil then
    Exit;
  Eye := FPhys.EyePosition;
  PlayerLeaf := FBsp.PointLeaf(Eye);
  for M in FMonsters do
    if (M.State = msIdle) and not M.Ambush and not M.Crucified and
       (PointsDistance(Eye, M.Origin) < HearRange) and
       FBsp.LeafVisible(PlayerLeaf, FBsp.PointLeaf(M.Center)) and
       not BrushModelBlocks(Eye, M.Center) then
      M.HearNoise;
end;

function TQuakeWorld.BrushModelBlocks(const Start, Stop: TVector3): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FPhys.SolidModels) do
    if FBsp.TraceHull(0, FPhys.SolidModels[I].ModelIndex, FPhys.SolidModels[I].Offset,
      Start, Stop).Fraction < 1 then
      Exit(True);
  Result := False;
end;

procedure TQuakeWorld.MonsterFireBullets(const M: TQuakeMonster; const Count: Integer;
  const Spread: Single; const Target: TVector3);
var
  Src, Aim, Right, Up, Dir: TVector3;
  T: TQuakeTrace;
  I, Hits, J: Integer;
  Victim: TQuakeMonster;
  HitPlayer: Boolean;
  Hit: array of TQuakeMonster;
  HitDamage: array of Single;
begin
  { army_fire: pellets with spread towards the target; they hit whatever is
    in the way, other monsters included (multidamage) }
  Src := M.Origin + Vector3(0, 0, 20);
  Aim := (Target - Src).Normalize;
  Right := Vector3(Aim.Y, -Aim.X, 0);
  if Right.IsPerfectlyZero then
    Right := Vector3(1, 0, 0);
  Right := Right.Normalize;
  Up := TVector3.CrossProduct(Right, Aim);
  Hits := 0;
  SetLength(Hit, 0);
  SetLength(HitDamage, 0);
  for I := 1 to Count do
  begin
    Dir := Aim + Right * ((Random * 2 - 1) * Spread) + Up * ((Random * 2 - 1) * Spread);
    T := TraceMissile(Src, Src + Dir * 2048, M, Victim, HitPlayer);
    if HitPlayer then
      Inc(Hits)
    else
    if Victim <> nil then
    begin
      Particles.SpawnBlood(QuakeToCge(T.EndPos - Dir * 4), QuakeToCge(Dir * -1));
      J := 0;
      while (J < Length(Hit)) and (Hit[J] <> Victim) do
        Inc(J);
      if J = Length(Hit) then
      begin
        SetLength(Hit, J + 1);
        SetLength(HitDamage, J + 1);
        Hit[J] := Victim;
        HitDamage[J] := 0;
      end;
      HitDamage[J] := HitDamage[J] + 4;
    end else
    if T.Fraction < 1 then
      Particles.SpawnPuff(QuakeToCge(T.EndPos - Dir * 4), QuakeToCge(T.PlaneNormal));
  end;
  Lighting.TriggerMuzzleFlash(QuakeToCge(Src), 1.5);
  if Hits > 0 then
    DamagePlayer(4 * Hits, FHud);
  for J := 0 to High(Hit) do
    DamageMonster(Hit[J], HitDamage[J], Src, M);
end;

procedure TQuakeWorld.MonsterLaunch(const M: TQuakeMonster; const Kind: TMonsterAttack;
  const Org, Vel: TVector3);
var
  PKind: TQuakeProjectileKind;
  P: TQuakeProjectile;
begin
  case Kind of
    maGrenade: PKind := pjOgreGrenade;
    maWizSpike: PKind := pjWizSpike;
    maKnightSpike: PKind := pjKnightSpike;
    maLaser: PKind := pjLaser;
    maVorePod: PKind := pjVorePod;
    maZombieGib: PKind := pjZombieGib;
    maLavaBall: PKind := pjLavaBall;
    else Exit;
  end;
  P := TQuakeProjectile.Create(FRootTransform, PKind, Org, Vel);
  P.Owner := M;
  FProjectiles.Add(P);
end;

procedure TQuakeWorld.MonsterLightning(const M: TQuakeMonster; const Target: TVector3);
var
  Org, Dir: TVector3;
  T: TQuakeTrace;
  Victim: TQuakeMonster;
  HitPlayer: Boolean;
begin
  { CastLightning (shambler): 600 units towards the target, 10 damage to
    whatever the bolt hits first }
  Org := M.Origin + Vector3(0, 0, 40);
  Dir := (Target + Vector3(0, 0, 16) - Org).Normalize;
  T := TraceMissile(Org, M.Origin + Dir * 600, M, Victim, HitPlayer);
  if HitPlayer then
    DamagePlayer(10, FHud)
  else
  if Victim <> nil then
    DamageMonster(Victim, 10, Org, M);
  ShowBeam(1, Org, T.EndPos, 0.1);
end;

procedure TQuakeWorld.MonsterExplode(const M: TQuakeMonster);
begin
  { tbaby_die: the spawn blows up }
  M.ExplodePending := False;
  M.Transform.Exists := False;
  RadiusDamage(M.Center, 120, M, FHud, False, False, M);
  Particles.SpawnExplosion(QuakeToCge(M.Center));
  Lighting.TriggerMuzzleFlash(QuakeToCge(M.Center), 6.0);
end;

procedure TQuakeWorld.LightningEvent;
var
  Sub, Le1, Le2: TQuakeSubmodel;
  M: TQuakeMonster;
  C1, C2, AMins, AMaxs: TVector3;
begin
  { lightning_use: both electrodes (doors targeting "lightning") must have
    stopped at the same end; at the top the bolt shocks Chthon }
  if FLightningEnd >= FTime + 1 then
    Exit;
  Le1 := nil;
  Le2 := nil;
  for Sub in FGeometry.Submodels do
    if SameText(Sub.Target, 'lightning') then
    begin
      if Le1 = nil then
        Le1 := Sub
      else if Le2 = nil then
        Le2 := Sub;
    end;
  if (Le1 = nil) or (Le2 = nil) then
    Exit;
  if not (Le1.State in [smsOpen, smsClosed]) or (Le1.State <> Le2.State) then
    Exit;

  FLightningEnd := FTime + 1;
  Sounds.Play('sound/misc/power.wav');
  C1 := TVector3.Zero;
  C2 := TVector3.Zero;
  if SubmodelBounds(Le1, AMins, AMaxs) then
    C1 := (AMins + AMaxs) * 0.5;
  if SubmodelBounds(Le2, AMins, AMaxs) then
    C2 := (AMins + AMaxs) * 0.5;
  ShowBeam(2, C1, C2, 1.0);

  if Le1.State = smsOpen then
    for M in FMonsters do
      if M.EntityClassName = 'monster_boss' then
        M.LightningShock;
end;
