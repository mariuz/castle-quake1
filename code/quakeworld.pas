{ Quake 1 gameplay simulation: weapons, inventory, combat, monster AI,
  pickups, doors, lifts, and world interactions. }
unit QuakeWorld;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math,
  CastleVectors, CastleTransform, CastleScene, CastleLog, CastleColors, CastleQuaternions,
  QuakeBsp, QuakeGeometry, QuakeMdl, QuakeLight, QuakeSound, QuakeHud,
  QuakeParticles, QuakeEntities, QuakeAmbient, QuakePhysics, QuakeMonsters, QuakePak, QuakeSaveGame, QuakeDemo,
  QuakeBehaviors, QuakeDebug, QuakeRecords;

type
  { A moment of a run: the time in the level, the origin and the yaw
    (Quake coordinates) }
  TGhostSample = packed record
    T, X, Y, Z, Yaw: Single;
  end;

var
  { Show the level time to the hundredth and the split at the end
    (Options, console speedrun) }
  SpeedrunTimer: Boolean = False;
  { Record the runs and show the map's best one as a ghost (Options,
    console ghost) }
  GhostRacing: Boolean = False;

type
  { World simulation manager }
  TQuakeWorld = class
  private
    FBsp: TQuakeBsp;
    FGeometry: TQuakeGeometry;
    FRootTransform: TCastleTransform;
    FPickups: TQuakePickupList;
    FMonsters: TQuakeMonsterList;
    FProjectiles: TQuakeProjectileList;
    FGibs: TQuakeGibList;
    FTriggers: TQuakeTriggerList;
    FTriggerRoot: TCastleTransform; { the triggers' transforms for the inspector }
    FDebug: TQuakeDebugOverlay;
    FAmbient: TQuakeAmbientSounds;
    FPlayerStats: TQuakePlayerStats;
    FPlayerPos: TVector3;
    FPlayerFacing: Single;
    FPlayerPitch: Single;
    FWeaponScene: TCastleScene;
    FWeaponMdl: TQuakeMdl;
    FWeaponAnim: TMdlAnimator;
    FWeaponTransform: TCastleTransform;
    FWeaponModelName: String;
    FWeaponRecoil: Single;
    FWeaponCooldown: Single;
    FLevelExited: Boolean;
    FNextMap: String;
    FSpawnPoint: TVector3;
    FSpawnAngle: Single;
    FGodMode: Boolean;
    FPlayerDead: Boolean;
    FPhys: TQuakePlayerPhysics;
    FSpawnOrigin: TVector3;     { Quake coordinates }
    FLastSubOffsets: array of TVector3;
    FTime: Single;
    FPendingYaw: Single;
    FHasPendingYaw: Boolean;
    { QuakeC WaterMove state }
    FAirFinished, FDmgTime, FPainFinished: Single;
    FDrownDamage: Integer;
    FInWater: Boolean;
    { Weapons }
    FNailOffset: Single;        { nails alternate between the two barrels }
    FLightningSoundTime: Single;
    FLightningFiring: Boolean;
    FLastLightningTime: Single;
    { Lightning beams: 0 = player (bolt2), 1 = shambler (bolt), 2 = Chthon electrodes (bolt3) }
    FBeams: array[0..2] of record
      Segments: array of TCastleTransform;
      Time: Single;
    end;
    FMonsterEnv: TQuakeMonsterEnv;
    FHud: TQuakeHud;            { HUD of the current frame, for monster damage flashes }
    FLightningEvents: TStringList; { targetnames of event_lightning entities }
    FLightningEnd: Single;
    FShowHostile: Single;       { monsters notice the player behind them until then }
    { Game state kept across levels }
    FSkill: Integer;            { 0 easy, 1 normal, 2 hard, 3 nightmare }
    FServerFlags: Integer;      { episode runes collected (bits 1, 2, 4, 8) }
    { parm1..parm16: the player as they entered the level, restored on death }
    FLevelStartStats: TQuakePlayerStats;
    FLevelStartServerFlags: Integer;
    FLevelStartValid: Boolean;
    FViewForward: TVector3;     { horizontal view direction, Quake coordinates }
    { Intermission: the camera looks from an info_intermission spot while the
      tallies are shown; the next map loads when the player presses a button }
    FIntermission: Boolean;
    FIntermissionExitTime: Single;
    FIntermissionMap: String;
    FIntermissionEye, FIntermissionDir: TVector3; { CGE coordinates }
    { intermission_running: 1 the tallies, 2 the episode text, 3 the text once
      all four runes are held; the next map after the last one shown }
    FIntermissionStage: Integer;
    { The ending: the player telefragged Shub-Niggurath (finale_1 .. finale_4
      of oldone.qc), then the game is over }
    FFinaleStage: Integer;
    FFinaleTime: Single;
    FFinaleBoss: TQuakeMonster;
    FGameOver: Boolean;
    { misc_teleporttrain (end.bsp): the spiked ball along its path_corners,
      the destination of the teleporter into Shub-Niggurath }
    FTrain: TCastleTransform;
    FTrainName: String;
    FTrainCorners: array of TVector3;
    FTrainWaits: array of Single;
    FTrainNext: Integer;
    FTrainOrigin: TVector3;
    FTrainSpeed, FTrainWait: Single;
    FTrainAngles: TVector3;
    { Demo recording }
    FRecorder: TQuakeDemoWriter;
    FRecordUrl: String;
    FRecordMuzzle: Boolean;
    FRecordHud: TQuakeHud;
    { Horde mode (quakeworld_horde.inc) }
    FHordeMode, FHordeActive, FHordeFighting: Boolean;
    FHordeWave, FHordeScore, FHordeToSpawn, FHordeAlive, FHordeMoves: Integer;
    FHordeTimer, FHordeSpawnTimer: Single;
    FHordeSpots: array of TVector3;
    { Speedrun timer and ghost racing (quakeworld_ghost.inc) }
    FGhostRec, FGhostRun: array of TGhostSample;
    FGhostRecTimer, FGhostBest, FGhostDelta, FGhostDeltaTime: Single;
    FGhostRecValid, FRunFinished: Boolean;
    FGhostNextCheck: Integer;
    FGhostTransform: TCastleTransform;
    FGhostScene: TCastleScene;
    FGhostAnimator: TMdlAnimator;
    FGhostRunSeq, FGhostStandSeq: TMdlSequence;
    FLockedTimer: Single;       { attack_finished of the last locked door message }
    procedure UpdateDebugOverlay;
    procedure BeginIntermissionView;
    function EpisodeText: String;
    procedure StartShubFinale(const Boss: TQuakeMonster);
    procedure UpdateFinale;
    procedure SpawnTeleportTrain(const Ent: TQuakeEntity);
    procedure UpdateTeleportTrain(const SecondsPassed: Single);
    { tdeath: whatever stands where the player teleported to dies; Shub-Niggurath
      starts the ending }
    procedure Telefrag(const Dest: TVector3);
    procedure UpdateSolids;
    procedure CarryPlayerWithMovers;
    procedure TouchMovers;
    { door_touch of a key door: opens it with the key (used up), else the
      "You need the ... key" message; True when it opened }
    function TouchKeyDoor(const Sub: TQuakeSubmodel): Boolean;
    function WorldType: Integer;
    procedure PlayerWaterRules(const Hud: TQuakeHud);
    function SubmodelBounds(const Sub: TQuakeSubmodel; out AMins, AMaxs: TVector3): Boolean;
    procedure PlayerBox(out AMins, AMaxs: TVector3);
    procedure UseTargets(const Target: String);
    { Quake bounding box of a living monster (False for corpses) }
    function MonsterBounds(const M: TQuakeMonster; out AMins, AMaxs: TVector3): Boolean;
    { Point trace against world, brush entities and monsters (traceline) }
    function TraceShot(const Start, Stop: TVector3; out HitMonster: TQuakeMonster): TQuakeTrace;
    { Same, for monster missiles: skips the owner and can hit the player }
    function TraceMissile(const Start, Stop: TVector3; const Owner: TObject;
      out HitMonster: TQuakeMonster; out HitPlayer: Boolean): TQuakeTrace;
    { CanDamage: the explosion can see the target center or one of its corners }
    function CanDamage(const Inflictor, TargetCenter: TVector3): Boolean;
    { T_RadiusDamage from an explosion at Center (Quake coordinates) }
    procedure RadiusDamage(const Center: TVector3; const Damage: Single;
      const Ignore: TQuakeMonster; const Hud: TQuakeHud; const PlayerAttacker: Boolean = True;
      const IgnorePlayer: Boolean = False; const Attacker: TQuakeMonster = nil);
    { Attacker = nil for the player }
    procedure DamageMonster(const M: TQuakeMonster; const Damage: Single; const From: TVector3;
      const Attacker: TQuakeMonster = nil);
    procedure FireBullets(const Count: Integer; const Src, Dir, Right, Up: TVector3;
      const SpreadX, SpreadY: Single);
    procedure LaunchSpike(const Kind: TQuakeProjectileKind; const Src, Dir: TVector3);
    procedure FireLightning(const Src, Dir: TVector3; const Hud: TQuakeHud);
    procedure ShowBeam(const Pool: Integer; const StartQ, StopQ: TVector3; const Duration: Single);
    { Monster support (TWorldMonsterEnv) }
    function MonsterTrace(const M: TQuakeMonster; const Start, Stop: TVector3): TQuakeTrace;
    function MonsterCheckBottom(const M: TQuakeMonster): Boolean;
    function MonsterMoveStep(const M: TQuakeMonster; const Move: TVector3): Boolean;
    function MonsterTossStep(const M: TQuakeMonster; const Dt: Single; out HitPlayer: Boolean;
      out HitMonster: TQuakeMonster): Boolean;
    procedure MonsterDropToFloor(const M: TQuakeMonster);
    function MonsterCanSeePlayer(const M: TQuakeMonster): Boolean;
    function MonsterCanSeeMonster(const M, Other: TQuakeMonster): Boolean;
    function MonsterSightEntity(const M: TQuakeMonster): TQuakeMonster;
    procedure MonsterFireBullets(const M: TQuakeMonster; const Count: Integer; const Spread: Single;
      const Target: TVector3);
    procedure MonsterLaunch(const M: TQuakeMonster; const Kind: TMonsterAttack; const Org, Vel: TVector3);
    procedure MonsterLightning(const M: TQuakeMonster; const Target: TVector3);
    { Weapon noise: wakes idle monsters that could hear the shot }
    procedure PropagateNoise;
    { A brush entity (closed door) crosses the line }
    function BrushModelBlocks(const Start, Stop: TVector3): Boolean;
    procedure MonsterExplode(const M: TQuakeMonster);
    { event_lightning (E1M7): electrodes shock Chthon }
    procedure LightningEvent;
    procedure ExplodeProjectile(const P: TQuakeProjectile; const Direct: TQuakeMonster;
      const Hud: TQuakeHud; const DirectPlayer: Boolean = False);
    procedure UpdateProjectiles(const SecondsPassed: Single; const Hud: TQuakeHud);
    { Burst a monster into head and gibs (ThrowHead / ThrowGib) }
    procedure GibMonster(const M: TQuakeMonster);
    procedure UpdateGibs(const SecondsPassed: Single);
    procedure PressButton(const Sub: TQuakeSubmodel);
    procedure SpawnEntities;
    procedure StartHorde;
    procedure FreeGhost;
    procedure SetupGhost;
    procedure UpdateGhostPose;
    procedure UpdateGhost(const SecondsPassed: Single);
    procedure FinishRun;
    { Map records: this finished level's time, kills and secrets }
    procedure FinishRecord;
    function HordeClass: String;
    function HordeSpot(const Def: TMonsterDef; const AllowVisible: Boolean; out Spot: TVector3): Boolean;
    function SpawnHordeMonster(const AClassName: String): Boolean;
    procedure UpdateHorde(const SecondsPassed: Single);
    procedure HordeKill(const M: TQuakeMonster);
    function OwnsProjectile(const M: TQuakeMonster): Boolean;
    procedure UpdateWeaponModel;
    procedure ResetPlayerStats;
    procedure CheckPickups(const Hud: TQuakeHud);
    procedure CheckTriggers;
    { SetChangeParms: what the player keeps when leaving a level }
    procedure SetChangeParms;
    { func_episodegate / func_bossgate follow the collected runes }
    procedure ApplyEpisodeGates;
    function IsStartMap: Boolean;
    procedure StartIntermission(const NextMap: String);
    function ViewAnglesQuake: TVector3;
    procedure RecordLevelStart;
    procedure RecordFrame;
    procedure RecordSound(const APath: String; const Spatial: Boolean; const ATransform: TCastleTransform;
      const Volume: Single);
    procedure RecordEffect(const Kind: String; const Pos, Normal: TVector3);
    procedure RecordMessage(const S: String);
  public
    { View bob (V_CalcBob) the view sets: the weapon moves forward by 0.4 of it }
    WeaponBob: Single;
    constructor Create(const ARoot: TCastleTransform);
    destructor Destroy; override;

    { Load a map and initialize the world simulation }
    function LoadMap(const AMapName: String): Boolean;

    { Advance world simulation by SecondsPassed }
    { Draw only the monsters, items, missiles, gibs and brush entities in
      the camera's PVS (after Geometry.UpdateVisibility, each frame) }
    procedure CullEntities;
    procedure Update(const SecondsPassed: Single; const PlayerPos: TVector3;
      const PlayerFacing, PlayerPitch: Single; const Hud: TQuakeHud);

    { Player fires currently equipped weapon }
    procedure FireWeapon(const RayOrigin, RayDir: TVector3; const Hud: TQuakeHud);

    { Select weapon slot (1..8) }
    procedure SelectWeapon(const Slot: Integer; const Hud: TQuakeHud = nil);
    { impulse 10 / 12: the next (Direction 1) or previous (-1) weapon owned }
    procedure SelectNextWeapon(const Direction: Integer; const Hud: TQuakeHud = nil);

    { Activate nearby button, door, or switch }
    procedure ActivateUse(const RayOrigin, RayDir: TVector3; const Hud: TQuakeHud);

    { Cheat: give all weapons, keys, max ammo }
    procedure CheatGiveAll(const Hud: TQuakeHud);

    { Cheat: toggle god mode }
    procedure CheatGodMode(const Hud: TQuakeHud);

    { Hurt the player (T_Damage): armor absorbs part of the damage }
    procedure DamagePlayer(const Damage: Integer; const Hud: TQuakeHud);

    { Run Quake player physics for one frame. ViewDir is the camera direction
      (CGE coordinates). Afterwards PlayerEyePosition is the new camera position. }
    procedure MovePlayer(const Cmd: TQuakeUserCmd; const ViewDir: TVector3;
      const SecondsPassed: Single; const Hud: TQuakeHud);

    { Move the player so that the eyes are at a CGE position (debug / autotest) }
    procedure SetPlayerEyePosition(const Eye: TVector3);

    { Camera position for the player's eyes (CGE coordinates) }
    function PlayerEyePosition: TVector3;
    { The player's velocity, Quake coordinates (units / s) }
    function PlayerVelocity: TVector3;

    { The view should turn to this yaw (after a teleport); returns False if not }
    function TakePendingYaw(out Yaw: Single): Boolean;

    { Restore starting health, weapons and ammo (after death) }
    procedure RespawnPlayer;

    { New game: starting inventory, normal skill, no runes }
    procedure NewGame;

    { Fire, jump or use pressed during the intermission: go to the next map
      once the tallies had their time (IntermissionThink) }
    procedure IntermissionContinue;

    { Savegames: the level, the player, doors and plats, items, monsters and
      triggers. Not while dead or in the intermission. ViewDir is the camera
      direction (CGE coordinates). }
    function CanSave: Boolean;
    function SaveGame(const Url: String; const ViewDir: TVector3): Boolean;
    { Loads the saved map and puts everything back; ViewDir returns the
      saved camera direction }
    function LoadGame(const Url: String; out ViewDir: TVector3): Boolean;
    function MapName: String;

    { Demo recording (NetQuake protocol .dem) of everything from now on }
    function StartRecording(const Url: String): Boolean;
    procedure StopRecording;
    { A fog or skybox change during the level (the console), recorded when
      a demo is being recorded }
    procedure RecordFog(const Density: Single; const Color: TVector3);
    procedure RecordSkybox(const Name: String);
    function Recording: Boolean;

    { Contents (CONTENTS_xxx) at a point in CGE coordinates, CONTENTS_EMPTY without a map }
    function PointContents(const P: TVector3): Integer;

    { Attach viewmodel weapon directly to camera }
    procedure AttachWeaponToCamera(const Camera: TCastleTransform);

    property Stats: TQuakePlayerStats read FPlayerStats write FPlayerStats;
    property SpawnPoint: TVector3 read FSpawnPoint;
    property SpawnAngle: Single read FSpawnAngle;
    property LevelExited: Boolean read FLevelExited;
    property PlayerDead: Boolean read FPlayerDead;
    property Physics: TQuakePlayerPhysics read FPhys;
    property GodMode: Boolean read FGodMode;
    property NextMap: String read FNextMap;
    property Skill: Integer read FSkill write FSkill;
    property ServerFlags: Integer read FServerFlags write FServerFlags;
    property Intermission: Boolean read FIntermission;
    { The ending was played and dismissed: back to the menu }
    property GameOver: Boolean read FGameOver;
    property IntermissionEye: TVector3 read FIntermissionEye;
    property IntermissionDir: TVector3 read FIntermissionDir;
    property Monsters: TQuakeMonsterList read FMonsters;
    { Horde mode for the maps loaded from now on: waves of monsters instead
      of the map's, no exits (set before LoadMap) }
    property HordeMode: Boolean read FHordeMode write FHordeMode;
    property HordeActive: Boolean read FHordeActive;
    property HordeWave: Integer read FHordeWave;
    property HordeScore: Integer read FHordeScore;
    { The HUD line: wave, monsters left, score ('' outside horde mode) }
    function HordeText: String;
    { Cheat: every monster dies (console killall) }
    procedure KillAllMonsters;
    { The HUD line of the speedrun timer and the ghost's split ('' when
      neither shows) }
    function SpeedrunText: String;
    { Forget the map's best run (console ghost_reset) }
    procedure ResetGhost;
  public
    { Debug overlay over the level: trigger volumes, monster boxes and
      sight lines, mover bounds, the player's BSP leaf and box }
    DebugModes: TQuakeDebugModes;
    property Pickups: TQuakePickupList read FPickups;
    property WeaponTransform: TCastleTransform read FWeaponTransform;
    property Bsp: TQuakeBsp read FBsp;
    property Geometry: TQuakeGeometry read FGeometry;
  end;

implementation

uses
  CastleDownload, CastleUriUtils, X3DNodes, StrUtils, GameTranslate;

const
  { Trace entity numbers of monsters: MonsterEntityBase - index in FMonsters }
  MonsterEntityBase = -100;

function SubmodelIsSolid(const Sub: TQuakeSubmodel): Boolean; forward;

{$I world/quakeworld_monsters.inc}
{$I world/quakeworld_game.inc}
{$I world/quakeworld_save.inc}
{$I world/quakeworld_record.inc}
{$I world/quakeworld_movers.inc}
{$I world/quakeworld_debug.inc}
{$I world/quakeworld_player.inc}
{$I world/quakeworld_weapons.inc}
{$I world/quakeworld_map.inc}
{$I world/quakeworld_pickups.inc}
{$I world/quakeworld_horde.inc}
{$I world/quakeworld_ghost.inc}

end.
