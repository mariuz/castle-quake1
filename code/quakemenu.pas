{ Quake Main Menu: New Game, Episode/Map Select, Options, and CGE Showcase. }
unit QuakeMenu;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math,
  CastleVectors, CastleUIControls, CastleControls, CastleKeysMouse, CastleColors,
  CastleRectangles, CastleGLUtils, CastleImages, CastleFindFiles, CastleUriUtils, CastleComponentSerialize,
  CastleGameControllers,
  QuakeSound, QuakePak, QuakeGeometry, QuakeMapBrowser, GameInput, GameVideo;

type
  TMenuAction = (
    maNone, maNewGame, maWarpMap, maPlayDemo, maPlayQc, maHostGame, maJoinGame, maToggleShadows,
    maToggleLighting, maToggleCamera, maToggleSound, maQuit, maSaveGame, maLoadGame, maCloseMenu
  );

  TOnMenuActionEvent = procedure(const Action: TMenuAction; const Param: String) of object;

  { Quake Title and Main Menu }
  TQuakeMenu = class(TCastleUserInterface)
  private
    FSelectedIdx: Integer;
    FSubMenu: (smMain, smEpisodes, smMultiplayer, smMaps, smDemos, smOptions, smControls, smShowcase,
      smBrowser, smBrowserMap, smLoad, smSave, smLan);
    { Load / Save Game: what each item does (load:<slot>, save:<slot>, back),
      the thumbnail shown, a game running (Save Game offered) }
    FSlotActions: TStringList;
    FThumbnailUrl: String;
    FInGame: Boolean;
    FLoggedHint: String;
    FThumbnailFrame: TCastleUserInterface;
    FThumbnail: TCastleImageControl;
    { Map browser: the list's sort and page, the map shown, what each item
      does (BrowserActions, parallel to FItems), a download to play when it
      is done, the state the items were built for }
    FBrowserSort: TMapSort;
    FBrowserPage: Integer;
    FBrowserMap: Integer;
    FBrowserActions: TStringList;
    FPlayAfterInstall: Integer;
    FBrowserBuiltFor: String;
    { Find LAN Games: the search's state the items were built for }
    FLanBuiltFor: String;
    FBindWaiting: Boolean; { Controls: the next key / button goes to FBindTarget }
    FBindTarget: TQuakeBinding;
    FDefaultHint: String;
    FLanguageVersion: Integer;
    FDemoUrls: TStringList;
    FItems: TStringList;
    FOnMenuAction: TOnMenuActionEvent;
    FShadowsEnabled: Boolean;
    FCameraModeName: String;
    FVolume: Integer;
    { The editor design (data/ui/menu.castle-user-interface) }
    FDesign: TCastleUserInterface;
    FItemsGroup: TCastleVerticalGroup;
    FShowcaseLabel, FHintLabel: TCastleLabel;
    FItemLabels: array of TCastleLabel;
    procedure RebuildMenuItems;
    procedure ExecuteSelection;
    procedure SyncDesign;
    procedure BuildBrowserItems;
    procedure BrowserAction(const Action: String);
    function BrowserState: String;
    function LanState: String;
    procedure GoBack;
    procedure BuildSlotItems;
    procedure UpdateThumbnail;
    procedure SetInGame(const Value: Boolean);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    function Press(const Event: TInputPressRelease): Boolean; override;
    procedure Update(const SecondsPassed: Single; var HandleInput: Boolean); override;

    property OnMenuAction: TOnMenuActionEvent read FOnMenuAction write FOnMenuAction;
    property ShadowsEnabled: Boolean read FShadowsEnabled write FShadowsEnabled;
    property CameraModeName: String read FCameraModeName write FCameraModeName;
    { A game is running: the main menu offers Save Game }
    property InGame: Boolean read FInGame write SetInGame;
  end;

implementation

uses
  GameTranslate,
  StrUtils, CastleLog, QuakeRandomMap, QuakeCaptions, QuakeWorld, QuakeSaveGame, QuakeNet;

constructor TQuakeMenu.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FullSize := True;
  FItems := TStringList.Create;
  FDemoUrls := TStringList.Create;
  FBrowserActions := TStringList.Create;
  FSlotActions := TStringList.Create;
  FBrowserMap := -1;
  FPlayAfterInstall := -1;
  FSelectedIdx := 0;
  FSubMenu := smMain;
  FShadowsEnabled := False;
  FCameraModeName := 'First-Person';
  FVolume := 100;
  { The layout, fonts and colors come from the editor design }
  FDesign := UserInterfaceLoad('castle-data:/ui/menu.castle-user-interface', Self);
  InsertFront(FDesign);
  FItemsGroup := FindRequiredComponent('ItemsGroup') as TCastleVerticalGroup;
  FShowcaseLabel := FindRequiredComponent('ShowcaseLabel') as TCastleLabel;
  FHintLabel := FindRequiredComponent('HintLabel') as TCastleLabel;
  { The design's hint in English (shown translated) }
  FDefaultHint := FHintLabel.Caption;
  FHintLabel.Alignment := hpMiddle;
  FThumbnailFrame := FindRequiredComponent('SaveThumbnailFrame') as TCastleUserInterface;
  FThumbnail := FindRequiredComponent('SaveThumbnail') as TCastleImageControl;
  RebuildMenuItems;
  SyncDesign;
end;

const
  { The item group's top above the middle in the design, and how much
    higher a page too long for it starts }
  DesignItemsTop = 100;
  LongPageRaise = 70;

procedure TQuakeMenu.SyncDesign;
var
  I: Integer;
  L: TCastleLabel;
  Avail, RowHeight: Single;
begin
  { The design's own texts in the current language }
  if FLanguageVersion <> LanguageVersion then
  begin
    FLanguageVersion := LanguageVersion;
    TranslateDesign(Self);
  end;
  { One label per item in the vertical group, the selected one marked }
  while Length(FItemLabels) > FItems.Count do
  begin
    FItemLabels[High(FItemLabels)].Free;
    SetLength(FItemLabels, Length(FItemLabels) - 1);
  end;
  while Length(FItemLabels) < FItems.Count do
  begin
    L := TCastleLabel.Create(Self);
    L.Name := 'MenuItem' + IntToStr(Length(FItemLabels));
    FItemsGroup.InsertFront(L);
    SetLength(FItemLabels, Length(FItemLabels) + 1);
    FItemLabels[High(FItemLabels)] := L;
  end;
  { A long page (or longer translations) shrinks to fit between the
    group's top and the hint line }
  Avail := EffectiveHeight / 2 + DesignItemsTop - 80;
  RowHeight := 34;
  if (FItems.Count > 0) and (FItems.Count * RowHeight > Avail) then
  begin
    { Up to the subtitle, then smaller rows }
    Avail := Avail + LongPageRaise;
    RowHeight := Max(14, Avail / FItems.Count);
    FItemsGroup.Translation := Vector2(0, DesignItemsTop + LongPageRaise);
  end else
    FItemsGroup.Translation := Vector2(0, DesignItemsTop);
  if RowHeight >= 34 then
    FItemsGroup.Spacing := 12
  else
    FItemsGroup.Spacing := Max(2, RowHeight * 0.2);
  for I := 0 to FItems.Count - 1 do
  begin
    { 0 is the design's own size }
    if RowHeight >= 34 then
      FItemLabels[I].FontSize := 0
    else
      FItemLabels[I].FontSize := (RowHeight - FItemsGroup.Spacing) / 1.2;
    if I = FSelectedIdx then
    begin
      FItemLabels[I].Caption := '> ' + TrItem(FItems[I]) + ' <';
      FItemLabels[I].Color := Vector4(1.0, 0.85, 0.15, 1.0);
    end else
    begin
      FItemLabels[I].Caption := TrItem(FItems[I]);
      FItemLabels[I].Color := Vector4(0.75, 0.75, 0.75, 0.9);
    end;
  end;
  UpdateThumbnail;
  FShowcaseLabel.Exists := FSubMenu = smShowcase;
  FItemsGroup.Exists := FSubMenu <> smShowcase;
  FHintLabel.Exists := FSubMenu <> smShowcase;
  if FDefaultHint = '' then
    FDefaultHint := FHintLabel.Caption;
  if FBindWaiting then
    FHintLabel.Caption := Format(Tr('Press a key, mouse button or wheel for "%s" (Escape keeps it)'),
      [Tr(BindingCaptions[FBindTarget])])
  else
  if FSubMenu = smControls then
    FHintLabel.Caption := Format(Tr('Enter rebinds; the gamepad: left stick moves, right stick turns, %s jumps, ' +
      '%s uses, %s / %s fires, D-pad changes weapons, %s photo mode, %s menu'), [GamepadButtonLabel(GamepadJump),
      GamepadButtonLabel(GamepadUse), GamepadButtonLabel(GamepadFire), GamepadTriggerLabel,
      GamepadButtonLabel(gbView), GamepadButtonLabel(gbMenu)])
  else
  if (FSubMenu in [smBrowser, smBrowserMap]) and (MapBrowser.Status <> '') then
    FHintLabel.Caption := MapBrowser.Status
  else
  if (FSubMenu in [smBrowser, smBrowserMap]) and GamepadConnected then
    FHintLabel.Caption := Format(Tr('%d maps from Quaddicted: %s shows one, %s goes back, left / right turn the pages'),
      [MapBrowser.Count, GamepadButtonLabel(GamepadConfirmButton), GamepadButtonLabel(GamepadBackButton)])
  else
  if FSubMenu in [smBrowser, smBrowserMap] then
    FHintLabel.Caption := Format(Tr('%d maps from Quaddicted: Enter shows one, Escape goes back'), [MapBrowser.Count])
  else
  if GamepadConnected then
    FHintLabel.Caption := Format(Tr('D-pad to navigate, %s to select, %s to go back'), [
      GamepadButtonLabel(GamepadConfirmButton), GamepadButtonLabel(GamepadBackButton)])
  else
    FHintLabel.Caption := Tr(FDefaultHint);
  { A long hint (and translations are longer) wraps instead of leaving the window }
  FHintLabel.MaxWidth := Max(200, EffectiveWidth - 60);
  if FHintLabel.Caption <> FLoggedHint then
  begin
    FLoggedHint := FHintLabel.Caption;
    WritelnLog('Menu', 'Hint: ' + FLoggedHint);
  end;
end;

procedure TQuakeMenu.Update(const SecondsPassed: Single; var HandleInput: Boolean);
var
  N: Integer;
begin
  inherited Update(SecondsPassed, HandleInput);
  { The gamepad walks the menu: D-pad, A selects, B goes back }
  if Exists and not FBindWaiting and (FItems.Count > 0) then
  begin
    UpdateGamepad;
    if GamepadJustPressed(gbDPadUp) then
    begin
      FSelectedIdx := (FSelectedIdx - 1 + FItems.Count) mod FItems.Count;
      Sounds.Play('sound/misc/menu1.wav');
    end;
    if GamepadJustPressed(gbDPadDown) then
    begin
      FSelectedIdx := (FSelectedIdx + 1) mod FItems.Count;
      Sounds.Play('sound/misc/menu1.wav');
    end;
    if GamepadJustPressed(GamepadConfirmButton) then
      ExecuteSelection;
    { Map browser: the D-pad's left / right turn the pages }
    if (FSubMenu = smBrowser) and GamepadJustPressed(gbDPadRight) and (FBrowserActions.IndexOf('next') >= 0) then
      BrowserAction('next');
    if (FSubMenu = smBrowser) and GamepadJustPressed(gbDPadLeft) and (FBrowserActions.IndexOf('prev') >= 0) then
      BrowserAction('prev');
    { The menu button, or back on the main page, closes the menu in a game }
    if (GamepadJustPressed(gbMenu) or (GamepadJustPressed(GamepadBackButton) and (FSubMenu = smMain))) and
       FInGame and Assigned(FOnMenuAction) then
      FOnMenuAction(maCloseMenu, '');
    if GamepadJustPressed(GamepadBackButton) and (FSubMenu <> smMain) then
    begin
      GoBack;
      Sounds.Play('sound/misc/menu3.wav');
    end;
  end;
  { Find LAN Games: the answers come in, the items follow }
  if Exists and (FSubMenu = smLan) then
  begin
    LanDiscovery.Update(SecondsPassed);
    if LanState <> FLanBuiltFor then
    begin
      N := FSelectedIdx;
      RebuildMenuItems;
      FSelectedIdx := Min(N, FItems.Count - 1);
    end;
  end;
  { Map browser: the download goes on; the items follow its state (and a
    finished "download and play" plays) }
  if Exists and (FSubMenu in [smBrowser, smBrowserMap]) then
  begin
    MapBrowser.Update;
    if (FPlayAfterInstall >= 0) and not MapBrowser.Downloading then
    begin
      FBrowserMap := FPlayAfterInstall;
      FPlayAfterInstall := -1;
      if MapBrowser.Installed(FBrowserMap) then
        BrowserAction('play:' + MapBrowser[FBrowserMap].StartMaps[0]);
    end;
    if BrowserState <> FBrowserBuiltFor then
    begin
      N := FSelectedIdx;
      RebuildMenuItems;
      FSelectedIdx := Min(N, FItems.Count - 1);
    end;
  end;
  SyncDesign;
end;

destructor TQuakeMenu.Destroy;
begin
  FItems.Free;
  FDemoUrls.Free;
  FBrowserActions.Free;
  FSlotActions.Free;
  inherited Destroy;
end;

procedure TQuakeMenu.RebuildMenuItems;
var
  PakFiles: TStringList;
  Found: TFileInfoList;
  I: Integer;
  B: TQuakeBinding;
begin
  FItems.Clear;
  case FSubMenu of
    smMain:
      begin
        FItems.Add('Single Player');
        FItems.Add('Multiplayer');
        FItems.Add('Map Warp');
        FItems.Add('Map Browser');
        if FInGame then
          FItems.Add('Save Game');
        FItems.Add('Load Game');
        FItems.Add('Demos');
        FItems.Add('Options');
        FItems.Add('CGE Features Showcase');
        FItems.Add('Quit');
      end;
    smEpisodes:
      begin
        { The id1 hub (episode and skill portals) when an original Quake pak
          provides it, and the bundled LibreQuake hub }
        if Pak.OriginalFileExists('maps/start.bsp') then
          FItems.Add('Quake: Episode Hub');
        FItems.Add('LibreQuake: Episode Hub');
        FItems.Add('Random Map: a new level from a seed');
        FItems.Add('Horde Mode: waves of monsters on E1M1');
        FItems.Add('Horde Mode: a random map');
        FItems.Add('QuakeC Mode: progs.dat runs the game');
        FItems.Add('Back to Main Menu');
      end;
    smMultiplayer:
      begin
        FItems.Add('Host Deathmatch: start (port 26000)');
        FItems.Add('Host Deathmatch: e1m1 (port 26000)');
        FItems.Add('Host Coop: e1m1 (port 26000)');
        FItems.Add('Split-Screen Coop: e1m1 (gamepad for player 2)');
        FItems.Add('Host Deathmatch: random map (port 26000)');
        FItems.Add('Deathmatch vs 3 bots: start');
        FItems.Add('Deathmatch vs 3 bots: e1m1');
        FItems.Add('Team Deathmatch with 3 bots: e1m1');
        FItems.Add('Coop with 2 bots: e1m1');
        FItems.Add('Find LAN Games');
        FItems.Add('Join: localhost');
        FItems.Add('Spectate: localhost');
        FItems.Add('Back to Main Menu');
      end;
    smLan:
      begin
        { The games the search found so far, then what it is doing }
        for I := 0 to LanDiscovery.Count - 1 do
          FItems.Add(LanDiscovery.Describe(I));
        if LanDiscovery.Searching then
          FItems.Add('Searching the local network...')
        else if LanDiscovery.Count = 0 then
          FItems.Add('No games found on the local network');
        FItems.Add('Search Again');
        FItems.Add('Back to Multiplayer');
        FLanBuiltFor := LanState;
      end;
    smMaps:
      begin
        FItems.Add('maps/start.bsp');
        FItems.Add('maps/e1m1.bsp');
        FItems.Add('maps/e1m2.bsp');
        FItems.Add('maps/e1m3.bsp');
        FItems.Add('maps/lq_e0m1.bsp');
        FItems.Add('maps/lq_e0m2.bsp');
        { Random maps: a new seed, and a few fixed ones to come back to }
        FItems.Add('Random map: new seed');
        FItems.Add('maps/random1.bsp');
        FItems.Add('maps/random42.bsp');
        FItems.Add('maps/random1234.bsp');
        FItems.Add('Back to Main Menu');
      end;
    smDemos:
      begin
        { Demos from the PAKs and recordings in the config directory }
        FDemoUrls.Clear;
        PakFiles := Pak.FindFiles('', '.dem');
        try
          PakFiles.Sort;
          for I := 0 to PakFiles.Count - 1 do
          begin
            FItems.Add(PakFiles[I]);
            FDemoUrls.Add(PakFiles[I]);
          end;
        finally
          PakFiles.Free;
        end;
        try
          Found := FindFilesList('castle-config:/', '*.dem', False, []);
          try
            Found.SortUrls;
            for I := 0 to Found.Count - 1 do
            begin
              FItems.Add('recorded: ' + Found[I].Name);
              FDemoUrls.Add(Found[I].Url);
            end;
          finally
            Found.Free;
          end;
        except
          { no config directory yet }
        end;
        FItems.Add('Back to Main Menu');
      end;
    smOptions:
      begin
        if FShadowsEnabled then
          FItems.Add('Dynamic Shadows: [ON]')
        else
          FItems.Add('Dynamic Shadows: [OFF]');
        if WorldLightmaps then
          FItems.Add('World Lighting: [Quake Lightmaps]')
        else
          FItems.Add('World Lighting: [Dynamic PBR]');
        FItems.Add('Camera View: [' + FCameraModeName + ']');
        FItems.Add('Sound Effects: [' + IntToStr(FVolume) + '%]');
        FItems.Add(Format('Field of View: [%d]', [Round(VideoFov)]));
        FItems.Add(Format('Brightness (gamma): [%.2f]', [VideoGamma]));
        if ViewBob > 0 then
          FItems.Add('View Bob: [ON]')
        else
          FItems.Add('View Bob: [OFF]');
        if ShowWeapon then
          FItems.Add('Show Weapon: [ON]')
        else
          FItems.Add('Show Weapon: [OFF]');
        FItems.Add('Captions: [' + BoolToStr(CaptionsEnabled, 'ON', 'OFF') + ']');
        FItems.Add('High Contrast HUD: [' + BoolToStr(HighContrastHud, 'ON', 'OFF') + ']');
        FItems.Add('Reduced Flashes: [' + BoolToStr(ReducedFlashes, 'ON', 'OFF') + ']');
        FItems.Add('Speedrun Timer: [' + BoolToStr(SpeedrunTimer, 'ON', 'OFF') + ']');
        FItems.Add('Ghost of the Best Run: [' + BoolToStr(GhostRacing, 'ON', 'OFF') + ']');
        FItems.Add('Shirt Color: [' + IntToStr(PlayerShirt) + ']');
        FItems.Add('Pants Color: [' + IntToStr(PlayerPants) + ']');
        if LanguageSetting = '' then
          FItems.Add('Language: [Auto: ' + CurrentLanguageName + ']')
        else
          FItems.Add('Language: [' + LanguageName(LanguageSetting) + ']');
        FItems.Add('Controls');
        FItems.Add('Back to Main Menu');
      end;
    smControls:
      begin
        for B := Low(TQuakeBinding) to High(TQuakeBinding) do
          FItems.Add(BindingCaptions[B] + ': ' + BindingDescription(B));
        FItems.Add('Gamepad: ' + GamepadName + ' (' + PadFamilyNames[GamepadFamily] + ' buttons)');
        FItems.Add(Format('Gamepad look sensitivity: %.2fx', [GamepadSensitivity]));
        FItems.Add(Format('Gamepad dead zone: %.2f', [GamepadDeadZone]));
        if GamepadInvertLook then
          FItems.Add('Gamepad invert look: [ON]')
        else
          FItems.Add('Gamepad invert look: [OFF]');
        if GamepadLayout = plAuto then
          FItems.Add('Gamepad button names: [Auto: ' + PadFamilyNames[GamepadFamily] + ']')
        else
          FItems.Add('Gamepad button names: [' + PadLayoutNames[GamepadLayout] + ']');
        FItems.Add('Gamepad confirm button: [' + PadConfirmNames[GamepadConfirm] + ': ' +
          GamepadButtonLabel(GamepadConfirmButton) + ']');
        FItems.Add('Reset to defaults');
        FItems.Add('Back');
      end;
    smShowcase:
      begin
        FItems.Add('Back to Main Menu');
      end;
    smBrowser, smBrowserMap:
      BuildBrowserItems;
    smLoad, smSave:
      BuildSlotItems;
  end;
  FSelectedIdx := 0;
end;

{ Load Game lists the savegames, the newest first; Save Game the slots 1..8
  with what each holds now }
procedure TQuakeMenu.BuildSlotItems;

  function Describe(const Info: TSaveGameInfo): String;
  begin
    Result := Format('%s  health %d  kills %d/%d  skill %d  %d:%.2d  %s', [Info.Map, Info.Health, Info.Kills,
      Info.TotalKills, Info.Skill, Trunc(Info.LevelTime) div 60, Trunc(Info.LevelTime) mod 60, Info.Saved]);
  end;

var
  Saves: TSaveGameInfoArray;
  Info: TSaveGameInfo;
  I: Integer;
  Slot: String;
begin
  FSlotActions.Clear;
  if FSubMenu = smLoad then
  begin
    Saves := ListSaveGames;
    for I := 0 to High(Saves) do
    begin
      FItems.Add(Saves[I].Slot + ': ' + Describe(Saves[I]));
      FSlotActions.Add('load:' + Saves[I].Slot);
    end;
    if Length(Saves) = 0 then
    begin
      FItems.Add('(no saved games yet)');
      FSlotActions.Add('');
    end;
  end else
    for I := 1 to 8 do
    begin
      Slot := IntToStr(I);
      if ReadSaveGameInfo(SaveGameUrl(Slot), Info) then
        FItems.Add('Slot ' + Slot + ': ' + Describe(Info))
      else
        FItems.Add('Slot ' + Slot + ': empty');
      FSlotActions.Add('save:' + Slot);
    end;
  FItems.Add('Back to Main Menu');
  FSlotActions.Add('back');
end;

procedure TQuakeMenu.SetInGame(const Value: Boolean);
begin
  FInGame := Value;
  if FSubMenu = smMain then
    RebuildMenuItems;
end;

{ The selected slot's thumbnail beside the list, loaded when the selection
  changes }
procedure TQuakeMenu.UpdateThumbnail;
var
  Url, Action: String;
begin
  Url := '';
  if (FSubMenu in [smLoad, smSave]) and (FSelectedIdx >= 0) and (FSelectedIdx < FSlotActions.Count) then
  begin
    Action := FSlotActions[FSelectedIdx];
    if (Pos('load:', Action) = 1) or (Pos('save:', Action) = 1) then
      Url := SaveThumbnailUrl(Copy(Action, 6, MaxInt));
    if (Url <> '') and (UriExists(Url) <> ueFile) then
      Url := '';
  end;
  if Url <> FThumbnailUrl then
  begin
    FThumbnailUrl := Url;
    FThumbnail.Url := '';
    if Url <> '' then
      FThumbnail.Url := Url;
  end;
  FThumbnailFrame.Exists := FThumbnailUrl <> '';
end;

const
  BrowserPageSize = 10;
  SortNames: array[TMapSort] of String = ('Rating', 'Newest', 'Name', 'Installed');

{ What the browser's items show: rebuilt when it changes }
function TQuakeMenu.BrowserState: String;
var
  Installed: Boolean;
begin
  Installed := (FBrowserMap >= 0) and MapBrowser.Installed(FBrowserMap);
  Result := Format('%d %d %d %d %s %d', [Ord(FSubMenu), Ord(FBrowserSort), FBrowserPage, FBrowserMap,
    BoolToStr(Installed, True), MapBrowser.DownloadingIndex]);
  if MapBrowser.Downloading then
    Result := Result + ' ' + IntToStr(Round(MapBrowser.Progress * 20));
end;

procedure TQuakeMenu.BuildBrowserItems;

  procedure Add(const Caption, Action: String);
  begin
    FItems.Add(Caption);
    FBrowserActions.Add(Action);
  end;

var
  List: specialize TArray<Integer>;
  Pages, I, J: Integer;
  M: TCatalogMap;
  Needs: String;
begin
  FBrowserActions.Clear;
  if FSubMenu = smBrowser then
  begin
    List := MapBrowser.Sorted(FBrowserSort);
    Pages := Max(1, (Length(List) + BrowserPageSize - 1) div BrowserPageSize);
    FBrowserPage := EnsureRange(FBrowserPage, 0, Pages - 1);
    Add(Format(Tr('Sort: [%s]  page %d of %d'), [Tr(SortNames[FBrowserSort]), FBrowserPage + 1, Pages]), 'sort');
    for J := FBrowserPage * BrowserPageSize to Min(Length(List), (FBrowserPage + 1) * BrowserPageSize) - 1 do
    begin
      I := List[J];
      if MapBrowser.Installed(I) then
        Add('* ' + MapBrowser.Describe(I), 'map:' + IntToStr(I))
      else
        Add(MapBrowser.Describe(I), 'map:' + IntToStr(I));
    end;
    if Length(List) = 0 then
      Add(Tr('(no maps installed yet)'), '');
    if FBrowserPage + 1 < Pages then
      Add(Tr('Next page'), 'next');
    if FBrowserPage > 0 then
      Add(Tr('Previous page'), 'prev');
    Add('Back to Main Menu', 'back');
  end else
  begin
    M := MapBrowser[FBrowserMap];
    Add(M.Title, '');
    Add(Format(Tr('by %s, released %s'), [M.Author, M.Date]), '');
    if M.Rating >= 0 then
      Add(Format(Tr('Rating %.1f / 5, %s, %.1f MB'), [M.Rating, Tr(M.Size), M.Bytes / (1024 * 1024)],
        DefaultFormatSettings), '')
    else
      Add(Format(Tr('Not rated, %s, %.1f MB'), [Tr(M.Size), M.Bytes / (1024 * 1024)], DefaultFormatSettings), '');
    Needs := '';
    if Pos('limits', M.Flags) > 0 then
      Needs := Tr('raised engine limits');
    if Pos('bsp2', M.Flags) > 0 then
      Needs := Needs + IfThen(Needs <> '', ', ', '') + 'BSP2';
    if Pos('lit', M.Flags) > 0 then
      Needs := Needs + IfThen(Needs <> '', ', ', '') + Tr('colored light');
    if Needs <> '' then
      Add(Format(Tr('Uses %s'), [Needs]), '');
    if Length(M.Needs) > 0 then
      Add(Format(Tr('Needs %s (QuakeC mode)'), [MapBrowser.NeedsText(FBrowserMap)]), '')
    else if MapBrowser.NeedsQuakeC(FBrowserMap) then
      Add(Tr('A mod: plays in QuakeC mode'), '');
    if MapBrowser.Ready(FBrowserMap) then
    begin
      for I := 0 to Min(High(M.StartMaps), 5) do
        Add('Play: ' + M.StartMaps[I], 'play:' + M.StartMaps[I]);
      Add(Tr('Remove'), 'remove');
    end else
    if MapBrowser.DownloadingIndex = FBrowserMap then
      Add(Format(Tr('Downloading: %d%%'), [Round(MapBrowser.Progress * 100)]), '')
    else
    if MapBrowser.BytesToInstall(FBrowserMap) > M.Bytes then
      Add(Format(Tr('Download and play (%.0f MB with the mods)'), [MapBrowser.BytesToInstall(FBrowserMap) / (1024 * 1024)],
        DefaultFormatSettings), 'install')
    else
      Add(Tr('Download and play'), 'install');
    Add(Tr('Back to the list'), 'back');
  end;
  FBrowserBuiltFor := BrowserState;
end;

procedure TQuakeMenu.BrowserAction(const Action: String);
var
  Map: String;
begin
  if Action = '' then
    Exit;
  if Action = 'back' then
    GoBack
  else if Action = 'sort' then
  begin
    if FBrowserSort = High(TMapSort) then
      FBrowserSort := Low(TMapSort)
    else
      FBrowserSort := Succ(FBrowserSort);
    FBrowserPage := 0;
    RebuildMenuItems;
  end else
  if Action = 'next' then
  begin
    Inc(FBrowserPage);
    RebuildMenuItems;
  end else
  if Action = 'prev' then
  begin
    Dec(FBrowserPage);
    RebuildMenuItems;
  end else
  if Pos('map:', Action) = 1 then
  begin
    FBrowserMap := StrToIntDef(Copy(Action, 5, MaxInt), -1);
    if FBrowserMap >= 0 then
    begin
      FSubMenu := smBrowserMap;
      RebuildMenuItems;
    end;
  end else
  if Action = 'install' then
  begin
    if MapBrowser.Install(FBrowserMap) then
      FPlayAfterInstall := FBrowserMap;
    RebuildMenuItems;
  end else
  if Action = 'remove' then
  begin
    MapBrowser.Remove(FBrowserMap);
    RebuildMenuItems;
  end else
  if Pos('play:', Action) = 1 then
  begin
    Map := Copy(Action, 6, MaxInt);
    if MapBrowser.Mount(FBrowserMap) and Pak.FileExists('maps/' + Map + '.bsp') and Assigned(FOnMenuAction) then
    begin
      { A mod's map plays with its QuakeC }
      if MapBrowser.NeedsQuakeC(FBrowserMap) then
        FOnMenuAction(maPlayQc, Map)
      else
        FOnMenuAction(maWarpMap, 'maps/' + Map + '.bsp');
    end;
  end;
end;

{ Escape, the gamepad's B and a click outside the items }
procedure TQuakeMenu.GoBack;
begin
  case FSubMenu of
    smControls:
      begin
        FSubMenu := smOptions;
        RebuildMenuItems;
        FSelectedIdx := 13;
        Exit;
      end;
    smBrowserMap:
      FSubMenu := smBrowser;
    smLan:
      FSubMenu := smMultiplayer;
    else
      FSubMenu := smMain;
  end;
  RebuildMenuItems;
end;

function TQuakeMenu.LanState: String;
begin
  Result := Format('%d %s', [LanDiscovery.Count, BoolToStr(LanDiscovery.Searching, True)]);
end;

{ The value after Current in Values (the first one after the last) }
function NextInCycle(const Current: Single; const Values: array of Single): Single;
var
  I: Integer;
begin
  for I := 0 to High(Values) do
    if Values[I] > Current + 0.001 then
      Exit(Values[I]);
  Result := Values[0];
end;

procedure TQuakeMenu.ExecuteSelection;
var
  ItemText, Slot: String;
  N, Selected: Integer;
begin
  if (FSelectedIdx < 0) or (FSelectedIdx >= FItems.Count) then
    Exit;

  ItemText := FItems[FSelectedIdx];
  Sounds.Play('sound/misc/menu2.wav');

  case FSubMenu of
    smMain:
      begin
        if ItemText = 'Single Player' then FSubMenu := smEpisodes
        else if ItemText = 'Multiplayer' then FSubMenu := smMultiplayer
        else if ItemText = 'Map Warp' then FSubMenu := smMaps
        else if ItemText = 'Map Browser' then FSubMenu := smBrowser
        else if ItemText = 'Save Game' then FSubMenu := smSave
        else if ItemText = 'Load Game' then FSubMenu := smLoad
        else if ItemText = 'Demos' then FSubMenu := smDemos
        else if ItemText = 'Options' then FSubMenu := smOptions
        else if ItemText = 'CGE Features Showcase' then FSubMenu := smShowcase
        else
        begin
          if Assigned(FOnMenuAction) then
            FOnMenuAction(maQuit, '');
          Exit;
        end;
        RebuildMenuItems;
      end;
    smLoad, smSave:
      if FSelectedIdx < FSlotActions.Count then
      begin
        Slot := FSlotActions[FSelectedIdx];
        if Slot = 'back' then
          GoBack
        else if (Pos('load:', Slot) = 1) and Assigned(FOnMenuAction) then
          FOnMenuAction(maLoadGame, Copy(Slot, 6, MaxInt))
        else if (Pos('save:', Slot) = 1) and Assigned(FOnMenuAction) then
        begin
          FOnMenuAction(maSaveGame, Copy(Slot, 6, MaxInt));
          { The slot shows what it holds now }
          N := FSelectedIdx;
          RebuildMenuItems;
          FSelectedIdx := N;
          FThumbnailUrl := '-';
        end;
      end;
    smLan:
      begin
        if ItemText = 'Back to Multiplayer' then
        begin
          FSubMenu := smMultiplayer;
          RebuildMenuItems;
        end else
        if ItemText = 'Search Again' then
        begin
          LanDiscovery.Start;
          RebuildMenuItems;
        end else
          for N := 0 to LanDiscovery.Count - 1 do
            if (LanDiscovery.Describe(N) = ItemText) and Assigned(FOnMenuAction) then
            begin
              WritelnLog('Menu', 'Joining the LAN game %s', [ItemText]);
              FOnMenuAction(maJoinGame, LanDiscovery[N].Host + ':' + IntToStr(LanDiscovery[N].Port));
              Break;
            end;
      end;
    smMultiplayer:
      begin
        if ItemText = 'Back to Main Menu' then
        begin
          FSubMenu := smMain;
          RebuildMenuItems;
        end else
        if Assigned(FOnMenuAction) then
        begin
          if Pos('Host Deathmatch: start', ItemText) = 1 then
            FOnMenuAction(maHostGame, 'start')
          else if Pos('Host Deathmatch: e1m1', ItemText) = 1 then
            FOnMenuAction(maHostGame, 'e1m1')
          else if Pos('Host Coop: e1m1', ItemText) = 1 then
            FOnMenuAction(maHostGame, 'coop:e1m1')
          else if Pos('Split-Screen Coop: e1m1', ItemText) = 1 then
            FOnMenuAction(maHostGame, 'split:e1m1')
          else if ItemText = 'Deathmatch vs 3 bots: start' then
            FOnMenuAction(maHostGame, 'bots:start')
          else if ItemText = 'Deathmatch vs 3 bots: e1m1' then
            FOnMenuAction(maHostGame, 'bots:e1m1')
          else if ItemText = 'Team Deathmatch with 3 bots: e1m1' then
            FOnMenuAction(maHostGame, 'teambots:e1m1')
          else if ItemText = 'Coop with 2 bots: e1m1' then
            FOnMenuAction(maHostGame, 'coopbots:e1m1')
          else if Pos('Host Deathmatch: random', ItemText) = 1 then
            FOnMenuAction(maHostGame, RandomMapName(NewRandomMapSeed))
          else if ItemText = 'Find LAN Games' then
          begin
            LanDiscovery.Start;
            FSubMenu := smLan;
            RebuildMenuItems;
            FSelectedIdx := 0;
          end else
          if ItemText = 'Spectate: localhost' then
            FOnMenuAction(maJoinGame, 'spectate:127.0.0.1')
          else
            FOnMenuAction(maJoinGame, '127.0.0.1');
        end;
      end;
    smEpisodes:
      begin
        if ItemText = 'Back to Main Menu' then
        begin
          FSubMenu := smMain;
          RebuildMenuItems;
        end else
        if Assigned(FOnMenuAction) then
        begin
          if ItemText = 'Quake: Episode Hub' then
            FOnMenuAction(maNewGame, 'quake')
          else if Pos('QuakeC', ItemText) = 1 then
            FOnMenuAction(maPlayQc, 'start')
          else if ItemText = 'Horde Mode: a random map' then
            FOnMenuAction(maWarpMap, 'horde:maps/' + RandomMapName(NewRandomMapSeed) + '.bsp')
          else if Pos('Horde Mode', ItemText) = 1 then
            FOnMenuAction(maWarpMap, 'horde:maps/e1m1.bsp')
          else if Pos('Random Map', ItemText) = 1 then
            FOnMenuAction(maWarpMap, 'maps/' + RandomMapName(NewRandomMapSeed) + '.bsp')
          else
            FOnMenuAction(maNewGame, 'librequake');
        end;
      end;
    smMaps:
      begin
        if ItemText = 'Back to Main Menu' then
        begin
          FSubMenu := smMain;
          RebuildMenuItems;
        end else
        if Assigned(FOnMenuAction) then
        begin
          if Pos('Random map', ItemText) = 1 then
            FOnMenuAction(maWarpMap, 'maps/' + RandomMapName(NewRandomMapSeed) + '.bsp')
          else
            FOnMenuAction(maWarpMap, ItemText);
        end;
      end;
    smDemos:
      begin
        if ItemText = 'Back to Main Menu' then
        begin
          FSubMenu := smMain;
          RebuildMenuItems;
        end else
        if Assigned(FOnMenuAction) and (FSelectedIdx < FDemoUrls.Count) then
          FOnMenuAction(maPlayDemo, FDemoUrls[FSelectedIdx]);
      end;
    smOptions:
      case FSelectedIdx of
        0:
          begin
            FShadowsEnabled := not FShadowsEnabled;
            RebuildMenuItems;
            if Assigned(FOnMenuAction) then
              FOnMenuAction(maToggleShadows, BoolToStr(FShadowsEnabled, True));
          end;
        1:
          begin
            { Applied when the next map is loaded }
            WorldLightmaps := not WorldLightmaps;
            RebuildMenuItems;
            FSelectedIdx := 1;
            if Assigned(FOnMenuAction) then
              FOnMenuAction(maToggleLighting, BoolToStr(WorldLightmaps, True));
          end;
        2:
          begin
            if Assigned(FOnMenuAction) then
              FOnMenuAction(maToggleCamera, '');
          end;
        3:
          begin
            FVolume := (FVolume + 25) mod 125;
            RebuildMenuItems;
            FSelectedIdx := 3;
          end;
        4, 5, 6, 7, 8, 9, 10, 11, 12:
          begin
            { Video and accessibility options, applied by the views each
              frame and saved }
            case FSelectedIdx of
              4: VideoFov := NextInCycle(VideoFov, [75, 90, 100, 110, 120]);
              5: VideoGamma := NextInCycle(VideoGamma, [0.6, 0.7, 0.8, 0.9, 1.0, 1.2]);
              6: if ViewBob > 0 then ViewBob := 0 else ViewBob := DefaultViewBob;
              7: ShowWeapon := not ShowWeapon;
              8: CaptionsEnabled := not CaptionsEnabled;
              9: HighContrastHud := not HighContrastHud;
              10: ReducedFlashes := not ReducedFlashes;
              11: SpeedrunTimer := not SpeedrunTimer;
              12: GhostRacing := not GhostRacing;
            end;
            SaveVideoSettings;
            Selected := FSelectedIdx;
            RebuildMenuItems;
            FSelectedIdx := Selected;
          end;
        13, 14:
          begin
            { The colors of the player in network games (0..13) }
            if FSelectedIdx = 13 then
              PlayerShirt := (PlayerShirt + 1) mod 14
            else
              PlayerPants := (PlayerPants + 1) mod 14;
            SaveVideoSettings;
            Selected := FSelectedIdx;
            RebuildMenuItems;
            FSelectedIdx := Selected;
          end;
        15:
          begin
            { Auto (the system's), English, then the translations }
            SetLanguage(NextLanguageSetting(LanguageSetting));
            SaveLanguageSettings;
            RebuildMenuItems;
            FSelectedIdx := 15;
          end;
        16:
          begin
            FSubMenu := smControls;
            RebuildMenuItems;
          end;
        17:
          begin
            FSubMenu := smMain;
            RebuildMenuItems;
          end;
      end;
    smControls:
      begin
        N := Ord(High(TQuakeBinding)) + 1; { the first item after the bindings }
        Selected := FSelectedIdx;
        if FSelectedIdx < N then
        begin
          { The next key or mouse button pressed becomes the binding }
          FBindWaiting := True;
          FBindTarget := TQuakeBinding(FSelectedIdx);
        end else
        if FSelectedIdx = N then
          { The gamepad's name: look again for one connected meanwhile }
          Controllers.Initialize
        else
        if FSelectedIdx = N + 1 then
          GamepadSensitivity := NextInCycle(GamepadSensitivity, [0.5, 0.75, 1.0, 1.5, 2.0, 3.0])
        else
        if FSelectedIdx = N + 2 then
          GamepadDeadZone := NextInCycle(GamepadDeadZone, [0.1, 0.15, 0.2, 0.25, 0.3, 0.4])
        else
        if FSelectedIdx = N + 3 then
          GamepadInvertLook := not GamepadInvertLook
        else
        if FSelectedIdx = N + 4 then
        begin
          if GamepadLayout = High(TPadLayout) then
            GamepadLayout := Low(TPadLayout)
          else
            GamepadLayout := Succ(GamepadLayout);
        end else
        if FSelectedIdx = N + 5 then
        begin
          if GamepadConfirm = High(TPadConfirm) then
            GamepadConfirm := Low(TPadConfirm)
          else
            GamepadConfirm := Succ(GamepadConfirm);
        end else
        if FSelectedIdx = N + 6 then
        begin
          ResetBindings;
          GamepadSensitivity := 1.0;
          GamepadDeadZone := DefaultGamepadDeadZone;
          GamepadInvertLook := False;
          GamepadLayout := plAuto;
          GamepadConfirm := pcAuto;
        end else
        begin
          FSubMenu := smOptions;
          RebuildMenuItems;
          FSelectedIdx := 16;
          Exit;
        end;
        if (FSelectedIdx > N) and (FSelectedIdx <= N + 6) then
          SaveGamepadSettings;
        RebuildMenuItems;
        FSelectedIdx := Selected;
      end;
    smShowcase:
      begin
        FSubMenu := smMain;
        RebuildMenuItems;
      end;
    smBrowser, smBrowserMap:
      if FSelectedIdx < FBrowserActions.Count then
        BrowserAction(FBrowserActions[FSelectedIdx]);
  end;
end;

function TQuakeMenu.Press(const Event: TInputPressRelease): Boolean;
var
  Selected: Integer;
begin
  Result := False;

  { Controls: waiting for the key of a binding }
  if FBindWaiting then
  begin
    if Event.IsKey(keyEscape) then
      FBindWaiting := False
    else
    if AssignBinding(FBindTarget, Event) then
    begin
      FBindWaiting := False;
      Selected := FSelectedIdx;
      RebuildMenuItems;
      FSelectedIdx := Selected;
      Sounds.Play('sound/misc/menu2.wav');
    end;
    Exit(True);
  end;

  { A tap or click on an item selects and runs it (touch screens); outside
    the items it goes back like Escape, and from the main menu it is left
    to the owner (the play view closes the menu) }
  if (Event.EventType = itMouseButton) and (Event.MouseButton = buttonLeft) then
  begin
    if FItemsGroup.Exists then
      for Selected := 0 to High(FItemLabels) do
        if (Selected < FItems.Count) and FItemLabels[Selected].RenderRect.Grow(6).Contains(Event.Position) then
        begin
          FSelectedIdx := Selected;
          ExecuteSelection;
          Exit(True);
        end;
    if FSubMenu = smMain then
      Exit(False);
    GoBack;
    Sounds.Play('sound/misc/menu3.wav');
    Exit(True);
  end;

  if Event.IsKey(keyArrowUp) then
  begin
    FSelectedIdx := (FSelectedIdx - 1 + FItems.Count) mod FItems.Count;
    Sounds.Play('sound/misc/menu1.wav');
    Exit(True);
  end;

  if Event.IsKey(keyArrowDown) then
  begin
    FSelectedIdx := (FSelectedIdx + 1) mod FItems.Count;
    Sounds.Play('sound/misc/menu1.wav');
    Exit(True);
  end;

  if Event.IsKey(keyEnter) or Event.IsKey(keySpace) then
  begin
    ExecuteSelection;
    Exit(True);
  end;

  if Event.IsKey(keyEscape) and (FSubMenu <> smMain) then
  begin
    GoBack;
    Sounds.Play('sound/misc/menu3.wav');
    Exit(True);
  end;
  { Map browser: left / right turn the pages }
  if (FSubMenu = smBrowser) and (Event.IsKey(keyArrowRight) or Event.IsKey(keyArrowLeft)) then
  begin
    if Event.IsKey(keyArrowRight) and (FBrowserActions.IndexOf('next') >= 0) then
      BrowserAction('next')
    else if Event.IsKey(keyArrowLeft) and (FBrowserActions.IndexOf('prev') >= 0) then
      BrowserAction('prev');
    Sounds.Play('sound/misc/menu1.wav');
    Exit(True);
  end;
end;

end.
