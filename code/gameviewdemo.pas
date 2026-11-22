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
  CastleCameras, CastleBehaviors, X3DNodes,
  GameInput, GameVideo, GameTouch, GamePhoto,
  QuakePak, QuakeBsp, QuakeGeometry, QuakeLight, QuakeSound, QuakeHud, QuakeParticles,
  QuakeMdl, QuakeSprite, QuakeAmbient, QuakePalette, QuakeDemo, QuakePhysics, QuakeNet, QuakeServer, QuakeWebSocketRelay,
  GameEntityRenderer, QuakeEffectParticles, QuakeConsole;

type
  TDemoVisual = TEntityVisual;

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
    { Draws the entities (shared with the QuakeC view) }
    FRenderer: TEntityRenderer;
    { The first view's underwater warp }
    FUnderwater: TUnderwaterWarp;
    FWeaponTransform: TCastleTransform;
    FPhoto: TPhotoMode;
    FWeapon: TDemoVisual;
    FSoundPool: array[0..31] of TCastleTransform;
    FSoundPoolNext: Integer;
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
    { Recording a network game: the demo being written, its name and blocks }
    FRecord: TMemoryStream;
    FRecordName: String;
    FRecordBlocks: Integer;
    { Typing a line of chat (the chat binding), and what was typed }
    FChatting: Boolean;
    FChatText: String;
    { Ping: when each input left (by its sequence), the last acked one, a
      smoothed round trip in ms; the scoreboard shown at the intermission }
    FNetClock: Double;
    FInputSent: array[0..255] of Double;
    FPingAck: Integer;
    FPing: Single;
    { svc_pointparticles / svc_trailparticles drawn }
    FEffectMessages: Integer;
    { The developer console (the settings commands, photo mode's, the host's) }
    FConsole: TQuakeConsole;
    FIntermissionBoard: Boolean;
    procedure ShowChatLine;
    { Send a chat line, or run a host command (a line starting with /) }
    procedure SendChatLine(const Text: String);
    procedure RunHostCommand(const Line: String);
    { A line of the console or of a script's CMD: the settings commands,
      photo mode's, then the host's (network game) }
    procedure RunConsoleCommand(const Line: String);
    procedure HandleConsoleCommand(const Cmd, Args: String);
    { To the console and, while it is closed, the HUD }
    procedure ConsoleSay(const S: String; const Seconds: Single);
    function ScoreboardText: String;
    function ScoreboardLog: String;
    procedure ClearLevel;
    { Demo playback controls }
    procedure MeasureDemoLength;
    procedure SeekDemo(const Target: Single);
    procedure SetDemoSpeed(const Speed: Single);
    procedure ToggleDemoPause;
    procedure ShowDemoStatus;
    { Network recording: from the level's signon on, every block received }
    procedure StartNetRecord(const AName: String);
    procedure StopNetRecord;
    procedure WriteRecordBlock(const Data: TBytes);
    procedure HandleNetBlock(const Data: TBytes);
    procedure LoadLevel;
    procedure ApplyEnvironment;
    procedure HandleServerInfo;
    procedure HandleSound(const Entity, Channel, SoundIndex: Integer; const Volume, Attenuation: Single;
      const Origin: TVector3);
    procedure HandleTempEntity(const Kind: Integer; const Pos, Pos2: TVector3;
      const Entity, ColorStart, ColorLength: Integer);
    procedure HandleParticle(const Org, Dir: TVector3; const Count, Color: Integer);
    { svc_pointparticles / svc_trailparticles: a mod's effectinfo.txt effect }
    procedure HandleEffect(const Trail: Boolean; const Num: Integer; const A, B: TVector3; const Count: Integer);
    procedure HandlePrint(const S: String);
    procedure HandleCenterPrint(const S: String);
    procedure HandleFinale(const S: String);
    procedure HandleDamage(const Armor, Blood: Integer; const From: TVector3);
    procedure HandleLightStyle(const Index: Integer; const Pattern: String);
    procedure HandleCdTrack(const Track, LoopTrack: Integer);
    procedure HandleIntermission;
    procedure ShowVisual(var V: TDemoVisual; const State: TDemoEntityState; const Dt: Single);
    { Draw only the entities and brush models in the camera's PVS }
    procedure CullVisuals;
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
    { Record the network game to castle-config:/<RecordName>.dem from the
      moment the connection is complete (-record <name>) }
    RecordName: String;
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
  CastleRectangles, CastleGameControllers, CastleDownload, GameViewMenu, GameTranslate, GameConsole, GameLogWatch, QuakeModelLight, QuakeDecals;

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
  FDemo.OnEffect := @HandleEffect;
  FDemo.OnPrint := @HandlePrint;
  FDemo.OnCenterPrint := @HandleCenterPrint;
  FDemo.OnFinale := @HandleFinale;
  FDemo.OnDamage := @HandleDamage;
  FDemo.OnLightStyle := @HandleLightStyle;
  FDemo.OnCdTrack := @HandleCdTrack;
  FDemo.OnNetBlock := @HandleNetBlock;
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
  FreeAndNil(FRenderer);
  FreeAndNil(FUnderwater);
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
    FUnderwater := TUnderwaterWarp.Create(FViewport, 'demo');
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
  if FConsole = nil then
  begin
    FConsole := TQuakeConsole.Create(Self);
    FConsole.OnCommand := @HandleConsoleCommand;
    InsertFront(FConsole);
  end;
  Particles.SetParent(FViewport.Items);
  if FRenderer = nil then
    FRenderer := TEntityRenderer.Create(FViewport.Items, 'entity');
  { A mod's effectinfo.txt, before a listen server spawns its level (the
    progs ask for effect numbers then) }
  if EffectParticles = nil then
    EffectParticles := TQuakeEffectParticles.Create;
  EffectParticles.Load(FViewport.Items);

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
    FClient.PlayerName := PlayerName;
    FClient.PlayerColors := PlayerColors;
    FChatting := False;
    FChatText := '';
    FNetClock := 0;
    FPingAck := -1;
    FPing := 0;
    FIntermissionBoard := False;
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
  StopNetRecord;
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
  FreeAndNil(EffectParticles);
  if Sounds <> nil then
    Sounds.StopMusic;
  if Lighting <> nil then
    Lighting.ResetStyles;
  inherited Stop;
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

{ The players by frags, the most first: name and frags }
function SortedPlayers(const D: TQuakeDemoReader): specialize TArray<Integer>;
var
  I, J, N, T: Integer;
begin
  Result := nil;
  SetLength(Result, Length(D.Names));
  N := 0;
  for I := 0 to High(D.Names) do
    if D.Names[I] <> '' then
    begin
      Result[N] := I;
      Inc(N);
    end;
  SetLength(Result, N);
  for I := 1 to N - 1 do
  begin
    T := Result[I];
    J := I;
    while (J > 0) and (D.Frags[Result[J - 1]] < D.Frags[T]) do
    begin
      Result[J] := Result[J - 1];
      Dec(J);
    end;
    Result[J] := T;
  end;
end;

const
  { The names of the 14 player color rows of the palette }
  TeamColorNames: array[0..13] of String = ('White', 'Brown', 'Light Blue', 'Green', 'Red', 'Olive', 'Orange',
    'Peach', 'Purple', 'Magenta', 'Tan', 'Teal', 'Yellow', 'Blue');

{ Teamplay: the pants colors of the named players, the most frags first,
  with their frags }
procedure SortedTeams(const D: TQuakeDemoReader; out Teams, TeamFrags: specialize TArray<Integer>);
var
  I, J, K, P, T, F: Integer;
  Found: Boolean;
begin
  Teams := nil;
  TeamFrags := nil;
  for I in SortedPlayers(D) do
  begin
    P := D.Colors[I] and 15;
    Found := False;
    for K := 0 to High(Teams) do
      if Teams[K] = P then
      begin
        TeamFrags[K] := TeamFrags[K] + D.Frags[I];
        Found := True;
      end;
    if not Found then
    begin
      SetLength(Teams, Length(Teams) + 1);
      SetLength(TeamFrags, Length(TeamFrags) + 1);
      Teams[High(Teams)] := P;
      TeamFrags[High(TeamFrags)] := D.Frags[I];
    end;
  end;
  for I := 1 to High(Teams) do
  begin
    T := Teams[I];
    F := TeamFrags[I];
    J := I;
    while (J > 0) and (TeamFrags[J - 1] < F) do
    begin
      Teams[J] := Teams[J - 1];
      TeamFrags[J] := TeamFrags[J - 1];
      Dec(J);
    end;
    Teams[J] := T;
    TeamFrags[J] := F;
  end;
end;

procedure TViewDemo.Leave;
var
  I: Integer;
begin
  StopNetRecord;
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
  if NetMode and (RecordName <> '') and (FRecord = nil) and (FDemo.Signon = Signons) then
  begin
    StartNetRecord(RecordName);
    RecordName := '';
  end;
  if (FLevelStart < 0) and (FDemo.Signon = Signons) then
  begin
    FLevelStart := FDemo.Time;
    for I := 2 to MaxSplitPlayers do
      FPlayers[I].LevelStart := FLevelStart;
  end;

  { Touch controls only in a network game; their menu button leaves it }
  FTouch.UpdateShown(NetMode);
  if NetMode and FNavigation.MouseLook and (TouchControlsWanted or FConsole.IsOpen) then
    FNavigation.MouseLook := False
  else if NetMode and (AutoTestPrefix = '') and not TouchControlsWanted and not FConsole.IsOpen and
     not FNavigation.MouseLook and FNavigation.Exists then
    FNavigation.MouseLook := True;
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
    { The round trip of the input the last frame acknowledged }
    FNetClock := FNetClock + SecondsPassed;
    if (FClient <> nil) and FClient.HasAckedInput and (FClient.AckedInput <> FPingAck) then
    begin
      FPingAck := FClient.AckedInput;
      if FPing = 0 then
        FPing := (FNetClock - FInputSent[FPingAck and 255]) * 1000
      else
        FPing := FPing * 0.9 + (FNetClock - FInputSent[FPingAck and 255]) * 1000 * 0.1;
    end;
    { The scoreboard: while its binding is held, and at the intermission }
    if (FDemo.Intermission <> 0) and (FDemo.GameType = 1) and not FIntermissionBoard then
    begin
      FIntermissionBoard := True;
      WritelnLog('GameViewDemo', 'Scoreboard at the intermission: %s', [ScoreboardLog]);
    end else
    if FDemo.Intermission = 0 then
      FIntermissionBoard := False;
    if ((FDemo.Intermission <> 0) and (FDemo.GameType = 1)) or
       (not FChatting and BindingHeld(qbScoreboard, Container, PlayerOne)) then
      FHud.ShowScoreboard(ScoreboardText)
    else
      FHud.ShowScoreboard('');
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
  for I := 0 to High(FRenderer.SubmodelUsed) do
    FRenderer.SubmodelUsed[I] := False;
  for I := 1 to High(FVisuals) do
    if FDemo.EntityVisible(I) and ((I <> FDemo.ViewEntity) or FSplit or (Spectate and FSpecFree)) then
    begin
      ShowVisual(FVisuals[I], FDemo.Entities[I].State, Dt);
    end else
      FRenderer.Hide(FVisuals[I]);
  for I := 1 to High(FRenderer.Submodels) do
    if (FRenderer.Submodels[I] <> nil) and not FRenderer.SubmodelUsed[I] then
      FRenderer.Submodels[I].Transform.Exists := False;

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

  FRenderer.UpdateBeams(Dt);

  FGeometry.Update(Dt, FViewport.Camera.Translation);
  UpdateWorldVisibility;
  FAmbient.Update(SecondsPassed, FViewport.Camera.Translation);
  Particles.Update(Dt);
  { The effect particles face the first view's camera }
  if EffectParticles <> nil then
  begin
    EffectParticles.WorldBsp := FBsp;
    EffectParticles.Update(Dt,
      TVector3.CrossProduct(FViewport.Camera.Direction, FViewport.Camera.Up).Normalize,
      FViewport.Camera.Up.Normalize);
  end;
  UpdateModelLights(FBsp, Dt);
  Decals.WorldBsp := FBsp;
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

function TViewDemo.Press(const Event: TInputPressRelease): Boolean;
var
  I: Integer;
begin
  Result := inherited Press(Event);
  if Result then
    Exit;
  { The console takes the keys while it is open }
  if FConsole.IsOpen then
    Exit(FConsole.Press(Event));
  if not FChatting and not FPhoto.Active and
     (BindingEvent(qbConsole, Event) or (Event.KeyString = '~') or (Event.KeyString = '`')) then
  begin
    FConsole.Toggle;
    WritelnLog('GameViewDemo', 'Console %s', [BoolToStr(FConsole.IsOpen, 'opened', 'closed')]);
    Exit(True);
  end;
  if NetMode then
  begin
    { Typing chat: Enter sends, Escape drops it, the rest is the text }
    if FChatting then
    begin
      if Event.EventType = itKey then
      begin
        if Event.IsKey(keyEnter) then
        begin
          FChatting := False;
          FHud.ShowMessage('', 0.1);
          SendChatLine(FChatText);
        end else
        if Event.IsKey(keyEscape) then
        begin
          FChatting := False;
          FHud.ShowMessage('', 0.1);
        end else
        if Event.IsKey(keyBackSpace) then
        begin
          if FChatText <> '' then
            SetLength(FChatText, Length(FChatText) - 1);
          ShowChatLine;
        end else
        if (Length(Event.KeyString) = 1) and (Event.KeyString[1] >= ' ') and (Event.KeyString[1] < #127) and
           (Length(FChatText) < MaxChatLength) then
        begin
          FChatText := FChatText + Event.KeyString;
          ShowChatLine;
        end;
      end;
      Exit(True);
    end;
    if BindingEvent(qbChat, Event) and (FClient <> nil) then
    begin
      FChatting := True;
      FChatText := '';
      ShowChatLine;
      Exit(True);
    end;
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

{ The methods of the subsystems, a file each (demo) }
{$I demo/gameviewdemo_split.inc}
{$I demo/gameviewdemo_net.inc}
{$I demo/gameviewdemo_level.inc}
{$I demo/gameviewdemo_events.inc}
{$I demo/gameviewdemo_hud.inc}
{$I demo/gameviewdemo_script.inc}
{$I demo/gameviewdemo_playback.inc}

end.
