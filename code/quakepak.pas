{ Quake 1 PAK archive reader and custom URL protocol. Also reads .pk3
  (zip) archives and loose files in a game directory, the way mods ship. }
unit QuakePak;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, ZStream, Math,
  CastleDownload, CastleUriUtils, CastleLog, CastleTransform;

type
  { Where an entry's bytes are: in a .pak (stored), in a .pk3 (zip: stored
    or deflated) or a loose file on disk }
  TQuakePakEntryKind = (pekPak, pekZip, pekFile);

const
  { In front of a path (VariantPath): the original copy of a replaced file }
  OriginalPathMarker = '@original/';

{ A component Name for the engine's inspector: Base made a valid identifier
  (lowercase letters, digits, underscores) with a running number per base,
  like monster_ogre_3 or func_door_7. ResetComponentNames starts the
  numbers again (a new level). }
function ComponentName(const Base: String): String;
procedure ResetComponentNames;
{ Log the transform tree under Root (names and classes), what the
  inspector shows }
procedure LogSceneTree(const Root: TObject; const Category: String);

type
  { Single file entry inside a Quake PAK archive. }
  TQuakePakEntry = record
    Path: String;
    Offset: Cardinal;      { pak: the data; zip: the local file header }
    Size: Cardinal;        { uncompressed size }
    PakIndex: Integer;     { the container (pak, pk3 or directory) }
    Kind: TQuakePakEntryKind;
    CompressedSize: Cardinal;
    Method: Word;          { zip: 0 stored, 8 deflated }
    DiskPath: String;      { loose file }
  end;

  TQuakePakEntryList = specialize TList<TQuakePakEntry>;

  { Asked for a file no container has (a normalized path); True when it
    added the file (QuakeRandomMap builds maps/random<seed>.bsp) }
  TQuakePakMissingFileHook = function(const APath: String): Boolean;

  { A pak, pk3, directory or memory file the entries point into }
  TQuakePakContainer = class
    Name: String;
    { The archive's bytes (nil: a directory of loose files, or unmounted):
      a TMemoryStream, or a TFileStream reading the file on disk when asked }
    Stream: TStream;
    { Where the archive starts in Stream and its size (a pak stored in a
      zip shares the zip's stream) }
    Base, Size: Int64;
    OwnsStream: Boolean;
    Original: Boolean;
    { The MountTag it was added with ('' for the paks of the start) }
    Tag: String;
    Removed: Boolean;
    destructor Destroy; override;
  end;

  { Quake PAK archive manager. Supports stacking multiple PAK files
    (e.g. pak0.pak, pak1.pak) where later paks override earlier ones. }
  TQuakePak = class
  private
    FContainers: specialize TObjectList<TQuakePakContainer>;
    FEntries: TQuakePakEntryList;
    { Entries replaced by a later pak, kept so original maps stay reachable }
    FShadowed: TQuakePakEntryList;
    FProtocolRegistered: Boolean;
    FPreferOriginal: Boolean;
    { Unpacked zip entries and loose files handed out by GetData }
    FDataCache: specialize TObjectDictionary<String, TMemoryStream>;
    FInMissingHook: Boolean;
    FMountTag: String;
    function FindEntryIndex(const APath: String; const AllowHook: Boolean = True): Integer;
    function FindEntry(const APath: String; out Entry: TQuakePakEntry): Boolean;
    function AddContainer(const Name: String; const Stream: TStream; const Base, Size: Int64;
      const OwnsStream, Original: Boolean): Integer;
    { Count bytes at Offset of container Index into Buffer; False out of its bounds }
    function ReadAt(const Index: Integer; const Offset: Int64; var Buffer; const Count: Int64): Boolean;
    function AddPakArchive(const Name: String; const Stream: TStream; const Base, Size: Int64;
      const OwnsStream, Original: Boolean): Boolean;
    function IsOriginal(const Index: Integer): Boolean;
    { A pak file on disk, read from there, under another name }
    function AddPakFile(const Name, FileName: String): Boolean;
    procedure AddEntry(const Entry: TQuakePakEntry);
    function ReadEntry(const Entry: TQuakePakEntry): TMemoryStream;
  public
    constructor Create;
    destructor Destroy; override;

    { Add a PAK archive from file or castle-data URL. Returns true if
      successful. A file on disk stays there, its entries are read when
      asked for (OpenLocalFile); a URL that is no file (the web, Android's
      assets) is copied into memory. }
    function AddFile(const AUrlOrFilename: String; const Original: Boolean = False): Boolean;
    { Add a PAK archive already in memory (the pak owns Stream from now
      on, also on failure): a mod's pak inside its zip }
    function AddPakStream(const Name: String; const Stream: TMemoryStream; const Original: Boolean = False): Boolean;

    { Add a .pk3 (zip) archive from a file or URL: stored and deflated
      entries. Returns true if successful. }
    function AddPk3(const AUrlOrFilename: String): Boolean;
    { The same with the zip's paths moved by Mapping (MapArchivePath): a
      map browser zip whose files land in id1/maps/ }
    function AddPk3(const AUrlOrFilename, Mapping: String; const GameDir: String = 'id1'): Boolean;

    { Add the pak at InnerPath of an archive already added (a mod's pak0.pak
      in its zip): stored in a zip on disk it is read from there, deflated
      it is unpacked once to CacheFile (a filename, '' for none) and read
      from that, else it is copied into memory }
    function AddPakFromArchive(const Name, InnerPath, CacheFile: String): Boolean;

    { Remove every archive added with this MountTag: their files go, the
      ones they replaced come back. Returns how many archives went. }
    function Unmount(const Tag: String): Integer;

    { The bytes the archives hold in memory (the paks and pk3s that are no
      files on disk, memory files, unpacked entries GetData keeps) and how
      many archives are read from disk }
    function MemoryBytes: Int64;
    function DiskArchives: Integer;

    { Add the loose files under a directory (maps/x.bsp, progs/y.mdl...),
      searched below the archives added after it. Returns the file count. }
    function AddDirectory(const Dir: String): Integer;

    { Add a file made in memory (the pak owns Stream from now on), above
      everything added before }
    procedure AddMemoryFile(const APath: String; const Stream: TMemoryStream);

    { An original Quake pak (id1, shareware) provides this file }
    function OriginalFileExists(const APath: String): Boolean;

    { PreferOriginal picks an original copy of this file that a later pak
      replaces (the LibreQuake one is what FileExists alone would give) }
    function UsesOriginalCopy(const APath: String): Boolean;

    { '' for a file of the paks of the start, 'original' when
      UsesOriginalCopy, else the MountTag of the archive it comes from }
    function VariantTag(const APath: String): String;

    { APath, or APath with '@<VariantTag>/' in front (OriginalPathMarker for
      an original copy): the key and URL of a cached model or sound, so the
      original and the replacing version of a file, or the files of two
      mods, never share a cache entry }
    function VariantPath(const APath: String): String;

    { Check if a file exists in any loaded PAK. }
    function FileExists(const APath: String): Boolean;

    { Get file contents as a newly created TMemoryStream. Caller owns the stream. }
    function GetStream(const APath: String): TMemoryStream;

    { Direct pointer to file data in memory (valid as long as TQuakePak lives). }
    function GetData(const APath: String; out ASize: Cardinal): Pointer;

    { Find all files matching prefix and optional extension. Caller owns returned TStringList. }
    function FindFiles(const APrefix, AExtension: String): TStringList;

    { Register quakepak: URL protocol handler in Castle Game Engine. }
    procedure RegisterProtocol;
    function ReadPak(const Url: String; out MimeType: String): TStream;
    function GetFileCount: Integer; inline;

    property Entries: TQuakePakEntryList read FEntries;
    property FileCount: Integer read GetFileCount;
    { Load every file (maps, models, sounds...) from the original Quake paks
      even when a later pak (the bundled LibreQuake) replaces it: the id1
      episode hub plays id1's content, LibreQuake only fills in what the
      original paks lack }
    property PreferOriginal: Boolean read FPreferOriginal write FPreferOriginal;
    { The archives added from now on belong to this mount (Unmount, VariantTag):
      the map browser's release id, '' for none; no '/' in it }
    property MountTag: String read FMountTag write FMountTag;
  end;

{ Where a zip path lands in the game: Mapping is "from>to" pairs separated
  by ';' (from a zip path prefix, to a Quake directory path like
  'id1/maps/'), the longest matching prefix wins; True with the path in
  the paks (relative to its directory) when it lands in id1 or GameDir (a
  mod's: quoth, ad...) }
function MapArchivePath(const Mapping, ZipPath: String; out PakPath: String;
  const GameDir: String = 'id1'): Boolean;

var
  Pak: TQuakePak;
  PakMissingFileHook: TQuakePakMissingFileHook = nil;
  { The -game directory in use ('' for id1 / the bundled paks; 'hipnotic',
    'rogue' or a mod), after its paks were loaded on top of id1 }
  GameDir: String;

implementation

var
  NameCounters: specialize TDictionary<String, Integer>;

function ComponentName(const Base: String): String;
var
  I, N: Integer;
  C: Char;
  Clean: String;
begin
  Clean := '';
  for I := 1 to Length(Base) do
  begin
    C := LowerCase(Base[I]);
    if C in ['a'..'z', '0'..'9', '_'] then
      Clean := Clean + C
    else
      Clean := Clean + '_';
  end;
  if (Clean = '') or (Clean[1] in ['0'..'9']) then
    Clean := 'c_' + Clean;
  if NameCounters = nil then
    NameCounters := specialize TDictionary<String, Integer>.Create;
  if not NameCounters.TryGetValue(Clean, N) then
    N := 0;
  Inc(N);
  NameCounters.AddOrSetValue(Clean, N);
  Result := Clean + '_' + IntToStr(N);
end;

procedure ResetComponentNames;
begin
  if NameCounters <> nil then
    NameCounters.Clear;
end;

procedure LogSceneTree(const Root: TObject; const Category: String);
var
  Count: Integer;

  procedure Walk(const T: TCastleTransform; const Depth: Integer);
  var
    I: Integer;
    S: String;
  begin
    S := T.Name;
    if S = '' then
      S := '(unnamed)';
    if not T.Exists then
      S := S + ' [hidden]';
    WritelnLog(Category, '%s%s: %s', [StringOfChar(' ', Depth * 2), S, T.ClassName]);
    Inc(Count);
    for I := 0 to T.BehaviorsCount - 1 do
      WritelnLog(Category, '%s  @%s: %s', [StringOfChar(' ', Depth * 2), T.Behaviors[I].Name,
        T.Behaviors[I].ClassName]);
    for I := 0 to T.Count - 1 do
      Walk(T.Items[I], Depth + 1);
  end;

begin
  Count := 0;
  if Root is TCastleTransform then
    Walk(TCastleTransform(Root), 0);
  WritelnLog(Category, 'Scene tree: %d transforms', [Count]);
end;

type
  TPakHeader = packed record
    Magic: array[0..3] of AnsiChar; { 'PACK' }
    DirOffset: Cardinal;
    DirLength: Cardinal;
  end;

  TPakRawEntry = packed record
    Name: array[0..55] of AnsiChar;
    Offset: Cardinal;
    Size: Cardinal;
  end;

function NormalizePath(const S: String): String;
var
  I: Integer;
begin
  Result := LowerCase(S);
  for I := 1 to Length(Result) do
    if Result[I] = '\' then
      Result[I] := '/';
  while (Length(Result) > 0) and (Result[1] = '/') do
    Delete(Result, 1, 1);
  { The marker of VariantPath ('@tag/') only names a cache entry }
  if (Result <> '') and (Result[1] = '@') and (Pos('/', Result) > 0) then
    Delete(Result, 1, Pos('/', Result));
end;

destructor TQuakePakContainer.Destroy;
begin
  if OwnsStream then
    FreeAndNil(Stream);
  inherited Destroy;
end;

{ A local file for a URL or filename, '' when it is none (the web,
  Android's assets, http) }
function LocalFile(const AUrlOrFilename: String): String;
begin
  Result := '';
  {$ifndef WASI}
  Result := UriToFilenameSafe(AUrlOrFilename);
  if (Result <> '') and not SysUtils.FileExists(Result) then
    Result := '';
  {$endif}
end;

{ The archive's bytes: the file on disk opened for reading, else a copy in memory }
function OpenArchive(const AUrlOrFilename: String): TStream;
var
  FileName: String;
  InStream: TStream;
begin
  FileName := LocalFile(AUrlOrFilename);
  if FileName <> '' then
    Exit(TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite));
  InStream := Download(AUrlOrFilename);
  try
    Result := TMemoryStream.Create;
    Result.CopyFrom(InStream, InStream.Size);
    Result.Position := 0;
  finally
    InStream.Free;
  end;
end;

{ TQuakePak }

constructor TQuakePak.Create;
begin
  inherited Create;
  FContainers := specialize TObjectList<TQuakePakContainer>.Create(True);
  FEntries := TQuakePakEntryList.Create;
  FShadowed := TQuakePakEntryList.Create;
  FDataCache := specialize TObjectDictionary<String, TMemoryStream>.Create([doOwnsValues]);
  FProtocolRegistered := False;
end;

destructor TQuakePak.Destroy;
begin
  if FProtocolRegistered then
    CastleDownload.UnregisterUrlProtocol('quakepak');
  FContainers.Free;
  FEntries.Free;
  FShadowed.Free;
  FDataCache.Free;
  inherited Destroy;
end;

function TQuakePak.GetFileCount: Integer;
begin
  Result := FEntries.Count;
end;

function TQuakePak.IsOriginal(const Index: Integer): Boolean;
begin
  Result := FContainers[Index].Original;
end;

function TQuakePak.ReadAt(const Index: Integer; const Offset: Int64; var Buffer; const Count: Int64): Boolean;
var
  C: TQuakePakContainer;
begin
  C := FContainers[Index];
  Result := (C.Stream <> nil) and (Offset >= 0) and (Count >= 0) and (Offset + Count <= C.Size);
  if not Result or (Count = 0) then
    Exit;
  if C.Stream is TMemoryStream then
    Move((PByte(TMemoryStream(C.Stream).Memory) + C.Base + Offset)^, Buffer, Count)
  else
  begin
    C.Stream.Position := C.Base + Offset;
    C.Stream.ReadBuffer(Buffer, Count);
  end;
end;

function TQuakePak.AddFile(const AUrlOrFilename: String; const Original: Boolean): Boolean;
var
  Stream: TStream;
begin
  Result := False;
  try
    Stream := OpenArchive(AUrlOrFilename);
  except
    on E: Exception do
    begin
      WritelnWarning('QuakePak', 'Failed to load PAK "%s": %s', [AUrlOrFilename, E.Message]);
      Exit;
    end;
  end;
  Result := AddPakArchive(AUrlOrFilename, Stream, 0, Stream.Size, True, Original);
end;

function TQuakePak.AddPakStream(const Name: String; const Stream: TMemoryStream; const Original: Boolean): Boolean;
begin
  Result := AddPakArchive(Name, Stream, 0, Stream.Size, True, Original);
end;

{ Reads Count bytes at Offset of an archive not added yet }
function ReadArchive(const Stream: TStream; const Base, Size, Offset: Int64; var Buffer; const Count: Int64): Boolean;
begin
  Result := (Offset >= 0) and (Count >= 0) and (Offset + Count <= Size);
  if not Result or (Count = 0) then
    Exit;
  if Stream is TMemoryStream then
    Move((PByte(TMemoryStream(Stream).Memory) + Base + Offset)^, Buffer, Count)
  else
  begin
    Stream.Position := Base + Offset;
    Stream.ReadBuffer(Buffer, Count);
  end;
end;

function TQuakePak.AddPakArchive(const Name: String; const Stream: TStream; const Base, Size: Int64;
  const OwnsStream, Original: Boolean): Boolean;
var
  Header: TPakHeader;
  Dir: array of TPakRawEntry;
  Count, I: Integer;
  Entry: TQuakePakEntry;
  PakIdx: Integer;

  procedure Fail(const Message: String);
  begin
    WritelnWarning('QuakePak', 'PAK "%s" %s', [Name, Message]);
    if OwnsStream then
      Stream.Free;
  end;

begin
  Result := False;
  if not ReadArchive(Stream, Base, Size, 0, Header, SizeOf(TPakHeader)) then
  begin
    Fail(Format('is too small (%d bytes)', [Size]));
    Exit;
  end;
  if (Header.Magic[0] <> 'P') or (Header.Magic[1] <> 'A') or
     (Header.Magic[2] <> 'C') or (Header.Magic[3] <> 'K') then
  begin
    Fail('has invalid magic (not "PACK")');
    Exit;
  end;
  Count := Header.DirLength div SizeOf(TPakRawEntry);
  Dir := nil;
  SetLength(Dir, Count);
  if (Int64(Header.DirOffset) + Header.DirLength > Size) or
     (Header.DirLength mod SizeOf(TPakRawEntry) <> 0) or
     not ReadArchive(Stream, Base, Size, Header.DirOffset, Pointer(Dir)^, Int64(Count) * SizeOf(TPakRawEntry)) then
  begin
    Fail('has invalid directory header');
    Exit;
  end;

  PakIdx := AddContainer(Name, Stream, Base, Size, OwnsStream, Original);
  for I := 0 to Count - 1 do
  begin
    Entry := Default(TQuakePakEntry);
    Entry.Path := NormalizePath(PAnsiChar(@Dir[I].Name[0]));
    Entry.Offset := Dir[I].Offset;
    Entry.Size := Dir[I].Size;
    Entry.PakIndex := PakIdx;
    Entry.Kind := pekPak;
    AddEntry(Entry);
  end;

  if Stream is TMemoryStream then
    WritelnLog('QuakePak', 'Loaded PAK "%s": %d files (total indexed: %d)',
      [Name, Count, FEntries.Count])
  else
    WritelnLog('QuakePak', 'Loaded PAK "%s": %d files (total indexed: %d), read from disk',
      [Name, Count, FEntries.Count]);
  Result := True;
end;

function TQuakePak.AddContainer(const Name: String; const Stream: TStream; const Base, Size: Int64;
  const OwnsStream, Original: Boolean): Integer;
var
  C: TQuakePakContainer;
begin
  C := TQuakePakContainer.Create;
  C.Name := Name;
  C.Stream := Stream;
  C.Base := Base;
  C.Size := Size;
  C.OwnsStream := OwnsStream;
  C.Original := Original;
  C.Tag := FMountTag;
  Result := FContainers.Add(C);
end;

procedure TQuakePak.AddEntry(const Entry: TQuakePakEntry);
var
  ExistingIndex: Integer;
begin
  { A later container replaces the entry; the old one stays reachable for
    PreferOriginal }
  ExistingIndex := FindEntryIndex(Entry.Path, False);
  if ExistingIndex >= 0 then
  begin
    FShadowed.Add(FEntries[ExistingIndex]);
    FEntries[ExistingIndex] := Entry;
    FDataCache.Remove(Entry.Path);
  end else
    FEntries.Add(Entry);
end;

type
  TZipEndOfCentralDir = packed record
    Signature: LongWord; { $06054b50 }
    DiskNumber, CentralDirDisk, EntriesOnDisk, EntriesTotal: Word;
    CentralDirSize, CentralDirOffset: LongWord;
    CommentLength: Word;
  end;

  TZipCentralHeader = packed record
    Signature: LongWord; { $02014b50 }
    VersionMadeBy, VersionNeeded, Flags, Method, ModTime, ModDate: Word;
    Crc32, CompressedSize, UncompressedSize: LongWord;
    NameLength, ExtraLength, CommentLength, DiskStart, InternalAttr: Word;
    ExternalAttr, LocalHeaderOffset: LongWord;
  end;

  TZipLocalHeader = packed record
    Signature: LongWord; { $04034b50 }
    VersionNeeded, Flags, Method, ModTime, ModDate: Word;
    Crc32, CompressedSize, UncompressedSize: LongWord;
    NameLength, ExtraLength: Word;
  end;

function MapArchivePath(const Mapping, ZipPath: String; out PakPath: String; const GameDir: String): Boolean;
var
  Pairs: TStringList;
  I, Sep, BestLen: Integer;
  From, Target, BestTarget, Lower, Final: String;
begin
  Result := False;
  PakPath := '';
  Lower := LowerCase(ZipPath);
  BestLen := -1;
  BestTarget := '';
  Pairs := TStringList.Create;
  try
    Pairs.Delimiter := ';';
    Pairs.StrictDelimiter := True;
    Pairs.DelimitedText := Mapping;
    for I := 0 to Pairs.Count - 1 do
    begin
      Sep := Pos('>', Pairs[I]);
      if Sep = 0 then
        Continue;
      From := LowerCase(Copy(Pairs[I], 1, Sep - 1));
      Target := LowerCase(Copy(Pairs[I], Sep + 1, MaxInt));
      if (Copy(Lower, 1, Length(From)) = From) and (Length(From) > BestLen) then
      begin
        BestLen := Length(From);
        BestTarget := Target;
      end;
    end;
  finally
    Pairs.Free;
  end;
  if BestLen < 0 then
    Exit;
  Final := Copy(Lower, BestLen + 1, MaxInt);
  if (BestTarget <> '') and (BestTarget[Length(BestTarget)] <> '/') and (Final <> '') then
    BestTarget := BestTarget + '/';
  Final := BestTarget + Final;
  if Copy(Final, 1, 4) = 'id1/' then
    PakPath := Copy(Final, 5, MaxInt)
  else
  if (GameDir <> '') and (Copy(Final, 1, Length(GameDir) + 1) = LowerCase(GameDir) + '/') then
    PakPath := Copy(Final, Length(GameDir) + 2, MaxInt)
  else
    Exit;
  Result := PakPath <> '';
end;

function TQuakePak.AddPk3(const AUrlOrFilename: String): Boolean;
begin
  Result := AddPk3(AUrlOrFilename, '');
end;

function TQuakePak.AddPk3(const AUrlOrFilename, Mapping, GameDir: String): Boolean;
var
  Stream: TStream;
  Size, TailStart, Pos, Count: Int64;
  Tail, CentralDir: array of Byte;
  EndDir: TZipEndOfCentralDir;
  Central: TZipCentralHeader;
  { An Integer: a 32-bit CPU (Android arm) has no Int64 for loops; the
    entry count is 16-bit anyway }
  I, Idx: Integer;
  Name, Mapped: String;
  Entry: TQuakePakEntry;
begin
  Result := False;
  try
    Stream := OpenArchive(AUrlOrFilename);
  except
    on E: Exception do
    begin
      WritelnWarning('QuakePak', 'Failed to load PK3 "%s": %s', [AUrlOrFilename, E.Message]);
      Exit;
    end;
  end;
  Size := Stream.Size;

  { The end of central directory record, before an optional comment, in
    the last 64 KB }
  TailStart := Max(Int64(0), Size - SizeOf(TZipEndOfCentralDir) - 65535);
  Tail := nil;
  SetLength(Tail, Size - TailStart);
  Pos := -1;
  if (Size >= SizeOf(TZipEndOfCentralDir)) and
     ReadArchive(Stream, 0, Size, TailStart, Pointer(Tail)^, Length(Tail)) then
  begin
    Pos := Length(Tail) - SizeOf(TZipEndOfCentralDir);
    while (Pos >= 0) and (PLongWord(@Tail[Pos])^ <> $06054b50) do
      Dec(Pos);
  end;
  if Pos < 0 then
  begin
    WritelnWarning('QuakePak', 'PK3 "%s" is not a zip archive', [AUrlOrFilename]);
    Stream.Free;
    Exit;
  end;
  Move(Tail[Pos], EndDir, SizeOf(EndDir));
  Tail := nil;
  CentralDir := nil;
  SetLength(CentralDir, EndDir.CentralDirSize);
  if (Int64(EndDir.CentralDirOffset) + EndDir.CentralDirSize > TailStart + Pos) or
     not ReadArchive(Stream, 0, Size, EndDir.CentralDirOffset, Pointer(CentralDir)^, Length(CentralDir)) then
  begin
    WritelnWarning('QuakePak', 'PK3 "%s" has a broken central directory', [AUrlOrFilename]);
    Stream.Free;
    Exit;
  end;

  Idx := AddContainer(AUrlOrFilename, Stream, 0, Size, True, False);
  Count := 0;
  Pos := 0;
  for I := 0 to EndDir.EntriesTotal - 1 do
  begin
    if Pos + SizeOf(Central) > Length(CentralDir) then
      Break;
    Move(CentralDir[Pos], Central, SizeOf(Central));
    if (Central.Signature <> $02014b50) or (Pos + SizeOf(Central) + Central.NameLength > Length(CentralDir)) then
      Break;
    SetLength(Name, Central.NameLength);
    if Central.NameLength > 0 then
      Move(CentralDir[Pos + SizeOf(Central)], Name[1], Central.NameLength);
    Inc(Pos, SizeOf(Central) + Central.NameLength + Central.ExtraLength + Central.CommentLength);
    { Directories end with a slash; only stored and deflated files }
    if (Name = '') or (Name[Length(Name)] = '/') then
      Continue;
    if (Central.Method <> 0) and (Central.Method <> 8) then
    begin
      WritelnWarning('QuakePak', 'PK3 "%s": "%s" uses compression method %d (only stored and deflated)',
        [AUrlOrFilename, Name, Central.Method]);
      Continue;
    end;
    if Mapping <> '' then
    begin
      { Only what lands in id1, at its place there }
      if not MapArchivePath(Mapping, Name, Mapped, GameDir) then
        Continue;
      Name := Mapped;
    end;
    Entry := Default(TQuakePakEntry);
    Entry.Path := NormalizePath(Name);
    Entry.Offset := Central.LocalHeaderOffset;
    Entry.Size := Central.UncompressedSize;
    Entry.CompressedSize := Central.CompressedSize;
    Entry.Method := Central.Method;
    Entry.PakIndex := Idx;
    Entry.Kind := pekZip;
    AddEntry(Entry);
    Inc(Count);
  end;
  if Stream is TMemoryStream then
    WritelnLog('QuakePak', 'Loaded PK3 "%s": %d files (total indexed: %d)',
      [AUrlOrFilename, Count, FEntries.Count])
  else
    WritelnLog('QuakePak', 'Loaded PK3 "%s": %d files (total indexed: %d), read from disk',
      [AUrlOrFilename, Count, FEntries.Count]);
  Result := True;
end;

{ Where a zip entry's data starts (after its local header), -1 when broken }
function ZipDataOffset(const Pak: TQuakePak; const Entry: TQuakePakEntry): Int64; forward;

function TQuakePak.AddPakFile(const Name, FileName: String): Boolean;
var
  Stream: TStream;
begin
  Result := False;
  try
    Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  except
    on E: Exception do
    begin
      WritelnWarning('QuakePak', 'Failed to open "%s": %s', [FileName, E.Message]);
      Exit;
    end;
  end;
  Result := AddPakArchive(Name, Stream, 0, Stream.Size, True, False);
end;

function TQuakePak.AddPakFromArchive(const Name, InnerPath, CacheFile: String): Boolean;
var
  Entry: TQuakePakEntry;
  C: TQuakePakContainer;
  DataPos: Int64;
  Data: TMemoryStream;
  Info: TSearchRec;
  Fresh: Boolean;
begin
  Result := False;
  if not FindEntry(InnerPath, Entry) then
    Exit;
  C := FContainers[Entry.PakIndex];
  { Stored in an archive read from disk: a window into its stream }
  if (Entry.Kind = pekZip) and (Entry.Method = 0) and (C.Stream <> nil) and not (C.Stream is TMemoryStream) then
  begin
    DataPos := ZipDataOffset(Self, Entry);
    if DataPos >= 0 then
      Exit(AddPakArchive(Name, C.Stream, C.Base + DataPos, Entry.Size, False, False));
  end;
  if (Entry.Kind = pekFile) and (Entry.DiskPath <> '') then
    Exit(AddPakFile(Name, Entry.DiskPath));
  { Deflated: unpacked to a file once, then read from it }
  if (CacheFile <> '') and (C.Stream <> nil) and not (C.Stream is TMemoryStream) then
  begin
    Fresh := (FindFirst(CacheFile, faAnyFile, Info) = 0) and (Info.Size = Entry.Size);
    FindClose(Info);
    if not Fresh then
    begin
      Data := GetStream(InnerPath);
      if Data = nil then
        Exit;
      try
        Data.SaveToFile(CacheFile);
      finally
        Data.Free;
      end;
      WritelnLog('QuakePak', 'Unpacked "%s" to "%s" (%d bytes)', [InnerPath, CacheFile, Entry.Size]);
    end;
    Exit(AddPakFile(Name, CacheFile));
  end;
  Data := GetStream(InnerPath);
  if Data <> nil then
    Result := AddPakStream(Name, Data);
end;

function TQuakePak.Unmount(const Tag: String): Integer;
var
  I, J, Best: Integer;
  Gone: array of Boolean;
  Path: String;
begin
  Result := 0;
  if Tag = '' then
    Exit;
  Gone := nil;
  SetLength(Gone, FContainers.Count);
  for I := 0 to FContainers.Count - 1 do
    if not FContainers[I].Removed and (FContainers[I].Tag = Tag) then
    begin
      Gone[I] := True;
      Inc(Result);
    end;
  if Result = 0 then
    Exit;
  { The files of the archives that go: the top one below them comes back }
  for I := FEntries.Count - 1 downto 0 do
    if Gone[FEntries[I].PakIndex] then
    begin
      Path := FEntries[I].Path;
      FDataCache.Remove(Path);
      Best := -1;
      for J := 0 to FShadowed.Count - 1 do
        if (FShadowed[J].Path = Path) and not Gone[FShadowed[J].PakIndex] and
           ((Best < 0) or (FShadowed[J].PakIndex >= FShadowed[Best].PakIndex)) then
          Best := J;
      if Best >= 0 then
      begin
        FEntries[I] := FShadowed[Best];
        FShadowed.Delete(Best);
      end else
        FEntries.Delete(I);
    end;
  for J := FShadowed.Count - 1 downto 0 do
    if Gone[FShadowed[J].PakIndex] then
      FShadowed.Delete(J);
  { Windows into a zip's stream go before the zip that owns it (slots stay,
    so the other entries keep their indexes) }
  for I := FContainers.Count - 1 downto 0 do
    if Gone[I] then
    begin
      if FContainers[I].OwnsStream then
        FreeAndNil(FContainers[I].Stream)
      else
        FContainers[I].Stream := nil;
      FContainers[I].Removed := True;
      FContainers[I].Tag := '';
    end;
  WritelnLog('QuakePak', 'Unmounted "%s": %d archives (total indexed: %d)', [Tag, Result, FEntries.Count]);
end;

function TQuakePak.MemoryBytes: Int64;
var
  C: TQuakePakContainer;
  Cached: TMemoryStream;
begin
  Result := 0;
  for C in FContainers do
    if (C.Stream is TMemoryStream) and C.OwnsStream then
      Inc(Result, C.Stream.Size);
  for Cached in FDataCache.Values do
    Inc(Result, Cached.Size);
end;

function TQuakePak.DiskArchives: Integer;
var
  C: TQuakePakContainer;
begin
  Result := 0;
  for C in FContainers do
    if (C.Stream <> nil) and not (C.Stream is TMemoryStream) then
      Inc(Result);
end;

function TQuakePak.AddDirectory(const Dir: String): Integer;
var
  Idx: Integer;
  Root: String;

  procedure Scan(const Sub: String);
  var
    Info: TSearchRec;
    Entry: TQuakePakEntry;
    Ext: String;
  begin
    if FindFirst(Root + Sub + '*', faAnyFile, Info) <> 0 then
      Exit;
    try
      repeat
        if (Info.Name = '.') or (Info.Name = '..') then
          Continue;
        if (Info.Attr and faDirectory) <> 0 then
          Scan(Sub + Info.Name + '/')
        else
        begin
          Ext := LowerCase(ExtractFileExt(Info.Name));
          { The archives of the directory are added on their own }
          if (Ext = '.pak') or (Ext = '.pk3') then
            Continue;
          Entry := Default(TQuakePakEntry);
          Entry.Path := NormalizePath(Sub + Info.Name);
          Entry.Size := Info.Size;
          Entry.PakIndex := Idx;
          Entry.Kind := pekFile;
          Entry.DiskPath := Root + Sub + Info.Name;
          AddEntry(Entry);
          Inc(Result);
        end;
      until FindNext(Info) <> 0;
    finally
      FindClose(Info);
    end;
  end;

begin
  Result := 0;
  Root := IncludeTrailingPathDelimiter(Dir);
  if not DirectoryExists(Root) then
    Exit;
  Idx := AddContainer(Root, nil, 0, 0, False, False);
  Scan('');
  if Result > 0 then
    WritelnLog('QuakePak', 'Loaded %d loose files from "%s" (total indexed: %d)',
      [Result, Root, FEntries.Count]);
end;

procedure TQuakePak.AddMemoryFile(const APath: String; const Stream: TMemoryStream);
var
  Entry: TQuakePakEntry;
begin
  Entry := Default(TQuakePakEntry);
  Entry.Path := NormalizePath(APath);
  Entry.Offset := 0;
  Entry.Size := Stream.Size;
  Entry.PakIndex := AddContainer(Entry.Path, Stream, 0, Stream.Size, True, False);
  Entry.Kind := pekPak;
  AddEntry(Entry);
end;

function ZipDataOffset(const Pak: TQuakePak; const Entry: TQuakePakEntry): Int64;
var
  Local: TZipLocalHeader;
begin
  Result := -1;
  if not Pak.ReadAt(Entry.PakIndex, Entry.Offset, Local, SizeOf(Local)) or (Local.Signature <> $04034b50) then
    Exit;
  Result := Int64(Entry.Offset) + SizeOf(Local) + Local.NameLength + Local.ExtraLength;
end;

function TQuakePak.ReadEntry(const Entry: TQuakePakEntry): TMemoryStream;
var
  DataPos: Int64;
  Deflated: TMemoryStream;
  Inflater: TDecompressionStream;
begin
  Result := nil;
  case Entry.Kind of
    pekFile:
      begin
        if not SysUtils.FileExists(Entry.DiskPath) then
          Exit;
        Result := TMemoryStream.Create;
        Result.LoadFromFile(Entry.DiskPath);
      end;
    pekPak:
      begin
        Result := TMemoryStream.Create;
        Result.Size := Entry.Size;
        if not ReadAt(Entry.PakIndex, Entry.Offset, Result.Memory^, Entry.Size) then
          FreeAndNil(Result);
      end;
    pekZip:
      begin
        DataPos := ZipDataOffset(Self, Entry);
        if DataPos < 0 then
          Exit;
        Result := TMemoryStream.Create;
        if Entry.Method = 0 then
        begin
          Result.Size := Entry.Size;
          if not ReadAt(Entry.PakIndex, DataPos, Result.Memory^, Entry.Size) then
            FreeAndNil(Result);
        end else
        begin
          { Raw deflate (no zlib header) }
          Deflated := TMemoryStream.Create;
          try
            Deflated.Size := Entry.CompressedSize;
            if not ReadAt(Entry.PakIndex, DataPos, Deflated.Memory^, Entry.CompressedSize) then
            begin
              FreeAndNil(Result);
              Exit;
            end;
            Deflated.Position := 0;
            Inflater := TDecompressionStream.Create(Deflated, True);
            try
              Result.Size := Entry.Size;
              if Entry.Size > 0 then
                Inflater.ReadBuffer(Result.Memory^, Entry.Size);
            finally
              Inflater.Free;
            end;
          finally
            Deflated.Free;
          end;
        end;
      end;
  end;
  if Result <> nil then
    Result.Position := 0;
end;

function TQuakePak.FindEntryIndex(const APath: String; const AllowHook: Boolean): Integer;
var
  Target: String;
  I: Integer;
  Added: Boolean;
begin
  Target := NormalizePath(APath);
  for I := FEntries.Count - 1 downto 0 do
    if FEntries[I].Path = Target then
      Exit(I);
  Result := -1;
  if not AllowHook or FInMissingHook or not Assigned(PakMissingFileHook) then
    Exit;
  FInMissingHook := True;
  try
    Added := PakMissingFileHook(Target);
  finally
    FInMissingHook := False;
  end;
  if Added then
    for I := FEntries.Count - 1 downto 0 do
      if FEntries[I].Path = Target then
        Exit(I);
end;

function TQuakePak.FindEntry(const APath: String; out Entry: TQuakePakEntry): Boolean;
var
  Idx, I: Integer;
  Target: String;
begin
  Idx := FindEntryIndex(APath);
  Result := Idx >= 0;
  if not Result then
    Exit;
  Entry := FEntries[Idx];
  if not FPreferOriginal or IsOriginal(Entry.PakIndex) then
    Exit;
  Target := Entry.Path;
  for I := FShadowed.Count - 1 downto 0 do
    if (FShadowed[I].Path = Target) and IsOriginal(FShadowed[I].PakIndex) then
    begin
      Entry := FShadowed[I];
      Exit;
    end;
end;

function TQuakePak.FileExists(const APath: String): Boolean;
begin
  Result := FindEntryIndex(APath) >= 0;
end;

function TQuakePak.OriginalFileExists(const APath: String): Boolean;
var
  Idx, I: Integer;
  Target: String;
begin
  Idx := FindEntryIndex(APath);
  if Idx < 0 then
    Exit(False);
  if IsOriginal(FEntries[Idx].PakIndex) then
    Exit(True);
  Target := FEntries[Idx].Path;
  for I := 0 to FShadowed.Count - 1 do
    if (FShadowed[I].Path = Target) and IsOriginal(FShadowed[I].PakIndex) then
      Exit(True);
  Result := False;
end;

function TQuakePak.UsesOriginalCopy(const APath: String): Boolean;
var
  Idx: Integer;
  Entry: TQuakePakEntry;
begin
  Idx := FindEntryIndex(APath);
  Result := (Idx >= 0) and FindEntry(APath, Entry) and
    ((Entry.PakIndex <> FEntries[Idx].PakIndex) or (Entry.Offset <> FEntries[Idx].Offset));
end;

function TQuakePak.VariantTag(const APath: String): String;
var
  Idx: Integer;
begin
  Result := '';
  if UsesOriginalCopy(APath) then
    Exit('original');
  Idx := FindEntryIndex(APath);
  if Idx >= 0 then
    Result := FContainers[FEntries[Idx].PakIndex].Tag;
end;

function TQuakePak.VariantPath(const APath: String): String;
var
  Tag: String;
begin
  Result := NormalizePath(APath);
  Tag := VariantTag(Result);
  if Tag = 'original' then
    Result := OriginalPathMarker + Result
  else
  if Tag <> '' then
    Result := '@' + Tag + '/' + Result;
end;

function TQuakePak.GetStream(const APath: String): TMemoryStream;
var
  Entry: TQuakePakEntry;
begin
  Result := nil;
  if not FindEntry(APath, Entry) then
    Exit;
  try
    Result := ReadEntry(Entry);
  except
    on E: Exception do
    begin
      WritelnWarning('QuakePak', 'Cannot read "%s": %s', [APath, E.Message]);
      FreeAndNil(Result);
    end;
  end;
  if Result = nil then
    WritelnWarning('QuakePak', 'File entry "%s" points out of bounds', [APath]);
end;

function TQuakePak.GetData(const APath: String; out ASize: Cardinal): Pointer;
var
  Entry: TQuakePakEntry;
  Cached: TMemoryStream;
  C: TQuakePakContainer;
begin
  ASize := 0;
  Result := nil;
  if not FindEntry(APath, Entry) then
    Exit;

  { A pak in memory hands out its own bytes }
  C := FContainers[Entry.PakIndex];
  if (Entry.Kind = pekPak) and (C.Stream is TMemoryStream) then
  begin
    if Int64(Entry.Offset) + Entry.Size > C.Size then
      Exit;
    ASize := Entry.Size;
    Result := PByte(TMemoryStream(C.Stream).Memory) + C.Base + Entry.Offset;
    Exit;
  end;

  { Zip entries, loose files and paks read from disk are unpacked once and kept }
  if not FDataCache.TryGetValue(Entry.Path, Cached) then
  begin
    Cached := GetStream(Entry.Path);
    if Cached = nil then
      Exit;
    FDataCache.AddOrSetValue(Entry.Path, Cached);
  end;
  ASize := Cached.Size;
  Result := Cached.Memory;
end;

function TQuakePak.FindFiles(const APrefix, AExtension: String): TStringList;
var
  I: Integer;
  Entry: TQuakePakEntry;
  PrefixNorm, ExtNorm: String;
begin
  Result := TStringList.Create;
  PrefixNorm := NormalizePath(APrefix);
  ExtNorm := LowerCase(AExtension);

  for I := 0 to FEntries.Count - 1 do
  begin
    Entry := FEntries[I];
    if (PrefixNorm = '') or (Pos(PrefixNorm, Entry.Path) = 1) then
    begin
      if (ExtNorm = '') or (ExtractFileExt(Entry.Path) = ExtNorm) then
        Result.Add(Entry.Path);
    end;
  end;
end;

{ Many original Quake samples end with a broken chunk (a LIST of a few
  bytes declaring a size of gigabytes) or a data chunk longer than the file:
  Quake's loader stops after the data, the engine's WAV reader fails with a
  read error, which on WebAssembly cannot be caught and stops the game. The
  sample is rebuilt with only its fmt and data chunks, clamped to the bytes
  present; anything not understood is returned as it was. }
function CleanWav(const Source: TMemoryStream): TMemoryStream;
var
  Data: PByte;
  Size, P, ChunkSize, FmtPos, FmtSize, DataPos, DataSize: Int64;
  Id: array[0..3] of AnsiChar;
  RiffSize: LongWord;

  function ReadU32(const At: Int64): LongWord;
  begin
    Move(Data[At], Result, 4);
    Result := LEtoN(Result);
  end;

  procedure WriteU32(const Value: LongWord);
  var
    V: LongWord;
  begin
    V := NtoLE(Value);
    Result.WriteBuffer(V, 4);
  end;

begin
  Result := Source;
  Data := Source.Memory;
  Size := Source.Size;
  if (Size < 12) or (CompareByte(Data[0], 'RIFF', 4) <> 0) or (CompareByte(Data[8], 'WAVE', 4) <> 0) then
    Exit;
  FmtPos := -1;
  FmtSize := 0;
  DataPos := -1;
  DataSize := 0;
  P := 12;
  while (P + 8 <= Size) and (DataPos < 0) do
  begin
    Move(Data[P], Id, 4);
    ChunkSize := ReadU32(P + 4);
    if Id = 'fmt ' then
    begin
      FmtPos := P + 8;
      FmtSize := Min(ChunkSize, Size - FmtPos);
    end else
    if Id = 'data' then
    begin
      DataPos := P + 8;
      DataSize := Min(ChunkSize, Size - DataPos);
    end;
    P := P + 8 + ChunkSize + (ChunkSize and 1);
  end;
  if (FmtPos < 0) or (FmtSize < 16) or (DataPos < 0) then
    Exit;

  Result := TMemoryStream.Create;
  RiffSize := 4 + 8 + FmtSize + (FmtSize and 1) + 8 + DataSize + (DataSize and 1);
  Result.WriteBuffer('RIFF', 4);
  WriteU32(RiffSize);
  Result.WriteBuffer('WAVE', 4);
  Result.WriteBuffer('fmt ', 4);
  WriteU32(FmtSize);
  Result.WriteBuffer(Data[FmtPos], FmtSize);
  if Odd(FmtSize) then
    Result.WriteByte(0);
  Result.WriteBuffer('data', 4);
  WriteU32(DataSize);
  if DataSize > 0 then
    Result.WriteBuffer(Data[DataPos], DataSize);
  if Odd(DataSize) then
    Result.WriteByte(0);
  Result.Position := 0;
  Source.Free;
end;

function TQuakePak.ReadPak(const Url: String; out MimeType: String): TStream;
var
  Path: String;
  P: Integer;
begin
  Path := Url;
  P := Pos(':', Path);
  if P > 0 then Delete(Path, 1, P);
  while (Path <> '') and (Path[1] = '/') do Delete(Path, 1, 1);

  Result := GetStream(Path);
  if (Result <> nil) and (LowerCase(ExtractFileExt(Path)) = '.wav') then
    Result := CleanWav(TMemoryStream(Result));
  { Loaders (e.g. sound files) pick the format from the MIME type,
    so derive it from the file extension }
  MimeType := UriMimeType(Path);
  if Result = nil then
  begin
    WritelnLog('QuakePak', 'Resource not found: ' + Url);
    raise EFOpenError.Create('Resource not found in PAK: ' + Url);
  end;
end;

procedure TQuakePak.RegisterProtocol;
begin
  if not FProtocolRegistered then
  begin
    CastleDownload.RegisterUrlProtocol('quakepak', @ReadPak, nil);
    FProtocolRegistered := True;
    WritelnLog('QuakePak', 'Registered "quakepak:" URL protocol');
  end;
end;

initialization
  Pak := TQuakePak.Create;

finalization
  FreeAndNil(NameCounters);
  FreeAndNil(Pak);
end.
