{ Quake 1 Alias MDL (version 6) model loader and scene builder. }
unit QuakeMdl;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, Math,
  CastleVectors, CastleScene, CastleTransform, X3DNodes, CastleLog,
  CastleImages, CastleUtils, CastleRenderOptions,
  QuakePak, QuakePalette, QuakeLight;

type
  { Single triangle in MDL }
  TMdlTriangle = record
    FacesFront: Integer;
    Vertices: array[0..2] of Integer;
  end;

  { Texture coordinate per vertex }
  TMdlTexCoord = record
    OnSeam: Integer;
    S, T: Integer;
  end;

  { Single frame vertex positions }
  TMdlFrame = class
  public
    Name: String;
    Coords: TVector3List;
    Normals: TVector3List;
    constructor Create;
    destructor Destroy; override;
  end;

  TMdlFrameList = specialize TObjectList<TMdlFrame>;

  { Range of keyframes forming one animation (QuakeC $frame groups) }
  TMdlSequence = record
    First: Integer;
    Count: Integer;
    Loop: Boolean;
  end;

  { Quake 1 Alias MDL model }
  TQuakeMdl = class
  private
    FModelName: String;
    FNumSkins: Integer;
    FFlags: Cardinal;
    FSkinWidth: Integer;
    FSkinHeight: Integer;
    FNumVerts: Integer;
    FNumTris: Integer;
    FSkinImageIds: TStringList;
    FTriangles: array of TMdlTriangle;
    FTexCoords: array of TMdlTexCoord;
    FFrames: TMdlFrameList;
    FIndices: TInt32List;
    FBaseUVs: TVector2List;
  public
    constructor Create(const AModelName: String);
    destructor Destroy; override;

    { Load MDL from stream }
    function LoadFromStream(const Stream: TStream): Boolean;

    { Create a new TCastleScene displaying this model }
    function CreateScene(const SkinIndex: Integer = 0): TCastleScene;

    { Set active animation frame on an existing scene }
    procedure ApplyFrame(const Scene: TCastleScene; const FrameIndex: Integer);

    { Show a pose interpolated between two keyframes (Blend 0 = FrameA, 1 = FrameB) }
    procedure ApplyLerp(const Scene: TCastleScene; const FrameA, FrameB: Integer;
      const Blend: Single);

    { Sequence of Count frames starting at First, or the first frame alone
      when the model does not have these frames (e.g. a replacement model). }
    function Sequence(const First, Count: Integer; const Loop: Boolean): TMdlSequence;

    { Find frame index by name prefix, e.g. "stand", "walk", "attack" }
    function FindFrame(const NamePrefix: String): Integer;
    function GetFrameCount: Integer; inline;

    property ModelName: String read FModelName;
    property FrameCount: Integer read GetFrameCount;
    property Frames: TMdlFrameList read FFrames;
    property SkinCount: Integer read FNumSkins;
    { EF_ROCKET, EF_GRENADE, EF_GIB, EF_ROTATE... from the header }
    property Flags: Cardinal read FFlags;
  end;

  { Plays a TMdlSequence on one scene, interpolating between keyframes
    (like r_lerpmodels in later Quake engines) instead of snapping 10 times a second. }
  TMdlAnimator = class
  private
    FMdl: TQuakeMdl;
    FScene: TCastleScene;
    FSequence: TMdlSequence;
    FTime: Single;
    FLastA, FLastB: Integer;
    FLastBlend: Single;
  public
    { Keyframes per second; Quake animates monsters and weapons at 10 Hz }
    FramesPerSecond: Single;
    { When False, the pose snaps to whole keyframes (cheaper: the mesh changes
      only 10 times a second), like the original renderer. }
    Interpolate: Boolean;
    constructor Create(const AMdl: TQuakeMdl; const AScene: TCastleScene);
    { Start a sequence. When it is already playing, it continues unless Restart. }
    procedure Play(const Seq: TMdlSequence; const Restart: Boolean = False);
    { Advance time and update the scene pose }
    procedure Update(const SecondsPassed: Single);
    { True when a non-looping sequence reached its last frame }
    function Finished: Boolean;
    { Index of the current keyframe within the sequence (0 = first) }
    function FrameIndex: Integer;
    property Sequence: TMdlSequence read FSequence;
  end;

  TQuakeMdlCache = specialize TObjectDictionary<String, TQuakeMdl>;

  { Model manager / cache }
  TQuakeMdlManager = class
  private
    FCache: TQuakeMdlCache;
  public
    constructor Create;
    destructor Destroy; override;

    { Get or load model from PAK, e.g. "progs/armor.mdl", "progs/soldier.mdl" }
    function GetModel(const APath: String): TQuakeMdl;
  end;

var
  MdlManager: TQuakeMdlManager;

implementation

type
  TMdlHeader = packed record
    Ident: array[0..3] of AnsiChar; { 'IDPO' }
    Version: Cardinal;              { 6 }
    Scale: TVector3;
    Origin: TVector3;
    BoundingRadius: Single;
    EyePosition: TVector3;
    NumSkins: Cardinal;
    SkinWidth: Cardinal;
    SkinHeight: Cardinal;
    NumVerts: Cardinal;
    NumTris: Cardinal;
    NumFrames: Cardinal;
    SyncType: Cardinal;
    Flags: Cardinal;
    Size: Single;
  end;

  TTriVert = packed record
    V: array[0..2] of Byte;
    LightNormalIndex: Byte;
  end;

{ TMdlFrame }

constructor TMdlFrame.Create;
begin
  inherited Create;
  Coords := TVector3List.Create;
  Normals := TVector3List.Create;
end;

destructor TMdlFrame.Destroy;
begin
  Coords.Free;
  Normals.Free;
  inherited Destroy;
end;

{ TQuakeMdl }

constructor TQuakeMdl.Create(const AModelName: String);
begin
  inherited Create;
  FModelName := AModelName;
  FSkinImageIds := TStringList.Create;
  FFrames := TMdlFrameList.Create(True);
  FIndices := TInt32List.Create;
  FBaseUVs := TVector2List.Create;
end;

destructor TQuakeMdl.Destroy;
begin
  FSkinImageIds.Free;
  FFrames.Free;
  FIndices.Free;
  FBaseUVs.Free;
  inherited Destroy;
end;

function TQuakeMdl.GetFrameCount: Integer;
begin
  Result := FFrames.Count;
end;

function TQuakeMdl.LoadFromStream(const Stream: TStream): Boolean;
var
  Hdr: TMdlHeader;
  I, J, K: Integer;
  SkinGroup: Cardinal;
  NbSkins: Cardinal;
  SkinBuf: array of Byte;
  SkinSize: Integer;
  ImgId: String;
  Img: TRGBAlphaImage;
  Tri: TMdlTriangle;
  Tc: TMdlTexCoord;
  FrameType: Cardinal;
  BBoxMin, BBoxMax: TTriVert;
  FrameName: array[0..15] of AnsiChar;
  NameStr: String;
  VertBuf: array of TTriVert;
  Frame: TMdlFrame;
  VPos: TVector3;
  NbGroupFrames: Cardinal;
  U, V: Single;
begin
  Result := False;
  if Stream.Size < SizeOf(TMdlHeader) then
    Exit;

  Stream.ReadBuffer(Hdr, SizeOf(TMdlHeader));
  if (Hdr.Ident[0] <> 'I') or (Hdr.Ident[1] <> 'D') or
     (Hdr.Ident[2] <> 'P') or (Hdr.Ident[3] <> 'O') or
     (Hdr.Version <> 6) then
  begin
    WritelnWarning('QuakeMdl', 'Invalid MDL file "%s"', [FModelName]);
    Exit;
  end;

  FNumSkins := Hdr.NumSkins;
  FFlags := Hdr.Flags;
  FSkinWidth := Hdr.SkinWidth;
  FSkinHeight := Hdr.SkinHeight;
  FNumVerts := Hdr.NumVerts;
  FNumTris := Hdr.NumTris;

  SkinSize := FSkinWidth * FSkinHeight;
  SetLength(SkinBuf, SkinSize);

  { Read skins }
  for I := 0 to FNumSkins - 1 do
  begin
    Stream.ReadBuffer(SkinGroup, 4);
    if SkinGroup = 0 then
    begin
      Stream.ReadBuffer(SkinBuf[0], SkinSize);
      ImgId := 'mdl/' + FModelName + '/skin' + IntToStr(I);
      FSkinImageIds.Add(ImgId);
      if Palette.HasPalette and (SkinSize > 0) then
      begin
        Img := Palette.DecodeIndexed(@SkinBuf[0], FSkinWidth, FSkinHeight, 255);
        Palette.CacheImage(ImgId, Img);
      end;
    end else
    begin
      Stream.ReadBuffer(NbSkins, 4);
      Stream.Seek(NbSkins * 4, soFromCurrent); { skip time intervals }
      for J := 0 to NbSkins - 1 do
      begin
        Stream.ReadBuffer(SkinBuf[0], SkinSize);
        if J = 0 then
        begin
          ImgId := 'mdl/' + FModelName + '/skin' + IntToStr(I);
          FSkinImageIds.Add(ImgId);
          if Palette.HasPalette and (SkinSize > 0) then
          begin
            Img := Palette.DecodeIndexed(@SkinBuf[0], FSkinWidth, FSkinHeight, 255);
            Palette.CacheImage(ImgId, Img);
          end;
        end;
      end;
    end;
  end;

  { Read texture coordinates }
  SetLength(FTexCoords, FNumVerts);
  for I := 0 to FNumVerts - 1 do
  begin
    Stream.ReadBuffer(Tc.OnSeam, 4);
    Stream.ReadBuffer(Tc.S, 4);
    Stream.ReadBuffer(Tc.T, 4);
    FTexCoords[I] := Tc;

    U := (Tc.S + 0.5) / Max(1, FSkinWidth);
    V := 1.0 - (Tc.T + 0.5) / Max(1, FSkinHeight);
    FBaseUVs.Add(Vector2(U, V));
  end;

  { Read triangles }
  SetLength(FTriangles, FNumTris);
  for I := 0 to FNumTris - 1 do
  begin
    Stream.ReadBuffer(Tri.FacesFront, 4);
    Stream.ReadBuffer(Tri.Vertices[0], 12);
    FTriangles[I] := Tri;

    FIndices.Add(Tri.Vertices[0]);
    FIndices.Add(Tri.Vertices[1]);
    FIndices.Add(Tri.Vertices[2]);
  end;

  { Read frames }
  SetLength(VertBuf, FNumVerts);
  for I := 0 to Hdr.NumFrames - 1 do
  begin
    Stream.ReadBuffer(FrameType, 4);
    if FrameType = 0 then
    begin
      Stream.ReadBuffer(BBoxMin, SizeOf(TTriVert));
      Stream.ReadBuffer(BBoxMax, SizeOf(TTriVert));
      Stream.ReadBuffer(FrameName[0], 16);
      NameStr := LowerCase(Trim(PAnsiChar(@FrameName[0])));

      Stream.ReadBuffer(VertBuf[0], FNumVerts * SizeOf(TTriVert));

      Frame := TMdlFrame.Create;
      Frame.Name := NameStr;
      for J := 0 to FNumVerts - 1 do
      begin
        VPos := Vector3(
          VertBuf[J].V[0] * Hdr.Scale[0] + Hdr.Origin[0],
          VertBuf[J].V[1] * Hdr.Scale[1] + Hdr.Origin[1],
          VertBuf[J].V[2] * Hdr.Scale[2] + Hdr.Origin[2]);
        Frame.Coords.Add(QuakeToCge(VPos));
      end;
      FFrames.Add(Frame);
    end else
    begin
      Stream.ReadBuffer(NbGroupFrames, 4);
      Stream.ReadBuffer(BBoxMin, SizeOf(TTriVert));
      Stream.ReadBuffer(BBoxMax, SizeOf(TTriVert));
      Stream.Seek(NbGroupFrames * 4, soFromCurrent); { skip times }

      for K := 0 to NbGroupFrames - 1 do
      begin
        Stream.ReadBuffer(BBoxMin, SizeOf(TTriVert));
        Stream.ReadBuffer(BBoxMax, SizeOf(TTriVert));
        Stream.ReadBuffer(FrameName[0], 16);
        NameStr := LowerCase(Trim(PAnsiChar(@FrameName[0])));

        Stream.ReadBuffer(VertBuf[0], FNumVerts * SizeOf(TTriVert));

        Frame := TMdlFrame.Create;
        Frame.Name := NameStr;
        for J := 0 to FNumVerts - 1 do
        begin
          VPos := Vector3(
            VertBuf[J].V[0] * Hdr.Scale[0] + Hdr.Origin[0],
            VertBuf[J].V[1] * Hdr.Scale[1] + Hdr.Origin[1],
            VertBuf[J].V[2] * Hdr.Scale[2] + Hdr.Origin[2]);
          Frame.Coords.Add(QuakeToCge(VPos));
        end;
        FFrames.Add(Frame);
      end;
    end;
  end;

  Result := (FFrames.Count > 0) and (FNumTris > 0);
end;

function TQuakeMdl.CreateScene(const SkinIndex: Integer): TCastleScene;
var
  Root: TX3DRootNode;
  Shape: TShapeNode;
  Geom: TIndexedTriangleSetNode;
  CoordNode: TCoordinateNode;
  TexCoordNode: TTextureCoordinateNode;
  App: TAppearanceNode;
  UnlitMat: TUnlitMaterialNode;
  TexNode: TImageTextureNode;
  TexProps: TTexturePropertiesNode;
  SkinId: String;
  NormalNode: TNormalNode;
  FlatNormals: TVector3List;
  I: Integer;
begin
  Result := TCastleScene.Create(nil);
  if FFrames.Count = 0 then
    Exit;

  Root := TX3DRootNode.Create;
  Shape := TShapeNode.Create;

  CoordNode := TCoordinateNode.Create;
  CoordNode.SetPoint(FFrames[0].Coords);

  TexCoordNode := TTextureCoordinateNode.Create;
  TexCoordNode.SetPoint(FBaseUVs);

  Geom := TIndexedTriangleSetNode.Create;
  Geom.Coord := CoordNode;
  Geom.TexCoord := TexCoordNode;
  Geom.SetIndex(FIndices);
  Geom.Solid := False; { two-sided for weapons and cape ribbons }

  { Models are unlit, so normals are not used. Give a constant normal per
    vertex: otherwise the engine regenerates smooth normals each time
    the animation changes the vertices. }
  NormalNode := TNormalNode.Create;
  FlatNormals := TVector3List.Create;
  try
    FlatNormals.Count := FNumVerts;
    for I := 0 to FNumVerts - 1 do
      FlatNormals.L[I] := Vector3(0, 1, 0);
    NormalNode.SetVector(FlatNormals);
  finally
    FlatNormals.Free;
  end;
  Geom.Normal := NormalNode;

  App := TAppearanceNode.Create;
  UnlitMat := TUnlitMaterialNode.Create;
  UnlitMat.EmissiveColor := Vector3(1, 1, 1);
  App.Material := UnlitMat;

  if (SkinIndex >= 0) and (SkinIndex < FSkinImageIds.Count) then
    SkinId := FSkinImageIds[SkinIndex]
  else if FSkinImageIds.Count > 0 then
    SkinId := FSkinImageIds[0]
  else
    SkinId := '';

  if SkinId <> '' then
  begin
    TexProps := TTexturePropertiesNode.Create;
    TexProps.MagnificationFilter := magNearest;
    TexProps.MinificationFilter := minNearestMipmapLinear;

    TexNode := TImageTextureNode.Create;
    TexNode.SetUrl(['quaketex:/' + SkinId]);
    TexNode.TextureProperties := TexProps;
    App.Texture := TexNode;
  end;

  Shape.Geometry := Geom;
  Shape.Appearance := App;
  Root.AddChildren(Shape);

  Result.Load(Root, True);
  { Bounding box collisions, like Quake entity hulls. A precise triangle
    octree would have to be rebuilt every time the animated mesh changes. }
  Result.PreciseCollisions := False;
  Result.Collides := True;
end;

procedure TQuakeMdl.ApplyFrame(const Scene: TCastleScene; const FrameIndex: Integer);
var
  Shape: TShapeNode;
  Geom: TIndexedTriangleSetNode;
  CoordNode: TCoordinateNode;
  Idx: Integer;
begin
  if (Scene = nil) or (Scene.RootNode = nil) or (FFrames.Count = 0) then
    Exit;

  Idx := FrameIndex mod FFrames.Count;
  if Idx < 0 then Idx := 0;

  Shape := Scene.RootNode.FindNode(TShapeNode, '') as TShapeNode;
  if (Shape <> nil) and (Shape.Geometry is TIndexedTriangleSetNode) then
  begin
    Geom := TIndexedTriangleSetNode(Shape.Geometry);
    if Geom.Coord is TCoordinateNode then
    begin
      CoordNode := TCoordinateNode(Geom.Coord);
      CoordNode.SetPoint(FFrames[Idx].Coords);
    end;
  end;
end;

procedure TQuakeMdl.ApplyLerp(const Scene: TCastleScene; const FrameA, FrameB: Integer;
  const Blend: Single);
var
  Shape: TShapeNode;
  Geom: TIndexedTriangleSetNode;
  CoordNode: TCoordinateNode;
  A, B: TVector3List;
  Points: TVector3List;
  I: Integer;
begin
  if (Scene = nil) or (Scene.RootNode = nil) or (FFrames.Count = 0) then
    Exit;
  if (Blend <= 0) or (FrameA = FrameB) then
  begin
    ApplyFrame(Scene, FrameA);
    Exit;
  end;
  if Blend >= 1 then
  begin
    ApplyFrame(Scene, FrameB);
    Exit;
  end;

  Shape := Scene.RootNode.FindNode(TShapeNode, '') as TShapeNode;
  if (Shape = nil) or not (Shape.Geometry is TIndexedTriangleSetNode) then
    Exit;
  Geom := TIndexedTriangleSetNode(Shape.Geometry);
  if not (Geom.Coord is TCoordinateNode) then
    Exit;
  CoordNode := TCoordinateNode(Geom.Coord);

  A := FFrames[EnsureRange(FrameA, 0, FFrames.Count - 1)].Coords;
  B := FFrames[EnsureRange(FrameB, 0, FFrames.Count - 1)].Coords;
  Points := TVector3List.Create;
  try
    Points.Count := A.Count;
    for I := 0 to A.Count - 1 do
      Points.L[I] := A.L[I] + (B.L[I] - A.L[I]) * Blend;
    CoordNode.SetPoint(Points);
  finally
    Points.Free;
  end;
end;

function TQuakeMdl.Sequence(const First, Count: Integer; const Loop: Boolean): TMdlSequence;
begin
  if (First >= 0) and (Count > 0) and (First + Count <= FFrames.Count) then
  begin
    Result.First := First;
    Result.Count := Count;
  end else
  begin
    Result.First := 0;
    Result.Count := 1;
  end;
  Result.Loop := Loop;
end;

{ TMdlAnimator }

constructor TMdlAnimator.Create(const AMdl: TQuakeMdl; const AScene: TCastleScene);
begin
  inherited Create;
  FMdl := AMdl;
  FScene := AScene;
  FramesPerSecond := 10.0;
  Interpolate := True;
  FSequence.First := 0;
  FSequence.Count := 1;
  FSequence.Loop := True;
  FLastA := -1;
end;

procedure TMdlAnimator.Play(const Seq: TMdlSequence; const Restart: Boolean);
begin
  if Restart or (Seq.First <> FSequence.First) or (Seq.Count <> FSequence.Count) or
     (Seq.Loop <> FSequence.Loop) then
  begin
    FSequence := Seq;
    FTime := 0;
  end;
end;

function TMdlAnimator.Finished: Boolean;
begin
  Result := (not FSequence.Loop) and (FTime * FramesPerSecond >= FSequence.Count - 1);
end;

function TMdlAnimator.FrameIndex: Integer;
begin
  if FSequence.Count <= 0 then
    Exit(0);
  Result := Trunc(FTime * FramesPerSecond);
  if FSequence.Loop then
    Result := Result mod FSequence.Count
  else
    Result := Min(Result, FSequence.Count - 1);
end;

procedure TMdlAnimator.Update(const SecondsPassed: Single);
var
  Pos, Blend: Single;
  A, B: Integer;
begin
  if (FMdl = nil) or (FScene = nil) or (FSequence.Count <= 0) then
    Exit;

  FTime := FTime + SecondsPassed;
  if FSequence.Loop then
    FTime := FloatModulo(FTime, FSequence.Count / FramesPerSecond);
  Pos := FTime * FramesPerSecond;
  if FSequence.Loop then
  begin
    Pos := FloatModulo(Pos, FSequence.Count);
    A := Min(Trunc(Pos), FSequence.Count - 1);
    B := (A + 1) mod FSequence.Count;
  end else
  begin
    Pos := Min(Pos, FSequence.Count - 1);
    A := Trunc(Pos);
    B := Min(A + 1, FSequence.Count - 1);
  end;
  if (A = B) or not Interpolate then
    Blend := 0
  else
    Blend := Pos - A;

  { Off-screen (frustum culled) models keep their animation time but
    do not need a new pose; they catch up on the frame they are seen again. }
  if not FScene.WasVisible then
    Exit;

  A := FSequence.First + A;
  B := FSequence.First + B;
  { Avoid re-uploading an unchanged pose (single-frame idle, finished death) }
  if (A = FLastA) and (B = FLastB) and SameValue(Blend, FLastBlend, 0.001) then
    Exit;
  FLastA := A;
  FLastB := B;
  FLastBlend := Blend;
  FMdl.ApplyLerp(FScene, A, B, Blend);
end;

function TQuakeMdl.FindFrame(const NamePrefix: String): Integer;
var
  I: Integer;
  Target: String;
begin
  Target := LowerCase(NamePrefix);
  for I := 0 to FFrames.Count - 1 do
    if Pos(Target, FFrames[I].Name) = 1 then
      Exit(I);
  Result := 0;
end;

{ TQuakeMdlManager }

constructor TQuakeMdlManager.Create;
begin
  inherited Create;
  FCache := TQuakeMdlCache.Create([doOwnsValues]);
end;

destructor TQuakeMdlManager.Destroy;
begin
  FCache.Free;
  inherited Destroy;
end;

function TQuakeMdlManager.GetModel(const APath: String): TQuakeMdl;
var
  NormPath, Key: String;
  Stream: TMemoryStream;
begin
  NormPath := LowerCase(APath);
  Key := ChangeFileExt(ExtractFileName(NormPath), '');

  if FCache.TryGetValue(Key, Result) then
    Exit;

  Stream := Pak.GetStream(NormPath);
  if Stream = nil then
  begin
    WritelnWarning('QuakeMdl', 'Model "%s" not found in PAK', [NormPath]);
    Exit(nil);
  end;

  try
    Result := TQuakeMdl.Create(Key);
    if Result.LoadFromStream(Stream) then
    begin
      FCache.Add(Key, Result);
      WritelnLog('QuakeMdl', 'Loaded model "%s": %d frames, %d skins',
        [Key, Result.FrameCount, Result.SkinCount]);
    end else
    begin
      Result.Free;
      Result := nil;
    end;
  finally
    Stream.Free;
  end;
end;

initialization
  MdlManager := TQuakeMdlManager.Create;

finalization
  FreeAndNil(MdlManager);
end.
