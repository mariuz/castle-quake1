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
  public
    { The menu's actions; the play view's menu hands it the ones that leave
      the game for another view (host, join, a demo) }
    procedure HandleMenuAction(const Action: TMenuAction; const Param: String);
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
var
  Map, Address: String;
begin
  case Action of
    maNewGame:
      begin
        Pak.PreferOriginal := Param = 'quake';
        ViewPlay.HordeMode := False;
        ViewPlay.MapName := 'start';
        Container.View := ViewPlay;
      end;
    maWarpMap:
      begin
        { horde:<map> plays the map in horde mode }
        Map := Param;
        ViewPlay.HordeMode := Pos('horde:', Map) = 1;
        if ViewPlay.HordeMode then
          Delete(Map, 1, Length('horde:'));
        { Original episode maps come with the id1 hub to return to }
        Pak.PreferOriginal := (Map <> 'maps/start.bsp') and Pak.OriginalFileExists(Map);
        ViewPlay.MapName := Map;
        Container.View := ViewPlay;
      end;
    maLoadGame:
      begin
        { The play view starts from the savegame }
        ViewPlay.HordeMode := False;
        ViewPlay.LoadSlot := Param;
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
        ViewDemo.Spectate := False;
        ViewDemo.DemoName := Param;
        ViewDemo.NetHost := '';
        ViewDemo.HostMap := '';
        ViewDemo.AutoTestPrefix := '';
        ViewDemo.AutoTestScript := '';
        Container.View := ViewDemo;
      end;
    maHostGame:
      begin
        ViewDemo.Spectate := False;
        ViewDemo.DemoName := '';
        ViewDemo.NetHost := '';
        ViewDemo.NetPort := 0;
        ViewDemo.HostCoop := Pos('coop:', Param) = 1;
        ViewDemo.HostSkill := 1;
        ViewDemo.HostBots := 0;
        { split:<map>: split-screen coop, a second player with the gamepad }
        ViewDemo.SplitScreen := Pos('split:', Param) = 1;
        ViewDemo.SplitStacked := False;
        ViewDemo.SplitPlayers := 2;
        if ViewDemo.SplitScreen then
        begin
          ViewDemo.HostCoop := True;
          ViewDemo.HostMap := Copy(Param, 7, MaxInt);
        end else
        if ViewDemo.HostCoop then
          ViewDemo.HostMap := Copy(Param, 6, MaxInt)
        else if Pos('bots:', Param) = 1 then
        begin
          { bots:<map>: deathmatch against three bots }
          ViewDemo.HostBots := 3;
          ViewDemo.HostMap := Copy(Param, 6, MaxInt);
        end else
          ViewDemo.HostMap := Param;
        ViewDemo.AutoTestPrefix := '';
        ViewDemo.AutoTestScript := '';
        Container.View := ViewDemo;
      end;
    maJoinGame:
      begin
        ViewDemo.DemoName := '';
        ViewDemo.HostMap := '';
        { [spectate:]host[:port] (a game Find LAN Games found) }
        Address := Param;
        ViewDemo.Spectate := Pos('spectate:', Address) = 1;
        if ViewDemo.Spectate then
          Delete(Address, 1, Length('spectate:'));
        ViewDemo.NetHost := Address;
        ViewDemo.NetPort := 0;
        if Pos(':', Address) > 0 then
        begin
          ViewDemo.NetHost := Copy(Address, 1, Pos(':', Address) - 1);
          ViewDemo.NetPort := StrToIntDef(Copy(Address, Pos(':', Address) + 1, MaxInt), 0);
        end;
        ViewDemo.SplitScreen := False;
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
