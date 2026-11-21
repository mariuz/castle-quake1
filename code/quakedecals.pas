{ Decals: the marks shots, explosions and blood leave on the level. Each
  is a quad laid on the surface next to where it happened (found with a
  short trace against the level), dark or red, fading out after a while;
  the oldest goes when there are too many. All in one mesh, like the
  particles. QuakeParticles makes them with its impacts, explosions and
  blood, QuakeEffectParticles for a mod's "type decal" sections. }
unit QuakeDecals;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math,
  CastleVectors, CastleTransform, CastleScene, CastleImages, CastleRenderOptions, CastleUtils, X3DNodes,
  QuakeBsp;

const
  MaxDecals = 128;
  { A decal stays this long and fades over the last seconds of it }
  DecalLife = 40.0;
  DecalFade = 8.0;

type
  TDecalKind = (dkBullet, dkScorch, dkBlood);

  TDecal = record
    Center, Right, Up: TVector3;   { CGE coordinates; Right and Up carry the size }
    Color: TVector3;
    Alpha: Single;
    Age: Single;
  end;

  TQuakeDecals = class
  private
    FItems: array[0..MaxDecals - 1] of TDecal;
    FCount, FNext: Integer;
    FMade: Int64;
    FParent: TCastleTransform;
    FScene: TCastleScene;
    FCoord: TCoordinateNode;
    FTexCoord: TTextureCoordinateNode;
    FColor: TColorRGBANode;
    FGeom: TIndexedTriangleSetNode;
    FDirty: Boolean;
    procedure BuildScene;
    procedure Rebuild;
    { The surface of the level nearest to P within Reach (Quake
      coordinates); Down: only what is under P }
    function FindSurface(const P: TVector3; const Reach: Single; const Down: Boolean;
      out Hit, Normal: TVector3): Boolean;
    { Is the level's surface right behind this point of a decal }
    function OnSurface(const P, Normal: TVector3): Boolean;
  public
    { The level the decals lie on (nil: none are made) }
    WorldBsp: TQuakeBsp;
    constructor Create;
    destructor Destroy; override;
    procedure SetParent(const AParent: TCastleTransform);
    { A mark of a kind on the surface near CgePos; False when there is
      none near enough (an explosion in the air) or decals are off }
    function Add(const Kind: TDecalKind; const CgePos: TVector3): Boolean;
    { A mark of a mod's effect: its own size, color and alpha }
    function AddCustom(const CgePos: TVector3; const Size: Single; const Color: TVector3;
      const Alpha: Single): Boolean;
    procedure Update(const SecondsPassed: Single);
    { The level goes: its decals too }
    procedure Clear;
    { Decals on the walls now, and made since the start }
    property Count: Integer read FCount;
    property Made: Int64 read FMade;
  end;

var
  { r_decals: marks of shots, explosions and blood on the level }
  DecalsEnabled: Boolean = True;
  Decals: TQuakeDecals;

implementation

function QuakeToCge(const V: TVector3): TVector3;
begin
  Result := Vector3(V.X, V.Z, -V.Y);
end;

function CgeToQuake(const V: TVector3): TVector3;
begin
  Result := Vector3(V.X, -V.Z, V.Y);
end;

constructor TQuakeDecals.Create;
begin
  inherited Create;
end;

destructor TQuakeDecals.Destroy;
begin
  FreeAndNil(FScene);
  inherited Destroy;
end;

procedure TQuakeDecals.SetParent(const AParent: TCastleTransform);
begin
  if FParent = AParent then
    Exit;
  FreeAndNil(FScene);
  FParent := AParent;
  FCount := 0;
  FNext := 0;
  if FParent <> nil then
    BuildScene;
end;

procedure TQuakeDecals.BuildScene;
var
  Root: TX3DRootNode;
  Shape: TShapeNode;
  App: TAppearanceNode;
  Mat: TUnlitMaterialNode;
  Tex: TPixelTextureNode;
  Img: TRGBAlphaImage;
  X, Y: Integer;
  D, Ragged: Single;
begin
  { A blot with a ragged edge, tinted by each decal's color }
  Img := TRGBAlphaImage.Create(32, 32);
  for Y := 0 to 31 do
    for X := 0 to 31 do
    begin
      D := Sqrt(Sqr(X - 15.5) + Sqr(Y - 15.5)) / 16;
      Ragged := 0.12 * Sin(ArcTan2(Y - 15.5, X - 15.5) * 7) + 0.06 * Sin(ArcTan2(Y - 15.5, X - 15.5) * 13 + 1);
      Img.PixelPtr(X, Y)^ := Vector4Byte(255, 255, 255, Round(255 * EnsureRange(3 * (0.85 + Ragged - D), 0, 1)));
    end;
  Tex := TPixelTextureNode.Create;
  Tex.FdImage.Value := Img;
  Tex.RepeatS := False;
  Tex.RepeatT := False;
  FCoord := TCoordinateNode.Create;
  FTexCoord := TTextureCoordinateNode.Create;
  FColor := TColorRGBANode.Create;
  FGeom := TIndexedTriangleSetNode.Create;
  FGeom.Coord := FCoord;
  FGeom.TexCoord := FTexCoord;
  FGeom.Color := FColor;
  FGeom.Solid := False;
  Mat := TUnlitMaterialNode.Create;
  Mat.EmissiveColor := Vector3(1, 1, 1);
  App := TAppearanceNode.Create;
  App.Material := Mat;
  App.Texture := Tex;
  App.AlphaMode := amBlend;
  Shape := TShapeNode.Create;
  Shape.Geometry := FGeom;
  Shape.Appearance := App;
  Root := TX3DRootNode.Create;
  Root.AddChildren(Shape);
  FScene := TCastleScene.Create(nil);
  FScene.Name := 'decals';
  FScene.Load(Root, True);
  FScene.Collides := False;
  FScene.Pickable := False;
  FScene.CastShadows := False;
  FParent.Add(FScene);
  FDirty := False;
end;

function TQuakeDecals.FindSurface(const P: TVector3; const Reach: Single; const Down: Boolean;
  out Hit, Normal: TVector3): Boolean;
const
  Dirs: array[0..5] of TVector3 = (
    (X: 0; Y: 0; Z: -1), (X: 0; Y: 0; Z: 1), (X: 1; Y: 0; Z: 0), (X: -1; Y: 0; Z: 0), (X: 0; Y: 1; Z: 0),
    (X: 0; Y: -1; Z: 0));
var
  I, Last: Integer;
  Trace: TQuakeTrace;
  Best: Single;
begin
  Result := False;
  Best := 2;
  if Down then
    Last := 0
  else
    Last := High(Dirs);
  for I := 0 to Last do
  begin
    Trace := WorldBsp.TraceHull(0, 0, TVector3.Zero, P, P + Dirs[I] * Reach);
    if Trace.StartSolid or Trace.AllSolid or (Trace.Fraction >= Best) or (Trace.Fraction >= 1) then
      Continue;
    Best := Trace.Fraction;
    Hit := Trace.EndPos;
    Normal := Trace.PlaneNormal;
    Result := True;
  end;
end;

function TQuakeDecals.OnSurface(const P, Normal: TVector3): Boolean;
var
  Trace: TQuakeTrace;
begin
  Trace := WorldBsp.TraceHull(0, 0, TVector3.Zero, P + Normal * 2, P - Normal * 2);
  Result := (Trace.Fraction < 1) and not Trace.StartSolid;
end;

function TQuakeDecals.AddCustom(const CgePos: TVector3; const Size: Single; const Color: TVector3;
  const Alpha: Single): Boolean;
var
  P, Hit, Normal, Side, Right, Up: TVector3;
  Half, Angle, S, C: Single;
  Shrinks, I: Integer;
  Fits: Boolean;
begin
  Result := False;
  if (not DecalsEnabled) or (WorldBsp = nil) or (Size <= 0) then
    Exit;
  P := CgeToQuake(CgePos);
  { An impact is at the surface (or a hair inside it): look from a little
    away from every side, then further for the big marks }
  if not FindSurface(P, Max(12, Size * 1.5), False, Hit, Normal) then
    Exit;
  { Two directions on the surface, turned at random }
  if Abs(Normal.Z) > 0.9 then
    Side := Vector3(1, 0, 0)
  else
    Side := Vector3(0, 0, 1);
  Right := TVector3.CrossProduct(Normal, Side).Normalize;
  Up := TVector3.CrossProduct(Normal, Right).Normalize;
  Angle := Random * 2 * Pi;
  SinCos(Angle, S, C);
  Side := Right * C + Up * S;
  Up := Up * C - Right * S;
  Right := Side;
  { A mark must lie on the level with all four corners: smaller near an
    edge, none on a thin ledge }
  Half := Size;
  Fits := False;
  for Shrinks := 0 to 2 do
  begin
    Fits := OnSurface(Hit + (Right + Up) * Half, Normal) and OnSurface(Hit + (Right - Up) * Half, Normal) and
      OnSurface(Hit - (Right + Up) * Half, Normal) and OnSurface(Hit - (Right - Up) * Half, Normal);
    if Fits then
      Break;
    Half := Half / 2;
  end;
  if not Fits then
    Exit;
  { The oldest gives its place when all are used }
  if FCount < MaxDecals then
  begin
    I := FCount;
    Inc(FCount);
  end else
  begin
    I := FNext;
    FNext := (FNext + 1) mod MaxDecals;
  end;
  { A little off the surface, further for the ones made later: no flicker
    where marks overlap }
  FItems[I].Center := QuakeToCge(Hit + Normal * (0.3 + 0.002 * (FMade mod 100)));
  FItems[I].Right := QuakeToCge(Right * Half);
  FItems[I].Up := QuakeToCge(Up * Half);
  FItems[I].Color := Color;
  FItems[I].Alpha := Alpha;
  FItems[I].Age := 0;
  Inc(FMade);
  FDirty := True;
  Result := True;
end;

function TQuakeDecals.Add(const Kind: TDecalKind; const CgePos: TVector3): Boolean;
begin
  case Kind of
    dkBullet: Result := AddCustom(CgePos, 2.5 + Random * 1.5, Vector3(0.04, 0.04, 0.04), 0.85);
    dkScorch: Result := AddCustom(CgePos, 24 + Random * 10, Vector3(0.03, 0.03, 0.03), 0.8);
    else Result := AddCustom(CgePos, 5 + Random * 6, Vector3(0.35 + Random * 0.1, 0.0, 0.0), 0.85);
  end;
end;

procedure TQuakeDecals.Update(const SecondsPassed: Single);
var
  I: Integer;
begin
  I := 0;
  while I < FCount do
  begin
    FItems[I].Age := FItems[I].Age + SecondsPassed;
    if FItems[I].Age > DecalLife - DecalFade then
      FDirty := True;
    if FItems[I].Age >= DecalLife then
    begin
      Dec(FCount);
      FItems[I] := FItems[FCount];
      if FNext >= FCount then
        FNext := 0;
      Continue;
    end;
    Inc(I);
  end;
  if FDirty then
    Rebuild;
end;

procedure TQuakeDecals.Rebuild;
var
  Pts: TVector3List;
  Tcs: TVector2List;
  Cols: TVector4List;
  Idx: TInt32List;
  I, J: Integer;
  C: TVector4;
begin
  FDirty := False;
  if FScene = nil then
    Exit;
  Pts := TVector3List.Create;
  Tcs := TVector2List.Create;
  Cols := TVector4List.Create;
  Idx := TInt32List.Create;
  try
    for I := 0 to FCount - 1 do
    begin
      Pts.Add(FItems[I].Center - FItems[I].Right - FItems[I].Up);
      Pts.Add(FItems[I].Center + FItems[I].Right - FItems[I].Up);
      Pts.Add(FItems[I].Center + FItems[I].Right + FItems[I].Up);
      Pts.Add(FItems[I].Center - FItems[I].Right + FItems[I].Up);
      Tcs.Add(Vector2(0, 0));
      Tcs.Add(Vector2(1, 0));
      Tcs.Add(Vector2(1, 1));
      Tcs.Add(Vector2(0, 1));
      C := Vector4(FItems[I].Color,
        FItems[I].Alpha * EnsureRange((DecalLife - FItems[I].Age) / DecalFade, 0, 1));
      for J := 1 to 4 do
        Cols.Add(C);
      J := I * 4;
      Idx.AddRange([J, J + 1, J + 2, J, J + 2, J + 3]);
    end;
    FCoord.SetPoint(Pts);
    FTexCoord.SetPoint(Tcs);
    FColor.SetColor(Cols);
    FGeom.SetIndex(Idx);
  finally
    Pts.Free;
    Tcs.Free;
    Cols.Free;
    Idx.Free;
  end;
end;

procedure TQuakeDecals.Clear;
begin
  FCount := 0;
  FNext := 0;
  WorldBsp := nil;
  FDirty := True;
  Rebuild;
end;

initialization
  Decals := TQuakeDecals.Create;

finalization
  FreeAndNil(Decals);
end.
