{ Main 3D gameplay view for Castle Quake. }
unit GameViewPlay;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, {$ifdef MSWINDOWS} Windows, {$endif}
  CastleVectors, CastleUIControls, CastleControls, CastleKeysMouse,
  CastleViewport, CastleCameras, CastleTransform, CastleColors, CastleLog,
  CastleApplicationProperties, CastleImages, CastleWindow, CastleUtils,
  X3DNodes, X3DFields, CastleRenderOptions,
  QuakePak, QuakePalette, QuakeBsp, QuakeGeometry, QuakeLight, QuakeSound,
  QuakeHud, QuakeParticles, QuakeEntities, QuakeWorld, QuakeConsole, QuakeMenu,
  QuakePhysics;

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
    FUnderwaterEffect: TScreenEffectNode;
    FUnderwaterTime: TSFFloat;
    FWarpTime: Single;
    FDeathTimer: Single;
    FQuitRequested: Boolean;
    { Autotest movement: forward / side / up fractions of full speed, and jump time left }
    FDemoMove: TVector3;
    FDemoJumpTime: Single;
    FDemoFireTime: Single;
    procedure BuildUserCmd(out Cmd: TQuakeUserCmd);
    procedure SetupNavigation;
    procedure CreateUnderwaterEffect;
    procedure UpdateViewContents(const SecondsPassed: Single);
    procedure HandleConsoleCommand(const Cmd, Args: String);
    procedure HandleMenuAction(const Action: TMenuAction; const Param: String);
    procedure ParseDemoScript(const Script: String);
    procedure RunDemoStep(const SecondsPassed: Single);
    procedure CaptureScreenshot(const Prefix: String);
    { Leave the application. Never Halt here: we are inside the window's
      update loop, and finalizing units now would free views still in use. }
    procedure RequestQuit;
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

const
  { Underwater view warp, after D_WarpScreen in software Quake: every row and
    column is shifted by a sine wave (8 pixels at 320x200, 128 pixel period),
    with the image shrunk by the amplitude so the edges never sample outside. }
  UnderwaterFragmentShader =
    'uniform float warp_time;' + LineEnding +
    'void main(void)' + LineEnding +
    '{' + LineEnding +
    '  const vec2 amp = vec2(8.0 / 320.0, 8.0 / 200.0);' + LineEnding +
    '  const float tau = 6.2831853;' + LineEnding +
    '  vec2 p = screenf_01_position;' + LineEnding +
    '  vec2 q = p * (1.0 - 2.0 * amp) + amp;' + LineEnding +
    '  q.x += amp.x * sin(p.y * (200.0 / 128.0) * tau + warp_time);' + LineEnding +
    '  q.y += amp.y * sin(p.x * (320.0 / 128.0) * tau + warp_time);' + LineEnding +
    '  gl_FragColor = vec4(screenf_01_get_color(q).rgb, 1.0);' + LineEnding +
    '}' + LineEnding;

  { Turbulence phase speed: 20 sine table steps (of 128) per second }
  UnderwaterWarpSpeed = 20.0 * 6.2831853 / 128.0;

  { Delay before the level restarts after the player dies }
  DeathRestartDelay = 2.0;

procedure TViewPlay.RequestQuit;
begin
  if FQuitRequested then
    Exit;
  FQuitRequested := True;
  {$ifdef MSWINDOWS}
  if FAutoTestActive then
    ExitProcess(0);
  {$endif}
  { Ends Application.Run after this frame; the program then shuts down normally }
  Application.Terminate;
end;

procedure TViewPlay.CreateUnderwaterEffect;
var
  FragmentPart: TShaderPartNode;
  Shader: TComposedShaderNode;
begin
  FragmentPart := TShaderPartNode.Create;
  FragmentPart.ShaderType := stFragment;
  FragmentPart.Contents := UnderwaterFragmentShader;

  Shader := TComposedShaderNode.Create;
  Shader.SetParts([FragmentPart]);
  FUnderwaterTime := TSFFloat.Create(Shader, True, 'warp_time', 0);
  Shader.AddCustomField(FUnderwaterTime);

  FUnderwaterEffect := TScreenEffectNode.Create;
  FUnderwaterEffect.SetShaders([Shader]);
  FUnderwaterEffect.Enabled := False;
  FViewport.AddScreenEffect(FUnderwaterEffect);
end;

procedure TViewPlay.UpdateViewContents(const SecondsPassed: Single);
var
  Contents: Integer;
  InLiquid: Boolean;
begin
  { Contents at the eye decide the liquid tint and the underwater warp }
  Contents := FWorld.PointContents(FViewport.Camera.Translation);
  FHud.SetContents(Contents);
  InLiquid := (Contents = CONTENTS_WATER) or (Contents = CONTENTS_SLIME) or
    (Contents = CONTENTS_LAVA);
  if FUnderwaterEffect.Enabled <> InLiquid then
    FUnderwaterEffect.Enabled := InLiquid;
  if InLiquid then
  begin
    FWarpTime := FloatModulo(FWarpTime + SecondsPassed * UnderwaterWarpSpeed, 2 * Pi);
    FUnderwaterTime.Send(FWarpTime);
  end;
end;

procedure TViewPlay.SetupNavigation;
begin
  if FNavigation = nil then
  begin
    FNavigation := TCastleWalkNavigation.Create(Self);
    { The navigation only turns the view (mouse look, arrow keys).
      Moving is done by Quake physics (TQuakeWorld.MovePlayer), except in
      free-fly mode where the navigation flies the camera. }
    FNavigation.MoveSpeed := 0;
    FNavigation.Gravity := False;
    FNavigation.HeadBobbing := 0;
    FNavigation.MouseLook := True;
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
        FNavigation.MoveSpeed := 0;
        FMenu.CameraModeName := 'First-Person';
        FHud.CrosshairVisible := True;
      end;
    cmThirdPerson:
      begin
        FNavigation.MouseLook := True;
        FNavigation.MoveSpeed := 0;
        FMenu.CameraModeName := 'Third-Person';
        FHud.CrosshairVisible := True;
      end;
    cmFreeFly:
      begin
        FNavigation.MouseLook := True;
        FNavigation.MoveSpeed := 320.0;
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
    CreateUnderwaterEffect;
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

  { Every start from the main menu (or the command line) is a new game }
  FWorld.NewGame;

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
  { At program exit the view is stopped from CastleWindow finalization,
    after QuakeSound finalization already freed Sounds }
  if Sounds <> nil then
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
    FViewport.Camera.Translation := FWorld.PlayerEyePosition;

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
  Parts: TStringArray;
begin
  if FDemoIndex >= FDemoCommands.Count then
  begin
    if FAutoTestActive then
    begin
      if not FQuitRequested then
        CaptureScreenshot(FAutoTestPrefix);
      RequestQuit;
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
    FWorld.SetPlayerEyePosition(FViewport.Camera.Translation);
    Inc(FDemoIndex);
  end else
  if Action = 'G' then { Teleport the player's eyes to x;y;z (CGE coordinates) }
  begin
    Parts := Param.Split([';']);
    if Length(Parts) = 3 then
    begin
      FViewport.Camera.Translation := Vector3(StrToFloatDef(Parts[0], 0),
        StrToFloatDef(Parts[1], 0), StrToFloatDef(Parts[2], 0));
      FWorld.SetPlayerEyePosition(FViewport.Camera.Translation);
    end;
    Inc(FDemoIndex);
  end else
  if Action = 'V' then { Hold movement: forward;side;up fractions of full speed }
  begin
    Parts := Param.Split([';']);
    FDemoMove := TVector3.Zero;
    for P := 0 to Min(High(Parts), 2) do
      FDemoMove.Data[P] := StrToFloatDef(Parts[P], 0);
    Inc(FDemoIndex);
  end else
  if Action = 'F' then { Hold fire for some seconds }
  begin
    FDemoFireTime := StrToFloatDef(Param, 1.0);
    Inc(FDemoIndex);
  end else
  if Action = 'J' then { Jump }
  begin
    FDemoJumpTime := 0.1;
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
    RequestQuit;
    FDemoIndex := FDemoCommands.Count;
  end else
    Inc(FDemoIndex);
end;

procedure TViewPlay.BuildUserCmd(out Cmd: TQuakeUserCmd);
begin
  FillChar(Cmd, SizeOf(Cmd), 0);
  if (not FConsole.IsOpen) and (not FMenu.Exists) then
  begin
    if FNavigation.Input_Forward.IsPressed(Container) then
      Cmd.ForwardMove := Cmd.ForwardMove + ClForwardSpeed;
    if FNavigation.Input_Backward.IsPressed(Container) then
      Cmd.ForwardMove := Cmd.ForwardMove - ClBackSpeed;
    if FNavigation.Input_RightStrafe.IsPressed(Container) then
      Cmd.SideMove := Cmd.SideMove + ClSideSpeed;
    if FNavigation.Input_LeftStrafe.IsPressed(Container) then
      Cmd.SideMove := Cmd.SideMove - ClSideSpeed;
    { Movement is "always run"; holding the run key walks instead }
    if FNavigation.Input_Run.IsPressed(Container) then
    begin
      Cmd.ForwardMove := Cmd.ForwardMove * 0.5;
      Cmd.SideMove := Cmd.SideMove * 0.5;
    end;
    Cmd.Jump := FNavigation.Input_Jump.IsPressed(Container);
  end;

  { Autotest input }
  Cmd.ForwardMove := Cmd.ForwardMove + FDemoMove.X * ClForwardSpeed;
  Cmd.SideMove := Cmd.SideMove + FDemoMove.Y * ClSideSpeed;
  Cmd.UpMove := Cmd.UpMove + FDemoMove.Z * ClUpSpeed;
  if FDemoJumpTime > 0 then
    Cmd.Jump := True;
end;

procedure TViewPlay.Update(const SecondsPassed: Single; var HandleInput: Boolean);
var
  CamDir: TVector3;
  Yaw, Pitch: Single;
  RayOrigin, RayDir: TVector3;
  Cmd: TQuakeUserCmd;
  NewYaw: Single;
begin
  inherited Update(SecondsPassed, HandleInput);

  { Execute demo commands if any }
  if FDemoCommands.Count > 0 then
    RunDemoStep(SecondsPassed);

  { Quake player physics moves the player; the camera follows the eyes }
  if (FWorld <> nil) and (FCameraMode <> cmFreeFly) then
  begin
    BuildUserCmd(Cmd);
    FDemoJumpTime := Max(0, FDemoJumpTime - SecondsPassed);
    FDemoFireTime := Max(0, FDemoFireTime - SecondsPassed);
    FWorld.MovePlayer(Cmd, FViewport.Camera.Direction, SecondsPassed, FHud);
    if FWorld.TakePendingYaw(NewYaw) then
      FViewport.Camera.SetWorldView(FViewport.Camera.Translation,
        QuakeToCge(Vector3(Cos(DegToRad(NewYaw)), Sin(DegToRad(NewYaw)), 0)), Vector3(0, 1, 0));
    FViewport.Camera.Translation := FWorld.PlayerEyePosition;
  end;

  { Intermission: look from the info_intermission spot }
  if (FWorld <> nil) and FWorld.Intermission then
    FViewport.Camera.SetWorldView(FWorld.IntermissionEye, FWorld.IntermissionDir, Vector3(0, 1, 0));

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
      FWorld.WeaponTransform.Exists := (FCameraMode = cmFirstPerson) and not FWorld.Intermission;

    UpdateViewContents(SecondsPassed);

    { Handle level transition }
    if FWorld.LevelExited and (FWorld.NextMap <> '') then
      LoadLevel(FWorld.NextMap);

    { Restart the level with starting inventory after death }
    if FWorld.PlayerDead then
    begin
      FDeathTimer := FDeathTimer + SecondsPassed;
      if FDeathTimer >= DeathRestartDelay then
      begin
        FDeathTimer := 0;
        FWorld.RespawnPlayer;
        LoadLevel(FMapName);
      end;
    end;
  end;

  { Update camera positioning for third-person view }
  if (FCameraMode = cmThirdPerson) and not FWorld.Intermission then
  begin
    CamDir := FViewport.Camera.Direction;
    CamDir.Y := 0;
    if CamDir.Length > 0 then
      CamDir := CamDir.Normalize;
    FViewport.Camera.Translation := FViewport.Camera.Translation - CamDir * FThirdPersonDist + Vector3(0, 24, 0);
  end;

  { Attack trigger while fire key is held }
  if not FConsole.IsOpen and not FMenu.Exists and not FWorld.PlayerDead then
  begin
    if Container.Pressed[keyCtrl] or (buttonLeft in Container.MousePressed) or
       (FDemoFireTime > 0) then
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
  if Cmd = 'skill' then
  begin
    { Like Quake: takes effect on the next map }
    if Args <> '' then
      FWorld.Skill := EnsureRange(StrToIntDef(Args, FWorld.Skill), 0, 3);
    FConsole.Print('Skill: ' + IntToStr(FWorld.Skill));
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
    RequestQuit;
  end else
  if Cmd = 'help' then
  begin
    FConsole.Print('Commands:');
    FConsole.Print('  map <name>     - Load map (e.g. start, e1m1, lq_e0m1)');
    FConsole.Print('  skill <0..3>   - Skill for the next map');
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
        Pak.PreferOriginalMaps := Param = 'quake';
        FWorld.NewGame;
        LoadLevel('start');
      end;
    maWarpMap:
      begin
        FMenu.Exists := False;
        FNavigation.MouseLook := True;
        Pak.PreferOriginalMaps := (Param <> 'maps/start.bsp') and Pak.OriginalFileExists(Param);
        FWorld.NewGame;
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
      RequestQuit;
  end;
end;

end.
