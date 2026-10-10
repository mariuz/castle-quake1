{ Demo recording: the .dem writer fed from the simulation (level start, sounds, effects, messages, frames).
  Part of the QuakeWorld unit (included from quakeworld.pas). }

function TQuakeWorld.ViewAnglesQuake: TVector3;
begin
  { Quake angles: pitch > 0 looks down, yaw 0 along +X }
  Result := Vector3(-FPlayerPitch, 90 - FPlayerFacing, 0);
end;

function TQuakeWorld.Recording: Boolean;
begin
  Result := FRecorder <> nil;
end;

function TQuakeWorld.StartRecording(const Url: String): Boolean;
begin
  Result := False;
  StopRecording;
  if FBsp = nil then
    Exit;
  FRecorder := TQuakeDemoWriter.Create;
  FRecordUrl := Url;
  FRecordHud := FHud;
  Sounds.OnPlay := @RecordSound;
  Particles.OnEffect := @RecordEffect;
  if FRecordHud <> nil then
    FRecordHud.OnMessage := @RecordMessage;
  RecordLevelStart;
  Result := True;
end;

procedure TQuakeWorld.StopRecording;
begin
  if FRecorder = nil then
    Exit;
  FRecorder.SaveToUrl(FRecordUrl);
  FreeAndNil(FRecorder);
  if Sounds <> nil then
    Sounds.OnPlay := nil;
  if Particles <> nil then
    Particles.OnEffect := nil;
  if FRecordHud <> nil then
    FRecordHud.OnMessage := nil;
  FRecordHud := nil;
end;

procedure TQuakeWorld.RecordLevelStart;
var
  World: TQuakeEntity;
  Title: String;
begin
  if (FRecorder = nil) or (FBsp = nil) then
    Exit;
  Title := FBsp.MapName;
  World := FBsp.FindEntity('worldspawn');
  if (World <> nil) and (World.MessageText <> '') then
    Title := World.MessageText;
  FRecorder.BeginLevel('maps/' + FBsp.MapName + '.bsp', Title, ViewAnglesQuake,
    FPlayerStats.TotalKills, FPlayerStats.TotalSecrets);
end;

procedure TQuakeWorld.RecordSound(const APath: String; const Spatial: Boolean;
  const ATransform: TCastleTransform; const Volume: Single);
begin
  if FRecorder = nil then
    Exit;
  if Spatial then
    FRecorder.WriteSound(0, 0, FRecorder.SoundIndex(APath), Volume, 1,
      CgeToQuake(ATransform.WorldTranslation))
  else
    FRecorder.WriteSound(1, 0, FRecorder.SoundIndex(APath), Volume, 0, FPhys.Origin);
end;

procedure TQuakeWorld.RecordEffect(const Kind: String; const Pos, Normal: TVector3);
begin
  if FRecorder = nil then
    Exit;
  if Kind = 'explosion' then
    FRecorder.WriteTempEntity(TE_EXPLOSION, CgeToQuake(Pos))
  else if Kind = 'teleport' then
    FRecorder.WriteTempEntity(TE_TELEPORT, CgeToQuake(Pos))
  else if Kind = 'lavasplash' then
    FRecorder.WriteTempEntity(TE_LAVASPLASH, CgeToQuake(Pos))
  else if Kind = 'puff' then
    FRecorder.WriteTempEntity(TE_GUNSHOT, CgeToQuake(Pos))
  else if Kind = 'blood' then
    FRecorder.WriteParticle(CgeToQuake(Pos), CgeToQuake(Normal) * 2, 20, 73);
end;

procedure TQuakeWorld.RecordMessage(const S: String);
begin
  if FRecorder <> nil then
    FRecorder.WriteCenterPrint(StringReplace(S, LineEnding, #10, [rfReplaceAll]));
end;

procedure TQuakeWorld.RecordFrame;
const
  WeaponItems: array[1..8] of Cardinal = (IT_AXE, IT_SHOTGUN, IT_SUPER_SHOTGUN, IT_NAILGUN,
    IT_SUPER_NAILGUN, IT_GRENADE_LAUNCHER, IT_ROCKET_LAUNCHER, IT_LIGHTNING);
var
  CD: TDemoClientData;
  I, Num: Integer;
  St: TDemoEntityState;
  Sub: TQuakeSubmodel;
  M: TQuakeMonster;
  P: TQuakePickup;
  Proj: TQuakeProjectile;
  Gib: TQuakeGib;
  Dir: TVector3;

  procedure Send(const ModelPath: String; const Origin, Angles: TVector3; const Frame: Integer;
    const Effects: Integer = 0);
  begin
    if Num >= MaxDemoEntities then
      Exit;
    St := Default(TDemoEntityState);
    St.ModelIndex := FRecorder.ModelIndex(ModelPath);
    St.Frame := Frame;
    St.Origin := Origin;
    St.Angles := Angles;
    St.Effects := Effects;
    if St.ModelIndex > 0 then
      FRecorder.WriteEntity(Num, St);
    Inc(Num);
  end;

begin
  if (FRecorder = nil) or (FBsp = nil) or (FGeometry = nil) then
    Exit;
  FRecorder.BeginFrame(FTime);

  { The player (view entity 1) }
  CD := Default(TDemoClientData);
  CD.ViewHeight := FPhys.ViewHeight;
  CD.Velocity := FPhys.Velocity;
  for I := 1 to 8 do
    if (FPlayerStats.WeaponMask and (1 shl I)) <> 0 then
      CD.Items := CD.Items or WeaponItems[I];
  case FPlayerStats.CurrentWeapon of
    2, 3: CD.Items := CD.Items or IT_SHELLS;
    4, 5: CD.Items := CD.Items or IT_NAILS;
    6, 7: CD.Items := CD.Items or IT_ROCKETS;
    8: CD.Items := CD.Items or IT_CELLS;
  end;
  case FPlayerStats.ArmorType of
    1: CD.Items := CD.Items or IT_ARMOR1;
    2: CD.Items := CD.Items or IT_ARMOR2;
    3: CD.Items := CD.Items or IT_ARMOR3;
  end;
  if (FPlayerStats.Keys and 1) <> 0 then
    CD.Items := CD.Items or IT_KEY1;
  if (FPlayerStats.Keys and 2) <> 0 then
    CD.Items := CD.Items or IT_KEY2;
  if FPlayerStats.BiosuitTime > 0 then
    CD.Items := CD.Items or IT_SUIT;
  if FWeaponAnim <> nil then
    CD.WeaponFrame := FWeaponAnim.Sequence.First + FWeaponAnim.FrameIndex;
  CD.Armor := EnsureRange(FPlayerStats.Armor, 0, 255);
  if (FWeaponModelName <> '') and not FPlayerDead then
    CD.Weapon := FRecorder.ModelIndex(FWeaponModelName);
  CD.Health := FPlayerStats.Health;
  CD.Ammo := EnsureRange(FPlayerStats.Ammo, 0, 255);
  CD.Shells := EnsureRange(FPlayerStats.Shells, 0, 255);
  CD.Nails := EnsureRange(FPlayerStats.Nails, 0, 255);
  CD.Rockets := EnsureRange(FPlayerStats.Rockets, 0, 255);
  CD.Cells := EnsureRange(FPlayerStats.Cells, 0, 255);
  if (FPlayerStats.CurrentWeapon >= 1) and (FPlayerStats.CurrentWeapon <= 8) then
    CD.ActiveWeapon := WeaponItems[FPlayerStats.CurrentWeapon];
  FRecorder.WriteClientData(CD);

  Num := 1;
  if FRecordMuzzle then
    Send('progs/player.mdl', FPhys.Origin, Vector3(0, 90 - FPlayerFacing, 0), 0, EF_MUZZLEFLASH)
  else
    Send('progs/player.mdl', FPhys.Origin, Vector3(0, 90 - FPlayerFacing, 0), 0);
  FRecordMuzzle := False;

  { Brush entities at their current offsets }
  for Sub in FGeometry.Submodels do
  begin
    if SubmodelIsSolid(Sub) then
      Send('*' + IntToStr(Sub.ModelIndex), CgeToQuake(Sub.Transform.Translation), TVector3.Zero, 0)
    else
      Inc(Num);
  end;

  for M in FMonsters do
  begin
    if M.Transform.Exists and (M.Animator <> nil) then
      Send(M.Def.Model, M.Origin, Vector3(0, M.Yaw, 0),
        M.Animator.Sequence.First + M.Animator.FrameIndex)
    else
      Inc(Num);
  end;

  for P in FPickups do
  begin
    if not P.Collected then
      Send(P.ModelPath, CgeToQuake(P.Origin), Vector3(0, P.RotationAngle, 0), 0)
    else
      Inc(Num);
  end;

  for Proj in FProjectiles do
  begin
    Dir := Proj.Velocity;
    if Dir.IsPerfectlyZero then
      Dir := Vector3(1, 0, 0);
    Send(Proj.ModelPath, Proj.Origin, Vector3(RadToDeg(ArcTan2(Dir.Z, Sqrt(Sqr(Dir.X) + Sqr(Dir.Y)))),
      RadToDeg(ArcTan2(Dir.Y, Dir.X)), Proj.Spin), 0);
  end;

  for Gib in FGibs do
    Send(Gib.ModelPath, Gib.Origin, Gib.Angles, 0);

  FRecorder.EndFrame(ViewAnglesQuake);
end;
