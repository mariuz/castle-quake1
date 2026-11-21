{ Game initialization: window, views, PAK asset loading, and command-line parsing. }
unit GameInitialize;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math,
  CastleWindow, CastleLog, CastleUIControls, CastleApplicationProperties, CastleParameters,
  CastleUtils, CastleFilesUtils, CastleUriUtils, CastleRenderOptions, CastleKeysMouse,
  QuakePak, QuakePalette, QuakeSound, QuakeBsp, QuakeProgs, QuakeGeometry,
  GameViewMenu, GameViewPlay, GameViewDemo, GameViewQc, QuakeNet, QuakeServer, QuakeDemo, GameInput, GameVideo, GameTouch, GameScreen, GameTranslate, GameFontUi, CastleFonts, CastleControls, QuakeWebStorage, QuakeWebSocketClient,
  QuakeRandomMap, QuakeWorld, QuakeMapBrowser, CastleConfig, GameLogWatch, GameOptions;

var
  Window: TCastleWindow;
  AutoTestMap: String;
  AutoTestPrefix: String;
  AutoTestDemo: String;
  CmdWarp: String;
  { -load <slot>: start from a savegame }
  CmdLoad: String;
  { -horde: waves of monsters on the map played }
  CmdHorde: Boolean = False;
  { -bots N: deathmatch bots in the hosted game }
  CmdBots: Integer = 0;
  { -speedrun / -ghost: the timer / ghost racing on (over the user config) }
  CmdSpeedrun: Boolean = False;
  CmdGhost: Boolean = False;
  CmdPaks: TStringList;
  CmdGame: String;
  CmdPlayDemo: String;
  CmdQcTest: String;
  CmdQc: String;
  CmdHost: String;
  CmdConnect: String;
  { -spectate: join (-connect, connect:<host>) as a spectator }
  CmdSpectate: Boolean;
  { -name / -color for this run (-1: the saved ones) }
  CmdPlayerName: String;
  CmdPlayerNameSet: Boolean;
  CmdShirt: Integer = -1;
  CmdPants: Integer = -1;
  { -record <name>: record the network game (host or client) to castle-config:/<name>.dem }
  CmdRecord: String;
  CmdRegister: String;
  CmdRendezvous: Boolean;
  CmdWebSocket: Integer;
  CmdWsRelay: String;
  CmdNoPredict: Boolean;
  CmdPort: Integer;
  CmdCoop: Boolean;
  { -splitscreen [stacked]: host with a second local player (coop) }
  CmdSplit, CmdSplitStacked: Boolean;
  { -splitplayers N: split-screen with N local players (2..4) }
  CmdSplitPlayers: Integer = 2;
  { -lang <code>: the language for this run (not saved) }
  CmdLang: String;
  CmdSkill: Integer;
  CmdExportMap, CmdExportUrl: String;

procedure ApplicationInitialize;

implementation

procedure RunQcTest(const MapName: String);
var
  Progs: TQuakeProgs;
  Bsp: TQuakeBsp;
  Spawned, I, Monsters, E: Integer;
  Classes: TStringList;
  CName: String;
begin
  Progs := TQuakeProgs.Create;
  Bsp := TQuakeBsp.Create;
  Classes := TStringList.Create;
  try
    if not Progs.Load then
      Exit;
    if not Bsp.LoadFromPak('maps/' + MapName + '.bsp') then
      Exit;
    Progs.Global(Progs.GTime)^.F := 1.0;
    Spawned := Progs.SpawnEntities(Bsp.Entities, 1);
    WritelnLog('QcTest', 'Spawned %d entities (%d edicts): total_monsters %d, total_secrets %d, models %d, sounds %d',
      [Spawned, Progs.NumEdicts, Round(Progs.Global(Progs.GTotalMonsters)^.F),
       Round(Progs.Global(Progs.GTotalSecrets)^.F), Progs.PrecachedModels.Count, Progs.PrecachedSounds.Count]);
    for I := 1 to 100 do
      Progs.RunFrame(0.1);
    Monsters := 0;
    for E := 1 to Progs.NumEdicts - 1 do
      if not Progs.EdictFree(E) then
      begin
        CName := Progs.FieldString(E, Progs.FClassName);
        if Pos('monster_', CName) = 1 then
          Inc(Monsters);
        if Classes.IndexOf(CName) < 0 then
          Classes.Add(CName);
      end;
    WritelnLog('QcTest', 'After 10 s: time %.1f, %d thinks, %d calls, %d monsters alive, %d classes',
      [Progs.Global(Progs.GTime)^.F, Progs.Statistics.Thinks, Progs.Statistics.Calls, Monsters,
       Classes.Count]);
  finally
    Classes.Free;
    Bsp.Free;
    Progs.Free;
  end;
end;

{ -game <dir>: a mission pack (hipnotic, rogue) or a mod directory on top of
  id1, from the working directory, next to the executable, the data
  directory or the config directory. Like Quake, the directory's loose
  files come first and its pak0..pak9.pak override them; then its .pk3
  (zip) archives in name order. Returns the number of containers loaded. }
function LoadGameDir(const Dir: String): Integer;
var
  I: Integer;
  Base, Name, Url, Path: String;
  Bases: array[0..3] of String;
  Seen, Pk3s: TStringList;
  Info: TSearchRec;

  { The same directory reached from two bases is loaded once }
  function FirstTime(const FileOrDir: String): Boolean;
  var
    Key: String;
  begin
    Key := ExcludeTrailingPathDelimiter(ExpandFileName(FileOrDir));
    Result := Seen.IndexOf(Key) < 0;
    if Result then
      Seen.Add(Key);
  end;

begin
  Result := 0;
  Bases[0] := '';
  Bases[1] := ExtractFilePath(ParamStr(0));
  Bases[2] := 'castle-data:/';
  Bases[3] := 'castle-config:/';
  Seen := TStringList.Create;
  Pk3s := TStringList.Create;
  try
    for Base in Bases do
    begin
      { A directory on disk for the loose files and the .pk3 listing }
      if Pos(':/', Base) > 0 then
        Path := UriToFilenameSafe(Base + Dir)
      else
        Path := Base + Dir;
      if (Path <> '') and DirectoryExists(Path) and FirstTime(Path) then
      begin
        if Pak.AddDirectory(Path) > 0 then
          Inc(Result);
      end else
        Path := '';

      for I := 0 to 9 do
      begin
        Name := Dir + '/pak' + IntToStr(I) + '.pak';
        Url := Base + Name;
        if Pos(':/', Base) > 0 then
        begin
          if UriExists(Url) <> ueFile then
            Continue;
        end else
        if not FileExists(Url) then
          Continue;
        if (Pos(':/', Base) = 0) and not FirstTime(Url) then
          Continue;
        if Pak.AddFile(Url) then
          Inc(Result);
      end;

      if Path <> '' then
      begin
        Pk3s.Clear;
        if FindFirst(IncludeTrailingPathDelimiter(Path) + '*', faAnyFile, Info) = 0 then
        try
          repeat
            if ((Info.Attr and faDirectory) = 0) and (LowerCase(ExtractFileExt(Info.Name)) = '.pk3') then
              Pk3s.Add(IncludeTrailingPathDelimiter(Path) + Info.Name);
          until FindNext(Info) <> 0;
        finally
          FindClose(Info);
        end;
        Pk3s.Sort;
        for I := 0 to Pk3s.Count - 1 do
          if Pak.AddPk3(Pk3s[I]) then
            Inc(Result);
      end;
    end;
  finally
    Seen.Free;
    Pk3s.Free;
  end;
end;

{ "host[:port]" into Host and Port (DefaultPort when none) }
procedure SplitAddress(const Address: String; out Host: String; out Port: Word; const DefaultPort: Word);
var
  P: Integer;
begin
  Host := Address;
  Port := DefaultPort;
  P := Pos(':', Address);
  if P > 0 then
  begin
    Host := Copy(Address, 1, P - 1);
    Port := StrToIntDef(Copy(Address, P + 1, MaxInt), DefaultPort);
  end;
  if Host = '' then
    Host := '127.0.0.1';
end;

{ "host[:port]" or "name@rendezvous[:port]" into the client view }
procedure SetNetAddress(const View: TViewDemo; const Address: String);
var
  P: Integer;
  Host: String;
  Port: Word;
begin
  View.HostMap := '';
  View.NetName := '';
  P := Pos('@', Address);
  if P > 0 then
  begin
    View.NetName := Copy(Address, 1, P - 1);
    SplitAddress(Copy(Address, P + 1, MaxInt), Host, Port, CmdPort);
  end else
    SplitAddress(Address, Host, Port, CmdPort);
  View.NetHost := Host;
  View.NetPort := Port;
  View.Spectate := CmdSpectate;
  View.RecordName := CmdRecord;
end;

{ -register "name@rendezvous[:port]" into the host view }
procedure SetRegistration(const View: TViewDemo);
var
  P: Integer;
  Host: String;
  Port: Word;
begin
  View.RegisterName := '';
  P := Pos('@', CmdRegister);
  if P <= 0 then
    Exit;
  View.RegisterName := Copy(CmdRegister, 1, P - 1);
  SplitAddress(Copy(CmdRegister, P + 1, MaxInt), Host, Port, DefaultNetPort);
  View.RegisterHost := Host;
  View.RegisterPort := Port;
end;

{ --export-map <map> <file.x3d|file.gltf>: the level as a scene file }
procedure ExportMap(const MapName, FileName: String);
var
  Bsp: TQuakeBsp;
  Geometry: TQuakeGeometry;
  Url: String;
begin
  Bsp := TQuakeBsp.Create;
  Geometry := nil;
  try
    if not Bsp.LoadFromPak('maps/' + MapName + '.bsp') then
    begin
      WritelnWarning('GameInitialize', 'Cannot load map "%s" for the export', [MapName]);
      Exit;
    end;
    Url := AbsoluteUri(FileName);
    Geometry := TQuakeGeometry.Create(Bsp);
    Geometry.ExportMap(Url);
  finally
    Geometry.Free;
    Bsp.Free;
  end;
end;

{ The UI font: DejaVu Sans like CGE's default, with Latin Extended-A and
  Romanian's comma-below letters (tools/font/make_ui_font.sh) }
procedure UseUiFont;
var
  Font: TCastleFont;
begin
  Font := TCastleFont.Create(Application);
  Font.Load(Font_GameUi);
  UIFont := Font;
  Window.Container.DefaultFont := Font;
end;

{ The options with their own rules (see GameOptions for what a handler
  gets and returns) }

function OptAutoTest(const Args: TStringArray): Integer;
begin
  if Length(Args) < 2 then
    Exit(-1);
  AutoTestMap := Args[0];
  AutoTestPrefix := Args[1];
  { The script's WL: action reads the log from here on }
  StartLogWatch;
  Result := 2;
end;

function OptExportMap(const Args: TStringArray): Integer;
begin
  if Length(Args) < 2 then
    Exit(-1);
  CmdExportMap := Args[0];
  CmdExportUrl := Args[1];
  Result := 2;
end;

function OptRandomMap(const Args: TStringArray): Integer;
begin
  { -randommap [seed]: play maps/random<seed>.bsp (a new seed without one) }
  if (Length(Args) > 0) and (StrToInt64Def(Args[0], -1) >= 0) then
  begin
    CmdWarp := RandomMapName(LongWord(StrToInt64(Args[0])));
    Exit(1);
  end;
  CmdWarp := RandomMapName(NewRandomMapSeed);
  Result := 0;
end;

function OptSplitPlayers(const Args: TStringArray): Integer;
begin
  if Length(Args) < 1 then
    Exit(-1);
  CmdSplit := True;
  CmdCoop := True;
  CmdSplitPlayers := StrToIntDef(Args[0], 2);
  Result := 1;
end;

function OptSplitScreen(const Args: TStringArray): Integer;
begin
  { -splitscreen [stacked|sides] }
  CmdSplit := True;
  CmdCoop := True;
  Result := 0;
  if (Length(Args) > 0) and ((Args[0] = 'stacked') or (Args[0] = 'sides')) then
  begin
    CmdSplitStacked := Args[0] = 'stacked';
    Result := 1;
  end;
end;

function OptName(const Args: TStringArray): Integer;
begin
  if Length(Args) < 1 then
    Exit(-1);
  CmdPlayerName := Args[0];
  CmdPlayerNameSet := True;
  Result := 1;
end;

function OptColor(const Args: TStringArray): Integer;
begin
  { -color <shirt> [<pants>] like Quake's color command }
  if Length(Args) < 1 then
    Exit(-1);
  CmdShirt := EnsureRange(StrToIntDef(Args[0], 0), 0, 13);
  CmdPants := CmdShirt;
  Result := 1;
  if (Length(Args) > 1) and (StrToIntDef(Args[1], -1) >= 0) then
  begin
    CmdPants := EnsureRange(StrToIntDef(Args[1], 0), 0, 13);
    Result := 2;
  end;
end;

function OptTouch(const Args: TStringArray): Integer;
begin
  { The on-screen controls, the mouse as one finger }
  TouchControlsMode := tcOn;
  Result := 0;
end;

function OptNoTouch(const Args: TStringArray): Integer;
begin
  TouchControlsMode := tcOff;
  Result := 0;
end;

function OptProtocol(const Args: TStringArray): Integer;
begin
  { 666: recorded demos and the network game always use FitzQuake,
    999: RMQ (float coordinates); else 15 unless a level needs more
    than 255 models or sounds, a sky or fog (666) or coordinates beyond
    16 bits (999) }
  if Length(Args) < 1 then
    Exit(-1);
  if Args[0] = '666' then
  begin
    PreferredProtocol := ProtocolFitzQuake;
    NetForceProtocol := 666;
  end else
  if Args[0] = '999' then
  begin
    PreferredProtocol := ProtocolRMQ;
    NetForceProtocol := 999;
  end;
  Result := 1;
end;

function OptGame(const Args: TStringArray): Integer;
begin
  if Length(Args) < 1 then
    Exit(-1);
  CmdGame := LowerCase(Args[0]);
  Result := 1;
end;

function OptPak(const Args: TStringArray): Integer;
begin
  if Length(Args) < 1 then
    Exit(-1);
  CmdPaks.Add(Args[0]);
  Result := 1;
end;

{ The table of the command line options. The last argument True: the web
  page takes the option as ?name=value too. }
procedure RegisterOptions;
const
  Web = True;
begin
  ClearOptions;
  { What to play }
  AddTextOption('warp map', CmdWarp, Web);
  AddTextOption('load', CmdLoad);
  AddIntegerOption('skill', CmdSkill, 1, Low(Integer), High(Integer));
  AddCustomOption('randommap', @OptRandomMap, Web);
  AddFlagOption('horde', CmdHorde, Web);
  AddFlagOption('speedrun', CmdSpeedrun);
  AddFlagOption('ghost', CmdGhost);
  AddTextOption('qc', CmdQc);
  AddTextOption('playdemo', CmdPlayDemo);
  AddCustomOption('game', @OptGame);
  AddCustomOption('pak', @OptPak);
  AddTextOption('mapcatalog', MapCatalogOverride);
  AddTextOption('lang', CmdLang, Web);
  { Network games }
  AddTextOption('host', CmdHost, Web);
  AddTextOption('connect', CmdConnect, Web);
  AddIntegerOption('port', CmdPort, 0, Low(Integer), High(Integer));
  AddIntegerOption('bots', CmdBots, 0, Low(Integer), High(Integer), Web);
  AddFlagOption('coop', CmdCoop);
  AddFlagOption('spectate', CmdSpectate, Web);
  AddCustomOption('name', @OptName, Web);
  AddCustomOption('color', @OptColor);
  AddIntegerOption('teamplay', ServerTeamPlay, 0, 0, 2, Web);
  AddNumberOption('fraglimit', ServerFragLimit);
  AddNumberOption('timelimit', ServerTimeLimit);
  AddTextOption('maps', ServerMapRotation);
  AddIntegerOption('spawnspot', ServerSpawnSpot, -1, Low(Integer), High(Integer));
  AddTextOption('record', CmdRecord);
  AddCustomOption('splitscreen', @OptSplitScreen);
  AddCustomOption('splitplayers', @OptSplitPlayers);
  AddTextOption('register', CmdRegister);
  AddFlagOption('rendezvous', CmdRendezvous);
  AddIntegerOption('websocket', CmdWebSocket, DefaultWebSocketPort, Low(Integer), High(Integer));
  AddTextOption('wsrelay', CmdWsRelay);
  AddFlagOption('nopredict', CmdNoPredict);
  AddFlagOption('netloopback', NetLoopback);
  AddCustomOption('protocol', @OptProtocol);
  { The screen }
  AddCustomOption('touch', @OptTouch);
  AddCustomOption('notouch', @OptNoTouch);
  AddNumberOption('density', ForcedDensity);
  AddIntegerOption('lmatlas', LightmapAtlasSize, 2048, 64, 4096);
  { Tests and tools }
  AddCustomOption('autotest', @OptAutoTest);
  AddTextOption('demo', AutoTestDemo);
  AddTextOption('qctest', CmdQcTest);
  AddCustomOption('export-map', @OptExportMap);
end;

procedure ApplicationInitialize;
var
  I: Integer;
  LoadedAny: Boolean;
  Args: TStringArray;
begin
  UseUiFont;
  { Command line options (the table of RegisterOptions) }
  CmdSkill := 1;
  RegisterOptions;
  { The web page has no parameters at all (High is -1 there) }
  SetLength(Args, Max(Parameters.High, 0));
  for I := 1 to Parameters.High do
    Args[I - 1] := Parameters[I];
  ParseOptions(Args);
  {$ifdef WASI}
  { The web page's address: ?warp=<map>, ?horde=1, ?randommap=<seed|new>,
    ?host=<map>, ?bots=N, ?teamplay=N, ?lang=<code>, ?connect=<host>,
    ?spectate=1, ?name=<name> (the options registered for the web) }
  ParseWebOptions(@PageParameter);
  {$endif}

  WritelnLog('GameInitialize', 'Parsed AutoTestMap="%s" Prefix="%s" Demo="%s"', [AutoTestMap, AutoTestPrefix, AutoTestDemo]);

  { The engine's inspector (F8, or three fingers) in every build, not only
    debug ones: the level's components are named for it }
  TCastleContainer.InputInspector.Key := keyF8;
  TCastleContainer.InputInspector.PressFingers := 3;

  Window.Container.LoadSettings('castle-data:/CastleSettings.xml');
  { The UI scale also follows the screen's density (phones), see GameScreen }
  InstallUIScaleWatcher(Window.Container);
  { Quake's textures and lightmaps are not linear: no gamma correction, even
    for the physical materials of the dynamic world lighting }
  ColorSpace := csSRGB;

  { Register URL protocols }
  Pak.RegisterProtocol;
  Palette.RegisterProtocol;

  { Load PAK archives }
  LoadedAny := False;

  { Load custom user paks if specified }
  for I := 0 to CmdPaks.Count - 1 do
    if Pak.AddFile(CmdPaks[I], True) then
      LoadedAny := True;

  { Auto-detect bundled or local PAK files }
  if FileExists('id1/pak0.pak') then
  begin
    Pak.AddFile('id1/pak0.pak', True);
    LoadedAny := True;
  end;
  if FileExists('id1/pak1.pak') then
    Pak.AddFile('id1/pak1.pak', True);

  { The bundled paks through the data URL, which also works where the
    data is packed (the web build has no file system) }
  if UriExists('castle-data:/paks/quake1_demo.pak') = ueFile then
  begin
    Pak.AddFile('castle-data:/paks/quake1_demo.pak', True);
    LoadedAny := True;
  end;

  if UriExists('castle-data:/paks/pak0.pak') = ueFile then
  begin
    Pak.AddFile('castle-data:/paks/pak0.pak');
    LoadedAny := True;
  end;

  if UriExists('castle-data:/paks/pak1.pak') = ueFile then
  begin
    Pak.AddFile('castle-data:/paks/pak1.pak');
    LoadedAny := True;
  end;

  {$ifdef WASI}
  { The web page: ?game=quake plays the original content like -game quake
    (the browser has no game directories) }
  if (PageParameter('game') = 'quake') or (PageParameter('game') = 'id1') then
    CmdGame := PageParameter('game');
  {$endif}

  { -game quake: the id1 start map and its episode portals instead of the
    bundled LibreQuake hub; any other -game is a directory of paks loaded
    on top (a mission pack's progs.dat, maps, models and pictures win) }
  Pak.PreferOriginal := (CmdGame = 'quake') or (CmdGame = 'id1');
  if (CmdGame <> '') and not Pak.PreferOriginal then
  begin
    if LoadGameDir(CmdGame) > 0 then
      GameDir := LowerCase(ExtractFileName(ExcludeTrailingPathDelimiter(CmdGame))) { a path is fine too }
    else
      WritelnWarning('GameInitialize', 'Nothing found for -game "%s": no loose files, pak or pk3 archives ' +
        '(looked in ./%0:s/, next to the executable, the data and the config directory)', [CmdGame]);
  end;

  if not LoadedAny then
    WritelnWarning('GameInitialize', 'No PAK archives found! Check data/paks/ or pass -pak <file>');

  { Load palette and colormap }
  Palette.LoadFromPak;

  { Warm up audio }
  Sounds.PreloadCommonSounds;

  { Headless QuakeC test: spawn a map through progs.dat and run its thinks }
  if CmdQcTest <> '' then
  begin
    RunQcTest(CmdQcTest);
    Application.Terminate;
    Exit;
  end;
  if CmdExportMap <> '' then
  begin
    ExportMap(CmdExportMap, CmdExportUrl);
    Application.Terminate;
    Exit;
  end;

  {$ifdef WASI}
  { The web page's parameters with their own rules (the others are in
    the options' table): ?autotest=<map>&demo=<script> runs a demo script
    like --autotest (the smoke test; screenshots only log, the browser has
    no files) }
  { ?touch=1 always shows the touch controls, ?touch=0 never; without it
    they appear at the first touch }
  if PageParameter('touch') = '1' then
    TouchControlsMode := tcOn
  else
  if PageParameter('touch') = '0' then
    TouchControlsMode := tcOff;
  if PageParameter('fullscreen') = '0' then
    TouchFullscreen := False;
  { ?splitscreen=1 (or stacked): with ?autotest=host:<map> or ?host=<map>,
    split-screen coop with a second local player on the page's own
    (loopback) listen server }
  if PageParameter('splitscreen') <> '' then
  begin
    CmdSplit := True;
    CmdCoop := True;
    CmdSplitStacked := PageParameter('splitscreen') = 'stacked';
    { ?splitscreen=3 or 4: that many local players }
    CmdSplitPlayers := StrToIntDef(PageParameter('splitscreen'), 2);
  end;
  if PageParameter('autotest') <> '' then
  begin
    AutoTestMap := PageParameter('autotest');
    AutoTestPrefix := 'web';
    StartLogWatch;
    AutoTestDemo := PageParameter('demo');
    WritelnLog('GameInitialize', 'Web autotest "%s" with "%s"', [AutoTestMap, AutoTestDemo]);
  end;
  {$endif}

  { The browser keeps the user config directory in localStorage: restored
    before the config is read, written back as files change }
  RestoreWebStorage;
  StartWebStorageSync;

  { The player's bindings (saved in the user config) and the gamepad }
  InitializeBindings;
  { Headless tests keep the default video options (the reference
    screenshots) and never save the ones a test changes }
  if AutoTestMap <> '' then
    VideoSettingsVolatile := True
  else
    LoadVideoSettings;
  if CmdPlayerNameSet then
    PlayerName := CmdPlayerName;
  if CmdShirt >= 0 then
  begin
    PlayerShirt := CmdShirt;
    PlayerPants := CmdPants;
  end;
  { The language: -lang for this run, English in headless tests (the
    reference screenshots and the logged texts), else the saved choice }
  if (CmdLang <> '') or (AutoTestMap <> '') then
  begin
    LanguageVolatile := True;
    if CmdLang <> '' then
      SetLanguage(CmdLang)
    else
      SetLanguage('en');
  end else
    LoadLanguageSettings;
  if CmdSpeedrun then
    SpeedrunTimer := True;
  if CmdGhost then
    GhostRacing := True;

  { Create views }
  ViewMenu := TViewMenu.Create(Application);
  ViewPlay := TViewPlay.Create(Application);
  ViewPlay.HordeMode := CmdHorde;
  ViewDemo := TViewDemo.Create(Application);
  ViewQc := TViewQc.Create(Application);

  { Handle warp / autotest; a .dem name plays that demo instead of a map,
    "qc:map" runs the map with its QuakeC, "host:map" hosts a deathmatch
    game on it, "connect:host[:port]" joins one }
  ViewDemo.Predict := not CmdNoPredict;
  ViewDemo.WebSocketPort := CmdWebSocket;
  if (AutoTestMap <> '') and (LowerCase(Copy(AutoTestMap, 1, 8)) = 'wsrelay:') then
  begin
    ViewDemo.WsRelayTarget := Copy(AutoTestMap, 9, MaxInt);
    ViewDemo.NetPort := CmdPort;
    ViewDemo.AutoTestPrefix := AutoTestPrefix;
    ViewDemo.AutoTestScript := AutoTestDemo;
    Window.Container.View := ViewDemo;
  end else
  if CmdWsRelay <> '' then
  begin
    ViewDemo.WsRelayTarget := CmdWsRelay;
    ViewDemo.NetPort := CmdPort;
    Window.Container.View := ViewDemo;
  end else
  if (AutoTestMap <> '') and (LowerCase(AutoTestMap) = 'rendezvous') then
  begin
    ViewDemo.Rendezvous := True;
    ViewDemo.NetPort := CmdPort;
    ViewDemo.AutoTestPrefix := AutoTestPrefix;
    ViewDemo.AutoTestScript := AutoTestDemo;
    Window.Container.View := ViewDemo;
  end else
  if (AutoTestMap <> '') and (LowerCase(Copy(AutoTestMap, 1, 5)) = 'host:') then
  begin
    ViewDemo.HostMap := Copy(AutoTestMap, 6, MaxInt);
    ViewDemo.RecordName := CmdRecord;
    ViewDemo.HostCoop := CmdCoop;
    ViewDemo.SplitScreen := CmdSplit;
    ViewDemo.SplitStacked := CmdSplitStacked;
    ViewDemo.SplitPlayers := CmdSplitPlayers;
    ViewDemo.HostSkill := CmdSkill;
    ViewDemo.HostBots := CmdBots;
    ViewDemo.NetPort := CmdPort;
    SetRegistration(ViewDemo);
    ViewDemo.AutoTestPrefix := AutoTestPrefix;
    ViewDemo.AutoTestScript := AutoTestDemo;
    Window.Container.View := ViewDemo;
  end else
  if (AutoTestMap <> '') and (LowerCase(Copy(AutoTestMap, 1, 8)) = 'connect:') then
  begin
    SetNetAddress(ViewDemo, Copy(AutoTestMap, 9, MaxInt));
    ViewDemo.AutoTestPrefix := AutoTestPrefix;
    ViewDemo.AutoTestScript := AutoTestDemo;
    Window.Container.View := ViewDemo;
  end else
  if CmdRendezvous then
  begin
    ViewDemo.Rendezvous := True;
    ViewDemo.NetPort := CmdPort;
    Window.Container.View := ViewDemo;
  end else
  if CmdHost <> '' then
  begin
    ViewDemo.HostMap := CmdHost;
    ViewDemo.RecordName := CmdRecord;
    ViewDemo.HostCoop := CmdCoop;
    ViewDemo.SplitScreen := CmdSplit;
    ViewDemo.SplitStacked := CmdSplitStacked;
    ViewDemo.SplitPlayers := CmdSplitPlayers;
    ViewDemo.HostSkill := CmdSkill;
    ViewDemo.HostBots := CmdBots;
    ViewDemo.NetPort := CmdPort;
    SetRegistration(ViewDemo);
    Window.Container.View := ViewDemo;
  end else
  if CmdConnect <> '' then
  begin
    SetNetAddress(ViewDemo, CmdConnect);
    Window.Container.View := ViewDemo;
  end else
  if (AutoTestMap <> '') and (LowerCase(Copy(AutoTestMap, 1, 3)) = 'qc:') then
  begin
    ViewQc.MapName := Copy(AutoTestMap, 4, MaxInt);
    ViewQc.AutoTestPrefix := AutoTestPrefix;
    ViewQc.AutoTestScript := AutoTestDemo;
    Window.Container.View := ViewQc;
  end else
  if CmdQc <> '' then
  begin
    ViewQc.MapName := CmdQc;
    Window.Container.View := ViewQc;
  end else
  if (AutoTestMap <> '') and (LowerCase(ExtractFileExt(AutoTestMap)) = '.dem') then
  begin
    ViewDemo.DemoName := AutoTestMap;
    ViewDemo.AutoTestPrefix := AutoTestPrefix;
    ViewDemo.AutoTestScript := AutoTestDemo;
    Window.Container.View := ViewDemo;
  end else
  if CmdPlayDemo <> '' then
  begin
    ViewDemo.DemoName := CmdPlayDemo;
    Window.Container.View := ViewDemo;
  end else
  if AutoTestMap <> '' then
  begin
    ViewPlay.AutoTestMap := AutoTestMap;
    ViewPlay.AutoTestPrefix := AutoTestPrefix;
    ViewPlay.AutoTestDemo := AutoTestDemo;
    Window.Container.View := ViewPlay;
  end else
  if CmdLoad <> '' then
  begin
    ViewPlay.LoadSlot := CmdLoad;
    Window.Container.View := ViewPlay;
  end else
  if CmdWarp <> '' then
  begin
    ViewPlay.MapName := CmdWarp;
    Window.Container.View := ViewPlay;
  end else
    Window.Container.View := ViewMenu;
end;

function SavedAntiAliasing: TAntiAliasing;
var
  I, Samples: Integer;
begin
  { The window's samples are fixed when it opens, before the user config
    is loaded for everything else: read the one setting here. Headless
    tests and the platforms whose config is not a file yet keep the default. }
  Result := aaNone;
  {$if not defined(ANDROID) and not defined(WASI)}
  for I := 1 to Parameters.High do
    if (Parameters[I] = '--autotest') or (Parameters[I] = '--qctest') or (Parameters[I] = '--export-map') then
      Exit;
  try
    UserConfig.Load;
    Samples := ValidAntiAlias(UserConfig.GetValue('video/fsaa', 1));
  except
    Samples := 1;
  end;
  case Samples of
    2: Result := aa2SamplesFaster;
    4: Result := aa4SamplesFaster;
    8: Result := aa8SamplesFaster;
  end;
  if Samples > 1 then
    WritelnLog('GameInitialize', 'Anti-aliasing: %d samples', [Samples]);
  {$endif}
end;

initialization
  CmdPaks := TStringList.Create;
  ApplicationProperties.ApplicationName := 'castle-quake1';
  ApplicationProperties.Version := '0.2.0';
  LogFileName := 'castle-quake1.log';
  InitializeLog;
  Application.OnInitialize := @ApplicationInitialize;

  Window := TCastleWindow.Create(Application);
  Window.AntiAliasing := SavedAntiAliasing;
  Window.Caption := 'Castle Quake';
  Window.Width := 1600;
  Window.Height := 900;
  Application.MainWindow := Window;
  Window.ParseParameters;

finalization
  CmdPaks.Free;
end.
