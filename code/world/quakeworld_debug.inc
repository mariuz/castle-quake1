{ Debug overlay: boxes and lines for triggers, monsters, movers, the player leaf and projectiles.
  Part of the QuakeWorld unit (included from quakeworld.pas). }

procedure TQuakeWorld.UpdateDebugOverlay;
var
  T: TQuakeTrigger;
  M: TQuakeMonster;
  Sub: TQuakeSubmodel;
  P: TQuakeProjectile;
  AMins, AMaxs, Eye: TVector3;
  Leaf: Integer;
  L: TBSPLeaf;
begin
  if DebugModes = [] then
  begin
    if FDebug <> nil then
    begin
      FDebug.Clear;
      FDebug.Commit;
    end;
    Exit;
  end;
  if (FBsp = nil) or (FGeometry = nil) then
    Exit;
  if FDebug = nil then
    FDebug := TQuakeDebugOverlay.Create(FRootTransform);
  FDebug.Clear;
  Eye := FPhys.Origin + Vector3(0, 0, FPhys.ViewHeight);

  if dbTriggers in DebugModes then
    for T in FTriggers do
      if T.Removed then
        FDebug.AddBox(T.Mins, T.Maxs, DebugColorTriggerDone)
      else
        FDebug.AddBox(T.Mins, T.Maxs, DebugColorTrigger);

  if dbMonsters in DebugModes then
    for M in FMonsters do
      if M.Transform.Exists and M.IsSolid then
      begin
        if M.SightAlerted then
        begin
          FDebug.AddBox(M.Origin + M.Def.Mins, M.Origin + M.Def.Maxs, DebugColorMonsterAlert);
          FDebug.AddLine(M.Center, Eye, DebugColorMonsterAlert);
        end else
          FDebug.AddBox(M.Origin + M.Def.Mins, M.Origin + M.Def.Maxs, DebugColorMonster);
      end;

  if dbMovers in DebugModes then
    for Sub in FGeometry.Submodels do
      if SubmodelBounds(Sub, AMins, AMaxs) then
        FDebug.AddBox(AMins, AMaxs, DebugColorMover);

  if dbLeaf in DebugModes then
  begin
    Leaf := FBsp.PointLeaf(Eye);
    if (Leaf >= 0) and (Leaf < Length(FBsp.Leaves)) then
    begin
      L := FBsp.Leaves[Leaf];
      FDebug.AddBox(Vector3(L.Mins[0], L.Mins[1], L.Mins[2]), Vector3(L.Maxs[0], L.Maxs[1], L.Maxs[2]),
        DebugColorLeaf);
    end;
    PlayerBox(AMins, AMaxs);
    FDebug.AddBox(AMins, AMaxs, DebugColorPlayer);
    for P in FProjectiles do
      FDebug.AddMarker(P.Origin, 8, DebugColorProjectile);
  end;
  FDebug.Commit;
end;
