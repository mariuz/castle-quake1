{ Quake 1 ambient sounds: looping static emitters placed by map entities
  (ambient_*, torches, fluorescent lights) and the BSP leaf ambients
  (water and wind) that follow the player. }
unit QuakeAmbient;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, Math,
  CastleVectors, CastleTransform, CastleBehaviors, CastleSoundEngine, CastleLog,
  QuakeBsp, QuakeLight, QuakeSound, QuakePak;

type
  { One looping sound at a fixed position (ambientsound() in QuakeC) }
  TQuakeStaticSound = class
  public
    Origin: TVector3; { CGE coordinates }
    Volume: Single;
    Sound: TCastleSound;
    Transform: TCastleTransform;
    Source: TCastleSoundSource; { only while one of the closest emitters }
    Gain: Single;
    destructor Destroy; override;
  end;

  TQuakeStaticSoundList = specialize TObjectList<TQuakeStaticSound>;
  TCastleSoundDict = specialize TObjectDictionary<String, TCastleSound>;

  TQuakeAmbientSounds = class
  private
    FBsp: TQuakeBsp;
    FStatics: TQuakeStaticSoundList;
    FSoundCache: TCastleSoundDict;
    { Leaf ambients: AMBIENT_WATER and AMBIENT_SKY (slime and lava have no sound) }
    FLeafSounds: array[0..1] of TCastleSound;
    FLeafPlaying: array[0..1] of TCastlePlayingSound;
    FLeafVolume: array[0..1] of Single;
    function GetSound(const Path: String): TCastleSound;
  public
    { An emitter at a point (ambientsound in QuakeC); Origin in CGE coordinates }
    procedure AddStatic(const Parent: TCastleTransform; const Origin: TVector3;
      const Path: String; const Volume: Single);
  private
    procedure UpdateStatics(const ListenerPos: TVector3);
    procedure UpdateLeafAmbients(const SecondsPassed: Single; const ListenerPos: TVector3);
    procedure StopLeafAmbients;
  public
    constructor Create;
    destructor Destroy; override;

    { Create emitters for the entities of a freshly loaded map }
    procedure Setup(const ABsp: TQuakeBsp; const Parent: TCastleTransform);

    { Remove all emitters (before loading another map) }
    procedure Clear;

    { Attenuate emitters and fade leaf ambients for the listener (camera) position }
    procedure Update(const SecondsPassed: Single; const ListenerPos: TVector3);
  end;

{ Ambient sound and volume that QuakeC spawns for an entity class.
  Returns False when the class makes no ambient sound. }
function AmbientSoundForClass(const ClassName: String; out Path: String;
  out Volume: Single): Boolean;

implementation

const
  { ATTN_STATIC: static sounds fade out linearly over sound_nominal_clip_dist / 3 }
  StaticClipDistance = 1000.0 / 3.0;
  { Only the closest emitters get a sound source; the engine has a small pool }
  MaxActiveStatics = 8;
  { ambient_level and ambient_fade cvars (S_UpdateAmbientSounds) }
  AmbientLevel = 0.3;
  AmbientFade = 100.0;

function AmbientSoundForClass(const ClassName: String; out Path: String;
  out Volume: Single): Boolean;
begin
  Result := True;
  Volume := 0.5;
  if ClassName = 'ambient_suck_wind' then
  begin
    Path := 'sound/ambience/suck1.wav';
    Volume := 1.0;
  end else
  if ClassName = 'ambient_drone' then
    Path := 'sound/ambience/drone6.wav'
  else
  if ClassName = 'ambient_flouro_buzz' then
  begin
    Path := 'sound/ambience/buzz1.wav';
    Volume := 1.0;
  end else
  if ClassName = 'ambient_drip' then
    Path := 'sound/ambience/drip1.wav'
  else
  if ClassName = 'ambient_comp_hum' then
  begin
    Path := 'sound/ambience/comp1.wav';
    Volume := 1.0;
  end else
  if ClassName = 'ambient_thunder' then
    Path := 'sound/ambience/thunder1.wav'
  else
  if ClassName = 'ambient_light_buzz' then
    Path := 'sound/ambience/fl_hum1.wav'
  else
  if ClassName = 'ambient_swamp1' then
    Path := 'sound/ambience/swamp1.wav'
  else
  if ClassName = 'ambient_swamp2' then
    Path := 'sound/ambience/swamp2.wav'
  else
  if ClassName = 'light_fluoro' then
    Path := 'sound/ambience/fl_hum1.wav'
  else
  if ClassName = 'light_fluorospark' then
    Path := 'sound/ambience/buzz1.wav'
  else
  if (ClassName = 'light_torch_small_walltorch') or
     (ClassName = 'light_flame_large_yellow') or
     (ClassName = 'light_flame_small_yellow') or
     (ClassName = 'light_flame_small_white') then
    Path := 'sound/ambience/fire1.wav'
  else
  begin
    Path := '';
    Volume := 0;
    Result := False;
  end;
end;

{ TQuakeStaticSound }

destructor TQuakeStaticSound.Destroy;
begin
  { Frees the sound source behavior too }
  Transform.Free;
  inherited Destroy;
end;

{ TQuakeAmbientSounds }

constructor TQuakeAmbientSounds.Create;
begin
  inherited Create;
  FStatics := TQuakeStaticSoundList.Create(True);
  FSoundCache := TCastleSoundDict.Create([doOwnsValues]);
end;

destructor TQuakeAmbientSounds.Destroy;
begin
  Clear;
  FStatics.Free;
  FSoundCache.Free;
  inherited Destroy;
end;

function TQuakeAmbientSounds.GetSound(const Path: String): TCastleSound;
begin
  if not FSoundCache.TryGetValue(Path, Result) then
  begin
    Result := TCastleSound.Create(nil);
    Result.Url := 'quakepak:/' + Path;
    { Attenuation is computed here (Quake's linear falloff), so keep the
      engine's distance gain at 1: the distance is always clamped to 1000
      and both reference and max distance are 1000. Only panning remains. }
    Result.ReferenceDistance := 1000;
    Result.MaxDistance := 1000;
    FSoundCache.Add(Path, Result);
  end;
end;

procedure TQuakeAmbientSounds.AddStatic(const Parent: TCastleTransform;
  const Origin: TVector3; const Path: String; const Volume: Single);
var
  S: TQuakeStaticSound;
begin
  S := TQuakeStaticSound.Create;
  S.Origin := Origin;
  S.Volume := Volume;
  S.Sound := GetSound(Path);
  S.Transform := TCastleTransform.Create(nil);
  S.Transform.Name := ComponentName('ambient_' + ChangeFileExt(ExtractFileName(Path), ''));
  S.Transform.Translation := Origin;
  Parent.Add(S.Transform);
  FStatics.Add(S);
end;

procedure TQuakeAmbientSounds.Setup(const ABsp: TQuakeBsp; const Parent: TCastleTransform);
var
  Ent: TQuakeEntity;
  Path: String;
  Volume: Single;
  I: Integer;
begin
  Clear;
  FBsp := ABsp;
  if (FBsp = nil) or (Parent = nil) then
    Exit;

  for Ent in FBsp.Entities do
    if AmbientSoundForClass(LowerCase(Ent.ClassName), Path, Volume) then
      AddStatic(Parent, QuakeToCge(Ent.Origin), Path, Volume);

  for I := 0 to High(FLeafSounds) do
  begin
    FLeafVolume[I] := 0;
    if FLeafSounds[I] = nil then
    begin
      if I = 0 then
        FLeafSounds[I] := GetSound('sound/ambience/water1.wav')
      else
        FLeafSounds[I] := GetSound('sound/ambience/wind2.wav');
    end;
  end;

  WritelnLog('QuakeAmbient', 'Created %d ambient sound emitters', [FStatics.Count]);
end;

procedure TQuakeAmbientSounds.StopLeafAmbients;
var
  I: Integer;
begin
  for I := 0 to High(FLeafPlaying) do
  begin
    if FLeafPlaying[I] <> nil then
    begin
      FLeafPlaying[I].Stop;
      FreeAndNil(FLeafPlaying[I]);
    end;
    FLeafVolume[I] := 0;
  end;
end;

procedure TQuakeAmbientSounds.Clear;
begin
  StopLeafAmbients;
  FStatics.Clear;
  FBsp := nil;
end;

procedure TQuakeAmbientSounds.UpdateStatics(const ListenerPos: TVector3);
var
  S: TQuakeStaticSound;
  Active: array[0..MaxActiveStatics - 1] of TQuakeStaticSound;
  ActiveCount, I, J: Integer;
  IsActive: Boolean;
begin
  { SND_Spatialize: volume falls linearly with distance }
  for S in FStatics do
    S.Gain := S.Volume * Max(0, 1 - PointsDistance(S.Origin, ListenerPos) / StaticClipDistance);

  { Keep the loudest emitters (insertion into a short sorted array) }
  FillChar(Active, SizeOf(Active), 0);
  ActiveCount := 0;
  for S in FStatics do
  begin
    if S.Gain <= 0.01 then
      Continue;
    I := ActiveCount;
    while (I > 0) and (Active[I - 1].Gain < S.Gain) do
      Dec(I);
    if I >= MaxActiveStatics then
      Continue;
    for J := Min(ActiveCount, MaxActiveStatics - 1) downto I + 1 do
      Active[J] := Active[J - 1];
    Active[I] := S;
    if ActiveCount < MaxActiveStatics then
      Inc(ActiveCount);
  end;

  for S in FStatics do
  begin
    IsActive := False;
    for I := 0 to ActiveCount - 1 do
      if Active[I] = S then
      begin
        IsActive := True;
        Break;
      end;

    if IsActive then
    begin
      if S.Source = nil then
      begin
        S.Source := TCastleSoundSource.Create(S.Transform);
        S.Source.Spatial := True;
        S.Transform.AddBehavior(S.Source);
        S.Source.Sound := S.Sound; { looping }
      end;
      S.Source.Volume := S.Gain;
      S.Source.SoundPlaying := True;
    end else
    if (S.Source <> nil) and S.Source.SoundPlaying then
      S.Source.SoundPlaying := False;
  end;
end;

procedure TQuakeAmbientSounds.UpdateLeafAmbients(const SecondsPassed: Single;
  const ListenerPos: TVector3);
var
  Leaf, I: Integer;
  Target: Single;
begin
  if FBsp = nil then
    Exit;
  Leaf := FBsp.PointLeaf(CgeToQuake(ListenerPos));

  for I := 0 to High(FLeafSounds) do
  begin
    { S_UpdateAmbientSounds: volume in 0..255 units, faded at ambient_fade per second }
    if Leaf >= 0 then
      Target := AmbientLevel * FBsp.Leaves[Leaf].AmbientLevel[I]
    else
      Target := 0;
    if Target < 8 then
      Target := 0;
    if FLeafVolume[I] < Target then
      FLeafVolume[I] := Min(Target, FLeafVolume[I] + SecondsPassed * AmbientFade)
    else
      FLeafVolume[I] := Max(Target, FLeafVolume[I] - SecondsPassed * AmbientFade);

    if FLeafVolume[I] > 0 then
    begin
      if FLeafPlaying[I] = nil then
      begin
        FLeafPlaying[I] := TCastlePlayingSound.Create(nil);
        FLeafPlaying[I].Sound := FLeafSounds[I];
        FLeafPlaying[I].Loop := True;
        SoundEngine.Play(FLeafPlaying[I]);
      end;
      FLeafPlaying[I].Volume := FLeafVolume[I] / 255;
    end else
    if FLeafPlaying[I] <> nil then
    begin
      FLeafPlaying[I].Stop;
      FreeAndNil(FLeafPlaying[I]);
    end;
  end;
end;

procedure TQuakeAmbientSounds.Update(const SecondsPassed: Single; const ListenerPos: TVector3);
begin
  if (SoundEngine = nil) or (Sounds = nil) or not Sounds.Enabled then
    Exit;
  try
    UpdateStatics(ListenerPos);
    UpdateLeafAmbients(SecondsPassed, ListenerPos);
  except
    on E: Exception do
      WritelnWarning('QuakeAmbient', 'Ambient sound update failed: %s', [E.Message]);
  end;
end;

end.
