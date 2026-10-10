{ Quake 1 palette, colormap, and texture image decoding. }
unit QuakePalette;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections,
  CastleVectors, CastleImages, CastleDownload, CastleUriUtils, CastleLog,
  QuakePak;

type
  TQuakeRGB = packed record
    R, G, B: Byte;
  end;

  { Quake 256-color palette and 64-level colormap table. }
  TQuakePalette = class
  private
    FColors: array[0..255] of TQuakeRGB;
    FColormap: array[0..63, 0..255] of Byte;
    FHasPalette: Boolean;
    FHasColormap: Boolean;
    FTextureCache: specialize TObjectDictionary<String, TCastleImage>;
    FProtocolRegistered: Boolean;
  public
    constructor Create;
    destructor Destroy; override;

    { Load palette.lmp and colormap.lmp from currently active PAK. }
    function LoadFromPak: Boolean;

    { Get RGBA byte vector for a palette index. }
    function Color(const Index: Byte; const Alpha: Byte = 255): TVector4Byte;

    { Check if index is in the Quake fullbright range (224..255). }
    function IsFullbright(const Index: Byte): Boolean;

    { Convert 8-bit palette indexed buffer to TRGBAlphaImage.
      If TransparentIndex >= 0, that palette index becomes fully transparent. }
    { FullbrightAlpha: the alpha channel marks the fullbright palette
      entries (224..255) with 255, the rest with 0, for the lightmap shader }
    function DecodeIndexed(const Pixels: PByte; const Width, Height: Integer;
      const TransparentIndex: Integer = -1; const FullbrightAlpha: Boolean = False): TRGBAlphaImage;

    { Add an image to the memory cache under a unique identifier. }
    procedure CacheImage(const AId: String; const Image: TCastleImage);

    { Retrieve an image from cache. }
    function GetCachedImage(const AId: String): TCastleImage;

    { Check if image is cached. }
    function HasCachedImage(const AId: String): Boolean;

    { Register quaketex: URL protocol for on-the-fly texture serving. }
    procedure RegisterProtocol;
    function ReadTex(const Url: String; out MimeType: String): TStream;

    property HasPalette: Boolean read FHasPalette;
    property HasColormap: Boolean read FHasColormap;
  end;

{ Fast uncompressed 32-bit TGA writer for memory streams. }
procedure WriteTga(const Image: TRGBAlphaImage; Stream: TStream);

var
  Palette: TQuakePalette;

implementation

type
  TTgaHeader = packed record
    IdLength: Byte;
    ColorMapType: Byte;
    ImageType: Byte; { 2 = uncompressed true-color }
    ColorMapSpec: array[0..4] of Byte;
    XOrigin: Word;
    YOrigin: Word;
    Width: Word;
    Height: Word;
    PixelDepth: Byte; { 32 }
    ImageDescriptor: Byte; { bit 5 = top-to-bottom, bits 3..0 = alpha depth }
  end;

procedure WriteTga(const Image: TRGBAlphaImage; Stream: TStream);
var
  Hdr: TTgaHeader;
  X, Y: Integer;
  Pixel: PVector4Byte;
  Bgra: array[0..3] of Byte;
begin
  FillChar(Hdr, SizeOf(Hdr), 0);
  Hdr.ImageType := 2; { uncompressed true-color }
  Hdr.Width := Image.Width;
  Hdr.Height := Image.Height;
  Hdr.PixelDepth := 32;
  Hdr.ImageDescriptor := 8 or 32; { 8-bit alpha, origin at top-left }

  Stream.WriteBuffer(Hdr, SizeOf(Hdr));

  { TGA stores BGRA; write rows top to bottom matching ImageDescriptor }
  for Y := 0 to Image.Height - 1 do
  begin
    for X := 0 to Image.Width - 1 do
    begin
      Pixel := Image.PixelPtr(X, Y);
      Bgra[0] := Pixel^[2]; { Blue }
      Bgra[1] := Pixel^[1]; { Green }
      Bgra[2] := Pixel^[0]; { Red }
      Bgra[3] := Pixel^[3]; { Alpha }
      Stream.WriteBuffer(Bgra, 4);
    end;
  end;
end;

{ TQuakePalette }

constructor TQuakePalette.Create;
begin
  inherited Create;
  FTextureCache := specialize TObjectDictionary<String, TCastleImage>.Create([doOwnsValues]);
  FHasPalette := False;
  FHasColormap := False;
  FProtocolRegistered := False;
end;

destructor TQuakePalette.Destroy;
begin
  if FProtocolRegistered then
    CastleDownload.UnregisterUrlProtocol('quaketex');
  FTextureCache.Free;
  inherited Destroy;
end;

function TQuakePalette.LoadFromPak: Boolean;
var
  Data: Pointer;
  Size: Cardinal;
begin
  Result := False;
  if Pak = nil then
    Exit;

  Data := Pak.GetData('gfx/palette.lmp', Size);
  if (Data <> nil) and (Size >= 768) then
  begin
    Move(Data^, FColors[0], 768);
    FHasPalette := True;
    WritelnLog('QuakePalette', 'Loaded gfx/palette.lmp (768 bytes)');
  end else
    WritelnWarning('QuakePalette', 'Failed to load gfx/palette.lmp');

  Data := Pak.GetData('gfx/colormap.lmp', Size);
  if (Data <> nil) and (Size >= 16384) then
  begin
    Move(Data^, FColormap[0, 0], 16384);
    FHasColormap := True;
    WritelnLog('QuakePalette', 'Loaded gfx/colormap.lmp (16384 bytes)');
  end else
    WritelnWarning('QuakePalette', 'Failed to load gfx/colormap.lmp');

  Result := FHasPalette;
end;

function TQuakePalette.Color(const Index: Byte; const Alpha: Byte): TVector4Byte;
begin
  Result := Vector4Byte(FColors[Index].R, FColors[Index].G, FColors[Index].B, Alpha);
end;

function TQuakePalette.IsFullbright(const Index: Byte): Boolean;
begin
  Result := Index >= 224;
end;

function TQuakePalette.DecodeIndexed(const Pixels: PByte; const Width, Height: Integer;
  const TransparentIndex: Integer; const FullbrightAlpha: Boolean): TRGBAlphaImage;
var
  X, Y: Integer;
  Src: PByte;
  Dst: PVector4Byte;
  Idx: Byte;
begin
  Result := TRGBAlphaImage.Create(Width, Height);
  Src := Pixels;
  for Y := 0 to Height - 1 do
  begin
    for X := 0 to Width - 1 do
    begin
      Idx := Src^;
      Inc(Src);
      Dst := Result.PixelPtr(X, Y);
      if (TransparentIndex >= 0) and (Idx = TransparentIndex) then
      begin
        Dst^ := Vector4Byte(0, 0, 0, 0);
      end else
      if FullbrightAlpha and not IsFullbright(Idx) then
        Dst^ := Vector4Byte(FColors[Idx].R, FColors[Idx].G, FColors[Idx].B, 0)
      else
        Dst^ := Vector4Byte(FColors[Idx].R, FColors[Idx].G, FColors[Idx].B, 255);
    end;
  end;
end;

procedure TQuakePalette.CacheImage(const AId: String; const Image: TCastleImage);
begin
  FTextureCache.AddOrSetValue(LowerCase(AId), Image);
end;

function TQuakePalette.GetCachedImage(const AId: String): TCastleImage;
begin
  if not FTextureCache.TryGetValue(LowerCase(AId), Result) then
    Result := nil;
end;

function TQuakePalette.HasCachedImage(const AId: String): Boolean;
begin
  Result := FTextureCache.ContainsKey(LowerCase(AId));
end;

function TQuakePalette.ReadTex(const Url: String; out MimeType: String): TStream;
var
  Path, TexId: String;
  P: Integer;
  Img: TCastleImage;
  RgbAlpha: TRGBAlphaImage;
begin
  Result := nil;
  Path := Url;
  P := Pos(':', Path);
  if P > 0 then Delete(Path, 1, P);
  while (Path <> '') and (Path[1] = '/') do Delete(Path, 1, 1);
  TexId := Path;

  Img := GetCachedImage(TexId);
  if Img = nil then
  begin
    WritelnWarning('QuakePalette', 'Texture not in cache: %s', [TexId]);
    raise EFOpenError.Create('Texture not in cache: ' + TexId);
  end;

  if Img is TRGBAlphaImage then
    RgbAlpha := TRGBAlphaImage(Img)
  else
  begin
    RgbAlpha := TRGBAlphaImage.Create(Img.Width, Img.Height);
    RgbAlpha.DrawFrom(Img, 0, 0);
  end;

  Result := TMemoryStream.Create;
  try
    WriteTga(RgbAlpha, Result);
    Result.Position := 0;
    MimeType := 'image/x-tga';
  finally
    if RgbAlpha <> Img then
      RgbAlpha.Free;
  end;
end;

procedure TQuakePalette.RegisterProtocol;
begin
  if not FProtocolRegistered then
  begin
    CastleDownload.RegisterUrlProtocol('quaketex', @ReadTex, nil);
    FProtocolRegistered := True;
    WritelnLog('QuakePalette', 'Registered "quaketex:" URL protocol');
  end;
end;

initialization
  Palette := TQuakePalette.Create;

finalization
  FreeAndNil(Palette);
end.
