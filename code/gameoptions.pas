{ The command line options as one table: each option has its names, the
  variable it sets (a flag, a text, a whole number or a number) or a
  handler for the ones with their own rules, and whether the web page
  takes it as a ?name=value parameter too. GameInitialize fills the table
  (RegisterOptions) and parses the command line and the page's address
  with it. }
unit GameOptions;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  { A handler gets the parameters after the option and returns how many of
    them it used, or -1 when it needs more than there are (the option is
    then ignored). On the web page it gets the one value of ?name=value. }
  TOptionHandler = function(const Args: TStringArray): Integer;
  { The value of a parameter of the web page's address ('' without one) }
  TPageParameterGetter = function(const Name: String): String;

{ Names: the option's names without dashes, separated by spaces
  ("warp map" answers to -warp, --warp, -map and --map). Web: the page
  takes ?<first name>=<value> too (=1 for a flag). }
procedure AddFlagOption(const Names: String; var Target: Boolean; const Web: Boolean = False);
procedure AddTextOption(const Names: String; var Target: String; const Web: Boolean = False);
{ A value that is not a number gives Default; the result is kept in Min..Max }
procedure AddIntegerOption(const Names: String; var Target: Integer; const Default, Min, Max: Integer;
  const Web: Boolean = False);
procedure AddNumberOption(const Names: String; var Target: Single; const Web: Boolean = False);
procedure AddCustomOption(const Names: String; const Handler: TOptionHandler; const Web: Boolean = False);

{ Apply the options in Args (the parameters without the program's name);
  returns how many options it knew. Unknown parameters are skipped. }
function ParseOptions(const Args: TStringArray): Integer;
{ Apply the web page's parameters to the options that take them; returns
  how many were given }
function ParseWebOptions(const Getter: TPageParameterGetter): Integer;
{ Every name of the table (tests, documentation) }
function OptionNames: TStringArray;
procedure ClearOptions;

implementation

type
  TOptionKind = (okFlag, okText, okInteger, okNumber, okCustom);

  TOption = record
    Names: TStringArray;
    Kind: TOptionKind;
    Target: Pointer;
    Default, Min, Max: Integer;
    Handler: TOptionHandler;
    Web: Boolean;
  end;

var
  Options: array of TOption;

function NewOption(const Names: String; const Kind: TOptionKind; const Target: Pointer; const Web: Boolean): Integer;
begin
  SetLength(Options, Length(Options) + 1);
  Result := High(Options);
  Options[Result].Names := Names.Split([' '], TStringSplitOptions.ExcludeEmpty);
  Options[Result].Kind := Kind;
  Options[Result].Target := Target;
  Options[Result].Handler := nil;
  Options[Result].Web := Web;
end;

procedure AddFlagOption(const Names: String; var Target: Boolean; const Web: Boolean);
begin
  NewOption(Names, okFlag, @Target, Web);
end;

procedure AddTextOption(const Names: String; var Target: String; const Web: Boolean);
begin
  NewOption(Names, okText, @Target, Web);
end;

procedure AddIntegerOption(const Names: String; var Target: Integer; const Default, Min, Max: Integer;
  const Web: Boolean);
var
  I: Integer;
begin
  I := NewOption(Names, okInteger, @Target, Web);
  Options[I].Default := Default;
  Options[I].Min := Min;
  Options[I].Max := Max;
end;

procedure AddNumberOption(const Names: String; var Target: Single; const Web: Boolean);
begin
  NewOption(Names, okNumber, @Target, Web);
end;

procedure AddCustomOption(const Names: String; const Handler: TOptionHandler; const Web: Boolean);
var
  I: Integer;
begin
  I := NewOption(Names, okCustom, nil, Web);
  Options[I].Handler := Handler;
end;

procedure ClearOptions;
begin
  SetLength(Options, 0);
end;

{ Apply option O with the parameters after it; how many it used, -1 when
  it needs one that is not there }
function ApplyOption(const O: TOption; const Rest: TStringArray): Integer;
var
  N: Integer;
  Dot: TFormatSettings;
begin
  if O.Kind = okFlag then
  begin
    PBoolean(O.Target)^ := True;
    Exit(0);
  end;
  if O.Kind = okCustom then
    Exit(O.Handler(Rest));
  if Length(Rest) = 0 then
    Exit(-1);
  case O.Kind of
    okText:
      PString(O.Target)^ := Rest[0];
    okInteger:
      begin
        N := StrToIntDef(Rest[0], O.Default);
        if N < O.Min then
          N := O.Min;
        if N > O.Max then
          N := O.Max;
        PInteger(O.Target)^ := N;
      end;
    okNumber:
      begin
        Dot := DefaultFormatSettings;
        Dot.DecimalSeparator := '.';
        PSingle(O.Target)^ := StrToFloatDef(Rest[0], 0, Dot);
      end;
  end;
  Result := 1;
end;

function FindOption(const Param: String): Integer;
var
  I: Integer;
  Bare, OptName: String;
begin
  Result := -1;
  if Copy(Param, 1, 2) = '--' then
    Bare := Copy(Param, 3, MaxInt)
  else if Copy(Param, 1, 1) = '-' then
    Bare := Copy(Param, 2, MaxInt)
  else
    Exit;
  for I := 0 to High(Options) do
    for OptName in Options[I].Names do
      if OptName = Bare then
        Exit(I);
end;

function ParseOptions(const Args: TStringArray): Integer;
var
  I, Found, Used: Integer;
begin
  Result := 0;
  I := 0;
  while I <= High(Args) do
  begin
    Found := FindOption(Args[I]);
    if Found >= 0 then
    begin
      Used := ApplyOption(Options[Found], Copy(Args, I + 1, Length(Args)));
      if Used >= 0 then
      begin
        Inc(Result);
        Inc(I, Used);
      end;
    end;
    Inc(I);
  end;
end;

function ParseWebOptions(const Getter: TPageParameterGetter): Integer;
var
  I: Integer;
  Value: String;
  One: TStringArray;
begin
  Result := 0;
  for I := 0 to High(Options) do
    if Options[I].Web and (Length(Options[I].Names) > 0) then
    begin
      Value := Getter(Options[I].Names[0]);
      if Value = '' then
        Continue;
      { A flag is ?name=1 }
      if (Options[I].Kind = okFlag) and (Value <> '1') then
        Continue;
      SetLength(One, 1);
      One[0] := Value;
      ApplyOption(Options[I], One);
      Inc(Result);
    end;
end;

function OptionNames: TStringArray;
var
  I: Integer;
  OptName: String;
begin
  SetLength(Result, 0);
  for I := 0 to High(Options) do
    for OptName in Options[I].Names do
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := OptName;
    end;
end;

end.
