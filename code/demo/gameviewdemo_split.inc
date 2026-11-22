{ Split-screen: the local players of a listen server, their viewports, HUDs and input.
  Included by gameviewdemo.pas. }

procedure TSplitViewport.RenderFromViewEverything(const RenderingCamera: TRenderingCamera);
var
  I: Integer;
  Was: array of Boolean;
begin
  Was := nil;
  SetLength(Was, Length(Hidden));
  for I := 0 to High(Hidden) do
    if Hidden[I] <> nil then
    begin
      Was[I] := Hidden[I].Visible;
      Hidden[I].Visible := False;
    end;
  if Assigned(OnBeforeDraw) then
    OnBeforeDraw(Self);
  inherited RenderFromViewEverything(RenderingCamera);
  for I := 0 to High(Hidden) do
    if Hidden[I] <> nil then
      Hidden[I].Visible := Was[I];
end;

constructor TSplitPlayer.Create(const AIndex: Integer);
begin
  inherited Create;
  Index := AIndex;
end;

destructor TSplitPlayer.Destroy;
begin
  if Client <> nil then
    Client.Disconnect;
  FreeAndNil(Client);
  FreeAndNil(Demo);
  inherited Destroy;
end;

procedure TSplitPlayer.HandleCenterPrint(const S: String);
begin
  Hud.ShowMessage(S, 2.5);
end;

procedure TSplitPlayer.HandleDamage(const Armor, Blood: Integer; const From: TVector3);
begin
  Hud.DamageFlash(Armor, Blood);
end;

procedure TSplitPlayer.HandleIntermission;
begin
  Hud.StartIntermission(Demo.LevelName, Math.Max(0.0, Demo.Time - LevelStart),
    Demo.Stats[STAT_MONSTERS], Demo.Stats[STAT_TOTALMONSTERS],
    Demo.Stats[STAT_SECRETS], Demo.Stats[STAT_TOTALSECRETS]);
end;

{ A further split-screen player: its gamepad only (GameInput's player Index) }
procedure TViewDemo.SendSplitInput(const P: TSplitPlayer; const SecondsPassed: Single);
var
  Input: TNetInput;
  PadForward, PadSide: Single;
begin
  if GamepadJustPressed(GamepadNextWeapon, P.Index) then
    P.Impulse := 10;
  if GamepadJustPressed(GamepadPrevWeapon, P.Index) then
    P.Impulse := 12;
  P.InputTime := P.InputTime + SecondsPassed;
  if P.InputTime * 1000 < MinInputMsec then
    Exit;
  Input := Default(TNetInput);
  Inc(P.InputSeq);
  Input.Sequence := P.InputSeq;
  Input.Msec := Min(Round(P.InputTime * 1000), MaxInputMsec);
  P.InputTime := Max(0, P.InputTime - Input.Msec / 1000);
  Input.Angles := P.Demo.ViewAngles;
  GamepadMove(PadForward, PadSide, P.Index);
  Input.Move := Vector3(PadForward * ClForwardSpeed, PadSide * ClSideSpeed, 0);
  if BindingHeld(qbJump, nil, P.Index) then
    Input.Buttons := Input.Buttons or nbJump;
  if BindingHeld(qbFire, nil, P.Index) then
    Input.Buttons := Input.Buttons or nbFire;
  Input.Impulse := EnsureRange(P.Impulse, 0, 255);
  P.Impulse := 0;
  P.Client.SendInput(Input);
end;

{ A further player's camera turns with its pad, the server's angles win
  (spawn, teleport), its input goes out and its view follows its entity }
procedure TViewDemo.UpdateSplitPlayer(const P: TSplitPlayer; const SecondsPassed: Single);
var
  CamDir, Eye, Dir: TVector3;
  Yaw, Pitch, Bob: Single;
  CD: TDemoClientData;
  D: TQuakeDemoReader;
begin
  D := P.Demo;
  UpdateGamepad(P.Index);
  GamepadTurnCamera(P.Camera, SecondsPassed, P.Index);
  CamDir := P.Camera.Direction;
  Yaw := RadToDeg(ArcTan2(-CamDir.Z, CamDir.X));
  Pitch := -RadToDeg(ArcSin(Clamped(CamDir.Y, -1, 1)));
  if D.AngleFixed then
  begin
    Yaw := D.ViewAngles.Y;
    Pitch := D.ViewAngles.X;
    D.AngleFixed := False;
  end;
  D.ViewAngles := Vector3(EnsureRange(Pitch, -89, 89), Yaw, 0);
  if (P.Client <> nil) and (D.Signon = Signons) then
    SendSplitInput(P, SecondsPassed);

  CD := D.ClientData;
  if (D.ViewEntity > 0) and (D.ViewEntity < Length(D.Entities)) then
    Eye := D.Entities[D.ViewEntity].State.Origin + Vector3(0, 0, CD.ViewHeight)
  else
    Eye := TVector3.Zero;
  Pitch := EnsureRange(D.ViewAngles.X + CD.Punch.X, -89, 89);
  Yaw := D.ViewAngles.Y;
  Dir := Vector3(Cos(DegToRad(Yaw)) * Cos(DegToRad(Pitch)), Sin(DegToRad(Yaw)) * Cos(DegToRad(Pitch)),
    -Sin(DegToRad(Pitch)));
  if (D.Intermission = 0) and (D.ViewEntity > 0) then
    Bob := CalcViewBob(D.Time, CD.Velocity)
  else
    Bob := 0;
  P.Camera.SetWorldView(QuakeToCge(Eye + Vector3(0, 0, Bob)), QuakeToCge(Dir), Vector3(0, 1, 0));
  P.WeaponTransform.Translation := Vector3(0, 0, -Bob * 0.4);
  UpdateWeapon(D, P.Weapon, P.WeaponTransform);
end;

function TViewDemo.PlayerOne: Integer;
begin
  if FSplit then
    Result := 1
  else
    Result := 0;
end;

{ One viewport over the window, or one per player: two side by side (the
  first player on the left) or one above the other (the first on top),
  three with the first on top and two below, four in a 2 x 2 grid; each
  view has its HUD }
procedure TViewDemo.ApplySplitLayout;

  procedure MoveHud(const Hud: TQuakeHud; const NewParent: TCastleUserInterface);
  begin
    if Hud.Parent = NewParent then
      Exit;
    if Hud.Parent <> nil then
      Hud.Parent.RemoveControl(Hud);
    NewParent.InsertFront(Hud);
  end;

  procedure Place(const V: TSplitViewport; const W, H: Single; const HP: THorizontalPosition;
    const VP: TVerticalPosition);
  begin
    V.FullSize := False;
    V.WidthFraction := W;
    V.HeightFraction := H;
    V.Anchor(HP);
    V.Anchor(VP);
  end;

var
  I: Integer;
begin
  { At program exit Stop can come after the destructor freed the players }
  if (FViewport = nil) or (FPlayers[2] = nil) then
    Exit;
  for I := 2 to MaxSplitPlayers do
  begin
    FPlayers[I].Viewport.Exists := FSplit and (I <= FSplitCount);
    SetLength(FPlayers[I].Viewport.Hidden, 0);
  end;
  FViewport.FullSize := not FSplit;
  if FSplit then
  begin
    case FSplitCount of
      2: if SplitStacked then
         begin
           Place(FViewport, 1, 0.5, hpLeft, vpTop);
           Place(FPlayers[2].Viewport, 1, 0.5, hpLeft, vpBottom);
         end else
         begin
           Place(FViewport, 0.5, 1, hpLeft, vpBottom);
           Place(FPlayers[2].Viewport, 0.5, 1, hpRight, vpBottom);
         end;
      3: begin
           Place(FViewport, 1, 0.5, hpLeft, vpTop);
           Place(FPlayers[2].Viewport, 0.5, 0.5, hpLeft, vpBottom);
           Place(FPlayers[3].Viewport, 0.5, 0.5, hpRight, vpBottom);
         end;
      else
        begin
          Place(FViewport, 0.5, 0.5, hpLeft, vpTop);
          Place(FPlayers[2].Viewport, 0.5, 0.5, hpRight, vpTop);
          Place(FPlayers[3].Viewport, 0.5, 0.5, hpLeft, vpBottom);
          Place(FPlayers[4].Viewport, 0.5, 0.5, hpRight, vpBottom);
        end;
    end;
    MoveHud(FHud, FViewport);
  end else
  begin
    FViewport.WidthFraction := 0;
    FViewport.HeightFraction := 0;
    MoveHud(FHud, Self);
    { Back in front of the viewport (the touch controls stay on top) }
    if FTouch <> nil then
    begin
      RemoveControl(FTouch);
      InsertFront(FTouch);
    end;
  end;
  SetLength(FViewport.Hidden, 0);
end;

procedure TViewDemo.ConnectSplitPlayers;
var
  I: Integer;
  P: TSplitPlayer;
begin
  if not FSplit then
    Exit;
  for I := 2 to FSplitCount do
  begin
    P := FPlayers[I];
    if P.Client <> nil then
      Continue;
    P.Demo.Free;
    P.Demo := TQuakeDemoReader.Create;
    P.Demo.OnCenterPrint := @P.HandleCenterPrint;
    P.Demo.OnDamage := @P.HandleDamage;
    P.Demo.OnIntermission := @P.HandleIntermission;
    P.Demo.StartNetwork;
    P.InputSeq := 0;
    P.InputTime := 0;
    P.LevelStart := FLevelStart;
    P.Client := TQuakeNetClient.Create;
    if P.Client.Connect('127.0.0.1', NetPort) then
      WritelnLog('GameViewDemo', 'Split-screen: player %d joins on port %d (%s)',
        [I, NetPort, SplitLayoutName(FSplitCount, SplitStacked)])
    else
      FreeAndNil(P.Client);
  end;
end;

procedure TViewDemo.JoinFromPads;
var
  I: Integer;
  Down: Boolean;
begin
  for I := 0 to Min(Controllers.Count, Length(FPadMenuDown)) - 1 do
  begin
    Down := Controllers[I].Pressed[gbMenu];
    if Down and not FPadMenuDown[I] and (PadPlayer(I) = 0) and (FSplitCount < MaxSplitPlayers) then
    begin
      Inc(FSplitCount);
      SplitPlayerCount := FSplitCount;
      WritelnLog('GameViewDemo', 'Split-screen: pad %d (%s) pressed Start: player %d', [I, Controllers[I].Name,
        FSplitCount]);
      ApplySplitLayout;
      ConnectSplitPlayers;
    end;
    FPadMenuDown[I] := Down;
  end;
end;
