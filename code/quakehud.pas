{ Quake 1 Heads-Up Display (HUD): Status bar, armor/health/ammo counters,
  crosshair, inventory, and player notifications. }
unit QuakeHud;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math,
  CastleVectors, CastleControls, CastleUIControls, CastleColors,
  CastleRectangles, CastleGLUtils, CastleComponentSerialize;

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
    BiosuitTime: Single; { seconds of environment suit left }
    Underwater: Boolean; { eyes below the surface }
    AirLeft: Single;     { seconds of air before drowning (12 when full) }
  end;

  { Full-screen palette shift (cshift_t): Dest color in 0..255, Percent in 0..255 }
  TQuakeColorShift = record
    Dest: TVector3;
    Percent: Single;
  end;

  { Quake Heads-Up Display container }
  TQuakeHud = class(TCastleUserInterface)
  private
    FStats: TQuakePlayerStats;
    { The editor design (data/ui/hud.castle-user-interface) }
    FDesign: TCastleUserInterface;
    FMessageLabel: TCastleLabel;
    FStatsLabel: TCastleLabel;
    FArmorValue, FHealthValue, FAmmoValue, FKeysLabel: TCastleLabel;
    FStatusFrame, FAirBar, FAirFill: TCastleUserInterface;
    FMessageTimer: Single;
    FCrosshairVisible: Boolean;
    FStatsVisible: Boolean;
    FContentsShift: TQuakeColorShift;
    FDamageShift: TQuakeColorShift;
    FBonusShift: TQuakeColorShift;
    FPowerupShift: TQuakeColorShift;
    { Intermission (Sbar_IntermissionOverlay) with counting tallies }
    FIntermission: Boolean;
    FInterTitle: String;
    FInterTime: Single;
    FInterKills, FInterTotalKills, FInterSecrets, FInterTotalSecrets: Integer;
    FInterClock: Single;
    FInterStage: Integer;     { 0 time, 1 secrets, 2 kills, 3 done }
    FInterShown: Single;      { value of the stage being counted }
    FInterTick: Single;
    FInterReady: Boolean;     { the player may continue }
    { Finale (svc_finale): the text typed out over the finale picture }
    FFinale: Boolean;
    FFinaleText: String;
    FFinaleClock: Single;
    function CalcBlend: TVector4;
  public
    { Demo recording: centerprints }
    OnMessage: procedure(const S: String) of object;
    { Appended to the stats line (the console's fps command) }
    FpsText: String;
  private
    procedure UpdateIntermission(const SecondsPassed: Single);
    procedure RenderIntermission;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    { Update HUD with latest player state }
    procedure Update(const SecondsPassed: Single; const Stats: TQuakePlayerStats); reintroduce;

    { Display a centered notification message }
    procedure ShowMessage(const S: String; const Duration: Single = 3.0);

    { Red flash after the player is hurt (V_ParseDamage).
      Armor and Blood are the amounts absorbed by armor and taken from health. }
    procedure DamageFlash(const Armor, Blood: Integer);

    { Gold flash after picking up an item (bonus_flash) }
    procedure BonusFlash;

    { Tint for the liquid the view is in (V_SetContentsColor), CONTENTS_xxx value }
    procedure SetContents(const Contents: Integer);

    { Show the level completed screen: level title, time, secrets and
      kills counted up one after another }
    procedure StartIntermission(const ATitle: String; const ATime: Single;
      const AKills, ATotalKills, ASecrets, ATotalSecrets: Integer);
    procedure StopIntermission;
    { The episode or ending text (SCR_DrawCenterString during cl.intermission 2),
      typed out at 8 characters per second over gfx/finale.lmp }
    procedure StartFinale(const AText: String);
    property Intermission: Boolean read FIntermission;
    { Set by the world once the intermission may be left }
    property IntermissionReady: Boolean read FInterReady write FInterReady;

    { Render custom crosshair and status bar at bottom of viewport }
    procedure Render; override;

    property CrosshairVisible: Boolean read FCrosshairVisible write FCrosshairVisible;
    property StatsVisible: Boolean read FStatsVisible write FStatsVisible;
  end;

implementation

uses
  CastleGLImages,
  QuakeBsp, QuakeSound, QuakePics;

const
  { Seconds to count each tally }
  TallyDuration = 1.0;

function ColorShift(const R, G, B, Percent: Single): TQuakeColorShift;
begin
  Result.Dest := Vector3(R, G, B);
  Result.Percent := Percent;
end;

{ TQuakeHud }

constructor TQuakeHud.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FullSize := True;

  FillChar(FStats, SizeOf(FStats), 0);
  FStats.Health := 100;

  { The status bar, message banner and stats line are an editor design;
    the palette blends, the crosshair and the intermission pictures are
    still drawn in Render }
  FDesign := UserInterfaceLoad('castle-data:/ui/hud.castle-user-interface', Self);
  InsertFront(FDesign);
  FMessageLabel := FindRequiredComponent('MessageLabel') as TCastleLabel;
  FStatsLabel := FindRequiredComponent('StatsLabel') as TCastleLabel;
  FArmorValue := FindRequiredComponent('ArmorValue') as TCastleLabel;
  FHealthValue := FindRequiredComponent('HealthValue') as TCastleLabel;
  FAmmoValue := FindRequiredComponent('AmmoValue') as TCastleLabel;
  FKeysLabel := FindRequiredComponent('KeysLabel') as TCastleLabel;
  FStatusFrame := FindRequiredComponent('StatusBarFrame') as TCastleUserInterface;
  FAirBar := FindRequiredComponent('AirBar') as TCastleUserInterface;
  FAirFill := FindRequiredComponent('AirFill') as TCastleUserInterface;

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
  if Assigned(OnMessage) then
    OnMessage(S);
  FMessageLabel.Caption := S;
  FMessageTimer := Duration;
end;

procedure TQuakeHud.DamageFlash(const Armor, Blood: Integer);
var
  Count: Integer;
begin
  Count := Max(Armor + Blood, 10);
  FDamageShift.Percent := Min(150, FDamageShift.Percent + 3 * Count);
  if Armor > Blood then
    FDamageShift.Dest := Vector3(200, 100, 100)
  else if Armor > 0 then
    FDamageShift.Dest := Vector3(220, 50, 50)
  else
    FDamageShift.Dest := Vector3(255, 0, 0);
end;

procedure TQuakeHud.BonusFlash;
begin
  FBonusShift := ColorShift(215, 186, 69, 50);
end;

procedure TQuakeHud.SetContents(const Contents: Integer);
begin
  case Contents of
    CONTENTS_WATER: FContentsShift := ColorShift(130, 80, 50, 128);
    CONTENTS_SLIME: FContentsShift := ColorShift(0, 25, 5, 150);
    CONTENTS_LAVA:  FContentsShift := ColorShift(255, 80, 0, 150);
    else            FContentsShift := ColorShift(0, 0, 0, 0);
  end;
end;

function TQuakeHud.CalcBlend: TVector4;
var
  Shifts: array[0..3] of TQuakeColorShift;
  I: Integer;
  A, A2: Single;
  Rgb: TVector3;
begin
  { V_CalcBlend: layer every active shift over the previous ones }
  Shifts[0] := FContentsShift;
  Shifts[1] := FDamageShift;
  Shifts[2] := FBonusShift;
  Shifts[3] := FPowerupShift;
  A := 0;
  Rgb := TVector3.Zero;
  for I := 0 to High(Shifts) do
  begin
    A2 := Shifts[I].Percent / 255.0;
    if A2 <= 0 then
      Continue;
    A := A + A2 * (1 - A);
    A2 := A2 / A;
    Rgb := Rgb * (1 - A2) + Shifts[I].Dest * A2;
  end;
  Result := Vector4(Rgb / 255.0, Min(A, 1.0));
end;

procedure TQuakeHud.Update(const SecondsPassed: Single; const Stats: TQuakePlayerStats);
var
  Mins, Secs: Integer;
begin
  FStats := Stats;
  if FIntermission then
    UpdateIntermission(SecondsPassed);
  FMessageLabel.Exists := not FIntermission;
  FStatsLabel.Exists := FStatsVisible and not FIntermission;
  FStatusFrame.Exists := not FIntermission;
  FAirBar.Exists := Stats.Underwater and not FIntermission;
  FAirFill.Width := 600 * EnsureRange(Stats.AirLeft / 12.0, 0, 1);

  { The status bar values and their colors }
  FArmorValue.Caption := IntToStr(Max(0, Stats.Armor));
  if Stats.Armor > 100 then
    FArmorValue.Color := Vector4(1.0, 0.85, 0.1, 1.0)
  else if Stats.Armor > 0 then
    FArmorValue.Color := Vector4(0.35, 0.9, 0.35, 1.0)
  else
    FArmorValue.Color := Vector4(0.5, 0.5, 0.5, 0.7);
  FHealthValue.Caption := IntToStr(Max(0, Stats.Health));
  if Stats.Health > 100 then
    FHealthValue.Color := Vector4(0.4, 0.7, 1.0, 1.0)
  else if Stats.Health > 25 then
    FHealthValue.Color := Vector4(0.95, 0.95, 0.95, 1.0)
  else
    FHealthValue.Color := Vector4(1.0, 0.25, 0.25, 1.0);
  FAmmoValue.Caption := IntToStr(Max(0, Stats.Ammo));
  FKeysLabel.Caption := '';
  if (Stats.Keys and 1) <> 0 then
    FKeysLabel.Caption := '[SILVER] ';
  if (Stats.Keys and 2) <> 0 then
    FKeysLabel.Caption := FKeysLabel.Caption + '[GOLD]';

  { Flashes fade out like in V_UpdatePalette }
  FDamageShift.Percent := Max(0, FDamageShift.Percent - 150 * SecondsPassed);
  FBonusShift.Percent := Max(0, FBonusShift.Percent - 100 * SecondsPassed);
  if Stats.BiosuitTime > 0 then
    FPowerupShift := ColorShift(0, 255, 0, 20)
  else
    FPowerupShift := ColorShift(0, 0, 0, 0);

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
    if FpsText <> '' then
      FStatsLabel.Caption := FStatsLabel.Caption + '   ' + FpsText;
  end else
    FStatsLabel.Caption := '';
end;

procedure TQuakeHud.Render;
var
  CX, CY: Single;
  R: TFloatRectangle;
  Blend: TVector4;
begin
  inherited Render;

  { 0. Palette shift over the 3D view (damage, pickups, liquids, powerups) }
  Blend := CalcBlend;
  if Blend.W > 0 then
    DrawRectangle(RenderRect, Blend);

  if FIntermission then
  begin
    RenderIntermission;
    Exit;
  end;

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

procedure TQuakeHud.StartIntermission(const ATitle: String; const ATime: Single;
  const AKills, ATotalKills, ASecrets, ATotalSecrets: Integer);
begin
  FIntermission := True;
  FInterTitle := ATitle;
  FInterTime := ATime;
  FInterKills := AKills;
  FInterTotalKills := ATotalKills;
  FInterSecrets := ASecrets;
  FInterTotalSecrets := ATotalSecrets;
  FInterClock := 0;
  FInterStage := 0;
  FInterShown := 0;
  FInterTick := 0;
  FInterReady := False;
  FDamageShift.Percent := 0;
  FBonusShift.Percent := 0;
  FContentsShift.Percent := 0;
end;

procedure TQuakeHud.StopIntermission;
begin
  FIntermission := False;
  FFinale := False;
  FFinaleText := '';
end;

procedure TQuakeHud.StartFinale(const AText: String);
begin
  FIntermission := True;
  FFinale := True;
  FFinaleText := AText;
  FFinaleClock := 0;
  FInterReady := False;
  FDamageShift.Percent := 0;
  FBonusShift.Percent := 0;
  FContentsShift.Percent := 0;
end;

procedure TQuakeHud.UpdateIntermission(const SecondsPassed: Single);
var
  Target, Before: Single;
begin
  FInterClock := FInterClock + SecondsPassed;
  if FFinale then
  begin
    FFinaleClock := FFinaleClock + SecondsPassed;
    Exit;
  end;
  if FInterStage > 2 then
    Exit;
  { Short pause before the counting starts }
  if FInterClock < 0.5 then
    Exit;

  case FInterStage of
    0: Target := Trunc(FInterTime);
    1: Target := FInterSecrets;
    else Target := FInterKills;
  end;
  Before := FInterShown;
  FInterShown := Min(Target, FInterShown + Max(Target, 1) * SecondsPassed / TallyDuration);

  { A tick for each counted step, a thud when a line is complete }
  FInterTick := FInterTick - SecondsPassed;
  if (Trunc(FInterShown) <> Trunc(Before)) and (FInterTick <= 0) then
  begin
    Sounds.Play('sound/misc/menu1.wav');
    FInterTick := 0.06;
  end;
  if FInterShown >= Target then
  begin
    Sounds.Play('sound/weapons/r_exp3.wav');
    Inc(FInterStage);
    FInterShown := 0;
  end;
end;

procedure TQuakeHud.RenderIntermission;
var
  Scale, OffX, OffY: Single;
  Shown: array[0..2] of Integer;

  { Draw a picture at Quake 320x200 screen coordinates (top left origin) }
  function DrawPic(const X, Y: Single; const Name: String): Boolean;
  var
    Pic: TDrawableImage;
  begin
    Pic := QuakePic(Name);
    Result := Pic <> nil;
    if Result then
      Pic.Draw(FloatRectangle(OffX + X * Scale, RenderRect.Height - OffY - (Y + Pic.Height) * Scale,
        Pic.Width * Scale, Pic.Height * Scale));
  end;

  procedure DrawText(const X, Y: Single; const S: String; const Centered: Boolean = False);
  var
    PX: Single;
  begin
    PX := OffX + X * Scale;
    if Centered then
      PX := PX - UIFont.TextWidth(S) / 2;
    UIFont.Print(PX, RenderRect.Height - OffY - Y * Scale - UIFont.Height,
      Vector4(1.0, 0.85, 0.35, 1.0), S);
  end;

  { Sbar_IntermissionNumber: right aligned in Digits places of 24 pixels }
  procedure DrawNumber(X: Single; const Y: Single; const Num, Digits: Integer);
  var
    S: String;
    I: Integer;
  begin
    S := IntToStr(Num);
    if Length(S) > Digits then
      S := Copy(S, Length(S) - Digits + 1, Digits);
    X := X + (Digits - Length(S)) * 24;
    for I := 1 to Length(S) do
    begin
      if S[I] = '-' then
      begin
        if not DrawPic(X, Y, 'num_minus') then
          DrawText(X + 12, Y, '-', True);
      end else
      if not DrawPic(X, Y, 'num_' + S[I]) then
        DrawText(X + 12, Y, S[I], True);
      X := X + 24;
    end;
  end;

  procedure DrawSeparator(const X, Y: Single; const Pic, Fallback: String);
  begin
    if not DrawPic(X, Y, Pic) then
      DrawText(X + 6, Y, Fallback, True);
  end;

  { SCR_DrawCenterString of the finale: lines from y = 48, typed out at
    scr_printspeed (8 characters a second) }
  procedure DrawFinale;
  var
    Lines: TStringArray;
    I, Remaining: Integer;
    Line: String;
    Pic: TDrawableImage;
  begin
    Pic := QuakePic('gfx/finale.lmp');
    if Pic <> nil then
      DrawPic(160 - Pic.Width / 2, 16, 'gfx/finale.lmp')
    else
      DrawText(160, 16, 'FINALE', True);
    Remaining := Trunc(FFinaleClock * 8);
    Lines := FFinaleText.Split([#10]);
    for I := 0 to High(Lines) do
    begin
      if Remaining <= 0 then
        Break;
      Line := Copy(Lines[I], 1, Remaining);
      Remaining := Remaining - Length(Lines[I]);
      DrawText(160, 48 + I * 8, Line, True);
    end;
  end;

var
  Complete: TDrawableImage;
  I, Secs: Integer;
begin
  { The 320x200 Quake screen, scaled up and centered }
  Scale := Min(RenderRect.Width / 320, RenderRect.Height / 200);
  OffX := (RenderRect.Width - 320 * Scale) / 2;
  OffY := (RenderRect.Height - 200 * Scale) / 2;

  DrawRectangle(RenderRect, Vector4(0, 0, 0, 0.35));

  if FFinale then
  begin
    DrawFinale;
    Exit;
  end;

  { Values counted so far: finished stages show their total }
  Shown[0] := Trunc(FInterTime);
  Shown[1] := FInterSecrets;
  Shown[2] := FInterKills;
  for I := 0 to 2 do
    if I > FInterStage then
      Shown[I] := 0
    else if I = FInterStage then
      Shown[I] := Trunc(FInterShown);

  if FInterTitle <> '' then
    DrawText(160, 6, FInterTitle, True);

  Complete := QuakePic('gfx/complete.lmp');
  if Complete <> nil then
    DrawPic(160 - Complete.Width / 2, 24, 'gfx/complete.lmp')
  else
    DrawText(160, 30, 'COMPLETED', True);

  if not DrawPic(0, 56, 'gfx/inter.lmp') then
  begin
    DrawText(40, 64, 'Time');
    DrawText(40, 104, 'Secrets');
    DrawText(40, 144, 'Kills');
  end;

  { Time as minutes:seconds }
  Secs := Shown[0];
  DrawNumber(160, 64, Secs div 60, 3);
  DrawSeparator(234, 64, 'num_colon', ':');
  DrawNumber(246, 64, (Secs mod 60) div 10, 1);
  DrawNumber(266, 64, Secs mod 10, 1);

  DrawNumber(160, 104, Shown[1], 3);
  DrawSeparator(232, 104, 'num_slash', '/');
  DrawNumber(240, 104, FInterTotalSecrets, 3);

  DrawNumber(160, 144, Shown[2], 3);
  DrawSeparator(232, 144, 'num_slash', '/');
  DrawNumber(240, 144, FInterTotalKills, 3);

  if FInterReady and (FInterStage > 2) then
    DrawText(160, 184, 'Press fire to continue', True);
end;

end.
