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
    qbNextWeapon, qbPrevWeapon, qbQuickSave, qbQuickLoad, qbConsole, qbCamera, qbShadows, qbScreenshot);

const
  BindingCaptions: array[TQuakeBinding] of String = (
    'Move forward', 'Move backward', 'Strafe left', 'Strafe right', 'Walk (slow)', 'Jump', 'Fire', 'Use',
    'Axe', 'Shotgun', 'Super shotgun', 'Nailgun', 'Super nailgun', 'Grenade launcher', 'Rocket launcher',
    'Thunderbolt', 'Next weapon', 'Previous weapon', 'Quick save', 'Quick load', 'Console', 'Camera view',
    'Shadows', 'Screenshot');
  { The gamepad: the left stick moves, the right stick turns, these
    buttons are the bindings }
  GamepadJump = gbSouth;
  GamepadUse = gbWest;
  GamepadFire = gbRightBumper;
  GamepadNextWeapon = gbDPadRight;
  GamepadPrevWeapon = gbDPadLeft;
  GamepadStickDeadZone = 0.2;
  GamepadYawSpeed = 160.0;   { degrees per second at full deflection }
  GamepadPitchSpeed = 90.0;

var
  Bindings: array[TQuakeBinding] of TInputShortcut;
  { The same shortcuts as a list (owns them), for the config file; they are
    local shortcuts, apart from the engine's own global ones }
  BindingList: TInputShortcutList;

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
function BindingHeld(const B: TQuakeBinding; const Container: TCastleContainer): Boolean;
{ A press event is this binding }
function BindingEvent(const B: TQuakeBinding; const Event: TInputPressRelease): Boolean;
{ A gamepad button went down since the last UpdateGamepad }
function GamepadJustPressed(const Button: TGameControllerButton): Boolean;
{ The left stick as movement fractions (-1..1): forward and side }
procedure GamepadMove(out Forward, Side: Single);
{ Turn the camera with the right stick (call every frame when playing) }
procedure GamepadTurnCamera(const Camera: TCastleCamera; const SecondsPassed: Single);
{ Refresh the just-pressed state of the gamepad buttons; once per frame }
procedure UpdateGamepad;
function GamepadConnected: Boolean;

implementation

var
  WasPressed, JustPressed: array[TGameControllerButton] of Boolean;
  ConfigLoaded: Boolean;

function FirstController: TGameController;
begin
  if Controllers.Count > 0 then
    Result := Controllers[0]
  else
    Result := nil;
end;

function GamepadConnected: Boolean;
begin
  Result := FirstController <> nil;
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
  try
    UserConfig.Load;
    ConfigLoaded := True;
    BindingList.LoadFromConfig(UserConfig, 'bindings');
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
  Result := True;
  case B of
    qbJump: Button := GamepadJump;
    qbUse: Button := GamepadUse;
    qbFire: Button := GamepadFire;
    qbNextWeapon: Button := GamepadNextWeapon;
    qbPrevWeapon: Button := GamepadPrevWeapon;
    else Result := False;
  end;
end;

function BindingHeld(const B: TQuakeBinding; const Container: TCastleContainer): Boolean;
var
  C: TGameController;
  Button: TGameControllerButton;
begin
  Result := (Bindings[B] <> nil) and (Container <> nil) and Bindings[B].IsPressed(Container);
  if Result then
    Exit;
  C := FirstController;
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

procedure UpdateGamepad;
var
  C: TGameController;
  Button: TGameControllerButton;
begin
  C := FirstController;
  for Button := Low(TGameControllerButton) to High(TGameControllerButton) do
  begin
    JustPressed[Button] := (C <> nil) and C.Pressed[Button] and not WasPressed[Button];
    WasPressed[Button] := (C <> nil) and C.Pressed[Button];
  end;
end;

function GamepadJustPressed(const Button: TGameControllerButton): Boolean;
begin
  Result := JustPressed[Button];
end;

function DeadZone(const V: Single): Single;
begin
  if Abs(V) < GamepadStickDeadZone then
    Result := 0
  else
    Result := Sign(V) * (Abs(V) - GamepadStickDeadZone) / (1 - GamepadStickDeadZone);
end;

procedure GamepadMove(out Forward, Side: Single);
var
  C: TGameController;
  Stick: TVector2;
begin
  Forward := 0;
  Side := 0;
  C := FirstController;
  if C = nil then
    Exit;
  Stick := C.AxisLeft;
  Forward := EnsureRange(DeadZone(Stick.Y), -1, 1);
  Side := EnsureRange(DeadZone(Stick.X), -1, 1);
end;

procedure GamepadTurnCamera(const Camera: TCastleCamera; const SecondsPassed: Single);
var
  C: TGameController;
  Stick: TVector2;
  Dir, Up, Side: TVector3;
  Yaw, Pitch, CurrentPitch: Single;
begin
  C := FirstController;
  if (C = nil) or (Camera = nil) then
    Exit;
  Stick := C.AxisRight;
  Yaw := -DeadZone(Stick.X) * GamepadYawSpeed * SecondsPassed;
  Pitch := DeadZone(Stick.Y) * GamepadPitchSpeed * SecondsPassed;
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
