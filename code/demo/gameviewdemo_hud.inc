{ The HUD of the demo and network view: stats, the scoreboard, the demo status line.
  Included by gameviewdemo.pas. }

function TViewDemo.ScoreboardText: String;
var
  I, K: Integer;
  Teams, TeamFrags: specialize TArray<Integer>;

  procedure AddPlayer(const I: Integer);
  begin
    Result := Result + LineEnding + Format('%3d   %s', [FDemo.Frags[I], FDemo.Names[I]]);
    if (I = FDemo.ViewEntity - 1) and not Spectate then
      Result := Result + Format(Tr('   (you, ping %d ms)'), [Round(FPing)]);
  end;

begin
  Result := Tr('Scoreboard');
  if FDemo.TeamPlay > 0 then
  begin
    { The teams by frags, each with its players }
    SortedTeams(FDemo, Teams, TeamFrags);
    for K := 0 to High(Teams) do
    begin
      Result := Result + LineEnding + Format(Tr('%s team: %d'), [Tr(TeamColorNames[Min(Teams[K], 13)]), TeamFrags[K]]);
      for I in SortedPlayers(FDemo) do
        if (FDemo.Colors[I] and 15) = Teams[K] then
          AddPlayer(I);
    end;
    Exit;
  end;
  for I in SortedPlayers(FDemo) do
    AddPlayer(I);
end;

function TViewDemo.ScoreboardLog: String;
var
  I, K: Integer;
  Teams, TeamFrags: specialize TArray<Integer>;
  Line: String;

  function PlayerText(const I: Integer): String;
  begin
    Result := Format('%s %d', [FDemo.Names[I], FDemo.Frags[I]]);
    if (I = FDemo.ViewEntity - 1) and not Spectate then
      Result := Result + Format(' (you, ping %d ms)', [Round(FPing)]);
  end;

begin
  Result := '';
  if FDemo.TeamPlay > 0 then
  begin
    SortedTeams(FDemo, Teams, TeamFrags);
    for K := 0 to High(Teams) do
    begin
      Line := '';
      for I in SortedPlayers(FDemo) do
        if (FDemo.Colors[I] and 15) = Teams[K] then
        begin
          if Line <> '' then
            Line := Line + ', ';
          Line := Line + PlayerText(I);
        end;
      if Result <> '' then
        Result := Result + '; ';
      Result := Result + Format('%s team %d: %s', [TeamColorNames[Min(Teams[K], 13)], TeamFrags[K], Line]);
    end;
    Exit;
  end;
  for I in SortedPlayers(FDemo) do
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + PlayerText(I);
  end;
end;

procedure TViewDemo.UpdateHudStats(const Reader: TQuakeDemoReader; const Hud: TQuakeHud; const Eye: TVector3;
  const Main: Boolean; const SecondsPassed: Single);
var
  S: TQuakePlayerStats;
  Items: Cardinal;
  I: Integer;
const
  WeaponItems: array[1..8] of Cardinal = (IT_AXE, IT_SHOTGUN, IT_SUPER_SHOTGUN, IT_NAILGUN,
    IT_SUPER_NAILGUN, IT_GRENADE_LAUNCHER, IT_ROCKET_LAUNCHER, IT_LIGHTNING);
begin
  S := Default(TQuakePlayerStats);
  Items := Reader.ClientData.Items;
  S.Health := Reader.ClientData.Health;
  S.Armor := Reader.ClientData.Armor;
  if (Items and IT_ARMOR3) <> 0 then
    S.ArmorType := 3
  else if (Items and IT_ARMOR2) <> 0 then
    S.ArmorType := 2
  else if (Items and IT_ARMOR1) <> 0 then
    S.ArmorType := 1;
  S.Ammo := Reader.ClientData.Ammo;
  S.Shells := Reader.ClientData.Shells;
  S.Nails := Reader.ClientData.Nails;
  S.Rockets := Reader.ClientData.Rockets;
  S.Cells := Reader.ClientData.Cells;
  S.MaxShells := 100;
  S.MaxNails := 200;
  S.MaxRockets := 100;
  S.MaxCells := 100;
  for I := 1 to 8 do
  begin
    if (Items and WeaponItems[I]) <> 0 then
      S.WeaponMask := S.WeaponMask or (1 shl I);
    if Cardinal(Reader.ClientData.ActiveWeapon) = WeaponItems[I] then
      S.CurrentWeapon := I;
  end;
  if (Items and IT_KEY1) <> 0 then
    S.Keys := S.Keys or 1;
  if (Items and IT_KEY2) <> 0 then
    S.Keys := S.Keys or 2;
  if (Items and IT_SUIT) <> 0 then
    S.BiosuitTime := 1;
  S.Kills := Reader.Stats[STAT_MONSTERS];
  S.TotalKills := Reader.Stats[STAT_TOTALMONSTERS];
  S.Secrets := Reader.Stats[STAT_SECRETS];
  S.TotalSecrets := Reader.Stats[STAT_TOTALSECRETS];
  S.LevelTime := Math.Max(0.0, Reader.Time - FLevelStart);
  S.AirLeft := 12;
  if FBsp <> nil then
  begin
    I := FBsp.PointContentsCge(Eye);
    Hud.SetContents(I);
    S.Underwater := (I = CONTENTS_WATER) or (I = CONTENTS_SLIME) or (I = CONTENTS_LAVA);
    if Main then
    begin
      Sounds.SetUnderwater(S.Underwater);
      FUnderwater.Update(S.Underwater, SecondsPassed);
    end;
  end;
  Hud.Update(SecondsPassed, S);
end;

procedure TViewDemo.ShowDemoStatus;
var
  S: String;
begin
  if FDemoPaused then
    S := Format(Tr('Demo %s / %s, paused'), [DemoClockText(FPlayClock), DemoClockText(FDemoLength)])
  else if FDemoSpeed <> 1 then
    S := Format(Tr('Demo %s / %s at %s x speed'), [DemoClockText(FPlayClock), DemoClockText(FDemoLength),
      FormatFloat('0.##', FDemoSpeed)])
  else
    S := Format(Tr('Demo %s / %s'), [DemoClockText(FPlayClock), DemoClockText(FDemoLength)]);
  FHud.ShowMessage(S, 2);
end;
