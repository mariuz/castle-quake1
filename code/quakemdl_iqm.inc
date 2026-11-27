{ Inter-Quake Model (IQM) files, the skeletal format of newer Quake mods:
  meshes of vertices bound to joints, and animations as the joints' poses.
  This engine draws vertex animation, so the loader does the skinning once:
  for every frame of the file it places the joints and moves each vertex
  with the up to four joints it is bound to, and keeps the result as a
  frame of positions like an Alias model's. The meshes become one mesh and
  their textures one skin image, as for MD3.
  Included by quakemdl.pas. }

type
  { Rotation, scale and translation: what a joint does to a point }
  TAffine = record
    M: array[0..2, 0..3] of Single;
  end;

function AffineIdentity: TAffine;
var
  R, C: Integer;
begin
  for R := 0 to 2 do
    for C := 0 to 3 do
      Result.M[R, C] := Ord(R = C);
end;

{ The two as one: a point goes through B first, then through A }
function AffineMul(const A, B: TAffine): TAffine;
var
  R, C: Integer;
begin
  for R := 0 to 2 do
  begin
    for C := 0 to 2 do
      Result.M[R, C] := A.M[R, 0] * B.M[0, C] + A.M[R, 1] * B.M[1, C] + A.M[R, 2] * B.M[2, C];
    Result.M[R, 3] := A.M[R, 0] * B.M[0, 3] + A.M[R, 1] * B.M[1, 3] + A.M[R, 2] * B.M[2, 3] + A.M[R, 3];
  end;
end;

function AffineApply(const A: TAffine; const P: TVector3): TVector3;
begin
  Result.X := A.M[0, 0] * P.X + A.M[0, 1] * P.Y + A.M[0, 2] * P.Z + A.M[0, 3];
  Result.Y := A.M[1, 0] * P.X + A.M[1, 1] * P.Y + A.M[1, 2] * P.Z + A.M[1, 3];
  Result.Z := A.M[2, 0] * P.X + A.M[2, 1] * P.Y + A.M[2, 2] * P.Z + A.M[2, 3];
end;

{ The identity for a transformation that cannot be undone (a zero scale) }
function AffineInverse(const A: TAffine): TAffine;
var
  Det, InvDet: Single;
  R: Integer;
  T: TVector3;
begin
  Det := A.M[0, 0] * (A.M[1, 1] * A.M[2, 2] - A.M[1, 2] * A.M[2, 1]) -
         A.M[0, 1] * (A.M[1, 0] * A.M[2, 2] - A.M[1, 2] * A.M[2, 0]) +
         A.M[0, 2] * (A.M[1, 0] * A.M[2, 1] - A.M[1, 1] * A.M[2, 0]);
  if Abs(Det) < 1e-12 then
    Exit(AffineIdentity);
  InvDet := 1 / Det;
  Result.M[0, 0] := (A.M[1, 1] * A.M[2, 2] - A.M[1, 2] * A.M[2, 1]) * InvDet;
  Result.M[0, 1] := (A.M[0, 2] * A.M[2, 1] - A.M[0, 1] * A.M[2, 2]) * InvDet;
  Result.M[0, 2] := (A.M[0, 1] * A.M[1, 2] - A.M[0, 2] * A.M[1, 1]) * InvDet;
  Result.M[1, 0] := (A.M[1, 2] * A.M[2, 0] - A.M[1, 0] * A.M[2, 2]) * InvDet;
  Result.M[1, 1] := (A.M[0, 0] * A.M[2, 2] - A.M[0, 2] * A.M[2, 0]) * InvDet;
  Result.M[1, 2] := (A.M[0, 2] * A.M[1, 0] - A.M[0, 0] * A.M[1, 2]) * InvDet;
  Result.M[2, 0] := (A.M[1, 0] * A.M[2, 1] - A.M[1, 1] * A.M[2, 0]) * InvDet;
  Result.M[2, 1] := (A.M[0, 1] * A.M[2, 0] - A.M[0, 0] * A.M[2, 1]) * InvDet;
  Result.M[2, 2] := (A.M[0, 0] * A.M[1, 1] - A.M[0, 1] * A.M[1, 0]) * InvDet;
  T := Vector3(A.M[0, 3], A.M[1, 3], A.M[2, 3]);
  for R := 0 to 2 do
    Result.M[R, 3] := -(Result.M[R, 0] * T.X + Result.M[R, 1] * T.Y + Result.M[R, 2] * T.Z);
end;

{ A joint's translation, rotation (a quaternion x y z w) and scale }
function AffineFromPose(const Translate: TVector3; const Rotate: TVector4; const Scale: TVector3): TAffine;
var
  Q: TVector4;
  L, X, Y, Z, W: Single;
  C: Integer;
begin
  Q := Rotate;
  L := Sqrt(Sqr(Q.X) + Sqr(Q.Y) + Sqr(Q.Z) + Sqr(Q.W));
  if L < 1e-9 then
    Q := Vector4(0, 0, 0, 1)
  else
    Q := Q * (1 / L);
  X := Q.X; Y := Q.Y; Z := Q.Z; W := Q.W;
  Result.M[0, 0] := 1 - 2 * (Y * Y + Z * Z);
  Result.M[0, 1] := 2 * (X * Y - Z * W);
  Result.M[0, 2] := 2 * (X * Z + Y * W);
  Result.M[1, 0] := 2 * (X * Y + Z * W);
  Result.M[1, 1] := 1 - 2 * (X * X + Z * Z);
  Result.M[1, 2] := 2 * (Y * Z - X * W);
  Result.M[2, 0] := 2 * (X * Z - Y * W);
  Result.M[2, 1] := 2 * (Y * Z + X * W);
  Result.M[2, 2] := 1 - 2 * (X * X + Y * Y);
  for C := 0 to 2 do
  begin
    Result.M[0, C] := Result.M[0, C] * Scale.Data[C];
    Result.M[1, C] := Result.M[1, C] * Scale.Data[C];
    Result.M[2, C] := Result.M[2, C] * Scale.Data[C];
  end;
  Result.M[0, 3] := Translate.X;
  Result.M[1, 3] := Translate.Y;
  Result.M[2, 3] := Translate.Z;
end;

function TQuakeMdl.LoadIqm(const Data: TBytes): Boolean;
const
  IqmMagic = 'INTERQUAKEMODEL';
  IQM_POSITION = 0;
  IQM_TEXCOORD = 1;
  IQM_BLENDINDEXES = 4;
  IQM_BLENDWEIGHTS = 5;
  IQM_UBYTE = 1;
  IQM_FLOAT = 7;
  MaxMeshes = 32;
  MaxJoints = 256;
  MaxFrames = 2048;
  MaxVerts = 65536;

  function Fits(const Ofs, Size: Int64): Boolean;
  begin
    Result := (Ofs >= 0) and (Size >= 0) and (Ofs + Size <= Length(Data));
  end;

  function U32(const Ofs: Integer): LongInt;
  begin
    Result := 0;
    if Fits(Ofs, 4) then
      Move(Data[Ofs], Result, 4);
  end;

  function U16(const Ofs: Integer): Integer;
  begin
    Result := 0;
    if Fits(Ofs, 2) then
      Result := Data[Ofs] or (Data[Ofs + 1] shl 8);
  end;

  function F32(const Ofs: Integer): Single;
  begin
    Result := 0;
    if Fits(Ofs, 4) then
      Move(Data[Ofs], Result, 4);
  end;

  function Vec3(const Ofs: Integer): TVector3;
  begin
    Result := Vector3(F32(Ofs), F32(Ofs + 4), F32(Ofs + 8));
  end;

var
  OfsText, NumText: Integer;

  function Text(const Index: Integer): String;
  var
    I: Integer;
  begin
    Result := '';
    if (Index < 0) or (Index >= NumText) then
      Exit;
    for I := OfsText + Index to OfsText + NumText - 1 do
    begin
      if not Fits(I, 1) or (Data[I] = 0) then
        Break;
      Result := Result + Chr(Data[I]);
    end;
  end;

var
  NumMeshes, OfsMeshes, NumArrays, NumVerts, OfsArrays, NumTris, OfsTris, NumJoints, OfsJoints, NumPoses, OfsPoses,
    NumAnims, OfsAnims, NumFrames, NumChannels, OfsFrames: Integer;
  OfsPos, OfsTex, OfsIdx, OfsWgt: Integer;
  I, J, K, M, F, V, C, Ofs, Parent, Mask, W, H, FrameOfs, First, Count: Integer;
  Names: array of String;
  Parts: TSkinParts;
  Missing: String;
  VertPart: array of Integer;
  Base: array of TVector3;
  BaseWorld, InvBase, Pose, Skin: array of TAffine;
  Channels: array[0..9] of Single;
  Frame: TMdlFrame;
  FrameNames: array of String;
  P, Moved: TVector3;
  Weight, Total: Single;
begin
  Result := False;
  if not Fits(0, 124) then
    Exit;
  for I := 1 to Length(IqmMagic) do
    if Data[I - 1] <> Ord(IqmMagic[I]) then
      Exit;
  if U32(16) <> 2 then
  begin
    WritelnWarning('QuakeMdl', 'IQM "%s": version %d (only 2 is read)', [FModelName, U32(16)]);
    Exit;
  end;
  NumText := U32(28);       OfsText := U32(32);
  NumMeshes := U32(36);     OfsMeshes := U32(40);
  NumArrays := U32(44);     NumVerts := U32(48);     OfsArrays := U32(52);
  NumTris := U32(56);       OfsTris := U32(60);
  NumJoints := U32(68);     OfsJoints := U32(72);
  NumPoses := U32(76);      OfsPoses := U32(80);
  NumAnims := U32(84);      OfsAnims := U32(88);
  NumFrames := U32(92);     NumChannels := U32(96);  OfsFrames := U32(100);
  if (NumMeshes < 1) or (NumMeshes > MaxMeshes) or (NumVerts < 1) or (NumVerts > MaxVerts) or (NumTris < 1) or
     (NumJoints < 0) or (NumJoints > MaxJoints) or (NumFrames < 0) or (NumFrames > MaxFrames) or
     (NumArrays < 1) or (NumArrays > 64) or (NumChannels < 0) or (NumChannels > MaxJoints * 10) or
     not Fits(OfsText, NumText) or not Fits(OfsMeshes, Int64(NumMeshes) * 24) or
     not Fits(OfsArrays, Int64(NumArrays) * 20) or not Fits(OfsTris, Int64(NumTris) * 12) or
     not Fits(OfsJoints, Int64(NumJoints) * 48) then
  begin
    WritelnWarning('QuakeMdl', 'IQM "%s" is cut short or too large (%d meshes, %d vertices, %d joints, %d frames)',
      [FModelName, NumMeshes, NumVerts, NumJoints, NumFrames]);
    Exit;
  end;

  { The vertex arrays this loader uses }
  OfsPos := -1;
  OfsTex := -1;
  OfsIdx := -1;
  OfsWgt := -1;
  for I := 0 to NumArrays - 1 do
  begin
    Ofs := OfsArrays + I * 20;
    if (U32(Ofs) = IQM_POSITION) and (U32(Ofs + 8) = IQM_FLOAT) and (U32(Ofs + 12) = 3) then
      OfsPos := U32(Ofs + 16)
    else if (U32(Ofs) = IQM_TEXCOORD) and (U32(Ofs + 8) = IQM_FLOAT) and (U32(Ofs + 12) = 2) then
      OfsTex := U32(Ofs + 16)
    else if (U32(Ofs) = IQM_BLENDINDEXES) and (U32(Ofs + 8) = IQM_UBYTE) and (U32(Ofs + 12) = 4) then
      OfsIdx := U32(Ofs + 16)
    else if (U32(Ofs) = IQM_BLENDWEIGHTS) and (U32(Ofs + 8) = IQM_UBYTE) and (U32(Ofs + 12) = 4) then
      OfsWgt := U32(Ofs + 16);
  end;
  if (OfsPos < 0) or not Fits(OfsPos, Int64(NumVerts) * 12) or
     ((OfsTex >= 0) and not Fits(OfsTex, Int64(NumVerts) * 8)) or
     ((OfsIdx >= 0) and not Fits(OfsIdx, Int64(NumVerts) * 4)) or
     ((OfsWgt >= 0) and not Fits(OfsWgt, Int64(NumVerts) * 4)) then
  begin
    WritelnWarning('QuakeMdl', 'IQM "%s" has no positions this loader reads', [FModelName]);
    Exit;
  end;
  { Frames need the joints' poses and the vertices' bindings }
  if (OfsIdx < 0) or (OfsWgt < 0) or (NumPoses <> NumJoints) or (NumJoints = 0) or (NumFrames = 0) or
     not Fits(OfsPoses, Int64(NumPoses) * 88) or not Fits(OfsFrames, Int64(NumFrames) * NumChannels * 2) or
     (Int64(NumFrames) * NumVerts > 8 * 1024 * 1024) then
    NumFrames := 0;

  { The meshes: their textures side by side, each vertex in its mesh's part }
  SetLength(Names, NumMeshes);
  SetLength(VertPart, NumVerts);
  for V := 0 to NumVerts - 1 do
    VertPart[V] := 0;
  for M := 0 to NumMeshes - 1 do
  begin
    Ofs := OfsMeshes + M * 24;
    Names[M] := Text(U32(Ofs + 4));
    First := U32(Ofs + 8);
    Count := U32(Ofs + 12);
    if (First >= 0) and (Count >= 0) and (Int64(First) + Count <= NumVerts) then
      for V := First to First + Count - 1 do
        VertPart[V] := M;
  end;
  JoinSkin(Names, Parts, W, H, Missing);

  FNumVerts := NumVerts;
  FNumTris := NumTris;
  SetLength(Base, NumVerts);
  for V := 0 to NumVerts - 1 do
  begin
    Base[V] := Vec3(OfsPos + V * 12);
    if OfsTex >= 0 then
      FBaseUVs.Add(Vector2(
        Parts[VertPart[V]].U0 + EnsureRange(F32(OfsTex + V * 8), 0, 1) * Parts[VertPart[V]].UScale,
        Parts[VertPart[V]].V0 + (1 - EnsureRange(F32(OfsTex + V * 8 + 4), 0, 1)) * Parts[VertPart[V]].VScale))
    else
      FBaseUVs.Add(Vector2(Parts[VertPart[V]].U0, Parts[VertPart[V]].V0));
  end;
  for I := 0 to NumTris * 3 - 1 do
    FIndices.Add(EnsureRange(U32(OfsTris + I * 4), 0, NumVerts - 1));

  if NumFrames = 0 then
  begin
    { No animation: the model as it was made }
    Frame := TMdlFrame.Create;
    Frame.Name := 'base';
    for V := 0 to NumVerts - 1 do
      Frame.Coords.Add(QuakeToCge(Base[V]));
    FFrames.Add(Frame);
  end else
  begin
    { Where the joints are in the model as it was made, and the way back
      from there: a vertex is given in that pose }
    SetLength(BaseWorld, NumJoints);
    SetLength(InvBase, NumJoints);
    SetLength(Pose, NumJoints);
    SetLength(Skin, NumJoints);
    for J := 0 to NumJoints - 1 do
    begin
      Ofs := OfsJoints + J * 48;
      Parent := U32(Ofs + 4);
      BaseWorld[J] := AffineFromPose(Vec3(Ofs + 8),
        Vector4(F32(Ofs + 20), F32(Ofs + 24), F32(Ofs + 28), F32(Ofs + 32)), Vec3(Ofs + 36));
      { (a joint comes after its parent in the file) }
      if (Parent >= 0) and (Parent < J) then
        BaseWorld[J] := AffineMul(BaseWorld[Parent], BaseWorld[J]);
      InvBase[J] := AffineInverse(BaseWorld[J]);
    end;
    { The frames' names: the animation's and the frame's number in it }
    SetLength(FrameNames, NumFrames);
    for F := 0 to NumFrames - 1 do
      FrameNames[F] := 'frame' + IntToStr(F);
    if Fits(OfsAnims, Int64(NumAnims) * 20) then
      for I := 0 to NumAnims - 1 do
      begin
        Ofs := OfsAnims + I * 20;
        First := U32(Ofs + 4);
        Count := U32(Ofs + 8);
        for K := 0 to Count - 1 do
          if (First + K >= 0) and (First + K < NumFrames) then
            FrameNames[First + K] := LowerCase(Text(U32(Ofs))) + IntToStr(K + 1);
      end;
    for F := 0 to NumFrames - 1 do
    begin
      { The joints of this frame: each pose's ten channels are its fixed
        value, plus the frame's number times a scale where the mask says so }
      FrameOfs := OfsFrames + F * NumChannels * 2;
      K := 0;
      for J := 0 to NumJoints - 1 do
      begin
        Ofs := OfsPoses + J * 88;
        Parent := U32(Ofs);
        Mask := U32(Ofs + 4);
        for C := 0 to 9 do
        begin
          Channels[C] := F32(Ofs + 8 + C * 4);
          if (Mask and (1 shl C)) <> 0 then
          begin
            if K < NumChannels then
              Channels[C] := Channels[C] + U16(FrameOfs + K * 2) * F32(Ofs + 48 + C * 4);
            Inc(K);
          end;
        end;
        Pose[J] := AffineFromPose(Vector3(Channels[0], Channels[1], Channels[2]),
          Vector4(Channels[3], Channels[4], Channels[5], Channels[6]),
          Vector3(Channels[7], Channels[8], Channels[9]));
        if (Parent >= 0) and (Parent < J) then
          Pose[J] := AffineMul(Pose[Parent], Pose[J]);
        Skin[J] := AffineMul(Pose[J], InvBase[J]);
      end;
      Frame := TMdlFrame.Create;
      Frame.Name := FrameNames[F];
      for V := 0 to NumVerts - 1 do
      begin
        Moved := TVector3.Zero;
        Total := 0;
        for K := 0 to 3 do
        begin
          Weight := Data[OfsWgt + V * 4 + K] / 255;
          J := Data[OfsIdx + V * 4 + K];
          if (Weight > 0) and (J < NumJoints) then
          begin
            P := AffineApply(Skin[J], Base[V]);
            Moved := Moved + P * Weight;
            Total := Total + Weight;
          end;
        end;
        { A vertex no joint holds stays where it was made }
        if Total > 1e-4 then
          Moved := Moved * (1 / Total)
        else
          Moved := Base[V];
        Frame.Coords.Add(QuakeToCge(Moved));
      end;
      FFrames.Add(Frame);
    end;
  end;
  WritelnLog('QuakeMdl', 'IQM "%s": %d meshes joined (%d vertices, %d triangles, %d joints, %d frames, textures %d x %d)',
    [FModelName, NumMeshes, NumVerts, NumTris, NumJoints, FFrames.Count, W, H]);
  if Missing <> '' then
    WritelnWarning('QuakeMdl', 'IQM "%s": no texture %s in the paks', [FModelName, Missing]);
  Result := True;
end;
