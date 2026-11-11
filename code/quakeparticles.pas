{ Particle effects and impact visuals for Castle Quake. }
unit QuakeParticles;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, Math,
  CastleVectors, CastleTransform, CastleScene, CastleColors, CastleUtils, CastleImages,
  CastleRenderOptions, X3DNodes;

type
  { Particle type kinds }
  TParticleKind = (pkSparks, pkSmoke, pkBlood, pkFireball, pkTeleport);

  { Single active particle in the world (CGE coordinates); the manager
    draws them all in one mesh }
  TQuakeParticle = class
  public
    Position: TVector3;
    Velocity: TVector3;
    Color: TVector3;
    Kind: TParticleKind;
    Life: Single;
    MaxLife: Single;
    StartScale: Single;
    EndScale: Single;
    Gravity: Single;
    { What it is drawn with now }
    Scale, Alpha: Single;
    constructor Create(const Parent: TCastleTransform; const Pos, Vel: TVector3;
      const AKind: TParticleKind; const ALife, AStartScale, AEndScale: Single;
      const ColorTint: TVector3);
    function Update(const SecondsPassed: Single): Boolean; { returns False when expired }
  end;

  TQuakeParticleList = specialize TObjectList<TQuakeParticle>;

  { Particle effects manager }
  TQuakeParticleManager = class
  private
    FParticles: TQuakeParticleList;
    FParent: TCastleTransform;
    { One scene for every particle: camera-facing quads rebuilt each frame }
    FScene: TCastleScene;
    FCoord: TCoordinateNode;
    FTexCoord: TTextureCoordinateNode;
    FColor: TColorRGBANode;
    FGeom: TIndexedTriangleSetNode;
    FDrawnEmpty: Boolean;
    procedure BuildScene;
    procedure Rebuild;
  public
    { Demo recording: effects worth a temp entity (Kind: 'explosion',
      'teleport', 'puff', 'blood'); Pos and Normal are CGE coordinates }
    OnEffect: procedure(const Kind: String; const Pos, Normal: TVector3) of object;
    constructor Create;
    destructor Destroy; override;

    procedure SetParent(const AParent: TCastleTransform);
    { Particles alive (all in one draw call) }
    function Count: Integer;
    procedure Update(const SecondsPassed: Single);
    procedure Clear;

    { Spawn bullet impact sparks and smoke }
    procedure SpawnImpact(const Pos, Normal: TVector3);

    { Spawn blood burst when enemy is shot }
    procedure SpawnBlood(const Pos, Normal: TVector3);

    { Spawn rocket explosion fireball and sparks }
    procedure SpawnExplosion(const Pos: TVector3);

    { Spawn teleport particle fountain }
    procedure SpawnTeleport(const Pos: TVector3);
    { R_LavaSplash (TE_LAVASPLASH): a 16 x 16 field of lava drops rising
      from the pool, Chthon's entrance }
    procedure SpawnLavaSplash(const Pos: TVector3);

    { One puff of a projectile trail (CGE coordinates) }
    procedure SpawnRocketTrail(const Pos: TVector3);
    procedure SpawnGrenadeTrail(const Pos: TVector3);
    procedure SpawnNailTrail(const Pos: TVector3);
    procedure SpawnBloodTrail(const Pos: TVector3);
    { Glowing trail puff of a given color (monster missiles) }
    procedure SpawnTrail(const Pos, Color: TVector3);

    { Small puff where a bullet or nail hits a wall (TE_GUNSHOT / TE_SPIKE) }
    procedure SpawnPuff(const Pos, Normal: TVector3);
  end;

var
  Particles: TQuakeParticleManager;

implementation

constructor TQuakeParticle.Create(const Parent: TCastleTransform; const Pos, Vel: TVector3;
  const AKind: TParticleKind; const ALife, AStartScale, AEndScale: Single;
  const ColorTint: TVector3);
begin
  inherited Create;
  Kind := AKind;
  Position := Pos;
  Velocity := Vel;
  Color := ColorTint;
  Life := ALife;
  MaxLife := ALife;
  StartScale := AStartScale;
  EndScale := AEndScale;
  Scale := AStartScale;
  Alpha := 0.9;
  if (AKind = pkSparks) or (AKind = pkBlood) then
    Gravity := 400.0
  else
    Gravity := -50.0; { Smoke and fire rise }
end;

function TQuakeParticle.Update(const SecondsPassed: Single): Boolean;
var
  Fraction: Single;
begin
  Life := Life - SecondsPassed;
  if Life <= 0 then
    Exit(False);
  Velocity.Y := Velocity.Y - Gravity * SecondsPassed;
  Position := Position + Velocity * SecondsPassed;
  { Grow or shrink, and fade out }
  Fraction := 1.0 - (Life / MaxLife);
  Scale := StartScale + (EndScale - StartScale) * Fraction;
  Alpha := 0.9 * (1 - Fraction);
  Result := True;
end;

{ TQuakeParticleManager }

constructor TQuakeParticleManager.Create;
begin
  inherited Create;
  FParticles := TQuakeParticleList.Create(True);
  FParent := nil;
end;

destructor TQuakeParticleManager.Destroy;
begin
  FreeAndNil(FScene);
  FParticles.Free;
  inherited Destroy;
end;

procedure TQuakeParticleManager.SetParent(const AParent: TCastleTransform);
begin
  Clear;
  FreeAndNil(FScene);
  FParent := AParent;
  if FParent <> nil then
    BuildScene;
end;

function TQuakeParticleManager.Count: Integer;
begin
  Result := FParticles.Count;
end;

procedure TQuakeParticleManager.BuildScene;
var
  Root: TX3DRootNode;
  Shape: TShapeNode;
  App: TAppearanceNode;
  Mat: TUnlitMaterialNode;
  Tex: TPixelTextureNode;
  Img: TRGBAlphaImage;
  X, Y: Integer;
  D: Single;
begin
  { A soft white dot, tinted by each quad's color }
  Img := TRGBAlphaImage.Create(32, 32);
  for Y := 0 to 31 do
    for X := 0 to 31 do
    begin
      D := Sqrt(Sqr(X - 15.5) + Sqr(Y - 15.5)) / 16;
      Img.PixelPtr(X, Y)^ := Vector4Byte(255, 255, 255, Round(255 * EnsureRange(1.5 * (1 - D), 0, 1)));
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
  FScene.Name := 'particles';
  FScene.Load(Root, True);
  FScene.Collides := False;
  FScene.Pickable := False;
  FScene.CastShadows := False;
  FParent.Add(FScene);
  FDrawnEmpty := True;
end;

procedure TQuakeParticleManager.Clear;
begin
  FParticles.Clear;
  if FScene <> nil then
    Rebuild;
end;

procedure TQuakeParticleManager.Rebuild;
var
  Pts: TVector3List;
  Tcs: TVector2List;
  Cols: TVector4List;
  Idx: TInt32List;
  I, J: Integer;
  P: TQuakeParticle;
  Right, Up, R, U: TVector3;
  C: TVector4;
  Cam: TCastleCamera;
begin
  if (FScene = nil) or ((FParticles.Count = 0) and FDrawnEmpty) then
    Exit;
  FDrawnEmpty := FParticles.Count = 0;
  { The quads face the main camera }
  Right := Vector3(1, 0, 0);
  Up := Vector3(0, 1, 0);
  Cam := nil;
  if FParent is TCastleRootTransform then
    Cam := TCastleRootTransform(FParent).MainCamera;
  if Cam <> nil then
  begin
    Up := Cam.Up.Normalize;
    Right := TVector3.CrossProduct(Cam.Direction, Cam.Up).Normalize;
  end;
  Pts := TVector3List.Create;
  Tcs := TVector2List.Create;
  Cols := TVector4List.Create;
  Idx := TInt32List.Create;
  try
    for I := 0 to FParticles.Count - 1 do
    begin
      P := FParticles[I];
      R := Right * P.Scale;
      U := Up * P.Scale;
      Pts.Add(P.Position - R - U);
      Pts.Add(P.Position + R - U);
      Pts.Add(P.Position + R + U);
      Pts.Add(P.Position - R + U);
      Tcs.Add(Vector2(0, 0));
      Tcs.Add(Vector2(1, 0));
      Tcs.Add(Vector2(1, 1));
      Tcs.Add(Vector2(0, 1));
      C := Vector4(P.Color, P.Alpha);
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

procedure TQuakeParticleManager.Update(const SecondsPassed: Single);
var
  I: Integer;
begin
  for I := FParticles.Count - 1 downto 0 do
  begin
    if not FParticles[I].Update(SecondsPassed) then
      FParticles.Delete(I);
  end;
  Rebuild;
end;

procedure TQuakeParticleManager.SpawnImpact(const Pos, Normal: TVector3);
var
  I: Integer;
  Vel: TVector3;
  P: TQuakeParticle;
begin
  if FParent = nil then
    Exit;

  { Sparks bouncing away from surface }
  for I := 1 to 6 do
  begin
    Vel := Normal * (100.0 + Random * 120.0) +
      Vector3((Random - 0.5) * 100.0, (Random - 0.5) * 100.0, (Random - 0.5) * 100.0);
    P := TQuakeParticle.Create(FParent, Pos, Vel, pkSparks, 0.3 + Random * 0.2, 1.5, 0.5,
      Vector3(1.0, 0.85, 0.3));
    FParticles.Add(P);
  end;

  { Smoke puff }
  Vel := Normal * 20.0 + Vector3(0, 30.0, 0);
  P := TQuakeParticle.Create(FParent, Pos, Vel, pkSmoke, 0.5, 2.0, 8.0,
    Vector3(0.5, 0.5, 0.5));
  FParticles.Add(P);
end;

procedure TQuakeParticleManager.SpawnBlood(const Pos, Normal: TVector3);
var
  I: Integer;
  Vel: TVector3;
  P: TQuakeParticle;
begin
  if Assigned(OnEffect) then
    OnEffect('blood', Pos, Normal);
  if FParent = nil then
    Exit;

  for I := 1 to 8 do
  begin
    Vel := Normal * (60.0 + Random * 80.0) +
      Vector3((Random - 0.5) * 80.0, (Random - 0.5) * 80.0, (Random - 0.5) * 80.0);
    P := TQuakeParticle.Create(FParent, Pos, Vel, pkBlood, 0.4 + Random * 0.3, 2.0, 0.8,
      Vector3(0.75, 0.05, 0.05));
    FParticles.Add(P);
  end;
end;

procedure TQuakeParticleManager.SpawnExplosion(const Pos: TVector3);
var
  I: Integer;
  Vel: TVector3;
  P: TQuakeParticle;
begin
  if Assigned(OnEffect) then
    OnEffect('explosion', Pos, TVector3.Zero);
  if FParent = nil then
    Exit;

  { Central fireball expanding }
  P := TQuakeParticle.Create(FParent, Pos, Vector3(0, 20.0, 0), pkFireball, 0.4, 6.0, 24.0,
    Vector3(1.0, 0.5, 0.1));
  FParticles.Add(P);

  { Flying fiery debris }
  for I := 1 to 14 do
  begin
    Vel := Vector3((Random - 0.5) * 300.0, (Random * 200.0 + 50.0), (Random - 0.5) * 300.0);
    P := TQuakeParticle.Create(FParent, Pos, Vel, pkSparks, 0.6 + Random * 0.4, 3.0, 0.5,
      Vector3(1.0, 0.6, 0.1));
    FParticles.Add(P);
  end;
end;

procedure TQuakeParticleManager.SpawnTeleport(const Pos: TVector3);
var
  I: Integer;
  Vel: TVector3;
  P: TQuakeParticle;
begin
  if Assigned(OnEffect) then
    OnEffect('teleport', Pos, TVector3.Zero);
  if FParent = nil then
    Exit;

  for I := 1 to 20 do
  begin
    Vel := Vector3((Random - 0.5) * 80.0, Random * 250.0 + 80.0, (Random - 0.5) * 80.0);
    P := TQuakeParticle.Create(FParent, Pos, Vel, pkTeleport, 0.8 + Random * 0.4, 2.5, 0.5,
      Vector3(0.2, 0.9, 0.95));
    FParticles.Add(P);
  end;
end;

procedure TQuakeParticleManager.SpawnLavaSplash(const Pos: TVector3);
var
  I, J: Integer;
  Dir, Vel: TVector3;
  P: TQuakeParticle;
  Speed: Single;
begin
  if Assigned(OnEffect) then
    OnEffect('lavasplash', Pos, TVector3.Zero);
  if FParent = nil then
    Exit;
  { Every second cell of the original's grid: 64 drops }
  for I := -8 to 7 do
    for J := -8 to 7 do
      if ((I + J) and 1) = 0 then
      begin
        { Quake: dir = (j*8 + rand*8, i*8 + rand*8, 256), vel = 50 + rand*64 along dir }
        Dir := Vector3(J * 8 + Random * 8, 256, -(I * 8 + Random * 8));
        Speed := 50 + Random * 64;
        Vel := Dir.Normalize * Speed;
        P := TQuakeParticle.Create(FParent, Pos + Vector3(Dir.X, 0, Dir.Z), Vel, pkSparks,
          2 + Random * 0.64, 2.5, 1.0, Vector3(1.0, 0.45 + Random * 0.3, 0.1));
        P.Gravity := 0.05 * 800;
        FParticles.Add(P);
      end;
end;

procedure TQuakeParticleManager.SpawnRocketTrail(const Pos: TVector3);
begin
  if FParent = nil then
    Exit;
  FParticles.Add(TQuakeParticle.Create(FParent, Pos,
    Vector3((Random - 0.5) * 10, 10, (Random - 0.5) * 10), pkSmoke, 0.6, 2.0, 7.0,
    Vector3(0.45, 0.42, 0.4)));
  { Hot core right behind the rocket }
  FParticles.Add(TQuakeParticle.Create(FParent, Pos, TVector3.Zero, pkFireball, 0.12, 2.5, 1.0,
    Vector3(1.0, 0.7, 0.2)));
end;

procedure TQuakeParticleManager.SpawnGrenadeTrail(const Pos: TVector3);
begin
  if FParent = nil then
    Exit;
  FParticles.Add(TQuakeParticle.Create(FParent, Pos,
    Vector3((Random - 0.5) * 6, 6, (Random - 0.5) * 6), pkSmoke, 0.45, 1.5, 4.0,
    Vector3(0.35, 0.35, 0.35)));
end;

procedure TQuakeParticleManager.SpawnNailTrail(const Pos: TVector3);
begin
  if FParent = nil then
    Exit;
  FParticles.Add(TQuakeParticle.Create(FParent, Pos, TVector3.Zero, pkTeleport, 0.15, 0.8, 0.2,
    Vector3(0.55, 0.45, 1.0)));
end;

procedure TQuakeParticleManager.SpawnTrail(const Pos, Color: TVector3);
begin
  if FParent = nil then
    Exit;
  FParticles.Add(TQuakeParticle.Create(FParent, Pos, TVector3.Zero, pkTeleport, 0.25, 1.5, 0.3, Color));
end;

procedure TQuakeParticleManager.SpawnBloodTrail(const Pos: TVector3);
begin
  if FParent = nil then
    Exit;
  FParticles.Add(TQuakeParticle.Create(FParent, Pos,
    Vector3((Random - 0.5) * 20, 0, (Random - 0.5) * 20), pkBlood, 0.5, 1.6, 0.6,
    Vector3(0.6, 0.02, 0.02)));
end;

procedure TQuakeParticleManager.SpawnPuff(const Pos, Normal: TVector3);
var
  I: Integer;
begin
  if Assigned(OnEffect) then
    OnEffect('puff', Pos, Normal);
  if FParent = nil then
    Exit;
  for I := 1 to 3 do
    FParticles.Add(TQuakeParticle.Create(FParent, Pos,
      Normal * (60 + Random * 60) + Vector3((Random - 0.5) * 60, (Random - 0.5) * 60, (Random - 0.5) * 60),
      pkSparks, 0.25 + Random * 0.15, 1.0, 0.3, Vector3(0.9, 0.8, 0.5)));
  FParticles.Add(TQuakeParticle.Create(FParent, Pos, Normal * 15 + Vector3(0, 15, 0), pkSmoke,
    0.35, 1.5, 4.0, Vector3(0.45, 0.45, 0.45)));
end;

initialization
  Particles := TQuakeParticleManager.Create;

finalization
  FreeAndNil(Particles);
end.
