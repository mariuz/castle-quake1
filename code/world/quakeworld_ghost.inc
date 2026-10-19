{ Speedrun timer and ghost racing.

  While a level is played (not in horde mode) the player's origin and yaw
  are sampled ten times a second. Finishing the level (the intermission)
  faster than the best time so far writes the run to
  castle-config:/ghost_<map>.ghost; with GhostRacing on, the next runs of
  the map show it as a translucent player model, and every 5 seconds of
  the ghost's run is a checkpoint: passing near it shows how far ahead or
  behind the ghost the player is. SpeedrunTimer shows the time to the
  hundredth and the split against the best run at the end. }

const
  GhostSampleInterval = 0.1;
  GhostCheckpointEvery = 5.0;
  GhostCheckpointRadius = 128;
  GhostMagic: array[0..3] of AnsiChar = 'QGST';
  GhostVersion = 1;

function GhostUrl(const AMapName: String): String;
begin
  Result := 'castle-config:/ghost_' + LowerCase(AMapName) + '.ghost';
end;

function FormatRunTime(const T: Single): String;
var
  Cs: Integer;
begin
  Cs := Round(Max(0, T) * 100);
  Result := Format('%d:%.2d.%.2d', [Cs div 6000, (Cs div 100) mod 60, Cs mod 100]);
end;

function FormatRunDelta(const D: Single): String;
begin
  if D >= 0 then
    Result := Format('+%.2f', [D])
  else
    Result := Format('-%.2f', [-D]);
end;

procedure TQuakeWorld.FreeGhost;
begin
  FreeAndNil(FGhostAnimator);
  FreeAndNil(FGhostScene);
  if (FGhostTransform <> nil) and (FGhostTransform.Parent <> nil) then
    FGhostTransform.Parent.Remove(FGhostTransform);
  FreeAndNil(FGhostTransform);
end;

procedure TQuakeWorld.SetupGhost;
var
  Stream: TStream;
  Magic: array[0..3] of AnsiChar;
  Version, Count: LongInt;
  Best: Single;
  Mdl: TQuakeMdl;
  Mat: TUnlitMaterialNode;
begin
  SetLength(FGhostRec, 0);
  FGhostRecTimer := 0;
  FGhostRecValid := not FHordeActive;
  SetLength(FGhostRun, 0);
  FGhostBest := 0;
  FGhostNextCheck := 0;
  FGhostDeltaTime := 0;
  FRunFinished := False;
  FreeGhost;
  if FHordeActive or not (GhostRacing or SpeedrunTimer) then
    Exit;

  { The best run of this map }
  if UriExists(GhostUrl(MapName)) = ueFile then
  begin
    Stream := Download(GhostUrl(MapName));
    try
      if Stream.Size >= 16 then
      begin
        Stream.ReadBuffer(Magic, 4);
        Stream.ReadBuffer(Version, 4);
        Stream.ReadBuffer(Best, 4);
        Stream.ReadBuffer(Count, 4);
        if (Magic = GhostMagic) and (Version = GhostVersion) and (Count > 0) and
           (Stream.Size >= 16 + Int64(Count) * SizeOf(TGhostSample)) then
        begin
          FGhostBest := Best;
          SetLength(FGhostRun, Count);
          Stream.ReadBuffer(FGhostRun[0], Count * SizeOf(TGhostSample));
        end;
      end;
    finally
      Stream.Free;
    end;
  end;
  if Length(FGhostRun) = 0 then
    Exit;
  WritelnLog('Ghost', 'Ghost of "%s": best %s, %d samples', [MapName, FormatRunTime(FGhostBest), Length(FGhostRun)]);
  if not GhostRacing then
    Exit;

  { The ghost: the player model, bluish and translucent }
  Mdl := MdlManager.GetModel('progs/player.mdl');
  if Mdl = nil then
    Exit;
  FGhostTransform := TCastleTransform.Create(nil);
  FGhostTransform.Name := ComponentName('ghost');
  FGhostScene := Mdl.CreateScene(0);
  FGhostScene.Name := FGhostTransform.Name + '_scene';
  FGhostScene.Collides := False;
  FGhostScene.Pickable := False;
  FGhostScene.CastShadows := False;
  if FGhostScene.RootNode <> nil then
  begin
    Mat := FGhostScene.RootNode.TryFindNode(TUnlitMaterialNode, False) as TUnlitMaterialNode;
    if Mat <> nil then
    begin
      Mat.EmissiveColor := Vector3(0.55, 0.8, 1.0);
      Mat.Transparency := 0.55;
    end;
  end;
  FGhostTransform.Add(FGhostScene);
  FRootTransform.Add(FGhostTransform);
  FGhostAnimator := TMdlAnimator.Create(Mdl, FGhostScene);
  FGhostRunSeq := Mdl.Sequence(Max(0, Mdl.FindFrame('rockrun')), 6, True);
  FGhostStandSeq := Mdl.Sequence(Max(0, Mdl.FindFrame('stand')), 5, True);
  FGhostAnimator.Play(FGhostStandSeq);
  UpdateGhostPose;
end;

{ The ghost where the best run was at this moment of the level }
procedure TQuakeWorld.UpdateGhostPose;
var
  T, Blend, Speed: Single;
  Lo, Hi, Mid: Integer;
  A, B: TGhostSample;
  P: TVector3;
  Yaw, DYaw: Single;
begin
  if (FGhostTransform = nil) or (Length(FGhostRun) = 0) then
    Exit;
  T := FPlayerStats.LevelTime;
  if T >= FGhostRun[High(FGhostRun)].T then
  begin
    { The run is over: the ghost is gone }
    FGhostTransform.Exists := False;
    Exit;
  end;
  FGhostTransform.Exists := True;
  Lo := 0;
  Hi := High(FGhostRun);
  while Hi - Lo > 1 do
  begin
    Mid := (Lo + Hi) div 2;
    if FGhostRun[Mid].T <= T then
      Lo := Mid
    else
      Hi := Mid;
  end;
  A := FGhostRun[Lo];
  B := FGhostRun[Hi];
  if B.T > A.T then
    Blend := EnsureRange((T - A.T) / (B.T - A.T), 0, 1)
  else
    Blend := 0;
  P := Vector3(A.X + (B.X - A.X) * Blend, A.Y + (B.Y - A.Y) * Blend, A.Z + (B.Z - A.Z) * Blend);
  DYaw := B.Yaw - A.Yaw;
  while DYaw > 180 do
    DYaw := DYaw - 360;
  while DYaw < -180 do
    DYaw := DYaw + 360;
  Yaw := A.Yaw + DYaw * Blend;
  FGhostTransform.Translation := QuakeToCge(P);
  { Not drawn while it is where the player is (it fills the view) }
  FGhostTransform.Exists := (P - FPhys.Origin).Length > 48;
  FGhostTransform.Rotation := Vector4(0, 1, 0, DegToRad(Yaw));
  if B.T > A.T then
    Speed := Vector2(B.X - A.X, B.Y - A.Y).Length / (B.T - A.T)
  else
    Speed := 0;
  if Speed > 40 then
    FGhostAnimator.Play(FGhostRunSeq)
  else
    FGhostAnimator.Play(FGhostStandSeq);
end;

procedure TQuakeWorld.UpdateGhost(const SecondsPassed: Single);
var
  S: TGhostSample;
  I, J: Integer;
  CheckT: Single;
  CheckPos: TVector3;
begin
  if FRunFinished or FIntermission or FPlayerDead or FHordeActive then
    Exit;

  { Record the run }
  if FGhostRecValid and (GhostRacing or SpeedrunTimer) then
  begin
    FGhostRecTimer := FGhostRecTimer - SecondsPassed;
    if FGhostRecTimer <= 0 then
    begin
      FGhostRecTimer := GhostSampleInterval;
      S.T := FPlayerStats.LevelTime;
      S.X := FPhys.Origin.X;
      S.Y := FPhys.Origin.Y;
      S.Z := FPhys.Origin.Z;
      S.Yaw := FPlayerFacing;
      SetLength(FGhostRec, Length(FGhostRec) + 1);
      FGhostRec[High(FGhostRec)] := S;
    end;
  end;

  { The ghost, and its checkpoints passed }
  if FGhostAnimator <> nil then
  begin
    UpdateGhostPose;
    FGhostAnimator.Update(SecondsPassed);
  end;
  if Length(FGhostRun) > 0 then
  begin
    FGhostDeltaTime := Max(0, FGhostDeltaTime - SecondsPassed);
    I := FGhostNextCheck;
    { The sample at each multiple of GhostCheckpointEvery }
    while I <= High(FGhostRun) do
    begin
      CheckT := (Trunc(FGhostRun[I].T / GhostCheckpointEvery) + 1) * GhostCheckpointEvery;
      while (I <= High(FGhostRun)) and (FGhostRun[I].T < CheckT) do
        Inc(I);
      if I > High(FGhostRun) then
        Break;
      CheckPos := Vector3(FGhostRun[I].X, FGhostRun[I].Y, FGhostRun[I].Z);
      if (CheckPos - FPhys.Origin).Length < GhostCheckpointRadius then
      begin
        { Against the moment the ghost first came this near the spot, like
          the player now (both may have stood there a while) }
        J := I;
        while (J > 0) and ((Vector3(FGhostRun[J - 1].X, FGhostRun[J - 1].Y, FGhostRun[J - 1].Z) - CheckPos).Length <
          GhostCheckpointRadius) do
          Dec(J);
        FGhostDelta := FPlayerStats.LevelTime - FGhostRun[J].T;
        FGhostDeltaTime := 3;
        FGhostNextCheck := I + 1;
        WritelnLog('Ghost', 'Checkpoint at %s: %s', [FormatRunTime(FGhostRun[I].T), FormatRunDelta(FGhostDelta)]);
      end;
      Break;
    end;
  end;
end;

{ The level is done (the intermission starts): the time against the best
  one, and the run kept when it is faster }
procedure TQuakeWorld.FinishRun;
var
  T: Single;
  Stream: TStream;
  Version, Count: LongInt;
  Record_: Boolean;
  Msg: String;
begin
  if FRunFinished or FHordeActive or not (GhostRacing or SpeedrunTimer) then
    Exit;
  FRunFinished := True;
  T := FPlayerStats.LevelTime;
  Record_ := FGhostRecValid and ((FGhostBest <= 0) or (T < FGhostBest));
  if FGhostBest > 0 then
    Msg := Format('%s in %s (best %s, %s)', [MapName, FormatRunTime(T), FormatRunTime(FGhostBest),
      FormatRunDelta(T - FGhostBest)])
  else
    Msg := Format('%s in %s (first run)', [MapName, FormatRunTime(T)]);
  if not FGhostRecValid then
    Msg := Msg + ', not kept: the game was loaded';
  WritelnLog('Speedrun', Msg);
  if Record_ and (Length(FGhostRec) > 0) then
  begin
    { The last sample at the finish }
    SetLength(FGhostRec, Length(FGhostRec) + 1);
    FGhostRec[High(FGhostRec)] := FGhostRec[High(FGhostRec) - 1];
    FGhostRec[High(FGhostRec)].T := T;
    try
      Stream := UrlSaveStream(GhostUrl(MapName));
      try
        Stream.WriteBuffer(GhostMagic, 4);
        Version := GhostVersion;
        Stream.WriteBuffer(Version, 4);
        Stream.WriteBuffer(T, 4);
        Count := Length(FGhostRec);
        Stream.WriteBuffer(Count, 4);
        Stream.WriteBuffer(FGhostRec[0], Count * SizeOf(TGhostSample));
      finally
        Stream.Free;
      end;
      WritelnLog('Speedrun', 'New best run of "%s" kept (%d samples)', [MapName, Count]);
    except
      on E: Exception do
        WritelnWarning('Speedrun', 'Cannot keep the run: ' + E.Message);
    end;
  end;
  if FHud <> nil then
  begin
    if Record_ and (FGhostBest > 0) then
      FHud.ShowMessage(Format('NEW RECORD %s  (%s)', [FormatRunTime(T), FormatRunDelta(T - FGhostBest)]), 5)
    else if Record_ then
      FHud.ShowMessage(Format('TIME %s', [FormatRunTime(T)]), 5)
    else
      FHud.ShowMessage(Format('TIME %s  (%s)', [FormatRunTime(T), FormatRunDelta(T - FGhostBest)]), 5);
  end;
end;

procedure TQuakeWorld.ResetGhost;
var
  Stream: TStream;
  Zero: array[0..15] of Byte;
begin
  { An empty file: no best run (the web build cannot delete files) }
  FillChar(Zero, SizeOf(Zero), 0);
  try
    Stream := UrlSaveStream(GhostUrl(MapName));
    try
      Stream.WriteBuffer(Zero, SizeOf(Zero));
    finally
      Stream.Free;
    end;
  except
    on E: Exception do
      WritelnWarning('Ghost', 'Cannot reset the ghost: ' + E.Message);
  end;
  SetLength(FGhostRun, 0);
  FGhostBest := 0;
  FreeGhost;
  WritelnLog('Ghost', 'Best run of "%s" forgotten', [MapName]);
end;

function TQuakeWorld.SpeedrunText: String;
begin
  Result := '';
  if FHordeActive then
    Exit;
  if SpeedrunTimer then
    Result := 'RUN ' + FormatRunTime(FPlayerStats.LevelTime);
  if FGhostDeltaTime > 0 then
  begin
    if Result <> '' then
      Result := Result + '   ';
    Result := Result + 'GHOST ' + FormatRunDelta(FGhostDelta);
  end;
end;
