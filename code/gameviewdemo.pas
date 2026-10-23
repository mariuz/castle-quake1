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
  GameInput, GameVideo, GameTouch, GamePhoto,
  QuakePak, QuakeBsp, QuakeGeometry, QuakeLight, QuakeSound, QuakeHud, QuakeParticles,
  QuakeMdl, QuakeAmbient, QuakePalette, QuakeDemo, QuakePhysics, QuakeNet, QuakeServer, QuakeWebSocketRelay;

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

  { A view of split-screen: both share the world, so while one renders it
    hides what only the other shows (its weapon, the other's body) }
  TSplitViewport = class(TCastleViewport)
  protected
    procedure RenderFromViewEverything(const RenderingCamera: TRenderingCamera); override;
  public
    Hidden: array of TCastleTransform;
    { Called before it draws (the sky's eye for its camera) }
    OnBeforeDraw: TNotifyEvent;
  end;

  TViewDemo = class(TCastleView)
  private
    FViewport: TSplitViewport;
    FDemo: TQuakeDemoReader;
    FBsp: TQuakeBsp;
    FGeometry: TQuakeGeometry;
    FAmbient: TQuakeAmbientSounds;
    FHud: TQuakeHud;
    { Touch controls of a network game }
    FTouch: TQuakeTouchControls;
    FVisuals: array of TDemoVisual;
    FStaticVisuals: array of TDemoVisual;
    FSubmodels: array of TQuakeSubmodel;  { by BSP model index }
    FSubmodelUsed: array of Boolean;
    FSubmodelOrigin: array of TVector3;   { Quake origin of the shown submodels }
    FWeaponTransform: TCastleTransform;
    FPhoto: TPhotoMode;
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
    FWsRelay: TQuakeWebSocketRelay;
    { Client-side prediction: the player's physics run here on the inputs
      the server has not answered yet (cl_pred of QuakeWorld) }
    FPredict: TQuakePlayerPhysics;
    FHistory: array of TPredictedInput;
    FInputSeq: Word;
    { Frame time not sent yet: inputs last at least MinInputMsec }
    FInputTime: Single;
    FPredictValid: Boolean;
    FReconciledFrames: Cardinal;
    FPredictError, FPredictErrorMax: Single; { server origin vs. the prediction for the same input }
    FNavigation: TCastleWalkNavigation;
    FImpulse: Integer;
    FFireHeld: Single;
    FScriptMove: TVector3;
    FScriptJump: Single;
    FWasConnected: Boolean;
    { Split-screen: the second local player has its own client, reader,
      camera (in FViewport2, sharing FViewport's world), HUD and weapon;
      the entities and sounds come from the first player's client, which
      the listen server sends every entity }
    FSplit: Boolean;
    FViewport2: TSplitViewport;
    FCamera2: TCastleCamera;
    FHud2: TQuakeHud;
    FWeaponTransform2: TCastleTransform;
    FWeapon2: TDemoVisual;
    FClient2: TQuakeNetClient;
    FDemo2: TQuakeDemoReader;
    FInputSeq2: Word;
    FInputTime2: Single;
    FImpulse2: Integer;
    { The virtual gamepad of the script (GL, GR, GT, GB) }
    FPadLeft, FPadRight: TVector2;
    FPadButton: TGameControllerButton;
    FPadRelease: Single;
    { Autotest: W:sec, S (screenshot), Q }
    FScript: TStringList;
    FScriptIndex: Integer;
    FScriptTimer: Single;
    FShots: Integer;
    procedure ClearLevel;
    procedure LoadLevel;
    procedure ApplyEnvironment;
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
    { Draw only the entities and brush models in the camera's PVS }
    procedure CullVisuals;
    procedure FreeVisual(var V: TDemoVisual);
    procedure ShowBeam(const Pool: Integer; const StartQ, StopQ: TVector3; const Duration: Single);
    procedure UpdateWeapon(const Reader: TQuakeDemoReader; var Weapon: TDemoVisual; const Holder: TCastleTransform);
    procedure UpdateHudStats(const Reader: TQuakeDemoReader; const Hud: TQuakeHud; const Eye: TVector3;
      const Main: Boolean; const SecondsPassed: Single);
    procedure ApplySplitLayout;
    procedure UpdatePlayer2(const SecondsPassed: Single);
    procedure SendInput2(const SecondsPassed: Single);
    procedure HandleCenterPrint2(const S: String);
    procedure HandleDamage2(const Armor, Blood: Integer; const From: TVector3);
    procedure HandleIntermission2;
    function PlayerOne: Integer;
    procedure ViewportBeforeDraw(Sender: TObject);
    procedure UpdateWorldVisibility;
    procedure ComparePvsRender;
    function VisualTransform(const Entity: Integer): TCastleTransform;
    procedure RunScript(const SecondsPassed: Single);
    procedure CaptureScreenshot;
    procedure SetPhotoMode(const On: Boolean);
    function PhotoPrefix: String;
    procedure Leave;
    procedure SetViewAngles(const Yaw, Pitch: Single);
    procedure UpdateNetwork(const SecondsPassed: Single);
    function RelayTargetHost: String;
    function RelayTargetPort: Word;
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
    { Deathmatch bots the hosted game starts with (-bots N) }
    HostBots: Integer;
    { Rendezvous (UDP hole punching): the host registers as RegisterName
      at RegisterHost:RegisterPort; a client with NetName set looks the
      name up at NetHost:NetPort instead of connecting there }
    RegisterName, RegisterHost: String;
    RegisterPort: Word;
    NetName: String;
    { Run the rendezvous service itself on NetPort (no game) }
    Rendezvous: Boolean;
    { Players in the browser: the host also runs a WebSocket relay on this
      TCP port to its own server (0 = none) }
    WebSocketPort: Word;
    { Run only a WebSocket relay to this game server ("host[:port]"),
      listening on NetPort (TCP) }
    WsRelayTarget: String;
    { Client-side prediction of the local player (default on) }
    Predict: Boolean;
    { Split-screen with HostMap: a second local player with the gamepad
      (the keyboard and mouse play the first), side by side or, with
      SplitStacked, one above the other }
    SplitScreen, SplitStacked: Boolean;

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

procedure TSplitViewport.RenderFromViewEverything(const RenderingCamera: TRenderingCamera);
var
  I: Integer;
  Was: array of Boolean;
begin
  Was := nil;
  SetLength(Was, Length(Hidden));
  for I := 0 to High(Hidden) do
    if Hidden[I] <> nil then
    begin
      Was[I] := Hidden[I].Visible;
      Hidden[I].Visible := False;
    end;
  if Assigned(OnBeforeDraw) then
    OnBeforeDraw(Self);
  inherited RenderFromViewEverything(RenderingCamera);
  for I := 0 to High(Hidden) do
    if Hidden[I] <> nil then
      Hidden[I].Visible := Was[I];
end;

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
  FDemo2 := TQuakeDemoReader.Create;
  FDemo2.OnCenterPrint := @HandleCenterPrint2;
  FDemo2.OnDamage := @HandleDamage2;
  FDemo2.OnIntermission := @HandleIntermission2;
  FAmbient := TQuakeAmbientSounds.Create;
  FScript := TStringList.Create;
  SetLength(FVisuals, MaxDemoEntities);
end;

destructor TViewDemo.Destroy;
begin
  ClearLevel;
  FDemo.Free;
  FDemo2.Free;
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
    FViewport := TSplitViewport.Create(Self);
    FViewport.Name := 'viewport';
    FViewport.FullSize := True;
    FViewport.Transparent := False;
    FViewport.BackgroundColor := Vector4(0.02, 0.02, 0.03, 1.0);
    FViewport.Camera.Name := 'camera';
    FViewport.Camera.ProjectionNear := 1.0;
    ApplyVideoSettings(FViewport);
    InsertFront(FViewport);

    { The second split-screen view: its own camera in the same world }
    FViewport2 := TSplitViewport.Create(Self);
    FViewport2.Name := 'viewport2';
    FViewport2.Transparent := False;
    FViewport2.BackgroundColor := FViewport.BackgroundColor;
    FViewport2.Exists := False;
    FViewport.OnBeforeDraw := @ViewportBeforeDraw;
    FViewport2.OnBeforeDraw := @ViewportBeforeDraw;
    FCamera2 := TCastleCamera.Create(Self);
    FCamera2.Name := 'camera2';
    FCamera2.ProjectionNear := 1.0;
    FViewport.Items.Add(FCamera2);
    FViewport2.Items := FViewport.Items;
    FViewport2.Camera := FCamera2;
    InsertFront(FViewport2);
    FWeaponTransform2 := TCastleTransform.Create(Self);
    FWeaponTransform2.Name := 'view_weapon2';
    FWeaponTransform2.Rotation := Vector4(0, 1, 0, Pi / 2);
    FCamera2.Add(FWeaponTransform2);

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
    FHud2 := TQuakeHud.Create(Self);
    FHud2.Name := 'hud2';
    FViewport2.InsertFront(FHud2);
  end;
  if FTouch = nil then
  begin
    FTouch := TQuakeTouchControls.Create(Self);
    InsertFront(FTouch);
  end;
  if FPhoto = nil then
    FPhoto := TPhotoMode.Create(Self, FViewport, Self, FNavigation);
  SetPhotoMode(False);
  { Split-screen hosts here: a listen server and two clients, over UDP or
    (in the browser, -netloopback) in-process loopback sockets }
  FSplit := SplitScreen and (HostMap <> '');
  ApplySplitLayout;
  FHud2.StopIntermission;
  FHud2.CrosshairVisible := True;
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
  FImpulse2 := 0;
  FPadRelease := 0;
  FPadLeft := TVector2.Zero;
  FPadRight := TVector2.Zero;
  ClearLevel;
  if NetMode then
  begin
    if NetPort = 0 then
      NetPort := DefaultNetPort;
    FreeAndNil(ListenServer);
    FreeAndNil(FRendezvous);
    FreeAndNil(FWsRelay);
    FDemo.StartNetwork;
    if WsRelayTarget <> '' then
    begin
      if NetPort = DefaultNetPort then
        NetPort := DefaultWebSocketPort;
      FWsRelay := TQuakeWebSocketRelay.Create(NetPort, RelayTargetHost, RelayTargetPort);
      if not FWsRelay.Valid then
      begin
        FHud.ShowMessage('Cannot open TCP port ' + IntToStr(NetPort) + ' for the WebSocket relay', 3);
        FreeAndNil(FWsRelay);
        FDemo.Finished := True;
      end else
        FHud.ShowMessage('WebSocket relay on TCP port ' + IntToStr(NetPort) + ' for ' + WsRelayTarget +
          ' (Escape quits)', 10);
      Exit;
    end;
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
      if HostBots > 0 then
        ListenServer.AddBots(HostBots, HostSkill);
      if RegisterName <> '' then
        ListenServer.Net.RegisterAt(RegisterHost, RegisterPort, RegisterName);
      if WebSocketPort > 0 then
      begin
        FWsRelay := TQuakeWebSocketRelay.Create(WebSocketPort, '127.0.0.1', NetPort);
        if not FWsRelay.Valid then
          FreeAndNil(FWsRelay);
      end;
      NetHost := '127.0.0.1';
      NetName := '';
      ListenServer.SplitScreen := FSplit;
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
    { The second player joins the same listen server after the first }
    FreeAndNil(FClient2);
    if FSplit then
    begin
      FDemo2.StartNetwork;
      FClient2 := TQuakeNetClient.Create;
      if FClient2.Connect('127.0.0.1', NetPort) then
      begin
        if SplitStacked then
          WritelnLog('GameViewDemo', 'Split-screen: player 2 joins on port %d (one above the other)', [NetPort])
        else
          WritelnLog('GameViewDemo', 'Split-screen: player 2 joins on port %d (side by side)', [NetPort]);
      end else
        FreeAndNil(FClient2);
    end;
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
  if FClient2 <> nil then
  begin
    FClient2.Disconnect;
    FreeAndNil(FClient2);
  end;
  if FSplit then
  begin
    FSplit := False;
    ApplySplitLayout;
  end;
  FreeAndNil(ListenServer);
  FreeAndNil(FRendezvous);
  FreeAndNil(FWsRelay);
  ClearLevel;
  if Sounds <> nil then
    Sounds.StopMusic;
  if Lighting <> nil then
    Lighting.ResetStyles;
  inherited Stop;
end;

function TViewDemo.RelayTargetHost: String;
var
  P: Integer;
begin
  Result := WsRelayTarget;
  P := Pos(':', Result);
  if P > 0 then
    Result := Copy(Result, 1, P - 1);
  if (Result = '') or SameText(Result, 'localhost') then
    Result := '127.0.0.1';
end;

function TViewDemo.RelayTargetPort: Word;
var
  P: Integer;
begin
  Result := DefaultNetPort;
  P := Pos(':', WsRelayTarget);
  if P > 0 then
    Result := StrToIntDef(Copy(WsRelayTarget, P + 1, MaxInt), DefaultNetPort);
end;

function TViewDemo.NetMode: Boolean;
begin
  Result := (NetHost <> '') or (HostMap <> '') or Rendezvous or (WsRelayTarget <> '');
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
  PadForward, PadSide: Single;
begin
  { Weapon changes of the frames in between are kept for the next input }
  if AutoTestPrefix = '' then
  begin
    if GamepadJustPressed(GamepadNextWeapon, PlayerOne) then
      FImpulse := 10;
    if GamepadJustPressed(GamepadPrevWeapon, PlayerOne) then
      FImpulse := 12;
  end;
  { Fast frames add up: the server and the prediction run each input as one
    physics step, which must not be shorter than MinPhysicsStep }
  FInputTime := FInputTime + SecondsPassed;
  if FInputTime * 1000 < MinInputMsec then
    Exit;
  Input := Default(TNetInput);
  Inc(FInputSeq);
  Input.Sequence := FInputSeq;
  Input.Msec := Min(Round(FInputTime * 1000), MaxInputMsec);
  FInputTime := Max(0, FInputTime - Input.Msec / 1000);
  Input.Angles := FDemo.ViewAngles;
  if AutoTestPrefix = '' then
  begin
    if BindingHeld(qbForward, Container, PlayerOne) then
      Input.Move.X := Input.Move.X + ClForwardSpeed;
    if BindingHeld(qbBackward, Container, PlayerOne) then
      Input.Move.X := Input.Move.X - ClBackSpeed;
    if BindingHeld(qbStrafeRight, Container, PlayerOne) then
      Input.Move.Y := Input.Move.Y + ClSideSpeed;
    if BindingHeld(qbStrafeLeft, Container, PlayerOne) then
      Input.Move.Y := Input.Move.Y - ClSideSpeed;
    GamepadMove(PadForward, PadSide, PlayerOne);
    Input.Move.X := Input.Move.X + PadForward * ClForwardSpeed;
    Input.Move.Y := Input.Move.Y + PadSide * ClSideSpeed;
    if BindingHeld(qbWalk, Container, PlayerOne) then
      Input.Move := Input.Move * 0.5;
    if BindingHeld(qbJump, Container, PlayerOne) then
      Input.Buttons := Input.Buttons or nbJump;
    if BindingHeld(qbFire, Container, PlayerOne) then
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

{ The second split-screen player: the gamepad only (the last one connected) }
procedure TViewDemo.SendInput2(const SecondsPassed: Single);
var
  Input: TNetInput;
  PadForward, PadSide: Single;
begin
  if GamepadJustPressed(GamepadNextWeapon, 2) then
    FImpulse2 := 10;
  if GamepadJustPressed(GamepadPrevWeapon, 2) then
    FImpulse2 := 12;
  FInputTime2 := FInputTime2 + SecondsPassed;
  if FInputTime2 * 1000 < MinInputMsec then
    Exit;
  Input := Default(TNetInput);
  Inc(FInputSeq2);
  Input.Sequence := FInputSeq2;
  Input.Msec := Min(Round(FInputTime2 * 1000), MaxInputMsec);
  FInputTime2 := Max(0, FInputTime2 - Input.Msec / 1000);
  Input.Angles := FDemo2.ViewAngles;
  GamepadMove(PadForward, PadSide, 2);
  Input.Move := Vector3(PadForward * ClForwardSpeed, PadSide * ClSideSpeed, 0);
  if BindingHeld(qbJump, nil, 2) then
    Input.Buttons := Input.Buttons or nbJump;
  if BindingHeld(qbFire, nil, 2) then
    Input.Buttons := Input.Buttons or nbFire;
  Input.Impulse := EnsureRange(FImpulse2, 0, 255);
  FImpulse2 := 0;
  FClient2.SendInput(Input);
end;

{ The second player's camera turns with its pad, the server's angles win
  (spawn, teleport), its input goes out and its view follows its entity }
procedure TViewDemo.UpdatePlayer2(const SecondsPassed: Single);
var
  CamDir, Eye, Dir: TVector3;
  Yaw, Pitch, Bob: Single;
  CD: TDemoClientData;
begin
  UpdateGamepad(2);
  GamepadTurnCamera(FCamera2, SecondsPassed, 2);
  CamDir := FCamera2.Direction;
  Yaw := RadToDeg(ArcTan2(-CamDir.Z, CamDir.X));
  Pitch := -RadToDeg(ArcSin(Clamped(CamDir.Y, -1, 1)));
  if FDemo2.AngleFixed then
  begin
    Yaw := FDemo2.ViewAngles.Y;
    Pitch := FDemo2.ViewAngles.X;
    FDemo2.AngleFixed := False;
  end;
  FDemo2.ViewAngles := Vector3(EnsureRange(Pitch, -89, 89), Yaw, 0);
  if (FClient2 <> nil) and (FDemo2.Signon = Signons) then
    SendInput2(SecondsPassed);

  CD := FDemo2.ClientData;
  if (FDemo2.ViewEntity > 0) and (FDemo2.ViewEntity < Length(FDemo2.Entities)) then
    Eye := FDemo2.Entities[FDemo2.ViewEntity].State.Origin + Vector3(0, 0, CD.ViewHeight)
  else
    Eye := TVector3.Zero;
  Pitch := EnsureRange(FDemo2.ViewAngles.X + CD.Punch.X, -89, 89);
  Yaw := FDemo2.ViewAngles.Y;
  Dir := Vector3(Cos(DegToRad(Yaw)) * Cos(DegToRad(Pitch)), Sin(DegToRad(Yaw)) * Cos(DegToRad(Pitch)),
    -Sin(DegToRad(Pitch)));
  if (FDemo2.Intermission = 0) and (FDemo2.ViewEntity > 0) then
    Bob := CalcViewBob(FDemo2.Time, CD.Velocity)
  else
    Bob := 0;
  FCamera2.SetWorldView(QuakeToCge(Eye + Vector3(0, 0, Bob)), QuakeToCge(Dir), Vector3(0, 1, 0));
  FWeaponTransform2.Translation := Vector3(0, 0, -Bob * 0.4);
  UpdateWeapon(FDemo2, FWeapon2, FWeaponTransform2);
end;

{ What the PVS shows, and the entities in it; split-screen: one world for
  two cameras, so what either PVS has }
procedure TViewDemo.UpdateWorldVisibility;
begin
  if FSplit then
    FGeometry.UpdateVisibility2(FViewport.Camera.Translation, FCamera2.Translation)
  else
    FGeometry.UpdateVisibility(FViewport.Camera.Translation);
  CullVisuals;
end;

{ The NC action: this frame drawn with the PVS culling and without it; no
  pixel may differ (in split-screen both views are in the window) }
procedure TViewDemo.ComparePvsRender;
var
  Culled, Full: TRGBImage;
  WasCulling: Boolean;
  X, Y, Differ, Total: Integer;
  A, B: PVector3Byte;
  Status: String;

  function Render(const Culling: Boolean): TRGBImage;
  begin
    WorldPvsCulling := Culling;
    UpdateWorldVisibility;
    if Culling then
      Status := Format('leaves %d and %d, clusters %d/%d, entities %d/%d', [FGeometry.CameraLeaf,
        FGeometry.SecondLeaf, FGeometry.VisibleClusters, FGeometry.ClusterCount, FGeometry.VisibleEntities,
        FGeometry.EntityCount]);
    Result := Container.SaveScreen;
  end;

begin
  if FGeometry = nil then
    Exit;
  WasCulling := WorldPvsCulling;
  Culled := Render(True);
  Full := Render(False);
  try
    { Pixels where a channel differs by more than 24 of 255 }
    Differ := 0;
    Total := Min(Culled.Width, Full.Width) * Min(Culled.Height, Full.Height);
    for Y := 0 to Min(Culled.Height, Full.Height) - 1 do
      for X := 0 to Min(Culled.Width, Full.Width) - 1 do
      begin
        A := Culled.PixelPtr(X, Y);
        B := Full.PixelPtr(X, Y);
        if (Abs(A^.X - B^.X) > 24) or (Abs(A^.Y - B^.Y) > 24) or (Abs(A^.Z - B^.Z) > 24) then
          Inc(Differ);
      end;
    WritelnLog('GameViewDemo', 'PVS compare: %d of %d pixels differ, %s', [Differ, Total, Status]);
    if (Differ > 0) and (AutoTestPrefix <> '') then
    begin
      Inc(FShots);
      {$ifndef WASI}
      SaveImage(Culled, AutoTestPrefix + '_' + IntToStr(FShots) + '_pvs.png');
      SaveImage(Full, AutoTestPrefix + '_' + IntToStr(FShots) + '_full.png');
      {$endif}
    end;
  finally
    Culled.Free;
    Full.Free;
    WorldPvsCulling := WasCulling;
    UpdateWorldVisibility;
  end;
end;

{ Each split-screen view projects the scrolling sky from its own eye }
procedure TViewDemo.ViewportBeforeDraw(Sender: TObject);
begin
  if FSplit and (FGeometry <> nil) then
    FGeometry.SetSkyEye(TCastleViewport(Sender).Camera.Translation);
end;

function TViewDemo.PlayerOne: Integer;
begin
  if FSplit then
    Result := 1
  else
    Result := 0;
end;

{ One viewport over the window, or two: side by side (the first player on
  the left) or one above the other (the first on top), each with its HUD }
procedure TViewDemo.ApplySplitLayout;

  procedure MoveHud(const Hud: TQuakeHud; const NewParent: TCastleUserInterface);
  begin
    if Hud.Parent = NewParent then
      Exit;
    if Hud.Parent <> nil then
      Hud.Parent.RemoveControl(Hud);
    NewParent.InsertFront(Hud);
  end;

begin
  FViewport2.Exists := FSplit;
  FViewport.FullSize := not FSplit;
  if FSplit then
  begin
    FViewport2.FullSize := False;
    if SplitStacked then
    begin
      FViewport.WidthFraction := 1;
      FViewport.HeightFraction := 0.5;
      FViewport.Anchor(hpLeft);
      FViewport.Anchor(vpTop);
      FViewport2.WidthFraction := 1;
      FViewport2.HeightFraction := 0.5;
      FViewport2.Anchor(hpLeft);
      FViewport2.Anchor(vpBottom);
    end else
    begin
      FViewport.WidthFraction := 0.5;
      FViewport.HeightFraction := 1;
      FViewport.Anchor(hpLeft);
      FViewport.Anchor(vpBottom);
      FViewport2.WidthFraction := 0.5;
      FViewport2.HeightFraction := 1;
      FViewport2.Anchor(hpRight);
      FViewport2.Anchor(vpBottom);
    end;
    MoveHud(FHud, FViewport);
  end else
  begin
    FViewport.WidthFraction := 0;
    FViewport.HeightFraction := 0;
    MoveHud(FHud, Self);
    { Back in front of the viewport (the touch controls stay on top) }
    if FTouch <> nil then
    begin
      RemoveControl(FTouch);
      InsertFront(FTouch);
    end;
  end;
  SetLength(FViewport.Hidden, 0);
  SetLength(FViewport2.Hidden, 0);
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
  if FWsRelay <> nil then
    FWsRelay.Update;
  if WsRelayTarget <> '' then
    Exit;
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
  if FClient2 <> nil then
  begin
    FClient2.Update(SecondsPassed);
    while FClient2.PollBlock(Data) do
      FDemo2.PushBlock(Data);
  end;
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

procedure TViewDemo.CullVisuals;
var
  I: Integer;
begin
  for I := 0 to High(FVisuals) do
    if (FVisuals[I].Transform <> nil) and FVisuals[I].Transform.Exists then
      FGeometry.CullScene(FVisuals[I].Scene);
  for I := 0 to High(FStaticVisuals) do
    if (FStaticVisuals[I].Transform <> nil) and FStaticVisuals[I].Transform.Exists then
      FGeometry.CullScene(FStaticVisuals[I].Scene);
  FGeometry.CullSubmodels;
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
  FreeVisual(FWeapon2);
  if FViewport <> nil then
    SetLength(FViewport.Hidden, 0);
  if FViewport2 <> nil then
    SetLength(FViewport2.Hidden, 0);
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
  ApplyWorldFog(FViewport, FGeometry);
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

procedure TViewDemo.ApplyEnvironment;
begin
  { FitzQuake's svc_fog / svc_skybox (and a stuffed fog command) replace the
    map's own worldspawn fog and sky applied when the level was loaded }
  if FDemo.FogChanged then
  begin
    FDemo.FogChanged := False;
    SetViewportFog(FViewport, FDemo.FogDensity, FDemo.FogColor);
    if FDemo.FogDensity <= 0 then
      WritelnLog('GameViewDemo', 'Fog: off');
  end;
  if FDemo.SkyboxChanged then
  begin
    FDemo.SkyboxChanged := False;
    if FGeometry <> nil then
      FGeometry.SetSkybox(FDemo.SkyboxName);
  end;
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
    TE_TAREXPLOSION:
      begin
        Particles.SpawnExplosion(P);
        Lighting.TriggerMuzzleFlash(P, 6.0);
        Sounds.Play('sound/weapons/r_exp3.wav');
      end;
    TE_LAVASPLASH:
      Particles.SpawnLavaSplash(P);
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

procedure TViewDemo.HandleCenterPrint2(const S: String);
begin
  FHud2.ShowMessage(S, 2.5);
end;

procedure TViewDemo.HandleDamage2(const Armor, Blood: Integer; const From: TVector3);
begin
  FHud2.DamageFlash(Armor, Blood);
end;

procedure TViewDemo.HandleIntermission2;
begin
  FHud2.StartIntermission(FDemo2.LevelName, Math.Max(0.0, FDemo2.Time - FLevelStart),
    FDemo2.Stats[STAT_MONSTERS], FDemo2.Stats[STAT_TOTALMONSTERS],
    FDemo2.Stats[STAT_SECRETS], FDemo2.Stats[STAT_TOTALSECRETS]);
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

  { The health and ammo boxes are brush model files (maps/b_*.bsp) }
  if LowerCase(ExtractFileExt(MdlName)) = '.bsp' then
  begin
    if (V.Transform = nil) or (V.ModelIndex <> State.ModelIndex) then
    begin
      FreeVisual(V);
      V.Transform := TCastleTransform.Create(nil);
      V.Transform.Name := ComponentName('entity');
      V.Scene := CreateBspModelScene(MdlName, V.Transform);
      if V.Scene = nil then
      begin
        FreeVisual(V);
        Exit;
      end;
      V.Scene.Name := V.Transform.Name + '_scene';
      V.Scene.Collides := False;
      V.Transform.Add(V.Scene);
      FViewport.Items.Add(V.Transform);
      V.ModelIndex := State.ModelIndex;
    end;
    V.Transform.Exists := True;
    V.Transform.Translation := QuakeToCge(State.Origin);
    Exit;
  end;

  if LowerCase(ExtractFileExt(MdlName)) <> '.mdl' then
  begin
    { Sprites are not drawn }
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

procedure TViewDemo.UpdateWeapon(const Reader: TQuakeDemoReader; var Weapon: TDemoVisual;
  const Holder: TCastleTransform);
var
  MdlName: String;
  Mdl: TQuakeMdl;
  Idx: Integer;
begin
  Idx := Reader.ClientData.Weapon;
  MdlName := Reader.ModelName(Idx);
  if (MdlName = '') or (Reader.Intermission <> 0) or (Reader.ClientData.Health <= 0) then
  begin
    HideVisual(Weapon);
    Exit;
  end;
  Mdl := MdlManager.GetModel(MdlName);
  if Mdl = nil then
  begin
    HideVisual(Weapon);
    Exit;
  end;
  if (Weapon.Transform = nil) or (Weapon.ModelIndex <> Idx) then
  begin
    FreeVisual(Weapon);
    Weapon.Transform := TCastleTransform.Create(nil);
    Weapon.Transform.Name := 'weapon_model';
    Weapon.Scene := Mdl.CreateScene(0);
    Weapon.Scene.Name := 'weapon_model_scene';
    Weapon.Scene.Collides := False;
    Weapon.Transform.Add(Weapon.Scene);
    Holder.Add(Weapon.Transform);
    Weapon.Mdl := Mdl;
    Weapon.ModelIndex := Idx;
    Weapon.Frame := -1;
  end;
  Weapon.Transform.Exists := ShowWeapon;
  if Weapon.Frame <> Reader.ClientData.WeaponFrame then
  begin
    Weapon.Frame := Reader.ClientData.WeaponFrame;
    Mdl.ApplyFrame(Weapon.Scene, EnsureRange(Weapon.Frame, 0, Max(0, Mdl.FrameCount - 1)));
  end;
end;

procedure TViewDemo.UpdateHudStats(const Reader: TQuakeDemoReader; const Hud: TQuakeHud; const Eye: TVector3;
  const Main: Boolean; const SecondsPassed: Single);
var
  S: TQuakePlayerStats;
  Items: Cardinal;
  I: Integer;
const
  WeaponItems: array[1..8] of Cardinal = (IT_AXE, IT_SHOTGUN, IT_SUPER_SHOTGUN, IT_NAILGUN,
    IT_SUPER_NAILGUN, IT_GRENADE_LAUNCHER, IT_ROCKET_LAUNCHER, IT_LIGHTNING);
begin
  S := Default(TQuakePlayerStats);
  Items := Reader.ClientData.Items;
  S.Health := Reader.ClientData.Health;
  S.Armor := Reader.ClientData.Armor;
  if (Items and IT_ARMOR3) <> 0 then
    S.ArmorType := 3
  else if (Items and IT_ARMOR2) <> 0 then
    S.ArmorType := 2
  else if (Items and IT_ARMOR1) <> 0 then
    S.ArmorType := 1;
  S.Ammo := Reader.ClientData.Ammo;
  S.Shells := Reader.ClientData.Shells;
  S.Nails := Reader.ClientData.Nails;
  S.Rockets := Reader.ClientData.Rockets;
  S.Cells := Reader.ClientData.Cells;
  S.MaxShells := 100;
  S.MaxNails := 200;
  S.MaxRockets := 100;
  S.MaxCells := 100;
  for I := 1 to 8 do
  begin
    if (Items and WeaponItems[I]) <> 0 then
      S.WeaponMask := S.WeaponMask or (1 shl I);
    if Cardinal(Reader.ClientData.ActiveWeapon) = WeaponItems[I] then
      S.CurrentWeapon := I;
  end;
  if (Items and IT_KEY1) <> 0 then
    S.Keys := S.Keys or 1;
  if (Items and IT_KEY2) <> 0 then
    S.Keys := S.Keys or 2;
  if (Items and IT_SUIT) <> 0 then
    S.BiosuitTime := 1;
  S.Kills := Reader.Stats[STAT_MONSTERS];
  S.TotalKills := Reader.Stats[STAT_TOTALMONSTERS];
  S.Secrets := Reader.Stats[STAT_SECRETS];
  S.TotalSecrets := Reader.Stats[STAT_TOTALSECRETS];
  S.LevelTime := Math.Max(0.0, Reader.Time - FLevelStart);
  S.AirLeft := 12;
  if FBsp <> nil then
  begin
    I := FBsp.PointContentsCge(Eye);
    Hud.SetContents(I);
    S.Underwater := (I = CONTENTS_WATER) or (I = CONTENTS_SLIME) or (I = CONTENTS_LAVA);
    if Main then
      Sounds.SetUnderwater(S.Underwater);
  end;
  Hud.Update(SecondsPassed, S);
end;

{ Photo mode in demo playback (not in a network game, which goes on): the
  demo stops, the HUD and the weapon hide, the camera flies }
procedure TViewDemo.SetPhotoMode(const On: Boolean);
begin
  if On and NetMode then
    Exit;
  if On = FPhoto.Active then
    Exit;
  if On then
  begin
    FNavigation.Exists := True;
    FPhoto.Enter;
    FHud.Exists := False;
    if FWeaponTransform <> nil then
      FWeaponTransform.Exists := False;
  end else
  begin
    FPhoto.Leave;
    FHud.Exists := True;
    if FWeaponTransform <> nil then
      FWeaponTransform.Exists := True;
    FNavigation.Exists := NetMode;
    FNavigation.MouseLook := NetMode and (AutoTestPrefix = '');
  end;
end;

function TViewDemo.PhotoPrefix: String;
begin
  if AutoTestPrefix <> '' then
    Result := AutoTestPrefix
  else
    Result := 'castle-quake';
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
      { The browser has no files: the screenshot only logs }
      {$ifndef WASI}
      SaveImage(Img, OutPath);
      {$endif}
      Img.Free;
      WritelnLog('GameViewDemo', 'Saved screenshot to "%s" (signon %d, health %d, ammo %d, frags %d, time %.1f)',
        [OutPath, FDemo.Signon, FDemo.ClientData.Health, FDemo.ClientData.Ammo,
         FDemo.Frags[Max(0, FDemo.ViewEntity - 1) mod 16], FDemo.Time]);
      { The view entity's latest position from the server (Quake units) }
      if (FDemo.ViewEntity > 0) and (FDemo.ViewEntity < Length(FDemo.Entities)) then
        WritelnLog('GameViewDemo', 'View entity %d at %.1f %.1f %.1f (protocol %d)',
          [FDemo.ViewEntity, FDemo.Entities[FDemo.ViewEntity].Msg[0].Origin.X,
           FDemo.Entities[FDemo.ViewEntity].Msg[0].Origin.Y, FDemo.Entities[FDemo.ViewEntity].Msg[0].Origin.Z,
           FDemo.Protocol]);
      if FSplit and (FDemo2.ViewEntity > 0) and (FDemo2.ViewEntity < Length(FDemo2.Entities)) then
        WritelnLog('GameViewDemo', 'Player 2: view entity %d at %.1f %.1f %.1f, yaw %.0f, health %d, ammo %d, ' +
          'weapon %d, signon %d, viewports %.0fx%.0f and %.0fx%.0f',
          [FDemo2.ViewEntity, FDemo2.Entities[FDemo2.ViewEntity].Msg[0].Origin.X,
           FDemo2.Entities[FDemo2.ViewEntity].Msg[0].Origin.Y, FDemo2.Entities[FDemo2.ViewEntity].Msg[0].Origin.Z,
           FDemo2.ViewAngles.Y, FDemo2.ClientData.Health, FDemo2.ClientData.Ammo, FDemo2.ClientData.ActiveWeapon,
           FDemo2.Signon, FViewport.EffectiveWidth, FViewport.EffectiveHeight,
           FViewport2.EffectiveWidth, FViewport2.EffectiveHeight]);
      if FSplit and (FGeometry <> nil) then
        WritelnLog('GameViewDemo', 'Split-screen PVS: leaves %d and %d, %d of %d clusters, %d of %d entities drawn',
          [FGeometry.CameraLeaf, FGeometry.SecondLeaf, FGeometry.VisibleClusters, FGeometry.ClusterCount,
           FGeometry.VisibleEntities, FGeometry.EntityCount]);
      if FWsRelay <> nil then
        WritelnLog('GameViewDemo', 'WebSocket relay: %d clients, %d messages in, %d out',
          [FWsRelay.ClientCount, FWsRelay.MessagesIn, FWsRelay.MessagesOut]);
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
    else if Action = 'NC' then
      ComparePvsRender
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
    if (Action = 'GL') or (Action = 'GR') then
    begin
      { The virtual gamepad (in split-screen the second player's): sticks
        x;y in -1..1, the right trigger, a button pressed for 0.2 s }
      Parts := Param.Split([';']);
      if Length(Parts) >= 2 then
      begin
        if Action = 'GL' then
          FPadLeft := Vector2(StrToFloatDef(Parts[0], 0), StrToFloatDef(Parts[1], 0))
        else
          FPadRight := Vector2(StrToFloatDef(Parts[0], 0), StrToFloatDef(Parts[1], 0));
        SetVirtualSticks(FPadLeft, FPadRight);
      end;
    end else
    if Action = 'GT' then
      SetVirtualRightTrigger(StrToFloatDef(Param, 0))
    else
    if Action = 'GB' then
    begin
      if GamepadButtonByName(Param, FPadButton) then
      begin
        SetVirtualButton(FPadButton, True);
        FPadRelease := 0.2;
      end else
        WritelnWarning('GameViewDemo', 'Unknown gamepad button "%s"', [Param]);
    end else
    if Action = 'PN' then
      SetVirtualPadName(Param)
    else
    if Action = 'CMD' then
    begin
      { Photo mode's console commands: photo [0|1], photo_fov, photo_effect,
        photo_scale, photo_shot }
      P := Pos(' ', Param);
      if P = 0 then
        P := Length(Param) + 1;
      if Copy(Param, 1, P - 1) = 'photo' then
        SetPhotoMode(Trim(Copy(Param, P + 1, MaxInt)) <> '0')
      else
        FPhoto.Command(Copy(Param, 1, P - 1), Trim(Copy(Param, P + 1, MaxInt)), PhotoPrefix);
    end else
    if (Action = 'M') and FPhoto.Active then
      FViewport.Camera.Translation := FViewport.Camera.Translation +
        FViewport.Camera.Direction * StrToFloatDef(Param, 50)
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
  if FClient2 <> nil then
    FClient2.Disconnect;
  if AutoTestPrefix <> '' then
    Application.Terminate
  else
    Container.View := ViewMenu;
end;

procedure TViewDemo.Update(const SecondsPassed: Single; var HandleInput: Boolean);
var
  I, J: Integer;
  Eye, Dir, CamDir: TVector3;
  Pitch, Yaw, Bob: Single;
  CD: TDemoClientData;
  Cmd: String;
begin
  inherited Update(SecondsPassed, HandleInput);
  ApplyVideoSettings(FViewport);
  if FSplit then
    ApplyVideoSettings(FViewport2);
  FPhoto.ApplyView;
  if FPadRelease > 0 then
  begin
    FPadRelease := FPadRelease - SecondsPassed;
    if FPadRelease <= 0 then
      SetVirtualButton(FPadButton, False);
  end;

  if FScript.Count > 0 then
    RunScript(SecondsPassed);

  { Photo mode: the demo waits; B or View leaves, A takes a photo }
  if FPhoto.Active then
  begin
    FTouch.UpdateShown(False);
    UpdateGamepad;
    FPhoto.Update(SecondsPassed);
    if GamepadJustPressed(GamepadBackButton) or GamepadJustPressed(gbView) then
      SetPhotoMode(False)
    else if GamepadJustPressed(GamepadConfirmButton) then
      FPhoto.TakePhoto(FPhoto.NextPhotoName(PhotoPrefix));
    Exit;
  end;
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
  if FSplit then
    FDemo2.Advance(SecondsPassed);
  if not FLoaded then
    Exit;
  ApplyEnvironment;
  if (FLevelStart < 0) and (FDemo.Signon = Signons) then
    FLevelStart := FDemo.Time;

  { Touch controls only in a network game; their menu button leaves it }
  FTouch.UpdateShown(NetMode);
  if NetMode and TouchControlsWanted and FNavigation.MouseLook then
    FNavigation.MouseLook := False;
  if FTouch.MenuRequested then
  begin
    Leave;
    Exit;
  end;

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
    UpdateGamepad(PlayerOne);
    if AutoTestPrefix = '' then
      GamepadTurnCamera(FViewport.Camera, SecondsPassed, PlayerOne);
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
    if FDemo.EntityVisible(I) and ((I <> FDemo.ViewEntity) or FSplit) then
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
  { V_CalcBob from the recorded velocity: the eye and, forward, the weapon }
  if (FDemo.Intermission = 0) and (FDemo.ViewEntity > 0) then
    Bob := CalcViewBob(FDemo.Time, CD.Velocity)
  else
    Bob := 0;
  FViewport.Camera.SetWorldView(QuakeToCge(Eye + Vector3(0, 0, Bob)), QuakeToCge(Dir), Vector3(0, 1, 0));
  if FWeaponTransform <> nil then
    FWeaponTransform.Translation := Vector3(0, 0, -Bob * 0.4);
  UpdateWeapon(FDemo, FWeapon, FWeaponTransform);
  if FSplit then
    UpdatePlayer2(SecondsPassed);

  for I := 0 to High(FBeams) do
    if FBeams[I].Time > 0 then
    begin
      FBeams[I].Time := FBeams[I].Time - SecondsPassed;
      if FBeams[I].Time <= 0 then
        for J := 0 to High(FBeams[I].Segments) do
          FBeams[I].Segments[J].Exists := False;
    end;

  FGeometry.Update(SecondsPassed, FViewport.Camera.Translation);
  UpdateWorldVisibility;
  FAmbient.Update(SecondsPassed, FViewport.Camera.Translation);
  Particles.Update(SecondsPassed);
  Lighting.Update(SecondsPassed, FViewport.Camera.Translation);
  UpdateHudStats(FDemo, FHud, FViewport.Camera.Translation, True, SecondsPassed);
  if FSplit then
  begin
    UpdateHudStats(FDemo2, FHud2, FCamera2.Translation, False, SecondsPassed);
    FViewport2.Fog := FViewport.Fog;
    FViewport2.Background := FViewport.Background;
    { Each view hides its own player's body and the other's weapon }
    SetLength(FViewport.Hidden, 2);
    FViewport.Hidden[0] := FWeaponTransform2;
    FViewport.Hidden[1] := VisualTransform(FDemo.ViewEntity);
    SetLength(FViewport2.Hidden, 2);
    FViewport2.Hidden[0] := FWeaponTransform;
    FViewport2.Hidden[1] := VisualTransform(FDemo2.ViewEntity);
  end;
end;

function TViewDemo.VisualTransform(const Entity: Integer): TCastleTransform;
begin
  if (Entity > 0) and (Entity <= High(FVisuals)) then
    Result := FVisuals[Entity].Transform
  else
    Result := nil;
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
      if BindingEvent(TQuakeBinding(Ord(qbWeapon1) + I - 1), Event) then
      begin
        FImpulse := I;
        Exit(True);
      end;
    if BindingEvent(qbNextWeapon, Event) then
    begin
      FImpulse := 10;
      Exit(True);
    end;
    if BindingEvent(qbPrevWeapon, Event) then
    begin
      FImpulse := 12;
      Exit(True);
    end;
    if BindingEvent(qbScreenshot, Event) then
    begin
      CaptureScreenshot;
      Exit(True);
    end;
    Exit;
  end;
  { Photo mode: P (the photo binding) in a demo; Escape or P leaves it,
    Enter or the screenshot binding takes a photo }
  if FPhoto.Active then
  begin
    if Event.IsKey(keyEscape) or BindingEvent(qbPhotoMode, Event) then
      SetPhotoMode(False)
    else if Event.IsKey(keyEnter) or BindingEvent(qbScreenshot, Event) then
      FPhoto.TakePhoto(FPhoto.NextPhotoName(PhotoPrefix))
    else
      Exit(FPhoto.Press(Event));
    Exit(True);
  end;
  if BindingEvent(qbPhotoMode, Event) then
  begin
    SetPhotoMode(True);
    Exit(True);
  end;
  if Event.IsKey(keyEscape) or Event.IsKey(keyEnter) or Event.IsKey(keySpace) then
  begin
    Leave;
    Exit(True);
  end;
end;

end.
