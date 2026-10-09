{ Quake 1 gameplay simulation: weapons, inventory, combat, monster AI,
  pickups, doors, lifts, and world interactions. }
unit QuakeWorld;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math,
  CastleVectors, CastleTransform, CastleScene, CastleLog, CastleColors, CastleQuaternions,
  QuakeBsp, QuakeGeometry, QuakeMdl, QuakeLight, QuakeSound, QuakeHud,
  QuakeParticles, QuakeEntities, QuakeAmbient, QuakePhysics;

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
    FBoltSegments: array of TCastleTransform;
    FBoltTime: Single;
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
    { CanDamage: the explosion can see the target center or one of its corners }
    function CanDamage(const Inflictor, TargetCenter: TVector3): Boolean;
    { T_RadiusDamage from an explosion at Center (Quake coordinates) }
    procedure RadiusDamage(const Center: TVector3; const Damage: Single;
      const Ignore: TQuakeMonster; const Hud: TQuakeHud);
    procedure DamageMonster(const M: TQuakeMonster; const Damage: Single; const From: TVector3);
    procedure FireBullets(const Count: Integer; const Src, Dir, Right, Up: TVector3;
      const SpreadX, SpreadY: Single);
    procedure LaunchSpike(const Kind: TQuakeProjectileKind; const Src, Dir: TVector3);
    procedure FireLightning(const Src, Dir: TVector3; const Hud: TQuakeHud);
    procedure ShowLightningBeam(const StartQ, StopQ: TVector3);
    procedure ExplodeProjectile(const P: TQuakeProjectile; const Direct: TQuakeMonster;
      const Hud: TQuakeHud);
    procedure UpdateProjectiles(const SecondsPassed: Single; const Hud: TQuakeHud);
    procedure PressButton(const Sub: TQuakeSubmodel);
    procedure SpawnEntities;
    procedure UpdateWeaponModel;
    procedure ResetPlayerStats;
    procedure CheckPickups(const Hud: TQuakeHud);
    function MonsterSeesPlayer(const M: TQuakeMonster): Boolean;
    function MonsterHitChance(const M: TQuakeMonster): Single;
    procedure CheckTriggers;
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
    property Monsters: TQuakeMonsterList read FMonsters;
    property Pickups: TQuakePickupList read FPickups;
    property WeaponTransform: TCastleTransform read FWeaponTransform;
    property Bsp: TQuakeBsp read FBsp;
  end;

implementation

constructor TQuakeWorld.Create(const ARoot: TCastleTransform);
begin
  inherited Create;
  FRootTransform := ARoot;
  FBsp := nil;
  FGeometry := nil;
  FPickups := TQuakePickupList.Create(True);
  FMonsters := TQuakeMonsterList.Create(True);
  FProjectiles := TQuakeProjectileList.Create(True);
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
  FWeaponModelName := 'progs/v_shot.mdl';
  FPlayerDead := False;
end;

procedure TQuakeWorld.RespawnPlayer;
begin
  ResetPlayerStats;
  UpdateWeaponModel;
end;

function TQuakeWorld.PointContents(const P: TVector3): Integer;
begin
  if FBsp <> nil then
    Result := FBsp.PointContentsCge(P)
  else
    Result := CONTENTS_EMPTY;
end;

function TQuakeWorld.MonsterSeesPlayer(const M: TQuakeMonster): Boolean;
var
  Eye, Delta: TVector3;
  Len, HitDist: Single;
  Hit: TCastleTransform;
begin
  { Like Quake's visible(): a traceline from the monster's eyes that only
    world geometry and brush entities (closed doors) can block. }
  Result := True;
  if FGeometry = nil then
    Exit;
  Eye := M.Transform.Translation + Vector3(0, 24, 0);
  Delta := FPlayerPos - Eye;
  Len := Delta.Length;
  if Len < 1 then
    Exit;
  Hit := M.Transform.RayCast(Eye, Delta / Len, HitDist);
  Result := not ((Hit <> nil) and (HitDist < Len) and FGeometry.IsGeometryScene(Hit));
end;

function TQuakeWorld.MonsterHitChance(const M: TQuakeMonster): Single;
const
  MeleeRange = 100.0;
begin
  { Monster attacks are instant for now. Ranged ones stand in for spread
    shotgun blasts and dodgeable grenades, so they hit less often far away. }
  if M.AttackRange <= MeleeRange then
    Result := 1.0
  else
    Result := EnsureRange(1.0 - 0.75 * (M.Transform.Translation - FPlayerPos).Length / M.AttackRange, 0.25, 1.0);
end;

function SubmodelIsSolid(const Sub: TQuakeSubmodel): Boolean;
begin
  { Triggers and illusionary walls are SOLID_NOT }
  Result := (Pos('trigger_', Sub.EntityClassName) <> 1) and
    (Sub.EntityClassName <> 'func_illusionary');
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
begin
  { SUB_UseTargets: activate every brush entity with this targetname }
  if (Target = '') or (FGeometry = nil) then
    Exit;
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
  if FPlayerDead or FGodMode or (Damage <= 0) then
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
  I: Integer;
begin
  for I := 0 to High(FBoltSegments) do
    FBoltSegments[I].Free;
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
begin
  FPickups.Clear;
  FMonsters.Clear;
  FTriggers.Clear;

  for I := 0 to FBsp.Entities.Count - 1 do
  begin
    Ent := FBsp.Entities[I];
    CName := LowerCase(Ent.ClassName);
    Pos := QuakeToCge(Ent.Origin);
    Yaw := Ent.Angle;

    { Player start }
    if CName = 'info_player_start' then
    begin
      FSpawnOrigin := Ent.Origin;
      FSpawnPoint := QuakeToCge(Ent.Origin + Vector3(0, 0, FPhys.ViewHeight));
      FSpawnAngle := Yaw;
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

    { Monsters }
    if CName = 'monster_army' then
    begin
      Monster := TQuakeMonster.Create(FRootTransform, CName, Pos, Yaw, 'progs/soldier.mdl',
        30, 9, 80.0, 500.0);
      FMonsters.Add(Monster);
      Inc(FPlayerStats.TotalKills);
    end else
    if CName = 'monster_dog' then
    begin
      Monster := TQuakeMonster.Create(FRootTransform, CName, Pos, Yaw, 'progs/dog.mdl',
        25, 12, 140.0, 48.0);
      FMonsters.Add(Monster);
      Inc(FPlayerStats.TotalKills);
    end else
    if CName = 'monster_ogre' then
    begin
      Monster := TQuakeMonster.Create(FRootTransform, CName, Pos, Yaw, 'progs/ogre.mdl',
        200, 25, 60.0, 600.0);
      FMonsters.Add(Monster);
      Inc(FPlayerStats.TotalKills);
    end else
    if CName = 'monster_knight' then
    begin
      Monster := TQuakeMonster.Create(FRootTransform, CName, Pos, Yaw, 'progs/knight.mdl',
        75, 15, 90.0, 55.0);
      FMonsters.Add(Monster);
      Inc(FPlayerStats.TotalKills);
    end else

    { Triggers }
    if (CName = 'trigger_teleport') or (CName = 'trigger_changelevel') or
       (CName = 'trigger_multiple') or (CName = 'trigger_once') then
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
      FTriggers.Add(Trig);
    end;
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

  MapPath := AMapName;
  if ExtractFileExt(MapPath) = '' then
    MapPath := 'maps/' + MapPath + '.bsp';

  FAmbient.Clear;
  FreeAndNil(FGeometry);
  FreeAndNil(FBsp);

  FBsp := TQuakeBsp.Create;
  if not FBsp.LoadFromPak(MapPath) then
  begin
    WritelnWarning('QuakeWorld', 'Failed to load BSP "%s"', [MapPath]);
    Exit;
  end;

  { Build 3D world scene }
  FGeometry := TQuakeGeometry.Create(FBsp);
  FGeometry.AddToWorld(FRootTransform);

  { Initialize dynamic lights from map entities }
  Lighting.CreateLightsFromBsp(FBsp, FRootTransform);

  { Spawn world items and monsters }
  SpawnEntities;

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

  WritelnLog('QuakeWorld', 'Successfully initialized map "%s"', [MapPath]);
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

      case P.Kind of
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
    if not Trig.Touches(BoxMins, BoxMaxs) then
      Continue;

    if Trig.EntityClassName = 'trigger_changelevel' then
    begin
      FLevelExited := True;
      FNextMap := Trig.MapName;
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
    if (Trig.EntityClassName = 'trigger_multiple') or (Trig.EntityClassName = 'trigger_once') then
      UseTargets(Trig.Target);
  end;
end;

procedure TQuakeWorld.Update(const SecondsPassed: Single; const PlayerPos: TVector3;
  const PlayerFacing, PlayerPitch: Single; const Hud: TQuakeHud);
var
  I: Integer;
  M: TQuakeMonster;
begin
  FPlayerPos := PlayerPos;
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

  { Advance monsters }
  for I := 0 to FMonsters.Count - 1 do
  begin
    M := FMonsters[I];
    M.Update(SecondsPassed, FPlayerPos);
    if M.AttackLaunched then
    begin
      M.AttackLaunched := False;
      if MonsterSeesPlayer(M) and (Random < MonsterHitChance(M)) then
        DamagePlayer(M.AttackDamage, Hud);
    end;
    if (M.State = msDead) and (M.Health = 0) then
    begin
      Inc(FPlayerStats.Kills);
      M.Health := -1; { count kill once }
    end;
  end;

  { Advance projectiles }
  UpdateProjectiles(SecondsPassed, Hud);
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
  Result := not (M.State in [msDeath, msDead]);
  if not Result then
    Exit;
  { Sizes from the QuakeC monster spawn functions }
  if M.EntityClassName = 'monster_dog' then
  begin
    AMins := Vector3(-32, -32, -24);
    AMaxs := Vector3(32, 32, 40);
  end else
  if M.EntityClassName = 'monster_ogre' then
  begin
    AMins := Vector3(-32, -32, -24);
    AMaxs := Vector3(32, 32, 64);
  end else
  begin
    AMins := Vector3(-16, -16, -24);
    AMaxs := Vector3(16, 16, 40);
  end;
  Org := CgeToQuake(M.Transform.Translation);
  AMins := AMins + Org;
  AMaxs := AMaxs + Org;
end;

function TQuakeWorld.TraceShot(const Start, Stop: TVector3; out HitMonster: TQuakeMonster): TQuakeTrace;
var
  M: TQuakeMonster;
  BoxMins, BoxMaxs: TVector3;
  T: TQuakeTrace;
begin
  HitMonster := nil;
  if FBsp = nil then
  begin
    FillChar(Result, SizeOf(Result), 0);
    Result.Fraction := 1;
    Result.EndPos := Stop;
    Exit;
  end;
  Result := FPhys.Trace(Start, Stop, True, True);
  for M in FMonsters do
    if MonsterBounds(M, BoxMins, BoxMaxs) then
    begin
      T := TraceSegmentBox(BoxMins, BoxMaxs, Start, Stop);
      if T.StartSolid then
      begin
        { Point blank: the shot starts inside the monster }
        T.Fraction := 0;
        T.EndPos := Start;
        T.PlaneNormal := (Stop - Start).Normalize * -1;
      end;
      if (T.Fraction < Result.Fraction) and (T.Fraction < 1) then
      begin
        Result := T;
        HitMonster := M;
      end;
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

procedure TQuakeWorld.DamageMonster(const M: TQuakeMonster; const Damage: Single; const From: TVector3);
begin
  if Damage > 0 then
    M.TakeDamage(Max(1, Round(Damage)), QuakeToCge(From));
end;

procedure TQuakeWorld.RadiusDamage(const Center: TVector3; const Damage: Single;
  const Ignore: TQuakeMonster; const Hud: TQuakeHud);
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
      if (Points > 0) and CanDamage(Center, Target) then
        DamageMonster(M, Points, Center);
    end;

  { The player takes half damage from their own explosions, and the
    knockback (T_Damage) is what makes rocket jumping work }
  Target := FPhys.Origin + (FPhys.Mins + FPhys.Maxs) * 0.5;
  Points := (Damage - 0.5 * PointsDistance(Center, Target)) * 0.5;
  if (Points > 0) and CanDamage(Center, Target) and not FPlayerDead then
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

procedure TQuakeWorld.ShowLightningBeam(const StartQ, StopQ: TVector3);
const
  SegmentLength = 30.0; { CL_ParseBeam draws bolt models every 30 units }
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
  Count := Min(Ceil(Dist / SegmentLength), 32);

  { Grow the pool of bolt segments when needed }
  while Length(FBoltSegments) < Count do
  begin
    Mdl := MdlManager.GetModel('progs/bolt2.mdl');
    if Mdl = nil then
      Break;
    Seg := TCastleTransform.Create(nil);
    Scene := Mdl.CreateScene(0);
    Scene.Collides := False;
    Seg.Add(Scene);
    FRootTransform.Add(Seg);
    SetLength(FBoltSegments, Length(FBoltSegments) + 1);
    FBoltSegments[High(FBoltSegments)] := Seg;
  end;

  Yaw := ArcTan2(Dir.Y, Dir.X);
  Pitch := ArcTan2(Dir.Z, Sqrt(Sqr(Dir.X) + Sqr(Dir.Y)));
  for I := 0 to High(FBoltSegments) do
  begin
    Seg := FBoltSegments[I];
    Seg.Exists := I < Count;
    if not Seg.Exists then
      Continue;
    { Random roll per segment makes the bolt flicker }
    Q := QuatFromAxisAngle(Vector3(0, 1, 0), Yaw) * QuatFromAxisAngle(Vector3(0, 0, 1), Pitch) *
      QuatFromAxisAngle(Vector3(1, 0, 0), Random * 2 * Pi);
    Seg.Rotation := Q.ToAxisAngle;
    Seg.Translation := QuakeToCge(StartQ + Dir * (I * SegmentLength));
  end;
  FBoltTime := 0.1;
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
  ShowLightningBeam(Src, T.EndPos);
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

  if not CanFire then
  begin
    FWeaponCooldown := 0.3;
    Sounds.Play('sound/weapons/noammo.wav');
  end;
end;

procedure TQuakeWorld.ExplodeProjectile(const P: TQuakeProjectile; const Direct: TQuakeMonster;
  const Hud: TQuakeHud);
var
  Center: TVector3;
begin
  { T_MissileTouch / GrenadeExplode: direct hit damage, then 120 radius damage
    from slightly behind the impact point }
  Center := P.Origin;
  if not P.Velocity.IsPerfectlyZero then
    Center := Center - P.Velocity.Normalize * 8;
  if P.Kind = pjRocket then
  begin
    if Direct <> nil then
      DamageMonster(Direct, 100 + Random * 20, P.Origin);
    RadiusDamage(Center, 120, Direct, Hud);
  end else
    RadiusDamage(Center, 120, nil, Hud);
  Particles.SpawnExplosion(QuakeToCge(Center));
  Lighting.TriggerMuzzleFlash(QuakeToCge(Center), 6.0);
  Sounds.PlayAt('sound/weapons/r_exp3.wav', P.Transform);
end;

procedure TQuakeWorld.UpdateProjectiles(const SecondsPassed: Single; const Hud: TQuakeHud);
var
  I: Integer;
  P: TQuakeProjectile;
  T: TQuakeTrace;
  M: TQuakeMonster;
  Remove: Boolean;
  Damage: Single;
begin
  for I := FProjectiles.Count - 1 downto 0 do
  begin
    P := FProjectiles[I];
    Remove := False;
    P.Life := P.Life - SecondsPassed;

    if P.Life <= 0 then
    begin
      if P.Kind = pjGrenade then
        ExplodeProjectile(P, nil, Hud); { fuse ran out }
      Remove := True;
    end else
    if not P.OnGround then
    begin
      { MOVETYPE_BOUNCE grenades fall, the rest fly straight (MOVETYPE_FLYMISSILE) }
      if P.Kind = pjGrenade then
      begin
        P.Velocity.Z := P.Velocity.Z - SvGravity * SecondsPassed;
        P.Spin := P.Spin + 300 * SecondsPassed;
      end;
      T := TraceShot(P.Origin, P.Origin + P.Velocity * SecondsPassed, M);
      P.Origin := T.EndPos;

      if (T.Fraction < 1) or T.StartSolid then
      begin
        if (M = nil) and (FBsp.PointContents(T.EndPos) = CONTENTS_SKY) then
          Remove := True { missiles vanish into the sky }
        else
        case P.Kind of
          pjNail, pjSuperNail:
            begin
              { spike_touch }
              if P.Kind = pjSuperNail then
                Damage := 18
              else
                Damage := 9;
              if M <> nil then
              begin
                Particles.SpawnBlood(QuakeToCge(T.EndPos), QuakeToCge(P.Velocity.Normalize * -1));
                DamageMonster(M, Damage, T.EndPos);
              end else
              begin
                Particles.SpawnPuff(QuakeToCge(T.EndPos), QuakeToCge(T.PlaneNormal));
                case Random(5) of
                  0: Sounds.PlayAt('sound/weapons/ric1.wav', P.Transform);
                  1: Sounds.PlayAt('sound/weapons/ric2.wav', P.Transform);
                  2: Sounds.PlayAt('sound/weapons/ric3.wav', P.Transform);
                  else Sounds.PlayAt('sound/weapons/tink1.wav', P.Transform);
                end;
              end;
              Remove := True;
            end;
          pjRocket:
            begin
              ExplodeProjectile(P, M, Hud);
              Remove := True;
            end;
          pjGrenade:
            if M <> nil then
            begin
              ExplodeProjectile(P, M, Hud); { GrenadeTouch: explode on monsters }
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
            pjRocket:
              begin
                Particles.SpawnRocketTrail(QuakeToCge(P.Origin));
                P.TrailTimer := 0.03;
              end;
            pjGrenade:
              begin
                Particles.SpawnGrenadeTrail(QuakeToCge(P.Origin));
                P.TrailTimer := 0.05;
              end;
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

  { Lightning beam lasts a moment after each discharge }
  if FBoltTime > 0 then
  begin
    FBoltTime := FBoltTime - SecondsPassed;
    if FBoltTime <= 0 then
      for I := 0 to High(FBoltSegments) do
        FBoltSegments[I].Exists := False;
  end;
end;

procedure TQuakeWorld.ActivateUse(const RayOrigin, RayDir: TVector3; const Hud: TQuakeHud);
var
  Sub: TQuakeSubmodel;
  AMins, AMaxs, P: TVector3;
  I: Integer;
begin
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
