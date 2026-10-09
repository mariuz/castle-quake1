{ Quake 1 BSP (version 29) map parser. }
unit QuakeBsp;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections,
  CastleVectors, CastleImages, CastleLog,
  QuakePak, QuakePalette;

const
  BSP_VERSION = 29;

  LUMP_ENTITIES     = 0;
  LUMP_PLANES       = 1;
  LUMP_MIPTEX       = 2;
  LUMP_VERTICES     = 3;
  LUMP_VISIBILITY   = 4;
  LUMP_NODES        = 5;
  LUMP_TEXINFO      = 6;
  LUMP_FACES        = 7;
  LUMP_LIGHTMAPS    = 8;
  LUMP_CLIPNODES    = 9;
  LUMP_LEAVES       = 10;
  LUMP_MARKSURFACES = 11;
  LUMP_EDGES        = 12;
  LUMP_SURFEDGES    = 13;
  LUMP_MODELS       = 14;

  { Suffixes of the cached images holding the two layers of a sky miptex }
  SKY_FRONT_SUFFIX = '_front';
  SKY_BACK_SUFFIX  = '_back';
  LUMP_COUNT        = 15;

  SURF_DRAW_SKY   = $0004; { sky surface }
  SURF_DRAW_WATER = $0020; { animated/turbulent water }
  SURF_DRAW_SLIME = $0040; { slime }
  SURF_DRAW_LAVA  = $0080; { lava }

  { Leaf contents (bspfile.h) }
  CONTENTS_EMPTY = -1;
  CONTENTS_SOLID = -2;
  CONTENTS_WATER = -3;
  CONTENTS_SLIME = -4;
  CONTENTS_LAVA  = -5;
  CONTENTS_SKY   = -6;

type
  TBSPLump = packed record
    Offset: Cardinal;
    Length: Cardinal;
  end;

  TBSPHeader = packed record
    Version: Cardinal;
    Lumps: array[0..LUMP_COUNT - 1] of TBSPLump;
  end;

  TBSPPlane = packed record
    Normal: TVector3;
    Dist: Single;
    PlaneType: Cardinal;
  end;

  TBSPNode = packed record
    PlaneId: LongInt;
    Children: array[0..1] of SmallInt; { >= 0: node index, < 0: -(leaf index + 1) }
    Mins: array[0..2] of SmallInt;
    Maxs: array[0..2] of SmallInt;
    FirstFace: Word;
    NumFaces: Word;
  end;

  TBSPLeaf = packed record
    Contents: LongInt;
    VisOfs: LongInt;
    Mins: array[0..2] of SmallInt;
    Maxs: array[0..2] of SmallInt;
    FirstMarkSurface: Word;
    NumMarkSurfaces: Word;
    AmbientLevel: array[0..3] of Byte;
  end;

  TBSPEdge = packed record
    V0: Word;
    V1: Word;
  end;

  TBSPTexInfo = packed record
    VecS: TVector4;
    VecT: TVector4;
    Miptex: LongInt;
    Flags: LongInt;
  end;

  TBSPFace = packed record
    PlaneId: Word;
    Side: Word;
    FirstEdge: LongInt;
    NumEdges: SmallInt;
    TexInfoId: SmallInt;
    LightType: Byte;
    LightBase: Byte;
    Light: array[0..1] of Byte;
    LightmapOffset: LongInt;
  end;

  TBSPModel = packed record
    Mins: TVector3;
    Maxs: TVector3;
    Origin: TVector3;
    HeadNodes: array[0..3] of LongInt;
    VisLeafs: LongInt;
    FirstFace: LongInt;
    NumFaces: LongInt;
  end;

  TQuakeMiptex = class
  public
    Name: String;
    Width: Integer;
    Height: Integer;
    Offsets: array[0..3] of Cardinal;
    Pixels: PByte;
    ImageId: String;
  end;

  TQuakeEntity = class
  private
    FFields: specialize TDictionary<String, String>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure SetField(const Key, Value: String);
    function GetField(const Key: String; const Default: String = ''): String;
    function HasField(const Key: String): Boolean;
    function GetVector(const Key: String; const Default: TVector3): TVector3;
    function GetFloat(const Key: String; const Default: Single = 0): Single;
    function GetInt(const Key: String; const Default: Integer = 0): Integer;

    function ClassName: String;
    function Origin: TVector3;
    function Target: String;
    function TargetName: String;
    function Model: String;
    function Angle: Single;
    function Angles: TVector3;
    function MessageText: String;
    function Light: Single;
    function Speed: Single;
    function Sounds: Integer;
    function SpawnFlags: Integer;

    property Fields: specialize TDictionary<String, String> read FFields;
  end;

  TQuakeEntityList = specialize TObjectList<TQuakeEntity>;

  TBSPPlaneArray = array of TBSPPlane;
  TVector3Array = array of TVector3;
  TBSPEdgeArray = array of TBSPEdge;
  TSurfEdgeArray = array of LongInt;
  TBSPTexInfoArray = array of TBSPTexInfo;
  TBSPFaceArray = array of TBSPFace;
  TBSPModelArray = array of TBSPModel;
  TBSPNodeArray = array of TBSPNode;
  TBSPLeafArray = array of TBSPLeaf;

  { Loaded Quake 1 BSP map }
  TQuakeBsp = class
  private
    FMapName: String;
    FPlanes: TBSPPlaneArray;
    FVertices: TVector3Array;
    FEdges: TBSPEdgeArray;
    FSurfEdges: TSurfEdgeArray;
    FTexInfos: TBSPTexInfoArray;
    FFaces: TBSPFaceArray;
    FModels: TBSPModelArray;
    FNodes: TBSPNodeArray;
    FLeaves: TBSPLeafArray;
    FMiptexes: specialize TObjectList<TQuakeMiptex>;
    FLightmaps: PByte;
    FLightmapsSize: Cardinal;
    FEntitiesText: String;
    FEntities: TQuakeEntityList;
    function GetFaceCount: Integer; inline;
    function GetModelCount: Integer; inline;
    function ParseEntities(const Text: String): TQuakeEntityList;
    procedure ParseMiptexLump(const Data: PByte; const Size: Cardinal);
    procedure CacheSkyLayers(const Mip: TQuakeMiptex);
  public
    constructor Create;
    destructor Destroy; override;

    { Load map from PAK, e.g. "maps/start.bsp" or "maps/e1m1.bsp" }
    function LoadFromPak(const AMapPath: String): Boolean;

    { Get vertex position for given face and local index (0 .. Face.NumEdges - 1) }
    function GetFaceVertex(const FaceIdx, VertIdx: Integer): TVector3;

    { Get texture UV coordinates for given vertex and TexInfo }
    function GetFaceTexCoord(const Vert: TVector3; const TexInfoIdx: Integer): TVector2;

    { Face vertex count }
    function GetFaceVertexCount(const FaceIdx: Integer): Integer;

    { Get face plane normal }
    function GetFaceNormal(const FaceIdx: Integer): TVector3;

    { Contents (CONTENTS_xxx) of the world leaf containing a point in Quake coordinates }
    function PointContents(const QuakePoint: TVector3): Integer;

    { Same as PointContents, for a point in CGE coordinates }
    function PointContentsCge(const CgePoint: TVector3): Integer;

    { Find entity by classname }
    function FindEntity(const AClassName: String): TQuakeEntity;

    { Find all entities matching classname }
    function FindEntities(const AClassName: String): TQuakeEntityList;

    property MapName: String read FMapName;
    property Faces: TBSPFaceArray read FFaces;
    property FaceCount: Integer read GetFaceCount;
    property Models: TBSPModelArray read FModels;
    property ModelCount: Integer read GetModelCount;
    property Miptexes: specialize TObjectList<TQuakeMiptex> read FMiptexes;
    property Entities: TQuakeEntityList read FEntities;
    property Lightmaps: PByte read FLightmaps;
    property LightmapsSize: Cardinal read FLightmapsSize;
    property TexInfos: TBSPTexInfoArray read FTexInfos;
  end;

implementation

{ TQuakeEntity }

constructor TQuakeEntity.Create;
begin
  inherited Create;
  FFields := specialize TDictionary<String, String>.Create;
end;

destructor TQuakeEntity.Destroy;
begin
  FFields.Free;
  inherited Destroy;
end;

procedure TQuakeEntity.SetField(const Key, Value: String);
begin
  FFields.AddOrSetValue(LowerCase(Key), Value);
end;

function TQuakeEntity.GetField(const Key: String; const Default: String): String;
begin
  if not FFields.TryGetValue(LowerCase(Key), Result) then
    Result := Default;
end;

function TQuakeEntity.HasField(const Key: String): Boolean;
begin
  Result := FFields.ContainsKey(LowerCase(Key));
end;

function TQuakeEntity.GetVector(const Key: String; const Default: TVector3): TVector3;
var
  S, Token: String;
  P, Idx: Integer;
begin
  Result := Default;
  S := Trim(GetField(Key));
  if S = '' then
    Exit;

  Idx := 0;
  while S <> '' do
  begin
    P := Pos(' ', S);
    if P > 0 then
    begin
      Token := Copy(S, 1, P - 1);
      S := Trim(Copy(S, P + 1, Length(S)));
    end else
    begin
      Token := S;
      S := '';
    end;

    if Token <> '' then
    begin
      if Idx = 0 then Result.X := StrToFloatDef(Token, Default.X)
      else if Idx = 1 then Result.Y := StrToFloatDef(Token, Default.Y)
      else if Idx = 2 then Result.Z := StrToFloatDef(Token, Default.Z);
      Inc(Idx);
    end;
  end;
end;

function TQuakeEntity.GetFloat(const Key: String; const Default: Single): Single;
begin
  Result := StrToFloatDef(GetField(Key), Default);
end;

function TQuakeEntity.GetInt(const Key: String; const Default: Integer): Integer;
begin
  Result := StrToIntDef(GetField(Key), Default);
end;

function TQuakeEntity.ClassName: String;
begin
  Result := GetField('classname');
end;

function TQuakeEntity.Origin: TVector3;
begin
  Result := GetVector('origin', Vector3(0, 0, 0));
end;

function TQuakeEntity.Target: String;
begin
  Result := GetField('target');
end;

function TQuakeEntity.TargetName: String;
begin
  Result := GetField('targetname');
end;

function TQuakeEntity.Model: String;
begin
  Result := GetField('model');
end;

function TQuakeEntity.Angle: Single;
begin
  Result := GetFloat('angle', 0);
end;

function TQuakeEntity.Angles: TVector3;
begin
  Result := GetVector('angles', Vector3(0, Angle, 0));
end;

function TQuakeEntity.MessageText: String;
begin
  Result := GetField('message');
end;

function TQuakeEntity.Light: Single;
begin
  Result := GetFloat('light', 200);
end;

function TQuakeEntity.Speed: Single;
begin
  Result := GetFloat('speed', 100);
end;

function TQuakeEntity.Sounds: Integer;
begin
  Result := GetInt('sounds', 0);
end;

function TQuakeEntity.SpawnFlags: Integer;
begin
  Result := GetInt('spawnflags', 0);
end;

{ TQuakeBsp }

constructor TQuakeBsp.Create;
begin
  inherited Create;
  FMiptexes := specialize TObjectList<TQuakeMiptex>.Create(True);
  FEntities := TQuakeEntityList.Create(True);
  FLightmaps := nil;
  FLightmapsSize := 0;
end;

function TQuakeBsp.GetFaceCount: Integer;
begin
  Result := Length(FFaces);
end;

function TQuakeBsp.GetModelCount: Integer;
begin
  Result := Length(FModels);
end;

destructor TQuakeBsp.Destroy;
begin
  if FLightmaps <> nil then
    FreeMem(FLightmaps);
  FMiptexes.Free;
  FEntities.Free;
  inherited Destroy;
end;

function TQuakeBsp.ParseEntities(const Text: String): TQuakeEntityList;
var
  I, Len: Integer;
  CurEnt: TQuakeEntity;
  InEntity, InQuotes: Boolean;
  Key, Val, CurStr: String;
  State: (stWaiting, stKey, stValue);

  procedure FlushToken;
  begin
    if State = stKey then
    begin
      Key := CurStr;
      CurStr := '';
      State := stValue;
    end else
    if State = stValue then
    begin
      Val := CurStr;
      CurStr := '';
      if (CurEnt <> nil) and (Key <> '') then
        CurEnt.SetField(Key, Val);
      Key := '';
      Val := '';
      State := stWaiting;
    end;
  end;

begin
  Result := TQuakeEntityList.Create(True);
  Len := Length(Text);
  I := 1;
  InEntity := False;
  InQuotes := False;
  CurEnt := nil;
  CurStr := '';
  State := stWaiting;

  while I <= Len do
  begin
    case Text[I] of
      '{':
        if not InQuotes then
        begin
          InEntity := True;
          CurEnt := TQuakeEntity.Create;
          State := stWaiting;
          CurStr := '';
        end else
          CurStr := CurStr + Text[I];
      '}':
        if not InQuotes then
        begin
          if CurEnt <> nil then
          begin
            Result.Add(CurEnt);
            CurEnt := nil;
          end;
          InEntity := False;
          State := stWaiting;
        end else
          CurStr := CurStr + Text[I];
      '"':
        begin
          InQuotes := not InQuotes;
          if not InQuotes then
            FlushToken
          else
            if State = stWaiting then
              State := stKey;
        end;
      #10, #13, #9, ' ':
        if InQuotes then
          CurStr := CurStr + Text[I];
      else
        if InQuotes then
          CurStr := CurStr + Text[I];
    end;
    Inc(I);
  end;
end;

procedure TQuakeBsp.CacheSkyLayers(const Mip: TQuakeMiptex);
var
  HalfW, Y, I, Count: Integer;
  Front, Back: array of Byte;
  FrontImg: TRGBAlphaImage;
  Sum: TVector3;
  Avg, C: TVector4Byte;
begin
  { Quake sky textures are 256x128: the left half is the front (cloud) layer,
    where palette index 0 is transparent, the right half is the solid back layer
    (see R_InitSky in the original engine). }
  if (Mip.Width <> 2 * Mip.Height) or (Mip.Height <= 0) then
    Exit;
  HalfW := Mip.Width div 2;
  SetLength(Front, HalfW * Mip.Height);
  SetLength(Back, HalfW * Mip.Height);
  for Y := 0 to Mip.Height - 1 do
  begin
    Move((Mip.Pixels + Y * Mip.Width)^, Front[Y * HalfW], HalfW);
    Move((Mip.Pixels + Y * Mip.Width + HalfW)^, Back[Y * HalfW], HalfW);
  end;
  { Like GLQuake, give transparent texels the average color of the layer,
    so texture filtering does not darken the cloud edges. }
  FrontImg := Palette.DecodeIndexed(@Front[0], HalfW, Mip.Height, 0);
  Sum := TVector3.Zero;
  Count := 0;
  for I := 0 to HalfW * Mip.Height - 1 do
    if Front[I] <> 0 then
    begin
      C := Palette.Color(Front[I]);
      Sum := Sum + Vector3(C.X, C.Y, C.Z);
      Inc(Count);
    end;
  if Count > 0 then
  begin
    Avg := Vector4Byte(Round(Sum.X / Count), Round(Sum.Y / Count), Round(Sum.Z / Count), 0);
    for I := 0 to HalfW * Mip.Height - 1 do
      if Front[I] = 0 then
        PVector4Byte(FrontImg.PixelPtr(I mod HalfW, I div HalfW))^ := Avg;
  end;
  Palette.CacheImage(Mip.ImageId + SKY_FRONT_SUFFIX, FrontImg);
  Palette.CacheImage(Mip.ImageId + SKY_BACK_SUFFIX,
    Palette.DecodeIndexed(@Back[0], HalfW, Mip.Height, -1));
end;

procedure TQuakeBsp.ParseMiptexLump(const Data: PByte; const Size: Cardinal);
type
  TMiptexRaw = packed record
    Name: array[0..15] of AnsiChar;
    Width: Cardinal;
    Height: Cardinal;
    Offsets: array[0..3] of Cardinal;
  end;
var
  NumMiptex, I: Cardinal;
  Offsets: PCardinal;
  MipOff: Cardinal;
  Raw: ^TMiptexRaw;
  Mip: TQuakeMiptex;
  NameStr, ImageId: String;
  Img: TRGBAlphaImage;
begin
  if Size < 4 then
    Exit;

  NumMiptex := PCardinal(Data)^;
  Offsets := PCardinal(Data + 4);

  for I := 0 to NumMiptex - 1 do
  begin
    MipOff := Offsets[I];
    if (MipOff = $FFFFFFFF) or (MipOff >= Size) then
      Continue;

    Raw := Pointer(Data + MipOff);
    NameStr := LowerCase(Trim(PAnsiChar(@Raw^.Name[0])));
    if NameStr = '' then
      Continue;

    Mip := TQuakeMiptex.Create;
    Mip.Name := NameStr;
    Mip.Width := Raw^.Width;
    Mip.Height := Raw^.Height;
    Mip.Offsets := Raw^.Offsets;
    Mip.Pixels := Data + MipOff + Raw^.Offsets[0];

    { Cache texture image for quaketex: protocol }
    ImageId := 'map/' + FMapName + '/' + NameStr;
    Mip.ImageId := ImageId;

    if Palette.HasPalette and (Mip.Width > 0) and (Mip.Height > 0) then
    begin
      Img := Palette.DecodeIndexed(Mip.Pixels, Mip.Width, Mip.Height, -1);
      Palette.CacheImage(ImageId, Img);
      if Pos('sky', NameStr) = 1 then
        CacheSkyLayers(Mip);
    end;

    FMiptexes.Add(Mip);
  end;
end;

function TQuakeBsp.LoadFromPak(const AMapPath: String): Boolean;
var
  Stream: TMemoryStream;
  Hdr: TBSPHeader;
  Count: Integer;
begin
  Result := False;
  FMapName := ChangeFileExt(ExtractFileName(AMapPath), '');
  Stream := Pak.GetStream(AMapPath);
  if Stream = nil then
  begin
    WritelnWarning('QuakeBsp', 'Map "%s" not found in PAK', [AMapPath]);
    Exit;
  end;

  try
    if Stream.Size < SizeOf(TBSPHeader) then
      Exit;

    Stream.ReadBuffer(Hdr, SizeOf(TBSPHeader));
    if Hdr.Version <> BSP_VERSION then
    begin
      WritelnWarning('QuakeBsp', 'Map "%s" has invalid BSP version %d (expected %d)',
        [AMapPath, Hdr.Version, BSP_VERSION]);
      Exit;
    end;

    { 0: Entities }
    if Hdr.Lumps[LUMP_ENTITIES].Length > 0 then
    begin
      SetLength(FEntitiesText, Hdr.Lumps[LUMP_ENTITIES].Length);
      Stream.Position := Hdr.Lumps[LUMP_ENTITIES].Offset;
      Stream.ReadBuffer(FEntitiesText[1], Hdr.Lumps[LUMP_ENTITIES].Length);
      FEntities.Free;
      FEntities := ParseEntities(FEntitiesText);
      WritelnLog('QuakeBsp', 'Parsed %d entities', [FEntities.Count]);
    end;

    { 1: Planes }
    Count := Hdr.Lumps[LUMP_PLANES].Length div SizeOf(TBSPPlane);
    SetLength(FPlanes, Count);
    if Count > 0 then
    begin
      Stream.Position := Hdr.Lumps[LUMP_PLANES].Offset;
      Stream.ReadBuffer(FPlanes[0], Hdr.Lumps[LUMP_PLANES].Length);
    end;

    { 3: Vertices }
    Count := Hdr.Lumps[LUMP_VERTICES].Length div SizeOf(TVector3);
    SetLength(FVertices, Count);
    if Count > 0 then
    begin
      Stream.Position := Hdr.Lumps[LUMP_VERTICES].Offset;
      Stream.ReadBuffer(FVertices[0], Hdr.Lumps[LUMP_VERTICES].Length);
    end;

    { 12: Edges }
    Count := Hdr.Lumps[LUMP_EDGES].Length div SizeOf(TBSPEdge);
    SetLength(FEdges, Count);
    if Count > 0 then
    begin
      Stream.Position := Hdr.Lumps[LUMP_EDGES].Offset;
      Stream.ReadBuffer(FEdges[0], Hdr.Lumps[LUMP_EDGES].Length);
    end;

    { 13: SurfEdges }
    Count := Hdr.Lumps[LUMP_SURFEDGES].Length div SizeOf(LongInt);
    SetLength(FSurfEdges, Count);
    if Count > 0 then
    begin
      Stream.Position := Hdr.Lumps[LUMP_SURFEDGES].Offset;
      Stream.ReadBuffer(FSurfEdges[0], Hdr.Lumps[LUMP_SURFEDGES].Length);
    end;

    { 6: TexInfo }
    Count := Hdr.Lumps[LUMP_TEXINFO].Length div SizeOf(TBSPTexInfo);
    SetLength(FTexInfos, Count);
    if Count > 0 then
    begin
      Stream.Position := Hdr.Lumps[LUMP_TEXINFO].Offset;
      Stream.ReadBuffer(FTexInfos[0], Hdr.Lumps[LUMP_TEXINFO].Length);
    end;

    { 7: Faces }
    Count := Hdr.Lumps[LUMP_FACES].Length div SizeOf(TBSPFace);
    SetLength(FFaces, Count);
    if Count > 0 then
    begin
      Stream.Position := Hdr.Lumps[LUMP_FACES].Offset;
      Stream.ReadBuffer(FFaces[0], Hdr.Lumps[LUMP_FACES].Length);
    end;

    { 14: Models }
    Count := Hdr.Lumps[LUMP_MODELS].Length div SizeOf(TBSPModel);
    SetLength(FModels, Count);
    if Count > 0 then
    begin
      Stream.Position := Hdr.Lumps[LUMP_MODELS].Offset;
      Stream.ReadBuffer(FModels[0], Hdr.Lumps[LUMP_MODELS].Length);
    end;

    { 5: Nodes }
    Count := Hdr.Lumps[LUMP_NODES].Length div SizeOf(TBSPNode);
    SetLength(FNodes, Count);
    if Count > 0 then
    begin
      Stream.Position := Hdr.Lumps[LUMP_NODES].Offset;
      Stream.ReadBuffer(FNodes[0], Count * SizeOf(TBSPNode));
    end;

    { 10: Leaves }
    Count := Hdr.Lumps[LUMP_LEAVES].Length div SizeOf(TBSPLeaf);
    SetLength(FLeaves, Count);
    if Count > 0 then
    begin
      Stream.Position := Hdr.Lumps[LUMP_LEAVES].Offset;
      Stream.ReadBuffer(FLeaves[0], Count * SizeOf(TBSPLeaf));
    end;

    { 8: Lightmaps }
    if FLightmaps <> nil then
    begin
      FreeMem(FLightmaps);
      FLightmaps := nil;
    end;
    FLightmapsSize := Hdr.Lumps[LUMP_LIGHTMAPS].Length;
    if FLightmapsSize > 0 then
    begin
      GetMem(FLightmaps, FLightmapsSize);
      Stream.Position := Hdr.Lumps[LUMP_LIGHTMAPS].Offset;
      Stream.ReadBuffer(FLightmaps^, FLightmapsSize);
    end;

    { 2: Miptex }
    FMiptexes.Clear;
    if Hdr.Lumps[LUMP_MIPTEX].Length > 0 then
    begin
      Stream.Position := Hdr.Lumps[LUMP_MIPTEX].Offset;
      ParseMiptexLump(PByte(Stream.Memory) + Hdr.Lumps[LUMP_MIPTEX].Offset,
        Hdr.Lumps[LUMP_MIPTEX].Length);
    end;

    WritelnLog('QuakeBsp', 'Loaded map "%s": %d faces, %d vertices, %d textures, %d models',
      [AMapPath, Length(FFaces), Length(FVertices), FMiptexes.Count, Length(FModels)]);
    Result := True;
  finally
    Stream.Free;
  end;
end;

function TQuakeBsp.PointContents(const QuakePoint: TVector3): Integer;
var
  NodeIdx, Child: Integer;
  Plane: TBSPPlane;
  D: Single;
begin
  Result := CONTENTS_EMPTY;
  if (Length(FModels) = 0) or (Length(FNodes) = 0) then
    Exit;

  NodeIdx := FModels[0].HeadNodes[0];
  { Walk the BSP tree (SV_HullPointContents on hull 0 / Mod_PointInLeaf) }
  while NodeIdx >= 0 do
  begin
    if (NodeIdx >= Length(FNodes)) or (FNodes[NodeIdx].PlaneId < 0) or
       (FNodes[NodeIdx].PlaneId >= Length(FPlanes)) then
      Exit;
    Plane := FPlanes[FNodes[NodeIdx].PlaneId];
    D := TVector3.DotProduct(Plane.Normal, QuakePoint) - Plane.Dist;
    if D >= 0 then
      Child := FNodes[NodeIdx].Children[0]
    else
      Child := FNodes[NodeIdx].Children[1];
    NodeIdx := Child;
  end;

  NodeIdx := -(NodeIdx + 1);
  if NodeIdx < Length(FLeaves) then
    Result := FLeaves[NodeIdx].Contents;
end;

function TQuakeBsp.PointContentsCge(const CgePoint: TVector3): Integer;
begin
  Result := PointContents(Vector3(CgePoint.X, -CgePoint.Z, CgePoint.Y));
end;

function TQuakeBsp.GetFaceVertexCount(const FaceIdx: Integer): Integer;
begin
  if (FaceIdx >= 0) and (FaceIdx < Length(FFaces)) then
    Result := FFaces[FaceIdx].NumEdges
  else
    Result := 0;
end;

function TQuakeBsp.GetFaceVertex(const FaceIdx, VertIdx: Integer): TVector3;
var
  Face: TBSPFace;
  SurfEdgeIdx: LongInt;
  EdgeIdx: LongInt;
  Edge: TBSPEdge;
  VIdx: Word;
begin
  Result := Vector3(0, 0, 0);
  if (FaceIdx < 0) or (FaceIdx >= Length(FFaces)) then
    Exit;

  Face := FFaces[FaceIdx];
  SurfEdgeIdx := FSurfEdges[Face.FirstEdge + VertIdx];
  if SurfEdgeIdx >= 0 then
  begin
    Edge := FEdges[SurfEdgeIdx];
    VIdx := Edge.V0;
  end else
  begin
    Edge := FEdges[-SurfEdgeIdx];
    VIdx := Edge.V1;
  end;

  if VIdx < Length(FVertices) then
    Result := FVertices[VIdx];
end;

function TQuakeBsp.GetFaceTexCoord(const Vert: TVector3; const TexInfoIdx: Integer): TVector2;
var
  TexInfo: TBSPTexInfo;
  Mip: TQuakeMiptex;
  S, T: Single;
  Width, Height: Single;
begin
  Result := Vector2(0, 0);
  if (TexInfoIdx < 0) or (TexInfoIdx >= Length(FTexInfos)) then
    Exit;

  TexInfo := FTexInfos[TexInfoIdx];
  Width := 64;
  Height := 64;

  if (TexInfo.Miptex >= 0) and (TexInfo.Miptex < FMiptexes.Count) then
  begin
    Mip := FMiptexes[TexInfo.Miptex];
    if Mip.Width > 0 then Width := Mip.Width;
    if Mip.Height > 0 then Height := Mip.Height;
  end;

  S := (Vert[0] * TexInfo.VecS[0] + Vert[1] * TexInfo.VecS[1] + Vert[2] * TexInfo.VecS[2] + TexInfo.VecS[3]) / Width;
  T := (Vert[0] * TexInfo.VecT[0] + Vert[1] * TexInfo.VecT[1] + Vert[2] * TexInfo.VecT[2] + TexInfo.VecT[3]) / Height;

  Result := Vector2(S, 1.0 - T); { OpenGL / CGE bottom-to-top convention }
end;

function TQuakeBsp.GetFaceNormal(const FaceIdx: Integer): TVector3;
var
  Face: TBSPFace;
  Plane: TBSPPlane;
begin
  Result := Vector3(0, 1, 0);
  if (FaceIdx < 0) or (FaceIdx >= Length(FFaces)) then
    Exit;

  Face := FFaces[FaceIdx];
  if Face.PlaneId < Length(FPlanes) then
  begin
    Plane := FPlanes[Face.PlaneId];
    if Face.Side <> 0 then
      Result := -Plane.Normal
    else
      Result := Plane.Normal;
  end;
end;

function TQuakeBsp.FindEntity(const AClassName: String): TQuakeEntity;
var
  Ent: TQuakeEntity;
begin
  for Ent in FEntities do
    if SameText(Ent.ClassName, AClassName) then
      Exit(Ent);
  Result := nil;
end;

function TQuakeBsp.FindEntities(const AClassName: String): TQuakeEntityList;
var
  Ent: TQuakeEntity;
begin
  Result := TQuakeEntityList.Create(False);
  for Ent in FEntities do
    if (AClassName = '') or SameText(Ent.ClassName, AClassName) then
      Result.Add(Ent);
end;

end.
