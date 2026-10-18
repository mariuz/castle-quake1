{ Random maps: a playable level made from a seed.

  "maps/random<seed>.bsp" is in no pak: when something looks for it (a
  warp, a changelevel, a network client, a demo), the hook of
  InstallRandomMaps builds it in memory and adds it, with a .lit of colored
  light, as if a pak had it. The map loader, the renderer, the physics,
  QuakeC, demos and multiplayer all see an ordinary BSP29 level.

  The level: rooms on a grid of 64 x 64 x 16 unit cells, joined by
  corridors two cells wide along a spanning tree of the rooms plus a loop
  or two; pillars, a raised dais, wall torches and ceiling lights; monsters
  harder the further a room is from the start; weapons, ammo, health and
  armor on the way; the exit pad in the farthest room leads to
  random<seed + 1>.

  The BSP: an axis aligned k-d tree over the cells (each leaf a box of
  solid or empty cells); its faces are the solid / empty boundaries, merged
  into rectangles of up to 256 units within each node, with the T-junctions
  fixed; the clip hulls are the same kind of tree over the cells grown by
  the hull's box; no PVS (every leaf sees every leaf); lightmaps traced
  through the cells from the lights. The textures come from a map in the
  paks (start.bsp), or plain generated ones without it.

  Everything comes from the seed through an own random number generator,
  so a seed is the same map on every machine. }
unit QuakeRandomMap;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$Q-}{$R-}

interface

uses
  Classes, SysUtils, Types, Math, Generics.Collections, Generics.Defaults, CastleVectors;

type
  TRandomMapInfo = record
    Seed: LongWord;
    Rooms, Corridors, ReachableRooms: Integer;
    Monsters, Items, Lights: Integer;
    Faces, Leaves, Nodes, ClipNodes: Integer;
    { Quake coordinates of the player start and of the middle of the exit pad
      (at standing height) }
    StartOrigin, ExitOrigin: TVector3;
    StartYaw: Single;
    Textures: String;
  end;

const
  RandomMapPrefix = 'random';

{ 'random42' -> 42 }
function ParseRandomMapName(const MapName: String; out Seed: LongWord): Boolean;
function RandomMapName(const Seed: LongWord): String;
{ A seed from the clock, 1 to 999999 }
function NewRandomMapSeed: LongWord;

{ The BSP29 file of the map for Seed and its .lit; the textures come from
  the miptex lump of Donor (a BSP file, may be nil) }
function BuildRandomMap(const Seed: LongWord; const Donor: TMemoryStream;
  out Lit: TMemoryStream; out Info: TRandomMapInfo): TMemoryStream;

{ Serve maps/random<seed>.bsp (and .lit) from the pak, built on first use }
procedure InstallRandomMaps;

var
  { The last map BuildRandomMap made }
  LastRandomMapInfo: TRandomMapInfo;

implementation

uses
  CastleLog, QuakeBsp, QuakePak;

const
  GW = 36;           { columns of the grid }
  GH = 36;           { rows }
  GZ = 18;           { layers of 16 units }
  CellXY = 64;
  CellZ = 16;
  CorridorHeight = 8; { layers }
  SolidOwner = -1;
  CorridorOwner = 1000;
  MaxFaceSize = 256;

  SpecialNone = 0;
  SpecialDais = 1;
  SpecialPad = 2;

{ Random numbers ------------------------------------------------------------ }

type
  TRng = record
    State: LongWord;
    procedure Init(const Seed: LongWord);
    function Next: LongWord;
    function Below(const N: Integer): Integer;
    function Range(const Lo, Hi: Integer): Integer;
    function Chance(const Percent: Integer): Boolean;
  end;

procedure TRng.Init(const Seed: LongWord);
begin
  State := LongWord(Seed * LongWord(2654435761) + LongWord(2246822519));
  if State = 0 then
    State := 1;
  Next;
  Next;
end;

function TRng.Next: LongWord;
begin
  { xorshift32 }
  State := LongWord(State xor LongWord(State shl 13));
  State := State xor (State shr 17);
  State := LongWord(State xor LongWord(State shl 5));
  Result := State;
end;

function TRng.Below(const N: Integer): Integer;
begin
  if N <= 1 then
    Exit(0);
  Result := Integer(Next mod LongWord(N));
end;

function TRng.Range(const Lo, Hi: Integer): Integer;
begin
  if Hi <= Lo then
    Exit(Lo);
  Result := Lo + Below(Hi - Lo + 1);
end;

function TRng.Chance(const Percent: Integer): Boolean;
begin
  Result := Below(100) < Percent;
end;

{ A grid of solid / empty cells and the k-d tree over it ------------------- }

type
  TIdx3 = array[0..2] of Integer;

  TKdGrid = class
  public
    N: TIdx3;
    { Cell boundaries along each axis, N + 1 of them }
    Coords: array[0..2] of array of Single;
    Solid: array of Boolean;
    { Solid cells below and left of each corner (summed volume table) }
    Sum: array of LongInt;
    constructor Create(const NX, NY, NZ: Integer);
    function Index(const I, J, K: Integer): Integer; inline;
    function SumAt(const I, J, K: Integer): LongInt; inline;
    procedure Prepare;
    { Solid cells in [Lo, Hi) }
    function Count(const Lo, Hi: TIdx3): Integer;
  end;

  TKdNode = record
    Axis, Split: Integer;
    { >= 0: node, < 0: -(leaf + 1); [0] is the side at or above Split }
    Children: array[0..1] of Integer;
    Lo, Hi: TIdx3;
  end;

  TKdLeaf = record
    Solid: Boolean;
    Lo, Hi: TIdx3;
  end;

  TKdTree = class
  private
    procedure ChooseSplit(const Lo, Hi: TIdx3; out Axis, Split: Integer);
    function Build(const Lo, Hi: TIdx3): Integer;
  public
    Grid: TKdGrid;
    Nodes: array of TKdNode;
    NodeCount: Integer;
    Leaves: array of TKdLeaf;
    LeafCount: Integer;
    { Root: node 0 }
    constructor Create(const AGrid: TKdGrid);
  end;

constructor TKdGrid.Create(const NX, NY, NZ: Integer);
begin
  inherited Create;
  N[0] := NX;
  N[1] := NY;
  N[2] := NZ;
  SetLength(Solid, NX * NY * NZ);
  SetLength(Coords[0], NX + 1);
  SetLength(Coords[1], NY + 1);
  SetLength(Coords[2], NZ + 1);
end;

function TKdGrid.Index(const I, J, K: Integer): Integer;
begin
  Result := (K * N[1] + J) * N[0] + I;
end;

function TKdGrid.SumAt(const I, J, K: Integer): LongInt;
begin
  Result := Sum[(K * (N[1] + 1) + J) * (N[0] + 1) + I];
end;

procedure TKdGrid.Prepare;
var
  I, J, K: Integer;
begin
  SetLength(Sum, 0);
  SetLength(Sum, (N[0] + 1) * (N[1] + 1) * (N[2] + 1));
  for K := 1 to N[2] do
    for J := 1 to N[1] do
      for I := 1 to N[0] do
        Sum[(K * (N[1] + 1) + J) * (N[0] + 1) + I] := Ord(Solid[Index(I - 1, J - 1, K - 1)])
          + SumAt(I - 1, J, K) + SumAt(I, J - 1, K) + SumAt(I, J, K - 1)
          - SumAt(I - 1, J - 1, K) - SumAt(I - 1, J, K - 1) - SumAt(I, J - 1, K - 1)
          + SumAt(I - 1, J - 1, K - 1);
end;

function TKdGrid.Count(const Lo, Hi: TIdx3): Integer;
begin
  Result := SumAt(Hi[0], Hi[1], Hi[2])
    - SumAt(Lo[0], Hi[1], Hi[2]) - SumAt(Hi[0], Lo[1], Hi[2]) - SumAt(Hi[0], Hi[1], Lo[2])
    + SumAt(Lo[0], Lo[1], Hi[2]) + SumAt(Lo[0], Hi[1], Lo[2]) + SumAt(Hi[0], Lo[1], Lo[2])
    - SumAt(Lo[0], Lo[1], Lo[2]);
end;

constructor TKdTree.Create(const AGrid: TKdGrid);
var
  Lo: TIdx3;
begin
  inherited Create;
  Grid := AGrid;
  Lo[0] := 0;
  Lo[1] := 0;
  Lo[2] := 0;
  Build(Lo, Grid.N);
end;

{ Split where the solid count changes between two slabs, nearest the middle
  of the region (relative to its width); with no such place, halve the
  widest axis }
procedure TKdTree.ChooseSplit(const Lo, Hi: TIdx3; out Axis, Split: Integer);
var
  A, T, Cnt, Prev: Integer;
  SLo, SHi: TIdx3;
  W, Mid, Score, BestScore, BestW: Single;
begin
  Axis := -1;
  Split := 0;
  BestScore := 10;
  BestW := 0;
  for A := 0 to 2 do
  begin
    if Hi[A] - Lo[A] < 2 then
      Continue;
    W := Grid.Coords[A][Hi[A]] - Grid.Coords[A][Lo[A]];
    Mid := (Grid.Coords[A][Hi[A]] + Grid.Coords[A][Lo[A]]) / 2;
    SLo := Lo;
    SHi := Hi;
    SHi[A] := Lo[A] + 1;
    Prev := Grid.Count(SLo, SHi);
    for T := Lo[A] + 1 to Hi[A] - 1 do
    begin
      SLo[A] := T;
      SHi[A] := T + 1;
      Cnt := Grid.Count(SLo, SHi);
      if Cnt <> Prev then
      begin
        Score := Abs(Grid.Coords[A][T] - Mid) / W;
        if (Score < BestScore - 1e-4) or ((Abs(Score - BestScore) <= 1e-4) and (W > BestW)) then
        begin
          BestScore := Score;
          BestW := W;
          Axis := A;
          Split := T;
        end;
      end;
      Prev := Cnt;
    end;
  end;
  if Axis >= 0 then
    Exit;
  BestW := -1;
  for A := 0 to 2 do
    if (Hi[A] - Lo[A] >= 2) and (Grid.Coords[A][Hi[A]] - Grid.Coords[A][Lo[A]] > BestW) then
    begin
      BestW := Grid.Coords[A][Hi[A]] - Grid.Coords[A][Lo[A]];
      Axis := A;
    end;
  Split := (Lo[Axis] + Hi[Axis]) div 2;
end;

function TKdTree.Build(const Lo, Hi: TIdx3): Integer;
var
  Volume, Solids, Axis, Split, Idx, Child: Integer;
  FrontLo, BackHi: TIdx3;
begin
  Volume := (Hi[0] - Lo[0]) * (Hi[1] - Lo[1]) * (Hi[2] - Lo[2]);
  Solids := Grid.Count(Lo, Hi);
  if (Solids = 0) or (Solids = Volume) then
  begin
    if LeafCount = Length(Leaves) then
      SetLength(Leaves, Max(64, 2 * LeafCount));
    Leaves[LeafCount].Solid := Solids > 0;
    Leaves[LeafCount].Lo := Lo;
    Leaves[LeafCount].Hi := Hi;
    Inc(LeafCount);
    Exit(-LeafCount);
  end;
  ChooseSplit(Lo, Hi, Axis, Split);
  if NodeCount = Length(Nodes) then
    SetLength(Nodes, Max(64, 2 * NodeCount));
  Idx := NodeCount;
  Inc(NodeCount);
  Nodes[Idx].Axis := Axis;
  Nodes[Idx].Split := Split;
  Nodes[Idx].Lo := Lo;
  Nodes[Idx].Hi := Hi;
  FrontLo := Lo;
  FrontLo[Axis] := Split;
  BackHi := Hi;
  BackHi[Axis] := Split;
  { The arrays may grow in the calls: no element address across them }
  Child := Build(FrontLo, Hi);
  Nodes[Idx].Children[0] := Child;
  Child := Build(Lo, BackHi);
  Nodes[Idx].Children[1] := Child;
  Result := Idx;
end;

{ The cells where the origin of a box (Mins, Maxs) touches a solid cell of
  Base: the boundaries are Base's moved by the box, and a cell of the result
  is solid when the box around its center overlaps a solid cell }
function MakeClipGrid(const Base: TKdGrid; const Mins, Maxs: TVector3; const OutsideSolid: Boolean): TKdGrid;
var
  A, I, J, K, C, B, NB: Integer;
  List: specialize TList<Single>;
  Values: array[0..2] of array of Single;
  RangeLo, RangeHi: array[0..2] of array of Integer;
  Outside: array[0..2] of array of Boolean;
  Center, L, H: Single;
  Lo3, Hi3: TIdx3;
  IsSolid, AnyOutside, Empty: Boolean;
begin
  List := specialize TList<Single>.Create;
  try
    for A := 0 to 2 do
    begin
      List.Clear;
      for I := 0 to Base.N[A] do
      begin
        List.Add(Base.Coords[A][I] - Maxs[A]);
        List.Add(Base.Coords[A][I] - Mins[A]);
      end;
      List.Sort;
      SetLength(Values[A], 0);
      for I := 0 to List.Count - 1 do
        if (Length(Values[A]) = 0) or (List[I] - Values[A][High(Values[A])] > 0.01) then
        begin
          SetLength(Values[A], Length(Values[A]) + 1);
          Values[A][High(Values[A])] := List[I];
        end;
    end;
  finally
    List.Free;
  end;

  Result := TKdGrid.Create(Length(Values[0]) - 1, Length(Values[1]) - 1, Length(Values[2]) - 1);
  for A := 0 to 2 do
  begin
    for I := 0 to High(Values[A]) do
      Result.Coords[A][I] := Values[A][I];
    NB := Base.N[A];
    SetLength(RangeLo[A], Result.N[A]);
    SetLength(RangeHi[A], Result.N[A]);
    SetLength(Outside[A], Result.N[A]);
    for C := 0 to Result.N[A] - 1 do
    begin
      Center := (Values[A][C] + Values[A][C + 1]) / 2;
      L := Center + Mins[A];
      H := Center + Maxs[A];
      Outside[A][C] := (L < Base.Coords[A][0] - 0.01) or (H > Base.Coords[A][NB] + 0.01);
      { The base cells whose inside overlaps (L, H) }
      B := 0;
      while (B < NB) and (Base.Coords[A][B + 1] <= L + 0.01) do
        Inc(B);
      RangeLo[A][C] := B;
      while (B < NB) and (Base.Coords[A][B] < H - 0.01) do
        Inc(B);
      RangeHi[A][C] := B;
    end;
  end;

  for K := 0 to Result.N[2] - 1 do
    for J := 0 to Result.N[1] - 1 do
      for I := 0 to Result.N[0] - 1 do
      begin
        AnyOutside := Outside[0][I] or Outside[1][J] or Outside[2][K];
        Lo3[0] := RangeLo[0][I]; Hi3[0] := RangeHi[0][I];
        Lo3[1] := RangeLo[1][J]; Hi3[1] := RangeHi[1][J];
        Lo3[2] := RangeLo[2][K]; Hi3[2] := RangeHi[2][K];
        Empty := (Hi3[0] <= Lo3[0]) or (Hi3[1] <= Lo3[1]) or (Hi3[2] <= Lo3[2]);
        IsSolid := (AnyOutside and OutsideSolid) or (not Empty and (Base.Count(Lo3, Hi3) > 0));
        Result.Solid[Result.Index(I, J, K)] := IsSolid;
      end;
  Result.Prepare;
end;

{ BSP29 records as written ------------------------------------------------- }

type
  TRNode = packed record
    PlaneId: LongInt;
    Children: array[0..1] of Word;
    Mins, Maxs: array[0..2] of SmallInt;
    FirstFace, NumFaces: Word;
  end;

  TRLeaf = packed record
    Contents, VisOfs: LongInt;
    Mins, Maxs: array[0..2] of SmallInt;
    FirstMarkSurface, NumMarkSurfaces: Word;
    AmbientLevel: array[0..3] of Byte;
  end;

  TRClipNode = packed record
    PlaneId: LongInt;
    Children: array[0..1] of SmallInt;
  end;

  TREdge = packed record
    V0, V1: Word;
  end;

  TRFace = packed record
    PlaneId: Word;
    Side: SmallInt;
    FirstEdge: LongInt;
    NumEdges: SmallInt;
    TexInfoId: SmallInt;
    Styles: array[0..3] of Byte;
    LightmapOffset: LongInt;
  end;

  TRMiptexHeader = packed record
    Name: array[0..15] of AnsiChar;
    Width, Height: LongWord;
    Offsets: array[0..3] of LongWord;
  end;

{ The level ----------------------------------------------------------------- }

type
  TRoom = record
    X0, Y0, X1, Y1: Integer;
    FloorK, CeilK: Integer;
    WallTex, FloorTex, CeilTex: Integer;
    Color: TVector3;
    Depth, Order: Integer;
  end;

  TMapLight = record
    Pos: TVector3;
    Value: Single;
    Color: TVector3;
    Style: Integer;
  end;

  TMapTexture = record
    Name: String;
    Width, Height: Integer;
    Blob: TBytes;
  end;

  TQuad = record
    Axis, B, U, V, Side, TexInfo, ECell, Node: Integer;
  end;

  TGenFace = record
    Axis, Side, TexInfo, Node: Integer;
    Plane, UMin, UMax, VMin, VMax: Single;
    Leaves: array of Integer;
    Verts: array of Integer;
    LightOfs: Integer;
    Styles: array[0..3] of Byte;
  end;

  TRandomMapBuilder = class
  private
    Rng: TRng;
    Seed: LongWord;
    Owner, FloorK, CeilK, Special: array[0..GW - 1, 0..GH - 1] of Integer;
    Used: array[0..GW - 1, 0..GH - 1] of Boolean;
    Rooms: array of TRoom;
    EdgeA, EdgeB: array of Integer;
    CorridorCells: array of TPoint;
    Lights: array of TMapLight;
    Textures: array of TMapTexture;
    CorridorWall, CorridorFloor, CorridorCeil, ExitTex: Integer;
    StartRoom, ExitRoom: Integer;
    PadI, PadJ: Integer;
    EntText: String;
    Info: TRandomMapInfo;

    { Compiled }
    Base: TKdGrid;
    World: TKdTree;
    LeafOfCell: array of Integer;
    Planes: array of TBSPPlane;
    PlaneIndex: specialize TDictionary<Int64, Integer>;
    Vertices: array of TVector3;
    VertexIndex: specialize TDictionary<Int64, Integer>;
    Faces: array of TGenFace;
    BspNodes: array of TRNode;
    BspLeaves: array of TRLeaf;
    LeafFaces: array of array of Integer;
    ClipNodes: array of TRClipNode;
    TexInfos: array of TBSPTexInfo;
    LightBytes, LitBytes: array of Byte;
    LightCount: Integer;

    function CellSolid(const I, J, K: Integer): Boolean;
    function RoomCX(const R: Integer): Integer;
    function RoomCY(const R: Integer): Integer;
    procedure PlaceRooms;
    procedure CarveCell(const I, J: Integer);
    procedure CarveRect(const X0, Y0, X1, Y1: Integer);
    procedure Connect;
    procedure RankRooms;
    procedure Decorate;
    procedure CheckReachable;
    procedure ChooseTextures(const Donor: TMemoryStream);
    function AddGeneratedTexture(const AName: String; const BaseColor, Pattern: Integer): Integer;
    procedure AddEntity(const Fields: array of String);
    procedure AddLight(const P: TVector3; const Value: Single; const Color: TVector3; const Style: Integer;
      const AClassName: String);
    function FreeCell(const R: Integer; const Big: Boolean; out I, J: Integer): Boolean;
    procedure PlaceEntities;

    function PlaneFor(const Axis: Integer; const Dist: Single): Integer;
    function VertexKey(const P: TVector3): Int64;
    function AddVertex(const P: TVector3): Integer;
    function FaceTexture(const Axis, Side: Integer; const S, E: TIdx3): Integer;
    function FindNode(const Axis, B: Integer; const E: TIdx3): Integer;
    procedure BuildWorldTree;
    procedure BuildFaces;
    procedure BuildTexInfos;
    function LineClear(const A, B: TVector3): Boolean;
    procedure LightFace(var F: TGenFace);
    procedure BuildLightmaps;
    function AddHull(const Tree: TKdTree; const Grid: TKdGrid): Integer;
    function AddHull0(const Tree: TKdTree; const NodeBase: Integer; const MapLeaves: Boolean): Integer;
    function Write(out Lit: TMemoryStream): TMemoryStream;
  public
    constructor Create(const ASeed: LongWord);
    destructor Destroy; override;
    function Run(const Donor: TMemoryStream; out Lit: TMemoryStream): TMemoryStream;
  end;

function WX(const I: Integer): Single;
begin
  Result := (I - GW div 2) * CellXY;
end;

function WY(const J: Integer): Single;
begin
  Result := (J - GH div 2) * CellXY;
end;

function WZ(const K: Integer): Single;
begin
  Result := (K - 1) * CellZ;
end;

function FmtInt(const V: Single): String;
begin
  Result := IntToStr(Round(V));
end;

function FmtVec(const V: TVector3): String;
begin
  Result := FmtInt(V[0]) + ' ' + FmtInt(V[1]) + ' ' + FmtInt(V[2]);
end;

constructor TRandomMapBuilder.Create(const ASeed: LongWord);
begin
  inherited Create;
  Seed := ASeed;
  Rng.Init(ASeed);
  PlaneIndex := specialize TDictionary<Int64, Integer>.Create;
  VertexIndex := specialize TDictionary<Int64, Integer>.Create;
  Info := Default(TRandomMapInfo);
  Info.Seed := ASeed;
end;

destructor TRandomMapBuilder.Destroy;
begin
  PlaneIndex.Free;
  VertexIndex.Free;
  World.Free;
  Base.Free;
  inherited Destroy;
end;

function TRandomMapBuilder.CellSolid(const I, J, K: Integer): Boolean;
begin
  if (I < 0) or (J < 0) or (K < 0) or (I >= GW) or (J >= GH) or (K >= GZ) then
    Exit(True);
  Result := (Owner[I, J] = SolidOwner) or (K < FloorK[I, J]) or (K >= CeilK[I, J]);
end;

function TRandomMapBuilder.RoomCX(const R: Integer): Integer;
begin
  Result := (Rooms[R].X0 + Rooms[R].X1) div 2;
end;

function TRandomMapBuilder.RoomCY(const R: Integer): Integer;
begin
  Result := (Rooms[R].Y0 + Rooms[R].Y1) div 2;
end;

{ Layout ------------------------------------------------------------------- }

const
  RoomColors: array[0..5] of TVector3 = (
    (X: 1.0; Y: 0.95; Z: 0.85),
    (X: 1.0; Y: 0.85; Z: 0.65),
    (X: 0.8; Y: 0.9; Z: 1.0),
    (X: 0.85; Y: 1.0; Z: 0.85),
    (X: 1.0; Y: 0.8; Z: 0.8),
    (X: 0.95; Y: 0.95; Z: 0.95)
  );

procedure TRandomMapBuilder.PlaceRooms;
var
  Target, Attempt, W, H, X0, Y0, R, I, J: Integer;
  Ok: Boolean;
  Room: TRoom;
begin
  for I := 0 to GW - 1 do
    for J := 0 to GH - 1 do
    begin
      Owner[I, J] := SolidOwner;
      FloorK[I, J] := 1;
      CeilK[I, J] := 1;
      Special[I, J] := SpecialNone;
      Used[I, J] := False;
    end;
  Target := 8 + Rng.Below(5);
  for Attempt := 1 to 600 do
  begin
    if Length(Rooms) >= Target then
      Break;
    W := Rng.Range(4, 9);
    H := Rng.Range(4, 9);
    X0 := Rng.Range(2, GW - 3 - W);
    Y0 := Rng.Range(2, GH - 3 - H);
    Ok := True;
    for R := 0 to High(Rooms) do
      if (X0 <= Rooms[R].X1 + 3) and (X0 + W - 1 >= Rooms[R].X0 - 3) and
         (Y0 <= Rooms[R].Y1 + 3) and (Y0 + H - 1 >= Rooms[R].Y0 - 3) then
      begin
        Ok := False;
        Break;
      end;
    if not Ok then
      Continue;
    Room := Default(TRoom);
    Room.X0 := X0;
    Room.Y0 := Y0;
    Room.X1 := X0 + W - 1;
    Room.Y1 := Y0 + H - 1;
    Room.FloorK := 1 + Rng.Below(2);
    Room.CeilK := Room.FloorK + Rng.Range(8, 13);
    Room.Color := RoomColors[Rng.Below(Length(RoomColors))];
    SetLength(Rooms, Length(Rooms) + 1);
    Rooms[High(Rooms)] := Room;
  end;
  for R := 0 to High(Rooms) do
    for I := Rooms[R].X0 to Rooms[R].X1 do
      for J := Rooms[R].Y0 to Rooms[R].Y1 do
      begin
        Owner[I, J] := R;
        FloorK[I, J] := Rooms[R].FloorK;
        CeilK[I, J] := Rooms[R].CeilK;
      end;
  Info.Rooms := Length(Rooms);
end;

procedure TRandomMapBuilder.CarveCell(const I, J: Integer);
begin
  if (I < 1) or (J < 1) or (I > GW - 2) or (J > GH - 2) then
    Exit;
  if Owner[I, J] <> SolidOwner then
    Exit;
  Owner[I, J] := CorridorOwner;
  FloorK[I, J] := 1;
  CeilK[I, J] := 1 + CorridorHeight;
  SetLength(CorridorCells, Length(CorridorCells) + 1);
  CorridorCells[High(CorridorCells)] := Point(I, J);
end;

procedure TRandomMapBuilder.CarveRect(const X0, Y0, X1, Y1: Integer);
var
  I, J: Integer;
begin
  for I := Min(X0, X1) to Max(X0, X1) do
    for J := Min(Y0, Y1) to Max(Y0, Y1) do
      CarveCell(I, J);
end;

procedure TRandomMapBuilder.Connect;
var
  InTree: array of Boolean;
  N, Step, A, B, BestA, BestB, D, BestD, E, Extra: Integer;
  Exists, Horizontal: Boolean;

  function Dist(const P, Q: Integer): Integer;
  begin
    Result := Abs(RoomCX(P) - RoomCX(Q)) + Abs(RoomCY(P) - RoomCY(Q));
  end;

  function HasEdge(const P, Q: Integer): Boolean;
  var
    K: Integer;
  begin
    for K := 0 to High(EdgeA) do
      if ((EdgeA[K] = P) and (EdgeB[K] = Q)) or ((EdgeA[K] = Q) and (EdgeB[K] = P)) then
        Exit(True);
    Result := False;
  end;

  procedure AddEdge(const P, Q: Integer);
  begin
    SetLength(EdgeA, Length(EdgeA) + 1);
    SetLength(EdgeB, Length(EdgeB) + 1);
    EdgeA[High(EdgeA)] := P;
    EdgeB[High(EdgeB)] := Q;
  end;

begin
  N := Length(Rooms);
  if N < 2 then
    Exit;
  { Prim's spanning tree over the room centers }
  SetLength(InTree, N);
  InTree[0] := True;
  for Step := 1 to N - 1 do
  begin
    BestD := MaxInt;
    BestA := -1;
    BestB := -1;
    for A := 0 to N - 1 do
      if InTree[A] then
        for B := 0 to N - 1 do
          if not InTree[B] then
          begin
            D := Dist(A, B);
            if D < BestD then
            begin
              BestD := D;
              BestA := A;
              BestB := B;
            end;
          end;
    InTree[BestB] := True;
    AddEdge(BestA, BestB);
  end;
  { A loop or two }
  Extra := 1 + Rng.Below(2);
  for E := 1 to Extra do
  begin
    A := Rng.Below(N);
    BestD := MaxInt;
    BestB := -1;
    for B := 0 to N - 1 do
      if (B <> A) and not HasEdge(A, B) then
      begin
        D := Dist(A, B);
        if D < BestD then
        begin
          BestD := D;
          BestB := B;
        end;
      end;
    Exists := BestB < 0;
    if not Exists then
      AddEdge(A, BestB);
  end;
  Info.Corridors := Length(EdgeA);

  { Corridors two cells wide, an L from center to center }
  for E := 0 to High(EdgeA) do
  begin
    A := EdgeA[E];
    B := EdgeB[E];
    Horizontal := Rng.Below(2) = 0;
    if Horizontal then
    begin
      CarveRect(RoomCX(A), RoomCY(A), RoomCX(B) + 1, RoomCY(A) + 1);
      CarveRect(RoomCX(B), RoomCY(A), RoomCX(B) + 1, RoomCY(B) + 1);
    end else
    begin
      CarveRect(RoomCX(A), RoomCY(A), RoomCX(A) + 1, RoomCY(B) + 1);
      CarveRect(RoomCX(A), RoomCY(B), RoomCX(B) + 1, RoomCY(B) + 1);
    end;
  end;
end;

{ Depth: corridors from the start room; Order: rooms by depth, then by
  distance (the start room is 0, the exit room the last) }
procedure TRandomMapBuilder.RankRooms;
var
  Queue: array of Integer;
  Head, R, E, Other, I, J, Tmp, Far, FarD, D: Integer;
  Sorted: array of Integer;

  function Before(const P, Q: Integer): Boolean;
  var
    DP, DQ: Integer;
  begin
    if Rooms[P].Depth <> Rooms[Q].Depth then
      Exit(Rooms[P].Depth < Rooms[Q].Depth);
    DP := Abs(RoomCX(P) - RoomCX(StartRoom)) + Abs(RoomCY(P) - RoomCY(StartRoom));
    DQ := Abs(RoomCX(Q) - RoomCX(StartRoom)) + Abs(RoomCY(Q) - RoomCY(StartRoom));
    if DP <> DQ then
      Exit(DP < DQ);
    Result := P < Q;
  end;

begin
  StartRoom := 0;
  for R := 0 to High(Rooms) do
    Rooms[R].Depth := -1;
  Rooms[StartRoom].Depth := 0;
  SetLength(Queue, 1);
  Queue[0] := StartRoom;
  Head := 0;
  while Head < Length(Queue) do
  begin
    R := Queue[Head];
    Inc(Head);
    for E := 0 to High(EdgeA) do
    begin
      Other := -1;
      if EdgeA[E] = R then
        Other := EdgeB[E]
      else if EdgeB[E] = R then
        Other := EdgeA[E];
      if (Other >= 0) and (Rooms[Other].Depth < 0) then
      begin
        Rooms[Other].Depth := Rooms[R].Depth + 1;
        SetLength(Queue, Length(Queue) + 1);
        Queue[High(Queue)] := Other;
      end;
    end;
  end;
  for R := 0 to High(Rooms) do
    if Rooms[R].Depth < 0 then
      Rooms[R].Depth := 0;

  SetLength(Sorted, Length(Rooms));
  for R := 0 to High(Rooms) do
    Sorted[R] := R;
  for I := 1 to High(Sorted) do
  begin
    J := I;
    while (J > 0) and Before(Sorted[J], Sorted[J - 1]) do
    begin
      Tmp := Sorted[J];
      Sorted[J] := Sorted[J - 1];
      Sorted[J - 1] := Tmp;
      Dec(J);
    end;
  end;
  for I := 0 to High(Sorted) do
    Rooms[Sorted[I]].Order := I;

  { The exit: the deepest room, the farthest of those }
  Far := StartRoom;
  FarD := -1;
  for R := 0 to High(Rooms) do
  begin
    D := Rooms[R].Depth * 1000 + Abs(RoomCX(R) - RoomCX(StartRoom)) + Abs(RoomCY(R) - RoomCY(StartRoom));
    if (R <> StartRoom) and (D > FarD) then
    begin
      FarD := D;
      Far := R;
    end;
  end;
  ExitRoom := Far;
end;

procedure TRandomMapBuilder.Decorate;
var
  R, W, H, I, J, CX, CY: Integer;

  procedure Pillar(const PI, PJ: Integer);
  begin
    if Owner[PI, PJ] = R then
      Owner[PI, PJ] := SolidOwner;
  end;

begin
  for R := 0 to High(Rooms) do
  begin
    if (R = StartRoom) or (R = ExitRoom) then
      Continue;
    W := Rooms[R].X1 - Rooms[R].X0 + 1;
    H := Rooms[R].Y1 - Rooms[R].Y0 + 1;
    CX := RoomCX(R);
    CY := RoomCY(R);
    if (W >= 7) and (H >= 7) and Rng.Chance(60) then
    begin
      Pillar(Rooms[R].X0 + 2, Rooms[R].Y0 + 2);
      Pillar(Rooms[R].X1 - 2, Rooms[R].Y0 + 2);
      Pillar(Rooms[R].X0 + 2, Rooms[R].Y1 - 2);
      Pillar(Rooms[R].X1 - 2, Rooms[R].Y1 - 2);
    end else
    if (W >= 6) and (H >= 6) and Rng.Chance(50) then
      for I := CX - 1 to CX + 1 do
        for J := CY - 1 to CY + 1 do
          if Owner[I, J] = R then
          begin
            FloorK[I, J] := Rooms[R].FloorK + 1;
            Special[I, J] := SpecialDais;
          end;
  end;
  { The exit pad: a step up in the middle of the exit room }
  PadI := RoomCX(ExitRoom);
  PadJ := RoomCY(ExitRoom);
  for I := PadI to PadI + 1 do
    for J := PadJ to PadJ + 1 do
    begin
      FloorK[I, J] := Rooms[ExitRoom].FloorK + 1;
      Special[I, J] := SpecialPad;
    end;
end;

{ Walk the columns from the start: a step of at most one layer and at least
  four layers of headroom; counts the rooms reached }
procedure TRandomMapBuilder.CheckReachable;
var
  Seen: array[0..GW - 1, 0..GH - 1] of Boolean;
  RoomSeen: array of Boolean;
  Queue: array of TPoint;
  Head, D, NI, NJ: Integer;
  P: TPoint;
const
  DI: array[0..3] of Integer = (1, -1, 0, 0);
  DJ: array[0..3] of Integer = (0, 0, 1, -1);
begin
  FillChar(Seen, SizeOf(Seen), 0);
  SetLength(RoomSeen, Length(Rooms));
  SetLength(Queue, 1);
  Queue[0] := Point(RoomCX(StartRoom), RoomCY(StartRoom));
  Seen[Queue[0].X, Queue[0].Y] := True;
  Head := 0;
  while Head < Length(Queue) do
  begin
    P := Queue[Head];
    Inc(Head);
    if (Owner[P.X, P.Y] >= 0) and (Owner[P.X, P.Y] < Length(Rooms)) then
      RoomSeen[Owner[P.X, P.Y]] := True;
    for D := 0 to 3 do
    begin
      NI := P.X + DI[D];
      NJ := P.Y + DJ[D];
      if (NI < 0) or (NJ < 0) or (NI >= GW) or (NJ >= GH) or Seen[NI, NJ] or
         (Owner[NI, NJ] = SolidOwner) then
        Continue;
      if (Abs(FloorK[NI, NJ] - FloorK[P.X, P.Y]) > 1) or
         (Min(CeilK[NI, NJ], CeilK[P.X, P.Y]) - Max(FloorK[NI, NJ], FloorK[P.X, P.Y]) < 4) then
        Continue;
      Seen[NI, NJ] := True;
      SetLength(Queue, Length(Queue) + 1);
      Queue[High(Queue)] := Point(NI, NJ);
    end;
  end;
  Info.ReachableRooms := 0;
  for D := 0 to High(RoomSeen) do
    if RoomSeen[D] then
      Inc(Info.ReachableRooms);
end;

{ Textures ----------------------------------------------------------------- }

function HasAny(const S: String; const Words: array of String): Boolean;
var
  W: String;
begin
  for W in Words do
    if Pos(W, S) > 0 then
      Exit(True);
  Result := False;
end;

function TRandomMapBuilder.AddGeneratedTexture(const AName: String; const BaseColor, Pattern: Integer): Integer;
const
  Size = 64;
var
  Tex: TMapTexture;
  Hdr: TRMiptexHeader;
  Pixels: array[0..Size * Size - 1] of Byte;
  X, Y, Level, LW, Ofs, Shade: Integer;
  Mortar: Boolean;
begin
  for Y := 0 to Size - 1 do
    for X := 0 to Size - 1 do
    begin
      case Pattern of
        0: Mortar := (Y mod 16 = 0) or (((X + 16 * ((Y div 16) mod 2)) mod 32) = 0); { bricks }
        1: Mortar := (X mod 32 = 0) or (Y mod 32 = 0); { tiles }
        else Mortar := (X mod 64 = 0) or (Y mod 16 = 0); { plates }
      end;
      Shade := 4 + Rng.Below(4);
      if Mortar then
        Shade := 1;
      Pixels[Y * Size + X] := BaseColor + Shade;
    end;
  Tex.Name := AName;
  Tex.Width := Size;
  Tex.Height := Size;
  SetLength(Tex.Blob, SizeOf(Hdr) + Size * Size * 85 div 64);
  FillChar(Hdr, SizeOf(Hdr), 0);
  Move(AName[1], Hdr.Name[0], Min(Length(AName), 15));
  Hdr.Width := Size;
  Hdr.Height := Size;
  Ofs := SizeOf(Hdr);
  for Level := 0 to 3 do
  begin
    Hdr.Offsets[Level] := Ofs;
    LW := Size shr Level;
    for Y := 0 to LW - 1 do
      for X := 0 to LW - 1 do
        Tex.Blob[Ofs + Y * LW + X] := Pixels[(Y shl Level) * Size + (X shl Level)];
    Inc(Ofs, LW * LW);
  end;
  Move(Hdr, Tex.Blob[0], SizeOf(Hdr));
  SetLength(Textures, Length(Textures) + 1);
  Textures[High(Textures)] := Tex;
  Result := High(Textures);
end;

procedure TRandomMapBuilder.ChooseTextures(const Donor: TMemoryStream);
var
  Cands: array of TMapTexture;
  DonorBase: PByte;
  Version, LumpOfs, LumpLen, Count, I, Ofs, W, H, Size, R: Integer;
  Name: String;
  Hdr: TRMiptexHeader;
  Tex: TMapTexture;
  Walls, Floors, Ceils: TIntegerDynArray;

  function Pick(const List: array of Integer): Integer;
  begin
    if Length(List) = 0 then
      Exit(-1);
    Result := List[Rng.Below(Length(List))];
  end;

  procedure Push(var List: TIntegerDynArray; const V: Integer);
  begin
    SetLength(List, Length(List) + 1);
    List[High(List)] := V;
  end;

  { The index in Textures of candidate C, added on first use }
  function Use(const C: Integer): Integer;
  var
    K: Integer;
  begin
    for K := 0 to High(Textures) do
      if Textures[K].Name = Cands[C].Name then
        Exit(K);
    SetLength(Textures, Length(Textures) + 1);
    Textures[High(Textures)] := Cands[C];
    Result := High(Textures);
  end;

  { Up to N different candidates of List (all candidates when it is empty) }
  function Choose(const List: TIntegerDynArray; const N: Integer): TIntegerDynArray;
  var
    Pool: TIntegerDynArray;
    K, P: Integer;
  begin
    Result := nil;
    if Length(List) > 0 then
      Pool := Copy(List)
    else
    begin
      SetLength(Pool, Length(Cands));
      for K := 0 to High(Cands) do
        Pool[K] := K;
    end;
    for K := 1 to N do
    begin
      if Length(Pool) = 0 then
        Break;
      P := Rng.Below(Length(Pool));
      Push(Result, Use(Pool[P]));
      Delete(Pool, P, 1);
    end;
  end;

var
  WallL, FloorL, CeilL, ExitL: TIntegerDynArray;
begin
  Cands := nil;
  if (Donor <> nil) and (Donor.Size > 124) then
  begin
    DonorBase := PByte(Donor.Memory);
    Version := PLongInt(DonorBase)^;
    LumpOfs := PLongInt(DonorBase + 4 + 8 * LUMP_MIPTEX)^;
    LumpLen := PLongInt(DonorBase + 8 + 8 * LUMP_MIPTEX)^;
    if ((Version = BSP_VERSION) or (Version = BSP2_VERSION_BSP2) or (Version = BSP2_VERSION_2PSB)) and
       (LumpOfs > 0) and (LumpLen >= 4) and (Int64(LumpOfs) + LumpLen <= Donor.Size) then
    begin
      Count := PLongInt(DonorBase + LumpOfs)^;
      for I := 0 to Count - 1 do
      begin
        if 4 + 4 * (I + 1) > LumpLen then
          Break;
        Ofs := PLongInt(DonorBase + LumpOfs + 4 + 4 * I)^;
        if (Ofs < 0) or (Ofs + SizeOf(Hdr) > LumpLen) then
          Continue;
        Move((DonorBase + LumpOfs + Ofs)^, Hdr, SizeOf(Hdr));
        Hdr.Name[15] := #0;
        Name := LowerCase(Trim(PAnsiChar(@Hdr.Name[0])));
        W := Hdr.Width;
        H := Hdr.Height;
        if (Name = '') or (W < 32) or (H < 32) or (W > 512) or (H > 512) or
           (W mod 16 <> 0) or (H mod 16 <> 0) then
          Continue;
        if (Name[1] in ['*', '+', '{', '#']) or (Pos('sky', Name) = 1) or
           HasAny(Name, ['skip', 'trigger', 'clip', 'hint', 'origin', 'note', 'go-', 'skill', 'comp',
             'term', 'scrn', 'arrow', 'planet', 'flat_', 'light', 'lit', 'button', 'door', 'exit',
             'sign', 'window', 'wind', 'glass', 'lava', 'water', 'slime', 'tele', 'switch', 'rune',
             'key', 'plaque', 'black', 'flesh', 'gut', 'blood', 'text', 'mmetal', 'ep0', 'ep1',
             'ep2', 'ep3', 'ep4']) then
          Continue;
        Size := SizeOf(Hdr) + W * H * 85 div 64;
        if (Hdr.Offsets[0] <> SizeOf(Hdr)) or (Ofs + Size > LumpLen) then
          Continue;
        Tex.Name := Name;
        Tex.Width := W;
        Tex.Height := H;
        SetLength(Tex.Blob, Size);
        Move((DonorBase + LumpOfs + Ofs)^, Tex.Blob[0], Size);
        SetLength(Cands, Length(Cands) + 1);
        Cands[High(Cands)] := Tex;
      end;
    end;
  end;

  WallL := nil;
  FloorL := nil;
  CeilL := nil;
  ExitL := nil;
  for I := 0 to High(Cands) do
  begin
    Name := Cands[I].Name;
    if HasAny(Name, ['wall', 'brick', 'bric', 'stone', 'rock', 'blok', 'block', 'city', 'wiz',
      'church', 'cop', 'wood', 'tech0', 'sect']) and not HasAny(Name, ['supp', 'strip', 'trim']) then
      Push(WallL, I);
    if HasAny(Name, ['flor', 'floor', 'flr', 'grate', 'tread', 'plat', 'ground', 'grnd', 'dirt',
      'tile']) then
      Push(FloorL, I);
    if HasAny(Name, ['ceil', 'sheet', 'metal', 'wizmet', 'tech0', 'flat']) and
       not HasAny(Name, ['strip', 'tread', 'plat', 'supp', 'trim']) then
      Push(CeilL, I);
    if HasAny(Name, ['trim', 'tech', 'metal', 'indent', 'blok']) and not HasAny(Name, ['supp', 'tread']) then
      Push(ExitL, I);
  end;

  if Length(Cands) > 0 then
  begin
    Walls := Choose(WallL, 3);
    Floors := Choose(FloorL, 2);
    Ceils := Choose(CeilL, 2);
    ExitTex := Choose(ExitL, 1)[0];
  end else
  begin
    Walls := nil;
    Push(Walls, AddGeneratedTexture('rnd_brick', 16, 0));
    Push(Walls, AddGeneratedTexture('rnd_stone', 0, 0));
    Floors := nil;
    Push(Floors, AddGeneratedTexture('rnd_tile', 0, 1));
    Ceils := nil;
    Push(Ceils, AddGeneratedTexture('rnd_plate', 80, 2));
    ExitTex := AddGeneratedTexture('rnd_exit', 192, 1);
  end;

  for R := 0 to High(Rooms) do
  begin
    Rooms[R].WallTex := Pick(Walls);
    Rooms[R].FloorTex := Pick(Floors);
    Rooms[R].CeilTex := Pick(Ceils);
  end;
  CorridorWall := Pick(Walls);
  CorridorFloor := Pick(Floors);
  CorridorCeil := Pick(Ceils);

  Info.Textures := '';
  for I := 0 to High(Textures) do
  begin
    if I > 0 then
      Info.Textures := Info.Textures + ' ';
    Info.Textures := Info.Textures + Textures[I].Name;
  end;
end;

{ Entities ------------------------------------------------------------------ }

procedure TRandomMapBuilder.AddEntity(const Fields: array of String);
var
  I: Integer;
begin
  EntText := EntText + '{' + #10;
  I := 0;
  while I + 1 <= High(Fields) do
  begin
    EntText := EntText + '"' + Fields[I] + '" "' + Fields[I + 1] + '"' + #10;
    Inc(I, 2);
  end;
  EntText := EntText + '}' + #10;
end;

procedure TRandomMapBuilder.AddLight(const P: TVector3; const Value: Single; const Color: TVector3;
  const Style: Integer; const AClassName: String);
var
  L: TMapLight;
begin
  L.Pos := P;
  L.Value := Value;
  L.Color := Color;
  L.Style := Style;
  SetLength(Lights, Length(Lights) + 1);
  Lights[High(Lights)] := L;
  if AClassName = 'light' then
  begin
    if Style <> 0 then
      AddEntity(['classname', 'light', 'origin', FmtVec(P), 'light', FmtInt(Value),
        '_color', FmtInt(Color[0] * 255) + ' ' + FmtInt(Color[1] * 255) + ' ' + FmtInt(Color[2] * 255),
        'style', IntToStr(Style)])
    else
      AddEntity(['classname', 'light', 'origin', FmtVec(P), 'light', FmtInt(Value),
        '_color', FmtInt(Color[0] * 255) + ' ' + FmtInt(Color[1] * 255) + ' ' + FmtInt(Color[2] * 255)]);
  end else
    AddEntity(['classname', AClassName, 'origin', FmtVec(P)]);
  Inc(Info.Lights);
end;

{ A free cell of room R on its plain floor; Big: its 8 neighbors are floor
  of the same height too (for the large monsters) }
function TRandomMapBuilder.FreeCell(const R: Integer; const Big: Boolean; out I, J: Integer): Boolean;
var
  Attempt, DI, DJ: Integer;
  Ok: Boolean;
begin
  for Attempt := 1 to 60 do
  begin
    I := Rng.Range(Rooms[R].X0, Rooms[R].X1);
    J := Rng.Range(Rooms[R].Y0, Rooms[R].Y1);
    if (Owner[I, J] <> R) or Used[I, J] or (Special[I, J] <> SpecialNone) then
      Continue;
    Ok := True;
    if Big then
      for DI := -1 to 1 do
        for DJ := -1 to 1 do
          if (Owner[I + DI, J + DJ] <> R) or (Special[I + DI, J + DJ] <> SpecialNone) or
             (FloorK[I + DI, J + DJ] <> FloorK[I, J]) then
            Ok := False;
    if not Ok then
      Continue;
    Used[I, J] := True;
    Exit(True);
  end;
  Result := False;
end;

const
  EarlyMonsters: array[0..3] of String = ('monster_army', 'monster_army', 'monster_dog', 'monster_dog');
  MidMonsters: array[0..5] of String = ('monster_army', 'monster_ogre', 'monster_knight',
    'monster_wizard', 'monster_enforcer', 'monster_zombie');
  LateMonsters: array[0..5] of String = ('monster_ogre', 'monster_hell_knight', 'monster_demon1',
    'monster_enforcer', 'monster_wizard', 'monster_shalrath');
  Weapons: array[1..6] of String = ('weapon_supershotgun', 'weapon_nailgun', 'weapon_grenadelauncher',
    'weapon_supernailgun', 'weapon_rocketlauncher', 'weapon_lightning');

function IsBigMonster(const CName: String): Boolean;
begin
  Result := (CName = 'monster_ogre') or (CName = 'monster_demon1') or (CName = 'monster_shambler') or
    (CName = 'monster_shalrath');
end;

procedure TRandomMapBuilder.PlaceEntities;
var
  R, I, J, K, N, Area, Order, Last, Flags, Yaw, OI, OJ, Best: Integer;
  Frac: Single;
  Ammo: String;
  P, Dir: TVector3;
  Floor, Ceil: Single;

  function Center(const CI, CJ: Integer; const Z: Single): TVector3;
  begin
    Result := Vector3(WX(CI) + CellXY / 2, WY(CJ) + CellXY / 2, Z);
  end;

  procedure Item(const AClass: String; const ASpawnFlags: Integer = 0);
  var
    II, IJ: Integer;
  begin
    if not FreeCell(R, False, II, IJ) then
      Exit;
    if ASpawnFlags <> 0 then
      AddEntity(['classname', AClass, 'origin', FmtVec(Center(II, IJ, WZ(FloorK[II, IJ]))),
        'spawnflags', IntToStr(ASpawnFlags)])
    else
      AddEntity(['classname', AClass, 'origin', FmtVec(Center(II, IJ, WZ(FloorK[II, IJ])))]);
    Inc(Info.Items);
  end;

  procedure Monster(const AClass: String; const ASpawnFlags: Integer);
  var
    MI, MJ: Integer;
    Z: Single;
  begin
    if not FreeCell(R, IsBigMonster(AClass), MI, MJ) then
      Exit;
    if AClass = 'monster_wizard' then
      Z := WZ(FloorK[MI, MJ]) + 72
    else
      Z := WZ(FloorK[MI, MJ]) + 25;
    if ASpawnFlags <> 0 then
      AddEntity(['classname', AClass, 'origin', FmtVec(Center(MI, MJ, Z)),
        'angle', IntToStr(Rng.Below(8) * 45), 'spawnflags', IntToStr(ASpawnFlags)])
    else
      AddEntity(['classname', AClass, 'origin', FmtVec(Center(MI, MJ, Z)),
        'angle', IntToStr(Rng.Below(8) * 45)]);
    Inc(Info.Monsters);
  end;

  function PickMonster: String;
  begin
    if Frac < 0.34 then
      Result := EarlyMonsters[Rng.Below(Length(EarlyMonsters))]
    else if Frac < 0.67 then
      Result := MidMonsters[Rng.Below(Length(MidMonsters))]
    else
      Result := LateMonsters[Rng.Below(Length(LateMonsters))];
  end;

  procedure Torch(const TI, TJ, DI, DJ: Integer);
  var
    TP: TVector3;
  begin
    { On the solid column next to cell (TI, TJ) in direction (DI, DJ) }
    if Owner[TI + DI, TJ + DJ] <> SolidOwner then
      Exit;
    TP := Center(TI, TJ, WZ(Rooms[R].FloorK) + 88);
    TP.Data[0] := TP[0] + DI * (CellXY / 2 - 8);
    TP.Data[1] := TP[1] + DJ * (CellXY / 2 - 8);
    AddLight(TP, 200, Vector3(1.0, 0.75, 0.45), 0, 'light_torch_small_walltorch');
  end;

begin
  Last := High(Rooms);
  { Worldspawn }
  AddEntity(['classname', 'worldspawn', 'message', 'Random level ' + IntToStr(Seed),
    'sounds', IntToStr(2 + Integer(Seed mod 9)), 'worldtype', '2', '_randomseed', IntToStr(Seed)]);

  { Nothing starts on or next to the exit pad (its trigger reaches 16 units
    past it) }
  for I := PadI - 1 to PadI + 2 do
    for J := PadJ - 1 to PadJ + 2 do
      Used[I, J] := True;

  { The player starts in the middle of the start room, looking down the
    first corridor }
  I := RoomCX(StartRoom);
  J := RoomCY(StartRoom);
  Used[I, J] := True;
  P := Center(I, J, WZ(FloorK[I, J]) + 24);
  { The opening of the start room nearest its middle: a corridor (or room)
    cell next to an edge cell }
  Best := MaxInt;
  Dir := Center(RoomCX(ExitRoom), RoomCY(ExitRoom), 0) - Center(I, J, 0);
  for OI := Rooms[StartRoom].X0 - 1 to Rooms[StartRoom].X1 + 1 do
    for OJ := Rooms[StartRoom].Y0 - 1 to Rooms[StartRoom].Y1 + 1 do
      if (((OI >= Rooms[StartRoom].X0) and (OI <= Rooms[StartRoom].X1) and
           ((OJ = Rooms[StartRoom].Y0 - 1) or (OJ = Rooms[StartRoom].Y1 + 1))) or
          ((OJ >= Rooms[StartRoom].Y0) and (OJ <= Rooms[StartRoom].Y1) and
           ((OI = Rooms[StartRoom].X0 - 1) or (OI = Rooms[StartRoom].X1 + 1)))) and
         (Owner[OI, OJ] <> SolidOwner) and (Sqr(OI - I) + Sqr(OJ - J) < Best) then
      begin
        Best := Sqr(OI - I) + Sqr(OJ - J);
        Dir := Center(OI, OJ, 0) - Center(I, J, 0);
      end;
  Yaw := (Round(RadToDeg(ArcTan2(Dir[1], Dir[0]))) + 360) mod 360;
  AddEntity(['classname', 'info_player_start', 'origin', FmtVec(P), 'angle', IntToStr(Yaw)]);
  Info.StartOrigin := P;
  Info.StartYaw := Yaw;
  R := StartRoom;
  for K := 1 to 3 do
    if FreeCell(R, False, I, J) then
      AddEntity(['classname', 'info_player_coop', 'origin', FmtVec(Center(I, J, WZ(FloorK[I, J]) + 24)),
        'angle', IntToStr(Yaw)]);
  AddEntity(['classname', 'info_intermission',
    'origin', FmtVec(Center(RoomCX(StartRoom), RoomCY(StartRoom), WZ(Rooms[StartRoom].CeilK) - 40)),
    'mangle', '20 ' + IntToStr((Yaw + 45) mod 360) + ' 0']);

  for R := 0 to Last do
  begin
    Area := (Rooms[R].X1 - Rooms[R].X0 + 1) * (Rooms[R].Y1 - Rooms[R].Y0 + 1);
    Order := Rooms[R].Order;
    if Last > 0 then
      Frac := Order / Last
    else
      Frac := 0;
    Floor := WZ(Rooms[R].FloorK);
    Ceil := WZ(Rooms[R].CeilK);

    { Deathmatch starts, one a room }
    if FreeCell(R, False, I, J) then
      AddEntity(['classname', 'info_player_deathmatch', 'origin', FmtVec(Center(I, J, Floor + 24)),
        'angle', IntToStr(Rng.Below(4) * 90)]);

    { Lights under the ceiling, a grid of them, and two torches }
    N := Max(1, (Rooms[R].X1 - Rooms[R].X0 + 3) div 4);
    K := Max(1, (Rooms[R].Y1 - Rooms[R].Y0 + 3) div 4);
    for I := 0 to N - 1 do
      for J := 0 to K - 1 do
        AddLight(Vector3(
          WX(Rooms[R].X0) + (Rooms[R].X1 - Rooms[R].X0 + 1) * CellXY * (2 * I + 1) / (2 * N),
          WY(Rooms[R].Y0) + (Rooms[R].Y1 - Rooms[R].Y0 + 1) * CellXY * (2 * J + 1) / (2 * K),
          Ceil - 24), 110 + (Rooms[R].CeilK - Rooms[R].FloorK) * 12, Rooms[R].Color, 0, 'light');
    if Rng.Below(2) = 0 then
    begin
      Torch(Rooms[R].X0, RoomCY(R) - 1 - Rng.Below(2), -1, 0);
      Torch(Rooms[R].X1, RoomCY(R) + 1 + Rng.Below(2), 1, 0);
    end else
    begin
      Torch(RoomCX(R) - 1 - Rng.Below(2), Rooms[R].Y0, 0, -1);
      Torch(RoomCX(R) + 1 + Rng.Below(2), Rooms[R].Y1, 0, 1);
    end;

    if R = StartRoom then
    begin
      Item('item_shells');
      Continue;
    end;

    { Monsters: more with the room's size; one more in medium and hard
      (not in easy), one more in hard only }
    N := EnsureRange(1 + Area div 20, 1, 4);
    for K := 1 to N do
      Monster(PickMonster, 0);
    Monster(PickMonster, 256);
    Flags := 256 or 512;
    if (Frac >= 0.67) and Rng.Chance(40) then
      Monster('monster_shambler', Flags)
    else
      Monster(PickMonster, Flags);

    { A new weapon in the first six rooms, ammo for what there is so far,
      health and armor }
    if (Order >= Low(Weapons)) and (Order <= High(Weapons)) then
      Item(Weapons[Order]);
    for K := 1 to 1 + Rng.Below(2) do
    begin
      case Rng.Below(4) of
        0: Ammo := 'item_spikes';
        1: Ammo := 'item_rockets';
        2: Ammo := 'item_cells';
        else Ammo := 'item_shells';
      end;
      if ((Ammo = 'item_spikes') and (Order < 2)) or ((Ammo = 'item_rockets') and (Order < 3)) or
         ((Ammo = 'item_cells') and (Order < 6)) then
        Ammo := 'item_shells';
      Item(Ammo);
    end;
    Item('item_health');
    if Rng.Chance(30) then
      Item('item_health', 1);
    if Order = 2 then
      Item('item_armor1');
    if (Order = Max(4, Last - 1)) then
      Item('item_armor2');
    if (R = ExitRoom) or ((Frac > 0.5) and Rng.Chance(10)) then
      Item('item_health', 2);
  end;

  { Corridor lights, every sixth cell }
  for K := 0 to High(CorridorCells) do
    if K mod 6 = 3 then
    begin
      I := CorridorCells[K].X;
      J := CorridorCells[K].Y;
      if Owner[I, J] = CorridorOwner then
        AddLight(Center(I, J, WZ(CeilK[I, J]) - 20), 180, Vector3(0.9, 0.95, 1.0), 0, 'light');
    end;

  { The exit: a pad that pulses, and the trigger above it }
  P := Vector3(WX(PadI + 1), WY(PadJ + 1), WZ(FloorK[PadI, PadJ]));
  AddLight(P + Vector3(0, 0, 72), 260, Vector3(0.6, 0.8, 1.0), 2, 'light');
  AddLight(P + Vector3(0, 0, 96), 160, Vector3(0.7, 0.85, 1.0), 0, 'light');
  AddEntity(['classname', 'trigger_changelevel', 'model', '*1', 'map', RandomMapName(Seed + 1)]);
  Info.ExitOrigin := P + Vector3(0, 0, 24);
end;

{ BSP ------------------------------------------------------------------------ }

function TRandomMapBuilder.PlaneFor(const Axis: Integer; const Dist: Single): Integer;
var
  Key: Int64;
  Pl: TBSPPlane;
begin
  Key := Int64(Axis) * 10000000 + (Round(Dist * 8) + 5000000);
  if PlaneIndex.TryGetValue(Key, Result) then
    Exit;
  Pl.Normal := TVector3.Zero;
  Pl.Normal.Data[Axis] := 1;
  Pl.Dist := Dist;
  Pl.PlaneType := Axis;
  SetLength(Planes, Length(Planes) + 1);
  Planes[High(Planes)] := Pl;
  Result := High(Planes);
  PlaneIndex.Add(Key, Result);
end;

function TRandomMapBuilder.VertexKey(const P: TVector3): Int64;
begin
  Result := ((Int64(Round(P[0])) + 65536) shl 36) or ((Int64(Round(P[1])) + 65536) shl 18) or
    (Int64(Round(P[2])) + 65536);
end;

function TRandomMapBuilder.AddVertex(const P: TVector3): Integer;
var
  Key: Int64;
begin
  Key := VertexKey(P);
  if VertexIndex.TryGetValue(Key, Result) then
    Exit;
  SetLength(Vertices, Length(Vertices) + 1);
  Vertices[High(Vertices)] := P;
  Result := High(Vertices);
  VertexIndex.Add(Key, Result);
end;

function TRandomMapBuilder.FaceTexture(const Axis, Side: Integer; const S, E: TIdx3): Integer;
var
  EO, SO: Integer;
begin
  EO := Owner[E[0], E[1]];
  SO := Owner[S[0], S[1]];
  if Axis = 2 then
  begin
    if Side = 0 then
    begin
      { A floor }
      if Special[E[0], E[1]] = SpecialPad then
        Exit(ExitTex);
      if (EO >= 0) and (EO < Length(Rooms)) then
        Exit(Rooms[EO].FloorTex);
      Exit(CorridorFloor);
    end;
    if (EO >= 0) and (EO < Length(Rooms)) then
      Exit(Rooms[EO].CeilTex);
    Exit(CorridorCeil);
  end;
  if (S[0] >= 0) and (S[0] < GW) and (S[1] >= 0) and (S[1] < GH) then
  begin
    if Special[S[0], S[1]] = SpecialPad then
      Exit(ExitTex);
    if (Special[S[0], S[1]] = SpecialDais) and (SO >= 0) and (SO < Length(Rooms)) then
      Exit(Rooms[SO].FloorTex);
  end;
  if (EO >= 0) and (EO < Length(Rooms)) then
    Exit(Rooms[EO].WallTex);
  Result := CorridorWall;
end;

procedure TRandomMapBuilder.BuildWorldTree;
var
  I, J, K: Integer;
begin
  Base := TKdGrid.Create(GW, GH, GZ);
  for I := 0 to GW do
    Base.Coords[0][I] := WX(I);
  for J := 0 to GH do
    Base.Coords[1][J] := WY(J);
  for K := 0 to GZ do
    Base.Coords[2][K] := WZ(K);
  for K := 0 to GZ - 1 do
    for J := 0 to GH - 1 do
      for I := 0 to GW - 1 do
        Base.Solid[Base.Index(I, J, K)] := CellSolid(I, J, K);
  Base.Prepare;
  World := TKdTree.Create(Base);
end;

{ The node whose plane separates cell E from its neighbor across boundary B
  of Axis (both cells take the same way down to it) }
function TRandomMapBuilder.FindNode(const Axis, B: Integer; const E: TIdx3): Integer;
var
  N: Integer;
begin
  N := 0;
  while N >= 0 do
  begin
    if World.Nodes[N].Axis = Axis then
    begin
      if World.Nodes[N].Split = B then
        Exit(N);
      if World.Nodes[N].Split < B then
        N := World.Nodes[N].Children[0]
      else
        N := World.Nodes[N].Children[1];
    end else
    if E[World.Nodes[N].Axis] >= World.Nodes[N].Split then
      N := World.Nodes[N].Children[0]
    else
      N := World.Nodes[N].Children[1];
  end;
  Result := -1;
end;

function CompareQuads(constref A, B: TQuad): Integer;
begin
  Result := A.Node - B.Node;
  if Result = 0 then
    Result := A.Side - B.Side;
  if Result = 0 then
    Result := A.TexInfo - B.TexInfo;
  if Result = 0 then
    Result := A.V - B.V;
  if Result = 0 then
    Result := A.U - B.U;
end;

const
  UAxisOf: array[0..2] of Integer = (1, 0, 0);
  VAxisOf: array[0..2] of Integer = (2, 2, 1);

procedure TRandomMapBuilder.BuildFaces;
var
  Quads: array of TQuad;
  QuadCount, I, J, K, A, G0, G1, Q, U0, U1, V0, V1, UA, VA, Idx, Cell, L, X, Steps, T, F: Integer;
  C, S, E: TIdx3;
  Q1: TQuad;
  Grid2: specialize TDictionary<Int64, Integer>;
  UsedQ: array of Boolean;
  Ok: Boolean;
  Face: TGenFace;
  Corner: array[0..3] of TVector3;
  P, D, N, Pt: TVector3;
  Cross: TVector3;
  Poly: array of Integer;
  Step: Single;
  LeafSeen: specialize TDictionary<Integer, Boolean>;

  function Lookup(const U, V: Integer): Integer;
  begin
    if not Grid2.TryGetValue(Int64(U) * 100000 + V, Result) then
      Result := -1
    else if UsedQ[Result] then
      Result := -1;
  end;

  procedure AddLeafOf(const QIdx: Integer);
  var
    Lf: Integer;
  begin
    Lf := LeafOfCell[Quads[QIdx].ECell];
    if (Lf > 0) and not LeafSeen.ContainsKey(Lf) then
    begin
      LeafSeen.Add(Lf, True);
      SetLength(Face.Leaves, Length(Face.Leaves) + 1);
      Face.Leaves[High(Face.Leaves)] := Lf;
    end;
  end;

  function CornerAt(const U, V: Single): TVector3;
  begin
    Result.Data[A] := Face.Plane;
    Result.Data[UA] := U;
    Result.Data[VA] := V;
  end;

begin
  { The unit quads between solid and empty cells }
  QuadCount := 0;
  SetLength(Quads, 4096);
  for K := 0 to GZ - 1 do
    for J := 0 to GH - 1 do
      for I := 0 to GW - 1 do
        for A := 0 to 2 do
        begin
          C[0] := I;
          C[1] := J;
          C[2] := K;
          if C[A] + 1 >= Base.N[A] then
            Continue;
          S := C;
          E := C;
          E[A] := C[A] + 1;
          if Base.Solid[Base.Index(S[0], S[1], S[2])] = Base.Solid[Base.Index(E[0], E[1], E[2])] then
            Continue;
          Q1 := Default(TQuad);
          Q1.Axis := A;
          Q1.B := C[A] + 1;
          if Base.Solid[Base.Index(S[0], S[1], S[2])] then
            Q1.Side := 0 { facing +Axis }
          else
          begin
            Q1.Side := 1;
            S := E;
            E := C;
          end;
          Q1.U := E[UAxisOf[A]];
          Q1.V := E[VAxisOf[A]];
          Q1.TexInfo := FaceTexture(A, Q1.Side, S, E) * 3 + A;
          Q1.ECell := Base.Index(E[0], E[1], E[2]);
          Q1.Node := FindNode(A, Q1.B, E);
          if Q1.Node < 0 then
            Continue;
          if QuadCount = Length(Quads) then
            SetLength(Quads, 2 * QuadCount);
          Quads[QuadCount] := Q1;
          Inc(QuadCount);
        end;
  SetLength(Quads, QuadCount);
  specialize TArrayHelper<TQuad>.Sort(Quads, specialize TComparer<TQuad>.Construct(@CompareQuads));

  { Merge each node's quads of one side and texture into rectangles }
  SetLength(UsedQ, QuadCount);
  Grid2 := specialize TDictionary<Int64, Integer>.Create;
  LeafSeen := specialize TDictionary<Integer, Boolean>.Create;
  try
    G0 := 0;
    while G0 < QuadCount do
    begin
      G1 := G0;
      while (G1 + 1 < QuadCount) and (Quads[G1 + 1].Node = Quads[G0].Node) and
            (Quads[G1 + 1].Side = Quads[G0].Side) and (Quads[G1 + 1].TexInfo = Quads[G0].TexInfo) do
        Inc(G1);
      Grid2.Clear;
      for Q := G0 to G1 do
        Grid2.AddOrSetValue(Int64(Quads[Q].U) * 100000 + Quads[Q].V, Q);
      A := Quads[G0].Axis;
      UA := UAxisOf[A];
      VA := VAxisOf[A];
      for Q := G0 to G1 do
      begin
        if UsedQ[Q] then
          Continue;
        U0 := Quads[Q].U;
        V0 := Quads[Q].V;
        U1 := U0;
        while (U1 + 2 <= Base.N[UA]) and (Lookup(U1 + 1, V0) >= 0) and
              (Base.Coords[UA][U1 + 2] - Base.Coords[UA][U0] <= MaxFaceSize) do
          Inc(U1);
        V1 := V0;
        repeat
          Ok := (V1 + 2 <= Base.N[VA]) and (Base.Coords[VA][V1 + 2] - Base.Coords[VA][V0] <= MaxFaceSize);
          if Ok then
            for X := U0 to U1 do
              if Lookup(X, V1 + 1) < 0 then
              begin
                Ok := False;
                Break;
              end;
          if Ok then
            Inc(V1);
        until not Ok;

        Face := Default(TGenFace);
        Face.Axis := A;
        Face.Side := Quads[Q].Side;
        Face.TexInfo := Quads[Q].TexInfo;
        Face.Node := Quads[Q].Node;
        Face.Plane := Base.Coords[A][Quads[Q].B];
        Face.UMin := Base.Coords[UA][U0];
        Face.UMax := Base.Coords[UA][U1 + 1];
        Face.VMin := Base.Coords[VA][V0];
        Face.VMax := Base.Coords[VA][V1 + 1];
        LeafSeen.Clear;
        for X := U0 to U1 do
          for Idx := V0 to V1 do
          begin
            Cell := Lookup(X, Idx);
            if Cell >= 0 then
            begin
              AddLeafOf(Cell);
              UsedQ[Cell] := True;
            end;
          end;
        SetLength(Faces, Length(Faces) + 1);
        Faces[High(Faces)] := Face;
      end;
      G0 := G1 + 1;
    end;
  finally
    Grid2.Free;
    LeafSeen.Free;
  end;

  { Corners first (every vertex of the map is one), then each polygon with
    the corners of other faces that lie on its edges (no T-junctions) }
  for F := 0 to High(Faces) do
  begin
    Face := Faces[F];
    A := Face.Axis;
    UA := UAxisOf[A];
    VA := VAxisOf[A];
    AddVertex(CornerAt(Face.UMin, Face.VMin));
    AddVertex(CornerAt(Face.UMin, Face.VMax));
    AddVertex(CornerAt(Face.UMax, Face.VMax));
    AddVertex(CornerAt(Face.UMax, Face.VMin));
  end;
  for F := 0 to High(Faces) do
  begin
    Face := Faces[F];
    A := Face.Axis;
    UA := UAxisOf[A];
    VA := VAxisOf[A];
    Corner[0] := CornerAt(Face.UMin, Face.VMin);
    Corner[1] := CornerAt(Face.UMin, Face.VMax);
    Corner[2] := CornerAt(Face.UMax, Face.VMax);
    Corner[3] := CornerAt(Face.UMax, Face.VMin);
    N := TVector3.Zero;
    if Face.Side = 0 then
      N.Data[A] := 1
    else
      N.Data[A] := -1;
    { Clockwise seen from the front, like qbsp }
    Cross := TVector3.CrossProduct(Corner[1] - Corner[0], Corner[2] - Corner[1]);
    if TVector3.DotProduct(Cross, N) > 0 then
    begin
      P := Corner[1];
      Corner[1] := Corner[3];
      Corner[3] := P;
    end;
    Poly := nil;
    for I := 0 to 3 do
    begin
      SetLength(Poly, Length(Poly) + 1);
      Poly[High(Poly)] := AddVertex(Corner[I]);
      D := Corner[(I + 1) mod 4] - Corner[I];
      if Abs(D[2]) > 0.5 then
        Step := CellZ
      else
        Step := CellXY;
      Steps := Round(D.Length / Step);
      for T := 1 to Steps - 1 do
      begin
        Pt := Corner[I] + D * (T / Steps);
        if VertexIndex.TryGetValue(VertexKey(Pt), L) then
        begin
          SetLength(Poly, Length(Poly) + 1);
          Poly[High(Poly)] := L;
        end;
      end;
    end;
    Faces[F].Verts := Poly;
  end;
  Info.Faces := Length(Faces);
end;

procedure TRandomMapBuilder.BuildTexInfos;
var
  T, A: Integer;
  TI: TBSPTexInfo;
begin
  SetLength(TexInfos, Length(Textures) * 3);
  for T := 0 to High(Textures) do
    for A := 0 to 2 do
    begin
      TI := Default(TBSPTexInfo);
      { qbsp's TextureAxisFromPlane }
      case A of
        0: begin TI.VecS := Vector4(0, 1, 0, 0); TI.VecT := Vector4(0, 0, -1, 0); end;
        1: begin TI.VecS := Vector4(1, 0, 0, 0); TI.VecT := Vector4(0, 0, -1, 0); end;
        else begin TI.VecS := Vector4(1, 0, 0, 0); TI.VecT := Vector4(0, -1, 0, 0); end;
      end;
      TI.Miptex := T;
      TI.Flags := 0;
      TexInfos[T * 3 + A] := TI;
    end;
end;

{ No solid cell on the segment (a walk through the cells it crosses) }
function TRandomMapBuilder.LineClear(const A, B: TVector3): Boolean;
var
  Cell, Target, StepDir: array[0..2] of Integer;
  TMax, TDelta, Org, Size: array[0..2] of Single;
  Ax, Best, Guard: Integer;
  D: Single;
begin
  Org[0] := WX(0);
  Org[1] := WY(0);
  Org[2] := WZ(0);
  Size[0] := CellXY;
  Size[1] := CellXY;
  Size[2] := CellZ;
  for Ax := 0 to 2 do
  begin
    Cell[Ax] := Floor((A[Ax] - Org[Ax]) / Size[Ax]);
    Target[Ax] := Floor((B[Ax] - Org[Ax]) / Size[Ax]);
    D := B[Ax] - A[Ax];
    if D > 1e-6 then
    begin
      StepDir[Ax] := 1;
      TMax[Ax] := ((Cell[Ax] + 1) * Size[Ax] + Org[Ax] - A[Ax]) / D;
      TDelta[Ax] := Size[Ax] / D;
    end else
    if D < -1e-6 then
    begin
      StepDir[Ax] := -1;
      TMax[Ax] := (Cell[Ax] * Size[Ax] + Org[Ax] - A[Ax]) / D;
      TDelta[Ax] := -Size[Ax] / D;
    end else
    begin
      StepDir[Ax] := 0;
      TMax[Ax] := 1e30;
      TDelta[Ax] := 1e30;
    end;
  end;
  for Guard := 0 to 1000 do
  begin
    if (Cell[0] = Target[0]) and (Cell[1] = Target[1]) and (Cell[2] = Target[2]) then
      Exit(True);
    Best := 0;
    if TMax[1] < TMax[Best] then
      Best := 1;
    if TMax[2] < TMax[Best] then
      Best := 2;
    if TMax[Best] > 1 then
      Exit(True);
    Cell[Best] := Cell[Best] + StepDir[Best];
    TMax[Best] := TMax[Best] + TDelta[Best];
    if CellSolid(Cell[0], Cell[1], Cell[2]) then
      Exit(False);
  end;
  Result := True;
end;

procedure TRandomMapBuilder.LightFace(var F: TGenFace);
const
  MinLight = 8;
var
  TI: TBSPTexInfo;
  MinS, MaxS, MinT, MaxT, SV, TV, Dist, CosA, Add: Single;
  BMinS, BMinT, W, H, I, J, SI, StyleCount, Slot, L, V: Integer;
  StyleOf: array[0..3] of Integer;
  Near: array of Integer;
  Acc: array of TVector3;
  N, P, Dir, BoxMin, BoxMax: TVector3;
  UA, VA, Ax: Integer;
  Mono: Integer;

  function SlotOf(const Style: Integer): Integer;
  var
    K: Integer;
  begin
    for K := 0 to StyleCount - 1 do
      if StyleOf[K] = Style then
        Exit(K);
    Result := -1;
  end;

begin
  TI := TexInfos[F.TexInfo];
  MinS := 1e30;
  MaxS := -1e30;
  MinT := 1e30;
  MaxT := -1e30;
  BoxMin := Vector3(1e30, 1e30, 1e30);
  BoxMax := Vector3(-1e30, -1e30, -1e30);
  for V := 0 to High(F.Verts) do
  begin
    P := Vertices[F.Verts[V]];
    SV := P[0] * TI.VecS[0] + P[1] * TI.VecS[1] + P[2] * TI.VecS[2] + TI.VecS[3];
    TV := P[0] * TI.VecT[0] + P[1] * TI.VecT[1] + P[2] * TI.VecT[2] + TI.VecT[3];
    MinS := Min(MinS, SV);
    MaxS := Max(MaxS, SV);
    MinT := Min(MinT, TV);
    MaxT := Max(MaxT, TV);
    for Ax := 0 to 2 do
    begin
      BoxMin.Data[Ax] := Min(BoxMin[Ax], P[Ax]);
      BoxMax.Data[Ax] := Max(BoxMax[Ax], P[Ax]);
    end;
  end;
  BMinS := Floor(MinS / 16);
  BMinT := Floor(MinT / 16);
  W := Ceil(MaxS / 16) - BMinS + 1;
  H := Ceil(MaxT / 16) - BMinT + 1;

  N := TVector3.Zero;
  if F.Side = 0 then
    N.Data[F.Axis] := 1
  else
    N.Data[F.Axis] := -1;

  { The lights in reach, in front of the face; style 0 first }
  Near := nil;
  StyleCount := 1;
  StyleOf[0] := 0;
  for L := 0 to High(Lights) do
  begin
    Dist := 0;
    for Ax := 0 to 2 do
      if Lights[L].Pos[Ax] < BoxMin[Ax] then
        Dist := Dist + Sqr(BoxMin[Ax] - Lights[L].Pos[Ax])
      else if Lights[L].Pos[Ax] > BoxMax[Ax] then
        Dist := Dist + Sqr(Lights[L].Pos[Ax] - BoxMax[Ax]);
    if Dist >= Sqr(Lights[L].Value) then
      Continue;
    if (Lights[L].Pos[F.Axis] - F.Plane) * N[F.Axis] <= 0 then
      Continue;
    if (SlotOf(Lights[L].Style) < 0) then
    begin
      if StyleCount >= 4 then
        Continue;
      StyleOf[StyleCount] := Lights[L].Style;
      Inc(StyleCount);
    end;
    SetLength(Near, Length(Near) + 1);
    Near[High(Near)] := L;
  end;

  SetLength(Acc, W * H * StyleCount);
  for I := 0 to High(Acc) do
    Acc[I] := TVector3.Zero;
  for I := 0 to W * H - 1 do
    Acc[I] := Vector3(MinLight, MinLight, MinLight);

  UA := UAxisOf[F.Axis];
  VA := VAxisOf[F.Axis];
  for J := 0 to H - 1 do
    for I := 0 to W - 1 do
    begin
      SV := (BMinS + I) * 16;
      TV := (BMinT + J) * 16;
      P := TVector3.Zero;
      case F.Axis of
        0: begin P.Data[1] := SV; P.Data[2] := -TV; end;
        1: begin P.Data[0] := SV; P.Data[2] := -TV; end;
        else begin P.Data[0] := SV; P.Data[1] := -TV; end;
      end;
      P.Data[UA] := EnsureRange(P[UA], F.UMin + 1, F.UMax - 1);
      P.Data[VA] := EnsureRange(P[VA], F.VMin + 1, F.VMax - 1);
      P.Data[F.Axis] := F.Plane + N[F.Axis];
      for SI := 0 to High(Near) do
      begin
        L := Near[SI];
        Dir := Lights[L].Pos - P;
        Dist := Dir.Length;
        if (Dist >= Lights[L].Value) or (Dist < 1e-3) then
          Continue;
        CosA := TVector3.DotProduct(Dir, N) / Dist;
        if CosA <= 0 then
          Continue;
        if not LineClear(P, Lights[L].Pos) then
          Continue;
        Add := (Lights[L].Value - Dist) * (0.5 + 0.5 * CosA);
        Slot := SlotOf(Lights[L].Style);
        Acc[Slot * W * H + J * W + I] := Acc[Slot * W * H + J * W + I] + Lights[L].Color * Add;
      end;
    end;

  F.LightOfs := LightCount;
  for I := 0 to 3 do
    if I < StyleCount then
      F.Styles[I] := StyleOf[I]
    else
      F.Styles[I] := 255;
  if LightCount + W * H * StyleCount > Length(LightBytes) then
  begin
    SetLength(LightBytes, Max(2 * Length(LightBytes), LightCount + W * H * StyleCount + 65536));
    SetLength(LitBytes, 3 * Length(LightBytes));
  end;
  for I := 0 to W * H * StyleCount - 1 do
  begin
    Mono := Round((Acc[I][0] + Acc[I][1] + Acc[I][2]) / 3);
    LightBytes[LightCount + I] := EnsureRange(Mono, 0, 255);
    LitBytes[3 * (LightCount + I)] := EnsureRange(Round(Acc[I][0]), 0, 255);
    LitBytes[3 * (LightCount + I) + 1] := EnsureRange(Round(Acc[I][1]), 0, 255);
    LitBytes[3 * (LightCount + I) + 2] := EnsureRange(Round(Acc[I][2]), 0, 255);
  end;
  Inc(LightCount, W * H * StyleCount);
end;

procedure TRandomMapBuilder.BuildLightmaps;
var
  F: Integer;
begin
  LightCount := 0;
  for F := 0 to High(Faces) do
    LightFace(Faces[F]);
end;

{ Hull 0 nodes of Tree, appended; leaves: solid ones are leaf 0, empty ones
  new leaves (with the cells' leaf noted when MapLeaves). The index of the
  root node. }
function TRandomMapBuilder.AddHull0(const Tree: TKdTree; const NodeBase: Integer; const MapLeaves: Boolean): Integer;
var
  KdLeafToBsp: array of Integer;
  I, J, K, L, N, Ax, Child: Integer;
  Lf: TRLeaf;
  Nd: TRNode;
  G: TKdGrid;
begin
  G := Tree.Grid;
  SetLength(KdLeafToBsp, Tree.LeafCount);
  for L := 0 to Tree.LeafCount - 1 do
  begin
    if Tree.Leaves[L].Solid then
    begin
      KdLeafToBsp[L] := 0;
      Continue;
    end;
    Lf := Default(TRLeaf);
    Lf.Contents := CONTENTS_EMPTY;
    Lf.VisOfs := -1;
    for Ax := 0 to 2 do
    begin
      Lf.Mins[Ax] := Floor(G.Coords[Ax][Tree.Leaves[L].Lo[Ax]]);
      Lf.Maxs[Ax] := Ceil(G.Coords[Ax][Tree.Leaves[L].Hi[Ax]]);
    end;
    SetLength(BspLeaves, Length(BspLeaves) + 1);
    BspLeaves[High(BspLeaves)] := Lf;
    KdLeafToBsp[L] := High(BspLeaves);
    if MapLeaves then
      for K := Tree.Leaves[L].Lo[2] to Tree.Leaves[L].Hi[2] - 1 do
        for J := Tree.Leaves[L].Lo[1] to Tree.Leaves[L].Hi[1] - 1 do
          for I := Tree.Leaves[L].Lo[0] to Tree.Leaves[L].Hi[0] - 1 do
            LeafOfCell[G.Index(I, J, K)] := High(BspLeaves);
  end;
  for N := 0 to Tree.NodeCount - 1 do
  begin
    Nd := Default(TRNode);
    Nd.PlaneId := PlaneFor(Tree.Nodes[N].Axis, G.Coords[Tree.Nodes[N].Axis][Tree.Nodes[N].Split]);
    for J := 0 to 1 do
    begin
      Child := Tree.Nodes[N].Children[J];
      if Child >= 0 then
        Nd.Children[J] := Word(NodeBase + Child)
      else
        Nd.Children[J] := Word((-(KdLeafToBsp[-(Child + 1)] + 1)) and $FFFF);
    end;
    for Ax := 0 to 2 do
    begin
      Nd.Mins[Ax] := Floor(G.Coords[Ax][Tree.Nodes[N].Lo[Ax]]);
      Nd.Maxs[Ax] := Ceil(G.Coords[Ax][Tree.Nodes[N].Hi[Ax]]);
    end;
    SetLength(BspNodes, Length(BspNodes) + 1);
    BspNodes[High(BspNodes)] := Nd;
  end;
  Result := NodeBase;
end;

{ Clip nodes of a hull tree, appended; the index of its root }
function TRandomMapBuilder.AddHull(const Tree: TKdTree; const Grid: TKdGrid): Integer;
var
  NodeBase, N, J, Child: Integer;
  CN: TRClipNode;
begin
  NodeBase := Length(ClipNodes);
  SetLength(ClipNodes, NodeBase + Tree.NodeCount);
  for N := 0 to Tree.NodeCount - 1 do
  begin
    CN.PlaneId := PlaneFor(Tree.Nodes[N].Axis, Grid.Coords[Tree.Nodes[N].Axis][Tree.Nodes[N].Split]);
    for J := 0 to 1 do
    begin
      Child := Tree.Nodes[N].Children[J];
      if Child >= 0 then
        CN.Children[J] := NodeBase + Child
      else if Tree.Leaves[-(Child + 1)].Solid then
        CN.Children[J] := CONTENTS_SOLID
      else
        CN.Children[J] := CONTENTS_EMPTY;
    end;
    ClipNodes[NodeBase + N] := CN;
  end;
  Result := NodeBase;
end;

function TRandomMapBuilder.Write(out Lit: TMemoryStream): TMemoryStream;
var
  Hdr: TBSPHeader;
  Models: array[0..1] of TBSPModel;
  Hull1Min, Hull1Max, Hull2Min, Hull2Max: TVector3;
  Grid1, Grid2, SubGrid, SubGrid1, SubGrid2: TKdGrid;
  Tree1, Tree2, SubTree, SubTree1, SubTree2: TKdTree;
  SubMin, SubMax: TVector3;
  WorldNodes, F, N, I, J, Ax, Pos, MarkCount: Integer;
  Faces29: array of TRFace;
  Edges: array of TREdge;
  SurfEdges: array of LongInt;
  Marks: array of Word;
  Miptex: TMemoryStream;
  Offsets: array of LongInt;
  Verts: array of TVector3;
  Magic: array[0..3] of AnsiChar;
  Version: LongInt;
  E: TREdge;
  Zero: LongWord;

  procedure Lump(const Index: Integer; const Data: Pointer; const Size: Integer);
  begin
    Zero := 0;
    while Result.Position mod 4 <> 0 do
      Result.WriteBuffer(Zero, 1);
    Hdr.Lumps[Index].Offset := Result.Position;
    Hdr.Lumps[Index].Length := Size;
    if Size > 0 then
      Result.WriteBuffer(Data^, Size);
  end;

begin
  Hull1Min := Vector3(-16, -16, -24);
  Hull1Max := Vector3(16, 16, 32);
  Hull2Min := Vector3(-32, -32, -24);
  Hull2Max := Vector3(32, 32, 64);

  { Leaf 0: the solid leaf shared by all }
  SetLength(BspLeaves, 1);
  BspLeaves[0] := Default(TRLeaf);
  BspLeaves[0].Contents := CONTENTS_SOLID;
  BspLeaves[0].VisOfs := -1;

  { World hull 0 and its leaves (needed by the faces first) }
  SetLength(LeafOfCell, GW * GH * GZ);
  AddHull0(World, 0, True);
  WorldNodes := Length(BspNodes);
  Info.Leaves := Length(BspLeaves);
  Info.Nodes := WorldNodes;

  BuildFaces;
  BuildTexInfos;
  BuildLightmaps;

  { Faces in node order: each node's faces in a row }
  for N := 0 to WorldNodes - 1 do
  begin
    BspNodes[N].FirstFace := 0;
    BspNodes[N].NumFaces := 0;
  end;
  SetLength(Faces29, Length(Faces));
  SetLength(Edges, 1); { edge 0 is never used }
  Edges[0].V0 := 0;
  Edges[0].V1 := 0;
  SurfEdges := nil;
  SetLength(LeafFaces, Length(BspLeaves));
  for F := 0 to High(Faces) do
  begin
    N := Faces[F].Node;
    if BspNodes[N].NumFaces = 0 then
      BspNodes[N].FirstFace := F;
    BspNodes[N].NumFaces := BspNodes[N].NumFaces + 1;
    Faces29[F].PlaneId := PlaneFor(Faces[F].Axis, Faces[F].Plane);
    Faces29[F].Side := Faces[F].Side;
    Faces29[F].FirstEdge := Length(SurfEdges);
    Faces29[F].NumEdges := Length(Faces[F].Verts);
    Faces29[F].TexInfoId := Faces[F].TexInfo;
    for I := 0 to 3 do
      Faces29[F].Styles[I] := Faces[F].Styles[I];
    Faces29[F].LightmapOffset := Faces[F].LightOfs;
    for I := 0 to High(Faces[F].Verts) do
    begin
      E.V0 := Faces[F].Verts[I];
      E.V1 := Faces[F].Verts[(I + 1) mod Length(Faces[F].Verts)];
      SetLength(Edges, Length(Edges) + 1);
      Edges[High(Edges)] := E;
      SetLength(SurfEdges, Length(SurfEdges) + 1);
      SurfEdges[High(SurfEdges)] := High(Edges);
    end;
    for I := 0 to High(Faces[F].Leaves) do
    begin
      J := Faces[F].Leaves[I];
      SetLength(LeafFaces[J], Length(LeafFaces[J]) + 1);
      LeafFaces[J][High(LeafFaces[J])] := F;
    end;
  end;

  { Mark surfaces of the world leaves }
  Marks := nil;
  MarkCount := 0;
  for I := 0 to High(BspLeaves) do
  begin
    BspLeaves[I].FirstMarkSurface := MarkCount;
    BspLeaves[I].NumMarkSurfaces := Length(LeafFaces[I]);
    for J := 0 to High(LeafFaces[I]) do
    begin
      SetLength(Marks, MarkCount + 1);
      Marks[MarkCount] := LeafFaces[I][J];
      Inc(MarkCount);
    end;
  end;

  { World clip hulls }
  Grid1 := MakeClipGrid(Base, Hull1Min, Hull1Max, True);
  Grid2 := MakeClipGrid(Base, Hull2Min, Hull2Max, True);
  Tree1 := TKdTree.Create(Grid1);
  Tree2 := TKdTree.Create(Grid2);
  Models[0] := Default(TBSPModel);
  Models[0].Mins := Vector3(WX(0), WY(0), WZ(0));
  Models[0].Maxs := Vector3(WX(GW), WY(GH), WZ(GZ));
  Models[0].HeadNodes[0] := 0;
  Models[0].HeadNodes[1] := AddHull(Tree1, Grid1);
  Models[0].HeadNodes[2] := AddHull(Tree2, Grid2);
  Models[0].HeadNodes[3] := 0;
  Models[0].VisLeafs := Length(BspLeaves) - 1;
  Models[0].FirstFace := 0;
  Models[0].NumFaces := Length(Faces);
  Tree1.Free;
  Tree2.Free;
  Grid1.Free;
  Grid2.Free;

  { Model 1: the exit trigger, a box over the pad }
  SubMin := Vector3(WX(PadI) - 16, WY(PadJ) - 16, WZ(FloorK[PadI, PadJ]) - 8);
  SubMax := Vector3(WX(PadI + 2) + 16, WY(PadJ + 2) + 16, WZ(FloorK[PadI, PadJ]) + 72);
  SubGrid := TKdGrid.Create(3, 3, 3);
  for Ax := 0 to 2 do
  begin
    SubGrid.Coords[Ax][0] := SubMin[Ax] - 64;
    SubGrid.Coords[Ax][1] := SubMin[Ax];
    SubGrid.Coords[Ax][2] := SubMax[Ax];
    SubGrid.Coords[Ax][3] := SubMax[Ax] + 64;
  end;
  SubGrid.Solid[SubGrid.Index(1, 1, 1)] := True;
  SubGrid.Prepare;
  SubTree := TKdTree.Create(SubGrid);
  SubGrid1 := MakeClipGrid(SubGrid, Hull1Min, Hull1Max, False);
  SubGrid2 := MakeClipGrid(SubGrid, Hull2Min, Hull2Max, False);
  SubTree1 := TKdTree.Create(SubGrid1);
  SubTree2 := TKdTree.Create(SubGrid2);
  Models[1] := Default(TBSPModel);
  Models[1].Mins := SubMin;
  Models[1].Maxs := SubMax;
  Models[1].HeadNodes[0] := AddHull0(SubTree, Length(BspNodes), False);
  Models[1].HeadNodes[1] := AddHull(SubTree1, SubGrid1);
  Models[1].HeadNodes[2] := AddHull(SubTree2, SubGrid2);
  Models[1].FirstFace := Length(Faces);
  Models[1].NumFaces := 0;
  SubTree.Free;
  SubTree1.Free;
  SubTree2.Free;
  SubGrid.Free;
  SubGrid1.Free;
  SubGrid2.Free;
  { The submodel's leaves have no faces }
  for I := Length(LeafFaces) to High(BspLeaves) do
  begin
    BspLeaves[I].FirstMarkSurface := 0;
    BspLeaves[I].NumMarkSurfaces := 0;
  end;
  Info.ClipNodes := Length(ClipNodes);

  { The miptex lump }
  Miptex := TMemoryStream.Create;
  try
    Pos := LongInt(Length(Textures));
    Miptex.WriteBuffer(Pos, 4);
    SetLength(Offsets, Length(Textures));
    Miptex.WriteBuffer(Offsets[0], 4 * Length(Textures));
    for I := 0 to High(Textures) do
    begin
      Zero := 0;
      while Miptex.Position mod 4 <> 0 do
        Miptex.WriteBuffer(Zero, 1);
      Offsets[I] := Miptex.Position;
      Miptex.WriteBuffer(Textures[I].Blob[0], Length(Textures[I].Blob));
    end;
    Miptex.Position := 4;
    Miptex.WriteBuffer(Offsets[0], 4 * Length(Textures));

    EntText := EntText + #0;
    Verts := Vertices;

    Result := TMemoryStream.Create;
    Hdr := Default(TBSPHeader);
    Hdr.Version := BSP_VERSION;
    Result.WriteBuffer(Hdr, SizeOf(Hdr));
    Lump(LUMP_ENTITIES, @EntText[1], Length(EntText));
    Lump(LUMP_PLANES, Pointer(Planes), Length(Planes) * SizeOf(TBSPPlane));
    Lump(LUMP_MIPTEX, Miptex.Memory, Miptex.Size);
    Lump(LUMP_VERTICES, Pointer(Verts), Length(Verts) * SizeOf(TVector3));
    Lump(LUMP_VISIBILITY, nil, 0);
    Lump(LUMP_NODES, Pointer(BspNodes), Length(BspNodes) * SizeOf(TRNode));
    Lump(LUMP_TEXINFO, Pointer(TexInfos), Length(TexInfos) * SizeOf(TBSPTexInfo));
    Lump(LUMP_FACES, Pointer(Faces29), Length(Faces29) * SizeOf(TRFace));
    Lump(LUMP_LIGHTMAPS, Pointer(LightBytes), LightCount);
    Lump(LUMP_CLIPNODES, Pointer(ClipNodes), Length(ClipNodes) * SizeOf(TRClipNode));
    Lump(LUMP_LEAVES, Pointer(BspLeaves), Length(BspLeaves) * SizeOf(TRLeaf));
    Lump(LUMP_MARKSURFACES, Pointer(Marks), Length(Marks) * SizeOf(Word));
    Lump(LUMP_EDGES, Pointer(Edges), Length(Edges) * SizeOf(TREdge));
    Lump(LUMP_SURFEDGES, Pointer(SurfEdges), Length(SurfEdges) * SizeOf(LongInt));
    Lump(LUMP_MODELS, @Models[0], SizeOf(Models));
    Result.Position := 0;
    Result.WriteBuffer(Hdr, SizeOf(Hdr));
    Result.Position := 0;
  finally
    Miptex.Free;
  end;

  Lit := TMemoryStream.Create;
  Magic := 'QLIT';
  Version := 1;
  Lit.WriteBuffer(Magic, 4);
  Lit.WriteBuffer(Version, 4);
  if LightCount > 0 then
    Lit.WriteBuffer(LitBytes[0], 3 * LightCount);
  Lit.Position := 0;
end;

function TRandomMapBuilder.Run(const Donor: TMemoryStream; out Lit: TMemoryStream): TMemoryStream;
begin
  PlaceRooms;
  Connect;
  RankRooms;
  Decorate;
  CheckReachable;
  ChooseTextures(Donor);
  PlaceEntities;
  BuildWorldTree;
  Result := Write(Lit);
end;

{ Public --------------------------------------------------------------------- }

function ParseRandomMapName(const MapName: String; out Seed: LongWord): Boolean;
var
  S: String;
  I: Integer;
  V: Int64;
begin
  Seed := 0;
  S := LowerCase(MapName);
  if Copy(S, 1, Length(RandomMapPrefix)) <> RandomMapPrefix then
    Exit(False);
  S := Copy(S, Length(RandomMapPrefix) + 1, MaxInt);
  if (S = '') or (Length(S) > 9) then
    Exit(False);
  for I := 1 to Length(S) do
    if not (S[I] in ['0'..'9']) then
      Exit(False);
  V := StrToInt64(S);
  Seed := LongWord(V);
  Result := True;
end;

function RandomMapName(const Seed: LongWord): String;
begin
  Result := RandomMapPrefix + IntToStr(Seed);
end;

function NewRandomMapSeed: LongWord;
var
  Mix: QWord;
begin
  Mix := QWord(GetTickCount64) xor QWord(Trunc(Frac(Now) * 86400000));
  Mix := Mix * 6364136223846793005 + 1442695040888963407;
  Result := LongWord((Mix shr 33) mod 999999) + 1;
end;

function BuildRandomMap(const Seed: LongWord; const Donor: TMemoryStream;
  out Lit: TMemoryStream; out Info: TRandomMapInfo): TMemoryStream;
var
  Builder: TRandomMapBuilder;
begin
  Builder := TRandomMapBuilder.Create(Seed);
  try
    Result := Builder.Run(Donor, Lit);
    Info := Builder.Info;
  finally
    Builder.Free;
  end;
  LastRandomMapInfo := Info;
end;

function RandomMapHook(const APath: String): Boolean;
var
  Name: String;
  Seed: LongWord;
  Donor, Bsp, Lit: TMemoryStream;
  Info: TRandomMapInfo;
  Start: QWord;
begin
  Result := False;
  if (Copy(APath, 1, 5) <> 'maps/') or (LowerCase(ExtractFileExt(APath)) <> '.bsp') then
    Exit;
  Name := ChangeFileExt(Copy(APath, 6, MaxInt), '');
  if not ParseRandomMapName(Name, Seed) then
    Exit;
  Start := GetTickCount64;
  Donor := nil;
  if Pak.FileExists('maps/start.bsp') then
    Donor := Pak.GetStream('maps/start.bsp');
  try
    Bsp := BuildRandomMap(Seed, Donor, Lit, Info);
  finally
    Donor.Free;
  end;
  Pak.AddMemoryFile(APath, Bsp);
  Pak.AddMemoryFile(ChangeFileExt(APath, '.lit'), Lit);
  WritelnLog('RandomMap', 'Random map %d: %d rooms (%d reachable), %d corridors, %d monsters, %d items, %d lights, ' +
    '%d faces, %d leaves, %d nodes, %d clipnodes, start %s, exit %s, textures %s, built in %d ms',
    [Seed, Info.Rooms, Info.ReachableRooms, Info.Corridors, Info.Monsters, Info.Items, Info.Lights,
     Info.Faces, Info.Leaves, Info.Nodes, Info.ClipNodes, FmtVec(Info.StartOrigin), FmtVec(Info.ExitOrigin),
     Info.Textures, GetTickCount64 - Start]);
  Result := True;
end;

procedure InstallRandomMaps;
begin
  PakMissingFileHook := @RandomMapHook;
end;

initialization
  InstallRandomMaps;
end.
