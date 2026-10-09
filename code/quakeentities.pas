{ Quake 1 entity definitions: items, pickups, monsters, triggers, and projectiles. }
unit QuakeEntities;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, Math,
  CastleVectors, CastleTransform, CastleScene, CastleLog, CastleQuaternions,
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
    ikQuadDamage, ikPentagram, ikRingShadows, ikBioSuit, ikSigil
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
    Target: String; { fired on pickup (SUB_UseTargets) }
    SpawnFlags: Integer; { item_sigil: episode rune bit }
    constructor Create(const Parent: TCastleTransform; const AKind: TQuakeItemKind;
      const Pos: TVector3; const MdlPath: String; const SkinIdx: Integer = 0);
    destructor Destroy; override;
    procedure Update(const SecondsPassed: Single);
  end;

  TQuakePickupList = specialize TObjectList<TQuakePickup>;

  TQuakeProjectileKind = (pjNail, pjSuperNail, pjGrenade, pjRocket,
    { monster missiles }
    pjWizSpike, pjKnightSpike, pjLaser, pjVorePod, pjZombieGib, pjLavaBall, pjOgreGrenade);

  { Active player projectile. Origin and Velocity are in Quake coordinates;
    the world moves it with hull traces (see TQuakeWorld.UpdateProjectiles). }
  TQuakeProjectile = class
  public
    Kind: TQuakeProjectileKind;
    Transform: TCastleTransform;
    Scene: TCastleScene;
    Origin: TVector3;
    Velocity: TVector3;
    Life: Single;        { removed (grenades: explode) when it runs out }
    OnGround: Boolean;   { grenade resting on the floor }
    TrailTimer: Single;
    Spin: Single;        { grenade tumbling angle }
    Owner: TObject;      { monster that fired it, nil for the player }
    HomeTimer: Single;   { vore pods steer towards the player }
    constructor Create(const Parent: TCastleTransform; const AKind: TQuakeProjectileKind;
      const AOrigin, AVelocity: TVector3);
    destructor Destroy; override;
    { Place the model at Origin, facing along Velocity }
    procedure UpdateVisual;
  end;

  TQuakeProjectileList = specialize TObjectList<TQuakeProjectile>;

  { Flying piece of a gibbed monster (ThrowGib / ThrowHead), MOVETYPE_BOUNCE.
    Origin and Velocity are in Quake coordinates. }
  TQuakeGib = class
  public
    Transform: TCastleTransform;
    Scene: TCastleScene;
    Origin: TVector3;
    Velocity: TVector3;
    AngularVelocity: TVector3; { degrees per second around X, Y, Z }
    Angles: TVector3;
    Life: Single;       { removed when it runs out; heads stay (Life < 0) }
    OnGround: Boolean;
    TrailTimer: Single;
    constructor Create(const Parent: TCastleTransform; const MdlPath: String;
      const AOrigin, AVelocity: TVector3; const ALife: Single);
    destructor Destroy; override;
    procedure UpdateVisual;
  end;

  TQuakeGibList = specialize TObjectList<TQuakeGib>;

  { Trigger zone (teleport, changelevel, trigger_multiple) }
  TQuakeTrigger = class
  public
    EntityClassName: String;
    Mins, Maxs: TVector3; { absolute bounds, Quake coordinates }
    Target: String;
    TargetName: String;
    MapName: String; { for changelevel }
    Message: String; { centerprinted when triggered }
    MoveDir: TVector3; { trigger_multiple with an angle: only when walking this way }
    Touchable: Boolean;
    Removed: Boolean; { trigger_once that has fired }
    SpawnFlags: Integer;
    WaitTime: Single;
    LastTriggerTime: Single;
    constructor Create(const ACName: String; const AMins, AMaxs: TVector3;
      const ATarget: String; const AMap: String = '');
    { Does a box (Quake coordinates) touch the trigger }
    function Touches(const BoxMins, BoxMaxs: TVector3): Boolean;
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
    ikSigil:
      begin
        MessageText := 'You got the rune!';
        PickupSound := 'sound/misc/runekey.wav';
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

{ TQuakeProjectile }

constructor TQuakeProjectile.Create(const Parent: TCastleTransform;
  const AKind: TQuakeProjectileKind; const AOrigin, AVelocity: TVector3);
var
  Mdl: TQuakeMdl;
  MdlPath: String;
begin
  inherited Create;
  Kind := AKind;
  Origin := AOrigin;
  Velocity := AVelocity;
  case Kind of
    pjGrenade, pjOgreGrenade:
      begin
        MdlPath := 'progs/grenade.mdl';
        Life := 2.5; { fuse }
      end;
    pjWizSpike:
      begin
        MdlPath := 'progs/w_spike.mdl';
        Life := 6.0;
      end;
    pjKnightSpike:
      begin
        MdlPath := 'progs/k_spike.mdl';
        Life := 6.0;
      end;
    pjLaser:
      begin
        MdlPath := 'progs/laser.mdl';
        Life := 5.0;
      end;
    pjVorePod:
      begin
        MdlPath := 'progs/v_spike.mdl';
        Life := 10.0;
      end;
    pjZombieGib:
      begin
        MdlPath := 'progs/zom_gib.mdl';
        Life := 6.0;
      end;
    pjLavaBall:
      begin
        MdlPath := 'progs/lavaball.mdl';
        Life := 8.0;
      end;
    pjRocket:
      begin
        MdlPath := 'progs/missile.mdl';
        Life := 5.0;
      end;
    pjSuperNail:
      begin
        MdlPath := 'progs/s_spike.mdl';
        Life := 6.0;
      end;
    else
      begin
        MdlPath := 'progs/spike.mdl';
        Life := 6.0;
      end;
  end;

  Transform := TCastleTransform.Create(nil);
  Mdl := MdlManager.GetModel(MdlPath);
  if Mdl <> nil then
  begin
    Scene := Mdl.CreateScene(0);
    Scene.Collides := False;
    Transform.Add(Scene);
  end;
  Parent.Add(Transform);
  UpdateVisual;
end;

destructor TQuakeProjectile.Destroy;
begin
  Transform.Free;
  inherited Destroy;
end;

procedure TQuakeProjectile.UpdateVisual;
var
  Yaw, Pitch: Single;
  Q: TQuaternion;
begin
  Transform.Translation := QuakeToCge(Origin);
  if Kind in [pjGrenade, pjOgreGrenade, pjZombieGib, pjLavaBall] then
  begin
    { Grenades and gibs tumble (avelocity '300 300 300') }
    Q := QuatFromAxisAngle(Vector3(0, 1, 0), DegToRad(Spin)) *
      QuatFromAxisAngle(Vector3(1, 0, 0), DegToRad(Spin));
  end else
  begin
    { Models point along Quake +X: yaw around the up axis, then pitch }
    if Velocity.IsPerfectlyZero then
      Exit;
    Yaw := ArcTan2(Velocity.Y, Velocity.X);
    Pitch := ArcTan2(Velocity.Z, Sqrt(Sqr(Velocity.X) + Sqr(Velocity.Y)));
    Q := QuatFromAxisAngle(Vector3(0, 1, 0), Yaw) * QuatFromAxisAngle(Vector3(0, 0, 1), Pitch);
  end;
  Transform.Rotation := Q.ToAxisAngle;
end;

{ TQuakeGib }

constructor TQuakeGib.Create(const Parent: TCastleTransform; const MdlPath: String;
  const AOrigin, AVelocity: TVector3; const ALife: Single);
var
  Mdl: TQuakeMdl;
begin
  inherited Create;
  Origin := AOrigin;
  Velocity := AVelocity;
  Life := ALife;
  Transform := TCastleTransform.Create(nil);
  Mdl := MdlManager.GetModel(MdlPath);
  if Mdl <> nil then
  begin
    Scene := Mdl.CreateScene(0);
    Scene.Collides := False;
    Transform.Add(Scene);
  end;
  Parent.Add(Transform);
  UpdateVisual;
end;

destructor TQuakeGib.Destroy;
begin
  Transform.Free;
  inherited Destroy;
end;

procedure TQuakeGib.UpdateVisual;
var
  Q: TQuaternion;
begin
  Transform.Translation := QuakeToCge(Origin);
  Q := QuatFromAxisAngle(Vector3(0, 1, 0), DegToRad(Angles.Y)) *
    QuatFromAxisAngle(Vector3(0, 0, 1), DegToRad(Angles.X)) *
    QuatFromAxisAngle(Vector3(1, 0, 0), DegToRad(Angles.Z));
  Transform.Rotation := Q.ToAxisAngle;
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
  Touchable := True;
end;

function TQuakeTrigger.Touches(const BoxMins, BoxMaxs: TVector3): Boolean;
begin
  Result := (BoxMins.X <= Maxs.X) and (BoxMaxs.X >= Mins.X) and
            (BoxMins.Y <= Maxs.Y) and (BoxMaxs.Y >= Mins.Y) and
            (BoxMins.Z <= Maxs.Z) and (BoxMaxs.Z >= Mins.Z);
end;

end.
