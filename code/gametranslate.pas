{ Localization: the menu, the HUD, the console help, the captions and the
  labels of the editor designs in another language.

  A translation is a gettext .po file, castle-data:/lang/<code>.po (msgid
  the English text, msgstr its translation; castle-quake.pot next to them
  lists every text, made by tools/lang_strings.py). Texts are translated
  where they are shown (Tr, TrItem, TranslateDesign), so the code keeps
  working with the English ones (the menu dispatches on its item texts).
  Quake's own texts (level names, centerprints, the progs' prints) stay as
  the maps and progs give them. }
unit GameTranslate;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Generics.Collections;

type
  TLanguageInfo = record
    Code, Name: String;
  end;
  TLanguageInfoArray = array of TLanguageInfo;
  TTranslationDictionary = specialize TDictionary<String, String>;

var
  { The language chosen in Options, with -lang or ?lang= ('' follows the
    system's language) }
  LanguageSetting: String;
  { Bumped on every change of the language, so the designs are translated
    again (TranslateDesign) by the views that show them }
  LanguageVersion: Integer = 1;
  { Autotest runs: English unless -lang says otherwise, never saved }
  LanguageVolatile: Boolean;

{ The translation of S in the current language, S itself when there is none }
function Tr(const S: String): String;
{ A menu item: the whole text, else "Label: value" with both parts (a
  value in brackets "[ON]" translated inside them) }
function TrItem(const S: String): String;
{ Translate every label (and button) the Root owns, line by line, keeping
  the English texts to translate them again after a language change }
procedure TranslateDesign(const Root: TComponent);

{ The languages with a translation (castle-data:/lang/languages.txt), English first }
function Languages: TLanguageInfoArray;
{ The language in use: 'en', 'de'... and its own name ('Deutsch') }
function CurrentLanguage: String;
function CurrentLanguageName: String;
function LanguageName(const Code: String): String;
{ The system's language as a two letter code ('' unknown) }
function SystemLanguage: String;
{ Use a language: a code, or '' for the system's (English when there is no
  translation); logs "Language: <code> (<name>), N texts" }
procedure SetLanguage(const Code: String);
{ The next language for the Options item: Auto, English, then the others }
function NextLanguageSetting(const Current: String): String;
procedure LoadLanguageSettings;
procedure SaveLanguageSettings;

{ Read a .po text into Dict (msgid -> msgstr, untranslated and header
  entries left out); the number of entries read. Header fields go to
  Header (name: value lines) when it is given }
function ParsePo(const Text: String; const Dict: TTranslationDictionary; const Header: TStrings = nil): Integer;
{ Use the translations of a .po text as language Code ('' text: English);
  SetLanguage reads the file and calls it }
procedure UseTranslation(const Code, PoText: String);
{ How many texts the current language translates }
function TranslatedCount: Integer;

implementation

uses
  {$ifdef MSWINDOWS} Windows, {$endif}
  CastleDownload, CastleConfig, CastleLog, CastleUIControls, CastleControls, CastleUriUtils;

var
  Dict: TTranslationDictionary;
  Current: String = 'en';
  LanguageList: TLanguageInfoArray;
  ListLoaded: Boolean;

type
  { The English text of a label and what it showed after the last translation }
  TLabelOriginal = record
    English, Shown: String;
  end;
  TLabelOriginals = specialize TDictionary<TComponent, TLabelOriginal>;

var
  Originals: TLabelOriginals;

function ReadText(const Url: String; out Text: String): Boolean;
var
  Stream: TStream;
  S: TStringStream;
begin
  Text := '';
  Result := False;
  { No exceptions on the web: check first }
  if UriExists(Url) <> ueFile then
    Exit;
  try
    Stream := Download(Url);
    try
      S := TStringStream.Create('');
      try
        S.CopyFrom(Stream, 0);
        Text := S.DataString;
        Result := True;
      finally
        S.Free;
      end;
    finally
      Stream.Free;
    end;
  except
    on E: Exception do
      Result := False;
  end;
end;

function Unescape(const S: String): String;
var
  I: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if (S[I] = '\') and (I < Length(S)) then
    begin
      Inc(I);
      case S[I] of
        'n': Result := Result + #10;
        't': Result := Result + #9;
        else Result := Result + S[I];
      end;
    end else
      Result := Result + S[I];
    Inc(I);
  end;
end;

{ The text between the first and the last double quote of a line }
function QuotedPart(const Line: String; out Value: String): Boolean;
var
  A, B: Integer;
begin
  A := Pos('"', Line);
  B := Length(Line);
  while (B > A) and (Line[B] <> '"') do
    Dec(B);
  Result := (A > 0) and (B > A);
  if Result then
    Value := Unescape(Copy(Line, A + 1, B - A - 1))
  else
    Value := '';
end;

function ParsePo(const Text: String; const Dict: TTranslationDictionary; const Header: TStrings): Integer;
var
  Lines: TStringList;
  Line, Value, Id, Str: String;
  I: Integer;
  State: (psNone, psId, psStr);

  procedure Flush;
  var
    H: String;
  begin
    if State = psStr then
    begin
      if Id = '' then
      begin
        if Header <> nil then
          for H in Str.Split([#10], TStringSplitOptions.ExcludeEmpty) do
            Header.Add(StringReplace(H, ': ', '=', []));
      end else
      if Str <> '' then
      begin
        Dict.AddOrSetValue(Id, Str);
        Inc(Result);
      end;
    end;
    State := psNone;
    Id := '';
    Str := '';
  end;

begin
  Result := 0;
  State := psNone;
  Id := '';
  Str := '';
  Lines := TStringList.Create;
  try
    Lines.Text := Text;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[I]);
      if (Line = '') or (Line[1] = '#') then
        Continue;
      if Copy(Line, 1, 6) = 'msgid ' then
      begin
        Flush;
        State := psId;
        QuotedPart(Line, Id);
      end else
      if Copy(Line, 1, 7) = 'msgstr ' then
      begin
        State := psStr;
        QuotedPart(Line, Str);
      end else
      if (Line[1] = '"') and QuotedPart(Line, Value) then
      begin
        if State = psId then
          Id := Id + Value
        else if State = psStr then
          Str := Str + Value;
      end;
    end;
    Flush;
  finally
    Lines.Free;
  end;
end;

function Tr(const S: String): String;
begin
  if (Dict = nil) or (S = '') or not Dict.TryGetValue(S, Result) then
    Result := S;
end;

function TrItem(const S: String): String;
var
  P: Integer;
  Head, Tail: String;
begin
  if (Dict = nil) or (Dict.Count = 0) then
    Exit(S);
  if Dict.TryGetValue(S, Result) then
    Exit;
  if (Length(S) > 2) and (S[1] = '[') and (S[Length(S)] = ']') then
    Exit('[' + TrItem(Copy(S, 2, Length(S) - 2)) + ']');
  P := Pos(': ', S);
  if P = 0 then
    Exit(S);
  Head := Copy(S, 1, P - 1);
  Tail := Copy(S, P + 2, MaxInt);
  Result := Tr(Head) + ': ' + TrItem(Tail);
end;

function TranslateLines(const English: String): String;
var
  Lines: TStringList;
  I: Integer;
begin
  Lines := TStringList.Create;
  try
    Lines.Text := English;
    for I := 0 to Lines.Count - 1 do
      Lines[I] := Tr(Lines[I]);
    Result := TrimRight(Lines.Text);
  finally
    Lines.Free;
  end;
end;

procedure TranslateDesign(const Root: TComponent);
var
  I: Integer;
  C: TComponent;
  O: TLabelOriginal;
  Now: String;
begin
  if Root = nil then
    Exit;
  if Originals = nil then
    Originals := TLabelOriginals.Create;
  for I := 0 to Root.ComponentCount - 1 do
  begin
    C := Root.Components[I];
    if C is TCastleLabel then
      Now := TrimRight(TCastleLabel(C).Text.Text)
    else
    if C is TCastleButton then
      Now := TCastleButton(C).Caption
    else
      Continue;
    { A label the code changed since (or a new one) starts from what it shows }
    if not Originals.TryGetValue(C, O) or (O.Shown <> Now) then
      O.English := Now;
    if C is TCastleLabel then
    begin
      TCastleLabel(C).Text.Text := TranslateLines(O.English);
      O.Shown := TrimRight(TCastleLabel(C).Text.Text);
    end else
    begin
      TCastleButton(C).Caption := Tr(O.English);
      O.Shown := TCastleButton(C).Caption;
    end;
    Originals.AddOrSetValue(C, O);
  end;
end;

procedure LoadList;
var
  Text, Line, Code: String;
  P: Integer;
begin
  if ListLoaded then
    Exit;
  ListLoaded := True;
  SetLength(LanguageList, 1);
  LanguageList[0].Code := 'en';
  LanguageList[0].Name := 'English';
  if not ReadText('castle-data:/lang/languages.txt', Text) then
    Exit;
  for Line in Text.Split([#10, #13], TStringSplitOptions.ExcludeEmpty) do
  begin
    if (Trim(Line) = '') or (Trim(Line)[1] = '#') then
      Continue;
    P := Pos(' ', Trim(Line));
    if P = 0 then
      Continue;
    Code := LowerCase(Copy(Trim(Line), 1, P - 1));
    if Code = 'en' then
      Continue;
    SetLength(LanguageList, Length(LanguageList) + 1);
    LanguageList[High(LanguageList)].Code := Code;
    LanguageList[High(LanguageList)].Name := Trim(Copy(Trim(Line), P + 1, MaxInt));
  end;
end;

function Languages: TLanguageInfoArray;
begin
  LoadList;
  Result := LanguageList;
end;

function LanguageName(const Code: String): String;
var
  L: TLanguageInfo;
begin
  for L in Languages do
    if L.Code = Code then
      Exit(L.Name);
  Result := Code;
end;

function HasLanguage(const Code: String): Boolean;
var
  L: TLanguageInfo;
begin
  for L in Languages do
    if L.Code = Code then
      Exit(True);
  Result := False;
end;

function CurrentLanguage: String;
begin
  Result := Current;
end;

function CurrentLanguageName: String;
begin
  Result := LanguageName(Current);
end;

function SystemLanguage: String;
{$ifdef MSWINDOWS}
const
  { Primary language ids of the translations }
  Codes: array[0..4] of record Id: Word; Code: String; end = (
    (Id: $09; Code: 'en'), (Id: $07; Code: 'de'), (Id: $0C; Code: 'fr'), (Id: $0A; Code: 'es'), (Id: $10; Code: 'it'));
var
  I: Integer;
  Id: Word;
begin
  Result := '';
  Id := GetUserDefaultLangID and $3FF;
  for I := Low(Codes) to High(Codes) do
    if Codes[I].Id = Id then
      Exit(Codes[I].Code);
end;
{$else}
var
  V: String;
  Name: String;
begin
  Result := '';
  {$ifndef WASI}
  for Name in ['LC_ALL', 'LC_MESSAGES', 'LANG', 'LANGUAGE'] do
  begin
    V := GetEnvironmentVariable(Name);
    if (Length(V) >= 2) and (V <> 'C') and (Copy(V, 1, 5) <> 'POSIX') then
      Exit(LowerCase(Copy(V, 1, 2)));
  end;
  {$endif}
end;
{$endif}

function TranslatedCount: Integer;
begin
  if Dict = nil then
    Result := 0
  else
    Result := Dict.Count;
end;

procedure UseTranslation(const Code, PoText: String);
begin
  if Dict = nil then
    Dict := TTranslationDictionary.Create
  else
    Dict.Clear;
  Current := Code;
  if PoText <> '' then
    ParsePo(PoText, Dict);
  Inc(LanguageVersion);
end;

procedure SetLanguage(const Code: String);
var
  Want, Text: String;
begin
  LanguageSetting := LowerCase(Trim(Code));
  Want := LanguageSetting;
  if Want = '' then
    Want := SystemLanguage;
  if not HasLanguage(Want) then
    Want := 'en';
  Text := '';
  if Want <> 'en' then
    ReadText('castle-data:/lang/' + Want + '.po', Text);
  UseTranslation(Want, Text);
  if LanguageSetting = '' then
    WritelnLog('GameTranslate', 'Language: %s (%s), %d texts (the system''s: "%s")',
      [Current, CurrentLanguageName, Dict.Count, SystemLanguage])
  else
    WritelnLog('GameTranslate', 'Language: %s (%s), %d texts', [Current, CurrentLanguageName, Dict.Count]);
end;

function NextLanguageSetting(const Current: String): String;
var
  L: TLanguageInfoArray;
  I: Integer;
begin
  L := Languages;
  if Current = '' then
    Exit(L[0].Code);
  for I := 0 to High(L) do
    if L[I].Code = Current then
    begin
      if I = High(L) then
        Exit('')
      else
        Exit(L[I + 1].Code);
    end;
  Result := '';
end;

procedure LoadLanguageSettings;
begin
  SetLanguage(UserConfig.GetValue('ui/language', ''));
end;

procedure SaveLanguageSettings;
begin
  if LanguageVolatile then
    Exit;
  UserConfig.SetDeleteValue('ui/language', LanguageSetting, '');
  UserConfig.Save;
end;

finalization
  FreeAndNil(Dict);
  FreeAndNil(Originals);
end.
