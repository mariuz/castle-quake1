{ Deathmatch bots: fake clients of the listen server.

  A bot takes a client slot of the QuakeC game (ConnectClient, like a
  network player) and is driven by input made here each frame
  (RunClientInput), so the progs' own rules apply to it: weapons, items,
  frags, respawns. Network players see it like any other player.

  Navigation: when a level is loaded, the floors are flooded with the
  player hull from every deathmatch start and item, in 64 unit steps (a
  step may go up 18 units or drop down to 240), giving a graph of standing
  spots; a bot goes to the item it wants most (a weapon it lacks, health
  when hurt, armor, ammo for its weapons) along the shortest path
  (Dijkstra). It fights the nearest player it can see: it turns toward
  him with a reaction delay and an aiming error, strafes, keeps its
  distance, picks the weapon for the range and fires when its aim is
  close. A bot that does not get anywhere jumps and takes another goal.

  Coop: a bot fights the monsters it sees instead of the players, follows
  the nearest human player when it is more than FollowDistance away (else
  takes the items near him), and one left far behind for a while catches
  up: it is put at a spot near the player that he does not see. }
unit QuakeBots;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Classes, Math, StrUtils, Generics.Collections, CastleVectors,
  QuakeBsp, QuakePhysics, QuakeQcGame;

type
  TIntegerArray = array of Integer;

  TBotNode = record
    Pos: TVector3;              { standing origin, Quake coordinates }
    Links: array of Integer;
  end;

  TQuakeBot = record
    E: Integer;
    Name: String;
    Path: array of Integer;
    PathPos: Integer;
    GoalEdict: Integer;
    GoalName: String;
    Repath: Single;
    Yaw, Pitch: Single;
    StrafeDir: Integer;
    StrafeTime: Single;
    LastPos: TVector3;
    StuckTime, ProgressTime: Single;
    JumpTime: Single;
    RespawnToggle: Boolean;
    RespawnTime: Single;
    WeaponTime: Single;
    Enemy: Integer;
    SeenTime: Single;
    AimError: TVector2;
    AimErrorTime: Single;
    Travelled: Single;
    { Goals that could not be reached, and until when they are left alone }
    Avoid: array of Integer;
    AvoidUntil: array of Single;
    { Coop: the player it follows (0: none) and how long it has been far
      behind him }
    Leader: Integer;
    FarTime: Single;
    { When the next fight may be logged }
    FightLogTime: Single;
  end;

  TQuakeBots = class
  private
    FGame: TQuakeQcGame;
    FNodes: array of TBotNode;
    FNavMap: String;
    FBots: array of TQuakeBot;
    FLogTime: Single;
    FClock: Single;
    procedure BuildNavigation;
    function Avoided(const B: TQuakeBot; const E: Integer): Boolean;
    procedure AvoidGoal(var B: TQuakeBot);
    function NearestNode(const P: TVector3): Integer;
    function FindPath(const FromNode, ToNode: Integer; out Path: TIntegerArray): Boolean;
    function Visible(const A, B: TVector3): Boolean;
    procedure ChooseGoal(var B: TQuakeBot);
    procedure UpdateBot(var B: TQuakeBot; const Dt: Single);
    function BestWeaponImpulse(const E: Integer; const Dist: Single): Integer;
    function IsBot(const E: Integer): Boolean;
    { Coop: the nearest human player alive (0: none) }
    function NearestHuman(const Org: TVector3): Integer;
    { Coop: put the bot near its leader, where he does not see it }
    procedure CatchUp(var B: TQuakeBot);
  public
    { Skill 0..3: reaction time and aiming error }
    Skill: Integer;
    constructor Create(const AGame: TQuakeQcGame);
    { Add a bot; its edict, 0 when no client slot is free }
    function Add: Integer;
    { Forget the bot of edict E (the server disconnects its client); False
      when E is no bot }
    function Remove(const E: Integer): Boolean;
    function Count: Integer;
    { Teamplay: put each bot in the team (pants color) with the fewest
      players, the humans' teams first (red and blue when they have fewer
      than two); the bots whose colors changed }
    function BalanceTeams: TIntegerArray;
    function BotEdict(const I: Integer): Integer;
    { Before each game frame: every bot's input }
    procedure Update(const SecondsPassed: Single);
    function NodeCount: Integer;
  end;

implementation

uses
  CastleLog, QuakeDemo;

const
  BotNames: array[0..7] of String = ('Wolf', 'Raven', 'Viper', 'Hawk', 'Cobra', 'Lynx', 'Puma', 'Fox');
  { Shirt * 16 + pants of each bot: red, blue, green, yellow, purple... }
  BotColors: array[0..7] of Integer = ($44, $DD, $33, $CC, $88, $29, $6B, $97);
  NavStep = 64;
  NavMaxNodes = 8000;
  NavMaxDrop = 240;
  MoveSpeed = 320;
  { Coop: a bot farther than this from its leader goes to him }
  FollowDistance = 350;
  { ... and one this far for this long catches up }
  CatchUpDistance = 1500;
  CatchUpTime = 8.0;

function HorizontalDistance(const A, B: TVector3): Single;
begin
  Result := Sqrt(Sqr(A.X - B.X) + Sqr(A.Y - B.Y));
end;

function AngleDelta(const A, B: Single): Single;
begin
  Result := B - A;
  while Result > 180 do
    Result := Result - 360;
  while Result < -180 do
    Result := Result + 360;
end;

constructor TQuakeBots.Create(const AGame: TQuakeQcGame);
begin
  inherited Create;
  FGame := AGame;
  Skill := 1;
end;

function TQuakeBots.Count: Integer;
begin
  Result := Length(FBots);
end;

function TQuakeBots.Remove(const E: Integer): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FBots) do
    if FBots[I].E = E then
    begin
      WritelnLog('Bots', 'Bot "%s" left', [FBots[I].Name]);
      Delete(FBots, I, 1);
      Exit(True);
    end;
  Result := False;
end;

function TQuakeBots.BalanceTeams: TIntegerArray;
const
  SpareTeams: array[0..3] of Integer = (4, 13, 12, 3);
var
  Teams, Sizes: array of Integer;
  I, J, O, Best, Old, Pants: Integer;

  function TeamIndex(const P: Integer): Integer;
  var
    K: Integer;
  begin
    for K := 0 to High(Teams) do
      if Teams[K] = P then
        Exit(K);
    Result := -1;
  end;

begin
  Result := nil;
  if (FGame.TeamPlay <= 0) or (Length(FBots) = 0) then
    Exit;
  Teams := nil;
  Sizes := nil;
  { The humans' teams and their sizes }
  for O := 1 to FGame.MaxClients do
    if FGame.ClientActive(O) and not IsBot(O) then
    begin
      Pants := FGame.ClientColors(O) and 15;
      J := TeamIndex(Pants);
      if J < 0 then
      begin
        SetLength(Teams, Length(Teams) + 1);
        SetLength(Sizes, Length(Sizes) + 1);
        J := High(Teams);
        Teams[J] := Pants;
        Sizes[J] := 0;
      end;
      Inc(Sizes[J]);
    end;
  I := 0;
  while (Length(Teams) < 2) and (I <= High(SpareTeams)) do
  begin
    if TeamIndex(SpareTeams[I]) < 0 then
    begin
      SetLength(Teams, Length(Teams) + 1);
      SetLength(Sizes, Length(Sizes) + 1);
      Teams[High(Teams)] := SpareTeams[I];
      Sizes[High(Sizes)] := 0;
    end;
    Inc(I);
  end;
  { Each bot in turn to the smallest team }
  for I := 0 to High(FBots) do
  begin
    Best := 0;
    for J := 1 to High(Teams) do
      if Sizes[J] < Sizes[Best] then
        Best := J;
    Inc(Sizes[Best]);
    Old := FGame.ClientColors(FBots[I].E);
    if (Old and 15) <> Teams[Best] then
    begin
      FGame.SetClientColors(FBots[I].E, (Old and $F0) or Teams[Best]);
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := FBots[I].E;
      WritelnLog('Bots', 'Bot "%s" joins team %d', [FBots[I].Name, Teams[Best]]);
    end;
  end;
end;

function TQuakeBots.BotEdict(const I: Integer): Integer;
begin
  Result := FBots[I].E;
end;

function TQuakeBots.NodeCount: Integer;
begin
  Result := Length(FNodes);
end;

function TQuakeBots.Add: Integer;
var
  B: TQuakeBot;
begin
  Result := FGame.FreeClientSlot;
  if Result = 0 then
    Exit;
  B := Default(TQuakeBot);
  B.E := Result;
  B.Name := BotNames[Length(FBots) mod Length(BotNames)];
  if not FGame.ConnectClient(B.E, B.Name, BotColors[Length(FBots) mod Length(BotColors)]) then
    Exit(0);
  B.Enemy := 0;
  B.StrafeDir := 1;
  B.LastPos := FGame.EntityOrigin(B.E);
  SetLength(FBots, Length(FBots) + 1);
  FBots[High(FBots)] := B;
  WritelnLog('Bots', 'Bot "%s" joined as client %d', [B.Name, B.E]);
end;

function TQuakeBots.Visible(const A, B: TVector3): Boolean;
var
  T: TQuakeTrace;
begin
  T := FGame.Bsp.TraceHull(0, 0, TVector3.Zero, A, B);
  Result := (T.Fraction >= 1) and not T.StartSolid;
end;

{ The standing spots: a flood of the player hull over the floors }
procedure TQuakeBots.BuildNavigation;
const
  DX: array[0..7] of Single = (1, -1, 0, 0, 0.7071, 0.7071, -0.7071, -0.7071);
  DY: array[0..7] of Single = (0, 0, 1, -1, 0.7071, -0.7071, 0.7071, -0.7071);
var
  Bsp: TQuakeBsp;
  Cells: specialize TDictionary<Int64, Integer>;
  Head, D, Found, Links, Contents: Integer;
  P, Up, Moved, Down, S: TVector3;
  T: TQuakeTrace;
  Start: QWord;
  Ent: TQuakeEntity;
  CName: String;

  { Spots closer than a cell are the same spot }
  function Key(const V: TVector3): Int64;
  begin
    Result := (Int64(Floor(V.X / 32) + 100000) shl 40) or (Int64(Floor(V.Y / 32) + 100000) shl 20) or
      Int64(Floor(V.Z / 24) + 100000);
  end;

  function AddNode(const V: TVector3): Integer;
  begin
    if Cells.TryGetValue(Key(V), Result) then
      Exit;
    Result := -1;
    if Length(FNodes) >= NavMaxNodes then
      Exit;
    SetLength(FNodes, Length(FNodes) + 1);
    FNodes[High(FNodes)].Pos := V;
    Result := High(FNodes);
    Cells.Add(Key(V), Result);
  end;

  procedure AddLink(const A, B: Integer);
  var
    K: Integer;
  begin
    for K := 0 to High(FNodes[A].Links) do
      if FNodes[A].Links[K] = B then
        Exit;
    SetLength(FNodes[A].Links, Length(FNodes[A].Links) + 1);
    FNodes[A].Links[High(FNodes[A].Links)] := B;
    Inc(Links);
  end;

  function Settle(const V: TVector3; out Stand: TVector3): Boolean;
  var
    ST: TQuakeTrace;
  begin
    ST := Bsp.TraceHull(1, 0, TVector3.Zero, V + Vector3(0, 0, 8), V - Vector3(0, 0, 128));
    Result := not ST.StartSolid and not ST.AllSolid and (ST.Fraction < 1);
    Stand := ST.EndPos;
  end;

begin
  Start := GetTickCount64;
  FNodes := nil;
  Links := 0;
  Bsp := FGame.Bsp;
  FNavMap := FGame.MapName;
  if Bsp = nil then
    Exit;
  Cells := specialize TDictionary<Int64, Integer>.Create;
  try
    for Ent in Bsp.Entities do
    begin
      CName := LowerCase(Ent.ClassName);
      if ((CName = 'info_player_deathmatch') or (CName = 'info_player_start') or (CName = 'info_player_coop') or
         (Pos('item_', CName) = 1) or (Pos('weapon_', CName) = 1)) and
         Settle(Ent.Origin + Vector3(0, 0, 24), S) then
        AddNode(S);
    end;

    Head := 0;
    while Head < Length(FNodes) do
    begin
      P := FNodes[Head].Pos;
      for D := 0 to 7 do
      begin
        T := Bsp.TraceHull(1, 0, TVector3.Zero, P, P + Vector3(0, 0, 18));
        Up := T.EndPos;
        T := Bsp.TraceHull(1, 0, TVector3.Zero, Up, Up + Vector3(DX[D], DY[D], 0) * NavStep);
        if T.Fraction < 1 then
          Continue;
        Moved := T.EndPos;
        T := Bsp.TraceHull(1, 0, TVector3.Zero, Moved, Moved - Vector3(0, 0, NavMaxDrop + 18));
        if T.StartSolid or (T.Fraction >= 1) or (T.PlaneNormal.Z < 0.7) then
          Continue;
        Down := T.EndPos;
        Contents := Bsp.PointContents(Down);
        if (Contents = CONTENTS_LAVA) or (Contents = CONTENTS_SLIME) or (Contents = CONTENTS_SOLID) then
          Continue;
        Found := AddNode(Down);
        if (Found >= 0) and (Found <> Head) then
          AddLink(Head, Found);
      end;
      Inc(Head);
    end;
  finally
    Cells.Free;
  end;
  WritelnLog('Bots', 'Navigation of "%s": %d spots, %d links in %d ms',
    [FNavMap, Length(FNodes), Links, GetTickCount64 - Start]);
end;

function TQuakeBots.NearestNode(const P: TVector3): Integer;
var
  I: Integer;
  D, Best: Single;
begin
  Result := -1;
  Best := 1e30;
  for I := 0 to High(FNodes) do
  begin
    D := Sqr(FNodes[I].Pos.X - P.X) + Sqr(FNodes[I].Pos.Y - P.Y) + Sqr((FNodes[I].Pos.Z - P.Z) * 2);
    if D < Best then
    begin
      Best := D;
      Result := I;
    end;
  end;
end;

{ Dijkstra with a binary heap over the spots }
function TQuakeBots.FindPath(const FromNode, ToNode: Integer; out Path: TIntegerArray): Boolean;
var
  Dist: array of Single;
  Prev: array of Integer;
  Done: array of Boolean;
  Heap: array of Integer;
  HeapCount, N, I, L, C, Tmp: Integer;
  ND: Single;

  procedure Push(const Node: Integer);
  var
    K, Parent, T: Integer;
  begin
    if HeapCount = Length(Heap) then
      SetLength(Heap, Max(64, 2 * HeapCount));
    Heap[HeapCount] := Node;
    K := HeapCount;
    Inc(HeapCount);
    while K > 0 do
    begin
      Parent := (K - 1) div 2;
      if Dist[Heap[Parent]] <= Dist[Heap[K]] then
        Break;
      T := Heap[Parent];
      Heap[Parent] := Heap[K];
      Heap[K] := T;
      K := Parent;
    end;
  end;

  function Pop: Integer;
  var
    K, Child, T: Integer;
  begin
    Result := Heap[0];
    Dec(HeapCount);
    Heap[0] := Heap[HeapCount];
    K := 0;
    while True do
    begin
      Child := 2 * K + 1;
      if Child >= HeapCount then
        Break;
      if (Child + 1 < HeapCount) and (Dist[Heap[Child + 1]] < Dist[Heap[Child]]) then
        Inc(Child);
      if Dist[Heap[K]] <= Dist[Heap[Child]] then
        Break;
      T := Heap[K];
      Heap[K] := Heap[Child];
      Heap[Child] := T;
      K := Child;
    end;
  end;

begin
  Path := nil;
  Result := False;
  N := Length(FNodes);
  if (FromNode < 0) or (ToNode < 0) or (FromNode >= N) or (ToNode >= N) then
    Exit;
  SetLength(Dist, N);
  SetLength(Prev, N);
  SetLength(Done, N);
  for I := 0 to N - 1 do
  begin
    Dist[I] := 1e30;
    Prev[I] := -1;
  end;
  HeapCount := 0;
  Dist[FromNode] := 0;
  Push(FromNode);
  while HeapCount > 0 do
  begin
    C := Pop;
    if Done[C] then
      Continue;
    Done[C] := True;
    if C = ToNode then
      Break;
    for L := 0 to High(FNodes[C].Links) do
    begin
      I := FNodes[C].Links[L];
      ND := Dist[C] + (FNodes[I].Pos - FNodes[C].Pos).Length;
      if ND < Dist[I] then
      begin
        Dist[I] := ND;
        Prev[I] := C;
        Push(I);
      end;
    end;
  end;
  if not Done[ToNode] then
    Exit;
  C := ToNode;
  while C >= 0 do
  begin
    SetLength(Path, Length(Path) + 1);
    Path[High(Path)] := C;
    C := Prev[C];
  end;
  { From the start }
  for I := 0 to (Length(Path) div 2) - 1 do
  begin
    Tmp := Path[I];
    Path[I] := Path[High(Path) - I];
    Path[High(Path) - I] := Tmp;
  end;
  Result := True;
end;

function TQuakeBots.Avoided(const B: TQuakeBot; const E: Integer): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(B.Avoid) do
    if (B.Avoid[I] = E) and (B.AvoidUntil[I] > FClock) then
      Exit(True);
  Result := False;
end;

{ The goal could not be reached: leave it alone for a while }
procedure TQuakeBots.AvoidGoal(var B: TQuakeBot);
begin
  if B.GoalEdict <= 0 then
    Exit;
  SetLength(B.Avoid, Length(B.Avoid) + 1);
  SetLength(B.AvoidUntil, Length(B.AvoidUntil) + 1);
  B.Avoid[High(B.Avoid)] := B.GoalEdict;
  B.AvoidUntil[High(B.AvoidUntil)] := FClock + 30;
  B.GoalEdict := 0;
end;

function TQuakeBots.IsBot(const E: Integer): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FBots) do
    if FBots[I].E = E then
      Exit(True);
  Result := False;
end;

function TQuakeBots.NearestHuman(const Org: TVector3): Integer;
var
  O: Integer;
  D, BestD: Single;
begin
  Result := 0;
  BestD := MaxSingle;
  for O := 1 to FGame.MaxClients do
    if FGame.ClientActive(O) and not IsBot(O) and not FGame.PlayerDead(O) then
    begin
      D := (FGame.EntityOrigin(O) - Org).Length;
      if D < BestD then
      begin
        BestD := D;
        Result := O;
      end;
    end;
end;

procedure TQuakeBots.CatchUp(var B: TQuakeBot);
var
  I, Best: Integer;
  LeaderOrg, LeaderEye: TVector3;
  D, BestD: Single;
begin
  if (B.Leader <= 0) or (Length(FNodes) = 0) then
    Exit;
  LeaderOrg := FGame.EntityOrigin(B.Leader);
  LeaderEye := LeaderOrg + Vector3(0, 0, 22);
  { The nearest spot 96 to 600 units from him that he does not see, else the nearest }
  Best := -1;
  BestD := MaxSingle;
  for I := 0 to High(FNodes) do
  begin
    D := (FNodes[I].Pos - LeaderOrg).Length;
    if (D >= 96) and (D < 600) and (D < BestD) and not Visible(LeaderEye, FNodes[I].Pos + Vector3(0, 0, 16)) then
    begin
      BestD := D;
      Best := I;
    end;
  end;
  if Best < 0 then
    Best := NearestNode(LeaderOrg);
  if Best < 0 then
    Exit;
  FGame.TeleportEntity(B.E, FNodes[Best].Pos);
  WritelnLog('Bots', 'Bot "%s" catches up with %s (%.0f units from him)',
    [B.Name, FGame.ClientName(B.Leader), (FNodes[Best].Pos - LeaderOrg).Length]);
  B.FarTime := 0;
  B.Path := nil;
  B.Repath := 0;
  B.LastPos := FNodes[Best].Pos;
end;

{ What the bot wants most: a weapon it lacks, health when hurt, armor,
  ammo for its weapons, by worth over distance; else somewhere at random.
  Coop: its leader when it is far from him, else the items near him }
procedure TQuakeBots.ChooseGoal(var B: TQuakeBot);
var
  E, Best, FromNode, ToNode, Tries: Integer;
  CName: String;
  Worth, Score, BestScore, Dist: Single;
  Org, P, LeaderOrg: TVector3;
  Items, Health: Cardinal;
  Path: TIntegerArray;
begin
  B.Repath := 4 + Random * 2;
  B.GoalEdict := 0;
  B.GoalName := '';
  Org := FGame.EntityOrigin(B.E);
  if FGame.Coop <> 0 then
  begin
    B.Leader := NearestHuman(Org);
    if B.Leader > 0 then
    begin
      LeaderOrg := FGame.EntityOrigin(B.Leader);
      if (LeaderOrg - Org).Length > FollowDistance then
      begin
        { He moves: look again soon }
        B.Repath := 1.5;
        B.GoalName := 'follow ' + FGame.ClientName(B.Leader);
        B.Path := nil;
        B.PathPos := 0;
        if FindPath(NearestNode(Org), NearestNode(LeaderOrg), Path) then
          B.Path := Path;
        Exit;
      end;
    end;
  end else
    B.Leader := 0;
  Items := FGame.PlayerItems(B.E);
  Health := Max(0, FGame.PlayerHealth(B.E));
  Best := 0;
  BestScore := 0;
  for E := FGame.MaxClients + 1 to FGame.EdictCount - 1 do
  begin
    CName := FGame.EntityClassName(E);
    if ((Pos('item_', CName) <> 1) and (Pos('weapon_', CName) <> 1)) or not FGame.EntityVisible(E) or
       Avoided(B, E) then
      Continue;
    Worth := 0;
    if CName = 'weapon_supershotgun' then
      Worth := IfThen((Items and IT_SUPER_SHOTGUN) = 0, 60, 8)
    else if CName = 'weapon_nailgun' then
      Worth := IfThen((Items and IT_NAILGUN) = 0, 60, 8)
    else if CName = 'weapon_supernailgun' then
      Worth := IfThen((Items and IT_SUPER_NAILGUN) = 0, 80, 8)
    else if CName = 'weapon_grenadelauncher' then
      Worth := IfThen((Items and IT_GRENADE_LAUNCHER) = 0, 70, 8)
    else if CName = 'weapon_rocketlauncher' then
      Worth := IfThen((Items and IT_ROCKET_LAUNCHER) = 0, 100, 10)
    else if CName = 'weapon_lightning' then
      Worth := IfThen((Items and IT_LIGHTNING) = 0, 90, 10)
    else if CName = 'item_health' then
      Worth := IfThen(Health < 100, (100 - Health) * 0.8, 0)
    else if Pos('item_armor', CName) = 1 then
      Worth := IfThen(FGame.PlayerArmor(B.E) < 100, 40, 5)
    else if (CName = 'item_shells') or (CName = 'item_spikes') or (CName = 'item_rockets') or
            (CName = 'item_cells') then
      Worth := 12
    else if Pos('item_artifact', CName) = 1 then
      Worth := 70;
    if Worth <= 0 then
      Continue;
    { Coop: only what is near the leader, he leads }
    if (B.Leader > 0) and ((FGame.EntityOrigin(E) - FGame.EntityOrigin(B.Leader)).Length > FollowDistance * 2) then
      Continue;
    Dist := (FGame.EntityOrigin(E) - Org).Length;
    Score := Worth / (200 + Dist);
    if Score > BestScore then
    begin
      BestScore := Score;
      Best := E;
    end;
  end;
  FromNode := NearestNode(Org);
  B.Path := nil;
  B.PathPos := 0;
  if Best > 0 then
  begin
    P := FGame.EntityOrigin(Best);
    { Items have their origin at a corner of their box }
    ToNode := NearestNode(P + Vector3(16, 16, 24));
    B.GoalEdict := Best;
    B.GoalName := FGame.EntityClassName(Best);
    if FindPath(FromNode, ToNode, Path) then
    begin
      B.Path := Path;
      Exit;
    end;
    AvoidGoal(B);
  end;
  { Coop: near the leader with nothing to take, wait there }
  if B.Leader > 0 then
  begin
    B.GoalName := 'stay near ' + FGame.ClientName(B.Leader);
    B.Repath := 1;
    Exit;
  end;
  { Somewhere at random that can be reached }
  B.GoalName := 'roam';
  for Tries := 1 to 8 do
    if FindPath(FromNode, Random(Max(1, Length(FNodes))), Path) and (Length(Path) > 3) then
    begin
      B.Path := Path;
      Break;
    end;
end;

function TQuakeBots.BestWeaponImpulse(const E: Integer; const Dist: Single): Integer;
var
  Items: Cardinal;
begin
  Items := FGame.PlayerItems(E);
  if ((Items and IT_LIGHTNING) <> 0) and (FGame.PlayerAmmo(E, 4) > 0) and (Dist < 600) then
    Exit(8);
  if ((Items and IT_ROCKET_LAUNCHER) <> 0) and (FGame.PlayerAmmo(E, 3) > 0) and (Dist > 160) then
    Exit(7);
  if ((Items and IT_SUPER_NAILGUN) <> 0) and (FGame.PlayerAmmo(E, 2) > 1) then
    Exit(5);
  if ((Items and IT_GRENADE_LAUNCHER) <> 0) and (FGame.PlayerAmmo(E, 3) > 0) and (Dist > 200) and (Dist < 600) then
    Exit(6);
  if ((Items and IT_SUPER_SHOTGUN) <> 0) and (FGame.PlayerAmmo(E, 1) > 1) and (Dist < 600) then
    Exit(3);
  if ((Items and IT_NAILGUN) <> 0) and (FGame.PlayerAmmo(E, 2) > 0) then
    Exit(4);
  if FGame.PlayerAmmo(E, 1) > 0 then
    Exit(2);
  Result := 1;
end;

procedure TQuakeBots.UpdateBot(var B: TQuakeBot; const Dt: Single);
var
  Org, Eye, Target, EnemyPos, Dir, Fwd, Right: TVector3;
  Cmd: TQuakeUserCmd;
  Fire: Boolean;
  Impulse, O, BestEnemy: Integer;
  D, BestD, WantYaw, WantPitch, TurnRate, Moved, AimOff: Single;
  WorldMove: TVector2;
  SY, CY: Single;
begin
  Cmd := Default(TQuakeUserCmd);
  Fire := False;
  Impulse := 0;

  { Dead: press and release fire to respawn }
  if FGame.PlayerDead(B.E) then
  begin
    B.RespawnTime := B.RespawnTime - Dt;
    if B.RespawnTime <= 0 then
    begin
      B.RespawnToggle := not B.RespawnToggle;
      B.RespawnTime := 0.3;
    end;
    B.Path := nil;
    B.Repath := 0;
    B.Enemy := 0;
    FGame.RunClientInput(B.E, Cmd, B.Yaw, 0, B.RespawnToggle, 0, Dt);
    B.LastPos := FGame.EntityOrigin(B.E);
    Exit;
  end;

  Org := FGame.EntityOrigin(B.E);
  Eye := Org + Vector3(0, 0, 22);
  Moved := HorizontalDistance(Org, B.LastPos);
  B.Travelled := B.Travelled + Moved;

  { The nearest player in sight (coop: the nearest monster) }
  BestEnemy := 0;
  BestD := 2500;
  if FGame.Coop <> 0 then
  begin
    BestD := 1500;
    for O := FGame.MaxClients + 1 to FGame.EdictCount - 1 do
      if FGame.EntityIsLiveMonster(O) then
      begin
        EnemyPos := FGame.EntityOrigin(O) + Vector3(0, 0, 8);
        D := (EnemyPos - Eye).Length;
        if (D < BestD) and Visible(Eye, EnemyPos) then
        begin
          BestD := D;
          BestEnemy := O;
        end;
      end;
  end else
  for O := 1 to FGame.MaxClients do
    if (O <> B.E) and FGame.ClientActive(O) and not FGame.PlayerDead(O) and
       ((FGame.TeamPlay <= 0) or (FGame.ClientTeam(O) <> FGame.ClientTeam(B.E))) then
    begin
      EnemyPos := FGame.EntityOrigin(O) + Vector3(0, 0, 16);
      D := (EnemyPos - Eye).Length;
      if (D < BestD) and Visible(Eye, EnemyPos) then
      begin
        BestD := D;
        BestEnemy := O;
      end;
    end;
  { Coop: left far behind its leader for a while, it catches up }
  if (FGame.Coop <> 0) and (B.Leader > 0) and FGame.ClientActive(B.Leader) then
  begin
    if (FGame.EntityOrigin(B.Leader) - Org).Length > CatchUpDistance then
      B.FarTime := B.FarTime + Dt
    else
      B.FarTime := 0;
    if B.FarTime > CatchUpTime then
    begin
      CatchUp(B);
      Org := FGame.EntityOrigin(B.E);
      Eye := Org + Vector3(0, 0, 22);
    end;
  end;
  if BestEnemy <> B.Enemy then
  begin
    { A new fight (at most one line every 5 s per bot): a monster in coop,
      a player in deathmatch }
    if (B.Enemy = 0) and (BestEnemy > 0) and (FClock >= B.FightLogTime) then
    begin
      B.FightLogTime := FClock + 5;
      if FGame.Coop <> 0 then
        WritelnLog('Bots', 'Bot "%s" fights %s (%.0f units)', [B.Name, FGame.EntityClassName(BestEnemy), BestD])
      else
        WritelnLog('Bots', 'Bot "%s" fights %s (%.0f units)', [B.Name, FGame.ClientName(BestEnemy), BestD]);
    end;
    B.Enemy := BestEnemy;
    B.SeenTime := 0;
  end;
  B.SeenTime := B.SeenTime + Dt;

  { Where to go: the path to the goal }
  B.Repath := B.Repath - Dt;
  if (B.Repath <= 0) or (B.PathPos > High(B.Path)) or
     ((B.GoalEdict > 0) and not FGame.EntityVisible(B.GoalEdict)) then
    ChooseGoal(B);
  Target := Org;
  while B.PathPos <= High(B.Path) do
  begin
    Target := FNodes[B.Path[B.PathPos]].Pos;
    if (HorizontalDistance(Target, Org) < 40) and (Abs(Target.Z - Org.Z) < 40) then
      Inc(B.PathPos)
    else
      Break;
  end;
  if B.PathPos > High(B.Path) then
  begin
    if B.GoalEdict > 0 then
      Target := FGame.EntityOrigin(B.GoalEdict) + Vector3(16, 16, 24)
    else
    if (B.Leader > 0) and FGame.ClientActive(B.Leader) and
       ((FGame.EntityOrigin(B.Leader) - Org).Length > FollowDistance * 0.6) then
      Target := FGame.EntityOrigin(B.Leader)
    else
      Target := Org;
  end;
  Dir := Target - Org;
  Dir.Z := 0;
  if Dir.Length > 8 then
    WorldMove := Vector2(Dir.X, Dir.Y).Normalize
  else
    WorldMove := TVector2.Zero;

  { Stuck: jump, strafe the other way, another goal }
  if (WorldMove.Length > 0) and (Moved < 60 * Dt) then
    B.StuckTime := B.StuckTime + Dt
  else
    B.StuckTime := Max(0, B.StuckTime - Dt);
  B.JumpTime := Max(0, B.JumpTime - Dt);
  if B.StuckTime > 0.6 then
  begin
    B.JumpTime := 0.2;
    B.StrafeDir := -B.StrafeDir;
    B.StrafeTime := 0.5;
    if B.StuckTime > 2 then
    begin
      B.StuckTime := 0;
      AvoidGoal(B);
      B.Repath := 0;
    end;
  end;

  { Aim: at the enemy (after a reaction time, with an error that drifts),
    else along the way }
  if B.Enemy > 0 then
  begin
    EnemyPos := FGame.EntityOrigin(B.Enemy) + Vector3(0, 0, 10);
    B.AimErrorTime := B.AimErrorTime - Dt;
    if B.AimErrorTime <= 0 then
    begin
      B.AimErrorTime := 0.4;
      AimOff := (4 - Skill) * 2.5;
      B.AimError := Vector2((Random - 0.5) * AimOff, (Random - 0.5) * AimOff * 0.6);
    end;
    Dir := EnemyPos - Eye;
    WantYaw := RadToDeg(ArcTan2(Dir.Y, Dir.X)) + B.AimError.X;
    WantPitch := -RadToDeg(ArcTan2(Dir.Z, Sqrt(Sqr(Dir.X) + Sqr(Dir.Y)))) + B.AimError.Y;
    TurnRate := 360 + 180 * Skill;
  end else
  begin
    if WorldMove.Length > 0 then
      WantYaw := RadToDeg(ArcTan2(WorldMove.Y, WorldMove.X))
    else
      WantYaw := B.Yaw;
    WantPitch := 0;
    TurnRate := 300;
  end;
  D := AngleDelta(B.Yaw, WantYaw);
  B.Yaw := B.Yaw + EnsureRange(D, -TurnRate * Dt, TurnRate * Dt);
  B.Pitch := B.Pitch + EnsureRange(WantPitch - B.Pitch, -TurnRate * Dt, TurnRate * Dt);
  if B.Yaw > 180 then
    B.Yaw := B.Yaw - 360
  else if B.Yaw < -180 then
    B.Yaw := B.Yaw + 360;

  { Fight: the weapon for the range, fire when aimed, strafe and keep the
    distance }
  if B.Enemy > 0 then
  begin
    B.WeaponTime := B.WeaponTime - Dt;
    if B.WeaponTime <= 0 then
    begin
      B.WeaponTime := 1.5;
      Impulse := BestWeaponImpulse(B.E, BestD);
    end;
    Fire := (B.SeenTime > 0.5 - 0.1 * Skill) and (Abs(AngleDelta(B.Yaw, WantYaw - B.AimError.X)) < 10);
    B.StrafeTime := B.StrafeTime - Dt;
    if B.StrafeTime <= 0 then
    begin
      B.StrafeTime := 0.6 + Random * 0.8;
      if Random < 0.5 then
        B.StrafeDir := -B.StrafeDir;
    end;
    Dir := FGame.EntityOrigin(B.Enemy) - Org;
    Dir.Z := 0;
    if Dir.Length > 1 then
    begin
      Dir := Dir.Normalize;
      { Close in from far, back off when too near, keep going for an item }
      if BestD > 500 then
        WorldMove := (WorldMove + Vector2(Dir.X, Dir.Y)) * 0.5
      else if BestD < 180 then
        WorldMove := Vector2(-Dir.X, -Dir.Y);
      WorldMove := WorldMove + Vector2(-Dir.Y, Dir.X) * (0.8 * B.StrafeDir);
    end;
  end;

  { The wished move turned into forward / side for the view's yaw }
  SinCos(DegToRad(B.Yaw), SY, CY);
  Fwd := Vector3(CY, SY, 0);
  Right := Vector3(SY, -CY, 0);
  if WorldMove.Length > 1 then
    WorldMove := WorldMove.Normalize;
  Cmd.ForwardMove := MoveSpeed * (WorldMove.X * Fwd.X + WorldMove.Y * Fwd.Y);
  Cmd.SideMove := MoveSpeed * (WorldMove.X * Right.X + WorldMove.Y * Right.Y);
  Cmd.Jump := B.JumpTime > 0;
  { Swim up out of water }
  if FGame.PlayerWaterLevel(B.E) >= 2 then
    Cmd.UpMove := MoveSpeed;

  FGame.RunClientInput(B.E, Cmd, B.Yaw, B.Pitch, Fire, Impulse, Dt);
  B.LastPos := Org;
end;

procedure TQuakeBots.Update(const SecondsPassed: Single);
var
  I: Integer;
  Dt: Single;
  S, Lead: String;
begin
  if (Length(FBots) = 0) or (FGame.Bsp = nil) or FGame.Intermission then
    Exit;
  if FNavMap <> FGame.MapName then
  begin
    BuildNavigation;
    for I := 0 to High(FBots) do
    begin
      FBots[I].Path := nil;
      FBots[I].Repath := 0;
    end;
  end;
  Dt := Min(SecondsPassed, 0.1);
  if Dt <= 0 then
    Exit;
  FClock := FClock + Dt;
  for I := 0 to High(FBots) do
    if FGame.ClientActive(FBots[I].E) then
      UpdateBot(FBots[I], Dt);

  FLogTime := FLogTime + SecondsPassed;
  if FLogTime >= 10 then
  begin
    FLogTime := 0;
    S := '';
    for I := 0 to High(FBots) do
    begin
      if S <> '' then
        S := S + ', ';
      Lead := '';
      if (FGame.Coop <> 0) and (FBots[I].Leader > 0) and FGame.ClientActive(FBots[I].Leader) then
        Lead := Format(', %.0f units from %s', [(FGame.EntityOrigin(FBots[I].Leader) -
          FGame.EntityOrigin(FBots[I].E)).Length, FGame.ClientName(FBots[I].Leader)]);
      S := S + Format('%s %d frags (health %d, %.0f units, goal %s%s%s)', [FBots[I].Name,
        FGame.PlayerFrags(FBots[I].E), FGame.PlayerHealth(FBots[I].E), FBots[I].Travelled, FBots[I].GoalName,
        IfThen(FBots[I].Enemy > 0, ', fighting' + IfThen(FGame.Coop <> 0, ' ' + FGame.EntityClassName(FBots[I].Enemy), ''),
        ''), Lead]);
    end;
    if FGame.Coop <> 0 then
      S := S + Format('; coop: %d of %d monsters killed', [FGame.KilledMonsters, FGame.TotalMonsters]);
    WritelnLog('Bots', S);
  end;
end;

end.
