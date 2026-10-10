{ Plays Quake .dem recordings: the map named by the demo is loaded, the
  entities of every server frame are shown with their models, and sounds,
  effects, lightstyles, centerprints and the status bar follow the
  recorded messages.

  The same view is the multiplayer client: with NetHost set it connects to
  a TQuakeServer, feeds the server's messages to the same reader, and
  sends the player's input back; with HostMap set it runs that server in
  this process first (a listen server). }
unit GameViewDemo;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math,
  CastleVectors, CastleUIControls, CastleKeysMouse, CastleViewport, CastleTransform,
  CastleScene, CastleLog, CastleImages, CastleQuaternions, CastleWindow, CastleUtils,
  CastleCameras,
  QuakePak, QuakeBsp, QuakeGeometry, QuakeLight, QuakeSound, QuakeHud, QuakeParticles,
  QuakeMdl, QuakeAmbient, QuakePalette, QuakeDemo, QuakePhysics, QuakeNet, QuakeServer;

type
  TDemoVisual = record
    Transform: TCastleTransform;
    Scene: TCastleScene;
    Mdl: TQuakeMdl;
    ModelIndex, Frame, Skin: Integer;
    TrailTimer: Single;
  end;

  { One input sent to the server, kept until the server reports it applied }
  TPredictedInput = record
    Sequence: Word;
    Cmd: TQuakeUserCmd;
    Yaw, Pitch, Dt: Single;
    Origin: TVector3; { predicted after this input }
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
    FSubmodelOrigin: array of TVector3;   { Quake origin of the shown submodels }
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
    { Network client }
    FClient: TQuakeNetClient;
    FRendezvous: TQuakeNetRendezvous;
    { Client-side prediction: the player's physics run here on the inputs
      the server has not answered yet (cl_pred of QuakeWorld) }
    FPredict: TQuakePlayerPhysics;
    FHistory: array of TPredictedInput;
    FInputSeq: Word;
    FPredictValid: Boolean;
    FReconciledFrames: Cardinal;
    FPredictError, FPredictErrorMax: Single; { server origin vs. the prediction for the same input }
    FNavigation: TCastleWalkNavigation;
    FImpulse: Integer;
    FFireHeld: Single;
    FScriptMove: TVector3;
    FScriptJump: Single;
    FWasConnected: Boolean;
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
    procedure HandleCdTrack(const Track, LoopTrack: Integer);
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
    procedure SetViewAngles(const Yaw, Pitch: Single);
    procedure UpdateNetwork(const SecondsPassed: Single);
    procedure SendInput(const SecondsPassed: Single);
    procedure PredictInput(const Input: TNetInput; const Dt: Single);
    procedure ReconcilePrediction;
    procedure RefreshPredictSolids;
    function PredictionActive: Boolean;
  public
    { PAK name ('demo1.dem') or URL of the demo to play }
    DemoName: String;
    { Headless testing: screenshots go to Prefix_N.png, Script like the
      play view's --demo (W, S and Q) }
    AutoTestPrefix, AutoTestScript: String;
    { Multiplayer: the server to join (NetHost, NetPort; 0 is the default
      port), and the map to host in this process first (HostMap) }
    NetHost: String;
    NetPort: Word;
    HostMap: String;
    HostCoop: Boolean;
    HostSkill: Integer;
    { Rendezvous (UDP hole punching): the host registers as RegisterName
      at RegisterHost:RegisterPort; a client with NetName set looks the
      name up at NetHost:NetPort instead of connecting there }
    RegisterName, RegisterHost: String;
    RegisterPort: Word;
    NetName: String;
    { Run the rendezvous service itself on NetPort (no game) }
    Rendezvous: Boolean;
    { Client-side prediction of the local player (default on) }
    Predict: Boolean;

    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Start; override;
    procedure Stop; override;
    procedure Update(const SecondsPassed: Single; var HandleInput: Boolean); override;
    function Press(const Event: TInputPressRelease): Boolean; override;
    function NetMode: Boolean;
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
  Predict := True;
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
  FDemo.OnCdTrack := @HandleCdTrack;
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
    FViewport.Camera.Name := 'camera';
    FViewport.Camera.ProjectionNear := 1.0;
    FViewport.Camera.Perspective.FieldOfViewAxis := faHorizontal;
    FViewport.Camera.Perspective.FieldOfView := DegToRad(90.0);
    InsertFront(FViewport);

    FNavigation := TCastleWalkNavigation.Create(Self);
    FNavigation.MoveSpeed := 0;
    FNavigation.Gravity := False;
    FNavigation.HeadBobbing := 0;
    FNavigation.MouseLook := False;
    FViewport.InsertFront(FNavigation);

    FWeaponTransform := TCastleTransform.Create(Self);
    FWeaponTransform.Name := 'view_weapon';
    FWeaponTransform.Rotation := Vector4(0, 1, 0, Pi / 2);
    FViewport.Camera.Add(FWeaponTransform);

    for I := 0 to High(FSoundPool) do
    begin
      FSoundPool[I] := TCastleTransform.Create(Self);
      FSoundPool[I].Name := 'sound_pool_' + IntToStr(I);
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
  FHud.CrosshairVisible := NetMode;
  FNavigation.Exists := NetMode;
  FNavigation.MouseLook := NetMode and (AutoTestPrefix = '');
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
  FImpulse := 0;
  FFireHeld := 0;
  FScriptMove := TVector3.Zero;
  FScriptJump := 0;
  FWasConnected := False;
  ClearLevel;
  if NetMode then
  begin
    if NetPort = 0 then
      NetPort := DefaultNetPort;
    FreeAndNil(ListenServer);
    FreeAndNil(FRendezvous);
    FDemo.StartNetwork;
    if Rendezvous then
    begin
      FRendezvous := TQuakeNetRendezvous.Create(NetPort);
      if not FRendezvous.Valid then
      begin
        FHud.ShowMessage('Cannot open UDP port ' + IntToStr(NetPort) + ' for the rendezvous', 3);
        FreeAndNil(FRendezvous);
        FDemo.Finished := True;
      end else
        FHud.ShowMessage('Rendezvous service on UDP port ' + IntToStr(NetPort) + ' (Escape quits)', 10);
      Exit;
    end;
    if HostMap <> '' then
    begin
      ListenServer := TQuakeServer.Create(NetPort, HostMap, MaxNetClients, HostCoop, HostSkill);
      if not ListenServer.Valid then
      begin
        FHud.ShowMessage('Cannot host ' + HostMap + ' on port ' + IntToStr(NetPort), 3);
        FreeAndNil(ListenServer);
        FDemo.Finished := True;
        Exit;
      end;
      if RegisterName <> '' then
        ListenServer.Net.RegisterAt(RegisterHost, RegisterPort, RegisterName);
      NetHost := '127.0.0.1';
      NetName := '';
    end;
    FreeAndNil(FClient);
    FClient := TQuakeNetClient.Create;
    if NetName <> '' then
    begin
      if not FClient.ConnectVia(NetHost, NetPort, NetName) then
      begin
        FHud.ShowMessage('Cannot look up ' + NetName + ' at ' + NetHost + ':' + IntToStr(NetPort), 3);
        FDemo.Finished := True;
      end else
        FHud.ShowMessage('Looking up ' + NetName + ' at ' + NetHost + ':' + IntToStr(NetPort) + '...', 5);
    end else
    if not FClient.Connect(NetHost, NetPort) then
    begin
      FHud.ShowMessage('Cannot connect to ' + NetHost + ':' + IntToStr(NetPort), 3);
      FDemo.Finished := True;
    end else
      FHud.ShowMessage('Connecting to ' + NetHost + ':' + IntToStr(NetPort) + '...', 5);
  end else
  if not FDemo.Load(DemoName) then
  begin
    FHud.ShowMessage('Cannot play demo ' + DemoName, 3);
    FDemo.Finished := True;
  end;
end;

procedure TViewDemo.Stop;
begin
  if FClient <> nil then
  begin
    FClient.Disconnect;
    FreeAndNil(FClient);
  end;
  FreeAndNil(ListenServer);
  FreeAndNil(FRendezvous);
  ClearLevel;
  if Sounds <> nil then
    Sounds.StopMusic;
  if Lighting <> nil then
    Lighting.ResetStyles;
  inherited Stop;
end;

function TViewDemo.NetMode: Boolean;
begin
  Result := (NetHost <> '') or (HostMap <> '') or Rendezvous;
end;

procedure TViewDemo.SetViewAngles(const Yaw, Pitch: Single);
var
  Dir: TVector3;
  P: Single;
begin
  { Quake angles: yaw 0 along +X, pitch > 0 looks down }
  P := EnsureRange(Pitch, -89, 89);
  FDemo.ViewAngles := Vector3(P, Yaw, 0);
  Dir := Vector3(Cos(DegToRad(Yaw)) * Cos(DegToRad(P)), Sin(DegToRad(Yaw)) * Cos(DegToRad(P)), -Sin(DegToRad(P)));
  FViewport.Camera.SetWorldView(FViewport.Camera.Translation, QuakeToCge(Dir), Vector3(0, 1, 0));
end;

procedure TViewDemo.SendInput(const SecondsPassed: Single);
var
  Input: TNetInput;
begin
  Input := Default(TNetInput);
  Inc(FInputSeq);
  Input.Sequence := FInputSeq;
  Input.Msec := Max(1, Min(Round(SecondsPassed * 1000), MaxInputMsec));
  Input.Angles := FDemo.ViewAngles;
  if AutoTestPrefix = '' then
  begin
    if FNavigation.Input_Forward.IsPressed(Container) then
      Input.Move.X := Input.Move.X + ClForwardSpeed;
    if FNavigation.Input_Backward.IsPressed(Container) then
      Input.Move.X := Input.Move.X - ClBackSpeed;
    if FNavigation.Input_RightStrafe.IsPressed(Container) then
      Input.Move.Y := Input.Move.Y + ClSideSpeed;
    if FNavigation.Input_LeftStrafe.IsPressed(Container) then
      Input.Move.Y := Input.Move.Y - ClSideSpeed;
    if FNavigation.Input_Run.IsPressed(Container) then
      Input.Move := Input.Move * 0.5;
    if FNavigation.Input_Jump.IsPressed(Container) then
      Input.Buttons := Input.Buttons or nbJump;
    if Container.Pressed[keyCtrl] or (buttonLeft in Container.MousePressed) then
      Input.Buttons := Input.Buttons or nbFire;
  end;
  Input.Move := Input.Move + Vector3(FScriptMove.X * ClForwardSpeed, FScriptMove.Y * ClSideSpeed,
    FScriptMove.Z * ClUpSpeed);
  if FScriptJump > 0 then
    Input.Buttons := Input.Buttons or nbJump;
  if FFireHeld > 0 then
    Input.Buttons := Input.Buttons or nbFire;
  Input.Impulse := EnsureRange(FImpulse, 0, 255);
  FImpulse := 0;
  FClient.SendInput(Input);
  PredictInput(Input, SecondsPassed);
end;

procedure TViewDemo.RefreshPredictSolids;
var
  I, N: Integer;
begin
  { The brush entities where the server last showed them }
  N := 0;
  SetLength(FPredict.SolidModels, Length(FSubmodels));
  for I := 1 to High(FSubmodels) do
    if (FSubmodels[I] <> nil) and FSubmodels[I].Transform.Exists then
    begin
      FPredict.SolidModels[N].ModelIndex := I;
      FPredict.SolidModels[N].Offset := FSubmodelOrigin[I];
      Inc(N);
    end;
  SetLength(FPredict.SolidModels, N);
  SetLength(FPredict.SolidBoxes, 0);
end;

procedure TViewDemo.PredictInput(const Input: TNetInput; const Dt: Single);
var
  H: TPredictedInput;
begin
  if not Predict or (FPredict = nil) then
    Exit;
  H := Default(TPredictedInput);
  H.Sequence := Input.Sequence;
  H.Cmd.ForwardMove := Input.Move.X;
  H.Cmd.SideMove := Input.Move.Y;
  H.Cmd.UpMove := Input.Move.Z;
  H.Cmd.Jump := (Input.Buttons and nbJump) <> 0;
  H.Yaw := Input.Angles.Y;
  H.Pitch := Input.Angles.X;
  H.Dt := Input.Msec / 1000; { what the server runs }
  if Length(FHistory) >= 128 then
    Delete(FHistory, 0, 1);
  SetLength(FHistory, Length(FHistory) + 1);
  FHistory[High(FHistory)] := H;
  if FPredictValid then
  begin
    RefreshPredictSolids;
    FPredict.Move(H.Cmd, H.Yaw, H.Pitch, H.Dt);
    FHistory[High(FHistory)].Origin := FPredict.Origin;
  end;
end;

procedure TViewDemo.ReconcilePrediction;
var
  V, I: Integer;
  Acked: Word;
  CD: TDemoClientData;
begin
  if not Predict or (FPredict = nil) or (FClient = nil) or not FClient.HasAckedInput then
    Exit;
  if FClient.FramesReceived = FReconciledFrames then
    Exit; { no new server frame }
  FReconciledFrames := FClient.FramesReceived;
  V := FDemo.ViewEntity;
  if (V <= 0) or (V >= Length(FDemo.Entities)) then
    Exit;
  { Start from the server's state and apply what it has not seen yet }
  Acked := FClient.AckedInput;
  CD := FDemo.ClientData;
  if FPredictValid then
    for I := 0 to High(FHistory) do
      if FHistory[I].Sequence = Acked then
      begin
        FPredictError := (FHistory[I].Origin - FDemo.Entities[V].Msg[0].Origin).Length;
        FPredictErrorMax := Max(FPredictErrorMax, FPredictError);
        Break;
      end;
  FPredict.Origin := FDemo.Entities[V].Msg[0].Origin;
  FPredict.Velocity := CD.Velocity;
  FPredict.OnGround := CD.OnGround;
  if CD.OnGround then
    FPredict.GroundEntity := 0
  else
    FPredict.GroundEntity := -1;
  FPredictValid := True;
  I := 0;
  while (I < Length(FHistory)) and (SmallInt(FHistory[I].Sequence - Acked) <= 0) do
    Inc(I);
  if I > 0 then
    Delete(FHistory, 0, I);
  RefreshPredictSolids;
  for I := 0 to High(FHistory) do
  begin
    FPredict.Move(FHistory[I].Cmd, FHistory[I].Yaw, FHistory[I].Pitch, FHistory[I].Dt);
    FHistory[I].Origin := FPredict.Origin;
  end;
end;

function TViewDemo.PredictionActive: Boolean;
begin
  Result := Predict and FPredictValid and (FPredict <> nil) and (FDemo.ClientData.Health > 0) and
    (FDemo.Intermission = 0);
end;

procedure TViewDemo.UpdateNetwork(const SecondsPassed: Single);
var
  Data: TNetBytes;
begin
  if FRendezvous <> nil then
  begin
    FRendezvous.Update(SecondsPassed);
    Exit;
  end;
  { The listen server runs here, before its own client reads it }
  if ListenServer <> nil then
    ListenServer.Update(SecondsPassed);
  if FClient = nil then
    Exit;
  FClient.Update(SecondsPassed);
  while FClient.PollBlock(Data) do
    FDemo.PushBlock(Data);
  if FClient.State = csConnected then
    FWasConnected := True
  else
  if (FClient.State = csDisconnected) and not FDemo.Finished then
  begin
    if FWasConnected then
      FHud.ShowMessage('Disconnected from the server', 3)
    else
      FHud.ShowMessage('Cannot reach ' + NetHost + ':' + IntToStr(NetPort) + ' ' + FClient.Error, 3);
    WritelnLog('GameViewDemo', 'Connection ended: %s', [FClient.Error]);
    FDemo.Finished := True;
  end;
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
  SetLength(FSubmodelOrigin, 0);
  FreeAndNil(FPredict);
  SetLength(FHistory, 0);
  FPredictValid := False;
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
  World: TQuakeEntity;
begin
  ClearLevel;
  ResetComponentNames;
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
  SetLength(FSubmodelOrigin, FBsp.ModelCount);
  if NetMode then
  begin
    FPredict := TQuakePlayerPhysics.Create;
    FPredict.Bsp := FBsp;
    FPredict.Mins := Vector3(-16, -16, -24);
    FPredict.Maxs := Vector3(16, 16, 32);
    FPredict.ViewHeight := 22;
    FPredictValid := False;
    SetLength(FHistory, 0);
  end;
  for Sub in FGeometry.Submodels do
  begin
    if (Sub.ModelIndex > 0) and (Sub.ModelIndex < Length(FSubmodels)) then
      FSubmodels[Sub.ModelIndex] := Sub;
    Sub.Transform.Exists := False;
  end;
  FLevelStart := -1;
  FLoaded := True;
  { The map's CD track until the server's svc_cdtrack says otherwise }
  World := FBsp.FindEntity('worldspawn');
  if (World <> nil) and (World.Sounds > 0) then
    Sounds.PlayTrack(World.Sounds)
  else
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
    Seg.Name := ComponentName('beam_segment');
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

procedure TViewDemo.HandleCdTrack(const Track, LoopTrack: Integer);
begin
  Sounds.PlayTrack(Track);
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
      FSubmodelOrigin[Skin] := State.Origin;
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
    V.Transform.Name := ComponentName('entity');
    V.Scene := Mdl.CreateScene(Skin);
    V.Scene.Name := V.Transform.Name + '_scene';
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
    FWeapon.Transform.Name := 'weapon_model';
    FWeapon.Scene := Mdl.CreateScene(0);
    FWeapon.Scene.Name := 'weapon_model_scene';
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
    Sounds.SetUnderwater(S.Underwater);
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
      WritelnLog('GameViewDemo', 'Saved screenshot to "%s" (signon %d, health %d, frags %d, time %.1f)',
        [OutPath, FDemo.Signon, FDemo.ClientData.Health, FDemo.Frags[Max(0, FDemo.ViewEntity - 1) mod 16], FDemo.Time]);
      if NetMode and (FPredict <> nil) and (FDemo.ViewEntity > 0) and (FDemo.ViewEntity < Length(FDemo.Entities)) then
        WritelnLog('GameViewDemo', 'Prediction %s: predicted %s, server %s, error %.1f (max %.1f), %d inputs pending',
          [BoolToStr(PredictionActive, 'on', 'off'), FPredict.Origin.ToString,
           FDemo.Entities[FDemo.ViewEntity].Msg[0].Origin.ToString, FPredictError, FPredictErrorMax, Length(FHistory)]);
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
  Parts: TStringArray;
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
    else if Action = 'X' then
      FFireHeld := 0.05
    else if Action = 'F' then
      FFireHeld := StrToFloatDef(Param, 1.0)
    else if Action = 'C' then
      FImpulse := StrToIntDef(Param, 2)
    else if Action = 'K' then
      FImpulse := 9
    else if Action = 'A' then
      SetViewAngles(StrToFloatDef(Param, 0), FDemo.ViewAngles.X)
    else if Action = 'T' then
      SetViewAngles(FDemo.ViewAngles.Y + StrToFloatDef(Param, 0), FDemo.ViewAngles.X)
    else if Action = 'P' then
      SetViewAngles(FDemo.ViewAngles.Y, -StrToFloatDef(Param, 0))
    else if Action = 'V' then
    begin
      Parts := Param.Split([';']);
      FScriptMove := TVector3.Zero;
      for P := 0 to Min(High(Parts), 2) do
        FScriptMove.Data[P] := StrToFloatDef(Parts[P], 0);
    end else
    if Action = 'J' then
      FScriptJump := 0.1
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
  if FClient <> nil then
    FClient.Disconnect;
  if AutoTestPrefix <> '' then
    Application.Terminate
  else
    Container.View := ViewMenu;
end;

procedure TViewDemo.Update(const SecondsPassed: Single; var HandleInput: Boolean);
var
  I, J: Integer;
  Eye, Dir, CamDir: TVector3;
  Pitch, Yaw: Single;
  CD: TDemoClientData;
  Cmd: String;
begin
  inherited Update(SecondsPassed, HandleInput);

  if FScript.Count > 0 then
    RunScript(SecondsPassed);
  if NetMode then
    UpdateNetwork(SecondsPassed);

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

  if NetMode then
  begin
    { The player looks where the mouse turned the camera, unless the
      server set the angles (spawn, teleport); then the input goes out }
    CamDir := FViewport.Camera.Direction;
    Yaw := RadToDeg(ArcTan2(-CamDir.Z, CamDir.X));
    Pitch := -RadToDeg(ArcSin(Clamped(CamDir.Y, -1, 1)));
    if FDemo.AngleFixed then
    begin
      Yaw := FDemo.ViewAngles.Y;
      Pitch := FDemo.ViewAngles.X;
      FDemo.AngleFixed := False;
    end;
    FDemo.ViewAngles := Vector3(EnsureRange(Pitch, -89, 89), Yaw, 0);
    FScriptJump := Math.Max(0.0, FScriptJump - SecondsPassed);
    if FDemo.Signon = Signons then
    begin
      ReconcilePrediction;
      SendInput(SecondsPassed);
    end;
    FFireHeld := Math.Max(0.0, FFireHeld - SecondsPassed);
    if FDemo.FragsChanged then
    begin
      FDemo.FragsChanged := False;
      Cmd := '';
      for I := 0 to High(FDemo.Names) do
        if FDemo.Names[I] <> '' then
        begin
          if Cmd <> '' then
            Cmd := Cmd + '   ';
          Cmd := Cmd + FDemo.Names[I] + ': ' + IntToStr(FDemo.Frags[I]);
        end;
      if Cmd <> '' then
        FHud.ShowMessage(Cmd, 4);
    end;
  end;

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
  if NetMode and PredictionActive then
    Eye := FPredict.Origin + Vector3(0, 0, CD.ViewHeight)
  else
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
var
  I: Integer;
begin
  Result := inherited Press(Event);
  if Result then
    Exit;
  if NetMode then
  begin
    if Event.IsKey(keyEscape) then
    begin
      Leave;
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
    Exit;
  end;
  if Event.IsKey(keyEscape) or Event.IsKey(keyEnter) or Event.IsKey(keySpace) then
  begin
    Leave;
    Exit(True);
  end;
end;

end.
