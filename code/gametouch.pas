{ On-screen controls for touch screens: a move stick on the left (it
  appears where the finger lands), look by dragging on the right, and
  fire, jump, use, weapon and menu buttons. They feed GameInput's touch
  state (TouchMove, TouchLookDelta, TouchButtons), which the views read
  through the same helpers as the game controller.

  Native builds (Android, or -touch on a desktop) take the fingers from the
  engine's press / motion / release events (FingerIndex). The web build has
  only one pointer in the engine, so a small JS helper tracks the browser's
  touch pointers by pointerId and keeps them from reaching the engine as
  mouse clicks while the controls are shown; the controls turn on by
  themselves at the first touch. The layout is the editor design
  data/ui/touch.castle-user-interface, scaled with the window height. }
unit GameTouch;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, Generics.Collections,
  CastleVectors, CastleUIControls, CastleControls, CastleKeysMouse, CastleGameControllers,
  CastleComponentSerialize, CastleApplicationProperties, CastleLog, CastleRectangles;

type
  TTouchControlsMode = (tcAuto, tcOn, tcOff);

  TQuakeTouchControls = class(TCastleUserInterface)
  private
    type
      TTouchRole = (trMove, trLook, trButton);
      TTouchPoint = record
        Role: TTouchRole;
        Button: TGameControllerButton;
        Start, Last: TVector2;
      end;
      TTouchButton = record
        Control: TCastleUserInterface;
        Button: TGameControllerButton;
      end;
      TDesignSize = record
        Control: TCastleUserInterface;
        Width, Height: Single;
        Translation: TVector2;
      end;
    var
      FDesign: TCastleUserInterface;
      FMoveBase, FMoveKnob: TCastleUserInterface;
      FButtons: array of TTouchButton;
      FSizes: array of TDesignSize;
      FTouches: specialize TDictionary<Integer, TTouchPoint>;
      FScale: Single;
      FMenuPressed: Boolean;
    function ButtonAt(const P: TVector2; out Button: TGameControllerButton): Boolean;
    procedure ApplyScale;
    procedure Publish;
    procedure PollWeb;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Resize; override;
    procedure Update(const SecondsPassed: Single; var HandleInput: Boolean); override;
    function Press(const Event: TInputPressRelease): Boolean; override;
    function Release(const Event: TInputPressRelease): Boolean; override;
    function Motion(const Event: TInputMotion): Boolean; override;

    { A finger down / moved / up at a container position (pixels, from the
      bottom left); the events and the demo script's TD / TM / TU end here }
    procedure TouchDown(const Id: Integer; const P: TVector2);
    procedure TouchMoved(const Id: Integer; const P: TVector2);
    procedure TouchUp(const Id: Integer);
    procedure ReleaseAll;
    { The menu button went down since the last call }
    function MenuRequested: Boolean;
    function ActiveTouches: Integer;
    { Show the controls when they are wanted (call every frame; Playing is
      False while a menu or the console is open) }
    procedure UpdateShown(const Playing: Boolean);
  end;

var
  { -touch / -notouch, ?touch=1 / ?touch=0: on, off or by the device }
  TouchControlsMode: TTouchControlsMode = tcAuto;
  { A touch was seen (the web page) or the script used one }
  TouchSeen: Boolean;

{ The controls are wanted: forced on, or auto on a touch device or after a touch }
function TouchControlsWanted: Boolean;

implementation

uses
  GameInput {$if defined(WASI)}, Job.JS, CastleInternalJobWeb{$endif};

const
  { The design is made for a 900 pixel high window }
  DesignHeight = 900;
  { Part of the move stick's radius that does nothing }
  MoveDeadZone = 0.12;

function TouchControlsWanted: Boolean;
begin
  case TouchControlsMode of
    tcOn: Result := True;
    tcOff: Result := False;
    else Result := ApplicationProperties.TouchDevice or TouchSeen;
  end;
end;

{ The web page's touch pointers --------------------------------------------- }

{$if defined(WASI)}
const
  WebTouchHelperName = 'castleQuakeTouch';
  { Records touch pointers (pointerdown / move / up / cancel, in the capture
    phase of window, so before the engine's canvas listeners) in canvas
    pixels from the bottom left; while active it stops them there, so they
    are not mouse clicks too. Everything inside try / catch. }
  WebTouchHelperSource =
    'var t = {}; var seen = 0; var active = 0;' +
    'function canvas() { return document.querySelector("canvas"); }' +
    'function rec(e, kind) {' +
    '  try { if (e.pointerType !== "touch") return; seen = 1;' +
    '    var c = canvas(); if (!c) return;' +
    '    if (kind === 2) { delete t[e.pointerId]; }' +
    '    else if (kind === 1 || t[e.pointerId]) {' +
    '      var r = c.getBoundingClientRect();' +
    '      t[e.pointerId] = [(e.clientX - r.left) * c.width / r.width, (r.bottom - e.clientY) * c.height / r.height]; }' +
    '    if (active) { e.stopImmediatePropagation(); e.preventDefault(); }' +
    '  } catch (x) {} }' +
    'try {' +
    '  window.addEventListener("pointerdown", function (e) { rec(e, 1); }, true);' +
    '  window.addEventListener("pointermove", function (e) { rec(e, 0); }, true);' +
    '  window.addEventListener("pointerup", function (e) { rec(e, 2); }, true);' +
    '  window.addEventListener("pointercancel", function (e) { rec(e, 2); }, true);' +
    '} catch (x) {}' +
    'return {' +
    '  poll: function () { var s = ""; try { for (var k in t) s += k + "," + t[k][0] + "," + t[k][1] + ";"; } catch (x) {} return s; },' +
    '  seen: function () { return seen; },' +
    '  setActive: function (a) { active = a; try { var c = canvas(); if (c) c.style.touchAction = a ? "none" : ""; } catch (x) {} return 1; }' +
    '};';

var
  WebTouchHelper: TJSObject;
  WebTouchActive: Integer = -1;

function GetWebTouchHelper: TJSObject;
var
  FunctionClass: TJSObject;
  Factory: IJSObject;
begin
  if WebTouchHelper = nil then
  begin
    FunctionClass := TJSObject.JOBCreateGlobal('Function');
    Factory := FunctionClass.NewJSObject([UnicodeString(WebTouchHelperSource)], TJSObject);
    FunctionClass.Free;
    JSWindow.WriteJSPropertyObject(WebTouchHelperName + 'Factory', Factory);
    WebTouchHelper := JSWindow.InvokeJSObjectResult(WebTouchHelperName + 'Factory', [], TJSObject);
  end;
  Result := WebTouchHelper;
end;
{$endif}

{ TQuakeTouchControls ------------------------------------------------------- }

constructor TQuakeTouchControls.Create(AOwner: TComponent);

  procedure AddButton(const Name: String; const Button: TGameControllerButton);
  begin
    SetLength(FButtons, Length(FButtons) + 1);
    FButtons[High(FButtons)].Control := FindRequiredComponent(Name) as TCastleUserInterface;
    FButtons[High(FButtons)].Button := Button;
  end;

  procedure KeepSize(const C: TCastleUserInterface);
  var
    I: Integer;
  begin
    SetLength(FSizes, Length(FSizes) + 1);
    FSizes[High(FSizes)].Control := C;
    FSizes[High(FSizes)].Width := C.Width;
    FSizes[High(FSizes)].Height := C.Height;
    FSizes[High(FSizes)].Translation := C.Translation;
    for I := 0 to C.ControlsCount - 1 do
      KeepSize(C.Controls[I]);
  end;

var
  I: Integer;
begin
  inherited Create(AOwner);
  FullSize := True;
  FTouches := specialize TDictionary<Integer, TTouchPoint>.Create;
  FDesign := UserInterfaceLoad('castle-data:/ui/touch.castle-user-interface', Self);
  InsertFront(FDesign);
  FMoveBase := FindRequiredComponent('MoveBase') as TCastleUserInterface;
  FMoveKnob := FindRequiredComponent('MoveKnob') as TCastleUserInterface;
  AddButton('FireButton', GamepadFire);
  AddButton('JumpButton', GamepadJump);
  AddButton('UseButton', GamepadUse);
  AddButton('NextWeaponButton', GamepadNextWeapon);
  AddButton('PrevWeaponButton', GamepadPrevWeapon);
  AddButton('MenuButton', gbMenu);
  for I := 0 to FDesign.ControlsCount - 1 do
    KeepSize(FDesign.Controls[I]);
  FScale := 1;
  Exists := False;
end;

destructor TQuakeTouchControls.Destroy;
begin
  ReleaseAll;
  FreeAndNil(FTouches);
  inherited Destroy;
end;

procedure TQuakeTouchControls.ApplyScale;
var
  I: Integer;
begin
  for I := 0 to High(FSizes) do
  begin
    FSizes[I].Control.Width := FSizes[I].Width * FScale;
    FSizes[I].Control.Height := FSizes[I].Height * FScale;
    FSizes[I].Control.Translation := FSizes[I].Translation * FScale;
  end;
end;

procedure TQuakeTouchControls.Resize;
begin
  inherited;
  if (Container <> nil) and (Container.PixelsHeight > 0) then
  begin
    FScale := Max(0.5, Container.PixelsHeight / DesignHeight);
    ApplyScale;
  end;
end;

function TQuakeTouchControls.ButtonAt(const P: TVector2; out Button: TGameControllerButton): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FButtons) do
    if FButtons[I].Control.RenderRect.Grow(8 * FScale).Contains(P) then
    begin
      Button := FButtons[I].Button;
      Exit(True);
    end;
  Button := gbSouth;
  Result := False;
end;

procedure TQuakeTouchControls.Publish;
var
  T: TTouchPoint;
  Button: TGameControllerButton;
  Radius: Single;
  D: TVector2;
  Moving: Boolean;
begin
  for Button := Low(TGameControllerButton) to High(TGameControllerButton) do
    TouchButtons[Button] := False;
  TouchMove := TVector2.Zero;
  Moving := False;
  for T in FTouches.Values do
    case T.Role of
      trButton:
        TouchButtons[T.Button] := True;
      trMove:
        begin
          { The deflection from where the finger landed, the stick's radius
            giving full speed }
          Radius := Max(1, FMoveBase.RenderRect.Width / 2);
          D := (T.Last - T.Start) / Radius;
          if D.Length > 1 then
            D := D / D.Length;
          if D.Length < MoveDeadZone then
            D := TVector2.Zero;
          TouchMove := D;
          { The knob follows the finger; the base sits under its landing point }
          FMoveKnob.Translation := D * (FMoveBase.Width / 2 - FMoveKnob.Width / 2);
          FMoveBase.Translation := Vector2(T.Start.X - FMoveBase.RenderRect.Width / 2,
            T.Start.Y - FMoveBase.RenderRect.Height / 2) / UIScale;
          Moving := True;
        end;
      else ;
    end;
  if not Moving then
  begin
    FMoveKnob.Translation := TVector2.Zero;
    FMoveBase.Translation := FSizes[0].Translation * FScale;
  end;
  if TouchButtons[gbMenu] then
    FMenuPressed := True;
end;

procedure TQuakeTouchControls.TouchDown(const Id: Integer; const P: TVector2);
var
  T: TTouchPoint;
begin
  TouchSeen := True;
  T.Start := P;
  T.Last := P;
  T.Button := gbSouth;
  if ButtonAt(P, T.Button) then
    T.Role := trButton
  else
  if (Container <> nil) and (P.X < Container.PixelsWidth / 2) then
    T.Role := trMove
  else
    T.Role := trLook;
  FTouches.AddOrSetValue(Id, T);
  Publish;
end;

procedure TQuakeTouchControls.TouchMoved(const Id: Integer; const P: TVector2);
var
  T: TTouchPoint;
begin
  if not FTouches.TryGetValue(Id, T) then
    Exit;
  if (T.Role = trLook) and (Container <> nil) and (Container.PixelsHeight > 0) then
    TouchLookDelta := TouchLookDelta + (P - T.Last) / Container.PixelsHeight;
  T.Last := P;
  FTouches.AddOrSetValue(Id, T);
  Publish;
end;

procedure TQuakeTouchControls.TouchUp(const Id: Integer);
begin
  if FTouches.ContainsKey(Id) then
  begin
    FTouches.Remove(Id);
    Publish;
  end;
end;

procedure TQuakeTouchControls.ReleaseAll;
var
  Button: TGameControllerButton;
begin
  if FTouches <> nil then
    FTouches.Clear;
  TouchMove := TVector2.Zero;
  TouchLookDelta := TVector2.Zero;
  for Button := Low(TGameControllerButton) to High(TGameControllerButton) do
    TouchButtons[Button] := False;
end;

function TQuakeTouchControls.MenuRequested: Boolean;
begin
  Result := FMenuPressed;
  FMenuPressed := False;
end;

function TQuakeTouchControls.ActiveTouches: Integer;
begin
  Result := FTouches.Count;
end;

procedure TQuakeTouchControls.UpdateShown(const Playing: Boolean);
var
  Shown: Boolean;
begin
  {$if defined(WASI)}
  if GetWebTouchHelper.InvokeJSLongIntResult('seen', []) = 1 then
    TouchSeen := True;
  {$endif}
  Shown := Playing and TouchControlsWanted;
  if Shown <> Exists then
  begin
    Exists := Shown;
    if not Shown then
      ReleaseAll
    else
    begin
      Resize;
      WritelnLog('GameTouch', 'Touch controls shown (%s)', [BoolToStr(TouchSeen, 'a touch was seen', 'forced or a touch device')]);
    end;
  end;
  {$if defined(WASI)}
  if Ord(Shown) <> WebTouchActive then
  begin
    WebTouchActive := Ord(Shown);
    GetWebTouchHelper.InvokeJSLongIntResult('setActive', [WebTouchActive]);
  end;
  {$endif}
end;

procedure TQuakeTouchControls.PollWeb;
{$if defined(WASI)}
var
  S, Item: String;
  Parts: TStringArray;
  Id: Integer;
  X, Y: Single;
  Seen: specialize TList<Integer>;
  Fmt: TFormatSettings;
  K: Integer;
begin
  { The helper's list of the touches now down: new ones go down, known
    ones move, missing ones went up }
  S := String(GetWebTouchHelper.InvokeJSUnicodeStringResult('poll', []));
  Fmt := DefaultFormatSettings;
  Fmt.DecimalSeparator := '.';
  Seen := specialize TList<Integer>.Create;
  try
    for Item in S.Split([';'], TStringSplitOptions.ExcludeEmpty) do
    begin
      Parts := Item.Split([',']);
      if (Length(Parts) <> 3) or not TryStrToInt(Parts[0], Id) then
        Continue;
      X := StrToFloatDef(Parts[1], 0, Fmt);
      Y := StrToFloatDef(Parts[2], 0, Fmt);
      Seen.Add(Id);
      if FTouches.ContainsKey(Id) then
        TouchMoved(Id, Vector2(X, Y))
      else
        TouchDown(Id, Vector2(X, Y));
    end;
    for K in FTouches.Keys.ToArray do
      if Seen.IndexOf(K) < 0 then
        TouchUp(K);
  finally
    Seen.Free;
  end;
end;
{$else}
begin
end;
{$endif}

procedure TQuakeTouchControls.Update(const SecondsPassed: Single; var HandleInput: Boolean);
begin
  inherited;
  PollWeb;
end;

function TQuakeTouchControls.Press(const Event: TInputPressRelease): Boolean;
begin
  Result := inherited Press(Event);
  if Result then
    Exit;
  {$if not defined(WASI)}
  { Fingers (or the mouse with -touch) }
  if Event.EventType = itMouseButton then
  begin
    TouchDown(Event.FingerIndex, Event.Position);
    Exit(True);
  end;
  {$endif}
end;

function TQuakeTouchControls.Release(const Event: TInputPressRelease): Boolean;
begin
  Result := inherited Release(Event);
  if Result then
    Exit;
  {$if not defined(WASI)}
  if Event.EventType = itMouseButton then
  begin
    TouchUp(Event.FingerIndex);
    Exit(True);
  end;
  {$endif}
end;

function TQuakeTouchControls.Motion(const Event: TInputMotion): Boolean;
begin
  Result := inherited Motion(Event);
  if Result then
    Exit;
  {$if not defined(WASI)}
  if FTouches.ContainsKey(Event.FingerIndex) then
  begin
    TouchMoved(Event.FingerIndex, Event.Position);
    Exit(True);
  end;
  {$endif}
end;

end.
