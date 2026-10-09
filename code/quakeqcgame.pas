{ A level run by its QuakeC: the progs.dat spawns and thinks for every
  entity, this unit gives them a world (sv_phys.c and sv_move.c ports over
  the BSP hulls, pr_cmds.c world builtins) and runs the player as edict 1
  with the Quake player physics (sv_user.c), calling PlayerPreThink and
  PlayerPostThink around it. Rendering and input are the view's. Quake
  coordinates throughout. }
unit QuakeQcGame;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, Math,
  CastleVectors, CastleLog, CastleUtils,
  QuakePak, QuakeBsp, QuakePhysics, QuakeLight, QuakeParticles, QuakePalette, QuakeProgs;

const
  { entity flags }
  FL_FLY = 1;
  FL_SWIM = 2;
  FL_CLIENT = 8;
  FL_INWATER = 16;
  FL_MONSTER = 32;
  FL_GODMODE = 64;
  FL_NOTARGET = 128;
  FL_ITEM = 256;
  FL_ONGROUND = 512;
  FL_PARTIALGROUND = 1024;
  FL_WATERJUMP = 2048;
  FL_JUMPRELEASED = 4096;

  MOVETYPE_NONE = 0;
  MOVETYPE_WALK = 3;
  MOVETYPE_STEP = 4;
  MOVETYPE_FLY = 5;
  MOVETYPE_TOSS = 6;
  MOVETYPE_PUSH = 7;
  MOVETYPE_NOCLIP = 8;
  MOVETYPE_FLYMISSILE = 9;
  MOVETYPE_BOUNCE = 10;

  SOLID_NOT = 0;
  SOLID_TRIGGER = 1;
  SOLID_BBOX = 2;
  SOLID_SLIDEBOX = 3;
  SOLID_BSP = 4;

  MOVE_NORMAL = 0;
  MOVE_NOMONSTERS = 1;
  MOVE_MISSILE = 2;

  StepHeight = 18.0;

  { Client edicts 1..MaxQcClients }
  MaxQcClients = 8;

type
  { A static entity left by makestatic (torches, decorations) }
  TQcStatic = record
    Model: String;
    Origin, Angles: TVector3;
    Frame, Skin: Integer;
  end;

  { One client: a player edict with its own Quake player physics and input }
  TQcClient = record
    Active: Boolean;
    Phys: TQuakePlayerPhysics;
    Cmd: TQuakeUserCmd;
    Yaw, Pitch: Single;
    Fire: Boolean;
    Impulse: Integer;
    Name: String;
  end;

  TQcSoundEvent = procedure(const E, Channel: Integer; const Sample: String; const Volume, Attenuation: Single;
    const Origin: TVector3) of object;
  TQcTextEvent = procedure(const S: String) of object;
  { E is the client edict the text is for, 0 for everyone }
  TQcClientTextEvent = procedure(const E: Integer; const S: String) of object;
  TQcTempEntityEvent = procedure(const Kind: Integer; const Pos, Pos2: TVector3; const Entity: Integer) of object;
  TQcDamageEvent = procedure(const E, Armor, Blood: Integer) of object;
  TQcAmbientEvent = procedure(const Origin: TVector3; const Sample: String; const Volume: Single) of object;
  TQcParticleEvent = procedure(const Org, Dir: TVector3; const Color, Count: Integer) of object;
  TQcLightStyleEvent = procedure(const Style: Integer; const Value: String) of object;
  { A complete svc message the progs wrote (raw protocol bytes), for the
    client edict E (0: everyone) }
  TQcMessageEvent = procedure(const E: Integer; const Data: TBytes) of object;

  TQuakeQcGame = class(TQuakeProgsHost)
  private
    FProgs: TQuakeProgs;
    FBsp: TQuakeBsp;
    FClients: array[1..MaxQcClients] of TQcClient;
    FMaxClients: Integer;
    FDeathmatch: Integer;
    FTime: Single;
    FMapName: String;
    FSkill: Integer;
    FStatics: array of TQcStatic;
    FLevelChange: String;
    FIntermission: Boolean;
    FMessageBytes: array of Integer;  { the svc message being written by the progs }
    FMessageStrings: TStringList;
    FMessageRaw: TBytes;              { the same message as protocol bytes }
    FMessageDest: Integer;            { MSG_xxx of its first byte }
    FLightStyles: array[0..63] of String;
    { Field offsets }
    FFLTime, FFMoveType, FFSolid, FFFlags, FFGroundEntity, FFVelocity, FFAVelocity, FFAngles, FFOrigin,
    FFOldOrigin, FFMins, FFMaxs, FFAbsMin, FFAbsMax, FFTouch, FFBlocked, FFOwner, FFModelIndex, FFModel,
    FFButton0, FFButton2, FFImpulse, FFVAngle, FFFixAngle, FFViewOfs, FFHealth, FFWaterLevel, FFWaterType,
    FFTeleportTime, FFTakeDamage, FFDeadFlag, FFFrame, FFSkin, FFEffects, FFWeaponModel, FFWeaponFrame,
    FFNextThink, FFThink, FFClassName, FFGoalEntity, FFEnemy, FFIdealYaw, FFSpawnFlags, FFTarget,
    FFTargetName, FFMoveDir, FFItems, FFArmorValue, FFCurrentAmmo, FFAmmoShells, FFAmmoNails,
    FFAmmoRockets, FFAmmoCells, FFWeapon, FFView_Ofs, FFNetName, FFColorMap, FFDmgTake, FFFrags: Integer;
    { Function indexes }
    FFnStartFrame, FFnPlayerPreThink, FFnPlayerPostThink, FFnClientConnect, FFnPutClientInServer,
    FFnSetNewParms, FFnSetChangeParms, FFnClientKill, FFnClientDisconnect: Integer;
    procedure CacheOffsets;
    procedure LinkEdict(const E: Integer);
    function EntityBox(const E: Integer; out AMins, AMaxs: TVector3): Boolean;
    { SV_Move: a box from Start to Stop against the world, pushers, solid
      entities and the player (Kind = MOVE_xxx) }
    function TraceBox(const Start, Stop, Mins, Maxs: TVector3; const Kind, Ignore: Integer): TQuakeTrace;
    function PointTrace(const Start, Stop: TVector3; const Ignore: Integer): TQuakeTrace;
    procedure RefreshPlayerColliders(const Client: Integer);
    function IsClient(const E: Integer): Boolean;
    function MessageTarget: Integer;
    procedure ConnectClientNow(const E: Integer);
    procedure MoveClient(const E: Integer; const Dt: Single);
    function RunThink(const E: Integer): Boolean;
    procedure Impact(const E1, E2: Integer);
    procedure CallTouch(const E, Other: Integer);
    function PushEntity(const E: Integer; const Push: TVector3): TQuakeTrace;
    procedure PhysicsPusher(const E: Integer; const Dt: Single);
    procedure PhysicsStep(const E: Integer; const Dt: Single);
    procedure PhysicsToss(const E: Integer; const Dt: Single);
    procedure PhysicsNoclip(const E: Integer; const Dt: Single);
    procedure PlayerTouchTriggers(const Client: Integer);
    procedure HandleMessage;
    function ModelBounds(const Model: String; out AMins, AMaxs: TVector3): Boolean;
  public
    OnSound: TQcSoundEvent;
    OnPrint: TQcTextEvent;
    OnCenterPrint, OnStuffCmd: TQcClientTextEvent;
    OnTempEntity: TQcTempEntityEvent;
    OnDamage: TQcDamageEvent;
    OnAmbient: TQcAmbientEvent;
    OnIntermission: TQcTextEvent;
    OnParticle: TQcParticleEvent;
    OnLightStyle: TQcLightStyleEvent;
    OnMessage: TQcMessageEvent;

    constructor Create;
    destructor Destroy; override;

    { Load the progs and the map, spawn everything and put the player in;
      Parms = True keeps the player's parms (next level) }
    function LoadLevel(const AMapName: String; const ASkill: Integer; const KeepParms: Boolean): Boolean;

    { One frame: the player's input, then every entity (SV_Physics).
      Yaw and Pitch are the view angles in degrees (Quake convention).
      This is the single player form: client 1 }
    procedure Frame(const Cmd: TQuakeUserCmd; const Yaw, Pitch, Dt: Single; const Fire: Boolean;
      const Impulse: Integer); overload;
    { One frame for every connected client with the input given to
      SetClientInput }
    procedure Frame(const Dt: Single); overload;

    { Multiplayer: MaxClients edicts are reserved for players (set before
      LoadLevel); clients connect and leave while the level runs }
    procedure SetClientInput(const E: Integer; const Cmd: TQuakeUserCmd; const Yaw, Pitch: Single;
      const Fire: Boolean; const Impulse: Integer);
    function ConnectClient(const E: Integer; const AName: String): Boolean;
    procedure DisconnectClient(const E: Integer);
    function ClientActive(const E: Integer): Boolean;
    function ClientPhys(const E: Integer): TQuakePlayerPhysics;
    function ClientName(const E: Integer): String;
    function FreeClientSlot: Integer;

    { The player's view angles the progs asked for (teleports, spawn);
      False when there was none }
    function TakeFixAngle(out Angles: TVector3): Boolean; overload;
    function TakeFixAngle(const E: Integer; out Angles: TVector3): Boolean; overload;
    function LightStyleValue(const Style: Integer): String;

    { Host overrides (the builtins) }
    procedure SetOrigin(const Progs: TQuakeProgs; const E: Integer; const Org: TVector3); override;
    procedure SetModel(const Progs: TQuakeProgs; const E: Integer; const Model: String); override;
    procedure SetSize(const Progs: TQuakeProgs; const E: Integer; const Mins, Maxs: TVector3); override;
    procedure Sound(const Progs: TQuakeProgs; const E, Channel: Integer; const Sample: String;
      const Volume, Attenuation: Single); override;
    procedure TraceLine(const Progs: TQuakeProgs; const Start, Stop: TVector3; const NoMonsters: Integer;
      const Ignore: Integer; out Fraction: Single; out EndPos, Normal: TVector3; out HitEntity: Integer;
      out AllSolid, StartSolid, InOpen, InWater: Boolean); override;
    function WalkMove(const Progs: TQuakeProgs; const E: Integer; const Yaw, Dist: Single): Boolean; override;
    procedure MoveToGoal(const Progs: TQuakeProgs; const E: Integer; const Dist: Single); override;
    function DropToFloor(const Progs: TQuakeProgs; const E: Integer): Boolean; override;
    function CheckBottom(const Progs: TQuakeProgs; const E: Integer): Boolean; override;
    function PointContents(const Progs: TQuakeProgs; const P: TVector3): Integer; override;
    procedure LightStyle(const Progs: TQuakeProgs; const Style: Integer; const Value: String); override;
    procedure Particle(const Progs: TQuakeProgs; const Org, Dir: TVector3; const Color, Count: Integer); override;
    procedure CenterPrint(const Progs: TQuakeProgs; const E: Integer; const S: String); override;
    procedure Print(const Progs: TQuakeProgs; const S: String); override;
    procedure AmbientSound(const Progs: TQuakeProgs; const Org: TVector3; const Sample: String;
      const Volume, Attenuation: Single); override;
    procedure ChangeLevel(const Progs: TQuakeProgs; const Map: String); override;
    function Cvar(const Progs: TQuakeProgs; const Name: String): Single; override;
    procedure MakeStatic(const Progs: TQuakeProgs; const E: Integer); override;
    procedure StuffCmd(const Progs: TQuakeProgs; const E: Integer; const Cmd: String); override;
    procedure WriteMessage(const Progs: TQuakeProgs; const Dest, Kind: Integer; const Value: TVector3;
      const S: String); override;

    property Progs: TQuakeProgs read FProgs;
    property Bsp: TQuakeBsp read FBsp;
    property Phys: TQuakePlayerPhysics read FClients[1].Phys;
    property MaxClients: Integer read FMaxClients write FMaxClients;
    property Deathmatch: Integer read FDeathmatch write FDeathmatch;
    property Time: Single read FTime;
    property MapName: String read FMapName;
    property Skill: Integer read FSkill;
    property LevelChange: String read FLevelChange write FLevelChange;
    property Intermission: Boolean read FIntermission;
    function StaticCount: Integer;
    function Static(const I: Integer): TQcStatic;
    { Player fields for the HUD (client 1, or the client edict E) }
    function PlayerHealth: Integer; overload;
    function PlayerArmor: Integer; overload;
    function PlayerItems: Cardinal; overload;
    function PlayerAmmo(const Kind: Integer): Integer; overload; { 0 current, 1 shells, 2 nails, 3 rockets, 4 cells }
    function PlayerWeapon: Cardinal; overload;
    function PlayerWeaponModel: String; overload;
    function PlayerWeaponFrame: Integer; overload;
    function PlayerViewOfs: TVector3; overload;
    function PlayerDead: Boolean; overload;
    function PlayerEffects: Integer; overload;
    function PlayerHealth(const E: Integer): Integer; overload;
    function PlayerArmor(const E: Integer): Integer; overload;
    function PlayerItems(const E: Integer): Cardinal; overload;
    function PlayerAmmo(const E, Kind: Integer): Integer; overload;
    function PlayerWeapon(const E: Integer): Cardinal; overload;
    function PlayerWeaponModel(const E: Integer): String; overload;
    function PlayerWeaponFrame(const E: Integer): Integer; overload;
    function PlayerViewOfs(const E: Integer): TVector3; overload;
    function PlayerDead(const E: Integer): Boolean; overload;
    function PlayerEffects(const E: Integer): Integer; overload;
    function PlayerFrags(const E: Integer): Integer;
    function PlayerVelocity(const E: Integer): TVector3;
    function PlayerOnGround(const E: Integer): Boolean;
    function PlayerWaterLevel(const E: Integer): Integer;
    { Entity fields for rendering }
    function EntityModel(const E: Integer): String;
    function EntityOrigin(const E: Integer): TVector3;
    function EntityAngles(const E: Integer): TVector3;
    function EntityFrame(const E: Integer): Integer;
    function EntitySkin(const E: Integer): Integer;
    function EntityEffects(const E: Integer): Integer;
    function EntityVisible(const E: Integer): Boolean;
    function KilledMonsters: Integer;
    function TotalMonsters: Integer;
    function FoundSecrets: Integer;
    function TotalSecrets: Integer;
    property FFixAngleOfs: Integer read FFFixAngle;
  end;

implementation

const
  { svc messages the progs write }
  svc_setangle = 10;
  svc_damage = 19;
  svc_temp_entity = 23;
  svc_killedmonster = 27;
  svc_foundsecret = 28;
  svc_intermission = 30;
  svc_finale = 31;
  svc_cdtrack = 32;
  svc_sellscreen = 33;

constructor TQuakeQcGame.Create;
var
  I: Integer;
begin
  inherited Create;
  FProgs := TQuakeProgs.Create(Self);
  for I := 1 to MaxQcClients do
    FClients[I].Phys := TQuakePlayerPhysics.Create;
  FMaxClients := 1;
  FMessageStrings := TStringList.Create;
end;

destructor TQuakeQcGame.Destroy;
var
  I: Integer;
begin
  FProgs.Free;
  for I := 1 to MaxQcClients do
    FClients[I].Phys.Free;
  FBsp.Free;
  FMessageStrings.Free;
  inherited Destroy;
end;

function TQuakeQcGame.IsClient(const E: Integer): Boolean;
begin
  Result := (E >= 1) and (E <= FMaxClients) and FClients[E].Active;
end;

function TQuakeQcGame.ClientActive(const E: Integer): Boolean;
begin
  Result := IsClient(E);
end;

function TQuakeQcGame.ClientPhys(const E: Integer): TQuakePlayerPhysics;
begin
  if (E >= 1) and (E <= MaxQcClients) then
    Result := FClients[E].Phys
  else
    Result := nil;
end;

function TQuakeQcGame.ClientName(const E: Integer): String;
begin
  if (E >= 1) and (E <= MaxQcClients) then
    Result := FClients[E].Name
  else
    Result := '';
end;

function TQuakeQcGame.FreeClientSlot: Integer;
var
  E: Integer;
begin
  for E := 1 to Min(FMaxClients, MaxQcClients) do
    if not FClients[E].Active then
      Exit(E);
  Result := 0;
end;

procedure TQuakeQcGame.CacheOffsets;
begin
  FFLTime := FProgs.FieldOfs('ltime');
  FFMoveType := FProgs.FieldOfs('movetype');
  FFSolid := FProgs.FieldOfs('solid');
  FFFlags := FProgs.FieldOfs('flags');
  FFGroundEntity := FProgs.FieldOfs('groundentity');
  FFVelocity := FProgs.FieldOfs('velocity');
  FFAVelocity := FProgs.FieldOfs('avelocity');
  FFAngles := FProgs.FieldOfs('angles');
  FFOrigin := FProgs.FieldOfs('origin');
  FFOldOrigin := FProgs.FieldOfs('oldorigin');
  FFMins := FProgs.FieldOfs('mins');
  FFMaxs := FProgs.FieldOfs('maxs');
  FFAbsMin := FProgs.FieldOfs('absmin');
  FFAbsMax := FProgs.FieldOfs('absmax');
  FFTouch := FProgs.FieldOfs('touch');
  FFBlocked := FProgs.FieldOfs('blocked');
  FFOwner := FProgs.FieldOfs('owner');
  FFModelIndex := FProgs.FieldOfs('modelindex');
  FFModel := FProgs.FieldOfs('model');
  FFButton0 := FProgs.FieldOfs('button0');
  FFButton2 := FProgs.FieldOfs('button2');
  FFImpulse := FProgs.FieldOfs('impulse');
  FFVAngle := FProgs.FieldOfs('v_angle');
  FFFixAngle := FProgs.FieldOfs('fixangle');
  FFViewOfs := FProgs.FieldOfs('view_ofs');
  FFView_Ofs := FFViewOfs;
  FFHealth := FProgs.FieldOfs('health');
  FFWaterLevel := FProgs.FieldOfs('waterlevel');
  FFWaterType := FProgs.FieldOfs('watertype');
  FFTeleportTime := FProgs.FieldOfs('teleport_time');
  FFTakeDamage := FProgs.FieldOfs('takedamage');
  FFDeadFlag := FProgs.FieldOfs('deadflag');
  FFFrame := FProgs.FieldOfs('frame');
  FFSkin := FProgs.FieldOfs('skin');
  FFEffects := FProgs.FieldOfs('effects');
  FFWeaponModel := FProgs.FieldOfs('weaponmodel');
  FFWeaponFrame := FProgs.FieldOfs('weaponframe');
  FFNextThink := FProgs.FieldOfs('nextthink');
  FFThink := FProgs.FieldOfs('think');
  FFClassName := FProgs.FieldOfs('classname');
  FFGoalEntity := FProgs.FieldOfs('goalentity');
  FFEnemy := FProgs.FieldOfs('enemy');
  FFIdealYaw := FProgs.FieldOfs('ideal_yaw');
  FFSpawnFlags := FProgs.FieldOfs('spawnflags');
  FFTarget := FProgs.FieldOfs('target');
  FFTargetName := FProgs.FieldOfs('targetname');
  FFMoveDir := FProgs.FieldOfs('movedir');
  FFItems := FProgs.FieldOfs('items');
  FFArmorValue := FProgs.FieldOfs('armorvalue');
  FFCurrentAmmo := FProgs.FieldOfs('currentammo');
  FFAmmoShells := FProgs.FieldOfs('ammo_shells');
  FFAmmoNails := FProgs.FieldOfs('ammo_nails');
  FFAmmoRockets := FProgs.FieldOfs('ammo_rockets');
  FFAmmoCells := FProgs.FieldOfs('ammo_cells');
  FFWeapon := FProgs.FieldOfs('weapon');
  FFNetName := FProgs.FieldOfs('netname');
  FFColorMap := FProgs.FieldOfs('colormap');
  FFFrags := FProgs.FieldOfs('frags');
  FFDmgTake := FProgs.FieldOfs('dmg_take');

  FFnStartFrame := FProgs.FunctionIndex('StartFrame');
  FFnPlayerPreThink := FProgs.FunctionIndex('PlayerPreThink');
  FFnPlayerPostThink := FProgs.FunctionIndex('PlayerPostThink');
  FFnClientConnect := FProgs.FunctionIndex('ClientConnect');
  FFnPutClientInServer := FProgs.FunctionIndex('PutClientInServer');
  FFnSetNewParms := FProgs.FunctionIndex('SetNewParms');
  FFnSetChangeParms := FProgs.FunctionIndex('SetChangeParms');
  FFnClientKill := FProgs.FunctionIndex('ClientKill');
  FFnClientDisconnect := FProgs.FunctionIndex('ClientDisconnect');
end;

function TQuakeQcGame.LoadLevel(const AMapName: String; const ASkill: Integer; const KeepParms: Boolean): Boolean;
var
  WorldEnt: TQuakeEntity;
  Parms: array[0..15] of Single;
  I, ParmOfs: Integer;
begin
  Result := False;
  { The level parms (SetChangeParms before a level change) survive the
    reload of the progs }
  ParmOfs := -1;
  if FProgs.Loaded then
  begin
    ParmOfs := FProgs.GlobalOfs('parm1');
    for I := 0 to 15 do
      Parms[I] := FProgs.Global(ParmOfs + I)^.F;
  end;
  if not FProgs.Load then
    Exit;
  CacheOffsets;
  if KeepParms and (ParmOfs >= 0) then
  begin
    for I := 0 to 15 do
      FProgs.Global(ParmOfs + I)^.F := Parms[I];
  end else
  if FFnSetNewParms > 0 then
    FProgs.Execute(FFnSetNewParms);

  FreeAndNil(FBsp);
  FBsp := TQuakeBsp.Create;
  if not FBsp.LoadFromPak('maps/' + AMapName + '.bsp') then
  begin
    FreeAndNil(FBsp);
    Exit;
  end;
  FMapName := AMapName;
  FSkill := ASkill;
  FLevelChange := '';
  FIntermission := False;
  SetLength(FStatics, 0);
  SetLength(FMessageBytes, 0);
  SetLength(FMessageRaw, 0);
  FMessageStrings.Clear;
  for I := 0 to High(FLightStyles) do
    FLightStyles[I] := '';
  FMaxClients := EnsureRange(FMaxClients, 1, MaxQcClients);

  { SV_SpawnServer: the client edicts, then the map's entities }
  FProgs.ReserveEdicts(FMaxClients);
  FTime := 1.0;
  FProgs.Global(FProgs.GTime)^.F := FTime;
  FProgs.Global(FProgs.GlobalOfs('mapname'))^.I := FProgs.NewString(AMapName);
  FProgs.Global(FProgs.GlobalOfs('serverflags'))^.F := 0;
  FProgs.Global(FProgs.GSkill)^.F := ASkill;
  FProgs.Global(FProgs.GlobalOfs('deathmatch'))^.F := FDeathmatch;
  FProgs.Global(FProgs.GlobalOfs('coop'))^.F := 0;
  WorldEnt := FBsp.FindEntity('worldspawn');
  if WorldEnt = nil then
    Exit;
  FProgs.SpawnEntities(FBsp.Entities, ASkill);

  { The players (SV_ConnectClient / SV_SpawnServer "spawn"): single player
    is always client 1, the connected clients come back on a new level }
  if FMaxClients = 1 then
  begin
    FClients[1].Active := True;
    if FClients[1].Name = '' then
      FClients[1].Name := 'player';
  end;
  for I := 1 to FMaxClients do
  begin
    FClients[I].Phys.Bsp := FBsp;
    if FClients[I].Active then
      ConnectClientNow(I);
  end;
  WritelnLog('QuakeQcGame', 'Level "%s" spawned by the progs: %d edicts, %d monsters, %d secrets, %d clients',
    [AMapName, FProgs.NumEdicts, TotalMonsters, TotalSecrets, FMaxClients]);
  Result := True;
end;

procedure TQuakeQcGame.ConnectClientNow(const E: Integer);
var
  P: TQuakePlayerPhysics;
begin
  P := FClients[E].Phys;
  FProgs.Field(E, FFColorMap)^.F := E;
  FProgs.Field(E, FFNetName)^.I := FProgs.NewString(FClients[E].Name);
  if FFnClientConnect > 0 then
    FProgs.CallWith(FFnClientConnect, E);
  if FFnPutClientInServer > 0 then
    FProgs.CallWith(FFnPutClientInServer, E);
  P.Bsp := FBsp;
  P.Mins := FProgs.FieldVector(E, FFMins);
  P.Maxs := FProgs.FieldVector(E, FFMaxs);
  if P.Maxs.Z <= P.Mins.Z then
  begin
    P.Mins := Vector3(-16, -16, -24);
    P.Maxs := Vector3(16, 16, 32);
  end;
  P.Teleport(FProgs.FieldVector(E, FFOrigin));
  LinkEdict(E);
end;

function TQuakeQcGame.ConnectClient(const E: Integer; const AName: String): Boolean;
begin
  Result := (E >= 1) and (E <= FMaxClients) and not FClients[E].Active and (FBsp <> nil) and FProgs.Loaded;
  if not Result then
    Exit;
  FClients[E].Active := True;
  FClients[E].Name := AName;
  FClients[E].Cmd := Default(TQuakeUserCmd);
  FClients[E].Fire := False;
  FClients[E].Impulse := 0;
  { A fresh player: the parms of a new game }
  if FFnSetNewParms > 0 then
    FProgs.Execute(FFnSetNewParms);
  FProgs.Global(FProgs.GTime)^.F := FTime;
  ConnectClientNow(E);
  WritelnLog('QuakeQcGame', 'Client %d "%s" entered the game', [E, AName]);
end;

procedure TQuakeQcGame.DisconnectClient(const E: Integer);
begin
  if not IsClient(E) then
    Exit;
  if FProgs.Loaded and (FFnClientDisconnect > 0) then
    FProgs.CallWith(FFnClientDisconnect, E);
  { SV_DropClient: the edict stays reserved but is nothing any more }
  if FProgs.Loaded then
  begin
    FProgs.Field(E, FFSolid)^.F := SOLID_NOT;
    FProgs.Field(E, FFModel)^.I := 0;
    FProgs.Field(E, FFModelIndex)^.F := 0;
    FProgs.Field(E, FFHealth)^.F := 0;
    FProgs.Field(E, FFFrags)^.F := 0;
    FProgs.Field(E, FFNextThink)^.F := 0;
    FProgs.Field(E, FFTakeDamage)^.F := 0;
    FProgs.Field(E, FFMoveType)^.F := MOVETYPE_NONE;
    FProgs.Field(E, FFNetName)^.I := 0;
    FProgs.Field(E, FFColorMap)^.F := 0;
  end;
  FClients[E].Active := False;
  WritelnLog('QuakeQcGame', 'Client %d left the game', [E]);
end;

procedure TQuakeQcGame.SetClientInput(const E: Integer; const Cmd: TQuakeUserCmd; const Yaw, Pitch: Single;
  const Fire: Boolean; const Impulse: Integer);
begin
  if (E < 1) or (E > MaxQcClients) then
    Exit;
  FClients[E].Cmd := Cmd;
  FClients[E].Yaw := Yaw;
  FClients[E].Pitch := Pitch;
  FClients[E].Fire := Fire;
  if Impulse <> 0 then
    FClients[E].Impulse := Impulse;
end;

{ Memory helpers }

procedure TQuakeQcGame.LinkEdict(const E: Integer);
var
  Org, Mins, Maxs: TVector3;
begin
  { SV_LinkEdict: absolute bounds (items are a little bigger to touch) }
  Org := FProgs.FieldVector(E, FFOrigin);
  Mins := Org + FProgs.FieldVector(E, FFMins);
  Maxs := Org + FProgs.FieldVector(E, FFMaxs);
  if (Round(FProgs.Field(E, FFFlags)^.F) and FL_ITEM) <> 0 then
  begin
    Mins := Mins - Vector3(15, 15, 1);
    Maxs := Maxs + Vector3(15, 15, 1);
  end else
  begin
    Mins := Mins - Vector3(1, 1, 1);
    Maxs := Maxs + Vector3(1, 1, 1);
  end;
  FProgs.SetFieldVector(E, FFAbsMin, Mins);
  FProgs.SetFieldVector(E, FFAbsMax, Maxs);
end;

function TQuakeQcGame.EntityBox(const E: Integer; out AMins, AMaxs: TVector3): Boolean;
var
  Org: TVector3;
begin
  Result := not FProgs.EdictFree(E);
  if not Result then
    Exit;
  Org := FProgs.FieldVector(E, FFOrigin);
  AMins := Org + FProgs.FieldVector(E, FFMins);
  AMaxs := Org + FProgs.FieldVector(E, FFMaxs);
end;

function TQuakeQcGame.ModelBounds(const Model: String; out AMins, AMaxs: TVector3): Boolean;
var
  Idx: Integer;
begin
  Result := True;
  if (Model <> '') and (Model[1] = '*') then
  begin
    Idx := StrToIntDef(Copy(Model, 2, MaxInt), -1);
    if (Idx > 0) and (Idx < FBsp.ModelCount) then
    begin
      AMins := FBsp.Models[Idx].Mins;
      AMaxs := FBsp.Models[Idx].Maxs;
      Exit;
    end;
  end;
  { Alias models and the rest: Mod_LoadAliasModel's fixed box }
  AMins := Vector3(-16, -16, -16);
  AMaxs := Vector3(16, 16, 16);
end;

{ Traces (world.c SV_Move) }

function TQuakeQcGame.TraceBox(const Start, Stop, Mins, Maxs: TVector3; const Kind, Ignore: Integer): TQuakeTrace;
var
  Hull, E, Idx: Integer;
  ClipOffset, BMins, BMaxs, EOrg: TVector3;
  T: TQuakeTrace;
  Model: String;
  Solid: Integer;

  procedure Combine(const Entity: Integer);
  begin
    if T.AllSolid or T.StartSolid or (T.Fraction < Result.Fraction) then
    begin
      T.Entity := Entity;
      if Result.StartSolid then
      begin
        Result := T;
        Result.StartSolid := True;
      end else
        Result := T;
    end else
    if T.StartSolid then
      Result.StartSolid := True;
  end;

begin
  Hull := FBsp.HullForSize(Mins, Maxs);
  ClipOffset := FBsp.HullClipMins(Hull) - Mins;
  if (Mins.IsZero) and (Maxs.IsZero) then
  begin
    Hull := 0;
    ClipOffset := TVector3.Zero;
  end;
  Result := FBsp.TraceHull(Hull, 0, ClipOffset, Start, Stop);
  Result.Entity := 0;
  if Result.AllSolid then
    Exit;

  for E := 1 to FProgs.NumEdicts - 1 do
  begin
    if (E = Ignore) or FProgs.EdictFree(E) then
      Continue;
    Solid := Round(FProgs.Field(E, FFSolid)^.F);
    if (Solid = SOLID_NOT) or (Solid = SOLID_TRIGGER) then
      Continue;
    if (Kind = MOVE_NOMONSTERS) and (Solid <> SOLID_BSP) then
      Continue;
    { The owner of a missile is not hit }
    if (Ignore > 0) and (FProgs.Field(E, FFOwner)^.I = Ignore) then
      Continue;
    if (Ignore > 0) and (FProgs.Field(Ignore, FFOwner)^.I = E) then
      Continue;
    EOrg := FProgs.FieldVector(E, FFOrigin);
    if Solid = SOLID_BSP then
    begin
      Model := FProgs.FieldString(E, FFModel);
      Idx := -1;
      if (Model <> '') and (Model[1] = '*') then
        Idx := StrToIntDef(Copy(Model, 2, MaxInt), -1);
      if (Idx <= 0) or (Idx >= FBsp.ModelCount) then
        Continue;
      T := FBsp.TraceHull(Hull, Idx, EOrg + ClipOffset, Start, Stop);
      Combine(E);
    end else
    begin
      BMins := EOrg + FProgs.FieldVector(E, FFMins);
      BMaxs := EOrg + FProgs.FieldVector(E, FFMaxs);
      T := TraceSegmentBox(BMins - Maxs, BMaxs - Mins, Start, Stop);
      if T.StartSolid then
      begin
        T.Fraction := 0;
        T.EndPos := Start;
        T.PlaneNormal := (Stop - Start).Normalize * -1;
      end;
      if (T.Fraction < 1) or T.StartSolid then
        Combine(E);
    end;
  end;
end;

function TQuakeQcGame.PointTrace(const Start, Stop: TVector3; const Ignore: Integer): TQuakeTrace;
begin
  Result := TraceBox(Start, Stop, TVector3.Zero, TVector3.Zero, MOVE_NORMAL, Ignore);
end;

procedure TQuakeQcGame.RefreshPlayerColliders(const Client: Integer);
var
  E, N, NB, Idx, Solid: Integer;
  Model: String;
  BMins, BMaxs: TVector3;
  FPhys: TQuakePlayerPhysics;
begin
  { The player physics collide with the pushers at their offsets and the
    boxes of the solid entities (the other players among them) }
  FPhys := FClients[Client].Phys;
  N := 0;
  NB := 0;
  SetLength(FPhys.SolidModels, FProgs.NumEdicts);
  SetLength(FPhys.SolidBoxes, FProgs.NumEdicts);
  for E := 1 to FProgs.NumEdicts - 1 do
  begin
    if (E = Client) or FProgs.EdictFree(E) then
      Continue;
    Solid := Round(FProgs.Field(E, FFSolid)^.F);
    if Solid = SOLID_BSP then
    begin
      Model := FProgs.FieldString(E, FFModel);
      Idx := -1;
      if (Model <> '') and (Model[1] = '*') then
        Idx := StrToIntDef(Copy(Model, 2, MaxInt), -1);
      if (Idx <= 0) or (Idx >= FBsp.ModelCount) then
        Continue;
      FPhys.SolidModels[N].ModelIndex := Idx;
      FPhys.SolidModels[N].Offset := FProgs.FieldVector(E, FFOrigin);
      Inc(N);
    end else
    if (Solid = SOLID_BBOX) or (Solid = SOLID_SLIDEBOX) then
    begin
      if EntityBox(E, BMins, BMaxs) and (BMaxs.Z > BMins.Z) then
      begin
        FPhys.SolidBoxes[NB].Mins := BMins;
        FPhys.SolidBoxes[NB].Maxs := BMaxs;
        Inc(NB);
      end;
    end;
  end;
  SetLength(FPhys.SolidModels, N);
  SetLength(FPhys.SolidBoxes, NB);
end;

{ Thinking and touching }

function TQuakeQcGame.RunThink(const E: Integer): Boolean;
var
  ThinkTime: Single;
  F: Integer;
begin
  { SV_RunThink: False when the entity was removed }
  ThinkTime := FProgs.Field(E, FFNextThink)^.F;
  if (ThinkTime <= 0) or (ThinkTime > FTime + FProgs.Global(FProgs.GlobalOfs('frametime'))^.F) then
    Exit(True);
  if ThinkTime < FTime then
    ThinkTime := FTime;
  FProgs.Field(E, FFNextThink)^.F := 0;
  FProgs.Global(FProgs.GTime)^.F := ThinkTime;
  F := FProgs.Field(E, FFThink)^.I;
  if F > 0 then
  begin
    Inc(FProgs.Statistics.Thinks);
    FProgs.CallWith(F, E);
  end;
  FProgs.Global(FProgs.GTime)^.F := FTime;
  Result := not FProgs.EdictFree(E);
end;

procedure TQuakeQcGame.CallTouch(const E, Other: Integer);
var
  F: Integer;
begin
  F := FProgs.Field(E, FFTouch)^.I;
  if (F > 0) and (Round(FProgs.Field(E, FFSolid)^.F) <> SOLID_NOT) then
    FProgs.CallWithOther(F, E, Other);
end;

procedure TQuakeQcGame.Impact(const E1, E2: Integer);
begin
  { SV_Impact: both get to know }
  CallTouch(E1, E2);
  if not FProgs.EdictFree(E2) then
    CallTouch(E2, E1);
end;

function TQuakeQcGame.PushEntity(const E: Integer; const Push: TVector3): TQuakeTrace;
var
  Start, Stop, Mins, Maxs: TVector3;
  Kind: Integer;
begin
  { SV_PushEntity: move, stop at whatever is hit and touch it }
  Start := FProgs.FieldVector(E, FFOrigin);
  Stop := Start + Push;
  Mins := FProgs.FieldVector(E, FFMins);
  Maxs := FProgs.FieldVector(E, FFMaxs);
  case Round(FProgs.Field(E, FFMoveType)^.F) of
    MOVETYPE_FLYMISSILE: Kind := MOVE_MISSILE;
    MOVETYPE_NONE: Kind := MOVE_NOMONSTERS;
    else Kind := MOVE_NORMAL;
  end;
  if Kind = MOVE_MISSILE then
  begin
    { Missiles hit with a 15 unit box like SV_Move does }
    Mins := Vector3(-15, -15, -15);
    Maxs := Vector3(15, 15, 15);
  end;
  Result := TraceBox(Start, Stop, Mins, Maxs, Kind, E);
  if Kind = MOVE_MISSILE then
  begin
    { But fly with their own (point) size }
    if (Result.Fraction < 1) and (Round(FProgs.Field(Result.Entity, FFSolid)^.F) = SOLID_BSP) then
      Result := TraceBox(Start, Stop, TVector3.Zero, TVector3.Zero, Kind, E);
  end;
  FProgs.SetFieldVector(E, FFOrigin, Result.EndPos);
  LinkEdict(E);
  if (Result.Fraction < 1) or Result.StartSolid then
    Impact(E, Result.Entity);
end;

procedure TQuakeQcGame.PhysicsPusher(const E: Integer; const Dt: Single);
var
  ThinkTime, OldLTime, MoveTime: Single;
  Move, Vel, Mins, Maxs, PMins, PMaxs: TVector3;
  Other: Integer;
  F: Integer;
begin
  { SV_Physics_Pusher: doors, plats, trains move by their velocity until
    the next think, pushing the player along }
  OldLTime := FProgs.Field(E, FFLTime)^.F;
  ThinkTime := FProgs.Field(E, FFNextThink)^.F;
  if ThinkTime < OldLTime + Dt then
  begin
    MoveTime := ThinkTime - OldLTime;
    if MoveTime < 0 then
      MoveTime := 0;
  end else
    MoveTime := Dt;

  if MoveTime > 0 then
  begin
    Vel := FProgs.FieldVector(E, FFVelocity);
    if not Vel.IsZero then
    begin
      Move := Vel * MoveTime;
      FProgs.SetFieldVector(E, FFOrigin, FProgs.FieldVector(E, FFOrigin) + Move);
      LinkEdict(E);
      { Push the player and the solid entities inside the new bounds }
      Mins := FProgs.FieldVector(E, FFAbsMin);
      Maxs := FProgs.FieldVector(E, FFAbsMax);
      for Other := 1 to FProgs.NumEdicts - 1 do
      begin
        if (Other = E) or FProgs.EdictFree(Other) then
          Continue;
        case Round(FProgs.Field(Other, FFMoveType)^.F) of
          MOVETYPE_PUSH, MOVETYPE_NONE, MOVETYPE_NOCLIP: Continue;
        end;
        if ((Round(FProgs.Field(Other, FFFlags)^.F) and FL_ONGROUND) = 0) or
           (FProgs.Field(Other, FFGroundEntity)^.I <> E) then
        begin
          if not EntityBox(Other, PMins, PMaxs) then
            Continue;
          if (PMins.X >= Maxs.X) or (PMaxs.X <= Mins.X) or (PMins.Y >= Maxs.Y) or (PMaxs.Y <= Mins.Y) or
             (PMins.Z >= Maxs.Z) or (PMaxs.Z <= Mins.Z) then
            Continue;
        end;
        { Carried or pushed }
        FProgs.SetFieldVector(Other, FFOrigin, FProgs.FieldVector(Other, FFOrigin) + Move);
        LinkEdict(Other);
        if IsClient(Other) then
          FClients[Other].Phys.Teleport(FProgs.FieldVector(Other, FFOrigin));
      end;
    end;
    FProgs.Field(E, FFLTime)^.F := OldLTime + MoveTime;
  end;

  if (ThinkTime > OldLTime) and (ThinkTime <= FProgs.Field(E, FFLTime)^.F) then
  begin
    FProgs.Field(E, FFNextThink)^.F := 0;
    FProgs.Global(FProgs.GTime)^.F := FTime;
    F := FProgs.Field(E, FFThink)^.I;
    if F > 0 then
    begin
      Inc(FProgs.Statistics.Thinks);
      FProgs.CallWith(F, E);
    end;
  end;
end;

procedure TQuakeQcGame.PhysicsStep(const E: Integer; const Dt: Single);
var
  Flags: Integer;
  Vel, Org: TVector3;
  T: TQuakeTrace;
  Mins, Maxs: TVector3;
  I: Integer;
begin
  { SV_Physics_Step: monsters fall when not on the ground, then think }
  Flags := Round(FProgs.Field(E, FFFlags)^.F);
  if (Flags and (FL_ONGROUND or FL_FLY or FL_SWIM)) = 0 then
  begin
    Vel := FProgs.FieldVector(E, FFVelocity);
    Vel.Z := Vel.Z - SvGravity * Dt;
    Org := FProgs.FieldVector(E, FFOrigin);
    Mins := FProgs.FieldVector(E, FFMins);
    Maxs := FProgs.FieldVector(E, FFMaxs);
    { A few slides like SV_FlyMove }
    for I := 1 to 4 do
    begin
      T := TraceBox(Org, Org + Vel * Dt, Mins, Maxs, MOVE_NORMAL, E);
      Org := T.EndPos;
      if T.Fraction >= 1 then
        Break;
      if T.PlaneNormal.Z > 0.7 then
      begin
        FProgs.Field(E, FFFlags)^.F := Flags or FL_ONGROUND;
        FProgs.Field(E, FFGroundEntity)^.I := T.Entity;
        Vel := TVector3.Zero;
        Break;
      end;
      Vel := ClipVelocity(Vel, T.PlaneNormal, 1);
      if T.Fraction <= 0 then
        Break;
    end;
    FProgs.SetFieldVector(E, FFVelocity, Vel);
    FProgs.SetFieldVector(E, FFOrigin, Org);
    LinkEdict(E);
  end;
  RunThink(E);
end;

procedure TQuakeQcGame.PhysicsToss(const E: Integer; const Dt: Single);
var
  MoveType, Flags: Integer;
  Vel, Angles: TVector3;
  T: TQuakeTrace;
  Backoff: Single;
begin
  { SV_Physics_Toss: gibs, grenades, missiles, dropped items }
  if not RunThink(E) then
    Exit;
  Flags := Round(FProgs.Field(E, FFFlags)^.F);
  if (Flags and FL_ONGROUND) <> 0 then
    Exit;
  MoveType := Round(FProgs.Field(E, FFMoveType)^.F);
  Vel := FProgs.FieldVector(E, FFVelocity);
  if (MoveType <> MOVETYPE_FLY) and (MoveType <> MOVETYPE_FLYMISSILE) then
    Vel.Z := Vel.Z - SvGravity * Dt;
  Angles := FProgs.FieldVector(E, FFAngles) + FProgs.FieldVector(E, FFAVelocity) * Dt;
  FProgs.SetFieldVector(E, FFAngles, Angles);
  FProgs.SetFieldVector(E, FFVelocity, Vel);

  T := PushEntity(E, Vel * Dt);
  if (T.Fraction >= 1) or FProgs.EdictFree(E) then
    Exit;
  if MoveType = MOVETYPE_BOUNCE then
    Backoff := 1.5
  else
    Backoff := 1;
  Vel := ClipVelocity(FProgs.FieldVector(E, FFVelocity), T.PlaneNormal, Backoff);
  if T.PlaneNormal.Z > 0.7 then
  begin
    if (Vel.Z < 60) or (MoveType <> MOVETYPE_BOUNCE) then
    begin
      FProgs.Field(E, FFFlags)^.F := Round(FProgs.Field(E, FFFlags)^.F) or FL_ONGROUND;
      FProgs.Field(E, FFGroundEntity)^.I := T.Entity;
      Vel := TVector3.Zero;
      FProgs.SetFieldVector(E, FFAVelocity, TVector3.Zero);
    end;
  end;
  FProgs.SetFieldVector(E, FFVelocity, Vel);
end;

procedure TQuakeQcGame.PhysicsNoclip(const E: Integer; const Dt: Single);
begin
  if not RunThink(E) then
    Exit;
  FProgs.SetFieldVector(E, FFAngles, FProgs.FieldVector(E, FFAngles) + FProgs.FieldVector(E, FFAVelocity) * Dt);
  FProgs.SetFieldVector(E, FFOrigin, FProgs.FieldVector(E, FFOrigin) + FProgs.FieldVector(E, FFVelocity) * Dt);
  LinkEdict(E);
end;

procedure TQuakeQcGame.PlayerTouchTriggers(const Client: Integer);
var
  E: Integer;
  PMins, PMaxs, Mins, Maxs: TVector3;
  FPhys: TQuakePlayerPhysics;
begin
  { SV_TouchLinks: the player touches the triggers and items it overlaps }
  FPhys := FClients[Client].Phys;
  PMins := FPhys.Origin + FPhys.Mins;
  PMaxs := FPhys.Origin + FPhys.Maxs;
  for E := FMaxClients + 1 to FProgs.NumEdicts - 1 do
  begin
    if FProgs.EdictFree(E) or (Round(FProgs.Field(E, FFSolid)^.F) <> SOLID_TRIGGER) then
      Continue;
    Mins := FProgs.FieldVector(E, FFAbsMin);
    Maxs := FProgs.FieldVector(E, FFAbsMax);
    if (PMins.X > Maxs.X) or (PMaxs.X < Mins.X) or (PMins.Y > Maxs.Y) or (PMaxs.Y < Mins.Y) or
       (PMins.Z > Maxs.Z) or (PMaxs.Z < Mins.Z) then
      Continue;
    CallTouch(E, Client);
  end;
end;

procedure TQuakeQcGame.Frame(const Cmd: TQuakeUserCmd; const Yaw, Pitch, Dt: Single; const Fire: Boolean;
  const Impulse: Integer);
begin
  SetClientInput(1, Cmd, Yaw, Pitch, Fire, Impulse);
  Frame(Dt);
end;

procedure TQuakeQcGame.MoveClient(const E: Integer; const Dt: Single);
var
  I, O, Flags: Integer;
  Org, NewOrg: TVector3;
  Dead: Boolean;
  FPhys: TQuakePlayerPhysics;
  Yaw, Pitch: Single;
begin
  { SV_RunClients for one player: input into the edict, PlayerPreThink,
    the movement, PlayerPostThink }
  FPhys := FClients[E].Phys;
  Yaw := FClients[E].Yaw;
  Pitch := FClients[E].Pitch;
  Dead := PlayerDead(E);
  FProgs.Field(E, FFButton0)^.F := Ord(FClients[E].Fire);
  FProgs.Field(E, FFButton2)^.F := Ord(FClients[E].Cmd.Jump);
  FProgs.Field(E, FFImpulse)^.F := FClients[E].Impulse;
  FClients[E].Impulse := 0;
  FProgs.SetFieldVector(E, FFVAngle, Vector3(Pitch, Yaw, 0));
  if not Dead then
    FProgs.SetFieldVector(E, FFAngles, Vector3(-Pitch / 3, Yaw, 0));
  if FFnPlayerPreThink > 0 then
    FProgs.CallWith(FFnPlayerPreThink, E);
  if FProgs.EdictFree(E) or not FClients[E].Active then
    Exit;

  { Movement with the Quake player physics, unless the progs moved the
    player (teleport) }
  Org := FProgs.FieldVector(E, FFOrigin);
  if PointsDistanceSqr(Org, FPhys.Origin) > 1 then
    FPhys.Teleport(Org);
  FPhys.Velocity := FProgs.FieldVector(E, FFVelocity);
  FPhys.Mins := FProgs.FieldVector(E, FFMins);
  FPhys.Maxs := FProgs.FieldVector(E, FFMaxs);
  RefreshPlayerColliders(E);
  if not Dead and not FIntermission then
    FPhys.Move(FClients[E].Cmd, Yaw, Pitch, Dt)
  else
  begin
    FPhys.Move(Default(TQuakeUserCmd), Yaw, Pitch, Dt);
  end;
  FProgs.SetFieldVector(E, FFOrigin, FPhys.Origin);
  FProgs.SetFieldVector(E, FFVelocity, FPhys.Velocity);
  Flags := Round(FProgs.Field(E, FFFlags)^.F);
  if FPhys.OnGround then
    Flags := Flags or FL_ONGROUND
  else
    Flags := Flags and not FL_ONGROUND;
  FProgs.Field(E, FFFlags)^.F := Flags;
  FProgs.Field(E, FFWaterLevel)^.F := FPhys.WaterLevel;
  FProgs.Field(E, FFWaterType)^.F := FPhys.WaterType;
  LinkEdict(E);
  { What the player ran into: doors open, buttons press }
  for I := 0 to High(FPhys.Touched) do
    for O := FMaxClients + 1 to FProgs.NumEdicts - 1 do
      if not FProgs.EdictFree(O) and (Round(FProgs.Field(O, FFSolid)^.F) = SOLID_BSP) and
         (FProgs.FieldString(O, FFModel) = '*' + IntToStr(FPhys.Touched[I])) then
        Impact(E, O);
  PlayerTouchTriggers(E);
  if FFnPlayerPostThink > 0 then
    FProgs.CallWith(FFnPlayerPostThink, E);
  { The progs may have changed the player's velocity (knockback) or origin }
  NewOrg := FProgs.FieldVector(E, FFOrigin);
  if PointsDistanceSqr(NewOrg, FPhys.Origin) > 1 then
    FPhys.Teleport(NewOrg);
  FPhys.Velocity := FProgs.FieldVector(E, FFVelocity);
  if FProgs.Field(E, FFTeleportTime)^.F > FTime then
    FPhys.TeleportTime := FPhys.Time + (FProgs.Field(E, FFTeleportTime)^.F - FTime);
end;

procedure TQuakeQcGame.Frame(const Dt: Single);
var
  E, MoveType: Integer;
begin
  if (FBsp = nil) or not FProgs.Loaded then
    Exit;
  FProgs.Global(FProgs.GlobalOfs('frametime'))^.F := Dt;
  FProgs.Global(FProgs.GTime)^.F := FTime;
  if FFnStartFrame > 0 then
    FProgs.CallWith(FFnStartFrame, 0);

  { The players }
  for E := 1 to FMaxClients do
    if FClients[E].Active then
      MoveClient(E, Dt);

  { Everything else (SV_Physics) }
  for E := FMaxClients + 1 to FProgs.NumEdicts - 1 do
  begin
    if FProgs.EdictFree(E) then
      Continue;
    MoveType := Round(FProgs.Field(E, FFMoveType)^.F);
    case MoveType of
      MOVETYPE_PUSH: PhysicsPusher(E, Dt);
      MOVETYPE_NONE: RunThink(E);
      MOVETYPE_NOCLIP: PhysicsNoclip(E, Dt);
      MOVETYPE_STEP: PhysicsStep(E, Dt);
      MOVETYPE_TOSS, MOVETYPE_BOUNCE, MOVETYPE_FLY, MOVETYPE_FLYMISSILE: PhysicsToss(E, Dt);
      else RunThink(E);
    end;
  end;

  FTime := FTime + Dt;
  FProgs.Global(FProgs.GTime)^.F := FTime;
end;

function TQuakeQcGame.TakeFixAngle(out Angles: TVector3): Boolean;
begin
  Result := TakeFixAngle(1, Angles);
end;

function TQuakeQcGame.TakeFixAngle(const E: Integer; out Angles: TVector3): Boolean;
begin
  Angles := TVector3.Zero;
  if not FProgs.Loaded or (E < 1) or (E >= FProgs.NumEdicts) then
    Exit(False);
  Result := FProgs.Field(E, FFFixAngle)^.F <> 0;
  if Result then
  begin
    Angles := FProgs.FieldVector(E, FFAngles);
    FProgs.Field(E, FFFixAngle)^.F := 0;
  end;
end;

function TQuakeQcGame.LightStyleValue(const Style: Integer): String;
begin
  if (Style >= 0) and (Style <= High(FLightStyles)) then
    Result := FLightStyles[Style]
  else
    Result := '';
end;

{ Builtins }

procedure TQuakeQcGame.SetOrigin(const Progs: TQuakeProgs; const E: Integer; const Org: TVector3);
begin
  Progs.SetFieldVector(E, FFOrigin, Org);
  LinkEdict(E);
  if IsClient(E) then
    FClients[E].Phys.Teleport(Org);
end;

procedure TQuakeQcGame.SetModel(const Progs: TQuakeProgs; const E: Integer; const Model: String);
var
  Mins, Maxs: TVector3;
begin
  { SV_SetModel: the precache index and the model's bounds }
  Progs.Field(E, FFModelIndex)^.F := Progs.PrecachedModels.IndexOf(Model) + 1;
  if ModelBounds(Model, Mins, Maxs) then
  begin
    Progs.SetFieldVector(E, FFMins, Mins);
    Progs.SetFieldVector(E, FFMaxs, Maxs);
    Progs.SetFieldVector(E, Progs.FieldOfs('size'), Maxs - Mins);
  end;
  LinkEdict(E);
end;

procedure TQuakeQcGame.SetSize(const Progs: TQuakeProgs; const E: Integer; const Mins, Maxs: TVector3);
begin
  inherited SetSize(Progs, E, Mins, Maxs);
  LinkEdict(E);
  if IsClient(E) then
  begin
    FClients[E].Phys.Mins := Mins;
    FClients[E].Phys.Maxs := Maxs;
  end;
end;

procedure TQuakeQcGame.Sound(const Progs: TQuakeProgs; const E, Channel: Integer; const Sample: String;
  const Volume, Attenuation: Single);
begin
  if Assigned(OnSound) then
    OnSound(E, Channel, 'sound/' + Sample, Volume, Attenuation, Progs.FieldVector(E, FFOrigin) +
      (Progs.FieldVector(E, FFMins) + Progs.FieldVector(E, FFMaxs)) * 0.5);
end;

procedure TQuakeQcGame.TraceLine(const Progs: TQuakeProgs; const Start, Stop: TVector3; const NoMonsters: Integer;
  const Ignore: Integer; out Fraction: Single; out EndPos, Normal: TVector3; out HitEntity: Integer;
  out AllSolid, StartSolid, InOpen, InWater: Boolean);
var
  T: TQuakeTrace;
  C: Integer;
begin
  if NoMonsters = MOVE_MISSILE then
    T := TraceBox(Start, Stop, Vector3(-15, -15, -15), Vector3(15, 15, 15), MOVE_NORMAL, Ignore)
  else
    T := TraceBox(Start, Stop, TVector3.Zero, TVector3.Zero, NoMonsters, Ignore);
  Fraction := T.Fraction;
  EndPos := T.EndPos;
  Normal := T.PlaneNormal;
  HitEntity := T.Entity;
  AllSolid := T.AllSolid;
  StartSolid := T.StartSolid;
  C := FBsp.PointContents(EndPos);
  InWater := C < CONTENTS_SOLID; { water, slime, lava }
  InOpen := C = CONTENTS_EMPTY;
end;

function TQuakeQcGame.WalkMove(const Progs: TQuakeProgs; const E: Integer; const Yaw, Dist: Single): Boolean;
var
  Move, OldOrg, NewOrg, Stop, Mins, Maxs: TVector3;
  Flags: Integer;
  T: TQuakeTrace;
begin
  { SV_movestep: fliers and swimmers move straight, walkers step up and
    down and never off a ledge }
  Result := False;
  SinCos(DegToRad(Yaw), Move.Y, Move.X);
  Move := Move * Dist;
  Move.Z := 0;
  OldOrg := Progs.FieldVector(E, FFOrigin);
  Mins := Progs.FieldVector(E, FFMins);
  Maxs := Progs.FieldVector(E, FFMaxs);
  Flags := Round(Progs.Field(E, FFFlags)^.F);

  if (Flags and (FL_SWIM or FL_FLY)) <> 0 then
  begin
    NewOrg := OldOrg + Move;
    T := TraceBox(OldOrg, NewOrg, Mins, Maxs, MOVE_NORMAL, E);
    if T.Fraction < 1 then
      Exit;
    Progs.SetFieldVector(E, FFOrigin, T.EndPos);
    LinkEdict(E);
    Exit(True);
  end;

  NewOrg := OldOrg + Move;
  NewOrg.Z := NewOrg.Z + StepHeight;
  Stop := NewOrg;
  Stop.Z := Stop.Z - StepHeight * 2;
  T := TraceBox(NewOrg, Stop, Mins, Maxs, MOVE_NORMAL, E);
  if T.AllSolid then
    Exit;
  if T.StartSolid then
  begin
    NewOrg.Z := NewOrg.Z - StepHeight;
    T := TraceBox(NewOrg, Stop, Mins, Maxs, MOVE_NORMAL, E);
    if T.AllSolid or T.StartSolid then
      Exit;
  end;
  if T.Fraction = 1 then
  begin
    { Walked off an edge: only allowed when already hanging over }
    if (Flags and FL_PARTIALGROUND) <> 0 then
    begin
      Progs.SetFieldVector(E, FFOrigin, OldOrg + Move);
      LinkEdict(E);
      Exit(True);
    end;
    Exit;
  end;
  Progs.SetFieldVector(E, FFOrigin, T.EndPos);
  if not CheckBottom(Progs, E) then
  begin
    if (Flags and FL_PARTIALGROUND) <> 0 then
    begin
      LinkEdict(E);
      Exit(True);
    end;
    Progs.SetFieldVector(E, FFOrigin, OldOrg);
    Exit;
  end;
  Progs.Field(E, FFFlags)^.F := Flags and not FL_PARTIALGROUND;
  Progs.Field(E, FFGroundEntity)^.I := T.Entity;
  LinkEdict(E);
  Result := True;
end;

procedure TQuakeQcGame.MoveToGoal(const Progs: TQuakeProgs; const E: Integer; const Dist: Single);
const
  Detours: array[0..4] of Single = (45, -45, 90, -90, 180);
var
  Goal, I: Integer;
  Dir, GoalMins, GoalMaxs, Mins, Maxs: TVector3;
  Yaw: Single;
begin
  { SV_MoveToGoal: stop when the enemy is in reach, else step with a few
    detours when blocked (SV_NewChaseDir, simplified) }
  Goal := Progs.Field(E, FFGoalEntity)^.I;
  if Goal <= 0 then
    Exit;
  if (Progs.Field(E, FFEnemy)^.I <> 0) and EntityBox(Goal, GoalMins, GoalMaxs) and EntityBox(E, Mins, Maxs) then
  begin
    { SV_CloseEnough }
    if (GoalMins.X <= Maxs.X + Dist) and (GoalMaxs.X >= Mins.X - Dist) and
       (GoalMins.Y <= Maxs.Y + Dist) and (GoalMaxs.Y >= Mins.Y - Dist) and
       (GoalMins.Z <= Maxs.Z + Dist) and (GoalMaxs.Z >= Mins.Z - Dist) then
      Exit;
  end;
  Dir := Progs.FieldVector(Goal, FFOrigin) - Progs.FieldVector(E, FFOrigin);
  if (Dir.X = 0) and (Dir.Y = 0) then
    Exit;
  Yaw := RadToDeg(ArcTan2(Dir.Y, Dir.X));
  Progs.Field(E, FFIdealYaw)^.F := Yaw;
  if WalkMove(Progs, E, Yaw, Dist) then
    Exit;
  for I := 0 to High(Detours) do
    if WalkMove(Progs, E, Yaw + Detours[I], Dist) then
      Exit;
end;

function TQuakeQcGame.DropToFloor(const Progs: TQuakeProgs; const E: Integer): Boolean;
var
  Org, Stop: TVector3;
  T: TQuakeTrace;
begin
  Org := Progs.FieldVector(E, FFOrigin);
  Stop := Org - Vector3(0, 0, 256);
  T := TraceBox(Org, Stop, Progs.FieldVector(E, FFMins), Progs.FieldVector(E, FFMaxs), MOVE_NORMAL, E);
  if (T.Fraction = 1) or T.AllSolid then
    Exit(False);
  Progs.SetFieldVector(E, FFOrigin, T.EndPos);
  LinkEdict(E);
  Progs.Field(E, FFFlags)^.F := Round(Progs.Field(E, FFFlags)^.F) or FL_ONGROUND;
  Progs.Field(E, FFGroundEntity)^.I := T.Entity;
  Result := True;
end;

function TQuakeQcGame.CheckBottom(const Progs: TQuakeProgs; const E: Integer): Boolean;
var
  Mins, Maxs, Start, Stop: TVector3;
  X, Y: Integer;
  Mid, Bottom: Single;
  T: TQuakeTrace;
  RealCheck: Boolean;
begin
  { SV_CheckBottom: all four corners on solid ground, else at least the
    middle, with no corner more than a step below }
  if not EntityBox(E, Mins, Maxs) then
    Exit(False);
  RealCheck := False;
  Start.Z := Mins.Z - 1;
  for X := 0 to 1 do
    for Y := 0 to 1 do
    begin
      if X = 0 then
        Start.X := Mins.X
      else
        Start.X := Maxs.X;
      if Y = 0 then
        Start.Y := Mins.Y
      else
        Start.Y := Maxs.Y;
      if FBsp.PointContents(Start) <> CONTENTS_SOLID then
        RealCheck := True;
    end;
  if not RealCheck then
    Exit(True);

  Start.Z := Mins.Z;
  Start.X := (Mins.X + Maxs.X) * 0.5;
  Start.Y := (Mins.Y + Maxs.Y) * 0.5;
  Stop := Start;
  Stop.Z := Start.Z - 2 * StepHeight;
  T := PointTrace(Start, Stop, E);
  if T.Fraction = 1 then
    Exit(False);
  Mid := T.EndPos.Z;
  Bottom := Mid;
  for X := 0 to 1 do
    for Y := 0 to 1 do
    begin
      if X = 0 then
        Start.X := Mins.X
      else
        Start.X := Maxs.X;
      if Y = 0 then
        Start.Y := Mins.Y
      else
        Start.Y := Maxs.Y;
      Stop.X := Start.X;
      Stop.Y := Start.Y;
      T := PointTrace(Start, Stop, E);
      if (T.Fraction <> 1) and (T.EndPos.Z > Bottom) then
        Bottom := T.EndPos.Z;
      if (T.Fraction = 1) or (Mid - T.EndPos.Z > StepHeight) then
        Exit(False);
    end;
  Result := True;
end;

function TQuakeQcGame.PointContents(const Progs: TQuakeProgs; const P: TVector3): Integer;
begin
  Result := FBsp.PointContents(P);
end;

procedure TQuakeQcGame.LightStyle(const Progs: TQuakeProgs; const Style: Integer; const Value: String);
begin
  if (Style >= 0) and (Style <= High(FLightStyles)) then
    FLightStyles[Style] := Value;
  if Lighting <> nil then
    Lighting.SetStyle(Style, Value);
  if Assigned(OnLightStyle) then
    OnLightStyle(Style, Value);
end;

procedure TQuakeQcGame.Particle(const Progs: TQuakeProgs; const Org, Dir: TVector3; const Color, Count: Integer);
var
  C: TVector4Byte;
begin
  if Assigned(OnParticle) then
    OnParticle(Org, Dir, Color, Count);
  if Particles = nil then
    Exit;
  if (Color >= 64) and (Color <= 79) then
    Particles.SpawnBlood(QuakeToCge(Org), QuakeToCge(Dir))
  else
  begin
    C := Palette.Color(Color and 255);
    Particles.SpawnTrail(QuakeToCge(Org), Vector3(C.X / 255, C.Y / 255, C.Z / 255));
  end;
end;

procedure TQuakeQcGame.CenterPrint(const Progs: TQuakeProgs; const E: Integer; const S: String);
begin
  if Assigned(OnCenterPrint) then
    OnCenterPrint(E, S);
end;

procedure TQuakeQcGame.Print(const Progs: TQuakeProgs; const S: String);
begin
  WritelnLog('QuakeC', Trim(S));
  if Assigned(OnPrint) then
    OnPrint(S);
end;

procedure TQuakeQcGame.AmbientSound(const Progs: TQuakeProgs; const Org: TVector3; const Sample: String;
  const Volume, Attenuation: Single);
begin
  if Assigned(OnAmbient) then
    OnAmbient(Org, 'sound/' + Sample, Volume);
end;

procedure TQuakeQcGame.ChangeLevel(const Progs: TQuakeProgs; const Map: String);
begin
  if FLevelChange = '' then
  begin
    FLevelChange := Map;
    if FFnSetChangeParms > 0 then
      Progs.CallWith(FFnSetChangeParms, 1);
  end;
end;

function TQuakeQcGame.Cvar(const Progs: TQuakeProgs; const Name: String): Single;
begin
  if Name = 'skill' then
    Result := FSkill
  else if Name = 'deathmatch' then
    Result := FDeathmatch
  else if Name = 'sv_gravity' then
    Result := SvGravity
  else if Name = 'registered' then
    Result := 1
  else
    Result := 0;
end;

procedure TQuakeQcGame.MakeStatic(const Progs: TQuakeProgs; const E: Integer);
begin
  SetLength(FStatics, Length(FStatics) + 1);
  FStatics[High(FStatics)].Model := Progs.FieldString(E, FFModel);
  FStatics[High(FStatics)].Origin := Progs.FieldVector(E, FFOrigin);
  FStatics[High(FStatics)].Angles := Progs.FieldVector(E, FFAngles);
  FStatics[High(FStatics)].Frame := Round(Progs.Field(E, FFFrame)^.F);
  FStatics[High(FStatics)].Skin := Round(Progs.Field(E, FFSkin)^.F);
  Progs.FreeEdict(E);
end;

procedure TQuakeQcGame.StuffCmd(const Progs: TQuakeProgs; const E: Integer; const Cmd: String);
begin
  if Assigned(OnStuffCmd) then
    OnStuffCmd(E, Trim(Cmd));
end;

procedure TQuakeQcGame.WriteMessage(const Progs: TQuakeProgs; const Dest, Kind: Integer; const Value: TVector3;
  const S: String);
var
  V, I: Integer;

  procedure RawByte(const B: Integer);
  begin
    SetLength(FMessageRaw, Length(FMessageRaw) + 1);
    FMessageRaw[High(FMessageRaw)] := Byte(B and 255);
  end;

begin
  { The progs write svc messages byte by byte; collect and act on the
    complete ones, and keep the protocol bytes for the network clients }
  if Length(FMessageBytes) = 0 then
    FMessageDest := Dest;
  if Kind = 58 then
  begin
    FMessageStrings.Add(S);
    SetLength(FMessageBytes, Length(FMessageBytes) + 1);
    FMessageBytes[High(FMessageBytes)] := -1000 - (FMessageStrings.Count - 1);
    for I := 1 to Length(S) do
      RawByte(Ord(S[I]));
    RawByte(0);
  end else
  begin
    SetLength(FMessageBytes, Length(FMessageBytes) + 1);
    if Kind = 56 then
      FMessageBytes[High(FMessageBytes)] := Round(Value.X * 8) { coords keep their precision }
    else
      FMessageBytes[High(FMessageBytes)] := Round(Value.X);
    case Kind of
      52, 53: RawByte(Round(Value.X));                     { byte, char }
      54, 59: begin V := Round(Value.X); RawByte(V); RawByte(V shr 8); end; { short, entity }
      55: begin V := Round(Value.X); RawByte(V); RawByte(V shr 8); RawByte(V shr 16); RawByte(V shr 24); end;
      56: begin V := Round(Value.X * 8); RawByte(V); RawByte(V shr 8); end; { coord }
      57: RawByte(Round(Value.X * 256 / 360) and 255);      { angle }
    end;
  end;
  HandleMessage;
end;

function TQuakeQcGame.MessageTarget: Integer;
var
  MsgEntity: Integer;
begin
  { MSG_ONE goes to msg_entity's client, the rest to everyone }
  Result := 0;
  if FMessageDest = 1 then
  begin
    MsgEntity := FProgs.GlobalOfs('msg_entity');
    if MsgEntity >= 0 then
      Result := FProgs.Global(MsgEntity)^.I;
    if not IsClient(Result) then
      Result := 0;
  end;
end;

procedure TQuakeQcGame.HandleMessage;
var
  N, E: Integer;

  function Coord(const I: Integer): Single;
  begin
    Result := FMessageBytes[I] / 8;
  end;

  procedure Done;
  begin
    if Assigned(OnMessage) then
      OnMessage(MessageTarget, FMessageRaw);
    SetLength(FMessageBytes, 0);
    SetLength(FMessageRaw, 0);
    FMessageStrings.Clear;
  end;

begin
  N := Length(FMessageBytes);
  if N = 0 then
    Exit;
  case FMessageBytes[0] of
    svc_damage:
      if N >= 6 then
      begin
        if Assigned(OnDamage) then
          OnDamage(MessageTarget, FMessageBytes[1], FMessageBytes[2]);
        Done;
      end;
    svc_temp_entity:
      if N >= 2 then
      begin
        case FMessageBytes[1] of
          5, 6, 9, 13: { lightning and beams: entity, start, end }
            if N >= 9 then
            begin
              if Assigned(OnTempEntity) then
                OnTempEntity(FMessageBytes[1], Vector3(Coord(3), Coord(4), Coord(5)),
                  Vector3(Coord(6), Coord(7), Coord(8)), FMessageBytes[2]);
              Done;
            end;
          12: { explosion2: position, color start, length }
            if N >= 7 then
            begin
              if Assigned(OnTempEntity) then
                OnTempEntity(3, Vector3(Coord(2), Coord(3), Coord(4)), TVector3.Zero, 0);
              Done;
            end;
          else
            if N >= 5 then
            begin
              if Assigned(OnTempEntity) then
                OnTempEntity(FMessageBytes[1], Vector3(Coord(2), Coord(3), Coord(4)), TVector3.Zero, 0);
              Done;
            end;
        end;
      end;
    svc_killedmonster, svc_foundsecret, svc_sellscreen:
      Done;
    svc_intermission:
      begin
        FIntermission := True;
        if Assigned(OnIntermission) then
          OnIntermission('');
        Done;
      end;
    svc_finale:
      if N >= 2 then
      begin
        FIntermission := True;
        if Assigned(OnIntermission) and (FMessageStrings.Count > 0) then
          OnIntermission(FMessageStrings[0]);
        Done;
      end;
    svc_setangle:
      if N >= 4 then
      begin
        E := MessageTarget;
        if E = 0 then
          E := 1;
        FProgs.SetFieldVector(E, FFAngles, Vector3(FMessageBytes[1], FMessageBytes[2], FMessageBytes[3]));
        FProgs.Field(E, FFFixAngle)^.F := 1;
        Done;
      end;
    svc_cdtrack:
      if N >= 3 then
        Done;
    else
      { Unknown: drop it when it grows }
      if N > 32 then
        Done;
  end;
end;

{ Accessors }

function TQuakeQcGame.StaticCount: Integer;
begin
  Result := Length(FStatics);
end;

function TQuakeQcGame.Static(const I: Integer): TQcStatic;
begin
  Result := FStatics[I];
end;

function TQuakeQcGame.PlayerHealth: Integer;
begin
  Result := PlayerHealth(1);
end;

function TQuakeQcGame.PlayerArmor: Integer;
begin
  Result := PlayerArmor(1);
end;

function TQuakeQcGame.PlayerItems: Cardinal;
begin
  Result := PlayerItems(1);
end;

function TQuakeQcGame.PlayerAmmo(const Kind: Integer): Integer;
begin
  Result := PlayerAmmo(1, Kind);
end;

function TQuakeQcGame.PlayerWeapon: Cardinal;
begin
  Result := PlayerWeapon(1);
end;

function TQuakeQcGame.PlayerWeaponModel: String;
begin
  Result := PlayerWeaponModel(1);
end;

function TQuakeQcGame.PlayerWeaponFrame: Integer;
begin
  Result := PlayerWeaponFrame(1);
end;

function TQuakeQcGame.PlayerViewOfs: TVector3;
begin
  Result := PlayerViewOfs(1);
end;

function TQuakeQcGame.PlayerDead: Boolean;
begin
  Result := PlayerDead(1);
end;

function TQuakeQcGame.PlayerEffects: Integer;
begin
  Result := PlayerEffects(1);
end;

function TQuakeQcGame.PlayerHealth(const E: Integer): Integer;
begin
  Result := Round(FProgs.Field(E, FFHealth)^.F);
end;

function TQuakeQcGame.PlayerArmor(const E: Integer): Integer;
begin
  Result := Round(FProgs.Field(E, FFArmorValue)^.F);
end;

function TQuakeQcGame.PlayerItems(const E: Integer): Cardinal;
begin
  Result := Cardinal(Round(FProgs.Field(E, FFItems)^.F));
end;

function TQuakeQcGame.PlayerAmmo(const E, Kind: Integer): Integer;
begin
  case Kind of
    1: Result := Round(FProgs.Field(E, FFAmmoShells)^.F);
    2: Result := Round(FProgs.Field(E, FFAmmoNails)^.F);
    3: Result := Round(FProgs.Field(E, FFAmmoRockets)^.F);
    4: Result := Round(FProgs.Field(E, FFAmmoCells)^.F);
    else Result := Round(FProgs.Field(E, FFCurrentAmmo)^.F);
  end;
end;

function TQuakeQcGame.PlayerWeapon(const E: Integer): Cardinal;
begin
  Result := Cardinal(Round(FProgs.Field(E, FFWeapon)^.F));
end;

function TQuakeQcGame.PlayerWeaponModel(const E: Integer): String;
begin
  Result := FProgs.FieldString(E, FFWeaponModel);
end;

function TQuakeQcGame.PlayerWeaponFrame(const E: Integer): Integer;
begin
  Result := Round(FProgs.Field(E, FFWeaponFrame)^.F);
end;

function TQuakeQcGame.PlayerViewOfs(const E: Integer): TVector3;
begin
  Result := FProgs.FieldVector(E, FFViewOfs);
end;

function TQuakeQcGame.PlayerDead(const E: Integer): Boolean;
begin
  Result := (FProgs.Field(E, FFDeadFlag)^.F <> 0) or (PlayerHealth(E) <= 0);
end;

function TQuakeQcGame.PlayerEffects(const E: Integer): Integer;
begin
  Result := Round(FProgs.Field(E, FFEffects)^.F);
end;

function TQuakeQcGame.PlayerFrags(const E: Integer): Integer;
begin
  Result := Round(FProgs.Field(E, FFFrags)^.F);
end;

function TQuakeQcGame.PlayerVelocity(const E: Integer): TVector3;
begin
  Result := FProgs.FieldVector(E, FFVelocity);
end;

function TQuakeQcGame.PlayerOnGround(const E: Integer): Boolean;
begin
  Result := (Round(FProgs.Field(E, FFFlags)^.F) and FL_ONGROUND) <> 0;
end;

function TQuakeQcGame.PlayerWaterLevel(const E: Integer): Integer;
begin
  Result := Round(FProgs.Field(E, FFWaterLevel)^.F);
end;

function TQuakeQcGame.EntityModel(const E: Integer): String;
begin
  Result := FProgs.FieldString(E, FFModel);
end;

function TQuakeQcGame.EntityOrigin(const E: Integer): TVector3;
begin
  Result := FProgs.FieldVector(E, FFOrigin);
end;

function TQuakeQcGame.EntityAngles(const E: Integer): TVector3;
begin
  Result := FProgs.FieldVector(E, FFAngles);
end;

function TQuakeQcGame.EntityFrame(const E: Integer): Integer;
begin
  Result := Round(FProgs.Field(E, FFFrame)^.F);
end;

function TQuakeQcGame.EntitySkin(const E: Integer): Integer;
begin
  Result := Round(FProgs.Field(E, FFSkin)^.F);
end;

function TQuakeQcGame.EntityEffects(const E: Integer): Integer;
begin
  Result := Round(FProgs.Field(E, FFEffects)^.F);
end;

function TQuakeQcGame.EntityVisible(const E: Integer): Boolean;
begin
  Result := not FProgs.EdictFree(E) and (FProgs.Field(E, FFModelIndex)^.F > 0) and
    (FProgs.FieldString(E, FFModel) <> '');
end;

function TQuakeQcGame.KilledMonsters: Integer;
begin
  Result := Round(FProgs.Global(FProgs.GKilledMonsters)^.F);
end;

function TQuakeQcGame.TotalMonsters: Integer;
begin
  Result := Round(FProgs.Global(FProgs.GTotalMonsters)^.F);
end;

function TQuakeQcGame.FoundSecrets: Integer;
begin
  Result := Round(FProgs.Global(FProgs.GlobalOfs('found_secrets'))^.F);
end;

function TQuakeQcGame.TotalSecrets: Integer;
begin
  Result := Round(FProgs.Global(FProgs.GTotalSecrets)^.F);
end;

end.
