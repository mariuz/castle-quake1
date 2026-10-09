{ Quake 1 sound effects and music player using Castle Game Engine audio. }
unit QuakeSound;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections,
  CastleVectors, CastleSoundEngine, CastleTransform, CastleBehaviors, CastleLog,
  QuakePak;

type
  { Sound manager for Quake SFX and music }
  TQuakeSounds = class
  private
    FSoundCache: specialize TObjectDictionary<String, TCastleSound>;
    FMusicSound: TCastleSound;
    FCurrentMusicTrack: String;
    FEnabled: Boolean;
  public
    { Demo recording: every sound played (Spatial = False for Play) }
    OnPlay: procedure(const APath: String; const Spatial: Boolean; const ATransform: TCastleTransform;
      const Volume: Single) of object;
    function GetSound(const APath: String): TCastleSound;
  public
    constructor Create;
    destructor Destroy; override;

    { Play 2D non-positional sound (weapon fire, UI, player damage) }
    procedure Play(const APath: String; const Volume: Single = 1.0);

    { Play 3D positional sound attached to a transform (door, monster, elevator) }
    procedure PlayAt(const APath: String; const ATransform: TCastleTransform;
      const Volume: Single = 1.0; const RefDist: Single = 200.0; const MaxDist: Single = 1800.0);

    { Play background music from castle-data:/music/trackXX.ogg or file }
    procedure PlayMusic(const TrackName: String);

    { Stop music }
    procedure StopMusic;

    { Preload common player and weapon sounds }
    procedure PreloadCommonSounds;

    property Enabled: Boolean read FEnabled write FEnabled;
  end;

var
  Sounds: TQuakeSounds;

implementation

constructor TQuakeSounds.Create;
begin
  inherited Create;
  FSoundCache := specialize TObjectDictionary<String, TCastleSound>.Create([doOwnsValues]);
  FEnabled := True;
  FMusicSound := nil;
  FCurrentMusicTrack := '';
end;

destructor TQuakeSounds.Destroy;
begin
  StopMusic;
  FSoundCache.Free;
  inherited Destroy;
end;

function TQuakeSounds.GetSound(const APath: String): TCastleSound;
var
  NormPath: String;
begin
  NormPath := LowerCase(APath);
  if not FSoundCache.TryGetValue(NormPath, Result) then
  begin
    Result := TCastleSound.Create(nil);
    Result.Url := 'quakepak:/' + NormPath;
    FSoundCache.Add(NormPath, Result);
  end;
end;

procedure TQuakeSounds.Play(const APath: String; const Volume: Single);
var
  Snd: TCastleSound;
  Playing: TCastlePlayingSound;
begin
  if Assigned(OnPlay) then
    OnPlay(APath, False, nil, Volume);
  if not FEnabled or (SoundEngine = nil) then
    Exit;

  try
    Snd := GetSound(APath);
    if Snd <> nil then
    begin
      Playing := TCastlePlayingSound.Create(nil);
      Playing.Sound := Snd;
      Playing.Volume := Volume;
      Playing.FreeOnStop := True;
      SoundEngine.Play(Playing);
    end;
  except
    on E: Exception do
      WritelnWarning('QuakeSound', 'Failed to play "%s": %s', [APath, E.Message]);
  end;
end;

procedure TQuakeSounds.PlayAt(const APath: String; const ATransform: TCastleTransform;
  const Volume: Single; const RefDist, MaxDist: Single);
var
  Snd: TCastleSound;
  Source: TCastleSoundSource;
begin
  if Assigned(OnPlay) and (ATransform <> nil) then
    OnPlay(APath, True, ATransform, Volume);
  if not FEnabled or (SoundEngine = nil) or (ATransform = nil) then
    Exit;

  try
    Snd := GetSound(APath);
    if Snd = nil then
      Exit;

    Snd.ReferenceDistance := RefDist;
    Snd.MaxDistance := MaxDist;

    Source := ATransform.FindBehavior(TCastleSoundSource) as TCastleSoundSource;
    if Source = nil then
    begin
      Source := TCastleSoundSource.Create(ATransform);
      Source.Spatial := True;
      ATransform.AddBehavior(Source);
    end;
    Source.Volume := Volume;
    Source.Play(Snd);
  except
    on E: Exception do
      WritelnWarning('QuakeSound', 'Failed to play 3D sound "%s": %s', [APath, E.Message]);
  end;
end;

procedure TQuakeSounds.PlayMusic(const TrackName: String);
var
  MusicUrl: String;
begin
  if not FEnabled or (SoundEngine = nil) then
    Exit;

  if FCurrentMusicTrack = TrackName then
    Exit;

  StopMusic;

  { Look in castle-data:/music/ first, or quakepak }
  MusicUrl := 'castle-data:/music/' + TrackName;
  try
    FMusicSound := TCastleSound.Create(nil);
    FMusicSound.Url := MusicUrl;
    SoundEngine.LoopingChannel[0].Volume := 0.7;
    SoundEngine.LoopingChannel[0].Sound := FMusicSound;
    FCurrentMusicTrack := TrackName;
    WritelnLog('QuakeSound', 'Playing music "%s"', [MusicUrl]);
  except
    on E: Exception do
    begin
      WritelnWarning('QuakeSound', 'Could not play music track "%s": %s', [TrackName, E.Message]);
      FreeAndNil(FMusicSound);
    end;
  end;
end;

procedure TQuakeSounds.StopMusic;
begin
  if SoundEngine <> nil then
    SoundEngine.LoopingChannel[0].Sound := nil;
  FreeAndNil(FMusicSound);
  FCurrentMusicTrack := '';
end;

procedure TQuakeSounds.PreloadCommonSounds;
begin
  { Warm up frequently used sounds }
  GetSound('sound/weapons/sgun1.wav');
  GetSound('sound/weapons/shotgn2.wav');
  GetSound('sound/weapons/rocket1i.wav');
  GetSound('sound/weapons/r_exp3.wav');
  GetSound('sound/weapons/ax1.wav');
  GetSound('sound/items/r_item1.wav');
  GetSound('sound/items/health1.wav');
  GetSound('sound/items/armor1.wav');
  GetSound('sound/player/pain1.wav');
  GetSound('sound/player/death1.wav');
  GetSound('sound/player/jump.wav');
  GetSound('sound/player/land.wav');
  GetSound('sound/doors/dr1_strt.wav');
  GetSound('sound/doors/dr1_end.wav');
end;

initialization
  Sounds := TQuakeSounds.Create;

finalization
  FreeAndNil(Sounds);
end.
