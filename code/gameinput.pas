{ The player's bindings (keys, mouse buttons, the game controller) as
  TInputShortcut instances saved in the user config, and the gamepad
  state: the sticks move and turn, the buttons map onto the bindings. }
unit GameInput;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math,
  CastleVectors, CastleKeysMouse, CastleInputs, CastleConfig, CastleUIControls, CastleTransform,
  CastleGameControllers, CastleLog;

type
  TQuakeBinding = (
    qbForward, qbBackward, qbStrafeLeft, qbStrafeRight, qbWalk, qbJump, qbFire, qbUse,
    qbWeapon1, qbWeapon2, qbWeapon3, qbWeapon4, qbWeapon5, qbWeapon6, qbWeapon7, qbWeapon8,
    qbNextWeapon, qbPrevWeapon, qbQuickSave, qbQuickLoad, qbConsole, qbCamera, qbShadows, qbScreenshot,
    qbPhotoMode, qbChat, qbScoreboard);

const
  BindingCaptions: array[TQuakeBinding] of String = (
    'Move forward', 'Move backward', 'Strafe left', 'Strafe right', 'Walk (slow)', 'Jump', 'Fire', 'Use',
    'Axe', 'Shotgun', 'Super shotgun', 'Nailgun', 'Super nailgun', 'Grenade launcher', 'Rocket launcher',
    'Thunderbolt', 'Next weapon', 'Previous weapon', 'Quick save', 'Quick load', 'Console', 'Camera view',
    'Shadows', 'Screenshot', 'Photo mode', 'Chat', 'Scoreboard');
  { The gamepad: the left stick moves, the right stick turns, these
    buttons are the bindings }
  GamepadJump = gbSouth;
  GamepadUse = gbWest;
  GamepadFire = gbRightBumper;
  GamepadNextWeapon = gbDPadRight;
  GamepadPrevWeapon = gbDPadLeft;
  GamepadYawSpeed = 160.0;   { degrees per second at full deflection, sensitivity 1 }
  GamepadPitchSpeed = 90.0;
  DefaultGamepadDeadZone = 0.2;

type
  { Whose button names a pad has: told from the controller's name (the
    engine calls every desktop pad an Xbox one), or set in Options }
  TPadFamily = (pfXbox, pfPlayStation, pfNintendo);
  TPadLayout = (plAuto, plXbox, plPlayStation, plNintendo);
  { Which face button confirms in the menus: Nintendo's A is on the east,
    the others' A / Cross on the south }
  TPadConfirm = (pcAuto, pcSouth, pcEast);

const
  PadFamilyNames: array[TPadFamily] of String = ('Xbox', 'PlayStation', 'Nintendo');
  PadLayoutNames: array[TPadLayout] of String = ('Auto', 'Xbox', 'PlayStation', 'Nintendo');
  PadConfirmNames: array[TPadConfirm] of String = ('Auto', 'South', 'East');

var
  Bindings: array[TQuakeBinding] of TInputShortcut;
  { The same shortcuts as a list (owns them), for the config file; they are
    local shortcuts, apart from the engine's own global ones }
  BindingList: TInputShortcutList;
  { Gamepad tuning, saved in the user config: the right stick's turn speed
    multiplier, the part of both sticks' travel ignored around the center,
    and up / down of the right stick swapped }
  GamepadSensitivity: Single = 1.0;
  GamepadDeadZone: Single = DefaultGamepadDeadZone;
  GamepadInvertLook: Boolean = False;
  { Saved under gamepad/layout and gamepad/confirm }
  GamepadLayout: TPadLayout = plAuto;
  GamepadConfirm: TPadConfirm = pcAuto;
  { The touch controls (GameTouch) add to the game controller: the move
    stick's deflection (-1..1, y forward), the look drag since the last
    turn (fractions of the screen height) and the on-screen buttons, held
    like the controller's buttons they stand for }
  TouchMove: TVector2;
  TouchLookDelta: TVector2;
  TouchButtons: array[TGameControllerButton] of Boolean;

const
  { Degrees turned by a look drag over the whole screen height }
  TouchLookDegrees = 160.0;

{ Create the bindings with their defaults and load the user's changes
  from UserConfig; detect the controllers }
procedure InitializeBindings;
{ Save the bindings to UserConfig (only what differs from the defaults) }
procedure SaveBindings;
procedure ResetBindings;
{ Rebind to the key or mouse button of Event; False if the event is not one }
function AssignBinding(const B: TQuakeBinding; const Event: TInputPressRelease): Boolean;
function BindingDescription(const B: TQuakeBinding): String;

{ The binding is held: its key or mouse button, or the gamepad button
  (or trigger) that stands for it }
function BindingHeld(const B: TQuakeBinding; const Container: TCastleContainer;
  const Player: Integer = 0): Boolean;
{ A press event is this binding }
function BindingEvent(const B: TQuakeBinding; const Event: TInputPressRelease): Boolean;
{ The gamepad button is down now }
function GamepadButtonDown(const Button: TGameControllerButton; const Player: Integer = 0): Boolean;
{ A gamepad button went down since the last UpdateGamepad }
function GamepadJustPressed(const Button: TGameControllerButton; const Player: Integer = 0): Boolean;
{ The left stick as movement fractions (-1..1): forward and side }
procedure GamepadMove(out Forward, Side: Single; const Player: Integer = 0);
{ Turn the camera with the right stick (call every frame when playing) }
procedure GamepadTurnCamera(const Camera: TCastleCamera; const SecondsPassed: Single; const Player: Integer = 0);
{ Refresh the just-pressed state of the gamepad buttons; once per frame }
procedure UpdateGamepad(const Player: Integer = 0);
{ Split-screen players: the Player argument of the helpers above is 0 for
  the one player (the first pad, the touch controls), 1 for the keyboard
  and mouse player (and the touch controls; the first pad too when there
  is one more pad than gamepad players) and 2..SplitPlayerCount for the
  gamepad players (the next pads in order, no keyboard) }
function PlayerController(const Player: Integer): TGameController;
{ The split-screen player a pad belongs to (1..SplitPlayerCount), 0 none }
function PadPlayer(const PadIndex: Integer): Integer;
function GamepadConnected: Boolean;
{ The first controller's name, 'none' without one }
function GamepadName: String;
procedure SaveGamepadSettings;
{ The family a controller name belongs to: Xbox for Xbox and Microsoft,
  PlayStation for Sony,
  DualShock, DualSense and "Wireless Controller", Nintendo for Nintendo,
  Switch, Pro Controller and Joy-Con, Xbox otherwise }
function PadFamilyOfName(const Name: String): TPadFamily;
{ The family whose names the prompts use: GamepadLayout, or the first
  controller's (Xbox without one) }
function GamepadFamily: TPadFamily;
{ A button's name on a family's pads (by position: gbSouth is A, Cross or
  B), or on the connected one }
function PadButtonLabel(const Family: TPadFamily; const Button: TGameControllerButton): String;
function GamepadButtonLabel(const Button: TGameControllerButton): String;
{ The right trigger's name (an axis, not a button): RT, R2 or ZR }
function GamepadTriggerLabel: String;
{ The menus' confirm and back buttons (GamepadConfirm, Auto: east on a
  Nintendo pad) }
function GamepadConfirmButton: TGameControllerButton;
function GamepadBackButton: TGameControllerButton;
{ Headless tests: the virtual controller's name (its family follows) }
procedure SetVirtualPadName(const Name: String);
{ The stick value after the dead zone (rescaled so the edge stays 1) }
function ApplyDeadZone(const V: Single): Single;

{ Headless tests: a virtual controller (the engine's explicit backend)
  whose sticks, trigger and buttons the demo script sets }
procedure UseVirtualGamepad;
procedure SetVirtualSticks(const Left, Right: TVector2);
procedure SetVirtualRightTrigger(const Value: Single);
procedure SetVirtualButton(const Button: TGameControllerButton; const Pressed: Boolean);
{ Several virtual pads (split-screen tests): how many, and which one the
  sticks, the trigger and the buttons above drive }
procedure SetVirtualPadCount(const Count: Integer);
{ 'south', 'east', 'west', 'north', 'lb', 'rb', 'up', 'down', 'left',
  'right', 'start', 'back'; False when unknown }
function GamepadButtonByName(const Name: String; out Button: TGameControllerButton): Boolean;

var
  { Split-screen: how many local players share the pads (2..4) }
  SplitPlayerCount: Integer = 2;
  { The virtual pad the demo script's GL, GR, GT and GB drive }
  VirtualPadIndex: Integer;

implementation

uses
  CastleInternalGameControllersExplicit;

var
  WasPressed, JustPressed: array[0..4, TGameControllerButton] of Boolean;
  ConfigLoaded: Boolean;

function FirstController: TGameController;
begin
  if Controllers.Count > 0 then
    Result := Controllers[0]
  else
    Result := nil;
end;

function PlayerController(const Player: Integer): TGameController;
var
  Extra, Index: Integer;
begin
  Result := nil;
  if Player <= 0 then
    Exit(FirstController);
  { One pad more than the gamepad players: the first is the keyboard player's }
  if Controllers.Count >= SplitPlayerCount then
    Extra := 1
  else
    Extra := 0;
  if Player = 1 then
    Index := Extra - 1
  else
    Index := Player - 2 + Extra;
  if (Index >= 0) and (Index < Controllers.Count) and (Player <= SplitPlayerCount) then
    Result := Controllers[Index];
end;

function PadPlayer(const PadIndex: Integer): Integer;
var
  P: Integer;
begin
  Result := 0;
  if (PadIndex < 0) or (PadIndex >= Controllers.Count) then
    Exit;
  for P := 1 to SplitPlayerCount do
    if PlayerController(P) = Controllers[PadIndex] then
      Exit(P);
end;

{ The touch controls belong to the one player, or the keyboard player }
function HasTouch(const Player: Integer): Boolean;
begin
  Result := Player <= 1;
end;

function GamepadConnected: Boolean;
begin
  Result := FirstController <> nil;
end;

function GamepadName: String;
begin
  if FirstController = nil then
    Result := 'none'
  else
    Result := FirstController.Name;
end;

procedure LoadGamepadSettings;
begin
  GamepadSensitivity := EnsureRange(UserConfig.GetFloat('gamepad/sensitivity', 1.0), 0.25, 4.0);
  GamepadDeadZone := EnsureRange(UserConfig.GetFloat('gamepad/dead_zone', DefaultGamepadDeadZone), 0.0, 0.6);
  GamepadInvertLook := UserConfig.GetValue('gamepad/invert_look', False);
  GamepadLayout := TPadLayout(EnsureRange(UserConfig.GetValue('gamepad/layout', 0), 0, Ord(High(TPadLayout))));
  GamepadConfirm := TPadConfirm(EnsureRange(UserConfig.GetValue('gamepad/confirm', 0), 0, Ord(High(TPadConfirm))));
end;

function PadFamilyOfName(const Name: String): TPadFamily;
var
  N: String;
begin
  N := LowerCase(Name);
  { "Xbox Wireless Controller" before the DualShock 4's "Wireless Controller" }
  if (Pos('xbox', N) > 0) or (Pos('x-box', N) > 0) or (Pos('microsoft', N) > 0) then
    Result := pfXbox
  else
  if (Pos('sony', N) > 0) or (Pos('playstation', N) > 0) or (Pos('dualshock', N) > 0) or
     (Pos('dualsense', N) > 0) or (Pos('ps3', N) > 0) or (Pos('ps4', N) > 0) or (Pos('ps5', N) > 0) or
     (Pos('wireless controller', N) > 0) then
    Result := pfPlayStation
  else
  if (Pos('nintendo', N) > 0) or (Pos('switch', N) > 0) or (Pos('pro controller', N) > 0) or
     (Pos('joy-con', N) > 0) or (Pos('joycon', N) > 0) then
    Result := pfNintendo
  else
    Result := pfXbox;
end;

function GamepadFamily: TPadFamily;
begin
  case GamepadLayout of
    plXbox: Result := pfXbox;
    plPlayStation: Result := pfPlayStation;
    plNintendo: Result := pfNintendo;
    else
      if FirstController <> nil then
        Result := PadFamilyOfName(FirstController.Name)
      else
        Result := pfXbox;
  end;
end;

function PadButtonLabel(const Family: TPadFamily; const Button: TGameControllerButton): String;
const
  Xbox: array[TGameControllerButton] of String = ('Y', 'B', 'A', 'X', 'LB', 'RB', 'Left Stick', 'Right Stick',
    'D-pad Up', 'D-pad Right', 'D-pad Down', 'D-pad Left', 'View', 'Menu', 'Guide', 'Share');
  PlayStation: array[TGameControllerButton] of String = ('Triangle', 'Circle', 'Cross', 'Square', 'L1', 'R1',
    'L3', 'R3', 'D-pad Up', 'D-pad Right', 'D-pad Down', 'D-pad Left', 'Create', 'Options', 'PS', 'Mute');
  Nintendo: array[TGameControllerButton] of String = ('X', 'A', 'B', 'Y', 'L', 'R', 'Left Stick', 'Right Stick',
    'D-pad Up', 'D-pad Right', 'D-pad Down', 'D-pad Left', '-', '+', 'Home', 'Capture');
begin
  case Family of
    pfPlayStation: Result := PlayStation[Button];
    pfNintendo: Result := Nintendo[Button];
    else Result := Xbox[Button];
  end;
end;

function GamepadButtonLabel(const Button: TGameControllerButton): String;
begin
  Result := PadButtonLabel(GamepadFamily, Button);
end;

function GamepadTriggerLabel: String;
begin
  case GamepadFamily of
    pfPlayStation: Result := 'R2';
    pfNintendo: Result := 'ZR';
    else Result := 'RT';
  end;
end;

function GamepadConfirmButton: TGameControllerButton;
begin
  if (GamepadConfirm = pcEast) or ((GamepadConfirm = pcAuto) and (GamepadFamily = pfNintendo)) then
    Result := gbEast
  else
    Result := gbSouth;
end;

function GamepadBackButton: TGameControllerButton;
begin
  if GamepadConfirmButton = gbEast then
    Result := gbSouth
  else
    Result := gbEast;
end;

procedure SaveGamepadSettings;
const
  { As Single, like the setting, so the default compares equal }
  DeadZoneDefault: Single = DefaultGamepadDeadZone;
begin
  if not ConfigLoaded then
    Exit;
  try
    UserConfig.SetDeleteFloat('gamepad/sensitivity', GamepadSensitivity, 1.0);
    UserConfig.SetDeleteFloat('gamepad/dead_zone', GamepadDeadZone, DeadZoneDefault);
    UserConfig.SetDeleteValue('gamepad/invert_look', GamepadInvertLook, False);
    UserConfig.SetDeleteValue('gamepad/layout', Ord(GamepadLayout), 0);
    UserConfig.SetDeleteValue('gamepad/confirm', Ord(GamepadConfirm), 0);
    UserConfig.Save;
  except
    on E: Exception do
      WritelnWarning('GameInput', 'Cannot save the user config: ' + E.Message);
  end;
end;


var
  VirtualPadReady: Boolean;

function ExplicitBackend: TExplicitControllerManagerBackend;
begin
  Result := Controllers.InternalExplicitBackend as TExplicitControllerManagerBackend;
  { Replace whatever the platform backend had listed (a CI runner may
    expose a device) with the one virtual controller, once }
  if not VirtualPadReady then
  begin
    Result.SetCount(1);
    VirtualPadReady := True;
  end;
end;

procedure UseVirtualGamepad;
begin
  ExplicitBackend;
  WritelnLog('GameInput', 'Virtual game controller for the demo script');
end;

procedure SetVirtualPadName(const Name: String);
begin
  ExplicitBackend;
  if Controllers.Count > 0 then
    Controllers[0].InternalBackend.Name := Name;
  WritelnLog('GameInput', 'Gamepad "%s": %s buttons, %s confirms, %s goes back', [Name,
    PadFamilyNames[GamepadFamily], GamepadButtonLabel(GamepadConfirmButton), GamepadButtonLabel(GamepadBackButton)]);
end;

procedure SetVirtualSticks(const Left, Right: TVector2);
begin
  ExplicitBackend.SetAxisLeft(VirtualPadIndex, Left);
  ExplicitBackend.SetAxisRight(VirtualPadIndex, Right);
end;

procedure SetVirtualRightTrigger(const Value: Single);
begin
  ExplicitBackend.SetAxisRightTrigger(VirtualPadIndex, Value);
end;

procedure SetVirtualButton(const Button: TGameControllerButton; const Pressed: Boolean);
begin
  ExplicitBackend.SetButton(VirtualPadIndex, Button, Pressed);
end;

procedure SetVirtualPadCount(const Count: Integer);
begin
  ExplicitBackend.SetCount(EnsureRange(Count, 1, 8));
  VirtualPadIndex := EnsureRange(VirtualPadIndex, 0, Controllers.Count - 1);
  WritelnLog('GameInput', 'Virtual game controllers: %d', [Controllers.Count]);
end;

function GamepadButtonByName(const Name: String; out Button: TGameControllerButton): Boolean;
var
  N: String;
begin
  N := LowerCase(Trim(Name));
  Result := True;
  if (N = 'south') or (N = 'a') then Button := gbSouth
  else if (N = 'east') or (N = 'b') then Button := gbEast
  else if (N = 'west') or (N = 'x') then Button := gbWest
  else if (N = 'north') or (N = 'y') then Button := gbNorth
  else if N = 'lb' then Button := gbLeftBumper
  else if N = 'rb' then Button := gbRightBumper
  else if N = 'up' then Button := gbDPadUp
  else if N = 'down' then Button := gbDPadDown
  else if N = 'left' then Button := gbDPadLeft
  else if N = 'right' then Button := gbDPadRight
  else if N = 'start' then Button := gbMenu
  else if N = 'back' then Button := gbView
  else
  begin
    Button := gbSouth;
    Result := False;
  end;
end;

function MakeBinding(const B: TQuakeBinding; const Key1: TKey; const Key2: TKey = keyNone;
  const MouseButtonUse: Boolean = False; const MouseButton: TCastleMouseButton = buttonLeft;
  const Wheel: TMouseWheelDirection = mwNone): TInputShortcut;
var
  Name: String;
begin
  WriteStr(Name, B);
  Delete(Name, 1, 2);
  Result := TInputShortcut.Create(nil, BindingCaptions[B], 'quake_' + LowerCase(Name), igLocal);
  Result.Assign(Key1, Key2, '', MouseButtonUse, MouseButton, Wheel);
  BindingList.Add(Result);
end;

procedure InitializeBindings;
begin
  if BindingList = nil then
    BindingList := TInputShortcutList.Create(True);
  Bindings[qbForward] := MakeBinding(qbForward, keyW, keyArrowUp);
  Bindings[qbBackward] := MakeBinding(qbBackward, keyS, keyArrowDown);
  Bindings[qbStrafeLeft] := MakeBinding(qbStrafeLeft, keyA);
  Bindings[qbStrafeRight] := MakeBinding(qbStrafeRight, keyD);
  Bindings[qbWalk] := MakeBinding(qbWalk, keyShift);
  Bindings[qbJump] := MakeBinding(qbJump, keySpace);
  Bindings[qbFire] := MakeBinding(qbFire, keyCtrl, keyNone, True, buttonLeft);
  Bindings[qbUse] := MakeBinding(qbUse, keyE);
  Bindings[qbWeapon1] := MakeBinding(qbWeapon1, key1);
  Bindings[qbWeapon2] := MakeBinding(qbWeapon2, key2);
  Bindings[qbWeapon3] := MakeBinding(qbWeapon3, key3);
  Bindings[qbWeapon4] := MakeBinding(qbWeapon4, key4);
  Bindings[qbWeapon5] := MakeBinding(qbWeapon5, key5);
  Bindings[qbWeapon6] := MakeBinding(qbWeapon6, key6);
  Bindings[qbWeapon7] := MakeBinding(qbWeapon7, key7);
  Bindings[qbWeapon8] := MakeBinding(qbWeapon8, key8);
  Bindings[qbNextWeapon] := MakeBinding(qbNextWeapon, keyNone, keyNone, False, buttonLeft, mwUp);
  Bindings[qbPrevWeapon] := MakeBinding(qbPrevWeapon, keyNone, keyNone, False, buttonLeft, mwDown);
  Bindings[qbQuickSave] := MakeBinding(qbQuickSave, keyF6);
  Bindings[qbQuickLoad] := MakeBinding(qbQuickLoad, keyF9);
  Bindings[qbConsole] := MakeBinding(qbConsole, keyBackQuote);
  Bindings[qbCamera] := MakeBinding(qbCamera, keyF1, keyC);
  Bindings[qbShadows] := MakeBinding(qbShadows, keyF2);
  Bindings[qbScreenshot] := MakeBinding(qbScreenshot, keyF12);
  Bindings[qbPhotoMode] := MakeBinding(qbPhotoMode, keyP);
  Bindings[qbChat] := MakeBinding(qbChat, keyT);
  Bindings[qbScoreboard] := MakeBinding(qbScoreboard, keyTab);
  try
    UserConfig.Load;
    ConfigLoaded := True;
    BindingList.LoadFromConfig(UserConfig, 'bindings');
    LoadGamepadSettings;
  except
    on E: Exception do
      WritelnWarning('GameInput', 'Cannot load the user config: ' + E.Message);
  end;
  try
    Controllers.Initialize;
    if Controllers.Count > 0 then
      WritelnLog('GameInput', 'Game controller: "%s"', [Controllers[0].Name]);
  except
    on E: Exception do
      WritelnWarning('GameInput', 'Game controllers unavailable: ' + E.Message);
  end;
end;

procedure SaveBindings;
begin
  if not ConfigLoaded then
    Exit;
  try
    BindingList.SaveToConfig(UserConfig, 'bindings');
    UserConfig.Save;
  except
    on E: Exception do
      WritelnWarning('GameInput', 'Cannot save the user config: ' + E.Message);
  end;
end;

procedure ResetBindings;
var
  B: TQuakeBinding;
begin
  for B := Low(TQuakeBinding) to High(TQuakeBinding) do
    if Bindings[B] <> nil then
      Bindings[B].MakeDefault;
  SaveBindings;
end;

function AssignBinding(const B: TQuakeBinding; const Event: TInputPressRelease): Boolean;
begin
  Result := False;
  if Bindings[B] = nil then
    Exit;
  case Event.EventType of
    itKey:
      if Event.Key <> keyNone then
      begin
        Bindings[B].AssignCurrent(Event.Key);
        Result := True;
      end;
    itMouseButton:
      begin
        Bindings[B].AssignCurrent(keyNone, keyNone, '', True, Event.MouseButton);
        Result := True;
      end;
    itMouseWheel:
      begin
        Bindings[B].AssignCurrent(keyNone, keyNone, '', False, buttonLeft, Event.MouseWheel);
        Result := True;
      end;
    else ;
  end;
  if Result then
    SaveBindings;
end;

function BindingDescription(const B: TQuakeBinding): String;
begin
  if Bindings[B] = nil then
    Result := ''
  else
    Result := Bindings[B].Description('none');
end;

function GamepadButtonFor(const B: TQuakeBinding; out Button: TGameControllerButton): Boolean;
begin
  { Always set: callers may read Button with the result (the compiler can
    evaluate both sides of "and") }
  Button := gbSouth;
  Result := True;
  case B of
    qbJump: Button := GamepadJump;
    qbUse: Button := GamepadUse;
    qbFire: Button := GamepadFire;
    qbNextWeapon: Button := GamepadNextWeapon;
    qbPrevWeapon: Button := GamepadPrevWeapon;
    qbPhotoMode: Button := gbView;
    else Result := False;
  end;
end;

function BindingHeld(const B: TQuakeBinding; const Container: TCastleContainer;
  const Player: Integer): Boolean;
var
  C: TGameController;
  Button: TGameControllerButton;
begin
  Result := (Player <> 2) and (Bindings[B] <> nil) and (Container <> nil) and Bindings[B].IsPressed(Container);
  if Result then
    Exit;
  if GamepadButtonFor(B, Button) and HasTouch(Player) then
    if TouchButtons[Button] then
      Exit(True);
  C := PlayerController(Player);
  if C = nil then
    Exit;
  if GamepadButtonFor(B, Button) and C.Pressed[Button] then
    Exit(True);
  { The right trigger fires too }
  if (B = qbFire) and (C.AxisRightTrigger > 0.5) then
    Exit(True);
end;

function BindingEvent(const B: TQuakeBinding; const Event: TInputPressRelease): Boolean;
begin
  Result := (Bindings[B] <> nil) and Bindings[B].IsEvent(Event);
end;

procedure UpdateGamepad(const Player: Integer);
var
  Button: TGameControllerButton;
  Down: Boolean;
  P: Integer;
begin
  P := EnsureRange(Player, 0, 4);
  for Button := Low(TGameControllerButton) to High(TGameControllerButton) do
  begin
    Down := GamepadButtonDown(Button, P);
    JustPressed[P, Button] := Down and not WasPressed[P, Button];
    WasPressed[P, Button] := Down;
  end;
end;

function GamepadButtonDown(const Button: TGameControllerButton; const Player: Integer): Boolean;
var
  C: TGameController;
begin
  C := PlayerController(Player);
  Result := ((C <> nil) and C.Pressed[Button]) or (HasTouch(Player) and TouchButtons[Button]);
end;

function GamepadJustPressed(const Button: TGameControllerButton; const Player: Integer): Boolean;
begin
  Result := JustPressed[EnsureRange(Player, 0, 4), Button];
end;

function ApplyDeadZone(const V: Single): Single;
begin
  if Abs(V) <= GamepadDeadZone then
    Result := 0
  else
    Result := Sign(V) * Min(1.0, (Abs(V) - GamepadDeadZone) / (1 - GamepadDeadZone));
end;

procedure GamepadMove(out Forward, Side: Single; const Player: Integer);
var
  C: TGameController;
  Stick: TVector2;
begin
  { The touch stick has no dead zone of its own (GameTouch keeps a small one) }
  Forward := 0;
  Side := 0;
  if HasTouch(Player) then
  begin
    Forward := TouchMove.Y;
    Side := TouchMove.X;
  end;
  C := PlayerController(Player);
  if C <> nil then
  begin
    Stick := C.AxisLeft;
    Forward := Forward + ApplyDeadZone(Stick.Y);
    Side := Side + ApplyDeadZone(Stick.X);
  end;
  Forward := EnsureRange(Forward, -1, 1);
  Side := EnsureRange(Side, -1, 1);
end;

procedure GamepadTurnCamera(const Camera: TCastleCamera; const SecondsPassed: Single; const Player: Integer);
var
  C: TGameController;
  Stick: TVector2;
  Dir, Up, Side: TVector3;
  Yaw, Pitch, CurrentPitch: Single;
begin
  if Camera = nil then
    Exit;
  Yaw := 0;
  Pitch := 0;
  C := PlayerController(Player);
  if C <> nil then
  begin
    Stick := C.AxisRight;
    Yaw := -ApplyDeadZone(Stick.X) * GamepadYawSpeed * GamepadSensitivity * SecondsPassed;
    Pitch := ApplyDeadZone(Stick.Y) * GamepadPitchSpeed * GamepadSensitivity * SecondsPassed;
    if GamepadInvertLook then
      Pitch := -Pitch;
  end;
  { The touch look drag: turned once, like a mouse move }
  if HasTouch(Player) then
  begin
    Yaw := Yaw - TouchLookDelta.X * TouchLookDegrees;
    Pitch := Pitch + TouchLookDelta.Y * TouchLookDegrees;
    TouchLookDelta := TVector2.Zero;
  end;
  if (Yaw = 0) and (Pitch = 0) then
    Exit;
  Dir := Camera.Direction;
  Up := Vector3(0, 1, 0);
  Dir := RotatePointAroundAxisDeg(Yaw, Dir, Up);
  { Pitch, kept away from straight up / down }
  CurrentPitch := RadToDeg(ArcSin(EnsureRange(Dir.Y, -1, 1)));
  Pitch := EnsureRange(CurrentPitch + Pitch, -85, 85) - CurrentPitch;
  Side := TVector3.CrossProduct(Dir, Up);
  if not Side.IsZero then
    Dir := RotatePointAroundAxisDeg(Pitch, Dir, Side.Normalize);
  Camera.SetWorldView(Camera.Translation, Dir, Up);
end;

finalization
  FreeAndNil(BindingList);
end.
