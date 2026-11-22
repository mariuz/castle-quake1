{ PVS culling: the clusters the camera sees, the entities in them.
  Included by quakegeometry.pas. }

function TQuakeGeometry.ClusterCount: Integer;
begin
  Result := FClusters.Count;
end;

constructor TQuakeVisCluster.Create;
begin
  inherited Create;
  Shapes := specialize TList<TShapeNode>.Create;
  Visible := True;
end;

destructor TQuakeVisCluster.Destroy;
begin
  Shapes.Free;
  inherited Destroy;
end;

procedure TQuakeGeometry.UpdateVisibility(const CameraPos: TVector3);
begin
  UpdateVisibilityOf([CameraPos]);
end;

procedure TQuakeGeometry.UpdateVisibility2(const CameraPos, SecondPos: TVector3);
begin
  UpdateVisibilityOf([CameraPos, SecondPos]);
end;

procedure TQuakeGeometry.UpdateVisibilityAll(const Positions: array of TVector3);
begin
  if Length(Positions) > 0 then
    UpdateVisibilityOf(Positions);
end;

procedure TQuakeGeometry.SetSkyEye(const EyePos: TVector3);
var
  I: Integer;
begin
  for I := 0 to FSkyEyeFields.Count - 1 do
    FSkyEyeFields[I].Send(EyePos);
end;

procedure TQuakeGeometry.UpdateVisibilityOf(const Positions: array of TVector3);
var
  Leaf, Leaf2, L, L2, I, ByteCount: Integer;
  Others: array of Integer;
  Same: Boolean;
  AllVisible, LiquidSeeThrough, V: Boolean;
  Cluster: TQuakeVisCluster;
  Shape: TShapeNode;
  Done: array of Boolean;

  function Bit(const Bits: TBytes; const LeafIdx: Integer): Boolean; inline;
  begin
    Result := (LeafIdx >= 1) and ((LeafIdx - 1) div 8 < Length(Bits)) and
      ((Bits[(LeafIdx - 1) div 8] and (1 shl ((LeafIdx - 1) and 7))) <> 0);
  end;

begin
  FEntityCount := 0;
  FVisibleEntities := 0;
  if FClusters.Count = 0 then
  begin
    FAllVisible := True;
    Exit;
  end;
  { The cameras' leaves (-1 without culling); the first, the second (-2
    without one) and the rest }
  Others := nil;
  SetLength(Others, Max(0, Length(Positions) - 2));
  Leaf := -1;
  Leaf2 := -2;
  for I := 0 to High(Positions) do
  begin
    if WorldPvsCulling then
      L := FBsp.PointLeaf(CgeToQuake(Positions[I]))
    else
      L := -1;
    case I of
      0: Leaf := L;
      1: Leaf2 := L;
      else Others[I - 2] := L;
    end;
  end;
  LiquidSeeThrough := FLiquidAlpha < 1;
  Same := (Leaf = FCameraLeaf) and (Leaf2 = FSecondLeaf) and (LiquidSeeThrough = FVisLiquidSeeThrough) and
    (Length(Others) = Length(FOtherLeaves));
  if Same then
    for I := 0 to High(Others) do
      if Others[I] <> FOtherLeaves[I] then
        Same := False;
  if Same then
    Exit;
  FCameraLeaf := Leaf;
  FSecondLeaf := Leaf2;
  FOtherLeaves := Others;
  FVisLiquidSeeThrough := LiquidSeeThrough;

  { Outside the map (solid leaf 0) or without vis data everything is drawn }
  AllVisible := (Leaf <= 0) or not FBsp.LeafPVS(Leaf, FVisBits);
  { Every further camera adds its leaf's row }
  for I := 1 to High(Positions) do
  begin
    if AllVisible then
      Break;
    if I = 1 then
      L := Leaf2
    else
      L := Others[I - 2];
    if (L <= 0) or not FBsp.LeafPVS(L, FRowBits) then
      AllVisible := True
    else
    begin
      for L2 := 0 to Min(Length(FVisBits), Length(FRowBits)) - 1 do
        FVisBits[L2] := FVisBits[L2] or FRowBits[L2];
      FVisBits[(L - 1) div 8] := FVisBits[(L - 1) div 8] or (1 shl ((L - 1) and 7));
    end;
  end;
  if not AllVisible then
  begin
    ByteCount := Length(FVisBits);
    FVisBits[(Leaf - 1) div 8] := FVisBits[(Leaf - 1) div 8] or (1 shl ((Leaf - 1) and 7));
    { Maps are not vised through water: through a translucent liquid
      surface the leaves on its other side add their PVS (one hop) }
    if LiquidSeeThrough then
    begin
      SetLength(FExtraBits, ByteCount);
      if ByteCount > 0 then
        FillChar(FExtraBits[0], ByteCount, 0);
      SetLength(Done, 0);
      SetLength(Done, Length(FLiquidLinks));
      for L := 1 to High(FLiquidLinks) do
        if (Length(FLiquidLinks[L]) > 0) and Bit(FVisBits, L) then
          for L2 in FLiquidLinks[L] do
            if not Done[L2] then
            begin
              Done[L2] := True;
              if FBsp.LeafPVS(L2, FRowBits) then
              begin
                for I := 0 to Min(ByteCount, Length(FRowBits)) - 1 do
                  FExtraBits[I] := FExtraBits[I] or FRowBits[I];
              end else
                AllVisible := True;
              FExtraBits[(L2 - 1) div 8] := FExtraBits[(L2 - 1) div 8] or (1 shl ((L2 - 1) and 7));
            end;
      for I := 0 to ByteCount - 1 do
        FVisBits[I] := FVisBits[I] or FExtraBits[I];
    end;
  end;

  FAllVisible := AllVisible;
  FVisibleClusters := 0;
  FVisibleShapes := 0;
  for Cluster in FClusters do
  begin
    V := AllVisible or (Length(Cluster.Leaves) = 0);
    if not V then
      for L in Cluster.Leaves do
        if Bit(FVisBits, L) then
        begin
          V := True;
          Break;
        end;
    if V then
    begin
      Inc(FVisibleClusters);
      Inc(FVisibleShapes, Cluster.Shapes.Count);
    end;
    if V <> Cluster.Visible then
    begin
      Cluster.Visible := V;
      for Shape in Cluster.Shapes do
        Shape.Visible := V;
    end;
  end;
end;

function TQuakeGeometry.BoxVisible(const Mins, Maxs: TVector3): Boolean;
begin
  if FAllVisible then
    Exit(True);
  Result := FBsp.BoxInPvs(Mins, Maxs, FVisBits);
end;

procedure TQuakeGeometry.CullScene(const Scene: TCastleTransform);
var
  Box: TBox3D;
  A, B, Mins, Maxs: TVector3;
  V: Boolean;
begin
  if Scene = nil then
    Exit;
  V := True;
  if not FAllVisible then
  begin
    Box := Scene.WorldBoundingBox;
    if not Box.IsEmpty then
    begin
      A := CgeToQuake(Box.Min);
      B := CgeToQuake(Box.Max);
      { CGE Z flips into Quake Y: take the minimum and maximum again, 1 unit larger }
      Mins := Vector3(Min(A.X, B.X) - 1, Min(A.Y, B.Y) - 1, Min(A.Z, B.Z) - 1);
      Maxs := Vector3(Max(A.X, B.X) + 1, Max(A.Y, B.Y) + 1, Max(A.Z, B.Z) + 1);
      V := BoxVisible(Mins, Maxs);
    end;
  end;
  Scene.Visible := V;
  Inc(FEntityCount);
  if V then
    Inc(FVisibleEntities);
end;
