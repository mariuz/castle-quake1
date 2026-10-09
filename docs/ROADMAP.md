# Castle Quake Roadmap

This document outlines the architectural comparison between **Castle Quake** and the original **Quake 1** (id Tech 2 / GLQuake / WinQuake), identifying missing features and detailing the implementation milestones to achieve 100% authentic Quake look, feel, and gameplay powered by the **Castle Game Engine**.

---

## 🎯 Architectural Comparison

| Subsystem | Original Quake 1 | Castle Quake (Current) | Target / Gap |
| :--- | :--- | :--- | :--- |
| **World Geometry** | BSP v29 tree, PVS clusters | Procedural X3D scene graphs (`TShapeNode`, `TIndexedTriangleSetNode`) | Full BSP geometry supported with texture coordinate mapping. |
| **Surface Lighting** | Static 8-bit luxel lightmaps in BSP + lightstyle animators | Default: the BSP lightmaps (all lightstyle layers) blended in a GLSL effect with the live lightstyle values and dynamic lights (`R_BuildLightMap` / `R_AddDynamicLights`). Option: physical materials under the engine's real-time point lights and shadow maps | Matches original; the dynamic PBR mode is the modern alternative. |
| **Dynamic Lights** | Lightstyles (0..63) modulated at 10 Hz; muzzle flashes | Quake lightstyles (0..12) evaluated dynamically; muzzle flashes; shadow maps | Matches original; enhanced with real-time shadow mapping. |
| **Sky & Atmosphere** | Double-layer scrolling cylindrical sky dome | Dual-layer scrolling sky shader (`Effect` node, GLQuake `EmitSkyPolys` projection per fragment) | Matches original. |
| **Liquid Surfaces** | Translucent water, lava, slime with sine wave turbulence (`R_Turbulent`) | Animated textures and transparent blend mode | GLSL vertex/fragment wave distortion shader. |
| **Screen Effects** | Palette shifts on damage (red), pickup (gold), water (blue), biosuit (green) | `V_CalcBlend` color shifts (damage, pickup, water/slime/lava, biosuit) and `D_WarpScreen`-style underwater warp | Matches original. |
| **3D Models** | Alias MDL v6 with discrete keyframes | Alias MDL v6 parser, per-state animation sequences with keyframe interpolation | Matches original (plus lerping, like later Quake engines). |
| **Audio** | 8-bit unsigned PCM mono WAVs, OpenAL 3D spatialization, CD music | PAK WAVs played through OpenAL (`TCastleSoundSource`), static ambient emitters and BSP leaf ambients, OGG background music | Matches original. |
| **Player Movement** | Custom Quake physics: air acceleration, strafe-jumping, bunny-hopping, water swimming | Port of the NetQuake player physics (`QuakePhysics`) tracing the BSP clipping hulls, doors and monster boxes | Matches original. |
| **Weapons & Combat** | 8 weapons: hitscan, spikes, bouncing grenades, rockets, lightning discharge | All 8 weapons from QuakeC `weapons.qc`: hull-traced hitscan, colliding nails, bouncing grenades, rockets with splash and knockback, lightning beam and discharge | Matches original. |
| **Monsters & AI** | 12 monster types + 2 bosses, state machine animations, infighting, sight tracing | All 13 monster types and both bosses with QuakeC data, `FindTarget` sight checks, `SV_movestep` chasing, frame-timed attacks, infighting, `sight_entity` alerts and PVS gunfire noise | Matches original (plus gunfire noise through open doorways). |
| **Gibs & Gore** | Overkill (> -40 health) explodes monsters into flying head/meat gibs | `ThrowGib` / `ThrowHead` with QuakeC thresholds, bouncing gib models and blood trails | Matches original. |
| **Level Flow** | `trigger_changelevel`, locked doors with Silver/Gold keys, secret counters | Start map hub with skill and episode portals, runes and episode gates, level parms carried between maps, trigger messages, secret areas, keys tracked in HUD, warp console command, submodel doors | Locked door triggers. |
| **Intermission** | Intermission stats screen with animated tallies and sound effects | `info_intermission` camera, level title, `gfx/complete.lmp` / `gfx/inter.lmp` and big number pictures with counting tallies, `trigger_secret` counting | Matches original (plus counting tallies). |
| **Save / Load** | Quake binary savegame format (`.sav`) | Text key/value savegames in the user config directory: level, player, inventory, doors and plats, items, monsters and triggers; F6 / F9 quicksave and console `save` / `load` | Projectiles and gibs in flight are not saved. |
| **Demos** | `.dem` recording and playback of the network stream (protocol 15) | `QuakeDemo`: protocol 15 reader with server frame interpolation shown by `GameViewDemo`, writer recording the game from `TQuakeWorld` (console `record` / `stop`) | Matches original; demos play in Quake engines too. |
| **Game Logic VM** | Stack-based QuakeC bytecode VM (`progs.dat`) | Native Object Pascal gameplay; a `progs.dat` interpreter (`QuakeProgs`) that loads the progs, spawns a map through its QuakeC spawn functions and runs the think loop with the engine builtins | Binding the VM to the world (physics, rendering, the player) so mods can replace the native gameplay. |

---

## 🗺️ Milestone Roadmap

### Phase 1: Authentic Look & Feel (Visual Polish)
- [x] **Dual-Layer Scrolling Sky Shader**:
  - Sky miptexes are split into a solid back layer and a transparent cloud front layer, projected onto Quake's flattened sky dome per fragment and scrolled at 8 / 16 texels per second.
- [x] **Underwater Screen Distortion & Palette Tints**:
  - Full-screen color shifts blended like `V_CalcBlend`: red on player damage (monster attacks now hurt the player, with armor absorption, death and level restart), gold on item pickup, green while the biosuit is active, and liquid tints when the eye is in water, slime or lava (BSP point contents).
  - GLSL screen effect reproducing the sine-wave underwater warp; liquid surfaces are no longer solid so the player can dive in.
- [x] **Model Keyframe Interpolation (Mesh Lerping)**:
  - `TMdlAnimator` plays QuakeC frame ranges at 10 Hz and interpolates vertex positions between keyframes every rendered frame; monsters use stand/run/attack/pain/death sequences and the view weapon plays its firing frames.
  - Distant (beyond 1024 units) and off-screen models skip the per-frame pose update to keep the cost low.
- [x] **Ambient Map Sound Emitters**:
  - Looping positional emitters for every entity QuakeC gives an `ambientsound()` (`ambient_*`, torches and flames, fluorescent lights), with Quake's linear `ATTN_STATIC` falloff; only the 8 loudest hold a sound source.
  - BSP leaf ambients: water and wind loops faded by the `ambient_level` of the listener's leaf (`S_UpdateAmbientSounds`).
  - Fixed the `quakepak:` protocol to report MIME types, without which no PAK sound could be decoded.

### Phase 2: Authentic Physics & Combat
- [x] **Quake Movement Physics**:
  - `SV_UserFriction` / `SV_Accelerate` / `SV_AirAccelerate` (30 u/s air wish speed: bunny-hopping and strafe-jumping), gravity 800, jump 270, stair stepping (`SV_WalkMove`) and plane sliding (`SV_FlyMove`) against the BSP clipping hulls (`SV_RecursiveHullCheck`), brush entities and monster boxes.
  - Swimming (`SV_WaterMove`: 0.7× speed, water friction, sink when idle, swim up with jump, look down to dive), water jumps out of pools, air supply with HUD meter, drowning, gasps and splash sounds.
  - Lava (10 × waterlevel every 0.2 s) and slime (4 × waterlevel per second) damage, reduced/blocked by the biosuit; falling damage and landing sounds.
  - Needed along the way: plats rest at the bottom and rise when stood on, doors open from their touch field, buttons fire their targets, triggers use their brush bounds and teleporters move the player.
- [x] **Complete Weapons Arsenal**:
  - Shots and projectiles trace the BSP hulls, brush entities and monster boxes (no more hitting the nearest monster through walls).
  - **Axe / Shotguns**: 64-unit melee trace; `FireBullets` with 6 pellets (spread 0.04) or 14 (0.14 x 0.08), 4 damage each, summed per target.
  - **Nailgun & Super Nailgun**: 10 nails per second at 1000 u/s from alternating barrels, 9 / 18 damage, ricochet sounds, blue-purple contrails.
  - **Grenade Launcher**: bouncing physics (1.5 overbounce, rests on floors), 2.5-second fuse, explodes on monsters, 120 radius damage.
  - **Rocket Launcher**: smoke trails, 100-120 direct damage plus `T_RadiusDamage` falloff, knockback (rocket jumping); missiles vanish into the sky.
  - **Lightning Gun (Thunderbolt)**: 600-unit beam drawn with `bolt2` segments, 30 damage per 0.1 s, underwater discharge that empties the cells and kills.
- [x] **Gib System**:
  - Overkill below each monster's QuakeC threshold (grunt and dog -35, knight -40, ogre -80) replaces the body with its head model and three meat gibs, thrown with `VelocityForDamage` (faster with more overkill), tumbling and bouncing on the BSP hulls, with blood trails, a blood fountain and `udeath.wav`. Gibs disappear after 10-20 seconds; heads stay.

### Phase 3: Monster Roster & AI Complete
- [x] **Full Monster Cast**:
  - **Fiend (Demon)**: long-range leaping jump attacks and slash combos.
  - **Scrag (Wizard)**: 3D flying movement and spit projectile attacks.
  - **Hell Knight**: multi-slash projectiles and charging melee.
  - **Shambler**: long-range instant lightning spell and devastating claw melee.
  - **Vore (Shalrath)**: tracking purple homing pods.
  - **Tarbaby (Spawn)**: high-speed bouncing and explosive death.
  - **Rotfish**: aquatic swimming and biting.
  - **Chthon** (E1M7 boss) and **Shub-Niggurath** (End boss).
  - Done with a data-driven `QuakeMonsters` unit: QuakeC sizes, health, frames and sounds for all classes (plus the existing grunt, dog, ogre, knight, and the enforcer and zombie); monsters wake on line of sight, chase with `SV_movestep` over the BSP hulls, attack on animation frames (traced grunt pellets replace the old hit chance), leap, flinch, die and gib. Zombies only die from gibbing and get knocked down by big hits; spawns explode; Chthon rises when the rune is taken and dies from three electrode shocks; Shub-Niggurath idles invulnerable (her telefrag ending is not done).
- [x] **Monster Infighting & Sound Propagation**:
  - Monsters retaliate against other monsters when damaged by friendly fire.
  - Weapon gunfire sound propagation alerting monsters across open doorways.
  - Done following QuakeC `T_Damage` / `ai.qc`: monsters track an `Enemy` (nil = the player) and turn on any other class that hurts them (grunts also fight grunts), with melee, pellets, missiles, lightning and leaps all hitting whatever is in the way; once that enemy dies they go back to the player. `FindTarget` now needs the player in front (`infront`) unless very close or the player just fired (`show_hostile`), a monster that has just spotted the player wakes the monsters that can see it (`sight_entity`), and gunfire wakes idle monsters within 1000 units whose leaf is in the player's PVS (the BSP visibility lump) and which no closed door cuts off. Ambush monsters (`spawnflags 1`) ignore both.

### Phase 4: Progression, UI, & Game Flow
- [x] **Episode Portals & Hub Flow**:
  - Walking into difficulty and episode portals in `start.bsp` transitions seamlessly into `e1m1`, `e2m1`, `e3m1`, or `e4m1`.
  - Done: `trigger_setskill` sets the skill used to spawn the next maps (`SPAWNFLAG_NOT_EASY/MEDIUM/HARD` for entities and brush models; nightmare limits monster pain), `trigger_changelevel` keeps the inventory like `SetChangeParms` (no keys or powerups, health 50..100) and a death restarts the level with the inventory it was entered with. Runes (`item_sigil`) set the server flags: back on the start map the player spawns at `info_player_start2` with a new inventory, `func_episodegate` closes completed episodes and `func_bossgate` opens with all four runes. `trigger_multiple` / `trigger_once` now honour `wait`, one-way angles and centerprint their messages. Portals to episodes missing from the paks say so. Single Player offers the id1 hub (from `quake1_demo.pak` or `id1/pak0.pak`, even though the bundled LibreQuake pak replaces `start.bsp`) and the LibreQuake hub; `-game quake` does the same from the command line.
- [x] **Intermission Screen**:
  - Authentic intermission screen showing level title, animated tallies for kills, secrets, and time, accompanied by classic Quake tally sounds.
  - Done: leaving a level through a `trigger_changelevel` without `NO_INTERMISSION` freezes the player and looks from a random `info_intermission` spot (`mangle`) to the intermission music, while the HUD draws `Sbar_IntermissionOverlay` from the PAK pictures (new `QuakePics` unit for `gfx/*.lmp` and `gfx.wad` qpics) under the level title. Time, secrets and kills count up one after another with ticks. After 5 seconds fire, jump or use loads the next map. `trigger_secret` now counts secret areas ("You found a secret area!").
- [x] **Save & Load System**:
  - Savegame system recording player state, inventory, camera position, submodel states, and remaining monsters to disk or browser `localStorage`.
  - Done with `QuakeSaveGame` (`key=value` text saved through `castle-config:/save_<slot>.sav`, so CGE puts it in the user config directory) and `TQuakeWorld.SaveGame` / `LoadGame`: map, skill, runes and the hub choice, player stats and the level start parms, origin, velocity and view, air and timers, door / plat / button positions and states, taken items, monsters (position, yaw, health, state, alert, enemy, gibbed, counted) and fired triggers. Loading spawns the map again with the saved skill and puts every entity back by index. F6 / F9 quicksave and quickload like Quake, console `save [slot]` / `load [slot]`, demo actions `O:slot` / `L:slot`. Not while dead or in the intermission.
- [x] **Quake Demos (`.dem`)**:
  - Support recording and playback of original Quake demo files.
  - Done with the `QuakeDemo` unit: `TQuakeDemoReader` parses the NetQuake protocol 15 stream (serverinfo, baselines, static entities, fast entity updates with `cl_parse.c` interpolation between server frames, client data, sounds, temp entities, particles, lightstyles, prints, intermission) and `GameViewDemo` shows it: the demo's map with its brush entities placed by the recording, alias models at their frames, the view entity's eyes and recorded view angles, the view weapon, beams, trails from the model flags, sounds, the status bar and the intermission. "Demos" in the menu lists the PAK demos and recordings; `-playdemo <name>` and `--autotest <name>.dem` play one. `TQuakeDemoWriter` records the game from `TQuakeWorld` (console `record <name>` / `stop`, demo action `R:name` / `R`): the player, doors, monsters, items, projectiles and gibs each frame, client data, sounds, explosions, teleports, puffs, blood, centerprints, kills, secrets, damage and the intermission, one serverinfo section per level, with models and sounds numbered on first use and baselines written when the demo is saved to `castle-config:/<name>.dem`.

### Phase 5: Advanced & Modding Features
- [x] **Software Lightmap Rendering Option**:
  - Shader-based baked BSP lightmap blending for players who want 100% authentic WinQuake/GLQuake software-style shadowing alongside modern real-time dynamic PBR lighting.
  - Done: `QuakeGeometry` packs every lightstyle layer of each face (up to 4, `TBSPFace.Styles`) into its own atlas and renders the world with an unlit material plus a GLSL `Effect` that sums the layers scaled by the current lightstyle values (flickering torches, pulsing lights on the walls, like `R_BuildLightMap`) and adds the dynamic lights of muzzle flashes and explosions (`R_AddDynamicLights`, `TQuakeLighting.AddDLight`), with Quake's x2 overbright. The alternative "Dynamic PBR" mode (Options menu, console `lightmaps 0`, demo action `B:0`) lights physical materials with the map's point lights (now attenuated) and shadow maps instead. Textures are kept in sRGB (no gamma correction).
- [ ] **QuakeC (`progs.dat`) Bytecode Interpreter**:
  - Optional VM to run community QuakeC game mods directly inside Castle Quake.
  - First step done: `QuakeProgs` loads `progs.dat` (version 6: statements, globals, fields, functions, strings), executes the whole instruction set like `pr_exec.c` (call stack, locals, `OP_STATE`, entity pointers), keeps the entity memory (`ED_Alloc` / `ED_Free`) and implements the builtins of `pr_cmds.c` (math, strings, `spawn`, `find`, `findradius`, `nextent`, precaches, prints, `changeyaw`, `vectoangles`, the `Write*` messages) with the world ones (`setmodel`, `traceline`, `walkmove`, `droptofloor`, sounds, lightstyles...) going through an overridable `TQuakeProgsHost`. `ED_LoadFromFile` spawns a map's entities through their QuakeC functions and `RunFrame` runs `StartFrame` and the due thinks. `--qctest <map>` runs this headless: on e1m1 the real progs spawn 336 entities, count 23 monsters and 6 secrets (the same as the native game) and run 2300 thinks in 10 s without errors. Not done: binding the host to the world (traces, physics, models, the player) so the VM drives the game.
- [ ] **Multiplayer / Deathmatch**:
  - Network multiplayer support over WebSockets / UDP.
