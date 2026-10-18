{ Horde mode: waves of monsters on any map.

  HordeMode (set by the view before LoadMap) clears the map's monsters and
  turns its exits off; waves then teleport in at the map's monster and
  deathmatch spots, preferring the ones out of the player's PVS, each wave
  bigger and mixing in stronger monsters. A cleared wave scores a bonus,
  brings the items back and gives a short pause. Kills score the
  monster's base health. }

const
  HordeFirstPause = 3.0;
  HordeWavePause = 5.0;
  HordeMaxAlive = 10;
  HordeSpawnInterval = 0.4;

  HordeTier1: array[0..2] of String = ('monster_army', 'monster_army', 'monster_dog');
  HordeTier2: array[0..3] of String = ('monster_ogre', 'monster_knight', 'monster_wizard', 'monster_enforcer');
  HordeTier3: array[0..3] of String = ('monster_demon1', 'monster_hell_knight', 'monster_shalrath',
    'monster_ogre');

procedure TQuakeWorld.StartHorde;
var
  Ent: TQuakeEntity;
  CName: String;
  P: TVector3;
begin
  FMonsters.Clear;
  FPlayerStats.Kills := 0;
  FPlayerStats.TotalKills := 0;
  FHordeActive := True;
  FHordeWave := 0;
  FHordeScore := 0;
  FHordeToSpawn := 0;
  FHordeAlive := 0;
  FHordeFighting := False;
  FHordeTimer := HordeFirstPause;
  FHordeSpawnTimer := 0;
  FHordeMoves := 0;
  { The spots: where the map's monsters and deathmatch starts stand, and
    above its items }
  SetLength(FHordeSpots, 0);
  for Ent in FBsp.Entities do
  begin
    CName := LowerCase(Ent.ClassName);
    if (Pos('monster_', CName) = 1) and (CName <> 'monster_boss') and (CName <> 'monster_oldone') then
      P := Ent.Origin
    else if CName = 'info_player_deathmatch' then
      P := Ent.Origin
    else if (Pos('item_', CName) = 1) or (Pos('weapon_', CName) = 1) then
      P := Ent.Origin + Vector3(0, 0, 32)
    else
      Continue;
    SetLength(FHordeSpots, Length(FHordeSpots) + 1);
    FHordeSpots[High(FHordeSpots)] := P;
  end;
  WritelnLog('Horde', 'Horde on "%s": %d spawn spots', [MapName, Length(FHordeSpots)]);
end;

function TQuakeWorld.HordeClass: String;
var
  R: Integer;
begin
  R := Random(100);
  if (FHordeWave >= 5) and (R < 15 + 3 * FHordeWave) then
    Result := HordeTier3[Random(Length(HordeTier3))]
  else if (FHordeWave >= 2) and (R < 60) then
    Result := HordeTier2[Random(Length(HordeTier2))]
  else
    Result := HordeTier1[Random(Length(HordeTier1))];
end;

{ A spot where a monster of Def fits: out of sight (out of the player's PVS
  or behind the player) and not too far (one of the three nearest such spots at least 400 units away, so the
  wave finds the player soon), else the farthest visible one; False when
  none is free }
function TQuakeWorld.HordeSpot(const Def: TMonsterDef; const AllowVisible: Boolean; out Spot: TVector3): Boolean;
var
  Hull, PlayerLeaf, I, J, Best, HiddenCount: Integer;
  P: TVector3;
  D, BestD: Single;
  SpotFree: Boolean;
  M: TQuakeMonster;
  Hidden: array[0..2] of Integer;
  HiddenD: array[0..2] of Single;
begin
  Result := False;
  if Length(FHordeSpots) = 0 then
    Exit;
  Hull := FBsp.HullForSize(Def.Mins, Def.Maxs);
  PlayerLeaf := FBsp.PointLeaf(FPhys.Origin);
  Best := -1;
  BestD := -1;
  HiddenCount := 0;
  for I := 0 to High(FHordeSpots) do
  begin
    P := FHordeSpots[I];
    D := (P - FPhys.Origin).Length;
    if D < 160 then
      Continue;
    if FBsp.HullPointContents(Hull, FBsp.Models[0].HeadNodes[Hull], P) <> CONTENTS_EMPTY then
      Continue;
    SpotFree := True;
    for M in FMonsters do
      if M.IsSolid and ((M.Origin - P).Length < 80) then
      begin
        SpotFree := False;
        Break;
      end;
    if not SpotFree then
      Continue;
    { Out of sight: out of the PVS, or behind the player (where a monster
      can often walk straight in) }
    if (D >= 400) and (AllowVisible or ((PlayerLeaf > 0) and not FBsp.LeafVisible(PlayerLeaf, FBsp.PointLeaf(P))) or
       (TVector3.DotProduct(FViewForward, (P - FPhys.Origin) / D) < -0.3)) then
    begin
      { Keep the three nearest, sorted }
      J := HiddenCount;
      if J = Length(Hidden) then
      begin
        if D >= HiddenD[High(Hidden)] then
          Continue;
        J := High(Hidden);
      end else
        Inc(HiddenCount);
      while (J > 0) and (HiddenD[J - 1] > D) do
      begin
        Hidden[J] := Hidden[J - 1];
        HiddenD[J] := HiddenD[J - 1];
        Dec(J);
      end;
      Hidden[J] := I;
      HiddenD[J] := D;
      Continue;
    end;
    if D > BestD then
    begin
      BestD := D;
      Best := I;
    end;
  end;
  if HiddenCount > 0 then
    Best := Hidden[Random(HiddenCount)];
  if Best >= 0 then
  begin
    Spot := FHordeSpots[Best];
    Result := True;
  end;
end;

function TQuakeWorld.SpawnHordeMonster(const AClassName: String): Boolean;
var
  Def: TMonsterDef;
  Spot: TVector3;
  M: TQuakeMonster;
begin
  Result := False;
  if not MonsterDef(AClassName, Def) or (MdlManager.GetModel(Def.Model) = nil) then
    Exit;
  if not HordeSpot(Def, False, Spot) then
    Exit;
  M := TQuakeMonster.Create(FRootTransform, Def, Spot, Random(8) * 45);
  M.Nightmare := FSkill >= 3;
  FMonsters.Add(M);
  if Def.Move = mmWalk then
    MonsterDropToFloor(M);
  Inc(FPlayerStats.TotalKills);
  Particles.SpawnTeleport(QuakeToCge(Spot));
  Sounds.PlayAt('sound/misc/r_tele' + IntToStr(1 + Random(5)) + '.wav', M.Transform);
  { It knows where the player is }
  M.HordeBestDist := (Spot - FPhys.Origin).Length;
  M.Use;
  Result := True;
end;

procedure TQuakeWorld.UpdateHorde(const SecondsPassed: Single);
var
  M: TQuakeMonster;
  Count, Bonus, PlayerLeaf: Integer;
  D: Single;
  Spot: TVector3;
  P: TQuakePickup;
begin
  if not FHordeActive or FPlayerDead or FIntermission then
    Exit;
  FHordeAlive := 0;
  PlayerLeaf := FBsp.PointLeaf(FPhys.Origin);
  for M in FMonsters do
    if (M.Health > 0) and not (M.State in [msDeath, msDead]) then
    begin
      Inc(FHordeAlive);
      { A monster that gets no closer for a while, out of the player's
        sight, comes in again somewhere better (Quake's monsters do not find
        their way around walls) }
      D := (M.Origin - FPhys.Origin).Length;
      if D < M.HordeBestDist - 32 then
      begin
        M.HordeBestDist := D;
        M.HordeStuckTime := 0;
      end else
        M.HordeStuckTime := M.HordeStuckTime + SecondsPassed;
      if (M.HordeStuckTime > 8) and (D > 300) and
         ((PlayerLeaf <= 0) or not FBsp.LeafVisible(PlayerLeaf, FBsp.PointLeaf(M.Origin)) or
          not MonsterCanSeePlayer(M)) and HordeSpot(M.Def, True, Spot) then
      begin
        Particles.SpawnTeleport(QuakeToCge(M.Origin));
        M.Origin := Spot;
        if M.Def.Move = mmWalk then
          MonsterDropToFloor(M);
        Particles.SpawnTeleport(QuakeToCge(Spot));
        M.HordeBestDist := (M.Origin - FPhys.Origin).Length;
        M.HordeStuckTime := 0;
        Inc(FHordeMoves);
      end;
    end;

  if FHordeFighting and (Trunc(FTime / 10) <> Trunc((FTime - SecondsPassed) / 10)) then
  begin
    D := 1e9;
    for M in FMonsters do
      if (M.Health > 0) and not (M.State in [msDeath, msDead]) then
        D := Min(D, (M.Origin - FPhys.Origin).Length);
    WritelnLog('Horde', 'Wave %d: %d alive, %d to come, nearest %.0f units, %d moved in again',
      [FHordeWave, FHordeAlive, FHordeToSpawn, D, FHordeMoves]);
  end;

  if not FHordeFighting then
  begin
    FHordeTimer := FHordeTimer - SecondsPassed;
    if FHordeTimer > 0 then
      Exit;
    { The next wave }
    Inc(FHordeWave);
    FHordeToSpawn := Min(4 + 2 * FHordeWave, 40);
    FHordeFighting := True;
    FHordeSpawnTimer := 0;
    WritelnLog('Horde', 'Wave %d: %d monsters', [FHordeWave, FHordeToSpawn]);
    if FHud <> nil then
      FHud.ShowMessage(Format('WAVE %d', [FHordeWave]), 2.0);
    Sounds.Play('sound/misc/talk.wav');
    Exit;
  end;

  { Teleport the wave in, a few at a time }
  FHordeSpawnTimer := FHordeSpawnTimer - SecondsPassed;
  if (FHordeToSpawn > 0) and (FHordeAlive < HordeMaxAlive) and (FHordeSpawnTimer <= 0) then
  begin
    FHordeSpawnTimer := HordeSpawnInterval;
    { A shambler closes every fifth wave }
    if (FHordeWave mod 5 = 0) and (FHordeToSpawn = 1) then
      Count := Ord(SpawnHordeMonster('monster_shambler'))
    else
      Count := Ord(SpawnHordeMonster(HordeClass));
    if Count > 0 then
    begin
      Dec(FHordeToSpawn);
      Inc(FHordeAlive);
    end;
  end;

  if (FHordeToSpawn = 0) and (FHordeAlive = 0) then
  begin
    Bonus := 100 * FHordeWave;
    Inc(FHordeScore, Bonus);
    WritelnLog('Horde', 'Wave %d cleared: score %d (%d monsters moved in again)', [FHordeWave, FHordeScore, FHordeMoves]);
    FHordeMoves := 0;
    if FHud <> nil then
      FHud.ShowMessage(Format('Wave %d cleared!' + LineEnding + 'Bonus %d', [FHordeWave, Bonus]), 3.0);
    { The items come back }
    for P in FPickups do
      P.Collected := False;
    { The dead go away (they would fill the list over many waves), but
      not one that still owns a missile in flight }
    for Count := FMonsters.Count - 1 downto 0 do
      if (FMonsters[Count].State = msDead) and not OwnsProjectile(FMonsters[Count]) then
        FMonsters.Delete(Count);
    FHordeFighting := False;
    FHordeTimer := HordeWavePause;
  end;
end;

function TQuakeWorld.OwnsProjectile(const M: TQuakeMonster): Boolean;
var
  I: Integer;
begin
  for I := 0 to FProjectiles.Count - 1 do
    if FProjectiles[I].Owner = TObject(M) then
      Exit(True);
  Result := False;
end;

procedure TQuakeWorld.HordeKill(const M: TQuakeMonster);
begin
  if FHordeActive then
    Inc(FHordeScore, Max(10, M.Def.Health));
end;

function TQuakeWorld.HordeText: String;
begin
  if not FHordeActive then
    Exit('');
  if FHordeFighting then
    Result := Format('WAVE %d   LEFT %d   SCORE %d', [FHordeWave, FHordeToSpawn + FHordeAlive, FHordeScore])
  else
    Result := Format('WAVE %d   NEXT IN %d   SCORE %d', [FHordeWave, Ceil(Max(0, FHordeTimer)), FHordeScore]);
end;

procedure TQuakeWorld.KillAllMonsters;
var
  M: TQuakeMonster;
begin
  for M in FMonsters do
    if (M.Health > 0) and not (M.State in [msDeath, msDead, msHidden]) and not M.Crucified then
      M.TakeDamage(Max(M.Health, 100));
end;
