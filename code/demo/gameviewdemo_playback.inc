{ Demo playback controls: pause, speed, seek, the length of a demo.
  Included by gameviewdemo.pas. }

procedure TViewDemo.MeasureDemoLength;
const
  Step = 0.05;
var
  Probe: TQuakeDemoReader;
begin
  { A second reader without events plays the demo through once }
  Probe := TQuakeDemoReader.Create;
  try
    if Probe.Load(DemoName) then
      while not Probe.Finished and (FDemoLength < 4 * 3600) do
      begin
        Probe.Advance(Step);
        FDemoLength := FDemoLength + Step;
      end;
  finally
    Probe.Free;
  end;
  WritelnLog('GameViewDemo', 'Demo "%s": %.1f s', [DemoName, FDemoLength]);
end;

procedure TViewDemo.ToggleDemoPause;
begin
  if NetMode then
    Exit;
  FDemoPaused := not FDemoPaused;
  if FDemoPaused then
    WritelnLog('GameViewDemo', 'Demo paused at %.2f of %.1f (time %.2f)', [FPlayClock, FDemoLength, FDemo.Time])
  else
    WritelnLog('GameViewDemo', 'Demo goes on at %.2f (time %.2f)', [FPlayClock, FDemo.Time]);
  ShowDemoStatus;
end;

procedure TViewDemo.SetDemoSpeed(const Speed: Single);
begin
  if NetMode then
    Exit;
  FDemoSpeed := EnsureRange(Speed, 0.25, 4);
  WritelnLog('GameViewDemo', 'Demo speed %s', [FormatFloat('0.##', FDemoSpeed)]);
  ShowDemoStatus;
end;

procedure TViewDemo.SeekDemo(const Target: Single);
const
  Step = 0.05;
var
  Goal, From: Single;
  Restarted: Boolean;
  Origin: TVector3;
begin
  if NetMode or FPhoto.Active then
    Exit;
  Goal := EnsureRange(Target, 0, Max(0, FDemoLength - Step));
  From := FPlayClock;
  Restarted := Goal < FPlayClock;
  FSeeking := True;
  try
    { Back: the demo starts again from its first message (and its level) }
    if Restarted then
    begin
      FLoaded := False;
      FPlayClock := 0;
      if not FDemo.Load(DemoName) then
      begin
        FDemo.Finished := True;
        Exit;
      end;
    end;
    while (FPlayClock + Step <= Goal + Step / 2) and not FDemo.Finished do
    begin
      FDemo.Advance(Step);
      FPlayClock := FPlayClock + Step;
      { The level timer starts when the connection is complete, as in Update }
      if FLoaded and (FLevelStart < 0) and (FDemo.Signon = Signons) then
        FLevelStart := FDemo.Time;
    end;
  finally
    FSeeking := False;
  end;
  FFinishedTimer := 0;
  Origin := TVector3.Zero;
  if (FDemo.ViewEntity > 0) and (FDemo.ViewEntity < Length(FDemo.Entities)) then
    Origin := FDemo.Entities[FDemo.ViewEntity].State.Origin;
  WritelnLog('GameViewDemo', 'Demo seek from %.2f to %.2f (%s): at %.2f, time %.2f, view entity at %.1f %.1f %.1f',
    [From, Goal, BoolToStr(Restarted, 'from the start', 'forward'), FPlayClock, FDemo.Time,
     Origin.X, Origin.Y, Origin.Z]);
  ShowDemoStatus;
end;
