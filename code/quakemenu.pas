{ Quake Main Menu: New Game, Episode/Map Select, Options, and CGE Showcase. }
unit QuakeMenu;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math,
  CastleVectors, CastleUIControls, CastleControls, CastleKeysMouse, CastleColors,
  CastleRectangles, CastleGLUtils, CastleImages, CastleFindFiles, CastleUriUtils, CastleComponentSerialize,
  CastleGameControllers,
  QuakeSound, QuakePak, QuakeGeometry, GameInput, GameVideo;

type
  TMenuAction = (
    maNone, maNewGame, maWarpMap, maPlayDemo, maPlayQc, maHostGame, maJoinGame, maToggleShadows,
    maToggleLighting, maToggleCamera, maToggleSound, maQuit
  );

  TOnMenuActionEvent = procedure(const Action: TMenuAction; const Param: String) of object;

  { Quake Title and Main Menu }
  TQuakeMenu = class(TCastleUserInterface)
  private
    FSelectedIdx: Integer;
    FSubMenu: (smMain, smEpisodes, smMultiplayer, smMaps, smDemos, smOptions, smControls, smShowcase);
    FBindWaiting: Boolean; { Controls: the next key / button goes to FBindTarget }
    FBindTarget: TQuakeBinding;
    FDefaultHint: String;
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
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    function Press(const Event: TInputPressRelease): Boolean; override;
    procedure Update(const SecondsPassed: Single; var HandleInput: Boolean); override;

    property OnMenuAction: TOnMenuActionEvent read FOnMenuAction write FOnMenuAction;
    property ShadowsEnabled: Boolean read FShadowsEnabled write FShadowsEnabled;
    property CameraModeName: String read FCameraModeName write FCameraModeName;
  end;

implementation

uses
  QuakeRandomMap, QuakeCaptions, QuakeWorld;

constructor TQuakeMenu.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FullSize := True;
  FItems := TStringList.Create;
  FDemoUrls := TStringList.Create;
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
  RebuildMenuItems;
  SyncDesign;
end;

procedure TQuakeMenu.SyncDesign;
var
  I: Integer;
  L: TCastleLabel;
begin
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
  for I := 0 to FItems.Count - 1 do
  begin
    if I = FSelectedIdx then
    begin
      FItemLabels[I].Caption := '> ' + FItems[I] + ' <';
      FItemLabels[I].Color := Vector4(1.0, 0.85, 0.15, 1.0);
    end else
    begin
      FItemLabels[I].Caption := FItems[I];
      FItemLabels[I].Color := Vector4(0.75, 0.75, 0.75, 0.9);
    end;
  end;
  FShowcaseLabel.Exists := FSubMenu = smShowcase;
  FItemsGroup.Exists := FSubMenu <> smShowcase;
  FHintLabel.Exists := FSubMenu <> smShowcase;
  if FDefaultHint = '' then
    FDefaultHint := FHintLabel.Caption;
  if FBindWaiting then
    FHintLabel.Caption := 'Press a key, mouse button or wheel for "' + BindingCaptions[FBindTarget] +
      '" (Escape keeps it)'
  else
  if FSubMenu = smControls then
    FHintLabel.Caption := 'Enter rebinds; the gamepad: left stick moves, right stick turns, A jumps, ' +
      'X uses, RB / right trigger fires, D-pad changes weapons'
  else
    FHintLabel.Caption := FDefaultHint;
end;

procedure TQuakeMenu.Update(const SecondsPassed: Single; var HandleInput: Boolean);
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
    if GamepadJustPressed(gbSouth) then
      ExecuteSelection;
    if GamepadJustPressed(gbEast) and (FSubMenu <> smMain) then
    begin
      if FSubMenu = smControls then
        FSubMenu := smOptions
      else
        FSubMenu := smMain;
      RebuildMenuItems;
      Sounds.Play('sound/misc/menu3.wav');
    end;
  end;
  SyncDesign;
end;

destructor TQuakeMenu.Destroy;
begin
  FItems.Free;
  FDemoUrls.Free;
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
        FItems.Add('Host Deathmatch: random map (port 26000)');
        FItems.Add('Deathmatch vs 3 bots: start');
        FItems.Add('Deathmatch vs 3 bots: e1m1');
        FItems.Add('Join: localhost');
        FItems.Add('Back to Main Menu');
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
        FItems.Add('Controls');
        FItems.Add('Back to Main Menu');
      end;
    smControls:
      begin
        for B := Low(TQuakeBinding) to High(TQuakeBinding) do
          FItems.Add(BindingCaptions[B] + ': ' + BindingDescription(B));
        FItems.Add('Gamepad: ' + GamepadName);
        FItems.Add(Format('Gamepad look sensitivity: %.2fx', [GamepadSensitivity]));
        FItems.Add(Format('Gamepad dead zone: %.2f', [GamepadDeadZone]));
        if GamepadInvertLook then
          FItems.Add('Gamepad invert look: [ON]')
        else
          FItems.Add('Gamepad invert look: [OFF]');
        FItems.Add('Reset to defaults');
        FItems.Add('Back');
      end;
    smShowcase:
      begin
        FItems.Add('Back to Main Menu');
      end;
  end;
  FSelectedIdx := 0;
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
  ItemText: String;
  N, Selected: Integer;
begin
  if (FSelectedIdx < 0) or (FSelectedIdx >= FItems.Count) then
    Exit;

  ItemText := FItems[FSelectedIdx];
  Sounds.Play('sound/misc/menu2.wav');

  case FSubMenu of
    smMain:
      case FSelectedIdx of
        0: begin FSubMenu := smEpisodes; RebuildMenuItems; end;
        1: begin FSubMenu := smMultiplayer; RebuildMenuItems; end;
        2: begin FSubMenu := smMaps; RebuildMenuItems; end;
        3: begin FSubMenu := smDemos; RebuildMenuItems; end;
        4: begin FSubMenu := smOptions; RebuildMenuItems; end;
        5: begin FSubMenu := smShowcase; RebuildMenuItems; end;
        6: if Assigned(FOnMenuAction) then FOnMenuAction(maQuit, '');
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
          else if ItemText = 'Deathmatch vs 3 bots: start' then
            FOnMenuAction(maHostGame, 'bots:start')
          else if ItemText = 'Deathmatch vs 3 bots: e1m1' then
            FOnMenuAction(maHostGame, 'bots:e1m1')
          else if Pos('Host Deathmatch: random', ItemText) = 1 then
            FOnMenuAction(maHostGame, RandomMapName(NewRandomMapSeed))
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
        13:
          begin
            FSubMenu := smControls;
            RebuildMenuItems;
          end;
        14:
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
          ResetBindings;
          GamepadSensitivity := 1.0;
          GamepadDeadZone := DefaultGamepadDeadZone;
          GamepadInvertLook := False;
        end else
        begin
          FSubMenu := smOptions;
          RebuildMenuItems;
          FSelectedIdx := 13;
          Exit;
        end;
        if (FSelectedIdx > N) and (FSelectedIdx <= N + 4) then
          SaveGamepadSettings;
        RebuildMenuItems;
        FSelectedIdx := Selected;
      end;
    smShowcase:
      begin
        FSubMenu := smMain;
        RebuildMenuItems;
      end;
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
    if FSubMenu = smControls then
    begin
      FSubMenu := smOptions;
      FSelectedIdx := 4;
    end else
    begin
      FSubMenu := smMain;
      FSelectedIdx := 0;
    end;
    RebuildMenuItems;
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

  if Event.IsKey(keyEscape) then
  begin
    if FSubMenu = smControls then
    begin
      FSubMenu := smOptions;
      RebuildMenuItems;
      FSelectedIdx := 4;
      Sounds.Play('sound/misc/menu3.wav');
      Exit(True);
    end;
    if FSubMenu <> smMain then
    begin
      FSubMenu := smMain;
      RebuildMenuItems;
      Sounds.Play('sound/misc/menu3.wav');
      Exit(True);
    end;
  end;
end;

end.
