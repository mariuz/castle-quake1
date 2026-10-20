{ Main 3D gameplay view for Castle Quake. }
unit GameViewPlay;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, {$ifdef MSWINDOWS} Windows, {$endif}
  CastleVectors, CastleUIControls, CastleControls, CastleKeysMouse, CastleGameControllers,
  CastleViewport, CastleCameras, CastleTransform, CastleColors, CastleLog,
  CastleApplicationProperties, CastleImages, CastleWindow, CastleUtils, CastleTimeUtils,
  X3DNodes, X3DFields, CastleRenderOptions,
  GameInput, GameVideo, GameTouch, QuakeCaptions, CastleConfig,
  QuakePak, QuakePalette, QuakeBsp, QuakeGeometry, QuakeLight, QuakeSound,
  QuakeHud, QuakeParticles, QuakeEntities, QuakeWorld, QuakeConsole, QuakeMenu,
  QuakePhysics, QuakeSaveGame, QuakeDebug, QuakeMapBrowser, GamePhoto, CastleUriUtils;

type
  TCameraMode = (cmFirstPerson, cmThirdPerson, cmFreeFly);

  { The main gameplay view }
  TViewPlay = class(TCastleView)
  private
    FViewport: TCastleViewport;
    FNavigation: TCastleWalkNavigation;
    FWorld: TQuakeWorld;
    FHud: TQuakeHud;
    { The on-screen sticks and buttons of touch screens }
    FTouch: TQuakeTouchControls;
    FConsole: TQuakeConsole;
    FMenu: TQuakeMenu;
    FCameraMode: TCameraMode;
    FThirdPersonDist: Single;
    FMapName: String;
    FLoadSlot: String;
    { Jump and fire held when the menu closed (Space, a click or the
      gamepad's A picked an item): ignored until released }
    FHeldFromMenu: Boolean;
    FAutoTestMap: String;
    FAutoTestPrefix: String;
    FAutoTestDemo: String;
    FAutoTestActive: Boolean;
    FAutoTestTimer: Single;
    FAutoTestShots: Integer;
    FDemoCommands: TStringList;
    FDemoIndex: Integer;
    FShowFps: Boolean;
    { Frame timing between two Z demo actions }
    FBenchFrames: Integer;
    FBenchStart: TTimerResult;
    FBenchLongest: Single;
    FBenchStarted: Boolean;
    FBobTime: Single;
    FDemoTimer: Single;
    FUnderwaterEffect: TScreenEffectNode;
    FPhoto: TPhotoMode;
    FUnderwaterTime: TSFFloat;
    FWarpTime: Single;
    FDeathTimer: Single;
    FHordeMode: Boolean;
    FHordeReported: Boolean;
    FQuitRequested: Boolean;
    { Autotest movement: forward / side / up fractions of full speed, and jump time left }
    FDemoMove: TVector3;
    FDemoJumpTime: Single;
    FDemoFireTime: Single;
    { Virtual gamepad of the demo script: the button pressed by GB and
      how long until it is released }
    FDemoPadButton: TGameControllerButton;
    FDemoPadRelease: Single;
    FDemoPadLeft, FDemoPadRight: TVector2;
    procedure BuildUserCmd(out Cmd: TQuakeUserCmd);
    procedure SetupNavigation;
    procedure CreateUnderwaterEffect;
    procedure UpdateViewContents(const SecondsPassed: Single);
    procedure HandleConsoleCommand(const Cmd, Args: String);
    procedure HandleMenuAction(const Action: TMenuAction; const Param: String);
    procedure ParseDemoScript(const Script: String);
    procedure RunDemoStep(const SecondsPassed: Single);
    function PvsStatus: String;
    procedure ComparePvsRender;
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

    { Savegame slots (quick = F6 / F9) }

    procedure SaveGameSlot(const Slot: String);

    procedure LoadGameSlot(const Slot: String);
    procedure ReportHorde;
    procedure MapBrowserCommand(const Cmd, Args: String);
    procedure SetPhotoMode(const On: Boolean);
    procedure SaveThumbnail(const Slot: String);
    procedure ListSavesCommand;
    function PhotoPrefix: String;
    procedure SetCameraMode(const Mode: TCameraMode);

    property World: TQuakeWorld read FWorld;
    property MapName: String read FMapName write FMapName;
    { A savegame slot to start from instead of MapName (Load Game in the
      main menu), cleared when used }
    property LoadSlot: String read FLoadSlot write FLoadSlot;
    { Horde mode: waves of monsters on the maps loaded (-horde, the menu,
      console horde) }
    property HordeMode: Boolean read FHordeMode write FHordeMode;
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
  Sounds.SetUnderwater(InLiquid);
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
    FNavigation.MouseLook := not TouchControlsWanted;
    FViewport.InsertFront(FNavigation);
  end;
end;

procedure TViewPlay.SetCameraMode(const Mode: TCameraMode);
begin
  FCameraMode := Mode;
  case Mode of
    cmFirstPerson:
      begin
        FNavigation.MouseLook := not TouchControlsWanted;
        FNavigation.MoveSpeed := 0;
        FMenu.CameraModeName := 'First-Person';
        FHud.CrosshairVisible := True;
      end;
    cmThirdPerson:
      begin
        FNavigation.MouseLook := not TouchControlsWanted;
        FNavigation.MoveSpeed := 0;
        FMenu.CameraModeName := 'Third-Person';
        FHud.CrosshairVisible := True;
      end;
    cmFreeFly:
      begin
        FNavigation.MouseLook := not TouchControlsWanted;
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
    FViewport.Camera.Name := 'camera';
    FViewport.Camera.ProjectionNear := 1.0;
    ApplyVideoSettings(FViewport);
  end;

  { Setup particles parent }
  Particles.SetParent(FViewport.Items);

  { Create HUD }
  if FHud = nil then
  begin
    FHud := TQuakeHud.Create(Self);
    InsertFront(FHud);
  end;

  { Touch controls above the HUD, below the console and the menu }
  if FTouch = nil then
  begin
    FTouch := TQuakeTouchControls.Create(Self);
    InsertFront(FTouch);
  end;

  { Photo mode's help line, above the touch controls }
  if FPhoto = nil then
    FPhoto := TPhotoMode.Create(Self, FViewport, Self, FNavigation);

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
    FMenu.InGame := True;
    FMenu.OnMenuAction := @HandleMenuAction;
    FMenu.Exists := False; { hidden initially during gameplay }
    InsertFront(FMenu);
  end;

  { Every start from the main menu (or the command line) is a new game }
  FWorld.NewGame;

  { Autotest or normal start; load:<slot> (and Load Game in the main menu)
    starts from a savegame, which loads its own map }
  if FAutoTestMap <> '' then
  begin
    FAutoTestActive := True;
    FAutoTestTimer := 0;
    ParseDemoScript(FAutoTestDemo);
    if Pos('load:', FAutoTestMap) = 1 then
      FLoadSlot := Copy(FAutoTestMap, 6, MaxInt)
    else
      LoadLevel(FAutoTestMap);
  end;
  if FLoadSlot <> '' then
  begin
    LoadGameSlot(FLoadSlot);
    FLoadSlot := '';
    if FWorld.MapName = '' then
      LoadLevel('start');
  end else
  if FAutoTestMap = '' then
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
  FWorld.HordeMode := FHordeMode;
  FHordeReported := False;

  if FWorld.LoadMap(FMapName) then
  begin
    ApplyWorldFog(FViewport, FWorld.Geometry);
    { Place player at map spawn point }
    FViewport.Camera.Translation := FWorld.PlayerEyePosition;

    Rad := DegToRad(FWorld.SpawnAngle);
    FViewport.Camera.Direction := Vector3(Cos(Rad), 0, -Sin(Rad));
    FViewport.Camera.Up := Vector3(0, 1, 0);

    if FWorld.HordeActive then
      FHud.ShowMessage('HORDE MODE: ' + FMapName + LineEnding + 'Survive the waves', 4.0)
    else
      FHud.ShowMessage('Welcome to Castle Quake: ' + FMapName, 4.0);
  end else
    FHud.ShowMessage('Failed to load level: ' + FMapName, 5.0);
end;

{ The horde ended with the player's death: the score against the best one
  of the map (user config horde/<map>/...) }
{ The map browser from the console: maps lists, maps_install downloads (the
  log says when it is installed), maps_play mounts and plays, maps_remove }
procedure TViewPlay.MapBrowserCommand(const Cmd, Args: String);
var
  Words: TStringList;
  Sort: TMapSort;
  Filter, Line: String;
  List: specialize TArray<Integer>;
  I, Index: Integer;
begin
  Words := TStringList.Create;
  try
    Words.Delimiter := ' ';
    Words.StrictDelimiter := True;
    Words.DelimitedText := Trim(Args);
    for I := Words.Count - 1 downto 0 do
      if Words[I] = '' then
        Words.Delete(I);
    if Cmd = 'maps' then
    begin
      Sort := msRating;
      Filter := '';
      for I := 0 to Words.Count - 1 do
        if SameText(Words[I], 'newest') then
          Sort := msNewest
        else if SameText(Words[I], 'name') then
          Sort := msName
        else if SameText(Words[I], 'installed') then
          Sort := msInstalled
        else if not SameText(Words[I], 'rating') then
          Filter := Trim(Filter + ' ' + Words[I]);
      List := MapBrowser.Sorted(Sort, Filter);
      FConsole.Print(Format('%d maps (%s)', [Length(List), MapBrowser.CatalogUrl]));
      WritelnLog('MapBrowser', '%d maps listed', [Length(List)]);
      for I := 0 to Min(High(List), 9) do
      begin
        Line := MapBrowser[List[I]].Id + ': ' + MapBrowser.Describe(List[I]);
        if MapBrowser.Installed(List[I]) then
          Line := Line + ' [installed]';
        FConsole.Print('  ' + Line);
        WritelnLog('MapBrowser', '  %s', [Line]);
      end;
      Exit;
    end;
    if Words.Count = 0 then
    begin
      FConsole.Print('Usage: ' + Cmd + ' <id>');
      Exit;
    end;
    Index := MapBrowser.IndexOf(Words[0]);
    if Index < 0 then
    begin
      FConsole.Print('No map "' + Words[0] + '" in the catalog');
      WritelnLog('MapBrowser', 'No map "%s" in the catalog', [Words[0]]);
      Exit;
    end;
    if Cmd = 'maps_install' then
    begin
      MapBrowser.Install(Index);
      FConsole.Print(MapBrowser.Status);
    end else
    if Cmd = 'maps_remove' then
    begin
      MapBrowser.Remove(Index);
      FConsole.Print(MapBrowser.Status);
    end else
    begin
      if not MapBrowser.Mount(Index) then
      begin
        FConsole.Print(MapBrowser[Index].Title + ' is not installed (maps_install ' + MapBrowser[Index].Id + ')');
        WritelnLog('MapBrowser', 'Map "%s" is not installed', [MapBrowser[Index].Id]);
        Exit;
      end;
      if Words.Count > 1 then
        Line := LowerCase(Words[1])
      else
        Line := MapBrowser[Index].StartMaps[0];
      if not Pak.FileExists('maps/' + Line + '.bsp') then
      begin
        FConsole.Print('No maps/' + Line + '.bsp in ' + MapBrowser[Index].Id);
        Exit;
      end;
      FConsole.Close;
      FWorld.NewGame;
      LoadLevel('maps/' + Line + '.bsp');
    end;
  finally
    Words.Free;
  end;
end;

{ Photo mode: the world stops (Update skips it), the HUD, the weapon and
  the touch controls hide, the camera flies; leaving puts the camera back }
procedure TViewPlay.SetPhotoMode(const On: Boolean);
begin
  if (FWorld = nil) or (On = FPhoto.Active) then
    Exit;
  WritelnLog('Photo', 'Level time %.2f', [FWorld.Stats.LevelTime]);
  if On then
  begin
    FPhoto.Enter;
    FHud.Exists := False;
    if FWorld.WeaponTransform <> nil then
      FWorld.WeaponTransform.Exists := False;
    FTouch.UpdateShown(False);
  end else
  begin
    FPhoto.Leave;
    FHud.Exists := True;
    FNavigation.MouseLook := not TouchControlsWanted;
  end;
end;

{ Where photos go: next to the autotest screenshots, else the working
  directory like the screenshots }
function TViewPlay.PhotoPrefix: String;
begin
  if FAutoTestPrefix <> '' then
    Result := FAutoTestPrefix
  else
    Result := 'castle-quake';
end;

procedure TViewPlay.ReportHorde;
var
  Key: String;
  Best, BestWave: Integer;
begin
  FHordeReported := True;
  Key := 'horde/' + LowerCase(FWorld.MapName) + '/';
  Best := UserConfig.GetValue(Key + 'score', 0);
  BestWave := UserConfig.GetValue(Key + 'wave', 0);
  WritelnLog('Horde', 'Horde over on "%s": wave %d, score %d (best %d, wave %d)',
    [FWorld.MapName, FWorld.HordeWave, FWorld.HordeScore, Best, BestWave]);
  if FWorld.HordeScore > Best then
  begin
    FHud.ShowMessage(Format('HORDE OVER' + LineEnding + 'Wave %d, score %d' + LineEnding + 'New best!',
      [FWorld.HordeWave, FWorld.HordeScore]), 5.0);
    if not VideoSettingsVolatile then
    begin
      UserConfig.SetValue(Key + 'score', FWorld.HordeScore);
      UserConfig.SetValue(Key + 'wave', FWorld.HordeWave);
      UserConfig.Save;
    end;
  end else
    FHud.ShowMessage(Format('HORDE OVER' + LineEnding + 'Wave %d, score %d' + LineEnding + 'Best: %d (wave %d)',
      [FWorld.HordeWave, FWorld.HordeScore, Best, BestWave]), 5.0);
end;

procedure TViewPlay.SaveGameSlot(const Slot: String);
begin
  if not FWorld.CanSave then
  begin
    FHud.ShowMessage('You can''t save now');
    Exit;
  end;
  if FWorld.SaveGame(SaveGameUrl(Slot), FViewport.Camera.Direction) then
  begin
    SaveThumbnail(Slot);
    FHud.ShowMessage('Game saved (' + Slot + ')');
  end else
    FHud.ShowMessage('Saving failed');
end;

{ A small picture of the view (the viewport alone: no HUD, no menu) for
  the Load Game list; not in the browser, where the config directory lives
  in localStorage }
procedure TViewPlay.SaveThumbnail(const Slot: String);
{$ifndef WASI}
var
  Image: TCastleImage;
begin
  try
    Image := RenderViewportImage(FViewport, 320, 180);
    if Image = nil then
      Exit;
    try
      SaveImage(Image, SaveThumbnailUrl(Slot));
      WritelnLog('GameViewPlay', 'Thumbnail of slot %s saved: %dx%d', [SaveSlotName(Slot), Image.Width, Image.Height]);
    finally
      Image.Free;
    end;
  except
    on E: Exception do
      WritelnWarning('GameViewPlay', 'Cannot save the thumbnail of slot %s: %s', [Slot, E.Message]);
  end;
end;
{$else}
begin
end;
{$endif}

{ Console saves: the savegames as the Load Game menu lists them }
procedure TViewPlay.ListSavesCommand;
var
  Saves: TSaveGameInfoArray;
  I: Integer;
  Line: String;
begin
  Saves := ListSaveGames;
  FConsole.Print(Format('%d saved games', [Length(Saves)]));
  WritelnLog('GameViewPlay', 'Saved games: %d', [Length(Saves)]);
  for I := 0 to High(Saves) do
  begin
    Line := Format('%s: %s, health %d, kills %d/%d, skill %d, %.0f s, %s, thumbnail %s', [Saves[I].Slot,
      Saves[I].Map, Saves[I].Health, Saves[I].Kills, Saves[I].TotalKills, Saves[I].Skill, Saves[I].LevelTime,
      Saves[I].Saved, BoolToStr(UriExists(SaveThumbnailUrl(Saves[I].Slot)) = ueFile, 'yes', 'no')]);
    FConsole.Print('  ' + Line);
    WritelnLog('GameViewPlay', '  Save %s', [Line]);
  end;
end;

procedure TViewPlay.LoadGameSlot(const Slot: String);
var
  ViewDir: TVector3;
begin
  if not FWorld.LoadGame(SaveGameUrl(Slot), ViewDir) then
  begin
    FHud.ShowMessage('Cannot load savegame ' + Slot);
    Exit;
  end;
  FMapName := FWorld.MapName;
  FDeathTimer := 0;
  FViewport.Camera.SetWorldView(FWorld.PlayerEyePosition, ViewDir, Vector3(0, 1, 0));
  FHud.ShowMessage('Game loaded (' + Slot + ')');
end;

function TViewPlay.PvsStatus: String;
var
  G: TQuakeGeometry;
begin
  Result := 'no world';
  if (FWorld = nil) or (FWorld.Geometry = nil) then
    Exit;
  G := FWorld.Geometry;
  Result := Format('culling %s, leaf %d, clusters %d/%d, shapes %d/%d, entities %d/%d',
    [BoolToStr(WorldPvsCulling, 'on', 'off'), G.CameraLeaf, G.VisibleClusters, G.ClusterCount,
     G.VisibleShapes, G.ShapeCount, G.VisibleEntities, G.EntityCount]);
end;

procedure TViewPlay.ComparePvsRender;
var
  Culled, Full: TRGBImage;
  WasCulling: Boolean;
  X, Y, Differ, Total: Integer;
  A, B: PVector3Byte;
  Status: String;

  function Render(const Culling: Boolean): TRGBImage;
  begin
    WorldPvsCulling := Culling;
    FWorld.Geometry.UpdateVisibility(FViewport.Camera.Translation);
    FWorld.CullEntities;
    if Culling then
      Status := PvsStatus;
    Result := Container.SaveScreen;
  end;

begin
  if (FWorld = nil) or (FWorld.Geometry = nil) then
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
    WritelnLog('GameViewPlay', 'PVS compare: %d of %d pixels differ, %s',
      [Differ, Total, Status]);
    if (Differ > 0) and (FAutoTestPrefix <> '') then
    begin
      Inc(FAutoTestShots);
      {$ifndef WASI}
      SaveImage(Culled, FAutoTestPrefix + '_' + IntToStr(FAutoTestShots) + '_pvs.png');
      SaveImage(Full, FAutoTestPrefix + '_' + IntToStr(FAutoTestShots) + '_full.png');
      {$endif}
    end;
  finally
    Culled.Free;
    Full.Free;
    WorldPvsCulling := WasCulling;
    FWorld.Geometry.UpdateVisibility(FViewport.Camera.Translation);
    FWorld.CullEntities;
  end;
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
      { The browser has no files: the screenshot only logs }
      {$ifndef WASI}
      SaveImage(Img, OutPath);
      {$endif}
      Img.Free;
      WritelnLog('GameViewPlay', 'Saved screenshot to "%s"', [OutPath]);
      if FWorld <> nil then
        WritelnLog('GameViewPlay', 'View: map %s, eye %s, yaw %.0f, pitch %.0f, weapon %d, ammo %d, health %d, kills %d/%d, intermission %s',
          [FWorld.MapName, CgeToQuake(FViewport.Camera.Translation).ToString,
           RadToDeg(ArcTan2(-FViewport.Camera.Direction.Z, FViewport.Camera.Direction.X)),
           RadToDeg(ArcSin(Clamped(FViewport.Camera.Direction.Y, -1.0, 1.0))),
           FWorld.Stats.CurrentWeapon, FWorld.Stats.Ammo, FWorld.Stats.Health,
           FWorld.Stats.Kills, FWorld.Stats.TotalKills, BoolToStr(FWorld.Intermission, 'yes', 'no')]);
      if FWorld <> nil then
        WritelnLog('GameViewPlay', 'PVS: ' + PvsStatus);
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
  TouchPos: TVector2;
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
    { In photo mode only the camera flies }
    if not FPhoto.Active then
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
  if (Action = 'TD') or (Action = 'TM') then { Touch: TD:id;x;y down, TM:id;x;y moved (fractions of the window) }
  begin
    Parts := Param.Split([';']);
    if Length(Parts) >= 3 then
    begin
      TouchPos := Vector2(StrToFloatDef(Parts[1], 0) * Container.Width, StrToFloatDef(Parts[2], 0) * Container.Height);
      if Action = 'TD' then
        FTouch.TouchDown(StrToIntDef(Parts[0], 0), TouchPos)
      else
        FTouch.TouchMoved(StrToIntDef(Parts[0], 0), TouchPos);
      WritelnLog('GameViewPlay', 'Touch %s %s at %.0f %.0f: %d down, move %.2f %.2f, buttons fire %s jump %s use %s',
        [Action, Parts[0], TouchPos.X, TouchPos.Y, FTouch.ActiveTouches, TouchMove.X, TouchMove.Y,
         BoolToStr(TouchButtons[GamepadFire], 'on', 'off'), BoolToStr(TouchButtons[GamepadJump], 'on', 'off'),
         BoolToStr(TouchButtons[GamepadUse], 'on', 'off')]);
    end;
    Inc(FDemoIndex);
  end else
  if Action = 'TU' then { Touch: TU:id up }
  begin
    FTouch.TouchUp(StrToIntDef(Param, 0));
    Inc(FDemoIndex);
  end else
  if (Action = 'GL') or (Action = 'GR') then { Virtual gamepad stick: x;y in -1..1 }
  begin
    Parts := Param.Split([';']);
    if Length(Parts) >= 2 then
    begin
      if Action = 'GL' then
        FDemoPadLeft := Vector2(StrToFloatDef(Parts[0], 0), StrToFloatDef(Parts[1], 0))
      else
        FDemoPadRight := Vector2(StrToFloatDef(Parts[0], 0), StrToFloatDef(Parts[1], 0));
      SetVirtualSticks(FDemoPadLeft, FDemoPadRight);
    end;
    Inc(FDemoIndex);
  end else
  if Action = 'GT' then { Virtual gamepad right trigger 0..1 }
  begin
    SetVirtualRightTrigger(StrToFloatDef(Param, 0));
    Inc(FDemoIndex);
  end else
  if Action = 'GB' then { Virtual gamepad button pressed for 0.2 s }
  begin
    if GamepadButtonByName(Param, FDemoPadButton) then
    begin
      SetVirtualButton(FDemoPadButton, True);
      FDemoPadRelease := 0.2;
    end else
      WritelnWarning('GameViewPlay', 'Unknown gamepad button "%s"', [Param]);
    Inc(FDemoIndex);
  end else
  if Action = 'F' then { Hold fire for some seconds }
  begin
    FDemoFireTime := StrToFloatDef(Param, 1.0);
    Inc(FDemoIndex);
  end else
  if Action = 'N' then { N:0 draws the whole world (r_novis 1), N:1 only the PVS }
  begin
    WorldPvsCulling := Param <> '0';
    Inc(FDemoIndex);
  end else
  if Action = 'CMD' then { Run a console command: CMD:fov 110 }
  begin
    P := Pos(' ', Param);
    if P > 0 then
      HandleConsoleCommand(LowerCase(Copy(Param, 1, P - 1)), Trim(Copy(Param, P + 1, MaxInt)))
    else
      HandleConsoleCommand(LowerCase(Param), '');
    Inc(FDemoIndex);
  end else
  if Action = 'NC' then { Render this frame with and without PVS culling, log the difference }
  begin
    ComparePvsRender;
    Inc(FDemoIndex);
  end else
  if Action = 'Z' then { Log the frame times since the previous Z, then start counting again }
  begin
    if FBenchStarted and (FBenchFrames > 0) then
      WritelnLog('GameViewPlay', 'Frames: %d in %.2f s, %.2f ms average, %.2f ms longest, %s',
        [FBenchFrames, FBenchStart.ElapsedTime, 1000 * FBenchStart.ElapsedTime / FBenchFrames,
         1000 * FBenchLongest, PvsStatus]);
    FBenchFrames := 0;
    FBenchLongest := 0;
    FBenchStart := Timer;
    FBenchStarted := True;
    Inc(FDemoIndex);
  end else
  if Action = 'B' then { World lighting: B:1 Quake lightmaps, B:0 dynamic PBR (reloads the map) }
  begin
    WorldLightmaps := Param <> '0';
    LoadLevel(FMapName);
    Inc(FDemoIndex);
  end else
  if Action = 'R' then { Record a demo (R:name), or stop it (R) }
  begin
    if Param = '' then
      FWorld.StopRecording
    else
      FWorld.StartRecording('castle-config:/' + Param + '.dem');
    Inc(FDemoIndex);
  end else
  if Action = 'PN' then { The virtual gamepad's name (its button names follow) }
  begin
    SetVirtualPadName(Param);
    Inc(FDemoIndex);
  end else
  if Action = 'O' then { Save game to a slot }
  begin
    SaveGameSlot(Param);
    Inc(FDemoIndex);
  end else
  if Action = 'I' then { Log the scene tree (component names) }
  begin
    LogSceneTree(FViewport.Items, 'GameViewPlay');
    Inc(FDemoIndex);
  end else
  if Action = 'D' then { Debug overlay: D:all, D:triggers;monsters, D:off }
  begin
    FWorld.DebugModes := ParseDebugModes(Param, FWorld.DebugModes);
    Inc(FDemoIndex);
  end else
  if Action = 'L' then { Load game from a slot }
  begin
    LoadGameSlot(Param);
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
var
  PadForward, PadSide: Single;
begin
  FillChar(Cmd, SizeOf(Cmd), 0);
  if (not FConsole.IsOpen) and (not FMenu.Exists) then
  begin
    if BindingHeld(qbForward, Container) then
      Cmd.ForwardMove := Cmd.ForwardMove + ClForwardSpeed;
    if BindingHeld(qbBackward, Container) then
      Cmd.ForwardMove := Cmd.ForwardMove - ClBackSpeed;
    if BindingHeld(qbStrafeRight, Container) then
      Cmd.SideMove := Cmd.SideMove + ClSideSpeed;
    if BindingHeld(qbStrafeLeft, Container) then
      Cmd.SideMove := Cmd.SideMove - ClSideSpeed;
    { The gamepad's left stick }
    GamepadMove(PadForward, PadSide);
    Cmd.ForwardMove := Cmd.ForwardMove + PadForward * ClForwardSpeed;
    Cmd.SideMove := Cmd.SideMove + PadSide * ClSideSpeed;
    { Movement is "always run"; holding the walk key walks instead }
    if BindingHeld(qbWalk, Container) then
    begin
      Cmd.ForwardMove := Cmd.ForwardMove * 0.5;
      Cmd.SideMove := Cmd.SideMove * 0.5;
    end;
    Cmd.Jump := BindingHeld(qbJump, Container) and not FHeldFromMenu;
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
  ApplyVideoSettings(FViewport);
  if FPhoto <> nil then
    FPhoto.ApplyView;
  if FShowFps then
    FHud.FpsText := 'FPS: ' + Container.Fps.ToString
  else
    FHud.FpsText := '';
  FHud.HordeText := FWorld.HordeText;
  FHud.SpeedrunText := FWorld.SpeedrunText;
  if FWorld.HordeActive and FWorld.PlayerDead and not FHordeReported then
    ReportHorde;
  { A map browser download started from the console goes on }
  if MapBrowserCreated then
    MapBrowser.Update;

  { Execute demo commands if any }
  if FDemoCommands.Count > 0 then
    RunDemoStep(SecondsPassed);

  { What picked a menu item must not jump or fire in the game }
  if FMenu.Exists or FConsole.IsOpen then
    FHeldFromMenu := True
  else if FHeldFromMenu and not BindingHeld(qbJump, Container) and not BindingHeld(qbFire, Container) then
    FHeldFromMenu := False;

  { Photo mode: nothing moves but the camera; the gamepad's B or View
    leaves, A takes a photo, Y changes the effect, the bumpers the field of
    view }
  if FPhoto.Active then
  begin
    FTouch.UpdateShown(False);
    UpdateGamepad;
    if not FConsole.IsOpen and not FMenu.Exists then
    begin
      FPhoto.Update(SecondsPassed);
      if GamepadJustPressed(GamepadBackButton) or GamepadJustPressed(gbView) then
        SetPhotoMode(False)
      else if GamepadJustPressed(GamepadConfirmButton) then
        FPhoto.TakePhoto(FPhoto.NextPhotoName(PhotoPrefix))
      else if GamepadJustPressed(gbNorth) then
      begin
        if FPhoto.Effect = High(TPhotoEffect) then
          FPhoto.Effect := Low(TPhotoEffect)
        else
          FPhoto.Effect := Succ(FPhoto.Effect);
      end else
      if GamepadJustPressed(gbLeftBumper) then
        FPhoto.Fov := FPhoto.Fov - 5
      else if GamepadJustPressed(gbRightBumper) then
        FPhoto.Fov := FPhoto.Fov + 5;
    end;
    Exit;
  end;

  { The touch controls while playing; their menu button opens the menu }
  FTouch.UpdateShown(not FConsole.IsOpen and not FMenu.Exists and (FWorld <> nil));
  { No mouse look on a touch screen (a web page turns touch on at the first touch) }
  if TouchControlsWanted and FNavigation.MouseLook then
    FNavigation.MouseLook := False;
  if FTouch.MenuRequested and not FMenu.Exists then
  begin
    FMenu.Exists := True;
    FNavigation.MouseLook := False;
  end;

  { The gamepad: the right stick turns, its buttons are bindings }
  UpdateGamepad;
  if not FConsole.IsOpen and not FMenu.Exists and (FWorld <> nil) then
  begin
    if GamepadJustPressed(gbView) then
    begin
      SetPhotoMode(True);
      Exit;
    end;
    { The menu button (Start, Options, +) opens the menu }
    if GamepadJustPressed(gbMenu) then
    begin
      WritelnLog('GameViewPlay', 'Menu opened from the gamepad');
      FMenu.Exists := True;
      FNavigation.MouseLook := False;
      Exit;
    end;
    GamepadTurnCamera(FViewport.Camera, SecondsPassed);
    if GamepadJustPressed(GamepadUse) then
      FWorld.ActivateUse(FViewport.Camera.Translation, FViewport.Camera.Direction, FHud);
    if GamepadJustPressed(GamepadNextWeapon) then
      FWorld.SelectNextWeapon(1, FHud);
    if GamepadJustPressed(GamepadPrevWeapon) then
      FWorld.SelectNextWeapon(-1, FHud);
  end;

  { Quake player physics moves the player; the camera follows the eyes }
  if (FWorld <> nil) and (FCameraMode <> cmFreeFly) then
  begin
    BuildUserCmd(Cmd);
    FDemoJumpTime := Math.Max(0.0, FDemoJumpTime - SecondsPassed);
    { The press lasts 0.2 s from when the engine reported it (a slow
      headless frame must not release it before it was seen) }
    if (FDemoPadRelease > 0) and GamepadButtonDown(FDemoPadButton) then
    begin
      FDemoPadRelease := FDemoPadRelease - SecondsPassed;
      if FDemoPadRelease <= 0 then
        SetVirtualButton(FDemoPadButton, False);
    end;
    FDemoFireTime := Math.Max(0.0, FDemoFireTime - SecondsPassed);
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
      FWorld.WeaponTransform.Exists := (FCameraMode = cmFirstPerson) and not FWorld.Intermission and ShowWeapon;

    UpdateViewContents(SecondsPassed);

    { Handle level transition }
    if FWorld.LevelExited and (FWorld.NextMap <> '') then
      LoadLevel(FWorld.NextMap);
    { The ending was played and dismissed: a fresh game in the hub, with
      the menu open }
    if FWorld.GameOver then
    begin
      FWorld.NewGame;
      LoadLevel('start');
      FMenu.Exists := True;
      FNavigation.MouseLook := False;
      Exit;
    end;

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

  { Draw only the world in the camera's potentially visible set }
  if (FWorld <> nil) and (FWorld.Geometry <> nil) then
  begin
    FWorld.Geometry.UpdateVisibility(FViewport.Camera.Translation);
    FWorld.CullEntities;
  end;
  Inc(FBenchFrames);
  FBenchLongest := Math.Max(FBenchLongest, SecondsPassed);

  { Attack trigger while fire key is held }
  if not FConsole.IsOpen and not FMenu.Exists and not FWorld.PlayerDead then
  begin
    if (BindingHeld(qbFire, Container) and not FHeldFromMenu) or (FDemoFireTime > 0) then
    begin
      RayOrigin := FViewport.Camera.Translation;
      RayDir := FViewport.Camera.Direction;
      FWorld.FireWeapon(RayOrigin, RayDir, FHud);
    end;
  end;

  { V_CalcBob, last: the shots and the contents use the eye itself; the
    physics puts the camera back on the eye next frame }
  if FWorld <> nil then
  begin
    FBobTime := FBobTime + SecondsPassed;
    if (FCameraMode = cmFirstPerson) and not FWorld.Intermission and not FWorld.PlayerDead then
      FWorld.WeaponBob := CalcViewBob(FBobTime, FWorld.PlayerVelocity)
    else
      FWorld.WeaponBob := 0;
    FViewport.Camera.Translation := FViewport.Camera.Translation + Vector3(0, FWorld.WeaponBob, 0);
  end;
end;

function TViewPlay.Press(const Event: TInputPressRelease): Boolean;
var
  RayOrigin, RayDir: TVector3;
  I: Integer;
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
      FNavigation.MouseLook := not TouchControlsWanted;
      Exit(True);
    end;
    Result := FMenu.Press(Event);
    { A tap outside the main menu's items goes back to the game }
    if not Result and (Event.EventType = itMouseButton) then
    begin
      FMenu.Exists := False;
      FNavigation.MouseLook := not TouchControlsWanted;
      Result := True;
    end;
    Exit;
  end;

  { Open console with backquote / tilde }
  if BindingEvent(qbConsole, Event) or (Event.KeyString = '~') or (Event.KeyString = '`') then
  begin
    FConsole.Toggle;
    Exit(True);
  end;

  { Photo mode takes the keys: Escape or the photo binding leaves, Enter or
    the screenshot binding takes a photo }
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

  { Open menu with Escape }
  if Event.IsKey(keyEscape) then
  begin
    FMenu.Exists := True;
    FNavigation.MouseLook := False;
    Exit(True);
  end;

  { Weapon fire (the fire binding is also held in Update) }
  if BindingEvent(qbFire, Event) then
  begin
    RayOrigin := FViewport.Camera.Translation;
    RayDir := FViewport.Camera.Direction;
    FWorld.FireWeapon(RayOrigin, RayDir, FHud);
    Exit(True);
  end;

  { Activate / Use }
  if BindingEvent(qbUse, Event) then
  begin
    RayOrigin := FViewport.Camera.Translation;
    RayDir := FViewport.Camera.Direction;
    FWorld.ActivateUse(RayOrigin, RayDir, FHud);
    Exit(True);
  end;

  { Weapon slot selection }
  for I := 1 to 8 do
    if BindingEvent(TQuakeBinding(Ord(qbWeapon1) + I - 1), Event) then
    begin
      FWorld.SelectWeapon(I, FHud);
      Exit(True);
    end;
  if BindingEvent(qbNextWeapon, Event) then
  begin
    FWorld.SelectNextWeapon(1, FHud);
    Exit(True);
  end;
  if BindingEvent(qbPrevWeapon, Event) then
  begin
    FWorld.SelectNextWeapon(-1, FHud);
    Exit(True);
  end;

  { Toggle Camera mode }
  if BindingEvent(qbCamera, Event) then
  begin
    if FCameraMode = cmFirstPerson then
      SetCameraMode(cmThirdPerson)
    else if FCameraMode = cmThirdPerson then
      SetCameraMode(cmFreeFly)
    else
      SetCameraMode(cmFirstPerson);
    Exit(True);
  end;

  { Toggle Shadows }
  if BindingEvent(qbShadows, Event) then
  begin
    Lighting.ShadowsEnabled := not Lighting.ShadowsEnabled;
    FMenu.ShadowsEnabled := Lighting.ShadowsEnabled;
    if Lighting.ShadowsEnabled then
      FHud.ShowMessage('Dynamic Shadows: ON')
    else
      FHud.ShowMessage('Dynamic Shadows: OFF');
    Exit(True);
  end;

  { Quicksave / quickload like Quake }
  if BindingEvent(qbQuickSave, Event) then
  begin
    SaveGameSlot('quick');
    Exit(True);
  end;
  if BindingEvent(qbQuickLoad, Event) then
  begin
    LoadGameSlot('quick');
    Exit(True);
  end;

  { Screenshot }
  if BindingEvent(qbScreenshot, Event) then
  begin
    CaptureScreenshot('screenshot');
    FHud.ShowMessage('Screenshot saved');
    Exit(True);
  end;
end;

procedure TViewPlay.HandleConsoleCommand(const Cmd, Args: String);
var
  Parts: TStringArray;
  FogColor: TVector3;
  SkyName: String;
begin
  if (Cmd = 'map') or (Cmd = 'warp') then
  begin
    if Args <> '' then
      LoadLevel(Args)
    else
      FConsole.Print('Usage: map <mapname>');
  end else
  if Cmd = 'save' then
  begin
    if Args <> '' then
      SaveGameSlot(Args)
    else
      SaveGameSlot('quick');
  end else
  if Cmd = 'load' then
  begin
    if Args <> '' then
      LoadGameSlot(Args)
    else
      LoadGameSlot('quick');
  end else
  if Cmd = 'debug' then
  begin
    { Debug overlay: debug triggers,monsters,movers,leaf | all | off }
    FWorld.DebugModes := ParseDebugModes(Args, FWorld.DebugModes);
    FConsole.Print('Debug overlay: ' + DebugModesToString(FWorld.DebugModes));
  end else
  if Cmd = 'fps' then
  begin
    FShowFps := not FShowFps;
    FConsole.Print('FPS display: ' + BoolToStr(FShowFps, 'on', 'off'));
  end else
  if Cmd = 'novis' then
  begin
    { r_novis: 1 draws the whole world, 0 only the camera's PVS }
    if Args <> '' then
      WorldPvsCulling := not ((Args = '1') or (Args = 'on'));
    FConsole.Print('PVS culling: ' + BoolToStr(WorldPvsCulling, 'on', 'off') + ' (' + PvsStatus + ')');
  end else
  if (Cmd = 'captions') or (Cmd = 'hud_contrast') or (Cmd = 'reduced_flashes') then
  begin
    { Accessibility options (saved like the Options menu ones) }
    if Args <> '' then
    begin
      if Cmd = 'captions' then
        CaptionsEnabled := (Args = '1') or (Args = 'on')
      else if Cmd = 'hud_contrast' then
        HighContrastHud := (Args = '1') or (Args = 'on')
      else
        ReducedFlashes := (Args = '1') or (Args = 'on');
      SaveVideoSettings;
    end;
    FConsole.Print(Format('captions %d, hud_contrast %d, reduced_flashes %d',
      [Ord(CaptionsEnabled), Ord(HighContrastHud), Ord(ReducedFlashes)]));
  end else
  if (Cmd = 'fov') or (Cmd = 'gamma') or (Cmd = 'cl_bob') or (Cmd = 'r_drawviewmodel') then
  begin
    { Video options (saved like the Options menu ones); no argument shows them }
    if Args <> '' then
    begin
      if Cmd = 'fov' then
        VideoFov := EnsureRange(StrToFloatDef(Args, VideoFov), 50, 130)
      else if Cmd = 'gamma' then
        VideoGamma := EnsureRange(StrToFloatDef(Args, VideoGamma), 0.4, 1.5)
      else if Cmd = 'cl_bob' then
        ViewBob := EnsureRange(StrToFloatDef(Args, ViewBob), 0, 0.1)
      else
        ShowWeapon := (Args = '1') or (Args = 'on');
      SaveVideoSettings;
    end;
    FConsole.Print(Format('fov %.0f (vertical %.1f), gamma %.2f, cl_bob %.3f, r_drawviewmodel %d',
      [VideoFov, RadToDeg(VerticalFov), VideoGamma, ViewBob, Ord(ShowWeapon)]));
  end else
  if Cmd = 'fog' then
  begin
    { FitzQuake's fog: fog <density> [r g b] for this level, 0 off; no
      argument shows it }
    if Args <> '' then
    begin
      Parts := Args.Split([' '], TStringSplitOptions.ExcludeEmpty);
      FogColor := Vector3(0.3, 0.3, 0.3);
      if Length(Parts) >= 4 then
        FogColor := Vector3(StrToFloatDef(Parts[1], 0.3), StrToFloatDef(Parts[2], 0.3), StrToFloatDef(Parts[3], 0.3));
      SetViewportFog(FViewport, StrToFloatDef(Parts[0], 0), FogColor);
      FWorld.RecordFog(StrToFloatDef(Parts[0], 0), FogColor);
    end;
    if FViewport.Fog <> nil then
      FConsole.Print(Format('Fog: visibility range %.0f, color %s',
        [FViewport.Fog.VisibilityRange, FViewport.Fog.Color.ToString]))
    else
      FConsole.Print('Fog: off');
  end else
  if Cmd = 'sky' then
  begin
    { FitzQuake's sky: sky <name> shows the skybox gfx/env/<name>, sky ""
      or sky - the map's scrolling sky; no argument shows it }
    if (Args <> '') and (FWorld.Geometry <> nil) then
    begin
      SkyName := LowerCase(Args);
      if (SkyName = '-') or (SkyName = '""') then
        SkyName := '';
      if FWorld.Geometry.SetSkybox(SkyName) then
        FWorld.RecordSkybox(FWorld.Geometry.Skybox);
    end;
    if (FWorld.Geometry <> nil) and (FWorld.Geometry.Skybox <> '') then
      FConsole.Print('Sky: ' + FWorld.Geometry.Skybox)
    else
      FConsole.Print('Sky: the scrolling sky');
  end else
  if Cmd = 'lightmaps' then
  begin
    { 1 = Quake lightmaps blended in the shader, 0 = dynamic PBR lighting;
      the current map is rebuilt }
    if Args <> '' then
    begin
      WorldLightmaps := (Args = '1') or (Args = 'on');
      LoadLevel(FMapName);
    end;
    FConsole.Print('Lightmaps: ' + BoolToStr(WorldLightmaps, True));
  end else
  if Cmd = 'record' then
  begin
    if Args = '' then
      FConsole.Print('Usage: record <name>')
    else if FWorld.StartRecording('castle-config:/' + Args + '.dem') then
      FConsole.Print('Recording to ' + Args + '.dem')
    else
      FConsole.Print('Cannot record now');
  end else
  if Cmd = 'stop' then
  begin
    if FWorld.Recording then
    begin
      FWorld.StopRecording;
      FConsole.Print('Recording stopped');
    end else
      FConsole.Print('Not recording');
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
  if Cmd = 'horde' then
  begin
    { horde [0|1]: restart the map with waves of monsters (or without) }
    if Args <> '' then
      FHordeMode := (Args = '1') or (Args = 'on')
    else
      FHordeMode := not FHordeMode;
    FConsole.Print('Horde mode: ' + BoolToStr(FHordeMode, 'on', 'off'));
    FWorld.RespawnPlayer;
    LoadLevel(FMapName);
  end else
  if (Cmd = 'speedrun') or (Cmd = 'ghost') then
  begin
    { speedrun [0|1]: the timer; ghost [0|1]: race the best run (from the
      next map load; saved like the Options ones) }
    if Args <> '' then
    begin
      if Cmd = 'speedrun' then
        SpeedrunTimer := (Args = '1') or (Args = 'on')
      else
        GhostRacing := (Args = '1') or (Args = 'on');
      SaveVideoSettings;
    end;
    FConsole.Print(Format('speedrun %d, ghost %d', [Ord(SpeedrunTimer), Ord(GhostRacing)]));
  end else
  if Cmd = 'ghost_reset' then
  begin
    FWorld.ResetGhost;
    FConsole.Print('Best run of ' + FWorld.MapName + ' forgotten');
  end else
  if Cmd = 'saves' then
    ListSavesCommand
  else
  if Cmd = 'photo' then
  begin
    { photo [0|1]: photo mode (toggles without an argument) }
    if Args <> '' then
      SetPhotoMode((Args = '1') or (Args = 'on'))
    else
      SetPhotoMode(not FPhoto.Active);
    FConsole.Print('Photo mode: ' + BoolToStr(FPhoto.Active, 'on', 'off'));
  end else
  if (Cmd = 'photo_fov') or (Cmd = 'photo_effect') or (Cmd = 'photo_scale') or (Cmd = 'photo_shot') then
    FConsole.Print(FPhoto.Command(Cmd, Args, PhotoPrefix))
  else
  if (Cmd = 'maps') or (Cmd = 'maps_install') or (Cmd = 'maps_play') or (Cmd = 'maps_remove') then
    MapBrowserCommand(Cmd, Args)
  else
  if Cmd = 'killall' then
  begin
    FWorld.KillAllMonsters;
    FConsole.Print('Killed every monster');
  end else
  if (Cmd = 'give') and (Args = 'all') then
  begin
    FWorld.CheatGiveAll(FHud);
    FConsole.Print('Gave all weapons, keys and ammo');
  end else
  if Cmd = 'wateralpha' then
  begin
    { r_wateralpha: 1 opaque, 0 invisible }
    if FWorld.Geometry <> nil then
      FWorld.Geometry.LiquidAlpha := EnsureRange(StrToFloatDef(Args, 0.65), 0, 1);
    FConsole.Print(Format('Water alpha: %.2f', [DefaultLiquidAlpha]));
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
    FConsole.Print('  record <name>  - Record a demo to <name>.dem, stop ends it');
    FConsole.Print('  save [slot]    - Save the game (F6 = quick)');
    FConsole.Print('  load [slot]    - Load a saved game (F9 = quick)');
    FConsole.Print('  god            - God mode');
    FConsole.Print('  give all       - Give all weapons, ammo, keys');
    FConsole.Print('  shadows <0|1>  - Toggle dynamic shadows');
    FConsole.Print('  wateralpha <0..1> - Opacity of water, slime and lava');
    FConsole.Print('  fog <density> [r g b] - Fog for this level (0 off)');
    FConsole.Print('  captions <0|1>, hud_contrast <0|1>, reduced_flashes <0|1> - Accessibility');
    FConsole.Print('  horde [0|1]    - Waves of monsters on this map; killall - every monster dies');
    FConsole.Print('  speedrun [0|1], ghost [0|1], ghost_reset - Timer, race the best run, forget it');
    FConsole.Print('  saves          - List the saved games (the Load Game menu)');
    FConsole.Print('  photo [0|1] (P) - Photo mode: the game pauses, the camera flies; photo_fov <deg>,');
    FConsole.Print('    photo_effect <none|dof|gray|sepia|vignette|ao>, photo_scale <1..4>, photo_shot');
    FConsole.Print('  maps [rating|newest|name|installed] [text] - Quaddicted maps; maps_install <id>,');
    FConsole.Print('    maps_play <id> [map], maps_remove <id> - download, play and remove one');
    FConsole.Print('  sky <name> - Skybox gfx/env/<name> for this level (- the scrolling sky)');
    FConsole.Print('  fov <degrees>  - Field of view at 4:3 (wider screens see more)');
    FConsole.Print('  gamma <0.4..1.5> - Brightness, lower is brighter');
    FConsole.Print('  cl_bob <0..0.1> - View bob (0 off), r_drawviewmodel <0|1> - the weapon');
    FConsole.Print('  lightmaps <0|1> - Quake lightmaps or dynamic PBR world lighting');
    FConsole.Print('  debug <modes>  - Overlay: triggers, monsters, movers, leaf, all, off');
    FConsole.Print('  fps            - Show the frame rate in the stats line');
    FConsole.Print('  novis <0|1>    - 1 draws the whole world, 0 only what the PVS can see');
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
        FNavigation.MouseLook := not TouchControlsWanted;
        Pak.PreferOriginal := Param = 'quake';
        FWorld.NewGame;
        LoadLevel('start');
      end;
    maWarpMap:
      begin
        FMenu.Exists := False;
        FNavigation.MouseLook := not TouchControlsWanted;
        Pak.PreferOriginal := (Param <> 'maps/start.bsp') and Pak.OriginalFileExists(Param);
        FWorld.NewGame;
        LoadLevel(Param);
      end;
    maSaveGame:
      SaveGameSlot(Param);
    maCloseMenu:
      begin
        WritelnLog('GameViewPlay', 'Menu closed from the gamepad');
        FMenu.Exists := False;
        FNavigation.MouseLook := not TouchControlsWanted;
      end;
    maLoadGame:
      begin
        FMenu.Exists := False;
        FNavigation.MouseLook := not TouchControlsWanted;
        LoadGameSlot(Param);
      end;
    maToggleShadows:
      begin
        Lighting.ShadowsEnabled := FMenu.ShadowsEnabled;
      end;
    maToggleLighting:
      begin
        if WorldLightmaps then
          FHud.ShowMessage('World lighting: Quake lightmaps (from the next map)', 3)
        else
          FHud.ShowMessage('World lighting: dynamic PBR (from the next map)', 3);
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
