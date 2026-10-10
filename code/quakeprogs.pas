{ QuakeC virtual machine: loads progs.dat (version 6) and runs its bytecode
  like pr_exec.c, with the entity memory of pr_edict.c and the builtins of
  pr_cmds.c. World builtins (traces, sounds, models...) go through
  TQuakeProgsHost so the game can bind them; the default host only logs. }
unit QuakeProgs;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, Math,
  CastleVectors, CastleLog, CastleUtils,
  QuakePak, QuakeBsp;

const
  ProgsVersion = 6;
  MaxEdicts = 600;
  MaxProgStack = 32;
  LocalStackSize = 2048;
  MaxRunaway = 100000;

  { Globals: return value and the 8 parameters (3 cells each) }
  OFS_NULL = 0;
  OFS_RETURN = 1;
  OFS_PARM0 = 4;
  RESERVED_OFS = 28;

  { ddef_t types }
  ev_void = 0;
  ev_string = 1;
  ev_float = 2;
  ev_vector = 3;
  ev_entity = 4;
  ev_field = 5;
  ev_function = 6;
  ev_pointer = 7;
  DEF_SAVEGLOBAL = 1 shl 15;

  { Opcodes }
  OP_DONE = 0;
  OP_MUL_F = 1;
  OP_MUL_V = 2;
  OP_MUL_FV = 3;
  OP_MUL_VF = 4;
  OP_DIV_F = 5;
  OP_ADD_F = 6;
  OP_ADD_V = 7;
  OP_SUB_F = 8;
  OP_SUB_V = 9;
  OP_EQ_F = 10;
  OP_EQ_V = 11;
  OP_EQ_S = 12;
  OP_EQ_E = 13;
  OP_EQ_FNC = 14;
  OP_NE_F = 15;
  OP_NE_V = 16;
  OP_NE_S = 17;
  OP_NE_E = 18;
  OP_NE_FNC = 19;
  OP_LE = 20;
  OP_GE = 21;
  OP_LT = 22;
  OP_GT = 23;
  OP_LOAD_F = 24;
  OP_LOAD_V = 25;
  OP_LOAD_S = 26;
  OP_LOAD_ENT = 27;
  OP_LOAD_FLD = 28;
  OP_LOAD_FNC = 29;
  OP_ADDRESS = 30;
  OP_STORE_F = 31;
  OP_STORE_V = 32;
  OP_STORE_S = 33;
  OP_STORE_ENT = 34;
  OP_STORE_FLD = 35;
  OP_STORE_FNC = 36;
  OP_STOREP_F = 37;
  OP_STOREP_V = 38;
  OP_STOREP_S = 39;
  OP_STOREP_ENT = 40;
  OP_STOREP_FLD = 41;
  OP_STOREP_FNC = 42;
  OP_RETURN = 43;
  OP_NOT_F = 44;
  OP_NOT_V = 45;
  OP_NOT_S = 46;
  OP_NOT_ENT = 47;
  OP_NOT_FNC = 48;
  OP_IF = 49;
  OP_IFNOT = 50;
  OP_CALL0 = 51;
  OP_CALL8 = 59;
  OP_STATE = 60;
  OP_GOTO = 61;
  OP_AND = 62;
  OP_OR = 63;
  OP_BITAND = 64;
  OP_BITOR = 65;

type
  TProgStatement = packed record
    Op: Word;
    A, B, C: SmallInt;
  end;

  TProgDef = packed record
    DefType: Word;
    Ofs: Word;
    SName: LongInt;
  end;

  TProgFunction = packed record
    FirstStatement: LongInt; { negative = builtin number }
    ParmStart: LongInt;
    Locals: LongInt;
    Profile: LongInt;
    SName: LongInt;
    SFile: LongInt;
    NumParms: LongInt;
    ParmSize: array[0..7] of Byte;
  end;

  TProgsHeader = packed record
    Version, Crc: LongInt;
    OfsStatements, NumStatements: LongInt;
    OfsGlobalDefs, NumGlobalDefs: LongInt;
    OfsFieldDefs, NumFieldDefs: LongInt;
    OfsFunctions, NumFunctions: LongInt;
    OfsStrings, NumStrings: LongInt;
    OfsGlobals, NumGlobals: LongInt;
    EntityFields: LongInt;
  end;

  { A 4-byte VM cell: float, int (entity / string / function / field) }
  PProgCell = ^TProgCell;
  TProgCell = record
    case Integer of
      0: (F: Single);
      1: (I: LongInt);
  end;

  TQuakeProgs = class;

  { What the QuakeC world builtins need from the game. The default
    implementation keeps the VM self contained (no traces, flat floor). }
  TQuakeProgsHost = class
  public
    procedure SetOrigin(const Progs: TQuakeProgs; const E: Integer; const Org: TVector3); virtual;
    procedure SetModel(const Progs: TQuakeProgs; const E: Integer; const Model: String); virtual;
    procedure SetSize(const Progs: TQuakeProgs; const E: Integer; const Mins, Maxs: TVector3); virtual;
    procedure Sound(const Progs: TQuakeProgs; const E, Channel: Integer; const Sample: String;
      const Volume, Attenuation: Single); virtual;
    { TraceLine: returns the fraction, end position, normal and the entity hit (0 = none / world) }
    procedure TraceLine(const Progs: TQuakeProgs; const Start, Stop: TVector3; const NoMonsters: Integer;
      const Ignore: Integer; out Fraction: Single; out EndPos, Normal: TVector3; out HitEntity: Integer;
      out AllSolid, StartSolid, InOpen, InWater: Boolean); virtual;
    function WalkMove(const Progs: TQuakeProgs; const E: Integer; const Yaw, Dist: Single): Boolean; virtual;
    { SV_MoveToGoal: a step of Dist towards self.goalentity }
    procedure MoveToGoal(const Progs: TQuakeProgs; const E: Integer; const Dist: Single); virtual;
    function DropToFloor(const Progs: TQuakeProgs; const E: Integer): Boolean; virtual;
    function CheckBottom(const Progs: TQuakeProgs; const E: Integer): Boolean; virtual;
    function PointContents(const Progs: TQuakeProgs; const P: TVector3): Integer; virtual;
    procedure LightStyle(const Progs: TQuakeProgs; const Style: Integer; const Value: String); virtual;
    procedure Particle(const Progs: TQuakeProgs; const Org, Dir: TVector3; const Color, Count: Integer); virtual;
    procedure CenterPrint(const Progs: TQuakeProgs; const E: Integer; const S: String); virtual;
    procedure Print(const Progs: TQuakeProgs; const S: String); virtual;
    procedure AmbientSound(const Progs: TQuakeProgs; const Org: TVector3; const Sample: String;
      const Volume, Attenuation: Single); virtual;
    procedure ChangeLevel(const Progs: TQuakeProgs; const Map: String); virtual;
    function Cvar(const Progs: TQuakeProgs; const Name: String): Single; virtual;
    procedure CvarSet(const Progs: TQuakeProgs; const Name, Value: String); virtual;
    procedure MakeStatic(const Progs: TQuakeProgs; const E: Integer); virtual;
    procedure StuffCmd(const Progs: TQuakeProgs; const E: Integer; const Cmd: String); virtual;
    procedure LocalCmd(const Progs: TQuakeProgs; const Cmd: String); virtual;
    procedure WriteMessage(const Progs: TQuakeProgs; const Dest, Kind: Integer; const Value: TVector3;
      const S: String); virtual;
  end;

  TProgsBuiltin = procedure of object;

  TProgsStatistics = record
    Spawned, Removed, Thinks, Calls: Int64;
  end;

  TQuakeProgs = class
  private
    FStatements: array of TProgStatement;
    FGlobalDefs, FFieldDefs: array of TProgDef;
    FFunctions: array of TProgFunction;
    FStrings: AnsiString;
    FGlobals: array of TProgCell;
    FEntityFields: Integer;
    FEdicts: array of TProgCell;   { MaxEdicts * FEntityFields }
    FEdictFree: array of Boolean;
    FEdictFreeTime: array of Single;
    FNumEdicts: Integer;
    FDynStrings: TStringList;      { engine made strings, referenced as negative offsets }
    FTempStrings: array[0..15] of Integer;
    FTempNext: Integer;
    FBuiltins: array[0..127] of TProgsBuiltin;
    FHost: TQuakeProgsHost;
    FOwnsHost: Boolean;
    FCrc: Integer;
    { execution }
    FStack: array[0..MaxProgStack - 1] of record S, F: Integer; end;
    FDepth: Integer;
    FLocalStack: array[0..LocalStackSize - 1] of TProgCell;
    FLocalStackUsed: Integer;
    FCurrentFunction: Integer;
    FXStatement: Integer;
    FTrace: Boolean;
    FArgC: Integer;
    FCurrentBuiltin: Integer;
    FAborted: Boolean;
    FGlobalNames: specialize TDictionary<String, Integer>;
    FFieldNames: specialize TDictionary<String, Integer>;
    FFunctionNames: specialize TDictionary<String, Integer>;
    { well known globals }
    FGSelf, FGOther, FGWorld, FGTime, FGFrameTime, FGForceRetouch, FGMapName, FGDeathmatch, FGCoop,
    FGTeamplay, FGServerFlags, FGTotalSecrets, FGTotalMonsters, FGFoundSecrets, FGKilledMonsters,
    FGParm1, FGTraceAllSolid, FGTraceStartSolid, FGTraceFraction, FGTraceEndPos, FGTracePlaneNormal,
    FGTracePlaneDist, FGTraceEnt, FGTraceInOpen, FGTraceInWater, FGMsgEntity, FGVForward, FGVUp,
    FGVRight, FGSkill: Integer;
    { well known fields }
    FFModelIndex, FFOrigin, FFOldOrigin, FFAngles, FFClassName, FFModel, FFFrame, FFSkin, FFEffects,
    FFMins, FFMaxs, FFSize, FFSolid, FFMoveType, FFHealth, FFNextThink, FFThink, FFTouch, FFUse,
    FFBlocked, FFChain, FFTargetName, FFTarget, FFOwner, FFVelocity, FFFlags, FFGroundEntity, FFAbsMin,
    FFAbsMax, FFEnemy, FFIdealYaw, FFYawSpeed, FFNetName, FFMessage, FFSounds, FFSpawnFlags: Integer;
    procedure Error(const Msg: String);
    function EnterFunction(const F: Integer): Integer;
    function LeaveFunction: Integer;
    procedure RegisterBuiltins;
    procedure SetupWellKnown;
    { builtins }
    procedure PF_makevectors;
    procedure PF_setorigin;
    procedure PF_setmodel;
    procedure PF_setsize;
    procedure PF_break;
    procedure PF_random;
    procedure PF_sound;
    procedure PF_normalize;
    procedure PF_error;
    procedure PF_objerror;
    procedure PF_vlen;
    procedure PF_vectoyaw;
    procedure PF_spawn;
    procedure PF_remove;
    procedure PF_traceline;
    procedure PF_checkclient;
    procedure PF_find;
    procedure PF_precache;
    procedure PF_stuffcmd;
    procedure PF_findradius;
    procedure PF_bprint;
    procedure PF_sprint;
    procedure PF_dprint;
    procedure PF_ftos;
    procedure PF_vtos;
    procedure PF_coredump;
    procedure PF_traceon;
    procedure PF_traceoff;
    procedure PF_eprint;
    procedure PF_walkmove;
    procedure PF_droptofloor;
    procedure PF_lightstyle;
    procedure PF_rint;
    procedure PF_floor;
    procedure PF_ceil;
    procedure PF_checkbottom;
    procedure PF_pointcontents;
    procedure PF_fabs;
    procedure PF_aim;
    procedure PF_cvar;
    procedure PF_localcmd;
    procedure PF_nextent;
    procedure PF_particle;
    procedure PF_changeyaw;
    procedure PF_vectoangles;
    procedure PF_WriteByte;
    procedure PF_WriteChar;
    procedure PF_WriteShort;
    procedure PF_WriteLong;
    procedure PF_WriteCoord;
    procedure PF_WriteAngle;
    procedure PF_WriteString;
    procedure PF_WriteEntity;
    procedure PF_movetogoal;
    procedure PF_makestatic;
    procedure PF_changelevel;
    procedure PF_cvar_set;
    procedure PF_centerprint;
    procedure PF_ambientsound;
    procedure PF_setspawnparms;
    procedure PF_Fixme;
  public
    { Counters of what the builtins were asked (tests, logs) }
    PrecachedModels, PrecachedSounds: TStringList;
    Statistics: TProgsStatistics;

    constructor Create(const AHost: TQuakeProgsHost = nil);
    destructor Destroy; override;

    { Load progs.dat from the PAKs (PR_LoadProgs) }
    function Load(const Path: String = 'progs.dat'): Boolean;
    function Loaded: Boolean;

    { Strings: offsets into the progs strings, negative for engine strings }
    function GetString(const Ofs: Integer): String;
    function NewString(const S: String): Integer;   { permanent }
    function TempString(const S: String): Integer;  { reused after 16 }

    { Globals and entity fields by offset }
    function Global(const Ofs: Integer): PProgCell; inline;
    function GlobalVector(const Ofs: Integer): TVector3;
    procedure SetGlobalVector(const Ofs: Integer; const V: TVector3);
    function Field(const E, Ofs: Integer): PProgCell; inline;
    function FieldVector(const E, Ofs: Integer): TVector3;
    procedure SetFieldVector(const E, Ofs: Integer; const V: TVector3);
    function FieldString(const E, Ofs: Integer): String;

    { Lookups by name (-1 if missing) }
    function GlobalOfs(const Name: String): Integer;
    function FieldOfs(const Name: String): Integer;
    function FunctionIndex(const Name: String): Integer;
    function FunctionName(const F: Integer): String;

    { Entities (ED_Alloc / ED_Free) }
    function AllocEdict: Integer;
    procedure FreeEdict(const E: Integer);
    function EdictFree(const E: Integer): Boolean;
    property NumEdicts: Integer read FNumEdicts;
    function ParmString(const N: Integer): String;

    { Set a field from a map key / value (ED_ParseEpair); False if the
      field is unknown to the progs }
    function ParseEpair(const E: Integer; const Key, Value: String): Boolean;

    { ED_LoadFromFile: spawn the map's entities through their QuakeC spawn
      functions (worldspawn first). Skill and deathmatch filter the
      spawnflags like Quake. Returns the number of entities spawned. }
    function SpawnEntities(const Entities: TQuakeEntityList; const Skill: Integer): Integer;

    { PR_ExecuteProgram: run a function with the current globals }
    procedure Execute(const F: Integer);
    { Convenience: self = E, other = world, then call F }
    procedure CallWith(const F, E: Integer);
    procedure CallWithOther(const F, E, Other: Integer);
    { Keep edicts 1..N for the clients (SV_SpawnServer) }
    procedure ReserveEdicts(const N: Integer);
    { The whole VM state (globals, edicts, engine strings, precaches) for a
      savegame; LoadState needs the same progs.dat (crc) loaded }
    procedure SaveState(const S: TStream);
    function LoadState(const S: TStream): Boolean;

    { One server frame: StartFrame, then the thinks that are due
      (SV_Physics without movement); Time advances by FrameTime }
    procedure RunFrame(const FrameTime: Single);

    property Host: TQuakeProgsHost read FHost;
    property Crc: Integer read FCrc;
    property EntityFields: Integer read FEntityFields;
    { Well known global offsets }
    property GSelf: Integer read FGSelf;
    property GOther: Integer read FGOther;
    property GTime: Integer read FGTime;
    property GSkill: Integer read FGSkill;
    property GTotalMonsters: Integer read FGTotalMonsters;
    property GTotalSecrets: Integer read FGTotalSecrets;
    property GKilledMonsters: Integer read FGKilledMonsters;
    { Well known field offsets }
    property FOrigin: Integer read FFOrigin;
    property FAngles: Integer read FFAngles;
    property FClassName: Integer read FFClassName;
    property FModel: Integer read FFModel;
    property FFrame: Integer read FFFrame;
    property FHealth: Integer read FFHealth;
    property FNextThink: Integer read FFNextThink;
    property FThink: Integer read FFThink;
    property FMins: Integer read FFMins;
    property FMaxs: Integer read FFMaxs;
    property FSolid: Integer read FFSolid;
    property FMoveType: Integer read FFMoveType;
    property FVelocity: Integer read FFVelocity;
    property FFlags: Integer read FFFlags;
  end;

implementation

{ TQuakeProgsHost: the self contained defaults }

procedure TQuakeProgsHost.SetOrigin(const Progs: TQuakeProgs; const E: Integer; const Org: TVector3);
begin
  Progs.SetFieldVector(E, Progs.FOrigin, Org);
end;

procedure TQuakeProgsHost.SetModel(const Progs: TQuakeProgs; const E: Integer; const Model: String);
begin
  { The model index is its position in the precache list }
  if Progs.FFModelIndex >= 0 then
    Progs.Field(E, Progs.FFModelIndex)^.F := Progs.PrecachedModels.IndexOf(Model) + 1;
end;

procedure TQuakeProgsHost.SetSize(const Progs: TQuakeProgs; const E: Integer; const Mins, Maxs: TVector3);
begin
  Progs.SetFieldVector(E, Progs.FMins, Mins);
  Progs.SetFieldVector(E, Progs.FMaxs, Maxs);
  if Progs.FFSize >= 0 then
    Progs.SetFieldVector(E, Progs.FFSize, Maxs - Mins);
end;

procedure TQuakeProgsHost.Sound(const Progs: TQuakeProgs; const E, Channel: Integer; const Sample: String;
  const Volume, Attenuation: Single);
begin
end;

procedure TQuakeProgsHost.TraceLine(const Progs: TQuakeProgs; const Start, Stop: TVector3;
  const NoMonsters: Integer; const Ignore: Integer; out Fraction: Single; out EndPos, Normal: TVector3;
  out HitEntity: Integer; out AllSolid, StartSolid, InOpen, InWater: Boolean);
begin
  { Nothing in the way }
  Fraction := 1;
  EndPos := Stop;
  Normal := TVector3.Zero;
  HitEntity := 0;
  AllSolid := False;
  StartSolid := False;
  InOpen := True;
  InWater := False;
end;

function TQuakeProgsHost.WalkMove(const Progs: TQuakeProgs; const E: Integer; const Yaw, Dist: Single): Boolean;
var
  Org: TVector3;
begin
  Org := Progs.FieldVector(E, Progs.FOrigin);
  Org.X := Org.X + Cos(DegToRad(Yaw)) * Dist;
  Org.Y := Org.Y + Sin(DegToRad(Yaw)) * Dist;
  Progs.SetFieldVector(E, Progs.FOrigin, Org);
  Result := True;
end;

procedure TQuakeProgsHost.MoveToGoal(const Progs: TQuakeProgs; const E: Integer; const Dist: Single);
var
  Goal: Integer;
  Dir: TVector3;
begin
  Goal := Progs.Field(E, Progs.FieldOfs('goalentity'))^.I;
  if Goal <= 0 then
    Exit;
  Dir := Progs.FieldVector(Goal, Progs.FOrigin) - Progs.FieldVector(E, Progs.FOrigin);
  if (Dir.X = 0) and (Dir.Y = 0) then
    Exit;
  WalkMove(Progs, E, RadToDeg(ArcTan2(Dir.Y, Dir.X)), Dist);
end;

function TQuakeProgsHost.DropToFloor(const Progs: TQuakeProgs; const E: Integer): Boolean;
begin
  Result := True;
end;

function TQuakeProgsHost.CheckBottom(const Progs: TQuakeProgs; const E: Integer): Boolean;
begin
  Result := True;
end;

function TQuakeProgsHost.PointContents(const Progs: TQuakeProgs; const P: TVector3): Integer;
begin
  Result := CONTENTS_EMPTY;
end;

procedure TQuakeProgsHost.LightStyle(const Progs: TQuakeProgs; const Style: Integer; const Value: String);
begin
end;

procedure TQuakeProgsHost.Particle(const Progs: TQuakeProgs; const Org, Dir: TVector3; const Color, Count: Integer);
begin
end;

procedure TQuakeProgsHost.CenterPrint(const Progs: TQuakeProgs; const E: Integer; const S: String);
begin
  WritelnLog('QuakeC', 'centerprint: ' + S);
end;

procedure TQuakeProgsHost.Print(const Progs: TQuakeProgs; const S: String);
begin
  WritelnLog('QuakeC', Trim(S));
end;

procedure TQuakeProgsHost.AmbientSound(const Progs: TQuakeProgs; const Org: TVector3; const Sample: String;
  const Volume, Attenuation: Single);
begin
end;

procedure TQuakeProgsHost.ChangeLevel(const Progs: TQuakeProgs; const Map: String);
begin
  WritelnLog('QuakeC', 'changelevel ' + Map);
end;

function TQuakeProgsHost.Cvar(const Progs: TQuakeProgs; const Name: String): Single;
begin
  if Name = 'skill' then
    Result := Progs.Global(Progs.GSkill)^.F
  else if Name = 'sv_gravity' then
    Result := 800
  else if Name = 'registered' then
    Result := 1
  else
    Result := 0;
end;

procedure TQuakeProgsHost.CvarSet(const Progs: TQuakeProgs; const Name, Value: String);
begin
end;

procedure TQuakeProgsHost.MakeStatic(const Progs: TQuakeProgs; const E: Integer);
begin
  Progs.FreeEdict(E);
end;

procedure TQuakeProgsHost.StuffCmd(const Progs: TQuakeProgs; const E: Integer; const Cmd: String);
begin
end;

procedure TQuakeProgsHost.LocalCmd(const Progs: TQuakeProgs; const Cmd: String);
begin
end;

procedure TQuakeProgsHost.WriteMessage(const Progs: TQuakeProgs; const Dest, Kind: Integer; const Value: TVector3;
  const S: String);
begin
end;

{ TQuakeProgs }

constructor TQuakeProgs.Create(const AHost: TQuakeProgsHost);
begin
  inherited Create;
  if AHost = nil then
  begin
    FHost := TQuakeProgsHost.Create;
    FOwnsHost := True;
  end else
    FHost := AHost;
  FDynStrings := TStringList.Create;
  PrecachedModels := TStringList.Create;
  PrecachedSounds := TStringList.Create;
  FGlobalNames := specialize TDictionary<String, Integer>.Create;
  FFieldNames := specialize TDictionary<String, Integer>.Create;
  FFunctionNames := specialize TDictionary<String, Integer>.Create;
  RegisterBuiltins;
end;

destructor TQuakeProgs.Destroy;
begin
  if FOwnsHost then
    FHost.Free;
  FDynStrings.Free;
  PrecachedModels.Free;
  PrecachedSounds.Free;
  FGlobalNames.Free;
  FFieldNames.Free;
  FFunctionNames.Free;
  inherited Destroy;
end;

function TQuakeProgs.Loaded: Boolean;
begin
  Result := Length(FFunctions) > 0;
end;

function TQuakeProgs.Load(const Path: String): Boolean;
var
  Data: PByte;
  Size: Cardinal;
  H: TProgsHeader;
  I: Integer;

  function Fits(const Ofs, Count, ItemSize: LongInt): Boolean;
  begin
    Result := (Ofs >= 0) and (Count >= 0) and (Int64(Ofs) + Int64(Count) * ItemSize <= Size);
  end;

begin
  Result := False;
  Data := Pak.GetData(Path, Size);
  if (Data = nil) or (Size < SizeOf(TProgsHeader)) then
  begin
    WritelnWarning('QuakeProgs', '"%s" not found in the PAKs', [Path]);
    Exit;
  end;
  Move(Data^, H, SizeOf(H));
  if H.Version <> ProgsVersion then
  begin
    WritelnWarning('QuakeProgs', '"%s" has version %d, only %d is supported', [Path, H.Version, ProgsVersion]);
    Exit;
  end;
  if not (Fits(H.OfsStatements, H.NumStatements, SizeOf(TProgStatement)) and
          Fits(H.OfsGlobalDefs, H.NumGlobalDefs, SizeOf(TProgDef)) and
          Fits(H.OfsFieldDefs, H.NumFieldDefs, SizeOf(TProgDef)) and
          Fits(H.OfsFunctions, H.NumFunctions, SizeOf(TProgFunction)) and
          Fits(H.OfsStrings, H.NumStrings, 1) and
          Fits(H.OfsGlobals, H.NumGlobals, 4)) then
  begin
    WritelnWarning('QuakeProgs', '"%s" is truncated', [Path]);
    Exit;
  end;
  FCrc := H.Crc;

  SetLength(FStatements, H.NumStatements);
  if H.NumStatements > 0 then
    Move((Data + H.OfsStatements)^, FStatements[0], H.NumStatements * SizeOf(TProgStatement));
  SetLength(FGlobalDefs, H.NumGlobalDefs);
  if H.NumGlobalDefs > 0 then
    Move((Data + H.OfsGlobalDefs)^, FGlobalDefs[0], H.NumGlobalDefs * SizeOf(TProgDef));
  SetLength(FFieldDefs, H.NumFieldDefs);
  if H.NumFieldDefs > 0 then
    Move((Data + H.OfsFieldDefs)^, FFieldDefs[0], H.NumFieldDefs * SizeOf(TProgDef));
  SetLength(FFunctions, H.NumFunctions);
  if H.NumFunctions > 0 then
    Move((Data + H.OfsFunctions)^, FFunctions[0], H.NumFunctions * SizeOf(TProgFunction));
  SetLength(FStrings, H.NumStrings);
  if H.NumStrings > 0 then
    Move((Data + H.OfsStrings)^, FStrings[1], H.NumStrings);
  SetLength(FGlobals, Max(H.NumGlobals, RESERVED_OFS));
  if H.NumGlobals > 0 then
    Move((Data + H.OfsGlobals)^, FGlobals[0], H.NumGlobals * 4);
  FEntityFields := H.EntityFields;

  { Entity memory: world plus the pool }
  SetLength(FEdicts, MaxEdicts * FEntityFields);
  FillChar(FEdicts[0], Length(FEdicts) * SizeOf(TProgCell), 0);
  SetLength(FEdictFree, MaxEdicts);
  SetLength(FEdictFreeTime, MaxEdicts);
  for I := 0 to MaxEdicts - 1 do
  begin
    FEdictFree[I] := I > 0;
    FEdictFreeTime[I] := -100;
  end;
  FNumEdicts := 1;

  FGlobalNames.Clear;
  FFieldNames.Clear;
  FFunctionNames.Clear;
  for I := 0 to High(FGlobalDefs) do
    FGlobalNames.AddOrSetValue(GetString(FGlobalDefs[I].SName), I);
  for I := 0 to High(FFieldDefs) do
    FFieldNames.AddOrSetValue(GetString(FFieldDefs[I].SName), I);
  for I := 0 to High(FFunctions) do
    FFunctionNames.AddOrSetValue(GetString(FFunctions[I].SName), I);
  SetupWellKnown;
  FDynStrings.Clear;
  PrecachedModels.Clear;
  PrecachedSounds.Clear;
  Statistics := Default(TProgsStatistics);

  WritelnLog('QuakeProgs', 'Loaded "%s": %d statements, %d functions, %d globals, %d entity fields, crc %d',
    [Path, H.NumStatements, H.NumFunctions, H.NumGlobals, FEntityFields, FCrc]);
  Result := True;
end;

procedure TQuakeProgs.SetupWellKnown;
begin
  FGSelf := GlobalOfs('self');
  FGOther := GlobalOfs('other');
  FGWorld := GlobalOfs('world');
  FGTime := GlobalOfs('time');
  FGFrameTime := GlobalOfs('frametime');
  FGForceRetouch := GlobalOfs('force_retouch');
  FGMapName := GlobalOfs('mapname');
  FGDeathmatch := GlobalOfs('deathmatch');
  FGCoop := GlobalOfs('coop');
  FGTeamplay := GlobalOfs('teamplay');
  FGServerFlags := GlobalOfs('serverflags');
  FGTotalSecrets := GlobalOfs('total_secrets');
  FGTotalMonsters := GlobalOfs('total_monsters');
  FGFoundSecrets := GlobalOfs('found_secrets');
  FGKilledMonsters := GlobalOfs('killed_monsters');
  FGParm1 := GlobalOfs('parm1');
  FGTraceAllSolid := GlobalOfs('trace_allsolid');
  FGTraceStartSolid := GlobalOfs('trace_startsolid');
  FGTraceFraction := GlobalOfs('trace_fraction');
  FGTraceEndPos := GlobalOfs('trace_endpos');
  FGTracePlaneNormal := GlobalOfs('trace_plane_normal');
  FGTracePlaneDist := GlobalOfs('trace_plane_dist');
  FGTraceEnt := GlobalOfs('trace_ent');
  FGTraceInOpen := GlobalOfs('trace_inopen');
  FGTraceInWater := GlobalOfs('trace_inwater');
  FGMsgEntity := GlobalOfs('msg_entity');
  FGVForward := GlobalOfs('v_forward');
  FGVUp := GlobalOfs('v_up');
  FGVRight := GlobalOfs('v_right');
  FGSkill := GlobalOfs('skill');

  FFModelIndex := FieldOfs('modelindex');
  FFOrigin := FieldOfs('origin');
  FFOldOrigin := FieldOfs('oldorigin');
  FFAngles := FieldOfs('angles');
  FFClassName := FieldOfs('classname');
  FFModel := FieldOfs('model');
  FFFrame := FieldOfs('frame');
  FFSkin := FieldOfs('skin');
  FFEffects := FieldOfs('effects');
  FFMins := FieldOfs('mins');
  FFMaxs := FieldOfs('maxs');
  FFSize := FieldOfs('size');
  FFSolid := FieldOfs('solid');
  FFMoveType := FieldOfs('movetype');
  FFHealth := FieldOfs('health');
  FFNextThink := FieldOfs('nextthink');
  FFThink := FieldOfs('think');
  FFTouch := FieldOfs('touch');
  FFUse := FieldOfs('use');
  FFBlocked := FieldOfs('blocked');
  FFChain := FieldOfs('chain');
  FFTargetName := FieldOfs('targetname');
  FFTarget := FieldOfs('target');
  FFOwner := FieldOfs('owner');
  FFVelocity := FieldOfs('velocity');
  FFFlags := FieldOfs('flags');
  FFGroundEntity := FieldOfs('groundentity');
  FFAbsMin := FieldOfs('absmin');
  FFAbsMax := FieldOfs('absmax');
  FFEnemy := FieldOfs('enemy');
  FFIdealYaw := FieldOfs('ideal_yaw');
  FFYawSpeed := FieldOfs('yaw_speed');
  FFNetName := FieldOfs('netname');
  FFMessage := FieldOfs('message');
  FFSounds := FieldOfs('sounds');
  FFSpawnFlags := FieldOfs('spawnflags');
end;

{ Strings }

function TQuakeProgs.GetString(const Ofs: Integer): String;
var
  I: Integer;
begin
  if Ofs < 0 then
  begin
    I := -Ofs - 1;
    if I < FDynStrings.Count then
      Exit(FDynStrings[I]);
    Exit('');
  end;
  if Ofs >= Length(FStrings) then
    Exit('');
  I := Ofs + 1;
  while (I <= Length(FStrings)) and (FStrings[I] <> #0) do
    Inc(I);
  Result := Copy(FStrings, Ofs + 1, I - Ofs - 1);
end;

function TQuakeProgs.NewString(const S: String): Integer;
begin
  Result := -(FDynStrings.Add(S)) - 1;
end;

function TQuakeProgs.TempString(const S: String): Integer;
begin
  { A ring of 16 slots like pr_string_temp, reused }
  if FTempStrings[FTempNext] = 0 then
    FTempStrings[FTempNext] := NewString(S)
  else
    FDynStrings[-FTempStrings[FTempNext] - 1] := S;
  Result := FTempStrings[FTempNext];
  FTempNext := (FTempNext + 1) mod Length(FTempStrings);
end;

{ Memory }

function TQuakeProgs.Global(const Ofs: Integer): PProgCell;
begin
  if (Ofs < 0) or (Ofs >= Length(FGlobals)) then
    Result := @FGlobals[OFS_NULL]
  else
    Result := @FGlobals[Ofs];
end;

function TQuakeProgs.GlobalVector(const Ofs: Integer): TVector3;
begin
  Result := Vector3(Global(Ofs)^.F, Global(Ofs + 1)^.F, Global(Ofs + 2)^.F);
end;

procedure TQuakeProgs.SetGlobalVector(const Ofs: Integer; const V: TVector3);
begin
  if Ofs < 0 then
    Exit;
  Global(Ofs)^.F := V.X;
  Global(Ofs + 1)^.F := V.Y;
  Global(Ofs + 2)^.F := V.Z;
end;

function TQuakeProgs.Field(const E, Ofs: Integer): PProgCell;
begin
  if (E < 0) or (E >= MaxEdicts) or (Ofs < 0) or (Ofs >= FEntityFields) then
    Result := @FGlobals[OFS_NULL]
  else
    Result := @FEdicts[E * FEntityFields + Ofs];
end;

function TQuakeProgs.FieldVector(const E, Ofs: Integer): TVector3;
begin
  Result := Vector3(Field(E, Ofs)^.F, Field(E, Ofs + 1)^.F, Field(E, Ofs + 2)^.F);
end;

procedure TQuakeProgs.SetFieldVector(const E, Ofs: Integer; const V: TVector3);
begin
  if Ofs < 0 then
    Exit;
  Field(E, Ofs)^.F := V.X;
  Field(E, Ofs + 1)^.F := V.Y;
  Field(E, Ofs + 2)^.F := V.Z;
end;

function TQuakeProgs.FieldString(const E, Ofs: Integer): String;
begin
  Result := GetString(Field(E, Ofs)^.I);
end;

function TQuakeProgs.GlobalOfs(const Name: String): Integer;
var
  I: Integer;
begin
  if FGlobalNames.TryGetValue(Name, I) then
    Result := FGlobalDefs[I].Ofs
  else
    Result := -1;
end;

function TQuakeProgs.FieldOfs(const Name: String): Integer;
var
  I: Integer;
begin
  if FFieldNames.TryGetValue(Name, I) then
    Result := FFieldDefs[I].Ofs
  else
    Result := -1;
end;

function TQuakeProgs.FunctionIndex(const Name: String): Integer;
begin
  if not FFunctionNames.TryGetValue(Name, Result) then
    Result := -1;
end;

function TQuakeProgs.FunctionName(const F: Integer): String;
begin
  if (F >= 0) and (F < Length(FFunctions)) then
    Result := GetString(FFunctions[F].SName)
  else
    Result := '?';
end;

function TQuakeProgs.ParmString(const N: Integer): String;
begin
  Result := GetString(Global(OFS_PARM0 + N * 3)^.I);
end;

{ Entities }

function TQuakeProgs.AllocEdict: Integer;
var
  I: Integer;
  T: Single;
begin
  { ED_Alloc: reuse a slot freed more than 0.5 s ago, else a new one }
  T := Global(FGTime)^.F;
  for I := 1 to MaxEdicts - 1 do
    if FEdictFree[I] and ((FEdictFreeTime[I] < 2) or (T - FEdictFreeTime[I] > 0.5)) then
    begin
      FEdictFree[I] := False;
      FillChar(FEdicts[I * FEntityFields], FEntityFields * SizeOf(TProgCell), 0);
      if I >= FNumEdicts then
        FNumEdicts := I + 1;
      Inc(Statistics.Spawned);
      Exit(I);
    end;
  Error('ED_Alloc: no free edicts');
  Result := 0;
end;

procedure TQuakeProgs.FreeEdict(const E: Integer);
begin
  if (E <= 0) or (E >= MaxEdicts) or FEdictFree[E] then
    Exit;
  FEdictFree[E] := True;
  FEdictFreeTime[E] := Global(FGTime)^.F;
  FillChar(FEdicts[E * FEntityFields], FEntityFields * SizeOf(TProgCell), 0);
  Inc(Statistics.Removed);
end;

function TQuakeProgs.EdictFree(const E: Integer): Boolean;
begin
  Result := (E <= 0) or (E >= MaxEdicts) or FEdictFree[E];
end;

function TQuakeProgs.ParseEpair(const E: Integer; const Key, Value: String): Boolean;
var
  I, Ofs: Integer;
  Parts: TStringArray;
  Fmt: TFormatSettings;
  K: String;
begin
  Result := False;
  K := Key;
  { ED_ParseEdict: "angle" sets the yaw }
  if K = 'angle' then
  begin
    Ofs := FieldOfs('angles');
    if Ofs < 0 then
      Exit;
    Field(E, Ofs)^.F := 0;
    Field(E, Ofs + 1)^.F := StrToFloatDef(Value, 0, DefaultFormatSettings);
    Field(E, Ofs + 2)^.F := 0;
    Exit(True);
  end;
  if K = 'light' then
    K := 'light_lev';
  if not FFieldNames.TryGetValue(K, I) then
    Exit;
  Ofs := FFieldDefs[I].Ofs;
  Fmt := DefaultFormatSettings;
  Fmt.DecimalSeparator := '.';
  case FFieldDefs[I].DefType and not DEF_SAVEGLOBAL of
    ev_string:
      Field(E, Ofs)^.I := NewString(StringReplace(Value, '\n', #10, [rfReplaceAll]));
    ev_float:
      Field(E, Ofs)^.F := StrToFloatDef(Value, 0, Fmt);
    ev_vector:
      begin
        Parts := Trim(Value).Split([' '], TStringSplitOptions.ExcludeEmpty);
        Field(E, Ofs)^.F := 0;
        Field(E, Ofs + 1)^.F := 0;
        Field(E, Ofs + 2)^.F := 0;
        if Length(Parts) > 0 then
          Field(E, Ofs)^.F := StrToFloatDef(Parts[0], 0, Fmt);
        if Length(Parts) > 1 then
          Field(E, Ofs + 1)^.F := StrToFloatDef(Parts[1], 0, Fmt);
        if Length(Parts) > 2 then
          Field(E, Ofs + 2)^.F := StrToFloatDef(Parts[2], 0, Fmt);
      end;
    ev_entity:
      Field(E, Ofs)^.I := StrToIntDef(Value, 0);
    ev_field:
      Field(E, Ofs)^.I := Max(0, FieldOfs(Value));
    ev_function:
      Field(E, Ofs)^.I := Max(0, FunctionIndex(Value));
    else
      Exit;
  end;
  Result := True;
end;

function TQuakeProgs.SpawnEntities(const Entities: TQuakeEntityList; const Skill: Integer): Integer;
const
  SPAWNFLAG_NOT_EASY = 256;
  SPAWNFLAG_NOT_MEDIUM = 512;
  SPAWNFLAG_NOT_HARD = 1024;
  SPAWNFLAG_NOT_DEATHMATCH = 2048;
var
  Ent: TQuakeEntity;
  E, F, I, Flags: Integer;
  Pair: specialize TPair<String, String>;
  CName: String;
  Worlds: Integer;
begin
  Result := 0;
  Worlds := 0;
  if not Loaded then
    Exit;
  Global(FGSkill)^.F := Skill;
  for I := 0 to Entities.Count - 1 do
  begin
    Ent := Entities[I];
    CName := LowerCase(Ent.ClassName);
    if (CName = 'worldspawn') and (Worlds = 0) then
    begin
      E := 0;
      Inc(Worlds);
    end else
      E := AllocEdict;
    for Pair in Ent.Fields do
      ParseEpair(E, Pair.Key, Pair.Value);

    { The skill and game type remove entities before they spawn }
    Flags := Round(Field(E, FFSpawnFlags)^.F);
    if (Global(FGDeathmatch)^.F <> 0) and ((Flags and SPAWNFLAG_NOT_DEATHMATCH) <> 0) or
       ((Skill = 0) and ((Flags and SPAWNFLAG_NOT_EASY) <> 0)) or
       ((Skill = 1) and ((Flags and SPAWNFLAG_NOT_MEDIUM) <> 0)) or
       ((Skill >= 2) and ((Flags and SPAWNFLAG_NOT_HARD) <> 0)) then
    begin
      if E > 0 then
        FreeEdict(E);
      Continue;
    end;

    if Field(E, FFClassName)^.I = 0 then
    begin
      WritelnWarning('QuakeProgs', 'Entity %d has no classname', [E]);
      if E > 0 then
        FreeEdict(E);
      Continue;
    end;
    F := FunctionIndex(FieldString(E, FFClassName));
    if F < 0 then
    begin
      WritelnLog('QuakeProgs', 'No spawn function for "%s"', [FieldString(E, FFClassName)]);
      if E > 0 then
        FreeEdict(E);
      Continue;
    end;
    CallWith(F, E);
    if FAborted then
      Exit;
    Inc(Result);
  end;
end;

{ Execution }

procedure TQuakeProgs.Error(const Msg: String);
begin
  WritelnWarning('QuakeProgs', 'QuakeC error in %s (statement %d): %s',
    [FunctionName(FCurrentFunction), FXStatement, Msg]);
  FAborted := True;
end;

function TQuakeProgs.EnterFunction(const F: Integer): Integer;
var
  I, J, O, C: Integer;
  Fn: ^TProgFunction;
begin
  { PR_EnterFunction: save the locals of the caller, copy the parameters }
  FStack[FDepth].S := FXStatement;
  FStack[FDepth].F := FCurrentFunction;
  Inc(FDepth);
  if FDepth >= MaxProgStack then
  begin
    Error('stack overflow');
    Exit(0);
  end;
  Fn := @FFunctions[F];
  C := Fn^.Locals;
  if FLocalStackUsed + C > LocalStackSize then
  begin
    Error('locals stack overflow');
    Exit(0);
  end;
  for I := 0 to C - 1 do
    FLocalStack[FLocalStackUsed + I] := FGlobals[Fn^.ParmStart + I];
  FLocalStackUsed := FLocalStackUsed + C;

  O := Fn^.ParmStart;
  for I := 0 to Fn^.NumParms - 1 do
  begin
    for J := 0 to Fn^.ParmSize[I] - 1 do
    begin
      FGlobals[O] := FGlobals[OFS_PARM0 + I * 3 + J];
      Inc(O);
    end;
  end;
  FCurrentFunction := F;
  Result := Fn^.FirstStatement - 1;
end;

function TQuakeProgs.LeaveFunction: Integer;
var
  I, C: Integer;
begin
  if FDepth <= 0 then
  begin
    Error('prog stack underflow');
    Exit(0);
  end;
  C := FFunctions[FCurrentFunction].Locals;
  FLocalStackUsed := FLocalStackUsed - C;
  if FLocalStackUsed < 0 then
  begin
    Error('locals stack underflow');
    Exit(0);
  end;
  for I := 0 to C - 1 do
    FGlobals[FFunctions[FCurrentFunction].ParmStart + I] := FLocalStack[FLocalStackUsed + I];
  Dec(FDepth);
  FCurrentFunction := FStack[FDepth].F;
  Result := FStack[FDepth].S;
end;

procedure TQuakeProgs.Execute(const F: Integer);
var
  S, ExitDepth, Runaway, I, NewF, E, Ptr: Integer;
  St: ^TProgStatement;
  A, B, C: PProgCell;
  Va, Vb: TVector3;
begin
  if (F <= 0) or (F >= Length(FFunctions)) then
  begin
    if F <> 0 then
      Error('bad function index ' + IntToStr(F));
    Exit;
  end;
  FAborted := False;
  ExitDepth := FDepth;
  Inc(Statistics.Calls);
  S := EnterFunction(F);
  Runaway := MaxRunaway;
  while not FAborted do
  begin
    Inc(S);
    Dec(Runaway);
    if Runaway = 0 then
    begin
      Error('runaway loop');
      Break;
    end;
    if (S < 0) or (S >= Length(FStatements)) then
    begin
      Error('statement out of range');
      Break;
    end;
    FXStatement := S;
    St := @FStatements[S];
    A := Global(St^.A);
    B := Global(St^.B);
    C := Global(St^.C);

    case St^.Op of
      OP_ADD_F: C^.F := A^.F + B^.F;
      OP_ADD_V:
        begin
          C^.F := A^.F + B^.F;
          Global(St^.C + 1)^.F := Global(St^.A + 1)^.F + Global(St^.B + 1)^.F;
          Global(St^.C + 2)^.F := Global(St^.A + 2)^.F + Global(St^.B + 2)^.F;
        end;
      OP_SUB_F: C^.F := A^.F - B^.F;
      OP_SUB_V:
        begin
          C^.F := A^.F - B^.F;
          Global(St^.C + 1)^.F := Global(St^.A + 1)^.F - Global(St^.B + 1)^.F;
          Global(St^.C + 2)^.F := Global(St^.A + 2)^.F - Global(St^.B + 2)^.F;
        end;
      OP_MUL_F: C^.F := A^.F * B^.F;
      OP_MUL_V:
        C^.F := A^.F * B^.F + Global(St^.A + 1)^.F * Global(St^.B + 1)^.F +
          Global(St^.A + 2)^.F * Global(St^.B + 2)^.F;
      OP_MUL_FV:
        begin
          C^.F := A^.F * B^.F;
          Global(St^.C + 1)^.F := A^.F * Global(St^.B + 1)^.F;
          Global(St^.C + 2)^.F := A^.F * Global(St^.B + 2)^.F;
        end;
      OP_MUL_VF:
        begin
          C^.F := B^.F * A^.F;
          Global(St^.C + 1)^.F := B^.F * Global(St^.A + 1)^.F;
          Global(St^.C + 2)^.F := B^.F * Global(St^.A + 2)^.F;
        end;
      OP_DIV_F:
        if B^.F = 0 then
          C^.F := 0
        else
          C^.F := A^.F / B^.F;
      OP_BITAND: C^.F := Trunc(A^.F) and Trunc(B^.F);
      OP_BITOR: C^.F := Trunc(A^.F) or Trunc(B^.F);
      OP_GE: C^.F := Ord(A^.F >= B^.F);
      OP_LE: C^.F := Ord(A^.F <= B^.F);
      OP_GT: C^.F := Ord(A^.F > B^.F);
      OP_LT: C^.F := Ord(A^.F < B^.F);
      OP_AND: C^.F := Ord((A^.F <> 0) and (B^.F <> 0));
      OP_OR: C^.F := Ord((A^.F <> 0) or (B^.F <> 0));
      OP_NOT_F: C^.F := Ord(A^.F = 0);
      OP_NOT_V: C^.F := Ord((A^.F = 0) and (Global(St^.A + 1)^.F = 0) and (Global(St^.A + 2)^.F = 0));
      OP_NOT_S: C^.F := Ord((A^.I = 0) or (GetString(A^.I) = ''));
      OP_NOT_FNC: C^.F := Ord(A^.I = 0);
      OP_NOT_ENT: C^.F := Ord(A^.I = 0);
      OP_EQ_F: C^.F := Ord(A^.F = B^.F);
      OP_EQ_V:
        C^.F := Ord((A^.F = B^.F) and (Global(St^.A + 1)^.F = Global(St^.B + 1)^.F) and
          (Global(St^.A + 2)^.F = Global(St^.B + 2)^.F));
      OP_EQ_S: C^.F := Ord(GetString(A^.I) = GetString(B^.I));
      OP_EQ_E, OP_EQ_FNC: C^.F := Ord(A^.I = B^.I);
      OP_NE_F: C^.F := Ord(A^.F <> B^.F);
      OP_NE_V:
        C^.F := Ord((A^.F <> B^.F) or (Global(St^.A + 1)^.F <> Global(St^.B + 1)^.F) or
          (Global(St^.A + 2)^.F <> Global(St^.B + 2)^.F));
      OP_NE_S: C^.F := Ord(GetString(A^.I) <> GetString(B^.I));
      OP_NE_E, OP_NE_FNC: C^.F := Ord(A^.I <> B^.I);

      OP_STORE_F, OP_STORE_ENT, OP_STORE_FLD, OP_STORE_S, OP_STORE_FNC:
        B^.I := A^.I;
      OP_STORE_V:
        begin
          B^.I := A^.I;
          Global(St^.B + 1)^.I := Global(St^.A + 1)^.I;
          Global(St^.B + 2)^.I := Global(St^.A + 2)^.I;
        end;

      { Pointers are cell indexes into the entity memory }
      OP_STOREP_F, OP_STOREP_ENT, OP_STOREP_FLD, OP_STOREP_S, OP_STOREP_FNC:
        begin
          Ptr := B^.I;
          if (Ptr >= 0) and (Ptr < Length(FEdicts)) then
            FEdicts[Ptr].I := A^.I;
        end;
      OP_STOREP_V:
        begin
          Ptr := B^.I;
          if (Ptr >= 0) and (Ptr + 2 < Length(FEdicts)) then
          begin
            FEdicts[Ptr].I := A^.I;
            FEdicts[Ptr + 1].I := Global(St^.A + 1)^.I;
            FEdicts[Ptr + 2].I := Global(St^.A + 2)^.I;
          end;
        end;
      OP_ADDRESS:
        begin
          E := A^.I;
          if (E < 0) or (E >= MaxEdicts) then
          begin
            Error('address of a bad entity');
            Break;
          end;
          if (E = 0) and (FDepth > 0) then
          begin
            { Quake refuses to write to the world (except during spawn);
              allow it like most engines do, QuakeC relies on it }
          end;
          C^.I := E * FEntityFields + B^.I;
        end;
      OP_LOAD_F, OP_LOAD_FLD, OP_LOAD_ENT, OP_LOAD_S, OP_LOAD_FNC:
        begin
          E := A^.I;
          if (E < 0) or (E >= MaxEdicts) then
          begin
            Error('load from a bad entity');
            Break;
          end;
          C^.I := Field(E, B^.I)^.I;
        end;
      OP_LOAD_V:
        begin
          E := A^.I;
          if (E < 0) or (E >= MaxEdicts) then
          begin
            Error('load from a bad entity');
            Break;
          end;
          C^.I := Field(E, B^.I)^.I;
          Global(St^.C + 1)^.I := Field(E, B^.I + 1)^.I;
          Global(St^.C + 2)^.I := Field(E, B^.I + 2)^.I;
        end;

      OP_IFNOT:
        if A^.I = 0 then
          S := S + St^.B - 1;
      OP_IF:
        if A^.I <> 0 then
          S := S + St^.B - 1;
      OP_GOTO:
        S := S + St^.A - 1;
      OP_CALL0..OP_CALL8:
        begin
          FArgC := St^.Op - OP_CALL0;
          NewF := A^.I;
          if (NewF <= 0) or (NewF >= Length(FFunctions)) then
          begin
            Error('NULL function');
            Break;
          end;
          Inc(Statistics.Calls);
          if FFunctions[NewF].FirstStatement < 0 then
          begin
            { Builtin }
            I := -FFunctions[NewF].FirstStatement;
            FCurrentBuiltin := I;
            if (I < Length(FBuiltins)) and Assigned(FBuiltins[I]) then
              FBuiltins[I]()
            else
            begin
              Error('bad builtin ' + IntToStr(I));
              Break;
            end;
          end else
            S := EnterFunction(NewF);
        end;
      OP_DONE, OP_RETURN:
        begin
          FGlobals[OFS_RETURN].I := A^.I;
          FGlobals[OFS_RETURN + 1].I := Global(St^.A + 1)^.I;
          FGlobals[OFS_RETURN + 2].I := Global(St^.A + 2)^.I;
          S := LeaveFunction;
          if FDepth = ExitDepth then
            Break;
        end;
      OP_STATE:
        begin
          { self.nextthink = time + 0.1; self.frame = a; self.think = b }
          E := Global(FGSelf)^.I;
          Field(E, FFNextThink)^.F := Global(FGTime)^.F + 0.1;
          Field(E, FFFrame)^.F := A^.F;
          Field(E, FFThink)^.I := B^.I;
        end;
      else
      begin
        Error('bad opcode ' + IntToStr(St^.Op));
        Break;
      end;
    end;
  end;
  if FAborted then
  begin
    { Unwind }
    FDepth := ExitDepth;
    FLocalStackUsed := 0;
  end;
end;

procedure TQuakeProgs.CallWith(const F, E: Integer);
begin
  Global(FGSelf)^.I := E;
  Global(FGOther)^.I := 0;
  Execute(F);
end;

procedure TQuakeProgs.CallWithOther(const F, E, Other: Integer);
begin
  Global(FGSelf)^.I := E;
  Global(FGOther)^.I := Other;
  Execute(F);
end;

procedure TQuakeProgs.ReserveEdicts(const N: Integer);
var
  I: Integer;
begin
  for I := 1 to Min(N, MaxEdicts - 1) do
  begin
    FEdictFree[I] := False;
    FillChar(FEdicts[I * FEntityFields], FEntityFields * SizeOf(TProgCell), 0);
  end;
  if FNumEdicts < N + 1 then
    FNumEdicts := N + 1;
end;

procedure TQuakeProgs.SaveState(const S: TStream);

  procedure WriteStr(const Str: String);
  var
    L: LongInt;
  begin
    L := Length(Str);
    S.WriteBuffer(L, 4);
    if L > 0 then
      S.WriteBuffer(Str[1], L);
  end;

  procedure WriteList(const List: TStrings);
  var
    L, I: LongInt;
  begin
    L := List.Count;
    S.WriteBuffer(L, 4);
    for I := 0 to L - 1 do
      WriteStr(List[I]);
  end;

var
  V: LongInt;
  I: Integer;
  B: Byte;
begin
  V := FCrc;
  S.WriteBuffer(V, 4);
  V := FEntityFields;
  S.WriteBuffer(V, 4);
  V := Length(FGlobals);
  S.WriteBuffer(V, 4);
  if V > 0 then
    S.WriteBuffer(FGlobals[0], V * SizeOf(TProgCell));
  V := FNumEdicts;
  S.WriteBuffer(V, 4);
  for I := 0 to FNumEdicts - 1 do
  begin
    B := Ord(FEdictFree[I]);
    S.WriteBuffer(B, 1);
    S.WriteBuffer(FEdictFreeTime[I], SizeOf(Single));
  end;
  if FNumEdicts * FEntityFields > 0 then
    S.WriteBuffer(FEdicts[0], FNumEdicts * FEntityFields * SizeOf(TProgCell));
  WriteList(FDynStrings);
  WriteList(PrecachedModels);
  WriteList(PrecachedSounds);
end;

function TQuakeProgs.LoadState(const S: TStream): Boolean;

  function ReadStr: String;
  var
    L: LongInt;
  begin
    S.ReadBuffer(L, 4);
    SetLength(Result, Max(0, L));
    if L > 0 then
      S.ReadBuffer(Result[1], L);
  end;

  procedure ReadList(const List: TStrings);
  var
    L, I: LongInt;
  begin
    List.Clear;
    S.ReadBuffer(L, 4);
    for I := 0 to L - 1 do
      List.Add(ReadStr);
  end;

var
  V: LongInt;
  I: Integer;
  B: Byte;
begin
  Result := False;
  if not Loaded then
    Exit;
  S.ReadBuffer(V, 4);
  if V <> FCrc then
  begin
    WritelnWarning('QuakeProgs', 'The savegame was made with another progs.dat (crc %d, loaded %d)', [V, FCrc]);
    Exit;
  end;
  S.ReadBuffer(V, 4);
  if V <> FEntityFields then
    Exit;
  S.ReadBuffer(V, 4);
  if V <> Length(FGlobals) then
    Exit;
  if V > 0 then
    S.ReadBuffer(FGlobals[0], V * SizeOf(TProgCell));
  S.ReadBuffer(V, 4);
  if (V < 1) or (V > MaxEdicts) then
    Exit;
  FNumEdicts := V;
  FillChar(FEdicts[0], Length(FEdicts) * SizeOf(TProgCell), 0);
  for I := 0 to MaxEdicts - 1 do
  begin
    FEdictFree[I] := I > 0;
    FEdictFreeTime[I] := -100;
  end;
  for I := 0 to FNumEdicts - 1 do
  begin
    S.ReadBuffer(B, 1);
    FEdictFree[I] := B <> 0;
    S.ReadBuffer(FEdictFreeTime[I], SizeOf(Single));
  end;
  if FNumEdicts * FEntityFields > 0 then
    S.ReadBuffer(FEdicts[0], FNumEdicts * FEntityFields * SizeOf(TProgCell));
  ReadList(FDynStrings);
  ReadList(PrecachedModels);
  ReadList(PrecachedSounds);
  for I := 0 to High(FTempStrings) do
    FTempStrings[I] := 0;
  FTempNext := 0;
  Result := True;
end;

procedure TQuakeProgs.RunFrame(const FrameTime: Single);
var
  E, F: Integer;
  T, NT: Single;
begin
  if not Loaded then
    Exit;
  Global(FGFrameTime)^.F := FrameTime;
  F := FunctionIndex('StartFrame');
  if F > 0 then
    CallWith(F, 0);
  T := Global(FGTime)^.F;
  for E := 1 to FNumEdicts - 1 do
  begin
    if FEdictFree[E] then
      Continue;
    NT := Field(E, FFNextThink)^.F;
    if (NT <= 0) or (NT > T + FrameTime) then
      Continue;
    { SV_RunThink: the think happens at its own time }
    Field(E, FFNextThink)^.F := 0;
    Global(FGTime)^.F := Max(NT, T);
    F := Field(E, FFThink)^.I;
    if F > 0 then
    begin
      Inc(Statistics.Thinks);
      CallWith(F, E);
    end;
  end;
  Global(FGTime)^.F := T + FrameTime;
end;

{ Builtins (pr_cmds.c) }

procedure TQuakeProgs.RegisterBuiltins;
begin
  FBuiltins[1] := @PF_makevectors;
  FBuiltins[2] := @PF_setorigin;
  FBuiltins[3] := @PF_setmodel;
  FBuiltins[4] := @PF_setsize;
  FBuiltins[6] := @PF_break;
  FBuiltins[7] := @PF_random;
  FBuiltins[8] := @PF_sound;
  FBuiltins[9] := @PF_normalize;
  FBuiltins[10] := @PF_error;
  FBuiltins[11] := @PF_objerror;
  FBuiltins[12] := @PF_vlen;
  FBuiltins[13] := @PF_vectoyaw;
  FBuiltins[14] := @PF_spawn;
  FBuiltins[15] := @PF_remove;
  FBuiltins[16] := @PF_traceline;
  FBuiltins[17] := @PF_checkclient;
  FBuiltins[18] := @PF_find;
  FBuiltins[19] := @PF_precache;
  FBuiltins[20] := @PF_precache;
  FBuiltins[21] := @PF_stuffcmd;
  FBuiltins[22] := @PF_findradius;
  FBuiltins[23] := @PF_bprint;
  FBuiltins[24] := @PF_sprint;
  FBuiltins[25] := @PF_dprint;
  FBuiltins[26] := @PF_ftos;
  FBuiltins[27] := @PF_vtos;
  FBuiltins[28] := @PF_coredump;
  FBuiltins[29] := @PF_traceon;
  FBuiltins[30] := @PF_traceoff;
  FBuiltins[31] := @PF_eprint;
  FBuiltins[32] := @PF_walkmove;
  FBuiltins[34] := @PF_droptofloor;
  FBuiltins[35] := @PF_lightstyle;
  FBuiltins[36] := @PF_rint;
  FBuiltins[37] := @PF_floor;
  FBuiltins[38] := @PF_ceil;
  FBuiltins[40] := @PF_checkbottom;
  FBuiltins[41] := @PF_pointcontents;
  FBuiltins[43] := @PF_fabs;
  FBuiltins[44] := @PF_aim;
  FBuiltins[45] := @PF_cvar;
  FBuiltins[46] := @PF_localcmd;
  FBuiltins[47] := @PF_nextent;
  FBuiltins[48] := @PF_particle;
  FBuiltins[49] := @PF_changeyaw;
  FBuiltins[51] := @PF_vectoangles;
  FBuiltins[52] := @PF_WriteByte;
  FBuiltins[53] := @PF_WriteChar;
  FBuiltins[54] := @PF_WriteShort;
  FBuiltins[55] := @PF_WriteLong;
  FBuiltins[56] := @PF_WriteCoord;
  FBuiltins[57] := @PF_WriteAngle;
  FBuiltins[58] := @PF_WriteString;
  FBuiltins[59] := @PF_WriteEntity;
  FBuiltins[67] := @PF_movetogoal;
  FBuiltins[68] := @PF_precache;
  FBuiltins[69] := @PF_makestatic;
  FBuiltins[70] := @PF_changelevel;
  FBuiltins[72] := @PF_cvar_set;
  FBuiltins[73] := @PF_centerprint;
  FBuiltins[74] := @PF_ambientsound;
  FBuiltins[75] := @PF_precache;
  FBuiltins[76] := @PF_precache;
  FBuiltins[77] := @PF_precache;
  FBuiltins[78] := @PF_setspawnparms;
end;

procedure TQuakeProgs.PF_makevectors;
var
  Angles: TVector3;
  SP, CP, SY, CY, SR, CR: Single;
begin
  { AngleVectors: pitch, yaw, roll in degrees }
  Angles := GlobalVector(OFS_PARM0);
  SinCos(DegToRad(Angles.X), SP, CP);
  SinCos(DegToRad(Angles.Y), SY, CY);
  SinCos(DegToRad(Angles.Z), SR, CR);
  SetGlobalVector(FGVForward, Vector3(CP * CY, CP * SY, -SP));
  SetGlobalVector(FGVRight, Vector3(-SR * SP * CY + CR * SY, -SR * SP * SY - CR * CY, -SR * CP));
  SetGlobalVector(FGVUp, Vector3(CR * SP * CY + SR * SY, CR * SP * SY - SR * CY, CR * CP));
end;

procedure TQuakeProgs.PF_setorigin;
begin
  FHost.SetOrigin(Self, Global(OFS_PARM0)^.I, GlobalVector(OFS_PARM0 + 3));
end;

procedure TQuakeProgs.PF_setmodel;
var
  E: Integer;
  M: String;
begin
  E := Global(OFS_PARM0)^.I;
  M := ParmString(1);
  Field(E, FFModel)^.I := Global(OFS_PARM0 + 3)^.I;
  if (M <> '') and (PrecachedModels.IndexOf(M) < 0) then
    PrecachedModels.Add(M);
  FHost.SetModel(Self, E, M);
end;

procedure TQuakeProgs.PF_setsize;
begin
  FHost.SetSize(Self, Global(OFS_PARM0)^.I, GlobalVector(OFS_PARM0 + 3), GlobalVector(OFS_PARM0 + 6));
end;

procedure TQuakeProgs.PF_break;
begin
  WritelnLog('QuakeProgs', 'break statement');
end;

procedure TQuakeProgs.PF_random;
begin
  Global(OFS_RETURN)^.F := Random;
end;

procedure TQuakeProgs.PF_sound;
begin
  FHost.Sound(Self, Global(OFS_PARM0)^.I, Round(Global(OFS_PARM0 + 3)^.F), ParmString(2),
    Global(OFS_PARM0 + 9)^.F, Global(OFS_PARM0 + 12)^.F);
end;

procedure TQuakeProgs.PF_normalize;
var
  V: TVector3;
begin
  V := GlobalVector(OFS_PARM0);
  if V.IsZero then
    SetGlobalVector(OFS_RETURN, TVector3.Zero)
  else
    SetGlobalVector(OFS_RETURN, V.Normalize);
end;

procedure TQuakeProgs.PF_error;
begin
  Error('error(): ' + ParmString(0));
end;

procedure TQuakeProgs.PF_objerror;
var
  E: Integer;
begin
  E := Global(FGSelf)^.I;
  WritelnWarning('QuakeProgs', 'objerror on %s: %s', [FieldString(E, FFClassName), ParmString(0)]);
  FreeEdict(E);
end;

procedure TQuakeProgs.PF_vlen;
begin
  Global(OFS_RETURN)^.F := GlobalVector(OFS_PARM0).Length;
end;

procedure TQuakeProgs.PF_vectoyaw;
var
  V: TVector3;
  Yaw: Single;
begin
  V := GlobalVector(OFS_PARM0);
  if (V.X = 0) and (V.Y = 0) then
    Yaw := 0
  else
  begin
    Yaw := Trunc(RadToDeg(ArcTan2(V.Y, V.X)));
    if Yaw < 0 then
      Yaw := Yaw + 360;
  end;
  Global(OFS_RETURN)^.F := Yaw;
end;

procedure TQuakeProgs.PF_spawn;
begin
  Global(OFS_RETURN)^.I := AllocEdict;
end;

procedure TQuakeProgs.PF_remove;
begin
  FreeEdict(Global(OFS_PARM0)^.I);
end;

procedure TQuakeProgs.PF_traceline;
var
  Fraction: Single;
  EndPos, Normal: TVector3;
  Hit: Integer;
  AllSolid, StartSolid, InOpen, InWater: Boolean;
begin
  FHost.TraceLine(Self, GlobalVector(OFS_PARM0), GlobalVector(OFS_PARM0 + 3),
    Round(Global(OFS_PARM0 + 6)^.F), Global(OFS_PARM0 + 9)^.I,
    Fraction, EndPos, Normal, Hit, AllSolid, StartSolid, InOpen, InWater);
  Global(FGTraceAllSolid)^.F := Ord(AllSolid);
  Global(FGTraceStartSolid)^.F := Ord(StartSolid);
  Global(FGTraceFraction)^.F := Fraction;
  Global(FGTraceInOpen)^.F := Ord(InOpen);
  Global(FGTraceInWater)^.F := Ord(InWater);
  SetGlobalVector(FGTraceEndPos, EndPos);
  SetGlobalVector(FGTracePlaneNormal, Normal);
  Global(FGTracePlaneDist)^.F := TVector3.DotProduct(Normal, EndPos);
  Global(FGTraceEnt)^.I := Hit;
end;

procedure TQuakeProgs.PF_checkclient;
begin
  { The player is entity 1 when there is one }
  if (FNumEdicts > 1) and not FEdictFree[1] then
    Global(OFS_RETURN)^.I := 1
  else
    Global(OFS_RETURN)^.I := 0;
end;

procedure TQuakeProgs.PF_find;
var
  E, F: Integer;
  S: String;
begin
  { find(start, field, string): the next entity whose string field matches }
  E := Global(OFS_PARM0)^.I;
  F := Global(OFS_PARM0 + 3)^.I;
  S := ParmString(2);
  for E := E + 1 to FNumEdicts - 1 do
    if not FEdictFree[E] and (FieldString(E, F) = S) then
    begin
      Global(OFS_RETURN)^.I := E;
      Exit;
    end;
  Global(OFS_RETURN)^.I := 0;
end;

procedure TQuakeProgs.PF_precache;
var
  I: Integer;
  S: String;
begin
  { precache_model / precache_sound / precache_file (and the *2 ones) }
  Global(OFS_RETURN)^.I := Global(OFS_PARM0)^.I;
  I := FCurrentBuiltin;
  S := ParmString(0);
  if S = '' then
    Exit;
  case I of
    20, 75:
      if PrecachedModels.IndexOf(S) < 0 then
        PrecachedModels.Add(S);
    19, 76:
      if PrecachedSounds.IndexOf(S) < 0 then
        PrecachedSounds.Add(S);
  end;
end;

procedure TQuakeProgs.PF_stuffcmd;
begin
  FHost.StuffCmd(Self, Global(OFS_PARM0)^.I, ParmString(1));
end;

procedure TQuakeProgs.PF_findradius;
var
  Org, EOrg: TVector3;
  Rad: Single;
  E, Chain: Integer;
begin
  { findradius(origin, radius): a chain of the entities within reach }
  Org := GlobalVector(OFS_PARM0);
  Rad := Global(OFS_PARM0 + 3)^.F;
  Chain := 0;
  for E := 1 to FNumEdicts - 1 do
  begin
    if FEdictFree[E] or (Field(E, FFSolid)^.F = 0) then
      Continue;
    EOrg := FieldVector(E, FFOrigin) + (FieldVector(E, FFMins) + FieldVector(E, FFMaxs)) * 0.5;
    if PointsDistance(Org, EOrg) > Rad then
      Continue;
    Field(E, FFChain)^.I := Chain;
    Chain := E;
  end;
  Global(OFS_RETURN)^.I := Chain;
end;

procedure TQuakeProgs.PF_bprint;
begin
  FHost.Print(Self, ParmString(0));
end;

procedure TQuakeProgs.PF_sprint;
begin
  FHost.Print(Self, ParmString(1));
end;

procedure TQuakeProgs.PF_dprint;
begin
  WritelnLog('QuakeC', Trim(ParmString(0)));
end;

procedure TQuakeProgs.PF_ftos;
var
  V: Single;
  S: String;
begin
  V := Global(OFS_PARM0)^.F;
  if V = Trunc(V) then
    S := IntToStr(Trunc(V))
  else
    S := FormatFloat('0.0', V);
  Global(OFS_RETURN)^.I := TempString(S);
end;

procedure TQuakeProgs.PF_vtos;
var
  V: TVector3;
begin
  V := GlobalVector(OFS_PARM0);
  Global(OFS_RETURN)^.I := TempString(Format('''%5.1f %5.1f %5.1f''', [V.X, V.Y, V.Z]));
end;

procedure TQuakeProgs.PF_coredump;
begin
  WritelnLog('QuakeProgs', 'coredump: %d edicts', [FNumEdicts]);
end;

procedure TQuakeProgs.PF_traceon;
begin
  FTrace := True;
end;

procedure TQuakeProgs.PF_traceoff;
begin
  FTrace := False;
end;

procedure TQuakeProgs.PF_eprint;
var
  E: Integer;
begin
  E := Global(OFS_PARM0)^.I;
  WritelnLog('QuakeProgs', 'edict %d: %s', [E, FieldString(E, FFClassName)]);
end;

procedure TQuakeProgs.PF_walkmove;
var
  E, OldSelf, OldOther: Integer;
begin
  E := Global(FGSelf)^.I;
  OldSelf := Global(FGSelf)^.I;
  OldOther := Global(FGOther)^.I;
  Global(OFS_RETURN)^.F := Ord(FHost.WalkMove(Self, E, Global(OFS_PARM0)^.F, Global(OFS_PARM0 + 3)^.F));
  Global(FGSelf)^.I := OldSelf;
  Global(FGOther)^.I := OldOther;
end;

procedure TQuakeProgs.PF_droptofloor;
begin
  Global(OFS_RETURN)^.F := Ord(FHost.DropToFloor(Self, Global(FGSelf)^.I));
end;

procedure TQuakeProgs.PF_lightstyle;
begin
  FHost.LightStyle(Self, Round(Global(OFS_PARM0)^.F), ParmString(1));
end;

procedure TQuakeProgs.PF_rint;
var
  F: Single;
begin
  F := Global(OFS_PARM0)^.F;
  if F > 0 then
    Global(OFS_RETURN)^.F := Trunc(F + 0.5)
  else
    Global(OFS_RETURN)^.F := Trunc(F - 0.5);
end;

procedure TQuakeProgs.PF_floor;
begin
  Global(OFS_RETURN)^.F := Floor(Global(OFS_PARM0)^.F);
end;

procedure TQuakeProgs.PF_ceil;
begin
  Global(OFS_RETURN)^.F := Ceil(Global(OFS_PARM0)^.F);
end;

procedure TQuakeProgs.PF_checkbottom;
begin
  Global(OFS_RETURN)^.F := Ord(FHost.CheckBottom(Self, Global(OFS_PARM0)^.I));
end;

procedure TQuakeProgs.PF_pointcontents;
begin
  Global(OFS_RETURN)^.F := FHost.PointContents(Self, GlobalVector(OFS_PARM0));
end;

procedure TQuakeProgs.PF_fabs;
begin
  Global(OFS_RETURN)^.F := Abs(Global(OFS_PARM0)^.F);
end;

procedure TQuakeProgs.PF_aim;
begin
  { Straight ahead; the auto aim is a client option }
  PF_makevectors;
  SetGlobalVector(OFS_RETURN, GlobalVector(FGVForward));
end;

procedure TQuakeProgs.PF_cvar;
begin
  Global(OFS_RETURN)^.F := FHost.Cvar(Self, ParmString(0));
end;

procedure TQuakeProgs.PF_localcmd;
begin
  FHost.LocalCmd(Self, ParmString(0));
end;

procedure TQuakeProgs.PF_nextent;
var
  E: Integer;
begin
  E := Global(OFS_PARM0)^.I;
  repeat
    Inc(E);
    if E >= FNumEdicts then
    begin
      Global(OFS_RETURN)^.I := 0;
      Exit;
    end;
  until not FEdictFree[E];
  Global(OFS_RETURN)^.I := E;
end;

procedure TQuakeProgs.PF_particle;
begin
  FHost.Particle(Self, GlobalVector(OFS_PARM0), GlobalVector(OFS_PARM0 + 3),
    Round(Global(OFS_PARM0 + 6)^.F), Round(Global(OFS_PARM0 + 9)^.F));
end;

procedure TQuakeProgs.PF_changeyaw;
var
  E: Integer;
  Current, Ideal, Speed, Move: Single;
begin
  { Turn self towards ideal_yaw by at most yaw_speed }
  E := Global(FGSelf)^.I;
  Current := FloatModulo(Field(E, FFAngles + 1)^.F, 360);
  Ideal := Field(E, FFIdealYaw)^.F;
  Speed := Field(E, FFYawSpeed)^.F;
  if Current = Ideal then
    Exit;
  Move := Ideal - Current;
  if Ideal > Current then
  begin
    if Move >= 180 then
      Move := Move - 360;
  end else
  begin
    if Move <= -180 then
      Move := Move + 360;
  end;
  if Move > 0 then
  begin
    if Move > Speed then
      Move := Speed;
  end else
  begin
    if Move < -Speed then
      Move := -Speed;
  end;
  Field(E, FFAngles + 1)^.F := FloatModulo(Current + Move, 360);
end;

procedure TQuakeProgs.PF_vectoangles;
var
  V: TVector3;
  Yaw, Pitch, Fwd: Single;
begin
  V := GlobalVector(OFS_PARM0);
  if (V.X = 0) and (V.Y = 0) then
  begin
    Yaw := 0;
    if V.Z > 0 then
      Pitch := 90
    else
      Pitch := 270;
  end else
  begin
    Yaw := Trunc(RadToDeg(ArcTan2(V.Y, V.X)));
    if Yaw < 0 then
      Yaw := Yaw + 360;
    Fwd := Sqrt(V.X * V.X + V.Y * V.Y);
    Pitch := Trunc(RadToDeg(ArcTan2(V.Z, Fwd)));
    if Pitch < 0 then
      Pitch := Pitch + 360;
  end;
  SetGlobalVector(OFS_RETURN, Vector3(Pitch, Yaw, 0));
end;

procedure TQuakeProgs.PF_WriteByte;
begin
  FHost.WriteMessage(Self, Round(Global(OFS_PARM0)^.F), 52, Vector3(Global(OFS_PARM0 + 3)^.F, 0, 0), '');
end;

procedure TQuakeProgs.PF_WriteChar;
begin
  FHost.WriteMessage(Self, Round(Global(OFS_PARM0)^.F), 53, Vector3(Global(OFS_PARM0 + 3)^.F, 0, 0), '');
end;

procedure TQuakeProgs.PF_WriteShort;
begin
  FHost.WriteMessage(Self, Round(Global(OFS_PARM0)^.F), 54, Vector3(Global(OFS_PARM0 + 3)^.F, 0, 0), '');
end;

procedure TQuakeProgs.PF_WriteLong;
begin
  FHost.WriteMessage(Self, Round(Global(OFS_PARM0)^.F), 55, Vector3(Global(OFS_PARM0 + 3)^.F, 0, 0), '');
end;

procedure TQuakeProgs.PF_WriteCoord;
begin
  FHost.WriteMessage(Self, Round(Global(OFS_PARM0)^.F), 56, Vector3(Global(OFS_PARM0 + 3)^.F, 0, 0), '');
end;

procedure TQuakeProgs.PF_WriteAngle;
begin
  FHost.WriteMessage(Self, Round(Global(OFS_PARM0)^.F), 57, Vector3(Global(OFS_PARM0 + 3)^.F, 0, 0), '');
end;

procedure TQuakeProgs.PF_WriteString;
begin
  FHost.WriteMessage(Self, Round(Global(OFS_PARM0)^.F), 58, TVector3.Zero, ParmString(1));
end;

procedure TQuakeProgs.PF_WriteEntity;
begin
  FHost.WriteMessage(Self, Round(Global(OFS_PARM0)^.F), 59, Vector3(Global(OFS_PARM0 + 3)^.I, 0, 0), '');
end;

procedure TQuakeProgs.PF_movetogoal;
begin
  FHost.MoveToGoal(Self, Global(FGSelf)^.I, Global(OFS_PARM0)^.F);
end;

procedure TQuakeProgs.PF_makestatic;
begin
  FHost.MakeStatic(Self, Global(OFS_PARM0)^.I);
end;

procedure TQuakeProgs.PF_changelevel;
begin
  FHost.ChangeLevel(Self, ParmString(0));
end;

procedure TQuakeProgs.PF_cvar_set;
begin
  FHost.CvarSet(Self, ParmString(0), ParmString(1));
end;

procedure TQuakeProgs.PF_centerprint;
var
  S: String;
  I: Integer;
begin
  S := '';
  for I := 1 to FArgC - 1 do
    S := S + ParmString(I);
  FHost.CenterPrint(Self, Global(OFS_PARM0)^.I, S);
end;

procedure TQuakeProgs.PF_ambientsound;
begin
  FHost.AmbientSound(Self, GlobalVector(OFS_PARM0), ParmString(1), Global(OFS_PARM0 + 6)^.F,
    Global(OFS_PARM0 + 9)^.F);
end;

procedure TQuakeProgs.PF_setspawnparms;
begin
end;

procedure TQuakeProgs.PF_Fixme;
begin
  Error('unimplemented builtin');
end;

end.
