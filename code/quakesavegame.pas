{ Savegame storage: a text file of "key=value" lines (numbers with a dot
  decimal separator, vectors as "x y z"), saved in the user config
  directory through CGE URLs (a file on desktop, browser storage on web). }
unit QuakeSaveGame;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  CastleVectors, CastleDownload, CastleLog;

type
  TQuakeSaveData = class
  private
    FValues: TStringList;
  public
    constructor Create;
    destructor Destroy; override;

    procedure SetStr(const Key, Value: String);
    procedure SetInt(const Key: String; const Value: Int64);
    procedure SetFloat(const Key: String; const Value: Single);
    procedure SetBool(const Key: String; const Value: Boolean);
    procedure SetVec(const Key: String; const Value: TVector3);

    function HasKey(const Key: String): Boolean;
    function GetStr(const Key: String; const Default: String = ''): String;
    function GetInt(const Key: String; const Default: Int64 = 0): Int64;
    function GetFloat(const Key: String; const Default: Single = 0): Single;
    function GetBool(const Key: String; const Default: Boolean = False): Boolean;
    function GetVec(const Key: String; const Default: TVector3): TVector3;

    function SaveToUrl(const Url: String): Boolean;
    function LoadFromUrl(const Url: String): Boolean;
  end;

  { What the load menu shows of a savegame }
  TSaveGameInfo = record
    Slot, Url, Map, Saved: String;
    Skill, Health, Kills, TotalKills: Integer;
    LevelTime: Single;
  end;
  TSaveGameInfoArray = array of TSaveGameInfo;

{ The slot name kept to safe file name characters ('quick' when empty) }
function SaveSlotName(const Slot: String): String;
{ URL of a savegame slot, e.g. 'quick' or 's0' }
function SaveGameUrl(const Slot: String): String;
{ URL of a slot's thumbnail (a small PNG of the view when it was saved) }
function SaveThumbnailUrl(const Slot: String): String;
{ The map, the date, skill, health, kills and level time of a savegame }
function ReadSaveGameInfo(const Url: String; out Info: TSaveGameInfo): Boolean;
{ The play view's savegames in the config directory (save_<slot>.sav, not
  QuakeC mode's qc_save_*), the newest first }
function ListSaveGames: TSaveGameInfoArray;

implementation

uses
  CastleFindFiles, CastleUriUtils;

var
  Fmt: TFormatSettings;

function SaveSlotName(const Slot: String): String;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(Slot) do
    if Slot[I] in ['a'..'z', 'A'..'Z', '0'..'9', '_', '-'] then
      Result := Result + Slot[I];
  if Result = '' then
    Result := 'quick';
end;

function SaveGameUrl(const Slot: String): String;
begin
  Result := 'castle-config:/save_' + SaveSlotName(Slot) + '.sav';
end;

function SaveThumbnailUrl(const Slot: String): String;
begin
  Result := 'castle-config:/save_' + SaveSlotName(Slot) + '.png';
end;

function ReadSaveGameInfo(const Url: String; out Info: TSaveGameInfo): Boolean;
var
  D: TQuakeSaveData;
  Name: String;
begin
  Info := Default(TSaveGameInfo);
  Result := False;
  if UriExists(Url) <> ueFile then
    Exit;
  D := TQuakeSaveData.Create;
  try
    if not D.LoadFromUrl(Url) or not D.HasKey('map') then
      Exit;
    Info.Url := Url;
    Name := ExtractUriName(Url);
    { save_<slot>.sav }
    Info.Slot := Copy(Name, 6, Length(Name) - 9);
    Info.Map := D.GetStr('map');
    Info.Saved := D.GetStr('saved');
    Info.Skill := D.GetInt('skill', 1);
    Info.Health := D.GetInt('stats.health');
    Info.Kills := D.GetInt('stats.kills');
    Info.TotalKills := D.GetInt('stats.totalkills');
    Info.LevelTime := D.GetFloat('stats.leveltime');
    Result := True;
  finally
    D.Free;
  end;
end;

function ListSaveGames: TSaveGameInfoArray;
var
  Found: TFileInfoList;
  I, J, N: Integer;
  Info, T: TSaveGameInfo;
begin
  Result := nil;
  N := 0;
  if UriExists('castle-config:/') <> ueDirectory then
    Exit;
  Found := FindFilesList('castle-config:/', 'save_*.sav', False, []);
  try
    SetLength(Result, Found.Count);
    for I := 0 to Found.Count - 1 do
      if ReadSaveGameInfo(Found[I].Url, Info) then
      begin
        Result[N] := Info;
        Inc(N);
      end;
  finally
    Found.Free;
  end;
  SetLength(Result, N);
  { The newest first (insertion sort: a handful of slots) }
  for I := 1 to N - 1 do
  begin
    T := Result[I];
    J := I;
    while (J > 0) and (Result[J - 1].Saved < T.Saved) do
    begin
      Result[J] := Result[J - 1];
      Dec(J);
    end;
    Result[J] := T;
  end;
end;

constructor TQuakeSaveData.Create;
begin
  inherited Create;
  FValues := TStringList.Create;
  FValues.NameValueSeparator := '=';
end;

destructor TQuakeSaveData.Destroy;
begin
  FValues.Free;
  inherited Destroy;
end;

procedure TQuakeSaveData.SetStr(const Key, Value: String);
begin
  FValues.Values[Key] := StringReplace(Value, LineEnding, '\n', [rfReplaceAll]);
end;

procedure TQuakeSaveData.SetInt(const Key: String; const Value: Int64);
begin
  FValues.Values[Key] := IntToStr(Value);
end;

procedure TQuakeSaveData.SetFloat(const Key: String; const Value: Single);
begin
  FValues.Values[Key] := FloatToStr(Value, Fmt);
end;

procedure TQuakeSaveData.SetBool(const Key: String; const Value: Boolean);
begin
  if Value then
    FValues.Values[Key] := '1'
  else
    FValues.Values[Key] := '0';
end;

procedure TQuakeSaveData.SetVec(const Key: String; const Value: TVector3);
begin
  FValues.Values[Key] := FloatToStr(Value.X, Fmt) + ' ' + FloatToStr(Value.Y, Fmt) + ' ' +
    FloatToStr(Value.Z, Fmt);
end;

function TQuakeSaveData.HasKey(const Key: String): Boolean;
begin
  Result := FValues.IndexOfName(Key) >= 0;
end;

function TQuakeSaveData.GetStr(const Key: String; const Default: String): String;
begin
  if HasKey(Key) then
    Result := StringReplace(FValues.Values[Key], '\n', LineEnding, [rfReplaceAll])
  else
    Result := Default;
end;

function TQuakeSaveData.GetInt(const Key: String; const Default: Int64): Int64;
begin
  Result := StrToInt64Def(FValues.Values[Key], Default);
end;

function TQuakeSaveData.GetFloat(const Key: String; const Default: Single): Single;
begin
  Result := StrToFloatDef(FValues.Values[Key], Default, Fmt);
end;

function TQuakeSaveData.GetBool(const Key: String; const Default: Boolean): Boolean;
begin
  if HasKey(Key) then
    Result := FValues.Values[Key] = '1'
  else
    Result := Default;
end;

function TQuakeSaveData.GetVec(const Key: String; const Default: TVector3): TVector3;
var
  Parts: TStringArray;
begin
  Parts := FValues.Values[Key].Split([' ']);
  if Length(Parts) <> 3 then
    Exit(Default);
  Result := Vector3(StrToFloatDef(Parts[0], Default.X, Fmt), StrToFloatDef(Parts[1], Default.Y, Fmt),
    StrToFloatDef(Parts[2], Default.Z, Fmt));
end;

function TQuakeSaveData.SaveToUrl(const Url: String): Boolean;
var
  Stream: TStream;
begin
  Result := False;
  try
    Stream := UrlSaveStream(Url);
    try
      FValues.SaveToStream(Stream);
    finally
      Stream.Free;
    end;
    Result := True;
  except
    on E: Exception do
      WritelnWarning('QuakeSaveGame', 'Cannot save "%s": %s', [Url, E.Message]);
  end;
end;

function TQuakeSaveData.LoadFromUrl(const Url: String): Boolean;
var
  Stream: TStream;
begin
  Result := False;
  try
    Stream := Download(Url);
    try
      FValues.LoadFromStream(Stream);
    finally
      Stream.Free;
    end;
    Result := True;
  except
    on E: Exception do
      WritelnWarning('QuakeSaveGame', 'Cannot load "%s": %s', [Url, E.Message]);
  end;
end;

initialization
  Fmt := DefaultFormatSettings;
  Fmt.DecimalSeparator := '.';
end.
