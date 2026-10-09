{ Plays Quake .dem recordings: the map named by the demo is loaded, the
  entities of every server frame are shown with their models, and sounds,
  effects, lightstyles, centerprints and the status bar follow the
  recorded messages. }
unit GameViewDemo;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math,
  CastleVectors, CastleUIControls, CastleKeysMouse, CastleViewport, CastleTransform,
  CastleScene, CastleLog, CastleImages, CastleQuaternions, CastleWindow, CastleUtils,
  QuakePak, QuakeBsp, QuakeGeometry, QuakeLight, QuakeSound, QuakeHud, QuakeParticles,
  QuakeMdl, QuakeAmbient, QuakePalette, QuakeDemo;

type
  TDemoVisual = record
    Transform: TCastleTransform;
    Scene: TCastleScene;
    Mdl: TQuakeMdl;
    ModelIndex, Frame, Skin: Integer;
    TrailTimer: Single;
  end;

  TViewDemo = class(TCastleView)
  private
    FViewport: TCastleViewport;
    FDemo: TQuakeDemoReader;
    FBsp: TQuakeBsp;
    FGeometry: TQuakeGeometry;
    FAmbient: TQuakeAmbientSounds;
    FHud: TQuakeHud;
    FVisuals: array of TDemoVisual;
    FStaticVisuals: array of TDemoVisual;
    FSubmodels: array of TQuakeSubmodel;  { by BSP model index }
    FSubmodelUsed: array of Boolean;
    FWeaponTransform: TCastleTransform;
    FWeapon: TDemoVisual;
    FSoundPool: array[0..31] of TCastleTransform;
    FSoundPoolNext: Integer;
    FBeams: array[0..2] of record
      Segments: array of TCastleTransform;
      Time: Single;
    end;
    FLevelStart: Single;
    FFinishedTimer: Single;
    FLoaded: Boolean;
    { Autotest: W:sec, S (screenshot), Q }
    FScript: TStringList;
    FScriptIndex: Integer;
    FScriptTimer: Single;
    FShots: Integer;
    procedure ClearLevel;
    procedure LoadLevel;
    procedure HandleServerInfo;
    procedure HandleSound(const Entity, Channel, SoundIndex: Integer; const Volume, Attenuation: Single;
      const Origin: TVector3);
    procedure HandleTempEntity(const Kind: Integer; const Pos, Pos2: TVector3;
      const Entity, ColorStart, ColorLength: Integer);
    procedure HandleParticle(const Org, Dir: TVector3; const Count, Color: Integer);
    procedure HandlePrint(const S: String);
    procedure HandleCenterPrint(const S: String);
    procedure HandleFinale(const S: String);
    procedure HandleDamage(const Armor, Blood: Integer; const From: TVector3);
    procedure HandleLightStyle(const Index: Integer; const Pattern: String);
    procedure HandleIntermission;
    procedure ShowVisual(var V: TDemoVisual; const State: TDemoEntityState; const Dt: Single);
    procedure HideVisual(var V: TDemoVisual);
    procedure FreeVisual(var V: TDemoVisual);
    procedure ShowBeam(const Pool: Integer; const StartQ, StopQ: TVector3; const Duration: Single);
    procedure UpdateWeapon;
    procedure UpdateHudStats(const SecondsPassed: Single);
    procedure RunScript(const SecondsPassed: Single);
    procedure CaptureScreenshot;
    procedure Leave;
  public
    { PAK name ('demo1.dem') or URL of the demo to play }
    DemoName: String;
    { Headless testing: screenshots go to Prefix_N.png, Script like the
      play view's --demo (W, S and Q) }
    AutoTestPrefix, AutoTestScript: String;

    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Start; override;
    procedure Stop; override;
    procedure Update(const SecondsPassed: Single; var HandleInput: Boolean); override;
    function Press(const Event: TInputPressRelease): Boolean; override;
  end;

var
  ViewDemo: TViewDemo;

implementation

uses
  GameViewMenu;

const
  BeamModels: array[0..2] of String = ('progs/bolt.mdl', 'progs/bolt2.mdl', 'progs/bolt3.mdl');

constructor TViewDemo.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FDemo := TQuakeDemoReader.Create;
  FDemo.OnServerInfo := @HandleServerInfo;
  FDemo.OnSound := @HandleSound;
  FDemo.OnTempEntity := @HandleTempEntity;
  FDemo.OnParticle := @HandleParticle;
  FDemo.OnPrint := @HandlePrint;
  FDemo.OnCenterPrint := @HandleCenterPrint;
  FDemo.OnFinale := @HandleFinale;
  FDemo.OnDamage := @HandleDamage;
  FDemo.OnLightStyle := @HandleLightStyle;
  FDemo.OnIntermission := @HandleIntermission;
  FAmbient := TQuakeAmbientSounds.Create;
  FScript := TStringList.Create;
  SetLength(FVisuals, MaxDemoEntities);
end;

destructor TViewDemo.Destroy;
begin
  ClearLevel;
  FDemo.Free;
  FAmbient.Free;
  FScript.Free;
  inherited Destroy;
end;

procedure TViewDemo.Start;
var
  I: Integer;
  Cmd: String;
begin
  inherited Start;

  if FViewport = nil then
  begin
    FViewport := TCastleViewport.Create(Self);
    FViewport.FullSize := True;
    FViewport.Transparent := False;
    FViewport.BackgroundColor := Vector4(0.02, 0.02, 0.03, 1.0);
    FViewport.Camera.ProjectionNear := 1.0;
    FViewport.Camera.Perspective.FieldOfViewAxis := faHorizontal;
    FViewport.Camera.Perspective.FieldOfView := DegToRad(90.0);
    InsertFront(FViewport);

    FWeaponTransform := TCastleTransform.Create(Self);
    FWeaponTransform.Rotation := Vector4(0, 1, 0, Pi / 2);
    FViewport.Camera.Add(FWeaponTransform);

    for I := 0 to High(FSoundPool) do
    begin
      FSoundPool[I] := TCastleTransform.Create(Self);
      FViewport.Items.Add(FSoundPool[I]);
    end;
  end;

  if FHud = nil then
  begin
    FHud := TQuakeHud.Create(Self);
    FHud.CrosshairVisible := False;
    InsertFront(FHud);
  end;
  FHud.StopIntermission;
  Particles.SetParent(FViewport.Items);

  FScript.Clear;
  FScriptIndex := 0;
  FScriptTimer := 0;
  FShots := 0;
  for Cmd in AutoTestScript.Split([',']) do
    if Trim(Cmd) <> '' then
      FScript.Add(Trim(Cmd));

  FFinishedTimer := 0;
  FLoaded := False;
  ClearLevel;
  if not FDemo.Load(DemoName) then
  begin
    FHud.ShowMessage('Cannot play demo ' + DemoName, 3);
    FDemo.Finished := True;
  end;
end;

procedure TViewDemo.Stop;
begin
  ClearLevel;
  if Sounds <> nil then
    Sounds.StopMusic;
  if Lighting <> nil then
    Lighting.ResetStyles;
  inherited Stop;
end;

procedure TViewDemo.FreeVisual(var V: TDemoVisual);
begin
  if V.Transform <> nil then
  begin
    if V.Transform.Parent <> nil then
      V.Transform.Parent.Remove(V.Transform);
    FreeAndNil(V.Transform); { owns the scene }
  end;
  V.Scene := nil;
  V.Mdl := nil;
  V.ModelIndex := 0;
  V.Frame := -1;
end;

procedure TViewDemo.HideVisual(var V: TDemoVisual);
begin
  if V.Transform <> nil then
    V.Transform.Exists := False;
end;

procedure TViewDemo.ClearLevel;
var
  I: Integer;
begin
  for I := 0 to High(FVisuals) do
    FreeVisual(FVisuals[I]);
  for I := 0 to High(FStaticVisuals) do
    FreeVisual(FStaticVisuals[I]);
  SetLength(FStaticVisuals, 0);
  FreeVisual(FWeapon);
  for I := 0 to High(FBeams) do
  begin
    FBeams[I].Time := 0;
    SetLength(FBeams[I].Segments, 0);
  end;
  SetLength(FSubmodels, 0);
  SetLength(FSubmodelUsed, 0);
  { At program exit the managers may be gone already }
  if (FAmbient <> nil) and (Sounds <> nil) then
    FAmbient.Clear;
  if Particles <> nil then
    Particles.Clear;
  if Lighting <> nil then
    Lighting.Clear;
  FreeAndNil(FGeometry);
  FreeAndNil(FBsp);
  FLoaded := False;
end;

procedure TViewDemo.LoadLevel;
var
  Sub: TQuakeSubmodel;
begin
  ClearLevel;
  FBsp := TQuakeBsp.Create;
  if not FBsp.LoadFromPak(FDemo.ModelName(1)) then
  begin
    WritelnWarning('GameViewDemo', 'Cannot load the demo map "%s"', [FDemo.ModelName(1)]);
    FreeAndNil(FBsp);
    FDemo.Finished := True;
    Exit;
  end;
  FGeometry := TQuakeGeometry.Create(FBsp);
  FGeometry.AddToWorld(FViewport.Items);
  Lighting.CreateLightsFromBsp(FBsp, FViewport.Items);
  Lighting.ResetStyles;
  FAmbient.Setup(FBsp, FViewport.Items);

  { Brush entities are placed by the demo; hidden until it does }
  SetLength(FSubmodels, FBsp.ModelCount);
  SetLength(FSubmodelUsed, FBsp.ModelCount);
  for Sub in FGeometry.Submodels do
  begin
    if (Sub.ModelIndex > 0) and (Sub.ModelIndex < Length(FSubmodels)) then
      FSubmodels[Sub.ModelIndex] := Sub;
    Sub.Transform.Exists := False;
  end;
  FLevelStart := -1;
  FLoaded := True;
  Sounds.PlayMusic('track02.ogg');
  FHud.StopIntermission;
  FHud.ShowMessage(FDemo.LevelName, 3);
end;

procedure TViewDemo.HandleServerInfo;
begin
  LoadLevel;
end;

procedure TViewDemo.HandleSound(const Entity, Channel, SoundIndex: Integer;
  const Volume, Attenuation: Single; const Origin: TVector3);
var
  Path: String;
  T: TCastleTransform;
begin
  Path := FDemo.SoundName(SoundIndex);
  if Path = '' then
    Exit;
  if (Attenuation = 0) or (Entity = FDemo.ViewEntity) then
    Sounds.Play(Path, Volume)
  else
  begin
    T := FSoundPool[FSoundPoolNext];
    FSoundPoolNext := (FSoundPoolNext + 1) mod Length(FSoundPool);
    T.Translation := QuakeToCge(Origin);
    Sounds.PlayAt(Path, T, Volume);
  end;
end;

procedure TViewDemo.ShowBeam(const Pool: Integer; const StartQ, StopQ: TVector3; const Duration: Single);
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
    Seg := TCastleTransform.Create(Self);
    Scene := Mdl.CreateScene(0);
    Scene.Collides := False;
    Seg.Add(Scene);
    FViewport.Items.Add(Seg);
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

procedure TViewDemo.HandleTempEntity(const Kind: Integer; const Pos, Pos2: TVector3;
  const Entity, ColorStart, ColorLength: Integer);
var
  P: TVector3;
begin
  { CL_ParseTEnt }
  P := QuakeToCge(Pos);
  case Kind of
    TE_SPIKE, TE_SUPERSPIKE, TE_GUNSHOT:
      begin
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
        Particles.SpawnTrail(P, Vector3(0.3, 0.9, 0.2));
        Sounds.Play('sound/wizard/hit.wav');
      end;
    TE_KNIGHTSPIKE:
      begin
        Particles.SpawnTrail(P, Vector3(1.0, 0.55, 0.15));
        Sounds.Play('sound/hknight/hit.wav');
      end;
    TE_EXPLOSION, TE_EXPLOSION2:
      begin
        Particles.SpawnExplosion(P);
        Lighting.TriggerMuzzleFlash(P, 6.0);
        Sounds.Play('sound/weapons/r_exp3.wav');
      end;
    TE_TAREXPLOSION, TE_LAVASPLASH:
      begin
        Particles.SpawnExplosion(P);
        Lighting.TriggerMuzzleFlash(P, 6.0);
        if Kind = TE_TAREXPLOSION then
          Sounds.Play('sound/weapons/r_exp3.wav');
      end;
    TE_TELEPORT:
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

procedure TViewDemo.HandleParticle(const Org, Dir: TVector3; const Count, Color: Integer);
var
  C: TVector4Byte;
begin
  if Count = 255 then
  begin
    Particles.SpawnExplosion(QuakeToCge(Org));
    Exit;
  end;
  { Blood is palette 64..79; anything else as a colored burst }
  if (Color >= 64) and (Color <= 79) then
    Particles.SpawnBlood(QuakeToCge(Org), QuakeToCge(Dir))
  else
  begin
    C := Palette.Color(Color and 255);
    Particles.SpawnTrail(QuakeToCge(Org), Vector3(C.X / 255, C.Y / 255, C.Z / 255));
  end;
end;

procedure TViewDemo.HandlePrint(const S: String);
begin
  WritelnLog('Demo', Trim(S));
end;

procedure TViewDemo.HandleCenterPrint(const S: String);
begin
  FHud.ShowMessage(S, 2.5);
end;

procedure TViewDemo.HandleFinale(const S: String);
begin
  FHud.StopIntermission;
  FHud.ShowMessage(S, 120);
end;

procedure TViewDemo.HandleDamage(const Armor, Blood: Integer; const From: TVector3);
begin
  FHud.DamageFlash(Armor, Blood);
end;

procedure TViewDemo.HandleLightStyle(const Index: Integer; const Pattern: String);
begin
  Lighting.SetStyle(Index, Pattern);
end;

procedure TViewDemo.HandleIntermission;
begin
  FHud.StartIntermission(FDemo.LevelName, Math.Max(0.0, FDemo.Time - FLevelStart),
    FDemo.Stats[STAT_MONSTERS], FDemo.Stats[STAT_TOTALMONSTERS],
    FDemo.Stats[STAT_SECRETS], FDemo.Stats[STAT_TOTALSECRETS]);
  Sounds.PlayMusic('track03.ogg');
end;

procedure TViewDemo.ShowVisual(var V: TDemoVisual; const State: TDemoEntityState; const Dt: Single);
var
  MdlName: String;
  Q: TQuaternion;
  Yaw: Single;
  Pos: TVector3;
  Mdl: TQuakeMdl;
  Skin: Integer;
begin
  MdlName := FDemo.ModelName(State.ModelIndex);
  if MdlName = '' then
  begin
    HideVisual(V);
    Exit;
  end;

  { Brush models (doors, plats) are the map's own submodels }
  if MdlName[1] = '*' then
  begin
    HideVisual(V);
    Skin := StrToIntDef(Copy(MdlName, 2, MaxInt), -1);
    if (Skin > 0) and (Skin < Length(FSubmodels)) and (FSubmodels[Skin] <> nil) then
    begin
      FSubmodels[Skin].Transform.Exists := True;
      FSubmodels[Skin].Transform.Translation := QuakeToCge(State.Origin);
      FSubmodelUsed[Skin] := True;
    end;
    Exit;
  end;

  if LowerCase(ExtractFileExt(MdlName)) <> '.mdl' then
  begin
    { Sprites and bsp item boxes are not drawn }
    HideVisual(V);
    Exit;
  end;

  Mdl := MdlManager.GetModel(MdlName);
  if Mdl = nil then
  begin
    HideVisual(V);
    Exit;
  end;
  Skin := EnsureRange(State.Skin, 0, Max(0, Mdl.SkinCount - 1));
  if (V.Transform = nil) or (V.ModelIndex <> State.ModelIndex) or (V.Skin <> Skin) then
  begin
    FreeVisual(V);
    V.Transform := TCastleTransform.Create(nil);
    V.Scene := Mdl.CreateScene(Skin);
    V.Scene.Collides := False;
    V.Transform.Add(V.Scene);
    FViewport.Items.Add(V.Transform);
    V.Mdl := Mdl;
    V.ModelIndex := State.ModelIndex;
    V.Skin := Skin;
    V.Frame := -1;
    V.TrailTimer := 0;
  end;
  V.Transform.Exists := True;
  if V.Frame <> State.Frame then
  begin
    V.Frame := State.Frame;
    Mdl.ApplyFrame(V.Scene, EnsureRange(State.Frame, 0, Max(0, Mdl.FrameCount - 1)));
  end;

  Pos := QuakeToCge(State.Origin);
  V.Transform.Translation := Pos;
  Yaw := State.Angles.Y;
  if (Mdl.Flags and MF_ROTATE) <> 0 then
    Yaw := FloatModulo(FDemo.Time * 100, 360); { items spin }
  { R_RotateForEntity: yaw, then pitch, then roll }
  Q := QuatFromAxisAngle(Vector3(0, 1, 0), DegToRad(Yaw)) *
    QuatFromAxisAngle(Vector3(0, 0, 1), DegToRad(State.Angles.X)) *
    QuatFromAxisAngle(Vector3(1, 0, 0), DegToRad(State.Angles.Z));
  V.Transform.Rotation := Q.ToAxisAngle;

  if (State.Effects and EF_MUZZLEFLASH) <> 0 then
    Lighting.TriggerMuzzleFlash(Pos + Vector3(0, 16, 0), 2.5)
  else if (State.Effects and (EF_BRIGHTLIGHT or EF_DIMLIGHT)) <> 0 then
    Lighting.TriggerMuzzleFlash(Pos + Vector3(0, 16, 0), 2.0);

  { Trails from the model flags (R_RocketTrail) }
  if (Mdl.Flags and (MF_ROCKET or MF_GRENADE or MF_GIB or MF_ZOMGIB or MF_TRACER or MF_TRACER2 or MF_TRACER3)) <> 0 then
  begin
    V.TrailTimer := V.TrailTimer - Dt;
    if V.TrailTimer <= 0 then
    begin
      V.TrailTimer := 0.04;
      if (Mdl.Flags and MF_ROCKET) <> 0 then
      begin
        Particles.SpawnRocketTrail(Pos);
        Lighting.TriggerMuzzleFlash(Pos, 2.0);
      end else
      if (Mdl.Flags and MF_GRENADE) <> 0 then
        Particles.SpawnGrenadeTrail(Pos)
      else if (Mdl.Flags and (MF_GIB or MF_ZOMGIB)) <> 0 then
        Particles.SpawnBloodTrail(Pos)
      else if (Mdl.Flags and MF_TRACER) <> 0 then
        Particles.SpawnTrail(Pos, Vector3(0.3, 0.9, 0.2))
      else if (Mdl.Flags and MF_TRACER2) <> 0 then
        Particles.SpawnTrail(Pos, Vector3(1.0, 0.55, 0.15))
      else
        Particles.SpawnTrail(Pos, Vector3(0.7, 0.3, 0.9));
    end;
  end;
end;

procedure TViewDemo.UpdateWeapon;
var
  MdlName: String;
  Mdl: TQuakeMdl;
  Idx: Integer;
begin
  Idx := FDemo.ClientData.Weapon;
  MdlName := FDemo.ModelName(Idx);
  if (MdlName = '') or (FDemo.Intermission <> 0) or (FDemo.ClientData.Health <= 0) then
  begin
    HideVisual(FWeapon);
    Exit;
  end;
  Mdl := MdlManager.GetModel(MdlName);
  if Mdl = nil then
  begin
    HideVisual(FWeapon);
    Exit;
  end;
  if (FWeapon.Transform = nil) or (FWeapon.ModelIndex <> Idx) then
  begin
    FreeVisual(FWeapon);
    FWeapon.Transform := TCastleTransform.Create(nil);
    FWeapon.Scene := Mdl.CreateScene(0);
    FWeapon.Scene.Collides := False;
    FWeapon.Transform.Add(FWeapon.Scene);
    FWeaponTransform.Add(FWeapon.Transform);
    FWeapon.Mdl := Mdl;
    FWeapon.ModelIndex := Idx;
    FWeapon.Frame := -1;
  end;
  FWeapon.Transform.Exists := True;
  if FWeapon.Frame <> FDemo.ClientData.WeaponFrame then
  begin
    FWeapon.Frame := FDemo.ClientData.WeaponFrame;
    Mdl.ApplyFrame(FWeapon.Scene, EnsureRange(FWeapon.Frame, 0, Max(0, Mdl.FrameCount - 1)));
  end;
end;

procedure TViewDemo.UpdateHudStats(const SecondsPassed: Single);
var
  S: TQuakePlayerStats;
  Items: Cardinal;
  I: Integer;
const
  WeaponItems: array[1..8] of Cardinal = (IT_AXE, IT_SHOTGUN, IT_SUPER_SHOTGUN, IT_NAILGUN,
    IT_SUPER_NAILGUN, IT_GRENADE_LAUNCHER, IT_ROCKET_LAUNCHER, IT_LIGHTNING);
begin
  S := Default(TQuakePlayerStats);
  Items := FDemo.ClientData.Items;
  S.Health := FDemo.ClientData.Health;
  S.Armor := FDemo.ClientData.Armor;
  if (Items and IT_ARMOR3) <> 0 then
    S.ArmorType := 3
  else if (Items and IT_ARMOR2) <> 0 then
    S.ArmorType := 2
  else if (Items and IT_ARMOR1) <> 0 then
    S.ArmorType := 1;
  S.Ammo := FDemo.ClientData.Ammo;
  S.Shells := FDemo.ClientData.Shells;
  S.Nails := FDemo.ClientData.Nails;
  S.Rockets := FDemo.ClientData.Rockets;
  S.Cells := FDemo.ClientData.Cells;
  S.MaxShells := 100;
  S.MaxNails := 200;
  S.MaxRockets := 100;
  S.MaxCells := 100;
  for I := 1 to 8 do
  begin
    if (Items and WeaponItems[I]) <> 0 then
      S.WeaponMask := S.WeaponMask or (1 shl I);
    if Cardinal(FDemo.ClientData.ActiveWeapon) = WeaponItems[I] then
      S.CurrentWeapon := I;
  end;
  if (Items and IT_KEY1) <> 0 then
    S.Keys := S.Keys or 1;
  if (Items and IT_KEY2) <> 0 then
    S.Keys := S.Keys or 2;
  if (Items and IT_SUIT) <> 0 then
    S.BiosuitTime := 1;
  S.Kills := FDemo.Stats[STAT_MONSTERS];
  S.TotalKills := FDemo.Stats[STAT_TOTALMONSTERS];
  S.Secrets := FDemo.Stats[STAT_SECRETS];
  S.TotalSecrets := FDemo.Stats[STAT_TOTALSECRETS];
  S.LevelTime := Math.Max(0.0, FDemo.Time - FLevelStart);
  S.AirLeft := 12;
  if FBsp <> nil then
  begin
    I := FBsp.PointContentsCge(FViewport.Camera.Translation);
    FHud.SetContents(I);
    S.Underwater := (I = CONTENTS_WATER) or (I = CONTENTS_SLIME) or (I = CONTENTS_LAVA);
  end;
  FHud.Update(SecondsPassed, S);
end;

procedure TViewDemo.CaptureScreenshot;
var
  OutPath: String;
  Img: TCastleImage;
begin
  Inc(FShots);
  OutPath := AutoTestPrefix + '_' + IntToStr(FShots) + '.png';
  try
    Img := Container.SaveScreen;
    if Img <> nil then
    begin
      SaveImage(Img, OutPath);
      Img.Free;
      WritelnLog('GameViewDemo', 'Saved screenshot to "%s"', [OutPath]);
    end;
  except
    on E: Exception do
      WritelnWarning('GameViewDemo', 'Failed to save screenshot "%s": %s', [OutPath, E.Message]);
  end;
end;

procedure TViewDemo.RunScript(const SecondsPassed: Single);
var
  Cmd, Action, Param: String;
  P: Integer;
begin
  while FScriptIndex < FScript.Count do
  begin
    Cmd := FScript[FScriptIndex];
    P := Pos(':', Cmd);
    if P > 0 then
    begin
      Action := UpperCase(Copy(Cmd, 1, P - 1));
      Param := Copy(Cmd, P + 1, MaxInt);
    end else
    begin
      Action := UpperCase(Cmd);
      Param := '';
    end;
    if Action = 'W' then
    begin
      FScriptTimer := FScriptTimer + SecondsPassed;
      if FScriptTimer < StrToFloatDef(Param, 1.0) then
        Exit;
      FScriptTimer := 0;
    end else
    if Action = 'S' then
      CaptureScreenshot
    else
    if Action = 'Q' then
    begin
      Application.Terminate;
      Exit;
    end;
    Inc(FScriptIndex);
  end;
end;

procedure TViewDemo.Leave;
begin
  if AutoTestPrefix <> '' then
    Application.Terminate
  else
    Container.View := ViewMenu;
end;

procedure TViewDemo.Update(const SecondsPassed: Single; var HandleInput: Boolean);
var
  I, J: Integer;
  Eye, Dir: TVector3;
  Pitch, Yaw: Single;
  CD: TDemoClientData;
begin
  inherited Update(SecondsPassed, HandleInput);

  if FScript.Count > 0 then
    RunScript(SecondsPassed);

  if FDemo.Finished then
  begin
    FFinishedTimer := FFinishedTimer + SecondsPassed;
    if (FFinishedTimer > 1.5) and (FScript.Count = 0) then
      Leave;
    Exit;
  end;

  FDemo.Advance(SecondsPassed);
  if not FLoaded then
    Exit;
  if (FLevelStart < 0) and (FDemo.Signon = Signons) then
    FLevelStart := FDemo.Time;

  { Entities of this server frame }
  for I := 0 to High(FSubmodelUsed) do
    FSubmodelUsed[I] := False;
  for I := 1 to High(FVisuals) do
    if FDemo.EntityVisible(I) and (I <> FDemo.ViewEntity) then
      ShowVisual(FVisuals[I], FDemo.Entities[I].State, SecondsPassed)
    else
      HideVisual(FVisuals[I]);
  for I := 1 to High(FSubmodels) do
    if (FSubmodels[I] <> nil) and not FSubmodelUsed[I] then
      FSubmodels[I].Transform.Exists := False;

  { Static entities (torches, decorations) }
  if Length(FStaticVisuals) < Length(FDemo.Statics) then
    SetLength(FStaticVisuals, Length(FDemo.Statics));
  for I := 0 to High(FDemo.Statics) do
    ShowVisual(FStaticVisuals[I], FDemo.Statics[I], SecondsPassed);

  { The view: the view entity's eyes, looking along the recorded angles }
  CD := FDemo.ClientData;
  if (FDemo.ViewEntity > 0) and (FDemo.ViewEntity < Length(FDemo.Entities)) then
    Eye := FDemo.Entities[FDemo.ViewEntity].State.Origin + Vector3(0, 0, CD.ViewHeight)
  else
    Eye := TVector3.Zero;
  Pitch := EnsureRange(FDemo.ViewAngles.X + CD.Punch.X, -89, 89);
  Yaw := FDemo.ViewAngles.Y;
  Dir := Vector3(Cos(DegToRad(Yaw)) * Cos(DegToRad(Pitch)), Sin(DegToRad(Yaw)) * Cos(DegToRad(Pitch)),
    -Sin(DegToRad(Pitch)));
  FViewport.Camera.SetWorldView(QuakeToCge(Eye), QuakeToCge(Dir), Vector3(0, 1, 0));
  UpdateWeapon;

  for I := 0 to High(FBeams) do
    if FBeams[I].Time > 0 then
    begin
      FBeams[I].Time := FBeams[I].Time - SecondsPassed;
      if FBeams[I].Time <= 0 then
        for J := 0 to High(FBeams[I].Segments) do
          FBeams[I].Segments[J].Exists := False;
    end;

  FGeometry.Update(SecondsPassed, FViewport.Camera.Translation);
  FAmbient.Update(SecondsPassed, FViewport.Camera.Translation);
  Particles.Update(SecondsPassed);
  Lighting.Update(SecondsPassed, FViewport.Camera.Translation);
  UpdateHudStats(SecondsPassed);
end;

function TViewDemo.Press(const Event: TInputPressRelease): Boolean;
begin
  Result := inherited Press(Event);
  if Result then
    Exit;
  if Event.IsKey(keyEscape) or Event.IsKey(keyEnter) or Event.IsKey(keySpace) then
  begin
    Leave;
    Exit(True);
  end;
end;

end.
