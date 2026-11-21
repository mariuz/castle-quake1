{ The log as the test scripts see it: the WL:<text> action of every view's
  script waits until a log line with that text appears (the client joined,
  the level changed) instead of a number of seconds. The lines are kept
  only in an autotest run. }
unit GameLogWatch;

{$mode objfpc}{$H+}

interface

const
  { A WL: action gives up after this many seconds and the script goes on }
  LogWaitTimeout = 30.0;

{ Keep the log lines from now on (an autotest run); safe to call twice }
procedure StartLogWatch;
{ One frame of a script's WL:<text> action. True while the script has to
  wait: no line after the last one a WL: found has Text yet. False once it
  has (logs "LogWatch: found "<text>" after N s") or after LogWaitTimeout
  (logs "LogWatch: gave up on "<text>" after N s"); Timer is the action's
  time so far and is set back to 0 then. }
function ScriptWaitsForLog(const Text: String; const SecondsPassed: Single; var Timer: Single): Boolean;
{ For the unit tests: forget the lines kept and the position, and add a
  line as the log would }
procedure ResetLogWatch;
procedure LogWatchLine(const Message: String);

implementation

uses
  SysUtils, Classes, CastleLog, CastleApplicationProperties;

type
  TLogWatch = class
    Lines: TStringList;
    { The first line the next WL: looks at }
    Position: Integer;
    constructor Create;
    destructor Destroy; override;
    procedure HandleLog(const Message: String);
  end;

var
  Watch: TLogWatch;

constructor TLogWatch.Create;
begin
  inherited Create;
  Lines := TStringList.Create;
end;

destructor TLogWatch.Destroy;
begin
  Lines.Free;
  inherited Destroy;
end;

procedure TLogWatch.HandleLog(const Message: String);
begin
  { Not the lines that quote the text waited for: this unit's own and the
    one that shows the script }
  if (Pos('LogWatch: ', Message) = 0) and (Pos('GameInitialize: Parsed AutoTestMap', Message) = 0) and
     (Pos('GameInitialize: Web autotest', Message) = 0) then
    Lines.Add(Message);
end;

procedure StartLogWatch;
begin
  if Watch <> nil then
    Exit;
  Watch := TLogWatch.Create;
  ApplicationProperties.OnLog.Add(@Watch.HandleLog);
end;

procedure ResetLogWatch;
begin
  if Watch <> nil then
  begin
    Watch.Lines.Clear;
    Watch.Position := 0;
  end;
end;

procedure LogWatchLine(const Message: String);
begin
  StartLogWatch;
  Watch.HandleLog(Message);
end;

function ScriptWaitsForLog(const Text: String; const SecondsPassed: Single; var Timer: Single): Boolean;
var
  I: Integer;
begin
  StartLogWatch;
  if Text <> '' then
    for I := Watch.Position to Watch.Lines.Count - 1 do
      if Pos(Text, Watch.Lines[I]) > 0 then
      begin
        Watch.Position := I + 1;
        WritelnLog('LogWatch', 'found "%s" after %.1f s', [Text, Timer]);
        Timer := 0;
        Exit(False);
      end;
  Timer := Timer + SecondsPassed;
  Result := (Text <> '') and (Timer < LogWaitTimeout);
  if not Result then
  begin
    WritelnLog('LogWatch', 'gave up on "%s" after %.1f s', [Text, Timer]);
    Timer := 0;
  end;
end;

finalization
  if Watch <> nil then
  begin
    if ApplicationProperties(false) <> nil then
      ApplicationProperties.OnLog.Remove(@Watch.HandleLog);
    FreeAndNil(Watch);
  end;
end.
