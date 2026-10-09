{ Quake .dem files: the NetQuake network protocol (15) recorded to disk.
  A demo is a CD track line followed by blocks of "length, 3 view angles,
  server messages". TQuakeDemoReader plays them back like cl_parse.c /
  cl_main.c (server frames, entity interpolation, client data) and reports
  sounds, effects and text through events. TQuakeDemoWriter records the
  same stream from the game. Coordinates and angles are Quake's. }
unit QuakeDemo;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, Math,
  CastleVectors, CastleDownload, CastleLog,
  QuakePak;

const
  ProtocolNetQuake = 15;

  { Server to client messages }
  svc_bad = 0;
  svc_nop = 1;
  svc_disconnect = 2;
  svc_updatestat = 3;
  svc_version = 4;
  svc_setview = 5;
  svc_sound = 6;
  svc_time = 7;
  svc_print = 8;
  svc_stufftext = 9;
  svc_setangle = 10;
  svc_serverinfo = 11;
  svc_lightstyle = 12;
  svc_updatename = 13;
  svc_updatefrags = 14;
  svc_clientdata = 15;
  svc_stopsound = 16;
  svc_updatecolors = 17;
  svc_particle = 18;
  svc_damage = 19;
  svc_spawnstatic = 20;
  svc_spawnbinary = 21;
  svc_spawnbaseline = 22;
  svc_temp_entity = 23;
  svc_setpause = 24;
  svc_signonnum = 25;
  svc_centerprint = 26;
  svc_killedmonster = 27;
  svc_foundsecret = 28;
  svc_spawnstaticsound = 29;
  svc_intermission = 30;
  svc_finale = 31;
  svc_cdtrack = 32;
  svc_sellscreen = 33;
  svc_cutscene = 34;

  { Entity update bits }
  U_MOREBITS = 1;
  U_ORIGIN1 = 2;
  U_ORIGIN2 = 4;
  U_ORIGIN3 = 8;
  U_ANGLE2 = 16;
  U_NOLERP = 32;
  U_FRAME = 64;
  U_SIGNAL = 128;
  U_ANGLE1 = 256;
  U_ANGLE3 = 512;
  U_MODEL = 1024;
  U_COLORMAP = 2048;
  U_SKIN = 4096;
  U_EFFECTS = 8192;
  U_LONGENTITY = 16384;

  { Client data bits }
  SU_VIEWHEIGHT = 1;
  SU_IDEALPITCH = 2;
  SU_PUNCH1 = 4;
  SU_VELOCITY1 = 32;
  SU_ONGROUND = 1024;
  SU_INWATER = 2048;
  SU_WEAPONFRAME = 4096;
  SU_ARMOR = 8192;
  SU_WEAPON = 16384;

  SND_VOLUME = 1;
  SND_ATTENUATION = 2;

  { Temp entities }
  TE_SPIKE = 0;
  TE_SUPERSPIKE = 1;
  TE_GUNSHOT = 2;
  TE_EXPLOSION = 3;
  TE_TAREXPLOSION = 4;
  TE_LIGHTNING1 = 5;
  TE_LIGHTNING2 = 6;
  TE_WIZSPIKE = 7;
  TE_KNIGHTSPIKE = 8;
  TE_LIGHTNING3 = 9;
  TE_LAVASPLASH = 10;
  TE_TELEPORT = 11;
  TE_EXPLOSION2 = 12;
  TE_BEAM = 13;

  { Entity effects }
  EF_BRIGHTFIELD = 1;
  EF_MUZZLEFLASH = 2;
  EF_BRIGHTLIGHT = 4;
  EF_DIMLIGHT = 8;

  { Model flags (mdl header) }
  MF_ROCKET = 1;
  MF_GRENADE = 2;
  MF_GIB = 4;
  MF_ROTATE = 8;
  MF_TRACER = 16;
  MF_ZOMGIB = 32;
  MF_TRACER2 = 64;
  MF_TRACER3 = 128;

  { Items (cl.items) }
  IT_SHOTGUN = 1;
  IT_SUPER_SHOTGUN = 2;
  IT_NAILGUN = 4;
  IT_SUPER_NAILGUN = 8;
  IT_GRENADE_LAUNCHER = 16;
  IT_ROCKET_LAUNCHER = 32;
  IT_LIGHTNING = 64;
  IT_SHELLS = 256;
  IT_NAILS = 512;
  IT_ROCKETS = 1024;
  IT_CELLS = 2048;
  IT_AXE = 4096;
  IT_ARMOR1 = 8192;
  IT_ARMOR2 = 16384;
  IT_ARMOR3 = 32768;
  IT_KEY1 = 131072;
  IT_KEY2 = 262144;
  IT_SUIT = 2097152;

  { Stats }
  STAT_TOTALSECRETS = 11;
  STAT_TOTALMONSTERS = 12;
  STAT_SECRETS = 13;
  STAT_MONSTERS = 14;

  MaxDemoEntities = 1024;
  MaxLightStyles = 64;
  Signons = 4;

type
  TDemoEntityState = record
    ModelIndex, Frame, ColorMap, Skin, Effects: Integer;
    Origin, Angles: TVector3;
  end;

  TDemoEntity = record
    Baseline: TDemoEntityState;
    { [0] from the latest server frame, [1] from the one before }
    Msg: array[0..1] of TDemoEntityState;
    MsgTime: Single;
    ForceLink: Boolean;
    { The state shown now (interpolated) }
    State: TDemoEntityState;
  end;

  TDemoClientData = record
    ViewHeight: Single;
    IdealPitch: Single;
    Punch, Velocity: TVector3;
    Items: Cardinal;
    OnGround, InWater: Boolean;
    WeaponFrame, Armor, Weapon: Integer;
    Health, Ammo, Shells, Nails, Rockets, Cells, ActiveWeapon: Integer;
  end;

  TDemoSoundEvent = procedure(const Entity, Channel, SoundIndex: Integer;
    const Volume, Attenuation: Single; const Origin: TVector3) of object;
  TDemoTempEntityEvent = procedure(const Kind: Integer; const Pos, Pos2: TVector3;
    const Entity, ColorStart, ColorLength: Integer) of object;
  TDemoParticleEvent = procedure(const Org, Dir: TVector3; const Count, Color: Integer) of object;
  TDemoTextEvent = procedure(const S: String) of object;
  TDemoDamageEvent = procedure(const Armor, Blood: Integer; const From: TVector3) of object;
  TDemoLightStyleEvent = procedure(const Index: Integer; const Pattern: String) of object;
  TDemoSimpleEvent = procedure of object;

  { Plays a .dem back: call Advance every frame, then read the entities
    and view. OnServerInfo tells the owner to load Models[1]. }
  TQuakeDemoReader = class
  private
    FData: TMemoryStream;
    FMsg: PByte;
    FMsgSize, FMsgPos: Integer;
    FBadMessage: Boolean;
    FDisconnected: Boolean;
    FNetwork: Boolean;
    FNetBlocks: specialize TQueue<TBytes>;
    FNetCurrent: TBytes;
    function ReadByte: Integer;
    function ReadChar: Integer;
    function ReadShort: Integer;
    function ReadLong: LongInt;
    function ReadFloat: Single;
    function ReadString: String;
    function ReadCoord: Single;
    function ReadAngle: Single;
    function ReadVector: TVector3;
    function ReadBlock: Boolean;
    procedure ParseMessages;
    procedure ParseServerInfo;
    procedure ParseUpdate(Bits: Integer);
    procedure ParseBaseline(var State: TDemoEntityState);
    procedure ParseClientData;
    procedure ParseTempEntity;
    procedure ClearState;
    procedure LerpPoint;
    procedure RelinkEntities;
  public
    Time: Single;                       { cl.time }
    MTime: array[0..1] of Single;       { cl.mtime: latest and previous server frame }
    Frac: Single;                       { position between the two server frames }
    MViewAngles: array[0..1] of TVector3;
    ViewAngles: TVector3;               { pitch (down > 0), yaw, roll }
    ViewEntity: Integer;
    Signon: Integer;
    Protocol: Integer;
    LevelName: String;
    MaxClients: Integer;
    Models, Sounds: TStringList;        { 1-based like the protocol: index 0 unused }
    Entities: array of TDemoEntity;
    Statics: array of TDemoEntityState;
    LightStyles: array[0..MaxLightStyles - 1] of String;
    Stats: array[0..31] of Integer;
    ClientData: TDemoClientData;
    Intermission: Integer;              { 1 stats, 2 finale, 3 cutscene }
    IntermissionTime: Single;
    Finished: Boolean;
    LevelStartTime: Single;
    { Network: the scoreboard (svc_updatefrags, svc_updatename) }
    Frags: array[0..15] of Integer;
    Names: array[0..15] of String;
    FragsChanged: Boolean;
    { Network: the server set the view angles (svc_setangle); the owner
      takes ViewAngles and clears this }
    AngleFixed: Boolean;

    OnServerInfo: TDemoSimpleEvent;
    OnSound: TDemoSoundEvent;
    OnTempEntity: TDemoTempEntityEvent;
    OnParticle: TDemoParticleEvent;
    OnPrint, OnCenterPrint, OnFinale: TDemoTextEvent;
    OnDamage: TDemoDamageEvent;
    OnLightStyle: TDemoLightStyleEvent;
    OnIntermission: TDemoSimpleEvent;

    constructor Create;
    destructor Destroy; override;

    { A demo from the PAKs ('demo1.dem') or any URL }
    function Load(const NameOrUrl: String): Boolean;

    { Network client: the blocks come from PushBlock instead of a file,
      nothing is finished until the server disconnects, and the view
      angles are the owner's }
    procedure StartNetwork;
    procedure PushBlock(const Data: TBytes);
    property Network: Boolean read FNetwork;

    { CL_ReadFromServer: read the messages that are due and interpolate }
    procedure Advance(const SecondsPassed: Single);

    { Entity shown this frame (has a model and was in the latest server frame) }
    function EntityVisible(const Num: Integer): Boolean;
    function ModelName(const Index: Integer): String;
    function SoundName(const Index: Integer): String;
  end;

  { Records the game as a protocol 15 demo. Models and sounds are numbered
    on first use and the serverinfo written when the demo is saved, so
    anything can be recorded without precaching. Each level becomes its
    own serverinfo section, like a real multi-level demo. }
  TQuakeDemoWriter = class
  private
    type
      TSection = class
        MapPath, LevelName: String;
        Models, Sounds: TStringList;
        Body: TMemoryStream;
        Baselines: array of TDemoEntityState;
        HasBaseline: array of Boolean;
        StartAngles: TVector3;
        TotalMonsters, TotalSecrets: Integer;
        constructor Create;
        destructor Destroy; override;
      end;
    var
      FSections: specialize TObjectList<TSection>;
      FCur: TSection;
      FMsg: TMemoryStream;
      FInFrame: Boolean;
      FLastViewAngles: TVector3;
    procedure WriteByte(const V: Integer);
    procedure WriteChar(const V: Integer);
    procedure WriteShort(const V: Integer);
    procedure WriteLong(const V: LongInt);
    procedure WriteFloat(const V: Single);
    procedure WriteString(const S: String);
    procedure WriteCoord(const V: Single);
    procedure WriteAngle(const V: Single);
    procedure WriteVector(const V: TVector3);
    procedure WriteBlock(const Dest: TStream; const Angles: TVector3; const Msg: TMemoryStream);
  public
    constructor Create;
    destructor Destroy; override;

    { A new level: everything that follows belongs to it }
    procedure BeginLevel(const AMapPath, ALevelName: String; const ViewAngles: TVector3;
      const ATotalMonsters, ATotalSecrets: Integer);
    function Recording: Boolean;

    function ModelIndex(const Path: String): Integer;
    { Sound paths with or without the 'sound/' prefix }
    function SoundIndex(const Path: String): Integer;

    procedure BeginFrame(const ATime: Single);
    procedure EndFrame(const ViewAngles: TVector3);
    { Messages (between BeginFrame and EndFrame) }
    procedure WriteClientData(const CD: TDemoClientData);
    procedure WriteEntity(const Num: Integer; const State: TDemoEntityState);
    procedure WriteSound(const Entity, Channel, SoundIdx: Integer; const Volume, Attenuation: Single;
      const Origin: TVector3);
    procedure WritePrint(const S: String);
    procedure WriteCenterPrint(const S: String);
    procedure WriteTempEntity(const Kind: Integer; const Pos: TVector3);
    procedure WriteBeam(const Kind, Entity: Integer; const Start, Stop: TVector3);
    procedure WriteParticle(const Org, Dir: TVector3; const Count, Color: Integer);
    procedure WriteDamage(const Armor, Blood: Integer; const From: TVector3);
    procedure WriteKilledMonster;
    procedure WriteFoundSecret;
    procedure WriteIntermission;
    procedure WriteSetAngle(const Angles: TVector3);

    function SaveToUrl(const Url: String): Boolean;
  end;

{ The standard QuakeC lightstyles 0..11 (worldspawn precaches them) }
function StandardLightStyle(const Index: Integer): String;

implementation

function StandardLightStyle(const Index: Integer): String;
begin
  case Index of
    0: Result := 'm';
    1: Result := 'mmnmmommommnonmmonqnmmo';
    2: Result := 'abcdefghijklmnopqrstuvwxyzyxwvutsrqponmlkjihgfedcba';
    3: Result := 'mmmmmaaaaammmmmaaaaaabcdefgabcdefg';
    4: Result := 'mamamamamama';
    5: Result := 'jklmnopqrstuvwxyzyxwvutsrqponmlkj';
    6: Result := 'nmonqnmomnmomomno';
    7: Result := 'mmmaaaabcdefgmmmmaaaammmaamm';
    8: Result := 'mmmaaammmaaammmabcdefaaaammmmabcdefmmmaaaa';
    9: Result := 'aaaaacdefgabcdefg';
    10: Result := 'mmamammmmammamamaaamamm';
    11: Result := 'abcdefghijklmnopqrsrqponmlkjihgfedcba';
    else Result := 'm';
  end;
end;

{ TQuakeDemoReader }

constructor TQuakeDemoReader.Create;
begin
  inherited Create;
  FNetBlocks := specialize TQueue<TBytes>.Create;
  FData := TMemoryStream.Create;
  Models := TStringList.Create;
  Sounds := TStringList.Create;
  SetLength(Entities, MaxDemoEntities);
  ClearState;
end;

destructor TQuakeDemoReader.Destroy;
begin
  FNetBlocks.Free;
  FData.Free;
  Models.Free;
  Sounds.Free;
  inherited Destroy;
end;

procedure TQuakeDemoReader.ClearState;
var
  I: Integer;
begin
  { CL_ClearState }
  for I := 0 to High(Entities) do
    Entities[I] := Default(TDemoEntity);
  SetLength(Statics, 0);
  for I := 0 to High(LightStyles) do
    LightStyles[I] := '';
  FillChar(Stats, SizeOf(Stats), 0);
  ClientData := Default(TDemoClientData);
  ClientData.ViewHeight := 22;
  Models.Clear;
  Sounds.Clear;
  Models.Add('');
  Sounds.Add('');
  ViewEntity := 1;
  Signon := 0;
  Intermission := 0;
  MTime[0] := 0;
  MTime[1] := 0;
  Time := 0;
  Frac := 1;
  LevelStartTime := 0;
end;

function TQuakeDemoReader.Load(const NameOrUrl: String): Boolean;
var
  Src: TStream;
  Line: String;
  C: AnsiChar;
begin
  Result := False;
  FData.Clear;
  Finished := False;
  FDisconnected := False;
  ClearState;
  if Pak.FileExists(NameOrUrl) then
    Src := Pak.GetStream(NameOrUrl)
  else
  begin
    try
      Src := Download(NameOrUrl);
    except
      on E: Exception do
      begin
        WritelnWarning('QuakeDemo', 'Cannot open demo "%s": %s', [NameOrUrl, E.Message]);
        Exit;
      end;
    end;
  end;
  if Src = nil then
    Exit;
  try
    FData.CopyFrom(Src, 0);
  finally
    Src.Free;
  end;
  FData.Position := 0;

  { The CD track line ("2\n" or "-1\n") }
  Line := '';
  while FData.Position < FData.Size do
  begin
    FData.ReadBuffer(C, 1);
    if C = #10 then
      Break;
    Line := Line + C;
    if Length(Line) > 12 then
    begin
      WritelnWarning('QuakeDemo', '"%s" is not a Quake demo', [NameOrUrl]);
      Exit;
    end;
  end;
  WritelnLog('QuakeDemo', 'Playing "%s" (%d bytes, CD track %s)', [NameOrUrl, FData.Size, Line]);
  Result := True;
end;

function TQuakeDemoReader.ReadByte: Integer;
begin
  if FMsgPos >= FMsgSize then
  begin
    FBadMessage := True;
    Exit(-1);
  end;
  Result := FMsg[FMsgPos];
  Inc(FMsgPos);
end;

function TQuakeDemoReader.ReadChar: Integer;
begin
  Result := ReadByte;
  if Result > 127 then
    Result := Result - 256;
end;

function TQuakeDemoReader.ReadShort: Integer;
begin
  if FMsgPos + 2 > FMsgSize then
  begin
    FBadMessage := True;
    Exit(-1);
  end;
  Result := SmallInt(FMsg[FMsgPos] or (FMsg[FMsgPos + 1] shl 8));
  Inc(FMsgPos, 2);
end;

function TQuakeDemoReader.ReadLong: LongInt;
begin
  if FMsgPos + 4 > FMsgSize then
  begin
    FBadMessage := True;
    Exit(-1);
  end;
  Result := LongInt(FMsg[FMsgPos] or (FMsg[FMsgPos + 1] shl 8) or (FMsg[FMsgPos + 2] shl 16) or
    (FMsg[FMsgPos + 3] shl 24));
  Inc(FMsgPos, 4);
end;

function TQuakeDemoReader.ReadFloat: Single;
begin
  if FMsgPos + 4 > FMsgSize then
  begin
    FBadMessage := True;
    Exit(0);
  end;
  Move(FMsg[FMsgPos], Result, 4);
  Inc(FMsgPos, 4);
end;

function TQuakeDemoReader.ReadString: String;
var
  C: Integer;
begin
  Result := '';
  repeat
    C := ReadByte;
    if (C <= 0) then
      Break;
    Result := Result + Chr(C);
  until False;
end;

function TQuakeDemoReader.ReadCoord: Single;
begin
  Result := ReadShort / 8;
end;

function TQuakeDemoReader.ReadAngle: Single;
begin
  Result := ReadChar * (360 / 256);
end;

function TQuakeDemoReader.ReadVector: TVector3;
begin
  Result.X := ReadCoord;
  Result.Y := ReadCoord;
  Result.Z := ReadCoord;
end;

function TQuakeDemoReader.ReadBlock: Boolean;
var
  Len: LongInt;
  Angles: TVector3;
begin
  Result := False;
  if FNetwork then
  begin
    if FNetBlocks.Count = 0 then
      Exit;
    FNetCurrent := FNetBlocks.Dequeue;
    if Length(FNetCurrent) = 0 then
      Exit(ReadBlock);
    FMsg := PByte(@FNetCurrent[0]);
    FMsgSize := Length(FNetCurrent);
    FMsgPos := 0;
    Exit(True);
  end;
  if FData.Position + 16 > FData.Size then
    Exit;
  FData.ReadBuffer(Len, 4);
  FData.ReadBuffer(Angles, SizeOf(Angles));
  if (Len < 0) or (FData.Position + Len > FData.Size) then
    Exit;
  MViewAngles[1] := MViewAngles[0];
  MViewAngles[0] := Angles;
  FMsg := PByte(FData.Memory) + FData.Position;
  FMsgSize := Len;
  FMsgPos := 0;
  FData.Position := FData.Position + Len;
  Result := True;
end;

procedure TQuakeDemoReader.ParseServerInfo;
var
  S: String;
begin
  Protocol := ReadLong;
  if Protocol <> ProtocolNetQuake then
  begin
    WritelnWarning('QuakeDemo', 'Demo protocol %d is not supported (only %d)', [Protocol, ProtocolNetQuake]);
    FDisconnected := True;
    Exit;
  end;
  ClearState;
  MaxClients := ReadByte;
  ReadByte; { gametype }
  LevelName := ReadString;
  repeat
    S := ReadString;
    if S = '' then
      Break;
    Models.Add(S);
  until FBadMessage;
  repeat
    S := ReadString;
    if S = '' then
      Break;
    Sounds.Add(S);
  until FBadMessage;
  WritelnLog('QuakeDemo', 'Level "%s": %d models, %d sounds', [LevelName, Models.Count - 1, Sounds.Count - 1]);
  if Assigned(OnServerInfo) then
    OnServerInfo();
end;

procedure TQuakeDemoReader.ParseBaseline(var State: TDemoEntityState);
begin
  State.ModelIndex := ReadByte;
  State.Frame := ReadByte;
  State.ColorMap := ReadByte;
  State.Skin := ReadByte;
  State.Origin.X := ReadCoord;
  State.Angles.X := ReadAngle;
  State.Origin.Y := ReadCoord;
  State.Angles.Y := ReadAngle;
  State.Origin.Z := ReadCoord;
  State.Angles.Z := ReadAngle;
  State.Effects := 0;
end;

procedure TQuakeDemoReader.ParseUpdate(Bits: Integer);
var
  Num: Integer;
  E: ^TDemoEntity;
  ForceLink: Boolean;
  Old: TDemoEntityState;
begin
  { CL_ParseUpdate: fields not sent come from the baseline }
  if Signon = Signons - 1 then
    Signon := Signons;
  if (Bits and U_MOREBITS) <> 0 then
    Bits := Bits or (ReadByte shl 8);
  if (Bits and U_LONGENTITY) <> 0 then
    Num := ReadShort
  else
    Num := ReadByte;
  if (Num < 0) or (Num >= MaxDemoEntities) then
  begin
    FBadMessage := True;
    Exit;
  end;
  E := @Entities[Num];
  ForceLink := E^.MsgTime <> MTime[1]; { not in the previous frame: no lerp }
  E^.MsgTime := MTime[0];
  Old := E^.Msg[0];
  E^.Msg[1] := Old;

  if (Bits and U_MODEL) <> 0 then
    E^.Msg[0].ModelIndex := ReadByte
  else
    E^.Msg[0].ModelIndex := E^.Baseline.ModelIndex;
  if E^.Msg[0].ModelIndex <> Old.ModelIndex then
    ForceLink := True;
  if (Bits and U_FRAME) <> 0 then
    E^.Msg[0].Frame := ReadByte
  else
    E^.Msg[0].Frame := E^.Baseline.Frame;
  if (Bits and U_COLORMAP) <> 0 then
    E^.Msg[0].ColorMap := ReadByte
  else
    E^.Msg[0].ColorMap := E^.Baseline.ColorMap;
  if (Bits and U_SKIN) <> 0 then
    E^.Msg[0].Skin := ReadByte
  else
    E^.Msg[0].Skin := E^.Baseline.Skin;
  if (Bits and U_EFFECTS) <> 0 then
    E^.Msg[0].Effects := ReadByte
  else
    E^.Msg[0].Effects := E^.Baseline.Effects;

  if (Bits and U_ORIGIN1) <> 0 then
    E^.Msg[0].Origin.X := ReadCoord
  else
    E^.Msg[0].Origin.X := E^.Baseline.Origin.X;
  if (Bits and U_ANGLE1) <> 0 then
    E^.Msg[0].Angles.X := ReadAngle
  else
    E^.Msg[0].Angles.X := E^.Baseline.Angles.X;
  if (Bits and U_ORIGIN2) <> 0 then
    E^.Msg[0].Origin.Y := ReadCoord
  else
    E^.Msg[0].Origin.Y := E^.Baseline.Origin.Y;
  if (Bits and U_ANGLE2) <> 0 then
    E^.Msg[0].Angles.Y := ReadAngle
  else
    E^.Msg[0].Angles.Y := E^.Baseline.Angles.Y;
  if (Bits and U_ORIGIN3) <> 0 then
    E^.Msg[0].Origin.Z := ReadCoord
  else
    E^.Msg[0].Origin.Z := E^.Baseline.Origin.Z;
  if (Bits and U_ANGLE3) <> 0 then
    E^.Msg[0].Angles.Z := ReadAngle
  else
    E^.Msg[0].Angles.Z := E^.Baseline.Angles.Z;

  if (Bits and U_NOLERP) <> 0 then
    ForceLink := True;
  if ForceLink then
  begin
    E^.Msg[1] := E^.Msg[0];
    E^.State := E^.Msg[0];
    E^.ForceLink := True;
  end;
end;

procedure TQuakeDemoReader.ParseClientData;
var
  Bits, I: Integer;
begin
  Bits := ReadShort;
  if (Bits and SU_VIEWHEIGHT) <> 0 then
    ClientData.ViewHeight := ReadChar
  else
    ClientData.ViewHeight := 22;
  if (Bits and SU_IDEALPITCH) <> 0 then
    ClientData.IdealPitch := ReadChar
  else
    ClientData.IdealPitch := 0;
  for I := 0 to 2 do
  begin
    if (Bits and (SU_PUNCH1 shl I)) <> 0 then
      ClientData.Punch.Data[I] := ReadChar
    else
      ClientData.Punch.Data[I] := 0;
    if (Bits and (SU_VELOCITY1 shl I)) <> 0 then
      ClientData.Velocity.Data[I] := ReadChar * 16
    else
      ClientData.Velocity.Data[I] := 0;
  end;
  ClientData.Items := Cardinal(ReadLong);
  ClientData.OnGround := (Bits and SU_ONGROUND) <> 0;
  ClientData.InWater := (Bits and SU_INWATER) <> 0;
  if (Bits and SU_WEAPONFRAME) <> 0 then
    ClientData.WeaponFrame := ReadByte
  else
    ClientData.WeaponFrame := 0;
  if (Bits and SU_ARMOR) <> 0 then
    ClientData.Armor := ReadByte
  else
    ClientData.Armor := 0;
  if (Bits and SU_WEAPON) <> 0 then
    ClientData.Weapon := ReadByte
  else
    ClientData.Weapon := 0;
  ClientData.Health := ReadShort;
  ClientData.Ammo := ReadByte;
  ClientData.Shells := ReadByte;
  ClientData.Nails := ReadByte;
  ClientData.Rockets := ReadByte;
  ClientData.Cells := ReadByte;
  ClientData.ActiveWeapon := ReadByte;
end;

procedure TQuakeDemoReader.ParseTempEntity;
var
  Kind, Ent, ColorStart, ColorLength: Integer;
  Pos, Pos2: TVector3;
begin
  Kind := ReadByte;
  Ent := 0;
  ColorStart := 0;
  ColorLength := 0;
  Pos2 := TVector3.Zero;
  case Kind of
    TE_LIGHTNING1, TE_LIGHTNING2, TE_LIGHTNING3, TE_BEAM:
      begin
        Ent := ReadShort;
        Pos := ReadVector;
        Pos2 := ReadVector;
      end;
    TE_EXPLOSION2:
      begin
        Pos := ReadVector;
        ColorStart := ReadByte;
        ColorLength := ReadByte;
      end;
    else
      Pos := ReadVector;
  end;
  if Assigned(OnTempEntity) then
    OnTempEntity(Kind, Pos, Pos2, Ent, ColorStart, ColorLength);
end;

procedure TQuakeDemoReader.ParseMessages;
var
  Cmd, I, Channel, SoundNum, Ent, Count, Color, Armor, Blood: Integer;
  Vol, Atten: Single;
  Pos, Dir: TVector3;
  S: String;
  State: TDemoEntityState;
begin
  FBadMessage := False;
  while (FMsgPos < FMsgSize) and not FBadMessage and not FDisconnected do
  begin
    Cmd := ReadByte;
    if (Cmd and U_SIGNAL) <> 0 then
    begin
      ParseUpdate(Cmd and 127);
      Continue;
    end;
    case Cmd of
      svc_nop: ;
      svc_disconnect:
        FDisconnected := True;
      svc_updatestat:
        begin
          I := ReadByte;
          Count := ReadLong;
          if (I >= 0) and (I <= High(Stats)) then
            Stats[I] := Count;
        end;
      svc_version:
        ReadLong;
      svc_setview:
        ViewEntity := ReadShort;
      svc_sound:
        begin
          I := ReadByte;
          if (I and SND_VOLUME) <> 0 then
            Vol := ReadByte / 255
          else
            Vol := 1;
          if (I and SND_ATTENUATION) <> 0 then
            Atten := ReadByte / 64
          else
            Atten := 1;
          Channel := ReadShort;
          Ent := Channel shr 3;
          Channel := Channel and 7;
          SoundNum := ReadByte;
          Pos := ReadVector;
          if Assigned(OnSound) then
            OnSound(Ent, Channel, SoundNum, Vol, Atten, Pos);
        end;
      svc_time:
        begin
          MTime[1] := MTime[0];
          MTime[0] := ReadFloat;
        end;
      svc_print:
        begin
          S := ReadString;
          if Assigned(OnPrint) then
            OnPrint(S);
        end;
      svc_stufftext:
        ReadString;
      svc_setangle:
        begin
          ViewAngles.X := ReadAngle;
          ViewAngles.Y := ReadAngle;
          ViewAngles.Z := ReadAngle;
          MViewAngles[0] := ViewAngles;
          MViewAngles[1] := ViewAngles;
          AngleFixed := True;
        end;
      svc_serverinfo:
        ParseServerInfo;
      svc_lightstyle:
        begin
          I := ReadByte;
          S := ReadString;
          if (I >= 0) and (I < MaxLightStyles) then
          begin
            LightStyles[I] := S;
            if Assigned(OnLightStyle) then
              OnLightStyle(I, S);
          end;
        end;
      svc_updatename:
        begin
          I := ReadByte;
          S := ReadString;
          if (I >= 0) and (I <= High(Names)) then
          begin
            Names[I] := S;
            FragsChanged := True;
          end;
        end;
      svc_updatefrags:
        begin
          I := ReadByte;
          Count := ReadShort;
          if (I >= 0) and (I <= High(Frags)) and (Frags[I] <> Count) then
          begin
            Frags[I] := Count;
            FragsChanged := True;
          end;
        end;
      svc_clientdata:
        ParseClientData;
      svc_stopsound:
        ReadShort;
      svc_updatecolors:
        begin
          ReadByte;
          ReadByte;
        end;
      svc_particle:
        begin
          Pos := ReadVector;
          Dir.X := ReadChar / 16;
          Dir.Y := ReadChar / 16;
          Dir.Z := ReadChar / 16;
          Count := ReadByte;
          Color := ReadByte;
          if Assigned(OnParticle) then
            OnParticle(Pos, Dir, Count, Color);
        end;
      svc_damage:
        begin
          Armor := ReadByte;
          Blood := ReadByte;
          Pos := ReadVector;
          if Assigned(OnDamage) then
            OnDamage(Armor, Blood, Pos);
        end;
      svc_spawnstatic:
        begin
          ParseBaseline(State);
          SetLength(Statics, Length(Statics) + 1);
          Statics[High(Statics)] := State;
        end;
      svc_spawnbinary:
        begin
          WritelnWarning('QuakeDemo', 'svc_spawnbinary is not supported');
          FBadMessage := True;
        end;
      svc_spawnbaseline:
        begin
          I := ReadShort;
          ParseBaseline(State);
          if (I >= 0) and (I < MaxDemoEntities) then
            Entities[I].Baseline := State;
        end;
      svc_temp_entity:
        ParseTempEntity;
      svc_setpause:
        ReadByte;
      svc_signonnum:
        begin
          I := ReadByte;
          if I > Signon then
            Signon := I;
        end;
      svc_centerprint:
        begin
          S := ReadString;
          if Assigned(OnCenterPrint) then
            OnCenterPrint(S);
        end;
      svc_killedmonster:
        Inc(Stats[STAT_MONSTERS]);
      svc_foundsecret:
        Inc(Stats[STAT_SECRETS]);
      svc_spawnstaticsound:
        begin
          ReadVector;
          ReadByte;
          ReadByte;
          ReadByte;
        end;
      svc_intermission:
        begin
          Intermission := 1;
          IntermissionTime := Time;
          if Assigned(OnIntermission) then
            OnIntermission();
        end;
      svc_finale, svc_cutscene:
        begin
          if Cmd = svc_finale then
            Intermission := 2
          else
            Intermission := 3;
          IntermissionTime := Time;
          S := ReadString;
          if Assigned(OnFinale) then
            OnFinale(S);
        end;
      svc_cdtrack:
        begin
          ReadByte;
          ReadByte;
        end;
      svc_sellscreen: ;
      else
      begin
        WritelnWarning('QuakeDemo', 'Illegible server message %d', [Cmd]);
        FBadMessage := True;
      end;
    end;
  end;
  if FBadMessage then
  begin
    WritelnWarning('QuakeDemo', 'Bad server message, stopping the demo');
    FDisconnected := True;
  end;
end;

procedure TQuakeDemoReader.LerpPoint;
var
  F: Single;
begin
  { CL_LerpPoint: where the client time lies between the two server frames }
  F := MTime[0] - MTime[1];
  if F <= 0 then
  begin
    Time := MTime[0];
    Frac := 1;
    Exit;
  end;
  if F > 0.1 then
  begin
    { Dropped packets: do not stretch the interpolation }
    MTime[1] := MTime[0] - 0.1;
    F := 0.1;
  end;
  Frac := (Time - MTime[1]) / F;
  if Frac < 0 then
  begin
    if Frac < -0.01 then
      Time := MTime[1];
    Frac := 0;
  end else
  if Frac > 1 then
  begin
    if Frac > 1.01 then
      Time := MTime[0];
    Frac := 1;
  end;
end;

procedure TQuakeDemoReader.RelinkEntities;
var
  I, J: Integer;
  E: ^TDemoEntity;
  F, D: Single;
  Delta: TVector3;
begin
  { View angles between the two recorded frames (a network client looks
    where its owner does) }
  if not FNetwork then
  for J := 0 to 2 do
  begin
    D := MViewAngles[0].Data[J] - MViewAngles[1].Data[J];
    if D > 180 then
      D := D - 360
    else if D < -180 then
      D := D + 360;
    ViewAngles.Data[J] := MViewAngles[1].Data[J] + Frac * D;
  end;

  for I := 1 to High(Entities) do
  begin
    E := @Entities[I];
    if (E^.Msg[0].ModelIndex = 0) or (E^.MsgTime <> MTime[0]) then
      Continue;
    if E^.ForceLink then
    begin
      E^.State := E^.Msg[0];
      E^.ForceLink := False;
      Continue;
    end;
    E^.State := E^.Msg[0];
    F := Frac;
    Delta := E^.Msg[0].Origin - E^.Msg[1].Origin;
    { Teleported: no interpolation }
    if (Abs(Delta.X) > 100) or (Abs(Delta.Y) > 100) or (Abs(Delta.Z) > 100) then
      F := 1;
    E^.State.Origin := E^.Msg[1].Origin + Delta * F;
    for J := 0 to 2 do
    begin
      D := E^.Msg[0].Angles.Data[J] - E^.Msg[1].Angles.Data[J];
      if D > 180 then
        D := D - 360
      else if D < -180 then
        D := D + 360;
      E^.State.Angles.Data[J] := E^.Msg[1].Angles.Data[J] + F * D;
    end;
  end;
end;

procedure TQuakeDemoReader.StartNetwork;
var
  I: Integer;
begin
  FNetwork := True;
  FNetBlocks.Clear;
  FDisconnected := False;
  Finished := False;
  ClearState;
  for I := 0 to High(Frags) do
  begin
    Frags[I] := 0;
    Names[I] := '';
  end;
  FragsChanged := False;
  AngleFixed := False;
end;

procedure TQuakeDemoReader.PushBlock(const Data: TBytes);
begin
  FNetBlocks.Enqueue(Data);
end;

procedure TQuakeDemoReader.Advance(const SecondsPassed: Single);
begin
  if Finished then
    Exit;
  Time := Time + SecondsPassed;
  if FNetwork then
  begin
    { Everything the server sent so far }
    while ReadBlock do
    begin
      ParseMessages;
      if FDisconnected then
      begin
        Finished := True;
        Break;
      end;
    end;
    LerpPoint;
    RelinkEntities;
    Exit;
  end;
  { CL_ReadFromServer: messages are read until the next one lies in the
    future; everything is read until the connection is complete }
  while True do
  begin
    if (Signon = Signons) and (Time <= MTime[0]) then
      Break;
    if not ReadBlock then
    begin
      Finished := True;
      Break;
    end;
    ParseMessages;
    if FDisconnected then
    begin
      Finished := True;
      Break;
    end;
  end;
  LerpPoint;
  RelinkEntities;
end;

function TQuakeDemoReader.EntityVisible(const Num: Integer): Boolean;
begin
  Result := (Num > 0) and (Num < Length(Entities)) and (Entities[Num].Msg[0].ModelIndex > 0) and
    (Entities[Num].MsgTime = MTime[0]) and (Signon = Signons);
end;

function TQuakeDemoReader.ModelName(const Index: Integer): String;
begin
  if (Index > 0) and (Index < Models.Count) then
    Result := Models[Index]
  else
    Result := '';
end;

function TQuakeDemoReader.SoundName(const Index: Integer): String;
begin
  if (Index > 0) and (Index < Sounds.Count) then
    Result := 'sound/' + Sounds[Index]
  else
    Result := '';
end;

{ TQuakeDemoWriter.TSection }

constructor TQuakeDemoWriter.TSection.Create;
begin
  inherited Create;
  Models := TStringList.Create;
  Sounds := TStringList.Create;
  Body := TMemoryStream.Create;
  SetLength(Baselines, MaxDemoEntities);
  SetLength(HasBaseline, MaxDemoEntities);
end;

destructor TQuakeDemoWriter.TSection.Destroy;
begin
  Models.Free;
  Sounds.Free;
  Body.Free;
  inherited Destroy;
end;

{ TQuakeDemoWriter }

constructor TQuakeDemoWriter.Create;
begin
  inherited Create;
  FSections := specialize TObjectList<TSection>.Create(True);
  FMsg := TMemoryStream.Create;
end;

destructor TQuakeDemoWriter.Destroy;
begin
  FSections.Free;
  FMsg.Free;
  inherited Destroy;
end;

function TQuakeDemoWriter.Recording: Boolean;
begin
  Result := FCur <> nil;
end;

procedure TQuakeDemoWriter.BeginLevel(const AMapPath, ALevelName: String; const ViewAngles: TVector3;
  const ATotalMonsters, ATotalSecrets: Integer);
begin
  if FCur <> nil then
    EndFrame(FLastViewAngles);
  FMsg.Clear;
  FCur := TSection.Create;
  FCur.MapPath := AMapPath;
  FCur.LevelName := ALevelName;
  FCur.StartAngles := ViewAngles;
  FCur.TotalMonsters := ATotalMonsters;
  FCur.TotalSecrets := ATotalSecrets;
  FCur.Models.Add(AMapPath);
  FSections.Add(FCur);
  FLastViewAngles := ViewAngles;
end;

function TQuakeDemoWriter.ModelIndex(const Path: String): Integer;
begin
  if FCur = nil then
    Exit(0);
  Result := FCur.Models.IndexOf(Path);
  if Result < 0 then
  begin
    if FCur.Models.Count >= 255 then
      Exit(0);
    Result := FCur.Models.Add(Path);
  end;
  Inc(Result); { the protocol counts from 1 }
end;

function TQuakeDemoWriter.SoundIndex(const Path: String): Integer;
var
  P: String;
begin
  if FCur = nil then
    Exit(0);
  P := Path;
  if Copy(P, 1, 6) = 'sound/' then
    Delete(P, 1, 6);
  Result := FCur.Sounds.IndexOf(P);
  if Result < 0 then
  begin
    if FCur.Sounds.Count >= 255 then
      Exit(0);
    Result := FCur.Sounds.Add(P);
  end;
  Inc(Result);
end;

procedure TQuakeDemoWriter.WriteByte(const V: Integer);
var
  B: Byte;
begin
  B := V and 255;
  FMsg.WriteBuffer(B, 1);
end;

procedure TQuakeDemoWriter.WriteChar(const V: Integer);
begin
  WriteByte(EnsureRange(V, -128, 127) and 255);
end;

procedure TQuakeDemoWriter.WriteShort(const V: Integer);
var
  S: SmallInt;
begin
  S := EnsureRange(V, -32768, 32767);
  FMsg.WriteBuffer(S, 2);
end;

procedure TQuakeDemoWriter.WriteLong(const V: LongInt);
begin
  FMsg.WriteBuffer(V, 4);
end;

procedure TQuakeDemoWriter.WriteFloat(const V: Single);
begin
  FMsg.WriteBuffer(V, 4);
end;

procedure TQuakeDemoWriter.WriteString(const S: String);
var
  Z: Byte;
begin
  if S <> '' then
    FMsg.WriteBuffer(S[1], Length(S));
  Z := 0;
  FMsg.WriteBuffer(Z, 1);
end;

procedure TQuakeDemoWriter.WriteCoord(const V: Single);
begin
  WriteShort(Round(V * 8));
end;

procedure TQuakeDemoWriter.WriteAngle(const V: Single);
begin
  WriteByte(Round(V * 256 / 360) and 255);
end;

procedure TQuakeDemoWriter.WriteVector(const V: TVector3);
begin
  WriteCoord(V.X);
  WriteCoord(V.Y);
  WriteCoord(V.Z);
end;

procedure TQuakeDemoWriter.WriteBlock(const Dest: TStream; const Angles: TVector3; const Msg: TMemoryStream);
var
  Len: LongInt;
begin
  Len := Msg.Size;
  Dest.WriteBuffer(Len, 4);
  Dest.WriteBuffer(Angles, SizeOf(Angles));
  if Len > 0 then
    Dest.WriteBuffer(Msg.Memory^, Len);
end;

procedure TQuakeDemoWriter.BeginFrame(const ATime: Single);
begin
  { Messages written since the last block (sounds, effects) stay in front
    of the server frame; the time precedes the entity updates }
  if FCur = nil then
    Exit;
  FInFrame := True;
  WriteByte(svc_time);
  WriteFloat(ATime);
end;

procedure TQuakeDemoWriter.EndFrame(const ViewAngles: TVector3);
begin
  if (FCur = nil) or (FMsg.Size = 0) then
    Exit;
  FInFrame := False;
  FLastViewAngles := ViewAngles;
  WriteBlock(FCur.Body, ViewAngles, FMsg);
  FMsg.Clear;
end;

procedure TQuakeDemoWriter.WriteClientData(const CD: TDemoClientData);
var
  Bits, I: Integer;
begin
  if FCur = nil then
    Exit;
  Bits := 0;
  if CD.ViewHeight <> 22 then
    Bits := Bits or SU_VIEWHEIGHT;
  for I := 0 to 2 do
    if CD.Velocity.Data[I] <> 0 then
      Bits := Bits or (SU_VELOCITY1 shl I);
  if CD.OnGround then
    Bits := Bits or SU_ONGROUND;
  if CD.InWater then
    Bits := Bits or SU_INWATER;
  if CD.WeaponFrame <> 0 then
    Bits := Bits or SU_WEAPONFRAME;
  if CD.Armor <> 0 then
    Bits := Bits or SU_ARMOR;
  if CD.Weapon <> 0 then
    Bits := Bits or SU_WEAPON;

  WriteByte(svc_clientdata);
  WriteShort(Bits);
  if (Bits and SU_VIEWHEIGHT) <> 0 then
    WriteChar(Round(CD.ViewHeight));
  for I := 0 to 2 do
    if (Bits and (SU_VELOCITY1 shl I)) <> 0 then
      WriteChar(Round(CD.Velocity.Data[I] / 16));
  WriteLong(LongInt(CD.Items));
  if (Bits and SU_WEAPONFRAME) <> 0 then
    WriteByte(CD.WeaponFrame);
  if (Bits and SU_ARMOR) <> 0 then
    WriteByte(CD.Armor);
  if (Bits and SU_WEAPON) <> 0 then
    WriteByte(CD.Weapon);
  WriteShort(CD.Health);
  WriteByte(CD.Ammo);
  WriteByte(CD.Shells);
  WriteByte(CD.Nails);
  WriteByte(CD.Rockets);
  WriteByte(CD.Cells);
  WriteByte(CD.ActiveWeapon);
end;

procedure TQuakeDemoWriter.WriteEntity(const Num: Integer; const State: TDemoEntityState);
var
  Bits: Integer;
  B: TDemoEntityState;

  function AngleByte(const A: Single): Integer;
  begin
    Result := Round(A * 256 / 360) and 255;
  end;

begin
  if (FCur = nil) or (Num <= 0) or (Num >= MaxDemoEntities) then
    Exit;
  { The first state of an entity becomes its baseline (written with the
    serverinfo); fields equal to the baseline are left out, as the client
    falls back to it }
  if not FCur.HasBaseline[Num] then
  begin
    FCur.Baselines[Num] := State;
    FCur.HasBaseline[Num] := True;
  end;
  B := FCur.Baselines[Num];
  Bits := U_SIGNAL;
  if State.ModelIndex <> B.ModelIndex then
    Bits := Bits or U_MODEL;
  if State.Frame <> B.Frame then
    Bits := Bits or U_FRAME;
  if State.Skin <> B.Skin then
    Bits := Bits or U_SKIN;
  if State.Effects <> B.Effects then
    Bits := Bits or U_EFFECTS;
  if Round(State.Origin.X * 8) <> Round(B.Origin.X * 8) then
    Bits := Bits or U_ORIGIN1;
  if Round(State.Origin.Y * 8) <> Round(B.Origin.Y * 8) then
    Bits := Bits or U_ORIGIN2;
  if Round(State.Origin.Z * 8) <> Round(B.Origin.Z * 8) then
    Bits := Bits or U_ORIGIN3;
  if AngleByte(State.Angles.X) <> AngleByte(B.Angles.X) then
    Bits := Bits or U_ANGLE1;
  if AngleByte(State.Angles.Y) <> AngleByte(B.Angles.Y) then
    Bits := Bits or U_ANGLE2;
  if AngleByte(State.Angles.Z) <> AngleByte(B.Angles.Z) then
    Bits := Bits or U_ANGLE3;
  if Num > 255 then
    Bits := Bits or U_LONGENTITY;
  if (Bits and $FF00) <> 0 then
    Bits := Bits or U_MOREBITS;

  WriteByte(Bits and 255);
  if (Bits and U_MOREBITS) <> 0 then
    WriteByte(Bits shr 8);
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
end;

procedure TQuakeDemoWriter.WriteSound(const Entity, Channel, SoundIdx: Integer;
  const Volume, Attenuation: Single; const Origin: TVector3);
var
  Mask: Integer;
begin
  if (FCur = nil) or (SoundIdx <= 0) then
    Exit;
  Mask := 0;
  if Volume <> 1 then
    Mask := Mask or SND_VOLUME;
  if Attenuation <> 1 then
    Mask := Mask or SND_ATTENUATION;
  WriteByte(svc_sound);
  WriteByte(Mask);
  if (Mask and SND_VOLUME) <> 0 then
    WriteByte(Round(EnsureRange(Volume, 0, 1) * 255));
  if (Mask and SND_ATTENUATION) <> 0 then
    WriteByte(Round(EnsureRange(Attenuation, 0, 3.98) * 64));
  WriteShort((Entity shl 3) or (Channel and 7));
  WriteByte(SoundIdx);
  WriteVector(Origin);
end;

procedure TQuakeDemoWriter.WritePrint(const S: String);
begin
  if FCur = nil then
    Exit;
  WriteByte(svc_print);
  WriteString(S);
end;

procedure TQuakeDemoWriter.WriteCenterPrint(const S: String);
begin
  if FCur = nil then
    Exit;
  WriteByte(svc_centerprint);
  WriteString(S);
end;

procedure TQuakeDemoWriter.WriteTempEntity(const Kind: Integer; const Pos: TVector3);
begin
  if FCur = nil then
    Exit;
  WriteByte(svc_temp_entity);
  WriteByte(Kind);
  WriteVector(Pos);
end;

procedure TQuakeDemoWriter.WriteBeam(const Kind, Entity: Integer; const Start, Stop: TVector3);
begin
  if FCur = nil then
    Exit;
  WriteByte(svc_temp_entity);
  WriteByte(Kind);
  WriteShort(Entity);
  WriteVector(Start);
  WriteVector(Stop);
end;

procedure TQuakeDemoWriter.WriteParticle(const Org, Dir: TVector3; const Count, Color: Integer);
var
  I: Integer;
begin
  if FCur = nil then
    Exit;
  WriteByte(svc_particle);
  WriteVector(Org);
  for I := 0 to 2 do
    WriteChar(Round(EnsureRange(Dir.Data[I] * 16, -128, 127)));
  WriteByte(EnsureRange(Count, 1, 255));
  WriteByte(Color);
end;

procedure TQuakeDemoWriter.WriteDamage(const Armor, Blood: Integer; const From: TVector3);
begin
  if FCur = nil then
    Exit;
  WriteByte(svc_damage);
  WriteByte(EnsureRange(Armor, 0, 255));
  WriteByte(EnsureRange(Blood, 0, 255));
  WriteVector(From);
end;

procedure TQuakeDemoWriter.WriteKilledMonster;
begin
  if FCur <> nil then
    WriteByte(svc_killedmonster);
end;

procedure TQuakeDemoWriter.WriteFoundSecret;
begin
  if FCur <> nil then
    WriteByte(svc_foundsecret);
end;

procedure TQuakeDemoWriter.WriteIntermission;
begin
  if FCur <> nil then
    WriteByte(svc_intermission);
end;

procedure TQuakeDemoWriter.WriteSetAngle(const Angles: TVector3);
begin
  if FCur = nil then
    Exit;
  WriteByte(svc_setangle);
  WriteAngle(Angles.X);
  WriteAngle(Angles.Y);
  WriteAngle(Angles.Z);
end;

function TQuakeDemoWriter.SaveToUrl(const Url: String): Boolean;
var
  Dest: TStream;
  Sec: TSection;
  I: Integer;
  Header: String;

  procedure Signon(const Num: Integer);
  begin
    WriteByte(svc_signonnum);
    WriteByte(Num);
    WriteBlock(Dest, Sec.StartAngles, FMsg);
    FMsg.Clear;
  end;

begin
  Result := False;
  if FCur <> nil then
    EndFrame(FLastViewAngles);
  try
    Dest := UrlSaveStream(Url);
  except
    on E: Exception do
    begin
      WritelnWarning('QuakeDemo', 'Cannot write demo "%s": %s', [Url, E.Message]);
      Exit;
    end;
  end;
  try
    { No CD track }
    Header := '-1' + #10;
    Dest.WriteBuffer(Header[1], Length(Header));
    for Sec in FSections do
    begin
      { Signon 1: the server info with everything the level used }
      FMsg.Clear;
      WriteByte(svc_print);
      WriteString(#2 + #10 + 'Castle Quake demo' + #10);
      WriteByte(svc_serverinfo);
      WriteLong(ProtocolNetQuake);
      WriteByte(1); { maxclients }
      WriteByte(0); { gametype }
      WriteString(Sec.LevelName);
      for I := 0 to Sec.Models.Count - 1 do
        WriteString(Sec.Models[I]);
      WriteString('');
      for I := 0 to Sec.Sounds.Count - 1 do
        WriteString(Sec.Sounds[I]);
      WriteString('');
      WriteByte(svc_setview);
      WriteShort(1);
      Signon(1);

      { Signon 2: lightstyles, baselines and level stats }
      for I := 0 to 11 do
      begin
        WriteByte(svc_lightstyle);
        WriteByte(I);
        WriteString(StandardLightStyle(I));
      end;
      for I := 1 to MaxDemoEntities - 1 do
        if Sec.HasBaseline[I] then
        begin
          WriteByte(svc_spawnbaseline);
          WriteShort(I);
          WriteByte(Sec.Baselines[I].ModelIndex);
          WriteByte(Sec.Baselines[I].Frame);
          WriteByte(Sec.Baselines[I].ColorMap);
          WriteByte(Sec.Baselines[I].Skin);
          WriteCoord(Sec.Baselines[I].Origin.X);
          WriteAngle(Sec.Baselines[I].Angles.X);
          WriteCoord(Sec.Baselines[I].Origin.Y);
          WriteAngle(Sec.Baselines[I].Angles.Y);
          WriteCoord(Sec.Baselines[I].Origin.Z);
          WriteAngle(Sec.Baselines[I].Angles.Z);
        end;
      WriteByte(svc_updatestat);
      WriteByte(STAT_TOTALSECRETS);
      WriteLong(Sec.TotalSecrets);
      WriteByte(svc_updatestat);
      WriteByte(STAT_TOTALMONSTERS);
      WriteLong(Sec.TotalMonsters);
      Signon(2);

      { Signon 3: the player's name and view }
      WriteByte(svc_updatename);
      WriteByte(0);
      WriteString('player');
      WriteByte(svc_setangle);
      WriteAngle(Sec.StartAngles.X);
      WriteAngle(Sec.StartAngles.Y);
      WriteAngle(Sec.StartAngles.Z);
      Signon(3);

      Dest.WriteBuffer(Sec.Body.Memory^, Sec.Body.Size);
    end;
    { The end }
    FMsg.Clear;
    WriteByte(svc_disconnect);
    WriteBlock(Dest, FLastViewAngles, FMsg);
    FMsg.Clear;
    Result := True;
  finally
    Dest.Free;
  end;
  WritelnLog('QuakeDemo', 'Recorded demo "%s" (%d levels)', [Url, FSections.Count]);
end;

end.
