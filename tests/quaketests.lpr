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
  CastleKeysMouse, CastleConfig,
  QuakePak, QuakePalette, QuakeBsp, QuakeProgs, QuakeSaveGame, QuakeDemo, GameInput;

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
  TestProgsVm;
  TestProgsStateRoundTrip;
  TestSaveData;
  TestDemoRoundTrip;
  TestBindings;

  WriteLn(Format('%d checks, %d failures', [Checks, Failures]));
  if Failures > 0 then
    Halt(1);
end.
