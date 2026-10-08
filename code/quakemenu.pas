{ Quake Main Menu: New Game, Episode/Map Select, Options, and CGE Showcase. }
unit QuakeMenu;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math,
  CastleVectors, CastleUIControls, CastleControls, CastleKeysMouse, CastleColors,
  CastleRectangles, CastleGLUtils, CastleImages, QuakeSound;

type
  TMenuAction = (
    maNone, maNewGame, maWarpMap, maToggleShadows, maToggleCamera, maToggleSound, maQuit
  );

  TOnMenuActionEvent = procedure(const Action: TMenuAction; const Param: String) of object;

  { Quake Title and Main Menu }
  TQuakeMenu = class(TCastleUserInterface)
  private
    FSelectedIdx: Integer;
    FSubMenu: (smMain, smEpisodes, smMaps, smOptions, smShowcase);
    FItems: TStringList;
    FOnMenuAction: TOnMenuActionEvent;
    FShadowsEnabled: Boolean;
    FCameraModeName: String;
    FVolume: Integer;
    procedure RebuildMenuItems;
    procedure ExecuteSelection;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    function Press(const Event: TInputPressRelease): Boolean; override;
    procedure Render; override;

    property OnMenuAction: TOnMenuActionEvent read FOnMenuAction write FOnMenuAction;
    property ShadowsEnabled: Boolean read FShadowsEnabled write FShadowsEnabled;
    property CameraModeName: String read FCameraModeName write FCameraModeName;
  end;

implementation

constructor TQuakeMenu.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FullSize := True;
  FItems := TStringList.Create;
  FSelectedIdx := 0;
  FSubMenu := smMain;
  FShadowsEnabled := False;
  FCameraModeName := 'First-Person';
  FVolume := 100;
  RebuildMenuItems;
end;

destructor TQuakeMenu.Destroy;
begin
  FItems.Free;
  inherited Destroy;
end;

procedure TQuakeMenu.RebuildMenuItems;
begin
  FItems.Clear;
  case FSubMenu of
    smMain:
      begin
        FItems.Add('Single Player');
        FItems.Add('Map Warp');
        FItems.Add('Options');
        FItems.Add('CGE Features Showcase');
        FItems.Add('Quit');
      end;
    smMaps:
      begin
        FItems.Add('maps/start.bsp');
        FItems.Add('maps/e1m1.bsp');
        FItems.Add('maps/e1m2.bsp');
        FItems.Add('maps/e1m3.bsp');
        FItems.Add('maps/lq_e0m1.bsp');
        FItems.Add('maps/lq_e0m2.bsp');
        FItems.Add('Back to Main Menu');
      end;
    smOptions:
      begin
        if FShadowsEnabled then
          FItems.Add('Dynamic Shadows: [ON]')
        else
          FItems.Add('Dynamic Shadows: [OFF]');
        FItems.Add('Camera View: [' + FCameraModeName + ']');
        FItems.Add('Sound Effects: [' + IntToStr(FVolume) + '%]');
        FItems.Add('Back to Main Menu');
      end;
    smShowcase:
      begin
        FItems.Add('Back to Main Menu');
      end;
  end;
  FSelectedIdx := 0;
end;

procedure TQuakeMenu.ExecuteSelection;
var
  ItemText: String;
begin
  if (FSelectedIdx < 0) or (FSelectedIdx >= FItems.Count) then
    Exit;

  ItemText := FItems[FSelectedIdx];
  Sounds.Play('sound/misc/menu2.wav');

  case FSubMenu of
    smMain:
      case FSelectedIdx of
        0: if Assigned(FOnMenuAction) then FOnMenuAction(maNewGame, 'start');
        1: begin FSubMenu := smMaps; RebuildMenuItems; end;
        2: begin FSubMenu := smOptions; RebuildMenuItems; end;
        3: begin FSubMenu := smShowcase; RebuildMenuItems; end;
        4: if Assigned(FOnMenuAction) then FOnMenuAction(maQuit, '');
      end;
    smMaps:
      begin
        if ItemText = 'Back to Main Menu' then
        begin
          FSubMenu := smMain;
          RebuildMenuItems;
        end else
        if Assigned(FOnMenuAction) then
          FOnMenuAction(maWarpMap, ItemText);
      end;
    smOptions:
      case FSelectedIdx of
        0:
          begin
            FShadowsEnabled := not FShadowsEnabled;
            RebuildMenuItems;
            if Assigned(FOnMenuAction) then
              FOnMenuAction(maToggleShadows, BoolToStr(FShadowsEnabled, True));
          end;
        1:
          begin
            if Assigned(FOnMenuAction) then
              FOnMenuAction(maToggleCamera, '');
          end;
        2:
          begin
            FVolume := (FVolume + 25) mod 125;
            RebuildMenuItems;
          end;
        3:
          begin
            FSubMenu := smMain;
            RebuildMenuItems;
          end;
      end;
    smShowcase:
      begin
        FSubMenu := smMain;
        RebuildMenuItems;
      end;
  end;
end;

function TQuakeMenu.Press(const Event: TInputPressRelease): Boolean;
begin
  Result := False;

  if Event.IsKey(keyArrowUp) then
  begin
    FSelectedIdx := (FSelectedIdx - 1 + FItems.Count) mod FItems.Count;
    Sounds.Play('sound/misc/menu1.wav');
    Exit(True);
  end;

  if Event.IsKey(keyArrowDown) then
  begin
    FSelectedIdx := (FSelectedIdx + 1) mod FItems.Count;
    Sounds.Play('sound/misc/menu1.wav');
    Exit(True);
  end;

  if Event.IsKey(keyEnter) or Event.IsKey(keySpace) then
  begin
    ExecuteSelection;
    Exit(True);
  end;

  if Event.IsKey(keyEscape) then
  begin
    if FSubMenu <> smMain then
    begin
      FSubMenu := smMain;
      RebuildMenuItems;
      Sounds.Play('sound/misc/menu3.wav');
      Exit(True);
    end;
  end;
end;

procedure TQuakeMenu.Render;
var
  CX, CY, StartY: Single;
  I: Integer;
  Col: TVector4;
begin
  inherited Render;

  CX := RenderRect.Width / 2;
  CY := RenderRect.Height / 2;

  { Dark vignette backdrop }
  DrawRectangle(RenderRect, Vector4(0.04, 0.04, 0.05, 0.88));

  { Quake Title }
  UIFont.Print(CX - 130, CY + 220, Vector4(1.0, 0.45, 0.1, 1.0), 'CASTLE QUAKE');
  UIFont.Print(CX - 165, CY + 195, Vector4(0.8, 0.8, 0.8, 0.8), 'Castle Game Engine Quake Showcase');

  if FSubMenu = smShowcase then
  begin
    UIFont.Print(CX - 280, CY + 140, Vector4(1.0, 0.8, 0.2, 1.0), 'Engine Features Used:');
    UIFont.Print(CX - 280, CY + 110, Vector4(0.9, 0.9, 0.9, 1.0), '- Full 3D X3D Scene Graphs (TIndexedTriangleSetNode, TShapeNode)');
    UIFont.Print(CX - 280, CY + 85,  Vector4(0.9, 0.9, 0.9, 1.0), '- Real-Time Dynamic PBR Lighting with Point Lights (TCastlePointLight)');
    UIFont.Print(CX - 280, CY + 60,  Vector4(0.9, 0.9, 0.9, 1.0), '- Real-Time Dynamic Shadow Mapping');
    UIFont.Print(CX - 280, CY + 35,  Vector4(0.9, 0.9, 0.9, 1.0), '- Quake 1 Alias MDL 3D Model Loading and Mesh Animation');
    UIFont.Print(CX - 280, CY + 10,  Vector4(0.9, 0.9, 0.9, 1.0), '- Positional 3D Spatial Audio via OpenAL (TCastleSoundSource)');
    UIFont.Print(CX - 280, CY - 15,  Vector4(0.9, 0.9, 0.9, 1.0), '- Custom URL Protocols ("quakepak:", "quaketex:") with Streaming Cache');
    UIFont.Print(CX - 280, CY - 40,  Vector4(0.9, 0.9, 0.9, 1.0), '- First/Third Person & Free-Fly Navigation (TCastleWalkNavigation)');
    UIFont.Print(CX - 280, CY - 65,  Vector4(0.9, 0.9, 0.9, 1.0), '- Interactive Submodels (doors, elevators, buttons) via TCastleTransform');
    UIFont.Print(CX - 280, CY - 90,  Vector4(0.9, 0.9, 0.9, 1.0), '- Particle Systems (impact sparks, blood splatters, explosions)');
    UIFont.Print(CX - 280, CY - 115, Vector4(0.9, 0.9, 0.9, 1.0), '- Dual Asset Support (Quake 1 Demo and LibreQuake open assets)');

    UIFont.Print(CX - 80, CY - 160, Vector4(1.0, 0.5, 0.1, 1.0), '[ Press Enter / Esc to Return ]');
    Exit;
  end;

  StartY := CY + 80;
  for I := 0 to FItems.Count - 1 do
  begin
    if I = FSelectedIdx then
    begin
      Col := Vector4(1.0, 0.85, 0.15, 1.0);
      { Cursor indicator }
      UIFont.Print(CX - 150, StartY - I * 36, Col, '> ' + FItems[I] + ' <');
    end else
    begin
      Col := Vector4(0.75, 0.75, 0.75, 0.9);
      UIFont.Print(CX - 130, StartY - I * 36, Col, FItems[I]);
    end;
  end;

  { Bottom help hint }
  UIFont.Print(CX - 160, 40, Vector4(0.6, 0.6, 0.6, 0.7),
    'Use Arrow Keys to Navigate, Enter to Select, Esc to Back');
end;

end.
