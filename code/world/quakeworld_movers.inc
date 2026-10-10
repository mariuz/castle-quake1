{ Movers and triggers: submodel solidity and bounds, targets, buttons, doors (and key doors), lifts, trigger volumes.
  Part of the QuakeWorld unit (included from quakeworld.pas). }

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

function TQuakeWorld.WorldType: Integer;
var
  World: TQuakeEntity;
begin
  { 0 medieval, 1 metal (runes), 2 base }
  Result := 0;
  if FBsp = nil then
    Exit;
  World := FBsp.FindEntity('worldspawn');
  if World <> nil then
    Result := World.GetInt('worldtype', 0);
end;

function TQuakeWorld.TouchKeyDoor(const Sub: TQuakeSubmodel): Boolean;
const
  TrySounds: array[0..2] of String = ('sound/doors/medtry.wav', 'sound/doors/runetry.wav', 'sound/doors/basetry.wav');
  UseSounds: array[0..2] of String = ('sound/doors/meduse.wav', 'sound/doors/runeuse.wav', 'sound/doors/baseuse.wav');
  KeyNames: array[0..2, 1..2] of String = (('silver key', 'gold key'), ('silver runekey', 'gold runekey'),
    ('silver keycard', 'gold keycard'));
var
  WT: Integer;
begin
  Result := False;
  if (Sub.KeyNeeded = 0) or (Sub.State <> smsClosed) then
    Exit;
  WT := EnsureRange(WorldType, 0, 2);
  if (FPlayerStats.Keys and Sub.KeyNeeded) = 0 then
  begin
    { door_touch: the message and noise3, at most every 2 seconds }
    if FLockedTimer <= 0 then
    begin
      FLockedTimer := 2;
      if FHud <> nil then
        FHud.ShowMessage('You need the ' + KeyNames[WT, Sub.KeyNeeded], 2.0);
      Sounds.PlayAt(TrySounds[WT], Sub.Transform);
      WritelnLog('QuakeWorld', 'Locked door: needs the %s', [KeyNames[WT, Sub.KeyNeeded]]);
    end;
    Exit;
  end;
  { The key is used up (other.items = other.items - self.items) }
  FPlayerStats.Keys := FPlayerStats.Keys and not Sub.KeyNeeded;
  Sounds.PlayAt(UseSounds[WT], Sub.Transform);
  Sub.Trigger;
  Sounds.PlayAt('sound/doors/dr1_strt.wav', Sub.Transform);
  UseTargets(Sub.Target);
  WritelnLog('QuakeWorld', 'Key door opened with the %s', [KeyNames[WT, Sub.KeyNeeded]]);
  Result := True;
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

    { door_touch of a key door: running into the door itself }
    if (Sub.EntityClassName = 'func_door') and (Sub.KeyNeeded <> 0) and WasTouched(Sub.ModelIndex) then
      TouchKeyDoor(Sub);

    { door_touch through the trigger field spawned around doors
      (60 units around the door horizontally, 8 vertically); key doors
      have no field }
    if (Sub.EntityClassName = 'func_door') and (Sub.TargetName = '') and (Sub.KeyNeeded = 0) and
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
        if FRecorder <> nil then
          FRecorder.WriteFoundSecret;
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
