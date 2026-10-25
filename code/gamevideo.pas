{ Video options: field of view, brightness, view bob and the view weapon,
  saved in the user config and applied by the play, QuakeC and demo views.
  The accessibility options of QuakeCaptions (captions, high contrast HUD,
  reduced flashes) are saved with them under access/. }
unit GameVideo;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, CastleVectors, CastleViewport, CastleTransform, CastleCameras, X3DNodes, X3DFields,
  CastleRenderOptions, CastleImages;

const
  DefaultFov = 90;
  DefaultGamma = 1.0;
  DefaultViewBob = 0.02;

var
  { fov: the horizontal field of view in degrees at a 4:3 aspect; wider
    windows see more at the sides (Hor+), like QuakeSpasm }
  VideoFov: Single = DefaultFov;
  { gamma: below 1 brightens (pow(color, gamma) like Quake's gamma table) }
  VideoGamma: Single = DefaultGamma;
  { cl_bob: how much the view bobs with the horizontal speed (0 off) }
  ViewBob: Single = DefaultViewBob;
  { r_drawviewmodel: the first person weapon is drawn }
  ShowWeapon: Boolean = True;
  { The player in network games: the name ('' lets the server name it
    player<N>) and the colors 0..13 of the shirt and the pants }
  PlayerName: String = '';
  PlayerShirt: Integer = 0;
  PlayerPants: Integer = 0;
  { Changes are not saved (headless tests) }
  VideoSettingsVolatile: Boolean = False;

procedure LoadVideoSettings;
procedure SaveVideoSettings;

{ The colors as the network sends them: shirt * 16 + pants }
function PlayerColors: Integer;

{ The vertical field of view (radians) of VideoFov at 4:3 }
function VerticalFov: Single;

{ V_CalcBob: the bob of the view at Time for a velocity (Quake units / s),
  -7 .. 4 units (0 without speed or with ViewBob 0) }
function CalcViewBob(const Time: Single; const Velocity: TVector3): Single;

{ Apply the field of view and the brightness to a viewport, and give the
  captions the camera (each frame:
  only changes cost anything). The brightness is a screen effect added to
  the viewport once. }
procedure ApplyVideoSettings(const Viewport: TCastleViewport);

{ The NC compare: the pixels of A and B where a channel differs by more
  than 24 of 255, and in Alone how many of them have no differing
  neighbour (a crack one pixel wide between two faces of the world, which
  shows whatever lies behind it, drawn or culled; a hidden object differs
  in more than one pixel together) }
function ComparePvsImages(const A, B: TRGBImage; out Alone: Integer): Integer;

implementation

uses
  CastleConfig, CastleLog, CastleUtils, QuakeCaptions, QuakeWorld;

function ComparePvsImages(const A, B: TRGBImage; out Alone: Integer): Integer;
var
  W, H, X, Y, DX, DY: Integer;
  Mask: array of Boolean;
  P, Q: PVector3Byte;
  Lonely: Boolean;
begin
  Result := 0;
  Alone := 0;
  W := Min(A.Width, B.Width);
  H := Min(A.Height, B.Height);
  Mask := nil;
  SetLength(Mask, W * H);
  for Y := 0 to H - 1 do
    for X := 0 to W - 1 do
    begin
      P := A.PixelPtr(X, Y);
      Q := B.PixelPtr(X, Y);
      if (Abs(P^.X - Q^.X) > 24) or (Abs(P^.Y - Q^.Y) > 24) or (Abs(P^.Z - Q^.Z) > 24) then
      begin
        Mask[Y * W + X] := True;
        Inc(Result);
      end;
    end;
  if Result = 0 then
    Exit;
  for Y := 0 to H - 1 do
    for X := 0 to W - 1 do
      if Mask[Y * W + X] then
      begin
        Lonely := True;
        for DY := -1 to 1 do
          for DX := -1 to 1 do
            if ((DX <> 0) or (DY <> 0)) and (X + DX >= 0) and (X + DX < W) and (Y + DY >= 0) and (Y + DY < H) and
               Mask[(Y + DY) * W + X + DX] then
              Lonely := False;
        if Lonely then
          Inc(Alone);
      end;
end;

const
  GammaFragmentShader =
    'uniform float quake_gamma;' + LineEnding +
    'void main(void)' + LineEnding +
    '{' + LineEnding +
    '  vec4 c = screenf_get_original_color();' + LineEnding +
    '  gl_FragColor = vec4(pow(max(c.rgb, vec3(0.0)), vec3(quake_gamma)), c.a);' + LineEnding +
    '}' + LineEnding;

  { cl_bobcycle, cl_bobup }
  BobCycle = 0.6;
  BobUp = 0.5;

procedure LoadVideoSettings;
begin
  VideoFov := EnsureRange(UserConfig.GetFloat('video/fov', DefaultFov), 50, 130);
  VideoGamma := EnsureRange(UserConfig.GetFloat('video/gamma', DefaultGamma), 0.4, 1.5);
  ViewBob := EnsureRange(UserConfig.GetFloat('video/bob', DefaultViewBob), 0, 0.1);
  ShowWeapon := UserConfig.GetValue('video/show_weapon', True);
  CaptionsEnabled := UserConfig.GetValue('access/captions', False);
  HighContrastHud := UserConfig.GetValue('access/hud_contrast', False);
  ReducedFlashes := UserConfig.GetValue('access/reduced_flashes', False);
  SpeedrunTimer := UserConfig.GetValue('speedrun/timer', False);
  GhostRacing := UserConfig.GetValue('speedrun/ghost', True);
  PlayerName := UserConfig.GetValue('player/name', '');
  PlayerShirt := EnsureRange(UserConfig.GetValue('player/shirt', 0), 0, 13);
  PlayerPants := EnsureRange(UserConfig.GetValue('player/pants', 0), 0, 13);
end;

function PlayerColors: Integer;
begin
  Result := (PlayerShirt and 15) * 16 + (PlayerPants and 15);
end;

procedure SaveVideoSettings;
const
  { As Single, like the setting, so the default compares equal }
  ViewBobDefault: Single = DefaultViewBob;
begin
  if VideoSettingsVolatile then
    Exit;
  try
    UserConfig.SetDeleteFloat('video/fov', VideoFov, DefaultFov);
    UserConfig.SetDeleteFloat('video/gamma', VideoGamma, DefaultGamma);
    UserConfig.SetDeleteFloat('video/bob', ViewBob, ViewBobDefault);
    UserConfig.SetDeleteValue('video/show_weapon', ShowWeapon, True);
    UserConfig.SetDeleteValue('access/captions', CaptionsEnabled, False);
    UserConfig.SetDeleteValue('access/hud_contrast', HighContrastHud, False);
    UserConfig.SetDeleteValue('access/reduced_flashes', ReducedFlashes, False);
    UserConfig.SetDeleteValue('speedrun/timer', SpeedrunTimer, False);
    UserConfig.SetDeleteValue('speedrun/ghost', GhostRacing, True);
    UserConfig.SetDeleteValue('player/name', PlayerName, '');
    UserConfig.SetDeleteValue('player/shirt', PlayerShirt, 0);
    UserConfig.SetDeleteValue('player/pants', PlayerPants, 0);
    UserConfig.Save;
  except
    on E: Exception do
      WritelnWarning('GameVideo', 'Cannot save the user config: ' + E.Message);
  end;
end;

function VerticalFov: Single;
begin
  Result := 2 * ArcTan(Tan(DegToRad(VideoFov) / 2) * 3 / 4);
end;

function CalcViewBob(const Time: Single; const Velocity: TVector3): Single;
var
  Cycle, Speed: Single;
begin
  if ViewBob <= 0 then
    Exit(0);
  Cycle := FloatModulo(Time, BobCycle) / BobCycle;
  if Cycle < BobUp then
    Cycle := Pi * Cycle / BobUp
  else
    Cycle := Pi + Pi * (Cycle - BobUp) / (1 - BobUp);
  { The horizontal speed, not the falling one }
  Speed := Sqrt(Sqr(Velocity.X) + Sqr(Velocity.Y)) * ViewBob;
  Result := EnsureRange(Speed * 0.3 + Speed * 0.7 * Sin(Cycle), -7, 4);
end;

type
  { The viewport's brightness effect, found again by its component name }
  TGammaHolder = class(TComponent)
  public
    Effect: TScreenEffectNode;
    Field: TSFFloat;
    Value: Single;
  end;

procedure ApplyVideoSettings(const Viewport: TCastleViewport);
var
  Fov: Single;
  Holder: TGammaHolder;
  Shader: TComposedShaderNode;
  FragmentPart: TShaderPartNode;
begin
  if Viewport = nil then
    Exit;
  { Where the captions' directions are measured from }
  if Viewport.Camera <> nil then
    Captions.SetListener(Viewport.Camera.WorldTranslation, Viewport.Camera.WorldDirection);
  Fov := VerticalFov;
  if (Viewport.Camera.Perspective.FieldOfViewAxis <> faVertical) or
     not SameValue(Viewport.Camera.Perspective.FieldOfView, Fov, 1e-4) then
  begin
    Viewport.Camera.Perspective.FieldOfViewAxis := faVertical;
    Viewport.Camera.Perspective.FieldOfView := Fov;
  end;

  { The brightness: one screen effect per viewport, off at gamma 1 }
  Holder := Viewport.FindComponent('quake_gamma') as TGammaHolder;
  if Holder = nil then
  begin
    if SameValue(VideoGamma, 1, 1e-3) then
      Exit;
    FragmentPart := TShaderPartNode.Create;
    FragmentPart.ShaderType := stFragment;
    FragmentPart.Contents := GammaFragmentShader;
    Shader := TComposedShaderNode.Create;
    Shader.SetParts([FragmentPart]);
    Holder := TGammaHolder.Create(Viewport);
    Holder.Name := 'quake_gamma';
    Holder.Field := TSFFloat.Create(Shader, True, 'quake_gamma', VideoGamma);
    Shader.AddCustomField(Holder.Field);
    Holder.Effect := TScreenEffectNode.Create;
    Holder.Effect.SetShaders([Shader]);
    Holder.Value := VideoGamma;
    Viewport.AddScreenEffect(Holder.Effect);
  end;
  if not SameValue(Holder.Value, VideoGamma, 1e-4) then
  begin
    Holder.Value := VideoGamma;
    Holder.Field.Send(VideoGamma);
  end;
  Holder.Effect.Enabled := not SameValue(VideoGamma, 1, 1e-3);
end;

end.
