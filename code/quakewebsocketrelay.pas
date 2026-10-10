{ WebSocket relay for players in the browser: browsers have no UDP, so
  the web build talks WebSocket to this relay, which runs in the native
  executable (next to a listen server with -websocket, or alone with
  -wsrelay). Each browser gets its own UDP socket towards the game server;
  every binary WebSocket message is one UDP datagram and every datagram
  coming back is one binary message, so the game server sees ordinary UDP
  clients and needs no change.

  RFC 6455 subset: the HTTP upgrade handshake, unfragmented binary
  messages, ping / pong and close. No TLS: an https page (GitHub Pages)
  needs wss://, so put a TLS proxy (Caddy, nginx, stunnel...) in front. }
unit QuakeWebSocketRelay;

{$mode objfpc}{$H+}

interface

{$if defined(WASI)}
  {$define QUAKE_NO_SOCKETS}
{$endif}

uses
  SysUtils, Classes, Generics.Collections,
  {$ifndef QUAKE_NO_SOCKETS}
  Sockets, ctypes, {$ifdef UNIX} BaseUnix, {$else} WinSock2, {$endif} sha1, base64,
  {$endif}
  CastleLog, QuakeNet;

const
  MaxWebSocketMessage = 64 * 1024;

type
  TWebSocketRelayClient = class
    Sock: cint;
    Address: String;
    InBuf, OutBuf: TBytes;
    Handshaken, Closed: Boolean;
    Udp: TQuakeNetSocket;
    destructor Destroy; override;
  end;

  TQuakeWebSocketRelay = class
  private
    FListen: cint;
    FTarget: TInetSockAddr;
    FClients: specialize TObjectList<TWebSocketRelayClient>;
    FMessagesIn, FMessagesOut: Int64;
    procedure Accept;
    procedure ReadClient(const C: TWebSocketRelayClient);
    procedure Handshake(const C: TWebSocketRelayClient);
    procedure ParseFrames(const C: TWebSocketRelayClient);
    procedure QueueFrame(const C: TWebSocketRelayClient; const Opcode: Byte; const Payload: TBytes);
    procedure Flush(const C: TWebSocketRelayClient);
  public
    { Listen for WebSocket clients on ListenPort (TCP) and forward to the
      UDP game server at TargetHost:TargetPort }
    constructor Create(const ListenPort: Word; const TargetHost: String; const TargetPort: Word);
    destructor Destroy; override;
    function Valid: Boolean;
    procedure Update;
    function ClientCount: Integer;
    property MessagesIn: Int64 read FMessagesIn;   { browser -> server }
    property MessagesOut: Int64 read FMessagesOut; { server -> browser }
  end;

{ The Sec-WebSocket-Accept value for a Sec-WebSocket-Key (RFC 6455 4.2.2) }
function WebSocketAcceptKey(const Key: String): String;

implementation

const
  WebSocketGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

{$ifdef QUAKE_NO_SOCKETS}

function WebSocketAcceptKey(const Key: String): String;
begin
  Result := '';
end;

destructor TWebSocketRelayClient.Destroy;
begin
  Udp.Free;
  inherited Destroy;
end;

constructor TQuakeWebSocketRelay.Create(const ListenPort: Word; const TargetHost: String; const TargetPort: Word);
begin
  inherited Create;
  FListen := -1;
  FClients := specialize TObjectList<TWebSocketRelayClient>.Create(True);
  WritelnWarning('QuakeNet', 'No sockets on this platform: no WebSocket relay');
end;

destructor TQuakeWebSocketRelay.Destroy;
begin
  FClients.Free;
  inherited Destroy;
end;

function TQuakeWebSocketRelay.Valid: Boolean;
begin
  Result := False;
end;

procedure TQuakeWebSocketRelay.Update;
begin
end;

function TQuakeWebSocketRelay.ClientCount: Integer;
begin
  Result := 0;
end;

procedure TQuakeWebSocketRelay.Accept;
begin
end;

procedure TQuakeWebSocketRelay.ReadClient(const C: TWebSocketRelayClient);
begin
end;

procedure TQuakeWebSocketRelay.Handshake(const C: TWebSocketRelayClient);
begin
end;

procedure TQuakeWebSocketRelay.ParseFrames(const C: TWebSocketRelayClient);
begin
end;

procedure TQuakeWebSocketRelay.QueueFrame(const C: TWebSocketRelayClient; const Opcode: Byte; const Payload: TBytes);
begin
end;

procedure TQuakeWebSocketRelay.Flush(const C: TWebSocketRelayClient);
begin
end;

{$else}

function WebSocketAcceptKey(const Key: String): String;
var
  Digest: TSHA1Digest;
  Raw: String;
begin
  Digest := SHA1String(Trim(Key) + WebSocketGuid);
  SetLength(Raw, SizeOf(Digest));
  Move(Digest[0], Raw[1], SizeOf(Digest));
  Result := EncodeStringBase64(Raw);
end;

procedure SetNonBlocking(const S: cint);
{$ifndef UNIX}
var
  NonBlocking: u_long;
{$endif}
begin
  {$ifdef UNIX}
  fpfcntl(S, F_SETFL, fpfcntl(S, F_GETFL) or O_NONBLOCK);
  {$else}
  NonBlocking := 1;
  ioctlsocket(S, FIONBIO, @NonBlocking);
  {$endif}
end;

function WouldBlock: Boolean;
var
  E: cint;
begin
  E := SocketError;
  {$ifdef UNIX}
  Result := (E = ESysEAGAIN) or (E = ESysEWOULDBLOCK) or (E = ESysEINTR);
  {$else}
  Result := (E = WSAEWOULDBLOCK) or (E = WSAEINTR);
  {$endif}
end;

procedure AppendBytes(var Buf: TBytes; const Data: PByte; const Count: Integer);
var
  Old: Integer;
begin
  if Count <= 0 then
    Exit;
  Old := Length(Buf);
  SetLength(Buf, Old + Count);
  Move(Data^, Buf[Old], Count);
end;

procedure DropBytes(var Buf: TBytes; const Count: Integer);
begin
  if Count >= Length(Buf) then
    SetLength(Buf, 0)
  else
  begin
    Move(Buf[Count], Buf[0], Length(Buf) - Count);
    SetLength(Buf, Length(Buf) - Count);
  end;
end;

destructor TWebSocketRelayClient.Destroy;
begin
  if Sock >= 0 then
    CloseSocket(Sock);
  Udp.Free;
  inherited Destroy;
end;

constructor TQuakeWebSocketRelay.Create(const ListenPort: Word; const TargetHost: String; const TargetPort: Word);
var
  Addr: TInetSockAddr;
  Yes: cint;
begin
  inherited Create;
  FClients := specialize TObjectList<TWebSocketRelayClient>.Create(True);
  FListen := -1;
  if not TQuakeNetSocket.Resolve(TargetHost, TargetPort, FTarget) then
  begin
    WritelnWarning('QuakeNet', 'WebSocket relay: bad target address %s', [TargetHost]);
    Exit;
  end;
  FListen := fpsocket(AF_INET, SOCK_STREAM, 0);
  if FListen < 0 then
  begin
    WritelnWarning('QuakeNet', 'WebSocket relay: cannot create a TCP socket');
    Exit;
  end;
  Yes := 1;
  fpsetsockopt(FListen, SOL_SOCKET, SO_REUSEADDR, @Yes, SizeOf(Yes));
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := htons(ListenPort);
  Addr.sin_addr.s_addr := 0;
  if (fpbind(FListen, @Addr, SizeOf(Addr)) < 0) or (fplisten(FListen, 16) < 0) then
  begin
    WritelnWarning('QuakeNet', 'WebSocket relay: cannot listen on TCP port %d', [ListenPort]);
    CloseSocket(FListen);
    FListen := -1;
    Exit;
  end;
  SetNonBlocking(FListen);
  WritelnLog('QuakeNet', 'WebSocket relay on TCP port %d for %s', [ListenPort,
    TQuakeNetSocket.AddressToString(FTarget)]);
end;

destructor TQuakeWebSocketRelay.Destroy;
begin
  FClients.Free;
  if FListen >= 0 then
    CloseSocket(FListen);
  inherited Destroy;
end;

function TQuakeWebSocketRelay.Valid: Boolean;
begin
  Result := FListen >= 0;
end;

function TQuakeWebSocketRelay.ClientCount: Integer;
begin
  Result := FClients.Count;
end;

procedure TQuakeWebSocketRelay.Accept;
var
  Addr: TInetSockAddr;
  Len: TSockLen;
  S: cint;
  C: TWebSocketRelayClient;
begin
  while True do
  begin
    Len := SizeOf(Addr);
    S := fpaccept(FListen, @Addr, @Len);
    if S < 0 then
      Break;
    SetNonBlocking(S);
    C := TWebSocketRelayClient.Create;
    C.Sock := S;
    C.Address := TQuakeNetSocket.AddressToString(Addr);
    C.Udp := TQuakeNetSocket.Create(0);
    FClients.Add(C);
    WritelnLog('QuakeNet', 'WebSocket relay: %s connected', [C.Address]);
  end;
end;

procedure TQuakeWebSocketRelay.ReadClient(const C: TWebSocketRelayClient);
var
  Buf: array[0..8191] of Byte;
  N: ssize_t;
begin
  while not C.Closed do
  begin
    N := fprecv(C.Sock, @Buf[0], SizeOf(Buf), 0);
    if N > 0 then
    begin
      AppendBytes(C.InBuf, @Buf[0], N);
      if Length(C.InBuf) > 4 * MaxWebSocketMessage then
        C.Closed := True; { nobody sends that much }
    end else
    begin
      if (N = 0) or not WouldBlock then
        C.Closed := True;
      Break;
    end;
  end;
end;

procedure TQuakeWebSocketRelay.Handshake(const C: TWebSocketRelayClient);
var
  HeaderEnd, I: Integer;
  Header, Line, Key, Reply: String;
  Lines: TStringArray;
  Reply8: TBytes;
begin
  HeaderEnd := -1;
  for I := 0 to Length(C.InBuf) - 4 do
    if (C.InBuf[I] = 13) and (C.InBuf[I + 1] = 10) and (C.InBuf[I + 2] = 13) and (C.InBuf[I + 3] = 10) then
    begin
      HeaderEnd := I;
      Break;
    end;
  if HeaderEnd < 0 then
    Exit; { not complete yet }
  SetLength(Header, HeaderEnd);
  if HeaderEnd > 0 then
    Move(C.InBuf[0], Header[1], HeaderEnd);
  DropBytes(C.InBuf, HeaderEnd + 4);
  Key := '';
  Lines := Header.Split([#13#10]);
  for Line in Lines do
    if Pos('sec-websocket-key:', LowerCase(Line)) = 1 then
      Key := Trim(Copy(Line, Length('sec-websocket-key:') + 1, MaxInt));
  if (Length(Lines) = 0) or (Pos('GET ', Lines[0]) <> 1) or (Key = '') then
  begin
    Reply := 'HTTP/1.1 400 Bad Request'#13#10'Content-Type: text/plain'#13#10'Connection: close'#13#10#13#10 +
      'Castle Quake WebSocket relay: connect with a WebSocket client.'#13#10;
    AppendBytes(C.OutBuf, PByte(PChar(Reply)), Length(Reply));
    Flush(C);
    C.Closed := True;
    WritelnLog('QuakeNet', 'WebSocket relay: %s sent no WebSocket handshake', [C.Address]);
    Exit;
  end;
  Reply := 'HTTP/1.1 101 Switching Protocols'#13#10 +
    'Upgrade: websocket'#13#10 +
    'Connection: Upgrade'#13#10 +
    'Sec-WebSocket-Accept: ' + WebSocketAcceptKey(Key) + #13#10#13#10;
  Reply8 := TEncoding.ASCII.GetBytes(Reply);
  AppendBytes(C.OutBuf, @Reply8[0], Length(Reply8));
  C.Handshaken := True;
  WritelnLog('QuakeNet', 'WebSocket relay: %s upgraded', [C.Address]);
end;

procedure TQuakeWebSocketRelay.QueueFrame(const C: TWebSocketRelayClient; const Opcode: Byte; const Payload: TBytes);
var
  Head: array[0..9] of Byte;
  HeadLen, Len, I: Integer;
begin
  Len := Length(Payload);
  Head[0] := $80 or Opcode; { FIN, server frames are not masked }
  if Len < 126 then
  begin
    Head[1] := Len;
    HeadLen := 2;
  end else
  if Len < 65536 then
  begin
    Head[1] := 126;
    Head[2] := Len shr 8;
    Head[3] := Len and 255;
    HeadLen := 4;
  end else
  begin
    Head[1] := 127;
    for I := 0 to 7 do
      Head[2 + I] := (Int64(Len) shr (8 * (7 - I))) and 255;
    HeadLen := 10;
  end;
  AppendBytes(C.OutBuf, @Head[0], HeadLen);
  if Len > 0 then
    AppendBytes(C.OutBuf, @Payload[0], Len);
end;

procedure TQuakeWebSocketRelay.ParseFrames(const C: TWebSocketRelayClient);
var
  Opcode: Byte;
  Masked, Fin: Boolean;
  Len: Int64;
  Pos, I: Integer;
  Mask: array[0..3] of Byte;
  Payload: TBytes;
begin
  while not C.Closed and (Length(C.InBuf) >= 2) do
  begin
    Fin := (C.InBuf[0] and $80) <> 0;
    Opcode := C.InBuf[0] and $0F;
    Masked := (C.InBuf[1] and $80) <> 0;
    Len := C.InBuf[1] and $7F;
    Pos := 2;
    if Len = 126 then
    begin
      if Length(C.InBuf) < 4 then
        Exit;
      Len := (C.InBuf[2] shl 8) or C.InBuf[3];
      Pos := 4;
    end else
    if Len = 127 then
    begin
      if Length(C.InBuf) < 10 then
        Exit;
      Len := 0;
      for I := 2 to 9 do
        Len := (Len shl 8) or C.InBuf[I];
      Pos := 10;
    end;
    if Len > MaxWebSocketMessage then
    begin
      C.Closed := True;
      Exit;
    end;
    if Masked then
    begin
      if Length(C.InBuf) < Pos + 4 then
        Exit;
      Move(C.InBuf[Pos], Mask[0], 4);
      Inc(Pos, 4);
    end;
    if Length(C.InBuf) < Pos + Len then
      Exit; { the rest of the frame has not arrived }
    SetLength(Payload, Len);
    for I := 0 to Len - 1 do
      if Masked then
        Payload[I] := C.InBuf[Pos + I] xor Mask[I and 3]
      else
        Payload[I] := C.InBuf[Pos + I];
    DropBytes(C.InBuf, Pos + Len);
    case Opcode of
      2: { binary: one datagram }
        if Fin and (Len > 0) then
        begin
          C.Udp.Send(FTarget, Payload);
          Inc(FMessagesIn);
        end;
      8: { close: answer it }
        begin
          QueueFrame(C, 8, Payload);
          Flush(C);
          C.Closed := True;
        end;
      9: { ping }
        QueueFrame(C, 10, Payload);
      else ; { text, continuation and pong are not used }
    end;
  end;
end;

procedure TQuakeWebSocketRelay.Flush(const C: TWebSocketRelayClient);
var
  N: ssize_t;
begin
  while Length(C.OutBuf) > 0 do
  begin
    N := fpsend(C.Sock, @C.OutBuf[0], Length(C.OutBuf), 0);
    if N > 0 then
      DropBytes(C.OutBuf, N)
    else
    begin
      if not WouldBlock then
        C.Closed := True;
      Break;
    end;
  end;
end;

procedure TQuakeWebSocketRelay.Update;
var
  I: Integer;
  C: TWebSocketRelayClient;
  Addr: TInetSockAddr;
  Data: TNetBytes;
begin
  if FListen < 0 then
    Exit;
  Accept;
  for I := FClients.Count - 1 downto 0 do
  begin
    C := FClients[I];
    ReadClient(C);
    if not C.Handshaken and not C.Closed then
      Handshake(C);
    if C.Handshaken then
    begin
      ParseFrames(C);
      { The server's datagrams back to the browser }
      while not C.Closed and C.Udp.Receive(Addr, Data) do
        if TQuakeNetSocket.SameAddress(Addr, FTarget) then
        begin
          QueueFrame(C, 2, Data);
          Inc(FMessagesOut);
        end;
    end;
    if Length(C.OutBuf) > 0 then
      Flush(C);
    if C.Closed then
    begin
      WritelnLog('QuakeNet', 'WebSocket relay: %s left', [C.Address]);
      FClients.Delete(I);
    end;
  end;
end;

{$endif}

end.
