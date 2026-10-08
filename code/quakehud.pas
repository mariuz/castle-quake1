{ Quake 1 Heads-Up Display (HUD): Status bar, armor/health/ammo counters,
  crosshair, inventory, and player notifications. }
unit QuakeHud;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math,
  CastleVectors, CastleControls, CastleUIControls, CastleColors,
  CastleRectangles, CastleGLUtils;

type
  { Player statistics needed for HUD rendering }
  TQuakePlayerStats = record
    Health: Integer;
    Armor: Integer;
    ArmorType: Integer; { 0 = none, 1 = green, 2 = yellow, 3 = red }
    Ammo: Integer;
    AmmoType: Integer;  { 0 = shells, 1 = nails, 2 = rockets, 3 = cells }
    Shells, Nails, Rockets, Cells: Integer;
    MaxShells, MaxNails, MaxRockets, MaxCells: Integer;
    WeaponMask: Cardinal;
    CurrentWeapon: Integer; { 1 = axe, 2 = shotgun, 3 = sshotgun, 4 = nailgun, 5 = snailgun, 6 = gl, 7 = rl, 8 = lg }
    Keys: Cardinal;     { bit 0 = silver, bit 1 = gold }
    Kills, TotalKills: Integer;
    Secrets, TotalSecrets: Integer;
    LevelTime: Single;
  end;

  { Quake Heads-Up Display container }
  TQuakeHud = class(TCastleUserInterface)
  private
    FStats: TQuakePlayerStats;
    FMessageLabel: TCastleLabel;
    FStatsLabel: TCastleLabel;
    FMessageTimer: Single;
    FCrosshairVisible: Boolean;
    FStatsVisible: Boolean;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    { Update HUD with latest player state }
    procedure Update(const SecondsPassed: Single; const Stats: TQuakePlayerStats); reintroduce;

    { Display a centered notification message }
    procedure ShowMessage(const S: String; const Duration: Single = 3.0);

    { Render custom crosshair and status bar at bottom of viewport }
    procedure Render; override;

    property CrosshairVisible: Boolean read FCrosshairVisible write FCrosshairVisible;
    property StatsVisible: Boolean read FStatsVisible write FStatsVisible;
  end;

implementation

{ TQuakeHud }

constructor TQuakeHud.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FullSize := True;

  FillChar(FStats, SizeOf(FStats), 0);
  FStats.Health := 100;

  { Centered message banner }
  FMessageLabel := TCastleLabel.Create(Self);
  FMessageLabel.Color := Vector4(1.0, 0.9, 0.2, 1.0);
  FMessageLabel.Anchor(hpMiddle);
  FMessageLabel.Anchor(vpTop, -80);
  FMessageLabel.Caption := '';
  InsertFront(FMessageLabel);

  { Corner stats label }
  FStatsLabel := TCastleLabel.Create(Self);
  FStatsLabel.Color := Vector4(0.8, 0.8, 0.8, 0.85);
  FStatsLabel.Anchor(hpLeft, 16);
  FStatsLabel.Anchor(vpTop, -16);
  FStatsLabel.Caption := '';
  InsertFront(FStatsLabel);

  FCrosshairVisible := True;
  FStatsVisible := True;
  FMessageTimer := 0;
end;

destructor TQuakeHud.Destroy;
begin
  inherited Destroy;
end;

procedure TQuakeHud.ShowMessage(const S: String; const Duration: Single);
begin
  FMessageLabel.Caption := S;
  FMessageTimer := Duration;
end;

procedure TQuakeHud.Update(const SecondsPassed: Single; const Stats: TQuakePlayerStats);
var
  Mins, Secs: Integer;
begin
  FStats := Stats;

  if FMessageTimer > 0 then
  begin
    FMessageTimer := FMessageTimer - SecondsPassed;
    if FMessageTimer <= 0 then
    begin
      FMessageTimer := 0;
      FMessageLabel.Caption := '';
    end;
  end;

  if FStatsVisible then
  begin
    Mins := Trunc(Stats.LevelTime) div 60;
    Secs := Trunc(Stats.LevelTime) mod 60;
    FStatsLabel.Caption := Format('KILLS: %d/%d   SECRETS: %d/%d   TIME: %02d:%02d',
      [Stats.Kills, Stats.TotalKills, Stats.Secrets, Stats.TotalSecrets, Mins, Secs]);
  end else
    FStatsLabel.Caption := '';
end;

procedure TQuakeHud.Render;
var
  CX, CY: Single;
  R: TFloatRectangle;
  BarW, BarH, BarX, BarY, ColW: Single;
  ArmorCol, HealthCol, AmmoCol: TVector4;
  KeyStr: String;
begin
  inherited Render;

  { 1. Draw Quake Status Bar at bottom center }
  BarW := Min(RenderRect.Width - 40, 600);
  if BarW < 320 then
    BarW := 320;
  BarH := 48;
  BarX := (RenderRect.Width - BarW) / 2;
  BarY := 12;

  { Status bar border and dark metal plate }
  DrawRectangle(FloatRectangle(BarX - 3, BarY - 3, BarW + 6, BarH + 6), Vector4(0.22, 0.22, 0.26, 0.95));
  DrawRectangle(FloatRectangle(BarX, BarY, BarW, BarH), Vector4(0.09, 0.09, 0.11, 0.92));

  ColW := BarW / 3;

  { Inner column dividing lines }
  DrawRectangle(FloatRectangle(BarX + ColW, BarY + 2, 2, BarH - 4), Vector4(0.25, 0.25, 0.3, 0.75));
  DrawRectangle(FloatRectangle(BarX + ColW * 2, BarY + 2, 2, BarH - 4), Vector4(0.25, 0.25, 0.3, 0.75));

  { Armor color logic }
  if FStats.Armor > 100 then
    ArmorCol := Vector4(1.0, 0.85, 0.1, 1.0)
  else if FStats.Armor > 0 then
    ArmorCol := Vector4(0.35, 0.9, 0.35, 1.0)
  else
    ArmorCol := Vector4(0.5, 0.5, 0.5, 0.7);

  { Health color logic }
  if FStats.Health > 100 then
    HealthCol := Vector4(0.4, 0.7, 1.0, 1.0)
  else if FStats.Health > 25 then
    HealthCol := Vector4(0.95, 0.95, 0.95, 1.0)
  else
    HealthCol := Vector4(1.0, 0.25, 0.25, 1.0);

  AmmoCol := Vector4(1.0, 0.75, 0.2, 1.0);

  { Section 1: ARMOR }
  UIFont.Print(BarX + 16, BarY + 28, Vector4(0.65, 0.65, 0.7, 0.9), 'ARMOR');
  UIFont.Print(BarX + 16, BarY + 8, ArmorCol, IntToStr(Max(0, FStats.Armor)));

  { Section 2: HEALTH }
  UIFont.Print(BarX + ColW + 16, BarY + 28, Vector4(0.65, 0.65, 0.7, 0.9), 'HEALTH');
  UIFont.Print(BarX + ColW + 16, BarY + 8, HealthCol, IntToStr(Max(0, FStats.Health)));

  { Section 3: AMMO }
  UIFont.Print(BarX + ColW * 2 + 16, BarY + 28, Vector4(0.65, 0.65, 0.7, 0.9), 'AMMO');
  UIFont.Print(BarX + ColW * 2 + 16, BarY + 8, AmmoCol, IntToStr(Max(0, FStats.Ammo)));

  { Keys indicator at far right if collected }
  KeyStr := '';
  if (FStats.Keys and 1) <> 0 then KeyStr := KeyStr + '[SILVER] ';
  if (FStats.Keys and 2) <> 0 then KeyStr := KeyStr + '[GOLD]';
  if KeyStr <> '' then
    UIFont.Print(BarX + ColW * 2 + 100, BarY + 18, Vector4(1.0, 0.85, 0.2, 1.0), KeyStr);

  { 2. Draw centered crosshair }
  if FCrosshairVisible then
  begin
    CX := RenderRect.Width / 2;
    CY := RenderRect.Height / 2;

    { Small crosshair with center gap }
    R := FloatRectangle(CX - 8, CY - 1, 5, 2);
    DrawRectangle(R, Vector4(1, 1, 1, 0.75));
    R := FloatRectangle(CX + 3, CY - 1, 5, 2);
    DrawRectangle(R, Vector4(1, 1, 1, 0.75));
    R := FloatRectangle(CX - 1, CY - 8, 2, 5);
    DrawRectangle(R, Vector4(1, 1, 1, 0.75));
    R := FloatRectangle(CX - 1, CY + 3, 2, 5);
    DrawRectangle(R, Vector4(1, 1, 1, 0.75));

    { Center dot }
    R := FloatRectangle(CX - 1, CY - 1, 2, 2);
    DrawRectangle(R, Vector4(1, 0.8, 0.2, 0.9));
  end;
end;

end.
