{ The title screen / menu view. }
unit GameViewMenu;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils,
  CastleVectors, CastleUIControls, CastleControls, CastleKeysMouse,
  CastleWindow, CastleColors, CastleLog,
  QuakeSound, QuakeMenu, QuakePak, GameViewPlay, GameViewDemo, GameViewQc;

type
  TViewMenu = class(TCastleView)
  private
    FMenu: TQuakeMenu;
    procedure HandleMenuAction(const Action: TMenuAction; const Param: String);
  public
    constructor Create(AOwner: TComponent); override;
    procedure Start; override;
    procedure Stop; override;
    function Press(const Event: TInputPressRelease): Boolean; override;
  end;

var
  ViewMenu: TViewMenu;

implementation

constructor TViewMenu.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FMenu := TQuakeMenu.Create(Self);
  FMenu.OnMenuAction := @HandleMenuAction;
  InsertFront(FMenu);
end;

procedure TViewMenu.Start;
begin
  inherited Start;
  Sounds.PlayMusic('track02.ogg');
end;

procedure TViewMenu.Stop;
begin
  inherited Stop;
end;

procedure TViewMenu.HandleMenuAction(const Action: TMenuAction; const Param: String);
begin
  case Action of
    maNewGame:
      begin
        Pak.PreferOriginalMaps := Param = 'quake';
        ViewPlay.MapName := 'start';
        Container.View := ViewPlay;
      end;
    maWarpMap:
      begin
        { Original episode maps come with the id1 hub to return to }
        Pak.PreferOriginalMaps := (Param <> 'maps/start.bsp') and Pak.OriginalFileExists(Param);
        ViewPlay.MapName := Param;
        Container.View := ViewPlay;
      end;
    maPlayQc:
      begin
        ViewQc.MapName := Param;
        ViewQc.AutoTestPrefix := '';
        ViewQc.AutoTestScript := '';
        Container.View := ViewQc;
      end;
    maPlayDemo:
      begin
        ViewDemo.DemoName := Param;
        ViewDemo.AutoTestPrefix := '';
        ViewDemo.AutoTestScript := '';
        Container.View := ViewDemo;
      end;
    maQuit:
      Application.Terminate;
  end;
end;

function TViewMenu.Press(const Event: TInputPressRelease): Boolean;
begin
  Result := FMenu.Press(Event);
end;

end.
