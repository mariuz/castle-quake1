{ Building the world from the BSP: faces into batches, clusters, shapes, the scenes.
  Included by quakegeometry.pas. }

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

procedure TQuakeGeometry.AddFace(const FaceIdx: Integer; const Batches: TQuakeGeomBatchDict;
  const Atlases: TQuakeLightmapAtlasList);
var
  Atlas: TQuakeLightmapAtlas;
  Page: Integer;
  BatchKey: String;
  NoLightmap: Boolean;
  Face: TBSPFace;
  TexInfo: TBSPTexInfo;
  MipName: String;
  Batch: TQuakeGeomBatch;
  VertCount, V: Integer;
  PolyVerts: array of TVector3;
  PolyUVs: array of TVector2;
  PolyLMUVs: array of TVector2;
  FaceS, FaceT: array of Single;
  PolyNormal: TVector3;
  RawVert: TVector3;
  NumStyles, K: Integer;
  FaceStyles: TVector4;
  MinS, MaxS, MinT, MaxT: Single;
  BMinS, BMinT, BMaxS, BMaxT: Integer;
  SurfW, SurfH, SurfSize: Integer;
  HasLightmap, AllocOk: Boolean;
  AtlasX, AtlasY: Integer;
  SrcPtr: PByte;
  Row, Col: Integer;
  SLux, TLux: Single;
begin
  Face := FBsp.Faces[FaceIdx];
  VertCount := Face.NumEdges;
  if VertCount < 3 then
    Exit;

  if (Face.TexInfoId >= 0) and (Face.TexInfoId < Length(FBsp.TexInfos)) then
  begin
    TexInfo := FBsp.TexInfos[Face.TexInfoId];
    if (TexInfo.Miptex >= 0) and (TexInfo.Miptex < FBsp.Miptexes.Count) then
      MipName := FBsp.Miptexes[TexInfo.Miptex].Name
    else
      MipName := 'default';
  end else
    MipName := 'default';

  if IsInvisibleToolTexture(MipName) then
    Exit;
  { Sky and liquids are drawn without lightmaps (the TQuakeGeomBatch rule) }
  NoLightmap := (Pos('sky', LowerCase(MipName)) = 1) or (Copy(MipName, 1, 1) = '*');
  Atlas := Atlases.Last;
  Page := Atlases.Count - 1;

  SetLength(PolyVerts, VertCount);
  SetLength(PolyUVs, VertCount);
  SetLength(PolyLMUVs, VertCount);
  SetLength(FaceS, VertCount);
  SetLength(FaceT, VertCount);

  PolyNormal := QuakeToCge(FBsp.GetFaceNormal(FaceIdx));

  MinS := 1e30; MaxS := -1e30;
  MinT := 1e30; MaxT := -1e30;

  for V := 0 to VertCount - 1 do
  begin
    RawVert := FBsp.GetFaceVertex(FaceIdx, V);
    PolyVerts[V] := QuakeToCge(RawVert);
    PolyUVs[V] := FBsp.GetFaceTexCoord(RawVert, Face.TexInfoId);

    if (Face.TexInfoId >= 0) and (Face.TexInfoId < Length(FBsp.TexInfos)) then
    begin
      FaceS[V] := RawVert[0] * TexInfo.VecS[0] + RawVert[1] * TexInfo.VecS[1] +
                  RawVert[2] * TexInfo.VecS[2] + TexInfo.VecS[3];
      FaceT[V] := RawVert[0] * TexInfo.VecT[0] + RawVert[1] * TexInfo.VecT[1] +
                  RawVert[2] * TexInfo.VecT[2] + TexInfo.VecT[3];
    end else
    begin
      FaceS[V] := 0;
      FaceT[V] := 0;
    end;

    if FaceS[V] < MinS then MinS := FaceS[V];
    if FaceS[V] > MaxS then MaxS := FaceS[V];
    if FaceT[V] < MinT then MinT := FaceT[V];
    if FaceT[V] > MaxT then MaxT := FaceT[V];
  end;

  BMinS := Floor(MinS / 16.0);
  BMinT := Floor(MinT / 16.0);
  BMaxS := Ceil(MaxS / 16.0);
  BMaxT := Ceil(MaxT / 16.0);
  SurfW := (BMaxS - BMinS) + 1;
  SurfH := (BMaxT - BMinT) + 1;
  SurfSize := SurfW * SurfH;

  { One lightmap per lightstyle slot in use (255 ends the list) }
  NumStyles := 0;
  while (NumStyles < 4) and (Face.Styles[NumStyles] <> 255) do
    Inc(NumStyles);
  FaceStyles := Vector4(Face.Styles[0], Face.Styles[1], Face.Styles[2], Face.Styles[3]);
  HasLightmap := (Face.LightmapOffset >= 0) and (FBsp.Lightmaps <> nil) and (NumStyles > 0) and
                 (SurfW > 0) and (SurfH > 0) and (SurfW <= 256) and (SurfH <= 256) and
                 (Face.LightmapOffset + SurfSize * NumStyles <= LongInt(FBsp.LightmapsSize)) and
                 not NoLightmap;

  AllocOk := False;
  if HasLightmap then
  begin
    AllocOk := Atlas.Allocate(SurfW, SurfH, AtlasX, AtlasY);
    if not AllocOk and (SurfW + 1 <= Atlas.Width) and (SurfH + 5 <= Atlas.Height) then
    begin
      { This page is full: the face starts the next one (it fits an empty
        page below the 4x4 gray block) }
      Atlases.Add(TQuakeLightmapAtlas.Create(Atlas.Width, Atlas.Height, Atlas.Rgb));
      Atlas := Atlases.Last;
      Page := Atlases.Count - 1;
      AllocOk := Atlas.Allocate(SurfW, SurfH, AtlasX, AtlasY);
    end;
    { The page's shader follows the lightstyles of its faces }
    for K := 0 to NumStyles - 1 do
      if Face.Styles[K] < 64 then
        Include(Atlas.UsedStyles, Face.Styles[K]);
    if not AllocOk then
      Inc(FFullbrightFaces);
    if AllocOk then
    begin
      for K := 0 to NumStyles - 1 do
        if Atlas.Rgb then
        begin
          { .lit: three bytes for each byte of the BSP lightmaps }
          SrcPtr := FBsp.LitData + 3 * (Face.LightmapOffset + K * SurfSize);
          for Row := 0 to SurfH - 1 do
            for Col := 0 to SurfW - 1 do
              Atlas.SetTexelRgb(K, AtlasX + Col, AtlasY + Row, (SrcPtr + 3 * (Row * SurfW + Col))^,
                (SrcPtr + 3 * (Row * SurfW + Col) + 1)^, (SrcPtr + 3 * (Row * SurfW + Col) + 2)^);
        end else
        begin
          SrcPtr := FBsp.Lightmaps + Face.LightmapOffset + K * SurfSize;
          for Row := 0 to SurfH - 1 do
            for Col := 0 to SurfW - 1 do
              Atlas.SetTexel(K, AtlasX + Col, AtlasY + Row, (SrcPtr + Row * SurfW + Col)^);
        end;

      for V := 0 to VertCount - 1 do
      begin
        SLux := (FaceS[V] - BMinS * 16.0) / 16.0;
        TLux := (FaceT[V] - BMinT * 16.0) / 16.0;
        PolyLMUVs[V] := Vector2(
          (AtlasX + SLux + 0.5) / Atlas.Width,
          (AtlasY + TLux + 0.5) / Atlas.Height
        );
      end;
    end;
  end;

  if not AllocOk then
  begin
    { Full brightness from the gray block, style 0 }
    for V := 0 to VertCount - 1 do
      PolyLMUVs[V] := Vector2(2.0 / Atlas.Width, 2.0 / Atlas.Height);
    FaceStyles := Vector4(0, 255, 255, 255);
  end;

  { A batch per texture and atlas page (the first page keeps the plain name) }
  if Page = 0 then
    BatchKey := MipName
  else
    BatchKey := MipName + '@' + IntToStr(Page);
  if not Batches.TryGetValue(BatchKey, Batch) then
  begin
    Batch := TQuakeGeomBatch.Create(MipName);
    Batch.LightmapPage := Page;
    Batches.Add(BatchKey, Batch);
  end;

  Batch.AddPolygon(PolyVerts, PolyUVs, PolyLMUVs, PolyNormal, FaceStyles);
end;

procedure TQuakeGeometry.FinishBatches(const Batches: TQuakeGeomBatchDict;
  const LMSets: array of TQuakeLightmapSet; const RootNode: TX3DRootNode; const Cluster: TQuakeVisCluster);
var
  BatchPair: specialize TPair<String, TQuakeGeomBatch>;
  Batch: TQuakeGeomBatch;
  SkySurface: TQuakeSkySurface;
  MapAlpha: Single;
  First: TSharedAppearance;
  Root: TX3DRootNode;
  Key: String;
  LM: TQuakeLightmapSet;
begin
  { The appearances are shared between the batches of one scene (a new
    scene's root has no shapes yet) }
  if (FSharedRoot <> RootNode) or (RootNode.FdChildren.Count = 0) then
  begin
    FSharedRoot := RootNode;
    FSharedBatches.Clear;
  end;
  for BatchPair in Batches do
  begin
    Batch := BatchPair.Value;
    Root := RootNode;
    Key := BatchPair.Key;
    LM := LMSets[EnsureRange(Batch.LightmapPage, 0, High(LMSets))];
    { The world's animated textures go to their own scene, with their own
      copy of the lightmap shader (a node belongs to one scene) }
    if (FAnimRoot <> nil) and (RootNode = FAnimWorldRoot) and (Length(FAnimLMSets) > 0) and
       (Batch.TextureName <> '') and (Batch.TextureName[1] = '+') and (Batch.Coords.Count > 0) then
    begin
      Root := FAnimRoot;
      Key := 'anim/' + Key;
      LM := FAnimLMSets[EnsureRange(Batch.LightmapPage, 0, High(FAnimLMSets))];
      Inc(FAnimShapes);
    end;
    if FSharedBatches.TryGetValue(Key, First) and (First.Appearance <> nil) and
       (First.IsSky = Batch.IsSky) and (First.IsLiquid = Batch.IsLiquid) and (First.IsFence = Batch.IsFence) then
    begin
      Batch.CreateNodes(FBsp.MapName, LM, First.Appearance, First.TexNode);
      if Batch.Shape <> nil then
      begin
        Inc(FSharedCount);
        Root.AddChildren(Batch.Shape);
        if Cluster <> nil then
          Cluster.Shapes.Add(Batch.Shape);
      end;
      { Its texture animation, sky and liquid fields are the first one's }
      Continue;
    end;
    Batch.CreateNodes(FBsp.MapName, LM);
    if Batch.Shape <> nil then
    begin
      First.Appearance := Batch.Appearance;
      First.TexNode := Batch.TexNode;
      First.IsSky := Batch.IsSky;
      First.IsLiquid := Batch.IsLiquid;
      First.IsFence := Batch.IsFence;
      FSharedBatches.AddOrSetValue(Key, First);
      Root.AddChildren(Batch.Shape);
      if Cluster <> nil then
        Cluster.Shapes.Add(Batch.Shape);
      if Batch.TexNode <> nil then
        RegisterAnimNode(Batch.TextureName, Batch.TexNode);
      if Batch.SkyTimeField <> nil then
      begin
        FSkyTimeFields.Add(Batch.SkyTimeField);
        FSkyEyeFields.Add(Batch.SkyEyeField);
      end;
      if Batch.IsSky then
      begin
        SkySurface.Appearance := Batch.Appearance;
        SkySurface.TextureName := Batch.TextureName;
        FSkySurfaces.Add(SkySurface);
      end;
      if Batch.IsLiquid and (Batch.Appearance.Material is TUnlitMaterialNode) then
      begin
        { The map's own opacity of this liquid kind (QuakeSpasm's
          worldspawn keys) stays; the others follow r_wateralpha }
        if WorldspawnLiquidAlpha(FBsp, Batch.TextureName, MapAlpha) then
        begin
          TUnlitMaterialNode(Batch.Appearance.Material).Transparency := 1 - MapAlpha;
          if MapAlpha >= 0.999 then
            Batch.Appearance.AlphaMode := amOpaque;
          if not FLoggedLiquidAlpha then
            WritelnLog('QuakeGeometry', 'Liquid alpha of "%s": %s from the worldspawn',
              [Batch.TextureName, FormatFloat('0.##', MapAlpha)]);
          FLoggedLiquidAlpha := True;
        end else
          FLiquidMaterials.Add(TUnlitMaterialNode(Batch.Appearance.Material));
      end;
      if Batch.LiquidTimeField <> nil then
        FLiquidTimeFields.Add(Batch.LiquidTimeField);
    end;
  end;
end;

procedure TQuakeGeometry.BuildClusters(out FaceCluster: TQuakeIntArray);
var
  SubtreeFaces: array of Integer;
  Mdl: TBSPModel;
  LeafIdx, M, F, C, Other: Integer;
  Leaf: TBSPLeaf;
  LeafLists: array of TIntegerList;
  LiquidOther: array of Integer;
  LiquidLeaves: array of TIntegerList;
  TexInfoId: Integer;
  MipIdx: Integer;

  function CountFaces(const Node: Integer): Integer;
  begin
    if (Node < 0) or (Node >= Length(FBsp.Nodes)) then
      Exit(0);
    Result := FBsp.Nodes[Node].NumFaces +
      CountFaces(FBsp.Nodes[Node].Children[0]) + CountFaces(FBsp.Nodes[Node].Children[1]);
    SubtreeFaces[Node] := Result;
  end;

  procedure AssignNodeFaces(const Node, ClusterIdx: Integer);
  var
    I: Integer;
  begin
    for I := FBsp.Nodes[Node].FirstFace to FBsp.Nodes[Node].FirstFace + FBsp.Nodes[Node].NumFaces - 1 do
      if (I >= 0) and (I < Length(FaceCluster)) then
        FaceCluster[I] := ClusterIdx;
  end;

  procedure Collect(const Node, ClusterIdx: Integer);
  begin
    if (Node < 0) or (Node >= Length(FBsp.Nodes)) then
      Exit;
    AssignNodeFaces(Node, ClusterIdx);
    Collect(FBsp.Nodes[Node].Children[0], ClusterIdx);
    Collect(FBsp.Nodes[Node].Children[1], ClusterIdx);
  end;

  function NewCluster: Integer;
  begin
    FClusters.Add(TQuakeVisCluster.Create);
    Result := FClusters.Count - 1;
  end;

  { Subtrees with few faces become one cluster; a bigger node keeps its
    own faces in a cluster and splits further }
  procedure Split(const Node: Integer);
  begin
    if (Node < 0) or (Node >= Length(FBsp.Nodes)) then
      Exit;
    if SubtreeFaces[Node] <= ClusterMaxFaces then
    begin
      if SubtreeFaces[Node] > 0 then
        Collect(Node, NewCluster);
      Exit;
    end;
    if FBsp.Nodes[Node].NumFaces > 0 then
      AssignNodeFaces(Node, NewCluster);
    Split(FBsp.Nodes[Node].Children[0]);
    Split(FBsp.Nodes[Node].Children[1]);
  end;

  { The leaf behind a liquid face, seen from FromLeaf; -1 when solid }
  function OtherLeaf(const Face, FromLeaf: Integer): Integer;
  var
    Center, N: TVector3;
    I, Cnt, Candidate, Sign: Integer;
  begin
    Result := -1;
    Cnt := FBsp.GetFaceVertexCount(Face);
    if Cnt <= 0 then
      Exit;
    Center := TVector3.Zero;
    for I := 0 to Cnt - 1 do
      Center := Center + FBsp.GetFaceVertex(Face, I);
    Center := Center / Cnt;
    N := FBsp.GetFaceNormal(Face);
    for Sign := -1 to 1 do
      if Sign <> 0 then
      begin
        Candidate := FBsp.PointLeaf(Center + N * (2 * Sign));
        if (Candidate > 0) and (Candidate <> FromLeaf) and (Candidate <= FBsp.VisLeafCount) and
           (FBsp.Leaves[Candidate].Contents <> CONTENTS_SOLID) then
          Exit(Candidate);
      end;
  end;

  procedure Link(const A, B: Integer);
  begin
    if (A <= 0) or (A > High(FLiquidLinks)) or (B <= 0) or (B > High(FLiquidLinks)) then
      Exit;
    if IndexIntArray(FLiquidLinks[A], B) < 0 then
    begin
      SetLength(FLiquidLinks[A], Length(FLiquidLinks[A]) + 1);
      FLiquidLinks[A][High(FLiquidLinks[A])] := B;
    end;
  end;

begin
  SetLength(FaceCluster, FBsp.FaceCount);
  for F := 0 to High(FaceCluster) do
    FaceCluster[F] := -1;
  if (FBsp.ModelCount = 0) or (Length(FBsp.Nodes) = 0) then
    Exit;
  Mdl := FBsp.Models[0];
  if (Mdl.HeadNodes[0] < 0) or (Mdl.HeadNodes[0] >= Length(FBsp.Nodes)) then
    Exit;

  SetLength(SubtreeFaces, Length(FBsp.Nodes));
  CountFaces(Mdl.HeadNodes[0]);
  Split(Mdl.HeadNodes[0]);

  { Faces outside the tree (none in well formed maps) stay always visible }
  C := -1;
  for F := Mdl.FirstFace to Mdl.FirstFace + Mdl.NumFaces - 1 do
    if (F >= 0) and (F < Length(FaceCluster)) and (FaceCluster[F] < 0) then
    begin
      if C < 0 then
        C := NewCluster;
      FaceCluster[F] := C;
    end;

  { A cluster is seen from the leaves listing its faces. The two sides of
    a liquid surface are separate faces, each listed by the leaf it faces:
    those two leaves see each other's PVS through it. }
  SetLength(LeafLists, FClusters.Count);
  for C := 0 to High(LeafLists) do
    LeafLists[C] := TIntegerList.Create;
  SetLength(FLiquidLinks, FBsp.VisLeafCount + 1);
  SetLength(LiquidOther, FBsp.FaceCount);
  SetLength(LiquidLeaves, FBsp.FaceCount);
  for F := 0 to FBsp.FaceCount - 1 do
  begin
    LiquidOther[F] := -1;
    TexInfoId := FBsp.Faces[F].TexInfoId;
    if (TexInfoId >= 0) and (TexInfoId < Length(FBsp.TexInfos)) then
    begin
      MipIdx := FBsp.TexInfos[TexInfoId].Miptex;
      if (MipIdx >= 0) and (MipIdx < FBsp.Miptexes.Count) and
         (Copy(FBsp.Miptexes[MipIdx].Name, 1, 1) = '*') then
        LiquidOther[F] := -2; { liquid, other leaf not looked up yet }
    end;
  end;
  try
    for LeafIdx := 1 to FBsp.VisLeafCount do
    begin
      Leaf := FBsp.Leaves[LeafIdx];
      for M := Leaf.FirstMarkSurface to Leaf.FirstMarkSurface + Leaf.NumMarkSurfaces - 1 do
      begin
        if M >= Length(FBsp.MarkSurfaces) then
          Break;
        F := FBsp.MarkSurfaces[M];
        if F >= Length(FaceCluster) then
          Continue;
        C := FaceCluster[F];
        if (C >= 0) and ((LeafLists[C].Count = 0) or (LeafLists[C].Last <> LeafIdx)) then
          LeafLists[C].Add(LeafIdx);
        if LiquidOther[F] <> -1 then
        begin
          if LiquidOther[F] = -2 then
            LiquidOther[F] := OtherLeaf(F, LeafIdx);
          Other := LiquidOther[F];
          Link(LeafIdx, Other);
          Link(Other, LeafIdx);
          { Leaves listing the same liquid face }
          if LiquidLeaves[F] = nil then
            LiquidLeaves[F] := TIntegerList.Create;
          for Other in LiquidLeaves[F] do
          begin
            Link(LeafIdx, Other);
            Link(Other, LeafIdx);
          end;
          LiquidLeaves[F].Add(LeafIdx);
        end;
      end;
    end;
    for C := 0 to FClusters.Count - 1 do
      FClusters[C].Leaves := LeafLists[C].ToArray;
  finally
    for C := 0 to High(LeafLists) do
      LeafLists[C].Free;
    for F := 0 to High(LiquidLeaves) do
      LiquidLeaves[F].Free;
  end;
end;

procedure TQuakeGeometry.BuildModelGeometry(const ModelIdx: Integer; const RootNode: TX3DRootNode;
  var OutBatches: TQuakeGeomBatchDict; const Clustered: Boolean);
var
  Mdl: TBSPModel;
  FaceIdx, C, P: Integer;
  Texels: Int64;
  Atlases: TQuakeLightmapAtlasList;
  LMSets: array of TQuakeLightmapSet;
  AtlasSize: Integer;
  FaceCluster: TQuakeIntArray;
  ClusterBatches: array of TQuakeGeomBatchDict;
  TotalShapes: Integer;

  procedure CreateLightmapSets;
  var
    I: Integer;
  begin
    SetLength(LMSets, Atlases.Count);
    for I := 0 to Atlases.Count - 1 do
      LMSets[I] := CreateLightmapSet(Atlases[I]);
  end;

begin
  if (ModelIdx < 0) or (ModelIdx >= FBsp.ModelCount) then
    Exit;

  { The world gets big atlas pages, brush entities small ones; a full page
    opens the next one }
  if ModelIdx = 0 then
    AtlasSize := LightmapAtlasSize
  else
    AtlasSize := BrushAtlasSize(FBsp, ModelIdx, Min(512, LightmapAtlasSize));
  FFullbrightFaces := 0;

  Atlases := TQuakeLightmapAtlasList.Create(True);
  try
    Atlases.Add(TQuakeLightmapAtlas.Create(AtlasSize, AtlasSize, FBsp.LitData <> nil));
    Mdl := FBsp.Models[ModelIdx];
    if Clustered then
    begin
      { The world split by BSP subtrees, each with its own texture batches,
        so the shapes outside the camera's PVS can be hidden }
      BuildClusters(FaceCluster);
      FBuildTime.Stage('clusters');
      SetLength(ClusterBatches, FClusters.Count);
      for C := 0 to High(ClusterBatches) do
        ClusterBatches[C] := TQuakeGeomBatchDict.Create([doOwnsValues]);
      try
        for FaceIdx := Mdl.FirstFace to Mdl.FirstFace + Mdl.NumFaces - 1 do
          if (FaceCluster[FaceIdx] >= 0) then
            AddFace(FaceIdx, ClusterBatches[FaceCluster[FaceIdx]], Atlases)
          else
            AddFace(FaceIdx, OutBatches, Atlases);
        FBuildTime.Stage('faces');
        CreateLightmapSets;
        { The animated textures' scene has its own lightmap shader }
        if FAnimRoot <> nil then
        begin
          SetLength(FAnimLMSets, Atlases.Count);
          for C := 0 to Atlases.Count - 1 do
            FAnimLMSets[C] := CreateLightmapSet(Atlases[C]);
        end;
        FBuildTime.Stage('lightmaps');
        for C := 0 to High(ClusterBatches) do
          FinishBatches(ClusterBatches[C], LMSets, RootNode, FClusters[C]);
        FinishBatches(OutBatches, LMSets, RootNode, nil);
        FBuildTime.Stage('shapes');
      finally
        for C := 0 to High(ClusterBatches) do
          ClusterBatches[C].Free;
      end;
      TotalShapes := 0;
      for C := 0 to FClusters.Count - 1 do
        Inc(TotalShapes, FClusters[C].Shapes.Count);
      FVisibleClusters := FClusters.Count;
      FVisibleShapes := TotalShapes;
      FShapeCount := TotalShapes;
      WritelnLog('QuakeGeometry', 'World split into %d PVS clusters, %d shapes, %d leaves',
        [FClusters.Count, TotalShapes, FBsp.VisLeafCount]);
      WritelnLog('QuakeGeometry', 'Appearances: %d of the %d world shapes share the appearance of another',
        [FSharedCount, TotalShapes]);
    end else
    begin
      for FaceIdx := Mdl.FirstFace to Mdl.FirstFace + Mdl.NumFaces - 1 do
        AddFace(FaceIdx, OutBatches, Atlases);
      CreateLightmapSets;
      FinishBatches(OutBatches, LMSets, RootNode, nil);
    end;
    if ((ModelIdx = 0) and Clustered) or (Atlases.Count > 1) or (FFullbrightFaces > 0) then
    begin
      P := 0;
      Texels := 0;
      for C := 0 to Atlases.Count - 1 do
      begin
        Inc(P, Atlases[C].UsedHeight);
        Inc(Texels, Atlases[C].TexelsUsed);
      end;
      WritelnLog('QuakeGeometry', 'Lightmaps of model %d: %d atlas page(s) of %dx%d, %d rows used, %d faces without room, %d%% filled',
        [ModelIdx, Atlases.Count, AtlasSize, AtlasSize, P, FFullbrightFaces,
         Round(100 * Texels / Max(1, Int64(Atlases.Count) * AtlasSize * AtlasSize))]);
    end;
  finally
    Atlases.Free;
  end;
end;

procedure TQuakeGeometry.AddAnimKeepers(const Root: TX3DRootNode);
var
  I: Integer;
  FrameName: String;
  Shape: TShapeNode;
  Geom: TIndexedTriangleSetNode;
  Coord: TCoordinateNode;
  TexCoord: TTextureCoordinateNode;
  App: TAppearanceNode;
  Mat: TUnlitMaterialNode;
  Tex: TImageTextureNode;
  TexProps: TTexturePropertiesNode;
  Center: TVector3;
begin
  { A shape nobody sees (a triangle of no area in the middle of the map)
    for every frame of every animated texture: the frames stay loaded on
    the GPU, so showing the next one uploads nothing }
  FAnimKeepers := 0;
  Center := QuakeToCge((FBsp.Models[0].Mins + FBsp.Models[0].Maxs) * 0.5);
  for I := 0 to FBsp.Miptexes.Count - 1 do
    if (FBsp.Miptexes[I] <> nil) and (FBsp.Miptexes[I].Name <> '') and (FBsp.Miptexes[I].Name[1] = '+') then
    begin
      { (every frame of the map: the brush entities' too) }
      FrameName := FBsp.Miptexes[I].Name;
      Coord := TCoordinateNode.Create;
      Coord.SetPoint([Center, Center, Center]);
      TexCoord := TTextureCoordinateNode.Create;
      TexCoord.SetPoint([Vector2(0, 0), Vector2(0, 0), Vector2(0, 0)]);
      Geom := TIndexedTriangleSetNode.Create;
      Geom.Coord := Coord;
      Geom.TexCoord := TexCoord;
      Geom.SetIndex([0, 1, 2]);
      TexProps := TTexturePropertiesNode.Create;
      SetupTextureFilter(TexProps, True);
      Tex := TImageTextureNode.Create;
      Tex.SetUrl(['quaketex:/map/' + FBsp.MapName + '/' + FrameName]);
      Tex.RepeatS := True;
      Tex.RepeatT := True;
      Tex.TextureProperties := TexProps;
      Mat := TUnlitMaterialNode.Create;
      Mat.EmissiveColor := Vector3(1, 1, 1);
      App := TAppearanceNode.Create;
      App.Material := Mat;
      App.Texture := Tex;
      Shape := TShapeNode.Create;
      Shape.Geometry := Geom;
      Shape.Appearance := App;
      Shape.Collision := scNone;
      Root.AddChildren(Shape);
      Inc(FAnimKeepers);
    end;
end;

procedure TQuakeGeometry.AddToWorld(const Parent: TCastleTransform);
var
  RootWorld: TX3DRootNode;
  Batches: TQuakeGeomBatchDict;
  I: Integer;
begin
  if (FBsp = nil) or (Parent = nil) then
    Exit;

  { The map's skybox, when its six faces are in the paks }
  SkyboxName := WorldspawnSky(FBsp);
  if (SkyboxName <> '') and not SkyboxAvailable(SkyboxName) then
  begin
    WritelnLog('QuakeGeometry', 'Skybox "%s" not found (gfx/env/%0:s{rt,bk,lf,ft,up,dn}.tga), using the sky texture',
      [SkyboxName]);
    SkyboxName := '';
  end else
  if SkyboxName <> '' then
    WritelnLog('QuakeGeometry', 'Skybox "%s"', [SkyboxName]);
  FSkybox := SkyboxName;

  { Build static world model (Model 0) }
  FBuildTime.Start;
  RootWorld := TX3DRootNode.Create;
  { A map with animated textures gets a second, small scene for them }
  FAnimRoot := nil;
  FAnimWorldRoot := RootWorld;
  FAnimShapes := 0;
  SetLength(FAnimLMSets, 0);
  for I := 0 to FBsp.Miptexes.Count - 1 do
    if (FBsp.Miptexes[I] <> nil) and (FBsp.Miptexes[I].Name <> '') and (FBsp.Miptexes[I].Name[1] = '+') then
    begin
      FAnimRoot := TX3DRootNode.Create;
      Break;
    end;
  Batches := TQuakeGeomBatchDict.Create([doOwnsValues]);
  try
    BuildModelGeometry(0, RootWorld, Batches, True);
    FSceneWorld.Load(RootWorld, True);
    if FAnimRoot <> nil then
    begin
      AddAnimKeepers(FAnimRoot);
      FSceneAnim.Load(FAnimRoot, True);
      WritelnLog('QuakeGeometry', 'Animated textures: %d world shapes in their own scene, %d frames kept loaded',
        [FAnimShapes, FAnimKeepers]);
    end;
    FBuildTime.Stage('scene');
  finally
    Batches.Free;
    FAnimRoot := nil;
    FAnimWorldRoot := nil;
  end;

  Parent.Add(FWorldTransform);

  { Setup interactive submodels (doors, plats, buttons) }
  SetupSubmodels(Parent);
  FBuildTime.Stage('brush entities');
  FBuildTime.Report('geometry of ' + FBsp.MapName);
end;
