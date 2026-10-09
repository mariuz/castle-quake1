{ Game initialization: window, views, PAK asset loading, and command-line parsing. }
unit GameInitialize;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  CastleWindow, CastleLog, CastleUIControls, CastleApplicationProperties, CastleParameters,
  CastleUtils, CastleFilesUtils, CastleUriUtils, CastleRenderOptions,
  QuakePak, QuakePalette, QuakeSound, QuakeBsp, QuakeProgs,
  GameViewMenu, GameViewPlay, GameViewDemo, GameViewQc;

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

procedure ApplicationInitialize;
var
  I: Integer;
  LoadedAny: Boolean;
begin
  { Command line options }
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
    if (Parameters[I] = '--qctest') and (I + 1 <= Parameters.High) then
    begin
      CmdQcTest := Parameters[I + 1];
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

  if FileExists('data/paks/quake1_demo.pak') then
  begin
    Pak.AddFile('castle-data:/paks/quake1_demo.pak', True);
    LoadedAny := True;
  end;

  if FileExists('data/paks/pak0.pak') then
  begin
    Pak.AddFile('castle-data:/paks/pak0.pak');
    LoadedAny := True;
  end;

  if FileExists('data/paks/pak1.pak') then
  begin
    Pak.AddFile('castle-data:/paks/pak1.pak');
    LoadedAny := True;
  end;

  { -game quake: the id1 start map and its episode portals instead of the
    bundled LibreQuake hub }
  Pak.PreferOriginalMaps := (CmdGame = 'quake') or (CmdGame = 'id1');

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

  { Create views }
  ViewMenu := TViewMenu.Create(Application);
  ViewPlay := TViewPlay.Create(Application);
  ViewDemo := TViewDemo.Create(Application);
  ViewQc := TViewQc.Create(Application);

  { Handle warp / autotest; a .dem name plays that demo instead of a map,
    "qc:map" runs the map with its QuakeC }
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
