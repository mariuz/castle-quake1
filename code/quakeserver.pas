{ A deathmatch server: the level runs in TQuakeQcGame (progs.dat with
  deathmatch 1), every network client is one of its player edicts, and
  what happens is streamed to them as NetQuake protocol 15 messages over
  TQuakeNetServer. The signon (serverinfo, lightstyles, statics) goes
  reliably; each server frame sends the time, the client's data and every
  visible entity unreliably, with the sounds and effects of the frame.
  The host plays too, through a local client of its own. }
unit QuakeServer;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, Generics.Collections,
  CastleVectors, CastleLog,
  QuakeBsp, QuakePhysics, QuakeProgs, QuakeQcGame, QuakeNet;

type
  TQuakeServer = class
  private
    FGame: TQuakeQcGame;
    FNet: TQuakeNetServer;
    FMapName: String;
    FSkill: Integer;
    FEvents: array[1..MaxNetClients] of TQuakeNetMessage;    { unreliable, this frame }
    FReliable: array[1..MaxNetClients] of TQuakeNetMessage;
    FOut: TQuakeNetMessage;
    FLastFrags: array[1..MaxQcClients] of Integer;
    FModels, FSounds: TStringList;
    function ClientOfEdict(const E: Integer): Integer;
    function NetModelIndex(const Model: String): Integer;
    function NetSoundIndex(const Sample: String): Integer;
    procedure ForClients(const E: Integer; const Reliable: Boolean; out First, Last: Integer);
    procedure WriteEntities(const Msg: TQuakeNetMessage);
    procedure WriteClientData(const Msg: TQuakeNetMessage; const E: Integer);
    procedure SendFrames;
    procedure ChangeLevel(const Map: String);
    procedure BuildLists;
    { Net events }
    function HandleConnect(const C: Integer): Integer;
    procedure HandleDisconnect(const C: Integer);
    procedure HandleSignon(const C: Integer; const Msg: TQuakeNetMessage);
    { Game events }
    procedure HandleSound(const E, Channel: Integer; const Sample: String; const Volume, Attenuation: Single;
      const Origin: TVector3);
    procedure HandlePrint(const S: String);
    procedure HandleCenterPrint(const E: Integer; const S: String);
    procedure HandleStuffCmd(const E: Integer; const S: String);
    procedure HandleLightStyle(const Style: Integer; const Value: String);
    procedure HandleParticle(const Org, Dir: TVector3; const Color, Count: Integer);
    procedure HandleMessage(const E: Integer; const Data: TBytes);
  public
    { Coop: the single player rules with monsters, everyone on one side;
      otherwise deathmatch }
    constructor Create(const Port: Word; const AMapName: String; const AMaxClients: Integer;
      const ACoop: Boolean; const ASkill: Integer);
    destructor Destroy; override;
    function Valid: Boolean;
    { One server frame: the clients' input, the progs, the messages }
    procedure Update(const SecondsPassed: Single);
    property Game: TQuakeQcGame read FGame;
    property Net: TQuakeNetServer read FNet;
    property MapName: String read FMapName;
  end;

var
  { The listen server of this process, when hosting }
  ListenServer: TQuakeServer;

implementation

const
  svc_damage = 19;
  svc_temp_entity = 23;
  svc_particle = 18;
  STAT_TOTALSECRETS = 11;
  STAT_TOTALMONSTERS = 12;
  STAT_SECRETS = 13;
  STAT_MONSTERS = 14;
  MaxFrameBytes = 7000;

constructor TQuakeServer.Create(const Port: Word; const AMapName: String; const AMaxClients: Integer;
  const ACoop: Boolean; const ASkill: Integer);
var
  I: Integer;
begin
  inherited Create;
  FMapName := AMapName;
  FSkill := EnsureRange(ASkill, 0, 3);
  FModels := TStringList.Create;
  FSounds := TStringList.Create;
  FOut := TQuakeNetMessage.Create;
  for I := 1 to MaxNetClients do
  begin
    FEvents[I] := TQuakeNetMessage.Create;
    FReliable[I] := TQuakeNetMessage.Create;
  end;
  FGame := TQuakeQcGame.Create;
  FGame.MaxClients := EnsureRange(AMaxClients, 1, Min(MaxQcClients, MaxNetClients));
  if ACoop then
  begin
    FGame.Deathmatch := 0;
    FGame.Coop := 1;
  end else
  begin
    FGame.Deathmatch := 1;
    FGame.Coop := 0;
  end;
  FGame.OnSound := @HandleSound;
  FGame.OnPrint := @HandlePrint;
  FGame.OnCenterPrint := @HandleCenterPrint;
  FGame.OnStuffCmd := @HandleStuffCmd;
  FGame.OnLightStyle := @HandleLightStyle;
  FGame.OnParticle := @HandleParticle;
  FGame.OnMessage := @HandleMessage;
  FNet := TQuakeNetServer.Create(Port);
  FNet.OnConnect := @HandleConnect;
  FNet.OnDisconnect := @HandleDisconnect;
  FNet.OnSignon := @HandleSignon;
  if not FGame.LoadLevel(AMapName, FSkill, False) then
    WritelnWarning('QuakeServer', 'Cannot load the level "%s"', [AMapName]);
  BuildLists;
  if FNet.Valid then
    WritelnLog('QuakeServer', 'Hosting "%s" on port %d for %d players (%s, skill %d)',
      [AMapName, Port, FGame.MaxClients, BoolToStr(ACoop, 'coop', 'deathmatch'), FSkill]);
end;

destructor TQuakeServer.Destroy;
var
  I: Integer;
begin
  if FNet <> nil then
    FNet.Shutdown;
  FNet.Free;
  FGame.Free;
  for I := 1 to MaxNetClients do
  begin
    FEvents[I].Free;
    FReliable[I].Free;
  end;
  FOut.Free;
  FModels.Free;
  FSounds.Free;
  inherited Destroy;
end;

function TQuakeServer.Valid: Boolean;
begin
  Result := (FNet <> nil) and FNet.Valid and (FGame.Bsp <> nil);
end;

procedure TQuakeServer.BuildLists;
var
  I: Integer;
begin
  { The protocol's model 1 is the map; the progs' precache list follows,
    so a progs modelindex is one more on the wire }
  FModels.Clear;
  FModels.Add('maps/' + FMapName + '.bsp');
  for I := 0 to FGame.Progs.PrecachedModels.Count - 1 do
    FModels.Add(FGame.Progs.PrecachedModels[I]);
  FSounds.Clear;
  for I := 0 to FGame.Progs.PrecachedSounds.Count - 1 do
    FSounds.Add(FGame.Progs.PrecachedSounds[I]);
end;

function TQuakeServer.NetModelIndex(const Model: String): Integer;
begin
  if Model = '' then
    Exit(0);
  Result := FModels.IndexOf(Model) + 1;
end;

function TQuakeServer.NetSoundIndex(const Sample: String): Integer;
var
  S: String;
begin
  S := Sample;
  if Pos('sound/', S) = 1 then
    Delete(S, 1, 6);
  Result := FSounds.IndexOf(S) + 1;
end;

function TQuakeServer.ClientOfEdict(const E: Integer): Integer;
var
  C: Integer;
begin
  for C := 1 to MaxNetClients do
    if FNet.ClientActive(C) and (FNet.ClientEdict(C) = E) then
      Exit(C);
  Result := 0;
end;

procedure TQuakeServer.ForClients(const E: Integer; const Reliable: Boolean; out First, Last: Integer);
begin
  { The net clients a message for edict E (0: everyone) goes to }
  if E = 0 then
  begin
    First := 1;
    Last := MaxNetClients;
  end else
  begin
    First := ClientOfEdict(E);
    Last := First;
  end;
end;

{ Net events }

function TQuakeServer.HandleConnect(const C: Integer): Integer;
var
  E, O: Integer;
begin
  E := FGame.FreeClientSlot;
  if E = 0 then
    Exit(0);
  if not FGame.ConnectClient(E, 'player' + IntToStr(E)) then
    Exit(0);
  FEvents[C].Clear;
  FReliable[C].Clear;
  FLastFrags[E] := 0;
  { Everyone learns the name }
  for O := 1 to MaxNetClients do
    if FNet.ClientActive(O) then
      FReliable[O].UpdateName(E - 1, FGame.ClientName(E));
  Result := E;
end;

procedure TQuakeServer.HandleDisconnect(const C: Integer);
var
  E, O: Integer;
begin
  E := FNet.ClientEdict(C);
  if E > 0 then
  begin
    FGame.DisconnectClient(E);
    for O := 1 to MaxNetClients do
      if FNet.ClientActive(O) and (O <> C) then
      begin
        FReliable[O].UpdateName(E - 1, '');
        FReliable[O].UpdateFrags(E - 1, 0);
      end;
  end;
end;

procedure TQuakeServer.HandleSignon(const C: Integer; const Msg: TQuakeNetMessage);
var
  E, I: Integer;
  St: TQcStatic;
  World: TQuakeEntity;
  LevelName: String;
begin
  E := FNet.ClientEdict(C);
  LevelName := FMapName;
  World := FGame.Bsp.FindEntity('worldspawn');
  if World <> nil then
    LevelName := World.GetField('message', FMapName);
  Msg.ServerInfo(LevelName, FModels, FSounds, FGame.MaxClients);
  for I := 0 to 63 do
    if FGame.LightStyleValue(I) <> '' then
      Msg.LightStyle(I, FGame.LightStyleValue(I));
  for I := 0 to FGame.StaticCount - 1 do
  begin
    St := FGame.Static(I);
    Msg.SpawnStatic(NetModelIndex(St.Model), St.Frame, St.Skin, St.Origin, St.Angles);
  end;
  Msg.UpdateStat(STAT_TOTALSECRETS, FGame.TotalSecrets);
  Msg.UpdateStat(STAT_TOTALMONSTERS, FGame.TotalMonsters);
  Msg.UpdateStat(STAT_SECRETS, FGame.FoundSecrets);
  Msg.UpdateStat(STAT_MONSTERS, FGame.KilledMonsters);
  Msg.SetView(E);
  Msg.SignonNum(1);
  for I := 1 to FGame.MaxClients do
    if FGame.ClientActive(I) then
    begin
      Msg.UpdateName(I - 1, FGame.ClientName(I));
      Msg.UpdateFrags(I - 1, FGame.PlayerFrags(I));
    end;
  Msg.SignonNum(2);
  Msg.SetAngle(FGame.EntityAngles(E));
  Msg.SignonNum(3);
  { Anything queued before the signon is for the old level }
  FReliable[C].Clear;
  FEvents[C].Clear;
end;

{ Game events }

procedure TQuakeServer.HandleSound(const E, Channel: Integer; const Sample: String; const Volume, Attenuation: Single;
  const Origin: TVector3);
var
  C, Idx: Integer;
begin
  Idx := NetSoundIndex(Sample);
  if Idx = 0 then
    Exit;
  for C := 1 to MaxNetClients do
    if FNet.ClientReady(C) then
      FEvents[C].Sound(E, Channel, Idx, Volume, Attenuation, Origin);
end;

procedure TQuakeServer.HandlePrint(const S: String);
var
  C: Integer;
begin
  for C := 1 to MaxNetClients do
    if FNet.ClientActive(C) then
      FReliable[C].Print(S);
end;

procedure TQuakeServer.HandleCenterPrint(const E: Integer; const S: String);
var
  C, First, Last: Integer;
begin
  ForClients(E, True, First, Last);
  for C := First to Last do
    if (C > 0) and FNet.ClientActive(C) then
      FReliable[C].CenterPrint(S);
end;

procedure TQuakeServer.HandleStuffCmd(const E: Integer; const S: String);
var
  C, First, Last: Integer;
begin
  ForClients(E, True, First, Last);
  for C := First to Last do
    if (C > 0) and FNet.ClientActive(C) then
      FReliable[C].StuffText(S + #10);
end;

procedure TQuakeServer.HandleLightStyle(const Style: Integer; const Value: String);
var
  C: Integer;
begin
  for C := 1 to MaxNetClients do
    if FNet.ClientActive(C) then
      FReliable[C].LightStyle(Style, Value);
end;

procedure TQuakeServer.HandleParticle(const Org, Dir: TVector3; const Color, Count: Integer);
var
  C: Integer;
begin
  for C := 1 to MaxNetClients do
    if FNet.ClientReady(C) then
      FEvents[C].Particle(Org, Dir, Count, Color);
end;

procedure TQuakeServer.HandleMessage(const E: Integer; const Data: TBytes);
var
  C, First, Last: Integer;
  Raw: TNetBytes;
  Unreliable: Boolean;
begin
  { The svc messages the progs wrote, forwarded as they are: effects and
    damage with the frame, the rest (intermission, finale, setangle,
    secrets and kills) reliably }
  if Length(Data) = 0 then
    Exit;
  SetLength(Raw, Length(Data));
  Move(Data[0], Raw[0], Length(Data));
  Unreliable := (Data[0] = svc_temp_entity) or (Data[0] = svc_damage) or (Data[0] = svc_particle);
  ForClients(E, not Unreliable, First, Last);
  for C := First to Last do
    if (C > 0) and FNet.ClientActive(C) then
    begin
      if Unreliable then
      begin
        if FNet.ClientReady(C) then
          FEvents[C].Append(Raw);
      end else
        FReliable[C].Append(Raw);
    end;
end;

{ Frames }

procedure TQuakeServer.WriteClientData(const Msg: TQuakeNetMessage; const E: Integer);
begin
  Msg.ClientData(FGame.PlayerViewOfs(E).Z, FGame.PlayerVelocity(E), FGame.PlayerItems(E),
    FGame.PlayerWeaponFrame(E), FGame.PlayerArmor(E), NetModelIndex(FGame.PlayerWeaponModel(E)),
    FGame.PlayerHealth(E), FGame.PlayerAmmo(E, 0), FGame.PlayerAmmo(E, 1), FGame.PlayerAmmo(E, 2),
    FGame.PlayerAmmo(E, 3), FGame.PlayerAmmo(E, 4), Integer(FGame.PlayerWeapon(E)));
end;

procedure TQuakeServer.WriteEntities(const Msg: TQuakeNetMessage);
var
  E, Idx: Integer;
begin
  { SV_WriteEntitiesToClient: everything with a model, the players too }
  for E := 1 to FGame.Progs.NumEdicts - 1 do
  begin
    if Msg.Size > MaxFrameBytes then
      Break;
    if (E <= FGame.MaxClients) and not FGame.ClientActive(E) then
      Continue;
    if not FGame.EntityVisible(E) then
      Continue;
    Idx := NetModelIndex(FGame.EntityModel(E));
    if (Idx <= 0) or (Idx > 255) then
      Continue;
    Msg.Entity(E, Idx, FGame.EntityFrame(E) and 255, FGame.EntitySkin(E) and 255, FGame.EntityEffects(E) and 255,
      FGame.EntityOrigin(E), FGame.EntityAngles(E));
  end;
end;

procedure TQuakeServer.SendFrames;
var
  C, E, I, O: Integer;
  Chunks: specialize TList<TNetBytes>;
begin
  { Frags that changed }
  for E := 1 to FGame.MaxClients do
    if FGame.ClientActive(E) and (FGame.PlayerFrags(E) <> FLastFrags[E]) then
    begin
      FLastFrags[E] := FGame.PlayerFrags(E);
      for O := 1 to MaxNetClients do
        if FNet.ClientActive(O) then
          FReliable[O].UpdateFrags(E - 1, FLastFrags[E]);
    end;

  for C := 1 to MaxNetClients do
  begin
    if not FNet.ClientActive(C) then
    begin
      FEvents[C].Clear;
      FReliable[C].Clear;
      Continue;
    end;
    E := FNet.ClientEdict(C);
    if FNet.ClientReady(C) and FGame.ClientActive(E) then
    begin
      FOut.Clear;
      FOut.Time(FGame.Time);
      WriteClientData(FOut, E);
      WriteEntities(FOut);
      if FOut.Size + FEvents[C].Size < MaxPacketSize - 16 then
        FOut.Append(FEvents[C].Bytes);
      FNet.SendFrame(C, FOut.Bytes);
    end;
    FEvents[C].Clear;
    if FReliable[C].Size > 0 then
    begin
      Chunks := FReliable[C].Chunks(ReliableChunkSize);
      try
        for I := 0 to Chunks.Count - 1 do
          FNet.SendReliable(C, Chunks[I]);
      finally
        Chunks.Free;
      end;
      FReliable[C].Clear;
    end;
  end;
end;

procedure TQuakeServer.ChangeLevel(const Map: String);
var
  C: Integer;
begin
  WritelnLog('QuakeServer', 'Level change to "%s"', [Map]);
  FGame.LevelChange := '';
  if not FGame.LoadLevel(Map, FSkill, True) then
  begin
    WritelnWarning('QuakeServer', 'Cannot load "%s", staying on "%s"', [Map, FMapName]);
    FGame.LoadLevel(FMapName, FSkill, True);
  end else
    FMapName := Map;
  BuildLists;
  for C := 1 to MaxNetClients do
    if FNet.ClientActive(C) then
    begin
      FLastFrags[FNet.ClientEdict(C)] := FGame.PlayerFrags(FNet.ClientEdict(C));
      FNet.Resignon(C);
    end;
end;

procedure TQuakeServer.Update(const SecondsPassed: Single);
var
  C, E, I: Integer;
  Input: TNetInput;
  Cmd: TQuakeUserCmd;
begin
  if not Valid then
    Exit;
  FNet.Update(SecondsPassed);

  { The clients' inputs: each one moves its player for the time it lasted
    (the client predicted the same), a few per tick when they queued up }
  for C := 1 to MaxNetClients do
    if FNet.ClientReady(C) then
    begin
      E := FNet.ClientEdict(C);
      I := 0;
      while (I < 4) and FNet.ClientInput(C, Input) do
      begin
        Inc(I);
        Cmd := Default(TQuakeUserCmd);
        Cmd.ForwardMove := Input.Move.X;
        Cmd.SideMove := Input.Move.Y;
        Cmd.UpMove := Input.Move.Z;
        Cmd.Jump := (Input.Buttons and nbJump) <> 0;
        FGame.RunClientInput(E, Cmd, Input.Angles.Y, Input.Angles.X, (Input.Buttons and nbFire) <> 0,
          Input.Impulse, Min(Input.Msec, MaxInputMsec) / 1000);
      end;
    end;

  FGame.Frame(Min(SecondsPassed, 0.1));
  if FGame.LevelChange <> '' then
    ChangeLevel(FGame.LevelChange);
  SendFrames;
end;

end.
