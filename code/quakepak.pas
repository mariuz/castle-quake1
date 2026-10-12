{ Quake 1 PAK archive reader and custom URL protocol. Also reads .pk3
  (zip) archives and loose files in a game directory, the way mods ship. }
unit QuakePak;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, ZStream,
  CastleDownload, CastleUriUtils, CastleLog, CastleTransform;

type
  { Where an entry's bytes are: in a .pak (stored), in a .pk3 (zip: stored
    or deflated) or a loose file on disk }
  TQuakePakEntryKind = (pekPak, pekZip, pekFile);

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
    FPreferOriginalMaps: Boolean;
    { Unpacked zip entries and loose files handed out by GetData }
    FDataCache: specialize TObjectDictionary<String, TMemoryStream>;
    function FindEntryIndex(const APath: String): Integer;
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

    { Add the loose files under a directory (maps/x.bsp, progs/y.mdl...),
      searched below the archives added after it. Returns the file count. }
    function AddDirectory(const Dir: String): Integer;

    { An original Quake pak (id1, shareware) provides this file }
    function OriginalFileExists(const APath: String): Boolean;

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
    { Load maps/ from the original Quake paks even when a later pak (the
      bundled LibreQuake start map) replaces them: the id1 episode hub }
    property PreferOriginalMaps: Boolean read FPreferOriginalMaps write FPreferOriginalMaps;
  end;

var
  Pak: TQuakePak;
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
    PreferOriginalMaps }
  ExistingIndex := FindEntryIndex(Entry.Path);
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

function TQuakePak.AddPk3(const AUrlOrFilename: String): Boolean;
var
  InStream: TStream;
  MemStream: TMemoryStream;
  EndDir: TZipEndOfCentralDir;
  Central: TZipCentralHeader;
  Pos, I, Count, Idx: Int64;
  Name: String;
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

function TQuakePak.FindEntryIndex(const APath: String): Integer;
var
  Target: String;
  I: Integer;
begin
  Target := NormalizePath(APath);
  for I := FEntries.Count - 1 downto 0 do
    if FEntries[I].Path = Target then
      Exit(I);
  Result := -1;
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
  if not FPreferOriginalMaps or FOriginal[Entry.PakIndex] or (Pos('maps/', Entry.Path) <> 1) then
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
