{ The particles of effectinfo.txt effects (DarkPlaces' pointparticles and
  trailparticles, particle rain and snow): every particle is a camera-facing
  quad in one of two meshes, added (static, spark, smoke...) or blended
  (alphastatic, blood), rebuilt each frame, textured from the mod's
  particles/particlefont.tga (a soft dot without one). }
unit QuakeEffectParticles;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math,
  CastleVectors, CastleTransform, CastleScene, CastleImages, CastleRenderOptions, CastleLog, CastleUtils,
  X3DNodes,
  QuakeEffectInfo;

const
  MaxEffectParticles = 4096;
  { One call makes at most this many (a big count on a slow machine) }
  MaxParticlesPerCall = 400;

type
  TEffectParticle = record
    Pos, Vel: TVector3;        { CGE coordinates }
    Color: TVector3;
    Alpha, AlphaFade: Single;
    Size, SizeIncrease: Single;
    Life: Single;
    Gravity: Single;           { units / s^2 down }
    Friction: Single;
    Tex: TVector4;
    Additive: Boolean;
  end;

  { Quake coordinates: is this point in water, slime or lava }
  TPointInLiquidFunc = function(const QuakePos: TVector3): Boolean of object;

  TQuakeEffectParticles = class
  private
    FItems: array of TEffectParticle;
    FCount: Integer;
    FScene: TCastleScene;
    FCoords, FTexCoords, FColors: array[Boolean] of TObject;
    FGeoms: array[Boolean] of TIndexedTriangleSetNode;
    FInfo: TEffectInfo;
    FFont: TParticleFont;
    FSpawned: Int64;
    FCalls: Integer;
    FDrawnEmpty: Boolean;
    procedure BuildScene(const Parent: TCastleTransform; const FontUrl: String);
    function Add: Integer;
    procedure SpawnSection(const Sec: PEffectSection; const QuakeOrg, QuakeVel: TVector3);
  public
    OnPointInLiquid: TPointInLiquidFunc;
    constructor Create;
    destructor Destroy; override;
    { effectinfo.txt and particles/particlefont.* from the paks; the scene
      under Parent. Returns the number of effects. }
    function Load(const Parent: TCastleTransform): Integer;
    procedure Clear;
    { DP's CL_ParticleEffect: Count times the effect's count (plus its
      countabsolute) particles at QuakeOrg; returns how many }
    function Spawn(const Num: Integer; const QuakeOrg, QuakeVel: TVector3; const Count: Single): Integer;
    { A trail from QuakeStart to QuakeStop: every trailspacing units }
    function Trail(const Num: Integer; const QuakeStart, QuakeStop: TVector3): Integer;
    { te_particlerain / te_particlesnow: Count drops in the box falling at
      QuakeVel, in Color }
    function Weather(const QuakeMins, QuakeMaxs, QuakeVel: TVector3; const Count: Integer;
      const Color: TVector3; const Snow: Boolean): Integer;
    { Move, fade and grow the particles, then face them to the camera }
    procedure Update(const SecondsPassed: Single; const CamRight, CamUp: TVector3);
    property Info: TEffectInfo read FInfo;
    property Count: Integer read FCount;
    { Particles made since the start, and effect calls }
    property Spawned: Int64 read FSpawned;
    property Calls: Integer read FCalls;
  end;

var
  { The views' effect particles (nil without a view: tests, servers) }
  EffectParticles: TQuakeEffectParticles;

implementation

uses
  QuakePak;

function QuakeToCge(const V: TVector3): TVector3;
begin
  Result := Vector3(V.X, V.Z, -V.Y);
end;

function Jitter(const J: TVector3): TVector3;
begin
  Result := Vector3((Random * 2 - 1) * J.X, (Random * 2 - 1) * J.Y, (Random * 2 - 1) * J.Z);
end;

function RandomBetween(const A, B: Single): Single;
begin
  Result := A + (B - A) * Random;
end;

constructor TQuakeEffectParticles.Create;
begin
  inherited Create;
  FInfo := TEffectInfo.Create;
  FFont := TParticleFont.Create;
end;

destructor TQuakeEffectParticles.Destroy;
begin
  FreeAndNil(FScene);
  FInfo.Free;
  FFont.Free;
  inherited Destroy;
end;

function SoftDotImage: TRGBAlphaImage;
var
  X, Y: Integer;
  D: Single;
  P: PVector4Byte;
begin
  { A white dot fading to its edge: every cell of the default font }
  Result := TRGBAlphaImage.Create(32, 32);
  for Y := 0 to 31 do
    for X := 0 to 31 do
    begin
      D := Sqrt(Sqr(X - 15.5) + Sqr(Y - 15.5)) / 16;
      P := Result.PixelPtr(X, Y);
      P^ := Vector4Byte(255, 255, 255, Round(255 * EnsureRange(1 - D * D, 0, 1)));
    end;
end;

procedure TQuakeEffectParticles.BuildScene(const Parent: TCastleTransform; const FontUrl: String);
var
  Root: TX3DRootNode;
  Additive: Boolean;
  Shape: TShapeNode;
  App: TAppearanceNode;
  Mat: TUnlitMaterialNode;
  Blend: TBlendModeNode;
  Tex: TAbstractTexture2DNode;
  ImgTex: TImageTextureNode;
  PixTex: TPixelTextureNode;
  Coord: TCoordinateNode;
  TexCoord: TTextureCoordinateNode;
  Color: TColorRGBANode;
begin
  FreeAndNil(FScene);
  Root := TX3DRootNode.Create;
  if FontUrl <> '' then
  begin
    ImgTex := TImageTextureNode.Create;
    ImgTex.SetUrl([FontUrl]);
    Tex := ImgTex;
  end else
  begin
    PixTex := TPixelTextureNode.Create;
    PixTex.FdImage.Value := SoftDotImage;
    Tex := PixTex;
  end;
  Tex.RepeatS := False;
  Tex.RepeatT := False;
  for Additive := False to True do
  begin
    Coord := TCoordinateNode.Create;
    TexCoord := TTextureCoordinateNode.Create;
    Color := TColorRGBANode.Create;
    FGeoms[Additive] := TIndexedTriangleSetNode.Create;
    FGeoms[Additive].Coord := Coord;
    FGeoms[Additive].TexCoord := TexCoord;
    FGeoms[Additive].Color := Color;
    FGeoms[Additive].Solid := False;
    FCoords[Additive] := Coord;
    FTexCoords[Additive] := TexCoord;
    FColors[Additive] := Color;
    Mat := TUnlitMaterialNode.Create;
    Mat.EmissiveColor := Vector3(1, 1, 1);
    App := TAppearanceNode.Create;
    App.Material := Mat;
    App.Texture := Tex;
    App.AlphaMode := amBlend;
    if Additive then
    begin
      Blend := TBlendModeNode.Create;
      Blend.SrcFactor := bsSrcAlpha;
      Blend.DestFactor := bdOne;
      App.BlendMode := Blend;
    end;
    Shape := TShapeNode.Create;
    Shape.Geometry := FGeoms[Additive];
    Shape.Appearance := App;
    Root.AddChildren(Shape);
  end;
  FScene := TCastleScene.Create(nil);
  FScene.Load(Root, True);
  FScene.Collides := False;
  FScene.Pickable := False;
  FScene.CastShadows := False;
  if Parent <> nil then
    Parent.Add(FScene);
end;

function TQuakeEffectParticles.Load(const Parent: TCastleTransform): Integer;
var
  Stream: TStream;
  Text, FontUrl: String;
begin
  Clear;
  FInfo.Clear;
  if Pak.FileExists('effectinfo.txt') then
  begin
    Stream := Pak.GetStream('effectinfo.txt');
    if Stream <> nil then
    try
      SetLength(Text, Stream.Size);
      if Stream.Size > 0 then
        Stream.ReadBuffer(Text[1], Stream.Size);
      FInfo.LoadFromText(Text);
    finally
      Stream.Free;
    end;
  end;
  FFont.Free;
  FFont := TParticleFont.Create;
  FontUrl := '';
  if Pak.FileExists('particles/particlefont.tga') or Pak.FileExists('particles/particlefont.png') then
  begin
    if Pak.FileExists('particles/particlefont.tga') then
      FontUrl := 'quakepak:/particles/particlefont.tga'
    else
      FontUrl := 'quakepak:/particles/particlefont.png';
    if Pak.FileExists('particles/particlefont.txt') then
    begin
      Stream := Pak.GetStream('particles/particlefont.txt');
      if Stream <> nil then
      try
        SetLength(Text, Stream.Size);
        if Stream.Size > 0 then
          Stream.ReadBuffer(Text[1], Stream.Size);
        FFont.LoadFromText(Text);
      finally
        Stream.Free;
      end;
    end;
  end;
  BuildScene(Parent, FontUrl);
  Result := FInfo.EffectCount;
  if Result > 0 then
    WritelnLog('QuakeEffectParticles', 'effectinfo.txt: %d effects (%d particle sections), %s',
      [Result, FInfo.TotalSections, BoolToStr(FontUrl <> '', 'particle font "' + FontUrl + '"', 'default particle dot')]);
end;

procedure TQuakeEffectParticles.Clear;
begin
  FCount := 0;
end;

function TQuakeEffectParticles.Add: Integer;
begin
  if FCount >= MaxEffectParticles then
    Exit(-1);
  if FCount >= Length(FItems) then
    SetLength(FItems, Min(MaxEffectParticles, Max(256, Length(FItems) * 2)));
  Result := FCount;
  Inc(FCount);
  Inc(FSpawned);
end;

procedure TQuakeEffectParticles.SpawnSection(const Sec: PEffectSection; const QuakeOrg, QuakeVel: TVector3);
var
  I: Integer;
  Org, Vel: TVector3;
begin
  Org := QuakeOrg + Sec^.OriginOffset + Jitter(Sec^.OriginJitter);
  if (Sec^.Underwater or Sec^.NotUnderwater) and Assigned(OnPointInLiquid) then
    if OnPointInLiquid(Org) <> Sec^.Underwater then
      Exit;
  I := Add;
  if I < 0 then
    Exit;
  Vel := QuakeVel * Sec^.VelocityMultiplier + Sec^.VelocityOffset + Jitter(Sec^.VelocityJitter);
  FItems[I].Pos := QuakeToCge(Org);
  FItems[I].Vel := QuakeToCge(Vel);
  FItems[I].Color := Sec^.Color1 + (Sec^.Color2 - Sec^.Color1) * Random;
  FItems[I].Alpha := RandomBetween(Sec^.AlphaMin, Sec^.AlphaMax);
  FItems[I].AlphaFade := Sec^.AlphaFade;
  FItems[I].Size := RandomBetween(Sec^.SizeMin, Sec^.SizeMax);
  FItems[I].SizeIncrease := Sec^.SizeIncrease;
  FItems[I].Life := RandomBetween(Sec^.TimeMin, Sec^.TimeMax);
  FItems[I].Gravity := Sec^.Gravity * 800;
  FItems[I].Friction := Sec^.AirFriction;
  if Sec^.TexMax > Sec^.TexMin then
    FItems[I].Tex := FFont.Rect(Sec^.TexMin + Random(Sec^.TexMax - Sec^.TexMin))
  else
    FItems[I].Tex := FFont.Rect(Sec^.TexMin);
  FItems[I].Additive := not (Sec^.PType in [eptAlphaStatic, eptBlood]);
end;

function RandomCount(const N: Single): Integer;
begin
  { 2.5 particles: 2, and a third one half the time }
  Result := Trunc(N);
  if Random < Frac(N) then
    Inc(Result);
end;

function TQuakeEffectParticles.Spawn(const Num: Integer; const QuakeOrg, QuakeVel: TVector3;
  const Count: Single): Integer;
var
  S, I, N: Integer;
  Before: Int64;
  Sec: PEffectSection;
begin
  Before := FSpawned;
  Inc(FCalls);
  for S := 0 to FInfo.SectionCount(Num) - 1 do
  begin
    Sec := FInfo.Section(Num, S);
    N := Min(RandomCount(Sec^.Count * Max(Count, 0) + Sec^.CountAbsolute), MaxParticlesPerCall);
    for I := 1 to N do
      SpawnSection(Sec, QuakeOrg, QuakeVel);
  end;
  { What was made: underwater / notunderwater sections and a full pool make fewer }
  Result := FSpawned - Before;
end;

function TQuakeEffectParticles.Trail(const Num: Integer; const QuakeStart, QuakeStop: TVector3): Integer;
var
  S, I, N: Integer;
  Sec: PEffectSection;
  Dir: TVector3;
  Len: Single;
  Before: Int64;
begin
  Before := FSpawned;
  Inc(FCalls);
  Dir := QuakeStop - QuakeStart;
  Len := Dir.Length;
  for S := 0 to FInfo.SectionCount(Num) - 1 do
  begin
    Sec := FInfo.Section(Num, S);
    if Sec^.TrailSpacing > 0 then
      N := RandomCount(Len / Sec^.TrailSpacing)
    else
      N := RandomCount(Sec^.Count + Sec^.CountAbsolute);
    N := Min(N, MaxParticlesPerCall);
    for I := 1 to N do
      SpawnSection(Sec, QuakeStart + Dir * Random, TVector3.Zero);
  end;
  Result := FSpawned - Before;
end;

function TQuakeEffectParticles.Weather(const QuakeMins, QuakeMaxs, QuakeVel: TVector3; const Count: Integer;
  const Color: TVector3; const Snow: Boolean): Integer;
var
  I, P: Integer;
  Org: TVector3;
begin
  Result := Min(Count, MaxParticlesPerCall);
  Inc(FCalls);
  for I := 1 to Result do
  begin
    P := Add;
    if P < 0 then
      Exit(I - 1);
    Org := Vector3(RandomBetween(QuakeMins.X, QuakeMaxs.X), RandomBetween(QuakeMins.Y, QuakeMaxs.Y),
      QuakeMaxs.Z);
    FItems[P].Pos := QuakeToCge(Org);
    FItems[P].Vel := QuakeToCge(QuakeVel + Jitter(Vector3(16, 16, 0)) * Ord(Snow));
    FItems[P].Color := Color;
    FItems[P].Alpha := 1;
    FItems[P].AlphaFade := 0;
    if Snow then
      FItems[P].Size := 1
    else
      FItems[P].Size := 0.5;
    FItems[P].SizeIncrease := 0;
    { Falls the box's height }
    if QuakeVel.Z < -1 then
      FItems[P].Life := (QuakeMaxs.Z - QuakeMins.Z) / -QuakeVel.Z
    else
      FItems[P].Life := 2;
    FItems[P].Gravity := 0;
    FItems[P].Friction := 0;
    FItems[P].Tex := FFont.Rect(0);
    FItems[P].Additive := True;
  end;
end;

procedure TQuakeEffectParticles.Update(const SecondsPassed: Single; const CamRight, CamUp: TVector3);
var
  I, J, Quads: Integer;
  Additive: Boolean;
  Pts: TVector3List;
  Tcs: TVector2List;
  Cols: TVector4List;
  Idx: TInt32List;
  R, U: TVector3;
  C: TVector4;
  V1, V2: Single;
begin
  if FScene = nil then
    Exit;
  { Move them; the dead go, the last taking their place }
  I := 0;
  while I < FCount do
  begin
    FItems[I].Life := FItems[I].Life - SecondsPassed;
    FItems[I].Alpha := FItems[I].Alpha - FItems[I].AlphaFade * SecondsPassed;
    FItems[I].Size := FItems[I].Size + FItems[I].SizeIncrease * SecondsPassed;
    if (FItems[I].Life <= 0) or (FItems[I].Alpha <= 0) or (FItems[I].Size <= 0) then
    begin
      Dec(FCount);
      FItems[I] := FItems[FCount];
      Continue;
    end;
    FItems[I].Vel.Y := FItems[I].Vel.Y - FItems[I].Gravity * SecondsPassed;
    if FItems[I].Friction > 0 then
      FItems[I].Vel := FItems[I].Vel * Max(0, 1 - FItems[I].Friction * SecondsPassed);
    FItems[I].Pos := FItems[I].Pos + FItems[I].Vel * SecondsPassed;
    Inc(I);
  end;
  { Nothing to draw and nothing drawn: the meshes stay as they are }
  if (FCount = 0) and FDrawnEmpty then
    Exit;
  FDrawnEmpty := FCount = 0;
  for Additive := False to True do
  begin
    Pts := TVector3List.Create;
    Tcs := TVector2List.Create;
    Cols := TVector4List.Create;
    Idx := TInt32List.Create;
    try
      Quads := 0;
      for I := 0 to FCount - 1 do
        if FItems[I].Additive = Additive then
        begin
          R := CamRight * FItems[I].Size;
          U := CamUp * FItems[I].Size;
          Pts.Add(FItems[I].Pos - R - U);
          Pts.Add(FItems[I].Pos + R - U);
          Pts.Add(FItems[I].Pos + R + U);
          Pts.Add(FItems[I].Pos - R + U);
          { particlefont's t runs from the top }
          V1 := 1 - FItems[I].Tex.W;
          V2 := 1 - FItems[I].Tex.Y;
          Tcs.Add(Vector2(FItems[I].Tex.X, V1));
          Tcs.Add(Vector2(FItems[I].Tex.Z, V1));
          Tcs.Add(Vector2(FItems[I].Tex.Z, V2));
          Tcs.Add(Vector2(FItems[I].Tex.X, V2));
          C := Vector4(FItems[I].Color, Min(FItems[I].Alpha, 1));
          for J := 1 to 4 do
            Cols.Add(C);
          J := Quads * 4;
          Idx.AddRange([J, J + 1, J + 2, J, J + 2, J + 3]);
          Inc(Quads);
        end;
      TCoordinateNode(FCoords[Additive]).SetPoint(Pts);
      TTextureCoordinateNode(FTexCoords[Additive]).SetPoint(Tcs);
      TColorRGBANode(FColors[Additive]).SetColor(Cols);
      FGeoms[Additive].SetIndex(Idx);
    finally
      Pts.Free;
      Tcs.Free;
      Cols.Free;
      Idx.Free;
    end;
  end;
end;

end.
