{ Accessibility: captions for the sounds that carry information, and the
  high contrast HUD and reduced flashes options.

  Every sound the game plays goes through TQuakeSounds (the play, QuakeC,
  demo and network views alike); its OnCaption hook, called even with the
  sound off, gives the path and, for a positional sound, where it is. The
  sounds that matter (monsters waking and attacking, doors, lifts, buttons,
  secrets, pickups, teleports, explosions) have a caption; a positional one
  gets a hint of where it came from relative to the view: left, right,
  ahead or behind. The HUD shows the last few captions for a while. }
unit QuakeCaptions;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, CastleVectors, CastleTransform;

const
  { Seconds a caption stays }
  CaptionDuration = 3.0;
  { Captions shown at once }
  MaxCaptions = 4;

var
  { Captions for the sounds (Options, console "captions 0|1") }
  CaptionsEnabled: Boolean = False;
  { HUD in black, white and saturated colors (console "hud_contrast") }
  HighContrastHud: Boolean = False;
  { The damage and pickup flashes at a third, and no stronger than a light
    tint (console "reduced_flashes") }
  ReducedFlashes: Boolean = False;

type
  TCaptionDirection = (cdNone, cdAhead, cdLeft, cdRight, cdBehind);

  TQuakeCaption = record
    Text: String;
    Direction: TCaptionDirection;
    TimeLeft: Single;
  end;

  { The captions on screen }
  TQuakeCaptions = class
  private
    FItems: array of TQuakeCaption;
    FListenerPos, FListenerDir: TVector3;
    FChanged: Boolean;
    procedure HandleSound(const APath: String; const Spatial: Boolean; const ATransform: TCastleTransform);
  public
    { Logged for each new caption (tests) }
    LogCaptions: Boolean;
    constructor Create;
    { The camera, CGE coordinates (each frame) }
    procedure SetListener(const Pos, Dir: TVector3);
    { A sound was played; Pos (CGE) only matters when Spatial }
    procedure Add(const APath: String; const Spatial: Boolean; const Pos: TVector3);
    procedure Update(const SecondsPassed: Single);
    procedure Clear;
    { One line per caption, the newest last ('' when none) }
    function Text: String;
    function Count: Integer;
    { Something was added or went away since the last call }
    function TakeChanged: Boolean;
  end;

{ The caption of a sound path ('' for the ones without, like the player's
  own weapon, footsteps and the ambience) }
function SoundCaption(const APath: String): String;

{ Where a sound at SoundPos is from a listener at ListenerPos looking along
  ListenerDir (CGE coordinates, Y up; cdNone when it is close by) }
function CaptionDirection(const ListenerPos, ListenerDir, SoundPos: TVector3): TCaptionDirection;

function CaptionDirectionName(const D: TCaptionDirection): String;

{ How strong the palette flashes are (1, or less with ReducedFlashes) }
function FlashScale: Single;
{ The strongest flash (Percent of 255) }
function FlashLimit: Single;

var
  Captions: TQuakeCaptions;

implementation

uses
  CastleLog, QuakeSound, GameTranslate;

type
  TCaptionEntry = record
    Path: String;   { a file, or a directory ending with '/' }
    Text: String;
  end;

const
  CaptionTable: array[0..71] of TCaptionEntry = (
    { Monsters }
    (Path: 'sound/soldier/sight1.wav'; Text: 'Soldier shouts'),
    (Path: 'sound/soldier/sattck1.wav'; Text: 'Soldier fires'),
    (Path: 'sound/soldier/death1.wav'; Text: 'Soldier dies'),
    (Path: 'sound/dog/dsight.wav'; Text: 'Dog growls'),
    (Path: 'sound/dog/dattack1.wav'; Text: 'Dog bites'),
    (Path: 'sound/ogre/ogwake.wav'; Text: 'Ogre wakes'),
    (Path: 'sound/ogre/ogsawatk.wav'; Text: 'Chainsaw'),
    (Path: 'sound/ogre/ogdrag.wav'; Text: 'Ogre drags its chainsaw'),
    (Path: 'sound/knight/ksight.wav'; Text: 'Knight shouts'),
    (Path: 'sound/knight/sword1.wav'; Text: 'Sword swing'),
    (Path: 'sound/knight/sword2.wav'; Text: 'Sword swing'),
    (Path: 'sound/hknight/sight1.wav'; Text: 'Death knight roars'),
    (Path: 'sound/hknight/attack1.wav'; Text: 'Fireballs'),
    (Path: 'sound/hknight/slash1.wav'; Text: 'Sword slash'),
    (Path: 'sound/wizard/wsight.wav'; Text: 'Scrag shrieks'),
    (Path: 'sound/wizard/wattack.wav'; Text: 'Scrag spits'),
    (Path: 'sound/demon/sight2.wav'; Text: 'Fiend roars'),
    (Path: 'sound/demon/djump.wav'; Text: 'Fiend leaps'),
    (Path: 'sound/shambler/ssight.wav'; Text: 'Shambler roars'),
    (Path: 'sound/shambler/sattck1.wav'; Text: 'Shambler swipes'),
    (Path: 'sound/shambler/sboom.wav'; Text: 'Lightning charging'),
    (Path: 'sound/zombie/z_idle.wav'; Text: 'Zombie moans'),
    (Path: 'sound/zombie/z_shot1.wav'; Text: 'Zombie throws flesh'),
    (Path: 'sound/enforcer/sight1.wav'; Text: 'Enforcer shouts'),
    (Path: 'sound/enforcer/sight2.wav'; Text: 'Enforcer shouts'),
    (Path: 'sound/enforcer/sight3.wav'; Text: 'Enforcer shouts'),
    (Path: 'sound/enforcer/sight4.wav'; Text: 'Enforcer shouts'),
    (Path: 'sound/enforcer/enfire.wav'; Text: 'Laser fire'),
    (Path: 'sound/shalrath/sight.wav'; Text: 'Vore wails'),
    (Path: 'sound/shalrath/attack.wav'; Text: 'Vore attacks'),
    (Path: 'sound/tarbaby/sight1.wav'; Text: 'Spawn gurgles'),
    (Path: 'sound/tarbaby/jump1.wav'; Text: 'Spawn jumps'),
    (Path: 'sound/fish/bite.wav'; Text: 'Rotfish bites'),
    (Path: 'sound/boss1/sight1.wav'; Text: 'Chthon rises'),
    (Path: 'sound/boss1/throw.wav'; Text: 'Chthon throws lava'),
    (Path: 'sound/boss2/sight.wav'; Text: 'Shub-Niggurath'),
    { The world }
    (Path: 'sound/doors/'; Text: 'Door moves'),
    (Path: 'sound/plats/'; Text: 'Platform moves'),
    (Path: 'sound/buttons/'; Text: 'Button'),
    (Path: 'sound/misc/secret.wav'; Text: 'Secret found'),
    (Path: 'sound/misc/trigger1.wav'; Text: 'Something happened'),
    (Path: 'sound/misc/r_tele1.wav'; Text: 'Teleport'),
    (Path: 'sound/misc/r_tele2.wav'; Text: 'Teleport'),
    (Path: 'sound/misc/r_tele3.wav'; Text: 'Teleport'),
    (Path: 'sound/misc/r_tele4.wav'; Text: 'Teleport'),
    (Path: 'sound/misc/r_tele5.wav'; Text: 'Teleport'),
    (Path: 'sound/misc/runekey.wav'; Text: 'Rune'),
    (Path: 'sound/misc/medkey.wav'; Text: 'Key'),
    (Path: 'sound/misc/basekey.wav'; Text: 'Key'),
    (Path: 'sound/misc/power.wav'; Text: 'Power hum'),
    (Path: 'sound/ambience/thunder1.wav'; Text: 'Thunder'),
    (Path: 'sound/weapons/r_exp3.wav'; Text: 'Explosion'),
    (Path: 'sound/weapons/grenade.wav'; Text: 'Grenade launched'),
    (Path: 'sound/weapons/sgun1.wav'; Text: 'Rocket launched'),
    (Path: 'sound/weapons/spike2.wav'; Text: 'Nails'),
    (Path: 'sound/weapons/lhit.wav'; Text: 'Lightning'),
    (Path: 'sound/player/teledth1.wav'; Text: 'Telefrag'),
    { Pickups }
    (Path: 'sound/items/r_item1.wav'; Text: 'Health'),
    (Path: 'sound/items/r_item2.wav'; Text: 'Megahealth'),
    (Path: 'sound/items/health1.wav'; Text: 'Health'),
    (Path: 'sound/items/armor1.wav'; Text: 'Armor'),
    (Path: 'sound/weapons/pkup.wav'; Text: 'Weapon'),
    (Path: 'sound/weapons/lock4.wav'; Text: 'Ammo'),
    (Path: 'sound/items/damage.wav'; Text: 'Quad Damage'),
    (Path: 'sound/items/damage3.wav'; Text: 'Quad Damage'),
    (Path: 'sound/items/protect.wav'; Text: 'Pentagram of Protection'),
    (Path: 'sound/items/protect3.wav'; Text: 'Pentagram of Protection'),
    (Path: 'sound/items/inv1.wav'; Text: 'Ring of Shadows'),
    (Path: 'sound/items/suit.wav'; Text: 'Biosuit'),
    (Path: 'sound/items/suit2.wav'; Text: 'Biosuit wearing off'),
    (Path: 'sound/items/itembk2.wav'; Text: 'Item respawns'),
    (Path: 'sound/player/drown1.wav'; Text: 'Drowning')
  );

function SoundCaption(const APath: String): String;
var
  P: String;
  I: Integer;
begin
  P := LowerCase(APath);
  if Copy(P, 1, 6) <> 'sound/' then
    P := 'sound/' + P;
  for I := Low(CaptionTable) to High(CaptionTable) do
    if (P = CaptionTable[I].Path) or
       ((CaptionTable[I].Path[Length(CaptionTable[I].Path)] = '/') and
        (Copy(P, 1, Length(CaptionTable[I].Path)) = CaptionTable[I].Path)) then
      Exit(CaptionTable[I].Text);
  Result := '';
end;

function CaptionDirection(const ListenerPos, ListenerDir, SoundPos: TVector3): TCaptionDirection;
var
  ToSound, Forward: TVector2;
  Ahead, Side, Len: Single;
begin
  { Seen from above: X right and -Z forward of the world }
  ToSound := Vector2(SoundPos.X - ListenerPos.X, SoundPos.Z - ListenerPos.Z);
  Len := ToSound.Length;
  if Len < 96 then
    Exit(cdNone);
  Forward := Vector2(ListenerDir.X, ListenerDir.Z);
  if Forward.Length < 1e-4 then
    Exit(cdNone);
  Forward := Forward.Normalize;
  ToSound := ToSound / Len;
  Ahead := ToSound.X * Forward.X + ToSound.Y * Forward.Y;
  { Right of the view: Forward turned clockwise seen from above (-Z
    forward, +X right) }
  Side := ToSound.X * (-Forward.Y) + ToSound.Y * Forward.X;
  if Ahead > 0.75 then
    Result := cdAhead
  else if Ahead < -0.75 then
    Result := cdBehind
  else if Side > 0 then
    Result := cdRight
  else
    Result := cdLeft;
end;

function CaptionDirectionName(const D: TCaptionDirection): String;
begin
  case D of
    cdAhead: Result := 'ahead';
    cdLeft: Result := 'left';
    cdRight: Result := 'right';
    cdBehind: Result := 'behind';
    else Result := '';
  end;
end;

function FlashScale: Single;
begin
  if ReducedFlashes then
    Result := 1 / 3
  else
    Result := 1;
end;

function FlashLimit: Single;
begin
  if ReducedFlashes then
    Result := 40
  else
    Result := 255;
end;

{ TQuakeCaptions }

constructor TQuakeCaptions.Create;
begin
  inherited Create;
  FListenerDir := Vector3(0, 0, -1);
end;

procedure TQuakeCaptions.SetListener(const Pos, Dir: TVector3);
begin
  FListenerPos := Pos;
  FListenerDir := Dir;
end;

procedure TQuakeCaptions.HandleSound(const APath: String; const Spatial: Boolean; const ATransform: TCastleTransform);
begin
  if not CaptionsEnabled then
    Exit;
  if Spatial and (ATransform <> nil) then
    Add(APath, True, ATransform.WorldTranslation)
  else
    Add(APath, False, TVector3.Zero);
end;

procedure TQuakeCaptions.Add(const APath: String; const Spatial: Boolean; const Pos: TVector3);
var
  S: String;
  D: TCaptionDirection;
  I: Integer;
begin
  S := SoundCaption(APath);
  if S = '' then
    Exit;
  if Spatial then
    D := CaptionDirection(FListenerPos, FListenerDir, Pos)
  else
    D := cdNone;
  { The same caption again (a door's start and stop, several soldiers)
    renews the one shown }
  for I := 0 to High(FItems) do
    if FItems[I].Text = S then
    begin
      FItems[I].TimeLeft := CaptionDuration;
      if FItems[I].Direction <> D then
      begin
        FItems[I].Direction := D;
        FChanged := True;
      end;
      Exit;
    end;
  if Length(FItems) >= MaxCaptions then
    Delete(FItems, 0, 1);
  SetLength(FItems, Length(FItems) + 1);
  FItems[High(FItems)].Text := S;
  FItems[High(FItems)].Direction := D;
  FItems[High(FItems)].TimeLeft := CaptionDuration;
  FChanged := True;
  if LogCaptions then
  begin
    if D <> cdNone then
      WritelnLog('Captions', 'Caption: %s (%s)', [S, CaptionDirectionName(D)])
    else
      WritelnLog('Captions', 'Caption: %s', [S]);
  end;
end;

procedure TQuakeCaptions.Update(const SecondsPassed: Single);
var
  I: Integer;
begin
  for I := High(FItems) downto 0 do
  begin
    FItems[I].TimeLeft := FItems[I].TimeLeft - SecondsPassed;
    if FItems[I].TimeLeft <= 0 then
    begin
      Delete(FItems, I, 1);
      FChanged := True;
    end;
  end;
end;

procedure TQuakeCaptions.Clear;
begin
  if Length(FItems) > 0 then
    FChanged := True;
  FItems := nil;
end;

function TQuakeCaptions.Text: String;
var
  I: Integer;
  Line, T: String;
begin
  Result := '';
  for I := 0 to High(FItems) do
  begin
    { Shown in the current language (logged in English) }
    T := Tr(FItems[I].Text);
    case FItems[I].Direction of
      cdLeft: Line := '< ' + T;
      cdRight: Line := T + ' >';
      cdAhead: Line := '^ ' + T + ' ^';
      cdBehind: Line := '[' + Tr('behind') + '] ' + T;
      else Line := T;
    end;
    if Result <> '' then
      Result := Result + LineEnding;
    Result := Result + Line;
  end;
end;

function TQuakeCaptions.Count: Integer;
begin
  Result := Length(FItems);
end;

function TQuakeCaptions.TakeChanged: Boolean;
begin
  Result := FChanged;
  FChanged := False;
end;

initialization
  Captions := TQuakeCaptions.Create;
  Captions.LogCaptions := True;
  if Sounds <> nil then
    Sounds.OnCaption := @Captions.HandleSound;
finalization
  if (Sounds <> nil) and (TMethod(Sounds.OnCaption).Data = Pointer(Captions)) then
    Sounds.OnCaption := nil;
  FreeAndNil(Captions);
end.
