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

  { Quake PAK archive manager. Supports stacking multiple PAK files
    (e.g. pak0.pak, pak1.pak) where later paks override earlier ones. }
  TQuakePak = class
  private
    FStreams: specialize TList<TMemoryStream>;
    FFilenames: TStringList;
    FEntries: TQuakePakEntryList;
    { Entries replaced by a later pak, kept so original maps stay reachable }
    FShadowed: TQuakePakEntryList;
    FOriginal: specialize TList<Boolean>;
    FProtocolRegistered: Boolean;
    FPreferOriginal: Boolean;
    { Unpacked zip entries and loose files handed out by GetData }
    FDataCache: specialize TObjectDictionary<String, TMemoryStream>;
    FInMissingHook: Boolean;
    function FindEntryIndex(const APath: String; const AllowHook: Boolean = True): Integer;
    function FindEntry(const APath: String; out Entry: TQuakePakEntry): Boolean;
    function AddContainer(const Name: String; const Stream: TMemoryStream; const Original: Boolean): Integer;
    procedure AddEntry(const Entry: TQuakePakEntry);
    function ReadEntry(const Entry: TQuakePakEntry): TMemoryStream;
  public
    constructor Create;
    destructor Destroy; override;

    { Add a PAK archive from file or castle-data URL. Returns true if successful. }
    function AddFile(const AUrlOrFilename: String; const Original: Boolean = False): Boolean;

    { Add a .pk3 (zip) archive from a file or URL: stored and deflated
      entries. Returns true if successful. }
    function AddPk3(const AUrlOrFilename: String): Boolean;
    { The same with the zip's paths moved by Mapping (MapArchivePath): a
      map browser zip whose files land in id1/maps/ }
    function AddPk3(const AUrlOrFilename, Mapping: String): Boolean;

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

    { APath, or APath with OriginalPathMarker in front when UsesOriginalCopy:
      the key and URL of a cached model or sound, so the original and the
      replacing version of a file never share a cache entry }
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
  end;

{ Where a zip path lands in the game: Mapping is "from>to" pairs separated
  by ';' (from a zip path prefix, to a Quake directory path like
  'id1/maps/'), the longest matching prefix wins; True with the path in
  the paks (relative to id1) when it lands in id1 }
function MapArchivePath(const Mapping, ZipPath: String; out PakPath: String): Boolean;

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
  { The marker of VariantPath only names a cache entry }
  if Pos(OriginalPathMarker, Result) = 1 then
    Delete(Result, 1, Length(OriginalPathMarker));
end;

{ TQuakePak }

constructor TQuakePak.Create;
begin
  inherited Create;
  FStreams := specialize TList<TMemoryStream>.Create;
  FFilenames := TStringList.Create;
  FEntries := TQuakePakEntryList.Create;
  FShadowed := TQuakePakEntryList.Create;
  FOriginal := specialize TList<Boolean>.Create;
  FDataCache := specialize TObjectDictionary<String, TMemoryStream>.Create([doOwnsValues]);
  FProtocolRegistered := False;
end;

destructor TQuakePak.Destroy;
var
  Stream: TMemoryStream;
begin
  if FProtocolRegistered then
    CastleDownload.UnregisterUrlProtocol('quakepak');
  for Stream in FStreams do
    Stream.Free;
  FStreams.Free;
  FFilenames.Free;
  FEntries.Free;
  FShadowed.Free;
  FOriginal.Free;
  FDataCache.Free;
  inherited Destroy;
end;

function TQuakePak.GetFileCount: Integer;
begin
  Result := FEntries.Count;
end;

function TQuakePak.AddFile(const AUrlOrFilename: String; const Original: Boolean): Boolean;
var
  InStream: TStream;
  MemStream: TMemoryStream;
  Header: TPakHeader;
  RawEntry: TPakRawEntry;
  Count, I: Integer;
  EntryName: String;
  Entry: TQuakePakEntry;
  PakIdx: Integer;
begin
  Result := False;
  try
    InStream := Download(AUrlOrFilename);
    try
      MemStream := TMemoryStream.Create;
      MemStream.CopyFrom(InStream, InStream.Size);
      MemStream.Position := 0;
    finally
      InStream.Free;
    end;
  except
    on E: Exception do
    begin
      WritelnWarning('QuakePak', 'Failed to load PAK "%s": %s', [AUrlOrFilename, E.Message]);
      Exit;
    end;
  end;

  if MemStream.Size < SizeOf(TPakHeader) then
  begin
    WritelnWarning('QuakePak', 'PAK "%s" is too small (%d bytes)', [AUrlOrFilename, MemStream.Size]);
    MemStream.Free;
    Exit;
  end;

  MemStream.ReadBuffer(Header, SizeOf(TPakHeader));
  if (Header.Magic[0] <> 'P') or (Header.Magic[1] <> 'A') or
     (Header.Magic[2] <> 'C') or (Header.Magic[3] <> 'K') then
  begin
    WritelnWarning('QuakePak', 'PAK "%s" has invalid magic (not "PACK")', [AUrlOrFilename]);
    MemStream.Free;
    Exit;
  end;

  Count := Header.DirLength div SizeOf(TPakRawEntry);
  if (Header.DirOffset + Header.DirLength > Cardinal(MemStream.Size)) or
     (Header.DirLength mod SizeOf(TPakRawEntry) <> 0) then
  begin
    WritelnWarning('QuakePak', 'PAK "%s" has invalid directory header', [AUrlOrFilename]);
    MemStream.Free;
    Exit;
  end;

  PakIdx := AddContainer(AUrlOrFilename, MemStream, Original);

  MemStream.Position := Header.DirOffset;
  for I := 0 to Count - 1 do
  begin
    MemStream.ReadBuffer(RawEntry, SizeOf(TPakRawEntry));
    EntryName := NormalizePath(PAnsiChar(@RawEntry.Name[0]));
    Entry := Default(TQuakePakEntry);
    Entry.Path := EntryName;
    Entry.Offset := RawEntry.Offset;
    Entry.Size := RawEntry.Size;
    Entry.PakIndex := PakIdx;
    Entry.Kind := pekPak;
    AddEntry(Entry);
  end;

  WritelnLog('QuakePak', 'Loaded PAK "%s": %d files (total indexed: %d)',
    [AUrlOrFilename, Count, FEntries.Count]);
  Result := True;
end;

function TQuakePak.AddContainer(const Name: String; const Stream: TMemoryStream; const Original: Boolean): Integer;
begin
  Result := FStreams.Count;
  FStreams.Add(Stream);
  FFilenames.Add(Name);
  FOriginal.Add(Original);
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

function MapArchivePath(const Mapping, ZipPath: String; out PakPath: String): Boolean;
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
  if Copy(Final, 1, 4) <> 'id1/' then
    Exit;
  PakPath := Copy(Final, 5, MaxInt);
  Result := PakPath <> '';
end;

function TQuakePak.AddPk3(const AUrlOrFilename: String): Boolean;
begin
  Result := AddPk3(AUrlOrFilename, '');
end;

function TQuakePak.AddPk3(const AUrlOrFilename, Mapping: String): Boolean;
var
  InStream: TStream;
  MemStream: TMemoryStream;
  EndDir: TZipEndOfCentralDir;
  Central: TZipCentralHeader;
  Pos, Count, Idx: Int64;
  { An Integer: a 32-bit CPU (Android arm) has no Int64 for loops; the
    entry count is 16-bit anyway }
  I: Integer;
  Name, Mapped: String;
  Entry: TQuakePakEntry;
  Base: PByte;
begin
  Result := False;
  try
    InStream := Download(AUrlOrFilename);
    try
      MemStream := TMemoryStream.Create;
      MemStream.CopyFrom(InStream, InStream.Size);
    finally
      InStream.Free;
    end;
  except
    on E: Exception do
    begin
      WritelnWarning('QuakePak', 'Failed to load PK3 "%s": %s', [AUrlOrFilename, E.Message]);
      Exit;
    end;
  end;
  Base := PByte(MemStream.Memory);

  { The end of central directory record, before an optional comment }
  Pos := MemStream.Size - SizeOf(TZipEndOfCentralDir);
  while (Pos >= 0) and (Pos >= MemStream.Size - SizeOf(TZipEndOfCentralDir) - 65535) and
        (PLongWord(Base + Pos)^ <> $06054b50) do
    Dec(Pos);
  if Pos < 0 then
  begin
    WritelnWarning('QuakePak', 'PK3 "%s" is not a zip archive', [AUrlOrFilename]);
    MemStream.Free;
    Exit;
  end;
  Move((Base + Pos)^, EndDir, SizeOf(EndDir));
  if Int64(EndDir.CentralDirOffset) + EndDir.CentralDirSize > Pos then
  begin
    WritelnWarning('QuakePak', 'PK3 "%s" has a broken central directory', [AUrlOrFilename]);
    MemStream.Free;
    Exit;
  end;

  Idx := AddContainer(AUrlOrFilename, MemStream, False);
  Count := 0;
  Pos := EndDir.CentralDirOffset;
  for I := 0 to EndDir.EntriesTotal - 1 do
  begin
    if Pos + SizeOf(Central) > MemStream.Size then
      Break;
    Move((Base + Pos)^, Central, SizeOf(Central));
    if (Central.Signature <> $02014b50) or (Pos + SizeOf(Central) + Central.NameLength > MemStream.Size) then
      Break;
    SetLength(Name, Central.NameLength);
    if Central.NameLength > 0 then
      Move((Base + Pos + SizeOf(Central))^, Name[1], Central.NameLength);
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
      if not MapArchivePath(Mapping, Name, Mapped) then
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
  WritelnLog('QuakePak', 'Loaded PK3 "%s": %d files (total indexed: %d)',
    [AUrlOrFilename, Count, FEntries.Count]);
  Result := True;
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
  Idx := AddContainer(Root, nil, False);
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
  Entry.PakIndex := AddContainer(Entry.Path, Stream, False);
  Entry.Kind := pekPak;
  AddEntry(Entry);
end;

function TQuakePak.ReadEntry(const Entry: TQuakePakEntry): TMemoryStream;
var
  Src: TMemoryStream;
  Local: TZipLocalHeader;
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
        Src := FStreams[Entry.PakIndex];
        if Int64(Entry.Offset) + Entry.Size > Src.Size then
          Exit;
        Result := TMemoryStream.Create;
        Result.Size := Entry.Size;
        if Entry.Size > 0 then
          Move((PByte(Src.Memory) + Entry.Offset)^, Result.Memory^, Entry.Size);
      end;
    pekZip:
      begin
        Src := FStreams[Entry.PakIndex];
        if Int64(Entry.Offset) + SizeOf(Local) > Src.Size then
          Exit;
        Move((PByte(Src.Memory) + Entry.Offset)^, Local, SizeOf(Local));
        if Local.Signature <> $04034b50 then
          Exit;
        DataPos := Int64(Entry.Offset) + SizeOf(Local) + Local.NameLength + Local.ExtraLength;
        if DataPos + Entry.CompressedSize > Src.Size then
          Exit;
        Result := TMemoryStream.Create;
        if Entry.Method = 0 then
        begin
          Result.Size := Entry.Size;
          if Entry.Size > 0 then
            Move((PByte(Src.Memory) + DataPos)^, Result.Memory^, Entry.Size);
        end else
        begin
          { Raw deflate (no zlib header) }
          Deflated := TMemoryStream.Create;
          try
            Deflated.Size := Entry.CompressedSize;
            if Entry.CompressedSize > 0 then
              Move((PByte(Src.Memory) + DataPos)^, Deflated.Memory^, Entry.CompressedSize);
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
  if not FPreferOriginal or FOriginal[Entry.PakIndex] then
    Exit;
  Target := Entry.Path;
  for I := FShadowed.Count - 1 downto 0 do
    if (FShadowed[I].Path = Target) and FOriginal[FShadowed[I].PakIndex] then
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
  if FOriginal[FEntries[Idx].PakIndex] then
    Exit(True);
  Target := FEntries[Idx].Path;
  for I := 0 to FShadowed.Count - 1 do
    if (FShadowed[I].Path = Target) and FOriginal[FShadowed[I].PakIndex] then
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

function TQuakePak.VariantPath(const APath: String): String;
begin
  Result := NormalizePath(APath);
  if UsesOriginalCopy(Result) then
    Result := OriginalPathMarker + Result;
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
  Src, Cached: TMemoryStream;
begin
  ASize := 0;
  Result := nil;
  if not FindEntry(APath, Entry) then
    Exit;

  if Entry.Kind = pekPak then
  begin
    Src := FStreams[Entry.PakIndex];
    if Int64(Entry.Offset) + Entry.Size > Src.Size then
      Exit;
    ASize := Entry.Size;
    Result := PByte(Src.Memory) + Entry.Offset;
    Exit;
  end;

  { Zip entries and loose files are unpacked once and kept }
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
