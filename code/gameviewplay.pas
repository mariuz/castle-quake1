{ Main 3D gameplay view for Castle Quake. }
unit GameViewPlay;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, {$ifdef MSWINDOWS} Windows, {$endif}
  CastleVectors, CastleUIControls, CastleControls, CastleKeysMouse,
  CastleViewport, CastleCameras, CastleTransform, CastleColors, CastleLog,
  CastleApplicationProperties, CastleImages, CastleWindow, CastleUtils,
  QuakePak, QuakePalette, QuakeBsp, QuakeGeometry, QuakeLight, QuakeSound,
  QuakeHud, QuakeParticles, QuakeEntities, QuakeWorld, QuakeConsole, QuakeMenu;

type
  TCameraMode = (cmFirstPerson, cmThirdPerson, cmFreeFly);

  { The main gameplay view }
  TViewPlay = class(TCastleView)
  private
    FViewport: TCastleViewport;
    FNavigation: TCastleWalkNavigation;
    FWorld: TQuakeWorld;
    FHud: TQuakeHud;
    FConsole: TQuakeConsole;
    FMenu: TQuakeMenu;
    FCameraMode: TCameraMode;
    FThirdPersonDist: Single;
    FMapName: String;
    FAutoTestMap: String;
    FAutoTestPrefix: String;
    FAutoTestDemo: String;
    FAutoTestActive: Boolean;
    FAutoTestTimer: Single;
    FAutoTestShots: Integer;
    FDemoCommands: TStringList;
    FDemoIndex: Integer;
    FDemoTimer: Single;
    procedure SetupNavigation;
    procedure HandleConsoleCommand(const Cmd, Args: String);
    procedure HandleMenuAction(const Action: TMenuAction; const Param: String);
    procedure ParseDemoScript(const Script: String);
    procedure RunDemoStep(const SecondsPassed: Single);
    procedure CaptureScreenshot(const Prefix: String);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    procedure Start; override;
    procedure Stop; override;
    procedure Update(const SecondsPassed: Single; var HandleInput: Boolean); override;
    function Press(const Event: TInputPressRelease): Boolean; override;

    procedure LoadLevel(const AMapName: String);
    procedure SetCameraMode(const Mode: TCameraMode);

    property World: TQuakeWorld read FWorld;
    property MapName: String read FMapName write FMapName;
    property AutoTestMap: String read FAutoTestMap write FAutoTestMap;
    property AutoTestPrefix: String read FAutoTestPrefix write FAutoTestPrefix;
    property AutoTestDemo: String read FAutoTestDemo write FAutoTestDemo;
  end;

var
  ViewPlay: TViewPlay;

implementation

constructor TViewPlay.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FCameraMode := cmFirstPerson;
  FThirdPersonDist := 70.0;
  FAutoTestActive := False;
  FAutoTestTimer := 0;
  FAutoTestShots := 0;
  FDemoCommands := TStringList.Create;
  FDemoIndex := 0;
  FDemoTimer := 0;
end;

destructor TViewPlay.Destroy;
begin
  FDemoCommands.Free;
  inherited Destroy;
end;

procedure TViewPlay.SetupNavigation;
begin
  if FNavigation = nil then
  begin
    FNavigation := TCastleWalkNavigation.Create(Self);
    FNavigation.PreferredHeight := 40.0; { Quake player eye level }
    FNavigation.ClimbHeight := 18.0;     { Quake step climbing height }
    FNavigation.MoveSpeed := 320.0;      { Quake standard run speed }
    FNavigation.JumpMaxHeight := 1.2;    { Quake jump height factor }
    FNavigation.MouseLook := True;
    FNavigation.HeadBobbing := 0.02;
    FViewport.InsertFront(FNavigation);
  end;
end;

procedure TViewPlay.SetCameraMode(const Mode: TCameraMode);
begin
  FCameraMode := Mode;
  case Mode of
    cmFirstPerson:
      begin
        FNavigation.MouseLook := True;
        FNavigation.Gravity := True;
        FMenu.CameraModeName := 'First-Person';
        FHud.CrosshairVisible := True;
      end;
    cmThirdPerson:
      begin
        FNavigation.MouseLook := True;
        FNavigation.Gravity := True;
        FMenu.CameraModeName := 'Third-Person';
        FHud.CrosshairVisible := True;
      end;
    cmFreeFly:
      begin
        FNavigation.MouseLook := True;
        FNavigation.Gravity := False;
        FMenu.CameraModeName := 'Free-Fly';
        FHud.CrosshairVisible := False;
      end;
  end;
end;

procedure TViewPlay.Start;
begin
  inherited Start;

  { Create 3D Viewport }
  if FViewport = nil then
  begin
    FViewport := TCastleViewport.Create(Self);
    FViewport.FullSize := True;
    FViewport.Transparent := False;
    FViewport.BackgroundColor := Vector4(0.02, 0.02, 0.03, 1.0);
    InsertFront(FViewport);
  end;

  SetupNavigation;

  { Create world simulation }
  if FWorld = nil then
  begin
    FWorld := TQuakeWorld.Create(FViewport.Items);
    FWorld.AttachWeaponToCamera(FViewport.Camera);
    FViewport.Camera.ProjectionNear := 1.0;
    FViewport.Camera.Perspective.FieldOfViewAxis := faHorizontal;
    FViewport.Camera.Perspective.FieldOfView := DegToRad(90.0);
  end;

  { Setup particles parent }
  Particles.SetParent(FViewport.Items);

  { Create HUD }
  if FHud = nil then
  begin
    FHud := TQuakeHud.Create(Self);
    InsertFront(FHud);
  end;

  { Create developer console }
  if FConsole = nil then
  begin
    FConsole := TQuakeConsole.Create(Self);
    FConsole.OnCommand := @HandleConsoleCommand;
    InsertFront(FConsole);
  end;

  { Create Menu overlay }
  if FMenu = nil then
  begin
    FMenu := TQuakeMenu.Create(Self);
    FMenu.OnMenuAction := @HandleMenuAction;
    FMenu.Exists := False; { hidden initially during gameplay }
    InsertFront(FMenu);
  end;

  { Autotest or normal start }
  if FAutoTestMap <> '' then
  begin
    FAutoTestActive := True;
    FAutoTestTimer := 0;
    ParseDemoScript(FAutoTestDemo);
    LoadLevel(FAutoTestMap);
  end else
  begin
    if FMapName = '' then
      FMapName := 'start';
    LoadLevel(FMapName);
  end;
end;

procedure TViewPlay.Stop;
begin
  Sounds.StopMusic;
  inherited Stop;
end;

procedure TViewPlay.LoadLevel(const AMapName: String);
var
  Rad: Single;
begin
  FMapName := AMapName;
  WritelnLog('GameViewPlay', 'Loading level "%s"', [FMapName]);

  if FWorld.LoadMap(FMapName) then
  begin
    { Place player at map spawn point }
    FViewport.Camera.Translation := FWorld.SpawnPoint;

    Rad := DegToRad(FWorld.SpawnAngle);
    FViewport.Camera.Direction := Vector3(Cos(Rad), 0, -Sin(Rad));
    FViewport.Camera.Up := Vector3(0, 1, 0);

    FHud.ShowMessage('Welcome to Castle Quake: ' + FMapName, 4.0);
  end else
    FHud.ShowMessage('Failed to load level: ' + FMapName, 5.0);
end;

procedure TViewPlay.CaptureScreenshot(const Prefix: String);
var
  OutPath: String;
  Img: TCastleImage;
begin
  Inc(FAutoTestShots);
  OutPath := Prefix + '_' + IntToStr(FAutoTestShots) + '.png';
  try
    Img := Container.SaveScreen;
    if Img <> nil then
    begin
      SaveImage(Img, OutPath);
      Img.Free;
      WritelnLog('GameViewPlay', 'Saved screenshot to "%s"', [OutPath]);
    end;
  except
    on E: Exception do
      WritelnWarning('GameViewPlay', 'Failed to save screenshot "%s": %s', [OutPath, E.Message]);
  end;
end;

procedure TViewPlay.ParseDemoScript(const Script: String);
var
  Commands: TStringArray;
  Cmd: String;
begin
  FDemoCommands.Clear;
  FDemoIndex := 0;
  FDemoTimer := 0;
  if Script = '' then
    Exit;

  Commands := Script.Split([',']);
  for Cmd in Commands do
    if Trim(Cmd) <> '' then
      FDemoCommands.Add(Trim(Cmd));
end;

procedure TViewPlay.RunDemoStep(const SecondsPassed: Single);
var
  Cmd, Action, Param: String;
  P: Integer;
  Val: Single;
  Rad: Single;
  HorizDir: TVector3;
begin
  if FDemoIndex >= FDemoCommands.Count then
  begin
    if FAutoTestActive then
    begin
      CaptureScreenshot(FAutoTestPrefix);
      {$ifdef MSWINDOWS}
      ExitProcess(0);
      {$else}
      if Application.MainWindow <> nil then
        Application.MainWindow.Close
      else
        Application.Terminate;
      {$endif}
    end;
    Exit;
  end;

  Cmd := FDemoCommands[FDemoIndex];
  P := Pos(':', Cmd);
  if P > 0 then
  begin
    Action := UpperCase(Copy(Cmd, 1, P - 1));
    Param := Copy(Cmd, P + 1, Length(Cmd));
  end else
  begin
    Action := UpperCase(Cmd);
    Param := '';
  end;

  if Action = 'W' then { Wait }
  begin
    Val := StrToFloatDef(Param, 1.0);
    FDemoTimer := FDemoTimer + SecondsPassed;
    if FDemoTimer >= Val then
    begin
      FDemoTimer := 0;
      Inc(FDemoIndex);
    end;
  end else
  if Action = 'S' then { Screenshot }
  begin
    CaptureScreenshot(FAutoTestPrefix);
    Inc(FDemoIndex);
  end else
  if Action = 'X' then { Fire }
  begin
    FWorld.FireWeapon(FViewport.Camera.Translation, FViewport.Camera.Direction, FHud);
    Inc(FDemoIndex);
  end else
  if Action = 'U' then { Use }
  begin
    FWorld.ActivateUse(FViewport.Camera.Translation, FViewport.Camera.Direction, FHud);
    Inc(FDemoIndex);
  end else
  if Action = 'A' then { Absolute angle }
  begin
    Val := StrToFloatDef(Param, 0);
    Rad := DegToRad(Val);
    FViewport.Camera.SetWorldView(FViewport.Camera.Translation, Vector3(Cos(Rad), 0, -Sin(Rad)), Vector3(0, 1, 0));
    Inc(FDemoIndex);
  end else
  if Action = 'T' then { Turn }
  begin
    Val := StrToFloatDef(Param, 0);
    Rad := DegToRad(Val);
    FViewport.Camera.SetWorldView(FViewport.Camera.Translation,
      RotatePointAroundAxisRad(Rad, FViewport.Camera.Direction, Vector3(0, 1, 0)),
      Vector3(0, 1, 0));
    Inc(FDemoIndex);
  end else
  if Action = 'P' then { Absolute pitch (positive looks up), keeps current yaw }
  begin
    Val := StrToFloatDef(Param, 0);
    Rad := DegToRad(Val);
    HorizDir := FViewport.Camera.Direction;
    HorizDir.Y := 0;
    if HorizDir.IsPerfectlyZero then
      HorizDir := Vector3(1, 0, 0);
    HorizDir := HorizDir.Normalize;
    FViewport.Camera.SetWorldView(FViewport.Camera.Translation,
      HorizDir * Cos(Rad) + Vector3(0, Sin(Rad), 0), Vector3(0, 1, 0));
    Inc(FDemoIndex);
  end else
  if Action = 'M' then { Move along camera direction }
  begin
    Val := StrToFloatDef(Param, 50.0);
    FViewport.Camera.Translation := FViewport.Camera.Translation + FViewport.Camera.Direction * Val;
    Inc(FDemoIndex);
  end else
  if Action = 'C' then { Change weapon }
  begin
    FWorld.SelectWeapon(StrToIntDef(Param, 2), FHud);
    Inc(FDemoIndex);
  end else
  if Action = 'K' then { Give all }
  begin
    FWorld.CheatGiveAll(FHud);
    Inc(FDemoIndex);
  end else
  if Action = 'Y' then { God mode }
  begin
    FWorld.CheatGodMode(FHud);
    Inc(FDemoIndex);
  end else
  if Action = 'Q' then { Quit }
  begin
    if FAutoTestActive then
    begin
      {$ifdef MSWINDOWS}
      ExitProcess(0);
      {$else}
      Halt(0);
      {$endif}
    end else
    if Application.MainWindow <> nil then
      Application.MainWindow.Close
    else
      Application.Terminate;
  end else
    Inc(FDemoIndex);
end;

procedure TViewPlay.Update(const SecondsPassed: Single; var HandleInput: Boolean);
var
  CamDir: TVector3;
  Yaw, Pitch: Single;
  RayOrigin, RayDir: TVector3;
begin
  inherited Update(SecondsPassed, HandleInput);

  { Execute demo commands if any }
  if FDemoCommands.Count > 0 then
    RunDemoStep(SecondsPassed);

  { Compute player facing angle from camera }
  CamDir := FViewport.Camera.Direction;
  Yaw := RadToDeg(ArcTan2(CamDir.X, -CamDir.Z));
  Pitch := RadToDeg(ArcSin(Clamped(CamDir.Y, -1.0, 1.0)));

  { Update world simulation }
  if FWorld <> nil then
  begin
    FWorld.Update(SecondsPassed, FViewport.Camera.Translation, Yaw, Pitch, FHud);

    { Toggle weapon visibility depending on camera mode }
    if FWorld.WeaponTransform <> nil then
      FWorld.WeaponTransform.Exists := (FCameraMode = cmFirstPerson);

    { Handle level transition }
    if FWorld.LevelExited and (FWorld.NextMap <> '') then
      LoadLevel(FWorld.NextMap);
  end;

  { Update camera positioning for third-person view }
  if FCameraMode = cmThirdPerson then
  begin
    CamDir := FViewport.Camera.Direction;
    CamDir.Y := 0;
    if CamDir.Length > 0 then
      CamDir := CamDir.Normalize;
    FViewport.Camera.Translation := FViewport.Camera.Translation - CamDir * FThirdPersonDist + Vector3(0, 24, 0);
  end;

  { Attack trigger while fire key is held }
  if not FConsole.IsOpen and not FMenu.Exists then
  begin
    if Container.Pressed[keyCtrl] then
    begin
      RayOrigin := FViewport.Camera.Translation;
      RayDir := FViewport.Camera.Direction;
      FWorld.FireWeapon(RayOrigin, RayDir, FHud);
    end;
  end;
end;

function TViewPlay.Press(const Event: TInputPressRelease): Boolean;
var
  RayOrigin, RayDir: TVector3;
begin
  Result := False;

  { If console is open, forward all keys to it }
  if FConsole.IsOpen then
    Exit(FConsole.Press(Event));

  { If menu is open, forward to menu }
  if FMenu.Exists then
  begin
    if Event.IsKey(keyEscape) then
    begin
      FMenu.Exists := False;
      FNavigation.MouseLook := True;
      Exit(True);
    end;
    Exit(FMenu.Press(Event));
  end;

  { Open console with backquote / tilde }
  if Event.IsKey(keyBackQuote) or (Event.KeyString = '~') or (Event.KeyString = '`') then
  begin
    FConsole.Toggle;
    Exit(True);
  end;

  { Open menu with Escape }
  if Event.IsKey(keyEscape) then
  begin
    FMenu.Exists := True;
    FNavigation.MouseLook := False;
    Exit(True);
  end;

  { Weapon fire with Left Mouse Button }
  if Event.IsMouseButton(buttonLeft) then
  begin
    RayOrigin := FViewport.Camera.Translation;
    RayDir := FViewport.Camera.Direction;
    FWorld.FireWeapon(RayOrigin, RayDir, FHud);
    Exit(True);
  end;

  { Activate / Use with E }
  if Event.IsKey(keyE) then
  begin
    RayOrigin := FViewport.Camera.Translation;
    RayDir := FViewport.Camera.Direction;
    FWorld.ActivateUse(RayOrigin, RayDir, FHud);
    Exit(True);
  end;

  { Weapon slot selection 1..8 }
  if Event.IsKey(key1) then begin FWorld.SelectWeapon(1, FHud); Exit(True); end;
  if Event.IsKey(key2) then begin FWorld.SelectWeapon(2, FHud); Exit(True); end;
  if Event.IsKey(key3) then begin FWorld.SelectWeapon(3, FHud); Exit(True); end;
  if Event.IsKey(key4) then begin FWorld.SelectWeapon(4, FHud); Exit(True); end;
  if Event.IsKey(key5) then begin FWorld.SelectWeapon(5, FHud); Exit(True); end;
  if Event.IsKey(key6) then begin FWorld.SelectWeapon(6, FHud); Exit(True); end;
  if Event.IsKey(key7) then begin FWorld.SelectWeapon(7, FHud); Exit(True); end;
  if Event.IsKey(key8) then begin FWorld.SelectWeapon(8, FHud); Exit(True); end;

  { Toggle Camera mode with F1 or C }
  if Event.IsKey(keyF1) or Event.IsKey(keyC) then
  begin
    if FCameraMode = cmFirstPerson then
      SetCameraMode(cmThirdPerson)
    else if FCameraMode = cmThirdPerson then
      SetCameraMode(cmFreeFly)
    else
      SetCameraMode(cmFirstPerson);
    Exit(True);
  end;

  { Toggle Shadows with F2 }
  if Event.IsKey(keyF2) then
  begin
    Lighting.ShadowsEnabled := not Lighting.ShadowsEnabled;
    FMenu.ShadowsEnabled := Lighting.ShadowsEnabled;
    if Lighting.ShadowsEnabled then
      FHud.ShowMessage('Dynamic Shadows: ON')
    else
      FHud.ShowMessage('Dynamic Shadows: OFF');
    Exit(True);
  end;

  { Screenshot with F12 }
  if Event.IsKey(keyF12) then
  begin
    CaptureScreenshot('screenshot');
    FHud.ShowMessage('Screenshot saved');
    Exit(True);
  end;
end;

procedure TViewPlay.HandleConsoleCommand(const Cmd, Args: String);
begin
  if (Cmd = 'map') or (Cmd = 'warp') then
  begin
    if Args <> '' then
      LoadLevel(Args)
    else
      FConsole.Print('Usage: map <mapname>');
  end else
  if Cmd = 'god' then
  begin
    FWorld.CheatGodMode(FHud);
    FConsole.Print('God mode enabled');
  end else
  if (Cmd = 'give') and (Args = 'all') then
  begin
    FWorld.CheatGiveAll(FHud);
    FConsole.Print('Gave all weapons, keys and ammo');
  end else
  if Cmd = 'shadows' then
  begin
    Lighting.ShadowsEnabled := (Args = '1') or (Args = 'on');
    FMenu.ShadowsEnabled := Lighting.ShadowsEnabled;
    FConsole.Print('Shadows: ' + BoolToStr(Lighting.ShadowsEnabled, True));
  end else
  if (Cmd = 'quit') or (Cmd = 'exit') then
  begin
    Application.Terminate;
  end else
  if Cmd = 'help' then
  begin
    FConsole.Print('Commands:');
    FConsole.Print('  map <name>     - Load map (e.g. start, e1m1, lq_e0m1)');
    FConsole.Print('  god            - God mode');
    FConsole.Print('  give all       - Give all weapons, ammo, keys');
    FConsole.Print('  shadows <0|1>  - Toggle dynamic shadows');
    FConsole.Print('  quit           - Exit game');
  end else
    FConsole.Print('Unknown command: ' + Cmd);
end;

procedure TViewPlay.HandleMenuAction(const Action: TMenuAction; const Param: String);
begin
  case Action of
    maNewGame:
      begin
        FMenu.Exists := False;
        FNavigation.MouseLook := True;
        LoadLevel('start');
      end;
    maWarpMap:
      begin
        FMenu.Exists := False;
        FNavigation.MouseLook := True;
        LoadLevel(Param);
      end;
    maToggleShadows:
      begin
        Lighting.ShadowsEnabled := FMenu.ShadowsEnabled;
      end;
    maToggleCamera:
      begin
        if FCameraMode = cmFirstPerson then
          SetCameraMode(cmThirdPerson)
        else
          SetCameraMode(cmFirstPerson);
      end;
    maQuit:
      Application.Terminate;
  end;
end;

end.
