{ Pickups: items, ammo, armor, weapons, keys, runes and powerups.
  Part of the QuakeWorld unit (included from quakeworld.pas). }

procedure TQuakeWorld.CheckPickups(const Hud: TQuakeHud);
var
  I: Integer;
  P: TQuakePickup;
  BoxMins, BoxMaxs, ItemOrg: TVector3;
begin
  PlayerBox(BoxMins, BoxMaxs);
  for I := 0 to FPickups.Count - 1 do
  begin
    P := FPickups[I];
    if P.Collected then
      Continue;

    { Items touch the player box with their Quake size ('-16 -16 0' '16 16 56') }
    ItemOrg := CgeToQuake(P.Origin);
    if (BoxMins.X <= ItemOrg.X + 16) and (BoxMaxs.X >= ItemOrg.X - 16) and
       (BoxMins.Y <= ItemOrg.Y + 16) and (BoxMaxs.Y >= ItemOrg.Y - 16) and
       (BoxMins.Z <= ItemOrg.Z + 56) and (BoxMaxs.Z >= ItemOrg.Z) and
       not FPlayerDead then
    begin
      P.Collected := True;
      Sounds.Play(P.PickupSound);
      if Hud <> nil then
      begin
        Hud.ShowMessage(P.MessageText);
        Hud.BonusFlash;
      end;
      UseTargets(P.Target);

      case P.Kind of
        ikSigil:
          { sigil_touch: the episode is completed }
          FServerFlags := FServerFlags or (P.SpawnFlags and 15);
        ikSuperShotgun:
          begin
            FPlayerStats.WeaponMask := FPlayerStats.WeaponMask or (1 shl 3);
            FPlayerStats.Shells := Min(FPlayerStats.MaxShells, FPlayerStats.Shells + 10);
            SelectWeapon(3);
          end;
        ikNailgun:
          begin
            FPlayerStats.WeaponMask := FPlayerStats.WeaponMask or (1 shl 4);
            FPlayerStats.Nails := Min(FPlayerStats.MaxNails, FPlayerStats.Nails + 30);
            SelectWeapon(4);
          end;
        ikSuperNailgun:
          begin
            FPlayerStats.WeaponMask := FPlayerStats.WeaponMask or (1 shl 5);
            FPlayerStats.Nails := Min(FPlayerStats.MaxNails, FPlayerStats.Nails + 30);
            SelectWeapon(5);
          end;
        ikGrenadeLauncher:
          begin
            FPlayerStats.WeaponMask := FPlayerStats.WeaponMask or (1 shl 6);
            FPlayerStats.Rockets := Min(FPlayerStats.MaxRockets, FPlayerStats.Rockets + 5);
            SelectWeapon(6);
          end;
        ikRocketLauncher:
          begin
            FPlayerStats.WeaponMask := FPlayerStats.WeaponMask or (1 shl 7);
            FPlayerStats.Rockets := Min(FPlayerStats.MaxRockets, FPlayerStats.Rockets + 5);
            SelectWeapon(7);
          end;
        ikLightning:
          begin
            FPlayerStats.WeaponMask := FPlayerStats.WeaponMask or (1 shl 8);
            FPlayerStats.Cells := Min(FPlayerStats.MaxCells, FPlayerStats.Cells + 30);
            SelectWeapon(8);
          end;
        ikGreenArmor:
          begin
            FPlayerStats.Armor := Max(FPlayerStats.Armor, 100);
            FPlayerStats.ArmorType := 1;
          end;
        ikYellowArmor:
          begin
            FPlayerStats.Armor := Max(FPlayerStats.Armor, 150);
            FPlayerStats.ArmorType := 2;
          end;
        ikRedArmor:
          begin
            FPlayerStats.Armor := 200;
            FPlayerStats.ArmorType := 3;
          end;
        ikHealthSmall:
          FPlayerStats.Health := Min(100, FPlayerStats.Health + 15);
        ikHealthNormal:
          FPlayerStats.Health := Min(100, FPlayerStats.Health + 25);
        ikHealthMega:
          FPlayerStats.Health := Min(200, FPlayerStats.Health + 100);
        ikShells:
          FPlayerStats.Shells := Min(FPlayerStats.MaxShells, FPlayerStats.Shells + 20);
        ikNails:
          FPlayerStats.Nails := Min(FPlayerStats.MaxNails, FPlayerStats.Nails + 30);
        ikRockets:
          FPlayerStats.Rockets := Min(FPlayerStats.MaxRockets, FPlayerStats.Rockets + 5);
        ikCells:
          FPlayerStats.Cells := Min(FPlayerStats.MaxCells, FPlayerStats.Cells + 30);
        ikKeySilver:
          FPlayerStats.Keys := FPlayerStats.Keys or 1;
        ikKeyGold:
          FPlayerStats.Keys := FPlayerStats.Keys or 2;
        ikBioSuit:
          FPlayerStats.BiosuitTime := 30.0;
      end;
    end;
  end;
end;
