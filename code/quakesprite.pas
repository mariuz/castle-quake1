{ Quake 1 sprites (.spr, IDSP version 1): the explosion, bubble and light
  of the original game and the many effect sprites of mods (Arcane
  Dimensions' flames, bubbles and dots). Each frame is a textured quad in
  an X3D Switch; the views place it, pick the frame and make it face the
  camera (TCastleBillboard) like R_DrawSpriteModel. }
unit QuakeSprite;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, Math,
  CastleVectors, CastleScene, CastleTransform, CastleBehaviors, X3DNodes, CastleLog,
  CastleImages, CastleRenderOptions,
  QuakePak, QuakePalette;

const
  { Sprite types (spritegn.h) }
  SPR_VP_PARALLEL_UPRIGHT = 0;
  SPR_FACING_UPRIGHT = 1;
  SPR_VP_PARALLEL = 2;
  SPR_ORIENTED = 3;
  SPR_VP_PARALLEL_ORIENTED = 4;

type
  TSpriteImage = record
    { Left, top of the image from the sprite's origin, and its size }
    OriginX, OriginY: Integer;
    Width, Height: Integer;
    ImageId: String;
  end;

  { A frame: one image, or a group cycling through images at its
    intervals (the end time of each, from the group start) }
  TSpriteFrame = record
    Images: array of TSpriteImage;
    Intervals: array of Single;
    { The index of the first image in the scene's Switch }
    FirstChoice: Integer;
  end;

  TQuakeSprite = class
  private
    FName: String;
    FType: Integer;
    FFrames: array of TSpriteFrame;
    FImageCount: Integer;
    FMaxWidth, FMaxHeight: Integer;
  public
    constructor Create(const AName: String);
    function LoadFromStream(const Stream: TStream): Boolean;
    function FrameCount: Integer;
    property SpriteType: Integer read FType;
    property Name: String read FName;
    { A scene with every image of the sprite in a Switch, none shown }
    function CreateScene: TCastleScene;
    { Show frame Frame at Time (seconds, for group frames) }
    procedure ApplyFrame(const Scene: TCastleScene; const Frame: Integer; const Time: Single);
    { The type faces the camera: a billboard behavior to add to the
      transform holding the scene (nil for the oriented types, which the
      entity's angles turn) }
    function CreateBillboard(const Owner: TComponent): TCastleBillboard;
  end;

  TQuakeSpriteCache = specialize TObjectDictionary<String, TQuakeSprite>;

  TQuakeSpriteManager = class
  private
    FCache: TQuakeSpriteCache;
  public
    constructor Create;
    destructor Destroy; override;
    { Get or load a sprite from the paks, e.g. "progs/s_explod.spr" (nil
      when missing or not a version 1 sprite) }
    function GetSprite(const APath: String): TQuakeSprite;
  end;

var
  SpriteManager: TQuakeSpriteManager;

implementation

constructor TQuakeSprite.Create(const AName: String);
begin
  inherited Create;
  FName := AName;
end;

function TQuakeSprite.FrameCount: Integer;
begin
  Result := Length(FFrames);
end;

function TQuakeSprite.LoadFromStream(const Stream: TStream): Boolean;
var
  Ident: array[0..3] of AnsiChar;
  Version, NumFrames, I, J, FrameType, Count: LongInt;

  function ReadInt: LongInt;
  begin
    Stream.ReadBuffer(Result, 4);
    Result := LEtoN(Result);
  end;

  function ReadFloat: Single;
  var
    L: LongInt;
  begin
    L := ReadInt;
    Move(L, Result, 4);
  end;

  function ReadImage: TSpriteImage;
  var
    Pixels: TBytes;
    Img: TCastleImage;
  begin
    Result.OriginX := ReadInt;
    Result.OriginY := ReadInt;
    Result.Width := ReadInt;
    Result.Height := ReadInt;
    if (Result.Width <= 0) or (Result.Height <= 0) or (Result.Width > 4096) or (Result.Height > 4096) then
      raise EReadError.Create('bad sprite frame size');
    Pixels := nil;
    SetLength(Pixels, Result.Width * Result.Height);
    Stream.ReadBuffer(Pixels[0], Length(Pixels));
    Result.ImageId := 'spr/' + FName + '/' + IntToStr(FImageCount);
    Inc(FImageCount);
    { Palette index 255 is transparent, like the GLQuake sprite loader }
    Img := Palette.DecodeIndexed(@Pixels[0], Result.Width, Result.Height, 255);
    Palette.CacheImage(Result.ImageId, Img);
    FMaxWidth := Max(FMaxWidth, Result.Width);
    FMaxHeight := Max(FMaxHeight, Result.Height);
  end;

begin
  Result := False;
  try
    Stream.ReadBuffer(Ident, 4);
    if Ident <> 'IDSP' then
      Exit;
    Version := ReadInt;
    if Version <> 1 then
    begin
      WritelnWarning('QuakeSprite', 'Sprite "%s" is version %d, only version 1 is read', [FName, Version]);
      Exit;
    end;
    FType := ReadInt;
    ReadFloat; { bounding radius }
    ReadInt; { width }
    ReadInt; { height }
    NumFrames := ReadInt;
    ReadFloat; { beam length }
    ReadInt; { sync type }
    if (NumFrames <= 0) or (NumFrames > 10000) then
      Exit;
    SetLength(FFrames, NumFrames);
    for I := 0 to NumFrames - 1 do
    begin
      FrameType := ReadInt;
      FFrames[I].FirstChoice := FImageCount;
      if FrameType = 0 then
      begin
        SetLength(FFrames[I].Images, 1);
        FFrames[I].Images[0] := ReadImage;
      end else
      begin
        Count := ReadInt;
        if (Count <= 0) or (Count > 10000) then
          Exit;
        SetLength(FFrames[I].Images, Count);
        SetLength(FFrames[I].Intervals, Count);
        for J := 0 to Count - 1 do
          FFrames[I].Intervals[J] := ReadFloat;
        for J := 0 to Count - 1 do
          FFrames[I].Images[J] := ReadImage;
      end;
    end;
    Result := True;
  except
    on E: Exception do
      WritelnWarning('QuakeSprite', 'Cannot read sprite "%s": %s', [FName, E.Message]);
  end;
end;

function TQuakeSprite.CreateScene: TCastleScene;
var
  Root: TX3DRootNode;
  Switch: TSwitchNode;
  I, J: Integer;
  Im: TSpriteImage;
  Shape: TShapeNode;
  Geom: TQuadSetNode;
  Coord: TCoordinateNode;
  TexCoord: TTextureCoordinateNode;
  App: TAppearanceNode;
  Mat: TUnlitMaterialNode;
  Tex: TImageTextureNode;
  TexProps: TTexturePropertiesNode;
  L, R, T, B: Single;
begin
  Result := TCastleScene.Create(nil);
  Root := TX3DRootNode.Create;
  Switch := TSwitchNode.Create('SpriteFrames');
  Switch.WhichChoice := -1;
  Root.AddChildren(Switch);
  for I := 0 to High(FFrames) do
    for J := 0 to High(FFrames[I].Images) do
    begin
      Im := FFrames[I].Images[J];
      { The quad in the sprite's plane: X right, Y up (R_DrawSpriteModel's
        origin is the image's left top corner, Y going down) }
      L := Im.OriginX;
      R := Im.OriginX + Im.Width;
      T := Im.OriginY;
      B := Im.OriginY - Im.Height;
      Coord := TCoordinateNode.Create;
      Coord.SetPoint([Vector3(L, B, 0), Vector3(R, B, 0), Vector3(R, T, 0), Vector3(L, T, 0)]);
      TexCoord := TTextureCoordinateNode.Create;
      TexCoord.SetPoint([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]);
      Geom := TQuadSetNode.Create;
      Geom.Coord := Coord;
      Geom.TexCoord := TexCoord;
      Geom.Solid := False;
      TexProps := TTexturePropertiesNode.Create;
      TexProps.MagnificationFilter := magNearest;
      TexProps.MinificationFilter := minNearestMipmapLinear;
      Tex := TImageTextureNode.Create;
      Tex.SetUrl(['quaketex:/' + Im.ImageId]);
      Tex.RepeatS := False;
      Tex.RepeatT := False;
      Tex.TextureProperties := TexProps;
      Mat := TUnlitMaterialNode.Create;
      Mat.EmissiveColor := Vector3(1, 1, 1);
      App := TAppearanceNode.Create;
      App.Material := Mat;
      App.Texture := Tex;
      App.AlphaMode := amMask;
      Shape := TShapeNode.Create;
      Shape.Geometry := Geom;
      Shape.Appearance := App;
      Switch.AddChildren(Shape);
    end;
  Result.Load(Root, True);
  Result.Collides := False;
  Result.Pickable := False;
  Result.CastShadows := False;
end;

procedure TQuakeSprite.ApplyFrame(const Scene: TCastleScene; const Frame: Integer; const Time: Single);
var
  Switch: TSwitchNode;
  F, I, Choice: Integer;
  Full, T: Single;
begin
  if (Scene = nil) or (Scene.RootNode = nil) or (Length(FFrames) = 0) then
    Exit;
  Switch := Scene.RootNode.TryFindNodeByName(TSwitchNode, 'SpriteFrames', False) as TSwitchNode;
  if Switch = nil then
    Exit;
  F := Frame;
  if (F < 0) or (F >= Length(FFrames)) then
    F := 0;
  Choice := FFrames[F].FirstChoice;
  if Length(FFrames[F].Images) > 1 then
  begin
    { R_GetSpriteFrame: the group's image for the time within its cycle }
    Full := FFrames[F].Intervals[High(FFrames[F].Intervals)];
    if Full > 0 then
    begin
      T := Time - Floor(Time / Full) * Full;
      I := 0;
      while (I < High(FFrames[F].Intervals)) and (FFrames[F].Intervals[I] <= T) do
        Inc(I);
      Choice := FFrames[F].FirstChoice + I;
    end;
  end;
  if Switch.WhichChoice <> Choice then
    Switch.WhichChoice := Choice;
end;

function TQuakeSprite.CreateBillboard(const Owner: TComponent): TCastleBillboard;
begin
  Result := nil;
  case FType of
    SPR_ORIENTED:
      Exit;
    SPR_VP_PARALLEL_UPRIGHT, SPR_FACING_UPRIGHT:
      begin
        Result := TCastleBillboard.Create(Owner);
        Result.AxisOfRotation := Vector3(0, 1, 0);
        { Facing upright turns toward the camera's position }
        Result.MatchCameraDirection := FType = SPR_VP_PARALLEL_UPRIGHT;
      end;
    else
      begin
        { VP_PARALLEL (and VP_PARALLEL_ORIENTED, without its roll) }
        Result := TCastleBillboard.Create(Owner);
        Result.AxisOfRotation := TVector3.Zero;
      end;
  end;
end;

{ TQuakeSpriteManager }

constructor TQuakeSpriteManager.Create;
begin
  inherited Create;
  FCache := TQuakeSpriteCache.Create([doOwnsValues]);
end;

destructor TQuakeSpriteManager.Destroy;
begin
  FCache.Free;
  inherited Destroy;
end;

function TQuakeSpriteManager.GetSprite(const APath: String): TQuakeSprite;
var
  NormPath, Key: String;
  Stream: TMemoryStream;
begin
  NormPath := LowerCase(APath);
  Key := ChangeFileExt(ExtractFileName(NormPath), '');
  { A mounted mod's sprite of the same name is kept apart }
  if Pak.VariantTag(NormPath) <> '' then
    Key := Key + '_' + Pak.VariantTag(NormPath);
  if FCache.TryGetValue(Key, Result) then
    Exit;
  Result := nil;
  Stream := Pak.GetStream(NormPath);
  if Stream = nil then
  begin
    WritelnWarning('QuakeSprite', 'Sprite "%s" not found in PAK', [NormPath]);
    { Not looked for again }
    FCache.Add(Key, nil);
    Exit;
  end;
  try
    Result := TQuakeSprite.Create(Key);
    if Result.LoadFromStream(Stream) then
      WritelnLog('QuakeSprite', 'Loaded sprite "%s": %d frames, type %d', [Key, Result.FrameCount, Result.SpriteType])
    else
      FreeAndNil(Result);
    FCache.Add(Key, Result);
  finally
    Stream.Free;
  end;
end;

initialization
  SpriteManager := TQuakeSpriteManager.Create;

finalization
  FreeAndNil(SpriteManager);
end.
