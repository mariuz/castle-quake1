{ Savegames: player stats, world state, monsters, movers, projectiles and gibs in flight.
  Part of the QuakeWorld unit (included from quakeworld.pas). }

const
  SaveVersion = 1;

procedure SaveStats(const D: TQuakeSaveData; const P: String; const S: TQuakePlayerStats);
begin
  D.SetInt(P + 'health', S.Health);
  D.SetInt(P + 'armor', S.Armor);
  D.SetInt(P + 'armortype', S.ArmorType);
  D.SetInt(P + 'shells', S.Shells);
  D.SetInt(P + 'nails', S.Nails);
  D.SetInt(P + 'rockets', S.Rockets);
  D.SetInt(P + 'cells', S.Cells);
  D.SetInt(P + 'maxshells', S.MaxShells);
  D.SetInt(P + 'maxnails', S.MaxNails);
  D.SetInt(P + 'maxrockets', S.MaxRockets);
  D.SetInt(P + 'maxcells', S.MaxCells);
  D.SetInt(P + 'weapons', S.WeaponMask);
  D.SetInt(P + 'weapon', S.CurrentWeapon);
  D.SetInt(P + 'keys', S.Keys);
  D.SetInt(P + 'kills', S.Kills);
  D.SetInt(P + 'totalkills', S.TotalKills);
  D.SetInt(P + 'secrets', S.Secrets);
  D.SetInt(P + 'totalsecrets', S.TotalSecrets);
  D.SetFloat(P + 'leveltime', S.LevelTime);
  D.SetFloat(P + 'biosuit', S.BiosuitTime);
end;

function LoadStats(const D: TQuakeSaveData; const P: String): TQuakePlayerStats;
begin
  Result := Default(TQuakePlayerStats);
  Result.Health := D.GetInt(P + 'health', 100);
  Result.Armor := D.GetInt(P + 'armor');
  Result.ArmorType := D.GetInt(P + 'armortype');
  Result.Shells := D.GetInt(P + 'shells');
  Result.Nails := D.GetInt(P + 'nails');
  Result.Rockets := D.GetInt(P + 'rockets');
  Result.Cells := D.GetInt(P + 'cells');
  Result.MaxShells := D.GetInt(P + 'maxshells', 100);
  Result.MaxNails := D.GetInt(P + 'maxnails', 200);
  Result.MaxRockets := D.GetInt(P + 'maxrockets', 100);
  Result.MaxCells := D.GetInt(P + 'maxcells', 100);
  Result.WeaponMask := D.GetInt(P + 'weapons', 6);
  Result.CurrentWeapon := D.GetInt(P + 'weapon', 2);
  Result.Keys := D.GetInt(P + 'keys');
  Result.Kills := D.GetInt(P + 'kills');
  Result.TotalKills := D.GetInt(P + 'totalkills');
  Result.Secrets := D.GetInt(P + 'secrets');
  Result.TotalSecrets := D.GetInt(P + 'totalsecrets');
  Result.LevelTime := D.GetFloat(P + 'leveltime');
  Result.BiosuitTime := D.GetFloat(P + 'biosuit');
  Result.AirLeft := 12;
end;

function TQuakeWorld.MapName: String;
begin
  if FBsp <> nil then
    Result := FBsp.MapName
  else
    Result := '';
end;

function TQuakeWorld.CanSave: Boolean;
begin
  Result := (FBsp <> nil) and (FGeometry <> nil) and not FPlayerDead and
    not FIntermission and not FLevelExited;
end;

function TQuakeWorld.SaveGame(const Url: String; const ViewDir: TVector3): Boolean;
var
  D: TQuakeSaveData;
  I, J: Integer;
  Sub: TQuakeSubmodel;
  M: TQuakeMonster;
  P: String;
begin
  Result := False;
  if not CanSave then
    Exit;
  D := TQuakeSaveData.Create;
  try
    D.SetInt('version', SaveVersion);
    D.SetStr('map', FBsp.MapName);
    D.SetBool('originalmaps', Pak.PreferOriginalMaps);
    D.SetInt('skill', FSkill);
    D.SetInt('serverflags', FServerFlags);
    D.SetFloat('time', FTime);
    D.SetBool('godmode', FGodMode);
    SaveStats(D, 'stats.', FPlayerStats);
    D.SetBool('levelstart.valid', FLevelStartValid);
    D.SetInt('levelstart.serverflags', FLevelStartServerFlags);
    SaveStats(D, 'levelstart.', FLevelStartStats);

    D.SetVec('player.origin', FPhys.Origin);
    D.SetVec('player.velocity', FPhys.Velocity);
    D.SetVec('player.view', ViewDir);
    D.SetFloat('player.air', FAirFinished - FTime);
    D.SetFloat('lightningend', FLightningEnd - FTime);

    D.SetInt('submodels', FGeometry.Submodels.Count);
    for I := 0 to FGeometry.Submodels.Count - 1 do
    begin
      Sub := FGeometry.Submodels[I];
      P := 'sub.' + IntToStr(I) + '.';
      D.SetVec(P + 'pos', Sub.Transform.Translation);
      D.SetVec(P + 'target', Sub.TargetPos);
      D.SetInt(P + 'state', Ord(Sub.State));
      D.SetFloat(P + 'timer', Sub.StateTimer);
    end;

    D.SetInt('pickups', FPickups.Count);
    for I := 0 to FPickups.Count - 1 do
      D.SetBool('pickup.' + IntToStr(I) + '.taken', FPickups[I].Collected);

    D.SetInt('monsters', FMonsters.Count);
    for I := 0 to FMonsters.Count - 1 do
    begin
      M := FMonsters[I];
      P := 'monster.' + IntToStr(I) + '.';
      D.SetVec(P + 'origin', M.Origin);
      D.SetFloat(P + 'yaw', M.Yaw);
      D.SetInt(P + 'health', M.Health);
      D.SetInt(P + 'state', Ord(M.State));
      D.SetBool(P + 'alerted', M.SightAlerted);
      D.SetBool(P + 'counted', M.KillCounted);
      D.SetBool(P + 'gone', not M.Transform.Exists);
      J := -1;
      if M.Enemy <> nil then
        J := FMonsters.IndexOf(M.Enemy);
      D.SetInt(P + 'enemy', J);
    end;

    D.SetInt('triggers', FTriggers.Count);
    for I := 0 to FTriggers.Count - 1 do
    begin
      P := 'trigger.' + IntToStr(I) + '.';
      D.SetBool(P + 'removed', FTriggers[I].Removed);
      D.SetFloat(P + 'last', FTriggers[I].LastTriggerTime - FTime);
    end;

    { Projectiles and gibs in flight }
    D.SetInt('projectiles', FProjectiles.Count);
    for I := 0 to FProjectiles.Count - 1 do
    begin
      P := 'projectile.' + IntToStr(I) + '.';
      D.SetInt(P + 'kind', Ord(FProjectiles[I].Kind));
      D.SetVec(P + 'origin', FProjectiles[I].Origin);
      D.SetVec(P + 'velocity', FProjectiles[I].Velocity);
      D.SetFloat(P + 'life', FProjectiles[I].Life);
      D.SetBool(P + 'onground', FProjectiles[I].OnGround);
      D.SetFloat(P + 'spin', FProjectiles[I].Spin);
      D.SetFloat(P + 'home', FProjectiles[I].HomeTimer);
      J := -1;
      if FProjectiles[I].Owner is TQuakeMonster then
        J := FMonsters.IndexOf(TQuakeMonster(FProjectiles[I].Owner));
      D.SetInt(P + 'owner', J);
    end;
    D.SetInt('gibs', FGibs.Count);
    for I := 0 to FGibs.Count - 1 do
    begin
      P := 'gib.' + IntToStr(I) + '.';
      D.SetStr(P + 'model', FGibs[I].ModelPath);
      D.SetVec(P + 'origin', FGibs[I].Origin);
      D.SetVec(P + 'velocity', FGibs[I].Velocity);
      D.SetVec(P + 'avelocity', FGibs[I].AngularVelocity);
      D.SetVec(P + 'angles', FGibs[I].Angles);
      D.SetFloat(P + 'life', FGibs[I].Life);
      D.SetBool(P + 'onground', FGibs[I].OnGround);
    end;

    Result := D.SaveToUrl(Url);
    if Result then
      WritelnLog('QuakeWorld', 'Saved game to "%s"', [Url]);
  finally
    D.Free;
  end;
end;

function TQuakeWorld.LoadGame(const Url: String; out ViewDir: TVector3): Boolean;
var
  D: TQuakeSaveData;
  I, Enemy, Kind: Integer;
  Sub: TQuakeSubmodel;
  M: TQuakeMonster;
  P: String;
  Gone: Boolean;
  Proj: TQuakeProjectile;
  Gib: TQuakeGib;
begin
  Result := False;
  ViewDir := Vector3(0, 0, -1);
  D := TQuakeSaveData.Create;
  try
    if not D.LoadFromUrl(Url) then
      Exit;
    if D.GetInt('version') <> SaveVersion then
    begin
      WritelnWarning('QuakeWorld', 'Savegame "%s" has an unknown version', [Url]);
      Exit;
    end;

    { The map is spawned again with the saved skill, so its entities line
      up with the saved ones }
    Pak.PreferOriginalMaps := D.GetBool('originalmaps');
    FSkill := D.GetInt('skill', 1);
    FServerFlags := D.GetInt('serverflags');
    FPlayerDead := False;
    if not LoadMap(D.GetStr('map')) then
      Exit;

    FTime := D.GetFloat('time');
    FGodMode := D.GetBool('godmode');
    FPlayerStats := LoadStats(D, 'stats.');
    FLevelStartValid := D.GetBool('levelstart.valid');
    FLevelStartServerFlags := D.GetInt('levelstart.serverflags');
    FLevelStartStats := LoadStats(D, 'levelstart.');

    FPhys.Teleport(D.GetVec('player.origin', FSpawnOrigin));
    FPhys.Velocity := D.GetVec('player.velocity', TVector3.Zero);
    ViewDir := D.GetVec('player.view', ViewDir);
    FAirFinished := FTime + D.GetFloat('player.air', 12);
    FLightningEnd := FTime + D.GetFloat('lightningend', -100);

    if D.GetInt('submodels') = FGeometry.Submodels.Count then
      for I := 0 to FGeometry.Submodels.Count - 1 do
      begin
        Sub := FGeometry.Submodels[I];
        P := 'sub.' + IntToStr(I) + '.';
        Sub.Transform.Translation := D.GetVec(P + 'pos', Sub.Transform.Translation);
        Sub.TargetPos := D.GetVec(P + 'target', Sub.TargetPos);
        case D.GetInt(P + 'state', Ord(Sub.State)) of
          0: Sub.State := smsClosed;
          1: Sub.State := smsOpening;
          2: Sub.State := smsOpen;
          else Sub.State := smsClosing;
        end;
        Sub.StateTimer := D.GetFloat(P + 'timer');
        FLastSubOffsets[I] := CgeToQuake(Sub.Transform.Translation);
      end
    else
      WritelnWarning('QuakeWorld', 'Savegame doors do not match the map, not restored');

    if D.GetInt('pickups') = FPickups.Count then
      for I := 0 to FPickups.Count - 1 do
      begin
        FPickups[I].Collected := D.GetBool('pickup.' + IntToStr(I) + '.taken');
        FPickups[I].Transform.Visible := not FPickups[I].Collected;
      end
    else
      WritelnWarning('QuakeWorld', 'Savegame items do not match the map, not restored');

    if D.GetInt('monsters') = FMonsters.Count then
    begin
      for I := 0 to FMonsters.Count - 1 do
      begin
        M := FMonsters[I];
        P := 'monster.' + IntToStr(I) + '.';
        M.Origin := D.GetVec(P + 'origin', M.Origin);
        M.SightAlerted := D.GetBool(P + 'alerted');
        M.KillCounted := D.GetBool(P + 'counted', M.KillCounted);
        M.RestoreState(TMonsterState(EnsureRange(D.GetInt(P + 'state'), 0, Ord(High(TMonsterState)))),
          D.GetInt(P + 'health', M.Health), D.GetFloat(P + 'yaw', M.Yaw));
        Gone := D.GetBool(P + 'gone');
        if Gone then
          M.Transform.Exists := False;
      end;
      for I := 0 to FMonsters.Count - 1 do
      begin
        Enemy := D.GetInt('monster.' + IntToStr(I) + '.enemy', -1);
        if (Enemy >= 0) and (Enemy < FMonsters.Count) then
          FMonsters[I].Enemy := FMonsters[Enemy];
      end;
    end else
      WritelnWarning('QuakeWorld', 'Savegame monsters do not match the map, not restored');

    if D.GetInt('triggers') = FTriggers.Count then
      for I := 0 to FTriggers.Count - 1 do
      begin
        P := 'trigger.' + IntToStr(I) + '.';
        FTriggers[I].Removed := D.GetBool(P + 'removed');
        FTriggers[I].LastTriggerTime := FTime + D.GetFloat(P + 'last', -999);
      end;

    { Projectiles and gibs in flight }
    for I := 0 to D.GetInt('projectiles') - 1 do
    begin
      P := 'projectile.' + IntToStr(I) + '.';
      Kind := D.GetInt(P + 'kind', -1);
      if (Kind < 0) or (Kind > Ord(High(TQuakeProjectileKind))) then
        Continue;
      Proj := TQuakeProjectile.Create(FRootTransform, TQuakeProjectileKind(Kind), D.GetVec(P + 'origin', TVector3.Zero),
        D.GetVec(P + 'velocity', TVector3.Zero));
      Proj.Life := D.GetFloat(P + 'life', Proj.Life);
      Proj.OnGround := D.GetBool(P + 'onground');
      Proj.Spin := D.GetFloat(P + 'spin');
      Proj.HomeTimer := D.GetFloat(P + 'home');
      Enemy := D.GetInt(P + 'owner', -1);
      if (Enemy >= 0) and (Enemy < FMonsters.Count) then
        Proj.Owner := FMonsters[Enemy];
      Proj.UpdateVisual;
      FProjectiles.Add(Proj);
    end;
    for I := 0 to D.GetInt('gibs') - 1 do
    begin
      P := 'gib.' + IntToStr(I) + '.';
      if D.GetStr(P + 'model') = '' then
        Continue;
      Gib := TQuakeGib.Create(FRootTransform, D.GetStr(P + 'model'), D.GetVec(P + 'origin', TVector3.Zero),
        D.GetVec(P + 'velocity', TVector3.Zero), D.GetFloat(P + 'life'));
      Gib.AngularVelocity := D.GetVec(P + 'avelocity', TVector3.Zero);
      Gib.Angles := D.GetVec(P + 'angles', TVector3.Zero);
      Gib.OnGround := D.GetBool(P + 'onground');
      Gib.UpdateVisual;
      FGibs.Add(Gib);
    end;

    ApplyEpisodeGates;
    UpdateSolids;
    UpdateWeaponModel;
    WritelnLog('QuakeWorld', 'Loaded game from "%s"', [Url]);
    Result := True;
  finally
    D.Free;
  end;
end;
