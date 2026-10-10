{ Map loading: entity spawning and LoadMap.
  Part of the QuakeWorld unit (included from quakeworld.pas). }

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

    if CName = 'misc_teleporttrain' then
      SpawnTeleportTrain(Ent)
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
  World: TQuakeEntity;
begin
  Result := False;
  FLevelExited := False;
  ResetComponentNames;
  if FTriggerRoot <> nil then
  begin
    if FTriggerRoot.Parent <> nil then
      FTriggerRoot.Parent.Remove(FTriggerRoot);
    FreeAndNil(FTriggerRoot);
  end;
  FNextMap := '';
  FPlayerStats.LevelTime := 0;
  FPlayerStats.Kills := 0;
  FPlayerStats.TotalKills := 0;
  FPlayerStats.Secrets := 0;
  FPlayerStats.TotalSecrets := 0;
  FIntermission := False;
  FIntermissionStage := 0;
  FFinaleStage := 0;
  FFinaleBoss := nil;
  FGameOver := False;
  if FTrain <> nil then
  begin
    if FTrain.Parent <> nil then
      FTrain.Parent.Remove(FTrain);
    FreeAndNil(FTrain);
  end;
  SetLength(FTrainCorners, 0);
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

  { The map's CD track (worldspawn "sounds") }
  World := FBsp.FindEntity('worldspawn');
  if (World <> nil) and (World.Sounds > 0) then
    Sounds.PlayTrack(World.Sounds)
  else
    Sounds.PlayMusic('track02.ogg');

  { A recording continues on the new level }
  RecordLevelStart;

  { Saved for the restart after death }
  FLevelStartStats := FPlayerStats;
  FLevelStartServerFlags := FServerFlags;
  FLevelStartValid := True;

  WritelnLog('QuakeWorld', 'Successfully initialized map "%s" (skill %d, runes %d)', [MapPath, FSkill, FServerFlags]);
  { The entities as behaviors for the engine's inspector }
  for I := 0 to FMonsters.Count - 1 do
    AttachMonsterBehavior(FMonsters[I]);
  for I := 0 to FPickups.Count - 1 do
    AttachPickupBehavior(FPickups[I]);
  for I := 0 to FGeometry.Submodels.Count - 1 do
    AttachSubmodelBehavior(FGeometry.Submodels[I]);
  FTriggerRoot := TCastleTransform.Create(nil);
  FTriggerRoot.Name := 'triggers';
  FRootTransform.Add(FTriggerRoot);
  for I := 0 to FTriggers.Count - 1 do
    CreateTriggerTransform(FTriggers[I], FTriggerRoot);
  Result := True;
end;
