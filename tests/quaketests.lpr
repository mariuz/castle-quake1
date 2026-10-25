{ Unit tests of the Quake units, run headless (no window, no OpenGL, no
  sound) by the Build workflow. Every check is counted, the exit code is
  the number of failures. The shareware pak (quake1_demo.pak, with E1M1
  and progs.dat) is read from the directory given as the first argument
  (default ../data/paks). }
program quaketests;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, Math, Generics.Collections,
  CastleVectors, CastleUriUtils, CastleLog, CastleDownload, CastleFilesUtils,
  CastleKeysMouse, CastleConfig, CastleTransform, CastleGameControllers,
  QuakePak, QuakePalette, QuakeMdl, QuakeBsp, QuakePhysics, QuakeProgs, QuakeSaveGame, QuakeDemo, GameInput, GameVideo, GameScreen, QuakeWebSocketRelay, CastleInternalSoundFile,
  QuakeRandomMap, QuakeCaptions, QuakeMapBrowser, GameTranslate, QuakeNet, Sockets, GameFontUi,
  CastleUnicode, ZStream, StrUtils;

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

{ Controller glyphs: the pad family from the controller's name, the button
  names by position and the menus' confirm button }
procedure TestPadGlyphs;
begin
  StartTest('Pad glyphs');
  Check(PadFamilyOfName('Xbox Wireless Controller') = pfXbox, 'an Xbox pad');
  Check(PadFamilyOfName('Microsoft X-Box 360 pad') = pfXbox, 'an Xbox 360 pad');
  Check(PadFamilyOfName('Sony Interactive Entertainment Wireless Controller') = pfPlayStation, 'a DualShock 4');
  Check(PadFamilyOfName('Wireless Controller') = pfPlayStation, 'a DualShock 4 by its short name');
  Check(PadFamilyOfName('DualSense Wireless Controller') = pfPlayStation, 'a DualSense');
  Check(PadFamilyOfName('Nintendo Switch Pro Controller') = pfNintendo, 'a Switch Pro Controller');
  Check(PadFamilyOfName('Joy-Con (L/R)') = pfNintendo, 'Joy-Cons');
  Check(PadFamilyOfName('Logitech Gamepad F310') = pfXbox, 'an unknown pad has Xbox names');
  CheckEqualsStr('A', PadButtonLabel(pfXbox, gbSouth), 'Xbox south is A');
  CheckEqualsStr('Cross', PadButtonLabel(pfPlayStation, gbSouth), 'PlayStation south is Cross');
  CheckEqualsStr('B', PadButtonLabel(pfNintendo, gbSouth), 'Nintendo south is B');
  CheckEqualsStr('A', PadButtonLabel(pfNintendo, gbEast), 'Nintendo east is A');
  CheckEqualsStr('Triangle', PadButtonLabel(pfPlayStation, gbNorth), 'PlayStation north is Triangle');
  CheckEqualsStr('R1', PadButtonLabel(pfPlayStation, gbRightBumper), 'PlayStation right bumper is R1');
  CheckEqualsStr('+', PadButtonLabel(pfNintendo, gbMenu), 'Nintendo menu is +');
  GamepadConfirm := pcAuto;
  GamepadLayout := plNintendo;
  Check((GamepadConfirmButton = gbEast) and (GamepadBackButton = gbSouth), 'Nintendo confirms with A on the east');
  GamepadLayout := plPlayStation;
  Check((GamepadConfirmButton = gbSouth) and (GamepadBackButton = gbEast), 'PlayStation confirms with Cross');
  GamepadConfirm := pcEast;
  Check(GamepadConfirmButton = gbEast, 'the confirm option swaps it');
  GamepadConfirm := pcAuto;
  GamepadLayout := plAuto;
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

    { Split-screen: one pad belongs to the second player; the keyboard
      player gets none of it }
    Check((PlayerController(2) <> nil) and (PlayerController(2) = PlayerController(0)),
      'the only pad is the second player''s');
    Check(PlayerController(1) = nil, 'the keyboard player has no pad of one');
    GamepadMove(Forward, Side, 2);
    CheckNear(1, Forward, 1e-5, 'the second player walks with the stick');
    GamepadMove(Forward, Side, 1);
    Check((Forward = 0) and (Side = 0), 'the stick does not walk the first player');
    { The container copies a virtual press into Pressed every frame }
    Controllers[0].Pressed[gbSouth] := True;
    UpdateGamepad(1);
    UpdateGamepad(2);
    Check(GamepadJustPressed(gbSouth, 2) and not GamepadJustPressed(gbSouth, 1),
      'a button is the second player''s alone');
    Check(BindingHeld(qbJump, nil, 2) and not BindingHeld(qbJump, nil, 1), 'the pad jumps the second player');
    Controllers[0].Pressed[gbSouth] := False;
    UpdateGamepad(2);

    { Four players, three pads: the gamepad players take them in order }
    SetVirtualPadCount(3);
    SplitPlayerCount := 4;
    Check((PlayerController(1) = nil) and (PlayerController(2) = Controllers[0]) and
      (PlayerController(3) = Controllers[1]) and (PlayerController(4) = Controllers[2]),
      'four players: pads 1, 2 and 3 for players 2, 3 and 4');
    Check(PadPlayer(2) = 4, 'the third pad is player 4''s');
    { Two players, three pads: the first is the keyboard player's, one is free }
    SplitPlayerCount := 2;
    Check((PlayerController(1) = Controllers[0]) and (PlayerController(2) = Controllers[1]) and
      (PadPlayer(2) = 0), 'two players, three pads: the third is free (it joins with Start)');
    SetVirtualPadCount(1);

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

{ Random maps: the same seed gives the same bytes, the map loads, every
  room is reachable on the grid and the exit by walking the player hull,
  and the entities stand in open space }
procedure TestRandomMap;
const
  Seeds: array[0..4] of LongWord = (1, 7, 42, 1234, 99999);
var
  SeedIdx, I, D, Head, Steps: Integer;
  Seed: LongWord;
  Donor, A, B, LitA, LitB: TMemoryStream;
  InfoA, InfoB: TRandomMapInfo;
  Bsp: TQuakeBsp;
  Ent, ExitEnt, Start: TQuakeEntity;
  CName: String;
  Hull, Contents: Integer;
  T: TQuakeTrace;
  Queue: array of TVector3;
  Seen: specialize TDictionary<Int64, Boolean>;
  P, Up, Moved, Down: TVector3;
  ExitReached: Boolean;
  FirstBytes: TBytes;
const
  DX: array[0..3] of Single = (32, -32, 0, 0);
  DY: array[0..3] of Single = (0, 0, 32, -32);

  function Key(const V: TVector3): Int64;
  begin
    Result := (Int64(Round(V.X / 16) + 10000) shl 32) or (Int64(Round(V.Y / 16) + 10000) shl 16) or
      (Round(V.Z / 8) + 10000);
  end;

begin
  StartTest('Random maps');
  Donor := Pak.GetStream('maps/start.bsp');
  Seen := specialize TDictionary<Int64, Boolean>.Create;
  try
    Check(Donor <> nil, 'the shareware start.bsp gives the textures');
    for SeedIdx := 0 to High(Seeds) do
    begin
      Seed := Seeds[SeedIdx];
      A := BuildRandomMap(Seed, Donor, LitA, InfoA);
      B := BuildRandomMap(Seed, Donor, LitB, InfoB);
      try
        Check((A.Size = B.Size) and CompareMem(A.Memory, B.Memory, A.Size),
          Format('seed %d: the same bytes twice', [Seed]));
        Check((LitA.Size = LitB.Size) and CompareMem(LitA.Memory, LitB.Memory, LitA.Size),
          Format('seed %d: the same .lit twice', [Seed]));
        Check(InfoA.Rooms >= 3, Format('seed %d: %d rooms', [Seed, InfoA.Rooms]));
        CheckEquals(InfoA.Rooms, InfoA.ReachableRooms, Format('seed %d: rooms reachable on the grid', [Seed]));
        Check(InfoA.Monsters > 0, Format('seed %d: monsters', [Seed]));
        Check(InfoA.Faces > 50, Format('seed %d: %d faces', [Seed, InfoA.Faces]));
        if SeedIdx = 0 then
        begin
          SetLength(FirstBytes, A.Size);
          Move(A.Memory^, FirstBytes[0], A.Size);
        end else
          Check((A.Size <> Length(FirstBytes)) or not CompareMem(A.Memory, @FirstBytes[0], A.Size),
            Format('seed %d differs from seed %d', [Seed, Seeds[0]]));
      finally
        A.Free;
        B.Free;
        LitA.Free;
        LitB.Free;
      end;

      { Through the pak, like a warp or a changelevel }
      Check(Pak.FileExists('maps/' + RandomMapName(Seed) + '.bsp'), Format('seed %d: in the pak', [Seed]));
      Bsp := TQuakeBsp.Create;
      try
        Check(Bsp.LoadFromPak('maps/' + RandomMapName(Seed) + '.bsp'), Format('seed %d: loads', [Seed]));
        Check(Bsp.LitData <> nil, Format('seed %d: colored lightmaps', [Seed]));
        CheckEquals(2, Bsp.ModelCount, Format('seed %d: the world and the exit trigger', [Seed]));
        Start := Bsp.FindEntity('info_player_start');
        ExitEnt := Bsp.FindEntity('trigger_changelevel');
        Check((Start <> nil) and (ExitEnt <> nil), Format('seed %d: a start and an exit', [Seed]));
        if (Start = nil) or (ExitEnt = nil) or (Bsp.ModelCount < 2) then
          Continue;
        CheckEqualsStr(RandomMapName(Seed + 1), ExitEnt.GetField('map'), 'the exit leads to the next seed');
        CheckEqualsStr('*1', ExitEnt.Model, 'the exit is model 1');

        { The player stands on the floor at the start }
        Check(Bsp.HullPointContents(1, Bsp.Models[0].HeadNodes[1], Start.Origin) = CONTENTS_EMPTY,
          Format('seed %d: the start is open for the player hull', [Seed]));
        T := Bsp.TraceHull(1, 0, TVector3.Zero, Start.Origin + Vector3(0, 0, 1), Start.Origin - Vector3(0, 0, 64));
        Check(not T.StartSolid and (T.Fraction < 1) and (Abs(T.EndPos.Z - Start.Origin.Z) < 2),
          Format('seed %d: the floor is under the start (%.1f)', [Seed, T.EndPos.Z]));
        CheckEquals(CONTENTS_SOLID, Bsp.PointContents(Vector3(5000, 0, 0)), 'far outside is solid');

        { Monsters in open space for their hull, items above the floor }
        for Ent in Bsp.Entities do
        begin
          CName := Ent.ClassName;
          if Pos('monster_', CName) = 1 then
          begin
            if (CName = 'monster_ogre') or (CName = 'monster_demon1') or (CName = 'monster_shambler') or
               (CName = 'monster_shalrath') then
              Hull := 2
            else
              Hull := 1;
            Contents := Bsp.HullPointContents(Hull, Bsp.Models[0].HeadNodes[Hull], Ent.Origin);
            Check(Contents = CONTENTS_EMPTY, Format('seed %d: %s at %s is open (%d)',
              [Seed, CName, Ent.Origin.ToString, Contents]));
          end else
          if (Pos('item_', CName) = 1) or (Pos('weapon_', CName) = 1) then
            Check(Bsp.PointContents(Ent.Origin + Vector3(16, 16, 8)) = CONTENTS_EMPTY,
              Format('seed %d: %s at %s is open', [Seed, CName, Ent.Origin.ToString]));
        end;

        { Walk the player hull from the start in 32 unit steps, stepping up
          18 units and falling down, until the exit box is reached }
        Seen.Clear;
        Queue := nil;
        SetLength(Queue, 1);
        Queue[0] := Start.Origin;
        Seen.Add(Key(Start.Origin), True);
        Head := 0;
        Steps := 0;
        ExitReached := False;
        while (Head < Length(Queue)) and not ExitReached and (Steps < 20000) do
        begin
          P := Queue[Head];
          Inc(Head);
          Inc(Steps);
          if (P.X + 16 > Bsp.Models[1].Mins.X) and (P.X - 16 < Bsp.Models[1].Maxs.X) and
             (P.Y + 16 > Bsp.Models[1].Mins.Y) and (P.Y - 16 < Bsp.Models[1].Maxs.Y) and
             (P.Z + 32 > Bsp.Models[1].Mins.Z) and (P.Z - 24 < Bsp.Models[1].Maxs.Z) then
            ExitReached := True;
          for D := 0 to 3 do
          begin
            Up := P + Vector3(0, 0, 18);
            T := Bsp.TraceHull(1, 0, TVector3.Zero, P, Up);
            Up := T.EndPos;
            T := Bsp.TraceHull(1, 0, TVector3.Zero, Up, Up + Vector3(DX[D], DY[D], 0));
            if T.Fraction < 1 then
              Continue;
            Moved := T.EndPos;
            T := Bsp.TraceHull(1, 0, TVector3.Zero, Moved, Moved - Vector3(0, 0, 80));
            if T.StartSolid or (T.Fraction >= 1) then
              Continue;
            Down := T.EndPos;
            if Seen.ContainsKey(Key(Down)) then
              Continue;
            Seen.Add(Key(Down), True);
            SetLength(Queue, Length(Queue) + 1);
            Queue[High(Queue)] := Down;
          end;
        end;
        Check(ExitReached, Format('seed %d: the exit is reached walking the player hull (%d spots)',
          [Seed, Length(Queue)]));
      finally
        Bsp.Free;
      end;
    end;

    { No textures to take: generated ones }
    A := BuildRandomMap(5, nil, LitA, InfoA);
    try
      Bsp := TQuakeBsp.Create;
      try
        Check(Bsp.LoadFromStream(A, 'maps/random5.bsp'), 'a map with generated textures loads');
        Check(Pos('rnd_', InfoA.Textures) = 1, 'generated textures: ' + InfoA.Textures);
      finally
        Bsp.Free;
      end;
    finally
      A.Free;
      LitA.Free;
    end;

    Check(ParseRandomMapName('random42', Seed) and (Seed = 42), 'random42 is seed 42');
    Check(not ParseRandomMapName('randomx', Seed), 'randomx is no random map');
    Check(not ParseRandomMapName('e1m1', Seed), 'e1m1 is no random map');
    Check(not Pak.FileExists('maps/random.bsp'), 'random.bsp without a seed does not exist');
  finally
    Seen.Free;
    Donor.Free;
  end;
end;

{ Captions: the table, the direction hint, merging repeats, the flash scale }
procedure TestCaptions;
var
  C: TQuakeCaptions;
  Lines: TStringArray;
begin
  StartTest('Captions');
  CheckEqualsStr('Ogre wakes', SoundCaption('sound/ogre/ogwake.wav'), 'a monster sight sound');
  CheckEqualsStr('Door moves', SoundCaption('sound/doors/drclos4.wav'), 'any door sound');
  CheckEqualsStr('Secret found', SoundCaption('misc/secret.wav'), 'a path without sound/');
  CheckEqualsStr('', SoundCaption('sound/weapons/guncock.wav'), 'the player''s shotgun has none');
  CheckEqualsStr('', SoundCaption('sound/player/pain1.wav'), 'the player''s pain has none');

  { The view at the origin looking along -Z (Quake +Y): +X is right }
  Check(CaptionDirection(TVector3.Zero, Vector3(0, 0, -1), Vector3(0, 0, -500)) = cdAhead, 'ahead');
  Check(CaptionDirection(TVector3.Zero, Vector3(0, 0, -1), Vector3(0, 0, 500)) = cdBehind, 'behind');
  Check(CaptionDirection(TVector3.Zero, Vector3(0, 0, -1), Vector3(500, 0, 0)) = cdRight, 'right');
  Check(CaptionDirection(TVector3.Zero, Vector3(0, 0, -1), Vector3(-500, 100, 0)) = cdLeft, 'left (height ignored)');
  Check(CaptionDirection(TVector3.Zero, Vector3(1, 0, 0), Vector3(0, 0, 500)) = cdRight,
    'looking along +X, +Z is on the right');
  Check(CaptionDirection(TVector3.Zero, Vector3(0, 0, -1), Vector3(10, 0, 20)) = cdNone, 'too close for a hint');

  C := TQuakeCaptions.Create;
  try
    C.SetListener(TVector3.Zero, Vector3(0, 0, -1));
    C.Add('sound/weapons/guncock.wav', False, TVector3.Zero);
    CheckEquals(0, C.Count, 'no caption for an uncaptioned sound');
    C.Add('sound/ogre/ogwake.wav', True, Vector3(-400, 0, 0));
    C.Add('sound/doors/doormv1.wav', True, Vector3(0, 0, -400));
    C.Add('sound/doors/drclos4.wav', True, Vector3(0, 0, -400));
    CheckEquals(2, C.Count, 'a door''s two sounds are one caption');
    Lines := C.Text.Split([LineEnding]);
    CheckEquals(2, Length(Lines), 'two lines');
    if Length(Lines) = 2 then
    begin
      CheckEqualsStr('< Ogre wakes', Lines[0], 'left hint');
      CheckEqualsStr('^ Door moves ^', Lines[1], 'ahead hint');
    end;
    C.Add('sound/items/armor1.wav', False, TVector3.Zero);
    C.Add('sound/weapons/pkup.wav', False, TVector3.Zero);
    C.Add('sound/weapons/lock4.wav', False, TVector3.Zero);
    CheckEquals(MaxCaptions, C.Count, 'at most MaxCaptions');
    Check(Pos('Ogre', C.Text) = 0, 'the oldest went first');
    C.Update(CaptionDuration + 0.1);
    CheckEquals(0, C.Count, 'captions go away');
  finally
    C.Free;
  end;

  ReducedFlashes := False;
  CheckNear(1, FlashScale, 1e-6, 'full flashes');
  ReducedFlashes := True;
  Check((FlashScale < 0.5) and (FlashLimit <= 50), 'reduced flashes');
  ReducedFlashes := False;
end;

{ Map browser: SHA-256 against the FIPS 180-2 vectors, zip paths moved by
  a release's mapping, and the bundled catalog }
procedure TestMapBrowser(const CatalogFile: String);
var
  S: AnsiString;
  P: String;
  B: TQuakeMapBrowser;
  I: Integer;
  List: specialize TArray<Integer>;
  Sorted: Boolean;
begin
  StartTest('Map browser');
  S := '';
  CheckEqualsStr('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855', Sha256Hex(PChar(S), 0),
    'SHA-256 of nothing');
  S := 'abc';
  CheckEqualsStr('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad', Sha256Hex(PChar(S), 3),
    'SHA-256 of abc');
  S := 'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq';
  CheckEqualsStr('248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
    Sha256Hex(PChar(S), Length(S)), 'SHA-256 of 56 bytes (two padding blocks)');
  S := StringOfChar('a', 1000000);
  CheckEqualsStr('cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
    Sha256Hex(PChar(S), Length(S)), 'SHA-256 of a million a');

  Check(MapArchivePath('tofaz/>id1/maps/', 'tofaz/tofaz.bsp', P) and (P = 'maps/tofaz.bsp'), 'a folder to maps/');
  Check(MapArchivePath('>id1/maps/', 'Digs08.BSP', P) and (P = 'maps/digs08.bsp'), 'the zip root to maps/, lowercase');
  Check(MapArchivePath('tntmap01/>;tntmap01/tntmap01.txt>id1/maps/tntmap01.txt',
    'tntmap01/id1/maps/snartroom.bsp', P) and (P = 'maps/snartroom.bsp'), 'a folder holding id1/');
  Check(MapArchivePath('tntmap01/>;tntmap01/tntmap01.txt>id1/maps/tntmap01.txt', 'tntmap01/tntmap01.txt', P) and
    (P = 'maps/tntmap01.txt'), 'the longest prefix wins');
  Check(not MapArchivePath('tntmap01/>', 'tntmap01/Extra files/x.map', P), 'a path outside id1 is left out');
  Check(not MapArchivePath('xl2/>id1/maps/', 'other/x.bsp', P), 'a path no prefix matches is left out');
  Check(MapArchivePath('>quoth/', 'pak1.pak', P, 'quoth') and (P = 'pak1.pak'), 'a mod''s zip root to its directory');
  Check(MapArchivePath('qescape/>quoth/maps/', 'qescape/Escape.bsp', P, 'quoth') and (P = 'maps/escape.bsp'),
    'a map for a mod to the mod''s maps/');
  Check(not MapArchivePath('>quoth/', 'pak0.pak', P), 'a mod''s files are not in id1');

  MapCatalogOverride := CatalogFile;
  B := TQuakeMapBrowser.Create;
  try
    Check(B.Count > 1000, Format('the bundled catalog lists Quaddicted''s maps (%d)', [B.Count]));
    I := B.IndexOf('tofaz');
    Check(I >= 0, 'tofaz is in the catalog');
    if I >= 0 then
    begin
      CheckEqualsStr('85c31466dda028d264b89ce54d613dfd7383306db97dc2b94f95cfce2a8cb8dc', B[I].Sha256, 'its SHA-256');
      CheckEqualsStr('tofaz', B[I].StartMaps[0], 'its start map');
      CheckEqualsStr('tofaz/>id1/maps/', B[I].Mapping, 'its mapping');
      Check(Pos('Temple of Azathoth by YukiRaven (2017) 5.0/5', B.Describe(I)) = 1, 'its line: ' + B.Describe(I));
    end;
    I := B.IndexOf('tofaz');
    Check((I >= 0) and (B[I].GameDir = 'id1') and (Length(B[I].Needs) = 0) and not B.NeedsQuakeC(I),
      'an id1 map needs no mod');
    I := B.IndexOf('quoth2pt2full_2');
    Check((I >= 0) and (B[I].GameDir = 'quoth') and (Length(B[I].Paks) = 3) and (B[I].Paks[0] = 'pak0.pak') and
      B.NeedsQuakeC(I), 'Quoth is a mod in quoth/ with three paks');
    I := B.IndexOf('quothescape');
    Check((I >= 0) and (B[I].GameDir = 'quoth') and (Length(B[I].Needs) = 1) and
      (B[I].Needs[0] = 'quoth2pt2full_2') and (B[I].Mapping = '>quoth/maps/'), 'a Quoth map needs Quoth');
    if I >= 0 then
    begin
      Check(B.BytesToInstall(I) > B[I].Bytes, 'installing it counts the mod''s download too');
      Check(Pos('Quoth', B.NeedsText(I)) > 0, 'it names the mod it needs: ' + B.NeedsText(I));
      Check(not B.Ready(I), 'it is not ready before the downloads');
    end;
    List := B.Sorted(msRating);
    Sorted := Length(List) > 0;
    for I := 1 to High(List) do
      if B[List[I]].Rating > B[List[I - 1]].Rating then
        Sorted := False;
    Check(Sorted, 'sorted by rating, best first');
    List := B.Sorted(msNewest, 'temple of azathoth');
    Check((Length(List) >= 1) and (B[List[0]].Id = 'tofaz'), 'a filter finds a title');
  finally
    B.Free;
    MapCatalogOverride := '';
  end;
end;

{ A pak in memory with one file }
function MakeTestPak(const Path, Content: AnsiString): TMemoryStream;
var
  Name: array[0..55] of AnsiChar;
  V: LongInt;
begin
  Result := TMemoryStream.Create;
  Result.WriteBuffer(AnsiString('PACK')[1], 4);
  V := 12 + Length(Content);
  Result.WriteBuffer(V, 4);
  V := 64;
  Result.WriteBuffer(V, 4);
  Result.WriteBuffer(Content[1], Length(Content));
  FillChar(Name, SizeOf(Name), 0);
  Move(Path[1], Name[0], Length(Path));
  Result.WriteBuffer(Name, SizeOf(Name));
  V := 12;
  Result.WriteBuffer(V, 4);
  V := Length(Content);
  Result.WriteBuffer(V, 4);
  Result.Position := 0;
end;

{ Writes a zip of the files (Names[i], Datas[i]), deflated where Deflate[i] }
procedure WriteTestZip(const FileName: String; const Names: array of AnsiString;
  const Datas: array of AnsiString; const Deflate: array of Boolean);
var
  Zip, Central, PackedData: TMemoryStream;
  Z: TCompressionStream;
  I: Integer;
  Offsets: array of LongWord;
  Sizes: array of LongWord;
  Methods: array of Word;
  W: Word;
  L: LongWord;

  procedure W16(const S: TStream; const V: Word);
  begin
    S.WriteBuffer(V, 2);
  end;

  procedure W32(const S: TStream; const V: LongWord);
  begin
    S.WriteBuffer(V, 4);
  end;

begin
  Zip := TMemoryStream.Create;
  Central := TMemoryStream.Create;
  try
    SetLength(Offsets, Length(Names));
    SetLength(Sizes, Length(Names));
    SetLength(Methods, Length(Names));
    for I := 0 to High(Names) do
    begin
      PackedData := TMemoryStream.Create;
      try
        if Deflate[I] then
        begin
          Z := TCompressionStream.Create(clDefault, PackedData, True);
          try
            Z.WriteBuffer(Datas[I][1], Length(Datas[I]));
          finally
            Z.Free;
          end;
          Methods[I] := 8;
        end else
        begin
          PackedData.WriteBuffer(Datas[I][1], Length(Datas[I]));
          Methods[I] := 0;
        end;
        Offsets[I] := Zip.Position;
        Sizes[I] := PackedData.Size;
        W32(Zip, $04034b50); W16(Zip, 20); W16(Zip, 0); W16(Zip, Methods[I]); W16(Zip, 0); W16(Zip, 0);
        W32(Zip, 0); W32(Zip, Sizes[I]); W32(Zip, Length(Datas[I]));
        W16(Zip, Length(Names[I])); W16(Zip, 0);
        Zip.WriteBuffer(Names[I][1], Length(Names[I]));
        PackedData.Position := 0;
        Zip.CopyFrom(PackedData, PackedData.Size);
      finally
        PackedData.Free;
      end;
      W32(Central, $02014b50); W16(Central, 20); W16(Central, 20); W16(Central, 0); W16(Central, Methods[I]);
      W16(Central, 0); W16(Central, 0); W32(Central, 0); W32(Central, Sizes[I]); W32(Central, Length(Datas[I]));
      W16(Central, Length(Names[I])); W16(Central, 0); W16(Central, 0); W16(Central, 0); W16(Central, 0);
      W32(Central, 0); W32(Central, Offsets[I]);
      Central.WriteBuffer(Names[I][1], Length(Names[I]));
    end;
    L := Zip.Position;
    Central.Position := 0;
    Zip.CopyFrom(Central, Central.Size);
    W := Length(Names);
    W32(Zip, $06054b50); W16(Zip, 0); W16(Zip, 0); W16(Zip, W); W16(Zip, W);
    W32(Zip, Central.Size); W32(Zip, L); W16(Zip, 0);
    Zip.SaveToFile(FileName);
  finally
    Zip.Free;
    Central.Free;
  end;
end;

function PakText(const P: TQuakePak; const Path: String): AnsiString;
var
  S: TMemoryStream;
begin
  Result := '';
  S := P.GetStream(Path);
  if S = nil then
    Exit('<none>');
  try
    SetLength(Result, S.Size);
    if S.Size > 0 then
      S.ReadBuffer(Result[1], S.Size);
  finally
    S.Free;
  end;
end;

{ Archives read from disk when a file is asked for, a pak inside a zip
  (stored: in place, deflated: unpacked to a file once), unmounting }
procedure TestDiskArchives;
var
  Dir, ZipFile, Cache: String;
  P: TQuakePak;
  Inner0, Inner1: TMemoryStream;
  S0, S1, Big: AnsiString;
  Data: Pointer;
  Size: Cardinal;
begin
  StartTest('Archives on disk and unmounting');
  Dir := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'quaketests_disk' + PathDelim;
  ForceDirectories(Dir);
  ZipFile := Dir + 'test.zip';
  Cache := Dir + 'test_pak1.pak';
  DeleteFile(Cache);
  Inner0 := MakeTestPak('maps/inner0.bsp', 'INNER ZERO');
  Inner1 := MakeTestPak('maps/inner1.bsp', 'INNER ONE');
  try
    SetLength(S0, Inner0.Size);
    Inner0.ReadBuffer(S0[1], Inner0.Size);
    SetLength(S1, Inner1.Size);
    Inner1.ReadBuffer(S1[1], Inner1.Size);
  finally
    Inner0.Free;
    Inner1.Free;
  end;
  Big := DupeString('deflate me ', 500);
  WriteTestZip(ZipFile, ['readme.txt', 'progs/x.mdl', 'pak0.pak', 'pak1.pak'], ['stored text', Big, S0, S1],
    [False, True, False, True]);

  P := TQuakePak.Create;
  try
    P.AddPakStream('base', MakeTestPak('progs/x.mdl', 'BASE'));
    CheckEqualsStr('BASE', PakText(P, 'progs/x.mdl'), 'the base pak''s file');
    CheckEqualsStr('', P.VariantTag('progs/x.mdl'), 'a file of the start has no tag');
    CheckEquals(0, P.DiskArchives, 'a pak in memory');
    P.MountTag := 'm1';
    Check(P.AddPk3(ZipFile), 'the zip mounts');
    CheckEquals(1, P.DiskArchives, 'the zip is read from disk');
    CheckEqualsStr('stored text', PakText(P, 'readme.txt'), 'a stored file of the zip');
    Check(PakText(P, 'progs/x.mdl') = Big, 'a deflated file of the zip replaces the base one');
    CheckEqualsStr('m1', P.VariantTag('progs/x.mdl'), 'its tag is the mount''s');
    CheckEqualsStr('@m1/progs/x.mdl', P.VariantPath('progs/x.mdl'), 'its cache path');
    Check(PakText(P, '@m1/progs/x.mdl') = Big, 'the cache path reads the file');
    Check(P.AddPakFromArchive('m1:pak0.pak', 'pak0.pak', Dir + 'test_pak0.pak'), 'the stored pak mounts');
    Check(not FileExists(Dir + 'test_pak0.pak'), 'a stored pak is read in place, not unpacked');
    CheckEqualsStr('INNER ZERO', PakText(P, 'maps/inner0.bsp'), 'a file of the stored pak');
    Check(P.AddPakFromArchive('m1:pak1.pak', 'pak1.pak', Cache), 'the deflated pak mounts');
    Check(FileExists(Cache), 'a deflated pak is unpacked to its file');
    CheckEqualsStr('INNER ONE', PakText(P, 'maps/inner1.bsp'), 'a file of the deflated pak');
    CheckEquals(3, P.DiskArchives, 'the zip, the window into it and the unpacked pak are read from disk');
    Data := P.GetData('maps/inner0.bsp', Size);
    Check((Data <> nil) and (Size = 10) and (CompareByte(Data^, AnsiString('INNER ZERO')[1], 10) = 0),
      'GetData of a pak read from disk');
    Check(P.MemoryBytes < 1000, Format('only the base pak and that file in memory (%d bytes)', [P.MemoryBytes]));
    P.MountTag := '';
    CheckEquals(3, P.Unmount('m1'), 'the three archives unmount');
    CheckEqualsStr('BASE', PakText(P, 'progs/x.mdl'), 'the base file comes back');
    CheckEqualsStr('', P.VariantTag('progs/x.mdl'), 'with no tag');
    Check(not P.FileExists('readme.txt') and not P.FileExists('maps/inner0.bsp') and
      not P.FileExists('maps/inner1.bsp'), 'the mount''s files are gone');
    CheckEquals(0, P.DiskArchives, 'no archive read from disk is left');
    CheckEquals(0, P.Unmount('m1'), 'unmounting again does nothing');
    { Mounting again uses the unpacked pak }
    P.MountTag := 'm1';
    Check(P.AddPk3(ZipFile) and P.AddPakFromArchive('m1:pak1.pak', 'pak1.pak', Cache), 'mounted again');
    CheckEqualsStr('INNER ONE', PakText(P, 'maps/inner1.bsp'), 'the unpacked pak again');
    P.MountTag := '';
  finally
    P.Free;
  end;
  DeleteFile(Cache);
  DeleteFile(ZipFile);
end;

type
  { Accepts every client of the loopback test as edict 1 }
  TLoopbackAccept = class
    function Connect(const Client: Integer): Integer;
    function Info: String;
  end;

function TLoopbackAccept.Info: String;
begin
  Result := 'e1m1'#9'the Slipgate Complex'#9'3'#9'8'#9'coop';
end;

function TLoopbackAccept.Connect(const Client: Integer): Integer;
begin
  Result := 1;
end;

{ Loopback sockets (the web build's listen server): packets between
  sockets of this process, and a client joining a server over them }
{ LAN discovery over loopback sockets: a server on one of the queried
  ports answers, the search lists it once with what it plays }
procedure TestLanDiscovery;
var
  Server: TQuakeNetServer;
  Answer: TLoopbackAccept;
  Search: TQuakeLanDiscovery;
  I: Integer;
begin
  StartTest('LAN discovery (loopback)');
  NetLoopback := True;
  Answer := TLoopbackAccept.Create;
  Server := TQuakeNetServer.Create(DefaultNetPort + 2);
  Search := TQuakeLanDiscovery.Create;
  try
    Server.OnInfo := @Answer.Info;
    Search.Start;
    Check(Search.Searching, 'the search runs');
    for I := 1 to 20 do
    begin
      Server.Update(0.05);
      Search.Update(0.05);
    end;
    CheckEquals(1, Search.Count, 'one game found');
    if Search.Count = 1 then
    begin
      CheckEquals(DefaultNetPort + 2, Search[0].Port, 'its port');
      CheckEqualsStr('127.0.0.1', Search[0].Host, 'its host');
      CheckEqualsStr('e1m1', Search[0].Map, 'its map');
      CheckEqualsStr('the Slipgate Complex', Search[0].Title, 'its title');
      CheckEquals(3, Search[0].Players, 'its players');
      CheckEquals(8, Search[0].MaxPlayers, 'its maximum');
      CheckEqualsStr('coop', Search[0].Mode, 'its mode');
      CheckEqualsStr('127.0.0.1:26002: e1m1 (the Slipgate Complex), 3/8, coop', Search.Describe(0), 'its line');
    end;
    for I := 1 to 60 do
    begin
      Server.Update(0.05);
      Search.Update(0.05);
    end;
    Check(not Search.Searching, 'the search ends');
    CheckEquals(1, Search.Count, 'the answers to the repeated queries count once');
  finally
    Search.Free;
    Server.Free;
    Answer.Free;
    NetLoopback := False;
  end;
end;

procedure TestLoopback;
var
  A, B: TQuakeNetSocket;
  Addr: TInetSockAddr;
  Data: TNetBytes;
  Port: Word;
  Server: TQuakeNetServer;
  Client: TQuakeNetClient;
  Accept: TLoopbackAccept;
  I: Integer;
begin
  StartTest('Loopback sockets');
  A := TQuakeNetSocket.CreateLoopback(26500);
  B := TQuakeNetSocket.CreateLoopback(0);
  try
    Check(A.Valid and B.Valid, 'two loopback sockets');
    Check(TQuakeNetSocket.LoopbackListening(26500), 'the first listens on its port');
    Data := TNetBytes.Create(1, 2, 3);
    Check(B.Send(TQuakeNetSocket.LoopbackAddress(26500), Data), 'a packet to the port');
    Check(not B.Send(TQuakeNetSocket.LoopbackAddress(26501), Data), 'no socket on another port');
    Check(A.Receive(Addr, Data) and (Length(Data) = 3) and (Data[2] = 3), 'it arrives');
    Check(TQuakeNetSocket.IsLoopbackAddress(Addr, Port) and (Port >= FirstLoopbackPort),
      Format('from the sender''s port %d', [Port]));
    CheckEqualsStr(Format('127.0.0.1:%d', [Port]), TQuakeNetSocket.AddressToString(Addr), 'shown as this machine');
    Check(A.Send(Addr, Data) and B.Receive(Addr, Data), 'the answer goes back');
    Check(not A.Receive(Addr, Data), 'nothing more');
  finally
    A.Free;
    B.Free;
  end;
  Check(not TQuakeNetSocket.LoopbackListening(26500), 'a freed socket stops listening');

  NetLoopback := True;
  Accept := TLoopbackAccept.Create;
  Server := TQuakeNetServer.Create(26501);
  Client := TQuakeNetClient.Create;
  try
    Server.OnConnect := @Accept.Connect;
    Check(Server.Valid and TQuakeNetSocket.LoopbackListening(26501), 'a server on loopback');
    Check(Client.Connect('127.0.0.1', 26501), 'a client connects');
    for I := 1 to 20 do
    begin
      Client.Update(0.05);
      Server.Update(0.05);
    end;
    Check(Client.State = csConnected, 'the client is connected over the loopback');
    Check((Server.ClientCount = 1) and (Copy(Server.ClientAddress(1), 1, 10) = '127.0.0.1:'),
      'the server has it as a client of this machine: ' + Server.ClientAddress(1));
  finally
    Client.Free;
    Server.Free;
    Accept.Free;
    NetLoopback := False;
  end;
end;

{ Localization: the .po reader, the menu item rule and every translation
  against the template (every text, the same format specifiers) }
procedure TestTranslate(const LangDir: String);
const
  Sample = '# a comment' + LineEnding +
    'msgid ""' + LineEnding + 'msgstr ""' + LineEnding + '"Language: xx\n"' + LineEnding + LineEnding +
    'msgid "Options"' + LineEnding + 'msgstr "Optionen"' + LineEnding + LineEnding +
    'msgid "Say \"hi\""' + LineEnding + 'msgstr ""' + LineEnding + '"Sag \"hallo\""' + LineEnding + LineEnding +
    'msgid "Untranslated"' + LineEnding + 'msgstr ""' + LineEnding;
var
  D, Pot, Po: TTranslationDictionary;
  Header: TStringList;
  Text, Id, Code: String;
  L: TLanguageInfo;
  Missing, Wrong, I: Integer;
  Codes: TStringList;

  function ReadFile(const Name: String): String;
  var
    F: TStringList;
  begin
    F := TStringList.Create;
    try
      F.LoadFromFile(Name);
      Result := F.Text;
    finally
      F.Free;
    end;
  end;

  function Specifiers(const S: String): String;
  var
    I: Integer;
  begin
    Result := '';
    I := 1;
    while I <= Length(S) do
    begin
      if S[I] = '%' then
      begin
        Inc(I);
        while (I <= Length(S)) and (S[I] in ['0'..'9', '.', '-']) do
          Inc(I);
        if I <= Length(S) then
          Result := Result + S[I];
      end;
      Inc(I);
    end;
  end;

begin
  StartTest('Translations');
  D := TTranslationDictionary.Create;
  Header := TStringList.Create;
  try
    Check(ParsePo(Sample, D, Header) = 2, 'two translated entries (the header and an empty one left out)');
    Check(D.TryGetValue('Options', Text) and (Text = 'Optionen'), 'an entry');
    Check(D.TryGetValue('Say "hi"', Text) and (Text = 'Sag "hallo"'), 'escaped quotes and a continued msgstr');
    CheckEqualsStr('xx', Header.Values['Language'], 'the header');
  finally
    D.Free;
    Header.Free;
  end;

  Pot := TTranslationDictionary.Create;
  Po := TTranslationDictionary.Create;
  try
    { The template has no msgstr: read the msgids by giving each one }
    Text := StringReplace(ReadFile(LangDir + 'castle-quake.pot'), 'msgstr ""', 'msgstr "x"', [rfReplaceAll]);
    ParsePo(Text, Pot);
    Check(Pot.Count > 200, Format('the template lists the texts (%d)', [Pot.Count]));
    { Every language languages.txt lists ("<code> <name>" lines) }
    Codes := TStringList.Create;
    try
      Codes.Text := ReadFile(LangDir + 'languages.txt');
      for I := Codes.Count - 1 downto 0 do
        if (Trim(Codes[I]) = '') or (Trim(Codes[I])[1] = '#') then
          Codes.Delete(I)
        else
          Codes[I] := Copy(Trim(Codes[I]), 1, Pos(' ', Trim(Codes[I])) - 1);
      Check(Codes.Count >= 5, 'languages.txt lists the translations: ' + Codes.CommaText);
    for Code in Codes do
    begin
      Po.Clear;
      ParsePo(ReadFile(LangDir + Code + '.po'), Po);
      Missing := 0;
      Wrong := 0;
      for Id in Pot.Keys do
        if not Po.ContainsKey(Id) then
          Inc(Missing)
        else if Specifiers(Po[Id]) <> Specifiers(Id) then
          Inc(Wrong);
      Check((Missing = 0) and (Wrong = 0) and (Po.Count = Pot.Count),
        Format('%s.po translates all %d texts (%d missing, %d with other format specifiers, %d entries)',
        [Code, Pot.Count, Missing, Wrong, Po.Count]));
    end;
    finally
      Codes.Free;
    end;

    { The menu: whole items, "Label: value" and values in brackets }
    UseTranslation('de', ReadFile(LangDir + 'de.po'));
    CheckEqualsStr('de', CurrentLanguage, 'German in use');
    Check(Tr('Options') <> 'Options', 'a menu item translated: ' + Tr('Options'));
    CheckEqualsStr(Tr('Dynamic Shadows') + ': [' + Tr('ON') + ']', TrItem('Dynamic Shadows: [ON]'),
      'a label and its value');
    CheckEqualsStr(Tr('Field of View') + ': [90]', TrItem('Field of View: [90]'), 'a number stays');
    CheckEqualsStr(Tr('Language') + ': [' + Tr('Auto') + ': Deutsch]', TrItem('Language: [Auto: Deutsch]'),
      'a value inside brackets with a label');
    CheckEqualsStr('maps/e1m1.bsp', TrItem('maps/e1m1.bsp'), 'a map name stays');
    CheckEqualsStr('Not in the table', Tr('Not in the table'), 'an unknown text stays');
    Check(Pos('%d', Tr('KILLS: %d/%d   SECRETS: %d/%d   TIME: %02d:%02d')) > 0, 'the stats line keeps its numbers');
    UseTranslation('en', '');
    CheckEqualsStr('Options', Tr('Options'), 'English again');

    { The UI font has what the translations write: Romanian's comma-below
      letters (the engine's default font has none), Latin Extended-A }
    for Code in ['ș', 'ț', 'Ș', 'Ț', 'ă', 'Ă', 'â', 'î', 'ł', 'ő', 'ğ', 'é', 'ß'] do
      Check(Font_GameUi.Glyph(Ord(UTF8Decode(Code)[1]), False) <> nil, 'the UI font has ' + Code);
  finally
    Pot.Free;
    Po.Free;
  end;
end;

{ Savegame listing: the info the Load Game menu shows, the newest first }
procedure TestPlayerColors;
begin
  StartTest('Player colors');
  CheckEquals(5, TranslatePlayerColor(5, $4C), 'other indices stay');
  CheckEquals(0, TranslatePlayerColor(16, 0), 'colors 0 0: the shirt row 0');
  CheckEquals(64 + 3, TranslatePlayerColor(19, $4C), 'the shirt takes row 4');
  CheckEquals(192 + 15 - 3, TranslatePlayerColor(99, $4C), 'the pants take row 12, reversed');
  CheckEquals(208 + 15, TranslatePlayerColor(16, $D0), 'row 13 of the shirt is reversed');
  CheckEquals(96, TranslatePlayerColor(96, $D6), 'pants 6: row 96');
end;

procedure TestSaveList;
var
  D: TQuakeSaveData;
  Info: TSaveGameInfo;
  Saves: TSaveGameInfoArray;
  I, A, B: Integer;
begin
  StartTest('Save list');
  CheckEqualsStr('castle-config:/save_3.sav', SaveGameUrl('3'), 'the slot URL');
  CheckEqualsStr('castle-config:/save_quick.png', SaveThumbnailUrl('../'), 'unsafe characters dropped');
  for I := 1 to 2 do
  begin
    D := TQuakeSaveData.Create;
    try
      D.SetStr('map', 'e1m' + IntToStr(I));
      D.SetStr('saved', '2026-10-2' + IntToStr(I) + ' 10:00:00');
      D.SetInt('skill', 2);
      D.SetInt('stats.health', 50 + I);
      D.SetInt('stats.kills', I);
      D.SetInt('stats.totalkills', 23);
      D.SetFloat('stats.leveltime', 61.5);
      Check(D.SaveToUrl(SaveGameUrl('unittest' + IntToStr(I))), 'a savegame is written');
    finally
      D.Free;
    end;
  end;
  Check(ReadSaveGameInfo(SaveGameUrl('unittest1'), Info), 'its info is read');
  CheckEqualsStr('unittest1', Info.Slot, 'the slot from the file name');
  CheckEqualsStr('e1m1', Info.Map, 'the map');
  CheckEquals(51, Info.Health, 'the health');
  CheckEquals(2, Info.Skill, 'the skill');
  CheckNear(61.5, Info.LevelTime, 0.01, 'the level time');
  Check(not ReadSaveGameInfo(SaveGameUrl('nosuchslot'), Info), 'no info without a file');
  Saves := ListSaveGames;
  A := -1;
  B := -1;
  for I := 0 to High(Saves) do
    if Saves[I].Slot = 'unittest1' then
      A := I
    else if Saves[I].Slot = 'unittest2' then
      B := I;
  Check((A >= 0) and (B >= 0) and (B < A), 'both are listed, the newer one first');
  DeleteFile(UriToFilenameSafe(SaveGameUrl('unittest1')));
  DeleteFile(UriToFilenameSafe(SaveGameUrl('unittest2')));
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
  TestPadGlyphs;
  TestVideo;
  TestRandomMap;
  TestCaptions;
  TestSaveList;
  TestPlayerColors;
  TestLoopback;
  TestLanDiscovery;
  TestDiskArchives;
  TestTranslate(ExpandFileName(IncludeTrailingPathDelimiter(PaksDir) + '..' + PathDelim + 'lang') + PathDelim);
  TestMapBrowser(ExpandFileName(IncludeTrailingPathDelimiter(PaksDir) + '..' + PathDelim + 'quaddicted' +
    PathDelim + 'maps.txt'));

  WriteLn(Format('%d checks, %d failures', [Checks, Failures]));
  if Failures > 0 then
    Halt(1);
end.
