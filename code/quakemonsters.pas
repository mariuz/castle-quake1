{ Quake 1 monsters: class definitions taken from the QuakeC sources (sizes,
  health, frame ranges, speeds, sounds, attacks) and a Quake-style think loop
  (sight, chase with SV_movestep, CheckAttack, attacks on animation frames,
  pain, death, gibbing). The world provides traces, damage and missiles
  through TQuakeMonsterEnv. Coordinates are Quake coordinates. }
unit QuakeMonsters;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, Math,
  CastleVectors, CastleTransform, CastleScene, CastleLog,
  QuakeMdl, QuakeLight, QuakeSound, QuakePak;

type
  TMonsterState = (
    msIdle,   { waiting for the player }
    msWalk,   { chasing }
    msAttack, { playing a melee or missile attack }
    msPain,
    msLeap,   { dog, fiend and spawn jumps }
    msDown,   { zombie knocked to the ground }
    msHidden, { Chthon before he is woken }
    msRise,   { Chthon rising from the lava }
    msDeath,  { playing the death animation }
    msDead
  );

  TMonsterAttack = (maNone, maBullets, maGrenade, maWizSpike, maKnightSpike, maLaser,
    maVorePod, maZombieGib, maLavaBall, maLightning);

  TMonsterMove = (mmWalk, mmFly, mmSwim, mmStatic);

  TMonsterSeq = record
    First, Count: Integer;
  end;

  { Static description of a monster class }
  TMonsterDef = record
    ClassName, Model, Head: String;
    Health: Integer;
    GibHealth: Integer;   { gibs below this health; NoGib = never }
    Mins, Maxs: TVector3;
    Move: TMonsterMove;
    RunSpeed: Single;     { units per second while chasing }
    Stand, Run, Melee, Missile, Pain, Death, Leap, Extra: TMonsterSeq;
    MeleeRange: Single;   { starts a melee attack closer than this (0 = none) }
    MeleeFrames: Cardinal; { bit mask of Melee frames that strike }
    MeleeDamage: Single;  { maximum damage per strike }
    MissileKind: TMonsterAttack;
    MissileFrames: Cardinal;
    MissileRange: Single;
    LeapMin, LeapMax: Single; { leap when the player is this far }
    LeapFrame: Integer;
    LeapForward, LeapUp: Single;
    LeapDamage: Single;
    PainFactor: Single;   { pain animation only if Random * PainFactor < damage; < 0 never }
    Invulnerable: Boolean;
    SightSound, PainSound, DeathSound, IdleSound, MeleeSound, MissileSound: String;
    GibModels: array[0..2] of String;
  end;

  TQuakeMonster = class;

  { What a monster needs from the world }
  TQuakeMonsterEnv = class
  public
    function Time: Single; virtual; abstract;
    function PlayerOrigin: TVector3; virtual; abstract;
    function PlayerVelocity: TVector3; virtual; abstract;
    function PlayerAlive: Boolean; virtual; abstract;
    function CanSeePlayer(const M: TQuakeMonster): Boolean; virtual; abstract;
    { visible() towards another monster (infighting) }
    function CanSeeMonster(const M, Other: TQuakeMonster): Boolean; virtual; abstract;
    { sight_entity: a monster that has just spotted the player and that M can
      see (FindTarget lets M join the hunt); nil if none }
    function SightEntity(const M: TQuakeMonster): TQuakeMonster; virtual; abstract;
    { The player fired a weapon recently (show_hostile) }
    function PlayerHostile: Boolean; virtual; abstract;
    { SV_movestep: move by Move (walkers step up/down stairs, never walk off
      ledges; fliers and swimmers follow the player height). False if blocked. }
    function MoveStep(const M: TQuakeMonster; const Move: TVector3): Boolean; virtual; abstract;
    { One step of a ballistic leap (gravity); True when landed }
    function TossStep(const M: TQuakeMonster; const Dt: Single; out HitPlayer: Boolean;
      out HitMonster: TQuakeMonster): Boolean; virtual; abstract;
    procedure DamagePlayer(const M: TQuakeMonster; const Damage: Single); virtual; abstract;
    procedure DamageMonster(const M, Victim: TQuakeMonster; const Damage: Single); virtual; abstract;
    { Pellets towards Aim; they hit the player and monsters in the way }
    procedure FireBullets(const M: TQuakeMonster; const Count: Integer; const Spread: Single;
      const Aim: TVector3); virtual; abstract;
    procedure LaunchMissile(const M: TQuakeMonster; const Kind: TMonsterAttack;
      const Org, Vel: TVector3); virtual; abstract;
    procedure CastLightning(const M: TQuakeMonster; const Aim: TVector3); virtual; abstract;
  end;

  TQuakeMonster = class
  private
    FDef: TMonsterDef;
    FTime: Single;
    FThinkTimer: Single;
    FAttackFinished: Single;
    FPainFinished: Single;
    FIdleSoundTime: Single;
    FLastFrame: Integer;
    FAttackIsMelee: Boolean;
    FLeapLaunched, FLeapHit: Boolean;
    FStateTime: Single;
    FDodgeYaw: Single;
    FDodgeTime: Single;
    FDownPhase: Integer;
    FAlertAge: Single;
    function GetOrigin: TVector3;
    procedure SetOrigin(const Value: TVector3);
    procedure SetYaw(const Value: Single);
    procedure PlaySeq(const Seq: TMonsterSeq; const Loop: Boolean; const Restart: Boolean = False);
    procedure Wake;
    procedure FoundTarget(const NewEnemy: TQuakeMonster);
    function EnemyValid: Boolean;
    function EnemyOrigin(const Env: TQuakeMonsterEnv): TVector3;
    function EnemyAlive(const Env: TQuakeMonsterEnv): Boolean;
    function CanSeeEnemy(const Env: TQuakeMonsterEnv): Boolean;
    procedure DamageEnemy(const Env: TQuakeMonsterEnv; const Damage: Single);
    procedure CheckEnemy;
    procedure FindTarget(const Env: TQuakeMonsterEnv);
    procedure FacePlayer(const Env: TQuakeMonsterEnv; const Dt: Single);
    procedure Chase(const Env: TQuakeMonsterEnv; const Dt: Single);
    procedure CheckAttack(const Env: TQuakeMonsterEnv);
    procedure StartAttack(const Melee: Boolean);
    procedure FrameEvents(const Env: TQuakeMonsterEnv);
    procedure FrameEvent(const Env: TQuakeMonsterEnv; const Frame: Integer);
    procedure FireMissile(const Env: TQuakeMonsterEnv; const Frame: Integer);
    procedure UpdateLeap(const Env: TQuakeMonsterEnv; const Dt: Single);
    procedure UpdateDown(const Dt: Single);
    procedure Die;
  public
    Transform: TCastleTransform;
    Scene: TCastleScene;
    Mdl: TQuakeMdl;
    Animator: TMdlAnimator;
    EntityClassName: String;
    TargetName, Target: String;
    State: TMonsterState;
    Health: Integer;
    Yaw: Single;          { Quake degrees }
    Velocity: TVector3;   { leaps }
    OnGround: Boolean;
    SightAlerted: Boolean;
    { Events the world handles }
    GibPending: Boolean;     { burst into gibs }
    LavaSplashPending: Boolean; { Chthon rose: the lava splash effect (the world spawns it) }
    ExplodePending: Boolean; { spawn death explosion }
    DeathTargetPending: Boolean; { fire Target (Chthon) }
    KillCounted: Boolean;
    { Crucified zombie (spawnflags 1): hangs on the wall, never fights }
    Crucified: Boolean;
    { Ambush (spawnflags 1): only wakes up on sight of the player or damage,
      not on gunfire noise or other monsters spotting the player }
    Ambush: Boolean;
    { Monster being fought after friendly fire; nil = the player }
    Enemy: TQuakeMonster;
    { Nightmare skill: at most one pain animation every 5 seconds }
    Nightmare: Boolean;

    constructor Create(const Parent: TCastleTransform; const ADef: TMonsterDef;
      const AOrigin: TVector3; const AYaw: Single);
    destructor Destroy; override;

    procedure Update(const SecondsPassed: Single; const Env: TQuakeMonsterEnv);
    { Attacker = nil for the player (or the world) }
    procedure TakeDamage(const Damage: Integer; const Attacker: TQuakeMonster = nil);
    { Gunfire heard (the world decides who can hear it) }
    procedure HearNoise;
    { Spotted the player within the last moment (sight_entity) }
    function JustSpottedPlayer: Boolean;
    { Triggered by a target (monster_use / Chthon waking up) }
    procedure Use;
    { Chthon: hit by the electrodes (lightning_use) }
    procedure LightningShock;
    { Turn into a crucified zombie (not counted as a kill, like in QuakeC) }
    procedure Crucify;
    { Savegames: put the monster back into a saved state (an attack, pain
      or leap in progress resumes as chasing) }
    procedure RestoreState(const AState: TMonsterState; const AHealth: Integer; const AYaw: Single);

    { Blocks movement and shots (not dead, hidden or lying down) }
    function IsSolid: Boolean;
    function Center: TVector3;
    property Def: TMonsterDef read FDef;
    property Origin: TVector3 read GetOrigin write SetOrigin;
  end;

  TQuakeMonsterList = specialize TObjectList<TQuakeMonster>;

const
  NoGib = -100000;

{ Definition of a monster class (e.g. 'monster_army'); False if unknown }
function MonsterDef(const ClassName: String; out Def: TMonsterDef): Boolean;

implementation

function Seq(const First, Count: Integer): TMonsterSeq;
begin
  Result.First := First;
  Result.Count := Count;
end;

function Frames(const Indexes: array of Integer): Cardinal;
var
  I: Integer;
begin
  Result := 0;
  for I in Indexes do
    Result := Result or (Cardinal(1) shl I);
end;

function MonsterDef(const ClassName: String; out Def: TMonsterDef): Boolean;
begin
  Result := True;
  Def := Default(TMonsterDef);
  Def.ClassName := ClassName;
  Def.Mins := Vector3(-16, -16, -24);
  Def.Maxs := Vector3(16, 16, 40);
  Def.Move := mmWalk;
  Def.GibHealth := -35;
  Def.MissileRange := 1000;
  Def.LeapFrame := -1;
  Def.GibModels[0] := 'progs/gib1.mdl';
  Def.GibModels[1] := 'progs/gib2.mdl';
  Def.GibModels[2] := 'progs/gib3.mdl';

  { Frame ranges follow the $frame order of the QuakeC sources }
  if ClassName = 'monster_army' then
  begin
    Def.Model := 'progs/soldier.mdl';
    Def.Head := 'progs/h_guard.mdl';
    Def.Health := 30;
    Def.RunSpeed := 110;
    Def.Stand := Seq(0, 8);
    Def.Death := Seq(8, 10);
    Def.Pain := Seq(40, 6);
    Def.Run := Seq(73, 8);
    Def.Missile := Seq(81, 9);
    Def.MissileKind := maBullets;
    Def.MissileFrames := Frames([4]);
    Def.SightSound := 'sound/soldier/sight1.wav';
    Def.PainSound := 'sound/soldier/pain1.wav';
    Def.DeathSound := 'sound/soldier/death1.wav';
    Def.IdleSound := 'sound/soldier/idle.wav';
    Def.MissileSound := 'sound/soldier/sattck1.wav';
  end else
  if ClassName = 'monster_dog' then
  begin
    Def.Model := 'progs/dog.mdl';
    Def.Head := 'progs/h_dog.mdl';
    Def.Health := 25;
    Def.Mins := Vector3(-32, -32, -24);
    Def.Maxs := Vector3(32, 32, 40);
    Def.RunSpeed := 250;
    Def.Melee := Seq(0, 8);
    Def.Death := Seq(8, 9);
    Def.Pain := Seq(26, 6);
    Def.Run := Seq(48, 12);
    Def.Leap := Seq(60, 9);
    Def.Stand := Seq(69, 9);
    Def.MeleeRange := 80;
    Def.MeleeFrames := Frames([3]);
    Def.MeleeDamage := 24;
    Def.LeapMin := 80;
    Def.LeapMax := 150;
    Def.LeapFrame := 1;
    Def.LeapForward := 300;
    Def.LeapUp := 200;
    Def.LeapDamage := 20;
    Def.GibModels[0] := 'progs/gib3.mdl';
    Def.GibModels[1] := 'progs/gib3.mdl';
    Def.SightSound := 'sound/dog/dsight.wav';
    Def.PainSound := 'sound/dog/dpain1.wav';
    Def.DeathSound := 'sound/dog/ddeath.wav';
    Def.IdleSound := 'sound/dog/idle.wav';
    Def.MeleeSound := 'sound/dog/dattack1.wav';
  end else
  if ClassName = 'monster_ogre' then
  begin
    Def.Model := 'progs/ogre.mdl';
    Def.Head := 'progs/h_ogre.mdl';
    Def.Health := 200;
    Def.GibHealth := -80;
    Def.Mins := Vector3(-32, -32, -24);
    Def.Maxs := Vector3(32, 32, 64);
    Def.RunSpeed := 110;
    Def.Stand := Seq(0, 9);
    Def.Run := Seq(25, 8);
    Def.Melee := Seq(33, 14);
    Def.Missile := Seq(61, 6);
    Def.Pain := Seq(67, 5);
    Def.Death := Seq(112, 14);
    Def.MeleeRange := 100;
    Def.MeleeFrames := Frames([4, 5, 6, 7, 8, 9, 10]); { chainsaw }
    Def.MeleeDamage := 12;
    Def.MissileKind := maGrenade;
    Def.MissileFrames := Frames([2]);
    Def.GibModels[0] := 'progs/gib3.mdl';
    Def.GibModels[2] := 'progs/gib2.mdl';
    Def.SightSound := 'sound/ogre/ogwake.wav';
    Def.PainSound := 'sound/ogre/ogpain1.wav';
    Def.DeathSound := 'sound/ogre/ogdth.wav';
    Def.IdleSound := 'sound/ogre/ogidle.wav';
    Def.MeleeSound := 'sound/ogre/ogsawatk.wav';
    Def.MissileSound := 'sound/weapons/grenade.wav';
  end else
  if ClassName = 'monster_knight' then
  begin
    Def.Model := 'progs/knight.mdl';
    Def.Head := 'progs/h_knight.mdl';
    Def.Health := 75;
    Def.GibHealth := -40;
    Def.RunSpeed := 140;
    Def.Stand := Seq(0, 9);
    Def.Run := Seq(9, 8);
    Def.Pain := Seq(28, 3);
    Def.Melee := Seq(42, 11);
    Def.Death := Seq(76, 10);
    Def.MeleeRange := 80;
    Def.MeleeFrames := Frames([3, 4, 5, 6, 7]);
    Def.MeleeDamage := 9;
    Def.SightSound := 'sound/knight/ksight.wav';
    Def.PainSound := 'sound/knight/khurt.wav';
    Def.DeathSound := 'sound/knight/kdeath.wav';
    Def.IdleSound := 'sound/knight/idle.wav';
    Def.MeleeSound := 'sound/knight/sword1.wav';
  end else
  if ClassName = 'monster_hell_knight' then
  begin
    Def.Model := 'progs/hknight.mdl';
    Def.Head := 'progs/h_hellkn.mdl';
    Def.Health := 250;
    Def.GibHealth := -40;
    Def.RunSpeed := 190;
    Def.Stand := Seq(0, 9);
    Def.Run := Seq(29, 8);
    Def.Pain := Seq(37, 5);
    Def.Death := Seq(42, 12);
    Def.Melee := Seq(85, 10);
    Def.Missile := Seq(155, 11);
    Def.MeleeRange := 80;
    Def.MeleeFrames := Frames([3, 4, 5, 6, 7]);
    Def.MeleeDamage := 9;
    Def.MissileKind := maKnightSpike;
    Def.MissileFrames := Frames([5, 6, 7, 8, 9, 10]);
    Def.PainFactor := 30;
    Def.SightSound := 'sound/hknight/sight1.wav';
    Def.PainSound := 'sound/hknight/pain1.wav';
    Def.DeathSound := 'sound/hknight/death1.wav';
    Def.IdleSound := 'sound/hknight/idle.wav';
    Def.MeleeSound := 'sound/hknight/slash1.wav';
    Def.MissileSound := 'sound/hknight/attack1.wav';
  end else
  if ClassName = 'monster_enforcer' then
  begin
    Def.Model := 'progs/enforcer.mdl';
    Def.Head := 'progs/h_mega.mdl';
    Def.Health := 80;
    Def.RunSpeed := 120;
    Def.Stand := Seq(0, 7);
    Def.Run := Seq(23, 8);
    Def.Missile := Seq(31, 10);
    Def.Death := Seq(41, 14);
    Def.Pain := Seq(66, 4);
    Def.MissileKind := maLaser;
    Def.MissileFrames := Frames([5]);
    Def.SightSound := 'sound/enforcer/sight1.wav';
    Def.PainSound := 'sound/enforcer/pain1.wav';
    Def.DeathSound := 'sound/enforcer/death1.wav';
    Def.IdleSound := 'sound/enforcer/idle1.wav';
    Def.MissileSound := 'sound/enforcer/enfire.wav';
  end else
  if ClassName = 'monster_fish' then
  begin
    Def.Model := 'progs/fish.mdl';
    Def.Health := 25;
    Def.GibHealth := NoGib;
    Def.Maxs := Vector3(16, 16, 24);
    Def.Move := mmSwim;
    Def.RunSpeed := 120;
    Def.Melee := Seq(0, 18);
    Def.Death := Seq(18, 21);
    Def.Stand := Seq(39, 18);
    Def.Run := Seq(39, 18);
    Def.Pain := Seq(57, 9);
    Def.MeleeRange := 70;
    Def.MeleeFrames := Frames([2, 8, 14]);
    Def.MeleeDamage := 6;
    Def.DeathSound := 'sound/fish/death.wav';
    Def.IdleSound := 'sound/fish/idle.wav';
    Def.MeleeSound := 'sound/fish/bite.wav';
  end else
  if ClassName = 'monster_shalrath' then
  begin
    Def.Model := 'progs/shalrath.mdl';
    Def.Head := 'progs/h_shal.mdl';
    Def.Health := 400;
    Def.GibHealth := -90;
    Def.Mins := Vector3(-32, -32, -24);
    Def.Maxs := Vector3(32, 32, 48);
    Def.RunSpeed := 60;
    Def.Missile := Seq(0, 11);
    Def.Pain := Seq(11, 5);
    Def.Death := Seq(16, 7);
    Def.Stand := Seq(23, 1);
    Def.Run := Seq(23, 12);
    Def.MissileKind := maVorePod;
    Def.MissileFrames := Frames([8]);
    Def.SightSound := 'sound/shalrath/sight.wav';
    Def.PainSound := 'sound/shalrath/pain.wav';
    Def.DeathSound := 'sound/shalrath/death.wav';
    Def.IdleSound := 'sound/shalrath/idle.wav';
    Def.MissileSound := 'sound/shalrath/attack2.wav';
  end else
  if ClassName = 'monster_tarbaby' then
  begin
    Def.Model := 'progs/tarbaby.mdl';
    Def.Health := 80;
    Def.GibHealth := NoGib;
    Def.RunSpeed := 120;
    Def.Stand := Seq(0, 25);
    Def.Run := Seq(25, 25);
    Def.Leap := Seq(50, 6);
    Def.Extra := Seq(56, 4); { flying }
    Def.LeapMin := 0;
    Def.LeapMax := 400;
    Def.LeapFrame := 4;
    Def.LeapForward := 600;
    Def.LeapUp := 250;
    Def.LeapDamage := 20;
    Def.PainFactor := -1;
    Def.SightSound := 'sound/blob/sight1.wav';
    Def.DeathSound := 'sound/blob/death1.wav';
    Def.MeleeSound := 'sound/blob/hit1.wav';
  end else
  if ClassName = 'monster_demon1' then
  begin
    Def.Model := 'progs/demon.mdl';
    Def.Head := 'progs/h_demon.mdl';
    Def.Health := 300;
    Def.GibHealth := -80;
    Def.Mins := Vector3(-32, -32, -24);
    Def.Maxs := Vector3(32, 32, 64);
    Def.RunSpeed := 200;
    Def.Stand := Seq(0, 13);
    Def.Run := Seq(21, 6);
    Def.Leap := Seq(27, 12);
    Def.Pain := Seq(39, 6);
    Def.Death := Seq(45, 9);
    Def.Melee := Seq(54, 15);
    Def.MeleeRange := 100;
    Def.MeleeFrames := Frames([3, 10]);
    Def.MeleeDamage := 15;
    Def.LeapMin := 100;
    Def.LeapMax := 400;
    Def.LeapFrame := 2;
    Def.LeapForward := 600;
    Def.LeapUp := 250;
    Def.LeapDamage := 50;
    Def.PainFactor := 200;
    Def.SightSound := 'sound/demon/sight2.wav';
    Def.PainSound := 'sound/demon/dpain1.wav';
    Def.DeathSound := 'sound/demon/ddeath.wav';
    Def.IdleSound := 'sound/demon/idle1.wav';
    Def.MeleeSound := 'sound/demon/dhit2.wav';
    Def.MissileSound := 'sound/demon/djump.wav';
  end else
  if ClassName = 'monster_wizard' then
  begin
    Def.Model := 'progs/wizard.mdl';
    Def.Head := 'progs/h_wizard.mdl';
    Def.Health := 80;
    Def.GibHealth := -40;
    Def.Move := mmFly;
    Def.RunSpeed := 160;
    Def.Stand := Seq(0, 15);
    Def.Run := Seq(15, 14);
    Def.Missile := Seq(29, 13);
    Def.Pain := Seq(42, 4);
    Def.Death := Seq(46, 8);
    Def.MissileKind := maWizSpike;
    Def.MissileFrames := Frames([4, 6]);
    Def.PainFactor := 70;
    Def.SightSound := 'sound/wizard/wsight.wav';
    Def.PainSound := 'sound/wizard/wpain.wav';
    Def.DeathSound := 'sound/wizard/wdeath.wav';
    Def.IdleSound := 'sound/wizard/widle1.wav';
    Def.MissileSound := 'sound/wizard/wattack.wav';
  end else
  if ClassName = 'monster_shambler' then
  begin
    Def.Model := 'progs/shambler.mdl';
    Def.Head := 'progs/h_shams.mdl';
    Def.Health := 600;
    Def.GibHealth := -60;
    Def.Mins := Vector3(-32, -32, -24);
    Def.Maxs := Vector3(32, 32, 64);
    Def.RunSpeed := 200;
    Def.Stand := Seq(0, 17);
    Def.Run := Seq(29, 6);
    Def.Melee := Seq(35, 12);
    Def.Missile := Seq(65, 12);
    Def.Pain := Seq(77, 6);
    Def.Death := Seq(83, 11);
    Def.MeleeRange := 100;
    Def.MeleeFrames := Frames([9]);
    Def.MeleeDamage := 120;
    Def.MissileKind := maLightning;
    Def.MissileFrames := Frames([5, 8, 9]);
    Def.MissileRange := 600;
    Def.PainFactor := 400;
    Def.SightSound := 'sound/shambler/ssight.wav';
    Def.PainSound := 'sound/shambler/shurt2.wav';
    Def.DeathSound := 'sound/shambler/sdeath.wav';
    Def.IdleSound := 'sound/shambler/sidle.wav';
    Def.MeleeSound := 'sound/shambler/smack.wav';
    Def.MissileSound := 'sound/shambler/sboom.wav';
  end else
  if ClassName = 'monster_zombie' then
  begin
    Def.Model := 'progs/zombie.mdl';
    Def.Head := 'progs/h_zombie.mdl';
    Def.Health := 60;
    Def.GibHealth := 0; { zombies only die by being gibbed }
    Def.RunSpeed := 60;
    Def.Stand := Seq(0, 15);
    Def.Run := Seq(34, 18);
    Def.Missile := Seq(52, 13);
    Def.Pain := Seq(91, 12);
    Def.Extra := Seq(162, 30); { knocked down and getting up }
    Def.MissileKind := maZombieGib;
    Def.MissileFrames := Frames([12]);
    Def.SightSound := 'sound/zombie/z_idle.wav';
    Def.PainSound := 'sound/zombie/z_pain.wav';
    Def.DeathSound := 'sound/zombie/z_gib.wav';
    Def.IdleSound := 'sound/zombie/z_idle1.wav';
    Def.MissileSound := 'sound/zombie/z_shot1.wav';
  end else
  if ClassName = 'monster_boss' then
  begin
    { Chthon: only the electrodes of E1M7 can hurt him (3 shocks) }
    Def.Model := 'progs/boss.mdl';
    Def.Health := 3;
    Def.GibHealth := NoGib;
    Def.Mins := Vector3(-128, -128, -24);
    Def.Maxs := Vector3(128, 128, 256);
    Def.Move := mmStatic;
    Def.Leap := Seq(0, 17); { rise }
    Def.Stand := Seq(17, 31);
    Def.Death := Seq(48, 9);
    Def.Missile := Seq(57, 23);
    Def.Pain := Seq(80, 10); { shock }
    Def.MissileKind := maLavaBall;
    Def.MissileFrames := Frames([8, 19]);
    Def.MissileRange := 100000;
    Def.PainFactor := -1;
    Def.Invulnerable := True;
    Def.SightSound := 'sound/boss1/sight1.wav';
    Def.PainSound := 'sound/boss1/pain.wav';
    Def.DeathSound := 'sound/boss1/death.wav';
    Def.MissileSound := 'sound/boss1/throw.wav';
  end else
  if ClassName = 'monster_oldone' then
  begin
    { Shub-Niggurath: a stationary, invulnerable end boss }
    Def.Model := 'progs/oldone.mdl';
    Def.Health := 40000;
    Def.GibHealth := NoGib;
    Def.Mins := Vector3(-160, -128, -24);
    Def.Maxs := Vector3(160, 128, 256);
    Def.Move := mmStatic;
    Def.Stand := Seq(0, 46);
    Def.PainFactor := -1;
    Def.Invulnerable := True;
    Def.IdleSound := 'sound/boss2/idle.wav';
  end else
    Result := False;
end;

{ TQuakeMonster }

constructor TQuakeMonster.Create(const Parent: TCastleTransform; const ADef: TMonsterDef;
  const AOrigin: TVector3; const AYaw: Single);
begin
  inherited Create;
  FDef := ADef;
  EntityClassName := ADef.ClassName;
  Health := ADef.Health;
  State := msIdle;
  FLastFrame := -1;
  FIdleSoundTime := 5 + Random * 10;
  FAlertAge := 1000;

  Transform := TCastleTransform.Create(nil);
  Transform.Name := ComponentName(ADef.ClassName);
  Mdl := MdlManager.GetModel(ADef.Model);
  if Mdl <> nil then
  begin
    Scene := Mdl.CreateScene(0);
    Scene.Name := Transform.Name + '_scene';
    Transform.Add(Scene);
    Animator := TMdlAnimator.Create(Mdl, Scene);
    PlaySeq(FDef.Stand, True);
  end;
  Origin := AOrigin;
  SetYaw(AYaw);
  OnGround := ADef.Move = mmWalk;
  if ADef.ClassName = 'monster_boss' then
  begin
    { Chthon waits hidden in the lava until his trigger fires }
    State := msHidden;
    Transform.Exists := False;
  end;
  Parent.Add(Transform);
end;

destructor TQuakeMonster.Destroy;
begin
  Animator.Free;
  Transform.Free;
  inherited Destroy;
end;

function TQuakeMonster.GetOrigin: TVector3;
begin
  Result := CgeToQuake(Transform.Translation);
end;

procedure TQuakeMonster.SetOrigin(const Value: TVector3);
begin
  Transform.Translation := QuakeToCge(Value);
end;

procedure TQuakeMonster.SetYaw(const Value: Single);
begin
  Yaw := Value;
  { Models face Quake +X at yaw 0; Quake yaw turns around the CGE +Y axis }
  Transform.Rotation := Vector4(0, 1, 0, DegToRad(Yaw));
end;

function TQuakeMonster.Center: TVector3;
begin
  Result := Origin + (FDef.Mins + FDef.Maxs) * 0.5;
end;

function TQuakeMonster.IsSolid: Boolean;
begin
  Result := not (State in [msDeath, msDead, msHidden, msDown]);
end;

procedure TQuakeMonster.PlaySeq(const Seq: TMonsterSeq; const Loop: Boolean; const Restart: Boolean);
begin
  if (Animator = nil) or (Seq.Count <= 0) then
    Exit;
  Animator.Play(Mdl.Sequence(Seq.First, Seq.Count, Loop), Restart);
  if Restart then
    FLastFrame := -1;
end;

procedure TQuakeMonster.Wake;
begin
  if SightAlerted and (Enemy = nil) then
    Exit;
  FoundTarget(nil);
end;

procedure TQuakeMonster.FoundTarget(const NewEnemy: TQuakeMonster);
begin
  { FoundTarget: hunt the new enemy; only spotting the player is passed on
    to other monsters (sight_entity) }
  Enemy := NewEnemy;
  if NewEnemy = nil then
    FAlertAge := 0;
  SightAlerted := True;
  if State = msIdle then
    State := msWalk;
  if FDef.SightSound <> '' then
    Sounds.PlayAt(FDef.SightSound, Transform);
end;

procedure TQuakeMonster.HearNoise;
begin
  if (State = msIdle) and not Ambush and not Crucified and (FDef.Move <> mmStatic) then
    Wake;
end;

function TQuakeMonster.JustSpottedPlayer: Boolean;
begin
  Result := SightAlerted and (Enemy = nil) and (FAlertAge < 0.3) and IsSolid;
end;

function TQuakeMonster.EnemyValid: Boolean;
begin
  Result := (Enemy <> nil) and (Enemy.Health > 0) and not (Enemy.State in [msDeath, msDead]);
end;

procedure TQuakeMonster.CheckEnemy;
begin
  { ai_run: a dead monster enemy is forgotten, back to the player }
  if (Enemy <> nil) and not EnemyValid then
    Enemy := nil;
end;

function TQuakeMonster.EnemyOrigin(const Env: TQuakeMonsterEnv): TVector3;
begin
  if Enemy <> nil then
    Result := Enemy.Origin
  else
    Result := Env.PlayerOrigin;
end;

function TQuakeMonster.EnemyAlive(const Env: TQuakeMonsterEnv): Boolean;
begin
  if Enemy <> nil then
    Result := EnemyValid
  else
    Result := Env.PlayerAlive;
end;

function TQuakeMonster.CanSeeEnemy(const Env: TQuakeMonsterEnv): Boolean;
begin
  if Enemy <> nil then
    Result := Env.CanSeeMonster(Self, Enemy)
  else
    Result := Env.CanSeePlayer(Self);
end;

procedure TQuakeMonster.DamageEnemy(const Env: TQuakeMonsterEnv; const Damage: Single);
begin
  if Enemy <> nil then
    Env.DamageMonster(Self, Enemy, Damage)
  else
    Env.DamagePlayer(Self, Damage);
end;

procedure TQuakeMonster.FindTarget(const Env: TQuakeMonsterEnv);
const
  RangeMelee = 120;
  RangeNear = 500;
  RangeMid = 1000;
var
  Dist, SY, CY: Single;
  Dir: TVector3;
begin
  if FDef.Move = mmStatic then
    Exit;
  { Another monster has just spotted the player and we can see it }
  if not Ambush and (Env.SightEntity(Self) <> nil) then
  begin
    Wake;
    Exit;
  end;
  if not Env.PlayerAlive then
    Exit;
  Dist := PointsDistance(Origin, Env.PlayerOrigin);
  if (Dist >= RangeMid) or not Env.CanSeePlayer(Self) then
    Exit;
  if Dist >= RangeMelee then
  begin
    { Out of melee range the player must be in front (infront: dot > 0.3),
      except up close right after firing (show_hostile) }
    SinCos(DegToRad(Yaw), SY, CY);
    Dir := Env.PlayerOrigin - Origin;
    Dir.Z := 0;
    if Dir.IsPerfectlyZero then
      Exit;
    Dir := Dir.Normalize;
    if (Dir.X * CY + Dir.Y * SY <= 0.3) and not ((Dist < RangeNear) and Env.PlayerHostile) then
      Exit;
  end;
  Wake;
end;

procedure TQuakeMonster.Use;
begin
  if State = msHidden then
  begin
    { boss_awake: rise from the lava }
    Transform.Exists := True;
    State := msRise;
    LavaSplashPending := True;
    SightAlerted := True;
    PlaySeq(FDef.Leap, False, True);
    if FDef.SightSound <> '' then
      Sounds.PlayAt(FDef.SightSound, Transform);
  end else
  if State = msIdle then
    Wake;
end;

procedure TQuakeMonster.LightningShock;
begin
  if (EntityClassName <> 'monster_boss') or (Health <= 0) or (State in [msHidden, msDeath, msDead]) then
    Exit;
  Health := Health - 1;
  Sounds.PlayAt(FDef.PainSound, Transform);
  if Health <= 0 then
  begin
    State := msDeath;
    PlaySeq(FDef.Death, False, True);
    Sounds.PlayAt(FDef.DeathSound, Transform);
  end else
  begin
    State := msPain;
    PlaySeq(FDef.Pain, False, True);
  end;
end;

procedure TQuakeMonster.Crucify;
begin
  Crucified := True;
  KillCounted := True;
  PlaySeq(Seq(192, 6), True, True); { $cruc_1 .. $cruc_6 }
end;

procedure TQuakeMonster.RestoreState(const AState: TMonsterState; const AHealth: Integer;
  const AYaw: Single);
begin
  Health := AHealth;
  SetYaw(AYaw);
  Velocity := TVector3.Zero;
  OnGround := FDef.Move = mmWalk;
  FLastFrame := -1;
  case AState of
    msDeath, msDead:
      begin
        State := msDead;
        PlaySeq(FDef.Death, False, True);
        if Animator <> nil then
          Animator.Update(1000); { lie at the last death frame }
        if EntityClassName = 'monster_boss' then
          Transform.Exists := False;
      end;
    msHidden:
      begin
        State := msHidden;
        Transform.Exists := False;
      end;
    msIdle:
      begin
        State := msIdle;
        if not Crucified then
          PlaySeq(FDef.Stand, True, True);
      end;
    msDown:
      begin
        { zombie lying on the ground, gets up after a while }
        State := msDown;
        FDownPhase := 1;
        FStateTime := 0;
        PlaySeq(Seq(FDef.Extra.First, 12), False, True);
        if Animator <> nil then
          Animator.Update(1000);
      end;
    else
      if EntityClassName = 'monster_boss' then
      begin
        { Chthon out of the lava keeps throwing }
        Transform.Exists := True;
        State := msAttack;
        FAttackIsMelee := False;
        PlaySeq(FDef.Missile, True, True);
      end else
      begin
        State := msWalk;
        PlaySeq(FDef.Run, True, True);
      end;
  end;
end;

procedure TQuakeMonster.Die;
begin
  { Killed: gib, explode or play the death animation }
  if EntityClassName = 'monster_tarbaby' then
  begin
    State := msDead;
    ExplodePending := True;
    Sounds.PlayAt(FDef.DeathSound, Transform);
    Exit;
  end;
  if (FDef.GibHealth <> NoGib) and (Health < FDef.GibHealth) then
  begin
    State := msDead;
    GibPending := True;
    if FDef.DeathSound <> '' then
      Sounds.PlayAt(FDef.DeathSound, Transform);
    Exit;
  end;
  State := msDeath;
  PlaySeq(FDef.Death, False, True);
  if FDef.DeathSound <> '' then
    Sounds.PlayAt(FDef.DeathSound, Transform);
end;

procedure TQuakeMonster.TakeDamage(const Damage: Integer; const Attacker: TQuakeMonster);
begin
  if FDef.Invulnerable or (State in [msDeath, msDead, msHidden]) or (Damage <= 0) then
    Exit;

  Health := Health - Damage;
  if not Crucified then
  begin
    { T_Damage: get mad at the attacker, unless it is of the same class
      (grunts always fight back) }
    if Attacker = nil then
      Wake
    else
    if (Attacker <> Self) and (Attacker <> Enemy) and
       ((Attacker.EntityClassName <> EntityClassName) or (EntityClassName = 'monster_army')) then
      FoundTarget(Attacker);
  end;

  if EntityClassName = 'monster_zombie' then
  begin
    { zombie_pain: health is reset after every hit, so only a single hit of
      60 or more (gibbing) kills; 25 or more knocks the zombie down }
    if Health <= 0 then
    begin
      Health := -100;
      Die;
      Exit;
    end;
    Health := 60;
    if (Damage < 9) or (State = msDown) or Crucified then
      Exit;
    if Damage >= 25 then
    begin
      State := msDown;
      FDownPhase := 0;
      FStateTime := 0;
      PlaySeq(Seq(FDef.Extra.First, 12), False, True);
      Sounds.PlayAt('sound/zombie/z_fall.wav', Transform);
      Exit;
    end;
  end else
  if Health <= 0 then
  begin
    Die;
    Exit;
  end;

  { Flinch }
  if (FDef.PainFactor < 0) or (FTime < FPainFinished) or (State = msLeap) then
    Exit;
  if (FDef.PainFactor > 0) and (Random * FDef.PainFactor > Damage) then
    Exit;
  State := msPain;
  FPainFinished := FTime + 1.0;
  if Nightmare then
    FPainFinished := FTime + 5;
  PlaySeq(FDef.Pain, False, True);
  if FDef.PainSound <> '' then
    Sounds.PlayAt(FDef.PainSound, Transform);
end;

procedure TQuakeMonster.FacePlayer(const Env: TQuakeMonsterEnv; const Dt: Single);
const
  YawSpeed = 270.0; { degrees per second (yaw_speed 20-30 per 0.1 s think) }
var
  Delta: TVector3;
  Ideal, Diff: Single;
begin
  Delta := EnemyOrigin(Env) - Origin;
  if (Abs(Delta.X) < 0.01) and (Abs(Delta.Y) < 0.01) then
    Exit;
  Ideal := RadToDeg(ArcTan2(Delta.Y, Delta.X));
  Diff := Ideal - Yaw;
  while Diff > 180 do
    Diff := Diff - 360;
  while Diff < -180 do
    Diff := Diff + 360;
  SetYaw(Yaw + EnsureRange(Diff, -YawSpeed * Dt, YawSpeed * Dt));
end;

procedure TQuakeMonster.StartAttack(const Melee: Boolean);
begin
  State := msAttack;
  FAttackIsMelee := Melee;
  if Melee then
  begin
    PlaySeq(FDef.Melee, False, True);
    if FDef.MeleeSound <> '' then
      Sounds.PlayAt(FDef.MeleeSound, Transform);
  end else
    PlaySeq(FDef.Missile, False, True);
end;

procedure TQuakeMonster.CheckAttack(const Env: TQuakeMonsterEnv);
var
  Dist, Chance: Single;
begin
  { CheckAttack: melee when close, otherwise leap or missile with a chance
    depending on the range (ai.qc / fight.qc) }
  if not EnemyAlive(Env) then
    Exit;
  if not CanSeeEnemy(Env) then
    Exit;
  Dist := PointsDistance(Origin, EnemyOrigin(Env));

  if (FDef.MeleeRange > 0) and (Dist < FDef.MeleeRange) then
  begin
    StartAttack(True);
    Exit;
  end;

  if (FDef.LeapFrame >= 0) and OnGround and (Dist >= FDef.LeapMin) and (Dist <= FDef.LeapMax) and
     (FTime >= FAttackFinished) then
  begin
    { CheckDemonJump: long leaps are rare }
    if (Dist > 200) and (EntityClassName = 'monster_demon1') and (Random < 0.9) then
      Exit;
    State := msLeap;
    FLeapLaunched := False;
    FLeapHit := False;
    FStateTime := 0;
    PlaySeq(FDef.Leap, False, True);
    FAttackFinished := FTime + 1;
    Exit;
  end;

  if (FDef.MissileKind <> maNone) and (Dist < FDef.MissileRange) and (FTime >= FAttackFinished) then
  begin
    if Dist < 120 then
      Chance := 0.9
    else if Dist < 500 then
      Chance := 0.4
    else if Dist < 1000 then
      Chance := 0.1
    else
      Chance := 0.02;
    if Random < Chance then
    begin
      StartAttack(False);
      FAttackFinished := FTime + 1 + Random;
    end;
  end;
end;

procedure TQuakeMonster.Chase(const Env: TQuakeMonsterEnv; const Dt: Single);
const
  MaxStepLength = 8.0;
var
  Dist, StepYaw, Remaining, StepLen: Single;
  Dir: TVector3;
  I: Integer;
  Moved: Boolean;
const
  Detours: array[0..4] of Single = (45, -45, 90, -90, 180);
begin
  FacePlayer(Env, Dt);
  PlaySeq(FDef.Run, True);

  { Decide attacks at the 10 Hz think rate }
  FThinkTimer := FThinkTimer - Dt;
  if FThinkTimer <= 0 then
  begin
    FThinkTimer := 0.1;
    CheckAttack(Env);
    if State <> msWalk then
      Exit;
  end;

  if (FDef.Move = mmStatic) or (FDef.RunSpeed <= 0) then
    Exit;
  Dist := PointsDistance(Origin, EnemyOrigin(Env));
  if (FDef.MeleeRange > 0) and (Dist < FDef.MeleeRange * 0.8) then
    Exit; { close enough, attack instead of pushing }

  { movetogoal: head for the player, take a detour for a while when blocked }
  if FDodgeTime > 0 then
  begin
    FDodgeTime := FDodgeTime - Dt;
    StepYaw := FDodgeYaw;
  end else
    StepYaw := Yaw;

  Remaining := FDef.RunSpeed * Dt;
  while Remaining > 0 do
  begin
    StepLen := Min(Remaining, MaxStepLength);
    Remaining := Remaining - StepLen;
    SinCos(DegToRad(StepYaw), Dir.Y, Dir.X);
    Dir.Z := 0;
    Moved := Env.MoveStep(Self, Dir * StepLen);
    if not Moved then
    begin
      for I := 0 to High(Detours) do
      begin
        SinCos(DegToRad(Yaw + Detours[I]), Dir.Y, Dir.X);
        if Env.MoveStep(Self, Dir * StepLen) then
        begin
          FDodgeYaw := Yaw + Detours[I];
          FDodgeTime := 0.3 + Random * 0.4;
          StepYaw := FDodgeYaw;
          Moved := True;
          Break;
        end;
      end;
      if not Moved then
        Break;
    end;
  end;
end;

procedure TQuakeMonster.FireMissile(const Env: TQuakeMonsterEnv; const Frame: Integer);
var
  Org, Dir, Right, Aim: TVector3;
  SY, CY, Offset: Single;
begin
  SinCos(DegToRad(Yaw), SY, CY);
  Right := Vector3(SY, -CY, 0);
  Aim := EnemyOrigin(Env);
  case FDef.MissileKind of
    maBullets:
      begin
        { army_fire: aim at where the player will be }
        if Enemy = nil then
          Aim := Aim - Env.PlayerVelocity * 0.2;
        Env.FireBullets(Self, 4, 0.1, Aim);
      end;
    maLightning:
      Env.CastLightning(Self, Aim);
    maGrenade:
      begin
        { OgreFireGrenade }
        Org := Origin;
        Dir := (Aim - Org).Normalize * 600;
        Dir.Z := 200;
        Env.LaunchMissile(Self, maGrenade, Org, Dir);
      end;
    maZombieGib:
      begin
        { ZombieFireGrenade from the raised hand }
        Org := Origin + Right * 10 + Vector3(0, 0, 30);
        Dir := (Aim - Org).Normalize * 600;
        Dir.Z := 200;
        Env.LaunchMissile(Self, maZombieGib, Org, Dir);
      end;
    maWizSpike:
      begin
        { Two spit balls, one from each side }
        if Frame mod 4 = 0 then
          Offset := 14
        else
          Offset := -14;
        Org := Origin + Vector3(0, 0, 30) + Right * Offset;
        Env.LaunchMissile(Self, maWizSpike, Org, (Aim + Vector3(0, 0, 10) - Org).Normalize * 600);
      end;
    maKnightSpike:
      begin
        { hknight_shot: a fan of six spikes, 6 degrees apart, at 300 u/s }
        Offset := (Frame - 7) * 6;
        Dir := (Aim - Center).Normalize;
        SinCos(ArcTan2(Dir.Y, Dir.X) + DegToRad(Offset), SY, CY);
        Dir := Vector3(CY * Sqrt(1 - Sqr(Dir.Z)), SY * Sqrt(1 - Sqr(Dir.Z)), Dir.Z);
        Org := Center + Vector3(CY, SY, 0) * 20;
        Env.LaunchMissile(Self, maKnightSpike, Org, Dir * 300);
      end;
    maLaser:
      begin
        SinCos(DegToRad(Yaw), SY, CY);
        Org := Origin + Vector3(CY, SY, 0) * 30 + Right * 8.5 + Vector3(0, 0, 16);
        Env.LaunchMissile(Self, maLaser, Org, (Aim - Org).Normalize * 600);
      end;
    maVorePod:
      begin
        Org := Origin + Vector3(0, 0, 10);
        Env.LaunchMissile(Self, maVorePod, Org, (Aim + Vector3(0, 0, 10) - Org).Normalize * 400);
      end;
    maLavaBall:
      begin
        { boss_missile: from the left hand, then the right one }
        SinCos(DegToRad(Yaw), SY, CY);
        if Frame < 15 then
          Offset := 100
        else
          Offset := -100;
        Org := Origin + Vector3(CY, SY, 0) * 100 - Right * Offset + Vector3(0, 0, 200);
        { Lead the target by the flight time }
        if Enemy = nil then
          Aim := Aim + Env.PlayerVelocity * (PointsDistance(Org, Aim) / 300);
        Env.LaunchMissile(Self, maLavaBall, Org, (Aim - Org).Normalize * 300);
      end;
  end;
  { The shambler's charge sound plays once per attack, the rest per shot }
  if (FDef.MissileSound <> '') and
     ((FDef.MissileKind <> maLightning) or (Frame = 5)) then
    Sounds.PlayAt(FDef.MissileSound, Transform);
end;

procedure TQuakeMonster.FrameEvent(const Env: TQuakeMonsterEnv; const Frame: Integer);
begin
  if Frame > 31 then
    Exit;
  if FAttackIsMelee then
  begin
    if (FDef.MeleeFrames and (Cardinal(1) shl Frame)) <> 0 then
      { ai_melee: only hits within reach }
      if EnemyAlive(Env) and (PointsDistance(Origin, EnemyOrigin(Env)) <= FDef.MeleeRange + 20) then
        DamageEnemy(Env, Random * FDef.MeleeDamage);
  end else
  if (FDef.MissileFrames and (Cardinal(1) shl Frame)) <> 0 then
    FireMissile(Env, Frame);
end;

procedure TQuakeMonster.FrameEvents(const Env: TQuakeMonsterEnv);
var
  Idx, F: Integer;
begin
  Idx := Animator.FrameIndex;
  if Idx = FLastFrame then
    Exit;
  if Idx > FLastFrame then
  begin
    for F := FLastFrame + 1 to Idx do
      FrameEvent(Env, F);
  end else
  begin
    { Looping sequence wrapped around }
    for F := FLastFrame + 1 to Animator.Sequence.Count - 1 do
      FrameEvent(Env, F);
    for F := 0 to Idx do
      FrameEvent(Env, F);
  end;
  FLastFrame := Idx;
end;

procedure TQuakeMonster.UpdateLeap(const Env: TQuakeMonsterEnv; const Dt: Single);
var
  HitPlayer: Boolean;
  HitMonster: TQuakeMonster;
  SY, CY: Single;
begin
  FStateTime := FStateTime + Dt;
  if not FLeapLaunched then
  begin
    FacePlayer(Env, Dt);
    if Animator.FrameIndex >= FDef.LeapFrame then
    begin
      SinCos(DegToRad(Yaw), SY, CY);
      Velocity := Vector3(CY, SY, 0) * FDef.LeapForward + Vector3(0, 0, FDef.LeapUp);
      FLeapLaunched := True;
      OnGround := False;
      if FDef.MissileSound <> '' then
        Sounds.PlayAt(FDef.MissileSound, Transform);
    end;
    Exit;
  end;

  if Animator.Finished and (FDef.Extra.Count > 0) then
    PlaySeq(FDef.Extra, True); { tarbaby keeps spinning in the air }

  if Env.TossStep(Self, Dt, HitPlayer, HitMonster) or (FStateTime > 3) then
  begin
    OnGround := True;
    Velocity := TVector3.Zero;
    State := msWalk;
    if EntityClassName = 'monster_tarbaby' then
      Sounds.PlayAt('sound/blob/land1.wav', Transform);
  end;
  if (HitPlayer or (HitMonster <> nil)) and not FLeapHit then
  begin
    { Demon_JumpTouch / dog / tarbaby: hurt what was hit once per leap }
    FLeapHit := True;
    if HitPlayer then
      Env.DamagePlayer(Self, FDef.LeapDamage * (0.5 + Random * 0.5))
    else
      Env.DamageMonster(Self, HitMonster, FDef.LeapDamage * (0.5 + Random * 0.5));
    if FDef.MeleeSound <> '' then
      Sounds.PlayAt(FDef.MeleeSound, Transform);
  end;
end;

procedure TQuakeMonster.UpdateDown(const Dt: Single);
begin
  { Zombie on the ground: fall (12 frames), lie for 5 seconds, get up }
  case FDownPhase of
    0:
      if Animator.Finished then
      begin
        FDownPhase := 1;
        FStateTime := 0;
      end;
    1:
      begin
        FStateTime := FStateTime + Dt;
        if FStateTime >= 5 then
        begin
          FDownPhase := 2;
          PlaySeq(Seq(FDef.Extra.First + 12, FDef.Extra.Count - 12), False, True);
          Sounds.PlayAt('sound/zombie/z_idle.wav', Transform);
        end;
      end;
    else
      if Animator.Finished then
        State := msWalk;
  end;
end;

procedure TQuakeMonster.Update(const SecondsPassed: Single; const Env: TQuakeMonsterEnv);
begin
  FTime := FTime + SecondsPassed;
  FAlertAge := FAlertAge + SecondsPassed;
  if Animator = nil then
    Exit;
  CheckEnemy;

  case State of
    msHidden:
      Exit;
    msDead:
      ;
    msDeath:
      if Animator.Finished then
      begin
        State := msDead;
        if EntityClassName = 'monster_boss' then
        begin
          DeathTargetPending := True;
          Transform.Exists := False;
        end;
      end;
    msRise:
      if Animator.Finished then
      begin
        State := msAttack;
        FAttackIsMelee := False;
        PlaySeq(FDef.Missile, True, True);
      end;
    msPain:
      if Animator.Finished then
      begin
        if EntityClassName = 'monster_boss' then
        begin
          State := msAttack;
          PlaySeq(FDef.Missile, True, True);
        end else
          State := msWalk;
      end;
    msDown:
      UpdateDown(SecondsPassed);
    msLeap:
      UpdateLeap(Env, SecondsPassed);
    msIdle:
      if Crucified then
        { zombie_cruc: just twitch }
      else
      begin
        PlaySeq(FDef.Stand, True);
        FThinkTimer := FThinkTimer - SecondsPassed;
        if FThinkTimer <= 0 then
        begin
          FThinkTimer := 0.1 + Random * 0.1;
          FindTarget(Env);
        end;
      end;
    msWalk:
      begin
        if not EnemyAlive(Env) then
          State := msIdle
        else
          Chase(Env, SecondsPassed);
      end;
    msAttack:
      begin
        FacePlayer(Env, SecondsPassed);
        if Animator.Finished then
          State := msWalk;
      end;
  end;

  Animator.Update(SecondsPassed);
  if State = msAttack then
  begin
    FrameEvents(Env);
    { Chthon keeps throwing while the player lives }
    if (EntityClassName = 'monster_boss') and not Env.PlayerAlive then
    begin
      State := msIdle;
      PlaySeq(FDef.Stand, True);
    end;
  end;

  { Idle noises now and then }
  if (State in [msIdle, msWalk]) and (FDef.IdleSound <> '') then
  begin
    FIdleSoundTime := FIdleSoundTime - SecondsPassed;
    if FIdleSoundTime <= 0 then
    begin
      FIdleSoundTime := 5 + Random * 10;
      if SightAlerted or (Random < 0.2) then
        Sounds.PlayAt(FDef.IdleSound, Transform);
    end;
  end;
end;

end.
