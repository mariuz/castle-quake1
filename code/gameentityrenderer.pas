{ The entities of the QuakeC view and of the demo / network view, drawn the
  same way: Alias models with pose blending, sprites, brush model files
  (health boxes), the map's brush entities, entity alpha, model trails,
  temp entities (impacts, explosions) and lightning beams. A view keeps its
  own TEntityVisual per entity and tells the renderer what each shows. }
unit GameEntityRenderer;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math,
  CastleVectors, CastleTransform, CastleScene, CastleQuaternions, CastleBehaviors, CastleUtils,
  X3DNodes,
  GameVideo,
  QuakePak, QuakeGeometry, QuakeLight, QuakeSound, QuakeParticles, QuakeMdl, QuakeSprite, QuakeDemo,
  QuakeEffectParticles;

type
  { What an entity is drawn with, kept from frame to frame }
  TEntityVisual = record
    Transform: TCastleTransform;
    Scene: TCastleScene;
    Mdl: TQuakeMdl;
    Model: String;
    Frame, Skin: Integer;
    { The colors its skin is painted in (a player's shirt and pants) }
    Colors: Integer;
    Sprite: Boolean;
    TrailTimer: Single;
    { effectinfo.txt's TR_ trails run from here (Quake coordinates) }
    TrailFrom: TVector3;
    TrailValid: Boolean;
    { The entity alpha the scene was last given (0: opaque, its own) }
    Alpha: Single;
    { r_lerpmodels: the pose blends from PrevFrame since LerpStart }
    PrevFrame: Integer;
    LerpStart: Single;
    LerpDone: Boolean;
    { r_lerpmove: the drawn place and angles glide from Move/AngFrom to the
      entity's latest ones (Move/AngTo) since MoveStart }
    MoveFrom, MoveTo, AngFrom, AngTo: TVector3;
    MoveStart: Single;
    MoveValid: Boolean;
  end;

  TEntityRenderer = class
  private
    FItems: TCastleTransform;
    FNamePrefix: String;
    FBeams: array[0..2] of record
      Segments: array of TCastleTransform;
      Time: Single;
    end;
    procedure ShowSprite(var V: TEntityVisual; const Model: String; const Origin, Angles: TVector3;
      const Frame: Integer; const Time: Single);
    procedure UpdatePose(var V: TEntityVisual; const Mdl: TQuakeMdl; const Frame: Integer; const Time: Single);
    procedure ModelTrail(var V: TEntityVisual; const Flags: Integer; const Origin, Pos: TVector3; const Dt: Single);
  public
    { The map's brush entities by model number ("*N"); a view clears
      SubmodelUsed before it shows its entities and hides the unused after }
    Submodels: array of TQuakeSubmodel;
    SubmodelUsed: array of Boolean;
    SubmodelOrigin: array of TVector3;
    { Items: where the visuals are added; NamePrefix names their components
      for the inspector ("edict", "entity") }
    constructor Create(const AItems: TCastleTransform; const ANamePrefix: String);
    destructor Destroy; override;
    procedure SetupSubmodels(const Geometry: TQuakeGeometry; const ModelCount: Integer);
    procedure ClearSubmodels;

    { Show Model at Origin (Quake coordinates) in this frame and skin;
      Colors paints a player's skin (0: as it is). Time is the game's or the
      demo's clock (pose blending, sprite frames, spinning items). }
    procedure Show(var V: TEntityVisual; const Model: String; const Origin, Angles: TVector3;
      const Frame, Skin, Effects, Colors: Integer; const Time, Dt: Single);
    procedure Hide(var V: TEntityVisual);
    procedure FreeVisual(var V: TEntityVisual);
    { Alpha 0: opaque, else the opacity }
    procedure ApplyAlpha(var V: TEntityVisual; const Alpha: Single);
    { r_lerpmove: where to draw an entity that moves in steps (Step: a
      walking monster) so it glides between them }
    procedure LerpMove(var V: TEntityVisual; const Origin, Angles: TVector3; const Step: Boolean;
      const Time: Single; out DrawOrigin, DrawAngles: TVector3);

    { CL_ParseTEnt: the particles, sound and light of a temp entity, or a
      lightning beam from Pos to Pos2 }
    procedure TempEntity(const Kind: Integer; const Pos, Pos2: TVector3);
    procedure ShowBeam(const Pool: Integer; const StartQ, StopQ: TVector3; const Duration: Single);
    procedure UpdateBeams(const Dt: Single);
    procedure ClearBeams;

    { A mod's effectinfo.txt effect for a temp entity (TE_GUNSHOT...) or a
      model's trail (TR_ROCKET...): False when it has none, for the
      engine's own particles }
    function EffectByName(const AName: String; const QuakePos: TVector3): Boolean;
    function EffectTrail(const Flags: Integer; const FromPos, ToPos: TVector3): Boolean;
  end;

{ DarkPlaces' effect name of a temp entity ('' for the beams) }
function TempEntityEffectName(const Kind: Integer): String;

implementation

const
  BeamModels: array[0..2] of String = ('progs/bolt.mdl', 'progs/bolt2.mdl', 'progs/bolt3.mdl');
  TrailFlags = MF_ROCKET or MF_GRENADE or MF_GIB or MF_ZOMGIB or MF_TRACER or MF_TRACER2 or MF_TRACER3;

function TempEntityEffectName(const Kind: Integer): String;
begin
  case Kind of
    TE_SPIKE: Result := 'TE_SPIKE';
    TE_SUPERSPIKE: Result := 'TE_SUPERSPIKE';
    TE_GUNSHOT: Result := 'TE_GUNSHOT';
    TE_EXPLOSION: Result := 'TE_EXPLOSION';
    TE_TAREXPLOSION: Result := 'TE_TAREXPLOSION';
    TE_WIZSPIKE: Result := 'TE_WIZSPIKE';
    TE_KNIGHTSPIKE: Result := 'TE_KNIGHTSPIKE';
    TE_LAVASPLASH: Result := 'TE_LAVASPLASH';
    TE_TELEPORT: Result := 'TE_TELEPORT';
    TE_EXPLOSION2: Result := 'TE_EXPLOSION2';
    else Result := '';
  end;
end;

constructor TEntityRenderer.Create(const AItems: TCastleTransform; const ANamePrefix: String);
begin
  inherited Create;
  FItems := AItems;
  FNamePrefix := ANamePrefix;
end;

destructor TEntityRenderer.Destroy;
begin
  ClearBeams;
  inherited Destroy;
end;

procedure TEntityRenderer.SetupSubmodels(const Geometry: TQuakeGeometry; const ModelCount: Integer);
var
  Sub: TQuakeSubmodel;
begin
  ClearSubmodels;
  SetLength(Submodels, ModelCount);
  SetLength(SubmodelUsed, ModelCount);
  SetLength(SubmodelOrigin, ModelCount);
  for Sub in Geometry.Submodels do
  begin
    if (Sub.ModelIndex > 0) and (Sub.ModelIndex < ModelCount) then
      Submodels[Sub.ModelIndex] := Sub;
    Sub.Transform.Exists := False;
  end;
end;

procedure TEntityRenderer.ClearSubmodels;
begin
  SetLength(Submodels, 0);
  SetLength(SubmodelUsed, 0);
  SetLength(SubmodelOrigin, 0);
end;

procedure TEntityRenderer.FreeVisual(var V: TEntityVisual);
begin
  if V.Transform <> nil then
  begin
    if V.Transform.Parent <> nil then
      V.Transform.Parent.Remove(V.Transform);
    FreeAndNil(V.Transform); { owns the scene }
  end;
  V.Scene := nil;
  V.Mdl := nil;
  V.Model := '';
  V.Frame := -1;
  V.Alpha := 0;
  V.Sprite := False;
  V.MoveValid := False;
  V.TrailValid := False;
end;

procedure TEntityRenderer.Hide(var V: TEntityVisual);
begin
  if V.Transform <> nil then
    V.Transform.Exists := False;
end;

procedure TEntityRenderer.UpdatePose(var V: TEntityVisual; const Mdl: TQuakeMdl; const Frame: Integer;
  const Time: Single);
var
  F: Integer;
  T: Single;
begin
  F := EnsureRange(Frame, 0, Max(0, Mdl.FrameCount - 1));
  if V.Frame <> F then
  begin
    { A new pose: blend from the last one (a new scene starts at it) }
    if V.Frame < 0 then
      V.PrevFrame := F
    else
      V.PrevFrame := V.Frame;
    V.Frame := F;
    V.LerpStart := Time;
    V.LerpDone := False;
  end;
  if V.LerpDone then
    Exit;
  T := (Time - V.LerpStart) / ModelLerpTime;
  if not ModelLerp or (V.PrevFrame = F) or (T >= 1) or (T < 0) then
  begin
    Mdl.ApplyFrame(V.Scene, F);
    V.LerpDone := True;
  end else
    Mdl.ApplyLerp(V.Scene, V.PrevFrame, F, T);
end;

procedure TEntityRenderer.ApplyAlpha(var V: TEntityVisual; const Alpha: Single);
var
  OpaqueMode: TAlphaMode;
begin
  { A new scene is opaque (Alpha 0); only a change touches the nodes }
  if (V.Scene = nil) or (V.Alpha = Alpha) then
    Exit;
  V.Alpha := Alpha;
  if V.Sprite then
    OpaqueMode := amMask
  else
    OpaqueMode := amAuto;
  if Alpha = 0 then
    SetSceneOpacity(V.Scene, 1, OpaqueMode)
  else
    SetSceneOpacity(V.Scene, Alpha, OpaqueMode);
end;

procedure TEntityRenderer.ShowSprite(var V: TEntityVisual; const Model: String; const Origin, Angles: TVector3;
  const Frame: Integer; const Time: Single);
var
  Spr: TQuakeSprite;
  Billboard: TCastleBillboard;
begin
  Spr := SpriteManager.GetSprite(Model);
  if Spr = nil then
  begin
    Hide(V);
    Exit;
  end;
  if (V.Transform = nil) or (V.Model <> Model) then
  begin
    FreeVisual(V);
    V.Transform := TCastleTransform.Create(nil);
    V.Transform.Name := ComponentName(FNamePrefix);
    V.Scene := Spr.CreateScene;
    V.Scene.Name := V.Transform.Name + '_scene';
    V.Transform.Add(V.Scene);
    V.Transform.InsertComponent(V.Scene);
    Billboard := Spr.CreateBillboard(V.Transform);
    if Billboard <> nil then
      V.Transform.AddBehavior(Billboard);
    FItems.Add(V.Transform);
    V.Model := Model;
    V.Sprite := True;
  end;
  V.Transform.Exists := True;
  Spr.ApplyFrame(V.Scene, Frame, Time);
  V.Transform.Translation := QuakeToCge(Origin);
  if Spr.SpriteType = SPR_ORIENTED then
    V.Transform.Rotation := (QuatFromAxisAngle(Vector3(0, 1, 0), DegToRad(Angles.Y)) *
      QuatFromAxisAngle(Vector3(0, 0, 1), DegToRad(Angles.X)) *
      QuatFromAxisAngle(Vector3(1, 0, 0), DegToRad(Angles.Z))).ToAxisAngle;
end;

procedure TEntityRenderer.Show(var V: TEntityVisual; const Model: String; const Origin, Angles: TVector3;
  const Frame, Skin, Effects, Colors: Integer; const Time, Dt: Single);
var
  Q: TQuaternion;
  Pos: TVector3;
  Mdl: TQuakeMdl;
  Idx, SkinIdx: Integer;
  Yaw: Single;
  Ext: String;
begin
  if Model = '' then
  begin
    Hide(V);
    Exit;
  end;
  { Brush models (doors, plats) are the map's own submodels }
  if Model[1] = '*' then
  begin
    Hide(V);
    Idx := StrToIntDef(Copy(Model, 2, MaxInt), -1);
    if (Idx > 0) and (Idx < Length(Submodels)) and (Submodels[Idx] <> nil) then
    begin
      Submodels[Idx].Transform.Exists := True;
      Submodels[Idx].Transform.Translation := QuakeToCge(Origin);
      { Rotating brush entities turn around their origin (R_RotateForEntity) }
      Submodels[Idx].Transform.Rotation := QuakeAnglesRotation(Angles);
      SubmodelOrigin[Idx] := Origin;
      SubmodelUsed[Idx] := True;
    end;
    Exit;
  end;
  Ext := LowerCase(ExtractFileExt(Model));
  { The health and ammo boxes are brush model files (maps/b_*.bsp) }
  if Ext = '.bsp' then
  begin
    if (V.Transform = nil) or (V.Model <> Model) then
    begin
      FreeVisual(V);
      V.Transform := TCastleTransform.Create(nil);
      V.Transform.Name := ComponentName(FNamePrefix);
      V.Scene := CreateBspModelScene(Model, V.Transform);
      if V.Scene = nil then
      begin
        FreeVisual(V);
        Exit;
      end;
      V.Scene.Name := V.Transform.Name + '_scene';
      V.Scene.Collides := False;
      V.Transform.Add(V.Scene);
      FItems.Add(V.Transform);
      V.Model := Model;
    end;
    V.Transform.Exists := True;
    V.Transform.Translation := QuakeToCge(Origin);
    Exit;
  end;
  if Ext = '.spr' then
  begin
    ShowSprite(V, Model, Origin, Angles, Frame, Time);
    Exit;
  end;
  if Ext <> '.mdl' then
  begin
    Hide(V);
    Exit;
  end;
  Mdl := MdlManager.GetModel(Model);
  if Mdl = nil then
  begin
    Hide(V);
    Exit;
  end;
  SkinIdx := EnsureRange(Skin, 0, Max(0, Mdl.SkinCount - 1));
  if (V.Transform = nil) or (V.Model <> Model) or (V.Skin <> SkinIdx) or (V.Colors <> Colors) then
  begin
    FreeVisual(V);
    V.Transform := TCastleTransform.Create(nil);
    V.Transform.Name := ComponentName(FNamePrefix);
    V.Scene := Mdl.CreateScene(SkinIdx, Colors);
    V.Scene.Name := V.Transform.Name + '_scene';
    V.Scene.Collides := False;
    V.Transform.Add(V.Scene);
    FItems.Add(V.Transform);
    V.Mdl := Mdl;
    V.Model := Model;
    V.Skin := SkinIdx;
    V.Colors := Colors;
    V.Frame := -1;
    V.TrailTimer := 0;
    V.TrailValid := False;
  end;
  V.Transform.Exists := True;
  UpdatePose(V, Mdl, Frame, Time);

  Pos := QuakeToCge(Origin);
  V.Transform.Translation := Pos;
  Yaw := Angles.Y;
  if (Mdl.Flags and MF_ROTATE) <> 0 then
    Yaw := FloatModulo(Time * 100, 360); { items spin }
  { R_RotateForEntity: yaw, then pitch, then roll }
  Q := QuatFromAxisAngle(Vector3(0, 1, 0), DegToRad(Yaw)) *
    QuatFromAxisAngle(Vector3(0, 0, 1), DegToRad(Angles.X)) *
    QuatFromAxisAngle(Vector3(1, 0, 0), DegToRad(Angles.Z));
  V.Transform.Rotation := Q.ToAxisAngle;

  if (Effects and EF_MUZZLEFLASH) <> 0 then
    Lighting.TriggerMuzzleFlash(Pos + Vector3(0, 16, 0), 2.5)
  else if (Effects and (EF_BRIGHTLIGHT or EF_DIMLIGHT)) <> 0 then
    Lighting.TriggerMuzzleFlash(Pos + Vector3(0, 16, 0), 2.0);

  if (Mdl.Flags and TrailFlags) <> 0 then
    ModelTrail(V, Mdl.Flags, Origin, Pos, Dt);
end;

procedure TEntityRenderer.ModelTrail(var V: TEntityVisual; const Flags: Integer; const Origin, Pos: TVector3;
  const Dt: Single);
begin
  { A mod's effectinfo.txt trail (DP's TR_ROCKET...) from where the entity
    was the last frame, else R_RocketTrail's puffs }
  if V.TrailValid and EffectTrail(Flags, V.TrailFrom, Origin) then
  begin
    V.TrailFrom := Origin;
    if (Flags and MF_ROCKET) <> 0 then
      Lighting.TriggerMuzzleFlash(Pos, 2.0);
    Exit;
  end;
  V.TrailFrom := Origin;
  V.TrailValid := True;
  V.TrailTimer := V.TrailTimer - Dt;
  if V.TrailTimer > 0 then
    Exit;
  V.TrailTimer := 0.04;
  if (Flags and MF_ROCKET) <> 0 then
  begin
    Particles.SpawnRocketTrail(Pos);
    Lighting.TriggerMuzzleFlash(Pos, 2.0);
  end else
  if (Flags and MF_GRENADE) <> 0 then
    Particles.SpawnGrenadeTrail(Pos)
  else if (Flags and (MF_GIB or MF_ZOMGIB)) <> 0 then
    Particles.SpawnBloodTrail(Pos)
  else if (Flags and MF_TRACER) <> 0 then
    Particles.SpawnTrail(Pos, Vector3(0.3, 0.9, 0.2))
  else if (Flags and MF_TRACER2) <> 0 then
    Particles.SpawnTrail(Pos, Vector3(1.0, 0.55, 0.15))
  else
    Particles.SpawnTrail(Pos, Vector3(0.7, 0.3, 0.9));
end;

procedure TEntityRenderer.LerpMove(var V: TEntityVisual; const Origin, Angles: TVector3; const Step: Boolean;
  const Time: Single; out DrawOrigin, DrawAngles: TVector3);

  function Blend(const T: Single): TVector3;
  var
    I: Integer;
    D: Single;
  begin
    for I := 0 to 2 do
    begin
      { The angles turn the short way round }
      D := V.AngTo[I] - V.AngFrom[I];
      D := D - 360 * Round(D / 360);
      Result.Data[I] := V.AngFrom[I] + D * T;
    end;
  end;

var
  T: Single;
begin
  { R_LerpMove: a walking monster's moves of a think (0.1 s) are drawn
    as a glide from where it was drawn to its new place }
  T := 1;
  if V.MoveValid then
    T := EnsureRange((Time - V.MoveStart) / ModelLerpTime, 0, 1);
  if not V.MoveValid or not MoveLerp or not Step then
  begin
    V.MoveFrom := Origin;
    V.AngFrom := Angles;
    V.MoveTo := Origin;
    V.AngTo := Angles;
    V.MoveStart := Time;
    V.MoveValid := True;
  end else
  if not TVector3.PerfectlyEquals(Origin, V.MoveTo) or not TVector3.PerfectlyEquals(Angles, V.AngTo) then
  begin
    if (Origin - V.MoveTo).Length > 100 then
    begin
      { A teleport or a respawn: no glide }
      V.MoveFrom := Origin;
      V.AngFrom := Angles;
    end else
    begin
      V.MoveFrom := V.MoveFrom + (V.MoveTo - V.MoveFrom) * T;
      V.AngFrom := Blend(T);
    end;
    V.MoveTo := Origin;
    V.AngTo := Angles;
    V.MoveStart := Time;
  end;
  T := EnsureRange((Time - V.MoveStart) / ModelLerpTime, 0, 1);
  DrawOrigin := V.MoveFrom + (V.MoveTo - V.MoveFrom) * T;
  DrawAngles := Blend(T);
end;

{ Temp entities and beams }

procedure TEntityRenderer.TempEntity(const Kind: Integer; const Pos, Pos2: TVector3);
var
  P: TVector3;
  Own: Boolean;
begin
  P := QuakeToCge(Pos);
  { A mod's effectinfo.txt effect of this name replaces the particles
    (the sounds and lights stay) }
  Own := EffectByName(TempEntityEffectName(Kind), Pos);
  case Kind of
    TE_SPIKE, TE_SUPERSPIKE, TE_GUNSHOT:
      begin
        if not Own then
          Particles.SpawnPuff(P, Vector3(0, 1, 0));
        if Kind <> TE_GUNSHOT then
        begin
          if Random(5) = 0 then
            Sounds.Play('sound/weapons/tink1.wav')
          else
          case Random(3) of
            0: Sounds.Play('sound/weapons/ric1.wav');
            1: Sounds.Play('sound/weapons/ric2.wav');
            else Sounds.Play('sound/weapons/ric3.wav');
          end;
        end;
      end;
    TE_WIZSPIKE:
      begin
        if not Own then
          Particles.SpawnTrail(P, Vector3(0.3, 0.9, 0.2));
        Sounds.Play('sound/wizard/hit.wav');
      end;
    TE_KNIGHTSPIKE:
      begin
        if not Own then
          Particles.SpawnTrail(P, Vector3(1.0, 0.55, 0.15));
        Sounds.Play('sound/hknight/hit.wav');
      end;
    TE_EXPLOSION, TE_EXPLOSION2, TE_TAREXPLOSION:
      begin
        if not Own then
          Particles.SpawnExplosion(P);
        Lighting.TriggerMuzzleFlash(P, 6.0);
        Sounds.Play('sound/weapons/r_exp3.wav');
      end;
    TE_LAVASPLASH:
      if not Own then
        Particles.SpawnLavaSplash(P);
    TE_TELEPORT:
      if not Own then
        Particles.SpawnTeleport(P);
    TE_LIGHTNING1, TE_LIGHTNING2, TE_LIGHTNING3, TE_BEAM:
      begin
        if Kind = TE_BEAM then
          ShowBeam(0, Pos, Pos2, 0.2)
        else
          ShowBeam(Kind - TE_LIGHTNING1, Pos, Pos2, 0.2);
        Lighting.TriggerMuzzleFlash(P, 3.0);
      end;
  end;
end;

procedure TEntityRenderer.ShowBeam(const Pool: Integer; const StartQ, StopQ: TVector3; const Duration: Single);
const
  SegmentLength = 30.0;
var
  Mdl: TQuakeMdl;
  Delta, Dir: TVector3;
  Dist, Yaw, Pitch: Single;
  Count, I: Integer;
  Q: TQuaternion;
  Seg: TCastleTransform;
  Scene: TCastleScene;
begin
  Delta := StopQ - StartQ;
  Dist := Delta.Length;
  if Dist < 1 then
    Exit;
  Dir := Delta / Dist;
  Count := Min(Ceil(Dist / SegmentLength), 40);
  while Length(FBeams[Pool].Segments) < Count do
  begin
    Mdl := MdlManager.GetModel(BeamModels[Pool]);
    if Mdl = nil then
      Break;
    Seg := TCastleTransform.Create(nil);
    Seg.Name := ComponentName('beam_segment');
    Scene := Mdl.CreateScene(0);
    Scene.Collides := False;
    Seg.Add(Scene);
    FItems.Add(Seg);
    SetLength(FBeams[Pool].Segments, Length(FBeams[Pool].Segments) + 1);
    FBeams[Pool].Segments[High(FBeams[Pool].Segments)] := Seg;
  end;
  Yaw := ArcTan2(Dir.Y, Dir.X);
  Pitch := ArcTan2(Dir.Z, Sqrt(Sqr(Dir.X) + Sqr(Dir.Y)));
  for I := 0 to High(FBeams[Pool].Segments) do
  begin
    Seg := FBeams[Pool].Segments[I];
    Seg.Exists := I < Count;
    if not Seg.Exists then
      Continue;
    Q := QuatFromAxisAngle(Vector3(0, 1, 0), Yaw) * QuatFromAxisAngle(Vector3(0, 0, 1), Pitch) *
      QuatFromAxisAngle(Vector3(1, 0, 0), Random * 2 * Pi);
    Seg.Rotation := Q.ToAxisAngle;
    Seg.Translation := QuakeToCge(StartQ + Dir * (I * SegmentLength));
  end;
  FBeams[Pool].Time := Duration;
end;

procedure TEntityRenderer.UpdateBeams(const Dt: Single);
var
  I, J: Integer;
begin
  for I := 0 to High(FBeams) do
    if FBeams[I].Time > 0 then
    begin
      FBeams[I].Time := FBeams[I].Time - Dt;
      if FBeams[I].Time <= 0 then
        for J := 0 to High(FBeams[I].Segments) do
          FBeams[I].Segments[J].Exists := False;
    end;
end;

procedure TEntityRenderer.ClearBeams;
var
  I, J: Integer;
begin
  for I := 0 to High(FBeams) do
  begin
    for J := 0 to High(FBeams[I].Segments) do
    begin
      if FBeams[I].Segments[J].Parent <> nil then
        FBeams[I].Segments[J].Parent.Remove(FBeams[I].Segments[J]);
      FBeams[I].Segments[J].Free;
    end;
    SetLength(FBeams[I].Segments, 0);
    FBeams[I].Time := 0;
  end;
end;

{ effectinfo.txt }

function TEntityRenderer.EffectByName(const AName: String; const QuakePos: TVector3): Boolean;
var
  Num: Integer;
begin
  Result := False;
  if (AName = '') or (EffectParticles = nil) or not ModEffects then
    Exit;
  Num := EffectParticles.Info.EffectNum(AName);
  if (Num = 0) or (EffectParticles.Info.SectionCount(Num) = 0) then
    Exit;
  EffectParticles.Spawn(Num, QuakePos, TVector3.Zero, 1);
  Result := True;
end;

function TEntityRenderer.EffectTrail(const Flags: Integer; const FromPos, ToPos: TVector3): Boolean;
var
  AName: String;
  Num: Integer;
begin
  Result := False;
  if (EffectParticles = nil) or not ModEffects then
    Exit;
  if (Flags and MF_ROCKET) <> 0 then
    AName := 'TR_ROCKET'
  else if (Flags and MF_GRENADE) <> 0 then
    AName := 'TR_GRENADE'
  else if (Flags and MF_GIB) <> 0 then
    AName := 'TR_BLOOD'
  else if (Flags and MF_ZOMGIB) <> 0 then
    AName := 'TR_SLIGHTBLOOD'
  else if (Flags and MF_TRACER) <> 0 then
    AName := 'TR_WIZSPIKE'
  else if (Flags and MF_TRACER2) <> 0 then
    AName := 'TR_KNIGHTSPIKE'
  else
    AName := 'TR_VORESPIKE';
  Num := EffectParticles.Info.EffectNum(AName);
  if (Num = 0) or (EffectParticles.Info.SectionCount(Num) = 0) then
    Exit;
  if not TVector3.PerfectlyEquals(FromPos, ToPos) then
    EffectParticles.Trail(Num, FromPos, ToPos);
  Result := True;
end;

end.
