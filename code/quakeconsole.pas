{ Quake in-game developer console and cheat commands. }
unit QuakeConsole;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math,
  CastleVectors, CastleUIControls, CastleControls, CastleKeysMouse, CastleColors,
  CastleRectangles, CastleGLUtils, CastleWindow, CastleComponentSerialize;

type
  TConsoleCommandEvent = procedure(const Cmd, Args: String) of object;

  { Drop-down developer console }
  TQuakeConsole = class(TCastleUserInterface)
  private
    FIsOpen: Boolean;
    FLines: TStringList;
    FHistory: TStringList;
    FHistoryIndex: Integer;
    FInputText: String;
    FOnCommand: TConsoleCommandEvent;
    FHeightFraction: Single;
    { The editor design (data/ui/console.castle-user-interface) }
    FDesign: TCastleUserInterface;
    FPanel: TCastleUserInterface;
    FOutputLabel, FPromptLabel: TCastleLabel;
    procedure SyncDesign;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    procedure Toggle;
    procedure Open;
    procedure Close;

    { Add text line to console buffer }
    procedure Print(const S: String);

    function Press(const Event: TInputPressRelease): Boolean; override;
    procedure Update(const SecondsPassed: Single; var HandleInput: Boolean); override;

    property IsOpen: Boolean read FIsOpen;
    property OnCommand: TConsoleCommandEvent read FOnCommand write FOnCommand;
  end;

implementation

constructor TQuakeConsole.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FullSize := True;
  FIsOpen := False;
  FLines := TStringList.Create;
  FHistory := TStringList.Create;
  FHistoryIndex := -1;
  FInputText := '';
  FHeightFraction := 0.45;
  FDesign := UserInterfaceLoad('castle-data:/ui/console.castle-user-interface', Self);
  InsertFront(FDesign);
  FPanel := FindRequiredComponent('Panel') as TCastleUserInterface;
  FOutputLabel := FindRequiredComponent('OutputLabel') as TCastleLabel;
  FPromptLabel := FindRequiredComponent('PromptLabel') as TCastleLabel;
  FPanel.HeightFraction := FHeightFraction;

  Print('Castle Quake Developer Console');
  Print('Type "help" for a list of available commands.');
end;

destructor TQuakeConsole.Destroy;
begin
  FLines.Free;
  FHistory.Free;
  inherited Destroy;
end;

procedure TQuakeConsole.Toggle;
begin
  if FIsOpen then
    Close
  else
    Open;
end;

procedure TQuakeConsole.Open;
begin
  FIsOpen := True;
  FInputText := '';
  FHistoryIndex := -1;
end;

procedure TQuakeConsole.Close;
begin
  FIsOpen := False;
end;

procedure TQuakeConsole.Print(const S: String);
begin
  FLines.Add(S);
  while FLines.Count > 100 do
    FLines.Delete(0);
end;

function TQuakeConsole.Press(const Event: TInputPressRelease): Boolean;
var
  FullCmd, Cmd, Args: String;
  P: Integer;
begin
  Result := False;
  if not FIsOpen then
  begin
    if Event.IsKey(keyBackQuote) or (Event.KeyString = '~') or (Event.KeyString = '`') then
    begin
      Toggle;
      Exit(True);
    end;
    Exit(False);
  end;

  { Key handling inside console }
  if Event.IsKey(keyBackQuote) or (Event.KeyString = '~') or (Event.KeyString = '`') or Event.IsKey(keyEscape) then
  begin
    Close;
    Exit(True);
  end;

  if Event.IsKey(keyEnter) then
  begin
    FullCmd := Trim(FInputText);
    FInputText := '';
    if FullCmd <> '' then
    begin
      Print('] ' + FullCmd);
      FHistory.Add(FullCmd);
      FHistoryIndex := FHistory.Count;

      P := Pos(' ', FullCmd);
      if P > 0 then
      begin
        Cmd := LowerCase(Copy(FullCmd, 1, P - 1));
        Args := Trim(Copy(FullCmd, P + 1, Length(FullCmd)));
      end else
      begin
        Cmd := LowerCase(FullCmd);
        Args := '';
      end;

      if Assigned(FOnCommand) then
        FOnCommand(Cmd, Args);
    end;
    Exit(True);
  end;

  if Event.IsKey(keyBackspace) then
  begin
    if Length(FInputText) > 0 then
      Delete(FInputText, Length(FInputText), 1);
    Exit(True);
  end;

  if Event.IsKey(keyArrowUp) then
  begin
    if (FHistory.Count > 0) and (FHistoryIndex > 0) then
    begin
      Dec(FHistoryIndex);
      FInputText := FHistory[FHistoryIndex];
    end;
    Exit(True);
  end;

  if Event.IsKey(keyArrowDown) then
  begin
    if (FHistory.Count > 0) and (FHistoryIndex < FHistory.Count - 1) then
    begin
      Inc(FHistoryIndex);
      FInputText := FHistory[FHistoryIndex];
    end else
    begin
      FHistoryIndex := FHistory.Count;
      FInputText := '';
    end;
    Exit(True);
  end;

  if Event.KeyCharacter <> #0 then
  begin
    if (Event.KeyCharacter >= ' ') and (Event.KeyCharacter <> '`') and (Event.KeyCharacter <> '~') then
      FInputText := FInputText + Event.KeyCharacter;
    Exit(True);
  end;

  Result := True;
end;

procedure TQuakeConsole.SyncDesign;
var
  MaxDisplay, StartIdx, I: Integer;
  LineH: Single;
begin
  FPanel.Exists := FIsOpen;
  if not FIsOpen then
    Exit;
  LineH := FOutputLabel.Font.Height + FOutputLabel.LineSpacing;
  if LineH < 1 then
    LineH := 18;
  MaxDisplay := Max(1, Trunc((FPanel.EffectiveHeight - 50) / LineH));
  StartIdx := Max(0, FLines.Count - MaxDisplay);
  FOutputLabel.Text.Clear;
  for I := StartIdx to FLines.Count - 1 do
    FOutputLabel.Text.Add(FLines[I]);
  FPromptLabel.Caption := '] ' + FInputText + '_';
end;

procedure TQuakeConsole.Update(const SecondsPassed: Single; var HandleInput: Boolean);
begin
  inherited Update(SecondsPassed, HandleInput);
  SyncDesign;
end;

end.
