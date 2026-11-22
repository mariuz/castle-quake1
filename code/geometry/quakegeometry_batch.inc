{ A batch of triangles of one texture and its X3D nodes (material, texture, effects).
  Included by quakegeometry.pas. }

constructor TQuakeGeomBatch.Create(const ATexName: String);
begin
  inherited Create;
  TextureName := ATexName;
  Coords := TVector3List.Create;
  TexCoords := TVector2List.Create;
  LMTexCoords := TVector2List.Create;
  LMStyles := TSingleList.Create;
  Normals := TVector3List.Create;
  Indices := TInt32List.Create;
  IsSky := (Pos('sky', LowerCase(ATexName)) = 1);
  IsLiquid := (Length(ATexName) > 0) and (ATexName[1] = '*');
  IsFence := (Length(ATexName) > 0) and (ATexName[1] = '{');
end;

destructor TQuakeGeomBatch.Destroy;
begin
  Coords.Free;
  TexCoords.Free;
  LMTexCoords.Free;
  LMStyles.Free;
  Normals.Free;
  Indices.Free;
  inherited Destroy;
end;

procedure TQuakeGeomBatch.AddPolygon(const Verts: array of TVector3; const UVs, LMUVs: array of TVector2;
  const Normal: TVector3; const Styles: TVector4);
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
    LMTexCoords.Add(LMUVs[I]);
    LMStyles.Add(Styles.X);
    LMStyles.Add(Styles.Y);
    LMStyles.Add(Styles.Z);
    LMStyles.Add(Styles.W);
    Normals.Add(Normal);
  end;

  { Triangle fan: 0, i, i+1 (Quake winding is clockwise, see Geometry.Ccw) }
  for I := 1 to High(Verts) - 1 do
  begin
    Indices.Add(BaseIdx);
    Indices.Add(BaseIdx + I);
    Indices.Add(BaseIdx + I + 1);
  end;
end;

procedure TQuakeGeomBatch.CreateNodes(const MapName: String; const Lightmaps: TQuakeLightmapSet;
  const SharedAppearance: TAppearanceNode; const SharedTexture: TImageTextureNode);
var
  TexProps: TTexturePropertiesNode;
  UnlitMat: TUnlitMaterialNode;
  PhysMat: TPhysicalMaterialNode;
  LMCoordAttrib, StylesAttrib: TFloatVertexAttributeNode;
  UseLightmap, UseSkyShader, UseSkybox: Boolean;
  SkyEffect, LiquidEffect: TEffectNode;
  FragmentPart: TEffectPartNode;
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
  Geometry.Normal := NormalNode;
  Geometry.SetIndex(Indices);
  { Quake BSP polygons are wound clockwise when seen from the front.
    X3D assumes counter-clockwise, so without this the renderer culls the
    visible side of every wall and you see the map "inside out". }
  Geometry.Ccw := False;
  Geometry.Solid := not IsLiquid;
  Geometry.NormalPerVertex := True; { one (face) normal per vertex }
  Geometry.TexCoord := TexCoordNode;

  UseLightmap := WorldLightmaps and (Lightmaps.Effect <> nil) and (not IsSky) and (not IsLiquid);
  if UseLightmap then
  begin
    { Lightmap coordinates and the face's lightstyles go to the shader as
      vertex attributes }
    LMCoordAttrib := TFloatVertexAttributeNode.Create;
    LMCoordAttrib.NameField := 'quake_lm_coord';
    LMCoordAttrib.NumComponents := 2;
    LMCoordAttrib.FdValue.Items.Count := LMTexCoords.Count * 2;
    Move(LMTexCoords.L^, LMCoordAttrib.FdValue.Items.L^, LMTexCoords.Count * SizeOf(TVector2));
    StylesAttrib := TFloatVertexAttributeNode.Create;
    StylesAttrib.NameField := 'quake_styles';
    StylesAttrib.NumComponents := 4;
    StylesAttrib.FdValue.Items.Assign(LMStyles);
    Geometry.FdAttrib.Add(LMCoordAttrib);
    Geometry.FdAttrib.Add(StylesAttrib);
  end;

  if SharedAppearance <> nil then
  begin
    { The same texture on the same lightmap page in another cluster: one
      appearance for all its shapes (a huge map has thousands of them) }
    Appearance := SharedAppearance;
    TexNode := SharedTexture;
    Shape := TShapeNode.Create;
    Shape.Geometry := Geometry;
    Shape.Appearance := Appearance;
    if IsLiquid then
      Shape.Collision := scNone;
    Exit;
  end;

  Appearance := TAppearanceNode.Create;

  { Texture properties for sharp retro filtering }
  TexProps := TTexturePropertiesNode.Create;
  SetupTextureFilter(TexProps, True);

  { Sky layers exist only for standard 256x128 sky miptexes (see TQuakeBsp.CacheSkyLayers) }
  UseSkybox := IsSky and SkyboxAvailable(SkyboxName);
  UseSkyShader := UseSkybox or (IsSky and
    Palette.HasCachedImage('map/' + MapName + '/' + TextureName + SKY_BACK_SUFFIX));

  if not UseSkyShader then
  begin
    TexNode := TImageTextureNode.Create;
    TexNode.SetUrl(['quaketex:/map/' + MapName + '/' + TextureName]);
    TexNode.RepeatS := True;
    TexNode.RepeatT := True;
    TexNode.TextureProperties := TexProps;
  end;

  UseLightmap := WorldLightmaps and (Lightmaps.Effect <> nil) and (not IsSky) and (not IsLiquid);
  UnlitMat := nil;
  if WorldLightmaps or IsSky or IsLiquid or UseSkyShader then
  begin
    { Quake surfaces are not lit dynamically: the look comes from the baked
      lightmaps, blended by the lightmap shader below }
    UnlitMat := TUnlitMaterialNode.Create;
    UnlitMat.EmissiveColor := Vector3(1, 1, 1);
    Appearance.Material := UnlitMat;
  end else
  begin
    { Dynamic lighting: the surface is lit by the engine's lights (and
      shadow maps) like any PBR material }
    PhysMat := TPhysicalMaterialNode.Create;
    PhysMat.BaseColor := Vector3(1, 1, 1);
    PhysMat.Metallic := 0;
    PhysMat.Roughness := 0.9;
    { A little minlight so unlit corners are not pitch black }
    PhysMat.EmissiveColor := Vector3(0.08, 0.08, 0.08);
    if TexNode <> nil then
      PhysMat.BaseTexture := TexNode;
    Appearance.Material := PhysMat;
  end;

  if UseSkyShader then
  begin
    { No regular texture: the sky effect computes the color from both layers
      of the scrolling sky, or from the six faces of the skybox }
    if UseSkybox then
      SkyEffect := CreateSkyEffect(MapName, TextureName, SkyboxName, SkyTimeField, SkyEyeField)
    else
      SkyEffect := CreateSkyEffect(MapName, TextureName, '', SkyTimeField, SkyEyeField);
    Appearance.SetEffects([SkyEffect]);
    Geometry.TexCoord := TexCoordNode;
  end else
  if UseLightmap then
  begin
    Appearance.Texture := TexNode;
    { (the lightmap coordinates and lightstyles are vertex attributes of
      the geometry, added above) }
    if IsFence then
      Appearance.SetEffects([CreateFenceEffect, Lightmaps.Effect])
    else
      Appearance.SetEffects([Lightmaps.Effect]);
  end else
  begin
    if UnlitMat <> nil then
      Appearance.Texture := TexNode;
    Geometry.TexCoord := TexCoordNode;
  end;

  if IsLiquid and (UnlitMat <> nil) then
  begin
    UnlitMat.Transparency := 1 - DefaultLiquidAlpha;
    Appearance.AlphaMode := amBlend;
    { The turbulent texture warp }
    LiquidEffect := TEffectNode.Create;
    LiquidEffect.Language := slGLSL;
    LiquidEffect.UniformMissing := umIgnore;
    LiquidTimeField := TSFFloat.Create(LiquidEffect, True, 'liquid_time', 0);
    LiquidEffect.AddCustomField(LiquidTimeField);
    FragmentPart := TEffectPartNode.Create;
    FragmentPart.ShaderType := stFragment;
    FragmentPart.Contents := LiquidFragmentShader;
    LiquidEffect.SetParts([FragmentPart]);
    Appearance.SetEffects([LiquidEffect]);
  end else
  if IsFence then
    { The holes are cut out in every lighting mode }
    Appearance.AlphaMode := amMask
  else
    Appearance.AlphaMode := amOpaque;

  Shape := TShapeNode.Create;
  Shape.Geometry := Geometry;
  Shape.Appearance := Appearance;
  { Liquid surfaces are not solid in Quake: the player has to be able to dive in }
  if IsLiquid then
    Shape.Collision := scNone;
end;
