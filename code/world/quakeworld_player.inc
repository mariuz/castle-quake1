{ Player: water rules, movement, eye position, damage, use, cheats.
  Part of the QuakeWorld unit (included from quakeworld.pas). }

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
  if FRecorder <> nil then
    FRecorder.WriteDamage(0, Damage, FPhys.Origin);

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
  StopRecording;
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
  FreeAndNil(FTriggerRoot);
  FreeAndNil(FDebug);
  FTriggers.Free;
  FreeAndNil(FAmbient);
  FreeAndNil(FPhys);
  FreeAndNil(FGeometry);
  FreeAndNil(FBsp);
  inherited Destroy;
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
      else if Sub.KeyNeeded <> 0 then
        TouchKeyDoor(Sub)
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
