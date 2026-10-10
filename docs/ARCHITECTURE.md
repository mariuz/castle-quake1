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
- Game directories (`-game <dir>`, `GameInitialize.LoadGameDir`): a mission pack (`hipnotic`, `rogue`) or mod directory is `<dir>/pak0..pak9.pak` found in the working directory, next to the executable, in the data or the config directory (or a path), loaded after id1 so its files win; `QuakePak.GameDir` names it. `-game quake` / `id1` only switch `PreferOriginalMaps`. QuakeC mode runs the pack's `progs.dat` this way; `TQuakeQcGame.PlayerItems` adds rogue's `items2` field in the high bits and `TViewQc` maps keys 9 / 0 to hipnotic's impulses 225 / 226.
- Intermission: `TQuakeWorld.StartIntermission` (camera at `info_intermission`, player frozen, monsters lose their target) and `TQuakeHud.StartIntermission`, which draws the qpics from `QuakePics` (`gfx/*.lmp` and `gfx.wad` lumps decoded with the palette into `TDrawableImage`s) on a 320x200 layout scaled to the window.
- QuakeC VM (`QuakeProgs`): `TQuakeProgs.Load` reads `progs.dat`; `Execute` interprets the bytecode (globals and entity fields are 4-byte cells, entity values are edict indexes, pointers are cell indexes into the edict memory); builtins are methods registered by number, the world dependent ones call `TQuakeProgsHost` (the default host is self contained). `SpawnEntities` and `RunFrame` mirror `ED_LoadFromFile` and the think part of `SV_Physics`. `QuakeQcGame.TQuakeQcGame` is the host for a real level: `TraceBox` (hull by size, pushers at their origins, solid entity boxes), `sv_move.c` ports for the monster builtins, `sv_phys.c` movetypes (`PhysicsPusher`, `PhysicsStep`, `PhysicsToss`, noclip), the player as edict 1 moved by `TQuakePlayerPhysics` around `PlayerPreThink` / `PlayerPostThink`, trigger touches and the svc messages written by the progs. `GameViewQc` renders its edicts and reads the player's fields for the HUD. It is a second gameplay path next to `TQuakeWorld`, used for mods.
- World lighting (`QuakeGeometry`, `QuakeLight`): the BSP lightmaps are packed per lightstyle slot into up to 4 atlases (`TQuakeLightmapAtlas`); each face carries its lightmap coordinates and 4 lightstyle indexes as vertex attributes, and one `TEffectNode` per BSP model (`TQuakeLightmapSet`) blends the layers with the `quake_lightstyles` uniform (from `TQuakeLighting.GetStyleMultiplier`, sent when a value changes) and adds `quake_dlights` (`TQuakeLighting.AddDLight`, filled by `TriggerMuzzleFlash`) in `PLUG_main_texture_apply`. With `WorldLightmaps = False` the surfaces get a `TPhysicalMaterialNode` lit by the map's `TCastlePointLight`s instead.
- Key doors (`TQuakeSubmodel.KeyNeeded`, `TQuakeWorld.TouchKeyDoor`): `func_door` with spawnflags 8 / 16 has no trigger field and `wait -1`; running into it or using it with the key opens it and takes the key, otherwise the worldtype message and try sound play (2 s cooldown).
- Liquids (`QuakeGeometry`): faces with `*` textures are translucent, non-solid batches with an `Effect` whose `PLUG_texture_coord_shift` ripples the texture coordinates like `R_Turbulent` (turbsin: 8 of 64 texels, `liquid_time` with a 2 pi period sent from `Update`).
- Demos (`QuakeDemo`, `GameViewDemo`): `TQuakeDemoReader` plays `.dem` files like `cl_parse.c` / `cl_main.c` (blocks of length, view angles and server messages; entities interpolated between the two latest server frames, `CL_LerpPoint`), reporting sounds, temp entities, particles, prints and lightstyles through events. `TViewDemo` loads the demo's map into its own viewport, places the brush entities and alias models each frame, follows the view entity and draws the view weapon, beams and the status bar. `TQuakeDemoWriter` records protocol 15 from `TQuakeWorld.RecordFrame` (hooks on `Sounds.OnPlay`, `Particles.OnEffect`, `Hud.OnMessage`), one serverinfo section per level, baselines and model / sound lists written when the file is saved.
- Inspector names: every transform the game creates gets a `Name` from `ComponentName` (`QuakePak`: identifier-safe base plus a per-level running number), so the engine's inspector (F8, enabled in all builds from `GameInitialize`) and the demo action `I` (`LogSceneTree`) show `world`, `func_door_7`, `monster_ogre_3`, `pickup_shells_2`, `light_12`, `ambient_comp1_1`, `edict_N`, `entity_N`, `view_weapon`, `camera`; `TQuakeLighting.Clear` frees the level's lights.
- Map export (`TQuakeGeometry.ExportMap`, `--export-map <map> <file.x3d|file.gltf>`): the world and the brush models built again as named `Transform`s, the light entities as `PointLight`s, textures saved as PNG files next to the output (`TTextureExporter` rewrites the `quaketex:` URLs), physical materials instead of the lightmap shader, saved with `SaveNode`.
- UI designs (`data/ui/*.castle-user-interface`): the menu, the HUD and the console are editor designs loaded with `UserInterfaceLoad` and filled by name (`ItemsGroup`, `MessageLabel`, `StatsLabel`, `ArmorValue`, `HealthValue`, `AmmoValue`, `KeysLabel`, `AirBar`, `Panel`, `OutputLabel`, `PromptLabel`); the code sets captions, colors and `Exists` each frame, the layout, fonts and colors are edited in the CGE editor. The palette blends, the crosshair and the intermission pictures stay in `TQuakeHud.Render`.
- Entities as behaviors (`QuakeBehaviors`): `TQuakeMonsterBehavior`, `TQuakePickupBehavior`, `TQuakeSubmodelBehavior` and `TQuakeTriggerBehavior` are `TCastleBehavior`s owned by and attached to the entity's transform (triggers get an empty transform under the `triggers` node) with published properties that read and write the entity's state, so the inspector (F8) edits a monster's health, a door's state or a trigger's wait while playing; `TQuakeWorld.LoadMap` attaches them after spawning.
- Debug overlay (`QuakeDebug`): `TQuakeDebugOverlay` keeps one unlit `TLineSetNode` with per-vertex colors under the `debug_overlay` transform; `TQuakeWorld.UpdateDebugOverlay` clears and refills it every frame according to `DebugModes` (trigger volumes, monster boxes and sight lines, mover bounds, the player's BSP leaf, player box and projectile markers). The console `debug` and `fps` commands and the demo action `D:` drive it; the QuakeC view's `E` action logs the edicts in use.
- QuakeC mode savegames and demos: `TQuakeProgs.SaveState` / `LoadState` write the VM (crc, entity field count, globals, used edicts with free flags and times, engine strings, precaches) as a stream; `TQuakeQcGame.SaveGame` / `LoadGame` store it hex encoded in a `TQuakeSaveData` with the map, skill, time, statics, lightstyles and view angles, reload the progs and the map without spawning (`LoadProgsAndMap`) and bind client 1's physics to the restored edict. `TViewQc` records demos with `TQuakeDemoWriter` from the player's fields and the visible edicts each frame, and from the game events.
- Multiplayer (`QuakeNet`, `QuakeServer`): `TQuakeServer` owns a `TQuakeQcGame` with `MaxClients` player edicts and `Deathmatch = 1` (or `Coop = 1` with a skill, for cooperative play) and a `TQuakeNetServer` (UDP, packets `[kind][seq][payload]`: connect / accept / refuse, reliable chunks acked one at a time, unreliable frames with a sequence number so late ones are dropped, inputs, disconnect, 10 s timeouts). On connect it takes a free client edict (`ConnectClient`: `ClientConnect` + `PutClientInServer`) and writes the signon into a `TQuakeNetMessage` (serverinfo with protocol 15, the map as model 1 followed by the progs' precache list so a progs `modelindex` is one more on the wire, lightstyles, `spawnstatic`, stats, setview, names and frags, setangle, signon 1-3). Each `Update` feeds the clients' latest `TNetInput` (angles, move, buttons, impulse; an input packet is used once so impulses do not repeat) into `SetClientInput`, runs one game frame (`MoveClient` per player, then `SV_Physics` for the rest) and sends every ready client `svc_time`, its `svc_clientdata`, every visible entity (no baselines, all fields each frame) and the frame's events; prints, centerprints, stuffcmds, lightstyles, frag changes and the non-effect svc messages of the progs go through the reliable channel. A level change reloads the game with the clients kept and resends the signon (`Resignon`). `TQuakeDemoReader.StartNetwork` makes the demo reader read the blocks pushed from `TQuakeNetClient` instead of a file (everything available each frame, `CL_LerpPoint` keeps the client time between the last two server frames), keeps the scoreboard and reports `svc_setangle`; `TViewDemo` with `NetHost` or `HostMap` set is the client view: it runs the listen server (`ListenServer`) when hosting, connects, reads the camera angles the mouse look turned, sends the input every frame and plays like a demo otherwise. `-host <map>`, `-connect host[:port]`, the Multiplayer menu, `--autotest host:<map>` / `connect:<host>`.
- Prediction and hole punching (`QuakeNet`, `GameViewDemo`): every `TNetInput` carries a sequence number and its duration in ms; the server queues a client's inputs and runs the player once per input for that duration (`TQuakeQcGame.RunClientInput`, after which `Frame` no longer moves that client), and each frame packet starts with the sequence of the last input applied. The client view keeps its own `TQuakePlayerPhysics` on the map (the brush entities where the server last showed them as colliders) and the unacknowledged inputs: a new server frame resets the physics to the view entity's origin, `svc_clientdata` velocity and ground flag, replays the pending inputs and the camera uses the predicted origin (not while dead or in the intermission; `Predict` / `-nopredict`). `TQuakeNetRendezvous` is a UDP service that remembers registered hosts by name (`pkRegister` every 5 s, 30 s expiry) and on a `pkLookup` sends the host's address to the client (`pkPeer`) and the client's to the host (`pkPunch`), which sends `pkHello` packets to it so its NAT lets the client's `pkConnect` in. `-rendezvous`, `-register name@host[:port]` on a host, `-connect name@host[:port]` on a client, `--autotest rendezvous`.
- Savegames: `QuakeSaveGame.TQuakeSaveData` (typed `key=value` text, saved through `castle-config:` URLs) filled by `TQuakeWorld.SaveGame`; `LoadGame` reloads the map with the saved skill and restores the player, submodels, pickups, monsters (`TQuakeMonster.RestoreState`) and triggers by index, then recreates the projectiles and gibs that were in flight (kind or model, origin, velocity, life, the monster owner by index).
- Episode and game endings (`TQuakeWorld`, `quakeworld_game.inc`): `IntermissionContinue` walks `intermission_running` 1 (tallies) to 2 (`EpisodeText` of e1m7 / e2m6 / e3m7 / e4m7, the shareware text when `maps/e2m1.bsp` is absent) to 3 (the all-four-runes text when `serverflags` has all episodes) before the next map; the HUD types the texts out over `gfx/finale.lmp` (`StartFinale`). `Telefrag` kills the monsters at a teleport destination; `monster_oldone` there starts `StartShubFinale` / `UpdateFinale` (teleport splash, death sound and lightstyle 0 `abcdefghijklmlkjihgfedcb`, the pop into gibs, the ending text, then `GameOver` which the play view turns into a new game). `misc_teleporttrain` is a spinning `progs/teleport.mdl` moving along its `path_corner`s at `speed` 100 and the fallback destination of a `trigger_teleport` that targets it.
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

- Skybox: `TQuakeGeometry.AddToWorld` reads the worldspawn `sky` key; when `gfx/env/<name>rt|bk|lf|ft|up|dn.tga` are in the paks (`SkyboxAvailable`) the sky batches get the `SkyboxFragmentShader` with six `sampler2D` uniforms (`quakepak:` URLs) instead of the two layer sky, picking the face from the view direction in Quake axes with the `vec_to_st` orientation of the original skybox code. Fullbright: `TQuakePalette.DecodeIndexed` with `FullbrightAlpha` writes alpha 255 for palette entries 224..255 (world textures only) and the lightmap shader mixes those texels to full color (`fragment_color.a`), the alpha mode staying opaque. Liquids: two sided, `DefaultLiquidAlpha` (0.65) as `1 - Transparency` of their unlit material, `LiquidAlpha` changes the live materials (console `wateralpha`). `TQuakeParticleManager.SpawnLavaSplash` is `R_LavaSplash` on every second cell of its 16 x 16 grid.

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

- Music: `PlayTrack(N)` maps Quake's CD track numbers to `data/music/trackNN.ogg` (track 2 when the file is missing); the native world, the QuakeC view and the demo / network client start the worldspawn `sounds` track of a map, and `svc_cdtrack` (`TQuakeDemoReader.OnCdTrack`, the raw message in `TViewQc.HandleMessage`) switches it. Under water (`SetUnderwater`) an EFX low-pass filter (`AL_FILTER_LOWPASS`, GAINHF 0.2) is set as the direct filter of every live OpenAL source; it is created once through CastleInternalEFX, applied again each frame while under water for new sources, and skipped without EFX or on the web.

- 2D sounds for UI and weapon fire (`SoundEngine.Play`).
- 3D spatial sounds with distance attenuation via `TCastleSoundSource` attached to doors, lifts, and monsters.
- Background OGG music played on `SoundEngine.LoopingChannel[0]`.
- `QuakeAmbient`: looping static emitters for ambient entities (Quake's linear `ATTN_STATIC` falloff computed in Pascal, OpenAL used for panning; at most 8 active sources) and BSP leaf ambients (water / wind) driven by the listener leaf's `ambient_level`.

---

## 9. QuakeWorld & Combat Simulation

- Layout: `code/quakeworld.pas` holds the `TQuakeWorld` declaration and includes its implementation from `code/world/quakeworld_*.inc`, one file per subsystem: `game` (construction, new game, respawn, intermission, `Update`), `map` (entity spawning, `LoadMap`), `player` (water rules, movement, damage, use, cheats), `weapons` (view model, traces, bullets, projectiles, explosions, gibs), `monsters` (`TWorldMonsterEnv`, steps, sight, noise, monster attacks), `movers` (submodels, targets, buttons, doors, lifts, triggers), `pickups`, `save`, `record` and `debug`. The pieces share the class's private state, so they are include files rather than units; the standalone helpers in them (`SaveStats`, `VelocityForDamage`, `ProjectileAttacker`, `SubmodelIsSolid`) have no world dependency.
- Weapons: Axe, Shotgun, Super Shotgun, Nailgun, Super Nailgun, Grenade Launcher, Rocket Launcher, Thunderbolt.
- Pickups: Armor, Health, Ammo, Keys, Powerups (Quad Damage, Pentagram).
- Monsters (`QuakeMonsters`): every Quake class is described by a `TMonsterDef` taken from QuakeC (size, health, gib threshold, frame ranges, run speed, attack frames, sounds). `TQuakeMonster.Update` runs a Quake-style think: sight checks with line of sight (`visible`), chasing with `SV_movestep` (hull traces, stair steps, no walking off ledges, detours when blocked; fliers and swimmers follow the player height), `CheckAttack` range chances, attacks fired on animation frames (hitscan pellets, ogre grenades, scrag / hell knight / vore / enforcer / zombie / lavaball missiles, shambler lightning), leaps (dog, fiend, spawn), pain, death and gibbing. The world implements `TQuakeMonsterEnv` (`TWorldMonsterEnv`) for traces, damage and missiles. Chthon wakes when used and only dies from the E1M7 electrodes (`event_lightning`); Shub-Niggurath is an invulnerable idle boss. Monsters fight an `Enemy` (nil = the player): damage from another monster class (`TakeDamage` with an attacker) starts infighting until that monster dies. Idle monsters wake on sight (`FindTarget`, with `infront` and `show_hostile`), on a monster that has just seen the player (`sight_entity`), and on gunfire noise (`TQuakeWorld.PropagateNoise`: within 1000 units, monster leaf in the player's PVS via `TQuakeBsp.LeafVisible`, no closed door in between); ambush monsters only wake on sight or damage.
- Entities with `SPAWNFLAG_NOT_MEDIUM` are skipped (skill 1), items fire their targets when picked up, and crucified zombies are decoration.
- Weapons follow QuakeC `weapons.qc`: hitscan and the lightning beam use `TraceShot` (BSP hull 0, brush entities, monster boxes); nails, grenades and rockets are `TQuakeProjectile`s moved by `UpdateProjectiles` with the same traces (grenades bounce with `ClipVelocity`). Explosions use `T_RadiusDamage` falloff, `CanDamage` line of sight and player knockback.
- Gibs: a monster killed below its `GibHealth` sets `GibPending`; `GibMonster` hides the body and spawns `TQuakeGib` heads and meat (`ThrowHead` / `ThrowGib`), moved by `UpdateGibs` as `MOVETYPE_BOUNCE`.

- Player physics: `QuakePhysics` ports the NetQuake server movement (`sv_user.c`, `sv_phys.c`) and the QuakeC player rules. The player is a 32×32×56 box traced through the BSP clipping hulls (`TQuakeBsp.TraceHull`, a port of `SV_RecursiveHullCheck`), brush entities at their current offsets, and monster boxes. `TQuakeWorld.MovePlayer` runs it each frame; the camera follows the eyes (origin + 22). `TCastleWalkNavigation` is only used for mouse look, and for flying in free-fly mode.

---

## 10. Input

- Bindings (`GameInput`): `Bindings[TQuakeBinding]` are global `TInputShortcut`s (group `igBasic`, names `quake_<action>`) created with their defaults by `InitializeBindings`, then `InputsAll.LoadFromConfig(UserConfig, 'bindings')`; `AssignBinding` rebinds one to a key, mouse button or wheel event with `AssignCurrent` and saves (`SaveToConfig` only writes what differs from the defaults). The views ask `BindingHeld` (keys, mouse buttons and the gamepad button standing for the action, the right trigger for fire) every frame and `BindingEvent` on presses; `TQuakeMenu` has the Controls submenu (`smControls`, `FBindWaiting` takes the next event). Gamepad: `Controllers.Initialize` at start, `GamepadMove` reads the left stick with a 0.2 dead zone into the user command, `GamepadTurnCamera` turns the camera with the right stick (160 deg/s yaw, 90 deg/s pitch, clamped at 85), `UpdateGamepad` / `GamepadJustPressed` give the edge of the buttons for use, weapon changes and the menus.

## 11. Automated Headless Testing

- Unit tests (`tests/quaketests.lpr`): a console program with the Quake units on its search path (`tests/CastleEngineManifest.xml`), loading `quake1_demo.pak` from the directory given as its argument; `Check` / `CheckEquals` helpers count the failures and the exit code is 1 when any failed. Covered: `TQuakeBsp.PointContents` / `TraceHull`, `TQuakeProgs` (function lookups, `anglemod` through `Execute`, `SpawnEntities` counts, `RunFrame`, `SaveState` / `LoadState`), `TQuakeSaveData` and `TQuakeDemoWriter` / `TQuakeDemoReader`. The Build workflow's `test` job runs it on Linux before the packages are released.

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
