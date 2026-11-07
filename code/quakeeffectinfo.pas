{ DarkPlaces' effectinfo.txt: named particle effects for QuakeC's
  particleeffectnum / pointparticles / trailparticles (DP_SV_POINTPARTICLES,
  which QuakeSpasm-Spiked and FTE read too). An effect is one or more
  "effect <name>" sections, each a kind of particle with its count, color,
  size, alpha, life, motion and texture. Vectors stay in Quake coordinates. }
unit QuakeEffectInfo;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, CastleVectors;

type
  { DP's particle types; the ones not drawn (decals, beams...) are eptNone }
  TEffectParticleType = (eptAlphaStatic, eptStatic, eptSpark, eptSmoke, eptBlood, eptBubble,
    eptSnow, eptRain, eptNone);

  TEffectSection = record
    Name: String;
    Num: Integer;               { the effect number of Name (1..) }
    PType: TEffectParticleType;
    Count: Single;              { times the count argument }
    CountAbsolute: Single;      { whatever the count argument }
    TrailSpacing: Single;       { trails: a particle every N units }
    Color1, Color2: TVector3;   { 0..1, each particle somewhere between }
    SizeMin, SizeMax, SizeIncrease: Single;
    AlphaMin, AlphaMax, AlphaFade: Single;   { 0..1 and per second }
    TimeMin, TimeMax: Single;   { life in seconds }
    Gravity: Single;            { times sv_gravity }
    AirFriction, LiquidFriction: Single;
    Bounce: Single;
    OriginOffset, OriginJitter: TVector3;
    VelocityOffset, VelocityJitter: TVector3;
    VelocityMultiplier: Single;
    TexMin, TexMax: Integer;    { particlefont cells, one picked at random }
    Underwater, NotUnderwater: Boolean;
    LightRadius: Single;
  end;
  PEffectSection = ^TEffectSection;

  TEffectInfo = class
  private
    FSections: array of TEffectSection;
    FNames: TStringList;        { effect Num - 1 -> name }
    FBySection: array of array of Integer;
    function NewSection(const AName: String): PEffectSection;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    { DP's ParseEffectInfo; returns the number of sections }
    function LoadFromText(const Text: String): Integer;
    function EffectCount: Integer;
    { 0 for a name effectinfo.txt does not have }
    function EffectNum(const AName: String): Integer;
    function EffectName(const Num: Integer): String;
    { The sections of effect Num }
    function SectionCount(const Num: Integer): Integer;
    function Section(const Num, I: Integer): PEffectSection;
    function TotalSections: Integer;
  end;

  { particlefont.txt: cell N's texture rectangle (s1 t1 s2 t2, t from the
    top), DP's default 8 x 8 grid for the cells it does not list }
  TParticleFont = class
  private
    FRects: array[0..255] of TVector4;
  public
    constructor Create;
    procedure LoadFromText(const Text: String);
    function Rect(const Cell: Integer): TVector4;
  end;

{ 0xRRGGBB (or a decimal number) as 0..1 RGB }
function ParseEffectColor(const S: String): TVector3;

implementation

function ParseEffectColor(const S: String): TVector3;
var
  V: LongInt;
  T: String;
begin
  T := Trim(S);
  if (Length(T) > 2) and (T[1] = '0') and (T[2] in ['x', 'X']) then
    V := StrToIntDef('$' + Copy(T, 3, MaxInt), $FFFFFF)
  else
    V := StrToIntDef(T, $FFFFFF);
  Result := Vector3(((V shr 16) and 255) / 255, ((V shr 8) and 255) / 255, (V and 255) / 255);
end;

function ParseFloat(const S: String; const Default: Single): Single;
var
  Fmt: TFormatSettings;
begin
  Fmt := DefaultFormatSettings;
  Fmt.DecimalSeparator := '.';
  Result := StrToFloatDef(Trim(S), Default, Fmt);
end;

constructor TEffectInfo.Create;
begin
  inherited Create;
  FNames := TStringList.Create;
  FNames.CaseSensitive := False;
end;

destructor TEffectInfo.Destroy;
begin
  FNames.Free;
  inherited Destroy;
end;

procedure TEffectInfo.Clear;
begin
  FSections := nil;
  FBySection := nil;
  FNames.Clear;
end;

function TEffectInfo.NewSection(const AName: String): PEffectSection;
var
  Num: Integer;
begin
  Num := FNames.IndexOf(AName) + 1;
  if Num = 0 then
  begin
    FNames.Add(AName);
    Num := FNames.Count;
    SetLength(FBySection, Num);
  end;
  SetLength(FSections, Length(FSections) + 1);
  Result := @FSections[High(FSections)];
  Result^ := Default(TEffectSection);
  { DP's defaults }
  Result^.Name := AName;
  Result^.Num := Num;
  Result^.PType := eptAlphaStatic;
  Result^.Color1 := Vector3(1, 1, 1);
  Result^.Color2 := Vector3(1, 1, 1);
  Result^.SizeMin := 1;
  Result^.SizeMax := 1;
  Result^.AlphaMin := 0;
  Result^.AlphaMax := 1;
  Result^.AlphaFade := 1;
  Result^.TimeMin := 16;
  Result^.TimeMax := 16;
  Result^.TexMin := 0;
  Result^.TexMax := 0;
end;

function TEffectInfo.LoadFromText(const Text: String): Integer;
var
  Lines: TStringList;
  Line: String;
  W: TStringArray;
  I, P: Integer;
  Sec: PEffectSection;
  Kept: array of TEffectSection;

  function Arg(const N: Integer; const Default: Single): Single;
  begin
    if N <= High(W) then
      Result := ParseFloat(W[N], Default)
    else
      Result := Default;
  end;

  function Vec(const Default: Single): TVector3;
  begin
    Result := Vector3(Arg(1, Default), Arg(2, Default), Arg(3, Default));
  end;

begin
  Clear;
  Lines := TStringList.Create;
  try
    Lines.Text := Text;
    Sec := nil;
    for Line in Lines do
    begin
      P := Pos('//', Line);
      if P > 0 then
        W := Copy(Line, 1, P - 1).Split([' ', #9], TStringSplitOptions.ExcludeEmpty)
      else
        W := Line.Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
      if Length(W) = 0 then
        Continue;
      W[0] := LowerCase(W[0]);
      if W[0] = 'effect' then
      begin
        if Length(W) > 1 then
          Sec := NewSection(W[1])
        else
          Sec := nil;
        Continue;
      end;
      if Sec = nil then
        Continue;
      if W[0] = 'count' then
        Sec^.Count := Arg(1, 0)
      else if W[0] = 'countabsolute' then
        Sec^.CountAbsolute := Arg(1, 0)
      else if W[0] = 'trailspacing' then
        Sec^.TrailSpacing := Arg(1, 0)
      else if W[0] = 'type' then
      begin
        if Length(W) < 2 then
          Continue;
        case LowerCase(W[1]) of
          'alphastatic': Sec^.PType := eptAlphaStatic;
          'static': Sec^.PType := eptStatic;
          'spark': Sec^.PType := eptSpark;
          'smoke': Sec^.PType := eptSmoke;
          'blood': Sec^.PType := eptBlood;
          'bubble': Sec^.PType := eptBubble;
          'snow': Sec^.PType := eptSnow;
          'rain': Sec^.PType := eptRain;
          else Sec^.PType := eptNone;   { decal, beam, entityparticle, raindecal }
        end;
      end
      else if W[0] = 'color' then
      begin
        if Length(W) > 1 then
          Sec^.Color1 := ParseEffectColor(W[1]);
        if Length(W) > 2 then
          Sec^.Color2 := ParseEffectColor(W[2])
        else
          Sec^.Color2 := Sec^.Color1;
      end
      else if W[0] = 'size' then
      begin
        Sec^.SizeMin := Arg(1, 1);
        Sec^.SizeMax := Arg(2, Sec^.SizeMin);
      end
      else if W[0] = 'sizeincrease' then
        Sec^.SizeIncrease := Arg(1, 0)
      else if W[0] = 'alpha' then
      begin
        Sec^.AlphaMin := Arg(1, 0) / 256;
        Sec^.AlphaMax := Arg(2, Arg(1, 0)) / 256;
        Sec^.AlphaFade := Arg(3, 0) / 256;
      end
      else if W[0] = 'time' then
      begin
        Sec^.TimeMin := Arg(1, 16);
        Sec^.TimeMax := Arg(2, Sec^.TimeMin);
      end
      else if W[0] = 'gravity' then
        Sec^.Gravity := Arg(1, 0)
      else if W[0] = 'airfriction' then
        Sec^.AirFriction := Arg(1, 0)
      else if W[0] = 'liquidfriction' then
        Sec^.LiquidFriction := Arg(1, 0)
      else if W[0] = 'bounce' then
        Sec^.Bounce := Arg(1, 0)
      else if W[0] = 'originoffset' then
        Sec^.OriginOffset := Vec(0)
      else if W[0] = 'originjitter' then
        Sec^.OriginJitter := Vec(0)
      else if W[0] = 'velocityoffset' then
        Sec^.VelocityOffset := Vec(0)
      else if W[0] = 'velocityjitter' then
        Sec^.VelocityJitter := Vec(0)
      else if W[0] = 'velocitymultiplier' then
        Sec^.VelocityMultiplier := Arg(1, 0)
      else if W[0] = 'tex' then
      begin
        Sec^.TexMin := EnsureRange(Round(Arg(1, 0)), 0, 255);
        Sec^.TexMax := EnsureRange(Round(Arg(2, Sec^.TexMin)), Sec^.TexMin, 256);
      end
      else if W[0] = 'underwater' then
        Sec^.Underwater := True
      else if W[0] = 'notunderwater' then
        Sec^.NotUnderwater := True
      else if W[0] = 'lightradius' then
        Sec^.LightRadius := Arg(1, 0);
    end;
  finally
    Lines.Free;
  end;
  { Index the sections of each effect; the ones without a drawn particle
    stay out }
  Kept := nil;
  for I := 0 to High(FSections) do
    if FSections[I].PType <> eptNone then
    begin
      SetLength(Kept, Length(Kept) + 1);
      Kept[High(Kept)] := FSections[I];
    end;
  FSections := Kept;
  SetLength(FBySection, FNames.Count);
  for I := 0 to High(FSections) do
  begin
    P := FSections[I].Num - 1;
    SetLength(FBySection[P], Length(FBySection[P]) + 1);
    FBySection[P][High(FBySection[P])] := I;
  end;
  Result := Length(FSections);
end;

function TEffectInfo.EffectCount: Integer;
begin
  Result := FNames.Count;
end;

function TEffectInfo.EffectNum(const AName: String): Integer;
begin
  Result := FNames.IndexOf(AName) + 1;
end;

function TEffectInfo.EffectName(const Num: Integer): String;
begin
  if (Num >= 1) and (Num <= FNames.Count) then
    Result := FNames[Num - 1]
  else
    Result := '';
end;

function TEffectInfo.SectionCount(const Num: Integer): Integer;
begin
  if (Num >= 1) and (Num <= Length(FBySection)) then
    Result := Length(FBySection[Num - 1])
  else
    Result := 0;
end;

function TEffectInfo.Section(const Num, I: Integer): PEffectSection;
begin
  Result := @FSections[FBySection[Num - 1][I]];
end;

function TEffectInfo.TotalSections: Integer;
begin
  Result := Length(FSections);
end;

{ TParticleFont }

constructor TParticleFont.Create;
var
  I: Integer;
begin
  inherited Create;
  for I := 0 to 255 do
    FRects[I] := Vector4((I mod 8) / 8, (I div 8 mod 8) / 8, (I mod 8 + 1) / 8, (I div 8 mod 8 + 1) / 8);
end;

procedure TParticleFont.LoadFromText(const Text: String);
var
  Lines: TStringList;
  Line: String;
  W: TStringArray;
  N: Integer;
begin
  Lines := TStringList.Create;
  try
    Lines.Text := Text;
    for Line in Lines do
    begin
      W := Line.Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
      if (Length(W) < 5) or (Copy(W[0], 1, 2) = '//') then
        Continue;
      N := StrToIntDef(W[0], -1);
      if (N < 0) or (N > 255) then
        Continue;
      FRects[N] := Vector4(ParseFloat(W[1], 0), ParseFloat(W[2], 0), ParseFloat(W[3], 1), ParseFloat(W[4], 1));
    end;
  finally
    Lines.Free;
  end;
end;

function TParticleFont.Rect(const Cell: Integer): TVector4;
begin
  Result := FRects[EnsureRange(Cell, 0, 255)];
end;

end.
