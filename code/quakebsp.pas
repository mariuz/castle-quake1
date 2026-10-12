{ Quake 1 BSP map parser: version 29 and the BSP2 / 2PSB formats of the
  larger community maps (32-bit indexes in place of the 16-bit ones). }
unit QuakeBsp;

{$mode objfpc}{$H+}
{$modeswitch nestedprocvars}

interface

uses
  SysUtils, Classes, Generics.Collections, Math,
  CastleVectors, CastleImages, CastleLog,
  QuakePak, QuakePalette;

const
  BSP_VERSION = 29;
  { BSP2 ('BSP2', float node / leaf bounds) and the older 2PSB (BSP2RMQ, short bounds) }
  BSP2_VERSION_BSP2 = $32505342;
  BSP2_VERSION_2PSB = $42535032;

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

  { Nodes, leaves, clipnodes, edges and faces as loaded: the widest of the
    BSP29, 2PSB and BSP2 layouts, which are converted to these }
  TBSPNode = record
    PlaneId: LongInt;
    Children: array[0..1] of LongInt; { >= 0: node index, < 0: -(leaf index + 1) }
    Mins: array[0..2] of Single;
    Maxs: array[0..2] of Single;
    FirstFace: LongInt;
    NumFaces: LongInt;
  end;

  TBSPLeaf = record
    Contents: LongInt;
    VisOfs: LongInt;
    Mins: array[0..2] of Single;
    Maxs: array[0..2] of Single;
    FirstMarkSurface: LongInt;
    NumMarkSurfaces: LongInt;
    AmbientLevel: array[0..3] of Byte;
  end;

  TBSPClipNode = record
    PlaneId: LongInt;
    Children: array[0..1] of LongInt; { >= 0: clipnode index, < 0: CONTENTS_xxx }
  end;

  { Collision hull (hull_t): 0 = point, 1 = player-sized box, 2 = large box }
  TQuakeHull = record
    ClipNodes: array of TBSPClipNode;
    FirstClipNode: Integer;
    ClipMins, ClipMaxs: TVector3; { box size this hull is expanded for }
  end;

  { Result of a hull trace (trace_t), Quake coordinates }
  TQuakeTrace = record
    AllSolid: Boolean;   { the whole move was inside solid }
    StartSolid: Boolean; { the start point was inside solid }
    InOpen, InWater: Boolean;
    Fraction: Single;    { 1.0 = moved the full distance }
    EndPos: TVector3;
    PlaneNormal: TVector3;
    PlaneDist: Single;
    Entity: Integer;     { set by callers: what was hit }
  end;

  TBSPEdge = record
    V0: LongWord;
    V1: LongWord;
  end;

  TBSPTexInfo = packed record
    VecS: TVector4;
    VecT: TVector4;
    Miptex: LongInt;
    Flags: LongInt;
  end;

  TBSPFace = record
    PlaneId: LongInt;
    Side: LongInt;
    FirstEdge: LongInt;
    NumEdges: LongInt;
    TexInfoId: LongInt;
    Styles: array[0..3] of Byte; { lightstyles of the lightmaps, 255 = none }
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

const
  SPAWNFLAG_NOT_EASY = 256;
  SPAWNFLAG_NOT_MEDIUM = 512;
  SPAWNFLAG_NOT_HARD = 1024;

{ ED_LoadFromFile: the entity is removed in single player at this skill
  (0 easy, 1 normal, 2 hard, 3 nightmare) }
function EntityNotInSkill(const Ent: TQuakeEntity; const Skill: Integer): Boolean;

type

  TBSPPlaneArray = array of TBSPPlane;
  TVector3Array = array of TVector3;
  TBSPEdgeArray = array of TBSPEdge;
  TSurfEdgeArray = array of LongInt;
  TBSPTexInfoArray = array of TBSPTexInfo;
  TBSPFaceArray = array of TBSPFace;
  TBSPModelArray = array of TBSPModel;
  TBSPNodeArray = array of TBSPNode;
  TBSPLeafArray = array of TBSPLeaf;
  TBSPMarkSurfaceArray = array of LongInt;
  TBSPFormat = (bfBsp29, bfBsp2, bf2psb);

  { Loaded Quake 1 BSP map }
  TQuakeBsp = class
  private
    FMapName: String;
    FFormat: TBSPFormat;
    FPlanes: TBSPPlaneArray;
    FVertices: TVector3Array;
    FEdges: TBSPEdgeArray;
    FSurfEdges: TSurfEdgeArray;
    FTexInfos: TBSPTexInfoArray;
    FFaces: TBSPFaceArray;
    FModels: TBSPModelArray;
    FNodes: TBSPNodeArray;
    FLeaves: TBSPLeafArray;
    FMarkSurfaces: TBSPMarkSurfaceArray;
    FVisData: array of Byte;
    FHulls: array[0..2] of TQuakeHull;
    FTraceRoot: Integer;
    FMiptexes: specialize TObjectList<TQuakeMiptex>;
    FLightmaps: PByte;
    FLightmapsSize: Cardinal;
    FLitData: PByte;
    FEntitiesText: String;
    FEntities: TQuakeEntityList;
    function GetFaceCount: Integer; inline;
    function GetModelCount: Integer; inline;
    function ParseEntities(const Text: String): TQuakeEntityList;
    procedure MakeHulls(const RawClipNodes: array of TBSPClipNode);
    function RecursiveHullCheck(const HullIdx, Num: Integer; const P1F, P2F: Single;
      const P1, P2: TVector3; var Trace: TQuakeTrace): Boolean;
    procedure ParseMiptexLump(const Data: PByte; const Size: Cardinal);
    procedure CacheSkyLayers(const Mip: TQuakeMiptex);
  public
    constructor Create;
    destructor Destroy; override;

    { Load map from PAK, e.g. "maps/start.bsp" or "maps/e1m1.bsp" }
    function LoadFromPak(const AMapPath: String): Boolean;

    { Read maps/<name>.lit next to the map (LoadFromPak does it) }
    procedure LoadLit(const LitPath: String);

    { Load a map from a stream holding the whole .bsp file (BSP29, BSP2 or
      2PSB); AMapPath is for the name and the log }
    function LoadFromStream(const Stream: TMemoryStream; const AMapPath: String): Boolean;

    { Get vertex position for given face and local index (0 .. Face.NumEdges - 1) }
    function GetFaceVertex(const FaceIdx, VertIdx: Integer): TVector3;

    { Get texture UV coordinates for given vertex and TexInfo }
    function GetFaceTexCoord(const Vert: TVector3; const TexInfoIdx: Integer): TVector2;

    { Face vertex count }
    function GetFaceVertexCount(const FaceIdx: Integer): Integer;

    { Get face plane normal }
    function GetFaceNormal(const FaceIdx: Integer): TVector3;

    { Index of the world leaf containing a point in Quake coordinates (Mod_PointInLeaf),
      -1 when the map has no BSP tree }
    function PointLeaf(const QuakePoint: TVector3): Integer;

    { Potentially visible set: True when leaf ToLeaf is in the PVS of leaf
      FromLeaf (Mod_LeafPVS). Maps without visibility data see everything. }
    function LeafVisible(const FromLeaf, ToLeaf: Integer): Boolean;

    { The PVS row of a leaf decompressed into Bits (Mod_LeafPVS): bit
      (L - 1) of Bits[(L - 1) div 8] is set when leaf L is visible.
      False, with Bits untouched, when the map has no visibility data
      for the leaf (it then sees everything). }
    function LeafPVS(const Leaf: Integer; var Bits: TBytes): Boolean;

    { Number of leaves in the world PVS rows (the world model's visleafs) }
    function VisLeafCount: Integer;

    { True when a box (Quake coordinates) touches a world leaf whose bit is
      set in Bits (a PVS row): SV_FindTouchedLeafs against a PVS }
    function BoxInPvs(const Mins, Maxs: TVector3; const Bits: TBytes): Boolean;

    { SV_FatPVS: the PVS rows of every leaf within 8 units of Org, OR-ed
      into Bits. False when one of them has no visibility data (or Org is
      outside the map): then everything is visible. }
    function FatPvs(const Org: TVector3; var Bits: TBytes): Boolean;

    { Contents of a point in a collision hull, starting at clipnode Num (SV_HullPointContents) }
    function HullPointContents(const HullIdx, Num: Integer; const P: TVector3): Integer;

    { Trace a box (sized for the hull) from Start to Stop through the hull of
      a BSP model (0 = world, others = brush entities), offset by Offset
      (SV_ClipMoveToEntity). Quake coordinates. }
    function TraceHull(const HullIdx, ModelIdx: Integer; const Offset, Start, Stop: TVector3): TQuakeTrace;

    { Hull index matching a box size, like SV_HullForEntity: 0 for points,
      1 for player sized boxes, 2 for larger ones }
    function HullForSize(const Mins, Maxs: TVector3): Integer;

    { Box mins a hull was expanded for (hull_t.clip_mins) }
    function HullClipMins(const HullIdx: Integer): TVector3;

    { Contents (CONTENTS_xxx) of the world leaf containing a point in Quake coordinates }
    function PointContents(const QuakePoint: TVector3): Integer;

    { Same as PointContents, for a point in CGE coordinates }
    function PointContentsCge(const CgePoint: TVector3): Integer;

    { Find entity by classname }
    function FindEntity(const AClassName: String): TQuakeEntity;

    { Find all entities matching classname }
    function FindEntities(const AClassName: String): TQuakeEntityList;

    property MapName: String read FMapName;
    { The file format the map was loaded from }
    property Format: TBSPFormat read FFormat;
    property Faces: TBSPFaceArray read FFaces;
    property FaceCount: Integer read GetFaceCount;
    property Models: TBSPModelArray read FModels;
    property ModelCount: Integer read GetModelCount;
    property Miptexes: specialize TObjectList<TQuakeMiptex> read FMiptexes;
    property Entities: TQuakeEntityList read FEntities;
    property Lightmaps: PByte read FLightmaps;
    property LightmapsSize: Cardinal read FLightmapsSize;
    { Colored lightmaps from maps/<name>.lit (QLIT version 1: three bytes,
      RGB, for each byte of Lightmaps); nil without a .lit file }
    property LitData: PByte read FLitData;
    property TexInfos: TBSPTexInfoArray read FTexInfos;
    property Leaves: TBSPLeafArray read FLeaves;
    property Nodes: TBSPNodeArray read FNodes;
    property Planes: TBSPPlaneArray read FPlanes;
    { Face indexes listed by the leaves (Leaf.FirstMarkSurface, NumMarkSurfaces) }
    property MarkSurfaces: TBSPMarkSurfaceArray read FMarkSurfaces;
  end;

implementation

function EntityNotInSkill(const Ent: TQuakeEntity; const Skill: Integer): Boolean;
var
  Flags: Integer;
begin
  Flags := Ent.SpawnFlags;
  case Skill of
    0: Result := (Flags and SPAWNFLAG_NOT_EASY) <> 0;
    1: Result := (Flags and SPAWNFLAG_NOT_MEDIUM) <> 0;
    else Result := (Flags and SPAWNFLAG_NOT_HARD) <> 0;
  end;
end;

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
  if FLitData <> nil then
    FreeMem(FLitData);
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
      { World textures carry the fullbright mask in their alpha channel }
      Img := Palette.DecodeIndexed(Mip.Pixels, Mip.Width, Mip.Height, -1, True);
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
begin
  Result := False;
  Stream := Pak.GetStream(AMapPath);
  if Stream = nil then
  begin
    WritelnWarning('QuakeBsp', 'Map "%s" not found in PAK', [AMapPath]);
    Exit;
  end;
  try
    Result := LoadFromStream(Stream, AMapPath);
  finally
    Stream.Free;
  end;
  if Result then
    LoadLit(ChangeFileExt(AMapPath, '.lit'));
end;

procedure TQuakeBsp.LoadLit(const LitPath: String);
var
  Stream: TMemoryStream;
  Magic: array[0..3] of AnsiChar;
  Version: LongInt;
begin
  if FLitData <> nil then
  begin
    FreeMem(FLitData);
    FLitData := nil;
  end;
  if (FLightmapsSize = 0) or not Pak.FileExists(LitPath) then
    Exit;
  Stream := Pak.GetStream(LitPath);
  if Stream = nil then
    Exit;
  try
    if Stream.Size < 8 then
      Exit;
    Stream.ReadBuffer(Magic, 4);
    Stream.ReadBuffer(Version, 4);
    if (Magic <> 'QLIT') or (Version <> 1) then
    begin
      WritelnWarning('QuakeBsp', '"%s" is not a QLIT version 1 file, ignored', [LitPath]);
      Exit;
    end;
    if Stream.Size - 8 < Int64(FLightmapsSize) * 3 then
    begin
      WritelnWarning('QuakeBsp', '"%s" has %d bytes of light for %d lightmap bytes (needs three each), ignored',
        [LitPath, Stream.Size - 8, FLightmapsSize]);
      Exit;
    end;
    GetMem(FLitData, FLightmapsSize * 3);
    Stream.ReadBuffer(FLitData^, FLightmapsSize * 3);
    WritelnLog('QuakeBsp', 'Colored lightmaps from "%s"', [LitPath]);
  finally
    Stream.Free;
  end;
end;

const
  BSPFormatNames: array[TBSPFormat] of String = ('BSP29', 'BSP2', '2PSB');

type
  { The on-disk layouts converted by LoadFromStream }
  TBSP29Node = packed record
    PlaneId: LongInt;
    Children: array[0..1] of Word;
    Mins, Maxs: array[0..2] of SmallInt;
    FirstFace, NumFaces: Word;
  end;
  TBSP2PSBNode = packed record
    PlaneId: LongInt;
    Children: array[0..1] of LongInt;
    Mins, Maxs: array[0..2] of SmallInt;
    FirstFace, NumFaces: LongWord;
  end;
  TBSP2Node = packed record
    PlaneId: LongInt;
    Children: array[0..1] of LongInt;
    Mins, Maxs: array[0..2] of Single;
    FirstFace, NumFaces: LongWord;
  end;
  TBSP29Leaf = packed record
    Contents, VisOfs: LongInt;
    Mins, Maxs: array[0..2] of SmallInt;
    FirstMarkSurface, NumMarkSurfaces: Word;
    AmbientLevel: array[0..3] of Byte;
  end;
  TBSP2PSBLeaf = packed record
    Contents, VisOfs: LongInt;
    Mins, Maxs: array[0..2] of SmallInt;
    FirstMarkSurface, NumMarkSurfaces: LongWord;
    AmbientLevel: array[0..3] of Byte;
  end;
  TBSP2Leaf = packed record
    Contents, VisOfs: LongInt;
    Mins, Maxs: array[0..2] of Single;
    FirstMarkSurface, NumMarkSurfaces: LongWord;
    AmbientLevel: array[0..3] of Byte;
  end;
  TBSP29ClipNode = packed record
    PlaneId: LongInt;
    Children: array[0..1] of SmallInt;
  end;
  TBSP2ClipNode = packed record
    PlaneId: LongInt;
    Children: array[0..1] of LongInt;
  end;
  TBSP29Edge = packed record
    V0, V1: Word;
  end;
  TBSP2Edge = packed record
    V0, V1: LongWord;
  end;
  TBSP29Face = packed record
    PlaneId: Word;
    Side: SmallInt;
    FirstEdge: LongInt;
    NumEdges: SmallInt;
    TexInfoId: SmallInt;
    Styles: array[0..3] of Byte;
    LightmapOffset: LongInt;
  end;
  TBSP2Face = packed record
    PlaneId, Side, FirstEdge, NumEdges, TexInfoId: LongInt;
    Styles: array[0..3] of Byte;
    LightmapOffset: LongInt;
  end;

function TQuakeBsp.LoadFromStream(const Stream: TMemoryStream; const AMapPath: String): Boolean;
var
  Hdr: TBSPHeader;
  Count: Integer;
  RawClipNodes: array of TBSPClipNode;
  Base: PByte;

  { Start of a lump and its number of Size byte records; 0 when the lump
    lies outside the file }
  function Lump(const Index, Size: Integer; out P: PByte): Integer;
  begin
    P := nil;
    Result := 0;
    if (Hdr.Lumps[Index].Length = 0) or
       (Int64(Hdr.Lumps[Index].Offset) + Hdr.Lumps[Index].Length > Stream.Size) then
      Exit;
    P := Base + Hdr.Lumps[Index].Offset;
    Result := Hdr.Lumps[Index].Length div Cardinal(Size);
  end;

  { A BSP29 node child: an unsigned short below the node count is a node,
    else a leaf counted down from 65535 (QuakeSpasm, for maps with more
    than 32767 nodes) }
  function Bsp29Child(const Child: Word; const NodeCount: Integer): LongInt;
  begin
    if Child < NodeCount then
      Result := Child
    else
      Result := LongInt(Child) - 65536;
  end;

  procedure ReadNodes;
  var
    I, J: Integer;
    P: PByte;
    N29: ^TBSP29Node;
    N2P: ^TBSP2PSBNode;
    N2: ^TBSP2Node;
  begin
    case FFormat of
      bfBsp29: Count := Lump(LUMP_NODES, SizeOf(TBSP29Node), P);
      bf2psb: Count := Lump(LUMP_NODES, SizeOf(TBSP2PSBNode), P);
      else Count := Lump(LUMP_NODES, SizeOf(TBSP2Node), P);
    end;
    SetLength(FNodes, Count);
    for I := 0 to Count - 1 do
      case FFormat of
        bfBsp29:
          begin
            N29 := Pointer(P + I * SizeOf(TBSP29Node));
            FNodes[I].PlaneId := N29^.PlaneId;
            for J := 0 to 1 do
              FNodes[I].Children[J] := Bsp29Child(N29^.Children[J], Count);
            for J := 0 to 2 do
            begin
              FNodes[I].Mins[J] := N29^.Mins[J];
              FNodes[I].Maxs[J] := N29^.Maxs[J];
            end;
            FNodes[I].FirstFace := N29^.FirstFace;
            FNodes[I].NumFaces := N29^.NumFaces;
          end;
        bf2psb:
          begin
            N2P := Pointer(P + I * SizeOf(TBSP2PSBNode));
            FNodes[I].PlaneId := N2P^.PlaneId;
            for J := 0 to 1 do
              FNodes[I].Children[J] := N2P^.Children[J];
            for J := 0 to 2 do
            begin
              FNodes[I].Mins[J] := N2P^.Mins[J];
              FNodes[I].Maxs[J] := N2P^.Maxs[J];
            end;
            FNodes[I].FirstFace := N2P^.FirstFace;
            FNodes[I].NumFaces := N2P^.NumFaces;
          end;
        else
          begin
            N2 := Pointer(P + I * SizeOf(TBSP2Node));
            FNodes[I].PlaneId := N2^.PlaneId;
            for J := 0 to 1 do
              FNodes[I].Children[J] := N2^.Children[J];
            for J := 0 to 2 do
            begin
              FNodes[I].Mins[J] := N2^.Mins[J];
              FNodes[I].Maxs[J] := N2^.Maxs[J];
            end;
            FNodes[I].FirstFace := N2^.FirstFace;
            FNodes[I].NumFaces := N2^.NumFaces;
          end;
      end;
  end;

  procedure ReadLeaves;
  var
    I, J: Integer;
    P: PByte;
    L29: ^TBSP29Leaf;
    L2P: ^TBSP2PSBLeaf;
    L2: ^TBSP2Leaf;
  begin
    case FFormat of
      bfBsp29: Count := Lump(LUMP_LEAVES, SizeOf(TBSP29Leaf), P);
      bf2psb: Count := Lump(LUMP_LEAVES, SizeOf(TBSP2PSBLeaf), P);
      else Count := Lump(LUMP_LEAVES, SizeOf(TBSP2Leaf), P);
    end;
    SetLength(FLeaves, Count);
    for I := 0 to Count - 1 do
      case FFormat of
        bfBsp29:
          begin
            L29 := Pointer(P + I * SizeOf(TBSP29Leaf));
            FLeaves[I].Contents := L29^.Contents;
            FLeaves[I].VisOfs := L29^.VisOfs;
            for J := 0 to 2 do
            begin
              FLeaves[I].Mins[J] := L29^.Mins[J];
              FLeaves[I].Maxs[J] := L29^.Maxs[J];
            end;
            FLeaves[I].FirstMarkSurface := L29^.FirstMarkSurface;
            FLeaves[I].NumMarkSurfaces := L29^.NumMarkSurfaces;
            FLeaves[I].AmbientLevel := L29^.AmbientLevel;
          end;
        bf2psb:
          begin
            L2P := Pointer(P + I * SizeOf(TBSP2PSBLeaf));
            FLeaves[I].Contents := L2P^.Contents;
            FLeaves[I].VisOfs := L2P^.VisOfs;
            for J := 0 to 2 do
            begin
              FLeaves[I].Mins[J] := L2P^.Mins[J];
              FLeaves[I].Maxs[J] := L2P^.Maxs[J];
            end;
            FLeaves[I].FirstMarkSurface := L2P^.FirstMarkSurface;
            FLeaves[I].NumMarkSurfaces := L2P^.NumMarkSurfaces;
            FLeaves[I].AmbientLevel := L2P^.AmbientLevel;
          end;
        else
          begin
            L2 := Pointer(P + I * SizeOf(TBSP2Leaf));
            FLeaves[I].Contents := L2^.Contents;
            FLeaves[I].VisOfs := L2^.VisOfs;
            for J := 0 to 2 do
            begin
              FLeaves[I].Mins[J] := L2^.Mins[J];
              FLeaves[I].Maxs[J] := L2^.Maxs[J];
            end;
            FLeaves[I].FirstMarkSurface := L2^.FirstMarkSurface;
            FLeaves[I].NumMarkSurfaces := L2^.NumMarkSurfaces;
            FLeaves[I].AmbientLevel := L2^.AmbientLevel;
          end;
      end;
  end;

  procedure ReadFacesEdgesMarks;
  var
    I, J: Integer;
    P: PByte;
    F29: ^TBSP29Face;
    F2: ^TBSP2Face;
    E29: ^TBSP29Edge;
    E2: ^TBSP2Edge;
  begin
    if FFormat = bfBsp29 then
    begin
      Count := Lump(LUMP_FACES, SizeOf(TBSP29Face), P);
      SetLength(FFaces, Count);
      for I := 0 to Count - 1 do
      begin
        F29 := Pointer(P + I * SizeOf(TBSP29Face));
        FFaces[I].PlaneId := F29^.PlaneId;
        FFaces[I].Side := F29^.Side;
        FFaces[I].FirstEdge := F29^.FirstEdge;
        FFaces[I].NumEdges := F29^.NumEdges;
        FFaces[I].TexInfoId := F29^.TexInfoId;
        FFaces[I].Styles := F29^.Styles;
        FFaces[I].LightmapOffset := F29^.LightmapOffset;
      end;
      Count := Lump(LUMP_EDGES, SizeOf(TBSP29Edge), P);
      SetLength(FEdges, Count);
      for I := 0 to Count - 1 do
      begin
        E29 := Pointer(P + I * SizeOf(TBSP29Edge));
        FEdges[I].V0 := E29^.V0;
        FEdges[I].V1 := E29^.V1;
      end;
      Count := Lump(LUMP_MARKSURFACES, SizeOf(Word), P);
      SetLength(FMarkSurfaces, Count);
      for I := 0 to Count - 1 do
        FMarkSurfaces[I] := PWord(P + I * SizeOf(Word))^;
    end else
    begin
      Count := Lump(LUMP_FACES, SizeOf(TBSP2Face), P);
      SetLength(FFaces, Count);
      for I := 0 to Count - 1 do
      begin
        F2 := Pointer(P + I * SizeOf(TBSP2Face));
        FFaces[I].PlaneId := F2^.PlaneId;
        FFaces[I].Side := F2^.Side;
        FFaces[I].FirstEdge := F2^.FirstEdge;
        FFaces[I].NumEdges := F2^.NumEdges;
        FFaces[I].TexInfoId := F2^.TexInfoId;
        FFaces[I].Styles := F2^.Styles;
        FFaces[I].LightmapOffset := F2^.LightmapOffset;
      end;
      Count := Lump(LUMP_EDGES, SizeOf(TBSP2Edge), P);
      SetLength(FEdges, Count);
      for I := 0 to Count - 1 do
      begin
        E2 := Pointer(P + I * SizeOf(TBSP2Edge));
        FEdges[I].V0 := E2^.V0;
        FEdges[I].V1 := E2^.V1;
      end;
      Count := Lump(LUMP_MARKSURFACES, SizeOf(LongWord), P);
      SetLength(FMarkSurfaces, Count);
      for I := 0 to Count - 1 do
        FMarkSurfaces[I] := PLongWord(P + I * SizeOf(LongWord))^;
    end;
  end;

  procedure ReadClipNodes;
  var
    I, J: Integer;
    P: PByte;
    C29: ^TBSP29ClipNode;
    C2: ^TBSP2ClipNode;
  begin
    if FFormat = bfBsp29 then
    begin
      Count := Lump(LUMP_CLIPNODES, SizeOf(TBSP29ClipNode), P);
      SetLength(RawClipNodes, Count);
      for I := 0 to Count - 1 do
      begin
        C29 := Pointer(P + I * SizeOf(TBSP29ClipNode));
        RawClipNodes[I].PlaneId := C29^.PlaneId;
        { Unsigned below the clipnode count, else contents (QuakeSpasm) }
        for J := 0 to 1 do
          if Word(C29^.Children[J]) < Count then
            RawClipNodes[I].Children[J] := Word(C29^.Children[J])
          else
            RawClipNodes[I].Children[J] := LongInt(Word(C29^.Children[J])) - 65536;
      end;
    end else
    begin
      Count := Lump(LUMP_CLIPNODES, SizeOf(TBSP2ClipNode), P);
      SetLength(RawClipNodes, Count);
      for I := 0 to Count - 1 do
      begin
        C2 := Pointer(P + I * SizeOf(TBSP2ClipNode));
        RawClipNodes[I].PlaneId := C2^.PlaneId;
        RawClipNodes[I].Children[0] := C2^.Children[0];
        RawClipNodes[I].Children[1] := C2^.Children[1];
      end;
    end;
  end;

  { Lumps whose layout is the same in every format }
  procedure ReadPlain(const Index, Size: Integer; const Dest: Pointer; out ACount: Integer);
  var
    P: PByte;
  begin
    ACount := Lump(Index, Size, P);
    if ACount > 0 then
      Move(P^, Dest^, ACount * Size);
  end;

  function PlainCount(const Index, Size: Integer): Integer;
  var
    P: PByte;
  begin
    Result := Lump(Index, Size, P);
  end;

begin
  Result := False;
  FMapName := ChangeFileExt(ExtractFileName(AMapPath), '');
  if Stream.Size < SizeOf(TBSPHeader) then
    Exit;
  Stream.Position := 0;
  Stream.ReadBuffer(Hdr, SizeOf(TBSPHeader));
  case Hdr.Version of
    BSP_VERSION: FFormat := bfBsp29;
    BSP2_VERSION_BSP2: FFormat := bfBsp2;
    BSP2_VERSION_2PSB: FFormat := bf2psb;
    else
    begin
      WritelnWarning('QuakeBsp', 'Map "%s" has an unsupported BSP version %d (expected %d, BSP2 or 2PSB)',
        [AMapPath, Hdr.Version, BSP_VERSION]);
      Exit;
    end;
  end;
  Base := PByte(Stream.Memory);

  { 0: Entities }
  if (Hdr.Lumps[LUMP_ENTITIES].Length > 0) and
     (Int64(Hdr.Lumps[LUMP_ENTITIES].Offset) + Hdr.Lumps[LUMP_ENTITIES].Length <= Stream.Size) then
  begin
    SetLength(FEntitiesText, Hdr.Lumps[LUMP_ENTITIES].Length);
    Move((Base + Hdr.Lumps[LUMP_ENTITIES].Offset)^, FEntitiesText[1], Hdr.Lumps[LUMP_ENTITIES].Length);
    FEntities.Free;
    FEntities := ParseEntities(FEntitiesText);
    WritelnLog('QuakeBsp', 'Parsed %d entities', [FEntities.Count]);
  end;

  { 1: Planes, 3: Vertices, 13: SurfEdges, 6: TexInfo, 14: Models }
  SetLength(FPlanes, PlainCount(LUMP_PLANES, SizeOf(TBSPPlane)));
  ReadPlain(LUMP_PLANES, SizeOf(TBSPPlane), Pointer(FPlanes), Count);
  SetLength(FVertices, PlainCount(LUMP_VERTICES, SizeOf(TVector3)));
  ReadPlain(LUMP_VERTICES, SizeOf(TVector3), Pointer(FVertices), Count);
  SetLength(FSurfEdges, PlainCount(LUMP_SURFEDGES, SizeOf(LongInt)));
  ReadPlain(LUMP_SURFEDGES, SizeOf(LongInt), Pointer(FSurfEdges), Count);
  SetLength(FTexInfos, PlainCount(LUMP_TEXINFO, SizeOf(TBSPTexInfo)));
  ReadPlain(LUMP_TEXINFO, SizeOf(TBSPTexInfo), Pointer(FTexInfos), Count);
  SetLength(FModels, PlainCount(LUMP_MODELS, SizeOf(TBSPModel)));
  ReadPlain(LUMP_MODELS, SizeOf(TBSPModel), Pointer(FModels), Count);

  { 5: Nodes, 10: Leaves, 7: Faces, 12: Edges, 11: MarkSurfaces in the
    format's own layout }
  ReadNodes;
  ReadLeaves;
  ReadFacesEdgesMarks;

  { 4: Visibility (run-length compressed PVS rows) }
  SetLength(FVisData, PlainCount(LUMP_VISIBILITY, 1));
  ReadPlain(LUMP_VISIBILITY, 1, Pointer(FVisData), Count);

  { 9: ClipNodes, and the collision hulls built from them }
  ReadClipNodes;
  MakeHulls(RawClipNodes);

  { 8: Lightmaps (a .lit of an earlier map no longer applies) }
  if FLitData <> nil then
  begin
    FreeMem(FLitData);
    FLitData := nil;
  end;
  if FLightmaps <> nil then
  begin
    FreeMem(FLightmaps);
    FLightmaps := nil;
  end;
  FLightmapsSize := PlainCount(LUMP_LIGHTMAPS, 1);
  if FLightmapsSize > 0 then
  begin
    GetMem(FLightmaps, FLightmapsSize);
    ReadPlain(LUMP_LIGHTMAPS, 1, FLightmaps, Count);
  end;

  { 2: Miptex }
  FMiptexes.Clear;
  if PlainCount(LUMP_MIPTEX, 1) > 0 then
    ParseMiptexLump(Base + Hdr.Lumps[LUMP_MIPTEX].Offset, Hdr.Lumps[LUMP_MIPTEX].Length);

  WritelnLog('QuakeBsp', 'Loaded map "%s" (%s): %d faces, %d vertices, %d textures, %d models',
    [AMapPath, BSPFormatNames[FFormat], Length(FFaces), Length(FVertices), FMiptexes.Count, Length(FModels)]);
  Result := True;
end;

function TQuakeBsp.LeafVisible(const FromLeaf, ToLeaf: Integer): Boolean;
var
  Ofs, RowBytes, ByteIdx, OutByte, Run: Integer;
begin
  Result := True;
  if (FromLeaf <= 0) or (ToLeaf <= 0) or (FromLeaf >= Length(FLeaves)) or
     (ToLeaf >= Length(FLeaves)) then
    Exit;
  Ofs := FLeaves[FromLeaf].VisOfs;
  if (Ofs < 0) or (Ofs >= Length(FVisData)) then
    Exit;
  { Bit (leaf - 1) of the row; runs of zero bytes are stored as 0, count }
  RowBytes := (Length(FLeaves) - 1 + 7) div 8;
  ByteIdx := (ToLeaf - 1) div 8;
  OutByte := 0;
  while (OutByte < RowBytes) and (Ofs < Length(FVisData)) do
  begin
    if FVisData[Ofs] <> 0 then
    begin
      if OutByte = ByteIdx then
        Exit((FVisData[Ofs] and (1 shl ((ToLeaf - 1) and 7))) <> 0);
      Inc(Ofs);
      Inc(OutByte);
    end else
    begin
      if Ofs + 1 >= Length(FVisData) then
        Break;
      Run := FVisData[Ofs + 1];
      if ByteIdx < OutByte + Run then
        Exit(False);
      Inc(OutByte, Run);
      Inc(Ofs, 2);
    end;
  end;
  Result := False;
end;

function TQuakeBsp.VisLeafCount: Integer;
begin
  Result := Length(FLeaves) - 1;
  if (Length(FModels) > 0) and (FModels[0].VisLeafs > 0) and (FModels[0].VisLeafs < Result) then
    Result := FModels[0].VisLeafs;
  if Result < 0 then
    Result := 0;
end;

{ Calls Visit for each world leaf a box touches, until it returns True;
  the result is True when a visit did }
type
  TLeafVisitor = function(const Leaf: Integer): Boolean is nested;

function WalkBoxLeaves(const Bsp: TQuakeBsp; const Mins, Maxs: TVector3; const Visit: TLeafVisitor): Boolean;

  function Walk(Node: Integer): Boolean;
  var
    Plane: TBSPPlane;
    Front, Back: Single;
    I: Integer;
  begin
    while Node >= 0 do
    begin
      if (Node >= Length(Bsp.Nodes)) or (Bsp.Nodes[Node].PlaneId < 0) or
         (Bsp.Nodes[Node].PlaneId >= Length(Bsp.Planes)) then
        Exit(Visit(-1));
      Plane := Bsp.Planes[Bsp.Nodes[Node].PlaneId];
      { BoxOnPlaneSide: the box corners nearest and farthest along the normal }
      Front := -Plane.Dist;
      Back := -Plane.Dist;
      for I := 0 to 2 do
        if Plane.Normal[I] >= 0 then
        begin
          Front := Front + Plane.Normal[I] * Maxs[I];
          Back := Back + Plane.Normal[I] * Mins[I];
        end else
        begin
          Front := Front + Plane.Normal[I] * Mins[I];
          Back := Back + Plane.Normal[I] * Maxs[I];
        end;
      if Back >= 0 then
        Node := Bsp.Nodes[Node].Children[0]
      else if Front < 0 then
        Node := Bsp.Nodes[Node].Children[1]
      else
      begin
        if Walk(Bsp.Nodes[Node].Children[0]) then
          Exit(True);
        Node := Bsp.Nodes[Node].Children[1];
      end;
    end;
    Result := Visit(-(Node + 1));
  end;

begin
  if (Bsp.ModelCount = 0) or (Length(Bsp.Nodes) = 0) then
    Exit(Visit(-1));
  Result := Walk(Bsp.Models[0].HeadNodes[0]);
end;

function TQuakeBsp.BoxInPvs(const Mins, Maxs: TVector3; const Bits: TBytes): Boolean;

  function InRow(const Leaf: Integer): Boolean;
  begin
    { A broken tree (-1) counts as visible }
    if Leaf < 0 then
      Exit(True);
    Result := (Leaf >= 1) and ((Leaf - 1) div 8 < Length(Bits)) and
      ((Bits[(Leaf - 1) div 8] and (1 shl ((Leaf - 1) and 7))) <> 0);
  end;

begin
  Result := WalkBoxLeaves(Self, Mins, Maxs, @InRow);
end;

function TQuakeBsp.FatPvs(const Org: TVector3; var Bits: TBytes): Boolean;
var
  Row: TBytes;
  AllVisible: Boolean;
  RowBytes: Integer;

  function AddRow(const Leaf: Integer): Boolean;
  var
    I: Integer;
  begin
    Result := False;
    if Leaf = 0 then
      Exit; { solid }
    if (Leaf < 0) or not LeafPVS(Leaf, Row) then
    begin
      AllVisible := True;
      Exit(True);
    end;
    for I := 0 to Min(Length(Row), Length(Bits)) - 1 do
      Bits[I] := Bits[I] or Row[I];
    Bits[(Leaf - 1) div 8] := Bits[(Leaf - 1) div 8] or (1 shl ((Leaf - 1) and 7));
  end;

begin
  RowBytes := (VisLeafCount + 7) div 8;
  SetLength(Bits, RowBytes);
  if RowBytes > 0 then
    FillChar(Bits[0], RowBytes, 0);
  AllVisible := False;
  WalkBoxLeaves(Self, Org - Vector3(8, 8, 8), Org + Vector3(8, 8, 8), @AddRow);
  Result := not AllVisible;
end;

function TQuakeBsp.LeafPVS(const Leaf: Integer; var Bits: TBytes): Boolean;
var
  Ofs, RowBytes, OutByte: Integer;
begin
  Result := False;
  if (Leaf <= 0) or (Leaf >= Length(FLeaves)) then
    Exit;
  Ofs := FLeaves[Leaf].VisOfs;
  if (Ofs < 0) or (Ofs >= Length(FVisData)) then
    Exit;
  RowBytes := (VisLeafCount + 7) div 8;
  if Length(Bits) <> RowBytes then
    SetLength(Bits, RowBytes);
  if RowBytes > 0 then
    FillChar(Bits[0], RowBytes, 0);
  { Runs of zero bytes are stored as 0, count }
  OutByte := 0;
  while (OutByte < RowBytes) and (Ofs < Length(FVisData)) do
  begin
    if FVisData[Ofs] <> 0 then
    begin
      Bits[OutByte] := FVisData[Ofs];
      Inc(Ofs);
      Inc(OutByte);
    end else
    begin
      if Ofs + 1 >= Length(FVisData) then
        Break;
      Inc(OutByte, FVisData[Ofs + 1]);
      Inc(Ofs, 2);
    end;
  end;
  Result := True;
end;

function TQuakeBsp.PointLeaf(const QuakePoint: TVector3): Integer;
var
  NodeIdx: Integer;
  Plane: TBSPPlane;
  D: Single;
begin
  Result := -1;
  if (Length(FModels) = 0) or (Length(FNodes) = 0) then
    Exit;

  NodeIdx := FModels[0].HeadNodes[0];
  { Walk the BSP tree (Mod_PointInLeaf / SV_HullPointContents on hull 0) }
  while NodeIdx >= 0 do
  begin
    if (NodeIdx >= Length(FNodes)) or (FNodes[NodeIdx].PlaneId < 0) or
       (FNodes[NodeIdx].PlaneId >= Length(FPlanes)) then
      Exit;
    Plane := FPlanes[FNodes[NodeIdx].PlaneId];
    D := TVector3.DotProduct(Plane.Normal, QuakePoint) - Plane.Dist;
    if D >= 0 then
      NodeIdx := FNodes[NodeIdx].Children[0]
    else
      NodeIdx := FNodes[NodeIdx].Children[1];
  end;

  NodeIdx := -(NodeIdx + 1);
  if NodeIdx < Length(FLeaves) then
    Result := NodeIdx;
end;

function TQuakeBsp.PointContents(const QuakePoint: TVector3): Integer;
var
  Leaf: Integer;
begin
  Leaf := PointLeaf(QuakePoint);
  if Leaf >= 0 then
    Result := FLeaves[Leaf].Contents
  else
    Result := CONTENTS_EMPTY;
end;

const
  { Keep traces this far from planes, against float precision (DIST_EPSILON) }
  DistEpsilon = 0.03125;

procedure TQuakeBsp.MakeHulls(const RawClipNodes: array of TBSPClipNode);
var
  I, J, Child: Integer;
begin
  { Hull 0 is made from the drawing nodes, with leaf contents as terminals (Mod_MakeHull0) }
  SetLength(FHulls[0].ClipNodes, Length(FNodes));
  for I := 0 to High(FNodes) do
  begin
    FHulls[0].ClipNodes[I].PlaneId := FNodes[I].PlaneId;
    for J := 0 to 1 do
    begin
      Child := FNodes[I].Children[J];
      if Child < 0 then
      begin
        Child := -(Child + 1);
        if Child < Length(FLeaves) then
          FHulls[0].ClipNodes[I].Children[J] := FLeaves[Child].Contents
        else
          FHulls[0].ClipNodes[I].Children[J] := CONTENTS_SOLID;
      end else
        FHulls[0].ClipNodes[I].Children[J] := Child;
    end;
  end;
  FHulls[0].ClipMins := TVector3.Zero;
  FHulls[0].ClipMaxs := TVector3.Zero;

  { Hulls 1 and 2 share the clipnodes lump, each model has its own head node }
  for I := 1 to 2 do
  begin
    SetLength(FHulls[I].ClipNodes, Length(RawClipNodes));
    for J := 0 to High(RawClipNodes) do
      FHulls[I].ClipNodes[J] := RawClipNodes[J];
  end;
  FHulls[1].ClipMins := Vector3(-16, -16, -24);
  FHulls[1].ClipMaxs := Vector3(16, 16, 32);
  FHulls[2].ClipMins := Vector3(-32, -32, -24);
  FHulls[2].ClipMaxs := Vector3(32, 32, 64);
end;

function TQuakeBsp.HullForSize(const Mins, Maxs: TVector3): Integer;
var
  SizeX: Single;
begin
  SizeX := Maxs.X - Mins.X;
  if SizeX < 3 then
    Result := 0
  else if SizeX <= 32 then
    Result := 1
  else
    Result := 2;
end;

function TQuakeBsp.HullClipMins(const HullIdx: Integer): TVector3;
begin
  Result := FHulls[HullIdx].ClipMins;
end;

function TQuakeBsp.HullPointContents(const HullIdx, Num: Integer; const P: TVector3): Integer;
var
  N: Integer;
  Node: TBSPClipNode;
  Plane: TBSPPlane;
begin
  N := Num;
  while N >= 0 do
  begin
    if N >= Length(FHulls[HullIdx].ClipNodes) then
      Exit(CONTENTS_SOLID);
    Node := FHulls[HullIdx].ClipNodes[N];
    if (Node.PlaneId < 0) or (Node.PlaneId >= Length(FPlanes)) then
      Exit(CONTENTS_SOLID);
    Plane := FPlanes[Node.PlaneId];
    if TVector3.DotProduct(Plane.Normal, P) - Plane.Dist < 0 then
      N := Node.Children[1]
    else
      N := Node.Children[0];
  end;
  Result := N;
end;

function TQuakeBsp.RecursiveHullCheck(const HullIdx, Num: Integer; const P1F, P2F: Single;
  const P1, P2: TVector3; var Trace: TQuakeTrace): Boolean;
var
  Node: TBSPClipNode;
  Plane: TBSPPlane;
  T1, T2, Frac, MidF: Single;
  Mid: TVector3;
  Side: Integer;
begin
  { Port of SV_RecursiveHullCheck. Returns False when the trace was stopped. }
  if Num < 0 then
  begin
    if Num <> CONTENTS_SOLID then
    begin
      Trace.AllSolid := False;
      if Num = CONTENTS_EMPTY then
        Trace.InOpen := True
      else
        Trace.InWater := True;
    end else
      Trace.StartSolid := True;
    Exit(True);
  end;

  if (Num >= Length(FHulls[HullIdx].ClipNodes)) then
    Exit(True);
  Node := FHulls[HullIdx].ClipNodes[Num];
  Plane := FPlanes[Node.PlaneId];
  T1 := TVector3.DotProduct(Plane.Normal, P1) - Plane.Dist;
  T2 := TVector3.DotProduct(Plane.Normal, P2) - Plane.Dist;

  if (T1 >= 0) and (T2 >= 0) then
    Exit(RecursiveHullCheck(HullIdx, Node.Children[0], P1F, P2F, P1, P2, Trace));
  if (T1 < 0) and (T2 < 0) then
    Exit(RecursiveHullCheck(HullIdx, Node.Children[1], P1F, P2F, P1, P2, Trace));

  { Put the crosspoint DistEpsilon units on the near side }
  if T1 < 0 then
    Frac := (T1 + DistEpsilon) / (T1 - T2)
  else
    Frac := (T1 - DistEpsilon) / (T1 - T2);
  Frac := EnsureRange(Frac, 0, 1);
  MidF := P1F + (P2F - P1F) * Frac;
  Mid := P1 + (P2 - P1) * Frac;
  if T1 < 0 then
    Side := 1
  else
    Side := 0;

  { Move up to the node }
  if not RecursiveHullCheck(HullIdx, Node.Children[Side], P1F, MidF, P1, Mid, Trace) then
    Exit(False);

  { Go past the node }
  if HullPointContents(HullIdx, Node.Children[1 - Side], Mid) <> CONTENTS_SOLID then
    Exit(RecursiveHullCheck(HullIdx, Node.Children[1 - Side], MidF, P2F, Mid, P2, Trace));

  if Trace.AllSolid then
    Exit(False); { never got out of the solid area }

  { The other side of the node is solid, this is the impact point }
  if Side = 0 then
  begin
    Trace.PlaneNormal := Plane.Normal;
    Trace.PlaneDist := Plane.Dist;
  end else
  begin
    Trace.PlaneNormal := -Plane.Normal;
    Trace.PlaneDist := -Plane.Dist;
  end;

  while HullPointContents(HullIdx, FTraceRoot, Mid) = CONTENTS_SOLID do
  begin
    { Shouldn't really happen, but does occasionally }
    Frac := Frac - 0.1;
    if Frac < 0 then
    begin
      Trace.Fraction := MidF;
      Trace.EndPos := Mid;
      Exit(False);
    end;
    MidF := P1F + (P2F - P1F) * Frac;
    Mid := P1 + (P2 - P1) * Frac;
  end;

  Trace.Fraction := MidF;
  Trace.EndPos := Mid;
  Result := False;
end;

function TQuakeBsp.TraceHull(const HullIdx, ModelIdx: Integer;
  const Offset, Start, Stop: TVector3): TQuakeTrace;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Fraction := 1;
  Result.AllSolid := True;
  Result.EndPos := Stop;
  Result.Entity := -1;
  if (ModelIdx < 0) or (ModelIdx >= Length(FModels)) or
     (Length(FHulls[HullIdx].ClipNodes) = 0) then
  begin
    Result.AllSolid := False;
    Exit;
  end;

  FTraceRoot := FModels[ModelIdx].HeadNodes[HullIdx];
  RecursiveHullCheck(HullIdx, FTraceRoot, 0, 1, Start - Offset, Stop - Offset, Result);
  if Result.Fraction <> 1 then
    Result.EndPos := Result.EndPos + Offset;
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
