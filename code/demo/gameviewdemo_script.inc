{ The console, the test script (--demo), screenshots and photo mode of the demo and network view.
  Included by gameviewdemo.pas. }

procedure TViewDemo.ConsoleSay(const S: String; const Seconds: Single);
begin
  if FConsole <> nil then
    FConsole.Print(S);
  if (FConsole = nil) or not FConsole.IsOpen then
    FHud.ShowMessage(S, Seconds);
end;

procedure TViewDemo.HandleConsoleCommand(const Cmd, Args: String);
begin
  RunConsoleCommand(Trim(Cmd + ' ' + Args));
end;

procedure TViewDemo.RunConsoleCommand(const Line: String);
var
  P: Integer;
  Cmd, Args, Reply, HelpLine: String;
  HelpLines: TStringList;
begin
  P := Pos(' ', Line);
  if P = 0 then
    P := Length(Line) + 1;
  Cmd := Copy(Line, 1, P - 1);
  Args := Trim(Copy(Line, P + 1, MaxInt));
  if Cmd = '' then
    Exit;
  { The settings commands of every view (fov, r_lerpmove...) first }
  if RunSettingsCommand(LowerCase(Cmd), Args, Reply) then
    ConsoleSay(Reply, 3)
  else
  if LowerCase(Cmd) = 'help' then
  begin
    FConsole.Print(Tr('Commands:'));
    FConsole.Print(Tr('  photo <0|1>, photo_fov, photo_effect, photo_scale, photo_shot - Photo mode (demos)'));
    FConsole.Print(Tr('  A network game''s host also runs status, kick, map, timelimit, fraglimit, addbot'));
    HelpLines := TStringList.Create;
    try
      SettingsCommandHelp(HelpLines);
      for HelpLine in HelpLines do
        FConsole.Print(HelpLine);
      WritelnLog('GameViewDemo', 'Console: help (%d settings lines)', [HelpLines.Count]);
    finally
      HelpLines.Free;
    end;
  end else
  { Photo mode's console commands: photo [0|1], photo_fov, photo_effect,
    photo_scale, photo_shot }
  if Cmd = 'photo' then
    SetPhotoMode(Args <> '0')
  else
  if Pos('photo_', Cmd) = 1 then
    FPhoto.Command(Cmd, Args, PhotoPrefix)
  else
  if NetMode then
    { The listen server's host console }
    RunHostCommand(Line)
  else
  begin
    FConsole.Print(Format(Tr('Unknown command: %s'), [Cmd]));
    WritelnLog('GameViewDemo', 'Command not run in a demo: %s', [Line]);
  end;
end;

{ Photo mode in demo playback (not in a network game, which goes on): the
  demo stops, the HUD and the weapon hide, the camera flies }
procedure TViewDemo.SetPhotoMode(const On: Boolean);
begin
  if On and NetMode then
    Exit;
  if On = FPhoto.Active then
    Exit;
  if On then
  begin
    FNavigation.Exists := True;
    FPhoto.Enter;
    FHud.Exists := False;
    if FWeaponTransform <> nil then
      FWeaponTransform.Exists := False;
  end else
  begin
    FPhoto.Leave;
    FHud.Exists := True;
    if FWeaponTransform <> nil then
      FWeaponTransform.Exists := True;
    FNavigation.Exists := NetMode;
    FNavigation.MouseLook := NetMode and (AutoTestPrefix = '');
  end;
end;

function TViewDemo.PhotoPrefix: String;
begin
  if AutoTestPrefix <> '' then
    Result := AutoTestPrefix
  else
    Result := 'castle-quake';
end;

procedure TViewDemo.CaptureScreenshot;
var
  OutPath: String;
  Img: TCastleImage;
  I, Gliding: Integer;
  D: TQuakeDemoReader;
  Eye: TVector3;
begin
  Inc(FShots);
  OutPath := AutoTestPrefix + '_' + IntToStr(FShots) + '.png';
  try
    Img := Container.SaveScreen;
    if Img <> nil then
    begin
      { The browser has no files: the screenshot only logs }
      {$ifndef WASI}
      SaveImage(Img, OutPath);
      {$endif}
      Img.Free;
      WritelnLog('GameViewDemo', 'Saved screenshot to "%s" (signon %d, health %d, ammo %d, frags %d, time %.1f)',
        [OutPath, FDemo.Signon, FDemo.ClientData.Health, FDemo.ClientData.Ammo,
         FDemo.Frags[Max(0, FDemo.ViewEntity - 1) mod 16], FDemo.Time]);
      { The view entity's latest position from the server (Quake units) }
      if (FDemo.ViewEntity > 0) and (FDemo.ViewEntity < Length(FDemo.Entities)) then
        WritelnLog('GameViewDemo', 'View entity %d at %.1f %.1f %.1f (protocol %d)',
          [FDemo.ViewEntity, FDemo.Entities[FDemo.ViewEntity].Msg[0].Origin.X,
           FDemo.Entities[FDemo.ViewEntity].Msg[0].Origin.Y, FDemo.Entities[FDemo.ViewEntity].Msg[0].Origin.Z,
           FDemo.Protocol]);
      { r_lerpmove: the entities between two of their steps }
      Gliding := 0;
      for I := 0 to High(FVisuals) do
        if (FVisuals[I].Transform <> nil) and FVisuals[I].Transform.Exists and FVisuals[I].MoveValid and
           (FDemo.Time - FVisuals[I].MoveStart < ModelLerpTime) and
           not TVector3.PerfectlyEquals(FVisuals[I].MoveFrom, FVisuals[I].MoveTo) then
          Inc(Gliding);
      WritelnLog('GameViewDemo', 'Entities gliding between steps: %d', [Gliding]);
      if (EffectParticles <> nil) and (EffectParticles.Calls > 0) then
      begin
        WritelnLog('GameViewDemo', 'Effect messages: %d (svc_pointparticles, svc_trailparticles)', [FEffectMessages]);
        WritelnLog('GameViewDemo', 'Effect particles: %d drawn, %d made by %d effect calls, %d lights, %d hits of the world',
          [EffectParticles.Count, EffectParticles.Spawned, EffectParticles.Calls, EffectParticles.Lights,
          EffectParticles.Bounces]);
      end;
      if Spectate then
      begin
        Eye := CgeToQuake(FViewport.Camera.Translation);
        if FSpecFree then
          WritelnLog('GameViewDemo', 'Spectator: flying freely, eye at %.1f %.1f %.1f', [Eye.X, Eye.Y, Eye.Z])
        else
          WritelnLog('GameViewDemo', 'Spectator: following entity %d, eye at %.1f %.1f %.1f',
            [FDemo.ViewEntity, Eye.X, Eye.Y, Eye.Z]);
      end;
      { The further players: their entity, and the first view's and their own size }
      for I := 2 to FSplitCount do
      begin
        D := FPlayers[I].Demo;
        if (D <> nil) and (D.ViewEntity > 0) and (D.ViewEntity < Length(D.Entities)) then
          WritelnLog('GameViewDemo', 'Player %d: view entity %d at %.1f %.1f %.1f, yaw %.0f, health %d, ammo %d, ' +
            'weapon %d, signon %d, viewports %.0fx%.0f and %.0fx%.0f',
            [I, D.ViewEntity, D.Entities[D.ViewEntity].Msg[0].Origin.X,
             D.Entities[D.ViewEntity].Msg[0].Origin.Y, D.Entities[D.ViewEntity].Msg[0].Origin.Z,
             D.ViewAngles.Y, D.ClientData.Health, D.ClientData.Ammo, D.ClientData.ActiveWeapon,
             D.Signon, FViewport.EffectiveWidth, FViewport.EffectiveHeight,
             FPlayers[I].Viewport.EffectiveWidth, FPlayers[I].Viewport.EffectiveHeight]);
      end;
      if FSplit and (FGeometry <> nil) then
        WritelnLog('GameViewDemo', 'Split-screen PVS: leaves %d and %d, %d of %d clusters, %d of %d entities drawn',
          [FGeometry.CameraLeaf, FGeometry.SecondLeaf, FGeometry.VisibleClusters, FGeometry.ClusterCount,
           FGeometry.VisibleEntities, FGeometry.EntityCount]);
      if FWsRelay <> nil then
        WritelnLog('GameViewDemo', 'WebSocket relay: %d clients, %d messages in, %d out',
          [FWsRelay.ClientCount, FWsRelay.MessagesIn, FWsRelay.MessagesOut]);
      if NetMode and (FPredict <> nil) and (FDemo.ViewEntity > 0) and (FDemo.ViewEntity < Length(FDemo.Entities)) then
        WritelnLog('GameViewDemo', 'Prediction %s: predicted %s, server %s, error %.1f (max %.1f), %d inputs pending',
          [BoolToStr(PredictionActive, 'on', 'off'), FPredict.Origin.ToString,
           FDemo.Entities[FDemo.ViewEntity].Msg[0].Origin.ToString, FPredictError, FPredictErrorMax, Length(FHistory)]);
    end;
  except
    on E: Exception do
      WritelnWarning('GameViewDemo', 'Failed to save screenshot "%s": %s', [OutPath, E.Message]);
  end;
end;

procedure TViewDemo.RunScript(const SecondsPassed: Single);
var
  Cmd, Action, Param: String;
  P: Integer;
  Parts: TStringArray;
begin
  while FScriptIndex < FScript.Count do
  begin
    Cmd := FScript[FScriptIndex];
    P := Pos(':', Cmd);
    if P > 0 then
    begin
      Action := UpperCase(Copy(Cmd, 1, P - 1));
      Param := Copy(Cmd, P + 1, MaxInt);
    end else
    begin
      Action := UpperCase(Cmd);
      Param := '';
    end;
    if Action = 'W' then
    begin
      FScriptTimer := FScriptTimer + SecondsPassed;
      if FScriptTimer < StrToFloatDef(Param, 1.0) then
        Exit;
      FScriptTimer := 0;
    end else
    if Action = 'WL' then
    begin
      { Wait for a log line with this text }
      if ScriptWaitsForLog(Param, SecondsPassed, FScriptTimer) then
        Exit;
    end else
    if Action = 'S' then
      CaptureScreenshot
    else if Action = 'NC' then
      ComparePvsRender
    else if Action = 'X' then
      FFireHeld := 0.05
    else if Action = 'F' then
      FFireHeld := StrToFloatDef(Param, 1.0)
    else if Action = 'C' then
      FImpulse := StrToIntDef(Param, 2)
    else if Action = 'K' then
      FImpulse := 9
    else if Action = 'A' then
      SetViewAngles(StrToFloatDef(Param, 0), FDemo.ViewAngles.X)
    else if Action = 'T' then
      SetViewAngles(FDemo.ViewAngles.Y + StrToFloatDef(Param, 0), FDemo.ViewAngles.X)
    else if Action = 'P' then
      SetViewAngles(FDemo.ViewAngles.Y, -StrToFloatDef(Param, 0))
    else if Action = 'V' then
    begin
      Parts := Param.Split([';']);
      FScriptMove := TVector3.Zero;
      for P := 0 to Min(High(Parts), 2) do
        FScriptMove.Data[P] := StrToFloatDef(Parts[P], 0);
    end else
    if Action = 'J' then
      FScriptJump := 0.1
    else
    if (Action = 'GL') or (Action = 'GR') then
    begin
      { The virtual gamepad (in split-screen the second player's): sticks
        x;y in -1..1, the right trigger, a button pressed for 0.2 s }
      Parts := Param.Split([';']);
      if Length(Parts) >= 2 then
      begin
        if Action = 'GL' then
          FPadLeft := Vector2(StrToFloatDef(Parts[0], 0), StrToFloatDef(Parts[1], 0))
        else
          FPadRight := Vector2(StrToFloatDef(Parts[0], 0), StrToFloatDef(Parts[1], 0));
        SetVirtualSticks(FPadLeft, FPadRight);
      end;
    end else
    if Action = 'GT' then
      SetVirtualRightTrigger(StrToFloatDef(Param, 0))
    else
    if Action = 'GB' then
    begin
      if GamepadButtonByName(Param, FPadButton) then
      begin
        SetVirtualButton(FPadButton, True);
        FPadRelease := 0.2;
      end else
        WritelnWarning('GameViewDemo', 'Unknown gamepad button "%s"', [Param]);
    end else
    if Action = 'PN' then
      SetVirtualPadName(Param)
    else
    if Action = 'PADS' then { How many virtual pads (split-screen players) }
      SetVirtualPadCount(StrToIntDef(Param, 1))
    else
    if Action = 'PAD' then { The virtual pad GL, GR, GT and GB drive }
    begin
      VirtualPadIndex := EnsureRange(StrToIntDef(Param, 0), 0, Max(0, Controllers.Count - 1));
      FPadLeft := TVector2.Zero;
      FPadRight := TVector2.Zero;
    end else
    if Action = 'CMD' then
    begin
      RunConsoleCommand(Param);
    end else
    if (Action = 'SB') and NetMode then { Log the scoreboard (and show it a moment) }
      WritelnLog('GameViewDemo', 'Scoreboard: %s', [ScoreboardLog])
    else
    if (Action = 'SAY') and NetMode then { A line of chat }
    begin
      SendChatLine(Param);
    end else
    if (Action = 'R') and NetMode then { Record the network game (R:name), stop (R) }
    begin
      if Param <> '' then
        StartNetRecord(Param)
      else
        StopNetRecord;
    end else
    if Action = 'DP' then { Demo playback: pause / go on }
      ToggleDemoPause
    else
    if Action = 'DS' then { Demo playback speed }
      SetDemoSpeed(StrToFloatDef(Param, 1))
    else
    if Action = 'DK' then { Seek: to a second of the demo, or +N / -N from here }
    begin
      if (Param <> '') and (Param[1] in ['+', '-']) then
        SeekDemo(FPlayClock + StrToFloatDef(Param, 0))
      else
        SeekDemo(StrToFloatDef(Param, 0));
    end else
    if (Action = 'M') and FPhoto.Active then
      FViewport.Camera.Translation := FViewport.Camera.Translation +
        FViewport.Camera.Direction * StrToFloatDef(Param, 50)
    else
    if Action = 'Q' then
    begin
      StopNetRecord;
      Application.Terminate;
      Exit;
    end;
    Inc(FScriptIndex);
  end;
end;
