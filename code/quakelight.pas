{ Quake 1 lighting: lightstyles, dynamic lights, and muzzle flashes using Castle Game Engine. }
unit QuakeLight;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections,
  CastleVectors, CastleScene, CastleTransform, CastleColors, CastleLog,
  QuakeBsp;

type
  { Dynamic light instance created from a Quake map light entity }
  TQuakeDynamicLight = class
  public
    LightNode: TCastlePointLight;
    BaseIntensity: Single;
    StyleIndex: Integer;
    Origin: TVector3;
    Color: TVector3;
    Radius: Single;
  end;

  TQuakeDynamicLightList = specialize TObjectList<TQuakeDynamicLight>;

  { A short lived light added to the lightmaps (dlight_t) }
  TQuakeDLight = record
    Position: TVector3; { CGE coordinates }
    Radius, Decay, TimeLeft: Single;
  end;

const
  MaxDLights = 4;

type

  { Lighting manager for Quake maps in Castle Game Engine }
  TQuakeLighting = class
  private
    FLights: TQuakeDynamicLightList;
    FStylePatterns: array[0..63] of String;
    FStyleFrames: array[0..63] of Integer;
    FStyleTimer: Single;
    FMuzzleLight: TCastlePointLight;
    FMuzzleTimer: Single;
    FAmbientSun: TCastleDirectionalLight;
    FShadowsEnabled: Boolean;
    FLightMode: (lmDynamicOnly, lmClassicAmbient, lmFullPBR);
    FDLights: array[0..MaxDLights - 1] of TQuakeDLight;
    FDLightNext: Integer;
  public
    constructor Create;
    destructor Destroy; override;

    { Build dynamic point lights from BSP map entities }
    procedure CreateLightsFromBsp(const Bsp: TQuakeBsp; const Parent: TCastleTransform);

    { Update light animation styles and timers. SecondsPassed since last frame. }
    procedure Update(const SecondsPassed: Single; const PlayerPos: TVector3);

    { Trigger a muzzle flash dynamic light at the given position }
    procedure TriggerMuzzleFlash(const Position: TVector3; const Intensity: Single = 3.0);

    { CL_AllocDlight: a light that fades out, added to the lightmaps by the
      world shader (muzzle flashes, explosions) }
    procedure AddDLight(const Position: TVector3; const Radius, Duration, Decay: Single);
    { Position and radius of dlight slot I for the shader; radius 0 when off }
    function DLightUniform(const I: Integer): TVector4;

    { Toggle real-time shadow mapping for all dynamic lights }
    procedure SetShadows(const Enabled: Boolean);

    { Get current intensity multiplier for a lightstyle (0.0 .. 2.0) }
    function GetStyleMultiplier(const Style: Integer): Single;
    { Replace a lightstyle pattern (svc_lightstyle); '' restores the default }
    procedure SetStyle(const Style: Integer; const Pattern: String);
    { The standard patterns again (after a demo changed them) }
    procedure ResetStyles;

    { Clear all dynamic lights }
    procedure Clear;
    function GetLightCount: Integer; inline;

    property Lights: TQuakeDynamicLightList read FLights;
    property ShadowsEnabled: Boolean read FShadowsEnabled write SetShadows;
    property LightCount: Integer read GetLightCount;
  end;

{ Convert Quake world coordinates to CGE world coordinates }
function QuakeToCge(const V: TVector3): TVector3; inline;
function CgeToQuake(const V: TVector3): TVector3; inline;

var
  Lighting: TQuakeLighting;

implementation

function QuakeToCge(const V: TVector3): TVector3;
begin
  Result := Vector3(V.X, V.Z, -V.Y);
end;

function CgeToQuake(const V: TVector3): TVector3;
begin
  Result := Vector3(V.X, -V.Z, V.Y);
end;

constructor TQuakeLighting.Create;
begin
  inherited Create;
  FLights := TQuakeDynamicLightList.Create(True);
  FShadowsEnabled := False;
  FLightMode := lmFullPBR;
  FStyleTimer := 0;
  FMuzzleTimer := 0;

  { Standard Quake lightstyle animation patterns }
  FStylePatterns[0]  := 'm';                                            { 0: normal }
  FStylePatterns[1]  := 'mmnmmommommnonmmonqnmmo';                      { 1: flicker }
  FStylePatterns[2]  := 'abcdefghijklmnopqrstuvwxyzyxwvutsrqponmlkjihgfedcba'; { 2: slow pulse }
  FStylePatterns[3]  := 'mmmmmaaaaammmmmaaaaaabcdefgabcdefg';          { 3: candle }
  FStylePatterns[4]  := 'mamamamamama';                                { 4: fast strobe }
  FStylePatterns[5]  := 'jklmnopqrstuvwxyzyxwvutsrqponmlkj';            { 5: gentle pulse }
  FStylePatterns[6]  := 'nmonqnmomnmomomno';                            { 6: flicker 2 }
  FStylePatterns[7]  := 'mmmaaaabcdefgmmmmaaaammmaamm';                 { 7: candle 2 }
  FStylePatterns[8]  := 'mmmaaammmaaammmabcdefaaaammmmabcdefmmmaaaa';   { 8: candle 3 }
  FStylePatterns[9]  := 'aaaaacdefgabcdefg';                            { 9: slow strobe }
  FStylePatterns[10] := 'mmamammmmammamamaaamamm';                      { 10: fluorescent flicker }
  FStylePatterns[11] := 'abcdefghijklmnopqrsrqponmlkjihgfedcba';        { 11: slow pulse no black }
  FStylePatterns[12] := 'a';                                            { 12: off }
  FillChar(FStyleFrames, SizeOf(FStyleFrames), 0);
end;

destructor TQuakeLighting.Destroy;
begin
  Clear;
  FLights.Free;
  inherited Destroy;
end;

procedure TQuakeLighting.Clear;
begin
  FLights.Clear;
  FMuzzleLight := nil;
  if FAmbientSun <> nil then
  begin
    if FAmbientSun.Parent <> nil then
      FAmbientSun.Parent.Remove(FAmbientSun);
    FreeAndNil(FAmbientSun);
  end;
end;

function TQuakeLighting.GetLightCount: Integer;
begin
  Result := FLights.Count;
end;

function TQuakeLighting.GetStyleMultiplier(const Style: Integer): Single;
var
  Pat: String;
  Frame: Integer;
  Ch: Char;
begin
  Result := 1.0;
  if (Style < 0) or (Style > High(FStylePatterns)) then
    Exit;

  Pat := FStylePatterns[Style];
  if Length(Pat) = 0 then
    Exit;

  Frame := FStyleFrames[Style] mod Length(Pat);
  Ch := Pat[Frame + 1];
  { 'a' is 0.0, 'm' is 1.0, 'z' is 2.0 }
  Result := (Ord(Ch) - Ord('a')) / (Ord('m') - Ord('a'));
end;

procedure TQuakeLighting.SetStyle(const Style: Integer; const Pattern: String);
begin
  if (Style < 0) or (Style > High(FStylePatterns)) then
    Exit;
  if Pattern = '' then
    FStylePatterns[Style] := 'm'
  else
    FStylePatterns[Style] := Pattern;
  FStyleFrames[Style] := 0;
end;

procedure TQuakeLighting.ResetStyles;
const
  Standard: array[0..12] of String = ('m', 'mmnmmommommnonmmonqnmmo',
    'abcdefghijklmnopqrstuvwxyzyxwvutsrqponmlkjihgfedcba', 'mmmmmaaaaammmmmaaaaaabcdefgabcdefg',
    'mamamamamama', 'jklmnopqrstuvwxyzyxwvutsrqponmlkj', 'nmonqnmomnmomomno',
    'mmmaaaabcdefgmmmmaaaammmaamm', 'mmmaaammmaaammmabcdefaaaammmmabcdefmmmaaaa',
    'aaaaacdefgabcdefg', 'mmamammmmammamamaaamamm', 'abcdefghijklmnopqrsrqponmlkjihgfedcba', 'a');
var
  I: Integer;
begin
  for I := 0 to High(FStylePatterns) do
    if I <= High(Standard) then
      FStylePatterns[I] := Standard[I]
    else
      FStylePatterns[I] := '';
  FillChar(FStyleFrames, SizeOf(FStyleFrames), 0);
end;

procedure TQuakeLighting.CreateLightsFromBsp(const Bsp: TQuakeBsp; const Parent: TCastleTransform);
var
  Ent: TQuakeEntity;
  CName: String;
  DynLight: TQuakeDynamicLight;
  PtLight: TCastlePointLight;
  LightVal, RadiusVal: Single;
  Origin: TVector3;
  Style: Integer;
  LightCol: TVector3;
  I: Integer;
begin
  Clear;
  if (Bsp = nil) or (Parent = nil) then
    Exit;

  { Ambient directional sun light illuminating the map }
  FAmbientSun := TCastleDirectionalLight.Create(Parent);
  FAmbientSun.Direction := Vector3(-0.35, -1.0, -0.25);
  FAmbientSun.Color := Vector3(0.85, 0.85, 0.9);
  FAmbientSun.Intensity := 0.25;
  FAmbientSun.CastShadows := False;
  Parent.Add(FAmbientSun);

  { Muzzle flash light attached to scene }
  FMuzzleLight := TCastlePointLight.Create(Parent);
  FMuzzleLight.Color := Vector3(1.0, 0.8, 0.3);
  FMuzzleLight.Intensity := 0.0;
  FMuzzleLight.Radius := 400.0;
  FMuzzleLight.CastShadows := False;
  Parent.Add(FMuzzleLight);

  for I := 0 to Bsp.Entities.Count - 1 do
  begin
    Ent := Bsp.Entities[I];
    CName := LowerCase(Ent.ClassName);

    if (CName = 'light') or (CName = 'light_fluorospark') or
       (CName = 'light_fluoro') or (CName = 'light_globe') or
       (CName = 'light_torch_small_walltorch') or (CName = 'light_flame_large_yellow') then
    begin
      LightVal := Ent.Light;
      if LightVal <= 0 then
        LightVal := 200;

      RadiusVal := LightVal * 1.8;
      Origin := Ent.Origin;
      Style := Ent.GetInt('style', 0);

      { Color tone based on light entity type }
      if (CName = 'light_torch_small_walltorch') or (CName = 'light_flame_large_yellow') then
        LightCol := Vector3(1.0, 0.75, 0.4) { Torch fire orange }
      else if (CName = 'light_fluorospark') then
        LightCol := Vector3(0.85, 0.9, 1.0) { Fluorescent blue-white }
      else
        LightCol := Vector3(0.95, 0.92, 0.85); { Warm incandescent }

      PtLight := TCastlePointLight.Create(Parent);
      PtLight.Translation := QuakeToCge(Origin);
      PtLight.Color := LightCol;
      PtLight.Radius := RadiusVal;
      PtLight.Intensity := (LightVal / 200.0) * 1.2;
      { Falls off with the distance like Quake's "light - distance", so the
        many lights of a map do not add up to white in the dynamic mode }
      PtLight.Attenuation := Vector3(1, 4 / RadiusVal, 8 / Sqr(RadiusVal));
      PtLight.CastShadows := FShadowsEnabled;
      Parent.Add(PtLight);

      DynLight := TQuakeDynamicLight.Create;
      DynLight.LightNode := PtLight;
      DynLight.BaseIntensity := PtLight.Intensity;
      DynLight.StyleIndex := Style;
      DynLight.Origin := Origin;
      DynLight.Color := LightCol;
      DynLight.Radius := RadiusVal;
      FLights.Add(DynLight);
    end;
  end;

  WritelnLog('QuakeLight', 'Created %d dynamic lights from map entities', [FLights.Count]);
end;

procedure TQuakeLighting.Update(const SecondsPassed: Single; const PlayerPos: TVector3);
var
  I: Integer;
  DynLight: TQuakeDynamicLight;
  Mult: Single;
begin
  { Advance lightstyles at 10 Hz (Quake's lightstyle tic rate is 0.1s) }
  FStyleTimer := FStyleTimer + SecondsPassed;
  if FStyleTimer >= 0.1 then
  begin
    FStyleTimer := 0;
    for I := 0 to High(FStylePatterns) do
      if Length(FStylePatterns[I]) > 1 then
        FStyleFrames[I] := (FStyleFrames[I] + 1) mod Length(FStylePatterns[I]);

    { Apply intensity animation to dynamic lights }
    for DynLight in FLights do
    begin
      if DynLight.StyleIndex > 0 then
      begin
        Mult := GetStyleMultiplier(DynLight.StyleIndex);
        DynLight.LightNode.Intensity := DynLight.BaseIntensity * Mult;
      end;
    end;
  end;

  for I := 0 to MaxDLights - 1 do
    if FDLights[I].TimeLeft > 0 then
    begin
      FDLights[I].TimeLeft := FDLights[I].TimeLeft - SecondsPassed;
      FDLights[I].Radius := FDLights[I].Radius - FDLights[I].Decay * SecondsPassed;
    end;

  { Update muzzle flash decay }
  if FMuzzleTimer > 0 then
  begin
    FMuzzleTimer := FMuzzleTimer - SecondsPassed;
    if FMuzzleTimer <= 0 then
    begin
      FMuzzleTimer := 0;
      if FMuzzleLight <> nil then
        FMuzzleLight.Intensity := 0.0;
    end else
    if FMuzzleLight <> nil then
      FMuzzleLight.Intensity := (FMuzzleTimer / 0.12) * 2.5;
  end;
end;

procedure TQuakeLighting.TriggerMuzzleFlash(const Position: TVector3; const Intensity: Single);
begin
  if FMuzzleLight <> nil then
  begin
    FMuzzleLight.Translation := Position;
    FMuzzleLight.Intensity := Intensity;
    FMuzzleTimer := 0.12;
  end;
  { Explosions light the walls longer and fade (R_ParseExplosion), shots
    just flash (CL_MuzzleFlash) }
  if Intensity >= 5 then
    AddDLight(Position, 350, 0.5, 300)
  else
    AddDLight(Position, 200 + Random * 32, 0.1, 0);
end;

procedure TQuakeLighting.AddDLight(const Position: TVector3; const Radius, Duration, Decay: Single);
begin
  FDLights[FDLightNext].Position := Position;
  FDLights[FDLightNext].Radius := Radius;
  FDLights[FDLightNext].Decay := Decay;
  FDLights[FDLightNext].TimeLeft := Duration;
  FDLightNext := (FDLightNext + 1) mod MaxDLights;
end;

function TQuakeLighting.DLightUniform(const I: Integer): TVector4;
begin
  if (I < 0) or (I >= MaxDLights) or (FDLights[I].TimeLeft <= 0) or (FDLights[I].Radius <= 0) then
    Exit(TVector4.Zero);
  Result := Vector4(FDLights[I].Position, FDLights[I].Radius);
end;

procedure TQuakeLighting.SetShadows(const Enabled: Boolean);
var
  DynLight: TQuakeDynamicLight;
begin
  FShadowsEnabled := Enabled;
  for DynLight in FLights do
    DynLight.LightNode.CastShadows := Enabled;
end;

initialization
  Lighting := TQuakeLighting.Create;

finalization
  FreeAndNil(Lighting);
end.
