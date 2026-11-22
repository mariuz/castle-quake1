{ The lightmap atlas pages and the lightmap shader of a page.
  Included by quakegeometry.pas. }

constructor TQuakeLightmapAtlas.Create(const AWidth, AMaxHeight: Integer; const ARgb: Boolean);
var
  X, Y, L: Integer;
begin
  inherited Create;
  FWidth := AWidth;
  FHeight := AMaxHeight;
  FRgb := ARgb;
  if FRgb then
    FChannels := 3
  else
    FChannels := 1;
  { Only the lightstyle layers faces use get memory (NeedLayer) }
  NeedLayer(0);
  { Reserve a 4x4 block at (0,0) filled with 128 (mid-gray = 1.0 with the x2
    overbright) so faces without a lightmap can sample (2,2) without bleeding }
  for Y := 0 to 3 do
    for X := 0 to 3 do
      FillChar(FData[0][(Y * FWidth + X) * FChannels], FChannels, 128);
  FLayerUsed[0] := True;
  { The first shelf holds the block, with 1 texel padding after it }
  SetLength(FShelves, 1);
  FShelves[0].Y := 0;
  FShelves[0].H := 4;
  FShelves[0].X := 5;
  FNextY := 5;
  FUsedHeight := 4;
end;

procedure TQuakeLightmapAtlas.NeedLayer(const Layer: Integer);
begin
  if Length(FData[Layer]) = 0 then
  begin
    SetLength(FData[Layer], FWidth * FHeight * FChannels);
    FillChar(FData[Layer][0], Length(FData[Layer]), 0);
  end;
end;

function TQuakeLightmapAtlas.Allocate(const W, H: Integer; out X, Y: Integer): Boolean;
var
  I, Best: Integer;
begin
  Result := False;
  X := 0;
  Y := 0;
  if (W > FWidth) or (W <= 0) or (H <= 0) then
    Exit;
  { The lowest open shelf the face fits (1 texel padding against bleeding
    with linear filtering): mixing tall and short faces in one shelf wasted
    most of the page on large maps }
  Best := -1;
  for I := 0 to High(FShelves) do
    if (FShelves[I].H >= H) and (FShelves[I].H <= H + 2) and (FShelves[I].X + W + 1 <= FWidth) and
       ((Best < 0) or (FShelves[I].H < FShelves[Best].H)) then
      Best := I;
  if Best < 0 then
  begin
    if FNextY + H > FHeight then
      Exit;
    SetLength(FShelves, Length(FShelves) + 1);
    Best := High(FShelves);
    FShelves[Best].Y := FNextY;
    FShelves[Best].H := H;
    FShelves[Best].X := 0;
    FNextY := FNextY + H + 1;
  end;
  X := FShelves[Best].X;
  Y := FShelves[Best].Y;
  FShelves[Best].X := X + W + 1;
  if Y + H > FUsedHeight then
    FUsedHeight := Y + H;
  Inc(FTexelsUsed, W * H);
  Result := True;
end;

procedure TQuakeLightmapAtlas.SetTexel(const Layer, X, Y: Integer; const Value: Byte);
begin
  SetTexelRgb(Layer, X, Y, Value, Value, Value);
end;

procedure TQuakeLightmapAtlas.SetTexelRgb(const Layer, X, Y: Integer; const R, G, B: Byte);
var
  I: Integer;
begin
  if (Layer >= 0) and (Layer <= 3) and (X >= 0) and (X < FWidth) and (Y >= 0) and (Y < FHeight) then
  begin
    NeedLayer(Layer);
    I := (Y * FWidth + X) * FChannels;
    if FRgb then
    begin
      FData[Layer][I] := R;
      FData[Layer][I + 1] := G;
      FData[Layer][I + 2] := B;
    end else
      FData[Layer][I] := R;
    FLayerUsed[Layer] := True;
  end;
end;

function TQuakeLightmapAtlas.CreateTextureNode(const Layer: Integer): TPixelTextureNode;
var
  Img: TCastleImage;
  Y, H: Integer;
  TexProps: TTexturePropertiesNode;
begin
  Result := nil;
  if (FUsedHeight = 0) or (Layer < 0) or (Layer > 3) or not FLayerUsed[Layer] then
    Exit;

  { The full atlas: the lightmap coordinates were computed against it }
  H := FHeight;
  if FRgb then
    Img := TRGBImage.Create(FWidth, H)
  else
    Img := TGrayscaleImage.Create(FWidth, H);
  for Y := 0 to H - 1 do
    Move(FData[Layer][Y * FWidth * FChannels], Img.PixelPtr(0, Y)^, FWidth * FChannels);

  TexProps := TTexturePropertiesNode.Create;
  TexProps.MagnificationFilter := magLinear;
  TexProps.MinificationFilter := minLinear;
  TexProps.BoundaryModeS := bmClampToEdge;
  TexProps.BoundaryModeT := bmClampToEdge;

  Result := TPixelTextureNode.Create;
  Result.FdImage.Value := Img;
  Result.RepeatS := False;
  Result.RepeatT := False;
  Result.TextureProperties := TexProps;
end;

function TQuakeGeometry.CreateLightmapSet(const Atlas: TQuakeLightmapAtlas): TQuakeLightmapSet;
var
  K, I: Integer;
  VertexPart, FragmentPart: TEffectPartNode;
  Styles: array[0..63] of Single;
begin
  Result := Default(TQuakeLightmapSet);
  if not WorldLightmaps then
    Exit;
  Result.UsedStyles := Atlas.UsedStyles;
  for K := 0 to 3 do
  begin
    Result.Layers[K] := Atlas.CreateTextureNode(K);
    if Result.Layers[K] <> nil then
      Result.LayerCount := K + 1;
  end;
  if Result.LayerCount = 0 then
    Exit;

  Result.Effect := TEffectNode.Create;
  Result.Effect.Language := slGLSL;
  Result.Effect.UniformMissing := umIgnore;
  for K := 0 to Result.LayerCount - 1 do
  begin
    if Result.Layers[K] = nil then
      Result.Layers[K] := Result.Layers[0]; { a slot without data in between }
    Result.Effect.AddCustomField(TSFNode.Create(Result.Effect, False, 'quake_lm' + IntToStr(K), [],
      Result.Layers[K]));
  end;
  Result.Effect.AddCustomField(TSFInt32.Create(Result.Effect, False, 'quake_lm_layers', Result.LayerCount));
  Result.Effect.AddCustomField(TSFInt32.Create(Result.Effect, False, 'quake_lm_rgb', Ord(Atlas.Rgb)));
  for I := 0 to 63 do
    Styles[I] := Lighting.GetStyleMultiplier(I);
  Result.StylesField := TMFFloat.Create(Result.Effect, True, 'quake_lightstyles', Styles);
  Result.Effect.AddCustomField(Result.StylesField);
  Result.DLightsField := TMFVec4f.Create(Result.Effect, True, 'quake_dlights',
    [TVector4.Zero, TVector4.Zero, TVector4.Zero, TVector4.Zero]);
  Result.Effect.AddCustomField(Result.DLightsField);

  VertexPart := TEffectPartNode.Create;
  VertexPart.ShaderType := stVertex;
  VertexPart.Contents := LightmapVertexShader;
  FragmentPart := TEffectPartNode.Create;
  FragmentPart.ShaderType := stFragment;
  FragmentPart.Contents := LightmapFragmentShader;
  Result.Effect.SetParts([VertexPart, FragmentPart]);

  SetLength(FLightmapSets, Length(FLightmapSets) + 1);
  FLightmapSets[High(FLightmapSets)] := Result;
end;
