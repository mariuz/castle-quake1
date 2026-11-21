{ The play view's console commands: RegisterCommands is the table (the
  names a handler answers to and its help line), the Cmd... methods are
  the handlers. A new command is a handler and an AddCommand line.
  Included by gameviewplay.pas. }

procedure TViewPlay.AddCommand(const Names, Help: String; const Handler: TPlayCommandHandler);
begin
  SetLength(FCommands, Length(FCommands) + 1);
  FCommands[High(FCommands)].Names := Names;
  FCommands[High(FCommands)].Help := Help;
  FCommands[High(FCommands)].Handler := Handler;
end;

procedure TViewPlay.RegisterCommands;
begin
  { In the order help lists them; the help lines are English here and
    translated when shown (tools/lang_strings.py collects them) }
  AddCommand('map warp', '  map <name>     - Load map (e.g. start, e1m1, lq_e0m1)', @CmdMap);
  AddCommand('skill', '  skill <0..3>   - Skill for the next map', @CmdSkill);
  AddCommand('record stop', '  record <name>  - Record a demo to <name>.dem, stop ends it', @CmdRecord);
  AddCommand('save', '  save [slot]    - Save the game (F6 = quick)', @CmdSave);
  AddCommand('load', '  load [slot]    - Load a saved game (F9 = quick)', @CmdLoad);
  AddCommand('god', '  god            - God mode', @CmdGod);
  AddCommand('give', '  give all       - Give all weapons, ammo, keys', @CmdGive);
  AddCommand('shadows', '  shadows <0|1>  - Toggle dynamic shadows', @CmdShadows);
  AddCommand('wateralpha', '  wateralpha <0..1> - Opacity of water, slime and lava', @CmdWaterAlpha);
  AddCommand('fog', '  fog <density> [r g b] - Fog for this level (0 off)', @CmdFog);
  AddCommand('horde', '  horde [0|1]    - Waves of monsters on this map; killall - every monster dies', @CmdHorde);
  AddCommand('killall', '', @CmdKillAll);
  AddCommand('speedrun ghost', '  speedrun [0|1], ghost [0|1], ghost_reset - Timer, race the best run, forget it', @CmdSpeedrun);
  AddCommand('ghost_reset', '', @CmdGhostReset);
  AddCommand('records records_reset', '  records [map], records_reset [map] - Best time, kills and secrets of each map and skill', @CmdRecords);
  AddCommand('saves', '  saves          - List the saved games (the Load Game menu)', @CmdSaves);
  AddCommand('photo', '  photo [0|1] (P) - Photo mode: the game pauses, the camera flies; photo_fov <deg>,', @CmdPhoto);
  AddCommand('photo_fov photo_effect photo_scale photo_shot', '    photo_effect <none|dof|gray|sepia|vignette|ao>, photo_scale <1..4>, photo_shot', @CmdPhotoSetting);
  AddCommand('maps maps_install', '  maps [rating|newest|name|installed] [text] - Quaddicted maps; maps_install <id>,', @MapBrowserCommand);
  AddCommand('maps_play maps_remove maps_mount', '    maps_play <id> [map], maps_remove <id> - download, play and remove one', @MapBrowserCommand);
  AddCommand('lan lan_join', '  lan - Find games on the local network; lan_join <n> - join the nth', @LanCommand);
  AddCommand('name color', '  name <name>, color <shirt> [<pants>] - You in network games (colors 0..13)', @CmdIdentity);
  AddCommand('sky', '  sky <name> - Skybox gfx/env/<name> for this level (- the scrolling sky)', @CmdSky);
  AddCommand('lightmaps', '  lightmaps <0|1> - Quake lightmaps or dynamic PBR world lighting', @CmdLightmaps);
  AddCommand('debug', '  debug <modes>  - Overlay: triggers, monsters, movers, leaf, all, off', @CmdDebug);
  AddCommand('fps', '  fps            - Show the frame rate in the stats line', @CmdFps);
  AddCommand('novis', '  novis <0|1>    - 1 draws the whole world, 0 only what the PVS can see', @CmdNoVis);
  AddCommand('lang', '  lang <code|auto> - Language of the menu, the HUD and this help', @CmdLang);
  AddCommand('quit exit', '  quit           - Exit game', @CmdQuit);
  AddCommand('help', '', @CmdHelp);
end;

function TViewPlay.PlayCommandNames: TStringArray;
var
  I: Integer;
  CmdName: String;
begin
  SetLength(Result, 0);
  for I := 0 to High(FCommands) do
    for CmdName in FCommands[I].Names.Split([' '], TStringSplitOptions.ExcludeEmpty) do
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := CmdName;
    end;
end;

procedure TViewPlay.HandleConsoleCommand(const Cmd, Args: String);
var
  Reply, CmdName: String;
  I: Integer;
begin
  { The settings commands of every view first }
  if RunSettingsCommand(Cmd, Args, Reply) then
  begin
    FConsole.Print(Reply);
    Exit;
  end;
  for I := 0 to High(FCommands) do
    for CmdName in FCommands[I].Names.Split([' '], TStringSplitOptions.ExcludeEmpty) do
      if CmdName = Cmd then
      begin
        FCommands[I].Handler(Cmd, Args);
        Exit;
      end;
  FConsole.Print(Tr('Unknown command: ') + Cmd);
end;

procedure TViewPlay.CmdMap(const Cmd, Args: String);
begin
  if Args <> '' then
    LoadLevel(Args)
  else
    FConsole.Print('Usage: map <mapname>');
end;

procedure TViewPlay.CmdSkill(const Cmd, Args: String);
begin
  { Like Quake: takes effect on the next map }
  if Args <> '' then
    FWorld.Skill := EnsureRange(StrToIntDef(Args, FWorld.Skill), 0, 3);
  FConsole.Print('Skill: ' + IntToStr(FWorld.Skill));
end;

procedure TViewPlay.CmdRecord(const Cmd, Args: String);
begin
  if Cmd = 'stop' then
  begin
    if FWorld.Recording then
    begin
      FWorld.StopRecording;
      FConsole.Print('Recording stopped');
    end else
      FConsole.Print('Not recording');
  end else
  begin
    if Args = '' then
      FConsole.Print('Usage: record <name>')
    else if FWorld.StartRecording('castle-config:/' + Args + '.dem') then
      FConsole.Print('Recording to ' + Args + '.dem')
    else
      FConsole.Print('Cannot record now');
  end;
end;

procedure TViewPlay.CmdSave(const Cmd, Args: String);
begin
  if Args <> '' then
    SaveGameSlot(Args)
  else
    SaveGameSlot('quick');
end;

procedure TViewPlay.CmdLoad(const Cmd, Args: String);
begin
  if Args <> '' then
    LoadGameSlot(Args)
  else
    LoadGameSlot('quick');
end;

procedure TViewPlay.CmdGod(const Cmd, Args: String);
begin
  FWorld.CheatGodMode(FHud);
  FConsole.Print('God mode enabled');
end;

procedure TViewPlay.CmdGive(const Cmd, Args: String);
begin
  if Args = 'all' then
  begin
    FWorld.CheatGiveAll(FHud);
    FConsole.Print('Gave all weapons, keys and ammo');
  end else
    FConsole.Print('Usage: give all');
end;

procedure TViewPlay.CmdShadows(const Cmd, Args: String);
begin
  Lighting.ShadowsEnabled := (Args = '1') or (Args = 'on');
  FMenu.ShadowsEnabled := Lighting.ShadowsEnabled;
  FConsole.Print('Shadows: ' + BoolToStr(Lighting.ShadowsEnabled, True));
end;

procedure TViewPlay.CmdWaterAlpha(const Cmd, Args: String);
begin
  { r_wateralpha: 1 opaque, 0 invisible }
  if FWorld.Geometry <> nil then
    FWorld.Geometry.LiquidAlpha := EnsureRange(StrToFloatDef(Args, 0.65), 0, 1);
  FConsole.Print(Format('Water alpha: %.2f', [DefaultLiquidAlpha]));
end;

procedure TViewPlay.CmdFog(const Cmd, Args: String);
var
  Parts: TStringArray;
  FogColor: TVector3;
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
end;

procedure TViewPlay.CmdHorde(const Cmd, Args: String);
begin
  { horde [0|1]: restart the map with waves of monsters (or without) }
  if Args <> '' then
    FHordeMode := (Args = '1') or (Args = 'on')
  else
    FHordeMode := not FHordeMode;
  FConsole.Print('Horde mode: ' + BoolToStr(FHordeMode, 'on', 'off'));
  FWorld.RespawnPlayer;
  LoadLevel(FMapName);
end;

procedure TViewPlay.CmdKillAll(const Cmd, Args: String);
begin
  FWorld.KillAllMonsters;
  FConsole.Print('Killed every monster');
end;

procedure TViewPlay.CmdSpeedrun(const Cmd, Args: String);
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
end;

procedure TViewPlay.CmdGhostReset(const Cmd, Args: String);
begin
  FWorld.ResetGhost;
  FConsole.Print('Best run of ' + FWorld.MapName + ' forgotten');
end;

procedure TViewPlay.CmdRecords(const Cmd, Args: String);
begin
  if Cmd = 'records' then
    ListRecordsCommand(LowerCase(Args))
  else
  begin
    { records_reset [map]: forget a map's records, or all of them }
    MapRecords.Reset(LowerCase(Args));
    SaveMapRecords;
    if Args <> '' then
    begin
      FConsole.Print(Format(Tr('Records of %s forgotten'), [LowerCase(Args)]));
      WritelnLog('Records', 'Records reset: %s', [LowerCase(Args)]);
    end else
    begin
      FConsole.Print(Tr('All map records forgotten'));
      WritelnLog('Records', 'Records reset: all');
    end;
  end;
end;

procedure TViewPlay.CmdSaves(const Cmd, Args: String);
begin
  ListSavesCommand;
end;

procedure TViewPlay.CmdPhoto(const Cmd, Args: String);
begin
  { photo [0|1]: photo mode (toggles without an argument) }
  if Args <> '' then
    SetPhotoMode((Args = '1') or (Args = 'on'))
  else
    SetPhotoMode(not FPhoto.Active);
  FConsole.Print('Photo mode: ' + BoolToStr(FPhoto.Active, 'on', 'off'));
end;

procedure TViewPlay.CmdPhotoSetting(const Cmd, Args: String);
begin
  FConsole.Print(FPhoto.Command(Cmd, Args, PhotoPrefix));
end;

procedure TViewPlay.CmdIdentity(const Cmd, Args: String);
var
  Parts: TStringArray;
begin
  if Cmd = 'name' then
  begin
    { The name in network games; no argument shows it }
    if Args <> '' then
    begin
      PlayerName := Trim(Copy(Args, 1, MaxPlayerName));
      SaveVideoSettings;
    end;
    FConsole.Print(Format(Tr('Name: "%s"'), [PlayerName]));
  end else
  begin
    { color <shirt> [<pants>] (0..13) in network games, like Quake }
    if Args <> '' then
    begin
      Parts := Args.Split([' '], TStringSplitOptions.ExcludeEmpty);
      PlayerShirt := EnsureRange(StrToIntDef(Parts[0], PlayerShirt), 0, 13);
      if Length(Parts) >= 2 then
        PlayerPants := EnsureRange(StrToIntDef(Parts[1], PlayerPants), 0, 13)
      else
        PlayerPants := PlayerShirt;
      SaveVideoSettings;
    end;
    FConsole.Print(Format(Tr('Colors: shirt %d, pants %d'), [PlayerShirt, PlayerPants]));
  end;
end;

procedure TViewPlay.CmdSky(const Cmd, Args: String);
var
  SkyName: String;
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
end;

procedure TViewPlay.CmdLightmaps(const Cmd, Args: String);
begin
  { 1 = Quake lightmaps blended in the shader, 0 = dynamic PBR lighting;
    the current map is rebuilt }
  if Args <> '' then
  begin
    WorldLightmaps := (Args = '1') or (Args = 'on');
    LoadLevel(FMapName);
  end;
  FConsole.Print('Lightmaps: ' + BoolToStr(WorldLightmaps, True));
end;

procedure TViewPlay.CmdDebug(const Cmd, Args: String);
begin
  { Debug overlay: debug triggers,monsters,movers,leaf | all | off }
  FWorld.DebugModes := ParseDebugModes(Args, FWorld.DebugModes);
  FConsole.Print('Debug overlay: ' + DebugModesToString(FWorld.DebugModes));
end;

procedure TViewPlay.CmdFps(const Cmd, Args: String);
begin
  FShowFps := not FShowFps;
  FConsole.Print('FPS display: ' + BoolToStr(FShowFps, 'on', 'off'));
end;

procedure TViewPlay.CmdNoVis(const Cmd, Args: String);
begin
  { r_novis: 1 draws the whole world, 0 only the camera's PVS }
  if Args <> '' then
    WorldPvsCulling := not ((Args = '1') or (Args = 'on'));
  FConsole.Print('PVS culling: ' + BoolToStr(WorldPvsCulling, 'on', 'off') + ' (' + PvsStatus + ')');
end;

procedure TViewPlay.CmdLang(const Cmd, Args: String);
var
  LangList: String;
  Lang: TLanguageInfo;
begin
  { lang <code>: the menu, HUD and help in another language (saved) }
  if Args <> '' then
  begin
    if Args = 'auto' then
      SetLanguage('')
    else
      SetLanguage(Args);
    SaveLanguageSettings;
  end;
  LangList := '';
  for Lang in Languages do
    LangList := LangList + ' ' + Lang.Code;
  FConsole.Print(Format(Tr('Language: %s (%s); lang <code> changes it:%s, auto'),
    [CurrentLanguage, CurrentLanguageName, LangList]));
end;

procedure TViewPlay.CmdQuit(const Cmd, Args: String);
begin
  RequestQuit;
end;

procedure TViewPlay.CmdHelp(const Cmd, Args: String);
var
  HelpLines: TStringList;
  HelpLine: String;
  I: Integer;
begin
  FConsole.Print(Tr('Commands:'));
  { The settings commands every view runs (GameConsole's table) }
  HelpLines := TStringList.Create;
  try
    SettingsCommandHelp(HelpLines);
    for I := 0 to High(FCommands) do
      if FCommands[I].Help <> '' then
        HelpLines.Add(Tr(FCommands[I].Help));
    for HelpLine in HelpLines do
      FConsole.Print(HelpLine);
    WritelnLog('GameViewPlay', 'Console: help (%d commands, %d lines)', [Length(PlayCommandNames), HelpLines.Count]);
  finally
    HelpLines.Free;
  end;
end;
