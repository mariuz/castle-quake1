{ Quake 1 BSP geometry to Castle Game Engine X3D scenes converter. }
unit QuakeGeometry;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, Math,
  CastleVectors, CastleScene, CastleTransform, X3DNodes, CastleLog, CastleColors,
  CastleImages, CastleUtils, CastleRenderOptions,
  QuakeBsp, QuakePalette, QuakeLight;

type
  { A batch of triangles sharing one texture }
  TQuakeGeomBatch = class
  public
    TextureName: String;
    Coords: TVector3List;
    TexCoords: TVector2List;
    Normals: TVector3List;
    Indices: TInt32List;
    TexNode: TImageTextureNode;
    Shape: TShapeNode;
    Geometry: TIndexedTriangleSetNode;
    CoordNode: TCoordinateNode;
    TexCoordNode: TTextureCoordinateNode;
    NormalNode: TNormalNode;
    Appearance: TAppearanceNode;
    Material: TMaterialNode;
    IsSky: Boolean;
    IsLiquid: Boolean;
    constructor Create(const ATexName: String);
    destructor Destroy; override;
    procedure AddPolygon(const Verts: array of TVector3; const UVs: array of TVector2;
      const Normal: TVector3);
    procedure CreateNodes(const MapName: String);
  end;

  TQuakeGeomBatchDict = specialize TObjectDictionary<String, TQuakeGeomBatch>;

  { Movable submodel instance (func_door, func_plat, func_button, etc.) }
  TQuakeSubmodel = class
  public
    ModelIndex: Integer;
    EntityClassName: String;
    Transform: TCastleTransform;
    Scene: TCastleScene;
    Mins: TVector3;
    Maxs: TVector3;
    Origin: TVector3;
    ClosedPos: TVector3;
    OpenPos: TVector3;
    TargetPos: TVector3;
    MoveDir: TVector3;
    Speed: Single;
    WaitTime: Single;
    StateTimer: Single;
    State: (smsClosed, smsOpening, smsOpen, smsClosing);
    Target: String;
    TargetName: String;
    Sounds: Integer;
    constructor Create;
    destructor Destroy; override;
    procedure Update(const SecondsPassed: Single);
    procedure Trigger;
  end;

  TQuakeSubmodelList = specialize TObjectList<TQuakeSubmodel>;

  { Animated texture tracking group }
  TQuakeAnimTex = class
  public
    BaseName: String;
    Frames: TStringList;
    CurrentFrame: Integer;
    TexNodes: specialize TList<TImageTextureNode>;
    Timer: Single;
    MapName: String;
    constructor Create(const ABaseName, AMapName: String);
    destructor Destroy; override;
    procedure AddNode(const Node: TImageTextureNode);
    procedure Update(const SecondsPassed: Single);
  end;

  TQuakeAnimTexList = specialize TObjectList<TQuakeAnimTex>;

  { World geometry builder and manager }
  TQuakeGeometry = class
  private
    FBsp: TQuakeBsp;
    FSceneWorld: TCastleScene;
    FWorldTransform: TCastleTransform;
    FSubmodels: TQuakeSubmodelList;
    FAnimTextures: TQuakeAnimTexList;
    procedure BuildModelGeometry(const ModelIdx: Integer; const RootNode: TX3DRootNode;
      var OutBatches: TQuakeGeomBatchDict);
    procedure SetupSubmodels(const Parent: TCastleTransform);
    procedure RegisterAnimNode(const TexName: String; const Node: TImageTextureNode);
  public
    constructor Create(const ABsp: TQuakeBsp);
    destructor Destroy; override;

    { Build all geometry and add to parent transform (viewport.Items) }
    procedure AddToWorld(const Parent: TCastleTransform);

    { Advance animated textures and submodels }
    procedure Update(const SecondsPassed: Single);

    { Find submodel by targetname or model string like "*1" }
    function FindSubmodel(const AName: String): TQuakeSubmodel;

    property SceneWorld: TCastleScene read FSceneWorld;
    property WorldTransform: TCastleTransform read FWorldTransform;
    property Submodels: TQuakeSubmodelList read FSubmodels;
  end;

implementation

{ TQuakeGeomBatch }

constructor TQuakeGeomBatch.Create(const ATexName: String);
begin
  inherited Create;
  TextureName := ATexName;
  Coords := TVector3List.Create;
  TexCoords := TVector2List.Create;
  Normals := TVector3List.Create;
  Indices := TInt32List.Create;
  IsSky := (Pos('sky', LowerCase(ATexName)) = 1);
  IsLiquid := (Length(ATexName) > 0) and (ATexName[1] = '*');
end;

destructor TQuakeGeomBatch.Destroy;
begin
  Coords.Free;
  TexCoords.Free;
  Normals.Free;
  Indices.Free;
  inherited Destroy;
end;

procedure TQuakeGeomBatch.AddPolygon(const Verts: array of TVector3; const UVs: array of TVector2;
  const Normal: TVector3);
var
  BaseIdx, I: Integer;
begin
  if Length(Verts) < 3 then
    Exit;

  BaseIdx := Coords.Count;
  for I := 0 to High(Verts) do
  begin
    Coords.Add(Verts[I]);
    TexCoords.Add(UVs[I]);
    Normals.Add(Normal);
  end;

  { Triangle fan: 0, i, i+1 }
  for I := 1 to High(Verts) - 1 do
  begin
    Indices.Add(BaseIdx);
    Indices.Add(BaseIdx + I);
    Indices.Add(BaseIdx + I + 1);
  end;
end;

procedure TQuakeGeomBatch.CreateNodes(const MapName: String);
var
  TexProps: TTexturePropertiesNode;
  UnlitMat: TUnlitMaterialNode;
begin
  if Coords.Count = 0 then
    Exit;

  CoordNode := TCoordinateNode.Create;
  CoordNode.SetPoint(Coords);

  TexCoordNode := TTextureCoordinateNode.Create;
  TexCoordNode.SetPoint(TexCoords);

  NormalNode := TNormalNode.Create;
  NormalNode.SetVector(Normals);

  Geometry := TIndexedTriangleSetNode.Create;
  Geometry.Coord := CoordNode;
  Geometry.TexCoord := TexCoordNode;
  Geometry.Normal := NormalNode;
  Geometry.SetIndex(Indices);
  Geometry.Solid := not IsLiquid;
  Geometry.NormalPerVertex := False;

  Appearance := TAppearanceNode.Create;

  { Texture properties for sharp retro filtering }
  TexProps := TTexturePropertiesNode.Create;
  TexProps.MagnificationFilter := magNearest;
  TexProps.MinificationFilter := minNearestMipmapLinear;
  TexProps.AnisotropicDegree := 4;

  TexNode := TImageTextureNode.Create;
  TexNode.SetUrl(['quaketex:/map/' + MapName + '/' + TextureName]);
  TexNode.RepeatS := True;
  TexNode.RepeatT := True;
  TexNode.TextureProperties := TexProps;
  Appearance.Texture := TexNode;

  if IsSky then
  begin
    { Sky is self-illuminated }
    UnlitMat := TUnlitMaterialNode.Create;
    Appearance.Material := UnlitMat;
    Appearance.AlphaMode := amOpaque;
  end else
  begin
    Material := TMaterialNode.Create;
    Material.DiffuseColor := Vector3(1, 1, 1);
    Material.EmissiveColor := Vector3(0.2, 0.2, 0.2);
    Material.AmbientIntensity := 0.4;
    Appearance.Material := Material;
    if IsLiquid then
    begin
      Material.Transparency := 0.35;
      Appearance.AlphaMode := amBlend;
    end else
      Appearance.AlphaMode := amOpaque;
  end;

  Shape := TShapeNode.Create;
  Shape.Geometry := Geometry;
  Shape.Appearance := Appearance;
end;

{ TQuakeSubmodel }

constructor TQuakeSubmodel.Create;
begin
  inherited Create;
  Transform := TCastleTransform.Create(nil);
  Scene := TCastleScene.Create(nil);
  Scene.PreciseCollisions := True;
  Scene.Collides := True;
  Transform.Add(Scene);
  State := smsClosed;
  Speed := 100.0;
  WaitTime := 3.0;
  StateTimer := 0;
end;

destructor TQuakeSubmodel.Destroy;
begin
  Transform.Free;
  inherited Destroy;
end;

procedure TQuakeSubmodel.Update(const SecondsPassed: Single);
var
  Delta: TVector3;
  Dist, Step: Single;
begin
  case State of
    smsOpening:
      begin
        Delta := TargetPos - Transform.Translation;
        Dist := Delta.Length;
        Step := Speed * SecondsPassed;
        if Step >= Dist then
        begin
          Transform.Translation := TargetPos;
          State := smsOpen;
          StateTimer := WaitTime;
        end else
          Transform.Translation := Transform.Translation + Delta.Normalize * Step;
      end;
    smsOpen:
      begin
        if WaitTime > 0 then
        begin
          StateTimer := StateTimer - SecondsPassed;
          if StateTimer <= 0 then
          begin
            State := smsClosing;
            TargetPos := ClosedPos;
          end;
        end;
      end;
    smsClosing:
      begin
        Delta := TargetPos - Transform.Translation;
        Dist := Delta.Length;
        Step := Speed * SecondsPassed;
        if Step >= Dist then
        begin
          Transform.Translation := TargetPos;
          State := smsClosed;
        end else
          Transform.Translation := Transform.Translation + Delta.Normalize * Step;
      end;
    smsClosed:
      ;
  end;
end;

procedure TQuakeSubmodel.Trigger;
begin
  if State = smsClosed then
  begin
    State := smsOpening;
    TargetPos := OpenPos;
  end else
  if (State = smsOpen) and (WaitTime > 0) then
  begin
    StateTimer := WaitTime; { Reset open timer }
  end;
end;

{ TQuakeAnimTex }

constructor TQuakeAnimTex.Create(const ABaseName, AMapName: String);
begin
  inherited Create;
  BaseName := ABaseName;
  MapName := AMapName;
  Frames := TStringList.Create;
  TexNodes := specialize TList<TImageTextureNode>.Create;
  CurrentFrame := 0;
  Timer := 0;
end;

destructor TQuakeAnimTex.Destroy;
begin
  Frames.Free;
  TexNodes.Free;
  inherited Destroy;
end;

procedure TQuakeAnimTex.AddNode(const Node: TImageTextureNode);
begin
  TexNodes.Add(Node);
end;

procedure TQuakeAnimTex.Update(const SecondsPassed: Single);
var
  Node: TImageTextureNode;
  NewFrame: String;
begin
  if Frames.Count <= 1 then
    Exit;

  Timer := Timer + SecondsPassed;
  if Timer >= 0.2 then
  begin
    Timer := 0;
    CurrentFrame := (CurrentFrame + 1) mod Frames.Count;
    NewFrame := Frames[CurrentFrame];
    for Node in TexNodes do
      Node.SetUrl(['quaketex:/map/' + MapName + '/' + NewFrame]);
  end;
end;

{ TQuakeGeometry }

constructor TQuakeGeometry.Create(const ABsp: TQuakeBsp);
begin
  inherited Create;
  FBsp := ABsp;
  FSceneWorld := TCastleScene.Create(nil);
  FSceneWorld.PreciseCollisions := True;
  FSceneWorld.Collides := True;
  FWorldTransform := TCastleTransform.Create(nil);
  FWorldTransform.Add(FSceneWorld);
  FSubmodels := TQuakeSubmodelList.Create(True);
  FAnimTextures := TQuakeAnimTexList.Create(True);
end;

destructor TQuakeGeometry.Destroy;
begin
  FWorldTransform.Free;
  FSubmodels.Free;
  FAnimTextures.Free;
  inherited Destroy;
end;

procedure TQuakeGeometry.RegisterAnimNode(const TexName: String; const Node: TImageTextureNode);
var
  Anim: TQuakeAnimTex;
  BaseKey: String;
  I: Integer;
  Mip: TQuakeMiptex;
begin
  if (Length(TexName) >= 2) and (TexName[1] = '+') then
  begin
    BaseKey := Copy(TexName, 3, Length(TexName));
    Anim := nil;
    for I := 0 to FAnimTextures.Count - 1 do
      if FAnimTextures[I].BaseName = BaseKey then
      begin
        Anim := FAnimTextures[I];
        Break;
      end;

    if Anim = nil then
    begin
      Anim := TQuakeAnimTex.Create(BaseKey, FBsp.MapName);
      FAnimTextures.Add(Anim);
      { Scan all miptexes for matching frames }
      for I := 0 to FBsp.Miptexes.Count - 1 do
      begin
        Mip := FBsp.Miptexes[I];
        if (Length(Mip.Name) >= 2) and (Mip.Name[1] = '+') and
           (Copy(Mip.Name, 3, Length(Mip.Name)) = BaseKey) then
          Anim.Frames.Add(Mip.Name);
      end;
    end;
    Anim.AddNode(Node);
  end;
end;

procedure TQuakeGeometry.BuildModelGeometry(const ModelIdx: Integer; const RootNode: TX3DRootNode;
  var OutBatches: TQuakeGeomBatchDict);
var
  Mdl: TBSPModel;
  FaceIdx, EndFace: Integer;
  Face: TBSPFace;
  TexInfo: TBSPTexInfo;
  MipName: String;
  Batch: TQuakeGeomBatch;
  VertCount, V: Integer;
  PolyVerts: array of TVector3;
  PolyUVs: array of TVector2;
  PolyNormal: TVector3;
  RawVert: TVector3;
  BatchPair: specialize TPair<String, TQuakeGeomBatch>;
begin
  if (ModelIdx < 0) or (ModelIdx >= FBsp.ModelCount) then
    Exit;

  Mdl := FBsp.Models[ModelIdx];
  EndFace := Mdl.FirstFace + Mdl.NumFaces;

  for FaceIdx := Mdl.FirstFace to EndFace - 1 do
  begin
    Face := FBsp.Faces[FaceIdx];
    VertCount := Face.NumEdges;
    if VertCount < 3 then
      Continue;

    if (Face.TexInfoId >= 0) and (Face.TexInfoId < Length(FBsp.TexInfos)) then
    begin
      TexInfo := FBsp.TexInfos[Face.TexInfoId];
      if (TexInfo.Miptex >= 0) and (TexInfo.Miptex < FBsp.Miptexes.Count) then
        MipName := FBsp.Miptexes[TexInfo.Miptex].Name
      else
        MipName := 'default';
    end else
      MipName := 'default';

    if not OutBatches.TryGetValue(MipName, Batch) then
    begin
      Batch := TQuakeGeomBatch.Create(MipName);
      OutBatches.Add(MipName, Batch);
    end;

    SetLength(PolyVerts, VertCount);
    SetLength(PolyUVs, VertCount);
    PolyNormal := QuakeToCge(FBsp.GetFaceNormal(FaceIdx));

    for V := 0 to VertCount - 1 do
    begin
      RawVert := FBsp.GetFaceVertex(FaceIdx, V);
      PolyVerts[V] := QuakeToCge(RawVert);
      PolyUVs[V] := FBsp.GetFaceTexCoord(RawVert, Face.TexInfoId);
    end;

    Batch.AddPolygon(PolyVerts, PolyUVs, PolyNormal);
  end;

  for BatchPair in OutBatches do
  begin
    Batch := BatchPair.Value;
    Batch.CreateNodes(FBsp.MapName);
    if Batch.Shape <> nil then
    begin
      RootNode.AddChildren(Batch.Shape);
      if Batch.TexNode <> nil then
        RegisterAnimNode(Batch.TextureName, Batch.TexNode);
    end;
  end;
end;

procedure TQuakeGeometry.SetupSubmodels(const Parent: TCastleTransform);
var
  I: Integer;
  Ent: TQuakeEntity;
  MdlStr, CName: String;
  MdlIdx: Integer;
  Sub: TQuakeSubmodel;
  Mdl: TBSPModel;
  Root: TX3DRootNode;
  Batches: TQuakeGeomBatchDict;
  AngleVal, SpeedVal, WaitVal, LipVal: Single;
  Rad: Single;
  MoveV: TVector3;
  BoxSize: TVector3;
  Dist: Single;
begin
  for I := 0 to FBsp.Entities.Count - 1 do
  begin
    Ent := FBsp.Entities[I];
    MdlStr := Ent.Model;
    CName := LowerCase(Ent.ClassName);

    if (Length(MdlStr) >= 2) and (MdlStr[1] = '*') then
    begin
      MdlIdx := StrToIntDef(Copy(MdlStr, 2, Length(MdlStr)), -1);
      if (MdlIdx > 0) and (MdlIdx < FBsp.ModelCount) then
      begin
        Mdl := FBsp.Models[MdlIdx];
        Sub := TQuakeSubmodel.Create;
        Sub.ModelIndex := MdlIdx;
        Sub.EntityClassName := CName;
        Sub.Target := Ent.Target;
        Sub.TargetName := Ent.TargetName;
        Sub.Sounds := Ent.Sounds;

        Sub.Mins := QuakeToCge(Mdl.Mins);
        Sub.Maxs := QuakeToCge(Mdl.Maxs);
        Sub.Origin := QuakeToCge(Mdl.Origin);

        SpeedVal := Ent.Speed;
        if SpeedVal <= 0 then SpeedVal := 100.0;
        Sub.Speed := SpeedVal;

        WaitVal := Ent.GetFloat('wait', 3.0);
        Sub.WaitTime := WaitVal;

        LipVal := Ent.GetFloat('lip', 8.0);
        AngleVal := Ent.Angle;

        { Movement direction based on angle and classname }
        if (CName = 'func_door') or (CName = 'func_door_secret') then
        begin
          BoxSize := Sub.Maxs - Sub.Mins;
          if AngleVal = -1 then { Up }
            MoveV := Vector3(0, 1, 0)
          else if AngleVal = -2 then { Down }
            MoveV := Vector3(0, -1, 0)
          else
          begin
            { Quake angles: 0 = East (+X), 90 = North (+Y in Quake, -Z in CGE) }
            Rad := DegToRad(AngleVal);
            MoveV := Vector3(Cos(Rad), 0, -Sin(Rad));
          end;

          { Movement distance matches bounding box size in movement axis minus lip }
          Dist := Abs(MoveV[0] * BoxSize[0]) + Abs(MoveV[1] * BoxSize[1]) + Abs(MoveV[2] * BoxSize[2]) - LipVal;
          if Dist < 16.0 then Dist := 64.0;

          Sub.ClosedPos := Vector3(0, 0, 0);
          Sub.OpenPos := MoveV * Dist;
          Sub.MoveDir := MoveV;
        end else
        if CName = 'func_plat' then
        begin
          { Elevators move down by height of the platform }
          Dist := Ent.GetFloat('height', Abs(Sub.Maxs[1] - Sub.Mins[1]) + 64.0);
          Sub.ClosedPos := Vector3(0, 0, 0);
          Sub.OpenPos := Vector3(0, -Dist, 0);
          Sub.MoveDir := Vector3(0, -1, 0);
        end else
        if CName = 'func_button' then
        begin
          Rad := DegToRad(AngleVal);
          MoveV := Vector3(Cos(Rad), 0, -Sin(Rad));
          Sub.ClosedPos := Vector3(0, 0, 0);
          Sub.OpenPos := MoveV * 4.0; { Button moves in slightly }
          Sub.MoveDir := MoveV;
          Sub.WaitTime := 1.0;
        end;

        Root := TX3DRootNode.Create;
        Batches := TQuakeGeomBatchDict.Create([doOwnsValues]);
        try
          BuildModelGeometry(MdlIdx, Root, Batches);
          Sub.Scene.Load(Root, True);
        finally
          Batches.Free;
        end;

        Parent.Add(Sub.Transform);
        FSubmodels.Add(Sub);
      end;
    end;
  end;

  WritelnLog('QuakeGeometry', 'Configured %d interactive submodels', [FSubmodels.Count]);
end;

procedure TQuakeGeometry.AddToWorld(const Parent: TCastleTransform);
var
  RootWorld: TX3DRootNode;
  Batches: TQuakeGeomBatchDict;
begin
  if (FBsp = nil) or (Parent = nil) then
    Exit;

  { Build static world model (Model 0) }
  RootWorld := TX3DRootNode.Create;
  Batches := TQuakeGeomBatchDict.Create([doOwnsValues]);
  try
    BuildModelGeometry(0, RootWorld, Batches);
    FSceneWorld.Load(RootWorld, True);
  finally
    Batches.Free;
  end;

  Parent.Add(FWorldTransform);

  { Setup interactive submodels (doors, plats, buttons) }
  SetupSubmodels(Parent);
end;

procedure TQuakeGeometry.Update(const SecondsPassed: Single);
var
  Sub: TQuakeSubmodel;
  Anim: TQuakeAnimTex;
begin
  for Sub in FSubmodels do
    Sub.Update(SecondsPassed);

  for Anim in FAnimTextures do
    Anim.Update(SecondsPassed);
end;

function TQuakeGeometry.FindSubmodel(const AName: String): TQuakeSubmodel;
var
  Sub: TQuakeSubmodel;
  TargetNum: Integer;
begin
  Result := nil;
  if Length(AName) = 0 then
    Exit;

  if AName[1] = '*' then
  begin
    TargetNum := StrToIntDef(Copy(AName, 2, Length(AName)), -1);
    for Sub in FSubmodels do
      if Sub.ModelIndex = TargetNum then
        Exit(Sub);
  end else
  begin
    for Sub in FSubmodels do
      if SameText(Sub.TargetName, AName) then
        Exit(Sub);
  end;
end;

end.
