{ The game's entities as engine behaviors: a TCastleBehavior attached to
  the transform of every monster, pickup, brush entity (submodel) and
  trigger, with published properties that read and write the entity's
  state. The engine's inspector (F8) lists them under the transform and
  edits them while playing; a future editor design can place them. The
  entities themselves stay plain objects run by TQuakeWorld. }
unit QuakeBehaviors;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  CastleVectors, CastleTransform,
  QuakePak, QuakeBsp, QuakeLight, QuakeEntities, QuakeMonsters, QuakeGeometry;

type
  TQuakeMonsterBehavior = class(TCastleBehavior)
  private
    FMonster: TQuakeMonster;
    function GetEntityClass: String;
    function GetHealth: Integer;
    procedure SetHealth(const Value: Integer);
    function GetState: TMonsterState;
    function GetYaw: Single;
    procedure SetYaw(const Value: Single);
    function GetTargetName: String;
    function GetTarget: String;
    function GetAlerted: Boolean;
    function GetEnemy: String;
    function GetAmbush: Boolean;
  public
    constructor CreateFor(const AMonster: TQuakeMonster);
    property Monster: TQuakeMonster read FMonster;
  published
    property EntityClass: String read GetEntityClass;
    property Health: Integer read GetHealth write SetHealth;
    property State: TMonsterState read GetState;
    property Yaw: Single read GetYaw write SetYaw;
    property TargetName: String read GetTargetName;
    property Target: String read GetTarget;
    property Alerted: Boolean read GetAlerted;
    property Ambush: Boolean read GetAmbush;
    { The monster it fights after friendly fire, else "player" }
    property Enemy: String read GetEnemy;
  end;

  TQuakePickupBehavior = class(TCastleBehavior)
  private
    FPickup: TQuakePickup;
    function GetKind: TQuakeItemKind;
    function GetCollected: Boolean;
    procedure SetCollected(const Value: Boolean);
    function GetRespawnTime: Single;
    function GetMessageText: String;
    function GetTarget: String;
    function GetModelPath: String;
  public
    constructor CreateFor(const APickup: TQuakePickup);
    property Pickup: TQuakePickup read FPickup;
  published
    property Kind: TQuakeItemKind read GetKind;
    { Setting it hides or shows the item }
    property Collected: Boolean read GetCollected write SetCollected;
    property RespawnTime: Single read GetRespawnTime;
    property MessageText: String read GetMessageText;
    property Target: String read GetTarget;
    property ModelPath: String read GetModelPath;
  end;

  TQuakeSubmodelBehavior = class(TCastleBehavior)
  private
    FSubmodel: TQuakeSubmodel;
    function GetEntityClass: String;
    function GetStateName: String;
    function GetSpeed: Single;
    procedure SetSpeed(const Value: Single);
    function GetWaitTime: Single;
    procedure SetWaitTime(const Value: Single);
    function GetTarget: String;
    function GetTargetName: String;
    function GetKeyNeeded: Integer;
    procedure SetKeyNeeded(const Value: Integer);
    function GetSpawnFlags: Integer;
    function GetModelIndex: Integer;
    function GetOpen: Boolean;
    procedure SetOpen(const Value: Boolean);
  public
    constructor CreateFor(const ASubmodel: TQuakeSubmodel);
    property Submodel: TQuakeSubmodel read FSubmodel;
  published
    property EntityClass: String read GetEntityClass;
    property StateName: String read GetStateName;
    { Setting it triggers the door / plat / button }
    property Open: Boolean read GetOpen write SetOpen;
    property Speed: Single read GetSpeed write SetSpeed;
    property WaitTime: Single read GetWaitTime write SetWaitTime;
    property Target: String read GetTarget;
    property TargetName: String read GetTargetName;
    { 0 none, 1 silver key, 2 gold key }
    property KeyNeeded: Integer read GetKeyNeeded write SetKeyNeeded;
    property SpawnFlags: Integer read GetSpawnFlags;
    property ModelIndex: Integer read GetModelIndex;
  end;

  { A trigger has no model: it gets an empty transform at the centre of its
    box so it appears in the tree, and this behavior with the bounds }
  TQuakeTriggerBehavior = class(TCastleBehavior)
  private
    FTrigger: TQuakeTrigger;
    function GetEntityClass: String;
    function GetTarget: String;
    function GetTargetName: String;
    function GetMapName: String;
    function GetMessageText: String;
    function GetTouchable: Boolean;
    procedure SetTouchable(const Value: Boolean);
    function GetRemoved: Boolean;
    procedure SetRemoved(const Value: Boolean);
    function GetWaitTime: Single;
    procedure SetWaitTime(const Value: Single);
    function GetSpawnFlags: Integer;
    function GetBounds: String;
  public
    constructor CreateFor(const ATrigger: TQuakeTrigger; const AOwner: TComponent);
    property Trigger: TQuakeTrigger read FTrigger;
  published
    property EntityClass: String read GetEntityClass;
    property Target: String read GetTarget;
    property TargetName: String read GetTargetName;
    property MapName: String read GetMapName;
    property MessageText: String read GetMessageText;
    property Touchable: Boolean read GetTouchable write SetTouchable;
    property Removed: Boolean read GetRemoved write SetRemoved;
    property WaitTime: Single read GetWaitTime write SetWaitTime;
    property SpawnFlags: Integer read GetSpawnFlags;
    { Quake coordinates: "mins .. maxs" }
    property Bounds: String read GetBounds;
  end;

{ Attach the behaviors (each owned by the transform it is attached to) }
procedure AttachMonsterBehavior(const M: TQuakeMonster);
procedure AttachPickupBehavior(const P: TQuakePickup);
procedure AttachSubmodelBehavior(const S: TQuakeSubmodel);
{ A named transform for the trigger under Parent, with its behavior }
function CreateTriggerTransform(const T: TQuakeTrigger; const Parent: TCastleTransform): TCastleTransform;

implementation

{ TQuakeMonsterBehavior }

constructor TQuakeMonsterBehavior.CreateFor(const AMonster: TQuakeMonster);
begin
  inherited Create(AMonster.Transform);
  FMonster := AMonster;
  Name := ComponentName('monster_behavior');
end;

function TQuakeMonsterBehavior.GetEntityClass: String;
begin
  Result := FMonster.EntityClassName;
end;

function TQuakeMonsterBehavior.GetHealth: Integer;
begin
  Result := FMonster.Health;
end;

procedure TQuakeMonsterBehavior.SetHealth(const Value: Integer);
begin
  FMonster.Health := Value;
end;

function TQuakeMonsterBehavior.GetState: TMonsterState;
begin
  Result := FMonster.State;
end;

function TQuakeMonsterBehavior.GetYaw: Single;
begin
  Result := FMonster.Yaw;
end;

procedure TQuakeMonsterBehavior.SetYaw(const Value: Single);
begin
  FMonster.Yaw := Value;
end;

function TQuakeMonsterBehavior.GetTargetName: String;
begin
  Result := FMonster.TargetName;
end;

function TQuakeMonsterBehavior.GetTarget: String;
begin
  Result := FMonster.Target;
end;

function TQuakeMonsterBehavior.GetAlerted: Boolean;
begin
  Result := FMonster.SightAlerted;
end;

function TQuakeMonsterBehavior.GetAmbush: Boolean;
begin
  Result := FMonster.Ambush;
end;

function TQuakeMonsterBehavior.GetEnemy: String;
begin
  if (FMonster.Enemy <> nil) and (FMonster.Enemy.Transform <> nil) then
    Result := FMonster.Enemy.Transform.Name
  else
    Result := 'player';
end;

{ TQuakePickupBehavior }

constructor TQuakePickupBehavior.CreateFor(const APickup: TQuakePickup);
begin
  inherited Create(APickup.Transform);
  FPickup := APickup;
  Name := ComponentName('pickup_behavior');
end;

function TQuakePickupBehavior.GetKind: TQuakeItemKind;
begin
  Result := FPickup.Kind;
end;

function TQuakePickupBehavior.GetCollected: Boolean;
begin
  Result := FPickup.Collected;
end;

procedure TQuakePickupBehavior.SetCollected(const Value: Boolean);
begin
  FPickup.Collected := Value;
  FPickup.Transform.Visible := not Value;
end;

function TQuakePickupBehavior.GetRespawnTime: Single;
begin
  Result := FPickup.RespawnTime;
end;

function TQuakePickupBehavior.GetMessageText: String;
begin
  Result := FPickup.MessageText;
end;

function TQuakePickupBehavior.GetTarget: String;
begin
  Result := FPickup.Target;
end;

function TQuakePickupBehavior.GetModelPath: String;
begin
  Result := FPickup.ModelPath;
end;

{ TQuakeSubmodelBehavior }

constructor TQuakeSubmodelBehavior.CreateFor(const ASubmodel: TQuakeSubmodel);
begin
  inherited Create(ASubmodel.Transform);
  FSubmodel := ASubmodel;
  Name := ComponentName('submodel_behavior');
end;

function TQuakeSubmodelBehavior.GetEntityClass: String;
begin
  Result := FSubmodel.EntityClassName;
end;

function TQuakeSubmodelBehavior.GetStateName: String;
const
  Names: array[0..3] of String = ('closed', 'opening', 'open', 'closing');
begin
  Result := Names[Ord(FSubmodel.State)];
end;

function TQuakeSubmodelBehavior.GetSpeed: Single;
begin
  Result := FSubmodel.Speed;
end;

procedure TQuakeSubmodelBehavior.SetSpeed(const Value: Single);
begin
  FSubmodel.Speed := Value;
end;

function TQuakeSubmodelBehavior.GetWaitTime: Single;
begin
  Result := FSubmodel.WaitTime;
end;

procedure TQuakeSubmodelBehavior.SetWaitTime(const Value: Single);
begin
  FSubmodel.WaitTime := Value;
end;

function TQuakeSubmodelBehavior.GetTarget: String;
begin
  Result := FSubmodel.Target;
end;

function TQuakeSubmodelBehavior.GetTargetName: String;
begin
  Result := FSubmodel.TargetName;
end;

function TQuakeSubmodelBehavior.GetKeyNeeded: Integer;
begin
  Result := FSubmodel.KeyNeeded;
end;

procedure TQuakeSubmodelBehavior.SetKeyNeeded(const Value: Integer);
begin
  FSubmodel.KeyNeeded := Value;
end;

function TQuakeSubmodelBehavior.GetSpawnFlags: Integer;
begin
  Result := FSubmodel.SpawnFlags;
end;

function TQuakeSubmodelBehavior.GetModelIndex: Integer;
begin
  Result := FSubmodel.ModelIndex;
end;

function TQuakeSubmodelBehavior.GetOpen: Boolean;
begin
  Result := Ord(FSubmodel.State) in [1, 2];
end;

procedure TQuakeSubmodelBehavior.SetOpen(const Value: Boolean);
begin
  if Value and (Ord(FSubmodel.State) = 0) then
    FSubmodel.Trigger
  else if (not Value) and (Ord(FSubmodel.State) = 2) then
  begin
    { Close now: the open timer runs out }
    FSubmodel.StateTimer := 0;
    if FSubmodel.WaitTime < 0 then
      FSubmodel.WaitTime := 0.01;
  end;
end;

{ TQuakeTriggerBehavior }

constructor TQuakeTriggerBehavior.CreateFor(const ATrigger: TQuakeTrigger; const AOwner: TComponent);
begin
  inherited Create(AOwner);
  FTrigger := ATrigger;
  Name := ComponentName('trigger_behavior');
end;

function TQuakeTriggerBehavior.GetEntityClass: String;
begin
  Result := FTrigger.EntityClassName;
end;

function TQuakeTriggerBehavior.GetTarget: String;
begin
  Result := FTrigger.Target;
end;

function TQuakeTriggerBehavior.GetTargetName: String;
begin
  Result := FTrigger.TargetName;
end;

function TQuakeTriggerBehavior.GetMapName: String;
begin
  Result := FTrigger.MapName;
end;

function TQuakeTriggerBehavior.GetMessageText: String;
begin
  Result := FTrigger.Message;
end;

function TQuakeTriggerBehavior.GetTouchable: Boolean;
begin
  Result := FTrigger.Touchable;
end;

procedure TQuakeTriggerBehavior.SetTouchable(const Value: Boolean);
begin
  FTrigger.Touchable := Value;
end;

function TQuakeTriggerBehavior.GetRemoved: Boolean;
begin
  Result := FTrigger.Removed;
end;

procedure TQuakeTriggerBehavior.SetRemoved(const Value: Boolean);
begin
  FTrigger.Removed := Value;
end;

function TQuakeTriggerBehavior.GetWaitTime: Single;
begin
  Result := FTrigger.WaitTime;
end;

procedure TQuakeTriggerBehavior.SetWaitTime(const Value: Single);
begin
  FTrigger.WaitTime := Value;
end;

function TQuakeTriggerBehavior.GetSpawnFlags: Integer;
begin
  Result := FTrigger.SpawnFlags;
end;

function TQuakeTriggerBehavior.GetBounds: String;
begin
  Result := Format('%.0f %.0f %.0f .. %.0f %.0f %.0f', [FTrigger.Mins.X, FTrigger.Mins.Y, FTrigger.Mins.Z,
    FTrigger.Maxs.X, FTrigger.Maxs.Y, FTrigger.Maxs.Z]);
end;

{ Attaching }

procedure AttachMonsterBehavior(const M: TQuakeMonster);
begin
  if (M = nil) or (M.Transform = nil) then
    Exit;
  M.Transform.AddBehavior(TQuakeMonsterBehavior.CreateFor(M));
end;

procedure AttachPickupBehavior(const P: TQuakePickup);
begin
  if (P = nil) or (P.Transform = nil) then
    Exit;
  P.Transform.AddBehavior(TQuakePickupBehavior.CreateFor(P));
end;

procedure AttachSubmodelBehavior(const S: TQuakeSubmodel);
begin
  if (S = nil) or (S.Transform = nil) then
    Exit;
  S.Transform.AddBehavior(TQuakeSubmodelBehavior.CreateFor(S));
end;

function CreateTriggerTransform(const T: TQuakeTrigger; const Parent: TCastleTransform): TCastleTransform;
var
  B: TQuakeTriggerBehavior;
begin
  Result := TCastleTransform.Create(Parent);
  Result.Name := ComponentName(T.EntityClassName);
  Result.Translation := QuakeToCge((T.Mins + T.Maxs) * 0.5);
  B := TQuakeTriggerBehavior.CreateFor(T, Result);
  Result.AddBehavior(B);
  Parent.Add(Result);
end;

end.
