{ Quake 2D pictures (qpic): gfx/*.lmp files and gfx.wad lumps, decoded with
  the palette into images for the HUD (palette index 255 is transparent). }
unit QuakePics;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections,
  CastleImages, CastleGLImages, CastleLog,
  QuakePak, QuakePalette;

{ Picture by name: a PAK path ('gfx/complete.lmp') or a gfx.wad lump name
  ('num_0'). Cached; nil when it does not exist. }
function QuakePic(const Name: String): TDrawableImage;

implementation

type
  TWadLump = packed record
    FilePos, DiskSize, Size: LongInt;
    LumpType, Compression: Byte;
    Pad: Word;
    Name: array[0..15] of AnsiChar;
  end;

var
  Pics: specialize TObjectDictionary<String, TDrawableImage>;

{ qpic_t: width, height, then width * height palette indexes, top row first }
function DecodePic(const Data: PByte; const Size: Cardinal): TDrawableImage;
var
  W, H: LongInt;
  Image: TRGBAlphaImage;
begin
  Result := nil;
  if (Data = nil) or (Size < 8) then
    Exit;
  W := PLongInt(Data)^;
  H := PLongInt(Data + 4)^;
  if (W <= 0) or (H <= 0) or (W > 4096) or (H > 4096) or
     (Cardinal(8 + W * H) > Size) then
    Exit;
  Image := Palette.DecodeIndexed(Data + 8, W, H, 255);
  { CGE images start with the bottom row }
  Image.FlipVertical;
  Result := TDrawableImage.Create(Image, True, True);
end;

function FindWadLump(const Name: String; out Size: Cardinal): PByte;
var
  Wad: PByte;
  WadSize: Cardinal;
  Count, DirOfs, I: LongInt;
  Lump: TWadLump;
begin
  Result := nil;
  Size := 0;
  Wad := Pak.GetData('gfx.wad', WadSize);
  if (Wad = nil) or (WadSize < 12) or (PAnsiChar(Wad)[0] <> 'W') then
    Exit;
  Count := PLongInt(Wad + 4)^;
  DirOfs := PLongInt(Wad + 8)^;
  for I := 0 to Count - 1 do
  begin
    if Cardinal(DirOfs + (I + 1) * SizeOf(TWadLump)) > WadSize then
      Exit;
    Move((Wad + DirOfs + I * SizeOf(TWadLump))^, Lump, SizeOf(TWadLump));
    if SameText(String(PAnsiChar(@Lump.Name[0])), Name) and (Lump.Compression = 0) and
       (Cardinal(Lump.FilePos + Lump.DiskSize) <= WadSize) then
    begin
      Size := Lump.DiskSize;
      Exit(Wad + Lump.FilePos);
    end;
  end;
end;

function QuakePic(const Name: String): TDrawableImage;
var
  Key: String;
  Data: PByte;
  Size: Cardinal;
begin
  Key := LowerCase(Name);
  if Pics.TryGetValue(Key, Result) then
    Exit;
  if Pos('/', Key) > 0 then
    Data := Pak.GetData(Key, Size)
  else
    Data := FindWadLump(Key, Size);
  Result := DecodePic(Data, Size);
  if Result = nil then
    WritelnWarning('QuakePics', 'Picture "%s" not found', [Name]);
  Pics.Add(Key, Result);
end;

initialization
  Pics := specialize TObjectDictionary<String, TDrawableImage>.Create([doOwnsValues]);
finalization
  FreeAndNil(Pics);
end.
