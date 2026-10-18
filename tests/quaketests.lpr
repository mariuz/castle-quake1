{ Unit tests of the Quake units, run headless (no window, no OpenGL, no
  sound) by the Build workflow. Every check is counted, the exit code is
  the number of failures. The shareware pak (quake1_demo.pak, with E1M1
  and progs.dat) is read from the directory given as the first argument
  (default ../data/paks). }
program quaketests;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, Math,
  CastleVectors, CastleUriUtils, CastleLog, CastleDownload, CastleFilesUtils,
  CastleKeysMouse, CastleConfig, CastleTransform, CastleGameControllers,
  QuakePak, QuakePalette, QuakeBsp, QuakePhysics, QuakeProgs, QuakeSaveGame, QuakeDemo, GameInput, GameVideo, GameScreen, QuakeWebSocketRelay, CastleInternalSoundFile;

var
  Checks, Failures: Integer;
  CurrentTest: String;

procedure Check(const Cond: Boolean; const Msg: String);
begin
  Inc(Checks);
  if not Cond then
  begin
    Inc(Failures);
    WriteLn('FAIL [', CurrentTest, '] ', Msg);
  end;
end;

procedure CheckEquals(const Expected, Actual: Int64; const Msg: String);
begin
  Check(Expected = Actual, Format('%s: expected %d, got %d', [Msg, Expected, Actual]));
end;

procedure CheckEqualsStr(const Expected, Actual, Msg: String);
begin
  Check(Expected = Actual, Format('%s: expected "%s", got "%s"', [Msg, Expected, Actual]));
end;

procedure CheckNear(const Expected, Actual, Tolerance: Single; const Msg: String);
begin
  Check(Abs(Expected - Actual) <= Tolerance, Format('%s: expected %.3f, got %.3f', [Msg, Expected, Actual]));
end;

procedure CheckVector(const Expected, Actual: TVector3; const Tolerance: Single; const Msg: String);
begin
  Check((Expected - Actual).Length <= Tolerance, Format('%s: expected %s, got %s',
    [Msg, Expected.ToString, Actual.ToString]));
end;

procedure StartTest(const Name: String);
begin
  CurrentTest := Name;
  WriteLn('--- ', Name);
end;

function TempUrl(const Name: String): String;
begin
  Result := FilenameToUriSafe(IncludeTrailingPathDelimiter(GetTempDir) + Name);
end;

{ ---------------------------------------------------------------------- }

procedure TestBspTracer;
var
  Bsp: TQuakeBsp;
  Start: TQuakeEntity;
  Eye, Below: TVector3;
  T: TQuakeTrace;
begin
  StartTest('BSP tracer (e1m1)');
  Bsp := TQuakeBsp.Create;
  try
    Check(Bsp.LoadFromPak('maps/e1m1.bsp'), 'e1m1.bsp loads');
    CheckEqualsStr('e1m1', Bsp.MapName, 'map name');
    Start := Bsp.FindEntity('info_player_start');
    Check(Start <> nil, 'info_player_start exists');
    if Start = nil then
      Exit;
    Eye := Start.Origin + Vector3(0, 0, 22);
    CheckEquals(CONTENTS_EMPTY, Bsp.PointContents(Eye), 'the start is in open space');
    CheckEquals(CONTENTS_SOLID, Bsp.PointContents(Vector3(100000, 0, 0)), 'far outside is solid');
    CheckEquals(CONTENTS_WATER, Bsp.PointContents(Vector3(836, 880, -308)), 'the pool is water');

    { The player hull dropped onto the floor: it stops on a horizontal plane }
    Below := Eye - Vector3(0, 0, 200);
    T := Bsp.TraceHull(1, 0, TVector3.Zero, Eye, Below);
    Check((T.Fraction > 0) and (T.Fraction < 1), Format('floor hit (fraction %.3f)', [T.Fraction]));
    Check(T.PlaneNormal.Z > 0.9, 'floor plane points up');
    Check((T.EndPos.Z < Eye.Z) and (T.EndPos.Z > Below.Z), 'end position between start and target');
    Check(not T.StartSolid and not T.AllSolid, 'start is not in solid');

    { A short move in free space goes the whole way }
    T := Bsp.TraceHull(1, 0, TVector3.Zero, Eye, Eye + Vector3(8, 0, 0));
    CheckNear(1, T.Fraction, 1e-5, 'free move fraction');
    CheckVector(Eye + Vector3(8, 0, 0), T.EndPos, 0.01, 'free move end');

    { A point trace from far outside the map stays in solid }
    T := Bsp.TraceHull(0, 0, TVector3.Zero, Vector3(100000, 0, 0), Vector3(100000, 10, 0));
    Check(T.AllSolid or T.StartSolid, 'outside trace is in solid');
  finally
    Bsp.Free;
  end;
end;

procedure TestPvs;
var
  Bsp: TQuakeBsp;
  Bits: TBytes;
  FatBits: TBytes;
  StartLeaf, FromLeaf, ToLeaf, Mismatches, Seen: Integer;
  InRow: Boolean;
begin
  StartTest('PVS rows (e1m1)');
  Bsp := TQuakeBsp.Create;
  try
    Check(Bsp.LoadFromPak('maps/e1m1.bsp'), 'e1m1.bsp loads');
    Check(Length(Bsp.MarkSurfaces) > Bsp.VisLeafCount, 'marksurfaces loaded');
    StartLeaf := Bsp.PointLeaf(Bsp.FindEntity('info_player_start').Origin + Vector3(0, 0, 22));
    Check(StartLeaf > 0, 'start leaf');
    Check(Bsp.LeafPVS(StartLeaf, Bits), 'start leaf has a PVS row');
    Seen := 0;
    for ToLeaf := 1 to Bsp.VisLeafCount do
      if (Bits[(ToLeaf - 1) div 8] and (1 shl ((ToLeaf - 1) and 7))) <> 0 then
        Inc(Seen);
    Check((Seen > 1) and (Seen < Bsp.VisLeafCount div 2),
      Format('the start sees part of the map (%d of %d leaves)', [Seen, Bsp.VisLeafCount]));
    Check(not Bsp.LeafPVS(0, Bits), 'the solid leaf has no row');

    { The decompressed rows agree with LeafVisible }
    Mismatches := 0;
    FromLeaf := 1;
    while FromLeaf <= Bsp.VisLeafCount do
    begin
      if Bsp.LeafPVS(FromLeaf, Bits) then
        for ToLeaf := 1 to Bsp.VisLeafCount do
        begin
          InRow := (Bits[(ToLeaf - 1) div 8] and (1 shl ((ToLeaf - 1) and 7))) <> 0;
          if InRow <> Bsp.LeafVisible(FromLeaf, ToLeaf) then
            Inc(Mismatches);
        end;
      Inc(FromLeaf, 37);
    end;
    CheckEquals(0, Mismatches, 'LeafPVS matches LeafVisible');

    { The server's fat PVS around the start eye holds the start leaf's row;
      a box at the start is in it, a box outside the map is not }
    Check(Bsp.FatPvs(Bsp.FindEntity('info_player_start').Origin + Vector3(0, 0, 22), FatBits), 'fat PVS at the start');
    Check(Bsp.LeafPVS(StartLeaf, Bits), 'start row again');
    Mismatches := 0;
    for ToLeaf := 1 to Bsp.VisLeafCount do
      if ((Bits[(ToLeaf - 1) div 8] and (1 shl ((ToLeaf - 1) and 7))) <> 0) and
         ((FatBits[(ToLeaf - 1) div 8] and (1 shl ((ToLeaf - 1) and 7))) = 0) then
        Inc(Mismatches);
    CheckEquals(0, Mismatches, 'the fat PVS covers the start leaf''s PVS');
    Check(Bsp.BoxInPvs(Bsp.FindEntity('info_player_start').Origin - Vector3(16, 16, 24),
      Bsp.FindEntity('info_player_start').Origin + Vector3(16, 16, 32), FatBits), 'a box at the start is in the PVS');
    Check(not Bsp.BoxInPvs(Vector3(100000, 0, 0), Vector3(100010, 10, 10), FatBits), 'a box outside the map is not');
  finally
    Bsp.Free;
  end;
end;

procedure TestProgsVm;
var
  Progs: TQuakeProgs;
  Bsp: TQuakeBsp;
  F, Spawned, E, Monsters: Integer;
begin
  StartTest('QuakeC VM (progs.dat)');
  Progs := TQuakeProgs.Create;
  Bsp := TQuakeBsp.Create;
  try
    Check(Progs.Load, 'progs.dat loads');
    if not Progs.Loaded then
      Exit;
    Check(Progs.FunctionIndex('worldspawn') > 0, 'worldspawn function');
    Check(Progs.FieldOfs('origin') >= 0, 'origin field');
    Check(Progs.GlobalOfs('time') >= 0, 'time global');

    { Opcodes through a QuakeC function: anglemod (v - 360 * floor(v / 360))
      uses OP_MUL_F, OP_DIV_F, OP_SUB_F, a builtin call and OP_RETURN }
    F := Progs.FunctionIndex('anglemod');
    Check(F > 0, 'anglemod function');
    if F > 0 then
    begin
      Progs.Global(OFS_PARM0)^.F := 370;
      Progs.Execute(F);
      CheckNear(10, Progs.Global(OFS_RETURN)^.F, 1e-3, 'anglemod(370)');
      Progs.Global(OFS_PARM0)^.F := -10;
      Progs.Execute(F);
      CheckNear(350, Progs.Global(OFS_RETURN)^.F, 1e-3, 'anglemod(-10)');
      Progs.Global(OFS_PARM0)^.F := 45;
      Progs.Execute(F);
      CheckNear(45, Progs.Global(OFS_RETURN)^.F, 1e-3, 'anglemod(45)');
    end;

    { ED_LoadFromFile of E1M1 at skill 1: the known counts of the shareware
      progs; then 10 s of thinks without the player }
    Check(Bsp.LoadFromPak('maps/e1m1.bsp'), 'e1m1.bsp loads');
    Progs.Global(Progs.GTime)^.F := 1.0;
    Spawned := Progs.SpawnEntities(Bsp.Entities, 1);
    CheckEquals(336, Spawned, 'entities spawned');
    CheckEquals(161, Progs.NumEdicts, 'edicts in use');
    CheckEquals(23, Round(Progs.Global(Progs.GTotalMonsters)^.F), 'total_monsters');
    CheckEquals(6, Round(Progs.Global(Progs.GTotalSecrets)^.F), 'total_secrets');
    CheckEquals(96, Progs.PrecachedModels.Count, 'precached models');
    CheckEquals(103, Progs.PrecachedSounds.Count, 'precached sounds');
    for E := 1 to 100 do
      Progs.RunFrame(0.1);
    CheckNear(11, Progs.Global(Progs.GTime)^.F, 0.01, 'time after 10 s');
    Monsters := 0;
    for E := 1 to Progs.NumEdicts - 1 do
      if not Progs.EdictFree(E) and (Pos('monster_', Progs.FieldString(E, Progs.FClassName)) = 1) then
        Inc(Monsters);
    CheckEquals(23, Monsters, 'monsters alive');
    Check(Progs.Statistics.Thinks > 1000, Format('thinks ran (%d)', [Progs.Statistics.Thinks]));
  finally
    Bsp.Free;
    Progs.Free;
  end;
end;

procedure TestProgsStateRoundTrip;
var
  Progs, Copy: TQuakeProgs;
  Bsp: TQuakeBsp;
  Mem: TMemoryStream;
  E, Mismatches: Integer;
begin
  StartTest('QuakeC VM state round trip');
  Progs := TQuakeProgs.Create;
  Copy := TQuakeProgs.Create;
  Bsp := TQuakeBsp.Create;
  Mem := TMemoryStream.Create;
  try
    if not Progs.Load or not Bsp.LoadFromPak('maps/e1m1.bsp') then
    begin
      Check(False, 'progs and e1m1 load');
      Exit;
    end;
    Progs.Global(Progs.GTime)^.F := 1.0;
    Progs.SpawnEntities(Bsp.Entities, 1);
    for E := 1 to 20 do
      Progs.RunFrame(0.1);
    Progs.SaveState(Mem);
    Check(Mem.Size > 10000, Format('state saved (%d bytes)', [Mem.Size]));
    Mem.Position := 0;
    Check(Copy.Load, 'second progs loads');
    Check(Copy.LoadState(Mem), 'state loads');
    CheckEquals(Progs.NumEdicts, Copy.NumEdicts, 'edict count');
    CheckNear(Progs.Global(Progs.GTime)^.F, Copy.Global(Copy.GTime)^.F, 1e-6, 'time global');
    Mismatches := 0;
    for E := 0 to Min(Progs.NumEdicts, Copy.NumEdicts) - 1 do
    begin
      if Progs.EdictFree(E) <> Copy.EdictFree(E) then
        Inc(Mismatches)
      else
      if not Progs.EdictFree(E) then
      begin
        if Progs.FieldString(E, Progs.FClassName) <> Copy.FieldString(E, Copy.FClassName) then
          Inc(Mismatches);
        if not TVector3.PerfectlyEquals(Progs.FieldVector(E, Progs.FieldOfs('origin')),
          Copy.FieldVector(E, Copy.FieldOfs('origin'))) then
          Inc(Mismatches);
      end;
    end;
    CheckEquals(0, Mismatches, 'edicts identical after the round trip');
    CheckEquals(Progs.PrecachedModels.Count, Copy.PrecachedModels.Count, 'precached models');
    { The copy keeps running }
    for E := 1 to 10 do
      Copy.RunFrame(0.1);
    CheckNear(Progs.Global(Progs.GTime)^.F + 1.0, Copy.Global(Copy.GTime)^.F, 0.01, 'the copy advances');
  finally
    Mem.Free;
    Bsp.Free;
    Copy.Free;
    Progs.Free;
  end;
end;

procedure TestSaveData;
var
  D, L: TQuakeSaveData;
  Url: String;
begin
  StartTest('Savegame data round trip');
  D := TQuakeSaveData.Create;
  L := TQuakeSaveData.Create;
  try
    D.SetStr('map', 'e1m1');
    D.SetStr('text', 'with spaces = and "quotes"');
    D.SetInt('health', -7);
    D.SetInt('big', 1234567890123);
    D.SetFloat('pitch', -12.5);
    D.SetBool('god', True);
    D.SetVec('origin', Vector3(480.25, -352, 88));
    Url := TempUrl('quaketests_save.sav');
    Check(D.SaveToUrl(Url), 'save');
    Check(L.LoadFromUrl(Url), 'load');
    CheckEqualsStr('e1m1', L.GetStr('map'), 'string');
    CheckEqualsStr('with spaces = and "quotes"', L.GetStr('text'), 'string with punctuation');
    CheckEquals(-7, L.GetInt('health'), 'negative integer');
    CheckEquals(1234567890123, L.GetInt('big'), '64 bit integer');
    CheckNear(-12.5, L.GetFloat('pitch'), 1e-5, 'float');
    Check(L.GetBool('god'), 'boolean');
    CheckVector(Vector3(480.25, -352, 88), L.GetVec('origin', TVector3.Zero), 1e-4, 'vector');
    Check(not L.HasKey('missing'), 'missing key');
    CheckEquals(42, L.GetInt('missing', 42), 'default value');
  finally
    L.Free;
    D.Free;
  end;
end;

type
  TDemoListener = class
    Prints: TStringList;
    ServerInfos: Integer;
    constructor Create;
    destructor Destroy; override;
    procedure OnPrint(const S: String);
    procedure OnServerInfo;
    procedure OnSound(const Entity, Channel, SoundIndex: Integer;
      const Volume, Attenuation: Single; const Origin: TVector3);
  public
    LastSoundEntity, LastSoundChannel, LastSoundIndex: Integer;
    LastSoundOrigin: TVector3;
  end;

constructor TDemoListener.Create;
begin
  inherited Create;
  Prints := TStringList.Create;
end;

destructor TDemoListener.Destroy;
begin
  Prints.Free;
  inherited Destroy;
end;

procedure TDemoListener.OnPrint(const S: String);
begin
  Prints.Add(S);
end;

procedure TDemoListener.OnServerInfo;
begin
  Inc(ServerInfos);
end;

procedure TDemoListener.OnSound(const Entity, Channel, SoundIndex: Integer;
  const Volume, Attenuation: Single; const Origin: TVector3);
begin
  LastSoundEntity := Entity;
  LastSoundChannel := Channel;
  LastSoundIndex := SoundIndex;
  LastSoundOrigin := Origin;
end;

procedure TestDemoRoundTrip;
var
  W: TQuakeDemoWriter;
  R: TQuakeDemoReader;
  Listener: TDemoListener;
  CD: TDemoClientData;
  State: TDemoEntityState;
  Url: String;
  I, PlayerModel: Integer;
begin
  StartTest('Demo writer / reader round trip');
  W := TQuakeDemoWriter.Create;
  R := TQuakeDemoReader.Create;
  Listener := TDemoListener.Create;
  try
    W.BeginLevel('maps/e1m1.bsp', 'Test level', Vector3(0, 90, 0), 5, 2);
    PlayerModel := W.ModelIndex('progs/player.mdl');
    Check(PlayerModel > 1, 'model index after the map');
    CD := Default(TDemoClientData);
    CD.Health := 77;
    CD.Armor := 50;
    CD.ViewHeight := 22;
    CD.Velocity := Vector3(1, 2, 3);
    CD.Ammo := 25;
    CD.Shells := 25;
    State := Default(TDemoEntityState);
    State.ModelIndex := PlayerModel;
    for I := 0 to 4 do
    begin
      W.BeginFrame(1.0 + I * 0.1);
      W.WriteClientData(CD);
      State.Origin := Vector3(100 + I * 10, 200, 300);
      State.Angles := Vector3(0, 90, 0);
      State.Frame := I;
      W.WriteEntity(1, State);
      if I = 1 then
        W.WritePrint('hello demo');
      if I = 2 then
        W.WriteTempEntity(TE_EXPLOSION, Vector3(1, 2, 3));
      W.EndFrame(Vector3(0, 90, 0));
    end;
    Url := TempUrl('quaketests_demo.dem');
    Check(W.SaveToUrl(Url), 'demo saved');

    R.OnPrint := @Listener.OnPrint;
    R.OnServerInfo := @Listener.OnServerInfo;
    Check(R.Load(Url), 'demo loads');
    for I := 1 to 40 do
      R.Advance(0.05);
    CheckEquals(1, Listener.ServerInfos, 'one serverinfo');
    CheckEqualsStr('Test level', R.LevelName, 'level name');
    CheckEqualsStr('maps/e1m1.bsp', R.ModelName(1), 'model 1 is the map');
    CheckEqualsStr('progs/player.mdl', R.ModelName(PlayerModel), 'player model');
    { The writer greets at the level start, then the print of frame 1 }
    CheckEquals(2, Listener.Prints.Count, 'print count');
    if Listener.Prints.Count > 1 then
      CheckEqualsStr('hello demo', Listener.Prints[1], 'print text');
    CheckEquals(77, R.ClientData.Health, 'health');
    CheckEquals(50, R.ClientData.Armor, 'armor');
    CheckEquals(25, R.ClientData.Shells, 'shells');
    Check(Length(R.Entities) > 1, 'entities parsed');
    if Length(R.Entities) > 1 then
    begin
      CheckEquals(PlayerModel, R.Entities[1].Msg[0].ModelIndex, 'entity model');
      CheckVector(Vector3(140, 200, 300), R.Entities[1].Msg[0].Origin, 0.2, 'last entity origin');
      CheckEquals(4, R.Entities[1].Msg[0].Frame, 'last entity frame');
    end;
    Check(R.Finished, 'demo finished');
  finally
    Listener.Free;
    R.Free;
    W.Free;
  end;
end;

procedure TestDemoFitzQuake;
var
  W: TQuakeDemoWriter;
  R: TQuakeDemoReader;
  Listener: TDemoListener;
  CD: TDemoClientData;
  State: TDemoEntityState;
  Url: String;
  I, BigModel, BigSound: Integer;
begin
  StartTest('Demo round trip with FitzQuake 16-bit numbers (protocol 666)');
  W := TQuakeDemoWriter.Create;
  R := TQuakeDemoReader.Create;
  Listener := TDemoListener.Create;
  try
    W.BeginLevel('maps/big.bsp', 'Big level', Vector3(0, 0, 0), 0, 0);
    BigModel := 0;
    for I := 1 to 300 do
      BigModel := W.ModelIndex(Format('progs/m%d.mdl', [I]));
    BigSound := 0;
    for I := 1 to 280 do
      BigSound := W.SoundIndex(Format('misc/s%d.wav', [I]));
    Check(BigModel > 255, Format('model index above 255 (%d)', [BigModel]));
    Check(BigSound > 255, Format('sound index above 255 (%d)', [BigSound]));
    CD := Default(TDemoClientData);
    CD.ViewHeight := 22;
    CD.Health := 100;
    CD.Weapon := BigModel;
    CD.Armor := 300;
    CD.Cells := 400;
    CD.WeaponFrame := 260;
    State := Default(TDemoEntityState);
    { The first state is the baseline (svc_spawnbaseline2), the second an update }
    for I := 0 to 1 do
    begin
      W.BeginFrame(1.0 + I * 0.1);
      W.WriteClientData(CD);
      State.ModelIndex := BigModel - I;
      State.Frame := 270 + I;
      State.Origin := Vector3(10, 20, 30 + I);
      W.WriteEntity(700, State);
      W.WriteSound(9000, 5, BigSound, 1, 1, Vector3(1, 2, 3));
      W.EndFrame(TVector3.Zero);
    end;
    Url := TempUrl('quaketests_fitz.dem');
    Check(W.SaveToUrl(Url), 'demo saved');

    R.OnSound := @Listener.OnSound;
    Check(R.Load(Url), 'demo loads');
    for I := 1 to 40 do
      R.Advance(0.05);
    CheckEquals(ProtocolFitzQuake, R.Protocol, 'the level is protocol 666');
    CheckEqualsStr(Format('progs/m%d.mdl', [300]), R.ModelName(BigModel), 'model above 255 in the serverinfo');
    CheckEquals(BigModel, R.Entities[700].Baseline.ModelIndex, 'baseline model above 255');
    CheckEquals(270, R.Entities[700].Baseline.Frame, 'baseline frame above 255');
    CheckEquals(BigModel - 1, R.Entities[700].Msg[0].ModelIndex, 'updated model above 255');
    CheckEquals(271, R.Entities[700].Msg[0].Frame, 'updated frame above 255');
    CheckEquals(BigModel, R.ClientData.Weapon, 'weapon model above 255');
    CheckEquals(300, R.ClientData.Armor, 'armor above 255');
    CheckEquals(400, R.ClientData.Cells, 'cells above 255');
    CheckEquals(260, R.ClientData.WeaponFrame, 'weapon frame above 255');
    CheckEquals(9000, Listener.LastSoundEntity, 'sound entity from 8192');
    CheckEquals(5, Listener.LastSoundChannel, 'sound channel');
    CheckEquals(BigSound, Listener.LastSoundIndex, 'sound above 255');
    Check(R.Finished, 'demo finished');
  finally
    Listener.Free;
    R.Free;
    W.Free;
  end;
end;

procedure TestBindings;
var
  Ev: TInputPressRelease;
begin
  StartTest('Bindings round trip (user config)');
  InitializeBindings;
  Check(Bindings[qbJump] <> nil, 'bindings created');
  if Bindings[qbJump] = nil then
    Exit;
  Check((Bindings[qbJump].Key1 = keySpace), 'jump defaults to Space');
  Ev := InputKey(TVector2.Zero, keyJ, 'j', []);
  Check(AssignBinding(qbJump, Ev), 'rebind jump to J');
  Check((Bindings[qbJump].Key1 = keyJ) and not (Bindings[qbJump].Key1 = keySpace), 'jump is J now');
  Check(Pos('J', BindingDescription(qbJump)) > 0, 'description names J: ' + BindingDescription(qbJump));
  { Back to the default in memory, then the saved config brings J back }
  Bindings[qbJump].MakeDefault;
  Check((Bindings[qbJump].Key1 = keySpace), 'default restored in memory');
  BindingList.LoadFromConfig(UserConfig, 'bindings');
  Check((Bindings[qbJump].Key1 = keyJ), 'the saved binding loads');
  Ev := InputMouseButton(TVector2.Zero, buttonRight, 0, []);
  Check(AssignBinding(qbUse, Ev), 'rebind use to the right mouse button');
  Check(Bindings[qbUse].IsEvent(Ev), 'use is the right mouse button');
  ResetBindings;
  Check((Bindings[qbJump].Key1 = keySpace) and (Bindings[qbUse].Key1 = keyE), 'reset to defaults');
end;

{ The player walks the same at any frame rate: Quake's movement needs steps
  of at least MinPhysicsStep, shorter frames add up }
procedure TestPhysicsFrameRate;
const
  Rates: array[0..4] of Integer = (30, 72, 144, 1000, 3000);
var
  Bsp: TQuakeBsp;
  Start: TQuakeEntity;
  Phys: TQuakePlayerPhysics;
  Cmd: TQuakeUserCmd;
  Rate, Frame: Integer;
  Reference: TVector3;
  AlwaysOnGround: Boolean;
  T: TQuakeTrace;

  { 1 s standing, then 1.5 s forward down the start ramp, then 1 s to stop }
  procedure Walk(const Fps: Integer);
  var
    I: Integer;
    Time: Single;
  begin
    Phys.Teleport(Start.Origin);
    Cmd := Default(TQuakeUserCmd);
    AlwaysOnGround := True;
    Time := 0;
    for I := 1 to Round(3.5 * Fps) do
    begin
      if (Time >= 1) and (Time < 2.5) then
        Cmd.ForwardMove := ClForwardSpeed
      else
        Cmd.ForwardMove := 0;
      Phys.Move(Cmd, 90, 0, 1 / Fps);
      Time := Time + 1 / Fps;
      if (Time > 0.5) and (Time < 1) and not Phys.OnGround then
        AlwaysOnGround := False;
    end;
  end;

begin
  StartTest('Player physics at any frame rate (e1m1)');
  Bsp := TQuakeBsp.Create;
  Phys := TQuakePlayerPhysics.Create;
  try
    Check(Bsp.LoadFromPak('maps/e1m1.bsp'), 'e1m1.bsp loads');
    Start := Bsp.FindEntity('info_player_start');
    if Start = nil then
      Exit;
    Phys.Bsp := Bsp;
    Walk(72);
    Reference := Phys.Origin;
    Check(Reference.Y > Start.Origin.Y + 300, Format('the 72 fps walk goes down the ramp (%s)', [Reference.ToString]));
    for Rate in Rates do
    begin
      Walk(Rate);
      CheckVector(Reference, Phys.Origin, 8, Format('%d fps ends where 72 fps does', [Rate]));
      Check(AlwaysOnGround, Format('%d fps: standing still stays on the ground', [Rate]));
      Check(Phys.OnGround, Format('%d fps: on the ground at the end', [Rate]));
      T := Bsp.TraceHull(1, 0, TVector3.Zero, Phys.Origin, Phys.Origin);
      Check(not T.StartSolid, Format('%d fps: not stuck in the floor', [Rate]));
    end;
    { Shorter calls than a step wait for it: nothing moves yet }
    Phys.Teleport(Start.Origin + Vector3(0, 0, 32));
    Frame := 0;
    while Frame < 5 do
    begin
      Phys.Move(Cmd, 90, 0, 0.001);
      Inc(Frame);
    end;
    CheckNear(Start.Origin.Z + 32, Phys.Origin.Z, 1e-4, '5 ms of 1 ms calls wait for a step');
    Phys.Move(Cmd, 90, 0, 0.002);
    Check(Phys.Origin.Z < Start.Origin.Z + 32, 'the 7th ms runs the step (falling)');
  finally
    Phys.Free;
    Bsp.Free;
  end;
end;

{ Every sample of the pak loads with the engine's WAV reader: many original
  ones end with a broken chunk (a LIST declaring gigabytes), which made the
  reader fail and, on WebAssembly, stopped the game (the pak cleans them) }
procedure TestSoundFiles;
var
  Files: TStringList;
  I, Failed: Integer;
  F: TSoundFile;
begin
  StartTest('Every sample loads through quakepak:');
  Files := Pak.FindFiles('sound/', '.wav');
  try
    Check(Files.Count > 100, Format('the pak has samples (%d)', [Files.Count]));
    Failed := 0;
    for I := 0 to Files.Count - 1 do
    begin
      try
        F := TSoundFile.Create('quakepak:/' + Files[I]);
        try
          if F.DataSize = 0 then
          begin
            Inc(Failed);
            WriteLn('  no sound data: ', Files[I]);
          end;
        finally
          F.Free;
        end;
      except
        on E: Exception do
        begin
          Inc(Failed);
          WriteLn('  cannot load ', Files[I], ': ', E.Message);
        end;
      end;
    end;
    CheckEquals(0, Failed, Format('samples that do not load (of %d)', [Files.Count]));
  finally
    Files.Free;
  end;
end;

{ FitzQuake's svc_skybox and svc_fog: the level's sky and fog in the
  signon and a change during the level, and a stuffed fog command }
procedure TestUIScale;
begin
  StartTest('UI scale for the screen size and density (GameScreen)');
  CheckNear(1.0, ComputeUIScale(1600, 900, 1), 0.001, 'a 1600 x 900 desktop window keeps the design size');
  CheckNear(0.8, ComputeUIScale(1280, 720, 1), 0.001, 'a smaller desktop window encloses the design');
  CheckNear(1.2, ComputeUIScale(1920, 1080, 1.5), 0.001, 'a 150% desktop: the enclosing scale is readable');
  { A phone of 844 x 390 CSS pixels at devicePixelRatio 3 }
  CheckNear(2.1, ComputeUIScale(2532, 1170, 3), 0.001, 'a landscape phone: readable text, not the 1.3 of enclosing');
  CheckNear(1170 / 800, ComputeUIScale(1170, 2532, 3), 0.001, 'a portrait phone: capped by the width');
  Check(1170 / ComputeUIScale(1170, 2532, 3) >= 799.9, 'a portrait phone keeps 800 design units across');
  Check(1170 / ComputeUIScale(2532, 1170, 3) >= 479.9, 'a landscape phone keeps 480 design units high');
  CheckNear(1.0, ComputeUIScale(0, 0, 3), 0.001, 'no window yet: 1');
end;

procedure TestDemoLargeCoords;
var
  W: TQuakeDemoWriter;
  R: TQuakeDemoReader;
  Listener: TDemoListener;
  CD: TDemoClientData;
  State: TDemoEntityState;
  Url: String;
  I, Snd: Integer;

  function WriteDemo(const Name: String; const Large: Boolean): String;
  var
    J: Integer;
  begin
    W := TQuakeDemoWriter.Create;
    try
      W.BeginLevel('maps/far.bsp', 'Far level', Vector3(0, 0, 0), 0, 0, Large);
      Snd := W.SoundIndex('misc/far.wav');
      CD := Default(TDemoClientData);
      CD.ViewHeight := 22;
      CD.Health := 100;
      State := Default(TDemoEntityState);
      State.ModelIndex := W.ModelIndex('progs/player.mdl');
      { The baseline far away, then moving further }
      for J := 0 to 39 do
      begin
        W.BeginFrame(1.0 + J * 0.1);
        W.WriteClientData(CD);
        State.Origin := Vector3(9000.5, -12000.25, 5000 + J);
        State.Angles := Vector3(-10, 200.5 + J, 0);
        W.WriteEntity(1, State);
        if J = 20 then
          W.WriteSound(1, 1, Snd, 1, 1, Vector3(-8191.5, 7000.125, 4200));
        W.EndFrame(TVector3.Zero);
      end;
      Result := TempUrl(Name);
      Check(W.SaveToUrl(Result), 'demo saved');
    finally
      FreeAndNil(W);
    end;
  end;

begin
  StartTest('Demo round trip beyond 16-bit coordinates (protocol 999)');
  Listener := TDemoListener.Create;
  R := TQuakeDemoReader.Create;
  try
    Url := WriteDemo('quaketests_far.dem', True);
    R.OnSound := @Listener.OnSound;
    Check(R.Load(Url), 'demo loads');
    for I := 1 to 120 do
      R.Advance(0.05);
    CheckEquals(ProtocolRMQ, R.Protocol, 'a level beyond 16-bit coordinates is protocol 999');
    CheckEquals(RMQProtocolFlags, R.ProtocolFlags, 'float coordinates and 16-bit angles');
    CheckNear(9000.5, R.Entities[1].Baseline.Origin.X, 0.001, 'baseline x beyond 4096');
    CheckNear(-12000.25, R.Entities[1].Baseline.Origin.Y, 0.001, 'baseline y beyond -4096');
    CheckNear(5000, R.Entities[1].Baseline.Origin.Z, 0.001, 'baseline z');
    CheckNear(5039, R.Entities[1].Msg[0].Origin.Z, 0.001, 'updated z beyond 4096');
    CheckNear(9000.5, R.Entities[1].Msg[0].Origin.X, 0.001, 'unchanged x from the baseline');
    { 16-bit angles: 360 / 65536 degrees apart }
    CheckNear(-10, R.Entities[1].Msg[0].Angles.X, 0.01, 'pitch in 16 bits');
    CheckNear(239.5 - 360, R.Entities[1].Msg[0].Angles.Y, 0.01, 'yaw in 16 bits');
    CheckVector(Vector3(-8191.5, 7000.125, 4200), Listener.LastSoundOrigin, 0.001, 'sound origin beyond 4096');
    Check(R.Finished, 'demo finished');

    { Without the flag the level stays protocol 15, its coordinates 16-bit }
    FreeAndNil(R);
    R := TQuakeDemoReader.Create;
    Url := WriteDemo('quaketests_near.dem', False);
    Check(R.Load(Url), 'protocol 15 demo loads');
    for I := 1 to 120 do
      R.Advance(0.05);
    CheckEquals(ProtocolNetQuake, R.Protocol, 'a level within 16-bit coordinates stays protocol 15');
    CheckNear(4095.875, R.Entities[1].Msg[0].Origin.Z, 0.001, '16-bit coordinates stop at 4095.875');
  finally
    R.Free;
    Listener.Free;
  end;
end;

procedure TestDemoFogSkybox;
var
  W: TQuakeDemoWriter;
  R: TQuakeDemoReader;
  CD: TDemoClientData;
  State: TDemoEntityState;
  Url: String;
  I: Integer;
begin
  StartTest('Demo fog and skybox (svc_fog, svc_skybox)');
  W := TQuakeDemoWriter.Create;
  R := TQuakeDemoReader.Create;
  try
    W.BeginLevel('maps/fog.bsp', 'Fog level', Vector3(0, 0, 0), 0, 0);
    W.SetLevelEnvironment('test', True, 0.1, Vector3(0.5, 0.35, 0.25));
    CD := Default(TDemoClientData);
    CD.ViewHeight := 22;
    CD.Health := 100;
    { 4 s of frames, the change 3 s in; the first entity update completes
      the signon (CL_ParseUpdate), from there playback follows the time }
    State := Default(TDemoEntityState);
    State.ModelIndex := W.ModelIndex('progs/player.mdl');
    for I := 0 to 39 do
    begin
      W.BeginFrame(1.0 + I * 0.1);
      W.WriteClientData(CD);
      W.WriteEntity(1, State);
      if I = 30 then
      begin
        W.WriteFog(0.2, Vector3(0.1, 0.2, 0.6));
        W.WriteSkybox('other');
      end;
      W.EndFrame(TVector3.Zero);
    end;
    Url := TempUrl('quaketests_fog.dem');
    Check(W.SaveToUrl(Url), 'demo saved');

    Check(R.Load(Url), 'demo loads');
    for I := 1 to 5 do
      R.Advance(0.05);
    CheckEquals(ProtocolFitzQuake, R.Protocol, 'a level with sky and fog is protocol 666');
    CheckEqualsStr('test', R.SkyboxName, 'the level''s skybox in the signon');
    Check(R.SkyboxChanged and R.FogChanged, 'the signon sets the changed flags');
    CheckNear(0.1, R.FogDensity, 0.005, 'the level''s fog density');
    CheckVector(Vector3(0.5, 0.35, 0.25), R.FogColor, 0.01, 'the level''s fog color');
    R.SkyboxChanged := False;
    R.FogChanged := False;
    for I := 1 to 60 do
      R.Advance(0.05);
    Check(R.SkyboxChanged and R.FogChanged, 'the change during the level sets the flags again');
    CheckEqualsStr('other', R.SkyboxName, 'the new skybox');
    CheckNear(0.2, R.FogDensity, 0.005, 'the new fog density');
    CheckVector(Vector3(0.1, 0.2, 0.6), R.FogColor, 0.01, 'the new fog color');

    { Mods change the fog by stuffcmd }
    R.FogChanged := False;
    R.ParseStuffText('echo hello' + #10 + 'fog 0.05 1 0 0.5;bf');
    Check(R.FogChanged, 'a stuffed fog command');
    CheckNear(0.05, R.FogDensity, 1e-5, 'stuffed fog density');
    CheckVector(Vector3(1, 0, 0.5), R.FogColor, 1e-5, 'stuffed fog color');
    R.ParseStuffText('fog 0.3');
    CheckNear(0.3, R.FogDensity, 1e-5, 'fog <density> keeps the color');
    CheckVector(Vector3(1, 0, 0.5), R.FogColor, 1e-5, 'the color kept');
    R.FogChanged := False;
    R.ParseStuffText('fog 0.1 0.2');
    Check(not R.FogChanged, 'a fog command of three words is ignored');
  finally
    R.Free;
    W.Free;
  end;
end;

procedure TestVideo;
var
  T, B, MinB, MaxB: Single;
  Crossings: Integer;
  Prev: Single;
begin
  StartTest('Video options (fov, view bob)');
  VideoFov := 90;
  CheckNear(73.74, RadToDeg(VerticalFov), 0.01, 'fov 90 at 4:3 is 73.74 degrees vertically');
  VideoFov := 120;
  Check(RadToDeg(VerticalFov) > 100, 'a wider fov widens the vertical one too');
  VideoFov := 90;

  ViewBob := DefaultViewBob;
  CheckNear(0, CalcViewBob(1.23, TVector3.Zero), 1e-6, 'no bob standing still');
  CheckNear(0, CalcViewBob(1.23, Vector3(0, 0, -300)), 1e-6, 'no bob falling straight down');
  { Running at 320: 6.4 units, 0.3 of it plus 0.7 of it on the sine, clamped to 4 }
  MinB := 100;
  MaxB := -100;
  Crossings := 0;
  Prev := CalcViewBob(0, Vector3(320, 0, 0));
  T := 0;
  while T < 1.2 do
  begin
    B := CalcViewBob(T, Vector3(320, 0, 0));
    MinB := Min(MinB, B);
    MaxB := Max(MaxB, B);
    if (Prev < 0) <> (B < 0) then
      Inc(Crossings);
    Prev := B;
    T := T + 0.001;
  end;
  CheckNear(4, MaxB, 1e-3, 'running bob tops out at the clamp of 4');
  CheckNear(-2.56, MinB, 0.01, 'running bob bottoms at 6.4 * (0.3 - 0.7)');
  CheckEquals(4, Crossings, 'two bob cycles in 1.2 s (cl_bobcycle 0.6)');
  ViewBob := 0;
  CheckNear(0, CalcViewBob(0.4, Vector3(320, 0, 0)), 1e-6, 'cl_bob 0 turns it off');
  ViewBob := DefaultViewBob;
end;

procedure TestGamepad;
var
  Camera: TCastleCamera;
  Forward, Side: Single;

  function Yaw: Single;
  begin
    Result := RadToDeg(ArcTan2(-Camera.Direction.Z, Camera.Direction.X));
  end;

  function Pitch: Single;
  begin
    Result := RadToDeg(ArcSin(Camera.Direction.Y));
  end;

  procedure ResetCamera;
  begin
    Camera.SetWorldView(TVector3.Zero, Vector3(1, 0, 0), Vector3(0, 1, 0));
  end;

begin
  StartTest('Gamepad (virtual controller)');
  GamepadSensitivity := 1.0;
  GamepadDeadZone := DefaultGamepadDeadZone;
  GamepadInvertLook := False;
  Camera := TCastleCamera.Create(nil);
  try
    { Dead zone: inside it nothing, the rest rescaled so the edge stays 1 }
    CheckNear(0, ApplyDeadZone(0.15), 1e-6, 'inside the dead zone');
    CheckNear(0.5, ApplyDeadZone(0.6), 1e-5, 'half way past the dead zone');
    CheckNear(-1, ApplyDeadZone(-1), 1e-6, 'full deflection');

    SetVirtualSticks(Vector2(0.6, 1.0), TVector2.Zero);
    Check(GamepadConnected, 'the virtual controller counts as connected');
    GamepadMove(Forward, Side);
    CheckNear(1, Forward, 1e-5, 'left stick forward');
    CheckNear(0.5, Side, 1e-5, 'left stick side');

    { Right stick right for 0.5 s: 160 deg/s turns 80 deg to the right }
    ResetCamera;
    SetVirtualSticks(TVector2.Zero, Vector2(1, 0));
    GamepadTurnCamera(Camera, 0.5);
    CheckNear(-80, Yaw, 0.1, 'turn right at sensitivity 1');
    GamepadSensitivity := 2.0;
    ResetCamera;
    GamepadTurnCamera(Camera, 0.5);
    CheckNear(-160, Yaw, 0.1, 'turn right at sensitivity 2');
    GamepadSensitivity := 1.0;

    { Right stick up for 0.25 s looks up 22.5 deg, inverted down }
    ResetCamera;
    SetVirtualSticks(TVector2.Zero, Vector2(0, 1));
    GamepadTurnCamera(Camera, 0.25);
    CheckNear(22.5, Pitch, 0.1, 'look up');
    GamepadInvertLook := True;
    ResetCamera;
    GamepadTurnCamera(Camera, 0.25);
    CheckNear(-22.5, Pitch, 0.1, 'inverted look goes down');
    GamepadInvertLook := False;

    { The pitch stops at 85 deg }
    ResetCamera;
    GamepadTurnCamera(Camera, 5);
    CheckNear(85, Pitch, 0.1, 'pitch clamped');

    { A small dead zone lets a light touch through }
    GamepadDeadZone := 0.1;
    ResetCamera;
    SetVirtualSticks(TVector2.Zero, Vector2(0.15, 0));
    GamepadTurnCamera(Camera, 1);
    Check(Abs(Yaw) > 1, Format('light touch turns with dead zone 0.1 (yaw %.2f)', [Yaw]));
    GamepadDeadZone := DefaultGamepadDeadZone;
    ResetCamera;
    GamepadTurnCamera(Camera, 1);
    CheckNear(0, Yaw, 1e-4, 'light touch ignored with dead zone 0.2');
    SetVirtualSticks(TVector2.Zero, TVector2.Zero);

    { The tuning is saved in the user config (only what differs from the defaults) }
    GamepadSensitivity := 2.0;
    GamepadInvertLook := True;
    SaveGamepadSettings;
    CheckNear(2.0, UserConfig.GetFloat('gamepad/sensitivity', 1.0), 1e-5, 'sensitivity saved');
    Check(UserConfig.GetValue('gamepad/invert_look', False), 'invert look saved');
    GamepadSensitivity := 1.0;
    GamepadInvertLook := False;
    SaveGamepadSettings;
    Check(not UserConfig.GetValue('gamepad/invert_look', False), 'defaults written back');
  finally
    Camera.Free;
  end;
end;

procedure TestWebSocket;
begin
  StartTest('WebSocket handshake');
  { The example of RFC 6455 section 1.3 }
  CheckEqualsStr('s3pPLMBiTxaQ9kYGzzhZRbK+xOo=', WebSocketAcceptKey('dGhlIHNhbXBsZSBub25jZQ=='), 'accept key');
  CheckEqualsStr('s3pPLMBiTxaQ9kYGzzhZRbK+xOo=', WebSocketAcceptKey(' dGhlIHNhbXBsZSBub25jZQ== '), 'key with spaces');
end;

{ ---------------------------------------------------------------------- }

var
  PaksDir, PakFile: String;
begin
  Checks := 0;
  Failures := 0;
  if ParamCount >= 1 then
    PaksDir := ParamStr(1)
  else
    PaksDir := '..' + PathDelim + 'data' + PathDelim + 'paks';
  PakFile := IncludeTrailingPathDelimiter(PaksDir) + 'quake1_demo.pak';
  if not FileExists(PakFile) then
  begin
    WriteLn('Cannot find ', PakFile, ' (pass the paks directory as the first argument)');
    Halt(2);
  end;
  Pak.RegisterProtocol;
  if not Pak.AddFile(PakFile, True) then
  begin
    WriteLn('Cannot load ', PakFile);
    Halt(2);
  end;
  Palette.LoadFromPak;

  TestBspTracer;
  TestPhysicsFrameRate;
  TestPvs;
  TestProgsVm;
  TestProgsStateRoundTrip;
  TestSaveData;
  TestDemoRoundTrip;
  TestDemoFitzQuake;
  TestDemoFogSkybox;
  TestDemoLargeCoords;
  TestUIScale;
  TestBindings;
  TestWebSocket;
  TestSoundFiles;
  TestGamepad;
  TestVideo;

  WriteLn(Format('%d checks, %d failures', [Checks, Failures]));
  if Failures > 0 then
    Halt(1);
end.
