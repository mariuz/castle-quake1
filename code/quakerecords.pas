{ Map records: the best time, kills and secrets of the player's finished
  runs of each map and skill, kept in castle-config:/records.txt (one line
  per map and skill: map, skill, best time, kills, total kills, secrets,
  total secrets, runs, tab separated). }
unit QuakeRecords;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

type
  TMapRecord = record
    Map: String;
    Skill: Integer;
    BestTime: Single;   { seconds, 0: none yet }
    Kills, TotalKills: Integer;
    Secrets, TotalSecrets: Integer;
    Runs: Integer;
  end;
  TMapRecordArray = array of TMapRecord;

  { What a finished run improved }
  TRecordNews = record
    Time, Kills, Secrets: Boolean;
    First: Boolean;     { the first finished run of this map and skill }
    Previous: TMapRecord;
  end;

  TMapRecords = class
  private
    FItems: TMapRecordArray;
    function IndexOf(const AMap: String; const ASkill: Integer): Integer;
  public
    procedure Clear;
    procedure LoadFromText(const Text: String);
    function SaveToText: String;
    function Count: Integer;
    function Item(const I: Integer): TMapRecord;
    function Find(const AMap: String; const ASkill: Integer; out R: TMapRecord): Boolean;
    { A finished run: the record of its map and skill takes what it
      improves (a shorter time, more kills, more secrets) }
    function Finish(const AMap: String; const ASkill: Integer; const Time: Single;
      const Kills, TotalKills, Secrets, TotalSecrets: Integer): TRecordNews;
    { Forget one map's records ('' every map) }
    procedure Reset(const AMap: String);
    { The records of a map on every skill, for the map list }
    function Describe(const AMap: String): String;
  end;

const
  RecordsUrl = 'castle-config:/records.txt';
  SkillNames: array[0..3] of String = ('Easy', 'Normal', 'Hard', 'Nightmare');

{ The records of this user, loaded from RecordsUrl the first time }
function MapRecords: TMapRecords;
procedure SaveMapRecords;

{ m:ss.cc }
function FormatRecordTime(const T: Single): String;

implementation

uses
  Math, CastleDownload, CastleLog, CastleFilesUtils, CastleUriUtils, GameTranslate;

function FormatRecordTime(const T: Single): String;
var
  C: Integer;
begin
  C := Round(Max(T, 0) * 100);
  Result := Format('%d:%.2d.%.2d', [C div 6000, (C div 100) mod 60, C mod 100]);
end;

procedure TMapRecords.Clear;
begin
  FItems := nil;
end;

function TMapRecords.IndexOf(const AMap: String; const ASkill: Integer): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FItems) do
    if SameText(FItems[I].Map, AMap) and (FItems[I].Skill = ASkill) then
      Exit(I);
  Result := -1;
end;

procedure TMapRecords.LoadFromText(const Text: String);
var
  Line: String;
  F: TStringArray;
  R: TMapRecord;
  Fmt: TFormatSettings;
begin
  Clear;
  Fmt := DefaultFormatSettings;
  Fmt.DecimalSeparator := '.';
  for Line in Text.Split([#10, #13], TStringSplitOptions.ExcludeEmpty) do
  begin
    F := Line.Split([#9]);
    if (Length(F) < 8) or (Trim(F[0]) = '') then
      Continue;
    R := Default(TMapRecord);
    R.Map := LowerCase(Trim(F[0]));
    R.Skill := EnsureRange(StrToIntDef(F[1], 1), 0, 3);
    R.BestTime := StrToFloatDef(F[2], 0, Fmt);
    R.Kills := StrToIntDef(F[3], 0);
    R.TotalKills := StrToIntDef(F[4], 0);
    R.Secrets := StrToIntDef(F[5], 0);
    R.TotalSecrets := StrToIntDef(F[6], 0);
    R.Runs := StrToIntDef(F[7], 0);
    if IndexOf(R.Map, R.Skill) < 0 then
    begin
      SetLength(FItems, Length(FItems) + 1);
      FItems[High(FItems)] := R;
    end;
  end;
end;

function TMapRecords.SaveToText: String;
var
  R: TMapRecord;
  Fmt: TFormatSettings;
begin
  Fmt := DefaultFormatSettings;
  Fmt.DecimalSeparator := '.';
  Result := '';
  for R in FItems do
    Result := Result + Format('%s'#9'%d'#9'%s'#9'%d'#9'%d'#9'%d'#9'%d'#9'%d'#10,
      [R.Map, R.Skill, FormatFloat('0.00', R.BestTime, Fmt), R.Kills, R.TotalKills, R.Secrets,
       R.TotalSecrets, R.Runs]);
end;

function TMapRecords.Count: Integer;
begin
  Result := Length(FItems);
end;

function TMapRecords.Item(const I: Integer): TMapRecord;
begin
  Result := FItems[I];
end;

function TMapRecords.Find(const AMap: String; const ASkill: Integer; out R: TMapRecord): Boolean;
var
  I: Integer;
begin
  I := IndexOf(AMap, ASkill);
  Result := I >= 0;
  if Result then
    R := FItems[I]
  else
    R := Default(TMapRecord);
end;

function TMapRecords.Finish(const AMap: String; const ASkill: Integer; const Time: Single;
  const Kills, TotalKills, Secrets, TotalSecrets: Integer): TRecordNews;
var
  I: Integer;
begin
  Result := Default(TRecordNews);
  I := IndexOf(AMap, ASkill);
  if I < 0 then
  begin
    SetLength(FItems, Length(FItems) + 1);
    I := High(FItems);
    FItems[I] := Default(TMapRecord);
    FItems[I].Map := LowerCase(AMap);
    FItems[I].Skill := ASkill;
    Result.First := True;
  end;
  Result.Previous := FItems[I];
  Inc(FItems[I].Runs);
  FItems[I].TotalKills := TotalKills;
  FItems[I].TotalSecrets := TotalSecrets;
  if Result.First then
  begin
    { The first run is the record, nothing to beat yet }
    FItems[I].BestTime := Round(Max(Time, 0) * 100) / 100;
    FItems[I].Kills := Kills;
    FItems[I].Secrets := Secrets;
    Exit;
  end;
  { In the hundredths shown (the file keeps no more) }
  if (Time > 0) and ((FItems[I].BestTime <= 0) or (Round(Time * 100) < Round(FItems[I].BestTime * 100))) then
  begin
    FItems[I].BestTime := Round(Time * 100) / 100;
    Result.Time := True;
  end;
  { Kills and secrets count the most found in one run }
  if Kills > FItems[I].Kills then
  begin
    FItems[I].Kills := Kills;
    Result.Kills := True;
  end;
  if Secrets > FItems[I].Secrets then
  begin
    FItems[I].Secrets := Secrets;
    Result.Secrets := True;
  end;
end;

procedure TMapRecords.Reset(const AMap: String);
var
  I: Integer;
begin
  if AMap = '' then
  begin
    Clear;
    Exit;
  end;
  for I := High(FItems) downto 0 do
    if SameText(FItems[I].Map, AMap) then
      Delete(FItems, I, 1);
end;

function TMapRecords.Describe(const AMap: String): String;
var
  S: Integer;
  R: TMapRecord;
begin
  Result := '';
  for S := 0 to 3 do
    if Find(AMap, S, R) then
    begin
      if Result <> '' then
        Result := Result + '; ';
      Result := Result + Format(Tr('%s: %s, kills %d/%d, secrets %d/%d'),
        [Tr(SkillNames[S]), FormatRecordTime(R.BestTime), R.Kills, R.TotalKills, R.Secrets, R.TotalSecrets]);
    end;
end;

var
  FRecords: TMapRecords;

function MapRecords: TMapRecords;
var
  Stream: TStream;
  Text: String;
begin
  if FRecords = nil then
  begin
    FRecords := TMapRecords.Create;
    { No file yet: no records (checked first, the web build cannot raise) }
    if UriExists(RecordsUrl) = ueFile then
    try
      Stream := Download(RecordsUrl);
      try
        Text := '';
        SetLength(Text, Stream.Size);
        if Stream.Size > 0 then
          Stream.ReadBuffer(Text[1], Stream.Size);
        FRecords.LoadFromText(Text);
      finally
        Stream.Free;
      end;
    except
      on E: Exception do
        WritelnWarning('Records', 'Cannot read the map records: ' + E.Message);
    end;
  end;
  Result := FRecords;
end;

procedure SaveMapRecords;
var
  Stream: TStream;
  Text: String;
begin
  Text := MapRecords.SaveToText;
  try
    Stream := UrlSaveStream(RecordsUrl);
    try
      if Text <> '' then
        Stream.WriteBuffer(Text[1], Length(Text));
    finally
      Stream.Free;
    end;
  except
    on E: Exception do
      WritelnWarning('Records', 'Cannot save the map records: ' + E.Message);
  end;
end;

finalization
  FreeAndNil(FRecords);
end.
