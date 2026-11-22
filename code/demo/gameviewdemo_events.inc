{ What the demo or the server says: sounds, effects, prints, damage, lightstyles, the intermission.
  Included by gameviewdemo.pas. }

procedure TViewDemo.HandleServerInfo;
begin
  LoadLevel;
end;

procedure TViewDemo.HandleSound(const Entity, Channel, SoundIndex: Integer;
  const Volume, Attenuation: Single; const Origin: TVector3);
var
  Path: String;
  T: TCastleTransform;
begin
  { A seek reads ahead without sounds and effects }
  if FSeeking then
    Exit;
  Path := FDemo.SoundName(SoundIndex);
  if Path = '' then
    Exit;
  if (Attenuation = 0) or (Entity = FDemo.ViewEntity) then
    Sounds.Play(Path, Volume)
  else
  begin
    T := FSoundPool[FSoundPoolNext];
    FSoundPoolNext := (FSoundPoolNext + 1) mod Length(FSoundPool);
    T.Translation := QuakeToCge(Origin);
    Sounds.PlayAt(Path, T, Volume);
  end;
end;

procedure TViewDemo.HandleTempEntity(const Kind: Integer; const Pos, Pos2: TVector3;
  const Entity, ColorStart, ColorLength: Integer);
begin
  { A seek reads ahead without sounds and effects }
  if FSeeking then
    Exit;
  FRenderer.TempEntity(Kind, Pos, Pos2);
end;

procedure TViewDemo.HandleEffect(const Trail: Boolean; const Num: Integer; const A, B: TVector3;
  const Count: Integer);
begin
  { A seek reads ahead without sounds and effects }
  if FSeeking or (EffectParticles = nil) or not ModEffects then
    Exit;
  Inc(FEffectMessages);
  if Trail then
    EffectParticles.Trail(Num, A, B)
  else
    EffectParticles.Spawn(Num, A, B, Count);
end;

procedure TViewDemo.HandleParticle(const Org, Dir: TVector3; const Count, Color: Integer);
var
  C: TVector4Byte;
begin
  { A seek reads ahead without sounds and effects }
  if FSeeking then
    Exit;
  if Count = 255 then
  begin
    Particles.SpawnExplosion(QuakeToCge(Org));
    Exit;
  end;
  { Blood is palette 64..79; anything else as a colored burst }
  if (Color >= 64) and (Color <= 79) then
    Particles.SpawnBlood(QuakeToCge(Org), QuakeToCge(Dir))
  else
  begin
    C := Palette.Color(Color and 255);
    Particles.SpawnTrail(QuakeToCge(Org), Vector3(C.X / 255, C.Y / 255, C.Z / 255));
  end;
end;

procedure TViewDemo.HandlePrint(const S: String);
begin
  { A seek reads ahead without sounds and effects }
  if FSeeking then
    Exit;
  WritelnLog('Demo', Trim(S));
  { In a network game the server's prints (chat, obituaries) show }
  if NetMode and (Trim(S) <> '') and not FChatting then
  begin
    FHud.ShowMessage(Trim(S), 4);
    if Pos(': ', S) > 0 then
      Sounds.Play('sound/misc/talk.wav');
  end;
end;

procedure TViewDemo.HandleCenterPrint(const S: String);
begin
  { A seek reads ahead without sounds and effects }
  if FSeeking then
    Exit;
  FHud.ShowMessage(S, 2.5);
end;

procedure TViewDemo.HandleCdTrack(const Track, LoopTrack: Integer);
begin
  Sounds.PlayTrack(Track);
end;

procedure TViewDemo.HandleFinale(const S: String);
begin
  FHud.StopIntermission;
  FHud.ShowMessage(S, 120);
end;

procedure TViewDemo.HandleDamage(const Armor, Blood: Integer; const From: TVector3);
begin
  { A seek reads ahead without sounds and effects }
  if FSeeking then
    Exit;
  FHud.DamageFlash(Armor, Blood);
end;

procedure TViewDemo.HandleLightStyle(const Index: Integer; const Pattern: String);
begin
  Lighting.SetStyle(Index, Pattern);
end;

procedure TViewDemo.HandleIntermission;
begin
  FHud.StartIntermission(FDemo.LevelName, Math.Max(0.0, FDemo.Time - FLevelStart),
    FDemo.Stats[STAT_MONSTERS], FDemo.Stats[STAT_TOTALMONSTERS],
    FDemo.Stats[STAT_SECRETS], FDemo.Stats[STAT_TOTALSECRETS]);
  Sounds.PlayMusic('track03.ogg');
end;
