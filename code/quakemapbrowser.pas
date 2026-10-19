{ The in-game map browser: Quaddicted's maps from a catalog
  (data/quaddicted/maps.txt, made by tools/quaddicted_catalog.py), downloaded
  with TCastleDownload, checked by SHA-256, kept in the config directory and
  mounted like a .pk3 on top of the paks to play. }
unit QuakeMapBrowser;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, Generics.Collections,
  CastleDownload, CastleUriUtils, CastleLog, CastleFilesUtils, CastleHttps;

type
  TCatalogMap = record
    Id, Sha256, Title, Author, Date, Size, Flags, Mapping, Url: String;
    Bytes: Int64;
    { Quaddicted's 0..5, -1 when not rated }
    Rating: Single;
    StartMaps: array of String;
  end;

  TMapSort = (msRating, msNewest, msName, msInstalled);

  TQuakeMapBrowser = class
  private
    FMaps: array of TCatalogMap;
    FMounted: TStringList;
    FDownload: TCastleDownload;
    FDownloadIndex: Integer;
    FStatus: String;
    FCatalogUrl: String;
    procedure ParseLine(const Line: String);
    procedure FinishDownload;
    function GetMap(const I: Integer): TCatalogMap;
  public
    constructor Create;
    destructor Destroy; override;
    { Reads the catalog: CatalogOverride (-mapcatalog), the one a "maps
      update" fetched, or the bundled one }
    procedure LoadCatalog;
    function Count: Integer;
    function IndexOf(const Id: String): Integer;
    function Installed(const I: Integer): Boolean;
    function ZipUrl(const I: Integer): String;
    { Starts the download (one at a time); False with Status saying why }
    function Install(const I: Integer): Boolean;
    function Downloading: Boolean;
    function DownloadingIndex: Integer;
    { The download's progress 0..1 }
    function Progress: Single;
    procedure Remove(const I: Integer);
    { Mounts the installed zip on top of the paks (once); False when it is
      not installed or not a zip }
    function Mount(const I: Integer): Boolean;
    { Indexes of the maps sorted (msInstalled: only the installed ones,
      by name), the ones whose title, author or id contain Filter }
    function Sorted(const Sort: TMapSort; const Filter: String = ''): specialize TArray<Integer>;
    { One line for menus and logs: title, author, year, rating, size }
    function Describe(const I: Integer): String;
    { Checks the downloads; the menu and the play view call it every frame }
    procedure Update;
    property Maps[const I: Integer]: TCatalogMap read GetMap; default;
    { What happened last (download progress, installed, errors) }
    property Status: String read FStatus;
    property CatalogUrl: String read FCatalogUrl;
  end;

{ SHA-256 of a block of memory, as 64 lowercase hex digits }
function Sha256Hex(const Data: Pointer; const Size: Int64): String;

{ The catalog to use instead of the bundled one (-mapcatalog file or URL) }
var
  MapCatalogOverride: String = '';

function MapBrowser: TQuakeMapBrowser;
{ The browser was used (MapBrowser called): there may be a download to check }
function MapBrowserCreated: Boolean;

implementation

uses
  QuakePak;

{ SHA-256 ----------------------------------------------------------------- }

{$push}{$Q-}{$R-}
const
  K256: array[0..63] of LongWord = (
    $428a2f98, $71374491, $b5c0fbcf, $e9b5dba5, $3956c25b, $59f111f1, $923f82a4, $ab1c5ed5,
    $d807aa98, $12835b01, $243185be, $550c7dc3, $72be5d74, $80deb1fe, $9bdc06a7, $c19bf174,
    $e49b69c1, $efbe4786, $0fc19dc6, $240ca1cc, $2de92c6f, $4a7484aa, $5cb0a9dc, $76f988da,
    $983e5152, $a831c66d, $b00327c8, $bf597fc7, $c6e00bf3, $d5a79147, $06ca6351, $14292967,
    $27b70a85, $2e1b2138, $4d2c6dfc, $53380d13, $650a7354, $766a0abb, $81c2c92e, $92722c85,
    $a2bfe8a1, $a81a664b, $c24b8b70, $c76c51a3, $d192e819, $d6990624, $f40e3585, $106aa070,
    $19a4c116, $1e376c08, $2748774c, $34b0bcb5, $391c0cb3, $4ed8aa4a, $5b9cca4f, $682e6ff3,
    $748f82ee, $78a5636f, $84c87814, $8cc70208, $90befffa, $a4506ceb, $bef9a3f7, $c67178f2);

function Ror(const X: LongWord; const N: Integer): LongWord; inline;
begin
  Result := (X shr N) or (X shl (32 - N));
end;

procedure Sha256Block(var H: array of LongWord; const Block: PByte);
var
  W: array[0..63] of LongWord;
  A, B, C, D, E, F, G, HH, T1, T2, S0, S1: LongWord;
  I: Integer;
begin
  for I := 0 to 15 do
    W[I] := (LongWord(Block[I * 4]) shl 24) or (LongWord(Block[I * 4 + 1]) shl 16) or
      (LongWord(Block[I * 4 + 2]) shl 8) or LongWord(Block[I * 4 + 3]);
  for I := 16 to 63 do
  begin
    S0 := Ror(W[I - 15], 7) xor Ror(W[I - 15], 18) xor (W[I - 15] shr 3);
    S1 := Ror(W[I - 2], 17) xor Ror(W[I - 2], 19) xor (W[I - 2] shr 10);
    W[I] := W[I - 16] + S0 + W[I - 7] + S1;
  end;
  A := H[0]; B := H[1]; C := H[2]; D := H[3];
  E := H[4]; F := H[5]; G := H[6]; HH := H[7];
  for I := 0 to 63 do
  begin
    S1 := Ror(E, 6) xor Ror(E, 11) xor Ror(E, 25);
    T1 := HH + S1 + ((E and F) xor ((not E) and G)) + K256[I] + W[I];
    S0 := Ror(A, 2) xor Ror(A, 13) xor Ror(A, 22);
    T2 := S0 + ((A and B) xor (A and C) xor (B and C));
    HH := G; G := F; F := E; E := D + T1;
    D := C; C := B; B := A; A := T1 + T2;
  end;
  H[0] := H[0] + A; H[1] := H[1] + B; H[2] := H[2] + C; H[3] := H[3] + D;
  H[4] := H[4] + E; H[5] := H[5] + F; H[6] := H[6] + G; H[7] := H[7] + HH;
end;
{$pop}

function Sha256Hex(const Data: Pointer; const Size: Int64): String;
const
  H0: array[0..7] of LongWord = (
    $6a09e667, $bb67ae85, $3c6ef372, $a54ff53a, $510e527f, $9b05688c, $1f83d9ab, $5be0cd19);
var
  H: array[0..7] of LongWord;
  Tail: array[0..127] of Byte;
  Pos, Rest, TailLen: Int64;
  Bits: QWord;
  I: Integer;
begin
  H := H0;
  Pos := 0;
  while Pos + 64 <= Size do
  begin
    Sha256Block(H, PByte(Data) + Pos);
    Inc(Pos, 64);
  end;
  Rest := Size - Pos;
  FillChar(Tail, SizeOf(Tail), 0);
  if Rest > 0 then
    Move((PByte(Data) + Pos)^, Tail[0], Rest);
  Tail[Rest] := $80;
  if Rest < 56 then
    TailLen := 64
  else
    TailLen := 128;
  Bits := QWord(Size) * 8;
  for I := 0 to 7 do
    Tail[TailLen - 1 - I] := Byte(Bits shr (8 * I));
  Sha256Block(H, @Tail[0]);
  if TailLen = 128 then
    Sha256Block(H, @Tail[64]);
  Result := '';
  for I := 0 to 7 do
    Result := Result + LowerCase(IntToHex(H[I], 8));
end;

{ TQuakeMapBrowser -------------------------------------------------------- }

const
  BundledCatalog = 'castle-data:/quaddicted/maps.txt';
  UpdatedCatalog = 'castle-config:/quaddicted_maps.txt';

function SplitTabs(const S: String; const Sep: Char): specialize TArray<String>;
var
  Start, I, N: Integer;
begin
  Result := nil;
  N := 0;
  Start := 1;
  for I := 1 to Length(S) + 1 do
    if (I > Length(S)) or (S[I] = Sep) then
    begin
      SetLength(Result, N + 1);
      Result[N] := Copy(S, Start, I - Start);
      Inc(N);
      Start := I + 1;
    end;
end;

constructor TQuakeMapBrowser.Create;
begin
  inherited Create;
  FMounted := TStringList.Create;
  FDownloadIndex := -1;
  LoadCatalog;
end;

destructor TQuakeMapBrowser.Destroy;
begin
  FreeAndNil(FDownload);
  FMounted.Free;
  inherited Destroy;
end;

procedure TQuakeMapBrowser.ParseLine(const Line: String);
var
  F, Starts: specialize TArray<String>;
  M: TCatalogMap;
  I: Integer;
begin
  if (Line = '') or (Line[1] = '#') then
    Exit;
  F := SplitTabs(Line, #9);
  if Length(F) < 12 then
    Exit;
  M := Default(TCatalogMap);
  M.Id := F[0];
  M.Sha256 := LowerCase(F[1]);
  M.Bytes := StrToInt64Def(F[2], 0);
  M.Title := F[3];
  M.Author := F[4];
  M.Date := F[5];
  M.Rating := StrToFloatDef(F[6], -1, DefaultFormatSettings);
  M.Size := F[7];
  M.Flags := F[8];
  Starts := SplitTabs(F[9], ',');
  for I := 0 to High(Starts) do
    if Starts[I] <> '' then
    begin
      SetLength(M.StartMaps, Length(M.StartMaps) + 1);
      M.StartMaps[High(M.StartMaps)] := Starts[I];
    end;
  M.Mapping := F[10];
  M.Url := F[11];
  if (M.Id = '') or (Length(M.StartMaps) = 0) then
    Exit;
  SetLength(FMaps, Length(FMaps) + 1);
  FMaps[High(FMaps)] := M;
end;

procedure TQuakeMapBrowser.LoadCatalog;
var
  Lines: TStringList;
  Stream: TStream;
  I: Integer;
begin
  FMaps := nil;
  if MapCatalogOverride <> '' then
    FCatalogUrl := MapCatalogOverride
  else if UriExists(UpdatedCatalog) = ueFile then
    FCatalogUrl := UpdatedCatalog
  else
    FCatalogUrl := BundledCatalog;
  if not (UriExists(FCatalogUrl) in [ueFile, ueUnknown]) then
  begin
    WritelnWarning('MapBrowser', 'No map catalog at "%s"', [FCatalogUrl]);
    Exit;
  end;
  Lines := TStringList.Create;
  try
    try
      Stream := Download(FCatalogUrl);
      try
        Lines.LoadFromStream(Stream);
      finally
        Stream.Free;
      end;
    except
      on E: Exception do
      begin
        WritelnWarning('MapBrowser', 'Cannot read the map catalog "%s": %s', [FCatalogUrl, E.Message]);
        Exit;
      end;
    end;
    for I := 0 to Lines.Count - 1 do
      ParseLine(Lines[I]);
  finally
    Lines.Free;
  end;
  WritelnLog('MapBrowser', 'Map catalog "%s": %d maps', [FCatalogUrl, Length(FMaps)]);
end;

function TQuakeMapBrowser.GetMap(const I: Integer): TCatalogMap;
begin
  Result := FMaps[I];
end;

function TQuakeMapBrowser.Count: Integer;
begin
  Result := Length(FMaps);
end;

function TQuakeMapBrowser.IndexOf(const Id: String): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FMaps) do
    if SameText(FMaps[I].Id, Id) then
      Exit(I);
  Result := -1;
end;

function TQuakeMapBrowser.ZipUrl(const I: Integer): String;
begin
  Result := 'castle-config:/quaddicted_' + LowerCase(FMaps[I].Id) + '.zip';
end;

function TQuakeMapBrowser.Installed(const I: Integer): Boolean;
begin
  Result := (I >= 0) and (I < Length(FMaps)) and (UriExists(ZipUrl(I)) = ueFile);
end;

function TQuakeMapBrowser.Downloading: Boolean;
begin
  Result := FDownload <> nil;
end;

function TQuakeMapBrowser.DownloadingIndex: Integer;
begin
  if FDownload <> nil then
    Result := FDownloadIndex
  else
    Result := -1;
end;

function TQuakeMapBrowser.Progress: Single;
var
  Total: Int64;
begin
  Result := 0;
  if FDownload = nil then
    Exit;
  Total := FDownload.TotalBytes;
  if Total <= 0 then
    Total := FMaps[FDownloadIndex].Bytes;
  if Total > 0 then
    Result := EnsureRange(FDownload.DownloadedBytes / Total, 0, 1);
end;

function TQuakeMapBrowser.Install(const I: Integer): Boolean;
begin
  Result := False;
  if (I < 0) or (I >= Length(FMaps)) then
    Exit;
  {$ifdef WASI}
  { The browser keeps the config directory in localStorage, too small for
    map zips }
  FStatus := 'Downloading maps needs the desktop or Android version';
  WritelnLog('MapBrowser', FStatus);
  Exit;
  {$endif}
  if FDownload <> nil then
  begin
    FStatus := 'Already downloading ' + FMaps[FDownloadIndex].Title;
    Exit;
  end;
  FDownloadIndex := I;
  FDownload := TCastleDownload.Create(nil);
  FDownload.Url := FMaps[I].Url;
  FDownload.Options := [soForceMemoryStream];
  FDownload.Start;
  FStatus := 'Downloading ' + FMaps[I].Title;
  WritelnLog('MapBrowser', 'Downloading "%s" from %s (%d bytes)', [FMaps[I].Id, FMaps[I].Url, FMaps[I].Bytes]);
  Result := True;
end;

procedure TQuakeMapBrowser.FinishDownload;
var
  M: TCatalogMap;
  Data: TMemoryStream;
  Digest: String;
  Dest: TStream;
begin
  M := FMaps[FDownloadIndex];
  try
    if FDownload.Status = dsError then
    begin
      FStatus := 'Download of ' + M.Title + ' failed: ' + FDownload.ErrorMessage;
      WritelnWarning('MapBrowser', 'Download of "%s" failed: %s', [M.Id, FDownload.ErrorMessage]);
      Exit;
    end;
    Data := TMemoryStream.Create;
    try
      FDownload.Contents.Position := 0;
      Data.CopyFrom(FDownload.Contents, FDownload.Contents.Size);
      Digest := Sha256Hex(Data.Memory, Data.Size);
      if Digest <> M.Sha256 then
      begin
        FStatus := M.Title + ': the download does not match its SHA-256, not installed';
        WritelnWarning('MapBrowser', 'Map "%s": SHA-256 %s does not match %s, not installed',
          [M.Id, Digest, M.Sha256]);
        Exit;
      end;
      try
        Dest := UrlSaveStream(ZipUrl(FDownloadIndex));
        try
          Data.Position := 0;
          Dest.CopyFrom(Data, Data.Size);
        finally
          Dest.Free;
        end;
      except
        on E: Exception do
        begin
          FStatus := 'Cannot keep ' + M.Title + ': ' + E.Message;
          WritelnWarning('MapBrowser', 'Cannot save "%s": %s', [ZipUrl(FDownloadIndex), E.Message]);
          Exit;
        end;
      end;
      FStatus := M.Title + ' installed';
      WritelnLog('MapBrowser', 'Map "%s" installed: %d bytes, SHA-256 %s', [M.Id, Data.Size, Digest]);
    finally
      Data.Free;
    end;
  finally
    FreeAndNil(FDownload);
  end;
end;

procedure TQuakeMapBrowser.Update;
begin
  if (FDownload <> nil) and (FDownload.Status <> dsDownloading) then
    FinishDownload
  else if FDownload <> nil then
    FStatus := Format('Downloading %s: %d%%', [FMaps[FDownloadIndex].Title, Round(Progress * 100)]);
end;

procedure TQuakeMapBrowser.Remove(const I: Integer);
var
  FileName: String;
begin
  if not Installed(I) then
    Exit;
  FileName := UriToFilenameSafe(ZipUrl(I));
  if (FileName <> '') and DeleteFile(FileName) then
  begin
    FStatus := FMaps[I].Title + ' removed';
    WritelnLog('MapBrowser', 'Map "%s" removed', [FMaps[I].Id]);
  end else
    FStatus := 'Cannot remove ' + FMaps[I].Title;
end;

function TQuakeMapBrowser.Mount(const I: Integer): Boolean;
begin
  Result := False;
  if not Installed(I) then
    Exit;
  if FMounted.IndexOf(FMaps[I].Id) >= 0 then
    Exit(True);
  Result := Pak.AddPk3(ZipUrl(I), FMaps[I].Mapping);
  if Result then
  begin
    FMounted.Add(FMaps[I].Id);
    WritelnLog('MapBrowser', 'Mounted "%s" (%s), start maps: %s',
      [FMaps[I].Id, FMaps[I].Title, String.Join(', ', FMaps[I].StartMaps)]);
  end;
end;

function TQuakeMapBrowser.Describe(const I: Integer): String;
var
  M: TCatalogMap;
begin
  M := FMaps[I];
  { Short enough for a menu line }
  Result := M.Title;
  if Length(Result) > 44 then
    Result := Copy(Result, 1, 41) + '...';
  if M.Author <> '' then
  begin
    if Length(M.Author) > 24 then
      Result := Result + ' by ' + Copy(M.Author, 1, 21) + '...'
    else
      Result := Result + ' by ' + M.Author;
  end;
  if Length(M.Date) >= 4 then
    Result := Result + ' (' + Copy(M.Date, 1, 4) + ')';
  if M.Rating >= 0 then
    Result := Result + Format(' %.1f/5', [M.Rating], DefaultFormatSettings);
  Result := Result + Format(' %.1f MB', [M.Bytes / (1024 * 1024)], DefaultFormatSettings);
end;

function TQuakeMapBrowser.Sorted(const Sort: TMapSort; const Filter: String): specialize TArray<Integer>;
var
  N, I, J, Gap: Integer;
  T: Integer;
  F: String;

  function Before(const A, B: Integer): Boolean;
  begin
    case Sort of
      msRating:
        if FMaps[A].Rating <> FMaps[B].Rating then
          Exit(FMaps[A].Rating > FMaps[B].Rating);
      msNewest:
        if FMaps[A].Date <> FMaps[B].Date then
          Exit(FMaps[A].Date > FMaps[B].Date);
      else ;
    end;
    Result := CompareText(FMaps[A].Title, FMaps[B].Title) < 0;
  end;

begin
  Result := nil;
  F := LowerCase(Filter);
  N := 0;
  SetLength(Result, Length(FMaps));
  for I := 0 to High(FMaps) do
  begin
    if (Sort = msInstalled) and not Installed(I) then
      Continue;
    if (F <> '') and (Pos(F, LowerCase(FMaps[I].Title + ' ' + FMaps[I].Author + ' ' + FMaps[I].Id)) = 0) then
      Continue;
    Result[N] := I;
    Inc(N);
  end;
  SetLength(Result, N);
  { Shell sort: no generics comparer (the web compiler's differs) }
  Gap := N div 2;
  while Gap > 0 do
  begin
    for I := Gap to N - 1 do
    begin
      T := Result[I];
      J := I;
      while (J >= Gap) and Before(T, Result[J - Gap]) do
      begin
        Result[J] := Result[J - Gap];
        Dec(J, Gap);
      end;
      Result[J] := T;
    end;
    Gap := Gap div 2;
  end;
end;

var
  FMapBrowser: TQuakeMapBrowser;

function MapBrowser: TQuakeMapBrowser;
begin
  if FMapBrowser = nil then
    FMapBrowser := TQuakeMapBrowser.Create;
  Result := FMapBrowser;
end;

function MapBrowserCreated: Boolean;
begin
  Result := FMapBrowser <> nil;
end;

finalization
  FreeAndNil(FMapBrowser);
end.
