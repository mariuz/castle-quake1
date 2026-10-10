{ Plays a level driven by its QuakeC (TQuakeQcGame): the map, the entities
  the progs move and animate, the player with mouse look and the Quake
  physics, the status bar from the player's fields. }
unit GameViewQc;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math,
  CastleVectors, CastleUIControls, CastleKeysMouse, CastleViewport, CastleTransform,
  CastleScene, CastleLog, CastleImages, CastleQuaternions, CastleWindow, CastleUtils,
  CastleCameras,
  QuakePak, QuakeBsp, QuakeGeometry, QuakeLight, QuakeSound, QuakeHud, QuakeParticles,
  QuakeMdl, QuakeAmbient, QuakePhysics, QuakeDemo, QuakeProgs, QuakeQcGame;

type
  TQcVisual = record
    Transform: TCastleTransform;
    Scene: TCastleScene;
    Mdl: TQuakeMdl;
    Model: String;
    Frame, Skin: Integer;
    TrailTimer: Single;
  end;

  TViewQc = class(TCastleView)
  private
    FViewport: TCastleViewport;
    FNavigation: TCastleWalkNavigation;
    FGame: TQuakeQcGame;
    FGeometry: TQuakeGeometry;
    FAmbient: TQuakeAmbientSounds;
    FHud: TQuakeHud;
    FVisuals: array of TQcVisual;
    FStaticVisuals: array of TQcVisual;
    FSubmodels: array of TQuakeSubmodel;
    FSubmodelUsed: array of Boolean;
    FWeaponTransform: TCastleTransform;
    FWeapon: TQcVisual;
    FSoundPool: array[0..31] of TCastleTransform;
    FSoundPoolNext: Integer;
    FBeams: array[0..2] of record
      Segments: array of TCastleTransform;
      Time: Single;
    end;
    FLoaded: Boolean;
    FDeathTimer: Single;
    FImpulse: Integer;
    FFireHeld: Single;
    FGod: Boolean;
    { Autotest }
    FScript: TStringList;
    FScriptIndex: Integer;
    FScriptTimer: Single;
    FShots: Integer;
    FScriptMove: TVector3;
    FScriptJump: Single;
    FQuitRequested: Boolean;
    { Demo recording }
    FRecorder: TQuakeDemoWriter;
    FRecordUrl: String;
    procedure ClearLevel;
    function LoadLevel(const AMapName: String; const KeepParms: Boolean): Boolean;
    { The viewport side of a level the game holds (after LoadLevel / LoadGame) }
    procedure SetupLevel;
    procedure SaveGameSlot(const Slot: String);
    procedure LoadGameSlot(const Slot: String);
    procedure StartRecording(const Url: String);
    procedure StopRecording;
    procedure RecordLevel;
    procedure RecordFrame(const Yaw, Pitch: Single);
    function ViewYawPitch(out Yaw, Pitch: Single): Boolean;
    procedure ShowVisual(var V: TQcVisual; const Model: String; const Origin, Angles: TVector3;
      const Frame, Skin, Effects: Integer; const Dt: Single);
    procedure HideVisual(var V: TQcVisual);
    procedure FreeVisual(var V: TQcVisual);
    procedure ShowBeam(const Pool: Integer; const StartQ, StopQ: TVector3; const Duration: Single);
    procedure UpdateWeapon;
    procedure UpdateHudStats(const SecondsPassed: Single);
    procedure BuildUserCmd(out Cmd: TQuakeUserCmd);
    procedure RunScript(const SecondsPassed: Single);
    procedure CaptureScreenshot;
    procedure SetViewAngles(const Yaw, Pitch: Single);
    { Game events }
    procedure HandleSound(const E, Channel: Integer; const Sample: String; const Volume, Attenuation: Single;
      const Origin: TVector3);
    procedure HandleCenterPrint(const E: Integer; const S: String);
    procedure HandleStuffCmd(const E: Integer; const S: String);
    procedure HandleTempEntity(const Kind: Integer; const Pos, Pos2: TVector3; const Entity: Integer);
    procedure HandleDamage(const E, Armor, Blood: Integer);
    procedure HandleAmbient(const Origin: TVector3; const Sample: String; const Volume: Single);
    procedure HandleIntermission(const S: String);
    procedure HandlePrint(const S: String);
    procedure HandleMessage(const E: Integer; const Data: TBytes);
  public
    MapName: String;
    Skill: Integer;
    AutoTestPrefix, AutoTestScript: String;

    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Start; override;
    procedure Stop; override;
    procedure Update(const SecondsPassed: Single; var HandleInput: Boolean); override;
    function Press(const Event: TInputPressRelease): Boolean; override;
  end;

var
  ViewQc: TViewQc;

implementation

uses
  GameViewMenu;

const
  BeamModels: array[0..2] of String = ('progs/bolt.mdl', 'progs/bolt2.mdl', 'progs/bolt3.mdl');
  DeathRestartDelay = 3.0;

constructor TViewQc.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FGame := TQuakeQcGame.Create;
  FGame.OnSound := @HandleSound;
  FGame.OnCenterPrint := @HandleCenterPrint;
  FGame.OnStuffCmd := @HandleStuffCmd;
  FGame.OnTempEntity := @HandleTempEntity;
  FGame.OnDamage := @HandleDamage;
  FGame.OnAmbient := @HandleAmbient;
  FGame.OnIntermission := @HandleIntermission;
  FGame.OnPrint := @HandlePrint;
  FGame.OnMessage := @HandleMessage;
  FAmbient := TQuakeAmbientSounds.Create;
  FScript := TStringList.Create;
  SetLength(FVisuals, MaxEdicts);
  Skill := 1;
end;

destructor TViewQc.Destroy;
begin
  ClearLevel;
  FGame.Free;
  FAmbient.Free;
  FScript.Free;
  inherited Destroy;
end;

procedure TViewQc.Start;
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

    FNavigation := TCastleWalkNavigation.Create(Self);
    FNavigation.MoveSpeed := 0;
    FNavigation.Gravity := False;
    FNavigation.HeadBobbing := 0;
    FNavigation.MouseLook := True;
    FViewport.InsertFront(FNavigation);

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
    InsertFront(FHud);
  end;
  FHud.StopIntermission;
  Particles.SetParent(FViewport.Items);

  FScript.Clear;
  FScriptIndex := 0;
  FScriptTimer := 0;
  FShots := 0;
  FScriptMove := TVector3.Zero;
  FScriptJump := 0;
  FQuitRequested := False;
  for Cmd in AutoTestScript.Split([',']) do
    if Trim(Cmd) <> '' then
      FScript.Add(Trim(Cmd));
  FNavigation.MouseLook := AutoTestPrefix = '';

  if MapName = '' then
    MapName := 'start';
  if not LoadLevel(MapName, False) then
    FHud.ShowMessage('Cannot load ' + MapName, 3);
end;

procedure TViewQc.Stop;
begin
  StopRecording;
  ClearLevel;
  if Sounds <> nil then
    Sounds.StopMusic;
  if Lighting <> nil then
    Lighting.ResetStyles;
  inherited Stop;
end;

procedure TViewQc.FreeVisual(var V: TQcVisual);
begin
  if V.Transform <> nil then
  begin
    if V.Transform.Parent <> nil then
      V.Transform.Parent.Remove(V.Transform);
    FreeAndNil(V.Transform);
  end;
  V.Scene := nil;
  V.Mdl := nil;
  V.Model := '';
  V.Frame := -1;
end;

procedure TViewQc.HideVisual(var V: TQcVisual);
begin
  if V.Transform <> nil then
    V.Transform.Exists := False;
end;

procedure TViewQc.ClearLevel;
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
  if (FAmbient <> nil) and (Sounds <> nil) then
    FAmbient.Clear;
  if Particles <> nil then
    Particles.Clear;
  if Lighting <> nil then
    Lighting.Clear;
  FreeAndNil(FGeometry);
  FLoaded := False;
end;

function TViewQc.LoadLevel(const AMapName: String; const KeepParms: Boolean): Boolean;
var
  Angles: TVector3;
begin
  Result := False;
  ClearLevel;
  if not FGame.LoadLevel(AMapName, Skill, KeepParms) then
    Exit;
  MapName := AMapName;
  SetupLevel;
  if FGame.TakeFixAngle(Angles) then
    SetViewAngles(Angles.Y, Angles.X)
  else
    SetViewAngles(FGame.EntityAngles(1).Y, 0);
  RecordLevel;
  Result := True;
end;

procedure TViewQc.SetupLevel;
var
  Sub: TQuakeSubmodel;
  I: Integer;
begin
  FGeometry := TQuakeGeometry.Create(FGame.Bsp);
  FGeometry.AddToWorld(FViewport.Items);
  Lighting.CreateLightsFromBsp(FGame.Bsp, FViewport.Items);
  Lighting.ResetStyles;
  { The lightstyles the progs set while spawning (or the saved ones) }
  for I := 0 to 63 do
    if FGame.LightStyleValue(I) <> '' then
      Lighting.SetStyle(I, FGame.LightStyleValue(I));
  FAmbient.Setup(FGame.Bsp, FViewport.Items);
  SetLength(FSubmodels, FGame.Bsp.ModelCount);
  SetLength(FSubmodelUsed, FGame.Bsp.ModelCount);
  for Sub in FGeometry.Submodels do
  begin
    if (Sub.ModelIndex > 0) and (Sub.ModelIndex < Length(FSubmodels)) then
      FSubmodels[Sub.ModelIndex] := Sub;
    Sub.Transform.Exists := False;
  end;
  FDeathTimer := 0;
  FHud.StopIntermission;
  Sounds.PlayMusic('track02.ogg');
  FLoaded := True;
end;

function TViewQc.ViewYawPitch(out Yaw, Pitch: Single): Boolean;
var
  CamDir: TVector3;
begin
  Result := FViewport <> nil;
  Yaw := 0;
  Pitch := 0;
  if not Result then
    Exit;
  CamDir := FViewport.Camera.Direction;
  Yaw := RadToDeg(ArcTan2(-CamDir.Z, CamDir.X));
  Pitch := -RadToDeg(ArcSin(Clamped(CamDir.Y, -1, 1)));
end;

procedure TViewQc.SaveGameSlot(const Slot: String);
var
  Yaw, Pitch: Single;
begin
  if not FLoaded or FGame.PlayerDead then
  begin
    FHud.ShowMessage('Cannot save now', 2);
    Exit;
  end;
  ViewYawPitch(Yaw, Pitch);
  if FGame.SaveGame('castle-config:/qc_save_' + Slot + '.sav', Vector3(Pitch, Yaw, 0)) then
    FHud.ShowMessage('Game saved (' + Slot + ')', 2)
  else
    FHud.ShowMessage('Cannot save the game', 2);
end;

procedure TViewQc.LoadGameSlot(const Slot: String);
var
  Angles: TVector3;
begin
  ClearLevel;
  if not FGame.LoadGame('castle-config:/qc_save_' + Slot + '.sav', Angles) then
  begin
    FHud.ShowMessage('Cannot load slot ' + Slot, 2);
    LoadLevel(MapName, True);
    Exit;
  end;
  MapName := FGame.MapName;
  SetupLevel;
  SetViewAngles(Angles.Y, Angles.X);
  RecordLevel;
  FHud.ShowMessage('Game loaded (' + Slot + ')', 2);
end;

{ Demo recording }

procedure TViewQc.StartRecording(const Url: String);
begin
  StopRecording;
  FRecorder := TQuakeDemoWriter.Create;
  FRecordUrl := Url;
  if FLoaded then
    RecordLevel;
  FHud.ShowMessage('Recording demo', 2);
end;

procedure TViewQc.StopRecording;
begin
  if FRecorder = nil then
    Exit;
  if FRecorder.SaveToUrl(FRecordUrl) then
    WritelnLog('GameViewQc', 'Demo saved to "%s"', [FRecordUrl]);
  FreeAndNil(FRecorder);
  if FHud <> nil then
    FHud.ShowMessage('Demo saved', 2);
end;

procedure TViewQc.RecordLevel;
var
  Title: String;
  World: TQuakeEntity;
  Yaw, Pitch: Single;
begin
  if (FRecorder = nil) or (FGame.Bsp = nil) then
    Exit;
  Title := MapName;
  World := FGame.Bsp.FindEntity('worldspawn');
  if (World <> nil) and (World.MessageText <> '') then
    Title := World.MessageText;
  ViewYawPitch(Yaw, Pitch);
  FRecorder.BeginLevel('maps/' + MapName + '.bsp', Title, Vector3(Pitch, Yaw, 0), FGame.TotalMonsters,
    FGame.TotalSecrets);
end;

procedure TViewQc.RecordFrame(const Yaw, Pitch: Single);
var
  CD: TDemoClientData;
  St: TDemoEntityState;
  E: Integer;
begin
  if FRecorder = nil then
    Exit;
  FRecorder.BeginFrame(FGame.Time);
  CD := Default(TDemoClientData);
  CD.ViewHeight := FGame.PlayerViewOfs.Z;
  CD.Velocity := FGame.PlayerVelocity(1);
  CD.Items := FGame.PlayerItems;
  CD.OnGround := FGame.PlayerOnGround(1);
  CD.InWater := FGame.PlayerWaterLevel(1) > 0;
  CD.WeaponFrame := FGame.PlayerWeaponFrame;
  CD.Armor := FGame.PlayerArmor;
  if FGame.PlayerWeaponModel <> '' then
    CD.Weapon := FRecorder.ModelIndex(FGame.PlayerWeaponModel);
  CD.Health := FGame.PlayerHealth;
  CD.Ammo := FGame.PlayerAmmo(0);
  CD.Shells := FGame.PlayerAmmo(1);
  CD.Nails := FGame.PlayerAmmo(2);
  CD.Rockets := FGame.PlayerAmmo(3);
  CD.Cells := FGame.PlayerAmmo(4);
  CD.ActiveWeapon := Integer(FGame.PlayerWeapon);
  FRecorder.WriteClientData(CD);
  for E := 1 to FGame.Progs.NumEdicts - 1 do
    if FGame.EntityVisible(E) then
    begin
      St := Default(TDemoEntityState);
      St.ModelIndex := FRecorder.ModelIndex(FGame.EntityModel(E));
      St.Frame := FGame.EntityFrame(E);
      St.Skin := FGame.EntitySkin(E);
      St.Effects := FGame.EntityEffects(E);
      St.Origin := FGame.EntityOrigin(E);
      St.Angles := FGame.EntityAngles(E);
      FRecorder.WriteEntity(E, St);
    end;
  FRecorder.EndFrame(Vector3(Pitch, Yaw, 0));
end;

procedure TViewQc.HandlePrint(const S: String);
begin
  if FRecorder <> nil then
    FRecorder.WritePrint(S);
end;

procedure TViewQc.HandleMessage(const E: Integer; const Data: TBytes);
begin
  if (FRecorder = nil) or (Length(Data) = 0) then
    Exit;
  case Data[0] of
    27: FRecorder.WriteKilledMonster;
    28: FRecorder.WriteFoundSecret;
  end;
end;

procedure TViewQc.SetViewAngles(const Yaw, Pitch: Single);
var
  Dir: TVector3;
  P: Single;
begin
  { Quake angles: yaw 0 along +X, pitch > 0 looks down }
  P := EnsureRange(Pitch, -89, 89);
  Dir := Vector3(Cos(DegToRad(Yaw)) * Cos(DegToRad(P)), Sin(DegToRad(Yaw)) * Cos(DegToRad(P)), -Sin(DegToRad(P)));
  FViewport.Camera.SetWorldView(QuakeToCge(FGame.Phys.Origin + FGame.PlayerViewOfs), QuakeToCge(Dir),
    Vector3(0, 1, 0));
end;

{ Events }

procedure TViewQc.HandleSound(const E, Channel: Integer; const Sample: String; const Volume, Attenuation: Single;
  const Origin: TVector3);
var
  T: TCastleTransform;
begin
  if FRecorder <> nil then
    FRecorder.WriteSound(E, Channel, FRecorder.SoundIndex(Sample), Volume, Attenuation, Origin);
  if (E = 1) or (Attenuation = 0) then
    Sounds.Play(Sample, Volume)
  else
  begin
    T := FSoundPool[FSoundPoolNext];
    FSoundPoolNext := (FSoundPoolNext + 1) mod Length(FSoundPool);
    T.Translation := QuakeToCge(Origin);
    Sounds.PlayAt(Sample, T, Volume);
  end;
end;

procedure TViewQc.HandleCenterPrint(const E: Integer; const S: String);
begin
  if FRecorder <> nil then
    FRecorder.WriteCenterPrint(S);
  FHud.ShowMessage(StringReplace(S, #10, LineEnding, [rfReplaceAll]), 2.5);
end;

procedure TViewQc.HandleStuffCmd(const E: Integer; const S: String);
begin
  { bf = bonus flash, the rest (cd tracks, cvars) is ignored }
  if S = 'bf' then
    FHud.BonusFlash;
end;

procedure TViewQc.HandleDamage(const E, Armor, Blood: Integer);
begin
  if FRecorder <> nil then
    FRecorder.WriteDamage(Armor, Blood, FGame.Phys.Origin);
  FHud.DamageFlash(Armor, Blood);
end;

procedure TViewQc.HandleAmbient(const Origin: TVector3; const Sample: String; const Volume: Single);
begin
  FAmbient.AddStatic(FViewport.Items, QuakeToCge(Origin), Sample, Volume);
end;

procedure TViewQc.HandleIntermission(const S: String);
begin
  if FRecorder <> nil then
    FRecorder.WriteIntermission;
  if S <> '' then
    FHud.ShowMessage(StringReplace(S, #10, LineEnding, [rfReplaceAll]), 120)
  else
    FHud.StartIntermission(FGame.Bsp.FindEntity('worldspawn').MessageText, FGame.Time - 1,
      FGame.KilledMonsters, FGame.TotalMonsters, FGame.FoundSecrets, FGame.TotalSecrets);
  FHud.IntermissionReady := True;
  Sounds.PlayMusic('track03.ogg');
end;

procedure TViewQc.ShowBeam(const Pool: Integer; const StartQ, StopQ: TVector3; const Duration: Single);
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

procedure TViewQc.HandleTempEntity(const Kind: Integer; const Pos, Pos2: TVector3; const Entity: Integer);
var
  P: TVector3;
begin
  if FRecorder <> nil then
  begin
    if Kind in [5, 6, 9, 13] then
      FRecorder.WriteBeam(Kind, Entity, Pos, Pos2)
    else
      FRecorder.WriteTempEntity(Kind, Pos);
  end;
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
    TE_EXPLOSION, TE_EXPLOSION2, TE_TAREXPLOSION:
      begin
        Particles.SpawnExplosion(P);
        Lighting.TriggerMuzzleFlash(P, 6.0);
        Sounds.Play('sound/weapons/r_exp3.wav');
      end;
    TE_LAVASPLASH:
      Particles.SpawnExplosion(P);
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

{ Rendering }

procedure TViewQc.ShowVisual(var V: TQcVisual; const Model: String; const Origin, Angles: TVector3;
  const Frame, Skin, Effects: Integer; const Dt: Single);
var
  Q: TQuaternion;
  Pos: TVector3;
  Mdl: TQuakeMdl;
  Idx, SkinIdx: Integer;
begin
  if Model = '' then
  begin
    HideVisual(V);
    Exit;
  end;
  if Model[1] = '*' then
  begin
    HideVisual(V);
    Idx := StrToIntDef(Copy(Model, 2, MaxInt), -1);
    if (Idx > 0) and (Idx < Length(FSubmodels)) and (FSubmodels[Idx] <> nil) then
    begin
      FSubmodels[Idx].Transform.Exists := True;
      FSubmodels[Idx].Transform.Translation := QuakeToCge(Origin);
      FSubmodelUsed[Idx] := True;
    end;
    Exit;
  end;
  if LowerCase(ExtractFileExt(Model)) <> '.mdl' then
  begin
    HideVisual(V);
    Exit;
  end;
  Mdl := MdlManager.GetModel(Model);
  if Mdl = nil then
  begin
    HideVisual(V);
    Exit;
  end;
  SkinIdx := EnsureRange(Skin, 0, Max(0, Mdl.SkinCount - 1));
  if (V.Transform = nil) or (V.Model <> Model) or (V.Skin <> SkinIdx) then
  begin
    FreeVisual(V);
    V.Transform := TCastleTransform.Create(nil);
    V.Scene := Mdl.CreateScene(SkinIdx);
    V.Scene.Collides := False;
    V.Transform.Add(V.Scene);
    FViewport.Items.Add(V.Transform);
    V.Mdl := Mdl;
    V.Model := Model;
    V.Skin := SkinIdx;
    V.Frame := -1;
    V.TrailTimer := 0;
  end;
  V.Transform.Exists := True;
  if V.Frame <> Frame then
  begin
    V.Frame := Frame;
    Mdl.ApplyFrame(V.Scene, EnsureRange(Frame, 0, Max(0, Mdl.FrameCount - 1)));
  end;
  Pos := QuakeToCge(Origin);
  V.Transform.Translation := Pos;
  Q := QuatFromAxisAngle(Vector3(0, 1, 0), DegToRad(Angles.Y)) *
    QuatFromAxisAngle(Vector3(0, 0, 1), DegToRad(Angles.X)) *
    QuatFromAxisAngle(Vector3(1, 0, 0), DegToRad(Angles.Z));
  V.Transform.Rotation := Q.ToAxisAngle;

  if (Effects and EF_MUZZLEFLASH) <> 0 then
    Lighting.TriggerMuzzleFlash(Pos + Vector3(0, 16, 0), 2.5)
  else if (Effects and (EF_BRIGHTLIGHT or EF_DIMLIGHT)) <> 0 then
    Lighting.TriggerMuzzleFlash(Pos + Vector3(0, 16, 0), 2.0);

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

procedure TViewQc.UpdateWeapon;
var
  Model: String;
  Mdl: TQuakeMdl;
  Frame: Integer;
begin
  Model := FGame.PlayerWeaponModel;
  if (Model = '') or FGame.Intermission or FGame.PlayerDead then
  begin
    HideVisual(FWeapon);
    Exit;
  end;
  Mdl := MdlManager.GetModel(Model);
  if Mdl = nil then
  begin
    HideVisual(FWeapon);
    Exit;
  end;
  if (FWeapon.Transform = nil) or (FWeapon.Model <> Model) then
  begin
    FreeVisual(FWeapon);
    FWeapon.Transform := TCastleTransform.Create(nil);
    FWeapon.Scene := Mdl.CreateScene(0);
    FWeapon.Scene.Collides := False;
    FWeapon.Transform.Add(FWeapon.Scene);
    FWeaponTransform.Add(FWeapon.Transform);
    FWeapon.Mdl := Mdl;
    FWeapon.Model := Model;
    FWeapon.Frame := -1;
  end;
  FWeapon.Transform.Exists := True;
  Frame := FGame.PlayerWeaponFrame;
  if FWeapon.Frame <> Frame then
  begin
    FWeapon.Frame := Frame;
    Mdl.ApplyFrame(FWeapon.Scene, EnsureRange(Frame, 0, Max(0, Mdl.FrameCount - 1)));
  end;
end;

procedure TViewQc.UpdateHudStats(const SecondsPassed: Single);
const
  WeaponItems: array[1..8] of Cardinal = (IT_AXE, IT_SHOTGUN, IT_SUPER_SHOTGUN, IT_NAILGUN,
    IT_SUPER_NAILGUN, IT_GRENADE_LAUNCHER, IT_ROCKET_LAUNCHER, IT_LIGHTNING);
var
  S: TQuakePlayerStats;
  Items: Cardinal;
  I, C: Integer;
begin
  S := Default(TQuakePlayerStats);
  Items := FGame.PlayerItems;
  S.Health := FGame.PlayerHealth;
  S.Armor := FGame.PlayerArmor;
  if (Items and IT_ARMOR3) <> 0 then
    S.ArmorType := 3
  else if (Items and IT_ARMOR2) <> 0 then
    S.ArmorType := 2
  else if (Items and IT_ARMOR1) <> 0 then
    S.ArmorType := 1;
  S.Ammo := FGame.PlayerAmmo(0);
  S.Shells := FGame.PlayerAmmo(1);
  S.Nails := FGame.PlayerAmmo(2);
  S.Rockets := FGame.PlayerAmmo(3);
  S.Cells := FGame.PlayerAmmo(4);
  S.MaxShells := 100;
  S.MaxNails := 200;
  S.MaxRockets := 100;
  S.MaxCells := 100;
  for I := 1 to 8 do
  begin
    if (Items and WeaponItems[I]) <> 0 then
      S.WeaponMask := S.WeaponMask or (1 shl I);
    if FGame.PlayerWeapon = WeaponItems[I] then
      S.CurrentWeapon := I;
  end;
  if (Items and IT_KEY1) <> 0 then
    S.Keys := S.Keys or 1;
  if (Items and IT_KEY2) <> 0 then
    S.Keys := S.Keys or 2;
  if (Items and IT_SUIT) <> 0 then
    S.BiosuitTime := 1;
  S.Kills := FGame.KilledMonsters;
  S.TotalKills := FGame.TotalMonsters;
  S.Secrets := FGame.FoundSecrets;
  S.TotalSecrets := FGame.TotalSecrets;
  S.LevelTime := Math.Max(0.0, FGame.Time - 1);
  S.AirLeft := 12;
  C := FGame.Bsp.PointContentsCge(FViewport.Camera.Translation);
  FHud.SetContents(C);
  S.Underwater := (C = CONTENTS_WATER) or (C = CONTENTS_SLIME) or (C = CONTENTS_LAVA);
  FHud.Update(SecondsPassed, S);
end;

{ Input }

procedure TViewQc.BuildUserCmd(out Cmd: TQuakeUserCmd);
begin
  FillChar(Cmd, SizeOf(Cmd), 0);
  if AutoTestPrefix = '' then
  begin
    if FNavigation.Input_Forward.IsPressed(Container) then
      Cmd.ForwardMove := Cmd.ForwardMove + ClForwardSpeed;
    if FNavigation.Input_Backward.IsPressed(Container) then
      Cmd.ForwardMove := Cmd.ForwardMove - ClBackSpeed;
    if FNavigation.Input_RightStrafe.IsPressed(Container) then
      Cmd.SideMove := Cmd.SideMove + ClSideSpeed;
    if FNavigation.Input_LeftStrafe.IsPressed(Container) then
      Cmd.SideMove := Cmd.SideMove - ClSideSpeed;
    if FNavigation.Input_Run.IsPressed(Container) then
    begin
      Cmd.ForwardMove := Cmd.ForwardMove * 0.5;
      Cmd.SideMove := Cmd.SideMove * 0.5;
    end;
    Cmd.Jump := FNavigation.Input_Jump.IsPressed(Container);
  end;
  Cmd.ForwardMove := Cmd.ForwardMove + FScriptMove.X * ClForwardSpeed;
  Cmd.SideMove := Cmd.SideMove + FScriptMove.Y * ClSideSpeed;
  Cmd.UpMove := Cmd.UpMove + FScriptMove.Z * ClUpSpeed;
  if FScriptJump > 0 then
    Cmd.Jump := True;
end;

procedure TViewQc.CaptureScreenshot;
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
      WritelnLog('GameViewQc', 'Saved screenshot to "%s" (health %d, kills %d/%d, edicts %d)',
        [OutPath, FGame.PlayerHealth, FGame.KilledMonsters, FGame.TotalMonsters, FGame.Progs.NumEdicts]);
    end;
  except
    on E: Exception do
      WritelnWarning('GameViewQc', 'Failed to save screenshot "%s": %s', [OutPath, E.Message]);
  end;
end;

procedure TViewQc.RunScript(const SecondsPassed: Single);
var
  Cmd, Action, Param: String;
  P: Integer;
  Parts: TStringArray;
  CamDir: TVector3;
  Yaw, Pitch: Single;
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
    CamDir := FViewport.Camera.Direction;
    Yaw := RadToDeg(ArcTan2(-CamDir.Z, CamDir.X));
    Pitch := -RadToDeg(ArcSin(Clamped(CamDir.Y, -1, 1)));
    if Action = 'W' then
    begin
      FScriptTimer := FScriptTimer + SecondsPassed;
      if FScriptTimer < StrToFloatDef(Param, 1.0) then
        Exit;
      FScriptTimer := 0;
    end else
    if Action = 'S' then
      CaptureScreenshot
    else if Action = 'X' then
      FFireHeld := 0.05
    else if Action = 'F' then
      FFireHeld := StrToFloatDef(Param, 1.0)
    else if Action = 'C' then
      FImpulse := StrToIntDef(Param, 2)
    else if Action = 'K' then
      FImpulse := 9
    else if Action = 'Y' then
      FGod := not FGod
    else if Action = 'A' then
      SetViewAngles(StrToFloatDef(Param, 0), Pitch)
    else if Action = 'T' then
      SetViewAngles(Yaw + StrToFloatDef(Param, 0), Pitch)
    else if Action = 'P' then
      SetViewAngles(Yaw, -StrToFloatDef(Param, 0))
    else if Action = 'G' then
    begin
      Parts := Param.Split([';']);
      if Length(Parts) = 3 then
      begin
        FGame.Phys.Teleport(CgeToQuake(Vector3(StrToFloatDef(Parts[0], 0), StrToFloatDef(Parts[1], 0),
          StrToFloatDef(Parts[2], 0))) - FGame.PlayerViewOfs);
        FGame.Progs.SetFieldVector(1, FGame.Progs.FOrigin, FGame.Phys.Origin);
      end;
    end else
    if Action = 'V' then
    begin
      Parts := Param.Split([';']);
      FScriptMove := TVector3.Zero;
      for P := 0 to Min(High(Parts), 2) do
        FScriptMove.Data[P] := StrToFloatDef(Parts[P], 0);
    end else
    if Action = 'J' then
      FScriptJump := 0.1
    else if Action = 'O' then
      SaveGameSlot(Param)
    else if Action = 'L' then
      LoadGameSlot(Param)
    else if Action = 'R' then
    begin
      if Param = '' then
        StopRecording
      else
        StartRecording('castle-config:/' + Param + '.dem');
    end
    else if Action = 'Q' then
    begin
      FQuitRequested := True;
      Application.Terminate;
      Exit;
    end;
    Inc(FScriptIndex);
  end;
end;

procedure TViewQc.Update(const SecondsPassed: Single; var HandleInput: Boolean);
var
  Cmd: TQuakeUserCmd;
  CamDir, Angles: TVector3;
  Yaw, Pitch: Single;
  E, I, J: Integer;
  Fire: Boolean;
  Flags: Integer;
begin
  inherited Update(SecondsPassed, HandleInput);
  if FQuitRequested or not FLoaded then
    Exit;
  if FScript.Count > 0 then
    RunScript(SecondsPassed);

  { Input }
  BuildUserCmd(Cmd);
  FScriptJump := Math.Max(0.0, FScriptJump - SecondsPassed);
  Fire := (FFireHeld > 0) or ((AutoTestPrefix = '') and
    (Container.Pressed[keyCtrl] or (buttonLeft in Container.MousePressed)));
  FFireHeld := Math.Max(0.0, FFireHeld - SecondsPassed);
  if FGod then
  begin
    Flags := Round(FGame.Progs.Field(1, FGame.Progs.FFlags)^.F);
    FGame.Progs.Field(1, FGame.Progs.FFlags)^.F := Flags or FL_GODMODE;
  end;

  CamDir := FViewport.Camera.Direction;
  Yaw := RadToDeg(ArcTan2(-CamDir.Z, CamDir.X));
  Pitch := -RadToDeg(ArcSin(Clamped(CamDir.Y, -1, 1)));

  { The frame of the progs }
  FGame.Frame(Cmd, Yaw, Pitch, Min(SecondsPassed, 0.1), Fire, FImpulse);
  FImpulse := 0;
  if FGame.TakeFixAngle(Angles) then
  begin
    Yaw := Angles.Y;
    Pitch := Angles.X;
  end;
  SetViewAngles(Yaw, Pitch);
  RecordFrame(Yaw, Pitch);

  { Level change and death }
  if FGame.LevelChange <> '' then
  begin
    if not LoadLevel(FGame.LevelChange, True) then
      FHud.ShowMessage('Cannot load ' + FGame.LevelChange, 3);
    Exit;
  end;
  if FGame.PlayerDead then
  begin
    FDeathTimer := FDeathTimer + SecondsPassed;
    if FDeathTimer >= DeathRestartDelay then
    begin
      LoadLevel(MapName, True);
      Exit;
    end;
  end;

  { Entities }
  for I := 0 to High(FSubmodelUsed) do
    FSubmodelUsed[I] := False;
  for E := 2 to FGame.Progs.NumEdicts - 1 do
    if FGame.EntityVisible(E) then
      ShowVisual(FVisuals[E], FGame.EntityModel(E), FGame.EntityOrigin(E), FGame.EntityAngles(E),
        FGame.EntityFrame(E), FGame.EntitySkin(E), FGame.EntityEffects(E), SecondsPassed)
    else
      HideVisual(FVisuals[E]);
  for E := FGame.Progs.NumEdicts to High(FVisuals) do
    HideVisual(FVisuals[E]);
  for I := 1 to High(FSubmodels) do
    if (FSubmodels[I] <> nil) and not FSubmodelUsed[I] then
      FSubmodels[I].Transform.Exists := False;
  if (FGame.PlayerEffects and EF_MUZZLEFLASH) <> 0 then
    Lighting.TriggerMuzzleFlash(FViewport.Camera.Translation + FViewport.Camera.Direction * 20, 2.5);

  if Length(FStaticVisuals) < FGame.StaticCount then
    SetLength(FStaticVisuals, FGame.StaticCount);
  for I := 0 to FGame.StaticCount - 1 do
    ShowVisual(FStaticVisuals[I], FGame.Static(I).Model, FGame.Static(I).Origin, FGame.Static(I).Angles,
      FGame.Static(I).Frame, FGame.Static(I).Skin, 0, SecondsPassed);

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

function TViewQc.Press(const Event: TInputPressRelease): Boolean;
var
  I: Integer;
begin
  Result := inherited Press(Event);
  if Result then
    Exit;
  if Event.IsKey(keyEscape) then
  begin
    Container.View := ViewMenu;
    Exit(True);
  end;
  for I := 1 to 8 do
    if Event.IsKey(Chr(Ord('0') + I)) then
    begin
      FImpulse := I;
      Exit(True);
    end;
  if Event.IsKey(keyF12) then
  begin
    CaptureScreenshot;
    Exit(True);
  end;
  if Event.IsKey(keyF6) then
  begin
    SaveGameSlot('quick');
    Exit(True);
  end;
  if Event.IsKey(keyF9) then
  begin
    LoadGameSlot('quick');
    Exit(True);
  end;
end;

end.
