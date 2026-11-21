{ The console commands that only change settings (video, accessibility,
  rendering of mods): one table of names, help lines and handlers, run by
  every view's console and by the test scripts' CMD: action. A view tries
  this table first and handles its own commands (map, save, god...) after. }
unit GameConsole;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

type
  { Returns what the console prints (the settings' values after the change) }
  TSettingsCommandHandler = function(const Cmd, Args: String): String;

  TSettingsCommand = record
    { The command names it answers to, separated by spaces }
    Names: String;
    { The line "help" shows (English, translated when shown) }
    Help: String;
    Run: TSettingsCommandHandler;
  end;

{ Run Cmd when it is a settings command: Reply is what to print, and the
  log gets "Console: <cmd> <args>: <reply>". False for any other command. }
function RunSettingsCommand(const Cmd, Args: String; out Reply: String): Boolean;
{ The help lines of the settings commands, translated }
procedure SettingsCommandHelp(const Lines: TStrings);
{ Every name of the table (tests, completion) }
function SettingsCommandNames: TStringArray;

implementation

uses
  Math, CastleLog,
  GameVideo, GameTranslate, QuakePalette, QuakeProgs, QuakeCaptions, QuakeModelLight, QuakeDecals;

function IsOn(const Args: String): Boolean;
begin
  Result := (Args = '1') or SameText(Args, 'on');
end;

function CmdVideo(const Cmd, Args: String): String;
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
      ShowWeapon := IsOn(Args);
    SaveVideoSettings;
  end;
  Result := Format('fov %.0f (vertical %.1f), gamma %.2f, cl_bob %.3f, r_drawviewmodel %d',
    [VideoFov, RadToDeg(VerticalFov), VideoGamma, ViewBob, Ord(ShowWeapon)]);
end;

function CmdTextures(const Cmd, Args: String): String;
begin
  { Texture filtering (the next level's textures) and multisampling
    (after a restart) }
  if Args <> '' then
  begin
    if Cmd = 'gl_texturemode' then
      TextureSmooth := Pos('linear', LowerCase(Args)) = 1
    else if Cmd = 'gl_texture_anisotropy' then
      TextureAnisotropy := ValidAnisotropy(StrToIntDef(Args, TextureAnisotropy))
    else
      AntiAliasSamples := ValidAntiAlias(StrToIntDef(Args, AntiAliasSamples));
    SaveVideoSettings;
  end;
  Result := Format('gl_texturemode %s, gl_texture_anisotropy %d, vid_fsaa %d',
    [BoolToStr(TextureSmooth, 'linear', 'nearest'), TextureAnisotropy, AntiAliasSamples]);
  WritelnLog('GameConsole', 'Video: texture filter %s, anisotropy %d, anti-aliasing %d samples',
    [BoolToStr(TextureSmooth, 'linear', 'nearest'), TextureAnisotropy, AntiAliasSamples]);
end;

function CmdAccess(const Cmd, Args: String): String;
begin
  { Accessibility options (saved like the Options menu ones) }
  if Args <> '' then
  begin
    if Cmd = 'captions' then
      CaptionsEnabled := IsOn(Args)
    else if Cmd = 'hud_contrast' then
      HighContrastHud := IsOn(Args)
    else
      ReducedFlashes := IsOn(Args);
    SaveVideoSettings;
  end;
  Result := Format('captions %d, hud_contrast %d, reduced_flashes %d',
    [Ord(CaptionsEnabled), Ord(HighContrastHud), Ord(ReducedFlashes)]);
end;

function CmdSwitch(const Cmd, Args: String): String;
var
  Value: ^Boolean;
begin
  { On / off switches that are not saved }
  if Cmd = 'r_lerpmodels' then
    Value := @ModelLerp
  else if Cmd = 'r_lerpmove' then
    Value := @MoveLerp
  else if Cmd = 'r_effectinfo' then
    Value := @ModEffects
  else if Cmd = 'r_waterwarp' then
    Value := @WaterWarp
  else if Cmd = 'r_modellight' then
    Value := @ModelLight
  else if Cmd = 'r_decals' then
    Value := @DecalsEnabled
  else
    Value := @ProgsExtensions;
  if Args <> '' then
    Value^ := Args <> '0';
  Result := Format('%s %d', [Cmd, Ord(Value^)]);
  { What the last frame lit }
  if Cmd = 'r_modellight' then
    Result := Result + ' (' + ModelLightStats + ')';
  if Cmd = 'r_decals' then
    Result := Result + Format(' (%d decals, %d made)', [Decals.Count, Decals.Made]);
end;

const
  Commands: array[0..13] of TSettingsCommand = (
    (Names: 'fov'; Help: '  fov <degrees>  - Field of view at 4:3 (wider screens see more)'; Run: @CmdVideo),
    (Names: 'gamma'; Help: '  gamma <0.4..1.5> - Brightness, lower is brighter'; Run: @CmdVideo),
    (Names: 'cl_bob r_drawviewmodel';
     Help: '  cl_bob <0..0.1> - View bob (0 off), r_drawviewmodel <0|1> - the weapon'; Run: @CmdVideo),
    (Names: 'gl_texturemode gl_texture_anisotropy';
     Help: '  gl_texturemode <nearest|linear>, gl_texture_anisotropy <1..16> - Texture filtering (next level)';
     Run: @CmdTextures),
    (Names: 'vid_fsaa'; Help: '  vid_fsaa <1|2|4|8> - Anti-aliasing samples (after a restart)'; Run: @CmdTextures),
    (Names: 'captions hud_contrast reduced_flashes';
     Help: '  captions <0|1>, hud_contrast <0|1>, reduced_flashes <0|1> - Accessibility'; Run: @CmdAccess),
    (Names: 'r_waterwarp'; Help: '  r_waterwarp <0|1> - The picture waves under water'; Run: @CmdSwitch),
    (Names: 'r_modellight';
     Help: '  r_modellight <0|1> - Models take the light of the level and of flashes and explosions';
     Run: @CmdSwitch),
    (Names: 'r_decals';
     Help: '  r_decals <0|1> - Shots, explosions and blood leave marks on the walls and floors';
     Run: @CmdSwitch),
    (Names: 'r_lerpmodels';
     Help: '  r_lerpmodels <0|1> - Blend the models from pose to pose (QuakeC mode, demos, network)';
     Run: @CmdSwitch),
    (Names: 'r_lerpmove';
     Help: '  r_lerpmove <0|1> - Walking monsters glide between their steps (QuakeC mode)'; Run: @CmdSwitch),
    (Names: 'pr_checkextension';
     Help: '  pr_checkextension <0|1> - Mods may use the QuakeC extensions (next QuakeC map)'; Run: @CmdSwitch),
    (Names: 'r_effectinfo';
     Help: '  r_effectinfo <0|1> - A mod''s effectinfo.txt draws the explosions, impacts and trails';
     Run: @CmdSwitch),
    (Names: ''; Help: ''; Run: nil)
  );

function RunSettingsCommand(const Cmd, Args: String; out Reply: String): Boolean;
var
  I: Integer;
  Name: String;
begin
  Reply := '';
  for I := 0 to High(Commands) do
    if Assigned(Commands[I].Run) then
      for Name in Commands[I].Names.Split([' ']) do
        if Name = Cmd then
        begin
          Reply := Commands[I].Run(Cmd, Args);
          WritelnLog('GameConsole', 'Console: %s: %s', [Trim(Cmd + ' ' + Args), Reply]);
          Exit(True);
        end;
  Result := False;
end;

procedure SettingsCommandHelp(const Lines: TStrings);
var
  I: Integer;
begin
  for I := 0 to High(Commands) do
    if Commands[I].Help <> '' then
      Lines.Add(Tr(Commands[I].Help));
end;

function SettingsCommandNames: TStringArray;
var
  I: Integer;
  Name: String;
begin
  SetLength(Result, 0);
  for I := 0 to High(Commands) do
    for Name in Commands[I].Names.Split([' '], TStringSplitOptions.ExcludeEmpty) do
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Name;
    end;
end;

end.
