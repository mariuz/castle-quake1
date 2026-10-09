# Castle Quake: Architecture & Technical Design

This document explains the technical architecture of **Castle Quake**, how Quake 1 game data is parsed and rendered in the **Castle Game Engine (CGE)**, and which engine features each subsystem utilizes.

---

## 1. Overview & Data Flow

```
┌────────────────────────┐
│  pak0.pak / pak1.pak   │
│ (LibreQuake / Quake 1) │
└───────────┬────────────┘
            │
            ▼
        QuakePak (TQuakePak)
        ┌───┴──────────────────────────────┐
        ▼                                  ▼
   QuakePalette                       QuakeBsp (v29)
(palette.lmp, colormap.lmp)       (lumps, planes, faces,
        │                          texinfo, models, ents)
        ▼                                  │
quaketex: URL protocol                     ▼
(CGE Texture Cache)                QuakeGeometry
        │                      (X3D Node Scene Graph)
        │                                  │
        └──────────────┬───────────────────┘
                       ▼
                 QuakeWorld (Simulation)
            ┌──────────┴──────────┐
            ▼                     ▼
      QuakeEntities          QuakeLight
   (Pickups, Monsters,   (TCastlePointLight,
     Projectiles)         Lightstyles, Shadows)
            │                     │
            └──────────┬──────────┘
                       ▼
                 GameViewPlay (TCastleView)
                 ├── TCastleViewport
                 ├── TCastleWalkNavigation
                 ├── QuakeHud (Status Bar)
                 ├── QuakeParticles
                 └── QuakeConsole & QuakeMenu
```

Three core design principles drive Castle Quake:

1. **Native Engine Representation**: Geometry is represented as standard X3D nodes (`TShapeNode`, `TIndexedTriangleSetNode`, `TCoordinateNode`, `TAppearanceNode`, `TMaterialNode`) loaded into `TCastleScene`. Submodels (`func_door`, `func_plat`, `func_button`) are dynamic `TCastleTransform` nodes.
2. **Custom URL Protocols**: PAK files and textures are served through CGE's URL system (`quakepak:`, `quaketex:`). Textures are decoded into 32-bit TGA streams in memory, allowing CGE's GPU texture cache and mipmapping to work transparently without disk writes.
3. **Showcasing CGE Features**: Dynamic point lights with animated lightstyles, real-time shadow maps, positional 3D sound sources (`TCastleSoundSource`), particle effects, customizable camera navigation, and an automated headless test harness.

---

## 2. Coordinate System & Units

Quake uses:
- X = East (+X right)
- Y = North (+Y forward)
- Z = Height (+Z up)

Castle Game Engine uses Y-up:
- CGE.X =  Quake.X
- CGE.Y =  Quake.Z  (Height)
- CGE.Z = -Quake.Y  (Forward is -Z)

This transformation has a determinant of +1, preserving triangle winding order, surface normals, and handedness. 1 Quake unit equals 1 CGE unit.

Player dimensions:
- Quake eye height: 40 units -> `TCastleWalkNavigation.PreferredHeight = 40.0`
- Maximum step height: 18 units -> `TCastleWalkNavigation.ClimbHeight = 18.0`
- Run speed: 320 units/s -> `TCastleWalkNavigation.MoveSpeed = 320.0`
- Jump velocity: 270 units/s -> `TCastleWalkNavigation.JumpSpeed = 270.0`

---

## 3. QuakePak: Archive Management

- Supports stacking multiple PAK archives (`pak0.pak`, `pak1.pak`, PWAD/custom paks). Files replaced by a later pak are kept: with `PreferOriginalMaps` (the Quake episode hub) `maps/` come from the original id paks (`id1`, shareware) first.
- Intermission: `TQuakeWorld.StartIntermission` (camera at `info_intermission`, player frozen, monsters lose their target) and `TQuakeHud.StartIntermission`, which draws the qpics from `QuakePics` (`gfx/*.lmp` and `gfx.wad` lumps decoded with the palette into `TDrawableImage`s) on a 320x200 layout scaled to the window.
- QuakeC VM (`QuakeProgs`): `TQuakeProgs.Load` reads `progs.dat`; `Execute` interprets the bytecode (globals and entity fields are 4-byte cells, entity values are edict indexes, pointers are cell indexes into the edict memory); builtins are methods registered by number, the world dependent ones call `TQuakeProgsHost` (the default host is self contained). `SpawnEntities` and `RunFrame` mirror `ED_LoadFromFile` and the think part of `SV_Physics`. `QuakeQcGame.TQuakeQcGame` is the host for a real level: `TraceBox` (hull by size, pushers at their origins, solid entity boxes), `sv_move.c` ports for the monster builtins, `sv_phys.c` movetypes (`PhysicsPusher`, `PhysicsStep`, `PhysicsToss`, noclip), the player as edict 1 moved by `TQuakePlayerPhysics` around `PlayerPreThink` / `PlayerPostThink`, trigger touches and the svc messages written by the progs. `GameViewQc` renders its edicts and reads the player's fields for the HUD. It is a second gameplay path next to `TQuakeWorld`, used for mods.
- World lighting (`QuakeGeometry`, `QuakeLight`): the BSP lightmaps are packed per lightstyle slot into up to 4 atlases (`TQuakeLightmapAtlas`); each face carries its lightmap coordinates and 4 lightstyle indexes as vertex attributes, and one `TEffectNode` per BSP model (`TQuakeLightmapSet`) blends the layers with the `quake_lightstyles` uniform (from `TQuakeLighting.GetStyleMultiplier`, sent when a value changes) and adds `quake_dlights` (`TQuakeLighting.AddDLight`, filled by `TriggerMuzzleFlash`) in `PLUG_main_texture_apply`. With `WorldLightmaps = False` the surfaces get a `TPhysicalMaterialNode` lit by the map's `TCastlePointLight`s instead.
- Liquids (`QuakeGeometry`): faces with `*` textures are translucent, non-solid batches with an `Effect` whose `PLUG_texture_coord_shift` ripples the texture coordinates like `R_Turbulent` (turbsin: 8 of 64 texels, `liquid_time` with a 2 pi period sent from `Update`).
- Demos (`QuakeDemo`, `GameViewDemo`): `TQuakeDemoReader` plays `.dem` files like `cl_parse.c` / `cl_main.c` (blocks of length, view angles and server messages; entities interpolated between the two latest server frames, `CL_LerpPoint`), reporting sounds, temp entities, particles, prints and lightstyles through events. `TViewDemo` loads the demo's map into its own viewport, places the brush entities and alias models each frame, follows the view entity and draws the view weapon, beams and the status bar. `TQuakeDemoWriter` records protocol 15 from `TQuakeWorld.RecordFrame` (hooks on `Sounds.OnPlay`, `Particles.OnEffect`, `Hud.OnMessage`), one serverinfo section per level, baselines and model / sound lists written when the file is saved.
- Multiplayer (`QuakeNet`, `QuakeServer`): `TQuakeServer` owns a `TQuakeQcGame` with `MaxClients` player edicts and `Deathmatch = 1` (or `Coop = 1` with a skill, for cooperative play) and a `TQuakeNetServer` (UDP, packets `[kind][seq][payload]`: connect / accept / refuse, reliable chunks acked one at a time, unreliable frames with a sequence number so late ones are dropped, inputs, disconnect, 10 s timeouts). On connect it takes a free client edict (`ConnectClient`: `ClientConnect` + `PutClientInServer`) and writes the signon into a `TQuakeNetMessage` (serverinfo with protocol 15, the map as model 1 followed by the progs' precache list so a progs `modelindex` is one more on the wire, lightstyles, `spawnstatic`, stats, setview, names and frags, setangle, signon 1-3). Each `Update` feeds the clients' latest `TNetInput` (angles, move, buttons, impulse; an input packet is used once so impulses do not repeat) into `SetClientInput`, runs one game frame (`MoveClient` per player, then `SV_Physics` for the rest) and sends every ready client `svc_time`, its `svc_clientdata`, every visible entity (no baselines, all fields each frame) and the frame's events; prints, centerprints, stuffcmds, lightstyles, frag changes and the non-effect svc messages of the progs go through the reliable channel. A level change reloads the game with the clients kept and resends the signon (`Resignon`). `TQuakeDemoReader.StartNetwork` makes the demo reader read the blocks pushed from `TQuakeNetClient` instead of a file (everything available each frame, `CL_LerpPoint` keeps the client time between the last two server frames), keeps the scoreboard and reports `svc_setangle`; `TViewDemo` with `NetHost` or `HostMap` set is the client view: it runs the listen server (`ListenServer`) when hosting, connects, reads the camera angles the mouse look turned, sends the input every frame and plays like a demo otherwise. `-host <map>`, `-connect host[:port]`, the Multiplayer menu, `--autotest host:<map>` / `connect:<host>`.
- Savegames: `QuakeSaveGame.TQuakeSaveData` (typed `key=value` text, saved through `castle-config:` URLs) filled by `TQuakeWorld.SaveGame`; `LoadGame` reloads the map with the saved skill and restores the player, submodels, pickups, monsters (`TQuakeMonster.RestoreState`) and triggers by index.
- Game state across levels (`TQuakeWorld`): skill (`trigger_setskill`), server flags (episode runes), the level parms the player entered a map with (restored on death), and `SetChangeParms` on `trigger_changelevel`. The start map uses `info_player_start2` and the episode / boss gates once runes are collected.
- Case-insensitive lookup.
- Registered protocol `quakepak:` allows loading sounds and models via `quakepak:/sound/weapons/sgun1.wav`.

---

## 4. QuakePalette: Colors and Textures

- Quake palette `gfx/palette.lmp`: 256 RGB triples (768 bytes).
- Fullbright colors: indices 224 to 255 (unaffected by dimming).
- `quaketex:` protocol serves uncompressed 32-bit TGA streams (`WriteTga`), avoiding slow PNG encoding in native and WebAssembly builds.
- Textures are cached in `TQuakePalette.FTextureCache` and referenced by `TImageTextureNode`.

---

## 5. QuakeBsp & QuakeGeometry: 3D Map Generation

- Reads Quake BSP version 29 lumps:
  - Faces, vertices, edges, surfedges, planes, texinfo, miptex, models, entities.
- Triangles grouped by texture into `TQuakeGeomBatch`es.
- Interactive submodels (`func_door`, `func_plat`, `func_button`):
  - Model 0 is static world geometry.
  - Models 1..N are separate `TCastleScene`s attached to `TCastleTransform` with automated sliding, elevation, sound, and collision detection.
- Animated textures (`+0`..`+9`):
  - Cycled every 0.2s by updating `TImageTextureNode.SetUrl`.

---

## 6. QuakeLight: Real-Time Dynamic Lighting

- Maps Quake `light` entities to real-time `TCastlePointLight` nodes.
- Quake lightstyles (0..12) emulated at 10 Hz:
  - `0: "m"` (steady)
  - `1: "mmnmmommommnonmmonqnmmo"` (flicker)
  - `10: "mmamammmmammamamaaamamm"` (fluorescent flicker)
- Dynamic muzzle flash: point light created at camera upon firing.
- Real-time shadows: `TCastlePointLight.CastShadows = true`.

---

## 7. QuakeMdl: 3D Alias Models

- Decodes Quake 1 Alias `.mdl` files (`IDPO`, version 6).
- Converts skins into CGE textures.
- Constructs `TCastleScene` meshes with `TIndexedTriangleSetNode`.
- `TMdlAnimator` plays QuakeC frame ranges at 10 Hz and interpolates vertices between keyframes on `TCoordinateNode`.

---

## 8. QuakeSound: Spatial Audio & Music

- 2D sounds for UI and weapon fire (`SoundEngine.Play`).
- 3D spatial sounds with distance attenuation via `TCastleSoundSource` attached to doors, lifts, and monsters.
- Background OGG music played on `SoundEngine.LoopingChannel[0]`.
- `QuakeAmbient`: looping static emitters for ambient entities (Quake's linear `ATTN_STATIC` falloff computed in Pascal, OpenAL used for panning; at most 8 active sources) and BSP leaf ambients (water / wind) driven by the listener leaf's `ambient_level`.

---

## 9. QuakeWorld & Combat Simulation

- Weapons: Axe, Shotgun, Super Shotgun, Nailgun, Super Nailgun, Grenade Launcher, Rocket Launcher, Thunderbolt.
- Pickups: Armor, Health, Ammo, Keys, Powerups (Quad Damage, Pentagram).
- Monsters (`QuakeMonsters`): every Quake class is described by a `TMonsterDef` taken from QuakeC (size, health, gib threshold, frame ranges, run speed, attack frames, sounds). `TQuakeMonster.Update` runs a Quake-style think: sight checks with line of sight (`visible`), chasing with `SV_movestep` (hull traces, stair steps, no walking off ledges, detours when blocked; fliers and swimmers follow the player height), `CheckAttack` range chances, attacks fired on animation frames (hitscan pellets, ogre grenades, scrag / hell knight / vore / enforcer / zombie / lavaball missiles, shambler lightning), leaps (dog, fiend, spawn), pain, death and gibbing. The world implements `TQuakeMonsterEnv` (`TWorldMonsterEnv`) for traces, damage and missiles. Chthon wakes when used and only dies from the E1M7 electrodes (`event_lightning`); Shub-Niggurath is an invulnerable idle boss. Monsters fight an `Enemy` (nil = the player): damage from another monster class (`TakeDamage` with an attacker) starts infighting until that monster dies. Idle monsters wake on sight (`FindTarget`, with `infront` and `show_hostile`), on a monster that has just seen the player (`sight_entity`), and on gunfire noise (`TQuakeWorld.PropagateNoise`: within 1000 units, monster leaf in the player's PVS via `TQuakeBsp.LeafVisible`, no closed door in between); ambush monsters only wake on sight or damage.
- Entities with `SPAWNFLAG_NOT_MEDIUM` are skipped (skill 1), items fire their targets when picked up, and crucified zombies are decoration.
- Weapons follow QuakeC `weapons.qc`: hitscan and the lightning beam use `TraceShot` (BSP hull 0, brush entities, monster boxes); nails, grenades and rockets are `TQuakeProjectile`s moved by `UpdateProjectiles` with the same traces (grenades bounce with `ClipVelocity`). Explosions use `T_RadiusDamage` falloff, `CanDamage` line of sight and player knockback.
- Gibs: a monster killed below its `GibHealth` sets `GibPending`; `GibMonster` hides the body and spawns `TQuakeGib` heads and meat (`ThrowHead` / `ThrowGib`), moved by `UpdateGibs` as `MOVETYPE_BOUNCE`.

- Player physics: `QuakePhysics` ports the NetQuake server movement (`sv_user.c`, `sv_phys.c`) and the QuakeC player rules. The player is a 32×32×56 box traced through the BSP clipping hulls (`TQuakeBsp.TraceHull`, a port of `SV_RecursiveHullCheck`), brush entities at their current offsets, and monster boxes. `TQuakeWorld.MovePlayer` runs it each frame; the camera follows the eyes (origin + 22). `TCastleWalkNavigation` is only used for mouse look, and for flying in free-fly mode.

---

## 10. Automated Headless Testing

Command line parameters:
- `--autotest <MAP> <PREFIX>`: loads map headlessly, executes demo actions, takes screenshot, and terminates.
- `--demo "COMMANDS"`:
  - `W:sec` wait
  - `S` take screenshot
  - `X` fire weapon
  - `U` use/activate
  - `C:slot` change weapon
  - `F:sec` hold fire, `V:f;s;u` hold movement input, `J` jump, `G:x;y;z` teleport
  - `K` give all
  - `Y` god mode
  - `Q` quit
