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

procedure TQuakeWorld.BeginIntermissionView;
var
  Spots: TQuakeEntityList;
  Ent: TQuakeEntity;
  Angles, Dir: TVector3;
begin
  { Freeze the player and look from a random info_intermission spot
    (mangle = pitch yaw roll) }
  FIntermission := True;
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
end;

procedure TQuakeWorld.StartIntermission(const NextMap: String);
var
  World: TQuakeEntity;
  Title: String;
begin
  { execute_changelevel }
  BeginIntermissionView;
  FIntermissionStage := 1;
  FIntermissionExitTime := FTime + 5;
  if FRecorder <> nil then
    FRecorder.WriteIntermission;
  FIntermissionMap := NextMap;

  Title := '';
  World := FBsp.FindEntity('worldspawn');
  if World <> nil then
    Title := World.MessageText;
  if FHud <> nil then
    FHud.StartIntermission(Title, FPlayerStats.LevelTime, FPlayerStats.Kills,
      FPlayerStats.TotalKills, FPlayerStats.Secrets, FPlayerStats.TotalSecrets);
  Sounds.PlayMusic('track03.ogg');
end;

function TQuakeWorld.EpisodeText: String;
var
  Registered: Boolean;
begin
  { ExitIntermission (client.qc): the text after the last map of an episode;
    the shareware version of the first one when the other episodes are
    not there (cvar registered) }
  Result := '';
  Registered := Pak.FileExists('maps/e2m1.bsp');
  if SameText(FBsp.MapName, 'e1m7') then
  begin
    if Registered then
      Result := 'As the corpse of the monstrous entity'#10'Chthon sinks back into the lava whence'#10 +
        'it rose, you grip the Rune of Earth'#10'Magic tightly. Now that you have'#10 +
        'conquered the Dimension of the Doomed,'#10'realm of Earth Magic, you are ready to'#10 +
        'complete your task. A Rune of magic'#10'power lies at the end of each haunted'#10 +
        'land of Quake. Go forth, seek the'#10'totality of the four Runes!'
    else
      Result := 'As the corpse of the monstrous entity'#10'Chthon sinks back into the lava whence'#10 +
        'it rose, you grip the Rune of Earth'#10'Magic tightly. Now that you have'#10 +
        'conquered the Dimension of the Doomed,'#10'realm of Earth Magic, you are ready to'#10 +
        'complete your task in the other three'#10'haunted lands of Quake. Or are you? If'#10 +
        'you don''t register Quake, you''ll never'#10'know what awaits you in the Realm of'#10 +
        'Black Magic, the Netherworld, and the'#10'Elder World!';
  end else
  if SameText(FBsp.MapName, 'e2m6') then
    Result := 'The Rune of Black Magic throbs evilly in'#10'your hand and whispers dark thoughts'#10 +
      'into your brain. You learn the inmost'#10'lore of the Hell-Mother; Shub-Niggurath!'#10 +
      'You now know that she is behind all the'#10'terrible plotting which has led to so'#10 +
      'much death and horror. But she is not'#10'inviolate! Armed with this Rune, you'#10 +
      'realize that once all four Runes are'#10'combined, the gate to Shub-Niggurath''s'#10 +
      'Pit will open, and you can face the'#10'Witch-Goddess herself in her frightful'#10 +
      'otherworld cathedral.'
  else
  if SameText(FBsp.MapName, 'e3m7') then
    Result := 'The charred viscera of diabolic horrors'#10'bubble viscously as you seize the Rune'#10 +
      'of Hell Magic. Its heat scorches your'#10'hand, and its terrible secrets blight'#10 +
      'your mind. Gathering the shreds of your'#10'courage, you shake the devil''s shackles'#10 +
      'from your soul, and become ever more'#10'hard and determined to destroy the'#10 +
      'hideous creatures whose mere existence'#10'threatens the souls and psyches of all'#10 +
      'the population of Earth.'
  else
  if SameText(FBsp.MapName, 'e4m7') then
    Result := 'Despite the awful might of the Elder'#10'World, you have achieved the Rune of'#10 +
      'Elder Magic, capstone of all types of'#10'arcane wisdom. Beyond good and evil,'#10 +
      'beyond life and death, the Rune'#10'pulsates, heavy with import. Patient and'#10 +
      'potent, the Elder Being Shub-Niggurath'#10'weaves her dire plans to clear off all'#10 +
      'life from the Earth, and bring her own'#10'foul offspring to our world! For all the'#10 +
      'dwellers in these nightmare dimensions'#10'are her descendants! Once all Runes of'#10 +
      'magic power are united, the energy'#10'behind them will blast open the Gateway'#10 +
      'to Shub-Niggurath, and you can travel'#10'there to foil the Hell-Mother''s plots'#10 +
      'in person.';
end;

procedure TQuakeWorld.IntermissionContinue;
const
  AllRunesText = 'Now, you have all four Runes. You sense'#10'tremendous invisible forces moving to'#10 +
    'unseal ancient barriers. Shub-Niggurath'#10'had hoped to use the Runes Herself to'#10 +
    'clear off the Earth, but now instead,'#10'you will use them to enter her home and'#10 +
    'confront her as an avatar of avenging'#10'Earth-life. If you defeat her, you will'#10 +
    'be remembered forever as the savior of'#10'the planet. If she conquers, it will be'#10 +
    'as if you had never been born.';
var
  Text: String;
begin
  if not FIntermission or FLevelExited or FGameOver or (FTime < FIntermissionExitTime) then
    Exit;
  { The ending: dismissed once its text is complete }
  if FFinaleStage > 0 then
  begin
    if FFinaleStage >= 4 then
      FGameOver := True;
    Exit;
  end;
  { ExitIntermission: a button press after the tallies shows the episode
    text, another the all-four-runes text, the next one loads the map }
  Inc(FIntermissionStage);
  FIntermissionExitTime := FTime + 1;
  if FIntermissionStage = 2 then
  begin
    Text := EpisodeText;
    if Text <> '' then
    begin
      if FHud <> nil then
        FHud.StartFinale(Text);
      Exit;
    end;
    Inc(FIntermissionStage);
  end;
  if (FIntermissionStage = 3) and ((FServerFlags and 15) = 15) and not IsStartMap then
  begin
    if FHud <> nil then
      FHud.StartFinale(AllRunesText);
    Exit;
  end;
  FLevelExited := True;
  FNextMap := FIntermissionMap;
end;

procedure TQuakeWorld.StartShubFinale(const Boss: TQuakeMonster);
begin
  { finale_1 (oldone.qc): the player is telefragging Shub-Niggurath; watch
    from the intermission spot, the rest follows two seconds apart }
  if FFinaleStage > 0 then
    Exit;
  FFinaleBoss := Boss;
  FFinaleStage := 1;
  FFinaleTime := FTime + 2;
  BeginIntermissionView;
  FIntermissionStage := 0;
  FIntermissionMap := '';
  FIntermissionExitTime := FTime + 1e9;
  if FHud <> nil then
    FHud.StartFinale('');
  Sounds.PlayMusic('track03.ogg');
  WritelnLog('QuakeWorld', 'The ending starts: Shub-Niggurath telefragged');
end;

procedure TQuakeWorld.UpdateFinale;
const
  EndText = 'Congratulations and well done! You have'#10'beaten the hideous Shub-Niggurath, and'#10 +
    'her hundreds of ugly changelings and'#10'monsters. You have proven that your'#10 +
    'skill and your cunning are greater than'#10'all the powers of Quake. You are the'#10 +
    'master now. Id Software salutes you.';
  GibModels: array[0..2] of String = ('progs/gib1.mdl', 'progs/gib2.mdl', 'progs/gib3.mdl');
var
  Org: TVector3;
  I: Integer;
  Gib: TQuakeGib;
begin
  if (FFinaleStage <= 0) or (FFinaleStage >= 4) or (FTime < FFinaleTime) then
    Exit;
  Org := FFinaleBoss.Origin;
  Inc(FFinaleStage);
  FFinaleTime := FTime + 2;
  case FFinaleStage of
    2:
      begin
        { finale_2: a teleport splash inside Shub }
        Particles.SpawnTeleport(QuakeToCge(Org - Vector3(0, 100, 0)));
        Sounds.PlayAt('sound/misc/r_tele1.wav', FFinaleBoss.Transform);
      end;
    3:
      begin
        { finale_3: her death cry, the lights flicker }
        Sounds.PlayAt('sound/boss2/death.wav', FFinaleBoss.Transform);
        Lighting.SetStyle(0, 'abcdefghijklmlkjihgfedcb');
      end;
    4:
      begin
        { finale_4: she pops into meat, the ending text }
        Sounds.PlayAt('sound/boss2/pop2.wav', FFinaleBoss.Transform);
        for I := 1 to 40 do
        begin
          Gib := TQuakeGib.Create(FRootTransform, GibModels[Random(3)], Org,
            Vector3(400 * (Random * 2 - 1), 400 * (Random * 2 - 1), 200 + 300 * Random), 20);
          Gib.AngularVelocity := Vector3(Random * 600, Random * 600, Random * 600);
          FGibs.Add(Gib);
        end;
        FFinaleBoss.Transform.Exists := False;
        Lighting.SetStyle(0, 'm');
        if FHud <> nil then
          FHud.StartFinale(EndText);
        FIntermissionExitTime := FTime + 2;
      end;
  end;
end;

procedure TQuakeWorld.SpawnTeleportTrain(const Ent: TQuakeEntity);
var
  Mdl: TQuakeMdl;
  Scene: TCastleScene;
  Corner, E: TQuakeEntity;
  Name: String;
  Guard: Integer;
begin
  { misc_teleporttrain: progs/teleport.mdl spinning along its path_corners
    (func_train without a brush), speed 100 }
  FreeAndNil(FTrain);
  FTrainName := Ent.TargetName;
  FTrainSpeed := Ent.GetFloat('speed', 100);
  FTrainOrigin := Ent.Origin;
  SetLength(FTrainCorners, 0);
  SetLength(FTrainWaits, 0);
  Name := Ent.Target;
  Guard := 0;
  while (Name <> '') and (Guard < 64) do
  begin
    Inc(Guard);
    Corner := nil;
    for E in FBsp.Entities do
      if (LowerCase(E.ClassName) = 'path_corner') and (E.TargetName = Name) then
      begin
        Corner := E;
        Break;
      end;
    if Corner = nil then
      Break;
    if (Length(FTrainCorners) > 0) and TVector3.PerfectlyEquals(FTrainCorners[0], Corner.Origin) then
      Break; { the loop closed }
    SetLength(FTrainCorners, Length(FTrainCorners) + 1);
    SetLength(FTrainWaits, Length(FTrainCorners));
    FTrainCorners[High(FTrainCorners)] := Corner.Origin;
    FTrainWaits[High(FTrainWaits)] := Corner.GetFloat('wait', 0);
    Name := Corner.Target;
  end;
  if Length(FTrainCorners) > 0 then
    FTrainOrigin := FTrainCorners[0];
  FTrainNext := 1;
  FTrainWait := 0;
  FTrain := TCastleTransform.Create(nil);
  FTrain.Name := ComponentName('misc_teleporttrain');
  Mdl := MdlManager.GetModel('progs/teleport.mdl');
  if Mdl <> nil then
  begin
    Scene := Mdl.CreateScene(0);
    Scene.Collides := False;
    FTrain.Add(Scene);
  end;
  FTrain.Translation := QuakeToCge(FTrainOrigin);
  FRootTransform.Add(FTrain);
end;

procedure TQuakeWorld.UpdateTeleportTrain(const SecondsPassed: Single);
var
  Target, Delta: TVector3;
  Dist, Step: Single;
begin
  if FTrain = nil then
    Exit;
  { avelocity '100 200 300' }
  FTrainAngles := FTrainAngles + Vector3(100, 200, 300) * SecondsPassed;
  FTrain.Rotation := (QuatFromAxisAngle(Vector3(0, 1, 0), DegToRad(FTrainAngles.Y)) *
    QuatFromAxisAngle(Vector3(0, 0, 1), DegToRad(FTrainAngles.X)) *
    QuatFromAxisAngle(Vector3(1, 0, 0), DegToRad(FTrainAngles.Z))).ToAxisAngle;
  if Length(FTrainCorners) < 2 then
    Exit;
  if FTrainWait > 0 then
  begin
    FTrainWait := FTrainWait - SecondsPassed;
    Exit;
  end;
  Target := FTrainCorners[FTrainNext];
  Delta := Target - FTrainOrigin;
  Dist := Delta.Length;
  Step := FTrainSpeed * SecondsPassed;
  if Dist <= Step then
  begin
    { train_wait at the corner, then the next one }
    FTrainOrigin := Target;
    FTrainWait := Max(FTrainWaits[FTrainNext], 0.1);
    FTrainNext := (FTrainNext + 1) mod Length(FTrainCorners);
  end else
    FTrainOrigin := FTrainOrigin + Delta * (Step / Dist);
  FTrain.Translation := QuakeToCge(FTrainOrigin);
end;

procedure TQuakeWorld.Telefrag(const Dest: TVector3);
var
  M: TQuakeMonster;
  PMins, PMaxs, Mins, Maxs: TVector3;
  I: Integer;
begin
  PMins := Dest + Vector3(-16, -16, -24);
  PMaxs := Dest + Vector3(16, 16, 32);
  for I := 0 to FMonsters.Count - 1 do
  begin
    M := FMonsters[I];
    if not MonsterBounds(M, Mins, Maxs) then
      Continue;
    if (PMins.X > Maxs.X) or (PMaxs.X < Mins.X) or (PMins.Y > Maxs.Y) or (PMaxs.Y < Mins.Y) or
       (PMins.Z > Maxs.Z) or (PMaxs.Z < Mins.Z) then
      Continue;
    if M.EntityClassName = 'monster_oldone' then
      StartShubFinale(M)
    else
      DamageMonster(M, 50000, Dest, nil);
  end;
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
  UpdateTeleportTrain(SecondsPassed);
  UpdateFinale;
  if FIntermission and (Hud <> nil) then
    Hud.IntermissionReady := FTime >= FIntermissionExitTime;

  { Advance monsters }
  for I := 0 to FMonsters.Count - 1 do
  begin
    M := FMonsters[I];
    M.Update(SecondsPassed, FMonsterEnv);
    if M.GibPending then
      GibMonster(M);
    if M.LavaSplashPending then
    begin
      M.LavaSplashPending := False;
      Particles.SpawnLavaSplash(QuakeToCge(M.Origin));
    end;
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
