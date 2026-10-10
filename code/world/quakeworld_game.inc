{ Lifecycle: construction, new game, respawn, episode gates, intermission and the per-frame Update.
  Part of the QuakeWorld unit (included from quakeworld.pas). }

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
  FWeaponTransform.Name := 'view_weapon';
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
  if FRecorder <> nil then
    FRecorder.WriteIntermission;
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
  FLockedTimer := Math.Max(0.0, FLockedTimer - SecondsPassed);

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
      if FRecorder <> nil then
        FRecorder.WriteKilledMonster;
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

  RecordFrame;

  { Update HUD }
  if Hud <> nil then
    Hud.Update(SecondsPassed, FPlayerStats);
  UpdateDebugOverlay;
end;
