{ Quake 1 gameplay simulation: weapons, inventory, combat, monster AI,
  pickups, doors, lifts, and world interactions. }
unit QuakeWorld;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math,
  CastleVectors, CastleTransform, CastleScene, CastleLog, CastleColors, CastleQuaternions,
  QuakeBsp, QuakeGeometry, QuakeMdl, QuakeLight, QuakeSound, QuakeHud,
  QuakeParticles, QuakeEntities, QuakeAmbient, QuakePhysics, QuakeMonsters, QuakePak;

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
    procedure UpdateSolids;
    procedure CarryPlayerWithMovers;
    procedure TouchMovers;
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
  public
    constructor Create(const ARoot: TCastleTransform);
    destructor Destroy; override;

    { Load a map and initialize the world simulation }
    function LoadMap(const AMapName: String): Boolean;

    { Advance world simulation by SecondsPassed }
    procedure Update(const SecondsPassed: Single; const PlayerPos: TVector3;
      const PlayerFacing, PlayerPitch: Single; const Hud: TQuakeHud);

    { Player fires currently equipped weapon }
    procedure FireWeapon(const RayOrigin, RayDir: TVector3; const Hud: TQuakeHud);

    { Select weapon slot (1..8) }
    procedure SelectWeapon(const Slot: Integer; const Hud: TQuakeHud = nil);

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

    { The view should turn to this yaw (after a teleport); returns False if not }
    function TakePendingYaw(out Yaw: Single): Boolean;

    { Restore starting health, weapons and ammo (after death) }
    procedure RespawnPlayer;

    { New game: starting inventory, normal skill, no runes }
    procedure NewGame;

    { Fire, jump or use pressed during the intermission: go to the next map
      once the tallies had their time (IntermissionThink) }
    procedure IntermissionContinue;

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
    property IntermissionEye: TVector3 read FIntermissionEye;
    property IntermissionDir: TVector3 read FIntermissionDir;
    property Monsters: TQuakeMonsterList read FMonsters;
    property Pickups: TQuakePickupList read FPickups;
    property WeaponTransform: TCastleTransform read FWeaponTransform;
    property Bsp: TQuakeBsp read FBsp;
  end;

implementation

const
  { Trace entity numbers of monsters: MonsterEntityBase - index in FMonsters }
  MonsterEntityBase = -100;

type
  { Gives monsters access to the world (traces, the player, missiles) }
  TWorldMonsterEnv = class(TQuakeMonsterEnv)
  private
    FWorld: TQuakeWorld;
  public
    constructor Create(const AWorld: TQuakeWorld);
    function Time: Single; override;
    function PlayerOrigin: TVector3; override;
    function PlayerVelocity: TVector3; override;
    function PlayerAlive: Boolean; override;
    function CanSeePlayer(const M: TQuakeMonster): Boolean; override;
    function CanSeeMonster(const M, Other: TQuakeMonster): Boolean; override;
    function SightEntity(const M: TQuakeMonster): TQuakeMonster; override;
    function PlayerHostile: Boolean; override;
    function MoveStep(const M: TQuakeMonster; const Move: TVector3): Boolean; override;
    function TossStep(const M: TQuakeMonster; const Dt: Single; out HitPlayer: Boolean;
      out HitMonster: TQuakeMonster): Boolean; override;
    procedure DamagePlayer(const M: TQuakeMonster; const Damage: Single); override;
    procedure DamageMonster(const M, Victim: TQuakeMonster; const Damage: Single); override;
    procedure FireBullets(const M: TQuakeMonster; const Count: Integer; const Spread: Single;
      const Aim: TVector3); override;
    procedure LaunchMissile(const M: TQuakeMonster; const Kind: TMonsterAttack;
      const Org, Vel: TVector3); override;
    procedure CastLightning(const M: TQuakeMonster; const Aim: TVector3); override;
  end;

constructor TWorldMonsterEnv.Create(const AWorld: TQuakeWorld);
begin
  inherited Create;
  FWorld := AWorld;
end;

function TWorldMonsterEnv.Time: Single;
begin
  Result := FWorld.FTime;
end;

function TWorldMonsterEnv.PlayerOrigin: TVector3;
begin
  Result := FWorld.FPhys.Origin;
end;

function TWorldMonsterEnv.PlayerVelocity: TVector3;
begin
  Result := FWorld.FPhys.Velocity;
end;

function TWorldMonsterEnv.PlayerAlive: Boolean;
begin
  Result := not FWorld.FPlayerDead and not FWorld.FIntermission;
end;

function TWorldMonsterEnv.CanSeePlayer(const M: TQuakeMonster): Boolean;
begin
  Result := FWorld.MonsterCanSeePlayer(M);
end;

function TWorldMonsterEnv.CanSeeMonster(const M, Other: TQuakeMonster): Boolean;
begin
  Result := FWorld.MonsterCanSeeMonster(M, Other);
end;

function TWorldMonsterEnv.SightEntity(const M: TQuakeMonster): TQuakeMonster;
begin
  Result := FWorld.MonsterSightEntity(M);
end;

function TWorldMonsterEnv.PlayerHostile: Boolean;
begin
  Result := FWorld.FTime < FWorld.FShowHostile;
end;

function TWorldMonsterEnv.MoveStep(const M: TQuakeMonster; const Move: TVector3): Boolean;
begin
  Result := FWorld.MonsterMoveStep(M, Move);
end;

function TWorldMonsterEnv.TossStep(const M: TQuakeMonster; const Dt: Single;
  out HitPlayer: Boolean; out HitMonster: TQuakeMonster): Boolean;
begin
  Result := FWorld.MonsterTossStep(M, Dt, HitPlayer, HitMonster);
end;

procedure TWorldMonsterEnv.DamagePlayer(const M: TQuakeMonster; const Damage: Single);
begin
  FWorld.DamagePlayer(Max(1, Round(Damage)), FWorld.FHud);
end;

procedure TWorldMonsterEnv.DamageMonster(const M, Victim: TQuakeMonster; const Damage: Single);
begin
  FWorld.DamageMonster(Victim, Damage, M.Origin, M);
end;

procedure TWorldMonsterEnv.FireBullets(const M: TQuakeMonster; const Count: Integer;
  const Spread: Single; const Aim: TVector3);
begin
  FWorld.MonsterFireBullets(M, Count, Spread, Aim);
end;

procedure TWorldMonsterEnv.LaunchMissile(const M: TQuakeMonster; const Kind: TMonsterAttack;
  const Org, Vel: TVector3);
begin
  FWorld.MonsterLaunch(M, Kind, Org, Vel);
end;

procedure TWorldMonsterEnv.CastLightning(const M: TQuakeMonster; const Aim: TVector3);
begin
  FWorld.MonsterLightning(M, Aim);
end;

constructor TQuakeWorld.Create(const ARoot: TCastleTransform);
begin
  inherited Create;
  FRootTransform := ARoot;
  FBsp := nil;
  FGeometry := nil;
  FPickups := TQuakePickupList.Create(True);
  FMonsters := TQuakeMonsterList.Create(True);
  FProjectiles := TQuakeProjectileList.Create(True);
  FGibs := TQuakeGibList.Create(True);
  FMonsterEnv := TWorldMonsterEnv.Create(Self);
  FLightningEvents := TStringList.Create;
  FTriggers := TQuakeTriggerList.Create(True);
  FAmbient := TQuakeAmbientSounds.Create;
  FPhys := TQuakePlayerPhysics.Create;

  FWeaponTransform := TCastleTransform.Create(nil);
  FWeaponScene := nil;

  ResetPlayerStats;

  FWeaponRecoil := 0;
  FWeaponCooldown := 0;
  FLevelExited := False;
  FNextMap := '';
  FSpawnPoint := Vector3(0, 40, 0);
  FSpawnAngle := 0;
  FSkill := 1;
end;

procedure TQuakeWorld.ResetPlayerStats;
begin
  { Default starting player stats }
  FillChar(FPlayerStats, SizeOf(FPlayerStats), 0);
  FPlayerStats.Health := 100;
  FPlayerStats.Armor := 0;
  FPlayerStats.ArmorType := 0;
  FPlayerStats.Shells := 25;
  FPlayerStats.MaxShells := 100;
  FPlayerStats.MaxNails := 200;
  FPlayerStats.MaxRockets := 100;
  FPlayerStats.MaxCells := 100;
  FPlayerStats.Ammo := 25;
  FPlayerStats.AmmoType := 0;
  FPlayerStats.WeaponMask := (1 shl 1) or (1 shl 2); { Axe and Shotgun }
  FPlayerStats.CurrentWeapon := 2;
  FPlayerDead := False;
end;

procedure TQuakeWorld.RespawnPlayer;
begin
  { The single player "restart": the level starts over with the player as
    they entered it }
  if FLevelStartValid then
  begin
    FPlayerStats := FLevelStartStats;
    FServerFlags := FLevelStartServerFlags;
    FPlayerDead := False;
  end else
    ResetPlayerStats;
  UpdateWeaponModel;
end;

procedure TQuakeWorld.NewGame;
begin
  ResetPlayerStats;
  FSkill := 1;
  FServerFlags := 0;
  FLevelStartValid := False;
  UpdateWeaponModel;
end;

procedure TQuakeWorld.SetChangeParms;
begin
  if FPlayerStats.Health <= 0 then
  begin
    ResetPlayerStats;
    Exit;
  end;
  { Keys and powerups stay behind; health is brought to 50 .. 100 }
  FPlayerStats.Keys := 0;
  FPlayerStats.BiosuitTime := 0;
  FPlayerStats.Health := EnsureRange(FPlayerStats.Health, 50, 100);
end;

function TQuakeWorld.IsStartMap: Boolean;
begin
  Result := (FBsp <> nil) and SameText(FBsp.MapName, 'start');
end;

procedure TQuakeWorld.StartIntermission(const NextMap: String);
var
  Spots: TQuakeEntityList;
  Ent, World: TQuakeEntity;
  Angles, Dir: TVector3;
  Title: String;
begin
  { execute_changelevel: freeze the player and look from a random
    info_intermission spot (mangle = pitch yaw roll) }
  FIntermission := True;
  FIntermissionExitTime := FTime + 5;
  FIntermissionMap := NextMap;
  FIntermissionEye := QuakeToCge(FPhys.EyePosition);
  FIntermissionDir := QuakeToCge(FViewForward);
  Spots := FBsp.FindEntities('info_intermission');
  try
    if Spots.Count > 0 then
    begin
      Ent := Spots[Random(Spots.Count)];
      Angles := Ent.GetVector('mangle', TVector3.Zero);
      SinCos(DegToRad(Angles.Y), Dir.Y, Dir.X);
      Dir := Vector3(Dir.X * Cos(DegToRad(Angles.X)), Dir.Y * Cos(DegToRad(Angles.X)),
        -Sin(DegToRad(Angles.X)));
      FIntermissionEye := QuakeToCge(Ent.Origin);
      FIntermissionDir := QuakeToCge(Dir);
    end;
  finally
    Spots.Free;
  end;
  FPhys.Velocity := TVector3.Zero;

  Title := '';
  World := FBsp.FindEntity('worldspawn');
  if World <> nil then
    Title := World.MessageText;
  if FHud <> nil then
    FHud.StartIntermission(Title, FPlayerStats.LevelTime, FPlayerStats.Kills,
      FPlayerStats.TotalKills, FPlayerStats.Secrets, FPlayerStats.TotalSecrets);
  Sounds.PlayMusic('track03.ogg');
end;

procedure TQuakeWorld.IntermissionContinue;
begin
  if not FIntermission or FLevelExited or (FTime < FIntermissionExitTime) then
    Exit;
  FLevelExited := True;
  FNextMap := FIntermissionMap;
end;

procedure TQuakeWorld.ApplyEpisodeGates;
var
  Sub: TQuakeSubmodel;
begin
  { func_episodegate closes the portal of a completed episode;
    func_bossgate opens once all four runes are collected }
  for Sub in FGeometry.Submodels do
    if Sub.EntityClassName = 'func_episodegate' then
      Sub.Transform.Exists := (FServerFlags and Sub.SpawnFlags and 15) <> 0
    else
    if Sub.EntityClassName = 'func_bossgate' then
      Sub.Transform.Exists := (FServerFlags and 15) <> 15;
end;

function TQuakeWorld.PointContents(const P: TVector3): Integer;
begin
  if FBsp <> nil then
    Result := FBsp.PointContentsCge(P)
  else
    Result := CONTENTS_EMPTY;
end;



{ Monsters }

function TQuakeWorld.MonsterTrace(const M: TQuakeMonster; const Start, Stop: TVector3): TQuakeTrace;
var
  Hull, I: Integer;
  ClipOffset, BoxMins, BoxMaxs: TVector3;
  T: TQuakeTrace;
  Other: TQuakeMonster;

  procedure Combine(const Entity: Integer);
  begin
    if T.AllSolid or T.StartSolid or (T.Fraction < Result.Fraction) then
    begin
      if (T.Fraction < 1) or T.StartSolid then
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
  { SV_Move for a monster box: the hull that fits its size, offset by
    clip_mins - mins (SV_HullForEntity), then brush entities, other monsters
    and the player }
  Hull := FBsp.HullForSize(M.Def.Mins, M.Def.Maxs);
  ClipOffset := FBsp.HullClipMins(Hull) - M.Def.Mins;
  Result := FBsp.TraceHull(Hull, 0, ClipOffset, Start, Stop);
  if (Result.Fraction < 1) or Result.StartSolid then
    Result.Entity := 0;
  if Result.AllSolid then
    Exit;

  for I := 0 to High(FPhys.SolidModels) do
  begin
    T := FBsp.TraceHull(Hull, FPhys.SolidModels[I].ModelIndex,
      FPhys.SolidModels[I].Offset + ClipOffset, Start, Stop);
    Combine(FPhys.SolidModels[I].ModelIndex);
  end;

  for I := 0 to FMonsters.Count - 1 do
  begin
    Other := FMonsters[I];
    if (Other <> M) and MonsterBounds(Other, BoxMins, BoxMaxs) then
    begin
      T := TraceSegmentBox(BoxMins - M.Def.Maxs, BoxMaxs - M.Def.Mins, Start, Stop);
      Combine(MonsterEntityBase - I);
    end;
  end;

  if not FPlayerDead then
  begin
    PlayerBox(BoxMins, BoxMaxs);
    T := TraceSegmentBox(BoxMins - M.Def.Maxs, BoxMaxs - M.Def.Mins, Start, Stop);
    Combine(-3);
  end;
end;

function TQuakeWorld.MonsterCheckBottom(const M: TQuakeMonster): Boolean;
var
  AMins, AMaxs, Start, Stop: TVector3;
  T: TQuakeTrace;
  X, Y: Integer;
  Mid: Single;
begin
  { SV_CheckBottom: is there ground under all four corners? }
  AMins := M.Origin + M.Def.Mins;
  AMaxs := M.Origin + M.Def.Maxs;
  Start.Z := AMins.Z - 1;
  Result := True;
  for X := 0 to 1 do
    for Y := 0 to 1 do
    begin
      if X = 0 then Start.X := AMins.X else Start.X := AMaxs.X;
      if Y = 0 then Start.Y := AMins.Y else Start.Y := AMaxs.Y;
      if FBsp.PointContents(Start) <> CONTENTS_SOLID then
        Result := False;
    end;
  if Result then
    Exit;

  { Real check: the corners must be within a step of the middle }
  Start := Vector3((AMins.X + AMaxs.X) * 0.5, (AMins.Y + AMaxs.Y) * 0.5, AMins.Z);
  Stop := Start - Vector3(0, 0, 2 * StepSize);
  T := FPhys.Trace(Start, Stop, True, True);
  if T.Fraction = 1 then
    Exit(False);
  Mid := T.EndPos.Z;
  for X := 0 to 1 do
    for Y := 0 to 1 do
    begin
      if X = 0 then Start.X := AMins.X else Start.X := AMaxs.X;
      if Y = 0 then Start.Y := AMins.Y else Start.Y := AMaxs.Y;
      Stop.X := Start.X;
      Stop.Y := Start.Y;
      T := FPhys.Trace(Start, Stop, True, True);
      if (T.Fraction = 1) or (Mid - T.EndPos.Z > StepSize) then
        Exit(False);
    end;
  Result := True;
end;

function TQuakeWorld.MonsterMoveStep(const M: TQuakeMonster; const Move: TVector3): Boolean;
var
  OldOrg, NewOrg, Stop: TVector3;
  T: TQuakeTrace;
  Dz: Single;
  Cont: Integer;
begin
  Result := False;
  if FBsp = nil then
    Exit;
  OldOrg := M.Origin;

  if M.Def.Move in [mmFly, mmSwim] then
  begin
    { Fliers and swimmers keep a little above the player (SV_movestep) }
    NewOrg := OldOrg + Move;
    if not FPlayerDead then
    begin
      Dz := OldOrg.Z - FPhys.Origin.Z;
      if Dz > 40 then
        NewOrg.Z := NewOrg.Z - Min(8, Dz - 40)
      else if Dz < 30 then
        NewOrg.Z := NewOrg.Z + Min(8, 30 - Dz);
    end;
    T := MonsterTrace(M, OldOrg, NewOrg);
    if T.Fraction < 1 then
    begin
      { Try again without the height change }
      NewOrg.Z := OldOrg.Z + Move.Z;
      T := MonsterTrace(M, OldOrg, NewOrg);
      if T.Fraction < 1 then
        Exit;
    end;
    if M.Def.Move = mmSwim then
    begin
      Cont := FBsp.PointContents(T.EndPos);
      if not ((Cont <= CONTENTS_WATER) and (Cont > CONTENTS_SKY)) then
        Exit; { fish stay in the water }
    end;
    M.Origin := T.EndPos;
    Exit(True);
  end;

  { Walkers: push up a step, trace down two steps }
  NewOrg := OldOrg + Move;
  NewOrg.Z := NewOrg.Z + StepSize;
  Stop := NewOrg;
  Stop.Z := Stop.Z - StepSize * 2;
  T := MonsterTrace(M, NewOrg, Stop);
  if T.AllSolid then
    Exit;
  if T.StartSolid then
  begin
    NewOrg.Z := NewOrg.Z - StepSize;
    T := MonsterTrace(M, NewOrg, Stop);
    if T.AllSolid or T.StartSolid then
      Exit;
  end;
  if T.Fraction = 1 then
    Exit; { walked off an edge }

  M.Origin := T.EndPos;
  if not MonsterCheckBottom(M) then
  begin
    M.Origin := OldOrg;
    Exit;
  end;
  Result := True;
end;

function TQuakeWorld.MonsterTossStep(const M: TQuakeMonster; const Dt: Single;
  out HitPlayer: Boolean; out HitMonster: TQuakeMonster): Boolean;
var
  T: TQuakeTrace;
begin
  { MOVETYPE_TOSS for leaps: gravity, slide on walls, stop on floors }
  HitPlayer := False;
  HitMonster := nil;
  Result := False;
  if FBsp = nil then
    Exit(True);
  M.Velocity.Z := M.Velocity.Z - SvGravity * Dt;
  T := MonsterTrace(M, M.Origin, M.Origin + M.Velocity * Dt);
  if T.AllSolid then
    Exit(True);
  M.Origin := T.EndPos;
  if T.Fraction < 1 then
  begin
    HitPlayer := T.Entity = -3;
    if (T.Entity <= MonsterEntityBase) and (MonsterEntityBase - T.Entity < FMonsters.Count) then
      HitMonster := FMonsters[MonsterEntityBase - T.Entity];
    M.Velocity := ClipVelocity(M.Velocity, T.PlaneNormal, 1);
    if T.PlaneNormal.Z > 0.7 then
      Result := True;
  end;
end;

procedure TQuakeWorld.MonsterDropToFloor(const M: TQuakeMonster);
var
  T: TQuakeTrace;
begin
  { droptofloor: monsters are placed above the floor in the map }
  T := MonsterTrace(M, M.Origin, M.Origin - Vector3(0, 0, 256));
  if (T.Fraction < 1) and not T.AllSolid and not T.StartSolid then
    M.Origin := T.EndPos;
end;

function TQuakeWorld.MonsterCanSeePlayer(const M: TQuakeMonster): Boolean;
begin
  { visible(): line from the monster's eyes to the player's eyes, only
    world geometry and brush entities block it }
  if (FBsp = nil) or FPlayerDead or FIntermission then
    Exit(False);
  Result := FPhys.Trace(M.Origin + Vector3(0, 0, 25), FPhys.EyePosition, True, True).Fraction = 1;
end;

function TQuakeWorld.MonsterCanSeeMonster(const M, Other: TQuakeMonster): Boolean;
begin
  if FBsp = nil then
    Exit(False);
  Result := FPhys.Trace(M.Origin + Vector3(0, 0, 25), Other.Origin + Vector3(0, 0, 25),
    True, True).Fraction = 1;
end;

function TQuakeWorld.MonsterSightEntity(const M: TQuakeMonster): TQuakeMonster;
const
  SightRange = 1000;
var
  Other: TQuakeMonster;
begin
  { sight_entity: a monster that has just found the player wakes up the
    monsters that can see it }
  for Other in FMonsters do
    if (Other <> M) and Other.JustSpottedPlayer and
       (PointsDistance(M.Origin, Other.Origin) < SightRange) and
       MonsterCanSeeMonster(M, Other) then
      Exit(Other);
  Result := nil;
end;

procedure TQuakeWorld.PropagateNoise;
const
  HearRange = 1000;
var
  M: TQuakeMonster;
  Eye: TVector3;
  PlayerLeaf: Integer;
begin
  { Gunfire wakes idle monsters nearby whose leaf is in the player's PVS
    (sound travels through open doorways, not through walls) and that are
    not shut off by a closed door }
  FShowHostile := FTime + 1;
  if FBsp = nil then
    Exit;
  Eye := FPhys.EyePosition;
  PlayerLeaf := FBsp.PointLeaf(Eye);
  for M in FMonsters do
    if (M.State = msIdle) and not M.Ambush and not M.Crucified and
       (PointsDistance(Eye, M.Origin) < HearRange) and
       FBsp.LeafVisible(PlayerLeaf, FBsp.PointLeaf(M.Center)) and
       not BrushModelBlocks(Eye, M.Center) then
      M.HearNoise;
end;

function TQuakeWorld.BrushModelBlocks(const Start, Stop: TVector3): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FPhys.SolidModels) do
    if FBsp.TraceHull(0, FPhys.SolidModels[I].ModelIndex, FPhys.SolidModels[I].Offset,
      Start, Stop).Fraction < 1 then
      Exit(True);
  Result := False;
end;

procedure TQuakeWorld.MonsterFireBullets(const M: TQuakeMonster; const Count: Integer;
  const Spread: Single; const Target: TVector3);
var
  Src, Aim, Right, Up, Dir: TVector3;
  T: TQuakeTrace;
  I, Hits, J: Integer;
  Victim: TQuakeMonster;
  HitPlayer: Boolean;
  Hit: array of TQuakeMonster;
  HitDamage: array of Single;
begin
  { army_fire: pellets with spread towards the target; they hit whatever is
    in the way, other monsters included (multidamage) }
  Src := M.Origin + Vector3(0, 0, 20);
  Aim := (Target - Src).Normalize;
  Right := Vector3(Aim.Y, -Aim.X, 0);
  if Right.IsPerfectlyZero then
    Right := Vector3(1, 0, 0);
  Right := Right.Normalize;
  Up := TVector3.CrossProduct(Right, Aim);
  Hits := 0;
  SetLength(Hit, 0);
  SetLength(HitDamage, 0);
  for I := 1 to Count do
  begin
    Dir := Aim + Right * ((Random * 2 - 1) * Spread) + Up * ((Random * 2 - 1) * Spread);
    T := TraceMissile(Src, Src + Dir * 2048, M, Victim, HitPlayer);
    if HitPlayer then
      Inc(Hits)
    else
    if Victim <> nil then
    begin
      Particles.SpawnBlood(QuakeToCge(T.EndPos - Dir * 4), QuakeToCge(Dir * -1));
      J := 0;
      while (J < Length(Hit)) and (Hit[J] <> Victim) do
        Inc(J);
      if J = Length(Hit) then
      begin
        SetLength(Hit, J + 1);
        SetLength(HitDamage, J + 1);
        Hit[J] := Victim;
        HitDamage[J] := 0;
      end;
      HitDamage[J] := HitDamage[J] + 4;
    end else
    if T.Fraction < 1 then
      Particles.SpawnPuff(QuakeToCge(T.EndPos - Dir * 4), QuakeToCge(T.PlaneNormal));
  end;
  Lighting.TriggerMuzzleFlash(QuakeToCge(Src), 1.5);
  if Hits > 0 then
    DamagePlayer(4 * Hits, FHud);
  for J := 0 to High(Hit) do
    DamageMonster(Hit[J], HitDamage[J], Src, M);
end;

procedure TQuakeWorld.MonsterLaunch(const M: TQuakeMonster; const Kind: TMonsterAttack;
  const Org, Vel: TVector3);
var
  PKind: TQuakeProjectileKind;
  P: TQuakeProjectile;
begin
  case Kind of
    maGrenade: PKind := pjOgreGrenade;
    maWizSpike: PKind := pjWizSpike;
    maKnightSpike: PKind := pjKnightSpike;
    maLaser: PKind := pjLaser;
    maVorePod: PKind := pjVorePod;
    maZombieGib: PKind := pjZombieGib;
    maLavaBall: PKind := pjLavaBall;
    else Exit;
  end;
  P := TQuakeProjectile.Create(FRootTransform, PKind, Org, Vel);
  P.Owner := M;
  FProjectiles.Add(P);
end;

procedure TQuakeWorld.MonsterLightning(const M: TQuakeMonster; const Target: TVector3);
var
  Org, Dir: TVector3;
  T: TQuakeTrace;
  Victim: TQuakeMonster;
  HitPlayer: Boolean;
begin
  { CastLightning (shambler): 600 units towards the target, 10 damage to
    whatever the bolt hits first }
  Org := M.Origin + Vector3(0, 0, 40);
  Dir := (Target + Vector3(0, 0, 16) - Org).Normalize;
  T := TraceMissile(Org, M.Origin + Dir * 600, M, Victim, HitPlayer);
  if HitPlayer then
    DamagePlayer(10, FHud)
  else
  if Victim <> nil then
    DamageMonster(Victim, 10, Org, M);
  ShowBeam(1, Org, T.EndPos, 0.1);
end;

procedure TQuakeWorld.MonsterExplode(const M: TQuakeMonster);
begin
  { tbaby_die: the spawn blows up }
  M.ExplodePending := False;
  M.Transform.Exists := False;
  RadiusDamage(M.Center, 120, M, FHud, False, False, M);
  Particles.SpawnExplosion(QuakeToCge(M.Center));
  Lighting.TriggerMuzzleFlash(QuakeToCge(M.Center), 6.0);
end;

procedure TQuakeWorld.LightningEvent;
var
  Sub, Le1, Le2: TQuakeSubmodel;
  M: TQuakeMonster;
  C1, C2, AMins, AMaxs: TVector3;
begin
  { lightning_use: both electrodes (doors targeting "lightning") must have
    stopped at the same end; at the top the bolt shocks Chthon }
  if FLightningEnd >= FTime + 1 then
    Exit;
  Le1 := nil;
  Le2 := nil;
  for Sub in FGeometry.Submodels do
    if SameText(Sub.Target, 'lightning') then
    begin
      if Le1 = nil then
        Le1 := Sub
      else if Le2 = nil then
        Le2 := Sub;
    end;
  if (Le1 = nil) or (Le2 = nil) then
    Exit;
  if not (Le1.State in [smsOpen, smsClosed]) or (Le1.State <> Le2.State) then
    Exit;

  FLightningEnd := FTime + 1;
  Sounds.Play('sound/misc/power.wav');
  C1 := TVector3.Zero;
  C2 := TVector3.Zero;
  if SubmodelBounds(Le1, AMins, AMaxs) then
    C1 := (AMins + AMaxs) * 0.5;
  if SubmodelBounds(Le2, AMins, AMaxs) then
    C2 := (AMins + AMaxs) * 0.5;
  ShowBeam(2, C1, C2, 1.0);

  if Le1.State = smsOpen then
    for M in FMonsters do
      if M.EntityClassName = 'monster_boss' then
        M.LightningShock;
end;

function SubmodelIsSolid(const Sub: TQuakeSubmodel): Boolean;
begin
  { Triggers and illusionary walls are SOLID_NOT }
  Result := (Pos('trigger_', Sub.EntityClassName) <> 1) and
    (Sub.EntityClassName <> 'func_illusionary') and Sub.Transform.Exists;
end;

function TQuakeWorld.SubmodelBounds(const Sub: TQuakeSubmodel; out AMins, AMaxs: TVector3): Boolean;
var
  Offset: TVector3;
begin
  Result := (FBsp <> nil) and (Sub.ModelIndex > 0) and (Sub.ModelIndex < FBsp.ModelCount);
  if not Result then
    Exit;
  Offset := CgeToQuake(Sub.Transform.Translation);
  AMins := FBsp.Models[Sub.ModelIndex].Mins + Offset;
  AMaxs := FBsp.Models[Sub.ModelIndex].Maxs + Offset;
end;

procedure TQuakeWorld.PlayerBox(out AMins, AMaxs: TVector3);
begin
  AMins := FPhys.Origin + FPhys.Mins;
  AMaxs := FPhys.Origin + FPhys.Maxs;
end;

procedure TQuakeWorld.UseTargets(const Target: String);
var
  Sub: TQuakeSubmodel;
  M: TQuakeMonster;
begin
  { SUB_UseTargets: activate every entity with this targetname }
  if (Target = '') or (FGeometry = nil) then
    Exit;
  for M in FMonsters do
    if SameText(M.TargetName, Target) then
      M.Use;
  if FLightningEvents.IndexOf(Target) >= 0 then
    LightningEvent;
  for Sub in FGeometry.Submodels do
    if SameText(Sub.TargetName, Target) and (Sub.State = smsClosed) then
    begin
      Sub.Trigger;
      Sounds.PlayAt('sound/doors/dr1_strt.wav', Sub.Transform);
    end;
end;

procedure TQuakeWorld.PressButton(const Sub: TQuakeSubmodel);
begin
  { button_fire }
  if Sub.State <> smsClosed then
    Exit;
  Sub.Trigger;
  Sounds.PlayAt('sound/buttons/switch21.wav', Sub.Transform);
  UseTargets(Sub.Target);
end;

procedure TQuakeWorld.UpdateSolids;
var
  Sub: TQuakeSubmodel;
  M: TQuakeMonster;
  N: Integer;
  BoxMins, BoxMaxs: TVector3;
begin
  N := 0;
  SetLength(FPhys.SolidModels, FGeometry.Submodels.Count);
  for Sub in FGeometry.Submodels do
    if SubmodelIsSolid(Sub) then
    begin
      FPhys.SolidModels[N].ModelIndex := Sub.ModelIndex;
      FPhys.SolidModels[N].Offset := CgeToQuake(Sub.Transform.Translation);
      Inc(N);
    end;
  SetLength(FPhys.SolidModels, N);

  { Living monsters block the player with their Quake bounding boxes }
  N := 0;
  SetLength(FPhys.SolidBoxes, FMonsters.Count);
  for M in FMonsters do
    if MonsterBounds(M, BoxMins, BoxMaxs) then
    begin
      FPhys.SolidBoxes[N].Mins := BoxMins;
      FPhys.SolidBoxes[N].Maxs := BoxMaxs;
      Inc(N);
    end;
  SetLength(FPhys.SolidBoxes, N);
end;

procedure TQuakeWorld.CarryPlayerWithMovers;
var
  I: Integer;
  Sub: TQuakeSubmodel;
  Offset, Delta: TVector3;
  Ride: Boolean;
begin
  { SV_PushMove, simplified: brush entities that moved since the last frame
    carry the player standing on them, and push the player out of their way }
  if Length(FLastSubOffsets) <> FGeometry.Submodels.Count then
    Exit;
  for I := 0 to FGeometry.Submodels.Count - 1 do
  begin
    Sub := FGeometry.Submodels[I];
    Offset := CgeToQuake(Sub.Transform.Translation);
    Delta := Offset - FLastSubOffsets[I];
    FLastSubOffsets[I] := Offset;
    if Delta.IsPerfectlyZero or not SubmodelIsSolid(Sub) then
      Continue;
    Ride := FPhys.OnGround and (FPhys.GroundEntity = Sub.ModelIndex);
    if Ride or FBsp.TraceHull(1, Sub.ModelIndex, Offset, FPhys.Origin, FPhys.Origin).StartSolid then
      FPhys.Origin := FPhys.Origin + Delta;
  end;
end;

procedure TQuakeWorld.TouchMovers;
var
  Sub: TQuakeSubmodel;
  BoxMins, BoxMaxs, AMins, AMaxs: TVector3;

  function WasTouched(const ModelIndex: Integer): Boolean;
  var
    E: Integer;
  begin
    for E in FPhys.Touched do
      if E = ModelIndex then
        Exit(True);
    Result := False;
  end;

begin
  PlayerBox(BoxMins, BoxMaxs);
  for Sub in FGeometry.Submodels do
  begin
    { plat_center_touch }
    if Sub.IsAutoPlat and FPhys.OnGround and (FPhys.GroundEntity = Sub.ModelIndex) then
    begin
      if Sub.State = smsOpen then
        Sounds.PlayAt('sound/plats/plat1.wav', Sub.Transform);
      Sub.PlatTouched;
    end;

    { button_touch: running into a button presses it }
    if (Sub.EntityClassName = 'func_button') and WasTouched(Sub.ModelIndex) then
      PressButton(Sub);

    { door_touch through the trigger field spawned around doors
      (60 units around the door horizontally, 8 vertically) }
    if (Sub.EntityClassName = 'func_door') and (Sub.TargetName = '') and
       (Sub.State = smsClosed) and SubmodelBounds(Sub, AMins, AMaxs) then
    begin
      if (BoxMins.X <= AMaxs.X + 60) and (BoxMaxs.X >= AMins.X - 60) and
         (BoxMins.Y <= AMaxs.Y + 60) and (BoxMaxs.Y >= AMins.Y - 60) and
         (BoxMins.Z <= AMaxs.Z + 8) and (BoxMaxs.Z >= AMins.Z - 8) then
      begin
        Sub.Trigger;
        Sounds.PlayAt('sound/doors/dr1_strt.wav', Sub.Transform);
      end;
    end;
  end;
end;

procedure TQuakeWorld.PlayerWaterRules(const Hud: TQuakeHud);
begin
  { WaterMove (client.qc): air supply, drowning, lava and slime }
  if FPlayerDead then
    Exit;
  if FPlayerStats.BiosuitTime > 0 then
    FAirFinished := FTime + 12; { CheckPowerups: the suit gives air }

  if FPhys.WaterLevel <> 3 then
  begin
    if FAirFinished < FTime then
      Sounds.Play('sound/player/gasp2.wav') { was drowning }
    else if FAirFinished < FTime + 9 then
      Sounds.Play('sound/player/gasp1.wav');
    FAirFinished := FTime + 12;
    FDrownDamage := 2;
  end else
  if FAirFinished < FTime then
  begin
    { Drown }
    if FPainFinished < FTime then
    begin
      FDrownDamage := FDrownDamage + 2;
      if FDrownDamage > 15 then
        FDrownDamage := 10;
      DamagePlayer(FDrownDamage, Hud);
      FPainFinished := FTime + 1;
    end;
  end;

  FPlayerStats.Underwater := FPhys.WaterLevel = 3;
  FPlayerStats.AirLeft := Max(0, FAirFinished - FTime);

  if FPhys.WaterLevel = 0 then
  begin
    if FInWater then
    begin
      Sounds.Play('sound/misc/outwater.wav');
      FInWater := False;
    end;
    Exit;
  end;

  if FPhys.WaterType = CONTENTS_LAVA then
  begin
    if FDmgTime < FTime then
    begin
      if FPlayerStats.BiosuitTime > 0 then
        FDmgTime := FTime + 1
      else
        FDmgTime := FTime + 0.2;
      DamagePlayer(10 * FPhys.WaterLevel, Hud);
    end;
  end else
  if FPhys.WaterType = CONTENTS_SLIME then
  begin
    if (FDmgTime < FTime) and (FPlayerStats.BiosuitTime <= 0) then
    begin
      FDmgTime := FTime + 1;
      DamagePlayer(4 * FPhys.WaterLevel, Hud);
    end;
  end;

  if not FInWater then
  begin
    case FPhys.WaterType of
      CONTENTS_LAVA: Sounds.Play('sound/player/inlava.wav');
      CONTENTS_SLIME: Sounds.Play('sound/player/slimbrn2.wav');
      else Sounds.Play('sound/player/inh2o.wav');
    end;
    FInWater := True;
    FDmgTime := 0;
  end;
end;

procedure TQuakeWorld.MovePlayer(const Cmd: TQuakeUserCmd; const ViewDir: TVector3;
  const SecondsPassed: Single; const Hud: TQuakeHud);
var
  Q: TVector3;
  Yaw, Pitch: Single;
  UseCmd: TQuakeUserCmd;
begin
  if (FBsp = nil) or (FGeometry = nil) then
    Exit;
  FTime := FTime + SecondsPassed;

  { View angles in the Quake convention (pitch > 0 looks down) }
  Q := CgeToQuake(ViewDir);
  Yaw := RadToDeg(ArcTan2(Q.Y, Q.X));
  Pitch := -RadToDeg(ArcSin(EnsureRange(Q.Z, -1, 1)));

  { The player is frozen during the intermission; jump continues }
  if FIntermission then
  begin
    if Cmd.Jump then
      IntermissionContinue;
    Exit;
  end;

  FViewForward := Vector3(Q.X, Q.Y, 0);
  if not FViewForward.IsPerfectlyZero then
    FViewForward := FViewForward.Normalize;

  UseCmd := Cmd;
  if FPlayerDead then
    FillChar(UseCmd, SizeOf(UseCmd), 0);

  CarryPlayerWithMovers;
  UpdateSolids;
  FPhys.Move(UseCmd, Yaw, Pitch, SecondsPassed);

  if FPhys.Jumped then
    Sounds.Play('sound/player/plyrjmp8.wav');

  { PlayerPostThink: landing sounds and falling damage }
  if (FPhys.LandingSpeed < -300) and not FPlayerDead then
  begin
    if FPhys.WaterType = CONTENTS_WATER then
      Sounds.Play('sound/player/h2ojump.wav')
    else if FPhys.LandingSpeed < -650 then
    begin
      DamagePlayer(5, Hud);
      Sounds.Play('sound/player/land2.wav');
    end else
      Sounds.Play('sound/player/land.wav');
  end;

  TouchMovers;
  PlayerWaterRules(Hud);
end;

procedure TQuakeWorld.SetPlayerEyePosition(const Eye: TVector3);
begin
  FPhys.Teleport(CgeToQuake(Eye) - Vector3(0, 0, FPhys.ViewHeight));
end;

function TQuakeWorld.TakePendingYaw(out Yaw: Single): Boolean;
begin
  Result := FHasPendingYaw;
  Yaw := FPendingYaw;
  FHasPendingYaw := False;
end;

function TQuakeWorld.PlayerEyePosition: TVector3;
begin
  Result := QuakeToCge(FPhys.EyePosition);
end;

procedure TQuakeWorld.DamagePlayer(const Damage: Integer; const Hud: TQuakeHud);
const
  ArmorAbsorb: array[0..3] of Single = (0, 0.3, 0.6, 0.8);
var
  Save, Take: Integer;
begin
  if FPlayerDead or FGodMode or FIntermission or (Damage <= 0) then
    Exit;

  Save := Ceil(ArmorAbsorb[EnsureRange(FPlayerStats.ArmorType, 0, 3)] * Damage);
  if Save >= FPlayerStats.Armor then
  begin
    Save := FPlayerStats.Armor;
    FPlayerStats.ArmorType := 0;
  end;
  FPlayerStats.Armor := FPlayerStats.Armor - Save;
  Take := Damage - Save;
  FPlayerStats.Health := FPlayerStats.Health - Take;

  if Hud <> nil then
    Hud.DamageFlash(Save, Take);

  if FPlayerStats.Health <= 0 then
  begin
    FPlayerStats.Health := 0;
    FPlayerDead := True;
    Sounds.Play('sound/player/death1.wav');
    if Hud <> nil then
      Hud.ShowMessage('You died', 3.0);
  end else
  if Take > 0 then
    Sounds.Play('sound/player/pain' + IntToStr(1 + Random(6)) + '.wav');
end;

destructor TQuakeWorld.Destroy;
var
  I, J: Integer;
begin
  for J := 0 to High(FBeams) do
    for I := 0 to High(FBeams[J].Segments) do
      FBeams[J].Segments[I].Free;
  FreeAndNil(FMonsterEnv);
  FreeAndNil(FLightningEvents);
  FreeAndNil(FWeaponAnim);
  if FWeaponTransform <> nil then
  begin
    if FWeaponTransform.Parent <> nil then
      FWeaponTransform.Parent.Remove(FWeaponTransform);
    FreeAndNil(FWeaponTransform);
  end;
  FPickups.Free;
  FMonsters.Free;
  FProjectiles.Free;
  FGibs.Free;
  FTriggers.Free;
  FreeAndNil(FAmbient);
  FreeAndNil(FPhys);
  FreeAndNil(FGeometry);
  FreeAndNil(FBsp);
  inherited Destroy;
end;

procedure TQuakeWorld.AttachWeaponToCamera(const Camera: TCastleTransform);
begin
  if (FWeaponTransform <> nil) and (Camera <> nil) then
  begin
    if FWeaponTransform.Parent <> nil then
      FWeaponTransform.Parent.Remove(FWeaponTransform);
    Camera.Add(FWeaponTransform);
    FWeaponTransform.Rotation := Vector4(0, 1, 0, Pi / 2);
    FWeaponTransform.Translation := Vector3(0, 0, 0);
  end;
end;

procedure TQuakeWorld.UpdateWeaponModel;
var
  TargetModel: String;
  Mdl: TQuakeMdl;
begin
  case FPlayerStats.CurrentWeapon of
    1: TargetModel := 'progs/v_axe.mdl';
    2: TargetModel := 'progs/v_shot.mdl';
    3: TargetModel := 'progs/v_shot2.mdl';
    4: TargetModel := 'progs/v_nail.mdl';
    5: TargetModel := 'progs/v_nail2.mdl';
    6: TargetModel := 'progs/v_rock.mdl';
    7: TargetModel := 'progs/v_rock2.mdl';
    8: TargetModel := 'progs/v_light.mdl';
    else TargetModel := 'progs/v_shot.mdl';
  end;

  if (TargetModel <> FWeaponModelName) or (FWeaponScene = nil) then
  begin
    FWeaponModelName := TargetModel;
    FreeAndNil(FWeaponAnim);
    FWeaponMdl := nil;
    if FWeaponScene <> nil then
    begin
      FWeaponTransform.Remove(FWeaponScene);
      FreeAndNil(FWeaponScene);
    end;

    Mdl := MdlManager.GetModel(TargetModel);
    if Mdl <> nil then
    begin
      FWeaponScene := Mdl.CreateScene(0);
      FWeaponTransform.Add(FWeaponScene);
      FWeaponMdl := Mdl;
      FWeaponAnim := TMdlAnimator.Create(Mdl, FWeaponScene);
      FWeaponAnim.Play(Mdl.Sequence(0, 1, True));
    end;
  end;
end;

procedure TQuakeWorld.SpawnEntities;
var
  I: Integer;
  Ent: TQuakeEntity;
  CName, MdlName: String;
  Pos: TVector3;
  Yaw: Single;
  Pickup: TQuakePickup;
  Monster: TQuakeMonster;
  Trig: TQuakeTrigger;
  Mins, Maxs: TVector3;
  MdlIdx: Integer;
  Def: TMonsterDef;
  PickupsBefore: Integer;
  HasStart2: Boolean;
  Start2Origin: TVector3;
  Start2Angle: Single;
begin
  HasStart2 := False;
  Start2Origin := TVector3.Zero;
  Start2Angle := 0;
  FPickups.Clear;
  FMonsters.Clear;
  FLightningEvents.Clear;
  FLightningEnd := 0;
  FTriggers.Clear;

  for I := 0 to FBsp.Entities.Count - 1 do
  begin
    Ent := FBsp.Entities[I];
    CName := LowerCase(Ent.ClassName);
    { ED_LoadFromFile: skip entities not meant for the current skill }
    if EntityNotInSkill(Ent, FSkill) then
      Continue;
    PickupsBefore := FPickups.Count;
    Pos := QuakeToCge(Ent.Origin);
    Yaw := Ent.Angle;

    { Player start }
    if CName = 'info_player_start' then
    begin
      FSpawnOrigin := Ent.Origin;
      FSpawnPoint := QuakeToCge(Ent.Origin + Vector3(0, 0, FPhys.ViewHeight));
      FSpawnAngle := Yaw;
    end else
    { Where the player returns to the start map after an episode }
    if CName = 'info_player_start2' then
    begin
      HasStart2 := True;
      Start2Origin := Ent.Origin;
      Start2Angle := Yaw;
    end else

    { Weapons }
    if CName = 'weapon_supershotgun' then
    begin
      Pickup := TQuakePickup.Create(FRootTransform, ikSuperShotgun, Pos, 'progs/g_shot.mdl');
      FPickups.Add(Pickup);
    end else
    if CName = 'weapon_nailgun' then
    begin
      Pickup := TQuakePickup.Create(FRootTransform, ikNailgun, Pos, 'progs/g_nail.mdl');
      FPickups.Add(Pickup);
    end else
    if CName = 'weapon_supernailgun' then
    begin
      Pickup := TQuakePickup.Create(FRootTransform, ikSuperNailgun, Pos, 'progs/g_nail2.mdl');
      FPickups.Add(Pickup);
    end else
    if CName = 'weapon_grenadelauncher' then
    begin
      Pickup := TQuakePickup.Create(FRootTransform, ikGrenadeLauncher, Pos, 'progs/g_rock.mdl');
      FPickups.Add(Pickup);
    end else
    if CName = 'weapon_rocketlauncher' then
    begin
      Pickup := TQuakePickup.Create(FRootTransform, ikRocketLauncher, Pos, 'progs/g_rock2.mdl');
      FPickups.Add(Pickup);
    end else
    if CName = 'weapon_lightning' then
    begin
      Pickup := TQuakePickup.Create(FRootTransform, ikLightning, Pos, 'progs/g_light.mdl');
      FPickups.Add(Pickup);
    end else

    { Armor }
    if CName = 'item_armor1' then
    begin
      Pickup := TQuakePickup.Create(FRootTransform, ikGreenArmor, Pos, 'progs/armor.mdl', 0);
      FPickups.Add(Pickup);
    end else
    if CName = 'item_armor2' then
    begin
      Pickup := TQuakePickup.Create(FRootTransform, ikYellowArmor, Pos, 'progs/armor.mdl', 1);
      FPickups.Add(Pickup);
    end else
    if CName = 'item_armorinv' then
    begin
      Pickup := TQuakePickup.Create(FRootTransform, ikRedArmor, Pos, 'progs/armor.mdl', 2);
      FPickups.Add(Pickup);
    end else

    { Health }
    if CName = 'item_health' then
    begin
      Pickup := TQuakePickup.Create(FRootTransform, ikHealthNormal, Pos, 'progs/b_bh25.bsp');
      if Pickup.Scene = nil then
      begin
        { Fallback to armor or key model if b_bh25.bsp not present }
        Pickup.Free;
        Pickup := TQuakePickup.Create(FRootTransform, ikHealthNormal, Pos, 'progs/armor.mdl', 0);
      end;
      FPickups.Add(Pickup);
    end else

    { Ammo }
    if CName = 'item_shells' then
    begin
      Pickup := TQuakePickup.Create(FRootTransform, ikShells, Pos, 'progs/g_shot.mdl');
      FPickups.Add(Pickup);
    end else
    if CName = 'item_spikes' then
    begin
      Pickup := TQuakePickup.Create(FRootTransform, ikNails, Pos, 'progs/g_nail.mdl');
      FPickups.Add(Pickup);
    end else
    if CName = 'item_rockets' then
    begin
      Pickup := TQuakePickup.Create(FRootTransform, ikRockets, Pos, 'progs/g_rock.mdl');
      FPickups.Add(Pickup);
    end else
    if CName = 'item_cells' then
    begin
      Pickup := TQuakePickup.Create(FRootTransform, ikCells, Pos, 'progs/g_light.mdl');
      FPickups.Add(Pickup);
    end else

    { Keys }
    if CName = 'item_artifact_envirosuit' then
    begin
      Pickup := TQuakePickup.Create(FRootTransform, ikBioSuit, Pos, 'progs/suit.mdl');
      FPickups.Add(Pickup);
    end else
    if CName = 'item_sigil' then
    begin
      { The episode rune; picking it up wakes Chthon in E1M7 }
      { One rune per episode: spawnflags 1, 2, 4, 8 -> end1 .. end4 }
      case Ent.SpawnFlags and 15 of
        2: MdlName := 'progs/end2.mdl';
        4: MdlName := 'progs/end3.mdl';
        8: MdlName := 'progs/end4.mdl';
        else MdlName := 'progs/end1.mdl';
      end;
      Pickup := TQuakePickup.Create(FRootTransform, ikSigil, Pos, MdlName);
      Pickup.SpawnFlags := Ent.SpawnFlags;
      FPickups.Add(Pickup);
    end else
    if CName = 'item_key1' then
    begin
      Pickup := TQuakePickup.Create(FRootTransform, ikKeySilver, Pos, 'progs/w_skey.mdl');
      FPickups.Add(Pickup);
    end else
    if CName = 'item_key2' then
    begin
      Pickup := TQuakePickup.Create(FRootTransform, ikKeyGold, Pos, 'progs/w_gkey.mdl');
      FPickups.Add(Pickup);
    end else

    { Monsters (all classes from QuakeMonsters) }
    if MonsterDef(CName, Def) then
    begin
      if MdlManager.GetModel(Def.Model) = nil then
        WritelnWarning('QuakeWorld', 'No model for %s, skipped', [CName])
      else
      begin
        Monster := TQuakeMonster.Create(FRootTransform, Def, Ent.Origin, Ent.Angle);
        Monster.TargetName := Ent.TargetName;
        Monster.Target := Ent.Target;
        FMonsters.Add(Monster);
        if (CName = 'monster_zombie') and ((Ent.SpawnFlags and 1) <> 0) then
          Monster.Crucify { decoration, not counted }
        else
        begin
          Monster.Ambush := (Ent.SpawnFlags and 1) <> 0;
          Monster.Nightmare := FSkill >= 3;
          if Def.Move = mmWalk then
            MonsterDropToFloor(Monster);
          Inc(FPlayerStats.TotalKills);
        end;
      end;
    end else
    if CName = 'event_lightning' then
      FLightningEvents.Add(Ent.TargetName)
    else

    { Triggers }
    if (CName = 'trigger_teleport') or (CName = 'trigger_changelevel') or
       (CName = 'trigger_multiple') or (CName = 'trigger_once') or
       (CName = 'trigger_setskill') or (CName = 'trigger_secret') then
    begin
      { Brush triggers use the bounds of their BSP model; point ones a small box }
      MdlIdx := -1;
      if (Length(Ent.Model) > 1) and (Ent.Model[1] = '*') then
        MdlIdx := StrToIntDef(Copy(Ent.Model, 2, MaxInt), -1);
      if (MdlIdx > 0) and (MdlIdx < FBsp.ModelCount) then
      begin
        Mins := FBsp.Models[MdlIdx].Mins;
        Maxs := FBsp.Models[MdlIdx].Maxs;
      end else
      begin
        Mins := Ent.Origin - Vector3(32, 32, 32);
        Maxs := Ent.Origin + Vector3(32, 32, 32);
      end;
      Trig := TQuakeTrigger.Create(CName, Mins, Maxs, Ent.Target, Ent.GetField('map'));
      Trig.TargetName := Ent.TargetName;
      Trig.SpawnFlags := Ent.SpawnFlags;
      Trig.Message := StringReplace(Ent.MessageText, '\n', LineEnding, [rfReplaceAll]);
      if CName = 'trigger_secret' then
      begin
        { trigger_secret: a trigger_once counted in the level stats }
        Inc(FPlayerStats.TotalSecrets);
        Trig.WaitTime := -1;
        if Trig.Message = '' then
          Trig.Message := 'You found a secret area!';
        Trig.Touchable := (Ent.GetFloat('health', 0) = 0) and ((Ent.SpawnFlags and 1) = 0);
      end else
      if (CName = 'trigger_multiple') or (CName = 'trigger_once') then
      begin
        { trigger_multiple waits 0.2 s by default, trigger_once fires once;
          shootable (health) and SPAWNFLAG_NOTOUCH triggers ignore touches }
        if CName = 'trigger_once' then
          Trig.WaitTime := -1
        else
        begin
          Trig.WaitTime := Ent.GetFloat('wait', 0);
          if Trig.WaitTime = 0 then
            Trig.WaitTime := 0.2;
        end;
        Trig.Touchable := (Ent.GetFloat('health', 0) = 0) and ((Ent.SpawnFlags and 1) = 0);
        { InitTrigger / SetMovedir: an angle makes it one-way }
        if Ent.Angle = -1 then
          Trig.MoveDir := Vector3(0, 0, 1)
        else if Ent.Angle = -2 then
          Trig.MoveDir := Vector3(0, 0, -1)
        else if Ent.Angle <> 0 then
          Trig.MoveDir := Vector3(Cos(DegToRad(Ent.Angle)), Sin(DegToRad(Ent.Angle)), 0);
      end;
      FTriggers.Add(Trig);
    end;

    { Items fire their targets when picked up }
    if FPickups.Count > PickupsBefore then
      FPickups.Last.Target := Ent.Target;
  end;

  { PutClientInServer: back on the start map after an episode }
  if HasStart2 and (FServerFlags <> 0) and IsStartMap then
  begin
    FSpawnOrigin := Start2Origin;
    FSpawnPoint := QuakeToCge(Start2Origin + Vector3(0, 0, FPhys.ViewHeight));
    FSpawnAngle := Start2Angle;
  end;

  WritelnLog('QuakeWorld', 'Spawned %d pickups, %d monsters, %d triggers',
    [FPickups.Count, FMonsters.Count, FTriggers.Count]);
end;

function TQuakeWorld.LoadMap(const AMapName: String): Boolean;
var
  MapPath: String;
  I: Integer;
begin
  Result := False;
  FLevelExited := False;
  FNextMap := '';
  FPlayerStats.LevelTime := 0;
  FPlayerStats.Kills := 0;
  FPlayerStats.TotalKills := 0;
  FPlayerStats.Secrets := 0;
  FPlayerStats.TotalSecrets := 0;
  FIntermission := False;
  if FHud <> nil then
    FHud.StopIntermission;

  MapPath := AMapName;
  if ExtractFileExt(MapPath) = '' then
    MapPath := 'maps/' + MapPath + '.bsp';

  FAmbient.Clear;
  FGibs.Clear;
  FProjectiles.Clear;
  FreeAndNil(FGeometry);
  FreeAndNil(FBsp);

  FBsp := TQuakeBsp.Create;
  if not FBsp.LoadFromPak(MapPath) then
  begin
    WritelnWarning('QuakeWorld', 'Failed to load BSP "%s"', [MapPath]);
    Exit;
  end;

  { DecodeLevelParms: returning to the start map after an episode starts
    over with a fresh inventory (the runes are kept) }
  if IsStartMap and (FServerFlags <> 0) then
  begin
    ResetPlayerStats;
    UpdateWeaponModel;
  end;

  { Build 3D world scene }
  FGeometry := TQuakeGeometry.Create(FBsp);
  FGeometry.Skill := FSkill;
  FGeometry.AddToWorld(FRootTransform);

  { Initialize dynamic lights from map entities }
  Lighting.CreateLightsFromBsp(FBsp, FRootTransform);

  { Spawn world items and monsters (monsters are dropped to the floor with
    the player physics traces, so give them the new map first) }
  FPhys.Bsp := FBsp;
  SetLength(FPhys.SolidModels, 0);
  SetLength(FPhys.SolidBoxes, 0);
  SpawnEntities;
  ApplyEpisodeGates;

  { Looping ambient sounds (ambient_*, torches, fluorescent lights) }
  FAmbient.Setup(FBsp, FRootTransform);

  { Player physics on the new map }
  FPhys.Bsp := FBsp;
  FPhys.Teleport(FSpawnOrigin);
  FHasPendingYaw := False;
  SetLength(FLastSubOffsets, FGeometry.Submodels.Count);
  for I := 0 to FGeometry.Submodels.Count - 1 do
    FLastSubOffsets[I] := CgeToQuake(FGeometry.Submodels[I].Transform.Translation);
  FAirFinished := FTime + 12;
  FDmgTime := 0;
  FPainFinished := 0;
  FDrownDamage := 2;
  FInWater := False;

  { Setup first-person weapon model }
  UpdateWeaponModel;

  { Start background music track }
  Sounds.PlayMusic('track02.ogg');

  { Saved for the restart after death }
  FLevelStartStats := FPlayerStats;
  FLevelStartServerFlags := FServerFlags;
  FLevelStartValid := True;

  WritelnLog('QuakeWorld', 'Successfully initialized map "%s" (skill %d, runes %d)', [MapPath, FSkill, FServerFlags]);
  Result := True;
end;

procedure TQuakeWorld.CheckPickups(const Hud: TQuakeHud);
var
  I: Integer;
  P: TQuakePickup;
  BoxMins, BoxMaxs, ItemOrg: TVector3;
begin
  PlayerBox(BoxMins, BoxMaxs);
  for I := 0 to FPickups.Count - 1 do
  begin
    P := FPickups[I];
    if P.Collected then
      Continue;

    { Items touch the player box with their Quake size ('-16 -16 0' '16 16 56') }
    ItemOrg := CgeToQuake(P.Origin);
    if (BoxMins.X <= ItemOrg.X + 16) and (BoxMaxs.X >= ItemOrg.X - 16) and
       (BoxMins.Y <= ItemOrg.Y + 16) and (BoxMaxs.Y >= ItemOrg.Y - 16) and
       (BoxMins.Z <= ItemOrg.Z + 56) and (BoxMaxs.Z >= ItemOrg.Z) and
       not FPlayerDead then
    begin
      P.Collected := True;
      Sounds.Play(P.PickupSound);
      if Hud <> nil then
      begin
        Hud.ShowMessage(P.MessageText);
        Hud.BonusFlash;
      end;
      UseTargets(P.Target);

      case P.Kind of
        ikSigil:
          { sigil_touch: the episode is completed }
          FServerFlags := FServerFlags or (P.SpawnFlags and 15);
        ikSuperShotgun:
          begin
            FPlayerStats.WeaponMask := FPlayerStats.WeaponMask or (1 shl 3);
            FPlayerStats.Shells := Min(FPlayerStats.MaxShells, FPlayerStats.Shells + 10);
            SelectWeapon(3);
          end;
        ikNailgun:
          begin
            FPlayerStats.WeaponMask := FPlayerStats.WeaponMask or (1 shl 4);
            FPlayerStats.Nails := Min(FPlayerStats.MaxNails, FPlayerStats.Nails + 30);
            SelectWeapon(4);
          end;
        ikSuperNailgun:
          begin
            FPlayerStats.WeaponMask := FPlayerStats.WeaponMask or (1 shl 5);
            FPlayerStats.Nails := Min(FPlayerStats.MaxNails, FPlayerStats.Nails + 30);
            SelectWeapon(5);
          end;
        ikGrenadeLauncher:
          begin
            FPlayerStats.WeaponMask := FPlayerStats.WeaponMask or (1 shl 6);
            FPlayerStats.Rockets := Min(FPlayerStats.MaxRockets, FPlayerStats.Rockets + 5);
            SelectWeapon(6);
          end;
        ikRocketLauncher:
          begin
            FPlayerStats.WeaponMask := FPlayerStats.WeaponMask or (1 shl 7);
            FPlayerStats.Rockets := Min(FPlayerStats.MaxRockets, FPlayerStats.Rockets + 5);
            SelectWeapon(7);
          end;
        ikLightning:
          begin
            FPlayerStats.WeaponMask := FPlayerStats.WeaponMask or (1 shl 8);
            FPlayerStats.Cells := Min(FPlayerStats.MaxCells, FPlayerStats.Cells + 30);
            SelectWeapon(8);
          end;
        ikGreenArmor:
          begin
            FPlayerStats.Armor := Max(FPlayerStats.Armor, 100);
            FPlayerStats.ArmorType := 1;
          end;
        ikYellowArmor:
          begin
            FPlayerStats.Armor := Max(FPlayerStats.Armor, 150);
            FPlayerStats.ArmorType := 2;
          end;
        ikRedArmor:
          begin
            FPlayerStats.Armor := 200;
            FPlayerStats.ArmorType := 3;
          end;
        ikHealthSmall:
          FPlayerStats.Health := Min(100, FPlayerStats.Health + 15);
        ikHealthNormal:
          FPlayerStats.Health := Min(100, FPlayerStats.Health + 25);
        ikHealthMega:
          FPlayerStats.Health := Min(200, FPlayerStats.Health + 100);
        ikShells:
          FPlayerStats.Shells := Min(FPlayerStats.MaxShells, FPlayerStats.Shells + 20);
        ikNails:
          FPlayerStats.Nails := Min(FPlayerStats.MaxNails, FPlayerStats.Nails + 30);
        ikRockets:
          FPlayerStats.Rockets := Min(FPlayerStats.MaxRockets, FPlayerStats.Rockets + 5);
        ikCells:
          FPlayerStats.Cells := Min(FPlayerStats.MaxCells, FPlayerStats.Cells + 30);
        ikKeySilver:
          FPlayerStats.Keys := FPlayerStats.Keys or 1;
        ikKeyGold:
          FPlayerStats.Keys := FPlayerStats.Keys or 2;
        ikBioSuit:
          FPlayerStats.BiosuitTime := 30.0;
      end;
    end;
  end;
end;

procedure TQuakeWorld.CheckTriggers;
var
  Trig: TQuakeTrigger;
  Ent, Dest: TQuakeEntity;
  BoxMins, BoxMaxs, Forward: TVector3;
  DestYaw: Single;
begin
  if FBsp = nil then
    Exit;
  PlayerBox(BoxMins, BoxMaxs);
  for Trig in FTriggers do
  begin
    if Trig.Removed or not Trig.Touchable or not Trig.Touches(BoxMins, BoxMaxs) or
       FPlayerDead or FIntermission or FLevelExited then
      Continue;

    if Trig.EntityClassName = 'trigger_changelevel' then
    begin
      if not Pak.FileExists('maps/' + Trig.MapName + '.bsp') then
      begin
        { A portal to an episode these paks do not have (shareware) }
        if FTime - Trig.LastTriggerTime > 3 then
        begin
          Trig.LastTriggerTime := FTime;
          if FHud <> nil then
            FHud.ShowMessage('This episode is not available:' + LineEnding +
              'maps/' + Trig.MapName + '.bsp is missing', 3.0);
        end;
        Continue;
      end;
      SetChangeParms;
      { changelevel_touch: NO_INTERMISSION portals (the start map) go
        straight to the next map }
      if (Trig.SpawnFlags and 1) <> 0 then
      begin
        FLevelExited := True;
        FNextMap := Trig.MapName;
      end else
        StartIntermission(Trig.MapName);
      Exit;
    end else
    if Trig.EntityClassName = 'trigger_setskill' then
    begin
      { trigger_setskill: the skill the next maps are spawned with }
      FSkill := EnsureRange(StrToIntDef(Trim(Trig.Message), FSkill), 0, 3);
    end else
    if Trig.EntityClassName = 'trigger_teleport' then
    begin
      { teleport_touch: find the destination with the matching targetname }
      Dest := nil;
      for Ent in FBsp.Entities do
        if (LowerCase(Ent.ClassName) = 'info_teleport_destination') and
           (Ent.TargetName = Trig.Target) then
        begin
          Dest := Ent;
          Break;
        end;
      if Dest = nil then
        Continue;

      Particles.SpawnTeleport(QuakeToCge(FPhys.Origin));
      DestYaw := Dest.Angles.Y;
      if DestYaw = 0 then
        DestYaw := Dest.Angle;
      SinCos(DegToRad(DestYaw), Forward.Y, Forward.X);
      Forward.Z := 0;
      { info_teleport_destination is raised 27 units above its map origin }
      FPhys.Teleport(Dest.Origin + Vector3(0, 0, 27));
      FPhys.Velocity := Forward * 300;
      FPhys.TeleportTime := FPhys.Time + 0.7;
      FPendingYaw := DestYaw;
      FHasPendingYaw := True;
      Particles.SpawnTeleport(QuakeToCge(Dest.Origin + Forward * 32));
      Sounds.Play('sound/misc/r_tele1.wav');
    end else
    if (Trig.EntityClassName = 'trigger_multiple') or (Trig.EntityClassName = 'trigger_once') or
       (Trig.EntityClassName = 'trigger_secret') then
    begin
      { multi_touch / multi_trigger }
      if (Trig.WaitTime > 0) and (FTime < Trig.LastTriggerTime + Trig.WaitTime) then
        Continue;
      if not Trig.MoveDir.IsPerfectlyZero and
         (TVector3.DotProduct(FViewForward, Trig.MoveDir) < 0) then
        Continue;
      Trig.LastTriggerTime := FTime;
      if Trig.WaitTime < 0 then
        Trig.Removed := True;
      if Trig.EntityClassName = 'trigger_secret' then
      begin
        Inc(FPlayerStats.Secrets);
        Sounds.Play('sound/misc/secret.wav');
        if FHud <> nil then
          FHud.ShowMessage(Trig.Message, 3.0);
      end else
      if Trig.Message <> '' then
      begin
        if FHud <> nil then
          FHud.ShowMessage(Trig.Message, 3.0);
        Sounds.Play('sound/misc/talk.wav');
      end;
      UseTargets(Trig.Target);
    end;
  end;
end;

procedure TQuakeWorld.Update(const SecondsPassed: Single; const PlayerPos: TVector3;
  const PlayerFacing, PlayerPitch: Single; const Hud: TQuakeHud);
var
  I: Integer;
  M: TQuakeMonster;
begin
  FPlayerPos := PlayerPos;
  FHud := Hud;
  FPlayerFacing := PlayerFacing;
  FPlayerPitch := PlayerPitch;
  FPlayerStats.LevelTime := FPlayerStats.LevelTime + SecondsPassed;

  { Update current ammo count in HUD stats }
  case FPlayerStats.CurrentWeapon of
    2, 3: FPlayerStats.Ammo := FPlayerStats.Shells;
    4, 5: FPlayerStats.Ammo := FPlayerStats.Nails;
    6, 7: FPlayerStats.Ammo := FPlayerStats.Rockets;
    8:    FPlayerStats.Ammo := FPlayerStats.Cells;
    else  FPlayerStats.Ammo := 0;
  end;

  { Ambient emitters and leaf ambients follow the listener }
  FAmbient.Update(SecondsPassed, FPlayerPos);

  { Advance geometry submodels and animations }
  if FGeometry <> nil then
    FGeometry.Update(SecondsPassed, PlayerPos);

  { Advance pickups }
  for I := 0 to FPickups.Count - 1 do
    FPickups[I].Update(SecondsPassed);
  CheckPickups(Hud);

  { Powerup timers }
  if FPlayerStats.BiosuitTime > 0 then
  begin
    if (FPlayerStats.BiosuitTime > 3) and (FPlayerStats.BiosuitTime - SecondsPassed <= 3) then
    begin
      Sounds.Play('sound/items/suit2.wav');
      if Hud <> nil then
        Hud.ShowMessage('Air supply in Biosuit expiring');
    end;
    FPlayerStats.BiosuitTime := Max(0, FPlayerStats.BiosuitTime - SecondsPassed);
  end;

  { Advance triggers }
  CheckTriggers;
  if FIntermission and (Hud <> nil) then
    Hud.IntermissionReady := FTime >= FIntermissionExitTime;

  { Advance monsters }
  for I := 0 to FMonsters.Count - 1 do
  begin
    M := FMonsters[I];
    M.Update(SecondsPassed, FMonsterEnv);
    if M.GibPending then
      GibMonster(M);
    if M.ExplodePending then
      MonsterExplode(M);
    if M.DeathTargetPending then
    begin
      { boss_death: fire the boss target (opens the exit) }
      M.DeathTargetPending := False;
      UseTargets(M.Target);
    end;
    if (M.State = msDead) and not M.KillCounted then
    begin
      Inc(FPlayerStats.Kills);
      M.KillCounted := True;
    end;
  end;

  { Advance projectiles }
  UpdateProjectiles(SecondsPassed, Hud);
  UpdateGibs(SecondsPassed);
  { The lightning hum restarts with lstart.wav after the trigger is released }
  if FTime - FLastLightningTime > 0.2 then
    FLightningFiring := False;

  { Advance particles }
  Particles.Update(SecondsPassed);

  { Update lighting styles and muzzle timer }
  Lighting.Update(SecondsPassed, FPlayerPos);

  { Update weapon cooldown and view recoil }
  if FWeaponCooldown > 0 then
    FWeaponCooldown := FWeaponCooldown - SecondsPassed;

  if FWeaponRecoil > 0 then
    FWeaponRecoil := Max(0, FWeaponRecoil - SecondsPassed * 4.0);

  { Animate the view weapon, back to idle after the attack frames }
  if FWeaponAnim <> nil then
  begin
    if FWeaponAnim.Finished then
      FWeaponAnim.Play(FWeaponMdl.Sequence(0, 1, True));
    FWeaponAnim.Update(SecondsPassed);
  end;

  { Update first-person weapon model position }
  if FWeaponTransform <> nil then
  begin
    if FWeaponTransform.Parent <> nil then
    begin
      { In camera space: apply firing recoil kickback along +Z and downward along -Y }
      FWeaponTransform.Translation := Vector3(0, -FWeaponRecoil * 1.5, FWeaponRecoil * 2.5);
      FWeaponTransform.Rotation := Vector4(0, 1, 0, Pi / 2);
    end else
    begin
      FWeaponTransform.Translation := FPlayerPos + Vector3(0, -6 - FWeaponRecoil * 3.0, 0);
      FWeaponTransform.Rotation := Vector4(0, 1, 0, DegToRad(FPlayerFacing));
    end;
  end;

  { Update HUD }
  if Hud <> nil then
    Hud.Update(SecondsPassed, FPlayerStats);
end;

procedure TQuakeWorld.SelectWeapon(const Slot: Integer; const Hud: TQuakeHud);
begin
  if (Slot >= 1) and (Slot <= 8) and ((FPlayerStats.WeaponMask and (1 shl Slot)) <> 0) then
  begin
    FPlayerStats.CurrentWeapon := Slot;
    UpdateWeaponModel;
    Sounds.Play('sound/weapons/pkup.wav');
  end;
end;

function TQuakeWorld.MonsterBounds(const M: TQuakeMonster; out AMins, AMaxs: TVector3): Boolean;
var
  Org: TVector3;
begin
  Result := M.IsSolid;
  if not Result then
    Exit;
  Org := M.Origin;
  AMins := M.Def.Mins + Org;
  AMaxs := M.Def.Maxs + Org;
end;

function TQuakeWorld.TraceShot(const Start, Stop: TVector3; out HitMonster: TQuakeMonster): TQuakeTrace;
var
  HitPlayer: Boolean;
begin
  Result := TraceMissile(Start, Stop, nil, HitMonster, HitPlayer);
end;

function TQuakeWorld.TraceMissile(const Start, Stop: TVector3; const Owner: TObject;
  out HitMonster: TQuakeMonster; out HitPlayer: Boolean): TQuakeTrace;
var
  M: TQuakeMonster;
  BoxMins, BoxMaxs: TVector3;
  T: TQuakeTrace;

  procedure Consider(const AMins, AMaxs: TVector3; const AMonster: TQuakeMonster);
  begin
    T := TraceSegmentBox(AMins, AMaxs, Start, Stop);
    if T.StartSolid then
    begin
      { Point blank: the shot starts inside the target }
      T.Fraction := 0;
      T.EndPos := Start;
      T.PlaneNormal := (Stop - Start).Normalize * -1;
    end;
    if (T.Fraction < Result.Fraction) and (T.Fraction < 1) then
    begin
      Result := T;
      HitMonster := AMonster;
      HitPlayer := AMonster = nil;
    end;
  end;

begin
  HitMonster := nil;
  HitPlayer := False;
  if FBsp = nil then
  begin
    FillChar(Result, SizeOf(Result), 0);
    Result.Fraction := 1;
    Result.EndPos := Stop;
    Exit;
  end;
  Result := FPhys.Trace(Start, Stop, True, True);
  for M in FMonsters do
    if (M <> Owner) and MonsterBounds(M, BoxMins, BoxMaxs) then
      Consider(BoxMins, BoxMaxs, M);
  { Monster missiles can hit the player }
  if (Owner <> nil) and not FPlayerDead then
  begin
    PlayerBox(BoxMins, BoxMaxs);
    Consider(BoxMins, BoxMaxs, nil);
  end;
end;

function TQuakeWorld.CanDamage(const Inflictor, TargetCenter: TVector3): Boolean;
const
  Corners: array[0..4] of TVector2 = ((X: 0; Y: 0), (X: 15; Y: 15), (X: -15; Y: -15),
    (X: -15; Y: 15), (X: 15; Y: -15));
var
  I: Integer;
begin
  for I := 0 to High(Corners) do
    if FPhys.Trace(Inflictor, TargetCenter + Vector3(Corners[I].X, Corners[I].Y, 0),
      True, True).Fraction = 1 then
      Exit(True);
  Result := False;
end;

procedure TQuakeWorld.DamageMonster(const M: TQuakeMonster; const Damage: Single;
  const From: TVector3; const Attacker: TQuakeMonster);
begin
  if Damage > 0 then
    M.TakeDamage(Max(1, Round(Damage)), Attacker);
end;

procedure TQuakeWorld.RadiusDamage(const Center: TVector3; const Damage: Single;
  const Ignore: TQuakeMonster; const Hud: TQuakeHud; const PlayerAttacker: Boolean;
  const IgnorePlayer: Boolean; const Attacker: TQuakeMonster);
var
  M: TQuakeMonster;
  BoxMins, BoxMaxs, Target, Dir: TVector3;
  Points: Single;
begin
  { T_RadiusDamage: damage falls off by half a point per unit of distance }
  for M in FMonsters do
    if (M <> Ignore) and MonsterBounds(M, BoxMins, BoxMaxs) then
    begin
      Target := (BoxMins + BoxMaxs) * 0.5;
      Points := Damage - 0.5 * PointsDistance(Center, Target);
      if M.EntityClassName = 'monster_shambler' then
        Points := Points * 0.5; { shamblers resist explosions }
      if (Points > 0) and CanDamage(Center, Target) then
        DamageMonster(M, Points, Center, Attacker);
    end;

  { The player takes half damage from their own explosions, and the
    knockback (T_Damage) is what makes rocket jumping work }
  Target := FPhys.Origin + (FPhys.Mins + FPhys.Maxs) * 0.5;
  Points := Damage - 0.5 * PointsDistance(Center, Target);
  if PlayerAttacker then
    Points := Points * 0.5;
  if (Points > 0) and CanDamage(Center, Target) and not FPlayerDead and not IgnorePlayer then
  begin
    Dir := FPhys.Origin - Center;
    if not Dir.IsPerfectlyZero then
      FPhys.Velocity := FPhys.Velocity + Dir.Normalize * Points * 8;
    DamagePlayer(Round(Points), Hud);
  end;
end;

procedure TQuakeWorld.FireBullets(const Count: Integer; const Src, Dir, Right, Up: TVector3;
  const SpreadX, SpreadY: Single);
var
  I, J: Integer;
  ShotDir: TVector3;
  T: TQuakeTrace;
  M: TQuakeMonster;
  Hit: array of TQuakeMonster;
  HitDamage: array of Single;
begin
  { FireBullets: each pellet is a 2048 unit traceline with random spread;
    damage is summed per target (multidamage) and applied once }
  SetLength(Hit, 0);
  SetLength(HitDamage, 0);
  for I := 1 to Count do
  begin
    ShotDir := Dir + Right * ((Random * 2 - 1) * SpreadX) + Up * ((Random * 2 - 1) * SpreadY);
    T := TraceShot(Src, Src + ShotDir * 2048, M);
    if T.Fraction = 1 then
      Continue;
    if M <> nil then
    begin
      Particles.SpawnBlood(QuakeToCge(T.EndPos - ShotDir * 4), QuakeToCge(ShotDir * -1));
      J := 0;
      while (J < Length(Hit)) and (Hit[J] <> M) do
        Inc(J);
      if J = Length(Hit) then
      begin
        SetLength(Hit, J + 1);
        SetLength(HitDamage, J + 1);
        Hit[J] := M;
        HitDamage[J] := 0;
      end;
      HitDamage[J] := HitDamage[J] + 4;
    end else
    if FBsp.PointContents(T.EndPos) <> CONTENTS_SKY then
      Particles.SpawnPuff(QuakeToCge(T.EndPos - ShotDir * 4), QuakeToCge(T.PlaneNormal));
  end;
  for J := 0 to High(Hit) do
    DamageMonster(Hit[J], HitDamage[J], Src);
end;

procedure TQuakeWorld.LaunchSpike(const Kind: TQuakeProjectileKind; const Src, Dir: TVector3);
begin
  { launch_spike: 1000 units/s }
  FProjectiles.Add(TQuakeProjectile.Create(FRootTransform, Kind, Src, Dir * 1000));
end;

procedure TQuakeWorld.ShowBeam(const Pool: Integer; const StartQ, StopQ: TVector3;
  const Duration: Single);
const
  SegmentLength = 30.0; { CL_ParseBeam draws bolt models every 30 units }
  BeamModels: array[0..2] of String = ('progs/bolt2.mdl', 'progs/bolt.mdl', 'progs/bolt3.mdl');
var
  Mdl: TQuakeMdl;
  Delta, Dir: TVector3;
  Dist, Yaw, Pitch: Single;
  Count, I: Integer;
  Q: TQuaternion;
  Seg: TCastleTransform;
  Scene: TCastleScene;
begin
  Delta := StopQ - StartQ;
  Dist := Delta.Length;
  if Dist < 1 then
    Exit;
  Dir := Delta / Dist;
  Count := Min(Ceil(Dist / SegmentLength), 40);

  { Grow the pool of bolt segments when needed }
  while Length(FBeams[Pool].Segments) < Count do
  begin
    Mdl := MdlManager.GetModel(BeamModels[Pool]);
    if Mdl = nil then
      Break;
    Seg := TCastleTransform.Create(nil);
    Scene := Mdl.CreateScene(0);
    Scene.Collides := False;
    Seg.Add(Scene);
    FRootTransform.Add(Seg);
    SetLength(FBeams[Pool].Segments, Length(FBeams[Pool].Segments) + 1);
    FBeams[Pool].Segments[High(FBeams[Pool].Segments)] := Seg;
  end;

  Yaw := ArcTan2(Dir.Y, Dir.X);
  Pitch := ArcTan2(Dir.Z, Sqrt(Sqr(Dir.X) + Sqr(Dir.Y)));
  for I := 0 to High(FBeams[Pool].Segments) do
  begin
    Seg := FBeams[Pool].Segments[I];
    Seg.Exists := I < Count;
    if not Seg.Exists then
      Continue;
    { Random roll per segment makes the bolt flicker }
    Q := QuatFromAxisAngle(Vector3(0, 1, 0), Yaw) * QuatFromAxisAngle(Vector3(0, 0, 1), Pitch) *
      QuatFromAxisAngle(Vector3(1, 0, 0), Random * 2 * Pi);
    Seg.Rotation := Q.ToAxisAngle;
    Seg.Translation := QuakeToCge(StartQ + Dir * (I * SegmentLength));
  end;
  FBeams[Pool].Time := Duration;
end;

procedure TQuakeWorld.FireLightning(const Src, Dir: TVector3; const Hud: TQuakeHud);
var
  T: TQuakeTrace;
  M: TQuakeMonster;
  Cells: Integer;
begin
  { W_FireLightning: discharge when fired under water }
  if FPhys.WaterLevel > 1 then
  begin
    Cells := FPlayerStats.Cells;
    FPlayerStats.Cells := 0;
    Sounds.Play('sound/weapons/lhit.wav');
    Particles.SpawnExplosion(QuakeToCge(FPhys.Origin));
    RadiusDamage(FPhys.Origin, 35 * Cells, nil, Hud);
    { T_RadiusDamage halves self damage; a discharge is meant to kill }
    DamagePlayer(Round(35 * Cells * 0.5), Hud);
    Exit;
  end;

  if (not FLightningFiring) or (FLightningSoundTime <= FTime) then
  begin
    if FLightningFiring then
      Sounds.Play('sound/weapons/lhit.wav')
    else
      Sounds.Play('sound/weapons/lstart.wav');
    FLightningSoundTime := FTime + 0.6;
  end;
  FLightningFiring := True;
  FLastLightningTime := FTime;

  T := TraceShot(Src, Src + Dir * 600, M);
  ShowBeam(0, Src, T.EndPos, 0.1);
  if M <> nil then
  begin
    { LightningDamage: 30 per 0.1 s }
    DamageMonster(M, 30, Src);
    Particles.SpawnBlood(QuakeToCge(T.EndPos), QuakeToCge(Dir * -1));
  end else
  if T.Fraction < 1 then
    Particles.SpawnPuff(QuakeToCge(T.EndPos), QuakeToCge(T.PlaneNormal));
end;

procedure TQuakeWorld.FireWeapon(const RayOrigin, RayDir: TVector3; const Hud: TQuakeHud);
var
  Fwd, Right, Up, Src: TVector3;
  Yaw: Single;
  T: TQuakeTrace;
  M: TQuakeMonster;
  CanFire: Boolean;
begin
  if FIntermission then
  begin
    IntermissionContinue;
    Exit;
  end;
  if (FWeaponCooldown > 0) or FPlayerDead or (FBsp = nil) then
    Exit;

  { Aim vectors from the view (Quake coordinates) }
  Fwd := CgeToQuake(RayDir).Normalize;
  Yaw := ArcTan2(Fwd.Y, Fwd.X);
  Right := Vector3(Sin(Yaw), -Cos(Yaw), 0);
  Up := TVector3.CrossProduct(Right, Fwd);
  { Shots leave from the player origin + 16 (absmin + 0.7 * size), like QuakeC }
  Src := FPhys.Origin + Vector3(0, 0, 16);

  CanFire := False;
  case FPlayerStats.CurrentWeapon of
    1: { W_FireAxe }
      begin
        CanFire := True;
        FWeaponCooldown := 0.5;
        FWeaponRecoil := 0.2;
        Sounds.Play('sound/weapons/ax1.wav');
        T := TraceShot(Src, Src + Fwd * 64, M);
        if T.Fraction < 1 then
        begin
          if M <> nil then
          begin
            Particles.SpawnBlood(QuakeToCge(T.EndPos - Fwd * 4), QuakeToCge(Fwd * -1));
            DamageMonster(M, 20, Src);
          end else
          begin
            Sounds.Play('sound/player/axhit2.wav');
            Particles.SpawnPuff(QuakeToCge(T.EndPos - Fwd * 4), QuakeToCge(T.PlaneNormal));
          end;
        end;
      end;

    2: { W_FireShotgun }
      if FPlayerStats.Shells >= 1 then
      begin
        Dec(FPlayerStats.Shells);
        CanFire := True;
        FWeaponCooldown := 0.5;
        FWeaponRecoil := 0.35;
        Sounds.Play('sound/weapons/guncock.wav');
        Lighting.TriggerMuzzleFlash(RayOrigin + RayDir * 20.0, 3.0);
        FireBullets(6, Src, Fwd, Right, Up, 0.04, 0.04);
      end;

    3: { W_FireSuperShotgun, falls back to the shotgun with one shell }
      if FPlayerStats.Shells >= 2 then
      begin
        Dec(FPlayerStats.Shells, 2);
        CanFire := True;
        FWeaponCooldown := 0.7;
        FWeaponRecoil := 0.6;
        Sounds.Play('sound/weapons/shotgn2.wav');
        Lighting.TriggerMuzzleFlash(RayOrigin + RayDir * 20.0, 4.5);
        FireBullets(14, Src, Fwd, Right, Up, 0.14, 0.08);
      end else
      if FPlayerStats.Shells = 1 then
      begin
        Dec(FPlayerStats.Shells);
        CanFire := True;
        FWeaponCooldown := 0.5;
        FWeaponRecoil := 0.35;
        Sounds.Play('sound/weapons/guncock.wav');
        FireBullets(6, Src, Fwd, Right, Up, 0.04, 0.04);
      end;

    4, 5: { W_FireSpikes: 10 nails per second from alternating barrels }
      if FPlayerStats.Nails >= 1 then
      begin
        CanFire := True;
        FWeaponCooldown := 0.1;
        FWeaponRecoil := 0.15;
        Lighting.TriggerMuzzleFlash(RayOrigin + RayDir * 20.0, 2.0);
        if (FPlayerStats.CurrentWeapon = 5) and (FPlayerStats.Nails >= 2) then
        begin
          Dec(FPlayerStats.Nails, 2);
          Sounds.Play('sound/weapons/spike2.wav');
          LaunchSpike(pjSuperNail, Src, Fwd);
        end else
        begin
          Dec(FPlayerStats.Nails);
          Sounds.Play('sound/weapons/rocket1i.wav');
          if FNailOffset > 0 then
            FNailOffset := -4
          else
            FNailOffset := 4;
          LaunchSpike(pjNail, Src + Right * FNailOffset, Fwd);
        end;
      end;

    6: { W_FireGrenade }
      if FPlayerStats.Rockets >= 1 then
      begin
        Dec(FPlayerStats.Rockets);
        CanFire := True;
        FWeaponCooldown := 0.6;
        FWeaponRecoil := 0.5;
        Sounds.Play('sound/weapons/grenade.wav');
        FProjectiles.Add(TQuakeProjectile.Create(FRootTransform, pjGrenade, FPhys.Origin,
          Fwd * 600 + Up * 200 + Right * ((Random * 2 - 1) * 10) + Up * ((Random * 2 - 1) * 10)));
      end;

    7: { W_FireRocket }
      if FPlayerStats.Rockets >= 1 then
      begin
        Dec(FPlayerStats.Rockets);
        CanFire := True;
        FWeaponCooldown := 0.8;
        FWeaponRecoil := 0.7;
        Sounds.Play('sound/weapons/sgun1.wav');
        Lighting.TriggerMuzzleFlash(RayOrigin + RayDir * 20.0, 5.0);
        FProjectiles.Add(TQuakeProjectile.Create(FRootTransform, pjRocket,
          FPhys.Origin + Fwd * 8 + Vector3(0, 0, 16), Fwd * 1000));
      end;

    8: { W_FireLightning }
      if FPlayerStats.Cells >= 1 then
      begin
        CanFire := True;
        FWeaponCooldown := 0.1;
        FWeaponRecoil := 0.1;
        Dec(FPlayerStats.Cells);
        Lighting.TriggerMuzzleFlash(RayOrigin + RayDir * 20.0, 4.0);
        FireLightning(Src, Fwd, Hud);
      end;
  end;

  { View weapon: frame 0 is the idle pose, the following frames the attack
    (weaponframe 1.. in QuakeC) }
  if CanFire and (FWeaponAnim <> nil) and (FWeaponMdl.FrameCount > 1) then
    FWeaponAnim.Play(FWeaponMdl.Sequence(1, FWeaponMdl.FrameCount - 1, False), True);

  { W_Attack: show_hostile; guns are heard, the axe only makes monsters
    nearby notice the player behind them }
  if CanFire then
  begin
    if FPlayerStats.CurrentWeapon = 1 then
      FShowHostile := FTime + 1
    else
      PropagateNoise;
  end;

  if not CanFire then
  begin
    FWeaponCooldown := 0.3;
    Sounds.Play('sound/weapons/noammo.wav');
  end;
end;

function ProjectileAttacker(const P: TQuakeProjectile): TQuakeMonster;
begin
  if P.Owner is TQuakeMonster then
    Result := TQuakeMonster(P.Owner)
  else
    Result := nil;
end;

procedure TQuakeWorld.ExplodeProjectile(const P: TQuakeProjectile; const Direct: TQuakeMonster;
  const Hud: TQuakeHud; const DirectPlayer: Boolean);
var
  Center: TVector3;
  ByPlayer: Boolean;
  Attacker: TQuakeMonster;
begin
  { T_MissileTouch / GrenadeExplode / OgreGrenadeExplode / ShalMissileTouch:
    direct hit damage, then radius damage from slightly behind the impact }
  Center := P.Origin;
  if not P.Velocity.IsPerfectlyZero then
    Center := Center - P.Velocity.Normalize * 8;
  ByPlayer := P.Owner = nil;
  Attacker := ProjectileAttacker(P);
  case P.Kind of
    pjRocket, pjLavaBall:
      begin
        { The direct target is left out of the splash }
        if Direct <> nil then
          DamageMonster(Direct, 100 + Random * 20, P.Origin, Attacker);
        if DirectPlayer then
          DamagePlayer(100 + Random(20), Hud);
        RadiusDamage(Center, 120, Direct, Hud, ByPlayer, DirectPlayer, Attacker);
      end;
    pjOgreGrenade:
      RadiusDamage(Center, 40, nil, Hud, False, False, Attacker);
    pjVorePod:
      begin
        if (Direct <> nil) and (Direct.EntityClassName = 'monster_zombie') then
          DamageMonster(Direct, 110, P.Origin, Attacker);
        RadiusDamage(Center, 40, nil, Hud, False, False, Attacker);
      end;
    else
      RadiusDamage(Center, 120, nil, Hud, ByPlayer, False, Attacker);
  end;
  Particles.SpawnExplosion(QuakeToCge(Center));
  Lighting.TriggerMuzzleFlash(QuakeToCge(Center), 6.0);
  Sounds.PlayAt('sound/weapons/r_exp3.wav', P.Transform);
end;

function VelocityForDamage(const Damage: Single): TVector3;
begin
  { VelocityForDamage (player.qc): the more overkill, the faster the gibs }
  Result := Vector3(100 * (Random * 2 - 1), 100 * (Random * 2 - 1), 200 + 100 * Random);
  if Damage > -50 then
    Result := Result * 0.7
  else if Damage > -200 then
    Result := Result * 2
  else
    Result := Result * 10;
end;

procedure TQuakeWorld.GibMonster(const M: TQuakeMonster);
var
  Org: TVector3;
  Gib: TQuakeGib;
  I: Integer;
begin
  M.GibPending := False;
  Org := M.Origin;
  { The body is replaced by its head }
  M.Transform.Exists := False;
  Sounds.PlayAt('sound/player/udeath.wav', M.Transform);

  for I := 0 to High(M.Def.GibModels) do
  begin
    { ThrowGib: removed after 10 to 20 seconds }
    Gib := TQuakeGib.Create(FRootTransform, M.Def.GibModels[I], Org, VelocityForDamage(M.Health),
      10 + Random * 10);
    Gib.AngularVelocity := Vector3(Random * 600, Random * 600, Random * 600);
    FGibs.Add(Gib);
  end;

  { ThrowHead: the head stays, 24 units lower, spinning around its up axis }
  if M.Def.Head <> '' then
  begin
    Gib := TQuakeGib.Create(FRootTransform, M.Def.Head, Org - Vector3(0, 0, 24),
      VelocityForDamage(M.Health), -1);
    Gib.AngularVelocity := Vector3(0, (Random * 2 - 1) * 600, 0);
    FGibs.Add(Gib);
  end;

  { Blood fountain }
  for I := 1 to 3 do
    Particles.SpawnBlood(QuakeToCge(Org + Vector3(0, 0, 8 * I)), Vector3(0, 1, 0));
end;

procedure TQuakeWorld.UpdateGibs(const SecondsPassed: Single);
var
  I: Integer;
  G: TQuakeGib;
  T: TQuakeTrace;
begin
  for I := FGibs.Count - 1 downto 0 do
  begin
    G := FGibs[I];
    if G.Life >= 0 then
    begin
      G.Life := G.Life - SecondsPassed;
      if G.Life <= 0 then
      begin
        FGibs.Delete(I);
        Continue;
      end;
    end;
    if G.OnGround or (FBsp = nil) then
      Continue;

    { SV_Physics_Toss with MOVETYPE_BOUNCE, against the world and brush entities }
    G.Velocity.Z := G.Velocity.Z - SvGravity * SecondsPassed;
    G.Angles := G.Angles + G.AngularVelocity * SecondsPassed;
    T := FPhys.Trace(G.Origin, G.Origin + G.Velocity * SecondsPassed, True, True);
    G.Origin := T.EndPos;
    if T.Fraction < 1 then
    begin
      G.Velocity := ClipVelocity(G.Velocity, T.PlaneNormal, 1.5);
      if (T.PlaneNormal.Z > 0.7) and (G.Velocity.Z < 60) then
      begin
        G.OnGround := True;
        G.Velocity := TVector3.Zero;
        G.AngularVelocity := TVector3.Zero;
      end;
    end;

    { EF_GIB blood trail while flying }
    G.TrailTimer := G.TrailTimer - SecondsPassed;
    if G.TrailTimer <= 0 then
    begin
      Particles.SpawnBloodTrail(QuakeToCge(G.Origin));
      G.TrailTimer := 0.05;
    end;
    G.UpdateVisual;
  end;
end;

procedure TQuakeWorld.UpdateProjectiles(const SecondsPassed: Single; const Hud: TQuakeHud);
var
  I, J: Integer;
  P: TQuakeProjectile;
  T: TQuakeTrace;
  M: TQuakeMonster;
  HitPlayer, Remove, Bounces: Boolean;
  Damage: Single;

  procedure DirectHit(const Amount: Single);
  begin
    if HitPlayer then
    begin
      DamagePlayer(Max(1, Round(Amount)), Hud);
      Particles.SpawnBlood(QuakeToCge(T.EndPos), QuakeToCge(P.Velocity.Normalize * -1));
    end else
    if M <> nil then
    begin
      Particles.SpawnBlood(QuakeToCge(T.EndPos), QuakeToCge(P.Velocity.Normalize * -1));
      DamageMonster(M, Amount, T.EndPos, ProjectileAttacker(P));
    end;
  end;

begin
  for I := FProjectiles.Count - 1 downto 0 do
  begin
    P := FProjectiles[I];
    Remove := False;
    P.Life := P.Life - SecondsPassed;
    Bounces := P.Kind in [pjGrenade, pjOgreGrenade];

    if P.Life <= 0 then
    begin
      if Bounces then
        ExplodeProjectile(P, nil, Hud); { fuse ran out }
      Remove := True;
    end else
    if not P.OnGround then
    begin
      { Grenades and zombie flesh fall, the rest fly straight }
      if Bounces or (P.Kind = pjZombieGib) then
      begin
        P.Velocity.Z := P.Velocity.Z - SvGravity * SecondsPassed;
        P.Spin := P.Spin + 300 * SecondsPassed;
      end;
      if P.Kind = pjLavaBall then
        P.Spin := P.Spin + 200 * SecondsPassed;

      { ShalHome: vore pods steer towards the vore's enemy }
      if P.Kind = pjVorePod then
      begin
        P.HomeTimer := P.HomeTimer - SecondsPassed;
        if P.HomeTimer <= 0 then
        begin
          P.HomeTimer := 0.2;
          M := ProjectileAttacker(P);
          if (M <> nil) and (M.Enemy <> nil) then
          begin
            if M.Enemy.IsSolid then
              P.Velocity := (M.Enemy.Origin + Vector3(0, 0, 10) - P.Origin).Normalize * 350;
          end else
          if not FPlayerDead then
            P.Velocity := (FPhys.Origin + Vector3(0, 0, 10) - P.Origin).Normalize * 350;
        end;
      end;

      T := TraceMissile(P.Origin, P.Origin + P.Velocity * SecondsPassed, P.Owner, M, HitPlayer);
      P.Origin := T.EndPos;

      if (T.Fraction < 1) or T.StartSolid then
      begin
        if (M = nil) and not HitPlayer and (FBsp.PointContents(T.EndPos) = CONTENTS_SKY) then
          Remove := True { missiles vanish into the sky }
        else
        case P.Kind of
          pjNail, pjSuperNail, pjWizSpike, pjKnightSpike, pjLaser:
            begin
              { spike_touch, Wiz_MissileTouch, laser touch }
              case P.Kind of
                pjSuperNail: Damage := 18;
                pjLaser: Damage := 15;
                else Damage := 9;
              end;
              if HitPlayer or (M <> nil) then
                DirectHit(Damage)
              else
              begin
                Particles.SpawnPuff(QuakeToCge(T.EndPos), QuakeToCge(T.PlaneNormal));
                if P.Kind = pjLaser then
                  Sounds.PlayAt('sound/enforcer/enfstop.wav', P.Transform)
                else
                case Random(5) of
                  0: Sounds.PlayAt('sound/weapons/ric1.wav', P.Transform);
                  1: Sounds.PlayAt('sound/weapons/ric2.wav', P.Transform);
                  2: Sounds.PlayAt('sound/weapons/ric3.wav', P.Transform);
                  else Sounds.PlayAt('sound/weapons/tink1.wav', P.Transform);
                end;
              end;
              Remove := True;
            end;
          pjRocket, pjLavaBall, pjVorePod:
            begin
              ExplodeProjectile(P, M, Hud, HitPlayer);
              Remove := True;
            end;
          pjZombieGib:
            begin
              { ZombieGrenadeTouch: 10 damage, or lie on the floor }
              if HitPlayer or (M <> nil) then
              begin
                DirectHit(10);
                Sounds.PlayAt('sound/zombie/z_hit.wav', P.Transform);
                Remove := True;
              end else
              begin
                Sounds.PlayAt('sound/zombie/z_miss.wav', P.Transform);
                P.OnGround := True;
                P.Velocity := TVector3.Zero;
                P.Life := Min(P.Life, 1.5);
              end;
            end;
          pjGrenade, pjOgreGrenade:
            if HitPlayer or (M <> nil) then
            begin
              ExplodeProjectile(P, M, Hud); { GrenadeTouch: explode on contact }
              Remove := True;
            end else
            begin
              { Bounce off walls, come to rest on floors }
              P.Velocity := ClipVelocity(P.Velocity, T.PlaneNormal, 1.5);
              if (T.PlaneNormal.Z > 0.7) and (P.Velocity.Z < 60) then
              begin
                P.OnGround := True;
                P.Velocity := TVector3.Zero;
              end;
              Sounds.PlayAt('sound/weapons/bounce.wav', P.Transform);
            end;
        end;
      end;

      { Trails }
      if not Remove then
      begin
        P.TrailTimer := P.TrailTimer - SecondsPassed;
        if P.TrailTimer <= 0 then
        begin
          case P.Kind of
            pjRocket, pjLavaBall:
              begin
                Particles.SpawnRocketTrail(QuakeToCge(P.Origin));
                P.TrailTimer := 0.03;
              end;
            pjGrenade, pjOgreGrenade:
              begin
                Particles.SpawnGrenadeTrail(QuakeToCge(P.Origin));
                P.TrailTimer := 0.05;
              end;
            pjZombieGib:
              begin
                Particles.SpawnBloodTrail(QuakeToCge(P.Origin));
                P.TrailTimer := 0.05;
              end;
            pjWizSpike:
              begin
                Particles.SpawnTrail(QuakeToCge(P.Origin), Vector3(0.3, 0.9, 0.2));
                P.TrailTimer := 0.04;
              end;
            pjKnightSpike:
              begin
                Particles.SpawnTrail(QuakeToCge(P.Origin), Vector3(1.0, 0.55, 0.15));
                P.TrailTimer := 0.04;
              end;
            pjVorePod:
              begin
                Particles.SpawnTrail(QuakeToCge(P.Origin), Vector3(0.7, 0.3, 0.9));
                P.TrailTimer := 0.04;
              end;
            pjLaser:
              P.TrailTimer := 1; { glows on its own }
            else
              begin
                Particles.SpawnNailTrail(QuakeToCge(P.Origin));
                P.TrailTimer := 0.04;
              end;
          end;
        end;
      end;
    end;

    if Remove then
      FProjectiles.Delete(I)
    else
      P.UpdateVisual;
  end;

  { Lightning beams last a moment after each discharge }
  for J := 0 to High(FBeams) do
    if FBeams[J].Time > 0 then
    begin
      FBeams[J].Time := FBeams[J].Time - SecondsPassed;
      if FBeams[J].Time <= 0 then
        for I := 0 to High(FBeams[J].Segments) do
          FBeams[J].Segments[I].Exists := False;
    end;
end;

procedure TQuakeWorld.ActivateUse(const RayOrigin, RayDir: TVector3; const Hud: TQuakeHud);
var
  Sub: TQuakeSubmodel;
  AMins, AMaxs, P: TVector3;
  I: Integer;
begin
  if FIntermission then
  begin
    IntermissionContinue;
    Exit;
  end;
  { Quake has no use key, this is a convenience: activate the door or button
    whose bounds are close to the point in front of the player }
  if FGeometry = nil then
    Exit;
  P := CgeToQuake(RayOrigin + RayDir * 48);
  for Sub in FGeometry.Submodels do
  begin
    if not SubmodelBounds(Sub, AMins, AMaxs) then
      Continue;
    for I := 0 to 2 do
    begin
      AMins.Data[I] := AMins.Data[I] - 32;
      AMaxs.Data[I] := AMaxs.Data[I] + 32;
    end;
    if (P.X >= AMins.X) and (P.X <= AMaxs.X) and (P.Y >= AMins.Y) and (P.Y <= AMaxs.Y) and
       (P.Z >= AMins.Z) and (P.Z <= AMaxs.Z) then
    begin
      if Sub.EntityClassName = 'func_button' then
        PressButton(Sub)
      else
      begin
        Sub.Trigger;
        Sounds.PlayAt('sound/doors/dr1_strt.wav', Sub.Transform);
      end;
      Break;
    end;
  end;
end;

procedure TQuakeWorld.CheatGiveAll(const Hud: TQuakeHud);
begin
  FPlayerStats.WeaponMask := $1FE; { weapons 1..8 }
  FPlayerStats.Shells := FPlayerStats.MaxShells;
  FPlayerStats.Nails := FPlayerStats.MaxNails;
  FPlayerStats.Rockets := FPlayerStats.MaxRockets;
  FPlayerStats.Cells := FPlayerStats.MaxCells;
  FPlayerStats.Armor := 200;
  FPlayerStats.ArmorType := 3;
  FPlayerStats.Health := 100;
  FPlayerStats.Keys := 3; { both keys }
  if Hud <> nil then
    Hud.ShowMessage('Gave all weapons, keys, and max ammo');
end;

procedure TQuakeWorld.CheatGodMode(const Hud: TQuakeHud);
begin
  FGodMode := not FGodMode;
  if Hud <> nil then
  begin
    if FGodMode then
      Hud.ShowMessage('God mode ON')
    else
      Hud.ShowMessage('God mode OFF');
  end;
end;

end.
