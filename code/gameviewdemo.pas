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

  { A further split-screen player (2..4): its own client and demo reader,
    a camera in its own viewport sharing the first one's world, a HUD and
    a weapon; the entities and sounds come from the first player's client }
  TSplitPlayer = class
  public
    Index: Integer;
    Viewport: TSplitViewport;
    Camera: TCastleCamera;
    Hud: TQuakeHud;
    WeaponTransform: TCastleTransform;
    Weapon: TDemoVisual;
    Client: TQuakeNetClient;
    Demo: TQuakeDemoReader;
    InputSeq: Word;
    InputTime: Single;
    Impulse: Integer;
    LevelStart: Single;
    constructor Create(const AIndex: Integer);
    destructor Destroy; override;
    procedure HandleCenterPrint(const S: String);
    procedure HandleDamage(const Armor, Blood: Integer; const From: TVector3);
    procedure HandleIntermission;
  end;

const
  MaxSplitPlayers = 4;

type
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
    { Split-screen: FSplitCount local players (2..4), the further ones in
      FPlayers; the first player's client gets every entity from the
      listen server, and the world drawn once serves all the views }
    FSplit: Boolean;
    FSplitCount: Integer;
    FPlayers: array[2..MaxSplitPlayers] of TSplitPlayer;
    { The pads' Start of the last frame: a pad without a player joins }
    FPadMenuDown: array[0..7] of Boolean;
    { The virtual gamepad of the script (GL, GR, GT, GB) }
    FPadLeft, FPadRight: TVector2;
    FPadButton: TGameControllerButton;
    FPadRelease: Single;
    { Autotest: W:sec, S (screenshot), Q }
    FScript: TStringList;
    FScriptIndex: Integer;
    FScriptTimer: Single;
    FShots: Integer;
    { Demo playback: paused, its speed, the playback clock (seconds of the
      demo played, FDemoLength for all of it) and a seek in progress
      (events muted) }
    FDemoPaused, FSeeking: Boolean;
    FDemoSpeed, FPlayClock, FDemoLength: Single;
    { Spectator: flying freely (else at the followed player's eyes), the
      free camera's eye (Quake units) and move, the jump of the last input,
      the entity followed last (for the message) }
    FSpecFree, FSpecJump: Boolean;
    FFlyEye, FSpecMove: TVector3;
    FSpecFollowed: Integer;
    procedure ClearLevel;
    { Demo playback controls }
    procedure MeasureDemoLength;
    procedure SeekDemo(const Target: Single);
    procedure SetDemoSpeed(const Speed: Single);
    procedure ToggleDemoPause;
    procedure ShowDemoStatus;
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
    procedure UpdateSplitPlayer(const P: TSplitPlayer; const SecondsPassed: Single);
    procedure SendSplitInput(const P: TSplitPlayer; const SecondsPassed: Single);
    { Connect the further players 2..FSplitCount that have no client yet }
    procedure ConnectSplitPlayers;
    { A pad without a player pressed Start: one more player (up to 4) }
    procedure JoinFromPads;
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
    { Join the network game as a spectator (-spectate): no player of its
      own; fire follows the next player, jump flies freely or follows again }
    Spectate: Boolean;
    { How many local players split-screen starts with (2..4; more join
      with Start on a further pad) }
    SplitPlayers: Integer;

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
  CastleRectangles, CastleGameControllers, GameViewMenu, GameTranslate;

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

{ TSplitPlayer }

constructor TSplitPlayer.Create(const AIndex: Integer);
begin
  inherited Create;
  Index := AIndex;
end;

destructor TSplitPlayer.Destroy;
begin
  if Client <> nil then
    Client.Disconnect;
  FreeAndNil(Client);
  FreeAndNil(Demo);
  inherited Destroy;
end;

procedure TSplitPlayer.HandleCenterPrint(const S: String);
begin
  Hud.ShowMessage(S, 2.5);
end;

procedure TSplitPlayer.HandleDamage(const Armor, Blood: Integer; const From: TVector3);
begin
  Hud.DamageFlash(Armor, Blood);
end;

procedure TSplitPlayer.HandleIntermission;
begin
  Hud.StartIntermission(Demo.LevelName, Math.Max(0.0, Demo.Time - LevelStart),
    Demo.Stats[STAT_MONSTERS], Demo.Stats[STAT_TOTALMONSTERS],
    Demo.Stats[STAT_SECRETS], Demo.Stats[STAT_TOTALSECRETS]);
end;

constructor TViewDemo.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Predict := True;
  SplitPlayers := 2;
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
var
  I: Integer;
begin
  ClearLevel;
  FDemo.Free;
  for I := 2 to MaxSplitPlayers do
    FreeAndNil(FPlayers[I]);
  FAmbient.Free;
  FScript.Free;
  inherited Destroy;
end;

procedure TViewDemo.Start;
var
  I: Integer;
  Cmd: String;
  P: TSplitPlayer;
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

    { The further split-screen views: each its own camera in the same
      world, a weapon and a HUD }
    FViewport.OnBeforeDraw := @ViewportBeforeDraw;
    for I := 2 to MaxSplitPlayers do
    begin
      P := TSplitPlayer.Create(I);
      FPlayers[I] := P;
      P.Viewport := TSplitViewport.Create(Self);
      P.Viewport.Name := 'viewport' + IntToStr(I);
      P.Viewport.Transparent := False;
      P.Viewport.BackgroundColor := FViewport.BackgroundColor;
      P.Viewport.Exists := False;
      P.Viewport.OnBeforeDraw := @ViewportBeforeDraw;
      P.Camera := TCastleCamera.Create(Self);
      P.Camera.Name := 'camera' + IntToStr(I);
      P.Camera.ProjectionNear := 1.0;
      FViewport.Items.Add(P.Camera);
      P.Viewport.Items := FViewport.Items;
      P.Viewport.Camera := P.Camera;
      InsertFront(P.Viewport);
      P.WeaponTransform := TCastleTransform.Create(Self);
      P.WeaponTransform.Name := 'view_weapon' + IntToStr(I);
      P.WeaponTransform.Rotation := Vector4(0, 1, 0, Pi / 2);
      P.Camera.Add(P.WeaponTransform);
      P.Hud := TQuakeHud.Create(Self);
      P.Hud.Name := 'hud' + IntToStr(I);
      P.Viewport.InsertFront(P.Hud);
    end;

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
  if FSplit then
    FSplitCount := EnsureRange(SplitPlayers, 2, MaxSplitPlayers)
  else
    FSplitCount := 1;
  SplitPlayerCount := Max(2, FSplitCount);
  FillChar(FPadMenuDown, SizeOf(FPadMenuDown), 0);
  ApplySplitLayout;
  for I := 2 to MaxSplitPlayers do
  begin
    FPlayers[I].Hud.StopIntermission;
    FPlayers[I].Hud.CrosshairVisible := True;
    FPlayers[I].Impulse := 0;
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
    FClient.Spectator := Spectate;
    FSpecFree := False;
    FSpecJump := False;
    FSpecFollowed := 0;
    FSpecMove := TVector3.Zero;
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
    { The further players join the same listen server after the first }
    for I := 2 to MaxSplitPlayers do
      FreeAndNil(FPlayers[I].Client);
    ConnectSplitPlayers;
  end else
  begin
    FDemoPaused := False;
    FSeeking := False;
    FDemoSpeed := 1;
    FPlayClock := 0;
    FDemoLength := 0;
    if not FDemo.Load(DemoName) then
    begin
      FHud.ShowMessage('Cannot play demo ' + DemoName, 3);
      FDemo.Finished := True;
    end else
      MeasureDemoLength;
  end;
end;

procedure TViewDemo.Stop;
var
  I: Integer;
begin
  if FClient <> nil then
  begin
    FClient.Disconnect;
    FreeAndNil(FClient);
  end;
  for I := 2 to MaxSplitPlayers do
    if (FPlayers[I] <> nil) and (FPlayers[I].Client <> nil) then
    begin
      FPlayers[I].Client.Disconnect;
      FreeAndNil(FPlayers[I].Client);
    end;
  if FSplit then
  begin
    FSplit := False;
    FSplitCount := 1;
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
  if Spectate then
  begin
    { Jump (pressed) flies freely or goes back to following; fire goes to
      the server, which follows the next player (and the camera with it) }
    if ((Input.Buttons and nbJump) <> 0) and not FSpecJump then
    begin
      FSpecFree := not FSpecFree;
      if FSpecFree then
        FFlyEye := CgeToQuake(FViewport.Camera.Translation);
      WritelnLog('GameViewDemo', 'Spectator: %s', [BoolToStr(FSpecFree, 'flying freely', 'following again')]);
    end;
    FSpecJump := (Input.Buttons and nbJump) <> 0;
    if (Input.Buttons and nbFire) <> 0 then
      FSpecFree := False;
    FSpecMove := Input.Move;
    FClient.SendInput(Input);
    Exit;
  end;
  FClient.SendInput(Input);
  PredictInput(Input, SecondsPassed);
end;

{ A further split-screen player: its gamepad only (GameInput's player Index) }
procedure TViewDemo.SendSplitInput(const P: TSplitPlayer; const SecondsPassed: Single);
var
  Input: TNetInput;
  PadForward, PadSide: Single;
begin
  if GamepadJustPressed(GamepadNextWeapon, P.Index) then
    P.Impulse := 10;
  if GamepadJustPressed(GamepadPrevWeapon, P.Index) then
    P.Impulse := 12;
  P.InputTime := P.InputTime + SecondsPassed;
  if P.InputTime * 1000 < MinInputMsec then
    Exit;
  Input := Default(TNetInput);
  Inc(P.InputSeq);
  Input.Sequence := P.InputSeq;
  Input.Msec := Min(Round(P.InputTime * 1000), MaxInputMsec);
  P.InputTime := Max(0, P.InputTime - Input.Msec / 1000);
  Input.Angles := P.Demo.ViewAngles;
  GamepadMove(PadForward, PadSide, P.Index);
  Input.Move := Vector3(PadForward * ClForwardSpeed, PadSide * ClSideSpeed, 0);
  if BindingHeld(qbJump, nil, P.Index) then
    Input.Buttons := Input.Buttons or nbJump;
  if BindingHeld(qbFire, nil, P.Index) then
    Input.Buttons := Input.Buttons or nbFire;
  Input.Impulse := EnsureRange(P.Impulse, 0, 255);
  P.Impulse := 0;
  P.Client.SendInput(Input);
end;

{ A further player's camera turns with its pad, the server's angles win
  (spawn, teleport), its input goes out and its view follows its entity }
procedure TViewDemo.UpdateSplitPlayer(const P: TSplitPlayer; const SecondsPassed: Single);
var
  CamDir, Eye, Dir: TVector3;
  Yaw, Pitch, Bob: Single;
  CD: TDemoClientData;
  D: TQuakeDemoReader;
begin
  D := P.Demo;
  UpdateGamepad(P.Index);
  GamepadTurnCamera(P.Camera, SecondsPassed, P.Index);
  CamDir := P.Camera.Direction;
  Yaw := RadToDeg(ArcTan2(-CamDir.Z, CamDir.X));
  Pitch := -RadToDeg(ArcSin(Clamped(CamDir.Y, -1, 1)));
  if D.AngleFixed then
  begin
    Yaw := D.ViewAngles.Y;
    Pitch := D.ViewAngles.X;
    D.AngleFixed := False;
  end;
  D.ViewAngles := Vector3(EnsureRange(Pitch, -89, 89), Yaw, 0);
  if (P.Client <> nil) and (D.Signon = Signons) then
    SendSplitInput(P, SecondsPassed);

  CD := D.ClientData;
  if (D.ViewEntity > 0) and (D.ViewEntity < Length(D.Entities)) then
    Eye := D.Entities[D.ViewEntity].State.Origin + Vector3(0, 0, CD.ViewHeight)
  else
    Eye := TVector3.Zero;
  Pitch := EnsureRange(D.ViewAngles.X + CD.Punch.X, -89, 89);
  Yaw := D.ViewAngles.Y;
  Dir := Vector3(Cos(DegToRad(Yaw)) * Cos(DegToRad(Pitch)), Sin(DegToRad(Yaw)) * Cos(DegToRad(Pitch)),
    -Sin(DegToRad(Pitch)));
  if (D.Intermission = 0) and (D.ViewEntity > 0) then
    Bob := CalcViewBob(D.Time, CD.Velocity)
  else
    Bob := 0;
  P.Camera.SetWorldView(QuakeToCge(Eye + Vector3(0, 0, Bob)), QuakeToCge(Dir), Vector3(0, 1, 0));
  P.WeaponTransform.Translation := Vector3(0, 0, -Bob * 0.4);
  UpdateWeapon(D, P.Weapon, P.WeaponTransform);
end;

{ What the PVS shows, and the entities in it; split-screen: one world for
  every camera, so what any of their PVS has }
procedure TViewDemo.UpdateWorldVisibility;
var
  Eyes: array of TVector3;
  I: Integer;
begin
  if FSplit then
  begin
    Eyes := nil;
    SetLength(Eyes, FSplitCount);
    Eyes[0] := FViewport.Camera.Translation;
    for I := 2 to FSplitCount do
      Eyes[I - 1] := FPlayers[I].Camera.Translation;
    FGeometry.UpdateVisibilityAll(Eyes);
  end else
    FGeometry.UpdateVisibility(FViewport.Camera.Translation);
  CullVisuals;
end;

{ The NC action: this frame drawn with the PVS culling and without it; no
  pixel may differ but a lone one in a crack between faces (in
  split-screen every view is in the window) }
procedure TViewDemo.ComparePvsRender;
var
  Culled, Full: TRGBImage;
  WasCulling: Boolean;
  Differ, Total, Alone: Integer;
  Status: String;

  function Render(const Culling: Boolean): TRGBImage;
  begin
    WorldPvsCulling := Culling;
    UpdateWorldVisibility;
    if Culling then
      Status := Format('leaves %d and %d, clusters %d/%d, entities %d/%d, %d views', [FGeometry.CameraLeaf,
        FGeometry.SecondLeaf, FGeometry.VisibleClusters, FGeometry.ClusterCount, FGeometry.VisibleEntities,
        FGeometry.EntityCount, FSplitCount]);
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
    Total := Min(Culled.Width, Full.Width) * Min(Culled.Height, Full.Height);
    Differ := ComparePvsImages(Culled, Full, Alone);
    WritelnLog('GameViewDemo', 'PVS compare: %d of %d pixels differ (%d alone), %s', [Differ, Total, Alone, Status]);
    if (Differ > 0) and (AutoTestPrefix <> '') then
    begin
      { Named after the next screenshot, whose number stays the same }
      {$ifndef WASI}
      SaveImage(Culled, AutoTestPrefix + '_' + IntToStr(FShots + 1) + '_pvs.png');
      SaveImage(Full, AutoTestPrefix + '_' + IntToStr(FShots + 1) + '_full.png');
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

function SplitLayoutName(const Count: Integer; const Stacked: Boolean): String;
begin
  case Count of
    2: if Stacked then
         Result := 'one above the other'
       else
         Result := 'side by side';
    3: Result := 'one on top, two below';
    else
      Result := 'a 2 x 2 grid';
  end;
end;

{ One viewport over the window, or one per player: two side by side (the
  first player on the left) or one above the other (the first on top),
  three with the first on top and two below, four in a 2 x 2 grid; each
  view has its HUD }
procedure TViewDemo.ApplySplitLayout;

  procedure MoveHud(const Hud: TQuakeHud; const NewParent: TCastleUserInterface);
  begin
    if Hud.Parent = NewParent then
      Exit;
    if Hud.Parent <> nil then
      Hud.Parent.RemoveControl(Hud);
    NewParent.InsertFront(Hud);
  end;

  procedure Place(const V: TSplitViewport; const W, H: Single; const HP: THorizontalPosition;
    const VP: TVerticalPosition);
  begin
    V.FullSize := False;
    V.WidthFraction := W;
    V.HeightFraction := H;
    V.Anchor(HP);
    V.Anchor(VP);
  end;

var
  I: Integer;
begin
  { At program exit Stop can come after the destructor freed the players }
  if (FViewport = nil) or (FPlayers[2] = nil) then
    Exit;
  for I := 2 to MaxSplitPlayers do
  begin
    FPlayers[I].Viewport.Exists := FSplit and (I <= FSplitCount);
    SetLength(FPlayers[I].Viewport.Hidden, 0);
  end;
  FViewport.FullSize := not FSplit;
  if FSplit then
  begin
    case FSplitCount of
      2: if SplitStacked then
         begin
           Place(FViewport, 1, 0.5, hpLeft, vpTop);
           Place(FPlayers[2].Viewport, 1, 0.5, hpLeft, vpBottom);
         end else
         begin
           Place(FViewport, 0.5, 1, hpLeft, vpBottom);
           Place(FPlayers[2].Viewport, 0.5, 1, hpRight, vpBottom);
         end;
      3: begin
           Place(FViewport, 1, 0.5, hpLeft, vpTop);
           Place(FPlayers[2].Viewport, 0.5, 0.5, hpLeft, vpBottom);
           Place(FPlayers[3].Viewport, 0.5, 0.5, hpRight, vpBottom);
         end;
      else
        begin
          Place(FViewport, 0.5, 0.5, hpLeft, vpTop);
          Place(FPlayers[2].Viewport, 0.5, 0.5, hpRight, vpTop);
          Place(FPlayers[3].Viewport, 0.5, 0.5, hpLeft, vpBottom);
          Place(FPlayers[4].Viewport, 0.5, 0.5, hpRight, vpBottom);
        end;
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
end;

procedure TViewDemo.ConnectSplitPlayers;
var
  I: Integer;
  P: TSplitPlayer;
begin
  if not FSplit then
    Exit;
  for I := 2 to FSplitCount do
  begin
    P := FPlayers[I];
    if P.Client <> nil then
      Continue;
    P.Demo.Free;
    P.Demo := TQuakeDemoReader.Create;
    P.Demo.OnCenterPrint := @P.HandleCenterPrint;
    P.Demo.OnDamage := @P.HandleDamage;
    P.Demo.OnIntermission := @P.HandleIntermission;
    P.Demo.StartNetwork;
    P.InputSeq := 0;
    P.InputTime := 0;
    P.LevelStart := FLevelStart;
    P.Client := TQuakeNetClient.Create;
    if P.Client.Connect('127.0.0.1', NetPort) then
      WritelnLog('GameViewDemo', 'Split-screen: player %d joins on port %d (%s)',
        [I, NetPort, SplitLayoutName(FSplitCount, SplitStacked)])
    else
      FreeAndNil(P.Client);
  end;
end;

procedure TViewDemo.JoinFromPads;
var
  I: Integer;
  Down: Boolean;
begin
  for I := 0 to Min(Controllers.Count, Length(FPadMenuDown)) - 1 do
  begin
    Down := Controllers[I].Pressed[gbMenu];
    if Down and not FPadMenuDown[I] and (PadPlayer(I) = 0) and (FSplitCount < MaxSplitPlayers) then
    begin
      Inc(FSplitCount);
      SplitPlayerCount := FSplitCount;
      WritelnLog('GameViewDemo', 'Split-screen: pad %d (%s) pressed Start: player %d', [I, Controllers[I].Name,
        FSplitCount]);
      ApplySplitLayout;
      ConnectSplitPlayers;
    end;
    FPadMenuDown[I] := Down;
  end;
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
  Result := Predict and not Spectate and FPredictValid and (FPredict <> nil) and (FDemo.ClientData.Health > 0) and
    (FDemo.Intermission = 0);
end;

procedure TViewDemo.UpdateNetwork(const SecondsPassed: Single);
var
  Data: TNetBytes;
  I: Integer;
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
  for I := 2 to FSplitCount do
    if FPlayers[I].Client <> nil then
    begin
      FPlayers[I].Client.Update(SecondsPassed);
      while FPlayers[I].Client.PollBlock(Data) do
        FPlayers[I].Demo.PushBlock(Data);
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
  for I := 2 to MaxSplitPlayers do
    if FPlayers[I] <> nil then
    begin
      FreeVisual(FPlayers[I].Weapon);
      if FPlayers[I].Viewport <> nil then
        SetLength(FPlayers[I].Viewport.Hidden, 0);
    end;
  if FViewport <> nil then
    SetLength(FViewport.Hidden, 0);
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
  { A seek reads ahead without sounds and effects }
  if FSeeking then
    Exit;
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
  { A seek reads ahead without sounds and effects }
  if FSeeking then
    Exit;
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
  { A seek reads ahead without sounds and effects }
  if FSeeking then
    Exit;
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
  { A seek reads ahead without sounds and effects }
  if FSeeking then
    Exit;
  WritelnLog('Demo', Trim(S));
end;

procedure TViewDemo.HandleCenterPrint(const S: String);
begin
  { A seek reads ahead without sounds and effects }
  if FSeeking then
    Exit;
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
  { A seek reads ahead without sounds and effects }
  if FSeeking then
    Exit;
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
  I: Integer;
  D: TQuakeDemoReader;
  Eye: TVector3;
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
      if Spectate then
      begin
        Eye := CgeToQuake(FViewport.Camera.Translation);
        if FSpecFree then
          WritelnLog('GameViewDemo', 'Spectator: flying freely, eye at %.1f %.1f %.1f', [Eye.X, Eye.Y, Eye.Z])
        else
          WritelnLog('GameViewDemo', 'Spectator: following entity %d, eye at %.1f %.1f %.1f',
            [FDemo.ViewEntity, Eye.X, Eye.Y, Eye.Z]);
      end;
      { The further players: their entity, and the first view's and their own size }
      for I := 2 to FSplitCount do
      begin
        D := FPlayers[I].Demo;
        if (D <> nil) and (D.ViewEntity > 0) and (D.ViewEntity < Length(D.Entities)) then
          WritelnLog('GameViewDemo', 'Player %d: view entity %d at %.1f %.1f %.1f, yaw %.0f, health %d, ammo %d, ' +
            'weapon %d, signon %d, viewports %.0fx%.0f and %.0fx%.0f',
            [I, D.ViewEntity, D.Entities[D.ViewEntity].Msg[0].Origin.X,
             D.Entities[D.ViewEntity].Msg[0].Origin.Y, D.Entities[D.ViewEntity].Msg[0].Origin.Z,
             D.ViewAngles.Y, D.ClientData.Health, D.ClientData.Ammo, D.ClientData.ActiveWeapon,
             D.Signon, FViewport.EffectiveWidth, FViewport.EffectiveHeight,
             FPlayers[I].Viewport.EffectiveWidth, FPlayers[I].Viewport.EffectiveHeight]);
      end;
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
    if Action = 'PADS' then { How many virtual pads (split-screen players) }
      SetVirtualPadCount(StrToIntDef(Param, 1))
    else
    if Action = 'PAD' then { The virtual pad GL, GR, GT and GB drive }
    begin
      VirtualPadIndex := EnsureRange(StrToIntDef(Param, 0), 0, Max(0, Controllers.Count - 1));
      FPadLeft := TVector2.Zero;
      FPadRight := TVector2.Zero;
    end else
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
    if Action = 'DP' then { Demo playback: pause / go on }
      ToggleDemoPause
    else
    if Action = 'DS' then { Demo playback speed }
      SetDemoSpeed(StrToFloatDef(Param, 1))
    else
    if Action = 'DK' then { Seek: to a second of the demo, or +N / -N from here }
    begin
      if (Param <> '') and (Param[1] in ['+', '-']) then
        SeekDemo(FPlayClock + StrToFloatDef(Param, 0))
      else
        SeekDemo(StrToFloatDef(Param, 0));
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
var
  I: Integer;
begin
  if FClient <> nil then
    FClient.Disconnect;
  for I := 2 to FSplitCount do
    if FPlayers[I].Client <> nil then
      FPlayers[I].Client.Disconnect;
  if AutoTestPrefix <> '' then
    Application.Terminate
  else
    Container.View := ViewMenu;
end;

procedure TViewDemo.Update(const SecondsPassed: Single; var HandleInput: Boolean);
var
  I, J, N: Integer;
  Dt: Single;
  Eye, Dir, CamDir: TVector3;
  Pitch, Yaw, Bob: Single;
  CD: TDemoClientData;
  Cmd: String;
  P: TSplitPlayer;
begin
  inherited Update(SecondsPassed, HandleInput);
  ApplyVideoSettings(FViewport);
  for I := 2 to FSplitCount do
    ApplyVideoSettings(FPlayers[I].Viewport);
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

  { A demo plays at its speed (0 while paused) }
  Dt := SecondsPassed;
  if not NetMode then
  begin
    UpdateGamepad;
    if GamepadJustPressed(GamepadConfirmButton) then
      ToggleDemoPause
    else if GamepadJustPressed(gbLeftBumper) then
      SeekDemo(FPlayClock - 10)
    else if GamepadJustPressed(gbRightBumper) then
      SeekDemo(FPlayClock + 10)
    else if GamepadJustPressed(gbDPadUp) then
      SetDemoSpeed(FDemoSpeed * 2)
    else if GamepadJustPressed(gbDPadDown) then
      SetDemoSpeed(FDemoSpeed / 2);
    if FDemoPaused then
      Dt := 0
    else
      Dt := SecondsPassed * FDemoSpeed;
    FPlayClock := FPlayClock + Dt;
  end;
  FDemo.Advance(Dt);
  for I := 2 to FSplitCount do
    if FPlayers[I].Demo <> nil then
      FPlayers[I].Demo.Advance(Dt);
  if not FLoaded then
    Exit;
  ApplyEnvironment;
  if (FLevelStart < 0) and (FDemo.Signon = Signons) then
  begin
    FLevelStart := FDemo.Time;
    for I := 2 to MaxSplitPlayers do
      FPlayers[I].LevelStart := FLevelStart;
  end;

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
    UpdateGamepad(PlayerOne);
    if AutoTestPrefix = '' then
      GamepadTurnCamera(FViewport.Camera, SecondsPassed, PlayerOne);
    if FDemo.Signon = Signons then
    begin
      ReconcilePrediction;
      SendInput(SecondsPassed);
    end;
    { A script's jump and fire count down after an input took them, so a
      slow frame does not lose them }
    FScriptJump := Math.Max(0.0, FScriptJump - SecondsPassed);
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
    if FDemo.EntityVisible(I) and ((I <> FDemo.ViewEntity) or FSplit or (Spectate and FSpecFree)) then
      ShowVisual(FVisuals[I], FDemo.Entities[I].State, Dt)
    else
      HideVisual(FVisuals[I]);
  for I := 1 to High(FSubmodels) do
    if (FSubmodels[I] <> nil) and not FSubmodelUsed[I] then
      FSubmodels[I].Transform.Exists := False;

  { Static entities (torches, decorations) }
  if Length(FStaticVisuals) < Length(FDemo.Statics) then
    SetLength(FStaticVisuals, Length(FDemo.Statics));
  for I := 0 to High(FDemo.Statics) do
    ShowVisual(FStaticVisuals[I], FDemo.Statics[I], Dt);

  { The view: the view entity's eyes, looking along the recorded angles }
  CD := FDemo.ClientData;
  if NetMode and Spectate and FSpecFree then
  begin
    { The free camera flies along the view (the move's up goes straight up) }
    Pitch := DegToRad(FDemo.ViewAngles.X);
    Yaw := DegToRad(FDemo.ViewAngles.Y);
    FFlyEye := FFlyEye + (Vector3(Cos(Yaw) * Cos(Pitch), Sin(Yaw) * Cos(Pitch), -Sin(Pitch)) * FSpecMove.X +
      Vector3(Sin(Yaw), -Cos(Yaw), 0) * FSpecMove.Y + Vector3(0, 0, FSpecMove.Z)) * SecondsPassed;
    Eye := FFlyEye;
  end else
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
  if (FDemo.Intermission = 0) and (FDemo.ViewEntity > 0) and not (Spectate and FSpecFree) then
    Bob := CalcViewBob(FDemo.Time, CD.Velocity)
  else
    Bob := 0;
  FViewport.Camera.SetWorldView(QuakeToCge(Eye + Vector3(0, 0, Bob)), QuakeToCge(Dir), Vector3(0, 1, 0));
  if FWeaponTransform <> nil then
    FWeaponTransform.Translation := Vector3(0, 0, -Bob * 0.4);
  UpdateWeapon(FDemo, FWeapon, FWeaponTransform);
  if FWeaponTransform <> nil then
    FWeaponTransform.Exists := not (Spectate and FSpecFree);
  { A spectator learns whom it follows }
  if Spectate and (FDemo.ViewEntity <> FSpecFollowed) and (FDemo.Signon = Signons) then
  begin
    FSpecFollowed := FDemo.ViewEntity;
    if (FSpecFollowed >= 1) and (FSpecFollowed <= Length(FDemo.Names)) then
      FHud.ShowMessage(Format(Tr('Spectating %s (fire: next player, jump: fly)'),
        [FDemo.Names[FSpecFollowed - 1]]), 3);
    WritelnLog('GameViewDemo', 'Spectator: following entity %d', [FSpecFollowed]);
  end;
  { A further pad's Start adds a player; the further players' views }
  if FSplit then
    JoinFromPads;
  for I := 2 to FSplitCount do
    if FPlayers[I].Demo <> nil then
      UpdateSplitPlayer(FPlayers[I], SecondsPassed);

  for I := 0 to High(FBeams) do
    if FBeams[I].Time > 0 then
    begin
      FBeams[I].Time := FBeams[I].Time - Dt;
      if FBeams[I].Time <= 0 then
        for J := 0 to High(FBeams[I].Segments) do
          FBeams[I].Segments[J].Exists := False;
    end;

  FGeometry.Update(Dt, FViewport.Camera.Translation);
  UpdateWorldVisibility;
  FAmbient.Update(SecondsPassed, FViewport.Camera.Translation);
  Particles.Update(Dt);
  Lighting.Update(Dt, FViewport.Camera.Translation);
  UpdateHudStats(FDemo, FHud, FViewport.Camera.Translation, True, SecondsPassed);
  if FSplit then
  begin
    { Each view hides its own player's body and the others' weapons }
    SetLength(FViewport.Hidden, FSplitCount);
    FViewport.Hidden[0] := VisualTransform(FDemo.ViewEntity);
    for I := 2 to FSplitCount do
      FViewport.Hidden[I - 1] := FPlayers[I].WeaponTransform;
    for I := 2 to FSplitCount do
    begin
      P := FPlayers[I];
      if P.Demo = nil then
        Continue;
      UpdateHudStats(P.Demo, P.Hud, P.Camera.Translation, False, SecondsPassed);
      P.Viewport.Fog := FViewport.Fog;
      P.Viewport.Background := FViewport.Background;
      SetLength(P.Viewport.Hidden, FSplitCount);
      P.Viewport.Hidden[0] := VisualTransform(P.Demo.ViewEntity);
      P.Viewport.Hidden[1] := FWeaponTransform;
      N := 2;
      for J := 2 to FSplitCount do
        if J <> I then
        begin
          P.Viewport.Hidden[N] := FPlayers[J].WeaponTransform;
          Inc(N);
        end;
    end;
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
  { Demo playback: Space pauses, left / right seek 10 s, up / down change the speed }
  if Event.IsKey(keySpace) then
  begin
    ToggleDemoPause;
    Exit(True);
  end;
  if Event.IsKey(keyArrowLeft) or Event.IsKey(keyArrowRight) then
  begin
    if Event.IsKey(keyArrowLeft) then
      SeekDemo(FPlayClock - 10)
    else
      SeekDemo(FPlayClock + 10);
    Exit(True);
  end;
  if Event.IsKey(keyArrowUp) or Event.IsKey(keyArrowDown) then
  begin
    if Event.IsKey(keyArrowUp) then
      SetDemoSpeed(FDemoSpeed * 2)
    else
      SetDemoSpeed(FDemoSpeed / 2);
    Exit(True);
  end;
  if Event.IsKey(keyEscape) or Event.IsKey(keyEnter) then
  begin
    Leave;
    Exit(True);
  end;
end;

function DemoClockText(const Seconds: Single): String;
var
  T: Integer;
begin
  T := Max(0, Trunc(Seconds));
  Result := Format('%d:%.2d', [T div 60, T mod 60]);
end;

procedure TViewDemo.MeasureDemoLength;
const
  Step = 0.05;
var
  Probe: TQuakeDemoReader;
begin
  { A second reader without events plays the demo through once }
  Probe := TQuakeDemoReader.Create;
  try
    if Probe.Load(DemoName) then
      while not Probe.Finished and (FDemoLength < 4 * 3600) do
      begin
        Probe.Advance(Step);
        FDemoLength := FDemoLength + Step;
      end;
  finally
    Probe.Free;
  end;
  WritelnLog('GameViewDemo', 'Demo "%s": %.1f s', [DemoName, FDemoLength]);
end;

procedure TViewDemo.ShowDemoStatus;
var
  S: String;
begin
  if FDemoPaused then
    S := Format(Tr('Demo %s / %s, paused'), [DemoClockText(FPlayClock), DemoClockText(FDemoLength)])
  else if FDemoSpeed <> 1 then
    S := Format(Tr('Demo %s / %s at %s x speed'), [DemoClockText(FPlayClock), DemoClockText(FDemoLength),
      FormatFloat('0.##', FDemoSpeed)])
  else
    S := Format(Tr('Demo %s / %s'), [DemoClockText(FPlayClock), DemoClockText(FDemoLength)]);
  FHud.ShowMessage(S, 2);
end;

procedure TViewDemo.ToggleDemoPause;
begin
  if NetMode then
    Exit;
  FDemoPaused := not FDemoPaused;
  if FDemoPaused then
    WritelnLog('GameViewDemo', 'Demo paused at %.2f of %.1f (time %.2f)', [FPlayClock, FDemoLength, FDemo.Time])
  else
    WritelnLog('GameViewDemo', 'Demo goes on at %.2f (time %.2f)', [FPlayClock, FDemo.Time]);
  ShowDemoStatus;
end;

procedure TViewDemo.SetDemoSpeed(const Speed: Single);
begin
  if NetMode then
    Exit;
  FDemoSpeed := EnsureRange(Speed, 0.25, 4);
  WritelnLog('GameViewDemo', 'Demo speed %s', [FormatFloat('0.##', FDemoSpeed)]);
  ShowDemoStatus;
end;

procedure TViewDemo.SeekDemo(const Target: Single);
const
  Step = 0.05;
var
  Goal, From: Single;
  Restarted: Boolean;
  Origin: TVector3;
begin
  if NetMode or FPhoto.Active then
    Exit;
  Goal := EnsureRange(Target, 0, Max(0, FDemoLength - Step));
  From := FPlayClock;
  Restarted := Goal < FPlayClock;
  FSeeking := True;
  try
    { Back: the demo starts again from its first message (and its level) }
    if Restarted then
    begin
      FLoaded := False;
      FPlayClock := 0;
      if not FDemo.Load(DemoName) then
      begin
        FDemo.Finished := True;
        Exit;
      end;
    end;
    while (FPlayClock + Step <= Goal + Step / 2) and not FDemo.Finished do
    begin
      FDemo.Advance(Step);
      FPlayClock := FPlayClock + Step;
      { The level timer starts when the connection is complete, as in Update }
      if FLoaded and (FLevelStart < 0) and (FDemo.Signon = Signons) then
        FLevelStart := FDemo.Time;
    end;
  finally
    FSeeking := False;
  end;
  FFinishedTimer := 0;
  Origin := TVector3.Zero;
  if (FDemo.ViewEntity > 0) and (FDemo.ViewEntity < Length(FDemo.Entities)) then
    Origin := FDemo.Entities[FDemo.ViewEntity].State.Origin;
  WritelnLog('GameViewDemo', 'Demo seek from %.2f to %.2f (%s): at %.2f, time %.2f, view entity at %.1f %.1f %.1f',
    [From, Goal, BoolToStr(Restarted, 'from the start', 'forward'), FPlayClock, FDemo.Time,
     Origin.X, Origin.Y, Origin.Z]);
  ShowDemoStatus;
end;

end.
