{ Keeps the user config directory of the web build between visits.

  In the browser the engine's castle-config:/ is a memory file system that
  is gone when the page closes. RestoreWebStorage fills it from the
  browser's localStorage (keys "castle-quake:<path>", base64) before the
  config is read, and SyncWebStorage, run about once a second, writes back
  the files whose content changed: the user config (bindings, gamepad and
  video options) and the savegames. Files above MaxStoredFileSize (long
  demos) are left out, localStorage being a few megabytes.

  WebAssembly cannot catch exceptions, so the localStorage calls (which
  throw in private windows or when the quota is full) run inside JS
  try / catch blocks of a small helper object; native builds do nothing. }
unit QuakeWebStorage;

{$mode objfpc}{$H+}

interface

const
  WebStorageKeyPrefix = 'castle-quake:';
  MaxStoredFileSize = 1024 * 1024;

{ Copy the files saved by an earlier visit into castle-config:/; returns
  how many (0 in native builds) }
function RestoreWebStorage: Integer;

{ Write the castle-config:/ files that changed since the last call (or
  the restore) to localStorage; returns how many }
function SyncWebStorage: Integer;

{ Run SyncWebStorage about once a second from the application's update }
procedure StartWebStorageSync;

implementation

{$if defined(WASI)}

uses
  SysUtils, Classes, Generics.Collections,
  Job.JS, CastleInternalJobWeb, CastleLog, CastleDownload, CastleFindFiles,
  CastleApplicationProperties, CastleTimeUtils;

const
  HelperName = 'castleQuakeStorage';
  { An object with keys / get / set over localStorage, base64 inside JS }
  HelperSource =
    'var s = null;' +
    'try { s = window.localStorage; } catch (e) { s = null; }' +
    'return {' +
    '  keys: function (prefix) {' +
    '    var r = [];' +
    '    try { for (var i = 0; s && i < s.length; i++) { var k = s.key(i);' +
    '      if (k.indexOf(prefix) === 0) r.push(k.substring(prefix.length)); } } catch (e) {}' +
    '    return r.join("\n");' +
    '  },' +
    '  get: function (key) {' +
    '    try { var v = s ? s.getItem(key) : null; if (v === null) return new Uint8Array(0);' +
    '      var b = atob(v); var a = new Uint8Array(b.length);' +
    '      for (var i = 0; i < b.length; i++) a[i] = b.charCodeAt(i);' +
    '      return a; } catch (e) { return new Uint8Array(0); }' +
    '  },' +
    '  set: function (key, data) {' +
    '    try { var b = ""; for (var i = 0; i < data.length; i += 8192)' +
    '        b += String.fromCharCode.apply(null, data.subarray(i, i + 8192));' +
    '      s.setItem(key, btoa(b)); return 1; } catch (e) { return 0; }' +
    '  }' +
    '};';

type
  TStorageSync = class
  private
    FTime: TTimerResult;
    FStarted: Boolean;
    FFiles: TStringList;
    procedure FoundFile(const FileInfo: TFileInfo; var StopSearch: Boolean);
    procedure Update(Sender: TObject);
  end;

var
  Helper: TJSObject;
  { Content of each file as last stored, so unchanged files are skipped }
  Stored: specialize TDictionary<String, String>;
  Sync: TStorageSync;
  WarnedQuota: Boolean;

function GetHelper: TJSObject;
var
  FunctionClass: TJSObject;
  Factory: IJSObject;
begin
  if Helper = nil then
  begin
    FunctionClass := TJSObject.JOBCreateGlobal('Function');
    Factory := FunctionClass.NewJSObject([UnicodeString(HelperSource)], TJSObject);
    FunctionClass.Free;
    JSWindow.WriteJSPropertyObject(HelperName + 'Factory', Factory);
    Helper := JSWindow.InvokeJSObjectResult(HelperName + 'Factory', [], TJSObject);
  end;
  Result := Helper;
end;

function StreamToString(const Stream: TStream): String;
begin
  SetLength(Result, Stream.Size);
  Stream.Position := 0;
  if Stream.Size > 0 then
    Stream.ReadBuffer(Result[1], Stream.Size);
end;

{ The path inside castle-config:/ of a URL found there }
function ConfigPath(const Url: String): String;
var
  P: Integer;
begin
  Result := Url;
  P := Pos(':/', Result);
  if P > 0 then
    Delete(Result, 1, P + 1);
  while (Result <> '') and (Result[1] = '/') do
    Delete(Result, 1, 1);
end;

function RestoreWebStorage: Integer;
var
  Keys: String;
  Path: String;
  Arr: TJSUint8Array;
  Len: Integer;
  Data: TMemoryStream;
  Dest: TStream;
begin
  Result := 0;
  if Stored = nil then
    Stored := specialize TDictionary<String, String>.Create;
  Keys := String(GetHelper.InvokeJSUnicodeStringResult('keys', [UnicodeString(WebStorageKeyPrefix)]));
  for Path in Keys.Split([#10]) do
  begin
    if (Path = '') or (Pos('..', Path) > 0) then
      Continue;
    Arr := GetHelper.InvokeJSObjectResult('get', [UnicodeString(WebStorageKeyPrefix + Path)], TJSUint8Array)
      as TJSUint8Array;
    Data := TMemoryStream.Create;
    try
      Len := Arr.ReadJSPropertyLongInt('length');
      Data.Size := Len;
      if Len > 0 then
        Arr.CopyToMemory(Data.Memory, Len);
      Dest := UrlSaveStream('castle-config:/' + Path);
      try
        if Len > 0 then
          Dest.WriteBuffer(Data.Memory^, Len);
      finally
        Dest.Free;
      end;
      Stored.AddOrSetValue(Path, StreamToString(Data));
      Inc(Result);
    finally
      Data.Free;
      Arr.Free;
    end;
  end;
  if Result > 0 then
    WritelnLog('QuakeWebStorage', 'Restored %d files from the browser storage', [Result]);
end;

procedure TStorageSync.FoundFile(const FileInfo: TFileInfo; var StopSearch: Boolean);
begin
  if not FileInfo.Directory then
    FFiles.Add(FileInfo.Url);
end;

function SyncWebStorage: Integer;
var
  Url, Path, Content: String;
  Previous: String;
  Stream: TStream;
  Arr: TJSUint8Array;
  Empty: Byte;
begin
  Result := 0;
  Empty := 0;
  if Stored = nil then
    Stored := specialize TDictionary<String, String>.Create;
  if Sync = nil then
    Sync := TStorageSync.Create;
  if Sync.FFiles = nil then
    Sync.FFiles := TStringList.Create;
  Sync.FFiles.Clear;
  FindFiles('castle-config:/', '*', False, @Sync.FoundFile, [ffRecursive]);
  for Url in Sync.FFiles do
  begin
    Path := ConfigPath(Url);
    Stream := Download('castle-config:/' + Path);
    try
      if Stream.Size > MaxStoredFileSize then
        Continue;
      Content := StreamToString(Stream);
    finally
      Stream.Free;
    end;
    if Stored.TryGetValue(Path, Previous) and (Previous = Content) then
      Continue;
    if Content <> '' then
      Arr := TJSUint8Array.Create(PByte(@Content[1]), Length(Content))
    else
      Arr := TJSUint8Array.Create(@Empty, 0);
    try
      if GetHelper.InvokeJSLongIntResult('set', [UnicodeString(WebStorageKeyPrefix + Path), Arr]) = 1 then
      begin
        Stored.AddOrSetValue(Path, Content);
        Inc(Result);
        WritelnLog('QuakeWebStorage', 'Stored "%s" (%d bytes) in the browser storage', [Path, Length(Content)]);
      end else
      if not WarnedQuota then
      begin
        WarnedQuota := True;
        WritelnWarning('QuakeWebStorage', 'The browser storage refused "%s" (private window or full)', [Path]);
      end;
    finally
      Arr.Free;
    end;
  end;
end;

procedure TStorageSync.Update(Sender: TObject);
begin
  if not FStarted then
  begin
    FTime := Timer;
    FStarted := True;
  end;
  if FTime.ElapsedTime < 1 then
    Exit;
  FTime := Timer;
  SyncWebStorage;
end;

procedure StartWebStorageSync;
begin
  if Sync = nil then
    Sync := TStorageSync.Create;
  ApplicationProperties.OnUpdate.Add(@Sync.Update);
end;

finalization
  FreeAndNil(Stored);
  if Sync <> nil then
    FreeAndNil(Sync.FFiles);
  FreeAndNil(Sync);
  FreeAndNil(Helper);

{$else}

function RestoreWebStorage: Integer;
begin
  Result := 0;
end;

function SyncWebStorage: Integer;
begin
  Result := 0;
end;

procedure StartWebStorageSync;
begin
end;

{$endif}

end.
