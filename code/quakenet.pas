{ Network play: UDP sockets, a small packet protocol (a connect handshake,
  a stop-and-wait reliable channel for the signon, unreliable server
  frames and client input, a rendezvous service for UDP hole punching)
  and a builder for the NetQuake svc messages the server streams, the
  same ones TQuakeDemoReader plays. }
unit QuakeNet;

{$mode objfpc}{$H+}

interface

{ WebAssembly (WASI) has no sockets: hosting fails there, and a client's
  socket is a WebSocket to a Castle Quake WebSocket relay (QuakeWebSocketRelay)
  carrying the same packets }
{$if defined(WASI)}
  {$define QUAKE_NO_SOCKETS}
{$endif}

uses
  SysUtils, Classes, Generics.Collections, Math,
  {$ifndef QUAKE_NO_SOCKETS}
  Sockets, ctypes, {$ifdef UNIX} BaseUnix, {$else} WinSock2, {$endif}
  {$endif}
  CastleVectors, CastleLog;

const
  DefaultNetPort = 26000;
  { The WebSocket relay's TCP port (QuakeWebSocketRelay), what the web build joins }
  DefaultWebSocketPort = 26001;
  NetProtocolVersion = 2;
  MaxNetClients = 8;
  MaxPacketSize = 8192;
  ReliableChunkSize = 1200;
  NetTimeout = 10.0;

  { Packet kinds (first byte) }
  pkConnect = 1;    { client -> server: protocol version; a payload byte 1: a spectator }
  pkAccept = 2;     { server -> client }
  pkReliable = 3;   { server -> client: seq, svc data; acked }
  pkAck = 4;        { client -> server: seq }
  pkFrame = 5;      { server -> client: seq, svc data of one frame }
  pkInput = 6;      { client -> server }
  pkDisconnect = 7; { either way }
  pkRefuse = 8;     { server -> client: text }
  { Rendezvous (hole punching): a host registers its name, a client looks
    it up and both learn each other's public address }
  pkRegister = 9;   { server -> rendezvous: name }
  pkLookup = 10;    { client -> rendezvous: name }
  pkPeer = 11;      { rendezvous -> client: the host's address (empty: unknown name) }
  pkPunch = 12;     { rendezvous -> server: a client's address }
  pkHello = 13;     { server -> client: opens the server's NAT mapping, ignored }
  { LAN discovery: anyone asks, a server answers with what it plays }
  pkInfoQuery = 14; { -> server: seq = protocol version }
  pkInfo = 15;      { server -> asker: seq = protocol version, "map<tab>title<tab>players<tab>max<tab>mode" }
  { The ports a LAN query goes to (DefaultNetPort and the next ones) }
  LanQueryPorts = 4;
  LanSearchTime = 3.0;      { how long a search waits for answers }
  LanQueryInterval = 1.0;   { the query is sent again this often while searching }

  MaxInputMsec = 250;
  { The client sends an input when this much time has passed (at most
    about 143 a second), at least QuakePhysics.MinPhysicsStep }
  MinInputMsec = 7;
  MaxQueuedInputs = 16;     { inputs kept per client until the game runs them }
  RegisterInterval = 5.0;   { keeps the NAT mapping at the rendezvous alive }
  RendezvousTimeout = 30.0; { a registration not refreshed for this long is dropped }

  { Client input buttons }
  nbFire = 1;
  nbJump = 2;
  { The first port of a loopback socket opened on port 0 }
  FirstLoopbackPort = 40000;

type
  TNetBytes = TBytes;

  {$ifdef QUAKE_NO_SOCKETS}
  { The shape of the socket address, so the rest of the unit is the same }
  TInetSockAddr = record
    sin_family: Word;
    sin_port: Word;
    sin_addr: record
      s_addr: Cardinal;
    end;
  end;
  cint = LongInt;
  {$endif}

  { One frame of a client's wishes }
  TNetInput = record
    Angles: TVector3;   { pitch, yaw, roll }
    Move: TVector3;     { forward, side, up (units per second) }
    Buttons: Byte;
    Impulse: Byte;
    { Counts the client's input packets; the server reports in each frame
      the last one it applied, for the client-side prediction }
    Sequence: Word;
    { How long this input lasted (ms, at most MaxInputMsec): the server runs
      the player for exactly that, so the client's prediction matches }
    Msec: Word;
  end;

  { A received svc block and, for a frame, the input it acknowledges }
  TNetBlock = record
    Data: TNetBytes;
    IsFrame: Boolean;
    AckedInput: Word;
  end;

  TQuakeNetSocket = class
  private
    FSock: cint;
    FWeb: TObject; { TQuakeBrowserWebSocket in the web build }
    FLoop: TObject; { TLoopEndpoint of a loopback socket }
    function LoopSend(const Addr: TInetSockAddr; const Data: TNetBytes): Boolean;
    function LoopReceive(out Addr: TInetSockAddr; out Data: TNetBytes): Boolean;
  public
    { A UDP socket on Port (0: any), or a loopback one with NetLoopback
      (always in the web build, which has no UDP) }
    constructor Create(const Port: Word);
    { An in-process socket: its packets go to the loopback socket of the
      port they are sent to (address 127.0.0.1), nothing leaves the
      process; Port 0 takes a free one }
    constructor CreateLoopback(const Port: Word);
    { A loopback socket listens on Port (a listen server of this process) }
    class function LoopbackListening(const Port: Word): Boolean;
    class function LoopbackAddress(const Port: Word): TInetSockAddr;
    class function IsLoopbackAddress(const A: TInetSockAddr; out Port: Word): Boolean;
    { The web build's socket: a WebSocket to the relay at Url; every packet
      goes there, whatever address Send is given }
    constructor CreateWebSocket(const Url: String);
    destructor Destroy; override;
    function Valid: Boolean;
    function Send(const Addr: TInetSockAddr; const Data: TNetBytes): Boolean;
    { Non-blocking; False when nothing arrived }
    function Receive(out Addr: TInetSockAddr; out Data: TNetBytes): Boolean;
    class function Resolve(const Host: String; const Port: Word; out Addr: TInetSockAddr): Boolean;
    class function SameAddress(const A, B: TInetSockAddr): Boolean;
    class function AddressToString(const A: TInetSockAddr): String;
    { Allow sending to a broadcast address (UDP only) }
    function EnableBroadcast: Boolean;
    function IsLoopback: Boolean;
  end;

  { The fields of an entity update (entity_state_t) }
  TNetEntityState = record
    ModelIndex, Frame, Skin, Effects: Integer;
    Origin, Angles: TVector3;
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
    { FitzQuake's svc_fog (density and color 0..1) and svc_skybox: protocol 666 }
    procedure Fog(const Density: Single; const Color: TVector3);
    procedure Skybox(const Name: String);
    procedure SpawnStatic(const ModelIndex, Frame, Skin: Integer; const Origin, Angles: TVector3);
    procedure UpdateStat(const Stat: Integer; const Value: LongInt);
    procedure SetAngle(const Angles: TVector3);
    procedure UpdateFrags(const Client, Frags: Integer);
    procedure UpdateName(const Client: Integer; const Name: String);
    { Every field is sent: the client has no baselines }
    { An entity update with only the fields that differ from its baseline
      (SV_WriteEntitiesToClient); the client takes the rest from it }
    procedure Entity(const Num: Integer; const State, Baseline: TNetEntityState);
    { svc_spawnbaseline (svc_spawnbaseline2 in FitzQuake for numbers above 255) }
    procedure SpawnBaseline(const Num: Integer; const Baseline: TNetEntityState);
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

  TNetClientState = (csDisconnected, csResolving, csConnecting, csConnected);

  { The client side of a connection }
  TQuakeNetClient = class
  private
    FSocket: TQuakeNetSocket;
    FServer: TInetSockAddr;
    FState: TNetClientState;
    FTimer, FSinceReceive: Single;
    FWebSocketUrl: String; { web build: the relay the socket connects to }
    FExpectedSeq: Word;
    FLastFrameSeq: Word;
    FHasFrame: Boolean;
    FBlocks: specialize TQueue<TNetBlock>;
    FError: String;
    FRendezvous: TInetSockAddr;
    FPeerName: String;
    FAckedInput: Word;
    FHasAckedInput: Boolean;
    FFramesReceived: Cardinal;
    procedure SendPacket(const Data: TNetBytes);
    function OpenSocket: Boolean;
  public
    { Join as a spectator (set before Connect) }
    Spectator: Boolean;
    constructor Create;
    destructor Destroy; override;
    function Connect(const Host: String; const Port: Word): Boolean;
    { Connect to the host registered as Name at a rendezvous service: the
      service answers with the host's public address and tells the host to
      punch a hole towards this client }
    function ConnectVia(const RendezvousHost: String; const RendezvousPort: Word; const Name: String): Boolean;
    procedure Disconnect;
    procedure Update(const SecondsPassed: Single);
    procedure SendInput(const Input: TNetInput);
    { The next received svc block (reliable data and frames, in order) }
    function PollBlock(out Data: TNetBytes): Boolean;
    property State: TNetClientState read FState;
    property Error: String read FError;
    { The input sequence the server had applied in the last frame block
      PollBlock returned (HasAckedInput once a frame arrived) }
    property AckedInput: Word read FAckedInput;
    property HasAckedInput: Boolean read FHasAckedInput;
    { Frame blocks returned by PollBlock so far }
    property FramesReceived: Cardinal read FFramesReceived;
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
    Inputs: specialize TList<TNetInput>; { received, not yet handed out }
    AckedSeq: Word;                      { the last input handed out }
    SignonDone: Boolean;
    { A spectator: no player of its own, Edict is the player it follows }
    Spectator: Boolean;
  end;

  TNetConnectEvent = function(const Client: Integer): Integer of object; { returns the edict, 0 to refuse }
  { What a server tells a LAN query: "map<tab>title<tab>players<tab>max<tab>mode" }
  TNetInfoEvent = function: String of object;
  TNetClientEvent = procedure(const Client: Integer) of object;
  TNetSignonEvent = procedure(const Client: Integer; const Msg: TQuakeNetMessage) of object;

  { The server side: accepts clients, delivers their input, sends the
    signon reliably and the frames unreliably }
  TQuakeNetServer = class
  private
    FSocket: TQuakeNetSocket;
    FClients: array[1..MaxNetClients] of TNetServerClient;
    FRendezvous: TInetSockAddr;
    FRegisterName: String;
    FRegisterTimer: Single;
    function FindClient(const Addr: TInetSockAddr): Integer;
    procedure SendRegister;
    procedure SendPacket(const C: Integer; const Data: TNetBytes);
    procedure SendReliableChunk(const C: Integer);
    procedure DropClient(const C: Integer; const Notify: Boolean);
    procedure QueueSignon(const C: Integer);
  public
    OnConnect: TNetConnectEvent;
    OnDisconnect: TNetClientEvent;
    OnSignon: TNetSignonEvent;
    OnInfo: TNetInfoEvent;

    constructor Create(const Port: Word);
    destructor Destroy; override;
    function Valid: Boolean;
    procedure Update(const SecondsPassed: Single);
    procedure SendFrame(const C: Integer; const Data: TNetBytes);
    { Reliable data to one client (a late centerprint, a level change) }
    procedure SendReliable(const C: Integer; const Data: TNetBytes);
    { Send the signon again (a new level): frames wait until it is acked }
    procedure Resignon(const C: Integer);
    { Register this server as Name at a rendezvous service (every
      RegisterInterval seconds), so clients behind NATs can ConnectVia it }
    function RegisterAt(const Host: String; const Port: Word; const Name: String): Boolean;
    procedure Shutdown;
    function ClientActive(const C: Integer): Boolean;
    function ClientEdict(const C: Integer): Integer;
    function ClientReady(const C: Integer): Boolean; { signon delivered }
    { The next input of the client not yet handed out (oldest first), in
      the order they were sent; False when there is none }
    function ClientInput(const C: Integer; out Input: TNetInput): Boolean;
    function ClientAddress(const C: Integer): String;
    function ClientCount: Integer;
    { A spectator (set when it connects, so OnConnect can ask) and the
      player it follows }
    function ClientSpectator(const C: Integer): Boolean;
    procedure SetClientEdict(const C, E: Integer);
  end;

  TRendezvousEntry = record
    Name: String;
    Addr: TInetSockAddr;
    Age: Single;
  end;

  { The rendezvous service: remembers where the registered hosts are
    reachable (their public address as seen from here) and, on a lookup,
    gives the client that address and the host the client's, so both
    NATs open (UDP hole punching). Run it on a machine both can reach. }
  TQuakeNetRendezvous = class
  private
    FSocket: TQuakeNetSocket;
    FEntries: array of TRendezvousEntry;
    function Find(const Name: String): Integer;
  public
    constructor Create(const Port: Word);
    destructor Destroy; override;
    function Valid: Boolean;
    procedure Update(const SecondsPassed: Single);
    function Count: Integer;
  end;

  { A game a LAN search found }
  TLanGame = record
    Address: String;   { host:port to connect to }
    Host: String;
    Port: Word;
    Map, Title, Mode: String;
    Players, MaxPlayers: Integer;
  end;

  { LAN discovery: sends pkInfoQuery to the broadcast address and this
    machine on the ports DefaultNetPort.. + LanQueryPorts - 1 (the listen
    servers of this process over loopback sockets in the web build) and
    collects the answers for LanSearchTime seconds }
  TQuakeLanDiscovery = class
  private
    FSocket: TQuakeNetSocket;
    FGames: array of TLanGame;
    FElapsed, FSinceQuery: Single;
    FSearching: Boolean;
    procedure SendQueries;
    function GetGame(const I: Integer): TLanGame;
  public
    destructor Destroy; override;
    { Forget what was found and search again }
    procedure Start;
    procedure Update(const SecondsPassed: Single);
    function Count: Integer;
    { One line: "host:port: map (title), players/max, mode" }
    function Describe(const I: Integer): String;
    property Games[const I: Integer]: TLanGame read GetGame; default;
    property Searching: Boolean read FSearching;
  end;

{ The LAN search of the menus and the console (created when first asked for) }
function LanDiscovery: TQuakeLanDiscovery;
function LanDiscoveryCreated: Boolean;

{ 6 bytes: the address and port as they are in the socket address }
function AddressToBytes(const A: TInetSockAddr): TNetBytes;
function BytesToAddress(const B: TNetBytes; const Offset: Integer; out A: TInetSockAddr): Boolean;
function NameBytes(const S: String): TNetBytes;
function BytesName(const B: TNetBytes; const Offset: Integer): String;


var
  { The game protocol the server's messages use: 15 (NetQuake), 666
    (FitzQuake: 16-bit model, frame and sound numbers through extension
    bits) when a level precaches more than 255 models or sounds or has a
    sky or fog, or 999 (RMQ: FitzQuake with float coordinates and 16-bit
    angles) when the map reaches beyond 16-bit coordinates.
    Set by TQuakeServer for each level. }
  NetGameProtocol: Integer = 15;
  { -protocol 666 / 999: the server uses at least that protocol }
  NetForceProtocol: Integer = 0;

const
  { The protocol flags sent with 999 (QuakeSpasm's default):
    PRFL_SHORTANGLE or PRFL_FLOATCOORD }
  NetRMQProtocolFlags = (1 shl 1) or (1 shl 4);

var
  { Sockets are in-process loopback ones (-netloopback; always in the web
    build): a listen server and the clients of this process only }
  NetLoopback: Boolean {$ifdef QUAKE_NO_SOCKETS} = True {$endif};

implementation

uses
  QuakeWebSocketClient;

{ Loopback sockets }

type
  TLoopPacket = record
    FromPort: Word;
    Data: TNetBytes;
  end;
  TLoopEndpoint = class
    Port: Word;
    Queue: specialize TQueue<TLoopPacket>;
    constructor Create(const APort: Word);
    destructor Destroy; override;
  end;
  TLoopEndpointList = specialize TList<TLoopEndpoint>;

var
  LoopEndpoints: TLoopEndpointList;

constructor TLoopEndpoint.Create(const APort: Word);
begin
  inherited Create;
  Port := APort;
  Queue := specialize TQueue<TLoopPacket>.Create;
end;

destructor TLoopEndpoint.Destroy;
begin
  Queue.Free;
  inherited Destroy;
end;

function FindLoopEndpoint(const Port: Word): TLoopEndpoint;
var
  E: TLoopEndpoint;
begin
  Result := nil;
  if LoopEndpoints <> nil then
    for E in LoopEndpoints do
      if E.Port = Port then
        Exit(E);
end;

{ The port of an address as a number, and back (network byte order with
  real sockets, as is in the web build's stand-in record) }
function PortOfAddress(const A: TInetSockAddr): Word;
begin
  {$ifdef QUAKE_NO_SOCKETS}
  Result := A.sin_port;
  {$else}
  Result := ntohs(A.sin_port);
  {$endif}
end;

function LoopHost: Cardinal;
begin
  {$ifdef QUAKE_NO_SOCKETS}
  Result := $7F000001;
  {$else}
  Result := htonl($7F000001);
  {$endif}
end;

class function TQuakeNetSocket.LoopbackAddress(const Port: Word): TInetSockAddr;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.sin_family := 2; { AF_INET }
  {$ifdef QUAKE_NO_SOCKETS}
  Result.sin_port := Port;
  {$else}
  Result.sin_port := htons(Port);
  {$endif}
  Result.sin_addr.s_addr := LoopHost;
end;

class function TQuakeNetSocket.IsLoopbackAddress(const A: TInetSockAddr; out Port: Word): Boolean;
begin
  Port := PortOfAddress(A);
  Result := A.sin_addr.s_addr = LoopHost;
end;

class function TQuakeNetSocket.LoopbackListening(const Port: Word): Boolean;
begin
  Result := FindLoopEndpoint(Port) <> nil;
end;

constructor TQuakeNetSocket.CreateLoopback(const Port: Word);
var
  P: Word;
begin
  inherited Create;
  FSock := -1;
  if LoopEndpoints = nil then
    LoopEndpoints := TLoopEndpointList.Create;
  P := Port;
  if P = 0 then
  begin
    P := FirstLoopbackPort;
    while FindLoopEndpoint(P) <> nil do
      Inc(P);
  end else
  if FindLoopEndpoint(P) <> nil then
  begin
    WritelnWarning('QuakeNet', 'Loopback port %d is in use', [P]);
    Exit;
  end;
  FLoop := TLoopEndpoint.Create(P);
  LoopEndpoints.Add(TLoopEndpoint(FLoop));
  WritelnLog('QuakeNet', 'Loopback socket on port %d', [P]);
end;

function TQuakeNetSocket.LoopSend(const Addr: TInetSockAddr; const Data: TNetBytes): Boolean;
var
  Target: TLoopEndpoint;
  Packet: TLoopPacket;
  Port: Word;
begin
  Result := False;
  if not IsLoopbackAddress(Addr, Port) or (Length(Data) = 0) then
    Exit;
  Target := FindLoopEndpoint(Port);
  if Target = nil then
    Exit;
  Packet.FromPort := TLoopEndpoint(FLoop).Port;
  Packet.Data := Copy(Data);
  Target.Queue.Enqueue(Packet);
  Result := True;
end;

function TQuakeNetSocket.LoopReceive(out Addr: TInetSockAddr; out Data: TNetBytes): Boolean;
var
  Packet: TLoopPacket;
begin
  SetLength(Data, 0);
  FillChar(Addr, SizeOf(Addr), 0);
  Result := TLoopEndpoint(FLoop).Queue.Count > 0;
  if not Result then
    Exit;
  Packet := TLoopEndpoint(FLoop).Queue.Dequeue;
  Addr := LoopbackAddress(Packet.FromPort);
  Data := Packet.Data;
end;

procedure FreeLoop(var Loop: TObject);
begin
  if Loop = nil then
    Exit;
  { At program exit the list may be gone before the last sockets }
  if LoopEndpoints <> nil then
    LoopEndpoints.Remove(TLoopEndpoint(Loop));
  FreeAndNil(Loop);
end;

{ TQuakeNetSocket }

constructor TQuakeNetSocket.CreateWebSocket(const Url: String);
begin
  inherited Create;
  FSock := -1;
  FWeb := TQuakeBrowserWebSocket.Create(Url);
end;

{$ifdef QUAKE_NO_SOCKETS}

constructor TQuakeNetSocket.Create(const Port: Word);
begin
  { No UDP here: a listen server (and its local clients) talk in-process }
  CreateLoopback(Port);
end;

destructor TQuakeNetSocket.Destroy;
begin
  FreeAndNil(FWeb);
  FreeLoop(FLoop);
  inherited Destroy;
end;

function TQuakeNetSocket.Valid: Boolean;
begin
  if FLoop <> nil then
    Exit(True);
  { A WebSocket counts while it is connecting or open }
  Result := (FWeb <> nil) and (TQuakeBrowserWebSocket(FWeb).State <= 1);
end;

function TQuakeNetSocket.Send(const Addr: TInetSockAddr; const Data: TNetBytes): Boolean;
begin
  if FLoop <> nil then
    Exit(LoopSend(Addr, Data));
  Result := (FWeb <> nil) and TQuakeBrowserWebSocket(FWeb).Send(Data);
end;

function TQuakeNetSocket.Receive(out Addr: TInetSockAddr; out Data: TNetBytes): Boolean;
begin
  if FLoop <> nil then
    Exit(LoopReceive(Addr, Data));
  { Everything on the WebSocket comes from the one server (address zero) }
  FillChar(Addr, SizeOf(Addr), 0);
  SetLength(Data, 0);
  Result := (FWeb <> nil) and TQuakeBrowserWebSocket(FWeb).Receive(Data);
end;

function TQuakeNetSocket.EnableBroadcast: Boolean;
begin
  Result := False;
end;

function TQuakeNetSocket.IsLoopback: Boolean;
begin
  Result := FLoop <> nil;
end;

class function TQuakeNetSocket.Resolve(const Host: String; const Port: Word; out Addr: TInetSockAddr): Boolean;
begin
  { This machine: a loopback listen server of the page. Elsewhere the
    relay knows the server: the client only needs a stand-in address, the
    same one Receive reports }
  if (Trim(Host) = '') or SameText(Trim(Host), 'localhost') or (Trim(Host) = '127.0.0.1') then
    Addr := LoopbackAddress(Port)
  else
    FillChar(Addr, SizeOf(Addr), 0);
  Result := Host <> '';
end;

class function TQuakeNetSocket.SameAddress(const A, B: TInetSockAddr): Boolean;
begin
  Result := (A.sin_addr.s_addr = B.sin_addr.s_addr) and (A.sin_port = B.sin_port);
end;

class function TQuakeNetSocket.AddressToString(const A: TInetSockAddr): String;
var
  Port: Word;
begin
  if IsLoopbackAddress(A, Port) then
    Result := Format('127.0.0.1:%d', [Port])
  else
    Result := 'the server (through the WebSocket relay)';
end;

{$else}

constructor TQuakeNetSocket.Create(const Port: Word);
var
  Addr: TInetSockAddr;
  {$ifndef UNIX} NonBlocking: u_long; {$endif}
begin
  if NetLoopback then
  begin
    CreateLoopback(Port);
    Exit;
  end;
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
  FreeAndNil(FWeb);
  FreeLoop(FLoop);
  inherited Destroy;
end;

function TQuakeNetSocket.Valid: Boolean;
begin
  Result := (FSock >= 0) or (FLoop <> nil);
end;

function TQuakeNetSocket.Send(const Addr: TInetSockAddr; const Data: TNetBytes): Boolean;
begin
  if FLoop <> nil then
    Exit(LoopSend(Addr, Data));
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
  if FLoop <> nil then
    Exit(LoopReceive(Addr, Data));
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

function TQuakeNetSocket.EnableBroadcast: Boolean;
var
  One: cint;
begin
  Result := False;
  if (FLoop <> nil) or (FSock < 0) then
    Exit;
  One := 1;
  Result := fpsetsockopt(FSock, SOL_SOCKET, SO_BROADCAST, @One, SizeOf(One)) = 0;
end;

function TQuakeNetSocket.IsLoopback: Boolean;
begin
  Result := FLoop <> nil;
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

{$endif}

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
  { Protocol 999: float coordinates (PRFL_FLOATCOORD) }
  if NetGameProtocol = 999 then
    WriteFloat(V)
  else
    WriteShort(Round(V * 8));
end;

procedure TQuakeNetMessage.WriteAngle(const V: Single);
begin
  { Protocol 999: 16-bit angles (PRFL_SHORTANGLE) }
  if NetGameProtocol = 999 then
    WriteShort(SmallInt(Round(V * 65536 / 360) and $FFFF))
  else
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
  WriteLong(NetGameProtocol);
  if NetGameProtocol = 999 then
    WriteLong(NetRMQProtocolFlags);
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

procedure TQuakeNetMessage.Fog(const Density: Single; const Color: TVector3);
begin
  BeginMessage;
  WriteByte(41); { svc_fog }
  WriteByte(EnsureRange(Round(Density * 255), 0, 255));
  WriteByte(EnsureRange(Round(Color.X * 255), 0, 255));
  WriteByte(EnsureRange(Round(Color.Y * 255), 0, 255));
  WriteByte(EnsureRange(Round(Color.Z * 255), 0, 255));
  WriteShort(0); { fade time }
end;

procedure TQuakeNetMessage.Skybox(const Name: String);
begin
  BeginMessage;
  WriteByte(37); { svc_skybox }
  WriteString(Name);
end;

procedure TQuakeNetMessage.SpawnStatic(const ModelIndex, Frame, Skin: Integer; const Origin, Angles: TVector3);
begin
  BeginMessage;
  if (NetGameProtocol <> 15) and ((ModelIndex > 255) or (Frame > 255)) then
  begin
    { svc_spawnstatic2: B_LARGEMODEL, B_LARGEFRAME }
    WriteByte(43);
    WriteByte(3);
    WriteShort(ModelIndex);
    WriteShort(Frame);
  end else
  begin
    WriteByte(20);
    WriteByte(ModelIndex);
    WriteByte(Frame);
  end;
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

procedure TQuakeNetMessage.Entity(const Num: Integer; const State, Baseline: TNetEntityState);
const
  U_MOREBITS = 1; U_ORIGIN1 = 2; U_ORIGIN2 = 4; U_ORIGIN3 = 8; U_ANGLE2 = 16; U_FRAME = 64; U_SIGNAL = 128;
  U_ANGLE1 = 256; U_ANGLE3 = 512; U_MODEL = 1024; U_SKIN = 4096; U_EFFECTS = 8192; U_LONGENTITY = 16384;
  U_EXTEND1 = 1 shl 15; U_FRAME2 = 1 shl 17; U_MODEL2 = 1 shl 18;
var
  Bits: Integer;

  { The value an angle is sent as }
  function AngleByte(const A: Single): Integer;
  begin
    if NetGameProtocol = 999 then
      Result := Round(A * 65536 / 360) and $FFFF
    else
      Result := Round(A * 256 / 360) and 255;
  end;

  function SameCoord(const A, B: Single): Boolean;
  begin
    if NetGameProtocol = 999 then
      Result := A = B
    else
      Result := Round(A * 8) = Round(B * 8);
  end;

begin
  BeginMessage;
  Bits := U_SIGNAL;
  if State.ModelIndex <> Baseline.ModelIndex then
    Bits := Bits or U_MODEL;
  if State.Frame <> Baseline.Frame then
    Bits := Bits or U_FRAME;
  if State.Skin <> Baseline.Skin then
    Bits := Bits or U_SKIN;
  if State.Effects <> Baseline.Effects then
    Bits := Bits or U_EFFECTS;
  if not SameCoord(State.Origin.X, Baseline.Origin.X) then
    Bits := Bits or U_ORIGIN1;
  if not SameCoord(State.Origin.Y, Baseline.Origin.Y) then
    Bits := Bits or U_ORIGIN2;
  if not SameCoord(State.Origin.Z, Baseline.Origin.Z) then
    Bits := Bits or U_ORIGIN3;
  if AngleByte(State.Angles.X) <> AngleByte(Baseline.Angles.X) then
    Bits := Bits or U_ANGLE1;
  if AngleByte(State.Angles.Y) <> AngleByte(Baseline.Angles.Y) then
    Bits := Bits or U_ANGLE2;
  if AngleByte(State.Angles.Z) <> AngleByte(Baseline.Angles.Z) then
    Bits := Bits or U_ANGLE3;
  if Num > 255 then
    Bits := Bits or U_LONGENTITY;
  { FitzQuake: the high bytes of a model or frame above 255 }
  if NetGameProtocol <> 15 then
  begin
    if ((Bits and U_MODEL) <> 0) and (State.ModelIndex > 255) then
      Bits := Bits or U_MODEL2 or U_EXTEND1;
    if ((Bits and U_FRAME) <> 0) and (State.Frame > 255) then
      Bits := Bits or U_FRAME2 or U_EXTEND1;
  end;
  if (Bits and $FF00) <> 0 then
    Bits := Bits or U_MOREBITS;
  WriteByte(Bits and 255);
  if (Bits and U_MOREBITS) <> 0 then
    WriteByte((Bits shr 8) and 255);
  if (Bits and U_EXTEND1) <> 0 then
    WriteByte(Bits shr 16);
  if (Bits and U_LONGENTITY) <> 0 then
    WriteShort(Num)
  else
    WriteByte(Num);
  if (Bits and U_MODEL) <> 0 then
    WriteByte(State.ModelIndex);
  if (Bits and U_FRAME) <> 0 then
    WriteByte(State.Frame);
  if (Bits and U_SKIN) <> 0 then
    WriteByte(State.Skin);
  if (Bits and U_EFFECTS) <> 0 then
    WriteByte(State.Effects);
  if (Bits and U_ORIGIN1) <> 0 then
    WriteCoord(State.Origin.X);
  if (Bits and U_ANGLE1) <> 0 then
    WriteAngle(State.Angles.X);
  if (Bits and U_ORIGIN2) <> 0 then
    WriteCoord(State.Origin.Y);
  if (Bits and U_ANGLE2) <> 0 then
    WriteAngle(State.Angles.Y);
  if (Bits and U_ORIGIN3) <> 0 then
    WriteCoord(State.Origin.Z);
  if (Bits and U_ANGLE3) <> 0 then
    WriteAngle(State.Angles.Z);
  if (Bits and U_FRAME2) <> 0 then
    WriteByte(State.Frame shr 8);
  if (Bits and U_MODEL2) <> 0 then
    WriteByte(State.ModelIndex shr 8);
end;

procedure TQuakeNetMessage.SpawnBaseline(const Num: Integer; const Baseline: TNetEntityState);
begin
  BeginMessage;
  if (NetGameProtocol <> 15) and ((Baseline.ModelIndex > 255) or (Baseline.Frame > 255)) then
  begin
    WriteByte(42); { svc_spawnbaseline2: B_LARGEMODEL, B_LARGEFRAME }
    WriteShort(Num);
    WriteByte(3);
    WriteShort(Baseline.ModelIndex);
    WriteShort(Baseline.Frame);
  end else
  begin
    WriteByte(22); { svc_spawnbaseline }
    WriteShort(Num);
    WriteByte(Baseline.ModelIndex);
    WriteByte(Baseline.Frame);
  end;
  WriteByte(0); { colormap }
  WriteByte(Baseline.Skin);
  WriteCoord(Baseline.Origin.X);
  WriteAngle(Baseline.Angles.X);
  WriteCoord(Baseline.Origin.Y);
  WriteAngle(Baseline.Angles.Y);
  WriteCoord(Baseline.Origin.Z);
  WriteAngle(Baseline.Angles.Z);
end;

procedure TQuakeNetMessage.ClientData(const ViewHeight: Single; const Velocity: TVector3; const Items: Cardinal;
  const WeaponFrame, Armor, WeaponModel, Health, Ammo, Shells, Nails, Rockets, Cells, ActiveWeapon: Integer);
const
  SU_VIEWHEIGHT = 1; SU_VELOCITY1 = 32; SU_WEAPONFRAME = 4096; SU_ARMOR = 8192; SU_WEAPON = 16384;
  SU_EXTEND1 = 1 shl 15; SU_WEAPON2 = 1 shl 16; SU_WEAPONFRAME2 = 1 shl 24; SU_EXTEND2 = 1 shl 23;
var
  Bits, I: Integer;
begin
  BeginMessage;
  Bits := SU_VIEWHEIGHT or SU_VELOCITY1 or (SU_VELOCITY1 shl 1) or (SU_VELOCITY1 shl 2) or SU_WEAPONFRAME or
    SU_ARMOR or SU_WEAPON;
  { FitzQuake: the weapon model and frame above 255 }
  if NetGameProtocol <> 15 then
  begin
    if WeaponModel > 255 then
      Bits := Bits or SU_WEAPON2 or SU_EXTEND1;
    if WeaponFrame > 255 then
      Bits := Bits or SU_WEAPONFRAME2 or SU_EXTEND2 or SU_EXTEND1;
  end;
  WriteByte(15);
  WriteShort(SmallInt(Bits and $FFFF));
  if (Bits and SU_EXTEND1) <> 0 then
    WriteByte((Bits shr 16) and 255);
  if (Bits and SU_EXTEND2) <> 0 then
    WriteByte((Bits shr 24) and 255);
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
  if (Bits and SU_WEAPON2) <> 0 then
    WriteByte(WeaponModel shr 8);
  if (Bits and SU_WEAPONFRAME2) <> 0 then
    WriteByte(WeaponFrame shr 8);
end;

procedure TQuakeNetMessage.Sound(const E, Channel, SoundIdx: Integer; const Volume, Attenuation: Single;
  const Origin: TVector3);
var
  Mask: Integer;
begin
  if SoundIdx <= 0 then
    Exit;
  BeginMessage;
  { SND_VOLUME, SND_ATTENUATION, and in FitzQuake SND_LARGEENTITY /
    SND_LARGESOUND for entities from 8192 and sounds above 255 }
  Mask := 3;
  if NetGameProtocol <> 15 then
  begin
    if (E >= 8192) or (Channel > 7) then
      Mask := Mask or 8;
    if SoundIdx > 255 then
      Mask := Mask or 16;
  end;
  WriteByte(6);
  WriteByte(Mask);
  WriteByte(Round(EnsureRange(Volume, 0, 1) * 255));
  WriteByte(Round(EnsureRange(Attenuation, 0, 3.98) * 64));
  if (Mask and 8) <> 0 then
  begin
    WriteShort(SmallInt(E and $FFFF));
    WriteByte(Channel);
  end else
    WriteShort(SmallInt(((E shl 3) or (Channel and 7)) and $FFFF));
  if (Mask and 16) <> 0 then
    WriteShort(SoundIdx)
  else
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

function AddressToBytes(const A: TInetSockAddr): TNetBytes;
begin
  SetLength(Result, 6);
  Move(A.sin_addr.s_addr, Result[0], 4);
  Move(A.sin_port, Result[4], 2);
end;

function BytesToAddress(const B: TNetBytes; const Offset: Integer; out A: TInetSockAddr): Boolean;
begin
  FillChar(A, SizeOf(A), 0);
  Result := Length(B) >= Offset + 6;
  if Result then
  begin
    {$ifndef QUAKE_NO_SOCKETS}
    A.sin_family := AF_INET;
    {$endif}
    Move(B[Offset], A.sin_addr.s_addr, 4);
    Move(B[Offset + 4], A.sin_port, 2);
  end;
end;

function NameBytes(const S: String): TNetBytes;
begin
  Result := TEncoding.ASCII.GetBytes(Copy(S, 1, 64));
end;

function BytesName(const B: TNetBytes; const Offset: Integer): String;
var
  I: Integer;
begin
  Result := '';
  for I := Offset to High(B) do
    Result := Result + Chr(B[I]);
end;

{ TQuakeLanDiscovery }

var
  FLanDiscovery: TQuakeLanDiscovery;

function LanDiscovery: TQuakeLanDiscovery;
begin
  if FLanDiscovery = nil then
    FLanDiscovery := TQuakeLanDiscovery.Create;
  Result := FLanDiscovery;
end;

function LanDiscoveryCreated: Boolean;
begin
  Result := FLanDiscovery <> nil;
end;

destructor TQuakeLanDiscovery.Destroy;
begin
  FreeAndNil(FSocket);
  inherited Destroy;
end;

procedure TQuakeLanDiscovery.Start;
begin
  FGames := nil;
  FElapsed := 0;
  FSearching := True;
  if FSocket = nil then
  begin
    FSocket := TQuakeNetSocket.Create(0);
    if not FSocket.IsLoopback and not FSocket.EnableBroadcast then
      WritelnWarning('QuakeNet', 'LAN: no broadcast on this socket, only this machine is searched');
  end;
  SendQueries;
end;

procedure TQuakeLanDiscovery.SendQueries;
var
  P: TNetBytes;
  Port: Word;
  Addr: TInetSockAddr;
  I, Sent: Integer;
begin
  FSinceQuery := 0;
  if (FSocket = nil) or not FSocket.Valid then
    Exit;
  P := PacketHeader(pkInfoQuery, NetProtocolVersion, 0);
  Sent := 0;
  for I := 0 to LanQueryPorts - 1 do
  begin
    Port := DefaultNetPort + I;
    if FSocket.IsLoopback then
    begin
      { The listen servers of this process }
      if TQuakeNetSocket.LoopbackListening(Port) and FSocket.Send(TQuakeNetSocket.LoopbackAddress(Port), P) then
        Inc(Sent);
      Continue;
    end;
    if TQuakeNetSocket.Resolve('255.255.255.255', Port, Addr) and FSocket.Send(Addr, P) then
      Inc(Sent);
    if TQuakeNetSocket.Resolve('127.0.0.1', Port, Addr) and FSocket.Send(Addr, P) then
      Inc(Sent);
  end;
  WritelnLog('QuakeNet', 'LAN: query sent to %d addresses', [Sent]);
end;

procedure TQuakeLanDiscovery.Update(const SecondsPassed: Single);
var
  Addr: TInetSockAddr;
  Data: TNetBytes;
  Fields: TStringArray;
  G: TLanGame;
  I, Colon: Integer;
  Known: Boolean;
begin
  if FSocket = nil then
    Exit;
  while FSocket.Receive(Addr, Data) do
  begin
    if (Length(Data) < 3) or (Data[0] <> pkInfo) or (PacketSeq(Data) <> NetProtocolVersion) then
      Continue;
    Fields := BytesName(Data, 3).Split([#9]);
    if Length(Fields) < 5 then
      Continue;
    G := Default(TLanGame);
    G.Address := TQuakeNetSocket.AddressToString(Addr);
    Colon := LastDelimiter(':', G.Address);
    G.Host := Copy(G.Address, 1, Colon - 1);
    G.Port := StrToIntDef(Copy(G.Address, Colon + 1, MaxInt), DefaultNetPort);
    G.Map := Fields[0];
    G.Title := Fields[1];
    G.Players := StrToIntDef(Fields[2], 0);
    G.MaxPlayers := StrToIntDef(Fields[3], 0);
    G.Mode := Fields[4];
    { The same server answers the broadcast and the query to this machine:
      kept once (by its port and what it plays) }
    Known := False;
    for I := 0 to High(FGames) do
      if (FGames[I].Address = G.Address) or ((FGames[I].Port = G.Port) and (FGames[I].Map = G.Map) and
         (FGames[I].Mode = G.Mode) and (FGames[I].Title = G.Title)) then
      begin
        Known := True;
        FGames[I].Players := G.Players;
      end;
    if Known then
      Continue;
    SetLength(FGames, Length(FGames) + 1);
    FGames[High(FGames)] := G;
    WritelnLog('QuakeNet', 'LAN: found %s', [Describe(High(FGames))]);
  end;
  if not FSearching then
    Exit;
  FElapsed := FElapsed + SecondsPassed;
  FSinceQuery := FSinceQuery + SecondsPassed;
  if FElapsed >= LanSearchTime then
  begin
    FSearching := False;
    WritelnLog('QuakeNet', 'LAN: %d games found', [Length(FGames)]);
  end else
  if FSinceQuery >= LanQueryInterval then
    SendQueries;
end;

function TQuakeLanDiscovery.Count: Integer;
begin
  Result := Length(FGames);
end;

function TQuakeLanDiscovery.GetGame(const I: Integer): TLanGame;
begin
  Result := FGames[I];
end;

function TQuakeLanDiscovery.Describe(const I: Integer): String;
var
  G: TLanGame;
begin
  G := FGames[I];
  Result := G.Address + ': ' + G.Map;
  if (G.Title <> '') and (G.Title <> G.Map) then
    Result := Result + ' (' + G.Title + ')';
  Result := Result + Format(', %d/%d, %s', [G.Players, G.MaxPlayers, G.Mode]);
end;

{ TQuakeNetClient }

constructor TQuakeNetClient.Create;
begin
  inherited Create;
  FBlocks := specialize TQueue<TNetBlock>.Create;
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

function TQuakeNetClient.OpenSocket: Boolean;
var
  LoopPort: Word;
begin
  FreeAndNil(FSocket);
  { A listen server of this process on loopback: join it in-process }
  if TQuakeNetSocket.IsLoopbackAddress(FServer, LoopPort) and TQuakeNetSocket.LoopbackListening(LoopPort) then
    FSocket := TQuakeNetSocket.CreateLoopback(0)
  else
  begin
    {$ifdef QUAKE_NO_SOCKETS}
    { Everything on the WebSocket comes from the stand-in address zero }
    FillChar(FServer, SizeOf(FServer), 0);
    FSocket := TQuakeNetSocket.CreateWebSocket(FWebSocketUrl);
    {$else}
    FSocket := TQuakeNetSocket.Create(0);
    {$endif}
  end;
  Result := FSocket.Valid;
  if not Result then
    FError := 'No socket';
  FTimer := 1; { send at once }
  FSinceReceive := 0;
  FExpectedSeq := 0;
  FHasFrame := False;
  FHasAckedInput := False;
  FAckedInput := 0;
  FFramesReceived := 0;
  FBlocks.Clear;
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
  { The web build reaches the server through a WebSocket relay, on the
    WebSocket port unless one was given }
  if Port = DefaultNetPort then
    FWebSocketUrl := WebSocketUrl(Host, DefaultWebSocketPort)
  else
    FWebSocketUrl := WebSocketUrl(Host, Port);
  if not OpenSocket then
    Exit(False);
  FState := csConnecting;
  WritelnLog('QuakeNet', 'Connecting to %s', [TQuakeNetSocket.AddressToString(FServer)]);
  Result := True;
end;

function TQuakeNetClient.ConnectVia(const RendezvousHost: String; const RendezvousPort: Word;
  const Name: String): Boolean;
begin
  Disconnect;
  FError := '';
  if not TQuakeNetSocket.Resolve(RendezvousHost, RendezvousPort, FRendezvous) then
  begin
    FError := 'Bad rendezvous address ' + RendezvousHost;
    Exit(False);
  end;
  if not OpenSocket then
    Exit(False);
  FPeerName := Name;
  FState := csResolving;
  WritelnLog('QuakeNet', 'Looking up "%s" at %s', [Name, TQuakeNetSocket.AddressToString(FRendezvous)]);
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
  Block: TNetBlock;
begin
  if (FState = csDisconnected) or (FSocket = nil) then
    Exit;
  {$ifdef QUAKE_NO_SOCKETS}
  { The web build's WebSocket closed or could not open }
  if not FSocket.Valid then
  begin
    if FState = csConnected then
      FError := 'The WebSocket relay closed the connection'
    else
      FError := 'Cannot reach the WebSocket relay ' + FWebSocketUrl;
    FState := csDisconnected;
    Exit;
  end;
  {$endif}
  FTimer := FTimer + SecondsPassed;
  FSinceReceive := FSinceReceive + SecondsPassed;
  if FState = csResolving then
  begin
    if FTimer >= 0.5 then
    begin
      FTimer := 0;
      Payload := NameBytes(FPeerName);
      P := PacketHeader(pkLookup, 0, Length(Payload));
      if Length(Payload) > 0 then
        Move(Payload[0], P[3], Length(Payload));
      FSocket.Send(FRendezvous, P);
    end;
    if FSinceReceive > NetTimeout then
    begin
      FError := 'No answer from the rendezvous';
      FState := csDisconnected;
      Exit;
    end;
  end else
  if FState = csConnecting then
  begin
    if FTimer >= 0.5 then
    begin
      FTimer := 0;
      P := PacketHeader(pkConnect, NetProtocolVersion, Ord(Spectator));
      if Spectator then
        P[3] := 1;
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
    if Length(Data) < 3 then
      Continue;
    if (FState = csResolving) and TQuakeNetSocket.SameAddress(Addr, FRendezvous) then
    begin
      if Data[0] = pkPeer then
      begin
        FSinceReceive := 0;
        if BytesToAddress(Data, 3, FServer) then
        begin
          FState := csConnecting;
          FTimer := 1;
          WritelnLog('QuakeNet', '"%s" is at %s, connecting', [FPeerName, TQuakeNetSocket.AddressToString(FServer)]);
        end else
        begin
          FError := 'No host named "' + FPeerName + '" at the rendezvous';
          FState := csDisconnected;
          Exit;
        end;
      end;
      Continue;
    end;
    if (FState = csResolving) or not TQuakeNetSocket.SameAddress(Addr, FServer) then
      Continue;
    FSinceReceive := 0;
    Seq := PacketSeq(Data);
    case Data[0] of
      pkHello:
        ; { the host's hole punch }
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
            Block := Default(TNetBlock);
            SetLength(Block.Data, Length(Data) - 3);
            if Length(Block.Data) > 0 then
              Move(Data[3], Block.Data[0], Length(Block.Data));
            FBlocks.Enqueue(Block);
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
          if Length(Data) < 5 then
            Continue;
          FLastFrameSeq := Seq;
          FHasFrame := True;
          Block := Default(TNetBlock);
          Block.IsFrame := True;
          Block.AckedInput := Data[3] or (Data[4] shl 8);
          SetLength(Block.Data, Length(Data) - 5);
          if Length(Block.Data) > 0 then
            Move(Data[5], Block.Data[0], Length(Block.Data));
          FBlocks.Enqueue(Block);
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
var
  Block: TNetBlock;
begin
  Result := FBlocks.Count > 0;
  if Result then
  begin
    Block := FBlocks.Dequeue;
    Data := Block.Data;
    if Block.IsFrame then
    begin
      FAckedInput := Block.AckedInput;
      FHasAckedInput := True;
      Inc(FFramesReceived);
    end;
  end else
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
  begin
    FClients[I].Reliable := specialize TList<TNetBytes>.Create;
    FClients[I].Inputs := specialize TList<TNetInput>.Create;
  end;
  if FSocket.Valid then
    WritelnLog('QuakeNet', 'Server listening on UDP port %d', [Port]);
end;

destructor TQuakeNetServer.Destroy;
var
  I: Integer;
begin
  Shutdown;
  for I := 1 to MaxNetClients do
  begin
    FClients[I].Reliable.Free;
    FClients[I].Inputs.Free;
  end;
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
  Addr, Peer: TInetSockAddr;
  Data, P: TNetBytes;
  C, I, E: Integer;
  Input: TNetInput;
  Info: String;
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
      pkInfoQuery:
        if Assigned(OnInfo) then
        begin
          Info := OnInfo();
          P := PacketHeader(pkInfo, NetProtocolVersion, Length(Info));
          for I := 1 to Length(Info) do
            P[2 + I] := Ord(Info[I]);
          FSocket.Send(Addr, P);
        end;
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
            FClients[C].Spectator := (Length(Data) >= 4) and (Data[3] = 1);
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
            FClients[C].Inputs.Clear;
            FClients[C].AckedSeq := 0;
            FClients[C].SignonDone := False;
            if FClients[C].Spectator then
              WritelnLog('QuakeNet', 'Client %d connected from %s as a spectator, following %d',
                [C, ClientAddress(C), E])
            else
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
          Move(Data[3], Input, SizeOf(TNetInput));
          { Out of order or duplicated packets are dropped; a client that
            sends faster than the game runs loses its oldest inputs }
          if (FClients[C].Inputs.Count > 0) and
             (SmallInt(Input.Sequence - FClients[C].Inputs.Last.Sequence) <= 0) then
            Continue;
          if (FClients[C].Inputs.Count = 0) and (SmallInt(Input.Sequence - FClients[C].AckedSeq) <= 0) and
             (FClients[C].AckedSeq <> 0) then
            Continue;
          FClients[C].Inputs.Add(Input);
          while FClients[C].Inputs.Count > MaxQueuedInputs do
            FClients[C].Inputs.Delete(0);
        end;
      pkDisconnect:
        if C > 0 then
          DropClient(C, False);
      pkPunch:
        { A client behind a NAT is coming: a few packets to it open the way }
        if (FRegisterName <> '') and TQuakeNetSocket.SameAddress(Addr, FRendezvous) and
          BytesToAddress(Data, 3, Peer) then
        begin
          WritelnLog('QuakeNet', 'Punching towards %s', [TQuakeNetSocket.AddressToString(Peer)]);
          P := PacketHeader(pkHello, 0, 0);
          for I := 1 to 3 do
            FSocket.Send(Peer, P);
        end;
    end;
  end;

  if FRegisterName <> '' then
  begin
    FRegisterTimer := FRegisterTimer + SecondsPassed;
    if FRegisterTimer >= RegisterInterval then
      SendRegister;
  end;
end;

procedure TQuakeNetServer.SendRegister;
var
  P, Payload: TNetBytes;
begin
  FRegisterTimer := 0;
  Payload := NameBytes(FRegisterName);
  P := PacketHeader(pkRegister, 0, Length(Payload));
  if Length(Payload) > 0 then
    Move(Payload[0], P[3], Length(Payload));
  FSocket.Send(FRendezvous, P);
end;

function TQuakeNetServer.RegisterAt(const Host: String; const Port: Word; const Name: String): Boolean;
begin
  Result := FSocket.Valid and (Name <> '') and TQuakeNetSocket.Resolve(Host, Port, FRendezvous);
  if not Result then
  begin
    WritelnWarning('QuakeNet', 'Cannot register "%s" at %s:%d', [Name, Host, Port]);
    Exit;
  end;
  FRegisterName := Name;
  WritelnLog('QuakeNet', 'Registering as "%s" at %s', [Name, TQuakeNetSocket.AddressToString(FRendezvous)]);
  SendRegister;
end;

procedure TQuakeNetServer.SendFrame(const C: Integer; const Data: TNetBytes);
var
  P: TNetBytes;
begin
  if not FClients[C].Active or not FClients[C].SignonDone or (Length(Data) = 0) then
    Exit;
  Inc(FClients[C].FrameSeq);
  { The frame carries the sequence of the input it was computed from }
  P := PacketHeader(pkFrame, FClients[C].FrameSeq, 2 + Length(Data));
  P[3] := FClients[C].AckedSeq and 255;
  P[4] := FClients[C].AckedSeq shr 8;
  Move(Data[0], P[5], Length(Data));
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

function TQuakeNetServer.ClientSpectator(const C: Integer): Boolean;
begin
  Result := (C >= 1) and (C <= MaxNetClients) and FClients[C].Spectator;
end;

procedure TQuakeNetServer.SetClientEdict(const C, E: Integer);
begin
  if ClientActive(C) then
    FClients[C].Edict := E;
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
  Result := ClientActive(C) and (FClients[C].Inputs.Count > 0);
  if Result then
  begin
    Input := FClients[C].Inputs[0];
    FClients[C].Inputs.Delete(0);
    FClients[C].AckedSeq := Input.Sequence;
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

{ TQuakeNetRendezvous }

constructor TQuakeNetRendezvous.Create(const Port: Word);
begin
  inherited Create;
  FSocket := TQuakeNetSocket.Create(Port);
  if FSocket.Valid then
    WritelnLog('QuakeNet', 'Rendezvous listening on UDP port %d', [Port]);
end;

destructor TQuakeNetRendezvous.Destroy;
begin
  FSocket.Free;
  inherited Destroy;
end;

function TQuakeNetRendezvous.Valid: Boolean;
begin
  Result := FSocket.Valid;
end;

function TQuakeNetRendezvous.Count: Integer;
begin
  Result := Length(FEntries);
end;

function TQuakeNetRendezvous.Find(const Name: String): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FEntries) do
    if SameText(FEntries[I].Name, Name) then
      Exit(I);
  Result := -1;
end;

procedure TQuakeNetRendezvous.Update(const SecondsPassed: Single);
var
  Addr: TInetSockAddr;
  Data, P, Payload: TNetBytes;
  Name: String;
  I: Integer;
begin
  if not FSocket.Valid then
    Exit;
  I := 0;
  while I <= High(FEntries) do
  begin
    FEntries[I].Age := FEntries[I].Age + SecondsPassed;
    if FEntries[I].Age > RendezvousTimeout then
    begin
      WritelnLog('QuakeNet', 'Rendezvous: "%s" expired', [FEntries[I].Name]);
      Delete(FEntries, I, 1);
    end else
      Inc(I);
  end;

  while FSocket.Receive(Addr, Data) do
  begin
    if Length(Data) < 3 then
      Continue;
    Name := BytesName(Data, 3);
    case Data[0] of
      pkRegister:
        if Name <> '' then
        begin
          I := Find(Name);
          if I < 0 then
          begin
            SetLength(FEntries, Length(FEntries) + 1);
            I := High(FEntries);
            FEntries[I].Name := Name;
            WritelnLog('QuakeNet', 'Rendezvous: "%s" registered from %s', [Name, TQuakeNetSocket.AddressToString(Addr)]);
          end;
          FEntries[I].Addr := Addr;
          FEntries[I].Age := 0;
        end;
      pkLookup:
        begin
          I := Find(Name);
          if I >= 0 then
          begin
            { The host's address to the client, the client's to the host }
            Payload := AddressToBytes(FEntries[I].Addr);
            P := PacketHeader(pkPeer, 0, Length(Payload));
            Move(Payload[0], P[3], Length(Payload));
            FSocket.Send(Addr, P);
            Payload := AddressToBytes(Addr);
            P := PacketHeader(pkPunch, 0, Length(Payload));
            Move(Payload[0], P[3], Length(Payload));
            FSocket.Send(FEntries[I].Addr, P);
            WritelnLog('QuakeNet', 'Rendezvous: %s asked for "%s"', [TQuakeNetSocket.AddressToString(Addr), Name]);
          end else
          begin
            P := PacketHeader(pkPeer, 0, 0);
            FSocket.Send(Addr, P);
          end;
        end;
    end;
  end;
end;

finalization
  FreeAndNil(FLanDiscovery);
  FreeAndNil(LoopEndpoints);
end.
