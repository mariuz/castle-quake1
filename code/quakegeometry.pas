{ Quake 1 BSP geometry to Castle Game Engine X3D scenes converter. }
unit QuakeGeometry;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, Math,
  CastleVectors, CastleBoxes, CastleScene, CastleTransform, X3DNodes, CastleLog, CastleColors,
  CastleImages, CastleUtils, CastleRenderOptions, X3DFields, CastleViewport,
  QuakeBsp, QuakePalette, QuakeLight, QuakePak, X3DLoad, CastleUriUtils, CastleTimeUtils;

type
  { Lightmap atlases (one per lightstyle slot) of a BSP model and the shader
    that blends them with the live lightstyle values and dynamic lights }
  TLightStyleSet = set of 0..63;

  TQuakeLightmapSet = record
    Layers: array[0..3] of TPixelTextureNode;
    LayerCount: Integer;
    Effect: TEffectNode;
    StylesField: TMFFloat;
    DLightsField: TMFVec4f;
    { The lightstyles its faces use: the shader gets new values only when
      one of them changed (a door lit by style 0 alone never does) }
    UsedStyles: TLightStyleSet;
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
    { A fence texture (its name starts with a brace): palette index 255 is a hole }
    IsFence: Boolean;
    { Index of the lightmap atlas page the batch's lightmap coordinates use }
    LightmapPage: Integer;
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
    { SharedAppearance (with its SharedTexture): the appearance (material,
      texture, effects) a batch of the same texture and lightmap page
      already made for the same scene; used instead of making the same
      nodes again. }
    procedure CreateNodes(const MapName: String; const Lightmaps: TQuakeLightmapSet;
      const SharedAppearance: TAppearanceNode = nil; const SharedTexture: TImageTextureNode = nil);
  end;

  { Packs the per-face Quake lightmaps (8-bit luminance, one map per
    lightstyle slot) into atlases, one per slot }
  TQuakeLightmapAtlas = class
  private
    FWidth, FHeight: Integer;
    FData: array[0..3] of array of Byte;
    FRgb: Boolean;
    FChannels: Integer;
    FLayerUsed: array[0..3] of Boolean;
    { Open shelves: rows of faces of about the same height, filled left to
      right; a face goes into the lowest shelf it fits (at most 2 texels
      taller), else a new shelf starts below the last one }
    FShelves: array of record
      Y, H, X: Integer;
    end;
    FNextY: Integer;
    FUsedHeight: Integer;
    FTexelsUsed: Int64;
    procedure NeedLayer(const Layer: Integer);
  public
    { The lightstyles of the faces packed here }
    UsedStyles: TLightStyleSet;
    { ARgb: three bytes per texel (colored .lit lightmaps), else one }
    constructor Create(const AWidth: Integer = 1024; const AMaxHeight: Integer = 4096; const ARgb: Boolean = False);
    { Reserve a W x H block. Returns False if the atlas is full. }
    function Allocate(const W, H: Integer; out X, Y: Integer): Boolean;
    procedure SetTexel(const Layer, X, Y: Integer; const Value: Byte);
    procedure SetTexelRgb(const Layer, X, Y: Integer; const R, G, B: Byte);
    { Create the texture of a lightstyle slot; nil if nothing was packed in it }
    function CreateTextureNode(const Layer: Integer): TPixelTextureNode;
    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
    { Rows packed so far }
    property UsedHeight: Integer read FUsedHeight;
    { The texels of the faces packed (without the padding) }
    property TexelsUsed: Int64 read FTexelsUsed;
    property Rgb: Boolean read FRgb;
  end;
  TQuakeLightmapAtlasList = specialize TObjectList<TQuakeLightmapAtlas>;

  TQuakeGeomBatchDict = specialize TObjectDictionary<String, TQuakeGeomBatch>;

  { The appearance the first batch of a texture and lightmap page made }
  TSharedAppearance = record
    Appearance: TAppearanceNode;
    TexNode: TImageTextureNode;
    IsSky, IsLiquid, IsFence: Boolean;
  end;
  TSharedAppearanceDict = specialize TDictionary<String, TSharedAppearance>;

  TQuakeIntArray = array of Integer;

  { A part of the world (a BSP subtree) shown when one of the leaves
    listing its faces is in the camera's potentially visible set }
  TQuakeVisCluster = class
  public
    Leaves: array of Integer; { none = always visible }
    Shapes: specialize TList<TShapeNode>;
    Visible: Boolean;
    constructor Create;
    destructor Destroy; override;
  end;
  TQuakeVisClusterList = specialize TObjectList<TQuakeVisCluster>;

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

  { A sky surface, kept so SetSkybox can give it another effect }
  TQuakeSkySurface = record
    Appearance: TAppearanceNode;
    TextureName: String;
  end;
  TQuakeSkySurfaceList = specialize TList<TQuakeSkySurface>;

  { World geometry builder and manager }
  TQuakeGeometry = class
  private
    FBsp: TQuakeBsp;
    FSceneWorld: TCastleScene;
    { The world's shapes with animated textures (+0name...): a scene of
      their own, because the engine looks at every shape of a scene when a
      texture node changes, and a frame of animation changes one. Built
      with FAnimRoot while the world (FAnimWorldRoot) is. }
    FSceneAnim: TCastleScene;
    FAnimRoot, FAnimWorldRoot: TX3DRootNode;
    FAnimLMSets: array of TQuakeLightmapSet;
    FAnimShapes, FAnimKeepers: Integer;
    FStyleSends: Int64;
    FWorldTransform: TCastleTransform;
    FSubmodels: TQuakeSubmodelList;
    FAnimTextures: TQuakeAnimTexList;
    FSkyTimeFields: TSFFloatList;
    FSkySurfaces: TQuakeSkySurfaceList;
    FSkybox: String;
    { Where the world's build spends its time (the log's "Level load "geometry of ..."") }
    FBuildTime: TLoadTimer;
    FSkyEyeFields: TSFVec3fList;
    FLiquidTimeFields: TSFFloatList;
    { The first batch of each texture and lightmap page of the scene being
      built (FSharedRoot): the later ones use its appearance }
    FSharedBatches: TSharedAppearanceDict;
    FSharedRoot: TX3DRootNode;
    FSharedCount: Integer;
    FLiquidMaterials: specialize TList<TUnlitMaterialNode>;
    FLiquidAlpha: Single;
    FLoggedLiquidAlpha: Boolean;
    FSkyTime, FLiquidTime: Single;
    FLightmapSets: array of TQuakeLightmapSet;
    FLastStyles: array[0..63] of Single;
    FDLightsOn: Boolean;
    FClusters: TQuakeVisClusterList;
    FLiquidLinks: array of array of Integer; { per leaf: leaves across its liquid surfaces }
    FVisBits, FExtraBits, FRowBits: TBytes;
    FCameraLeaf: Integer;
    { The second camera's leaf of a split-screen UpdateVisibility (-2 none) }
    FSecondLeaf: Integer;
    { The leaves of the third and later cameras of UpdateVisibilityAll }
    FOtherLeaves: array of Integer;
    FVisLiquidSeeThrough: Boolean;
    FVisibleClusters, FVisibleShapes, FShapeCount: Integer;
    FAllVisible: Boolean;
    FFullbrightFaces: Integer; { faces whose lightmap found no room, while building a model }
    FEntityCount, FVisibleEntities: Integer;
    procedure SetLiquidAlpha(const Value: Single);
    procedure UpdateVisibilityOf(const Positions: array of TVector3);
    function CreateLightmapSet(const Atlas: TQuakeLightmapAtlas): TQuakeLightmapSet;
    procedure AddFace(const FaceIdx: Integer; const Batches: TQuakeGeomBatchDict;
      const Atlases: TQuakeLightmapAtlasList);
    procedure FinishBatches(const Batches: TQuakeGeomBatchDict;
      const LMSets: array of TQuakeLightmapSet; const RootNode: TX3DRootNode; const Cluster: TQuakeVisCluster);
    procedure BuildClusters(out FaceCluster: TQuakeIntArray);
    procedure BuildModelGeometry(const ModelIdx: Integer; const RootNode: TX3DRootNode;
      var OutBatches: TQuakeGeomBatchDict; const Clustered: Boolean = False);
    procedure SetupSubmodels(const Parent: TCastleTransform);
    procedure RegisterAnimNode(const TexName: String; const Node: TImageTextureNode);
    procedure AddAnimKeepers(const Root: TX3DRootNode);
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

    { Show only the world clusters in the potentially visible set of the
      leaf containing the camera (CGE coordinates); recomputed when the
      camera changes leaves. Everything shows outside the map, without
      vis data or when WorldPvsCulling is off. }
    procedure UpdateVisibility(const CameraPos: TVector3);
    { Split-screen: what either camera's PVS has (one world for both views) }
    procedure UpdateVisibility2(const CameraPos, SecondPos: TVector3);
    { The same for any number of cameras (split-screen up to four) }
    procedure UpdateVisibilityAll(const Positions: array of TVector3);
    { The eye the scrolling sky is projected from, for the next render (a
      second view sets its own before it draws) }
    procedure SetSkyEye(const EyePos: TVector3);

    { True when a box (Quake coordinates) touches a leaf in the camera's
      PVS of the last UpdateVisibility (SV_FindTouchedLeafs against the
      PVS, like the original renderer's entity check) }
    function BoxVisible(const Mins, Maxs: TVector3): Boolean;

    { Draw Scene only when its world box is in the camera's PVS (sets
      Scene.Visible; collisions are unchanged, and a hidden MDL scene skips
      its animation poses). Call after UpdateVisibility each frame;
      counted in EntityCount / VisibleEntities. Nil is ignored. }
    procedure CullScene(const Scene: TCastleTransform);

    { CullScene for the brush entities (doors, plats, trains...) }
    procedure CullSubmodels;

    { The worldspawn "fog" key of FitzQuake and QuakeSpasm maps: "density"
      (gray 0.3) or "density r g b". False when the map has none. }
    function WorldFog(out Density: Single; out Color: TVector3): Boolean;

    { Show the skybox gfx/env/<Name> on the sky surfaces, or the scrolling
      sky with Name '' (svc_skybox after the map is built). False, and no
      change, when the six faces are not in the paks. }
    function SetSkybox(const Name: String): Boolean;
    { The skybox on the sky surfaces, '' for the scrolling sky }
    property Skybox: String read FSkybox;

    { True if T is the world scene or the scene of a brush entity (door, plat...) }
    function IsGeometryScene(const T: TCastleTransform): Boolean;

    { Find submodel by targetname or model string like "*1" }
    function FindSubmodel(const AName: String): TQuakeSubmodel;

    property SceneWorld: TCastleScene read FSceneWorld;
    { The lightmap shaders of the level, and how often one of them got new
      lightstyle values since the level loaded }
    function LightmapSetCount: Integer;
    property StyleSends: Int64 read FStyleSends;
    { r_wateralpha: opacity of water, slime and lava surfaces, both from
      above and from inside (the surfaces are two sided), default 0.65 }
    property LiquidAlpha: Single read FLiquidAlpha write SetLiquidAlpha;
    property WorldTransform: TCastleTransform read FWorldTransform;
    property Submodels: TQuakeSubmodelList read FSubmodels;
    { PVS statistics: the camera's leaf (-1 = not culled), the world
      clusters and shapes drawn and in total }
    property CameraLeaf: Integer read FCameraLeaf;
    { The second camera's leaf of UpdateVisibility2 (-2 without one) }
    property SecondLeaf: Integer read FSecondLeaf;
    property VisibleClusters: Integer read FVisibleClusters;
    property VisibleShapes: Integer read FVisibleShapes;
    property ShapeCount: Integer read FShapeCount;
    { Entities checked by CullScene since the last UpdateVisibility, and drawn }
    property EntityCount: Integer read FEntityCount;
    property VisibleEntities: Integer read FVisibleEntities;
    function ClusterCount: Integer;
  end;

var
  { World surfaces: True = Quake's baked lightmaps blended in a shader
    (lightstyles, dynamic lights), False = lit materials under the engine's
    real-time lights. Takes effect when a map is loaded. }
  WorldLightmaps: Boolean = True;

  { Size of the world's lightmap atlas pages (brush entities use at most
    512); a full page opens another. Smaller values only for testing. }
  LightmapAtlasSize: Integer = 2048;

  { r_novis off: draw only the world in the camera's potentially visible set }
  WorldPvsCulling: Boolean = True;

{ Set the viewport's fog from the map's worldspawn "fog" key (WorldFog),
  or remove it when the map has none. The fog component belongs to the
  viewport and is reused by the next level. Density 0 turns it off. }
procedure ApplyWorldFog(const Viewport: TCastleViewport; const Geometry: TQuakeGeometry);
procedure SetViewportFog(const Viewport: TCastleViewport; const Density: Single; const Color: TVector3);

const
  { Faces of a BSP subtree grouped into one PVS cluster }
  ClusterMaxFaces = 256;

var
  { The skybox of the map being built (gfx/env/<name>), '' for the scrolling sky }
  SkyboxName: String;
  { r_wateralpha for the maps built from now on }
  DefaultLiquidAlpha: Single = 0.65;

{ The six faces of a skybox are in the paks }
function SkyboxAvailable(const Name: String): Boolean;

{ A brush model file (maps/b_bh25.bsp, the health and ammo boxes) as a
  scene owned by Owner, its model 0 with the origin at the model's origin;
  nil when the file is missing. Built once per path, copied for each call. }
function CreateBspModelScene(const Path: String; const Owner: TComponent): TCastleScene;

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
    'uniform int quake_lm_rgb;' + LineEnding +
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
    '/* A lightmap texel: gray (one channel) or colored (.lit) */' + LineEnding +
    'vec3 quake_lm(sampler2D lm)' + LineEnding +
    '{' + LineEnding +
    '  vec4 t = texture2D(lm, quake_lm_coord_v);' + LineEnding +
    '  return quake_lm_rgb != 0 ? t.rgb : vec3(t.r);' + LineEnding +
    '}' + LineEnding +
    'void PLUG_main_texture_apply(inout vec4 fragment_color, const in vec3 normal)' + LineEnding +
    '{' + LineEnding +
    '  vec3 light = vec3(0.0);' + LineEnding +
    '  if (quake_lm_layers > 0 && quake_styles_v.x < 254.5)' + LineEnding +
    '    light += quake_lm(quake_lm0) * quake_style(quake_styles_v.x);' + LineEnding +
    '  if (quake_lm_layers > 1 && quake_styles_v.y < 254.5)' + LineEnding +
    '    light += quake_lm(quake_lm1) * quake_style(quake_styles_v.y);' + LineEnding +
    '  if (quake_lm_layers > 2 && quake_styles_v.z < 254.5)' + LineEnding +
    '    light += quake_lm(quake_lm2) * quake_style(quake_styles_v.z);' + LineEnding +
    '  if (quake_lm_layers > 3 && quake_styles_v.w < 254.5)' + LineEnding +
    '    light += quake_lm(quake_lm3) * quake_style(quake_styles_v.w);' + LineEnding +
    '  for (int i = 0; i < 4; i++)' + LineEnding +
    '  {' + LineEnding +
    '    float rad = quake_dlights[i].w;' + LineEnding +
    '    if (rad > 0.0)' + LineEnding +
    '      light += vec3(max(rad - distance(quake_pos_v, quake_dlights[i].xyz), 0.0) / 255.0);' + LineEnding +
    '  }' + LineEnding +
    '  /* The fullbright palette entries (alpha 255 of the texture) keep their color */' + LineEnding +
    '  fragment_color.rgb *= mix(min(light, vec3(1.0)) * 2.0, vec3(1.0), fragment_color.a);' + LineEnding +
    '  fragment_color.a = 1.0;' + LineEnding +
    '}' + LineEnding;

  { Fence textures: the holes (alpha 0) are discarded, the rest is lit by
    the lightmap shader that runs next (alpha 0: no fullbright texel) }
  FenceFragmentShader =
    'void PLUG_main_texture_apply(inout vec4 fragment_color, const in vec3 normal)' + LineEnding +
    '{' + LineEnding +
    '  if (fragment_color.a < 0.5) discard;' + LineEnding +
    '  fragment_color.a = 0.0;' + LineEnding +
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

{ The effect of a sky surface: the six faces of the skybox gfx/env/<Skybox>,
  or with Skybox '' the two scrolling layers of the map's sky texture.
  TimeField and EyeField are its uniforms, sent every frame }
function CreateSkyEffect(const MapName, TextureName, Skybox: String;
  out TimeField: TSFFloat; out EyeField: TSFVec3f): TEffectNode;
var
  I: Integer;
  TexProps: TTexturePropertiesNode;
  VertexPart, FragmentPart: TEffectPartNode;
begin
  Result := TEffectNode.Create;
  Result.Language := slGLSL;
  Result.UniformMissing := umIgnore;
  if Skybox <> '' then
  begin
    for I := 0 to 5 do
      Result.AddCustomField(TSFNode.Create(Result, False, 'skybox_' + SkyboxSuffixes[I], [],
        CreateSkyboxTexture(Skybox, SkyboxSuffixes[I])));
  end else
  begin
    TexProps := TTexturePropertiesNode.Create;
    SetupTextureFilter(TexProps, True);
    Result.AddCustomField(TSFNode.Create(Result, False, 'sky_back', [],
      CreateSkyLayerTexture('quaketex:/map/' + MapName + '/' + TextureName + SKY_BACK_SUFFIX, TexProps)));
    Result.AddCustomField(TSFNode.Create(Result, False, 'sky_front', [],
      CreateSkyLayerTexture('quaketex:/map/' + MapName + '/' + TextureName + SKY_FRONT_SUFFIX, TexProps)));
  end;
  TimeField := TSFFloat.Create(Result, True, 'sky_time', 0);
  Result.AddCustomField(TimeField);
  EyeField := TSFVec3f.Create(Result, True, 'sky_eye', TVector3.Zero);
  Result.AddCustomField(EyeField);

  VertexPart := TEffectPartNode.Create;
  VertexPart.ShaderType := stVertex;
  VertexPart.Contents := SkyVertexShader;
  FragmentPart := TEffectPartNode.Create;
  FragmentPart.ShaderType := stFragment;
  if Skybox <> '' then
    FragmentPart.Contents := SkyboxFragmentShader
  else
    FragmentPart.Contents := SkyFragmentShader;
  Result.SetParts([VertexPart, FragmentPart]);
end;

{ The fence texture's hole cutting, a node of its own for each batch (the
  X3D graph owns it) }
function CreateFenceEffect: TEffectNode;
var
  FragmentPart: TEffectPartNode;
begin
  Result := TEffectNode.Create;
  Result.Language := slGLSL;
  FragmentPart := TEffectPartNode.Create;
  FragmentPart.ShaderType := stFragment;
  FragmentPart.Contents := FenceFragmentShader;
  Result.SetParts([FragmentPart]);
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
  FSceneAnim := TCastleScene.Create(nil);
  FSceneAnim.PreciseCollisions := True;
  FSceneAnim.Collides := True;
  FSceneAnim.Name := 'world_anim_scene';
  FWorldTransform.Add(FSceneAnim);
  FSubmodels := TQuakeSubmodelList.Create(True);
  FAnimTextures := TQuakeAnimTexList.Create(True);
  FSkyTimeFields := TSFFloatList.Create;
  FLiquidTimeFields := TSFFloatList.Create;
  FSharedBatches := TSharedAppearanceDict.Create;
  FLiquidMaterials := specialize TList<TUnlitMaterialNode>.Create;
  FLiquidAlpha := DefaultLiquidAlpha;
  FSkyEyeFields := TSFVec3fList.Create;
  FSkySurfaces := TQuakeSkySurfaceList.Create;
  FClusters := TQuakeVisClusterList.Create(True);
  FCameraLeaf := -2;
  FSecondLeaf := -2;
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
  FSharedBatches.Free;
  FLiquidMaterials.Free;
  FSkyEyeFields.Free;
  FSkySurfaces.Free;
  FClusters.Free;
  inherited Destroy;
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

{ The lightmap atlas page of a brush entity: the smallest power of two
  that holds the lightmaps of its faces (with their padding and the gray
  block), up to MaxSize. Most doors and buttons need 32 or 64 texels, not
  the 512 every one of them got: on a map with a thousand brush entities
  that was most of the time spent on them, and of the lightmap memory. }
function BrushAtlasSize(const Bsp: TQuakeBsp; const ModelIdx, MaxSize: Integer): Integer;
var
  F, W, H, Widest: Integer;
  Area: Int64;
begin
  Area := 25; { the 4x4 gray block and its padding }
  Widest := 4;
  for F := Bsp.Models[ModelIdx].FirstFace to Bsp.Models[ModelIdx].FirstFace + Bsp.Models[ModelIdx].NumFaces - 1 do
    if Bsp.FaceLightmapSize(F, W, H) then
    begin
      Area := Area + Int64(W + 1) * (H + 1);
      Widest := Max(Widest, Max(W, H));
    end;
  { Shelves waste some room: half as much again as the texels, and a page as
    wide as the widest face plus the block }
  Result := 16;
  while (Result < MaxSize) and ((Result < Widest + 6) or (Int64(Result) * Result * 2 < Area * 3)) do
    Result := Result * 2;
  Result := Min(Result, MaxSize);
end;

function IndexIntArray(const A: array of Integer; const Value: Integer): Integer;
var
  I: Integer;
begin
  for I := 0 to High(A) do
    if A[I] = Value then
      Exit(I);
  Result := -1;
end;

type
  TTextureExporter = class
    OutDir, MapName: String;
    Count: Integer;
    procedure Handle(Node: TX3DNode);
  end;

procedure TQuakeGeometry.Update(const SecondsPassed: Single; const EyePos: TVector3);
var
  Sub: TQuakeSubmodel;
  Anim: TQuakeAnimTex;
  I, K: Integer;
  StylesChanged, DLightsOn: Boolean;
  V: Single;
  DL: array[0..3] of TVector4;
  Changed: TLightStyleSet;
begin
  for Sub in FSubmodels do
    Sub.Update(SecondsPassed);

  { Lightstyle values and dynamic lights for the lightmap shaders }
  if Length(FLightmapSets) > 0 then
  begin
    StylesChanged := False;
    Changed := [];
    for I := 0 to 63 do
    begin
      V := Lighting.GetStyleMultiplier(I);
      if V <> FLastStyles[I] then
      begin
        FLastStyles[I] := V;
        StylesChanged := True;
        Include(Changed, I);
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
      { (a set gets the values of every style, so one that was skipped
        while only other styles changed is still right for its own) }
      if StylesChanged and (Changed * FLightmapSets[K].UsedStyles <> []) then
      begin
        FLightmapSets[K].StylesField.Send(FLastStyles);
        Inc(FStyleSends);
      end;
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

function TQuakeGeometry.LightmapSetCount: Integer;
begin
  Result := Length(FLightmapSets);
end;

function TQuakeGeometry.WorldFog(out Density: Single; out Color: TVector3): Boolean;
begin
  Result := WorldspawnFog(FBsp, Density, Color);
end;

function TQuakeGeometry.SetSkybox(const Name: String): Boolean;
var
  I: Integer;
  Surface: TQuakeSkySurface;
  Effect: TEffectNode;
  TimeField: TSFFloat;
  EyeField: TSFVec3f;
begin
  Result := (Name = '') or SkyboxAvailable(Name);
  if not Result then
  begin
    WritelnWarning('QuakeGeometry', 'Skybox "%s" not found (gfx/env/%0:s{rt,bk,lf,ft,up,dn}.tga), the sky stays', [Name]);
    Exit;
  end;
  if (FBsp = nil) or (Name = FSkybox) then
    Exit;
  FSkyTimeFields.Clear;
  FSkyEyeFields.Clear;
  for I := 0 to FSkySurfaces.Count - 1 do
  begin
    Surface := FSkySurfaces[I];
    { The scrolling sky needs the two layers of a standard sky texture }
    if (Name = '') and not Palette.HasCachedImage('map/' + FBsp.MapName + '/' + Surface.TextureName + SKY_BACK_SUFFIX) then
      Continue;
    Effect := CreateSkyEffect(FBsp.MapName, Surface.TextureName, Name, TimeField, EyeField);
    Surface.Appearance.SetEffects([Effect]);
    FSkyTimeFields.Add(TimeField);
    FSkyEyeFields.Add(EyeField);
  end;
  FSkybox := Name;
  if Name <> '' then
    WritelnLog('QuakeGeometry', 'Skybox "%s"', [Name])
  else
    WritelnLog('QuakeGeometry', 'Scrolling sky');
end;
procedure SetViewportFog(const Viewport: TCastleViewport; const Density: Single; const Color: TVector3);
var
  Fog: TCastleFog;
begin
  if Density <= 0 then
  begin
    Viewport.Fog := nil;
    Exit;
  end;
  Fog := Viewport.FindComponent('world_fog') as TCastleFog;
  if Fog = nil then
  begin
    Fog := TCastleFog.Create(Viewport);
    Fog.Name := 'world_fog';
  end;
  { FitzQuake draws GL_EXP2 fog with density / 64: exp(-(d * density / 64)^2).
    The engine's exponential fog is exp(-d / (range - d)); this range makes
    both reach one half at the same distance (and almost nothing at the range) }
  Fog.FogType := ftExponential;
  Fog.Color := Color;
  Fog.VisibilityRange := 64 * Sqrt(Ln(2)) * (1 + 1 / Ln(2)) / Density;
  Viewport.Fog := Fog;
  WritelnLog('QuakeGeometry', 'Fog: density %.3f, color %s, visibility range %.0f',
    [Density, Color.ToString, Fog.VisibilityRange]);
end;

procedure ApplyWorldFog(const Viewport: TCastleViewport; const Geometry: TQuakeGeometry);
var
  Density: Single;
  Color: TVector3;
begin
  if (Geometry <> nil) and Geometry.WorldFog(Density, Color) then
    SetViewportFog(Viewport, Density, Color)
  else
    Viewport.Fog := nil;
end;

function TQuakeGeometry.IsGeometryScene(const T: TCastleTransform): Boolean;
var
  Sub: TQuakeSubmodel;
begin
  Result := (T = FSceneWorld) or (T = FSceneAnim);
  if not Result then
    for Sub in FSubmodels do
      if T = Sub.Scene then
        Exit(True);
end;

var
  BspModelRoots: specialize TObjectDictionary<String, TX3DRootNode>;

function CreateBspModelScene(const Path: String; const Owner: TComponent): TCastleScene;
var
  Root: TX3DRootNode;
  Bsp: TQuakeBsp;
  Geometry: TQuakeGeometry;
  Batches: TQuakeGeomBatchDict;
begin
  Result := nil;
  if BspModelRoots = nil then
    BspModelRoots := specialize TObjectDictionary<String, TX3DRootNode>.Create([doOwnsValues]);
  if not BspModelRoots.TryGetValue(Pak.VariantPath(Path), Root) then
  begin
    Root := nil;
    if Pak.FileExists(Path) then
    begin
      Bsp := TQuakeBsp.Create;
      try
        if Bsp.LoadFromPak(Path) and (Bsp.ModelCount > 0) then
        begin
          Geometry := TQuakeGeometry.Create(Bsp);
          Batches := TQuakeGeomBatchDict.Create([doOwnsValues]);
          try
            Root := TX3DRootNode.Create;
            Geometry.BuildModelGeometry(0, Root, Batches, False);
          finally
            Batches.Free;
            Geometry.Free;
          end;
        end;
      finally
        Bsp.Free;
      end;
    end;
    { Remember a missing model too, so it is not looked for again }
    BspModelRoots.Add(Pak.VariantPath(Path), Root);
  end;
  if Root = nil then
    Exit;
  Result := TCastleScene.Create(Owner);
  Result.Load(Root.DeepCopy as TX3DRootNode, True);
end;

{ The methods of the subsystems, a file each (geometry) }
{$I geometry/quakegeometry_batch.inc}
{$I geometry/quakegeometry_lightmap.inc}
{$I geometry/quakegeometry_build.inc}
{$I geometry/quakegeometry_submodels.inc}
{$I geometry/quakegeometry_visibility.inc}
{$I geometry/quakegeometry_export.inc}

finalization
  FreeAndNil(BspModelRoots);
end.
