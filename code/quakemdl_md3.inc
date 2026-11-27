{ MD3 models (Quake III's format, which newer Quake mods ship besides
  .mdl): vertex animation like an Alias model, in several surfaces with a
  texture file each. They load into the structures of TQuakeMdl: the
  surfaces become one mesh, their textures one image side by side (the
  texture coordinates moved into each one's part), so everything that
  draws an Alias model draws these.
  Included by quakemdl.pas. }

{ An image of the paks by its path: as it is named, without its extension
  or with .tga, .png, .jpg (a shader name often has none, or another one) }
function LoadModelTexture(const AName: String): TRGBAlphaImage;
const
  Exts: array[0..3] of String = ('', '.tga', '.png', '.jpg');
  Mimes: array[0..3] of String = ('', 'image/x-tga', 'image/png', 'image/jpeg');
var
  Base, Path, Mime, Ext: String;
  I: Integer;
  Stream: TMemoryStream;
  Loaded: TCastleImage;
begin
  Result := nil;
  Base := LowerCase(StringReplace(AName, '\', '/', [rfReplaceAll]));
  if Base = '' then
    Exit;
  Path := '';
  Mime := '';
  for I := 0 to High(Exts) do
  begin
    if (I = 0) and Pak.FileExists(Base) then
      Path := Base
    else if (I > 0) and Pak.FileExists(ChangeFileExt(Base, Exts[I])) then
      Path := ChangeFileExt(Base, Exts[I]);
    if Path <> '' then
      Break;
  end;
  if Path = '' then
    Exit;
  Ext := LowerCase(ExtractFileExt(Path));
  for I := 1 to High(Exts) do
    if Ext = Exts[I] then
      Mime := Mimes[I];
  if Mime = '' then
    Exit;
  Stream := Pak.GetStream(Path);
  if Stream = nil then
    Exit;
  try
    try
      Loaded := LoadImage(Stream, Mime, [TRGBAlphaImage, TRGBImage]);
    except
      on E: Exception do
      begin
        WritelnWarning('QuakeMdl', 'Cannot read the model texture "%s": %s', [Path, E.Message]);
        Exit;
      end;
    end;
  finally
    Stream.Free;
  end;
  if Loaded is TRGBAlphaImage then
    Result := TRGBAlphaImage(Loaded)
  else if Loaded is TRGBImage then
  begin
    Result := TRGBImage(Loaded).ToRGBAlphaImage;
    Loaded.Free;
  end else
    Loaded.Free;
end;

{ The texture files of a model's surfaces drawn side by side into one image,
  which becomes the model's skin (a gray square for a file the paks do not
  have: Missing lists those). Parts tells where each one is, in texture
  coordinates, half a texel in from its edges so the neighbour's color does
  not bleed in. }
procedure TQuakeMdl.JoinSkin(const Textures: array of String; out Parts: TSkinParts; out W, H: Integer;
  out Missing: String);
var
  Images: array of TRGBAlphaImage;
  Atlas: TRGBAlphaImage;
  I, X: Integer;
  ImgId: String;
begin
  SetLength(Images, Length(Textures));
  SetLength(Parts, Length(Textures));
  W := 0;
  H := 1;
  Missing := '';
  for I := 0 to High(Textures) do
  begin
    Images[I] := LoadModelTexture(Textures[I]);
    if Images[I] = nil then
    begin
      if Missing <> '' then
        Missing := Missing + ', ';
      Missing := Missing + '"' + Textures[I] + '"';
      Images[I] := TRGBAlphaImage.Create(8, 8);
      Images[I].Clear(Vector4Byte(160, 160, 160, 255));
    end;
    Inc(W, Images[I].Width);
    H := Max(H, Images[I].Height);
  end;
  W := Max(W, 1);
  Atlas := TRGBAlphaImage.Create(W, H);
  Atlas.Clear(Vector4Byte(0, 0, 0, 255));
  X := 0;
  for I := 0 to High(Textures) do
  begin
    { (the images' rows go up from the bottom, like the coordinates) }
    Atlas.DrawFrom(Images[I], X, 0, 0, 0, Images[I].Width, Images[I].Height, dmOverwrite);
    Parts[I].U0 := (X + 0.5) / W;
    Parts[I].UScale := (Images[I].Width - 1) / W;
    Parts[I].V0 := 0.5 / H;
    Parts[I].VScale := (Images[I].Height - 1) / H;
    Inc(X, Images[I].Width);
    FreeAndNil(Images[I]);
  end;
  FSkinWidth := W;
  FSkinHeight := H;
  FNumSkins := 1;
  FFlags := 0;
  ImgId := 'mdl/' + FModelName + '/skin0';
  FSkinImageIds.Add(ImgId);
  SetLength(FSkinPixels, 1);
  Palette.CacheImage(ImgId, Atlas);
end;

function TQuakeMdl.LoadMd3(const Data: TBytes): Boolean;
const
  Md3Scale = 1 / 64;
  MaxSurfaces = 32;

  function Fits(const Ofs, Size: Int64): Boolean;
  begin
    Result := (Ofs >= 0) and (Size >= 0) and (Ofs + Size <= Length(Data));
  end;

  function I32(const Ofs: Integer): LongInt;
  begin
    Result := 0;
    if Fits(Ofs, 4) then
      Move(Data[Ofs], Result, 4);
  end;

  function I16(const Ofs: Integer): SmallInt;
  begin
    Result := 0;
    if Fits(Ofs, 2) then
      Move(Data[Ofs], Result, 2);
  end;

  function F32(const Ofs: Integer): Single;
  begin
    Result := 0;
    if Fits(Ofs, 4) then
      Move(Data[Ofs], Result, 4);
  end;

  function Str(const Ofs, MaxLen: Integer): String;
  var
    I: Integer;
  begin
    Result := '';
    for I := 0 to MaxLen - 1 do
    begin
      if not Fits(Ofs + I, 1) or (Data[Ofs + I] = 0) then
        Break;
      Result := Result + Chr(Data[Ofs + I]);
    end;
  end;

type
  TSurface = record
    Ofs, NumVerts, NumTris, OfsTris, OfsSt, OfsXyz: Integer;
    Texture: String;
    FirstVert: Integer;
  end;

var
  NumFrames, NumSurfaces, OfsFrames, OfsSurfaces, S, F, V, T, Ofs, W, H: Integer;
  Surfaces: array of TSurface;
  Frame: TMdlFrame;
  Names: array of String;
  Parts: TSkinParts;
  Missing: String;
begin
  Result := False;
  if not Fits(0, 108) or (Str(0, 4) <> 'IDP3') or (I32(4) <> 15) then
  begin
    WritelnWarning('QuakeMdl', 'Invalid MD3 file "%s"', [FModelName]);
    Exit;
  end;
  NumFrames := I32(76);
  NumSurfaces := I32(84);
  OfsFrames := I32(92);
  OfsSurfaces := I32(100);
  if (NumFrames < 1) or (NumFrames > 4096) or (NumSurfaces < 1) or (NumSurfaces > MaxSurfaces) or
     not Fits(OfsFrames, Int64(NumFrames) * 56) then
  begin
    WritelnWarning('QuakeMdl', 'MD3 "%s": %d frames, %d surfaces', [FModelName, NumFrames, NumSurfaces]);
    Exit;
  end;

  { The surfaces: their sizes and textures }
  SetLength(Surfaces, NumSurfaces);
  Ofs := OfsSurfaces;
  FNumVerts := 0;
  FNumTris := 0;
  for S := 0 to NumSurfaces - 1 do
  begin
    if not Fits(Ofs, 108) or (Str(Ofs, 4) <> 'IDP3') then
      Exit;
    Surfaces[S].Ofs := Ofs;
    Surfaces[S].NumVerts := I32(Ofs + 80);
    Surfaces[S].NumTris := I32(Ofs + 84);
    Surfaces[S].OfsTris := Ofs + I32(Ofs + 88);
    Surfaces[S].OfsSt := Ofs + I32(Ofs + 96);
    Surfaces[S].OfsXyz := Ofs + I32(Ofs + 100);
    Surfaces[S].FirstVert := FNumVerts;
    if (I32(Ofs + 72) <> NumFrames) or (Surfaces[S].NumVerts < 1) or (Surfaces[S].NumVerts > 65536) or
       (Surfaces[S].NumTris < 1) or
       not Fits(Surfaces[S].OfsTris, Int64(Surfaces[S].NumTris) * 12) or
       not Fits(Surfaces[S].OfsSt, Int64(Surfaces[S].NumVerts) * 8) or
       not Fits(Surfaces[S].OfsXyz, Int64(Surfaces[S].NumVerts) * 8 * NumFrames) then
    begin
      WritelnWarning('QuakeMdl', 'MD3 "%s": surface %d is cut short', [FModelName, S]);
      Exit;
    end;
    { The first shader of the surface is its texture }
    if I32(Ofs + 76) > 0 then
      Surfaces[S].Texture := Str(Ofs + I32(Ofs + 92), 64)
    else
      Surfaces[S].Texture := '';
    Inc(FNumVerts, Surfaces[S].NumVerts);
    Inc(FNumTris, Surfaces[S].NumTris);
    if I32(Ofs + 104) <= 0 then
      Exit;
    Ofs := Ofs + I32(Ofs + 104);
  end;

  { The textures side by side as the model's one skin }
  SetLength(Names, NumSurfaces);
  for S := 0 to NumSurfaces - 1 do
    Names[S] := Surfaces[S].Texture;
  JoinSkin(Names, Parts, W, H, Missing);

  { One mesh of all surfaces }
  for S := 0 to NumSurfaces - 1 do
  begin
    for V := 0 to Surfaces[S].NumVerts - 1 do
      FBaseUVs.Add(Vector2(
        Parts[S].U0 + EnsureRange(F32(Surfaces[S].OfsSt + V * 8), 0, 1) * Parts[S].UScale,
        Parts[S].V0 + (1 - EnsureRange(F32(Surfaces[S].OfsSt + V * 8 + 4), 0, 1)) * Parts[S].VScale));
    for T := 0 to Surfaces[S].NumTris * 3 - 1 do
      FIndices.Add(Surfaces[S].FirstVert +
        EnsureRange(I32(Surfaces[S].OfsTris + T * 4), 0, Surfaces[S].NumVerts - 1));
  end;
  for F := 0 to NumFrames - 1 do
  begin
    Frame := TMdlFrame.Create;
    Frame.Name := LowerCase(Trim(Str(OfsFrames + F * 56 + 40, 16)));
    for S := 0 to NumSurfaces - 1 do
    begin
      Ofs := Surfaces[S].OfsXyz + F * Surfaces[S].NumVerts * 8;
      for V := 0 to Surfaces[S].NumVerts - 1 do
        Frame.Coords.Add(QuakeToCge(Vector3(I16(Ofs + V * 8) * Md3Scale, I16(Ofs + V * 8 + 2) * Md3Scale,
          I16(Ofs + V * 8 + 4) * Md3Scale)));
    end;
    FFrames.Add(Frame);
  end;
  WritelnLog('QuakeMdl', 'MD3 "%s": %d surfaces joined (%d vertices, %d triangles, textures %d x %d)',
    [FModelName, NumSurfaces, FNumVerts, FNumTris, W, H]);
  if Missing <> '' then
    WritelnWarning('QuakeMdl', 'MD3 "%s": no texture %s in the paks', [FModelName, Missing]);
  Result := True;
end;
