{ Game initialization: window, views, PAK asset loading, and command-line parsing. }
unit GameInitialize;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  CastleWindow, CastleLog, CastleUIControls, CastleApplicationProperties, CastleParameters,
  CastleUtils, CastleFilesUtils, CastleUriUtils,
  QuakePak, QuakePalette, QuakeSound,
  GameViewMenu, GameViewPlay;

var
  Window: TCastleWindow;
  AutoTestMap: String;
  AutoTestPrefix: String;
  AutoTestDemo: String;
  CmdWarp: String;
  CmdPaks: TStringList;

procedure ApplicationInitialize;

implementation

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
    if ((Parameters[I] = '-pak') or (Parameters[I] = '--pak')) and (I + 1 <= Parameters.High) then
    begin
      CmdPaks.Add(Parameters[I + 1]);
      Inc(I);
    end;
    Inc(I);
  end;

  WritelnLog('GameInitialize', 'Parsed AutoTestMap="%s" Prefix="%s" Demo="%s"', [AutoTestMap, AutoTestPrefix, AutoTestDemo]);

  Window.Container.LoadSettings('castle-data:/CastleSettings.xml');

  { Register URL protocols }
  Pak.RegisterProtocol;
  Palette.RegisterProtocol;

  { Load PAK archives }
  LoadedAny := False;

  { Load custom user paks if specified }
  for I := 0 to CmdPaks.Count - 1 do
    if Pak.AddFile(CmdPaks[I]) then
      LoadedAny := True;

  { Auto-detect bundled or local PAK files }
  if FileExists('id1/pak0.pak') then
  begin
    Pak.AddFile('id1/pak0.pak');
    LoadedAny := True;
  end;

  if FileExists('data/paks/quake1_demo.pak') then
  begin
    Pak.AddFile('castle-data:/paks/quake1_demo.pak');
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

  if not LoadedAny then
    WritelnWarning('GameInitialize', 'No PAK archives found! Check data/paks/ or pass -pak <file>');

  { Load palette and colormap }
  Palette.LoadFromPak;

  { Warm up audio }
  Sounds.PreloadCommonSounds;

  { Create views }
  ViewMenu := TViewMenu.Create(Application);
  ViewPlay := TViewPlay.Create(Application);

  { Handle warp / autotest }
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
  ApplicationProperties.Version := '0.1.0';
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
