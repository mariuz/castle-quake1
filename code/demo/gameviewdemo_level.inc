{ The level of a demo or a network game and the entities drawn in it.
  Included by gameviewdemo.pas. }

{ What the PVS shows, and the entities in it; split-screen: one world for
  every camera, so what any of their PVS has }
procedure TViewDemo.UpdateWorldVisibility;
var
  Eyes: array of TVector3;
  I: Integer;
begin
  if FSplit then
  begin
    Eyes := nil;
    SetLength(Eyes, FSplitCount);
    Eyes[0] := FViewport.Camera.Translation;
    for I := 2 to FSplitCount do
      Eyes[I - 1] := FPlayers[I].Camera.Translation;
    FGeometry.UpdateVisibilityAll(Eyes);
  end else
    FGeometry.UpdateVisibility(FViewport.Camera.Translation);
  CullVisuals;
end;

{ The NC action: this frame drawn with the PVS culling and without it; no
  pixel may differ but a lone one in a crack between faces (in
  split-screen every view is in the window) }
procedure TViewDemo.ComparePvsRender;
var
  Culled, Full: TRGBImage;
  WasCulling: Boolean;
  Differ, Total, Alone: Integer;
  Status: String;

  function Render(const Culling: Boolean): TRGBImage;
  begin
    WorldPvsCulling := Culling;
    UpdateWorldVisibility;
    if Culling then
      Status := Format('leaves %d and %d, clusters %d/%d, entities %d/%d, %d views', [FGeometry.CameraLeaf,
        FGeometry.SecondLeaf, FGeometry.VisibleClusters, FGeometry.ClusterCount, FGeometry.VisibleEntities,
        FGeometry.EntityCount, FSplitCount]);
    Result := Container.SaveScreen;
  end;

begin
  if FGeometry = nil then
    Exit;
  WasCulling := WorldPvsCulling;
  Culled := Render(True);
  Full := Render(False);
  try
    { Pixels where a channel differs by more than 24 of 255 }
    Total := Min(Culled.Width, Full.Width) * Min(Culled.Height, Full.Height);
    Differ := ComparePvsImages(Culled, Full, Alone);
    WritelnLog('GameViewDemo', 'PVS compare: %d of %d pixels differ (%d alone), %s', [Differ, Total, Alone, Status]);
    if (Differ > 0) and (AutoTestPrefix <> '') then
    begin
      { Named after the next screenshot, whose number stays the same }
      {$ifndef WASI}
      SaveImage(Culled, AutoTestPrefix + '_' + IntToStr(FShots + 1) + '_pvs.png');
      SaveImage(Full, AutoTestPrefix + '_' + IntToStr(FShots + 1) + '_full.png');
      {$endif}
    end;
  finally
    Culled.Free;
    Full.Free;
    WorldPvsCulling := WasCulling;
    UpdateWorldVisibility;
  end;
end;

{ Each split-screen view projects the scrolling sky from its own eye }
procedure TViewDemo.ViewportBeforeDraw(Sender: TObject);
begin
  if FSplit and (FGeometry <> nil) then
    FGeometry.SetSkyEye(TCastleViewport(Sender).Camera.Translation);
end;

procedure TViewDemo.CullVisuals;
var
  I: Integer;
begin
  for I := 0 to High(FVisuals) do
    if (FVisuals[I].Transform <> nil) and FVisuals[I].Transform.Exists then
      FGeometry.CullScene(FVisuals[I].Scene);
  for I := 0 to High(FStaticVisuals) do
    if (FStaticVisuals[I].Transform <> nil) and FStaticVisuals[I].Transform.Exists then
      FGeometry.CullScene(FStaticVisuals[I].Scene);
  FGeometry.CullSubmodels;
end;

procedure TViewDemo.ClearLevel;
var
  I: Integer;
begin
  { Before the first Start there is nothing to clear }
  if FRenderer = nil then
    Exit;
  for I := 0 to High(FVisuals) do
    FRenderer.FreeVisual(FVisuals[I]);
  for I := 0 to High(FStaticVisuals) do
    FRenderer.FreeVisual(FStaticVisuals[I]);
  SetLength(FStaticVisuals, 0);
  FRenderer.FreeVisual(FWeapon);
  for I := 2 to MaxSplitPlayers do
    if FPlayers[I] <> nil then
    begin
      FRenderer.FreeVisual(FPlayers[I].Weapon);
      if FPlayers[I].Viewport <> nil then
        SetLength(FPlayers[I].Viewport.Hidden, 0);
    end;
  if FViewport <> nil then
    SetLength(FViewport.Hidden, 0);
  FRenderer.ClearBeams;
  FRenderer.ClearSubmodels;
  FreeAndNil(FPredict);
  SetLength(FHistory, 0);
  FPredictValid := False;
  { At program exit the managers may be gone already }
  if (FAmbient <> nil) and (Sounds <> nil) then
    FAmbient.Clear;
  if Particles <> nil then
    Particles.Clear;
  if EffectParticles <> nil then
    EffectParticles.Clear;
  if Lighting <> nil then
    Lighting.Clear;
  FreeAndNil(FGeometry);
  FreeAndNil(FBsp);
  FLoaded := False;
end;

procedure TViewDemo.LoadLevel;
var
  World: TQuakeEntity;
begin
  ClearLevel;
  ResetComponentNames;
  FBsp := TQuakeBsp.Create;
  if not FBsp.LoadFromPak(FDemo.ModelName(1)) then
  begin
    WritelnWarning('GameViewDemo', 'Cannot load the demo map "%s"', [FDemo.ModelName(1)]);
    FreeAndNil(FBsp);
    FDemo.Finished := True;
    Exit;
  end;
  FGeometry := TQuakeGeometry.Create(FBsp);
  FGeometry.AddToWorld(FViewport.Items);
  ApplyWorldFog(FViewport, FGeometry);
  Lighting.CreateLightsFromBsp(FBsp, FViewport.Items);
  Lighting.ResetStyles;
  FAmbient.Setup(FBsp, FViewport.Items);

  { Brush entities are placed by the demo; hidden until it does }
  FRenderer.SetupSubmodels(FGeometry, FBsp.ModelCount);
  if NetMode then
  begin
    FPredict := TQuakePlayerPhysics.Create;
    FPredict.Bsp := FBsp;
    FPredict.Mins := Vector3(-16, -16, -24);
    FPredict.Maxs := Vector3(16, 16, 32);
    FPredict.ViewHeight := 22;
    FPredictValid := False;
    SetLength(FHistory, 0);
  end;
  FLevelStart := -1;
  FLoaded := True;
  { The map's CD track until the server's svc_cdtrack says otherwise }
  World := FBsp.FindEntity('worldspawn');
  if (World <> nil) and (World.Sounds > 0) then
    Sounds.PlayTrack(World.Sounds)
  else
    Sounds.PlayMusic('track02.ogg');
  FHud.StopIntermission;
  FHud.ShowMessage(FDemo.LevelName, 3);
end;

procedure TViewDemo.ApplyEnvironment;
begin
  { FitzQuake's svc_fog / svc_skybox (and a stuffed fog command) replace the
    map's own worldspawn fog and sky applied when the level was loaded }
  if FDemo.FogChanged then
  begin
    FDemo.FogChanged := False;
    SetViewportFog(FViewport, FDemo.FogDensity, FDemo.FogColor);
    if FDemo.FogDensity <= 0 then
      WritelnLog('GameViewDemo', 'Fog: off');
  end;
  if FDemo.SkyboxChanged then
  begin
    FDemo.SkyboxChanged := False;
    if FGeometry <> nil then
      FGeometry.SetSkybox(FDemo.SkyboxName);
  end;
end;

procedure TViewDemo.ShowVisual(var V: TDemoVisual; const State: TDemoEntityState; const Dt: Single);
var
  Colors: Integer;
  Alpha: Single;
  DrawOrigin, DrawAngles: TVector3;
begin
  { A player's entity (colormap = its client number) in that client's colors }
  Colors := 0;
  if (State.ColorMap >= 1) and (State.ColorMap <= Length(FDemo.Colors)) then
    Colors := FDemo.Colors[State.ColorMap - 1];
  { A stepping monster glides between its steps (r_lerpmove); the rest are
    already interpolated between the server's frames }
  FRenderer.LerpMove(V, State.Origin, State.Angles, State.Step, FDemo.Time, DrawOrigin, DrawAngles);
  FRenderer.Show(V, FDemo.ModelName(State.ModelIndex), DrawOrigin, DrawAngles, State.Frame, State.Skin,
    State.Effects, Colors, FDemo.Time, Dt);
  { The protocol's alpha byte: 0 is opaque, 1 invisible, 255 opaque }
  if State.Alpha = 0 then
    Alpha := 0
  else
    Alpha := Max(DecodeEntityAlpha(State.Alpha), 0.001);
  FRenderer.ApplyAlpha(V, Alpha);
end;

procedure TViewDemo.UpdateWeapon(const Reader: TQuakeDemoReader; var Weapon: TDemoVisual;
  const Holder: TCastleTransform);
var
  MdlName: String;
  Mdl: TQuakeMdl;
  Idx: Integer;
begin
  Idx := Reader.ClientData.Weapon;
  MdlName := Reader.ModelName(Idx);
  if (MdlName = '') or (Reader.Intermission <> 0) or (Reader.ClientData.Health <= 0) then
  begin
    FRenderer.Hide(Weapon);
    Exit;
  end;
  Mdl := MdlManager.GetModel(MdlName);
  if Mdl = nil then
  begin
    FRenderer.Hide(Weapon);
    Exit;
  end;
  if (Weapon.Transform = nil) or (Weapon.Model <> MdlName) then
  begin
    FRenderer.FreeVisual(Weapon);
    Weapon.Transform := TCastleTransform.Create(nil);
    Weapon.Transform.Name := 'weapon_model';
    Weapon.Scene := Mdl.CreateScene(0);
    Weapon.Scene.Name := 'weapon_model_scene';
    Weapon.Scene.Collides := False;
    Weapon.Transform.Add(Weapon.Scene);
    Holder.Add(Weapon.Transform);
    Weapon.Mdl := Mdl;
    Weapon.Model := MdlName;
    Weapon.Frame := -1;
  end;
  Weapon.Transform.Exists := ShowWeapon;
  if Weapon.Frame <> Reader.ClientData.WeaponFrame then
  begin
    Weapon.Frame := Reader.ClientData.WeaponFrame;
    Mdl.ApplyFrame(Weapon.Scene, EnsureRange(Weapon.Frame, 0, Max(0, Mdl.FrameCount - 1)));
  end;
end;

function TViewDemo.VisualTransform(const Entity: Integer): TCastleTransform;
begin
  if (Entity > 0) and (Entity <= High(FVisuals)) then
    Result := FVisuals[Entity].Transform
  else
    Result := nil;
end;
