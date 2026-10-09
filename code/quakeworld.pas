{ Quake 1 gameplay simulation: weapons, inventory, combat, monster AI,
  pickups, doors, lifts, and world interactions. }
unit QuakeWorld;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math,
  CastleVectors, CastleTransform, CastleScene, CastleLog, CastleColors,
  QuakeBsp, QuakeGeometry, QuakeMdl, QuakeLight, QuakeSound, QuakeHud,
  QuakeParticles, QuakeEntities;

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
    FPlayerStats: TQuakePlayerStats;
    FPlayerPos: TVector3;
    FPlayerFacing: Single;
    FPlayerPitch: Single;
    FWeaponScene: TCastleScene;
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
begin
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
      FSpawnPoint := Pos + Vector3(0, 24, 0);
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
      Mins := Pos - Vector3(32, 32, 32);
      Maxs := Pos + Vector3(32, 32, 32);
      Trig := TQuakeTrigger.Create(CName, Mins, Maxs, Ent.Target, Ent.GetField('map'));
      FTriggers.Add(Trig);
    end;
  end;

  WritelnLog('QuakeWorld', 'Spawned %d pickups, %d monsters, %d triggers',
    [FPickups.Count, FMonsters.Count, FTriggers.Count]);
end;

function TQuakeWorld.LoadMap(const AMapName: String): Boolean;
var
  MapPath: String;
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
  Dist: Single;
begin
  for I := 0 to FPickups.Count - 1 do
  begin
    P := FPickups[I];
    if P.Collected then
      Continue;

    Dist := (P.Transform.Translation - FPlayerPos).Length;
    if Dist < 40.0 then
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
  Ent: TQuakeEntity;
  DestPos: TVector3;
  Sub: TQuakeSubmodel;
begin
  for Trig in FTriggers do
  begin
    if Trig.Intersects(FPlayerPos, 20.0) then
    begin
      if Trig.EntityClassName = 'trigger_changelevel' then
      begin
        FLevelExited := True;
        FNextMap := Trig.MapName;
      end else
      if Trig.EntityClassName = 'trigger_teleport' then
      begin
        { Teleport destination lookup }
        Ent := FBsp.FindEntity('info_teleport_destination');
        if (Ent <> nil) and (Ent.TargetName = Trig.Target) then
        begin
          DestPos := QuakeToCge(Ent.Origin) + Vector3(0, 24, 0);
          Particles.SpawnTeleport(DestPos);
          Sounds.Play('sound/misc/r_tele1.wav');
        end;
      end else
      if (Trig.EntityClassName = 'trigger_multiple') or (Trig.EntityClassName = 'trigger_once') then
      begin
        Sub := FGeometry.FindSubmodel(Trig.Target);
        if Sub <> nil then
          Sub.Trigger;
      end;
    end;
  end;
end;

procedure TQuakeWorld.Update(const SecondsPassed: Single; const PlayerPos: TVector3;
  const PlayerFacing, PlayerPitch: Single; const Hud: TQuakeHud);
var
  I: Integer;
  M: TQuakeMonster;
  Proj: TQuakeProjectile;
  Sub: TQuakeSubmodel;
  Dist: Single;
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
  for I := FProjectiles.Count - 1 downto 0 do
  begin
    Proj := FProjectiles[I];
    if not Proj.Update(SecondsPassed) then
      FProjectiles.Delete(I);
  end;

  { Proximity trigger for automatic doors }
  if FGeometry <> nil then
  begin
    for Sub in FGeometry.Submodels do
    begin
      if (Sub.EntityClassName = 'func_door') or (Sub.EntityClassName = 'func_plat') then
      begin
        Dist := (Sub.Transform.Translation - FPlayerPos).Length;
        if (Dist < 80.0) and (Sub.State = smsClosed) then
        begin
          Sub.Trigger;
          Sounds.PlayAt('sound/doors/dr1_strt.wav', Sub.Transform);
        end;
      end;
    end;
  end;

  { Advance particles }
  Particles.Update(SecondsPassed);

  { Update lighting styles and muzzle timer }
  Lighting.Update(SecondsPassed, FPlayerPos);

  { Update weapon cooldown and view recoil }
  if FWeaponCooldown > 0 then
    FWeaponCooldown := FWeaponCooldown - SecondsPassed;

  if FWeaponRecoil > 0 then
    FWeaponRecoil := Max(0, FWeaponRecoil - SecondsPassed * 4.0);

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

procedure TQuakeWorld.FireWeapon(const RayOrigin, RayDir: TVector3; const Hud: TQuakeHud);
var
  I, Pellets, DamagePerPellet: Integer;
  ShotDir: TVector3;
  HitDist, BestDist: Single;
  HitPoint, HitNormal: TVector3;
  HitMonster: TQuakeMonster;
  M: TQuakeMonster;
  Proj: TQuakeProjectile;
  CanFire: Boolean;
begin
  if FWeaponCooldown > 0 then
    Exit;

  CanFire := False;

  case FPlayerStats.CurrentWeapon of
    1: { Axe }
      begin
        CanFire := True;
        FWeaponCooldown := 0.45;
        FWeaponRecoil := 0.2;
        Sounds.Play('sound/weapons/ax1.wav');

        { Melee trace }
        for M in FMonsters do
        begin
          if (M.State <> msDead) and ((M.Transform.Translation - RayOrigin).Length < 64.0) then
          begin
            M.TakeDamage(20, RayOrigin);
            Particles.SpawnBlood(M.Transform.Translation + Vector3(0, 24, 0), -RayDir);
            Break;
          end;
        end;
      end;

    2: { Shotgun }
      begin
        if FPlayerStats.Shells >= 1 then
        begin
          Dec(FPlayerStats.Shells);
          CanFire := True;
          FWeaponCooldown := 0.5;
          FWeaponRecoil := 0.35;
          Sounds.Play('sound/weapons/guncock.wav');
          Lighting.TriggerMuzzleFlash(RayOrigin + RayDir * 20.0, 3.0);

          Pellets := 6;
          DamagePerPellet := 4;
          for I := 1 to Pellets do
          begin
            ShotDir := RayDir + Vector3((Random - 0.5) * 0.08, (Random - 0.5) * 0.08, (Random - 0.5) * 0.08);
            ShotDir := ShotDir.Normalize;

            BestDist := 2000.0;
            HitMonster := nil;
            for M in FMonsters do
            begin
              if M.State <> msDead then
              begin
                HitDist := (M.Transform.Translation - RayOrigin).Length;
                if (HitDist < BestDist) and (HitDist > 10.0) then
                begin
                  BestDist := HitDist;
                  HitMonster := M;
                end;
              end;
            end;

            if HitMonster <> nil then
            begin
              HitMonster.TakeDamage(DamagePerPellet, RayOrigin);
              Particles.SpawnBlood(HitMonster.Transform.Translation + Vector3(0, 20, 0), -ShotDir);
            end else
            begin
              HitPoint := RayOrigin + ShotDir * 400.0;
              Particles.SpawnImpact(HitPoint, -ShotDir);
            end;
          end;
        end;
      end;

    3: { Super Shotgun }
      begin
        if FPlayerStats.Shells >= 2 then
        begin
          FPlayerStats.Shells := FPlayerStats.Shells - 2;
          CanFire := True;
          FWeaponCooldown := 0.75;
          FWeaponRecoil := 0.6;
          Sounds.Play('sound/weapons/shotgn2.wav');
          Lighting.TriggerMuzzleFlash(RayOrigin + RayDir * 20.0, 4.5);

          Pellets := 14;
          DamagePerPellet := 4;
          for I := 1 to Pellets do
          begin
            ShotDir := RayDir + Vector3((Random - 0.5) * 0.14, (Random - 0.5) * 0.14, (Random - 0.5) * 0.14);
            ShotDir := ShotDir.Normalize;

            BestDist := 2000.0;
            HitMonster := nil;
            for M in FMonsters do
            begin
              if M.State <> msDead then
              begin
                HitDist := (M.Transform.Translation - RayOrigin).Length;
                if HitDist < BestDist then
                begin
                  BestDist := HitDist;
                  HitMonster := M;
                end;
              end;
            end;

            if HitMonster <> nil then
            begin
              HitMonster.TakeDamage(DamagePerPellet, RayOrigin);
              Particles.SpawnBlood(HitMonster.Transform.Translation + Vector3(0, 20, 0), -ShotDir);
            end else
            begin
              HitPoint := RayOrigin + ShotDir * 350.0;
              Particles.SpawnImpact(HitPoint, -ShotDir);
            end;
          end;
        end;
      end;

    4, 5: { Nailgun / Super Nailgun }
      begin
        if FPlayerStats.Nails >= 1 then
        begin
          Dec(FPlayerStats.Nails);
          CanFire := True;
          FWeaponCooldown := 0.12;
          FWeaponRecoil := 0.15;
          Sounds.Play('sound/weapons/rocket1i.wav');
          Lighting.TriggerMuzzleFlash(RayOrigin + RayDir * 20.0, 2.0);

          Proj := TQuakeProjectile.Create(FRootTransform, RayOrigin + RayDir * 20.0,
            RayDir * 900.0, 'progs/spike.mdl', 9, 0, False, True);
          FProjectiles.Add(Proj);
        end;
      end;

    6, 7: { Rocket Launcher }
      begin
        if FPlayerStats.Rockets >= 1 then
        begin
          Dec(FPlayerStats.Rockets);
          CanFire := True;
          FWeaponCooldown := 0.8;
          FWeaponRecoil := 0.7;
          Sounds.Play('sound/weapons/sgun1.wav');
          Lighting.TriggerMuzzleFlash(RayOrigin + RayDir * 20.0, 5.0);

          Proj := TQuakeProjectile.Create(FRootTransform, RayOrigin + RayDir * 20.0,
            RayDir * 1000.0, 'progs/missile.mdl', 100, 120.0, True, True);
          FProjectiles.Add(Proj);
        end;
      end;
  end;

  if not CanFire and (FPlayerStats.Ammo <= 0) then
    Sounds.Play('sound/weapons/noammo.wav');
end;

procedure TQuakeWorld.ActivateUse(const RayOrigin, RayDir: TVector3; const Hud: TQuakeHud);
var
  Sub: TQuakeSubmodel;
  Dist: Single;
begin
  if FGeometry = nil then
    Exit;

  for Sub in FGeometry.Submodels do
  begin
    Dist := (Sub.Transform.Translation - RayOrigin).Length;
    if Dist < 100.0 then
    begin
      Sub.Trigger;
      Sounds.PlayAt('sound/doors/dr1_strt.wav', Sub.Transform);
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
