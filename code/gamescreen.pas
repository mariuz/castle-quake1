{ The user interface scale for the screen the game runs on.

  The editor designs are made for 1600 x 900 (CastleSettings.xml encloses
  that reference size). That alone makes the HUD and menu text tiny on a
  phone: its canvas has 2 to 3 device pixels per CSS pixel, and held
  upright the width limits the scale. UpdateUIScale sets an explicit scale
  instead, the larger of "fit 1600 x 900" and "readable at this density"
  (the design's 22 pixel text at least 15 density-independent pixels),
  capped so that at least 800 x 480 design units stay on screen. On a
  desktop at 96 DPI this is the enclosing scale, as before. }
unit GameScreen;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math, CastleUIControls;

const
  ReferenceWidth = 1600;
  ReferenceHeight = 900;
  { The smallest design area kept on screen }
  MinDesignWidth = 800;
  MinDesignHeight = 480;
  { Design pixels per density-independent pixel at the least }
  ReadableScale = 0.7;

var
  { -density <x>: the device pixels per density-independent pixel, instead
    of the detected one (to try a phone's layout on a desktop) }
  ForcedDensity: Single = 0;

{ The UI scale for a window of PixelsWidth x PixelsHeight device pixels with
  Density device pixels per density-independent pixel (1 on a 96 DPI
  desktop, the devicePixelRatio of a web page, dpi / 160 on Android) }
function ComputeUIScale(const PixelsWidth, PixelsHeight: Integer; const Density: Single): Single;

{ The density of the screen of this container }
function ScreenDensity(const Container: TCastleContainer): Single;

{ Set the container's explicit UI scale for its current size and density
  (call at start and on every resize); logs when the scale changes }
procedure UpdateUIScale(const Container: TCastleContainer);

{ Keep the scale up to date: an invisible control in the container (it
  stays when the views change) runs UpdateUIScale on every resize }
procedure InstallUIScaleWatcher(const Container: TCastleContainer);

implementation

uses
  CastleApplicationProperties, CastleLog, QuakeWebSocketClient;

type
  TUIScaleWatcher = class(TCastleUserInterface)
  public
    procedure Resize; override;
  end;

var
  LastScale: Single = 0;

procedure TUIScaleWatcher.Resize;
begin
  inherited;
  { Changing the scale resizes the controls again; the second time the
    scale is the same and nothing changes }
  UpdateUIScale(Container);
end;

procedure InstallUIScaleWatcher(const Container: TCastleContainer);
var
  W: TUIScaleWatcher;
begin
  W := TUIScaleWatcher.Create(Container);
  W.Exists := True;
  Container.Controls.InsertBack(W);
  UpdateUIScale(Container);
end;

function ComputeUIScale(const PixelsWidth, PixelsHeight: Integer; const Density: Single): Single;
var
  Fit, Readable, Cap: Single;
begin
  if (PixelsWidth <= 0) or (PixelsHeight <= 0) then
    Exit(1);
  Fit := Min(PixelsWidth / ReferenceWidth, PixelsHeight / ReferenceHeight);
  Readable := ReadableScale * Max(Density, 0.5);
  Cap := Min(PixelsWidth / MinDesignWidth, PixelsHeight / MinDesignHeight);
  Result := Max(Fit, Min(Readable, Cap));
  if Result <= 0 then
    Result := 1;
end;

function ScreenDensity(const Container: TCastleContainer): Single;
var
  Dpr: Single;
begin
  if ForcedDensity > 0 then
    Exit(ForcedDensity);
  Dpr := PageDevicePixelRatio;
  if Dpr > 0 then
    Exit(Dpr);
  { Native: Android's density-independent pixel is 1/160 inch, a desktop's
    reference is 96 DPI }
  if ApplicationProperties.TouchDevice then
    Result := Container.Dpi / 160
  else
    Result := Container.Dpi / 96;
end;

procedure UpdateUIScale(const Container: TCastleContainer);
var
  Density, Scale: Single;
begin
  if Container = nil then
    Exit;
  Density := ScreenDensity(Container);
  Scale := ComputeUIScale(Container.PixelsWidth, Container.PixelsHeight, Density);
  if Container.UIScaling <> usExplicitScale then
    Container.UIScaling := usExplicitScale;
  if not SameValue(Container.UIExplicitScale, Scale, 0.001) then
    Container.UIExplicitScale := Scale;
  if not SameValue(LastScale, Scale, 0.001) then
  begin
    LastScale := Scale;
    WritelnLog('GameScreen', 'UI scale %.2f for %d x %d pixels at density %.2f (%.0f x %.0f design units)',
      [Scale, Container.PixelsWidth, Container.PixelsHeight, Density,
       Container.PixelsWidth / Scale, Container.PixelsHeight / Scale]);
  end;
end;

end.
