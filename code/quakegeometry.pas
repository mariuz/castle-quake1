{ Quake 1 BSP geometry to Castle Game Engine X3D scenes converter. }
unit QuakeGeometry;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, Math,
  CastleVectors, CastleScene, CastleTransform, X3DNodes, CastleLog, CastleColors,
  CastleImages, CastleUtils, CastleRenderOptions, X3DFields,
  QuakeBsp, QuakePalette, QuakeLight, QuakePak, X3DLoad, CastleUriUtils;

type
  { Lightmap atlases (one per lightstyle slot) of a BSP model and the shader
    that blends them with the live lightstyle values and dynamic lights }
  TQuakeLightmapSet = record
    Layers: array[0..3] of TPixelTextureNode;
    LayerCount: Integer;
    Effect: TEffectNode;
    StylesField: TMFFloat;
    DLightsField: TMFVec4f;
  end;

  { A batch of triangles sharing one texture }
  TQuakeGeomBatch = class
  public
    TextureName: String;
    Coords: TVector3List;
    TexCoords: TVector2List;
    LMTexCoords: TVector2List;
    LMStyles: TSingleList; { 4 lightstyle indexes per vertex }
    Normals: TVector3List;
    Indices: TInt32List;
    TexNode: TImageTextureNode;
    Shape: TShapeNode;
    Geometry: TIndexedTriangleSetNode;
    CoordNode: TCoordinateNode;
    TexCoordNode: TTextureCoordinateNode;
    NormalNode: TNormalNode;
    Appearance: TAppearanceNode;
    Material: TMaterialNode;
    IsSky: Boolean;
    IsLiquid: Boolean;
    { Shader uniforms of the sky effect (only when IsSky), owned by the X3D graph }
    SkyTimeField: TSFFloat;
    SkyEyeField: TSFVec3f;
    { Time uniform of the liquid warp effect (only when IsLiquid) }
    LiquidTimeField: TSFFloat;
    constructor Create(const ATexName: String);
    destructor Destroy; override;
    procedure AddPolygon(const Verts: array of TVector3; const UVs, LMUVs: array of TVector2;
      const Normal: TVector3; const Styles: TVector4);
    { Build X3D nodes. Lightmaps.Effect may be nil (then the batch is fullbright). }
    procedure CreateNodes(const MapName: String; const Lightmaps: TQuakeLightmapSet);
  end;

  { Packs the per-face Quake lightmaps (8-bit luminance, one map per
    lightstyle slot) into atlases, one per slot }
  TQuakeLightmapAtlas = class
  private
    FWidth, FHeight: Integer;
    FData: array[0..3] of array of Byte;
    FLayerUsed: array[0..3] of Boolean;
    FShelfX, FShelfY, FShelfH: Integer;
    FUsedHeight: Integer;
  public
    constructor Create(const AWidth: Integer = 1024; const AMaxHeight: Integer = 4096);
    { Reserve a W x H block. Returns False if the atlas is full. }
    function Allocate(const W, H: Integer; out X, Y: Integer): Boolean;
    procedure SetTexel(const Layer, X, Y: Integer; const Value: Byte);
    { Create the texture of a lightstyle slot; nil if nothing was packed in it }
    function CreateTextureNode(const Layer: Integer): TPixelTextureNode;
    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
  end;

  TQuakeGeomBatchDict = specialize TObjectDictionary<String, TQuakeGeomBatch>;

  { Movable submodel instance (func_door, func_plat, func_button, etc.) }
  TQuakeSubmodel = class
  public
    ModelIndex: Integer;
    EntityClassName: String;
    Transform: TCastleTransform;
    Scene: TCastleScene;
    Mins: TVector3;
    Maxs: TVector3;
    Origin: TVector3;
    ClosedPos: TVector3;
    OpenPos: TVector3;
    TargetPos: TVector3;
    MoveDir: TVector3;
    Speed: Single;
    WaitTime: Single;
    StateTimer: Single;
    State: (smsClosed, smsOpening, smsOpen, smsClosing);
    Target: String;
    TargetName: String;
    Sounds: Integer;
    SpawnFlags: Integer;
    { func_door locked with a key: 1 silver, 2 gold (DOOR_SILVER_KEY,
      DOOR_GOLD_KEY spawnflags); it opens by touch with the key and stays open }
    KeyNeeded: Integer;
    { func_plat that rests at the bottom (ClosedPos = top, OpenPos = bottom) and
      rises when stood on; returns down 3 seconds after reaching the top }
    IsAutoPlat: Boolean;
    constructor Create;
    destructor Destroy; override;
    procedure Update(const SecondsPassed: Single);
    procedure Trigger;
    { The player stands on an auto plat (plat_center_touch) }
    procedure PlatTouched;
  end;

  TQuakeSubmodelList = specialize TObjectList<TQuakeSubmodel>;

  { Animated texture tracking group }
  TQuakeAnimTex = class
  public
    BaseName: String;
    Frames: TStringList;
    CurrentFrame: Integer;
    TexNodes: specialize TList<TImageTextureNode>;
    Timer: Single;
    MapName: String;
    constructor Create(const ABaseName, AMapName: String);
    destructor Destroy; override;
    procedure AddNode(const Node: TImageTextureNode);
    procedure Update(const SecondsPassed: Single);
  end;

  TQuakeAnimTexList = specialize TObjectList<TQuakeAnimTex>;

  TSFFloatList = specialize TList<TSFFloat>;
  TSFVec3fList = specialize TList<TSFVec3f>;

  { World geometry builder and manager }
  TQuakeGeometry = class
  private
    FBsp: TQuakeBsp;
    FSceneWorld: TCastleScene;
    FWorldTransform: TCastleTransform;
    FSubmodels: TQuakeSubmodelList;
    FAnimTextures: TQuakeAnimTexList;
    FSkyTimeFields: TSFFloatList;
    FSkyEyeFields: TSFVec3fList;
    FLiquidTimeFields: TSFFloatList;
    FLiquidMaterials: specialize TList<TUnlitMaterialNode>;
    FLiquidAlpha: Single;
    FSkyTime, FLiquidTime: Single;
    FLightmapSets: array of TQuakeLightmapSet;
    FLastStyles: array[0..63] of Single;
    FDLightsOn: Boolean;
    procedure SetLiquidAlpha(const Value: Single);
    function CreateLightmapSet(const Atlas: TQuakeLightmapAtlas): TQuakeLightmapSet;
    procedure BuildModelGeometry(const ModelIdx: Integer; const RootNode: TX3DRootNode;
      var OutBatches: TQuakeGeomBatchDict);
    procedure SetupSubmodels(const Parent: TCastleTransform);
    procedure RegisterAnimNode(const TexName: String; const Node: TImageTextureNode);
  public
    { Skill the brush entities are spawned for (set before AddToWorld) }
    Skill: Integer;
    constructor Create(const ABsp: TQuakeBsp);
    destructor Destroy; override;

    { Build all geometry and add to parent transform (viewport.Items) }
    procedure AddToWorld(const Parent: TCastleTransform);

    { Write the level as one X3D (or glTF, by the extension) file: the
      world and every brush entity as named transforms at their map
      positions, the light entities as point lights, the textures as PNG
      files in a "textures" folder next to it (the lightmaps are inline).
      Opens in the CGE editor, view3dscene or any X3D / glTF viewer. }
    function ExportMap(const Url: String): Boolean;

    { Advance animated textures, submodels and the scrolling sky.
      EyePos is the viewer position, used to project the sky layers. }
    procedure Update(const SecondsPassed: Single; const EyePos: TVector3);

    { True if T is the world scene or the scene of a brush entity (door, plat...) }
    function IsGeometryScene(const T: TCastleTransform): Boolean;

    { Find submodel by targetname or model string like "*1" }
    function FindSubmodel(const AName: String): TQuakeSubmodel;

    property SceneWorld: TCastleScene read FSceneWorld;
    { r_wateralpha: opacity of water, slime and lava surfaces, both from
      above and from inside (the surfaces are two sided), default 0.65 }
    property LiquidAlpha: Single read FLiquidAlpha write SetLiquidAlpha;
    property WorldTransform: TCastleTransform read FWorldTransform;
    property Submodels: TQuakeSubmodelList read FSubmodels;
  end;

var
  { World surfaces: True = Quake's baked lightmaps blended in a shader
    (lightstyles, dynamic lights), False = lit materials under the engine's
    real-time lights. Takes effect when a map is loaded. }
  WorldLightmaps: Boolean = True;

var
  { The skybox of the map being built (gfx/env/<name>), '' for the scrolling sky }
  SkyboxName: String;
  { r_wateralpha for the maps built from now on }
  DefaultLiquidAlpha: Single = 0.65;

{ The six faces of a skybox are in the paks }
function SkyboxAvailable(const Name: String): Boolean;

implementation

const
  { Quake sky (R_DrawSkyChain / EmitSkyPolys in GLQuake), evaluated per fragment.
    The view direction is flattened vertically (z * 3) and scaled to a fixed length,
    which projects both layers onto a low dome above the player.
    The back layer scrolls at 8 texels/s, the front (clouds) layer at 16 texels/s. }
  SkyVertexShader =
    'varying highp vec3 quake_sky_position;' + LineEnding +
    'void PLUG_vertex_object_space(const in vec4 vertex_object, const in vec3 normal_object)' + LineEnding +
    '{' + LineEnding +
    '  quake_sky_position = vec3(vertex_object);' + LineEnding +
    '}' + LineEnding;

  SkyFragmentShader =
    'uniform sampler2D sky_back;' + LineEnding +
    'uniform sampler2D sky_front;' + LineEnding +
    'uniform float sky_time;' + LineEnding +
    'uniform vec3 sky_eye;' + LineEnding +
    'varying highp vec3 quake_sky_position;' + LineEnding +
    'void PLUG_main_texture_apply(inout vec4 fragment_color, const in vec3 normal)' + LineEnding +
    '{' + LineEnding +
    '  /* CGE -> Quake axes: Quake.X = X, Quake.Y = -Z, Quake.Z = Y */' + LineEnding +
    '  highp vec3 d = quake_sky_position - sky_eye;' + LineEnding +
    '  highp vec2 dir = vec2(d.x, -d.z);' + LineEnding +
    '  highp float len = length(vec3(dir, d.y * 3.0));' + LineEnding +
    '  dir *= 378.0 / max(len, 0.001);' + LineEnding +
    '  vec4 back = texture2D(sky_back, (vec2(sky_time * 8.0) + dir) / 128.0);' + LineEnding +
    '  vec4 front = texture2D(sky_front, (vec2(sky_time * 16.0) + dir) / 128.0);' + LineEnding +
    '  fragment_color = vec4(mix(back.rgb, front.rgb, front.a), 1.0);' + LineEnding +
    '}' + LineEnding;

  { A six face skybox (the "sky" worldspawn key of the engines after
    GLQuake: gfx/env/<name>rt|bk|lf|ft|up|dn.tga) sampled by the view
    direction in Quake axes, the faces oriented like Sky_ProjectPoly /
    vec_to_st of the original skybox code }
  SkyboxFragmentShader =
    'uniform sampler2D skybox_rt;' + LineEnding +
    'uniform sampler2D skybox_bk;' + LineEnding +
    'uniform sampler2D skybox_lf;' + LineEnding +
    'uniform sampler2D skybox_ft;' + LineEnding +
    'uniform sampler2D skybox_up;' + LineEnding +
    'uniform sampler2D skybox_dn;' + LineEnding +
    'uniform vec3 sky_eye;' + LineEnding +
    'varying highp vec3 quake_sky_position;' + LineEnding +
    'void PLUG_main_texture_apply(inout vec4 fragment_color, const in vec3 normal)' + LineEnding +
    '{' + LineEnding +
    '  highp vec3 d = quake_sky_position - sky_eye;' + LineEnding +
    '  highp vec3 v = vec3(d.x, -d.z, d.y);' + LineEnding +
    '  highp vec3 a = abs(v);' + LineEnding +
    '  highp float s, t;' + LineEnding +
    '  vec4 c;' + LineEnding +
    '  if (a.x >= a.y && a.x >= a.z)' + LineEnding +
    '  {' + LineEnding +
    '    if (v.x > 0.0) { s = -v.y / v.x; t = v.z / v.x; c = texture2D(skybox_rt, vec2((s + 1.0) * 0.5, (t + 1.0) * 0.5)); }' + LineEnding +
    '    else { s = -v.y / v.x; t = -v.z / v.x; c = texture2D(skybox_bk, vec2((s + 1.0) * 0.5, (t + 1.0) * 0.5)); }' + LineEnding +
    '  }' + LineEnding +
    '  else if (a.y >= a.z)' + LineEnding +
    '  {' + LineEnding +
    '    if (v.y > 0.0) { s = v.x / v.y; t = v.z / v.y; c = texture2D(skybox_lf, vec2((s + 1.0) * 0.5, (t + 1.0) * 0.5)); }' + LineEnding +
    '    else { s = v.x / v.y; t = -v.z / v.y; c = texture2D(skybox_ft, vec2((s + 1.0) * 0.5, (t + 1.0) * 0.5)); }' + LineEnding +
    '  }' + LineEnding +
    '  else' + LineEnding +
    '  {' + LineEnding +
    '    if (v.z > 0.0) { s = -v.y / v.z; t = -v.x / v.z; c = texture2D(skybox_up, vec2((s + 1.0) * 0.5, (t + 1.0) * 0.5)); }' + LineEnding +
    '    else { s = v.y / v.z; t = -v.x / v.z; c = texture2D(skybox_dn, vec2((s + 1.0) * 0.5, (t + 1.0) * 0.5)); }' + LineEnding +
    '  }' + LineEnding +
    '  fragment_color = vec4(c.rgb, 1.0);' + LineEnding +
    '}' + LineEnding;

  { EmitWaterPolys / R_Turbulent: the texture coordinates of water, slime,
    lava and teleporters ripple with turbsin (8 texels of a 64 texel
    texture, period 2 pi) }
  LiquidFragmentShader =
    'uniform float liquid_time;' + LineEnding +
    'void PLUG_texture_coord_shift(inout vec2 tex_coord)' + LineEnding +
    '{' + LineEnding +
    '  vec2 uv = tex_coord;' + LineEnding +
    '  tex_coord.x = uv.x + 0.125 * sin(uv.y * 8.0 + liquid_time);' + LineEnding +
    '  tex_coord.y = uv.y + 0.125 * sin(uv.x * 8.0 + liquid_time);' + LineEnding +
    '}' + LineEnding;

  { R_BuildLightMap in a shader: the lightmaps of the face's lightstyle
    slots, scaled by the current lightstyle values, plus the dynamic lights
    (R_AddDynamicLights); x2 overbright like Quake's colormap }
  LightmapVertexShader =
    'attribute vec2 quake_lm_coord;' + LineEnding +
    'attribute vec4 quake_styles;' + LineEnding +
    'varying vec2 quake_lm_coord_v;' + LineEnding +
    'varying vec4 quake_styles_v;' + LineEnding +
    'varying vec3 quake_pos_v;' + LineEnding +
    'void PLUG_vertex_object_space(const in vec4 vertex_object, const in vec3 normal_object)' + LineEnding +
    '{' + LineEnding +
    '  quake_lm_coord_v = quake_lm_coord;' + LineEnding +
    '  quake_styles_v = quake_styles;' + LineEnding +
    '  quake_pos_v = vec3(vertex_object);' + LineEnding +
    '}' + LineEnding;

  LightmapFragmentShader =
    'uniform sampler2D quake_lm0;' + LineEnding +
    'uniform sampler2D quake_lm1;' + LineEnding +
    'uniform sampler2D quake_lm2;' + LineEnding +
    'uniform sampler2D quake_lm3;' + LineEnding +
    'uniform int quake_lm_layers;' + LineEnding +
    'uniform float quake_lightstyles[64];' + LineEnding +
    'uniform vec4 quake_dlights[4];' + LineEnding +
    'varying vec2 quake_lm_coord_v;' + LineEnding +
    'varying vec4 quake_styles_v;' + LineEnding +
    'varying vec3 quake_pos_v;' + LineEnding +
    'float quake_style(float s)' + LineEnding +
    '{' + LineEnding +
    '  int i = int(s + 0.5);' + LineEnding +
    '  if (i < 0 || i > 63) return 0.0;' + LineEnding +
    '  return quake_lightstyles[i];' + LineEnding +
    '}' + LineEnding +
    'void PLUG_main_texture_apply(inout vec4 fragment_color, const in vec3 normal)' + LineEnding +
    '{' + LineEnding +
    '  float light = 0.0;' + LineEnding +
    '  if (quake_lm_layers > 0 && quake_styles_v.x < 254.5)' + LineEnding +
    '    light += texture2D(quake_lm0, quake_lm_coord_v).r * quake_style(quake_styles_v.x);' + LineEnding +
    '  if (quake_lm_layers > 1 && quake_styles_v.y < 254.5)' + LineEnding +
    '    light += texture2D(quake_lm1, quake_lm_coord_v).r * quake_style(quake_styles_v.y);' + LineEnding +
    '  if (quake_lm_layers > 2 && quake_styles_v.z < 254.5)' + LineEnding +
    '    light += texture2D(quake_lm2, quake_lm_coord_v).r * quake_style(quake_styles_v.z);' + LineEnding +
    '  if (quake_lm_layers > 3 && quake_styles_v.w < 254.5)' + LineEnding +
    '    light += texture2D(quake_lm3, quake_lm_coord_v).r * quake_style(quake_styles_v.w);' + LineEnding +
    '  for (int i = 0; i < 4; i++)' + LineEnding +
    '  {' + LineEnding +
    '    float rad = quake_dlights[i].w;' + LineEnding +
    '    if (rad > 0.0)' + LineEnding +
    '      light += max(rad - distance(quake_pos_v, quake_dlights[i].xyz), 0.0) / 255.0;' + LineEnding +
    '  }' + LineEnding +
    '  /* The fullbright palette entries (alpha 255 of the texture) keep their color */' + LineEnding +
    '  fragment_color.rgb *= mix(min(light, 1.0) * 2.0, 1.0, fragment_color.a);' + LineEnding +
    '  fragment_color.a = 1.0;' + LineEnding +
    '}' + LineEnding;

  { Both layers repeat after 128 texels: 16 s for the back one, 8 s for the front one.
    Wrapping keeps the shader time small (float precision). }
  SkyTimePeriod = 16.0;

function CreateSkyLayerTexture(const Url: String; const TexProps: TTexturePropertiesNode): TImageTextureNode;
begin
  Result := TImageTextureNode.Create;
  Result.SetUrl([Url]);
  Result.RepeatS := True;
  Result.RepeatT := True;
  Result.TextureProperties := TexProps;
end;

const
  SkyboxSuffixes: array[0..5] of String = ('rt', 'bk', 'lf', 'ft', 'up', 'dn');

function SkyboxAvailable(const Name: String): Boolean;
var
  I: Integer;
begin
  Result := Name <> '';
  for I := 0 to 5 do
    if Result and not Pak.FileExists('gfx/env/' + Name + SkyboxSuffixes[I] + '.tga') then
      Result := False;
end;

function CreateSkyboxTexture(const Name, Suffix: String): TImageTextureNode;
begin
  Result := TImageTextureNode.Create;
  Result.SetUrl(['quakepak:/gfx/env/' + Name + Suffix + '.tga']);
  Result.RepeatS := False;
  Result.RepeatT := False;
end;

{ TQuakeGeomBatch }

constructor TQuakeGeomBatch.Create(const ATexName: String);
begin
  inherited Create;
  TextureName := ATexName;
  Coords := TVector3List.Create;
  TexCoords := TVector2List.Create;
  LMTexCoords := TVector2List.Create;
  LMStyles := TSingleList.Create;
  Normals := TVector3List.Create;
  Indices := TInt32List.Create;
  IsSky := (Pos('sky', LowerCase(ATexName)) = 1);
  IsLiquid := (Length(ATexName) > 0) and (ATexName[1] = '*');
end;

destructor TQuakeGeomBatch.Destroy;
begin
  Coords.Free;
  TexCoords.Free;
  LMTexCoords.Free;
  LMStyles.Free;
  Normals.Free;
  Indices.Free;
  inherited Destroy;
end;

procedure TQuakeGeomBatch.AddPolygon(const Verts: array of TVector3; const UVs, LMUVs: array of TVector2;
  const Normal: TVector3; const Styles: TVector4);
var
  BaseIdx, I: Integer;
begin
  if Length(Verts) < 3 then
    Exit;

  BaseIdx := Coords.Count;
  for I := 0 to High(Verts) do
  begin
    Coords.Add(Verts[I]);
    TexCoords.Add(UVs[I]);
    LMTexCoords.Add(LMUVs[I]);
    LMStyles.Add(Styles.X);
    LMStyles.Add(Styles.Y);
    LMStyles.Add(Styles.Z);
    LMStyles.Add(Styles.W);
    Normals.Add(Normal);
  end;

  { Triangle fan: 0, i, i+1 (Quake winding is clockwise, see Geometry.Ccw) }
  for I := 1 to High(Verts) - 1 do
  begin
    Indices.Add(BaseIdx);
    Indices.Add(BaseIdx + I);
    Indices.Add(BaseIdx + I + 1);
  end;
end;

procedure TQuakeGeomBatch.CreateNodes(const MapName: String; const Lightmaps: TQuakeLightmapSet);
var
  TexProps: TTexturePropertiesNode;
  UnlitMat: TUnlitMaterialNode;
  PhysMat: TPhysicalMaterialNode;
  LMCoordAttrib, StylesAttrib: TFloatVertexAttributeNode;
  UseLightmap, UseSkyShader, UseSkybox: Boolean;
  SkyEffect, LiquidEffect: TEffectNode;
  VertexPart, FragmentPart: TEffectPartNode;
  I: Integer;
begin
  if Coords.Count = 0 then
    Exit;

  CoordNode := TCoordinateNode.Create;
  CoordNode.SetPoint(Coords);

  TexCoordNode := TTextureCoordinateNode.Create;
  TexCoordNode.SetPoint(TexCoords);

  NormalNode := TNormalNode.Create;
  NormalNode.SetVector(Normals);

  Geometry := TIndexedTriangleSetNode.Create;
  Geometry.Coord := CoordNode;
  Geometry.Normal := NormalNode;
  Geometry.SetIndex(Indices);
  { Quake BSP polygons are wound clockwise when seen from the front.
    X3D assumes counter-clockwise, so without this the renderer culls the
    visible side of every wall and you see the map "inside out". }
  Geometry.Ccw := False;
  Geometry.Solid := not IsLiquid;
  Geometry.NormalPerVertex := True; { one (face) normal per vertex }

  Appearance := TAppearanceNode.Create;

  { Texture properties for sharp retro filtering }
  TexProps := TTexturePropertiesNode.Create;
  TexProps.MagnificationFilter := magNearest;
  TexProps.MinificationFilter := minNearestMipmapLinear;
  TexProps.AnisotropicDegree := 4;

  { Sky layers exist only for standard 256x128 sky miptexes (see TQuakeBsp.CacheSkyLayers) }
  UseSkybox := IsSky and SkyboxAvailable(SkyboxName);
  UseSkyShader := UseSkybox or (IsSky and
    Palette.HasCachedImage('map/' + MapName + '/' + TextureName + SKY_BACK_SUFFIX));

  if not UseSkyShader then
  begin
    TexNode := TImageTextureNode.Create;
    TexNode.SetUrl(['quaketex:/map/' + MapName + '/' + TextureName]);
    TexNode.RepeatS := True;
    TexNode.RepeatT := True;
    TexNode.TextureProperties := TexProps;
  end;

  UseLightmap := WorldLightmaps and (Lightmaps.Effect <> nil) and (not IsSky) and (not IsLiquid);
  UnlitMat := nil;
  if WorldLightmaps or IsSky or IsLiquid or UseSkyShader then
  begin
    { Quake surfaces are not lit dynamically: the look comes from the baked
      lightmaps, blended by the lightmap shader below }
    UnlitMat := TUnlitMaterialNode.Create;
    UnlitMat.EmissiveColor := Vector3(1, 1, 1);
    Appearance.Material := UnlitMat;
  end else
  begin
    { Dynamic lighting: the surface is lit by the engine's lights (and
      shadow maps) like any PBR material }
    PhysMat := TPhysicalMaterialNode.Create;
    PhysMat.BaseColor := Vector3(1, 1, 1);
    PhysMat.Metallic := 0;
    PhysMat.Roughness := 0.9;
    { A little minlight so unlit corners are not pitch black }
    PhysMat.EmissiveColor := Vector3(0.08, 0.08, 0.08);
    if TexNode <> nil then
      PhysMat.BaseTexture := TexNode;
    Appearance.Material := PhysMat;
  end;

  if UseSkyShader then
  begin
    { No regular texture: the sky effect computes the color from both layers
      of the scrolling sky, or from the six faces of the skybox }
    SkyEffect := TEffectNode.Create;
    SkyEffect.Language := slGLSL;
    SkyEffect.UniformMissing := umIgnore;
    if UseSkybox then
    begin
      for I := 0 to 5 do
        SkyEffect.AddCustomField(TSFNode.Create(SkyEffect, False, 'skybox_' + SkyboxSuffixes[I], [],
          CreateSkyboxTexture(SkyboxName, SkyboxSuffixes[I])));
    end else
    begin
      SkyEffect.AddCustomField(TSFNode.Create(SkyEffect, False, 'sky_back', [],
        CreateSkyLayerTexture('quaketex:/map/' + MapName + '/' + TextureName + SKY_BACK_SUFFIX, TexProps)));
      SkyEffect.AddCustomField(TSFNode.Create(SkyEffect, False, 'sky_front', [],
        CreateSkyLayerTexture('quaketex:/map/' + MapName + '/' + TextureName + SKY_FRONT_SUFFIX, TexProps)));
    end;
    SkyTimeField := TSFFloat.Create(SkyEffect, True, 'sky_time', 0);
    SkyEffect.AddCustomField(SkyTimeField);
    SkyEyeField := TSFVec3f.Create(SkyEffect, True, 'sky_eye', TVector3.Zero);
    SkyEffect.AddCustomField(SkyEyeField);

    VertexPart := TEffectPartNode.Create;
    VertexPart.ShaderType := stVertex;
    VertexPart.Contents := SkyVertexShader;
    FragmentPart := TEffectPartNode.Create;
    FragmentPart.ShaderType := stFragment;
    if UseSkybox then
      FragmentPart.Contents := SkyboxFragmentShader
    else
      FragmentPart.Contents := SkyFragmentShader;
    SkyEffect.SetParts([VertexPart, FragmentPart]);
    Appearance.SetEffects([SkyEffect]);
    Geometry.TexCoord := TexCoordNode;
  end else
  if UseLightmap then
  begin
    Appearance.Texture := TexNode;
    Geometry.TexCoord := TexCoordNode;
    { Lightmap coordinates and the face's lightstyles go to the shader as
      vertex attributes }
    LMCoordAttrib := TFloatVertexAttributeNode.Create;
    LMCoordAttrib.NameField := 'quake_lm_coord';
    LMCoordAttrib.NumComponents := 2;
    LMCoordAttrib.FdValue.Items.Count := LMTexCoords.Count * 2;
    Move(LMTexCoords.L^, LMCoordAttrib.FdValue.Items.L^, LMTexCoords.Count * SizeOf(TVector2));
    StylesAttrib := TFloatVertexAttributeNode.Create;
    StylesAttrib.NameField := 'quake_styles';
    StylesAttrib.NumComponents := 4;
    StylesAttrib.FdValue.Items.Assign(LMStyles);
    Geometry.FdAttrib.Add(LMCoordAttrib);
    Geometry.FdAttrib.Add(StylesAttrib);
    Appearance.SetEffects([Lightmaps.Effect]);
  end else
  begin
    if UnlitMat <> nil then
      Appearance.Texture := TexNode;
    Geometry.TexCoord := TexCoordNode;
  end;

  if IsLiquid and (UnlitMat <> nil) then
  begin
    UnlitMat.Transparency := 1 - DefaultLiquidAlpha;
    Appearance.AlphaMode := amBlend;
    { The turbulent texture warp }
    LiquidEffect := TEffectNode.Create;
    LiquidEffect.Language := slGLSL;
    LiquidEffect.UniformMissing := umIgnore;
    LiquidTimeField := TSFFloat.Create(LiquidEffect, True, 'liquid_time', 0);
    LiquidEffect.AddCustomField(LiquidTimeField);
    FragmentPart := TEffectPartNode.Create;
    FragmentPart.ShaderType := stFragment;
    FragmentPart.Contents := LiquidFragmentShader;
    LiquidEffect.SetParts([FragmentPart]);
    Appearance.SetEffects([LiquidEffect]);
  end else
    Appearance.AlphaMode := amOpaque;

  Shape := TShapeNode.Create;
  Shape.Geometry := Geometry;
  Shape.Appearance := Appearance;
  { Liquid surfaces are not solid in Quake: the player has to be able to dive in }
  if IsLiquid then
    Shape.Collision := scNone;
end;

{ TQuakeLightmapAtlas }

constructor TQuakeLightmapAtlas.Create(const AWidth, AMaxHeight: Integer);
var
  X, Y, L: Integer;
begin
  inherited Create;
  FWidth := AWidth;
  FHeight := AMaxHeight;
  for L := 0 to 3 do
  begin
    SetLength(FData[L], FWidth * FHeight);
    FillChar(FData[L][0], Length(FData[L]), 0);
  end;
  { Reserve a 4x4 block at (0,0) filled with 128 (mid-gray = 1.0 with the x2
    overbright) so faces without a lightmap can sample (2,2) without bleeding }
  for Y := 0 to 3 do
    for X := 0 to 3 do
      FData[0][Y * FWidth + X] := 128;
  FLayerUsed[0] := True;
  FShelfX := 5; { 1 texel padding after the 4x4 block }
  FShelfY := 0;
  FShelfH := 4;
  FUsedHeight := 4;
end;

function TQuakeLightmapAtlas.Allocate(const W, H: Integer; out X, Y: Integer): Boolean;
begin
  Result := False;
  X := 0;
  Y := 0;
  if (W > FWidth) or (W <= 0) or (H <= 0) then
    Exit;
  { 1 texel padding to avoid bleeding with linear filtering }
  if FShelfX + W + 1 > FWidth then
  begin
    FShelfY := FShelfY + FShelfH + 1;
    FShelfX := 0;
    FShelfH := 0;
  end;
  if FShelfY + H > FHeight then
    Exit;
  X := FShelfX;
  Y := FShelfY;
  FShelfX := FShelfX + W + 1;
  if H > FShelfH then
    FShelfH := H;
  if Y + H > FUsedHeight then
    FUsedHeight := Y + H;
  Result := True;
end;

procedure TQuakeLightmapAtlas.SetTexel(const Layer, X, Y: Integer; const Value: Byte);
begin
  if (Layer >= 0) and (Layer <= 3) and (X >= 0) and (X < FWidth) and (Y >= 0) and (Y < FHeight) then
  begin
    FData[Layer][Y * FWidth + X] := Value;
    FLayerUsed[Layer] := True;
  end;
end;

function TQuakeLightmapAtlas.CreateTextureNode(const Layer: Integer): TPixelTextureNode;
var
  Img: TGrayscaleImage;
  Y, H: Integer;
  TexProps: TTexturePropertiesNode;
begin
  Result := nil;
  if (FUsedHeight = 0) or (Layer < 0) or (Layer > 3) or not FLayerUsed[Layer] then
    Exit;

  { The full atlas: the lightmap coordinates were computed against it }
  H := FHeight;
  Img := TGrayscaleImage.Create(FWidth, H);
  for Y := 0 to H - 1 do
    Move(FData[Layer][Y * FWidth], Img.PixelPtr(0, Y)^, FWidth);

  TexProps := TTexturePropertiesNode.Create;
  TexProps.MagnificationFilter := magLinear;
  TexProps.MinificationFilter := minLinear;
  TexProps.BoundaryModeS := bmClampToEdge;
  TexProps.BoundaryModeT := bmClampToEdge;

  Result := TPixelTextureNode.Create;
  Result.FdImage.Value := Img;
  Result.RepeatS := False;
  Result.RepeatT := False;
  Result.TextureProperties := TexProps;
end;

{ TQuakeSubmodel }

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

{ TQuakeAnimTex }

constructor TQuakeAnimTex.Create(const ABaseName, AMapName: String);
begin
  inherited Create;
  BaseName := ABaseName;
  MapName := AMapName;
  Frames := TStringList.Create;
  TexNodes := specialize TList<TImageTextureNode>.Create;
  CurrentFrame := 0;
  Timer := 0;
end;

destructor TQuakeAnimTex.Destroy;
begin
  Frames.Free;
  TexNodes.Free;
  inherited Destroy;
end;

procedure TQuakeAnimTex.AddNode(const Node: TImageTextureNode);
begin
  TexNodes.Add(Node);
end;

procedure TQuakeAnimTex.Update(const SecondsPassed: Single);
var
  Node: TImageTextureNode;
  NewFrame: String;
begin
  if Frames.Count <= 1 then
    Exit;

  Timer := Timer + SecondsPassed;
  if Timer >= 0.2 then
  begin
    Timer := 0;
    CurrentFrame := (CurrentFrame + 1) mod Frames.Count;
    NewFrame := Frames[CurrentFrame];
    for Node in TexNodes do
      Node.SetUrl(['quaketex:/map/' + MapName + '/' + NewFrame]);
  end;
end;

{ TQuakeGeometry }

constructor TQuakeGeometry.Create(const ABsp: TQuakeBsp);
begin
  inherited Create;
  FBsp := ABsp;
  Skill := 1;
  FSceneWorld := TCastleScene.Create(nil);
  FSceneWorld.PreciseCollisions := True;
  FSceneWorld.Collides := True;
  FSceneWorld.Name := 'world_scene';
  FWorldTransform := TCastleTransform.Create(nil);
  FWorldTransform.Name := 'world';
  FWorldTransform.Add(FSceneWorld);
  FSubmodels := TQuakeSubmodelList.Create(True);
  FAnimTextures := TQuakeAnimTexList.Create(True);
  FSkyTimeFields := TSFFloatList.Create;
  FLiquidTimeFields := TSFFloatList.Create;
  FLiquidMaterials := specialize TList<TUnlitMaterialNode>.Create;
  FLiquidAlpha := DefaultLiquidAlpha;
  FSkyEyeFields := TSFVec3fList.Create;
end;

procedure TQuakeGeometry.SetLiquidAlpha(const Value: Single);
var
  M: TUnlitMaterialNode;
begin
  FLiquidAlpha := Value;
  DefaultLiquidAlpha := Value;
  for M in FLiquidMaterials do
    M.Transparency := 1 - FLiquidAlpha;
end;

destructor TQuakeGeometry.Destroy;
begin
  FWorldTransform.Free;
  FSubmodels.Free;
  FAnimTextures.Free;
  FSkyTimeFields.Free;
  FLiquidTimeFields.Free;
  FLiquidMaterials.Free;
  FSkyEyeFields.Free;
  inherited Destroy;
end;

procedure TQuakeGeometry.RegisterAnimNode(const TexName: String; const Node: TImageTextureNode);
var
  Anim: TQuakeAnimTex;
  BaseKey: String;
  I: Integer;
  Mip: TQuakeMiptex;
begin
  if (Length(TexName) >= 2) and (TexName[1] = '+') then
  begin
    BaseKey := Copy(TexName, 3, Length(TexName));
    Anim := nil;
    for I := 0 to FAnimTextures.Count - 1 do
      if FAnimTextures[I].BaseName = BaseKey then
      begin
        Anim := FAnimTextures[I];
        Break;
      end;

    if Anim = nil then
    begin
      Anim := TQuakeAnimTex.Create(BaseKey, FBsp.MapName);
      FAnimTextures.Add(Anim);
      { Scan all miptexes for matching frames }
      for I := 0 to FBsp.Miptexes.Count - 1 do
      begin
        Mip := FBsp.Miptexes[I];
        if (Length(Mip.Name) >= 2) and (Mip.Name[1] = '+') and
           (Copy(Mip.Name, 3, Length(Mip.Name)) = BaseKey) then
          Anim.Frames.Add(Mip.Name);
      end;
    end;
    Anim.AddNode(Node);
  end;
end;

function IsInvisibleToolTexture(const AName: String): Boolean;
var
  LName: String;
begin
  LName := LowerCase(AName);
  Result := (LName = 'skip') or (LName = 'hint') or (LName = 'hintskip') or
            (LName = 'trigger') or (LName = 'clip') or (LName = 'origin') or
            (LName = 'null') or (LName = 'invisible') or
            (Pos('skip', LName) > 0) or (Pos('hint', LName) > 0);
end;

procedure TQuakeGeometry.BuildModelGeometry(const ModelIdx: Integer; const RootNode: TX3DRootNode;
  var OutBatches: TQuakeGeomBatchDict);
var
  Mdl: TBSPModel;
  FaceIdx, EndFace: Integer;
  Face: TBSPFace;
  TexInfo: TBSPTexInfo;
  MipName: String;
  Batch: TQuakeGeomBatch;
  VertCount, V: Integer;
  PolyVerts: array of TVector3;
  PolyUVs: array of TVector2;
  PolyLMUVs: array of TVector2;
  FaceS, FaceT: array of Single;
  PolyNormal: TVector3;
  RawVert: TVector3;
  BatchPair: specialize TPair<String, TQuakeGeomBatch>;
  Atlas: TQuakeLightmapAtlas;
  LMSet: TQuakeLightmapSet;
  NumStyles, K: Integer;
  FaceStyles: TVector4;
  MinS, MaxS, MinT, MaxT: Single;
  BMinS, BMinT, BMaxS, BMaxT: Integer;
  SurfW, SurfH, SurfSize: Integer;
  HasLightmap, AllocOk: Boolean;
  AtlasX, AtlasY: Integer;
  SrcPtr: PByte;
  Row, Col: Integer;
  SLux, TLux: Single;
  AtlasW, AtlasH: Integer;
begin
  if (ModelIdx < 0) or (ModelIdx >= FBsp.ModelCount) then
    Exit;

  if ModelIdx = 0 then
  begin
    AtlasW := 2048;
    AtlasH := 2048;
  end else
  begin
    AtlasW := 512;
    AtlasH := 512;
  end;

  Atlas := TQuakeLightmapAtlas.Create(AtlasW, AtlasH);
  try
    Mdl := FBsp.Models[ModelIdx];
    EndFace := Mdl.FirstFace + Mdl.NumFaces;

    for FaceIdx := Mdl.FirstFace to EndFace - 1 do
    begin
      Face := FBsp.Faces[FaceIdx];
      VertCount := Face.NumEdges;
      if VertCount < 3 then
        Continue;

      if (Face.TexInfoId >= 0) and (Face.TexInfoId < Length(FBsp.TexInfos)) then
      begin
        TexInfo := FBsp.TexInfos[Face.TexInfoId];
        if (TexInfo.Miptex >= 0) and (TexInfo.Miptex < FBsp.Miptexes.Count) then
          MipName := FBsp.Miptexes[TexInfo.Miptex].Name
        else
          MipName := 'default';
      end else
        MipName := 'default';

      if IsInvisibleToolTexture(MipName) then
        Continue;

      if not OutBatches.TryGetValue(MipName, Batch) then
      begin
        Batch := TQuakeGeomBatch.Create(MipName);
        OutBatches.Add(MipName, Batch);
      end;

      SetLength(PolyVerts, VertCount);
      SetLength(PolyUVs, VertCount);
      SetLength(PolyLMUVs, VertCount);
      SetLength(FaceS, VertCount);
      SetLength(FaceT, VertCount);

      PolyNormal := QuakeToCge(FBsp.GetFaceNormal(FaceIdx));

      MinS := 1e30; MaxS := -1e30;
      MinT := 1e30; MaxT := -1e30;

      for V := 0 to VertCount - 1 do
      begin
        RawVert := FBsp.GetFaceVertex(FaceIdx, V);
        PolyVerts[V] := QuakeToCge(RawVert);
        PolyUVs[V] := FBsp.GetFaceTexCoord(RawVert, Face.TexInfoId);

        if (Face.TexInfoId >= 0) and (Face.TexInfoId < Length(FBsp.TexInfos)) then
        begin
          FaceS[V] := RawVert[0] * TexInfo.VecS[0] + RawVert[1] * TexInfo.VecS[1] +
                      RawVert[2] * TexInfo.VecS[2] + TexInfo.VecS[3];
          FaceT[V] := RawVert[0] * TexInfo.VecT[0] + RawVert[1] * TexInfo.VecT[1] +
                      RawVert[2] * TexInfo.VecT[2] + TexInfo.VecT[3];
        end else
        begin
          FaceS[V] := 0;
          FaceT[V] := 0;
        end;

        if FaceS[V] < MinS then MinS := FaceS[V];
        if FaceS[V] > MaxS then MaxS := FaceS[V];
        if FaceT[V] < MinT then MinT := FaceT[V];
        if FaceT[V] > MaxT then MaxT := FaceT[V];
      end;

      BMinS := Floor(MinS / 16.0);
      BMinT := Floor(MinT / 16.0);
      BMaxS := Ceil(MaxS / 16.0);
      BMaxT := Ceil(MaxT / 16.0);
      SurfW := (BMaxS - BMinS) + 1;
      SurfH := (BMaxT - BMinT) + 1;
      SurfSize := SurfW * SurfH;

      { One lightmap per lightstyle slot in use (255 ends the list) }
      NumStyles := 0;
      while (NumStyles < 4) and (Face.Styles[NumStyles] <> 255) do
        Inc(NumStyles);
      FaceStyles := Vector4(Face.Styles[0], Face.Styles[1], Face.Styles[2], Face.Styles[3]);
      HasLightmap := (Face.LightmapOffset >= 0) and (FBsp.Lightmaps <> nil) and (NumStyles > 0) and
                     (SurfW > 0) and (SurfH > 0) and (SurfW <= 256) and (SurfH <= 256) and
                     (Face.LightmapOffset + SurfSize * NumStyles <= LongInt(FBsp.LightmapsSize)) and
                     (not Batch.IsSky) and (not Batch.IsLiquid);

      AllocOk := False;
      if HasLightmap then
      begin
        AllocOk := Atlas.Allocate(SurfW, SurfH, AtlasX, AtlasY);
        if AllocOk then
        begin
          for K := 0 to NumStyles - 1 do
          begin
            SrcPtr := FBsp.Lightmaps + Face.LightmapOffset + K * SurfSize;
            for Row := 0 to SurfH - 1 do
              for Col := 0 to SurfW - 1 do
                Atlas.SetTexel(K, AtlasX + Col, AtlasY + Row, (SrcPtr + Row * SurfW + Col)^);
          end;

          for V := 0 to VertCount - 1 do
          begin
            SLux := (FaceS[V] - BMinS * 16.0) / 16.0;
            TLux := (FaceT[V] - BMinT * 16.0) / 16.0;
            PolyLMUVs[V] := Vector2(
              (AtlasX + SLux + 0.5) / Atlas.Width,
              (AtlasY + TLux + 0.5) / Atlas.Height
            );
          end;
        end;
      end;

      if not AllocOk then
      begin
        { Full brightness from the gray block, style 0 }
        for V := 0 to VertCount - 1 do
          PolyLMUVs[V] := Vector2(2.0 / Atlas.Width, 2.0 / Atlas.Height);
        FaceStyles := Vector4(0, 255, 255, 255);
      end;

      Batch.AddPolygon(PolyVerts, PolyUVs, PolyLMUVs, PolyNormal, FaceStyles);
    end;

    LMSet := CreateLightmapSet(Atlas);
    for BatchPair in OutBatches do
    begin
      Batch := BatchPair.Value;
      Batch.CreateNodes(FBsp.MapName, LMSet);
      if Batch.Shape <> nil then
      begin
        RootNode.AddChildren(Batch.Shape);
        if Batch.TexNode <> nil then
          RegisterAnimNode(Batch.TextureName, Batch.TexNode);
        if Batch.SkyTimeField <> nil then
        begin
          FSkyTimeFields.Add(Batch.SkyTimeField);
          FSkyEyeFields.Add(Batch.SkyEyeField);
        end;
        if Batch.IsLiquid and (Batch.Appearance.Material is TUnlitMaterialNode) then
          FLiquidMaterials.Add(TUnlitMaterialNode(Batch.Appearance.Material));
        if Batch.LiquidTimeField <> nil then
          FLiquidTimeFields.Add(Batch.LiquidTimeField);
      end;
    end;
  finally
    Atlas.Free;
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
begin
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
          BuildModelGeometry(MdlIdx, Root, Batches);
          Sub.Scene.Load(Root, True);
        finally
          Batches.Free;
        end;

        Parent.Add(Sub.Transform);
        FSubmodels.Add(Sub);
      end;
    end;
  end;

  WritelnLog('QuakeGeometry', 'Configured %d interactive submodels', [FSubmodels.Count]);
end;

procedure TQuakeGeometry.AddToWorld(const Parent: TCastleTransform);
var
  RootWorld: TX3DRootNode;
  Batches: TQuakeGeomBatchDict;
begin
  if (FBsp = nil) or (Parent = nil) then
    Exit;

  { The map's skybox, when its six faces are in the paks }
  SkyboxName := '';
  if FBsp.FindEntity('worldspawn') <> nil then
    SkyboxName := LowerCase(Trim(FBsp.FindEntity('worldspawn').GetField('sky', '')));
  if (SkyboxName <> '') and not SkyboxAvailable(SkyboxName) then
  begin
    WritelnLog('QuakeGeometry', 'Skybox "%s" not found (gfx/env/%0:s{rt,bk,lf,ft,up,dn}.tga), using the sky texture',
      [SkyboxName]);
    SkyboxName := '';
  end else
  if SkyboxName <> '' then
    WritelnLog('QuakeGeometry', 'Skybox "%s"', [SkyboxName]);

  { Build static world model (Model 0) }
  RootWorld := TX3DRootNode.Create;
  Batches := TQuakeGeomBatchDict.Create([doOwnsValues]);
  try
    BuildModelGeometry(0, RootWorld, Batches);
    FSceneWorld.Load(RootWorld, True);
  finally
    Batches.Free;
  end;

  Parent.Add(FWorldTransform);

  { Setup interactive submodels (doors, plats, buttons) }
  SetupSubmodels(Parent);
end;

type
  TTextureExporter = class
    OutDir, MapName: String;
    Count: Integer;
    procedure Handle(Node: TX3DNode);
  end;

procedure TTextureExporter.Handle(Node: TX3DNode);
var
  Tex: TImageTextureNode;
  Url, Name, FileName, C: String;
  Img: TCastleImage;
  I: Integer;
begin
  Tex := Node as TImageTextureNode;
  if Tex.FdUrl.Count = 0 then
    Exit;
  Url := Tex.FdUrl.Items[0];
  if Pos('quaketex:/', Url) <> 1 then
    Exit;
  { A file name from the texture name (Quake names have * and + and /) }
  Name := ExtractFileName(Url);
  FileName := '';
  for I := 1 to Length(Name) do
  begin
    C := Name[I];
    if not (Name[I] in ['a'..'z', 'A'..'Z', '0'..'9', '_', '-']) then
      C := '_';
    FileName := FileName + C;
  end;
  FileName := 'textures/' + FileName + '.png';
  if not UriFileExists(OutDir + FileName) then
  begin
    try
      Img := LoadImage(Url);
      try
        SaveImage(Img, OutDir + FileName);
        Inc(Count);
      finally
        Img.Free;
      end;
    except
      on E: Exception do
        WritelnWarning('QuakeGeometry', 'Cannot export texture "%s": %s', [Url, E.Message]);
    end;
  end;
  Tex.SetUrl([FileName]);
end;

function TQuakeGeometry.ExportMap(const Url: String): Boolean;
var
  Root: TX3DRootNode;
  Batches: TQuakeGeomBatchDict;
  ModelRoot: TX3DRootNode;
  T: TTransformNode;
  Light: TPointLightNode;
  Ent: TQuakeEntity;
  I, N: Integer;
  CName: String;
  LightVal: Single;
  Exporter: TTextureExporter;
  OutDir: String;
  SavedLightmaps: Boolean;
begin
  Result := False;
  if FBsp = nil then
    Exit;
  OutDir := ExtractUriPath(Url);
  { The physical materials lit by the exported lights: the lightmap
    atlases and their shader are a thing of this renderer (and megabytes
    of pixels as text) }
  SavedLightmaps := WorldLightmaps;
  WorldLightmaps := False;
  Root := TX3DRootNode.Create;
  Exporter := TTextureExporter.Create;
  try
    Exporter.OutDir := OutDir;
    Exporter.MapName := FBsp.MapName;
    { The world and the brush models, each a named transform }
    for I := 0 to FBsp.ModelCount - 1 do
    begin
      ModelRoot := TX3DRootNode.Create;
      Batches := TQuakeGeomBatchDict.Create([doOwnsValues]);
      try
        BuildModelGeometry(I, ModelRoot, Batches);
      finally
        Batches.Free;
      end;
      T := TTransformNode.Create;
      if I = 0 then
        T.X3DName := 'world'
      else
        T.X3DName := 'model_' + IntToStr(I);
      for N := 0 to FBsp.Entities.Count - 1 do
        if FBsp.Entities[N].Model = '*' + IntToStr(I) then
        begin
          T.X3DName := LowerCase(FBsp.Entities[N].ClassName) + '_' + IntToStr(I);
          Break;
        end;
      T.AddChildren(ModelRoot);
      Root.AddChildren(T);
    end;
    { The light entities }
    N := 0;
    for I := 0 to FBsp.Entities.Count - 1 do
    begin
      Ent := FBsp.Entities[I];
      CName := LowerCase(Ent.ClassName);
      if Pos('light', CName) <> 1 then
        Continue;
      LightVal := Ent.Light;
      if LightVal <= 0 then
        LightVal := 200;
      Light := TPointLightNode.Create;
      Inc(N);
      Light.X3DName := CName + '_' + IntToStr(N);
      Light.Location := QuakeToCge(Ent.Origin);
      Light.Radius := LightVal * 1.8;
      Light.Intensity := LightVal / 200;
      Light.Attenuation := Vector3(1, 4 / Light.Radius, 8 / Sqr(Light.Radius));
      Light.Global := True;
      if (CName = 'light_torch_small_walltorch') or (CName = 'light_flame_large_yellow') then
        Light.Color := Vector3(1.0, 0.75, 0.4)
      else if CName = 'light_fluorospark' then
        Light.Color := Vector3(0.85, 0.9, 1.0)
      else
        Light.Color := Vector3(0.95, 0.92, 0.85);
      Root.AddChildren(Light);
    end;
    { The textures as files next to the model }
    Root.EnumerateNodes(TImageTextureNode, @Exporter.Handle, False);
    SaveNode(Root, Url);
    WritelnLog('QuakeGeometry', 'Exported "%s" to "%s": %d models, %d lights, %d textures',
      [FBsp.MapName, Url, FBsp.ModelCount, N, Exporter.Count]);
    Result := True;
  finally
    WorldLightmaps := SavedLightmaps;
    Exporter.Free;
    Root.Free;
  end;
end;

function TQuakeGeometry.CreateLightmapSet(const Atlas: TQuakeLightmapAtlas): TQuakeLightmapSet;
var
  K, I: Integer;
  VertexPart, FragmentPart: TEffectPartNode;
  Styles: array[0..63] of Single;
begin
  Result := Default(TQuakeLightmapSet);
  if not WorldLightmaps then
    Exit;
  for K := 0 to 3 do
  begin
    Result.Layers[K] := Atlas.CreateTextureNode(K);
    if Result.Layers[K] <> nil then
      Result.LayerCount := K + 1;
  end;
  if Result.LayerCount = 0 then
    Exit;

  Result.Effect := TEffectNode.Create;
  Result.Effect.Language := slGLSL;
  Result.Effect.UniformMissing := umIgnore;
  for K := 0 to Result.LayerCount - 1 do
  begin
    if Result.Layers[K] = nil then
      Result.Layers[K] := Result.Layers[0]; { a slot without data in between }
    Result.Effect.AddCustomField(TSFNode.Create(Result.Effect, False, 'quake_lm' + IntToStr(K), [],
      Result.Layers[K]));
  end;
  Result.Effect.AddCustomField(TSFInt32.Create(Result.Effect, False, 'quake_lm_layers', Result.LayerCount));
  for I := 0 to 63 do
    Styles[I] := Lighting.GetStyleMultiplier(I);
  Result.StylesField := TMFFloat.Create(Result.Effect, True, 'quake_lightstyles', Styles);
  Result.Effect.AddCustomField(Result.StylesField);
  Result.DLightsField := TMFVec4f.Create(Result.Effect, True, 'quake_dlights',
    [TVector4.Zero, TVector4.Zero, TVector4.Zero, TVector4.Zero]);
  Result.Effect.AddCustomField(Result.DLightsField);

  VertexPart := TEffectPartNode.Create;
  VertexPart.ShaderType := stVertex;
  VertexPart.Contents := LightmapVertexShader;
  FragmentPart := TEffectPartNode.Create;
  FragmentPart.ShaderType := stFragment;
  FragmentPart.Contents := LightmapFragmentShader;
  Result.Effect.SetParts([VertexPart, FragmentPart]);

  SetLength(FLightmapSets, Length(FLightmapSets) + 1);
  FLightmapSets[High(FLightmapSets)] := Result;
end;

procedure TQuakeGeometry.Update(const SecondsPassed: Single; const EyePos: TVector3);
var
  Sub: TQuakeSubmodel;
  Anim: TQuakeAnimTex;
  I, K: Integer;
  StylesChanged, DLightsOn: Boolean;
  V: Single;
  DL: array[0..3] of TVector4;
begin
  for Sub in FSubmodels do
    Sub.Update(SecondsPassed);

  { Lightstyle values and dynamic lights for the lightmap shaders }
  if Length(FLightmapSets) > 0 then
  begin
    StylesChanged := False;
    for I := 0 to 63 do
    begin
      V := Lighting.GetStyleMultiplier(I);
      if V <> FLastStyles[I] then
      begin
        FLastStyles[I] := V;
        StylesChanged := True;
      end;
    end;
    DLightsOn := False;
    for I := 0 to 3 do
    begin
      DL[I] := Lighting.DLightUniform(I);
      if DL[I].W > 0 then
        DLightsOn := True;
    end;
    for K := 0 to High(FLightmapSets) do
    begin
      if StylesChanged then
        FLightmapSets[K].StylesField.Send(FLastStyles);
      if DLightsOn or FDLightsOn then
        FLightmapSets[K].DLightsField.Send(DL);
    end;
    FDLightsOn := DLightsOn;
  end;

  for Anim in FAnimTextures do
    Anim.Update(SecondsPassed);

  FSkyTime := FloatModulo(FSkyTime + SecondsPassed, SkyTimePeriod);
  for I := 0 to FSkyTimeFields.Count - 1 do
  begin
    FSkyTimeFields[I].Send(FSkyTime);
    FSkyEyeFields[I].Send(EyePos);
  end;
  FLiquidTime := FloatModulo(FLiquidTime + SecondsPassed, 2 * Pi);
  for I := 0 to FLiquidTimeFields.Count - 1 do
    FLiquidTimeFields[I].Send(FLiquidTime);
end;

function TQuakeGeometry.IsGeometryScene(const T: TCastleTransform): Boolean;
var
  Sub: TQuakeSubmodel;
begin
  Result := T = FSceneWorld;
  if not Result then
    for Sub in FSubmodels do
      if T = Sub.Scene then
        Exit(True);
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

end.
