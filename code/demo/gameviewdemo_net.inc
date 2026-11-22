{ The network client: input, prediction, the frames of the server, recording the game, chat and host commands.
  Included by gameviewdemo.pas. }

function TViewDemo.RelayTargetHost: String;
var
  P: Integer;
begin
  Result := WsRelayTarget;
  P := Pos(':', Result);
  if P > 0 then
    Result := Copy(Result, 1, P - 1);
  if (Result = '') or SameText(Result, 'localhost') then
    Result := '127.0.0.1';
end;

function TViewDemo.RelayTargetPort: Word;
var
  P: Integer;
begin
  Result := DefaultNetPort;
  P := Pos(':', WsRelayTarget);
  if P > 0 then
    Result := StrToIntDef(Copy(WsRelayTarget, P + 1, MaxInt), DefaultNetPort);
end;

procedure TViewDemo.SendInput(const SecondsPassed: Single);
var
  Input: TNetInput;
  PadForward, PadSide: Single;
begin
  { Weapon changes of the frames in between are kept for the next input }
  if AutoTestPrefix = '' then
  begin
    if GamepadJustPressed(GamepadNextWeapon, PlayerOne) then
      FImpulse := 10;
    if GamepadJustPressed(GamepadPrevWeapon, PlayerOne) then
      FImpulse := 12;
  end;
  { Fast frames add up: the server and the prediction run each input as one
    physics step, which must not be shorter than MinPhysicsStep }
  FInputTime := FInputTime + SecondsPassed;
  if FInputTime * 1000 < MinInputMsec then
    Exit;
  Input := Default(TNetInput);
  Inc(FInputSeq);
  Input.Sequence := FInputSeq;
  FInputSent[FInputSeq and 255] := FNetClock;
  Input.Msec := Min(Round(FInputTime * 1000), MaxInputMsec);
  FInputTime := Max(0, FInputTime - Input.Msec / 1000);
  Input.Angles := FDemo.ViewAngles;
  if (AutoTestPrefix = '') and not FChatting and not FConsole.IsOpen then
  begin
    if BindingHeld(qbForward, Container, PlayerOne) then
      Input.Move.X := Input.Move.X + ClForwardSpeed;
    if BindingHeld(qbBackward, Container, PlayerOne) then
      Input.Move.X := Input.Move.X - ClBackSpeed;
    if BindingHeld(qbStrafeRight, Container, PlayerOne) then
      Input.Move.Y := Input.Move.Y + ClSideSpeed;
    if BindingHeld(qbStrafeLeft, Container, PlayerOne) then
      Input.Move.Y := Input.Move.Y - ClSideSpeed;
    GamepadMove(PadForward, PadSide, PlayerOne);
    Input.Move.X := Input.Move.X + PadForward * ClForwardSpeed;
    Input.Move.Y := Input.Move.Y + PadSide * ClSideSpeed;
    if BindingHeld(qbWalk, Container, PlayerOne) then
      Input.Move := Input.Move * 0.5;
    if BindingHeld(qbJump, Container, PlayerOne) then
      Input.Buttons := Input.Buttons or nbJump;
    if BindingHeld(qbFire, Container, PlayerOne) then
      Input.Buttons := Input.Buttons or nbFire;
  end;
  Input.Move := Input.Move + Vector3(FScriptMove.X * ClForwardSpeed, FScriptMove.Y * ClSideSpeed,
    FScriptMove.Z * ClUpSpeed);
  if FScriptJump > 0 then
    Input.Buttons := Input.Buttons or nbJump;
  if FFireHeld > 0 then
    Input.Buttons := Input.Buttons or nbFire;
  Input.Impulse := EnsureRange(FImpulse, 0, 255);
  FImpulse := 0;
  if Spectate then
  begin
    { Jump (pressed) flies freely or goes back to following; fire goes to
      the server, which follows the next player (and the camera with it) }
    if ((Input.Buttons and nbJump) <> 0) and not FSpecJump then
    begin
      FSpecFree := not FSpecFree;
      if FSpecFree then
        FFlyEye := CgeToQuake(FViewport.Camera.Translation);
      WritelnLog('GameViewDemo', 'Spectator: %s', [BoolToStr(FSpecFree, 'flying freely', 'following again')]);
    end;
    FSpecJump := (Input.Buttons and nbJump) <> 0;
    if (Input.Buttons and nbFire) <> 0 then
      FSpecFree := False;
    FSpecMove := Input.Move;
    FClient.SendInput(Input);
    Exit;
  end;
  FClient.SendInput(Input);
  PredictInput(Input, SecondsPassed);
end;

procedure TViewDemo.RefreshPredictSolids;
var
  I, N: Integer;
begin
  { The brush entities where the server last showed them }
  N := 0;
  SetLength(FPredict.SolidModels, Length(FRenderer.Submodels));
  for I := 1 to High(FRenderer.Submodels) do
    if (FRenderer.Submodels[I] <> nil) and FRenderer.Submodels[I].Transform.Exists then
    begin
      FPredict.SolidModels[N].ModelIndex := I;
      FPredict.SolidModels[N].Offset := FRenderer.SubmodelOrigin[I];
      Inc(N);
    end;
  SetLength(FPredict.SolidModels, N);
  SetLength(FPredict.SolidBoxes, 0);
end;

procedure TViewDemo.PredictInput(const Input: TNetInput; const Dt: Single);
var
  H: TPredictedInput;
begin
  if not Predict or (FPredict = nil) then
    Exit;
  H := Default(TPredictedInput);
  H.Sequence := Input.Sequence;
  H.Cmd.ForwardMove := Input.Move.X;
  H.Cmd.SideMove := Input.Move.Y;
  H.Cmd.UpMove := Input.Move.Z;
  H.Cmd.Jump := (Input.Buttons and nbJump) <> 0;
  H.Yaw := Input.Angles.Y;
  H.Pitch := Input.Angles.X;
  H.Dt := Input.Msec / 1000; { what the server runs }
  if Length(FHistory) >= 128 then
    Delete(FHistory, 0, 1);
  SetLength(FHistory, Length(FHistory) + 1);
  FHistory[High(FHistory)] := H;
  if FPredictValid then
  begin
    RefreshPredictSolids;
    FPredict.Move(H.Cmd, H.Yaw, H.Pitch, H.Dt);
    FHistory[High(FHistory)].Origin := FPredict.Origin;
  end;
end;

procedure TViewDemo.ReconcilePrediction;
var
  V, I: Integer;
  Acked: Word;
  CD: TDemoClientData;
begin
  if not Predict or (FPredict = nil) or (FClient = nil) or not FClient.HasAckedInput then
    Exit;
  if FClient.FramesReceived = FReconciledFrames then
    Exit; { no new server frame }
  FReconciledFrames := FClient.FramesReceived;
  V := FDemo.ViewEntity;
  if (V <= 0) or (V >= Length(FDemo.Entities)) then
    Exit;
  { Start from the server's state and apply what it has not seen yet }
  Acked := FClient.AckedInput;
  CD := FDemo.ClientData;
  if FPredictValid then
    for I := 0 to High(FHistory) do
      if FHistory[I].Sequence = Acked then
      begin
        FPredictError := (FHistory[I].Origin - FDemo.Entities[V].Msg[0].Origin).Length;
        FPredictErrorMax := Max(FPredictErrorMax, FPredictError);
        Break;
      end;
  FPredict.Origin := FDemo.Entities[V].Msg[0].Origin;
  FPredict.Velocity := CD.Velocity;
  FPredict.OnGround := CD.OnGround;
  if CD.OnGround then
    FPredict.GroundEntity := 0
  else
    FPredict.GroundEntity := -1;
  FPredictValid := True;
  I := 0;
  while (I < Length(FHistory)) and (SmallInt(FHistory[I].Sequence - Acked) <= 0) do
    Inc(I);
  if I > 0 then
    Delete(FHistory, 0, I);
  RefreshPredictSolids;
  for I := 0 to High(FHistory) do
  begin
    FPredict.Move(FHistory[I].Cmd, FHistory[I].Yaw, FHistory[I].Pitch, FHistory[I].Dt);
    FHistory[I].Origin := FPredict.Origin;
  end;
end;

function TViewDemo.PredictionActive: Boolean;
begin
  Result := Predict and not Spectate and FPredictValid and (FPredict <> nil) and (FDemo.ClientData.Health > 0) and
    (FDemo.Intermission = 0);
end;

procedure TViewDemo.UpdateNetwork(const SecondsPassed: Single);
var
  Data: TNetBytes;
  I: Integer;
begin
  if FWsRelay <> nil then
    FWsRelay.Update;
  if WsRelayTarget <> '' then
    Exit;
  if FRendezvous <> nil then
  begin
    FRendezvous.Update(SecondsPassed);
    Exit;
  end;
  { The listen server runs here, before its own client reads it }
  if ListenServer <> nil then
    ListenServer.Update(SecondsPassed);
  if FClient = nil then
    Exit;
  FClient.Update(SecondsPassed);
  while FClient.PollBlock(Data) do
    FDemo.PushBlock(Data);
  for I := 2 to FSplitCount do
    if FPlayers[I].Client <> nil then
    begin
      FPlayers[I].Client.Update(SecondsPassed);
      while FPlayers[I].Client.PollBlock(Data) do
        FPlayers[I].Demo.PushBlock(Data);
    end;
  if FClient.State = csConnected then
    FWasConnected := True
  else
  if (FClient.State = csDisconnected) and not FDemo.Finished then
  begin
    if FWasConnected then
      FHud.ShowMessage('Disconnected from the server', 3)
    else
      FHud.ShowMessage('Cannot reach ' + NetHost + ':' + IntToStr(NetPort) + ' ' + FClient.Error, 3);
    WritelnLog('GameViewDemo', 'Connection ended: %s', [FClient.Error]);
    FDemo.Finished := True;
  end;
end;

procedure TViewDemo.SendChatLine(const Text: String);
begin
  { A line starting with a slash is a command of the host's console }
  if Copy(Trim(Text), 1, 1) = '/' then
    RunHostCommand(Copy(Trim(Text), 2, MaxInt))
  else
  if FClient <> nil then
    FClient.SendChat(Text);
end;

procedure TViewDemo.RunHostCommand(const Line: String);
var
  Answer: String;
begin
  if ListenServer = nil then
  begin
    FHud.ShowMessage(Tr('Only the host of the game runs commands'), 3);
    WritelnLog('GameViewDemo', 'Host command "%s" refused: not the host', [Line]);
    Exit;
  end;
  Answer := ListenServer.HostCommand(Line, FDemo.ViewEntity);
  if Answer <> '' then
    ConsoleSay(Answer, 4);
end;

procedure TViewDemo.ShowChatLine;
begin
  FHud.ShowMessage(Tr('say:') + ' ' + FChatText + '_', 30);
end;

procedure TViewDemo.WriteRecordBlock(const Data: TBytes);
var
  Len: LongInt;
  Angles: TVector3;
begin
  { A demo block: its length, the view angles, the server's messages }
  Len := Length(Data);
  Angles := FDemo.ViewAngles;
  FRecord.WriteBuffer(Len, SizeOf(Len));
  FRecord.WriteBuffer(Angles, SizeOf(Angles));
  if Len > 0 then
    FRecord.WriteBuffer(Data[0], Len);
  Inc(FRecordBlocks);
end;

procedure TViewDemo.StartNetRecord(const AName: String);
var
  Header: String;
  I: Integer;
begin
  if not NetMode or (AName = '') then
    Exit;
  StopNetRecord;
  FRecord := TMemoryStream.Create;
  FRecordName := AName;
  FRecordBlocks := 0;
  Header := '-1' + #10;
  FRecord.WriteBuffer(Header[1], Length(Header));
  { The level so far: its signon, then everything that comes }
  for I := 0 to FDemo.SignonBlockCount - 1 do
    WriteRecordBlock(FDemo.SignonBlock(I));
  WritelnLog('GameViewDemo', 'Recording the network game to "%s" (%d signon blocks)',
    [FRecordName, FDemo.SignonBlockCount]);
  FHud.ShowMessage(Format(Tr('Recording %s'), [FRecordName]), 2);
end;

procedure TViewDemo.HandleNetBlock(const Data: TBytes);
begin
  if FRecord <> nil then
    WriteRecordBlock(Data);
end;

procedure TViewDemo.StopNetRecord;
var
  Url: String;
  Dest: TStream;
begin
  if FRecord = nil then
    Exit;
  Url := 'castle-config:/' + FRecordName + '.dem';
  try
    Dest := UrlSaveStream(Url);
    try
      FRecord.Position := 0;
      Dest.CopyFrom(FRecord, FRecord.Size);
    finally
      Dest.Free;
    end;
    WritelnLog('GameViewDemo', 'Recorded the network game to "%s": %d blocks, %d bytes',
      [Url, FRecordBlocks, FRecord.Size]);
  except
    on E: Exception do
      WritelnWarning('GameViewDemo', 'Cannot write demo "%s": %s', [Url, E.Message]);
  end;
  FreeAndNil(FRecord);
end;
