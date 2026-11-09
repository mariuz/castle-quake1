{ QuakeC extension builtins (DP / FTE numbers, like QuakeSpasm-Spiked's
  pr_ext.c): what a mod finds through checkextension, and the builtins
  declared "#0" that QuakeSpasm-Spiked binds by name. Included by
  quakeprogs.pas. }

const
  { The extensions checkextension says yes to: each one's builtins are
    here (or, like the fog and turning brush entities, done elsewhere) }
  SupportedExtensions: array[0..32] of String = (
    'FTE_ENT_SKIN_CONTENTS',
    'DP_SV_POINTPARTICLES', 'FTE_SV_POINTPARTICLES', 'DP_TE_PARTICLERAIN', 'DP_TE_PARTICLESNOW',
    'DP_QC_ASINACOSATANATAN2TAN', 'DP_QC_COPYENTITY', 'DP_QC_CVAR_STRING', 'DP_QC_EDICT_NUM',
    'DP_QC_ETOS', 'DP_QC_FINDCHAIN', 'DP_QC_FINDCHAINFLAGS', 'DP_QC_FINDCHAINFLOAT', 'DP_QC_FINDFLAGS',
    'DP_QC_FINDFLOAT', 'DP_QC_MINMAXBOUND', 'DP_QC_RANDOMVEC', 'DP_QC_SINCOSSQRTPOW', 'DP_QC_SPRINTF',
    'DP_QC_STRING_CASE_FUNCTIONS', 'DP_QC_STRREPLACE', 'DP_QC_TOKENIZEBYSEPARATOR', 'DP_QC_TRACEBOX',
    'DP_QC_VECTORVECTORS', 'DP_REGISTERCVAR', 'DP_GFX_FOG', 'DP_SV_ROTATINGBMODEL', 'DP_QC_LOG',
    'FRIK_FILE', 'FTE_STRINGS', 'KRIMZON_SV_PARSECLIENTCOMMAND', 'FTE_QC_CHECKPVS', 'DP_QC_NUM_FOR_EDICT');

  { name -> number, for builtins declared #0 and for builtin_find }
  ExtBuiltinNames: array[0..79] of record Name: String; Num: Integer; end = (
    (Name: 'sin'; Num: 60), (Name: 'cos'; Num: 61), (Name: 'sqrt'; Num: 62), (Name: 'etos'; Num: 65),
    (Name: 'stof'; Num: 81), (Name: 'tracebox'; Num: 90), (Name: 'randomvec'; Num: 91),
    (Name: 'registercvar'; Num: 93), (Name: 'min'; Num: 94), (Name: 'max'; Num: 95),
    (Name: 'bound'; Num: 96), (Name: 'pow'; Num: 97), (Name: 'findfloat'; Num: 98),
    (Name: 'findentity'; Num: 98), (Name: 'checkextension'; Num: 99), (Name: 'builtin_find'; Num: 100),
    (Name: 'checkbuiltin'; Num: 100), (Name: 'anglemod'; Num: 102),
    (Name: 'fopen'; Num: 110), (Name: 'fclose'; Num: 111), (Name: 'fgets'; Num: 112),
    (Name: 'fputs'; Num: 113), (Name: 'strlen'; Num: 114), (Name: 'strcat'; Num: 115),
    (Name: 'substring'; Num: 116), (Name: 'stov'; Num: 117), (Name: 'strzone'; Num: 118),
    (Name: 'strunzone'; Num: 119), (Name: 'bitshift'; Num: 218), (Name: 'strstrofs'; Num: 221),
    (Name: 'str2chr'; Num: 222), (Name: 'chr2str'; Num: 223), (Name: 'strconv'; Num: 224),
    (Name: 'strpad'; Num: 225), (Name: 'infoadd'; Num: 226), (Name: 'infoget'; Num: 227),
    (Name: 'strncmp'; Num: 228), (Name: 'strcasecmp'; Num: 229), (Name: 'strncasecmp'; Num: 230),
    (Name: 'checkpvs'; Num: 240), (Name: 'addstat'; Num: 232),
    (Name: 'particleeffectnum'; Num: 335), (Name: 'trailparticles'; Num: 336), (Name: 'pointparticles'; Num: 337),
    (Name: 'te_particlerain'; Num: 409), (Name: 'te_particlesnow'; Num: 410), (Name: 'copyentity'; Num: 400), (Name: 'findchain'; Num: 402),
    (Name: 'findchainfloat'; Num: 403), (Name: 'findchainentity'; Num: 403),
    (Name: 'vectorvectors'; Num: 432), (Name: 'clientcommand'; Num: 440), (Name: 'tokenize'; Num: 441),
    (Name: 'argv'; Num: 442), (Name: 'cvar_string'; Num: 448), (Name: 'findflags'; Num: 449),
    (Name: 'findchainflags'; Num: 450), (Name: 'edict_num'; Num: 459), (Name: 'asin'; Num: 471),
    (Name: 'acos'; Num: 472), (Name: 'atan'; Num: 473), (Name: 'atan2'; Num: 474),
    (Name: 'tan'; Num: 475), (Name: 'tokenizebyseparator'; Num: 479), (Name: 'strtolower'; Num: 480),
    (Name: 'strtoupper'; Num: 481), (Name: 'cvar_defstring'; Num: 482), (Name: 'strreplace'; Num: 484),
    (Name: 'strireplace'; Num: 485), (Name: 'num_for_edict'; Num: 512), (Name: 'tokenize_console'; Num: 514),
    (Name: 'log'; Num: 532), (Name: 'sprintf'; Num: 627), (Name: 'ftoi'; Num: 0), (Name: 'itof'; Num: 0),
    (Name: 'crossproduct'; Num: 0), (Name: 'strtrim'; Num: 0), (Name: 'argc'; Num: 0),
    (Name: 'min3'; Num: 94), (Name: 'max3'; Num: 95));

  { The names bound to builtins of no fixed number: their own slots }
  BuiltinFtoi = 900;
  BuiltinItof = 901;
  BuiltinCrossProduct = 902;
  BuiltinStrTrim = 903;
  BuiltinArgc = 904;

function ExtBuiltinNumber(const AName: String): Integer;
var
  I: Integer;
begin
  for I := 0 to High(ExtBuiltinNames) do
    if ExtBuiltinNames[I].Name = AName then
    begin
      Result := ExtBuiltinNames[I].Num;
      if Result = 0 then
      begin
        if AName = 'ftoi' then
          Result := BuiltinFtoi
        else if AName = 'itof' then
          Result := BuiltinItof
        else if AName = 'crossproduct' then
          Result := BuiltinCrossProduct
        else if AName = 'strtrim' then
          Result := BuiltinStrTrim
        else if AName = 'argc' then
          Result := BuiltinArgc;
      end;
      Exit;
    end;
  Result := 0;
end;

function IsSupportedExtension(const AName: String): Boolean;
var
  S: String;
begin
  for S in SupportedExtensions do
    if SameText(S, AName) then
      Exit(True);
  Result := False;
end;

procedure TQuakeProgs.RegisterExtBuiltins;
begin
  FBuiltins[60] := @PF_sin;
  FBuiltins[61] := @PF_cos;
  FBuiltins[62] := @PF_sqrt;
  FBuiltins[65] := @PF_etos;
  FBuiltins[81] := @PF_stof;
  FBuiltins[90] := @PF_tracebox;
  FBuiltins[91] := @PF_randomvec;
  FBuiltins[93] := @PF_registercvar;
  FBuiltins[94] := @PF_min;
  FBuiltins[95] := @PF_max;
  FBuiltins[96] := @PF_bound;
  FBuiltins[97] := @PF_pow;
  FBuiltins[98] := @PF_findfloat;
  FBuiltins[99] := @PF_checkextension;
  FBuiltins[100] := @PF_builtin_find;
  FBuiltins[102] := @PF_anglemod;
  FBuiltins[110] := @PF_fopen;
  FBuiltins[111] := @PF_fclose;
  FBuiltins[112] := @PF_fgets;
  FBuiltins[113] := @PF_fputs;
  FBuiltins[114] := @PF_strlen;
  FBuiltins[115] := @PF_strcat;
  FBuiltins[116] := @PF_substring;
  FBuiltins[117] := @PF_stov;
  FBuiltins[118] := @PF_strzone;
  FBuiltins[119] := @PF_strunzone;
  FBuiltins[218] := @PF_bitshift;
  FBuiltins[221] := @PF_strstrofs;
  FBuiltins[222] := @PF_str2chr;
  FBuiltins[223] := @PF_chr2str;
  FBuiltins[224] := @PF_strconv;
  FBuiltins[225] := @PF_strpad;
  FBuiltins[226] := @PF_infoadd;
  FBuiltins[227] := @PF_infoget;
  FBuiltins[228] := @PF_strncmp;
  FBuiltins[229] := @PF_strcasecmp;
  FBuiltins[230] := @PF_strncasecmp;
  FBuiltins[232] := @PF_addstat;
  FBuiltins[240] := @PF_checkpvs;
  FBuiltins[335] := @PF_particleeffectnum;
  FBuiltins[336] := @PF_trailparticles;
  FBuiltins[337] := @PF_pointparticles;
  FBuiltins[409] := @PF_te_particlerain;
  FBuiltins[410] := @PF_te_particlesnow;
  FBuiltins[400] := @PF_copyentity;
  FBuiltins[402] := @PF_findchain;
  FBuiltins[403] := @PF_findchainfloat;
  FBuiltins[432] := @PF_vectorvectors;
  FBuiltins[440] := @PF_clientcommand;
  FBuiltins[441] := @PF_tokenize;
  FBuiltins[442] := @PF_argv;
  FBuiltins[448] := @PF_cvar_string;
  FBuiltins[449] := @PF_findflags;
  FBuiltins[450] := @PF_findchainflags;
  FBuiltins[459] := @PF_edict_num;
  FBuiltins[471] := @PF_asin;
  FBuiltins[472] := @PF_acos;
  FBuiltins[473] := @PF_atan;
  FBuiltins[474] := @PF_atan2;
  FBuiltins[475] := @PF_tan;
  FBuiltins[479] := @PF_tokenizebyseparator;
  FBuiltins[480] := @PF_strtolower;
  FBuiltins[481] := @PF_strtoupper;
  FBuiltins[482] := @PF_cvar_string;
  FBuiltins[484] := @PF_strreplace;
  FBuiltins[485] := @PF_strireplace;
  FBuiltins[512] := @PF_num_for_edict;
  FBuiltins[514] := @PF_tokenize;
  FBuiltins[532] := @PF_log;
  FBuiltins[627] := @PF_sprintf;
  FBuiltins[BuiltinFtoi] := @PF_ftoi;
  FBuiltins[BuiltinItof] := @PF_itof;
  FBuiltins[BuiltinCrossProduct] := @PF_crossproduct;
  FBuiltins[BuiltinStrTrim] := @PF_strtrim;
  FBuiltins[BuiltinArgc] := @PF_argc;
end;

procedure TQuakeProgs.BindNamedBuiltins;
var
  I, N, Bound: Integer;
begin
  { QuakeSpasm-Spiked: a builtin declared #0 gets the engine's builtin of
    its name }
  Bound := 0;
  for I := 1 to High(FFunctions) do
    if FFunctions[I].FirstStatement = 0 then
    begin
      N := ExtBuiltinNumber(GetString(FFunctions[I].SName));
      if (N > 0) and (N <= High(FBuiltins)) and Assigned(FBuiltins[N]) then
      begin
        FFunctions[I].FirstStatement := -N;
        Inc(Bound);
      end;
    end;
  if Bound > 0 then
    WritelnLog('QuakeProgs', 'Builtins bound by name: %d', [Bound]);
end;

function TQuakeProgs.CallBuiltin(const Num, ArgC: Integer): Boolean;
begin
  Result := (Num > 0) and (Num <= High(FBuiltins)) and Assigned(FBuiltins[Num]);
  if not Result then
    Exit;
  FArgC := ArgC;
  FCurrentBuiltin := Num;
  FBuiltins[Num]();
end;

function TQuakeProgs.ParmFloat(const N: Integer): Single;
begin
  Result := Global(OFS_PARM0 + 3 * N)^.F;
end;

function TQuakeProgs.ParmVector(const N: Integer): TVector3;
begin
  Result := GlobalVector(OFS_PARM0 + 3 * N);
end;

function TQuakeProgs.ParmEntity(const N: Integer): Integer;
begin
  Result := Global(OFS_PARM0 + 3 * N)^.I;
end;

procedure TQuakeProgs.ReturnFloat(const F: Single);
begin
  Global(OFS_RETURN)^.F := F;
end;

procedure TQuakeProgs.ReturnString(const S: String);
begin
  Global(OFS_RETURN)^.I := TempString(S);
end;

function TQuakeProgs.ArgsFrom(const First: Integer): String;
var
  I: Integer;
begin
  Result := '';
  for I := First to FArgC - 1 do
    Result := Result + ParmString(I);
end;

function TQuakeProgs.UserCvar(const AName: String; out Value: String): Boolean;
var
  I: Integer;
begin
  I := FUserCvars.IndexOfName(AName);
  Result := I >= 0;
  if Result then
    Value := FUserCvars.ValueFromIndex[I]
  else
    Value := '';
end;

{ Math }

procedure TQuakeProgs.PF_sin;
begin
  ReturnFloat(Sin(ParmFloat(0)));
end;

procedure TQuakeProgs.PF_cos;
begin
  ReturnFloat(Cos(ParmFloat(0)));
end;

procedure TQuakeProgs.PF_sqrt;
begin
  ReturnFloat(Sqrt(Max(ParmFloat(0), 0)));
end;

procedure TQuakeProgs.PF_asin;
begin
  ReturnFloat(ArcSin(EnsureRange(ParmFloat(0), -1, 1)));
end;

procedure TQuakeProgs.PF_acos;
begin
  ReturnFloat(ArcCos(EnsureRange(ParmFloat(0), -1, 1)));
end;

procedure TQuakeProgs.PF_atan;
begin
  ReturnFloat(ArcTan(ParmFloat(0)));
end;

procedure TQuakeProgs.PF_atan2;
begin
  ReturnFloat(ArcTan2(ParmFloat(0), ParmFloat(1)));
end;

procedure TQuakeProgs.PF_tan;
var
  C: Single;
begin
  C := Cos(ParmFloat(0));
  if Abs(C) < 1e-7 then
    ReturnFloat(0)
  else
    ReturnFloat(Sin(ParmFloat(0)) / C);
end;

procedure TQuakeProgs.PF_log;
begin
  if ParmFloat(0) > 0 then
    ReturnFloat(Ln(ParmFloat(0)))
  else
    ReturnFloat(0);
end;

procedure TQuakeProgs.PF_pow;
var
  A, B: Single;
begin
  A := ParmFloat(0);
  B := ParmFloat(1);
  if (A < 0) and (B <> Trunc(B)) then
    ReturnFloat(0)
  else if (A = 0) and (B < 0) then
    ReturnFloat(0)
  else
    ReturnFloat(EnsureRange(Power(Double(A), Double(B)), -MaxSingle, MaxSingle));
end;

procedure TQuakeProgs.PF_min;
var
  I: Integer;
  V: Single;
begin
  V := ParmFloat(0);
  for I := 1 to FArgC - 1 do
    V := Min(V, ParmFloat(I));
  ReturnFloat(V);
end;

procedure TQuakeProgs.PF_max;
var
  I: Integer;
  V: Single;
begin
  V := ParmFloat(0);
  for I := 1 to FArgC - 1 do
    V := Max(V, ParmFloat(I));
  ReturnFloat(V);
end;

procedure TQuakeProgs.PF_bound;
begin
  { bound(min, value, max) }
  ReturnFloat(Max(ParmFloat(0), Min(ParmFloat(1), ParmFloat(2))));
end;

procedure TQuakeProgs.PF_anglemod;
var
  V: Single;
begin
  V := ParmFloat(0);
  ReturnFloat(V - 360 * Floor(V / 360));
end;

procedure TQuakeProgs.PF_bitshift;
var
  V, Q: Integer;
begin
  V := Trunc(ParmFloat(0));
  Q := Trunc(ParmFloat(1));
  if Q >= 0 then
    ReturnFloat(LongInt(LongWord(V) shl Min(Q, 31)))
  else
    ReturnFloat(LongInt(LongWord(V) shr Min(-Q, 31)));
end;

procedure TQuakeProgs.PF_ftoi;
begin
  Global(OFS_RETURN)^.I := Trunc(ParmFloat(0));
end;

procedure TQuakeProgs.PF_itof;
begin
  ReturnFloat(Global(OFS_PARM0)^.I);
end;

procedure TQuakeProgs.PF_randomvec;
var
  V: TVector3;
begin
  { A random direction no longer than 1 }
  repeat
    V := Vector3(Random * 2 - 1, Random * 2 - 1, Random * 2 - 1);
  until V.LengthSqr <= 1;
  SetGlobalVector(OFS_RETURN, V);
end;

procedure TQuakeProgs.PF_crossproduct;
begin
  SetGlobalVector(OFS_RETURN, TVector3.CrossProduct(ParmVector(0), ParmVector(1)));
end;

procedure TQuakeProgs.PF_vectorvectors;
var
  F, R, U: TVector3;
  D: Single;
begin
  { DP's VectorVectors: v_forward, v_right and v_up of a direction }
  F := ParmVector(0).Normalize;
  R := Vector3(F.Z, -F.X, F.Y);
  D := TVector3.DotProduct(F, R);
  R := (R - F * D).Normalize;
  U := TVector3.CrossProduct(R, F);
  SetGlobalVector(FGVForward, F);
  SetGlobalVector(FGVRight, R);
  SetGlobalVector(FGVUp, U);
end;

{ Entities }

procedure TQuakeProgs.PF_etos;
begin
  ReturnString('entity ' + IntToStr(ParmEntity(0)));
end;

procedure TQuakeProgs.PF_edict_num;
var
  E: Integer;
begin
  E := Trunc(ParmFloat(0));
  if (E < 0) or (E >= FNumEdicts) then
    E := 0;
  Global(OFS_RETURN)^.I := E;
end;

procedure TQuakeProgs.PF_num_for_edict;
begin
  ReturnFloat(ParmEntity(0));
end;

procedure TQuakeProgs.PF_findfloat;
var
  E, F: Integer;
  V: LongInt;
begin
  { findfloat / findentity(start, field, value): the cell compares as is }
  E := ParmEntity(0);
  F := Global(OFS_PARM0 + 3)^.I;
  V := Global(OFS_PARM0 + 6)^.I;
  for E := E + 1 to FNumEdicts - 1 do
    if not FEdictFree[E] and ((Field(E, F)^.I = V) or ((Field(E, F)^.F = 0) and (Global(OFS_PARM0 + 6)^.F = 0))) then
    begin
      Global(OFS_RETURN)^.I := E;
      Exit;
    end;
  Global(OFS_RETURN)^.I := 0;
end;

procedure TQuakeProgs.PF_findflags;
var
  E, F, Flags: Integer;
begin
  E := ParmEntity(0);
  F := Global(OFS_PARM0 + 3)^.I;
  Flags := Trunc(ParmFloat(2));
  for E := E + 1 to FNumEdicts - 1 do
    if not FEdictFree[E] and ((Trunc(Field(E, F)^.F) and Flags) <> 0) then
    begin
      Global(OFS_RETURN)^.I := E;
      Exit;
    end;
  Global(OFS_RETURN)^.I := 0;
end;

procedure TQuakeProgs.PF_findchain;
var
  E, F, Chain: Integer;
  S: String;
begin
  { findchain(field, string): every entity whose field matches, through .chain }
  F := Global(OFS_PARM0)^.I;
  S := ParmString(1);
  Chain := 0;
  for E := FNumEdicts - 1 downto 1 do
    if not FEdictFree[E] and (FieldString(E, F) = S) then
    begin
      Field(E, FFChain)^.I := Chain;
      Chain := E;
    end;
  Global(OFS_RETURN)^.I := Chain;
end;

procedure TQuakeProgs.PF_findchainfloat;
var
  E, F, Chain: Integer;
  V: LongInt;
begin
  F := Global(OFS_PARM0)^.I;
  V := Global(OFS_PARM0 + 3)^.I;
  Chain := 0;
  for E := FNumEdicts - 1 downto 1 do
    if not FEdictFree[E] and (Field(E, F)^.I = V) then
    begin
      Field(E, FFChain)^.I := Chain;
      Chain := E;
    end;
  Global(OFS_RETURN)^.I := Chain;
end;

procedure TQuakeProgs.PF_findchainflags;
var
  E, F, Flags, Chain: Integer;
begin
  F := Global(OFS_PARM0)^.I;
  Flags := Trunc(ParmFloat(1));
  Chain := 0;
  for E := FNumEdicts - 1 downto 1 do
    if not FEdictFree[E] and ((Trunc(Field(E, F)^.F) and Flags) <> 0) then
    begin
      Field(E, FFChain)^.I := Chain;
      Chain := E;
    end;
  Global(OFS_RETURN)^.I := Chain;
end;

procedure TQuakeProgs.PF_copyentity;
var
  Src, Dst: Integer;
begin
  Src := ParmEntity(0);
  Dst := ParmEntity(1);
  if (Src < 0) or (Dst <= 0) or (Src >= MaxEdicts) or (Dst >= MaxEdicts) or (Src = Dst) then
    Exit;
  Move(FEdicts[Src * FEntityFields], FEdicts[Dst * FEntityFields], FEntityFields * SizeOf(TProgCell));
  FHost.SetOrigin(Self, Dst, FieldVector(Dst, FFOrigin));
end;

procedure TQuakeProgs.PF_tracebox;
var
  Fraction: Single;
  EndPos, Normal: TVector3;
  Hit: Integer;
  AllSolid, StartSolid, InOpen, InWater: Boolean;
begin
  { tracebox(start, mins, maxs, end, nomonsters, forent) }
  FHost.TraceHull(Self, ParmVector(0), ParmVector(1), ParmVector(2), ParmVector(3),
    Round(ParmFloat(4)), ParmEntity(5), Fraction, EndPos, Normal, Hit, AllSolid, StartSolid,
    InOpen, InWater);
  Global(FGTraceAllSolid)^.F := Ord(AllSolid);
  Global(FGTraceStartSolid)^.F := Ord(StartSolid);
  Global(FGTraceFraction)^.F := Fraction;
  Global(FGTraceInOpen)^.F := Ord(InOpen);
  Global(FGTraceInWater)^.F := Ord(InWater);
  SetGlobalVector(FGTraceEndPos, EndPos);
  SetGlobalVector(FGTracePlaneNormal, Normal);
  Global(FGTracePlaneDist)^.F := TVector3.DotProduct(Normal, EndPos);
  Global(FGTraceEnt)^.I := Hit;
end;

procedure TQuakeProgs.PF_checkpvs;
begin
  { checkpvs(viewpos, entity): the host's PVS, or "visible" without one }
  ReturnFloat(Ord(FHost.CheckPvs(Self, ParmVector(0), ParmEntity(1))));
end;

procedure TQuakeProgs.PF_addstat;
begin
  { addstat(index, type, field): a stat for client-side QuakeC (CSQC),
    which this engine does not run; counted only }
  Inc(FAddedStats);
end;

procedure TQuakeProgs.PF_particleeffectnum;
begin
  { particleeffectnum(name): the effect's number in effectinfo.txt }
  ReturnFloat(FHost.ParticleEffectNum(Self, ParmString(0)));
end;

procedure TQuakeProgs.PF_pointparticles;
var
  Count: Single;
begin
  { pointparticles(effectnum, origin, velocity, count = 1) }
  if FArgC > 3 then
    Count := ParmFloat(3)
  else
    Count := 1;
  FHost.PointParticles(Self, Trunc(ParmFloat(0)), ParmVector(1), ParmVector(2), Count);
end;

procedure TQuakeProgs.PF_trailparticles;
var
  A: Integer;
  B: Single;
begin
  { DP's trailparticles(entity, effectnum, start, end) or FTE's
    (effectnum, entity, start, end), like QuakeSpasm-Spiked: an entity is a
    small edict number, an effect number a float }
  A := Global(OFS_PARM0)^.I;
  B := ParmFloat(1);
  if (A >= 0) and (A < FNumEdicts) and (B >= 1) and (B = Trunc(B)) then
    FHost.TrailParticles(Self, Trunc(B), A, ParmVector(2), ParmVector(3))
  else
    FHost.TrailParticles(Self, Trunc(ParmFloat(0)), Global(OFS_PARM0 + 3)^.I, ParmVector(2), ParmVector(3));
end;

procedure TQuakeProgs.PF_te_particlerain;
begin
  { te_particlerain(mins, maxs, velocity, count, color) }
  FHost.ParticleWeather(Self, ParmVector(0), ParmVector(1), ParmVector(2), Trunc(ParmFloat(3)),
    Trunc(ParmFloat(4)), False);
end;

procedure TQuakeProgs.PF_te_particlesnow;
begin
  FHost.ParticleWeather(Self, ParmVector(0), ParmVector(1), ParmVector(2), Trunc(ParmFloat(3)),
    Trunc(ParmFloat(4)), True);
end;

procedure TQuakeProgs.PF_clientcommand;
begin
  { clientcommand(client, command): run as if the client typed it }
  FHost.StuffCmd(Self, ParmEntity(0), ParmString(1) + #10);
end;

{ Cvars and extensions }

procedure TQuakeProgs.PF_checkextension;
var
  S: String;
begin
  S := ParmString(0);
  ReturnFloat(Ord(IsSupportedExtension(S)));
  if FCheckedExtensions.IndexOf(S) < 0 then
  begin
    FCheckedExtensions.Add(S);
    WritelnLog('QuakeProgs', 'checkextension("%s"): %s', [S, BoolToStr(IsSupportedExtension(S), 'yes', 'no')]);
  end;
end;

procedure TQuakeProgs.PF_builtin_find;
var
  N: Integer;
begin
  N := ExtBuiltinNumber(ParmString(0));
  if (N > 0) and (N <= High(FBuiltins)) and Assigned(FBuiltins[N]) then
    ReturnFloat(N)
  else
    ReturnFloat(0);
end;

procedure TQuakeProgs.PF_registercvar;
var
  S, V: String;
begin
  { registercvar(name, default): 1 when it was new }
  S := ParmString(0);
  if UserCvar(S, V) then
  begin
    ReturnFloat(0);
    Exit;
  end;
  if FArgC > 1 then
    V := ParmString(1)
  else
    V := '';
  FUserCvars.Add(S + '=' + V);
  ReturnFloat(1);
end;

procedure TQuakeProgs.PF_cvar_string;
var
  S, V: String;
begin
  S := ParmString(0);
  if not UserCvar(S, V) then
    V := FHost.CvarString(Self, S);
  ReturnString(V);
end;

{ Strings }

function ParseQcFloat(const S: String): Single;
var
  Fmt: TFormatSettings;
  T: String;
  I: Integer;
begin
  { atof: the leading number, 0 for none }
  Fmt := DefaultFormatSettings;
  Fmt.DecimalSeparator := '.';
  T := Trim(S);
  I := 1;
  if (I <= Length(T)) and (T[I] in ['-', '+']) then
    Inc(I);
  while (I <= Length(T)) and (T[I] in ['0'..'9', '.', 'e', 'E']) do
  begin
    if (T[I] in ['e', 'E']) and (I < Length(T)) and (T[I + 1] in ['-', '+']) then
      Inc(I);
    Inc(I);
  end;
  Result := StrToFloatDef(Copy(T, 1, I - 1), 0, Fmt);
end;

procedure TQuakeProgs.PF_stof;
begin
  ReturnFloat(ParseQcFloat(ParmString(0)));
end;

procedure TQuakeProgs.PF_stov;
var
  Parts: TStringArray;
  V: TVector3;
  I: Integer;
begin
  { "'x y z'" or "x y z" }
  Parts := StringReplace(ParmString(0), '''', ' ', [rfReplaceAll]).Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
  V := TVector3.Zero;
  for I := 0 to Min(2, High(Parts)) do
    V.Data[I] := ParseQcFloat(Parts[I]);
  SetGlobalVector(OFS_RETURN, V);
end;

procedure TQuakeProgs.PF_strlen;
begin
  ReturnFloat(Length(ParmString(0)));
end;

procedure TQuakeProgs.PF_strcat;
begin
  ReturnString(ArgsFrom(0));
end;

procedure TQuakeProgs.PF_substring;
var
  S: String;
  Start, Len: Integer;
begin
  { substring(s, start, length): a negative start or length counts from the end }
  S := ParmString(0);
  Start := Trunc(ParmFloat(1));
  Len := Trunc(ParmFloat(2));
  if Start < 0 then
    Start := Max(Length(S) + Start, 0);
  if Len < 0 then
    Len := Max(Length(S) - Start + Len + 1, 0);
  ReturnString(Copy(S, Start + 1, Len));
end;

procedure TQuakeProgs.PF_strzone;
var
  S: String;
  I: Integer;
begin
  S := ArgsFrom(0);
  if Length(FZoneFree) > 0 then
  begin
    I := FZoneFree[High(FZoneFree)];
    SetLength(FZoneFree, Length(FZoneFree) - 1);
    FDynStrings[I] := S;
    Global(OFS_RETURN)^.I := -I - 1;
  end else
  begin
    Global(OFS_RETURN)^.I := NewString(S);
    I := -Global(OFS_RETURN)^.I - 1;
  end;
  FZoned.AddOrSetValue(I, True);
end;

procedure TQuakeProgs.PF_strunzone;
var
  I: Integer;
begin
  { Only a string strzone made goes back to the pool }
  I := -Global(OFS_PARM0)^.I - 1;
  if (I >= 0) and FZoned.ContainsKey(I) then
  begin
    FZoned.Remove(I);
    FDynStrings[I] := '';
    SetLength(FZoneFree, Length(FZoneFree) + 1);
    FZoneFree[High(FZoneFree)] := I;
  end;
end;

procedure TQuakeProgs.PF_strstrofs;
var
  S, Sub: String;
  Start, P: Integer;
begin
  S := ParmString(0);
  Sub := ParmString(1);
  Start := 0;
  if FArgC > 2 then
    Start := Max(Trunc(ParmFloat(2)), 0);
  P := Pos(Sub, Copy(S, Start + 1, MaxInt));
  if (P = 0) or (Sub = '') then
    ReturnFloat(-1)
  else
    ReturnFloat(P - 1 + Start);
end;

procedure TQuakeProgs.PF_str2chr;
var
  S: String;
  I: Integer;
begin
  S := ParmString(0);
  I := Trunc(ParmFloat(1));
  if I < 0 then
    I := Length(S) + I;
  if (I >= 0) and (I < Length(S)) then
    ReturnFloat(Ord(S[I + 1]))
  else
    ReturnFloat(0);
end;

procedure TQuakeProgs.PF_chr2str;
var
  I: Integer;
  S: String;
begin
  S := '';
  for I := 0 to FArgC - 1 do
    S := S + Chr(Byte(Trunc(ParmFloat(I))));
  ReturnString(S);
end;

procedure TQuakeProgs.PF_strconv;
var
  CCase, RedAlpha, RedNum, I: Integer;
  S: String;
  C: Byte;
begin
  { strconv(case, redalpha, rednum, s...): case 1 lower, 2 upper; the
    red modes 1 make letters / digits gold (high bit), 2 plain }
  CCase := Trunc(ParmFloat(0));
  RedAlpha := Trunc(ParmFloat(1));
  RedNum := Trunc(ParmFloat(2));
  S := ArgsFrom(3);
  for I := 1 to Length(S) do
  begin
    C := Ord(S[I]);
    if (CCase = 1) and (Chr(C and 127) in ['A'..'Z']) then
      C := C + 32
    else if CCase = 2 then
      C := Ord(UpCase(Chr(C and 127))) or (C and 128);
    if Chr(C and 127) in ['0'..'9'] then
    begin
      if RedNum = 1 then
        C := C or 128
      else if RedNum = 2 then
        C := C and 127;
    end else
    if Chr(C and 127) in ['a'..'z', 'A'..'Z'] then
    begin
      if RedAlpha = 1 then
        C := C or 128
      else if RedAlpha = 2 then
        C := C and 127;
    end;
    S[I] := Chr(C);
  end;
  ReturnString(S);
end;

procedure TQuakeProgs.PF_strpad;
var
  Pad: Integer;
  S: String;
begin
  { strpad(n, s...): positive pads on the right, negative on the left }
  Pad := Trunc(ParmFloat(0));
  S := ArgsFrom(1);
  if Pad > 0 then
    S := S + StringOfChar(' ', Max(Pad - Length(S), 0))
  else
    S := StringOfChar(' ', Max(-Pad - Length(S), 0)) + S;
  ReturnString(S);
end;

function InfoGet(const Info, Key: String): String;
var
  Parts: TStringArray;
  I: Integer;
begin
  { \key\value\key\value }
  Parts := Info.Split(['\']);
  I := 1;
  while I + 1 <= High(Parts) do
  begin
    if Parts[I] = Key then
      Exit(Parts[I + 1]);
    Inc(I, 2);
  end;
  Result := '';
end;

procedure TQuakeProgs.PF_infoget;
begin
  ReturnString(InfoGet(ParmString(0), ParmString(1)));
end;

procedure TQuakeProgs.PF_infoadd;
var
  Info, Key, Value, R: String;
  Parts: TStringArray;
  I: Integer;
begin
  { infoadd(info, key, value...): the info with key set (removed if empty) }
  Info := ParmString(0);
  Key := ParmString(1);
  Value := ArgsFrom(2);
  Parts := Info.Split(['\']);
  R := '';
  I := 1;
  while I + 1 <= High(Parts) do
  begin
    if Parts[I] <> Key then
      R := R + '\' + Parts[I] + '\' + Parts[I + 1];
    Inc(I, 2);
  end;
  if (Value <> '') and (Pos('\', Key + Value) = 0) then
    R := R + '\' + Key + '\' + Value;
  ReturnString(R);
end;

procedure TQuakeProgs.PF_strncmp;
var
  N: Integer;
begin
  N := Trunc(ParmFloat(2));
  ReturnFloat(Sign(CompareStr(Copy(ParmString(0), 1, N), Copy(ParmString(1), 1, N))));
end;

procedure TQuakeProgs.PF_strcasecmp;
begin
  ReturnFloat(Sign(CompareText(ParmString(0), ParmString(1))));
end;

procedure TQuakeProgs.PF_strncasecmp;
var
  N: Integer;
begin
  N := Trunc(ParmFloat(2));
  ReturnFloat(Sign(CompareText(Copy(ParmString(0), 1, N), Copy(ParmString(1), 1, N))));
end;

procedure TQuakeProgs.PF_strtolower;
begin
  ReturnString(LowerCase(ParmString(0)));
end;

procedure TQuakeProgs.PF_strtoupper;
begin
  ReturnString(UpperCase(ParmString(0)));
end;

procedure TQuakeProgs.PF_strtrim;
begin
  ReturnString(Trim(ParmString(0)));
end;

procedure TQuakeProgs.PF_strreplace;
begin
  { strreplace(search, replace, subject) }
  if ParmString(0) = '' then
    ReturnString(ParmString(2))
  else
    ReturnString(StringReplace(ParmString(2), ParmString(0), ParmString(1), [rfReplaceAll]));
end;

procedure TQuakeProgs.PF_strireplace;
begin
  if ParmString(0) = '' then
    ReturnString(ParmString(2))
  else
    ReturnString(StringReplace(ParmString(2), ParmString(0), ParmString(1), [rfReplaceAll, rfIgnoreCase]));
end;

procedure TQuakeProgs.PF_tokenize;
var
  S, T: String;
  I: Integer;
begin
  { tokenize(s): the words of s, a quoted string one word (COM_Parse) }
  S := ParmString(0);
  FTokens.Clear;
  I := 1;
  while I <= Length(S) do
  begin
    while (I <= Length(S)) and (S[I] <= ' ') do
      Inc(I);
    if I > Length(S) then
      Break;
    if S[I] = '"' then
    begin
      Inc(I);
      T := '';
      while (I <= Length(S)) and (S[I] <> '"') do
      begin
        T := T + S[I];
        Inc(I);
      end;
      Inc(I);
    end else
    if S[I] in ['{', '}', '(', ')', '''', ':'] then
    begin
      T := S[I];
      Inc(I);
    end else
    begin
      T := '';
      while (I <= Length(S)) and (S[I] > ' ') and not (S[I] in ['{', '}', '(', ')', '''', ':', '"']) do
      begin
        T := T + S[I];
        Inc(I);
      end;
    end;
    FTokens.Add(T);
  end;
  ReturnFloat(FTokens.Count);
end;

procedure TQuakeProgs.PF_tokenizebyseparator;
var
  S, Sep, Best: String;
  I, P, BestP: Integer;
begin
  { tokenizebyseparator(s, sep1, sep2...) }
  S := ParmString(0);
  FTokens.Clear;
  repeat
    BestP := 0;
    Best := '';
    for I := 1 to FArgC - 1 do
    begin
      Sep := ParmString(I);
      if Sep = '' then
        Continue;
      P := Pos(Sep, S);
      if (P > 0) and ((BestP = 0) or (P < BestP)) then
      begin
        BestP := P;
        Best := Sep;
      end;
    end;
    if BestP = 0 then
    begin
      FTokens.Add(S);
      Break;
    end;
    FTokens.Add(Copy(S, 1, BestP - 1));
    S := Copy(S, BestP + Length(Best), MaxInt);
  until False;
  ReturnFloat(FTokens.Count);
end;

procedure TQuakeProgs.PF_argv;
var
  I: Integer;
begin
  I := Trunc(ParmFloat(0));
  if I < 0 then
    I := FTokens.Count + I;
  if (I >= 0) and (I < FTokens.Count) then
    ReturnString(FTokens[I])
  else
    ReturnString('');
end;

procedure TQuakeProgs.PF_argc;
begin
  ReturnFloat(FTokens.Count);
end;

function CleanFormatSpec(const Spec: String): String;
var
  I: Integer;
  Left, Dot: Boolean;
  Width, Prec: String;
begin
  { "-", a width and a precision of at most two digits: what FPC's Format
    takes without raising (the web build cannot catch exceptions) }
  Left := False;
  Dot := False;
  Width := '';
  Prec := '';
  for I := 1 to Length(Spec) do
    case Spec[I] of
      '-': Left := True;
      '.': Dot := True;
      '0'..'9':
        if Dot then
          Prec := Prec + Spec[I]
        else if (Width <> '') or (Spec[I] <> '0') then
          Width := Width + Spec[I];
    end;
  Width := Copy(Width, 1, 2);
  Prec := Copy(Prec, 1, 2);
  Result := '';
  if Left and (Width <> '') then
    Result := '-';
  Result := Result + Width;
  if Dot then
    Result := Result + '.' + IntToStr(StrToIntDef(Prec, 0));
end;

function SpecWidth(const Spec: String): String;
begin
  if Pos('.', Spec) > 0 then
    Result := Copy(Spec, 1, Pos('.', Spec) - 1)
  else
    Result := Spec;
end;

procedure TQuakeProgs.PF_sprintf;
var
  Fmt, R, Spec, Arg: String;
  I, NextArg, J: Integer;
  C: Char;
  Fs: TFormatSettings;
  V: TVector3;
begin
  { sprintf(format, ...): %d %i %u %x %X %c %f %e %g %s %v %% with flags,
    width and precision, each % taking the next argument }
  Fs := DefaultFormatSettings;
  Fs.DecimalSeparator := '.';
  Fmt := ParmString(0);
  R := '';
  NextArg := 1;
  I := 1;
  while I <= Length(Fmt) do
  begin
    if (Fmt[I] <> '%') or (I = Length(Fmt)) then
    begin
      R := R + Fmt[I];
      Inc(I);
      Continue;
    end;
    if Fmt[I + 1] = '%' then
    begin
      R := R + '%';
      Inc(I, 2);
      Continue;
    end;
    { %[flags][width][.precision]conversion }
    J := I + 1;
    while (J <= Length(Fmt)) and (Fmt[J] in ['-', '+', ' ', '#', '0', '1'..'9', '.']) do
      Inc(J);
    if J > Length(Fmt) then
    begin
      R := R + Copy(Fmt, I, MaxInt);
      Break;
    end;
    C := Fmt[J];
    Spec := CleanFormatSpec(Copy(Fmt, I + 1, J - I - 1));
    if NextArg >= Max(FArgC, 1) then
      Arg := ''
    else
      case C of
        'd', 'i', 'u':
          Arg := Format('%' + Spec + 'd', [Trunc(ParmFloat(NextArg))]);
        'x':
          Arg := LowerCase(Format('%' + SpecWidth(Spec) + 'x', [Trunc(ParmFloat(NextArg))]));
        'X':
          Arg := Format('%' + SpecWidth(Spec) + 'x', [Trunc(ParmFloat(NextArg))]);
        'c':
          Arg := Chr(Byte(Trunc(ParmFloat(NextArg))));
        'f', 'F':
          begin
            if Pos('.', Spec) = 0 then
              Spec := Spec + '.6';
            Arg := Format('%' + Spec + 'f', [ParmFloat(NextArg)], Fs);
          end;
        'e', 'E':
          Arg := Format('%' + Spec + 'e', [ParmFloat(NextArg)], Fs);
        'g', 'G':
          Arg := Format('%' + Spec + 'g', [ParmFloat(NextArg)], Fs);
        's', 'S':
          Arg := Format('%' + Spec + 's', [ParmString(NextArg)]);
        'v':
          begin
            V := ParmVector(NextArg);
            if Pos('.', Spec) = 0 then
              Spec := Spec + '.1';
            Arg := Format('%' + Spec + 'f %' + Spec + 'f %' + Spec + 'f', [V.X, V.Y, V.Z], Fs);
          end;
        else
          Arg := Copy(Fmt, I, J - I + 1);
      end;
    if C in ['d', 'i', 'u', 'x', 'X', 'c', 'f', 'F', 'e', 'E', 'g', 'G', 's', 'S', 'v'] then
      Inc(NextArg);
    R := R + Arg;
    I := J + 1;
  end;
  ReturnString(R);
end;

{ FRIK_FILE: data/<name> in the paks to read, castle-config:/qcdata_<name> written by the mod }

function QcDataUrl(const AName: String): String;
var
  I: Integer;
  S: String;
begin
  S := LowerCase(AName);
  for I := 1 to Length(S) do
    if not (S[I] in ['a'..'z', '0'..'9', '.', '_', '-']) then
      S[I] := '_';
  Result := 'castle-config:/qcdata_' + S;
end;

procedure TQuakeProgs.PF_fopen;
var
  AName, Text: String;
  Mode, H: Integer;
  Stream: TStream;
begin
  { fopen(name, mode): mode 0 read, 1 append, 2 write; -1 when it fails }
  AName := ParmString(0);
  Mode := Trunc(ParmFloat(1));
  ReturnFloat(-1);
  if (AName = '') or (Pos('..', AName) > 0) then
    Exit;
  H := 0;
  while (H <= High(FFiles)) and (FFiles[H].Mode >= 0) do
    Inc(H);
  if H > High(FFiles) then
    Exit;
  Text := '';
  if Mode in [0, 1] then
  begin
    { The mod's own written file first, then data/<name> in the paks }
    Stream := nil;
    if UriExists(QcDataUrl(AName)) = ueFile then
    try
      Stream := Download(QcDataUrl(AName));
    except
      Stream := nil;
    end;
    if (Stream = nil) and Pak.FileExists('data/' + AName) then
      Stream := Pak.GetStream('data/' + AName);
    if Stream <> nil then
    try
      SetLength(Text, Stream.Size);
      if Stream.Size > 0 then
        Stream.ReadBuffer(Text[1], Stream.Size);
    finally
      Stream.Free;
    end else
    if Mode = 0 then
      Exit;
  end else
  if Mode <> 2 then
    Exit;
  FFiles[H].Mode := Mode;
  FFiles[H].Url := QcDataUrl(AName);
  FFiles[H].Text := Text;
  FFiles[H].Pos := 1;
  WritelnLog('QuakeProgs', 'fopen("%s", %d): file %d', [AName, Mode, H]);
  ReturnFloat(H);
end;

procedure TQuakeProgs.PF_fclose;
var
  H: Integer;
  Stream: TStream;
begin
  H := Trunc(ParmFloat(0));
  if (H < 0) or (H > High(FFiles)) or (FFiles[H].Mode < 0) then
    Exit;
  if FFiles[H].Mode in [1, 2] then
  try
    Stream := UrlSaveStream(FFiles[H].Url);
    try
      if FFiles[H].Text <> '' then
        Stream.WriteBuffer(FFiles[H].Text[1], Length(FFiles[H].Text));
    finally
      Stream.Free;
    end;
  except
    on E: Exception do
      WritelnWarning('QuakeProgs', 'Cannot write "%s": %s', [FFiles[H].Url, E.Message]);
  end;
  FFiles[H].Mode := -1;
  FFiles[H].Text := '';
end;

procedure TQuakeProgs.PF_fgets;
var
  H, P: Integer;
  T: String;
begin
  { The next line, '' at the end (string_null) }
  H := Trunc(ParmFloat(0));
  Global(OFS_RETURN)^.I := 0;
  if (H < 0) or (H > High(FFiles)) or (FFiles[H].Mode <> 0) then
    Exit;
  T := FFiles[H].Text;
  P := FFiles[H].Pos;
  if P > Length(T) then
    Exit;
  while (P <= Length(T)) and not (T[P] in [#10, #13]) do
    Inc(P);
  ReturnString(Copy(T, FFiles[H].Pos, P - FFiles[H].Pos));
  if (P <= Length(T)) and (T[P] = #13) then
    Inc(P);
  if (P <= Length(T)) and (T[P] = #10) then
    Inc(P);
  FFiles[H].Pos := P;
end;

procedure TQuakeProgs.PF_fputs;
var
  H: Integer;
begin
  H := Trunc(ParmFloat(0));
  if (H < 0) or (H > High(FFiles)) or not (FFiles[H].Mode in [1, 2]) then
    Exit;
  FFiles[H].Text := FFiles[H].Text + ArgsFrom(1);
end;
