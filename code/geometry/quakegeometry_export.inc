{ Exporting a map as glTF with its textures.
  Included by quakegeometry.pas. }

procedure TTextureExporter.Handle(Node: TX3DNode);
var
  Tex: TImageTextureNode;
  Url, Name, FileName, C: String;
  Img: TCastleImage;
  I: Integer;
begin
  Tex := Node as TImageTextureNode;
  if Tex.FdUrl.Count = 0 then
    Exit;
  Url := Tex.FdUrl.Items[0];
  if Pos('quaketex:/', Url) <> 1 then
    Exit;
  { A file name from the texture name (Quake names have * and + and /) }
  Name := ExtractFileName(Url);
  FileName := '';
  for I := 1 to Length(Name) do
  begin
    C := Name[I];
    if not (Name[I] in ['a'..'z', 'A'..'Z', '0'..'9', '_', '-']) then
      C := '_';
    FileName := FileName + C;
  end;
  FileName := 'textures/' + FileName + '.png';
  if not UriFileExists(OutDir + FileName) then
  begin
    try
      Img := LoadImage(Url);
      try
        SaveImage(Img, OutDir + FileName);
        Inc(Count);
      finally
        Img.Free;
      end;
    except
      on E: Exception do
        WritelnWarning('QuakeGeometry', 'Cannot export texture "%s": %s', [Url, E.Message]);
    end;
  end;
  Tex.SetUrl([FileName]);
end;

function TQuakeGeometry.ExportMap(const Url: String): Boolean;
var
  Root: TX3DRootNode;
  Batches: TQuakeGeomBatchDict;
  ModelRoot: TX3DRootNode;
  T: TTransformNode;
  Light: TPointLightNode;
  Ent: TQuakeEntity;
  I, N: Integer;
  CName: String;
  LightVal: Single;
  Exporter: TTextureExporter;
  OutDir: String;
  SavedLightmaps: Boolean;
begin
  Result := False;
  if FBsp = nil then
    Exit;
  OutDir := ExtractUriPath(Url);
  { The physical materials lit by the exported lights: the lightmap
    atlases and their shader are a thing of this renderer (and megabytes
    of pixels as text) }
  SavedLightmaps := WorldLightmaps;
  WorldLightmaps := False;
  Root := TX3DRootNode.Create;
  Exporter := TTextureExporter.Create;
  try
    Exporter.OutDir := OutDir;
    Exporter.MapName := FBsp.MapName;
    { The world and the brush models, each a named transform }
    for I := 0 to FBsp.ModelCount - 1 do
    begin
      ModelRoot := TX3DRootNode.Create;
      Batches := TQuakeGeomBatchDict.Create([doOwnsValues]);
      try
        BuildModelGeometry(I, ModelRoot, Batches);
      finally
        Batches.Free;
      end;
      T := TTransformNode.Create;
      if I = 0 then
        T.X3DName := 'world'
      else
        T.X3DName := 'model_' + IntToStr(I);
      for N := 0 to FBsp.Entities.Count - 1 do
        if FBsp.Entities[N].Model = '*' + IntToStr(I) then
        begin
          T.X3DName := LowerCase(FBsp.Entities[N].ClassName) + '_' + IntToStr(I);
          Break;
        end;
      T.AddChildren(ModelRoot);
      Root.AddChildren(T);
    end;
    { The light entities }
    N := 0;
    for I := 0 to FBsp.Entities.Count - 1 do
    begin
      Ent := FBsp.Entities[I];
      CName := LowerCase(Ent.ClassName);
      if Pos('light', CName) <> 1 then
        Continue;
      LightVal := Ent.Light;
      if LightVal <= 0 then
        LightVal := 200;
      Light := TPointLightNode.Create;
      Inc(N);
      Light.X3DName := CName + '_' + IntToStr(N);
      Light.Location := QuakeToCge(Ent.Origin);
      Light.Radius := LightVal * 1.8;
      Light.Intensity := LightVal / 200;
      Light.Attenuation := Vector3(1, 4 / Light.Radius, 8 / Sqr(Light.Radius));
      Light.Global := True;
      if (CName = 'light_torch_small_walltorch') or (CName = 'light_flame_large_yellow') then
        Light.Color := Vector3(1.0, 0.75, 0.4)
      else if CName = 'light_fluorospark' then
        Light.Color := Vector3(0.85, 0.9, 1.0)
      else
        Light.Color := Vector3(0.95, 0.92, 0.85);
      Root.AddChildren(Light);
    end;
    { The textures as files next to the model }
    Root.EnumerateNodes(TImageTextureNode, @Exporter.Handle, False);
    SaveNode(Root, Url);
    WritelnLog('QuakeGeometry', 'Exported "%s" to "%s": %d models, %d lights, %d textures',
      [FBsp.MapName, Url, FBsp.ModelCount, N, Exporter.Count]);
    Result := True;
  finally
    WorldLightmaps := SavedLightmaps;
    Exporter.Free;
    Root.Free;
  end;
end;
