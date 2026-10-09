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

{ URL of a savegame slot, e.g. 'quick' or 's0' }
function SaveGameUrl(const Slot: String): String;

implementation

var
  Fmt: TFormatSettings;

function SaveGameUrl(const Slot: String): String;
var
  I: Integer;
  Name: String;
begin
  { Keep slot names to safe file name characters }
  Name := '';
  for I := 1 to Length(Slot) do
    if Slot[I] in ['a'..'z', 'A'..'Z', '0'..'9', '_', '-'] then
      Name := Name + Slot[I];
  if Name = '' then
    Name := 'quick';
  Result := 'castle-config:/save_' + Name + '.sav';
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
