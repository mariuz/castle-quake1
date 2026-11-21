{ The light on Alias models (R_LightPoint): a model takes the light of the
  world under it, from the lightmap of the floor it stands above (with the
  lightstyles: flickering torches; colored with a .lit file), plus the
  dynamic lights near it (muzzle flashes, explosions). The models' unlit
  materials are tinted with it. TQuakeMdl.CreateScene registers each scene;
  the views call UpdateModelLights once a frame. }
unit QuakeModelLight;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  CastleVectors, CastleScene, X3DNodes,
  QuakeBsp;

var
  { r_modellight: models take the world's light (False: full bright, as
    before 0.3.77) }
  ModelLight: Boolean = True;

const
  { A model in the dark still shows (Quake keeps 8 of 200 on monsters and
    24 on the weapon) }
  ModelLightMin = 0.12;
  { The world is drawn with a x2 overbright: a lightmap value of 128 is
    the texture's own brightness. Models stop a little above it. }
  ModelLightMax = 1.3;

{ Scene (an Alias model's) is tinted by UpdateModelLights through Material;
  FullBright models (flames, lightning) keep their own brightness }
procedure RegisterModelScene(const Scene: TCastleScene; const Material: TUnlitMaterialNode;
  const FullBright: Boolean);
{ Flames and lightning bolts are drawn full bright, like in GLQuake }
function ModelIsFullBright(const ModelName: String): Boolean;
{ The tint of a model at P (Quake coordinates): the world's light under it
  and the dynamic lights around it, as a factor on the skin's colors }
function ModelLightAt(const Bsp: TQuakeBsp; const P: TVector3): TVector3;
{ Tint every model scene in a world for this frame }
procedure UpdateModelLights(const Bsp: TQuakeBsp; const SecondsPassed: Single);
{ Counted by UpdateModelLights: the scenes tinted in the last call and
  their mean tint, and the most scenes a frame since the last call of this
  function saw in a dynamic light (for the log and the tests) }
function ModelLightStats: String;

implementation

uses
  Math, QuakeLight;

type
  { Owned by its scene, so it goes with it }
  TModelLightTag = class(TComponent)
  public
    Material: TUnlitMaterialNode;
    FullBright: Boolean;
    Current: TVector3;
    destructor Destroy; override;
  end;

var
  Tags: TList;
  StatScenes, StatDynamic, StatDynamicPeak: Integer;
  StatMean: Single;

destructor TModelLightTag.Destroy;
begin
  if Tags <> nil then
    Tags.Remove(Self);
  inherited Destroy;
end;

procedure RegisterModelScene(const Scene: TCastleScene; const Material: TUnlitMaterialNode;
  const FullBright: Boolean);
var
  Tag: TModelLightTag;
begin
  if (Scene = nil) or (Material = nil) then
    Exit;
  if Tags = nil then
    Tags := TList.Create;
  Tag := TModelLightTag.Create(Scene);
  Tag.Material := Material;
  Tag.FullBright := FullBright;
  Tag.Current := Vector3(1, 1, 1);
  Tags.Add(Tag);
end;

function ModelIsFullBright(const ModelName: String): Boolean;
var
  N: String;
begin
  N := LowerCase(ExtractFileName(ModelName));
  Result := (Pos('flame', N) = 1) or (Pos('bolt', N) = 1) or (N = 'lavaball.mdl') or (N = 'laser.mdl') or
    (N = 's_light.mdl');
end;

{ The dynamic lights' part at P (CGE coordinates), in lightmap units }
function DynamicLightAt(const CgePoint: TVector3): Single;
var
  I: Integer;
  L: TVector4;
  D: Single;
begin
  Result := 0;
  if Lighting = nil then
    Exit;
  for I := 0 to MaxDLights - 1 do
  begin
    L := Lighting.DLightUniform(I);
    if L.W <= 0 then
      Continue;
    D := PointsDistance(CgePoint, L.XYZ);
    if D < L.W then
      Result := Result + (L.W - D);
  end;
end;

function ModelLightAt(const Bsp: TQuakeBsp; const P: TVector3): TVector3;
var
  Styles: array[0..63] of Single;
  I: Integer;
  Add: Single;
begin
  for I := 0 to High(Styles) do
    if Lighting <> nil then
      Styles[I] := Lighting.GetStyleMultiplier(I)
    else
      Styles[I] := 1;
  if (Bsp = nil) or not Bsp.LightPoint(P, Styles, Result) then
    { Nothing below (a model outside the map, a map without lightmaps) }
    Result := Vector3(128, 128, 128);
  Add := DynamicLightAt(QuakeToCge(P));
  Result := (Result + Vector3(Add, Add, Add)) / 128;
  for I := 0 to 2 do
    Result.Data[I] := EnsureRange(Result.Data[I], ModelLightMin, ModelLightMax);
end;

procedure UpdateModelLights(const Bsp: TQuakeBsp; const SecondsPassed: Single);
var
  I: Integer;
  Tag: TModelLightTag;
  Scene: TCastleScene;
  Target, Pos: TVector3;
  Blend, Sum: Single;
begin
  StatScenes := 0;
  StatDynamic := 0;
  StatMean := 0;
  if Tags = nil then
    Exit;
  Sum := 0;
  { The light follows in about a tenth of a second: no popping when a
    model crosses a lightmap texel }
  Blend := EnsureRange(SecondsPassed * 12, 0, 1);
  for I := 0 to Tags.Count - 1 do
  begin
    Tag := TModelLightTag(Tags[I]);
    Scene := TCastleScene(Tag.Owner);
    if (Scene.World = nil) or not Scene.Exists then
      Continue;
    if Tag.FullBright or not ModelLight then
      Target := Vector3(1, 1, 1)
    else
    begin
      Pos := Scene.WorldTransform.MultPoint(TVector3.Zero);
      Target := ModelLightAt(Bsp, CgeToQuake(Pos));
      if DynamicLightAt(Pos) > 0 then
        Inc(StatDynamic);
    end;
    Inc(StatScenes);
    Target := Tag.Current + (Target - Tag.Current) * Blend;
    Sum := Sum + (Target.X + Target.Y + Target.Z) / 3;
    { The material changes only when the tint really does }
    if PointsDistanceSqr(Target, Tag.Current) > Sqr(0.004) then
    begin
      Tag.Current := Target;
      Tag.Material.EmissiveColor := Target;
    end;
  end;
  if StatScenes > 0 then
    StatMean := Sum / StatScenes;
  if StatDynamic > StatDynamicPeak then
    StatDynamicPeak := StatDynamic;
end;

function ModelLightStats: String;
begin
  { A flash lasts a tenth of a second: the most models any frame since the
    last call saw in one }
  Result := Format('%d models lit, %d by dynamic lights, mean %.2f', [StatScenes, StatDynamicPeak, StatMean]);
  StatDynamicPeak := 0;
end;

finalization
  FreeAndNil(Tags);
end.
