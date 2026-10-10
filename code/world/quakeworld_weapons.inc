{ Weapons and projectiles: the view model, weapon selection, traces, damage, bullets, nails, lightning, rockets, grenades, explosions, gibs.
  Part of the QuakeWorld unit (included from quakeworld.pas). }

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
    FreeAndNil(FWeaponAnim);
    FWeaponMdl := nil;
    if FWeaponScene <> nil then
    begin
      FWeaponTransform.Remove(FWeaponScene);
      FreeAndNil(FWeaponScene);
    end;

    Mdl := MdlManager.GetModel(TargetModel);
    if Mdl <> nil then
    begin
      FWeaponScene := Mdl.CreateScene(0);
      FWeaponScene.Name := 'view_weapon_scene';
      FWeaponTransform.Add(FWeaponScene);
      FWeaponMdl := Mdl;
      FWeaponAnim := TMdlAnimator.Create(Mdl, FWeaponScene);
      FWeaponAnim.Play(Mdl.Sequence(0, 1, True));
    end;
  end;
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

procedure TQuakeWorld.SelectNextWeapon(const Direction: Integer; const Hud: TQuakeHud);
var
  Slot, I: Integer;
begin
  Slot := FPlayerStats.CurrentWeapon;
  for I := 1 to 8 do
  begin
    Slot := Slot + Sign(Direction);
    if Slot > 8 then
      Slot := 1;
    if Slot < 1 then
      Slot := 8;
    if (FPlayerStats.WeaponMask and (1 shl Slot)) <> 0 then
    begin
      SelectWeapon(Slot, Hud);
      Exit;
    end;
  end;
end;

function TQuakeWorld.MonsterBounds(const M: TQuakeMonster; out AMins, AMaxs: TVector3): Boolean;
var
  Org: TVector3;
begin
  Result := M.IsSolid;
  if not Result then
    Exit;
  Org := M.Origin;
  AMins := M.Def.Mins + Org;
  AMaxs := M.Def.Maxs + Org;
end;

function TQuakeWorld.TraceShot(const Start, Stop: TVector3; out HitMonster: TQuakeMonster): TQuakeTrace;
var
  HitPlayer: Boolean;
begin
  Result := TraceMissile(Start, Stop, nil, HitMonster, HitPlayer);
end;

function TQuakeWorld.TraceMissile(const Start, Stop: TVector3; const Owner: TObject;
  out HitMonster: TQuakeMonster; out HitPlayer: Boolean): TQuakeTrace;
var
  M: TQuakeMonster;
  BoxMins, BoxMaxs: TVector3;
  T: TQuakeTrace;

  procedure Consider(const AMins, AMaxs: TVector3; const AMonster: TQuakeMonster);
  begin
    T := TraceSegmentBox(AMins, AMaxs, Start, Stop);
    if T.StartSolid then
    begin
      { Point blank: the shot starts inside the target }
      T.Fraction := 0;
      T.EndPos := Start;
      T.PlaneNormal := (Stop - Start).Normalize * -1;
    end;
    if (T.Fraction < Result.Fraction) and (T.Fraction < 1) then
    begin
      Result := T;
      HitMonster := AMonster;
      HitPlayer := AMonster = nil;
    end;
  end;

begin
  HitMonster := nil;
  HitPlayer := False;
  if FBsp = nil then
  begin
    FillChar(Result, SizeOf(Result), 0);
    Result.Fraction := 1;
    Result.EndPos := Stop;
    Exit;
  end;
  Result := FPhys.Trace(Start, Stop, True, True);
  for M in FMonsters do
    if (M <> Owner) and MonsterBounds(M, BoxMins, BoxMaxs) then
      Consider(BoxMins, BoxMaxs, M);
  { Monster missiles can hit the player }
  if (Owner <> nil) and not FPlayerDead then
  begin
    PlayerBox(BoxMins, BoxMaxs);
    Consider(BoxMins, BoxMaxs, nil);
  end;
end;

function TQuakeWorld.CanDamage(const Inflictor, TargetCenter: TVector3): Boolean;
const
  Corners: array[0..4] of TVector2 = ((X: 0; Y: 0), (X: 15; Y: 15), (X: -15; Y: -15),
    (X: -15; Y: 15), (X: 15; Y: -15));
var
  I: Integer;
begin
  for I := 0 to High(Corners) do
    if FPhys.Trace(Inflictor, TargetCenter + Vector3(Corners[I].X, Corners[I].Y, 0),
      True, True).Fraction = 1 then
      Exit(True);
  Result := False;
end;

procedure TQuakeWorld.DamageMonster(const M: TQuakeMonster; const Damage: Single;
  const From: TVector3; const Attacker: TQuakeMonster);
begin
  if Damage > 0 then
    M.TakeDamage(Max(1, Round(Damage)), Attacker);
end;

procedure TQuakeWorld.RadiusDamage(const Center: TVector3; const Damage: Single;
  const Ignore: TQuakeMonster; const Hud: TQuakeHud; const PlayerAttacker: Boolean;
  const IgnorePlayer: Boolean; const Attacker: TQuakeMonster);
var
  M: TQuakeMonster;
  BoxMins, BoxMaxs, Target, Dir: TVector3;
  Points: Single;
begin
  { T_RadiusDamage: damage falls off by half a point per unit of distance }
  for M in FMonsters do
    if (M <> Ignore) and MonsterBounds(M, BoxMins, BoxMaxs) then
    begin
      Target := (BoxMins + BoxMaxs) * 0.5;
      Points := Damage - 0.5 * PointsDistance(Center, Target);
      if M.EntityClassName = 'monster_shambler' then
        Points := Points * 0.5; { shamblers resist explosions }
      if (Points > 0) and CanDamage(Center, Target) then
        DamageMonster(M, Points, Center, Attacker);
    end;

  { The player takes half damage from their own explosions, and the
    knockback (T_Damage) is what makes rocket jumping work }
  Target := FPhys.Origin + (FPhys.Mins + FPhys.Maxs) * 0.5;
  Points := Damage - 0.5 * PointsDistance(Center, Target);
  if PlayerAttacker then
    Points := Points * 0.5;
  if (Points > 0) and CanDamage(Center, Target) and not FPlayerDead and not IgnorePlayer then
  begin
    Dir := FPhys.Origin - Center;
    if not Dir.IsPerfectlyZero then
      FPhys.Velocity := FPhys.Velocity + Dir.Normalize * Points * 8;
    DamagePlayer(Round(Points), Hud);
  end;
end;

procedure TQuakeWorld.FireBullets(const Count: Integer; const Src, Dir, Right, Up: TVector3;
  const SpreadX, SpreadY: Single);
var
  I, J: Integer;
  ShotDir: TVector3;
  T: TQuakeTrace;
  M: TQuakeMonster;
  Hit: array of TQuakeMonster;
  HitDamage: array of Single;
begin
  { FireBullets: each pellet is a 2048 unit traceline with random spread;
    damage is summed per target (multidamage) and applied once }
  SetLength(Hit, 0);
  SetLength(HitDamage, 0);
  for I := 1 to Count do
  begin
    ShotDir := Dir + Right * ((Random * 2 - 1) * SpreadX) + Up * ((Random * 2 - 1) * SpreadY);
    T := TraceShot(Src, Src + ShotDir * 2048, M);
    if T.Fraction = 1 then
      Continue;
    if M <> nil then
    begin
      Particles.SpawnBlood(QuakeToCge(T.EndPos - ShotDir * 4), QuakeToCge(ShotDir * -1));
      J := 0;
      while (J < Length(Hit)) and (Hit[J] <> M) do
        Inc(J);
      if J = Length(Hit) then
      begin
        SetLength(Hit, J + 1);
        SetLength(HitDamage, J + 1);
        Hit[J] := M;
        HitDamage[J] := 0;
      end;
      HitDamage[J] := HitDamage[J] + 4;
    end else
    if FBsp.PointContents(T.EndPos) <> CONTENTS_SKY then
      Particles.SpawnPuff(QuakeToCge(T.EndPos - ShotDir * 4), QuakeToCge(T.PlaneNormal));
  end;
  for J := 0 to High(Hit) do
    DamageMonster(Hit[J], HitDamage[J], Src);
end;

procedure TQuakeWorld.LaunchSpike(const Kind: TQuakeProjectileKind; const Src, Dir: TVector3);
begin
  { launch_spike: 1000 units/s }
  FProjectiles.Add(TQuakeProjectile.Create(FRootTransform, Kind, Src, Dir * 1000));
end;

procedure TQuakeWorld.ShowBeam(const Pool: Integer; const StartQ, StopQ: TVector3;
  const Duration: Single);
const
  SegmentLength = 30.0; { CL_ParseBeam draws bolt models every 30 units }
  BeamModels: array[0..2] of String = ('progs/bolt2.mdl', 'progs/bolt.mdl', 'progs/bolt3.mdl');
var
  Mdl: TQuakeMdl;
  Delta, Dir: TVector3;
  Dist, Yaw, Pitch: Single;
  Count, I: Integer;
  Q: TQuaternion;
  Seg: TCastleTransform;
  Scene: TCastleScene;
begin
  Delta := StopQ - StartQ;
  Dist := Delta.Length;
  if Dist < 1 then
    Exit;
  Dir := Delta / Dist;
  Count := Min(Ceil(Dist / SegmentLength), 40);

  { Grow the pool of bolt segments when needed }
  while Length(FBeams[Pool].Segments) < Count do
  begin
    Mdl := MdlManager.GetModel(BeamModels[Pool]);
    if Mdl = nil then
      Break;
    Seg := TCastleTransform.Create(nil);
    Seg.Name := ComponentName('beam_segment');
    Scene := Mdl.CreateScene(0);
    Scene.Collides := False;
    Seg.Add(Scene);
    FRootTransform.Add(Seg);
    SetLength(FBeams[Pool].Segments, Length(FBeams[Pool].Segments) + 1);
    FBeams[Pool].Segments[High(FBeams[Pool].Segments)] := Seg;
  end;

  Yaw := ArcTan2(Dir.Y, Dir.X);
  Pitch := ArcTan2(Dir.Z, Sqrt(Sqr(Dir.X) + Sqr(Dir.Y)));
  for I := 0 to High(FBeams[Pool].Segments) do
  begin
    Seg := FBeams[Pool].Segments[I];
    Seg.Exists := I < Count;
    if not Seg.Exists then
      Continue;
    { Random roll per segment makes the bolt flicker }
    Q := QuatFromAxisAngle(Vector3(0, 1, 0), Yaw) * QuatFromAxisAngle(Vector3(0, 0, 1), Pitch) *
      QuatFromAxisAngle(Vector3(1, 0, 0), Random * 2 * Pi);
    Seg.Rotation := Q.ToAxisAngle;
    Seg.Translation := QuakeToCge(StartQ + Dir * (I * SegmentLength));
  end;
  FBeams[Pool].Time := Duration;
end;

procedure TQuakeWorld.FireLightning(const Src, Dir: TVector3; const Hud: TQuakeHud);
var
  T: TQuakeTrace;
  M: TQuakeMonster;
  Cells: Integer;
begin
  { W_FireLightning: discharge when fired under water }
  if FPhys.WaterLevel > 1 then
  begin
    Cells := FPlayerStats.Cells;
    FPlayerStats.Cells := 0;
    Sounds.Play('sound/weapons/lhit.wav');
    Particles.SpawnExplosion(QuakeToCge(FPhys.Origin));
    RadiusDamage(FPhys.Origin, 35 * Cells, nil, Hud);
    { T_RadiusDamage halves self damage; a discharge is meant to kill }
    DamagePlayer(Round(35 * Cells * 0.5), Hud);
    Exit;
  end;

  if (not FLightningFiring) or (FLightningSoundTime <= FTime) then
  begin
    if FLightningFiring then
      Sounds.Play('sound/weapons/lhit.wav')
    else
      Sounds.Play('sound/weapons/lstart.wav');
    FLightningSoundTime := FTime + 0.6;
  end;
  FLightningFiring := True;
  FLastLightningTime := FTime;

  T := TraceShot(Src, Src + Dir * 600, M);
  ShowBeam(0, Src, T.EndPos, 0.1);
  if M <> nil then
  begin
    { LightningDamage: 30 per 0.1 s }
    DamageMonster(M, 30, Src);
    Particles.SpawnBlood(QuakeToCge(T.EndPos), QuakeToCge(Dir * -1));
  end else
  if T.Fraction < 1 then
    Particles.SpawnPuff(QuakeToCge(T.EndPos), QuakeToCge(T.PlaneNormal));
end;

procedure TQuakeWorld.FireWeapon(const RayOrigin, RayDir: TVector3; const Hud: TQuakeHud);
var
  Fwd, Right, Up, Src: TVector3;
  Yaw: Single;
  T: TQuakeTrace;
  M: TQuakeMonster;
  CanFire: Boolean;
begin
  if FIntermission then
  begin
    IntermissionContinue;
    Exit;
  end;
  if (FWeaponCooldown > 0) or FPlayerDead or (FBsp = nil) then
    Exit;

  { Aim vectors from the view (Quake coordinates) }
  Fwd := CgeToQuake(RayDir).Normalize;
  Yaw := ArcTan2(Fwd.Y, Fwd.X);
  Right := Vector3(Sin(Yaw), -Cos(Yaw), 0);
  Up := TVector3.CrossProduct(Right, Fwd);
  { Shots leave from the player origin + 16 (absmin + 0.7 * size), like QuakeC }
  Src := FPhys.Origin + Vector3(0, 0, 16);

  CanFire := False;
  case FPlayerStats.CurrentWeapon of
    1: { W_FireAxe }
      begin
        CanFire := True;
        FWeaponCooldown := 0.5;
        FWeaponRecoil := 0.2;
        Sounds.Play('sound/weapons/ax1.wav');
        T := TraceShot(Src, Src + Fwd * 64, M);
        if T.Fraction < 1 then
        begin
          if M <> nil then
          begin
            Particles.SpawnBlood(QuakeToCge(T.EndPos - Fwd * 4), QuakeToCge(Fwd * -1));
            DamageMonster(M, 20, Src);
          end else
          begin
            Sounds.Play('sound/player/axhit2.wav');
            Particles.SpawnPuff(QuakeToCge(T.EndPos - Fwd * 4), QuakeToCge(T.PlaneNormal));
          end;
        end;
      end;

    2: { W_FireShotgun }
      if FPlayerStats.Shells >= 1 then
      begin
        Dec(FPlayerStats.Shells);
        CanFire := True;
        FWeaponCooldown := 0.5;
        FWeaponRecoil := 0.35;
        Sounds.Play('sound/weapons/guncock.wav');
        Lighting.TriggerMuzzleFlash(RayOrigin + RayDir * 20.0, 3.0);
        FireBullets(6, Src, Fwd, Right, Up, 0.04, 0.04);
      end;

    3: { W_FireSuperShotgun, falls back to the shotgun with one shell }
      if FPlayerStats.Shells >= 2 then
      begin
        Dec(FPlayerStats.Shells, 2);
        CanFire := True;
        FWeaponCooldown := 0.7;
        FWeaponRecoil := 0.6;
        Sounds.Play('sound/weapons/shotgn2.wav');
        Lighting.TriggerMuzzleFlash(RayOrigin + RayDir * 20.0, 4.5);
        FireBullets(14, Src, Fwd, Right, Up, 0.14, 0.08);
      end else
      if FPlayerStats.Shells = 1 then
      begin
        Dec(FPlayerStats.Shells);
        CanFire := True;
        FWeaponCooldown := 0.5;
        FWeaponRecoil := 0.35;
        Sounds.Play('sound/weapons/guncock.wav');
        FireBullets(6, Src, Fwd, Right, Up, 0.04, 0.04);
      end;

    4, 5: { W_FireSpikes: 10 nails per second from alternating barrels }
      if FPlayerStats.Nails >= 1 then
      begin
        CanFire := True;
        FWeaponCooldown := 0.1;
        FWeaponRecoil := 0.15;
        Lighting.TriggerMuzzleFlash(RayOrigin + RayDir * 20.0, 2.0);
        if (FPlayerStats.CurrentWeapon = 5) and (FPlayerStats.Nails >= 2) then
        begin
          Dec(FPlayerStats.Nails, 2);
          Sounds.Play('sound/weapons/spike2.wav');
          LaunchSpike(pjSuperNail, Src, Fwd);
        end else
        begin
          Dec(FPlayerStats.Nails);
          Sounds.Play('sound/weapons/rocket1i.wav');
          if FNailOffset > 0 then
            FNailOffset := -4
          else
            FNailOffset := 4;
          LaunchSpike(pjNail, Src + Right * FNailOffset, Fwd);
        end;
      end;

    6: { W_FireGrenade }
      if FPlayerStats.Rockets >= 1 then
      begin
        Dec(FPlayerStats.Rockets);
        CanFire := True;
        FWeaponCooldown := 0.6;
        FWeaponRecoil := 0.5;
        Sounds.Play('sound/weapons/grenade.wav');
        FProjectiles.Add(TQuakeProjectile.Create(FRootTransform, pjGrenade, FPhys.Origin,
          Fwd * 600 + Up * 200 + Right * ((Random * 2 - 1) * 10) + Up * ((Random * 2 - 1) * 10)));
      end;

    7: { W_FireRocket }
      if FPlayerStats.Rockets >= 1 then
      begin
        Dec(FPlayerStats.Rockets);
        CanFire := True;
        FWeaponCooldown := 0.8;
        FWeaponRecoil := 0.7;
        Sounds.Play('sound/weapons/sgun1.wav');
        Lighting.TriggerMuzzleFlash(RayOrigin + RayDir * 20.0, 5.0);
        FProjectiles.Add(TQuakeProjectile.Create(FRootTransform, pjRocket,
          FPhys.Origin + Fwd * 8 + Vector3(0, 0, 16), Fwd * 1000));
      end;

    8: { W_FireLightning }
      if FPlayerStats.Cells >= 1 then
      begin
        CanFire := True;
        FWeaponCooldown := 0.1;
        FWeaponRecoil := 0.1;
        Dec(FPlayerStats.Cells);
        Lighting.TriggerMuzzleFlash(RayOrigin + RayDir * 20.0, 4.0);
        FireLightning(Src, Fwd, Hud);
      end;
  end;

  { View weapon: frame 0 is the idle pose, the following frames the attack
    (weaponframe 1.. in QuakeC) }
  if CanFire and (FWeaponAnim <> nil) and (FWeaponMdl.FrameCount > 1) then
    FWeaponAnim.Play(FWeaponMdl.Sequence(1, FWeaponMdl.FrameCount - 1, False), True);

  { W_Attack: show_hostile; guns are heard, the axe only makes monsters
    nearby notice the player behind them }
  if CanFire then
  begin
    FRecordMuzzle := True;
    if FPlayerStats.CurrentWeapon = 1 then
      FShowHostile := FTime + 1
    else
      PropagateNoise;
  end;

  if not CanFire then
  begin
    FWeaponCooldown := 0.3;
    Sounds.Play('sound/weapons/noammo.wav');
  end;
end;

function ProjectileAttacker(const P: TQuakeProjectile): TQuakeMonster;
begin
  if P.Owner is TQuakeMonster then
    Result := TQuakeMonster(P.Owner)
  else
    Result := nil;
end;

procedure TQuakeWorld.ExplodeProjectile(const P: TQuakeProjectile; const Direct: TQuakeMonster;
  const Hud: TQuakeHud; const DirectPlayer: Boolean);
var
  Center: TVector3;
  ByPlayer: Boolean;
  Attacker: TQuakeMonster;
begin
  { T_MissileTouch / GrenadeExplode / OgreGrenadeExplode / ShalMissileTouch:
    direct hit damage, then radius damage from slightly behind the impact }
  Center := P.Origin;
  if not P.Velocity.IsPerfectlyZero then
    Center := Center - P.Velocity.Normalize * 8;
  ByPlayer := P.Owner = nil;
  Attacker := ProjectileAttacker(P);
  case P.Kind of
    pjRocket, pjLavaBall:
      begin
        { The direct target is left out of the splash }
        if Direct <> nil then
          DamageMonster(Direct, 100 + Random * 20, P.Origin, Attacker);
        if DirectPlayer then
          DamagePlayer(100 + Random(20), Hud);
        RadiusDamage(Center, 120, Direct, Hud, ByPlayer, DirectPlayer, Attacker);
      end;
    pjOgreGrenade:
      RadiusDamage(Center, 40, nil, Hud, False, False, Attacker);
    pjVorePod:
      begin
        if (Direct <> nil) and (Direct.EntityClassName = 'monster_zombie') then
          DamageMonster(Direct, 110, P.Origin, Attacker);
        RadiusDamage(Center, 40, nil, Hud, False, False, Attacker);
      end;
    else
      RadiusDamage(Center, 120, nil, Hud, ByPlayer, False, Attacker);
  end;
  Particles.SpawnExplosion(QuakeToCge(Center));
  Lighting.TriggerMuzzleFlash(QuakeToCge(Center), 6.0);
  Sounds.PlayAt('sound/weapons/r_exp3.wav', P.Transform);
end;

function VelocityForDamage(const Damage: Single): TVector3;
begin
  { VelocityForDamage (player.qc): the more overkill, the faster the gibs }
  Result := Vector3(100 * (Random * 2 - 1), 100 * (Random * 2 - 1), 200 + 100 * Random);
  if Damage > -50 then
    Result := Result * 0.7
  else if Damage > -200 then
    Result := Result * 2
  else
    Result := Result * 10;
end;

procedure TQuakeWorld.GibMonster(const M: TQuakeMonster);
var
  Org: TVector3;
  Gib: TQuakeGib;
  I: Integer;
begin
  M.GibPending := False;
  Org := M.Origin;
  { The body is replaced by its head }
  M.Transform.Exists := False;
  Sounds.PlayAt('sound/player/udeath.wav', M.Transform);

  for I := 0 to High(M.Def.GibModels) do
  begin
    { ThrowGib: removed after 10 to 20 seconds }
    Gib := TQuakeGib.Create(FRootTransform, M.Def.GibModels[I], Org, VelocityForDamage(M.Health),
      10 + Random * 10);
    Gib.AngularVelocity := Vector3(Random * 600, Random * 600, Random * 600);
    FGibs.Add(Gib);
  end;

  { ThrowHead: the head stays, 24 units lower, spinning around its up axis }
  if M.Def.Head <> '' then
  begin
    Gib := TQuakeGib.Create(FRootTransform, M.Def.Head, Org - Vector3(0, 0, 24),
      VelocityForDamage(M.Health), -1);
    Gib.AngularVelocity := Vector3(0, (Random * 2 - 1) * 600, 0);
    FGibs.Add(Gib);
  end;

  { Blood fountain }
  for I := 1 to 3 do
    Particles.SpawnBlood(QuakeToCge(Org + Vector3(0, 0, 8 * I)), Vector3(0, 1, 0));
end;

procedure TQuakeWorld.UpdateGibs(const SecondsPassed: Single);
var
  I: Integer;
  G: TQuakeGib;
  T: TQuakeTrace;
begin
  for I := FGibs.Count - 1 downto 0 do
  begin
    G := FGibs[I];
    if G.Life >= 0 then
    begin
      G.Life := G.Life - SecondsPassed;
      if G.Life <= 0 then
      begin
        FGibs.Delete(I);
        Continue;
      end;
    end;
    if G.OnGround or (FBsp = nil) then
      Continue;

    { SV_Physics_Toss with MOVETYPE_BOUNCE, against the world and brush entities }
    G.Velocity.Z := G.Velocity.Z - SvGravity * SecondsPassed;
    G.Angles := G.Angles + G.AngularVelocity * SecondsPassed;
    T := FPhys.Trace(G.Origin, G.Origin + G.Velocity * SecondsPassed, True, True);
    G.Origin := T.EndPos;
    if T.Fraction < 1 then
    begin
      G.Velocity := ClipVelocity(G.Velocity, T.PlaneNormal, 1.5);
      if (T.PlaneNormal.Z > 0.7) and (G.Velocity.Z < 60) then
      begin
        G.OnGround := True;
        G.Velocity := TVector3.Zero;
        G.AngularVelocity := TVector3.Zero;
      end;
    end;

    { EF_GIB blood trail while flying }
    G.TrailTimer := G.TrailTimer - SecondsPassed;
    if G.TrailTimer <= 0 then
    begin
      Particles.SpawnBloodTrail(QuakeToCge(G.Origin));
      G.TrailTimer := 0.05;
    end;
    G.UpdateVisual;
  end;
end;

procedure TQuakeWorld.UpdateProjectiles(const SecondsPassed: Single; const Hud: TQuakeHud);
var
  I, J: Integer;
  P: TQuakeProjectile;
  T: TQuakeTrace;
  M: TQuakeMonster;
  HitPlayer, Remove, Bounces: Boolean;
  Damage: Single;

  procedure DirectHit(const Amount: Single);
  begin
    if HitPlayer then
    begin
      DamagePlayer(Max(1, Round(Amount)), Hud);
      Particles.SpawnBlood(QuakeToCge(T.EndPos), QuakeToCge(P.Velocity.Normalize * -1));
    end else
    if M <> nil then
    begin
      Particles.SpawnBlood(QuakeToCge(T.EndPos), QuakeToCge(P.Velocity.Normalize * -1));
      DamageMonster(M, Amount, T.EndPos, ProjectileAttacker(P));
    end;
  end;

begin
  for I := FProjectiles.Count - 1 downto 0 do
  begin
    P := FProjectiles[I];
    Remove := False;
    P.Life := P.Life - SecondsPassed;
    Bounces := P.Kind in [pjGrenade, pjOgreGrenade];

    if P.Life <= 0 then
    begin
      if Bounces then
        ExplodeProjectile(P, nil, Hud); { fuse ran out }
      Remove := True;
    end else
    if not P.OnGround then
    begin
      { Grenades and zombie flesh fall, the rest fly straight }
      if Bounces or (P.Kind = pjZombieGib) then
      begin
        P.Velocity.Z := P.Velocity.Z - SvGravity * SecondsPassed;
        P.Spin := P.Spin + 300 * SecondsPassed;
      end;
      if P.Kind = pjLavaBall then
        P.Spin := P.Spin + 200 * SecondsPassed;

      { ShalHome: vore pods steer towards the vore's enemy }
      if P.Kind = pjVorePod then
      begin
        P.HomeTimer := P.HomeTimer - SecondsPassed;
        if P.HomeTimer <= 0 then
        begin
          P.HomeTimer := 0.2;
          M := ProjectileAttacker(P);
          if (M <> nil) and (M.Enemy <> nil) then
          begin
            if M.Enemy.IsSolid then
              P.Velocity := (M.Enemy.Origin + Vector3(0, 0, 10) - P.Origin).Normalize * 350;
          end else
          if not FPlayerDead then
            P.Velocity := (FPhys.Origin + Vector3(0, 0, 10) - P.Origin).Normalize * 350;
        end;
      end;

      T := TraceMissile(P.Origin, P.Origin + P.Velocity * SecondsPassed, P.Owner, M, HitPlayer);
      P.Origin := T.EndPos;

      if (T.Fraction < 1) or T.StartSolid then
      begin
        if (M = nil) and not HitPlayer and (FBsp.PointContents(T.EndPos) = CONTENTS_SKY) then
          Remove := True { missiles vanish into the sky }
        else
        case P.Kind of
          pjNail, pjSuperNail, pjWizSpike, pjKnightSpike, pjLaser:
            begin
              { spike_touch, Wiz_MissileTouch, laser touch }
              case P.Kind of
                pjSuperNail: Damage := 18;
                pjLaser: Damage := 15;
                else Damage := 9;
              end;
              if HitPlayer or (M <> nil) then
                DirectHit(Damage)
              else
              begin
                Particles.SpawnPuff(QuakeToCge(T.EndPos), QuakeToCge(T.PlaneNormal));
                if P.Kind = pjLaser then
                  Sounds.PlayAt('sound/enforcer/enfstop.wav', P.Transform)
                else
                case Random(5) of
                  0: Sounds.PlayAt('sound/weapons/ric1.wav', P.Transform);
                  1: Sounds.PlayAt('sound/weapons/ric2.wav', P.Transform);
                  2: Sounds.PlayAt('sound/weapons/ric3.wav', P.Transform);
                  else Sounds.PlayAt('sound/weapons/tink1.wav', P.Transform);
                end;
              end;
              Remove := True;
            end;
          pjRocket, pjLavaBall, pjVorePod:
            begin
              ExplodeProjectile(P, M, Hud, HitPlayer);
              Remove := True;
            end;
          pjZombieGib:
            begin
              { ZombieGrenadeTouch: 10 damage, or lie on the floor }
              if HitPlayer or (M <> nil) then
              begin
                DirectHit(10);
                Sounds.PlayAt('sound/zombie/z_hit.wav', P.Transform);
                Remove := True;
              end else
              begin
                Sounds.PlayAt('sound/zombie/z_miss.wav', P.Transform);
                P.OnGround := True;
                P.Velocity := TVector3.Zero;
                P.Life := Min(P.Life, 1.5);
              end;
            end;
          pjGrenade, pjOgreGrenade:
            if HitPlayer or (M <> nil) then
            begin
              ExplodeProjectile(P, M, Hud); { GrenadeTouch: explode on contact }
              Remove := True;
            end else
            begin
              { Bounce off walls, come to rest on floors }
              P.Velocity := ClipVelocity(P.Velocity, T.PlaneNormal, 1.5);
              if (T.PlaneNormal.Z > 0.7) and (P.Velocity.Z < 60) then
              begin
                P.OnGround := True;
                P.Velocity := TVector3.Zero;
              end;
              Sounds.PlayAt('sound/weapons/bounce.wav', P.Transform);
            end;
        end;
      end;

      { Trails }
      if not Remove then
      begin
        P.TrailTimer := P.TrailTimer - SecondsPassed;
        if P.TrailTimer <= 0 then
        begin
          case P.Kind of
            pjRocket, pjLavaBall:
              begin
                Particles.SpawnRocketTrail(QuakeToCge(P.Origin));
                P.TrailTimer := 0.03;
              end;
            pjGrenade, pjOgreGrenade:
              begin
                Particles.SpawnGrenadeTrail(QuakeToCge(P.Origin));
                P.TrailTimer := 0.05;
              end;
            pjZombieGib:
              begin
                Particles.SpawnBloodTrail(QuakeToCge(P.Origin));
                P.TrailTimer := 0.05;
              end;
            pjWizSpike:
              begin
                Particles.SpawnTrail(QuakeToCge(P.Origin), Vector3(0.3, 0.9, 0.2));
                P.TrailTimer := 0.04;
              end;
            pjKnightSpike:
              begin
                Particles.SpawnTrail(QuakeToCge(P.Origin), Vector3(1.0, 0.55, 0.15));
                P.TrailTimer := 0.04;
              end;
            pjVorePod:
              begin
                Particles.SpawnTrail(QuakeToCge(P.Origin), Vector3(0.7, 0.3, 0.9));
                P.TrailTimer := 0.04;
              end;
            pjLaser:
              P.TrailTimer := 1; { glows on its own }
            else
              begin
                Particles.SpawnNailTrail(QuakeToCge(P.Origin));
                P.TrailTimer := 0.04;
              end;
          end;
        end;
      end;
    end;

    if Remove then
      FProjectiles.Delete(I)
    else
      P.UpdateVisual;
  end;

  { Lightning beams last a moment after each discharge }
  for J := 0 to High(FBeams) do
    if FBeams[J].Time > 0 then
    begin
      FBeams[J].Time := FBeams[J].Time - SecondsPassed;
      if FBeams[J].Time <= 0 then
        for I := 0 to High(FBeams[J].Segments) do
          FBeams[J].Segments[I].Exists := False;
    end;
end;
