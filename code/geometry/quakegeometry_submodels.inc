{ Brush entities (doors, plats, buttons): their scenes and their moves.
  Included by quakegeometry.pas. }

constructor TQuakeSubmodel.Create;
begin
  inherited Create;
  Transform := TCastleTransform.Create(nil);
  Scene := TCastleScene.Create(nil);
  Scene.PreciseCollisions := True;
  Scene.Collides := True;
  Transform.Add(Scene);
  Transform.Name := ComponentName('submodel');
  State := smsClosed;
  Speed := 100.0;
  WaitTime := 3.0;
  StateTimer := 0;
end;

destructor TQuakeSubmodel.Destroy;
begin
  Transform.Free;
  inherited Destroy;
end;

procedure TQuakeSubmodel.Update(const SecondsPassed: Single);
var
  Delta: TVector3;
  Dist, Step: Single;
begin
  case State of
    smsOpening:
      begin
        Delta := TargetPos - Transform.Translation;
        Dist := Delta.Length;
        Step := Speed * SecondsPassed;
        if Step >= Dist then
        begin
          Transform.Translation := TargetPos;
          State := smsOpen;
          StateTimer := WaitTime;
        end else
          Transform.Translation := Transform.Translation + Delta.Normalize * Step;
      end;
    smsOpen:
      begin
        if WaitTime > 0 then
        begin
          StateTimer := StateTimer - SecondsPassed;
          if StateTimer <= 0 then
          begin
            State := smsClosing;
            TargetPos := ClosedPos;
          end;
        end;
      end;
    smsClosing:
      begin
        Delta := TargetPos - Transform.Translation;
        Dist := Delta.Length;
        Step := Speed * SecondsPassed;
        if Step >= Dist then
        begin
          Transform.Translation := TargetPos;
          State := smsClosed;
          StateTimer := 3.0;
        end else
          Transform.Translation := Transform.Translation + Delta.Normalize * Step;
      end;
    smsClosed:
      if IsAutoPlat then
      begin
        { plat_hit_top: go back down after a while }
        StateTimer := StateTimer - SecondsPassed;
        if StateTimer <= 0 then
        begin
          State := smsOpening;
          TargetPos := OpenPos;
        end;
      end;
  end;
end;

procedure TQuakeSubmodel.PlatTouched;
begin
  if not IsAutoPlat then
    Exit;
  case State of
    smsOpen:
      begin
        { At the bottom: go up }
        State := smsClosing;
        TargetPos := ClosedPos;
      end;
    smsClosed:
      StateTimer := Max(StateTimer, 1.0); { delay going down while ridden }
    else ;
  end;
end;

procedure TQuakeSubmodel.Trigger;
begin
  if State = smsClosed then
  begin
    State := smsOpening;
    TargetPos := OpenPos;
  end else
  if (State = smsOpen) and (WaitTime > 0) then
  begin
    StateTimer := WaitTime; { Reset open timer }
  end;
end;

procedure TQuakeGeometry.SetupSubmodels(const Parent: TCastleTransform);
var
  I: Integer;
  Ent: TQuakeEntity;
  MdlStr, CName: String;
  MdlIdx: Integer;
  Sub: TQuakeSubmodel;
  Mdl: TBSPModel;
  Root: TX3DRootNode;
  Batches: TQuakeGeomBatchDict;
  AngleVal, SpeedVal, WaitVal, LipVal: Single;
  Rad: Single;
  MoveV: TVector3;
  BoxSize: TVector3;
  Dist: Single;
  T0, T1: TTimerResult;
  BuildSeconds, LoadSeconds: Single;
begin
  BuildSeconds := 0;
  LoadSeconds := 0;
  for I := 0 to FBsp.Entities.Count - 1 do
  begin
    Ent := FBsp.Entities[I];
    MdlStr := Ent.Model;
    CName := LowerCase(Ent.ClassName);
    if EntityNotInSkill(Ent, Skill) then
      Continue;

    if (Length(MdlStr) >= 2) and (MdlStr[1] = '*') then
    begin
      MdlIdx := StrToIntDef(Copy(MdlStr, 2, Length(MdlStr)), -1);
      if (MdlIdx > 0) and (MdlIdx < FBsp.ModelCount) then
      begin
        Mdl := FBsp.Models[MdlIdx];
        Sub := TQuakeSubmodel.Create;
        Sub.ModelIndex := MdlIdx;
        Sub.EntityClassName := CName;
        Sub.Target := Ent.Target;
        Sub.TargetName := Ent.TargetName;
        Sub.Sounds := Ent.Sounds;
        { Named after the entity for the inspector: func_door_7 }
        Sub.Transform.Name := ComponentName(CName);
        Sub.Scene.Name := Sub.Transform.Name + '_scene';
        Sub.SpawnFlags := Ent.SpawnFlags;

        Sub.Mins := QuakeToCge(Mdl.Mins);
        Sub.Maxs := QuakeToCge(Mdl.Maxs);
        Sub.Origin := QuakeToCge(Mdl.Origin);

        SpeedVal := Ent.Speed;
        if SpeedVal <= 0 then SpeedVal := 100.0;
        Sub.Speed := SpeedVal;

        WaitVal := Ent.GetFloat('wait', 3.0);
        Sub.WaitTime := WaitVal;
        if CName = 'func_door' then
        begin
          if (Ent.SpawnFlags and 8) <> 0 then
            Sub.KeyNeeded := 1
          else if (Ent.SpawnFlags and 16) <> 0 then
            Sub.KeyNeeded := 2;
          { Key doors never close again (door spawn: if self.items, wait = -1) }
          if Sub.KeyNeeded <> 0 then
            Sub.WaitTime := -1;
        end;

        LipVal := Ent.GetFloat('lip', 8.0);
        AngleVal := Ent.Angle;

        { Movement direction based on angle and classname }
        if (CName = 'func_door') or (CName = 'func_door_secret') then
        begin
          BoxSize := Sub.Maxs - Sub.Mins;
          if AngleVal = -1 then { Up }
            MoveV := Vector3(0, 1, 0)
          else if AngleVal = -2 then { Down }
            MoveV := Vector3(0, -1, 0)
          else
          begin
            { Quake angles: 0 = East (+X), 90 = North (+Y in Quake, -Z in CGE) }
            Rad := DegToRad(AngleVal);
            MoveV := Vector3(Cos(Rad), 0, -Sin(Rad));
          end;

          { Movement distance matches bounding box size in movement axis minus lip }
          Dist := Abs(MoveV[0] * BoxSize[0]) + Abs(MoveV[1] * BoxSize[1]) + Abs(MoveV[2] * BoxSize[2]) - LipVal;
          if Dist < 16.0 then Dist := 64.0;

          Sub.ClosedPos := Vector3(0, 0, 0);
          Sub.OpenPos := MoveV * Dist;
          Sub.MoveDir := MoveV;
          { DOOR_START_OPEN: spawns moved, and "opens" back to its map position }
          if (CName = 'func_door') and ((Ent.SpawnFlags and 1) <> 0) then
          begin
            Sub.ClosedPos := MoveV * Dist;
            Sub.OpenPos := Vector3(0, 0, 0);
            Sub.Transform.Translation := Sub.ClosedPos;
          end;
        end else
        if CName = 'func_plat' then
        begin
          { Elevators move down by height of the platform }
          { func_plat default travel: its height minus 8 }
          Dist := Ent.GetFloat('height', Abs(Sub.Maxs[1] - Sub.Mins[1]) - 8.0);
          if Dist < 8 then
            Dist := 8;
          Sub.ClosedPos := Vector3(0, 0, 0);
          Sub.OpenPos := Vector3(0, -Dist, 0);
          Sub.MoveDir := Vector3(0, -1, 0);
          { Like Quake, plats without a targetname start at the bottom and
            rise when the player steps on them }
          if Sub.TargetName = '' then
          begin
            Sub.IsAutoPlat := True;
            Sub.Transform.Translation := Sub.OpenPos;
            Sub.State := smsOpen;
            Sub.WaitTime := -1;
          end;
        end else
        if CName = 'func_button' then
        begin
          Rad := DegToRad(AngleVal);
          MoveV := Vector3(Cos(Rad), 0, -Sin(Rad));
          Sub.ClosedPos := Vector3(0, 0, 0);
          Sub.OpenPos := MoveV * 4.0; { Button moves in slightly }
          Sub.MoveDir := MoveV;
          Sub.WaitTime := 1.0;
        end;

        Root := TX3DRootNode.Create;
        Batches := TQuakeGeomBatchDict.Create([doOwnsValues]);
        try
          T0 := Timer;
          BuildModelGeometry(MdlIdx, Root, Batches);
          T1 := Timer;
          Sub.Scene.Load(Root, True);
          BuildSeconds := BuildSeconds + TimerSeconds(T1, T0);
          LoadSeconds := LoadSeconds + TimerSeconds(Timer, T1);
        finally
          Batches.Free;
        end;

        Parent.Add(Sub.Transform);
        FSubmodels.Add(Sub);
      end;
    end;
  end;

  WritelnLog('QuakeGeometry', 'Configured %d interactive submodels (%.2f s building their shapes, %.2f s loading their scenes)',
    [FSubmodels.Count, BuildSeconds, LoadSeconds]);
end;

procedure TQuakeGeometry.CullSubmodels;
var
  Sub: TQuakeSubmodel;
begin
  for Sub in FSubmodels do
    if Sub.Transform.Exists then
      CullScene(Sub.Scene);
end;

function TQuakeGeometry.FindSubmodel(const AName: String): TQuakeSubmodel;
var
  Sub: TQuakeSubmodel;
  TargetNum: Integer;
begin
  Result := nil;
  if Length(AName) = 0 then
    Exit;

  if AName[1] = '*' then
  begin
    TargetNum := StrToIntDef(Copy(AName, 2, Length(AName)), -1);
    for Sub in FSubmodels do
      if Sub.ModelIndex = TargetNum then
        Exit(Sub);
  end else
  begin
    for Sub in FSubmodels do
      if SameText(Sub.TargetName, AName) then
        Exit(Sub);
  end;
end;
