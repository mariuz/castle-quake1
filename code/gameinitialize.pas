{ Game initialization: window, views, PAK asset loading, and command-line parsing. }
unit GameInitialize;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  CastleWindow, CastleLog, CastleUIControls, CastleApplicationProperties, CastleParameters,
  CastleUtils, CastleFilesUtils, CastleUriUtils, CastleRenderOptions, CastleKeysMouse,
  QuakePak, QuakePalette, QuakeSound, QuakeBsp, QuakeProgs, QuakeGeometry,
  GameViewMenu, GameViewPlay, GameViewDemo, GameViewQc, QuakeNet, GameInput, QuakeWebSocketClient;

var
  Window: TCastleWindow;
  AutoTestMap: String;
  AutoTestPrefix: String;
  AutoTestDemo: String;
  CmdWarp: String;
  CmdPaks: TStringList;
  CmdGame: String;
  CmdPlayDemo: String;
  CmdQcTest: String;
  CmdQc: String;
  CmdHost: String;
  CmdConnect: String;
  CmdRegister: String;
  CmdRendezvous: Boolean;
  CmdWebSocket: Integer;
  CmdWsRelay: String;
  CmdNoPredict: Boolean;
  CmdPort: Integer;
  CmdCoop: Boolean;
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
  id1: its pak0..pak9.pak from the working directory, next to the
  executable, the data directory or the config directory. Returns the
  number of paks loaded. }
function LoadGameDir(const Dir: String): Integer;
var
  I: Integer;
  Base, Name, Url: String;
  Bases: array[0..3] of String;
begin
  Result := 0;
  Bases[0] := '';
  Bases[1] := ExtractFilePath(ParamStr(0));
  Bases[2] := 'castle-data:/';
  Bases[3] := 'castle-config:/';
  for Base in Bases do
    for I := 0 to 9 do
    begin
      Name := Dir + '/pak' + IntToStr(I) + '.pak';
      if Pos(':/', Base) > 0 then
      begin
        Url := Base + Name;
        if UriExists(Url) <> ueFile then
          Continue;
      end else
      begin
        Url := Base + Name;
        if not FileExists(Url) then
          Continue;
      end;
      if Pak.AddFile(Url) then
        Inc(Result);
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

procedure ApplicationInitialize;
var
  I: Integer;
  LoadedAny: Boolean;
begin
  { Command line options }
  CmdSkill := 1;
  I := 1;
  while I <= Parameters.High do
  begin
    if (Parameters[I] = '--autotest') and (I + 2 <= Parameters.High) then
    begin
      AutoTestMap := Parameters[I + 1];
      AutoTestPrefix := Parameters[I + 2];
      Inc(I, 2);
    end else
    if (Parameters[I] = '--demo') and (I + 1 <= Parameters.High) then
    begin
      AutoTestDemo := Parameters[I + 1];
      Inc(I);
    end else
    if ((Parameters[I] = '-warp') or (Parameters[I] = '--warp') or (Parameters[I] = '-map')) and (I + 1 <= Parameters.High) then
    begin
      CmdWarp := Parameters[I + 1];
      Inc(I);
    end else
    if ((Parameters[I] = '-qc') or (Parameters[I] = '--qc')) and (I + 1 <= Parameters.High) then
    begin
      CmdQc := Parameters[I + 1];
      Inc(I);
    end else
    if (Parameters[I] = '--export-map') and (I + 2 <= Parameters.High) then
    begin
      CmdExportMap := Parameters[I + 1];
      CmdExportUrl := Parameters[I + 2];
      Inc(I, 2);
    end else
    if (Parameters[I] = '--qctest') and (I + 1 <= Parameters.High) then
    begin
      CmdQcTest := Parameters[I + 1];
      Inc(I);
    end else
    if ((Parameters[I] = '-host') or (Parameters[I] = '--host')) and (I + 1 <= Parameters.High) then
    begin
      CmdHost := Parameters[I + 1];
      Inc(I);
    end else
    if ((Parameters[I] = '-connect') or (Parameters[I] = '--connect')) and (I + 1 <= Parameters.High) then
    begin
      CmdConnect := Parameters[I + 1];
      Inc(I);
    end else
    if (Parameters[I] = '-coop') or (Parameters[I] = '--coop') then
      CmdCoop := True
    else
    if ((Parameters[I] = '-register') or (Parameters[I] = '--register')) and (I + 1 <= Parameters.High) then
    begin
      CmdRegister := Parameters[I + 1];
      Inc(I);
    end else
    if (Parameters[I] = '-rendezvous') or (Parameters[I] = '--rendezvous') then
      CmdRendezvous := True
    else
    if ((Parameters[I] = '-websocket') or (Parameters[I] = '--websocket')) and (I + 1 <= Parameters.High) then
    begin
      CmdWebSocket := StrToIntDef(Parameters[I + 1], DefaultWebSocketPort);
      Inc(I);
    end else
    if ((Parameters[I] = '-wsrelay') or (Parameters[I] = '--wsrelay')) and (I + 1 <= Parameters.High) then
    begin
      CmdWsRelay := Parameters[I + 1];
      Inc(I);
    end else
    if (Parameters[I] = '-nopredict') or (Parameters[I] = '--nopredict') then
      CmdNoPredict := True
    else
    if ((Parameters[I] = '-skill') or (Parameters[I] = '--skill')) and (I + 1 <= Parameters.High) then
    begin
      CmdSkill := StrToIntDef(Parameters[I + 1], 1);
      Inc(I);
    end else
    if ((Parameters[I] = '-port') or (Parameters[I] = '--port')) and (I + 1 <= Parameters.High) then
    begin
      CmdPort := StrToIntDef(Parameters[I + 1], 0);
      Inc(I);
    end else
    if ((Parameters[I] = '-playdemo') or (Parameters[I] = '--playdemo')) and (I + 1 <= Parameters.High) then
    begin
      CmdPlayDemo := Parameters[I + 1];
      Inc(I);
    end else
    if ((Parameters[I] = '-game') or (Parameters[I] = '--game')) and (I + 1 <= Parameters.High) then
    begin
      CmdGame := LowerCase(Parameters[I + 1]);
      Inc(I);
    end else
    if ((Parameters[I] = '-pak') or (Parameters[I] = '--pak')) and (I + 1 <= Parameters.High) then
    begin
      CmdPaks.Add(Parameters[I + 1]);
      Inc(I);
    end;
    Inc(I);
  end;

  WritelnLog('GameInitialize', 'Parsed AutoTestMap="%s" Prefix="%s" Demo="%s"', [AutoTestMap, AutoTestPrefix, AutoTestDemo]);

  { The engine's inspector (F8, or three fingers) in every build, not only
    debug ones: the level's components are named for it }
  TCastleContainer.InputInspector.Key := keyF8;
  TCastleContainer.InputInspector.PressFingers := 3;

  Window.Container.LoadSettings('castle-data:/CastleSettings.xml');
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

  { -game quake: the id1 start map and its episode portals instead of the
    bundled LibreQuake hub; any other -game is a directory of paks loaded
    on top (a mission pack's progs.dat, maps, models and pictures win) }
  Pak.PreferOriginalMaps := (CmdGame = 'quake') or (CmdGame = 'id1');
  if (CmdGame <> '') and not Pak.PreferOriginalMaps then
  begin
    if LoadGameDir(CmdGame) > 0 then
      GameDir := LowerCase(ExtractFileName(ExcludeTrailingPathDelimiter(CmdGame))) { a path is fine too }
    else
      WritelnWarning('GameInitialize', 'No pak0.pak found for -game "%s" (looked in ./%0:s/, next to the executable, ' +
        'the data and the config directory)', [CmdGame]);
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

  { The player's bindings (saved in the user config) and the gamepad }
  InitializeBindings;

  { Create views }
  ViewMenu := TViewMenu.Create(Application);
  ViewPlay := TViewPlay.Create(Application);
  ViewDemo := TViewDemo.Create(Application);
  ViewQc := TViewQc.Create(Application);

  { Handle warp / autotest; a .dem name plays that demo instead of a map,
    "qc:map" runs the map with its QuakeC, "host:map" hosts a deathmatch
    game on it, "connect:host[:port]" joins one }
  ViewDemo.Predict := not CmdNoPredict;
  ViewDemo.WebSocketPort := CmdWebSocket;
  {$ifdef WASI}
  { The web page: ?connect=host[:port] (or a ws:// / wss:// URL) joins a
    game through its WebSocket relay }
  if PageParameter('connect') <> '' then
    CmdConnect := PageParameter('connect');
  {$endif}
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
    ViewDemo.HostCoop := CmdCoop;
    ViewDemo.HostSkill := CmdSkill;
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
    ViewDemo.HostCoop := CmdCoop;
    ViewDemo.HostSkill := CmdSkill;
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
  if CmdWarp <> '' then
  begin
    ViewPlay.MapName := CmdWarp;
    Window.Container.View := ViewPlay;
  end else
    Window.Container.View := ViewMenu;
end;

initialization
  CmdPaks := TStringList.Create;
  ApplicationProperties.ApplicationName := 'castle-quake1';
  ApplicationProperties.Version := '0.2.0';
  LogFileName := 'castle-quake1.log';
  InitializeLog;
  Application.OnInitialize := @ApplicationInitialize;

  Window := TCastleWindow.Create(Application);
  Window.Caption := 'Castle Quake';
  Window.Width := 1600;
  Window.Height := 900;
  Application.MainWindow := Window;
  Window.ParseParameters;

finalization
  CmdPaks.Free;
end.
