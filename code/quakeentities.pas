{ Quake 1 entity definitions: items, pickups, monsters, triggers, and projectiles. }
unit QuakeEntities;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, Math,
  CastleVectors, CastleTransform, CastleScene, CastleLog,
  QuakeBsp, QuakeMdl, QuakeLight, QuakeSound;

type
  { Kind of item pickup }
  TQuakeItemKind = (
    ikAxe, ikShotgun, ikSuperShotgun, ikNailgun, ikSuperNailgun,
    ikGrenadeLauncher, ikRocketLauncher, ikLightning,
    ikGreenArmor, ikYellowArmor, ikRedArmor,
    ikHealthSmall, ikHealthNormal, ikHealthMega,
    ikShells, ikNails, ikRockets, ikCells,
    ikKeySilver, ikKeyGold,
    ikQuadDamage, ikPentagram, ikRingShadows, ikBioSuit
  );

  { Single active 3D pickup entity in the world }
  TQuakePickup = class
  public
    Kind: TQuakeItemKind;
    Transform: TCastleTransform;
    Scene: TCastleScene;
    Origin: TVector3;
    RotationAngle: Single;
    BobTimer: Single;
    Collected: Boolean;
    RespawnTime: Single;
    MessageText: String;
    PickupSound: String;
    constructor Create(const Parent: TCastleTransform; const AKind: TQuakeItemKind;
      const Pos: TVector3; const MdlPath: String; const SkinIdx: Integer = 0);
    destructor Destroy; override;
    procedure Update(const SecondsPassed: Single);
  end;

  TQuakePickupList = specialize TObjectList<TQuakePickup>;

  { Monster state enum }
  TMonsterState = (msIdle, msWalk, msAttack, msPain, msDeath, msDead);

  { Active 3D monster in the world }
  TQuakeMonster = class
  public
    EntityClassName: String;
    Transform: TCastleTransform;
    Scene: TCastleScene;
    Mdl: TQuakeMdl;
    State: TMonsterState;
    Health: Integer;
    MaxHealth: Integer;
    Speed: Single;
    AttackDamage: Integer;
    AttackRange: Single;
    AlertRange: Single;
    Origin: TVector3;
    FacingAngle: Single;
    AnimFrame: Integer;
    AnimTimer: Single;
    AttackCooldown: Single;
    TargetPos: TVector3;
    SightAlerted: Boolean;
    DropItem: TQuakeItemKind;
    HasDrop: Boolean;
    SightSound, PainSound, DeathSound, AttackSound: String;
    { Set when the monster attacked during the last Update; the world decides
      whether the attack reaches the player and clears it. }
    AttackLaunched: Boolean;
    constructor Create(const Parent: TCastleTransform; const ACName: String;
      const Pos: TVector3; const Yaw: Single; const MdlPath: String;
      const AHealth, ADamage: Integer; const ASpeed, ARange: Single);
    destructor Destroy; override;
    procedure Update(const SecondsPassed: Single; const PlayerPos: TVector3);
    procedure TakeDamage(const Dmg: Integer; const AttackerPos: TVector3);
  end;

  TQuakeMonsterList = specialize TObjectList<TQuakeMonster>;

  { Active projectile (rocket, grenade, nail) }
  TQuakeProjectile = class
  public
    Transform: TCastleTransform;
    Scene: TCastleScene;
    Velocity: TVector3;
    Damage: Integer;
    SplashRadius: Single;
    Life: Single;
    IsRocket: Boolean;
    FromPlayer: Boolean;
    constructor Create(const Parent: TCastleTransform; const Pos, Vel: TVector3;
      const MdlPath: String; const ADamage: Integer; const ASplash: Single;
      const ARocket, AFromPlayer: Boolean);
    destructor Destroy; override;
    function Update(const SecondsPassed: Single): Boolean; { returns False if expired }
  end;

  TQuakeProjectileList = specialize TObjectList<TQuakeProjectile>;

  { Trigger zone (teleport, changelevel, trigger_multiple) }
  TQuakeTrigger = class
  public
    EntityClassName: String;
    Mins, Maxs: TVector3;
    Target: String;
    TargetName: String;
    MapName: String; { for changelevel }
    SpawnFlags: Integer;
    WaitTime: Single;
    LastTriggerTime: Single;
    constructor Create(const ACName: String; const AMins, AMaxs: TVector3;
      const ATarget: String; const AMap: String = '');
    function Intersects(const Pos: TVector3; const Radius: Single = 16.0): Boolean;
  end;

  TQuakeTriggerList = specialize TObjectList<TQuakeTrigger>;

implementation

{ TQuakePickup }

constructor TQuakePickup.Create(const Parent: TCastleTransform; const AKind: TQuakeItemKind;
  const Pos: TVector3; const MdlPath: String; const SkinIdx: Integer);
var
  Mdl: TQuakeMdl;
begin
  inherited Create;
  Kind := AKind;
  Origin := Pos;
  RotationAngle := Random * 360.0;
  BobTimer := Random * 6.28;
  Collected := False;
  RespawnTime := 0;

  Transform := TCastleTransform.Create(nil);
  Transform.Translation := Pos;

  Mdl := MdlManager.GetModel(MdlPath);
  if Mdl <> nil then
  begin
    Scene := Mdl.CreateScene(SkinIdx);
    Transform.Add(Scene);
  end;

  case Kind of
    ikSuperShotgun:
      begin
        MessageText := 'You got the Super Shotgun!';
        PickupSound := 'sound/weapons/pkup.wav';
      end;
    ikNailgun:
      begin
        MessageText := 'You got the Nailgun!';
        PickupSound := 'sound/weapons/pkup.wav';
      end;
    ikSuperNailgun:
      begin
        MessageText := 'You got the Super Nailgun!';
        PickupSound := 'sound/weapons/pkup.wav';
      end;
    ikGrenadeLauncher:
      begin
        MessageText := 'You got the Grenade Launcher!';
        PickupSound := 'sound/weapons/pkup.wav';
      end;
    ikRocketLauncher:
      begin
        MessageText := 'You got the Rocket Launcher!';
        PickupSound := 'sound/weapons/pkup.wav';
      end;
    ikLightning:
      begin
        MessageText := 'You got the Thunderbolt!';
        PickupSound := 'sound/weapons/pkup.wav';
      end;
    ikGreenArmor:
      begin
        MessageText := 'You got Green Armor';
        PickupSound := 'sound/items/armor1.wav';
      end;
    ikYellowArmor:
      begin
        MessageText := 'You got Yellow Armor';
        PickupSound := 'sound/items/armor1.wav';
      end;
    ikRedArmor:
      begin
        MessageText := 'You got Red Armor';
        PickupSound := 'sound/items/armor1.wav';
      end;
    ikHealthSmall:
      begin
        MessageText := 'You got 15 health';
        PickupSound := 'sound/items/health1.wav';
      end;
    ikHealthNormal:
      begin
        MessageText := 'You got 25 health';
        PickupSound := 'sound/items/health1.wav';
      end;
    ikHealthMega:
      begin
        MessageText := 'Megahealth +100!';
        PickupSound := 'sound/items/r_item2.wav';
      end;
    ikShells:
      begin
        MessageText := 'Picked up shotgun shells';
        PickupSound := 'sound/weapons/lock4.wav';
      end;
    ikNails:
      begin
        MessageText := 'Picked up nails';
        PickupSound := 'sound/weapons/lock4.wav';
      end;
    ikRockets:
      begin
        MessageText := 'Picked up rockets';
        PickupSound := 'sound/weapons/lock4.wav';
      end;
    ikCells:
      begin
        MessageText := 'Picked up energy cells';
        PickupSound := 'sound/weapons/lock4.wav';
      end;
    ikKeySilver:
      begin
        MessageText := 'You found the Silver Keycard';
        PickupSound := 'sound/misc/medkey.wav';
      end;
    ikKeyGold:
      begin
        MessageText := 'You found the Gold Keycard';
        PickupSound := 'sound/misc/runekey.wav';
      end;
    ikQuadDamage:
      begin
        MessageText := 'QUAD DAMAGE!';
        PickupSound := 'sound/items/damage.wav';
      end;
    ikPentagram:
      begin
        MessageText := 'Pentagram of Protection!';
        PickupSound := 'sound/items/protect.wav';
      end;
    ikBioSuit:
      begin
        MessageText := 'You got the Biosuit';
        PickupSound := 'sound/items/suit.wav';
      end;
    else
      begin
        MessageText := 'Picked up an item';
        PickupSound := 'sound/items/r_item1.wav';
      end;
  end;

  Parent.Add(Transform);
end;

destructor TQuakePickup.Destroy;
begin
  Transform.Free;
  inherited Destroy;
end;

procedure TQuakePickup.Update(const SecondsPassed: Single);
var
  CurPos: TVector3;
begin
  if Collected then
  begin
    Transform.Visible := False;
    Exit;
  end;

  Transform.Visible := True;
  RotationAngle := RotationAngle + 90.0 * SecondsPassed;
  if RotationAngle >= 360.0 then
    RotationAngle := RotationAngle - 360.0;

  BobTimer := BobTimer + SecondsPassed * 2.5;

  CurPos := Origin;
  CurPos.Y := CurPos.Y + Sin(BobTimer) * 4.0;
  Transform.Translation := CurPos;
  Transform.Rotation := Vector4(0, 1, 0, DegToRad(RotationAngle));
end;

{ TQuakeMonster }

constructor TQuakeMonster.Create(const Parent: TCastleTransform; const ACName: String;
  const Pos: TVector3; const Yaw: Single; const MdlPath: String;
  const AHealth, ADamage: Integer; const ASpeed, ARange: Single);
begin
  inherited Create;
  EntityClassName := ACName;
  Origin := Pos;
  FacingAngle := Yaw;
  Health := AHealth;
  MaxHealth := AHealth;
  AttackDamage := ADamage;
  Speed := ASpeed;
  AttackRange := ARange;
  AlertRange := 800.0;
  State := msIdle;
  AnimFrame := 0;
  AnimTimer := 0;
  AttackCooldown := 0;
  SightAlerted := False;
  HasDrop := False;

  Transform := TCastleTransform.Create(nil);
  Transform.Translation := Pos;
  Transform.Rotation := Vector4(0, 1, 0, DegToRad(Yaw));

  Mdl := MdlManager.GetModel(MdlPath);
  if Mdl <> nil then
  begin
    Scene := Mdl.CreateScene(0);
    Transform.Add(Scene);
  end;

  { Default sound assignments }
  if ACName = 'monster_army' then
  begin
    SightSound := 'sound/soldier/sight1.wav';
    PainSound := 'sound/soldier/pain1.wav';
    DeathSound := 'sound/soldier/death1.wav';
    AttackSound := 'sound/soldier/sattck1.wav';
    DropItem := ikShells;
    HasDrop := True;
  end else
  if ACName = 'monster_dog' then
  begin
    SightSound := 'sound/dog/dsight.wav';
    PainSound := 'sound/dog/dpain1.wav';
    DeathSound := 'sound/dog/ddeath.wav';
    AttackSound := 'sound/dog/dattack1.wav';
  end else
  if ACName = 'monster_ogre' then
  begin
    SightSound := 'sound/ogre/ogwake.wav';
    PainSound := 'sound/ogre/ogpain1.wav';
    DeathSound := 'sound/ogre/ogdth.wav';
    AttackSound := 'sound/weapons/grenade.wav';
    DropItem := ikRockets;
    HasDrop := True;
  end else
  if ACName = 'monster_knight' then
  begin
    SightSound := 'sound/knight/ksight.wav';
    PainSound := 'sound/knight/kpain.wav';
    DeathSound := 'sound/knight/kdeath.wav';
    AttackSound := 'sound/knight/sword1.wav';
  end else
  begin
    SightSound := 'sound/soldier/sight1.wav';
    PainSound := 'sound/soldier/pain1.wav';
    DeathSound := 'sound/soldier/death1.wav';
    AttackSound := 'sound/weapons/ax1.wav';
  end;

  Parent.Add(Transform);
end;

destructor TQuakeMonster.Destroy;
begin
  Transform.Free;
  inherited Destroy;
end;

procedure TQuakeMonster.TakeDamage(const Dmg: Integer; const AttackerPos: TVector3);
begin
  if (State = msDeath) or (State = msDead) then
    Exit;

  Health := Health - Dmg;
  SightAlerted := True;

  if Health <= 0 then
  begin
    Health := 0;
    State := msDeath;
    AnimTimer := 0;
    Sounds.PlayAt(DeathSound, Transform);
    Scene.Collides := False; { corpses don't block movement }
  end else
  begin
    State := msPain;
    AnimTimer := 0;
    Sounds.PlayAt(PainSound, Transform);
  end;
end;

procedure TQuakeMonster.Update(const SecondsPassed: Single; const PlayerPos: TVector3);
var
  Delta: TVector3;
  Dist, Step: Single;
  TargetYaw: Single;
begin
  if State = msDead then
    Exit;

  { Death animation progression }
  if State = msDeath then
  begin
    AnimTimer := AnimTimer + SecondsPassed;
    if AnimTimer >= 0.8 then
      State := msDead;
    Exit;
  end;

  if State = msPain then
  begin
    AnimTimer := AnimTimer + SecondsPassed;
    if AnimTimer >= 0.3 then
      State := msWalk;
    Exit;
  end;

  Delta := PlayerPos - Transform.Translation;
  Dist := Delta.Length;

  { Check wake up / alert }
  if not SightAlerted and (Dist < AlertRange) then
  begin
    SightAlerted := True;
    State := msWalk;
    Sounds.PlayAt(SightSound, Transform);
  end;

  if not SightAlerted then
    Exit;

  { Turn toward player }
  if Dist > 1.0 then
  begin
    TargetYaw := RadToDeg(ArcTan2(Delta[0], -Delta[2]));
    FacingAngle := TargetYaw;
    Transform.Rotation := Vector4(0, 1, 0, DegToRad(FacingAngle));
  end;

  { Chasing or attacking }
  if AttackCooldown > 0 then
    AttackCooldown := AttackCooldown - SecondsPassed;

  if Dist <= AttackRange then
  begin
    { In melee / firing range }
    if (AttackCooldown <= 0) then
    begin
      State := msAttack;
      AttackCooldown := 1.2;
      AttackLaunched := True;
      Sounds.PlayAt(AttackSound, Transform);
      Lighting.TriggerMuzzleFlash(Transform.Translation + Vector3(0, 24, 0), 1.5);
    end;
  end else
  begin
    { Walk toward player }
    State := msWalk;
    Step := Speed * SecondsPassed;
    Delta.Y := 0; { Stay on horizontal plane }
    if Delta.Length > 0 then
      Transform.Translation := Transform.Translation + Delta.Normalize * Step;
  end;

  { Advance walk animation frame }
  if Mdl <> nil then
  begin
    AnimTimer := AnimTimer + SecondsPassed;
    if AnimTimer >= 0.12 then
    begin
      AnimTimer := 0;
      AnimFrame := AnimFrame + 1;
      Mdl.ApplyFrame(Scene, AnimFrame);
    end;
  end;
end;

{ TQuakeProjectile }

constructor TQuakeProjectile.Create(const Parent: TCastleTransform; const Pos, Vel: TVector3;
  const MdlPath: String; const ADamage: Integer; const ASplash: Single;
  const ARocket, AFromPlayer: Boolean);
var
  Mdl: TQuakeMdl;
begin
  inherited Create;
  Velocity := Vel;
  Damage := ADamage;
  SplashRadius := ASplash;
  IsRocket := ARocket;
  FromPlayer := AFromPlayer;
  Life := 6.0;

  Transform := TCastleTransform.Create(nil);
  Transform.Translation := Pos;

  Mdl := MdlManager.GetModel(MdlPath);
  if Mdl <> nil then
  begin
    Scene := Mdl.CreateScene(0);
    Transform.Add(Scene);
  end;

  Parent.Add(Transform);
end;

destructor TQuakeProjectile.Destroy;
begin
  Transform.Free;
  inherited Destroy;
end;

function TQuakeProjectile.Update(const SecondsPassed: Single): Boolean;
begin
  Life := Life - SecondsPassed;
  if Life <= 0 then
    Exit(False);

  Transform.Translation := Transform.Translation + Velocity * SecondsPassed;
  Result := True;
end;

{ TQuakeTrigger }

constructor TQuakeTrigger.Create(const ACName: String; const AMins, AMaxs: TVector3;
  const ATarget: String; const AMap: String);
begin
  inherited Create;
  EntityClassName := ACName;
  Mins := AMins;
  Maxs := AMaxs;
  Target := ATarget;
  MapName := AMap;
  WaitTime := 1.0;
  LastTriggerTime := -999.0;
end;

function TQuakeTrigger.Intersects(const Pos: TVector3; const Radius: Single): Boolean;
begin
  Result := (Pos.X + Radius >= Mins.X) and (Pos.X - Radius <= Maxs.X) and
            (Pos.Y + Radius >= Mins.Y) and (Pos.Y - Radius <= Maxs.Y) and
            (Pos.Z + Radius >= Mins.Z) and (Pos.Z - Radius <= Maxs.Z);
end;

end.
