{ Debug overlay: colored lines and boxes (Quake coordinates) drawn over
  the level, rebuilt every frame by whoever has something to show
  (trigger volumes, monster boxes and sight lines, mover bounds, the
  player's BSP leaf). One TCastleScene with a LineSet and per-vertex
  colors, unlit, not colliding. }
unit QuakeDebug;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  CastleVectors, CastleTransform, CastleScene, X3DNodes, CastleUtils,
  QuakeLight;

type
  TQuakeDebugMode = (dbTriggers, dbMonsters, dbMovers, dbLeaf);
  TQuakeDebugModes = set of TQuakeDebugMode;

  TQuakeDebugOverlay = class
  private
    FTransform: TCastleTransform;
    FScene: TCastleScene;
    FCoord: TCoordinateNode;
    FColor: TColorNode;
    FLineSet: TLineSetNode;
    FPoints: TVector3List;
    FColors: TVector3List;
    FCounts: TInt32List;
  public
    constructor Create(const Parent: TCastleTransform);
    destructor Destroy; override;
    procedure Clear;
    { Quake coordinates }
    procedure AddLine(const A, B: TVector3; const Color: TVector3);
    procedure AddBox(const Mins, Maxs: TVector3; const Color: TVector3);
    { A small cross at a point }
    procedure AddMarker(const P: TVector3; const Size: Single; const Color: TVector3);
    { Send the lines to the scene (after the adds of this frame) }
    procedure Commit;
    property Transform: TCastleTransform read FTransform;
  end;

const
  DebugColorTrigger: TVector3 = (X: 0.2; Y: 1.0; Z: 0.3);
  DebugColorTriggerDone: TVector3 = (X: 0.4; Y: 0.4; Z: 0.4);
  DebugColorMonster: TVector3 = (X: 1.0; Y: 0.9; Z: 0.2);
  DebugColorMonsterAlert: TVector3 = (X: 1.0; Y: 0.2; Z: 0.2);
  DebugColorMover: TVector3 = (X: 0.2; Y: 0.8; Z: 1.0);
  DebugColorLeaf: TVector3 = (X: 1.0; Y: 0.3; Z: 1.0);
  DebugColorPlayer: TVector3 = (X: 1.0; Y: 1.0; Z: 1.0);
  DebugColorProjectile: TVector3 = (X: 1.0; Y: 0.6; Z: 0.1);

{ "triggers,monsters" -> the modes; "all" and "off" understood }
function ParseDebugModes(const S: String; const Current: TQuakeDebugModes): TQuakeDebugModes;
function DebugModesToString(const Modes: TQuakeDebugModes): String;

implementation

uses
  X3DFields;

constructor TQuakeDebugOverlay.Create(const Parent: TCastleTransform);
var
  Root: TX3DRootNode;
  Shape: TShapeNode;
  Mat: TUnlitMaterialNode;
begin
  inherited Create;
  FPoints := TVector3List.Create;
  FColors := TVector3List.Create;
  FCounts := TInt32List.Create;

  FCoord := TCoordinateNode.Create;
  FColor := TColorNode.Create;
  FLineSet := TLineSetNode.Create;
  FLineSet.Coord := FCoord;
  FLineSet.Color := FColor;
  Mat := TUnlitMaterialNode.Create;
  Mat.EmissiveColor := Vector3(1, 1, 1);
  Shape := TShapeNode.Create;
  Shape.Geometry := FLineSet;
  Shape.Appearance := TAppearanceNode.Create;
  Shape.Appearance.Material := Mat;
  Root := TX3DRootNode.Create;
  Root.AddChildren(Shape);

  FScene := TCastleScene.Create(nil);
  FScene.Name := 'debug_overlay_scene';
  FScene.Load(Root, True);
  FScene.Collides := False;
  FScene.Pickable := False;
  FScene.CastShadows := False;
  FScene.RenderOptions.LineWidth := 2;
  FTransform := TCastleTransform.Create(nil);
  FTransform.Name := 'debug_overlay';
  FTransform.Add(FScene);
  Parent.Add(FTransform);
end;

destructor TQuakeDebugOverlay.Destroy;
begin
  if (FTransform <> nil) and (FTransform.Parent <> nil) then
    FTransform.Parent.Remove(FTransform);
  FreeAndNil(FTransform); { frees the scene }
  FPoints.Free;
  FColors.Free;
  FCounts.Free;
  inherited Destroy;
end;

procedure TQuakeDebugOverlay.Clear;
begin
  FPoints.Clear;
  FColors.Clear;
  FCounts.Clear;
end;

procedure TQuakeDebugOverlay.AddLine(const A, B: TVector3; const Color: TVector3);
begin
  FPoints.Add(QuakeToCge(A));
  FPoints.Add(QuakeToCge(B));
  FColors.Add(Color);
  FColors.Add(Color);
  FCounts.Add(2);
end;

function Pick(const Cond: Boolean; const A, B: Single): Single;
begin
  if Cond then
    Result := A
  else
    Result := B;
end;

procedure TQuakeDebugOverlay.AddBox(const Mins, Maxs: TVector3; const Color: TVector3);
var
  C: array[0..7] of TVector3;
  I: Integer;
const
  Edges: array[0..11, 0..1] of Integer = ((0, 1), (1, 3), (3, 2), (2, 0), (4, 5), (5, 7), (7, 6), (6, 4),
    (0, 4), (1, 5), (2, 6), (3, 7));
begin
  for I := 0 to 7 do
    C[I] := Vector3(Pick((I and 1) <> 0, Maxs.X, Mins.X), Pick((I and 2) <> 0, Maxs.Y, Mins.Y),
      Pick((I and 4) <> 0, Maxs.Z, Mins.Z));
  for I := 0 to 11 do
    AddLine(C[Edges[I, 0]], C[Edges[I, 1]], Color);
end;

procedure TQuakeDebugOverlay.AddMarker(const P: TVector3; const Size: Single; const Color: TVector3);
begin
  AddLine(P - Vector3(Size, 0, 0), P + Vector3(Size, 0, 0), Color);
  AddLine(P - Vector3(0, Size, 0), P + Vector3(0, Size, 0), Color);
  AddLine(P - Vector3(0, 0, Size), P + Vector3(0, 0, Size), Color);
end;

procedure TQuakeDebugOverlay.Commit;
begin
  FCoord.SetPoint(FPoints);
  FColor.SetColor(FColors);
  FLineSet.FdVertexCount.Items.Assign(FCounts);
  FLineSet.FdVertexCount.Changed;
  FTransform.Exists := FPoints.Count > 0;
end;

function ParseDebugModes(const S: String; const Current: TQuakeDebugModes): TQuakeDebugModes;
var
  Part: String;
begin
  Result := Current;
  for Part in LowerCase(S).Split([',', ' ', ';']) do
  begin
    if Part = 'all' then
      Result := [dbTriggers, dbMonsters, dbMovers, dbLeaf]
    else if (Part = 'off') or (Part = 'none') or (Part = '0') then
      Result := []
    else if Part = 'triggers' then
      Result := Result + [dbTriggers]
    else if Part = 'monsters' then
      Result := Result + [dbMonsters]
    else if Part = 'movers' then
      Result := Result + [dbMovers]
    else if Part = 'leaf' then
      Result := Result + [dbLeaf];
  end;
end;

function DebugModesToString(const Modes: TQuakeDebugModes): String;
begin
  Result := '';
  if dbTriggers in Modes then
    Result := Result + 'triggers ';
  if dbMonsters in Modes then
    Result := Result + 'monsters ';
  if dbMovers in Modes then
    Result := Result + 'movers ';
  if dbLeaf in Modes then
    Result := Result + 'leaf ';
  Result := Trim(Result);
  if Result = '' then
    Result := 'off';
end;

end.
