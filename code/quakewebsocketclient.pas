{ The browser's network transport (WebAssembly build): a WebSocket opened
  through the JS object bridge (Job.JS) to a Castle Quake WebSocket relay,
  which forwards each binary message as one UDP datagram to the game
  server and back. The browser has no UDP sockets.

  WebAssembly cannot catch exceptions, so everything that may fail on the
  JS side (a bad URL, a ws:// URL from an https page, sending before the
  connection is open) runs inside JS try / catch blocks of a small factory
  function, and the Pascal side only polls. }
unit QuakeWebSocketClient;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

type
  TQuakeBrowserWebSocket = class
  private
    FSocket: TObject; { TJSObject }
    FUrl: String;
  public
    constructor Create(const AUrl: String);
    destructor Destroy; override;
    { WebSocket.readyState: 0 connecting, 1 open, 2 closing, 3 closed }
    function State: Integer;
    { The reason the socket could not be created ('' when it was) }
    function Error: String;
    function Send(const Data: TBytes): Boolean;
    { The next message received, False when none is waiting }
    function Receive(out Data: TBytes): Boolean;
    procedure Close;
    property Url: String read FUrl;
  end;

{ ws://host:port/ for a host and port, wss:// when the page itself is
  served over https (browsers refuse ws:// there); a ws:// or wss:// URL
  is kept as it is }
function WebSocketUrl(const Host: String; const Port: Word): String;

{ A query parameter of the web page (?name=value&...), '' when missing or
  in a native build }
function PageParameter(const Name: String): String;

implementation

{$if defined(WASI)}
uses
  Job.JS, CastleInternalJobWeb, CastleLog;
{$endif}

{ %XX escapes and + of a query string }
function DecodeUrlComponent(const S: String): String;
var
  I: Integer;
  V: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if (S[I] = '%') and (I + 2 <= Length(S)) and TryStrToInt('$' + Copy(S, I + 1, 2), V) then
    begin
      Result := Result + Chr(V);
      Inc(I, 3);
    end else
    begin
      if S[I] = '+' then
        Result := Result + ' '
      else
        Result := Result + S[I];
      Inc(I);
    end;
  end;
end;

{$if defined(WASI)}

const
  FactoryName = 'castleQuakeWebSocketOpen';
  { Returns a WebSocket (or a closed stand-in object when the constructor
    threw) with a message queue and safe poll / send methods }
  FactorySource =
    'var ws;' +
    'try {' +
    '  ws = new WebSocket(url);' +
    '  ws.binaryType = "arraybuffer";' +
    '  ws.quakeError = "";' +
    '  ws.quakeQueue = [];' +
    '  ws.onmessage = function (ev) {' +
    '    if (ev.data instanceof ArrayBuffer) ws.quakeQueue.push(new Uint8Array(ev.data));' +
    '  };' +
    '} catch (e) {' +
    '  ws = { readyState: 3, quakeError: String(e), quakeQueue: [], close: function () {} };' +
    '}' +
    'ws.quakePoll = function () {' +
    '  return this.quakeQueue.length > 0 ? this.quakeQueue.shift() : new Uint8Array(0);' +
    '};' +
    'ws.quakeSend = function (a) {' +
    '  try { if (this.readyState === 1) { this.send(a); return 1; } } catch (e) {}' +
    '  return 0;' +
    '};' +
    'ws.quakeClose = function () { try { this.close(); } catch (e) {} };' +
    'return ws;';

var
  FactoryInstalled: Boolean;

{ Job.JS objects are reference counted (TInterfacedObject): an object
  passed as an IJSObject is released with its last interface reference,
  so it is never freed by hand. The window keeps its own JS reference. }
procedure SetWindowProperty(const Name: String; const Value: IJSObject);
begin
  JSWindow.WriteJSPropertyObject(Name, Value);
end;

procedure InstallFactory;
var
  FunctionClass: TJSObject;
begin
  if FactoryInstalled then
    Exit;
  FunctionClass := TJSObject.JOBCreateGlobal('Function');
  SetWindowProperty(FactoryName,
    FunctionClass.NewJSObject([UnicodeString('url'), UnicodeString(FactorySource)], TJSObject));
  FunctionClass.Free;
  FactoryInstalled := True;
end;

function PageIsHttps: Boolean;
var
  Location: TJSObject;
begin
  Location := JSWindow.ReadJSPropertyObject('location', TJSObject);
  try
    Result := Location.ReadJSPropertyUnicodeString('protocol') = 'https:';
  finally
    Location.Free;
  end;
end;

function WebSocketUrl(const Host: String; const Port: Word): String;
begin
  if (Pos('ws://', LowerCase(Host)) = 1) or (Pos('wss://', LowerCase(Host)) = 1) then
    Exit(Host);
  if PageIsHttps then
    Result := Format('wss://%s:%d/', [Host, Port])
  else
    Result := Format('ws://%s:%d/', [Host, Port]);
end;

function PageParameter(const Name: String): String;
var
  Location: TJSObject;
  Search, Pair, Key: String;
  P: Integer;
begin
  Result := '';
  Location := JSWindow.ReadJSPropertyObject('location', TJSObject);
  try
    Search := String(Location.ReadJSPropertyUnicodeString('search'));
  finally
    Location.Free;
  end;
  if (Search <> '') and (Search[1] = '?') then
    Delete(Search, 1, 1);
  for Pair in Search.Split(['&']) do
  begin
    P := Pos('=', Pair);
    if P = 0 then
      Continue;
    Key := Copy(Pair, 1, P - 1);
    if SameText(Key, Name) then
      Exit(DecodeUrlComponent(Copy(Pair, P + 1, MaxInt)));
  end;
end;

constructor TQuakeBrowserWebSocket.Create(const AUrl: String);
begin
  inherited Create;
  FUrl := AUrl;
  InstallFactory;
  FSocket := JSWindow.InvokeJSObjectResult(FactoryName, [UnicodeString(AUrl)], TJSObject);
  if Error <> '' then
    WritelnWarning('QuakeNet', 'WebSocket %s: %s', [AUrl, Error])
  else
    WritelnLog('QuakeNet', 'WebSocket opening %s', [AUrl]);
end;

destructor TQuakeBrowserWebSocket.Destroy;
begin
  Close;
  FreeAndNil(FSocket);
  inherited Destroy;
end;

function TQuakeBrowserWebSocket.State: Integer;
begin
  if FSocket = nil then
    Exit(3);
  Result := TJSObject(FSocket).ReadJSPropertyLongInt('readyState');
end;

function TQuakeBrowserWebSocket.Error: String;
begin
  if FSocket = nil then
    Exit('no socket');
  Result := String(TJSObject(FSocket).ReadJSPropertyUnicodeString('quakeError'));
end;

function TQuakeBrowserWebSocket.Send(const Data: TBytes): Boolean;
var
  Arr: TJSUint8Array;
begin
  Result := False;
  if (FSocket = nil) or (Length(Data) = 0) or (State <> 1) then
    Exit;
  Arr := TJSUint8Array.Create(PByte(@Data[0]), Length(Data));
  try
    Result := TJSObject(FSocket).InvokeJSLongIntResult('quakeSend', [Arr]) = 1;
  finally
    Arr.Free;
  end;
end;

function TQuakeBrowserWebSocket.Receive(out Data: TBytes): Boolean;
var
  Arr: TJSUint8Array;
  Len: Integer;
begin
  SetLength(Data, 0);
  Result := False;
  if FSocket = nil then
    Exit;
  Arr := TJSObject(FSocket).InvokeJSObjectResult('quakePoll', [], TJSUint8Array) as TJSUint8Array;
  try
    Len := Arr.ReadJSPropertyLongInt('length');
    if Len <= 0 then
      Exit;
    SetLength(Data, Len);
    Arr.CopyToMemory(PByte(@Data[0]), Len);
    Result := True;
  finally
    Arr.Free;
  end;
end;

procedure TQuakeBrowserWebSocket.Close;
begin
  if FSocket <> nil then
    TJSObject(FSocket).InvokeJSNoResult('quakeClose', []);
end;

{$else}

{ Native builds use UDP directly: the class exists so the code compiles,
  and never connects }

function PageParameter(const Name: String): String;
begin
  Result := '';
end;

function WebSocketUrl(const Host: String; const Port: Word): String;
begin
  if (Pos('ws://', LowerCase(Host)) = 1) or (Pos('wss://', LowerCase(Host)) = 1) then
    Result := Host
  else
    Result := Format('ws://%s:%d/', [Host, Port]);
end;

constructor TQuakeBrowserWebSocket.Create(const AUrl: String);
begin
  inherited Create;
  FUrl := AUrl;
end;

destructor TQuakeBrowserWebSocket.Destroy;
begin
  inherited Destroy;
end;

function TQuakeBrowserWebSocket.State: Integer;
begin
  Result := 3;
end;

function TQuakeBrowserWebSocket.Error: String;
begin
  Result := 'WebSockets are only used by the web build';
end;

function TQuakeBrowserWebSocket.Send(const Data: TBytes): Boolean;
begin
  Result := False;
end;

function TQuakeBrowserWebSocket.Receive(out Data: TBytes): Boolean;
begin
  SetLength(Data, 0);
  Result := False;
end;

procedure TQuakeBrowserWebSocket.Close;
begin
end;

{$endif}

end.
