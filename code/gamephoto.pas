{ Photo mode: the game paused, the camera flying free (no collisions), no
  HUD or view weapon, a field of view and a screen effect of one's own
  (depth of field, grayscale, sepia, vignette, the engine's ambient
  occlusion), and a photo rendered off-screen at a multiple of the window
  size. Used by the play view and the demo player. }
unit GamePhoto;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math,
  CastleVectors, CastleUIControls, CastleControls, CastleViewport, CastleKeysMouse,
  CastleCameras, CastleImages, CastleRectangles, CastleComponentSerialize,
  CastleGameControllers, X3DNodes, X3DFields, CastleRenderOptions;

type
  TPhotoEffect = (peNone, peDepthOfField, peGrayscale, pePhotoSepia, peVignette, peAmbientOcclusion);

  TPhotoMode = class(TComponent)
  private
    FViewport: TCastleViewport;
    FNavigation: TCastleWalkNavigation;
    FActive: Boolean;
    FFov: Single;
    FEffect: TPhotoEffect;
    FScale: Integer;
    FDesign: TCastleUserInterface;
    FLabel, FStatusLabel: TCastleLabel;
    FStatusTime: Single;
    FEffects: array[TPhotoEffect] of TScreenEffectNode;
    FDofNear, FDofFar, FDofAperture: TSFFloat;
    { The camera and the navigation as they were when photo mode began }
    FSavedPos, FSavedDir, FSavedUp: TVector3;
    FSavedMoveSpeed: Single;
    FSavedCollisions: Boolean;
    FCount: Integer;
    procedure CreateEffects;
    procedure ApplyEffect;
    procedure SetEffect(const Value: TPhotoEffect);
    procedure SetFov(const Value: Single);
    procedure SetScale(const Value: Integer);
    procedure ShowStatus(const S: String);
    procedure UpdateLabel;
  public
    { The photo's field of view and the depth of field's planes on the
      camera (after GameVideo's ApplyVideoSettings, before rendering) }
    procedure ApplyView;
    { Viewport: the camera to fly and render; Parent: where the help line is
      shown (the view); Navigation: its mouse look keeps working }
    constructor Create(const AOwner: TComponent; const AViewport: TCastleViewport;
      const Parent: TCastleUserInterface; const ANavigation: TCastleWalkNavigation); reintroduce;
    procedure Enter;
    procedure Leave;
    { Flies the camera (the movement bindings, the gamepad's left stick and
      the touch stick; jump goes up, walk goes down) and applies the field
      of view after GameVideo's }
    procedure Update(const SecondsPassed: Single);
    { Photo mode's keys: the wheel or [ ] the field of view, Tab the effect,
      + / - the photo size, Enter or the screenshot binding a photo, R
      resets; True when used }
    function Press(const Event: TInputPressRelease): Boolean;
    { Renders the viewport alone at Scale x the window into a PNG at
      FileName (only logged on the web); the name, or '' on failure }
    function TakePhoto(const FileName: String): String;
    { A console command: photo_fov, photo_effect, photo_scale, photo_shot;
      the reply to print }
    function Command(const Cmd, Args: String; const ShotPrefix: String): String;
    function NextPhotoName(const Prefix: String): String;
    property Active: Boolean read FActive;
    property Fov: Single read FFov write SetFov;
    property Effect: TPhotoEffect read FEffect write SetEffect;
    property Scale: Integer read FScale write SetScale;
  end;

{ The viewport alone (no HUD or menu) rendered off-screen into a W x H
  image (the caller frees it); nil when the viewport has no container }
function RenderViewportImage(const Viewport: TCastleViewport; const W, H: Integer): TCastleImage;

const
  PhotoEffectNames: array[TPhotoEffect] of String = (
    'none', 'dof', 'gray', 'sepia', 'vignette', 'ao');
  PhotoEffectCaptions: array[TPhotoEffect] of String = (
    'No effect', 'Depth of field', 'Grayscale', 'Sepia', 'Vignette', 'Ambient occlusion');

implementation

uses
  CastleLog, CastleGLImages, CastleGLUtils, CastleUtils, CastleTransform,
  GameInput, GameVideo, GameTouch;

const
  FlySpeed = 320;
  DefaultPhotoScale = 2;

  { Depth of field: the depth at the middle of the screen is in focus; a
    pixel's blur grows with its distance from that plane over its own
    distance (like a lens' circle of confusion), a disk of up to 10 pixels
    at 900 lines }
  DofShader =
    'uniform float photo_near;' + LineEnding +
    'uniform float photo_far;' + LineEnding +
    'uniform float photo_aperture;' + LineEnding +
    'float photo_linear(float d)' + LineEnding +
    '{' + LineEnding +
    '  float z = d * 2.0 - 1.0;' + LineEnding +
    '  if (photo_far <= 0.0)' + LineEnding +
    '    return 2.0 * photo_near / max(1.0 - z, 1e-6);' + LineEnding +
    '  return 2.0 * photo_near * photo_far / (photo_far + photo_near - z * (photo_far - photo_near));' + LineEnding +
    '}' + LineEnding +
    'void main(void)' + LineEnding +
    '{' + LineEnding +
    '  vec2 center = vec2(float(screen_width), float(screen_height)) * 0.5;' + LineEnding +
    '  float focus = photo_linear(screenf_get_depth(center));' + LineEnding +
    '  float here = photo_linear(screenf_get_depth(screenf_position()));' + LineEnding +
    '  float blur = clamp(abs(here - focus) / max(here, 1.0) * photo_aperture, 0.0, 1.0);' + LineEnding +
    '  float radius = blur * 10.0 * float(screen_height) / 900.0;' + LineEnding +
    '  vec4 sum = screenf_get_original_color();' + LineEnding +
    '  for (int i = 1; i < 16; i++)' + LineEnding +
    '  {' + LineEnding +
    '    float a = float(i) * 2.39996;' + LineEnding +
    '    float r = sqrt(float(i) / 15.0) * radius;' + LineEnding +
    '    sum += screenf_get_color(screenf_position() + vec2(cos(a), sin(a)) * r);' + LineEnding +
    '  }' + LineEnding +
    '  gl_FragColor = sum / 16.0;' + LineEnding +
    '}' + LineEnding;

  GrayShader =
    'void main(void)' + LineEnding +
    '{' + LineEnding +
    '  vec4 c = screenf_get_original_color();' + LineEnding +
    '  float l = dot(c.rgb, vec3(0.299, 0.587, 0.114));' + LineEnding +
    '  gl_FragColor = vec4(vec3(l), c.a);' + LineEnding +
    '}' + LineEnding;

  SepiaShader =
    'void main(void)' + LineEnding +
    '{' + LineEnding +
    '  vec4 c = screenf_get_original_color();' + LineEnding +
    '  vec3 s = vec3(dot(c.rgb, vec3(0.393, 0.769, 0.189)), dot(c.rgb, vec3(0.349, 0.686, 0.168)),' + LineEnding +
    '    dot(c.rgb, vec3(0.272, 0.534, 0.131)));' + LineEnding +
    '  gl_FragColor = vec4(min(s, vec3(1.0)), c.a);' + LineEnding +
    '}' + LineEnding;

  VignetteShader =
    'void main(void)' + LineEnding +
    '{' + LineEnding +
    '  vec4 c = screenf_get_original_color();' + LineEnding +
    '  vec2 p = screenf_01_position - vec2(0.5);' + LineEnding +
    '  float v = smoothstep(0.85, 0.3, length(p * vec2(1.0, float(screen_height) / float(screen_width))) * 1.4);' + LineEnding +
    '  gl_FragColor = vec4(c.rgb * mix(0.25, 1.0, v), c.a);' + LineEnding +
    '}' + LineEnding;

constructor TPhotoMode.Create(const AOwner: TComponent; const AViewport: TCastleViewport;
  const Parent: TCastleUserInterface; const ANavigation: TCastleWalkNavigation);
begin
  inherited Create(AOwner);
  FViewport := AViewport;
  FNavigation := ANavigation;
  FFov := VideoFov;
  FScale := DefaultPhotoScale;
  FDesign := UserInterfaceLoad('castle-data:/ui/photo.castle-user-interface', Self);
  FDesign.Exists := False;
  Parent.InsertFront(FDesign);
  FLabel := FindRequiredComponent('PhotoLabel') as TCastleLabel;
  FStatusLabel := FindRequiredComponent('PhotoStatusLabel') as TCastleLabel;
end;

procedure TPhotoMode.CreateEffects;

  function Make(const Source: String; const NeedsDepth: Boolean): TScreenEffectNode;
  var
    Part: TShaderPartNode;
    Shader: TComposedShaderNode;
  begin
    Part := TShaderPartNode.Create;
    Part.ShaderType := stFragment;
    Part.Contents := Source;
    Shader := TComposedShaderNode.Create;
    Shader.SetParts([Part]);
    if Source = DofShader then
    begin
      FDofNear := TSFFloat.Create(Shader, True, 'photo_near', 1);
      Shader.AddCustomField(FDofNear);
      FDofFar := TSFFloat.Create(Shader, True, 'photo_far', 0);
      Shader.AddCustomField(FDofFar);
      FDofAperture := TSFFloat.Create(Shader, True, 'photo_aperture', 1.2);
      Shader.AddCustomField(FDofAperture);
    end;
    Result := TScreenEffectNode.Create;
    Result.NeedsDepth := NeedsDepth;
    Result.SetShaders([Shader]);
    Result.Enabled := False;
    FViewport.AddScreenEffect(Result);
  end;

begin
  if FEffects[peDepthOfField] <> nil then
    Exit;
  FEffects[peDepthOfField] := Make(DofShader, True);
  FEffects[peGrayscale] := Make(GrayShader, False);
  FEffects[pePhotoSepia] := Make(SepiaShader, False);
  FEffects[peVignette] := Make(VignetteShader, False);
end;

procedure TPhotoMode.ApplyEffect;
var
  E: TPhotoEffect;
begin
  CreateEffects;
  for E := Low(TPhotoEffect) to High(TPhotoEffect) do
    if FEffects[E] <> nil then
      FEffects[E].Enabled := FActive and (E = FEffect);
  FViewport.ScreenSpaceAmbientOcclusion := FActive and (FEffect = peAmbientOcclusion);
end;

procedure TPhotoMode.SetEffect(const Value: TPhotoEffect);
begin
  FEffect := Value;
  ApplyEffect;
  ShowStatus(PhotoEffectCaptions[FEffect]);
end;

procedure TPhotoMode.SetFov(const Value: Single);
begin
  FFov := EnsureRange(Value, 10, 150);
  ShowStatus(Format('Field of view %d', [Round(FFov)]));
end;

procedure TPhotoMode.SetScale(const Value: Integer);
begin
  FScale := EnsureRange(Value, 1, 4);
  ShowStatus(Format('Photo size %dx', [FScale]));
end;

procedure TPhotoMode.ShowStatus(const S: String);
begin
  FStatusLabel.Caption := S;
  FStatusTime := 2.5;
  UpdateLabel;
end;

procedure TPhotoMode.UpdateLabel;
var
  W, H: Integer;
begin
  W := 0;
  H := 0;
  if FViewport.Container <> nil then
  begin
    W := FViewport.Container.PixelsWidth * FScale;
    H := FViewport.Container.PixelsHeight * FScale;
  end;
  FLabel.Caption := Format('PHOTO MODE   fov %d (wheel, [ ])   %s (Tab)   photo %dx%d (+ -)   ' +
    'Enter: take a photo   R: reset   Esc: back', [Round(FFov), PhotoEffectCaptions[FEffect], W, H]);
end;

procedure TPhotoMode.Enter;
begin
  if FActive then
    Exit;
  FActive := True;
  FSavedPos := FViewport.Camera.Translation;
  FSavedDir := FViewport.Camera.Direction;
  FSavedUp := FViewport.Camera.Up;
  FSavedMoveSpeed := FNavigation.MoveSpeed;
  FSavedCollisions := FNavigation.CheckCollisions;
  { The view's own flying; the navigation only looks around }
  FNavigation.MoveSpeed := 0;
  FNavigation.CheckCollisions := False;
  FNavigation.MouseLook := not TouchControlsWanted;
  FViewport.Items.Paused := True;
  FFov := VideoFov;
  FDesign.Exists := True;
  ApplyEffect;
  UpdateLabel;
  FStatusLabel.Caption := '';
  WritelnLog('Photo', 'Photo mode on at %s', [FViewport.Camera.Translation.ToString]);
end;

procedure TPhotoMode.Leave;
begin
  if not FActive then
    Exit;
  FActive := False;
  FViewport.Camera.SetWorldView(FSavedPos, FSavedDir, FSavedUp);
  FNavigation.MoveSpeed := FSavedMoveSpeed;
  FNavigation.CheckCollisions := FSavedCollisions;
  FViewport.Items.Paused := False;
  FDesign.Exists := False;
  ApplyEffect;
  WritelnLog('Photo', 'Photo mode off');
end;

procedure TPhotoMode.Update(const SecondsPassed: Single);
var
  Forward, Side, Up: Single;
  PadForward, PadSide: Single;
  Dir, Right: TVector3;
  Container: TCastleContainer;
begin
  if not FActive then
    Exit;
  Container := FViewport.Container;
  Forward := 0;
  Side := 0;
  Up := 0;
  if Container <> nil then
  begin
    if BindingHeld(qbForward, Container) then
      Forward := Forward + 1;
    if BindingHeld(qbBackward, Container) then
      Forward := Forward - 1;
    if BindingHeld(qbStrafeRight, Container) then
      Side := Side + 1;
    if BindingHeld(qbStrafeLeft, Container) then
      Side := Side - 1;
    if BindingHeld(qbJump, Container) then
      Up := Up + 1;
    if BindingHeld(qbWalk, Container) then
      Up := Up - 1;
  end;
  GamepadMove(PadForward, PadSide);
  Forward := EnsureRange(Forward + PadForward, -1, 1);
  Side := EnsureRange(Side + PadSide, -1, 1);
  GamepadTurnCamera(FViewport.Camera, SecondsPassed);
  if (Forward <> 0) or (Side <> 0) or (Up <> 0) then
  begin
    Dir := FViewport.Camera.Direction;
    Right := TVector3.CrossProduct(Dir, Vector3(0, 1, 0));
    if not Right.IsPerfectlyZero then
      Right := Right.Normalize;
    FViewport.Camera.Translation := FViewport.Camera.Translation +
      (Dir * Forward + Right * Side + Vector3(0, Up, 0)) * FlySpeed * SecondsPassed;
  end;

  ApplyView;
  if FStatusTime > 0 then
  begin
    FStatusTime := FStatusTime - SecondsPassed;
    if FStatusTime <= 0 then
      FStatusLabel.Caption := '';
  end;
end;

procedure TPhotoMode.ApplyView;
begin
  if not FActive then
    Exit;
  { The field of view of the photo (horizontal at 4:3, like GameVideo's) }
  FViewport.Camera.Perspective.FieldOfViewAxis := faVertical;
  FViewport.Camera.Perspective.FieldOfView := 2 * ArcTan(Tan(DegToRad(FFov) / 2) * 3 / 4);
  if FDofNear <> nil then
  begin
    FDofNear.Send(FViewport.Camera.EffectiveProjectionNear);
    FDofFar.Send(FViewport.Camera.EffectiveProjectionFar);
  end;
end;

function TPhotoMode.NextPhotoName(const Prefix: String): String;
begin
  Inc(FCount);
  Result := Format('%s_photo_%d.png', [Prefix, FCount]);
end;

function RenderViewportImage(const Viewport: TCastleViewport; const W, H: Integer): TCastleImage;
var
  Container: TCastleContainer;
  RenderTarget: TGLRenderToTexture;
  Rect: TRectangle;
  OldFullSize: Boolean;
  OldWidth, OldHeight: Single;
begin
  Result := nil;
  Container := Viewport.Container;
  if Container = nil then
    Exit;
  Rect := Rectangle(0, 0, W, H);
  OldFullSize := Viewport.FullSize;
  OldWidth := Viewport.Width;
  OldHeight := Viewport.Height;
  RenderTarget := TGLRenderToTexture.Create(W, H);
  try
    RenderTarget.Buffer := tbNone;
    RenderTarget.GLContextOpen;
    RenderTarget.RenderBegin;
    try
      { The viewport alone, W x H pixels from the bottom left }
      Viewport.FullSize := False;
      Viewport.Width := W / Viewport.UIScale;
      Viewport.Height := H / Viewport.UIScale;
      Container.RenderControl(Viewport, Rect);
      Result := SaveScreen_NoFlush(TRGBImage, Rect, RenderTarget.ColorBuffer);
    finally
      RenderTarget.RenderEnd;
      Viewport.Width := OldWidth;
      Viewport.Height := OldHeight;
      Viewport.FullSize := OldFullSize;
    end;
  finally
    FreeAndNil(RenderTarget);
  end;
end;

function TPhotoMode.TakePhoto(const FileName: String): String;
var
  Container: TCastleContainer;
  W, H, MaxSize: Integer;
  Image: TCastleImage;
begin
  Result := '';
  Container := FViewport.Container;
  if Container = nil then
    Exit;
  MaxSize := Min(GLFeatures.MaxTextureSize, 8192);
  W := Min(Container.PixelsWidth * FScale, MaxSize);
  H := Min(Container.PixelsHeight * FScale, MaxSize);
  Image := nil;
  ApplyView;
  try
    Image := RenderViewportImage(FViewport, W, H);
    if Image = nil then
      Exit;
    {$ifndef WASI}
    SaveImage(Image, FileName);
    {$endif}
    Result := FileName;
    WritelnLog('Photo', 'Photo saved to "%s": %dx%d, fov %d, %s, camera %s', [FileName, W, H, Round(FFov),
      PhotoEffectNames[FEffect], FViewport.Camera.Translation.ToString]);
    ShowStatus(Format('Photo saved: %s (%dx%d)', [ExtractFileName(FileName), W, H]));
  except
    on E: Exception do
    begin
      WritelnWarning('Photo', 'Cannot take the photo "%s": %s', [FileName, E.Message]);
      ShowStatus('Cannot take the photo: ' + E.Message);
    end;
  end;
  FreeAndNil(Image);
end;

function TPhotoMode.Press(const Event: TInputPressRelease): Boolean;
begin
  Result := False;
  if not FActive then
    Exit;
  if Event.IsMouseWheel(mwUp) or Event.IsKey(keyLeftBracket) then
    SetFov(FFov - 5)
  else if Event.IsMouseWheel(mwDown) or Event.IsKey(keyRightBracket) then
    SetFov(FFov + 5)
  else if Event.IsKey(keyTab) then
  begin
    if FEffect = High(TPhotoEffect) then
      SetEffect(Low(TPhotoEffect))
    else
      SetEffect(Succ(FEffect));
  end else
  if Event.IsKey(keyPlus) or Event.IsKey(keyNumpadPlus) or Event.IsKey(keyEqual) then
    SetScale(FScale + 1)
  else if Event.IsKey(keyMinus) or Event.IsKey(keyNumpadMinus) then
    SetScale(FScale - 1)
  else if Event.IsKey(keyR) then
  begin
    FFov := VideoFov;
    FScale := DefaultPhotoScale;
    SetEffect(peNone);
  end else
    Exit;
  Result := True;
end;

function TPhotoMode.Command(const Cmd, Args: String; const ShotPrefix: String): String;
var
  E: TPhotoEffect;
begin
  Result := '';
  if Cmd = 'photo_fov' then
  begin
    if Args <> '' then
      SetFov(StrToFloatDef(Args, FFov));
    Result := Format('Photo field of view %d', [Round(FFov)]);
  end else
  if Cmd = 'photo_effect' then
  begin
    for E := Low(TPhotoEffect) to High(TPhotoEffect) do
      if SameText(Args, PhotoEffectNames[E]) then
        SetEffect(E);
    Result := 'Photo effect ' + PhotoEffectNames[FEffect] + ' (none, dof, gray, sepia, vignette, ao)';
  end else
  if Cmd = 'photo_scale' then
  begin
    if Args <> '' then
      SetScale(StrToIntDef(Args, FScale));
    Result := Format('Photo size %dx the window', [FScale]);
  end else
  if Cmd = 'photo_shot' then
  begin
    if not FActive then
      Result := 'Not in photo mode (photo 1)'
    else
      Result := TakePhoto(NextPhotoName(ShotPrefix));
  end;
  if Result <> '' then
    WritelnLog('Photo', Result);
end;

end.
