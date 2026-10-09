{ Network play: UDP sockets, a small packet protocol (a connect handshake,
  a stop-and-wait reliable channel for the signon, unreliable server
  frames and client input) and a builder for the NetQuake svc messages the
  server streams, the same ones TQuakeDemoReader plays. }
unit QuakeNet;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, Math, Sockets,
  ctypes, {$ifdef UNIX} BaseUnix, {$else} WinSock2, {$endif}
  CastleVectors, CastleLog;

const
  DefaultNetPort = 26000;
  NetProtocolVersion = 1;
  MaxNetClients = 8;
  MaxPacketSize = 8192;
  ReliableChunkSize = 1200;
  NetTimeout = 10.0;

  { Packet kinds (first byte) }
  pkConnect = 1;    { client -> server: protocol version }
  pkAccept = 2;     { server -> client }
  pkReliable = 3;   { server -> client: seq, svc data; acked }
  pkAck = 4;        { client -> server: seq }
  pkFrame = 5;      { server -> client: seq, svc data of one frame }
  pkInput = 6;      { client -> server }
  pkDisconnect = 7; { either way }
  pkRefuse = 8;     { server -> client: text }

  { Client input buttons }
  nbFire = 1;
  nbJump = 2;

type
  TNetBytes = TBytes;

  { One frame of a client's wishes }
  TNetInput = record
    Angles: TVector3;   { pitch, yaw, roll }
    Move: TVector3;     { forward, side, up (units per second) }
    Buttons: Byte;
    Impulse: Byte;
  end;

  TQuakeNetSocket = class
  private
    FSock: cint;
  public
    constructor Create(const Port: Word);
    destructor Destroy; override;
    function Valid: Boolean;
    function Send(const Addr: TInetSockAddr; const Data: TNetBytes): Boolean;
    { Non-blocking; False when nothing arrived }
    function Receive(out Addr: TInetSockAddr; out Data: TNetBytes): Boolean;
    class function Resolve(const Host: String; const Port: Word; out Addr: TInetSockAddr): Boolean;
    class function SameAddress(const A, B: TInetSockAddr): Boolean;
    class function AddressToString(const A: TInetSockAddr): String;
  end;

  { Builds svc messages; the boundaries let the signon be cut into
    datagrams between messages }
  TQuakeNetMessage = class
  private
    FData: TNetBytes;
    FSize: Integer;
    FBoundaries: specialize TList<Integer>;
    procedure Grow(const N: Integer);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    procedure BeginMessage;
    procedure WriteByte(const V: Integer);
    procedure WriteChar(const V: Integer);
    procedure WriteShort(const V: Integer);
    procedure WriteLong(const V: LongInt);
    procedure WriteFloat(const V: Single);
    procedure WriteString(const S: String);
    procedure WriteCoord(const V: Single);
    procedure WriteAngle(const V: Single);
    procedure WriteVector(const V: TVector3);
    { svc messages }
    procedure Time(const T: Single);
    procedure ServerInfo(const LevelName: String; const Models, Sounds: TStrings; const MaxClients: Integer);
    procedure SetView(const E: Integer);
    procedure SignonNum(const N: Integer);
    procedure LightStyle(const Index: Integer; const Pattern: String);
    procedure SpawnStatic(const ModelIndex, Frame, Skin: Integer; const Origin, Angles: TVector3);
    procedure UpdateStat(const Stat: Integer; const Value: LongInt);
    procedure SetAngle(const Angles: TVector3);
    procedure UpdateFrags(const Client, Frags: Integer);
    procedure UpdateName(const Client: Integer; const Name: String);
    { Every field is sent: the client has no baselines }
    procedure Entity(const Num, ModelIndex, Frame, Skin, Effects: Integer; const Origin, Angles: TVector3);
    procedure ClientData(const ViewHeight: Single; const Velocity: TVector3; const Items: Cardinal;
      const WeaponFrame, Armor, WeaponModel, Health, Ammo, Shells, Nails, Rockets, Cells,
      ActiveWeapon: Integer);
    procedure Sound(const E, Channel, SoundIdx: Integer; const Volume, Attenuation: Single; const Origin: TVector3);
    procedure TempEntity(const Kind: Integer; const Pos: TVector3);
    procedure Beam(const Kind, E: Integer; const Start, Stop: TVector3);
    procedure Print(const S: String);
    procedure CenterPrint(const S: String);
    procedure StuffText(const S: String);
    procedure Damage(const Armor, Blood: Integer; const From: TVector3);
    procedure Simple(const Svc: Integer);
    procedure Finale(const S: String);
    procedure Particle(const Org, Dir: TVector3; const Count, Color: Integer);

    function Bytes: TNetBytes;
    { Raw protocol bytes (a complete message or several) }
    procedure Append(const Data: TNetBytes);
    { The data cut between messages into pieces of at most MaxSize bytes }
    function Chunks(const MaxSize: Integer): specialize TList<TNetBytes>;
    property Size: Integer read FSize;
  end;

  TNetClientState = (csDisconnected, csConnecting, csConnected);

  { The client side of a connection }
  TQuakeNetClient = class
  private
    FSocket: TQuakeNetSocket;
    FServer: TInetSockAddr;
    FState: TNetClientState;
    FTimer, FSinceReceive: Single;
    FExpectedSeq: Word;
    FLastFrameSeq: Word;
    FHasFrame: Boolean;
    FBlocks: specialize TQueue<TNetBytes>;
    FError: String;
    procedure SendPacket(const Data: TNetBytes);
  public
    constructor Create;
    destructor Destroy; override;
    function Connect(const Host: String; const Port: Word): Boolean;
    procedure Disconnect;
    procedure Update(const SecondsPassed: Single);
    procedure SendInput(const Input: TNetInput);
    { The next received svc block (reliable data and frames, in order) }
    function PollBlock(out Data: TNetBytes): Boolean;
    property State: TNetClientState read FState;
    property Error: String read FError;
  end;

  TNetServerClient = record
    Active: Boolean;
    Addr: TInetSockAddr;
    Edict: Integer;
    SinceSeen: Single;
    Reliable: specialize TList<TNetBytes>;
    ReliableSeq: Word;      { seq of the chunk in flight }
    InFlight: Boolean;
    ResendTimer: Single;
    FrameSeq: Word;
    Input: TNetInput;
    HasInput: Boolean;
    SignonDone: Boolean;
  end;

  TNetConnectEvent = function(const Client: Integer): Integer of object; { returns the edict, 0 to refuse }
  TNetClientEvent = procedure(const Client: Integer) of object;
  TNetSignonEvent = procedure(const Client: Integer; const Msg: TQuakeNetMessage) of object;

  { The server side: accepts clients, delivers their input, sends the
    signon reliably and the frames unreliably }
  TQuakeNetServer = class
  private
    FSocket: TQuakeNetSocket;
    FClients: array[1..MaxNetClients] of TNetServerClient;
    function FindClient(const Addr: TInetSockAddr): Integer;
    procedure SendPacket(const C: Integer; const Data: TNetBytes);
    procedure SendReliableChunk(const C: Integer);
    procedure DropClient(const C: Integer; const Notify: Boolean);
    procedure QueueSignon(const C: Integer);
  public
    OnConnect: TNetConnectEvent;
    OnDisconnect: TNetClientEvent;
    OnSignon: TNetSignonEvent;

    constructor Create(const Port: Word);
    destructor Destroy; override;
    function Valid: Boolean;
    procedure Update(const SecondsPassed: Single);
    procedure SendFrame(const C: Integer; const Data: TNetBytes);
    { Reliable data to one client (a late centerprint, a level change) }
    procedure SendReliable(const C: Integer; const Data: TNetBytes);
    { Send the signon again (a new level): frames wait until it is acked }
    procedure Resignon(const C: Integer);
    procedure Shutdown;
    function ClientActive(const C: Integer): Boolean;
    function ClientEdict(const C: Integer): Integer;
    function ClientReady(const C: Integer): Boolean; { signon delivered }
    function ClientInput(const C: Integer; out Input: TNetInput): Boolean;
    function ClientAddress(const C: Integer): String;
    function ClientCount: Integer;
  end;

implementation

{ TQuakeNetSocket }

constructor TQuakeNetSocket.Create(const Port: Word);
var
  Addr: TInetSockAddr;
  {$ifndef UNIX} NonBlocking: u_long; {$endif}
begin
  inherited Create;
  FSock := fpsocket(AF_INET, SOCK_DGRAM, 0);
  if FSock < 0 then
  begin
    WritelnWarning('QuakeNet', 'Cannot create a UDP socket');
    Exit;
  end;
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := htons(Port);
  Addr.sin_addr.s_addr := 0; { any }
  if fpbind(FSock, @Addr, SizeOf(Addr)) < 0 then
  begin
    WritelnWarning('QuakeNet', 'Cannot bind UDP port %d', [Port]);
    CloseSocket(FSock);
    FSock := -1;
    Exit;
  end;
  {$ifdef UNIX}
  fpfcntl(FSock, F_SETFL, fpfcntl(FSock, F_GETFL) or O_NONBLOCK);
  {$else}
  NonBlocking := 1;
  ioctlsocket(FSock, FIONBIO, @NonBlocking);
  {$endif}
end;

destructor TQuakeNetSocket.Destroy;
begin
  if FSock >= 0 then
    CloseSocket(FSock);
  inherited Destroy;
end;

function TQuakeNetSocket.Valid: Boolean;
begin
  Result := FSock >= 0;
end;

function TQuakeNetSocket.Send(const Addr: TInetSockAddr; const Data: TNetBytes): Boolean;
begin
  if (FSock < 0) or (Length(Data) = 0) then
    Exit(False);
  Result := fpsendto(FSock, @Data[0], Length(Data), 0, @Addr, SizeOf(Addr)) = Length(Data);
end;

function TQuakeNetSocket.Receive(out Addr: TInetSockAddr; out Data: TNetBytes): Boolean;
var
  Buf: array[0..MaxPacketSize - 1] of Byte;
  Len: tsocklen;
  N: ssize_t;
begin
  Result := False;
  SetLength(Data, 0);
  FillChar(Addr, SizeOf(Addr), 0);
  if FSock < 0 then
    Exit;
  Len := SizeOf(Addr);
  N := fprecvfrom(FSock, @Buf[0], SizeOf(Buf), 0, @Addr, @Len);
  if N <= 0 then
    Exit;
  SetLength(Data, N);
  Move(Buf[0], Data[0], N);
  Result := True;
end;

class function TQuakeNetSocket.Resolve(const Host: String; const Port: Word; out Addr: TInetSockAddr): Boolean;
var
  H: String;
  Parts: TStringArray;
  I, V: Integer;
  IP: Cardinal;
begin
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := htons(Port);
  H := Trim(Host);
  if (H = '') or (H = 'localhost') then
    H := '127.0.0.1';
  { Dotted numbers only }
  Parts := H.Split(['.']);
  if Length(Parts) <> 4 then
    Exit(False);
  IP := 0;
  for I := 0 to 3 do
  begin
    V := StrToIntDef(Parts[I], -1);
    if (V < 0) or (V > 255) then
      Exit(False);
    IP := (IP shl 8) or Cardinal(V);
  end;
  Addr.sin_addr.s_addr := htonl(IP);
  Result := True;
end;

class function TQuakeNetSocket.SameAddress(const A, B: TInetSockAddr): Boolean;
begin
  Result := (A.sin_addr.s_addr = B.sin_addr.s_addr) and (A.sin_port = B.sin_port);
end;

class function TQuakeNetSocket.AddressToString(const A: TInetSockAddr): String;
var
  IP: Cardinal;
begin
  IP := ntohl(A.sin_addr.s_addr);
  Result := Format('%d.%d.%d.%d:%d', [(IP shr 24) and 255, (IP shr 16) and 255, (IP shr 8) and 255, IP and 255,
    ntohs(A.sin_port)]);
end;

{ TQuakeNetMessage }

constructor TQuakeNetMessage.Create;
begin
  inherited Create;
  FBoundaries := specialize TList<Integer>.Create;
  SetLength(FData, 4096);
end;

destructor TQuakeNetMessage.Destroy;
begin
  FBoundaries.Free;
  inherited Destroy;
end;

procedure TQuakeNetMessage.Clear;
begin
  FSize := 0;
  FBoundaries.Clear;
end;

procedure TQuakeNetMessage.BeginMessage;
begin
  FBoundaries.Add(FSize);
end;

procedure TQuakeNetMessage.Grow(const N: Integer);
begin
  if FSize + N > Length(FData) then
    SetLength(FData, Max(Length(FData) * 2, FSize + N));
end;

procedure TQuakeNetMessage.WriteByte(const V: Integer);
begin
  Grow(1);
  FData[FSize] := V and 255;
  Inc(FSize);
end;

procedure TQuakeNetMessage.WriteChar(const V: Integer);
begin
  WriteByte(EnsureRange(V, -128, 127) and 255);
end;

procedure TQuakeNetMessage.WriteShort(const V: Integer);
var
  S: SmallInt;
begin
  S := EnsureRange(V, -32768, 32767);
  Grow(2);
  Move(S, FData[FSize], 2);
  Inc(FSize, 2);
end;

procedure TQuakeNetMessage.WriteLong(const V: LongInt);
begin
  Grow(4);
  Move(V, FData[FSize], 4);
  Inc(FSize, 4);
end;

procedure TQuakeNetMessage.WriteFloat(const V: Single);
begin
  Grow(4);
  Move(V, FData[FSize], 4);
  Inc(FSize, 4);
end;

procedure TQuakeNetMessage.WriteString(const S: String);
begin
  Grow(Length(S) + 1);
  if S <> '' then
    Move(S[1], FData[FSize], Length(S));
  FData[FSize + Length(S)] := 0;
  Inc(FSize, Length(S) + 1);
end;

procedure TQuakeNetMessage.WriteCoord(const V: Single);
begin
  WriteShort(Round(V * 8));
end;

procedure TQuakeNetMessage.WriteAngle(const V: Single);
begin
  WriteByte(Round(V * 256 / 360) and 255);
end;

procedure TQuakeNetMessage.WriteVector(const V: TVector3);
begin
  WriteCoord(V.X);
  WriteCoord(V.Y);
  WriteCoord(V.Z);
end;

procedure TQuakeNetMessage.Time(const T: Single);
begin
  BeginMessage;
  WriteByte(7);
  WriteFloat(T);
end;

procedure TQuakeNetMessage.ServerInfo(const LevelName: String; const Models, Sounds: TStrings;
  const MaxClients: Integer);
var
  I: Integer;
begin
  BeginMessage;
  WriteByte(11);
  WriteLong(15);
  WriteByte(MaxClients);
  WriteByte(1); { gametype: deathmatch }
  WriteString(LevelName);
  for I := 0 to Models.Count - 1 do
    WriteString(Models[I]);
  WriteString('');
  for I := 0 to Sounds.Count - 1 do
    WriteString(Sounds[I]);
  WriteString('');
end;

procedure TQuakeNetMessage.SetView(const E: Integer);
begin
  BeginMessage;
  WriteByte(5);
  WriteShort(E);
end;

procedure TQuakeNetMessage.SignonNum(const N: Integer);
begin
  BeginMessage;
  WriteByte(25);
  WriteByte(N);
end;

procedure TQuakeNetMessage.LightStyle(const Index: Integer; const Pattern: String);
begin
  BeginMessage;
  WriteByte(12);
  WriteByte(Index);
  WriteString(Pattern);
end;

procedure TQuakeNetMessage.SpawnStatic(const ModelIndex, Frame, Skin: Integer; const Origin, Angles: TVector3);
begin
  BeginMessage;
  WriteByte(20);
  WriteByte(ModelIndex);
  WriteByte(Frame);
  WriteByte(0);
  WriteByte(Skin);
  WriteCoord(Origin.X);
  WriteAngle(Angles.X);
  WriteCoord(Origin.Y);
  WriteAngle(Angles.Y);
  WriteCoord(Origin.Z);
  WriteAngle(Angles.Z);
end;

procedure TQuakeNetMessage.UpdateStat(const Stat: Integer; const Value: LongInt);
begin
  BeginMessage;
  WriteByte(3);
  WriteByte(Stat);
  WriteLong(Value);
end;

procedure TQuakeNetMessage.SetAngle(const Angles: TVector3);
begin
  BeginMessage;
  WriteByte(10);
  WriteAngle(Angles.X);
  WriteAngle(Angles.Y);
  WriteAngle(Angles.Z);
end;

procedure TQuakeNetMessage.UpdateFrags(const Client, Frags: Integer);
begin
  BeginMessage;
  WriteByte(14);
  WriteByte(Client);
  WriteShort(Frags);
end;

procedure TQuakeNetMessage.UpdateName(const Client: Integer; const Name: String);
begin
  BeginMessage;
  WriteByte(13);
  WriteByte(Client);
  WriteString(Name);
end;

procedure TQuakeNetMessage.Entity(const Num, ModelIndex, Frame, Skin, Effects: Integer; const Origin, Angles: TVector3);
const
  U_MOREBITS = 1; U_ORIGIN1 = 2; U_ORIGIN2 = 4; U_ORIGIN3 = 8; U_ANGLE2 = 16; U_FRAME = 64; U_SIGNAL = 128;
  U_ANGLE1 = 256; U_ANGLE3 = 512; U_MODEL = 1024; U_SKIN = 4096; U_EFFECTS = 8192; U_LONGENTITY = 16384;
var
  Bits: Integer;
begin
  BeginMessage;
  Bits := U_SIGNAL or U_MODEL or U_FRAME or U_ORIGIN1 or U_ORIGIN2 or U_ORIGIN3 or U_ANGLE1 or U_ANGLE2 or U_ANGLE3;
  if Skin <> 0 then
    Bits := Bits or U_SKIN;
  if Effects <> 0 then
    Bits := Bits or U_EFFECTS;
  if Num > 255 then
    Bits := Bits or U_LONGENTITY;
  Bits := Bits or U_MOREBITS;
  WriteByte(Bits and 255);
  WriteByte(Bits shr 8);
  if (Bits and U_LONGENTITY) <> 0 then
    WriteShort(Num)
  else
    WriteByte(Num);
  WriteByte(ModelIndex);
  WriteByte(Frame);
  if (Bits and U_SKIN) <> 0 then
    WriteByte(Skin);
  if (Bits and U_EFFECTS) <> 0 then
    WriteByte(Effects);
  WriteCoord(Origin.X);
  WriteAngle(Angles.X);
  WriteCoord(Origin.Y);
  WriteAngle(Angles.Y);
  WriteCoord(Origin.Z);
  WriteAngle(Angles.Z);
end;

procedure TQuakeNetMessage.ClientData(const ViewHeight: Single; const Velocity: TVector3; const Items: Cardinal;
  const WeaponFrame, Armor, WeaponModel, Health, Ammo, Shells, Nails, Rockets, Cells, ActiveWeapon: Integer);
const
  SU_VIEWHEIGHT = 1; SU_VELOCITY1 = 32; SU_WEAPONFRAME = 4096; SU_ARMOR = 8192; SU_WEAPON = 16384;
var
  Bits, I: Integer;
begin
  BeginMessage;
  Bits := SU_VIEWHEIGHT or SU_VELOCITY1 or (SU_VELOCITY1 shl 1) or (SU_VELOCITY1 shl 2) or SU_WEAPONFRAME or
    SU_ARMOR or SU_WEAPON;
  WriteByte(15);
  WriteShort(Bits);
  WriteChar(Round(ViewHeight));
  for I := 0 to 2 do
    WriteChar(Round(Velocity.Data[I] / 16));
  WriteLong(LongInt(Items));
  WriteByte(WeaponFrame);
  WriteByte(EnsureRange(Armor, 0, 255));
  WriteByte(WeaponModel);
  WriteShort(Health);
  WriteByte(EnsureRange(Ammo, 0, 255));
  WriteByte(EnsureRange(Shells, 0, 255));
  WriteByte(EnsureRange(Nails, 0, 255));
  WriteByte(EnsureRange(Rockets, 0, 255));
  WriteByte(EnsureRange(Cells, 0, 255));
  WriteByte(ActiveWeapon and 255);
end;

procedure TQuakeNetMessage.Sound(const E, Channel, SoundIdx: Integer; const Volume, Attenuation: Single;
  const Origin: TVector3);
begin
  if SoundIdx <= 0 then
    Exit;
  BeginMessage;
  WriteByte(6);
  WriteByte(3);
  WriteByte(Round(EnsureRange(Volume, 0, 1) * 255));
  WriteByte(Round(EnsureRange(Attenuation, 0, 3.98) * 64));
  WriteShort((E shl 3) or (Channel and 7));
  WriteByte(SoundIdx);
  WriteVector(Origin);
end;

procedure TQuakeNetMessage.TempEntity(const Kind: Integer; const Pos: TVector3);
begin
  BeginMessage;
  WriteByte(23);
  WriteByte(Kind);
  WriteVector(Pos);
end;

procedure TQuakeNetMessage.Beam(const Kind, E: Integer; const Start, Stop: TVector3);
begin
  BeginMessage;
  WriteByte(23);
  WriteByte(Kind);
  WriteShort(E);
  WriteVector(Start);
  WriteVector(Stop);
end;

procedure TQuakeNetMessage.Print(const S: String);
begin
  BeginMessage;
  WriteByte(8);
  WriteString(S);
end;

procedure TQuakeNetMessage.CenterPrint(const S: String);
begin
  BeginMessage;
  WriteByte(26);
  WriteString(S);
end;

procedure TQuakeNetMessage.StuffText(const S: String);
begin
  BeginMessage;
  WriteByte(9);
  WriteString(S);
end;

procedure TQuakeNetMessage.Damage(const Armor, Blood: Integer; const From: TVector3);
begin
  BeginMessage;
  WriteByte(19);
  WriteByte(EnsureRange(Armor, 0, 255));
  WriteByte(EnsureRange(Blood, 0, 255));
  WriteVector(From);
end;

procedure TQuakeNetMessage.Simple(const Svc: Integer);
begin
  BeginMessage;
  WriteByte(Svc);
end;

procedure TQuakeNetMessage.Finale(const S: String);
begin
  BeginMessage;
  WriteByte(31);
  WriteString(S);
end;

procedure TQuakeNetMessage.Particle(const Org, Dir: TVector3; const Count, Color: Integer);
var
  I: Integer;
begin
  BeginMessage;
  WriteByte(18);
  WriteVector(Org);
  for I := 0 to 2 do
    WriteChar(Round(EnsureRange(Dir.Data[I] * 16, -128, 127)));
  WriteByte(EnsureRange(Count, 1, 255));
  WriteByte(Color);
end;

procedure TQuakeNetMessage.Append(const Data: TNetBytes);
begin
  if Length(Data) = 0 then
    Exit;
  BeginMessage;
  Grow(Length(Data));
  Move(Data[0], FData[FSize], Length(Data));
  FSize := FSize + Length(Data);
end;

function TQuakeNetMessage.Bytes: TNetBytes;
begin
  SetLength(Result, FSize);
  if FSize > 0 then
    Move(FData[0], Result[0], FSize);
end;

function TQuakeNetMessage.Chunks(const MaxSize: Integer): specialize TList<TNetBytes>;
var
  I, Start, Stop, Next: Integer;
  Chunk: TNetBytes;
begin
  Result := specialize TList<TNetBytes>.Create;
  Start := 0;
  I := 0;
  while Start < FSize do
  begin
    { Take messages while they fit; a single oversized message goes alone }
    Stop := Start;
    while I < FBoundaries.Count do
    begin
      if I + 1 < FBoundaries.Count then
        Next := FBoundaries[I + 1]
      else
        Next := FSize;
      if (Next - Start > MaxSize) and (Stop > Start) then
        Break;
      Stop := Next;
      Inc(I);
      if Stop - Start >= MaxSize then
        Break;
    end;
    if Stop <= Start then
      Stop := FSize;
    SetLength(Chunk, Stop - Start);
    Move(FData[Start], Chunk[0], Stop - Start);
    Result.Add(Chunk);
    Start := Stop;
  end;
end;

{ Packet helpers }

function PacketHeader(const Kind: Integer; const Seq: Word; const PayloadSize: Integer): TNetBytes;
begin
  SetLength(Result, 3 + PayloadSize);
  Result[0] := Kind;
  Result[1] := Seq and 255;
  Result[2] := Seq shr 8;
end;

function PacketSeq(const Data: TNetBytes): Word;
begin
  Result := Data[1] or (Data[2] shl 8);
end;

{ TQuakeNetClient }

constructor TQuakeNetClient.Create;
begin
  inherited Create;
  FBlocks := specialize TQueue<TNetBytes>.Create;
end;

destructor TQuakeNetClient.Destroy;
begin
  Disconnect;
  FSocket.Free;
  FBlocks.Free;
  inherited Destroy;
end;

procedure TQuakeNetClient.SendPacket(const Data: TNetBytes);
begin
  if FSocket <> nil then
    FSocket.Send(FServer, Data);
end;

function TQuakeNetClient.Connect(const Host: String; const Port: Word): Boolean;
begin
  Disconnect;
  FError := '';
  if not TQuakeNetSocket.Resolve(Host, Port, FServer) then
  begin
    FError := 'Bad address ' + Host;
    Exit(False);
  end;
  FreeAndNil(FSocket);
  FSocket := TQuakeNetSocket.Create(0);
  if not FSocket.Valid then
  begin
    FError := 'No socket';
    Exit(False);
  end;
  FState := csConnecting;
  FTimer := 1; { send at once }
  FSinceReceive := 0;
  FExpectedSeq := 0;
  FHasFrame := False;
  FBlocks.Clear;
  WritelnLog('QuakeNet', 'Connecting to %s', [TQuakeNetSocket.AddressToString(FServer)]);
  Result := True;
end;

procedure TQuakeNetClient.Disconnect;
var
  P: TNetBytes;
begin
  if FState <> csDisconnected then
  begin
    P := PacketHeader(pkDisconnect, 0, 0);
    SendPacket(P);
    FState := csDisconnected;
  end;
end;

procedure TQuakeNetClient.Update(const SecondsPassed: Single);
var
  Addr: TInetSockAddr;
  Data, P, Payload: TNetBytes;
  Seq: Word;
begin
  if (FState = csDisconnected) or (FSocket = nil) then
    Exit;
  FTimer := FTimer + SecondsPassed;
  FSinceReceive := FSinceReceive + SecondsPassed;
  if FState = csConnecting then
  begin
    if FTimer >= 0.5 then
    begin
      FTimer := 0;
      P := PacketHeader(pkConnect, NetProtocolVersion, 0);
      SendPacket(P);
    end;
    if FSinceReceive > NetTimeout then
    begin
      FError := 'No answer from the server';
      FState := csDisconnected;
      Exit;
    end;
  end else
  if FSinceReceive > NetTimeout then
  begin
    FError := 'Connection timed out';
    FState := csDisconnected;
    Exit;
  end;

  while FSocket.Receive(Addr, Data) do
  begin
    if (Length(Data) < 3) or not TQuakeNetSocket.SameAddress(Addr, FServer) then
      Continue;
    FSinceReceive := 0;
    Seq := PacketSeq(Data);
    case Data[0] of
      pkAccept:
        if FState = csConnecting then
        begin
          FState := csConnected;
          WritelnLog('QuakeNet', 'Connected');
        end;
      pkRefuse:
        begin
          SetLength(Payload, Length(Data) - 3);
          if Length(Payload) > 0 then
            Move(Data[3], Payload[0], Length(Payload));
          FError := 'Refused: ' + TEncoding.ASCII.GetAnsiString(Payload);
          FState := csDisconnected;
          Exit;
        end;
      pkReliable:
        begin
          { Stop and wait: only the expected chunk is taken, every one is acked }
          if Seq = FExpectedSeq then
          begin
            SetLength(Payload, Length(Data) - 3);
            if Length(Payload) > 0 then
              Move(Data[3], Payload[0], Length(Payload));
            FBlocks.Enqueue(Payload);
            Inc(FExpectedSeq);
          end;
          P := PacketHeader(pkAck, Seq, 0);
          SendPacket(P);
        end;
      pkFrame:
        begin
          { Old frames out of order are dropped }
          if FHasFrame and (SmallInt(Seq - FLastFrameSeq) <= 0) then
            Continue;
          FLastFrameSeq := Seq;
          FHasFrame := True;
          SetLength(Payload, Length(Data) - 3);
          if Length(Payload) > 0 then
            Move(Data[3], Payload[0], Length(Payload));
          FBlocks.Enqueue(Payload);
        end;
      pkDisconnect:
        begin
          FError := 'The server closed the connection';
          FState := csDisconnected;
          Exit;
        end;
    end;
  end;
end;

procedure TQuakeNetClient.SendInput(const Input: TNetInput);
var
  P: TNetBytes;
begin
  if FState <> csConnected then
    Exit;
  P := PacketHeader(pkInput, 0, SizeOf(Input));
  Move(Input, P[3], SizeOf(Input));
  SendPacket(P);
end;

function TQuakeNetClient.PollBlock(out Data: TNetBytes): Boolean;
begin
  Result := FBlocks.Count > 0;
  if Result then
    Data := FBlocks.Dequeue
  else
    SetLength(Data, 0);
end;

{ TQuakeNetServer }

constructor TQuakeNetServer.Create(const Port: Word);
var
  I: Integer;
begin
  inherited Create;
  FSocket := TQuakeNetSocket.Create(Port);
  for I := 1 to MaxNetClients do
    FClients[I].Reliable := specialize TList<TNetBytes>.Create;
  if FSocket.Valid then
    WritelnLog('QuakeNet', 'Server listening on UDP port %d', [Port]);
end;

destructor TQuakeNetServer.Destroy;
var
  I: Integer;
begin
  Shutdown;
  for I := 1 to MaxNetClients do
    FClients[I].Reliable.Free;
  FSocket.Free;
  inherited Destroy;
end;

function TQuakeNetServer.Valid: Boolean;
begin
  Result := FSocket.Valid;
end;

function TQuakeNetServer.FindClient(const Addr: TInetSockAddr): Integer;
var
  I: Integer;
begin
  for I := 1 to MaxNetClients do
    if FClients[I].Active and TQuakeNetSocket.SameAddress(FClients[I].Addr, Addr) then
      Exit(I);
  Result := 0;
end;

procedure TQuakeNetServer.SendPacket(const C: Integer; const Data: TNetBytes);
begin
  FSocket.Send(FClients[C].Addr, Data);
end;

procedure TQuakeNetServer.SendReliableChunk(const C: Integer);
var
  P: TNetBytes;
  Chunk: TNetBytes;
begin
  if FClients[C].Reliable.Count = 0 then
  begin
    FClients[C].InFlight := False;
    Exit;
  end;
  Chunk := FClients[C].Reliable[0];
  P := PacketHeader(pkReliable, FClients[C].ReliableSeq, Length(Chunk));
  if Length(Chunk) > 0 then
    Move(Chunk[0], P[3], Length(Chunk));
  SendPacket(C, P);
  FClients[C].InFlight := True;
  FClients[C].ResendTimer := 0;
end;

procedure TQuakeNetServer.DropClient(const C: Integer; const Notify: Boolean);
var
  P: TNetBytes;
begin
  if not FClients[C].Active then
    Exit;
  if Notify then
  begin
    P := PacketHeader(pkDisconnect, 0, 0);
    SendPacket(C, P);
  end;
  WritelnLog('QuakeNet', 'Client %d (%s) left', [C, ClientAddress(C)]);
  FClients[C].Active := False;
  FClients[C].Reliable.Clear;
  if Assigned(OnDisconnect) then
    OnDisconnect(C);
end;

procedure TQuakeNetServer.Update(const SecondsPassed: Single);
var
  Addr: TInetSockAddr;
  Data, P: TNetBytes;
  C, I, E: Integer;
begin
  if not FSocket.Valid then
    Exit;
  for C := 1 to MaxNetClients do
    if FClients[C].Active then
    begin
      FClients[C].SinceSeen := FClients[C].SinceSeen + SecondsPassed;
      if FClients[C].SinceSeen > NetTimeout then
      begin
        DropClient(C, True);
        Continue;
      end;
      if FClients[C].InFlight then
      begin
        FClients[C].ResendTimer := FClients[C].ResendTimer + SecondsPassed;
        if FClients[C].ResendTimer > 0.3 then
          SendReliableChunk(C);
      end;
    end;

  while FSocket.Receive(Addr, Data) do
  begin
    if Length(Data) < 3 then
      Continue;
    C := FindClient(Addr);
    case Data[0] of
      pkConnect:
        begin
          if C = 0 then
          begin
            if PacketSeq(Data) <> NetProtocolVersion then
            begin
              P := PacketHeader(pkRefuse, 0, 0);
              FSocket.Send(Addr, P);
              Continue;
            end;
            for I := 1 to MaxNetClients do
              if not FClients[I].Active then
              begin
                C := I;
                Break;
              end;
            if C = 0 then
            begin
              P := PacketHeader(pkRefuse, 0, 0);
              FSocket.Send(Addr, P);
              Continue;
            end;
            E := 0;
            if Assigned(OnConnect) then
              E := OnConnect(C);
            if E <= 0 then
            begin
              P := PacketHeader(pkRefuse, 0, 0);
              FSocket.Send(Addr, P);
              Continue;
            end;
            FClients[C].Active := True;
            FClients[C].Addr := Addr;
            FClients[C].Edict := E;
            FClients[C].SinceSeen := 0;
            FClients[C].Reliable.Clear;
            FClients[C].ReliableSeq := 0;
            FClients[C].InFlight := False;
            FClients[C].FrameSeq := 0;
            FClients[C].HasInput := False;
            FClients[C].SignonDone := False;
            WritelnLog('QuakeNet', 'Client %d connected from %s (edict %d)', [C, ClientAddress(C), E]);
            QueueSignon(C);
          end;
          { Accept (again, if the first answer was lost) }
          P := PacketHeader(pkAccept, 0, 0);
          SendPacket(C, P);
          if not FClients[C].InFlight then
            SendReliableChunk(C);
        end;
      pkAck:
        if (C > 0) and FClients[C].InFlight and (PacketSeq(Data) = FClients[C].ReliableSeq) then
        begin
          FClients[C].SinceSeen := 0;
          FClients[C].Reliable.Delete(0);
          Inc(FClients[C].ReliableSeq);
          FClients[C].InFlight := False;
          if FClients[C].Reliable.Count > 0 then
            SendReliableChunk(C)
          else
            FClients[C].SignonDone := True;
        end;
      pkInput:
        if (C > 0) and (Length(Data) >= 3 + SizeOf(TNetInput)) then
        begin
          FClients[C].SinceSeen := 0;
          Move(Data[3], FClients[C].Input, SizeOf(TNetInput));
          FClients[C].HasInput := True;
        end;
      pkDisconnect:
        if C > 0 then
          DropClient(C, False);
    end;
  end;
end;

procedure TQuakeNetServer.SendFrame(const C: Integer; const Data: TNetBytes);
var
  P: TNetBytes;
begin
  if not FClients[C].Active or not FClients[C].SignonDone or (Length(Data) = 0) then
    Exit;
  Inc(FClients[C].FrameSeq);
  P := PacketHeader(pkFrame, FClients[C].FrameSeq, Length(Data));
  Move(Data[0], P[3], Length(Data));
  SendPacket(C, P);
end;

procedure TQuakeNetServer.SendReliable(const C: Integer; const Data: TNetBytes);
begin
  if not FClients[C].Active or (Length(Data) = 0) then
    Exit;
  FClients[C].Reliable.Add(Data);
  if not FClients[C].InFlight then
    SendReliableChunk(C);
end;

procedure TQuakeNetServer.QueueSignon(const C: Integer);
var
  Msg: TQuakeNetMessage;
  Chunks: specialize TList<TNetBytes>;
  I: Integer;
begin
  { The signon, reliably; the frames wait for its last ack }
  FClients[C].SignonDone := False;
  Msg := TQuakeNetMessage.Create;
  try
    if Assigned(OnSignon) then
      OnSignon(C, Msg);
    Chunks := Msg.Chunks(ReliableChunkSize);
    try
      for I := 0 to Chunks.Count - 1 do
        FClients[C].Reliable.Add(Chunks[I]);
    finally
      Chunks.Free;
    end;
  finally
    Msg.Free;
  end;
end;

procedure TQuakeNetServer.Resignon(const C: Integer);
begin
  if not FClients[C].Active then
    Exit;
  QueueSignon(C);
  if not FClients[C].InFlight then
    SendReliableChunk(C);
end;

procedure TQuakeNetServer.Shutdown;
var
  C: Integer;
begin
  for C := 1 to MaxNetClients do
    DropClient(C, True);
end;

function TQuakeNetServer.ClientActive(const C: Integer): Boolean;
begin
  Result := (C >= 1) and (C <= MaxNetClients) and FClients[C].Active;
end;

function TQuakeNetServer.ClientEdict(const C: Integer): Integer;
begin
  if ClientActive(C) then
    Result := FClients[C].Edict
  else
    Result := 0;
end;

function TQuakeNetServer.ClientReady(const C: Integer): Boolean;
begin
  Result := ClientActive(C) and FClients[C].SignonDone;
end;

function TQuakeNetServer.ClientInput(const C: Integer; out Input: TNetInput): Boolean;
begin
  { Each packet is handed out once: the impulse in it is not repeated }
  Result := ClientActive(C) and FClients[C].HasInput;
  if Result then
  begin
    Input := FClients[C].Input;
    FClients[C].HasInput := False;
  end else
    Input := Default(TNetInput);
end;

function TQuakeNetServer.ClientAddress(const C: Integer): String;
begin
  if ClientActive(C) then
    Result := TQuakeNetSocket.AddressToString(FClients[C].Addr)
  else
    Result := '';
end;

function TQuakeNetServer.ClientCount: Integer;
var
  C: Integer;
begin
  Result := 0;
  for C := 1 to MaxNetClients do
    if FClients[C].Active then
      Inc(Result);
end;

end.
