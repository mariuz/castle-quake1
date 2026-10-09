# Castle Quake Roadmap

This document outlines the architectural comparison between **Castle Quake** and the original **Quake 1** (id Tech 2 / GLQuake / WinQuake), identifying missing features and detailing the implementation milestones to achieve 100% authentic Quake look, feel, and gameplay powered by the **Castle Game Engine**.

---

## 🎯 Architectural Comparison

| Subsystem | Original Quake 1 | Castle Quake (Current) | Target / Gap |
| :--- | :--- | :--- | :--- |
| **World Geometry** | BSP v29 tree, PVS clusters | Procedural X3D scene graphs (`TShapeNode`, `TIndexedTriangleSetNode`) | Full BSP geometry supported with texture coordinate mapping. |
| **Surface Lighting** | Static 8-bit luxel lightmaps in BSP + lightstyle animators | Real-time PBR lighting (`TCastlePointLight`, `TCastleDirectionalLight`) | Option for authentic baked lightmap rendering via custom GLSL shaders. |
| **Dynamic Lights** | Lightstyles (0..63) modulated at 10 Hz; muzzle flashes | Quake lightstyles (0..12) evaluated dynamically; muzzle flashes; shadow maps | Matches original; enhanced with real-time shadow mapping. |
| **Sky & Atmosphere** | Double-layer scrolling cylindrical sky dome | Dual-layer scrolling sky shader (`Effect` node, GLQuake `EmitSkyPolys` projection per fragment) | Matches original. |
| **Liquid Surfaces** | Translucent water, lava, slime with sine wave turbulence (`R_Turbulent`) | Animated textures and transparent blend mode | GLSL vertex/fragment wave distortion shader. |
| **Screen Effects** | Palette shifts on damage (red), pickup (gold), water (blue), biosuit (green) | `V_CalcBlend` color shifts (damage, pickup, water/slime/lava, biosuit) and `D_WarpScreen`-style underwater warp | Matches original. |
| **3D Models** | Alias MDL v6 with discrete keyframes | Alias MDL v6 parser, per-state animation sequences with keyframe interpolation | Matches original (plus lerping, like later Quake engines). |
| **Audio** | 8-bit unsigned PCM mono WAVs, OpenAL 3D spatialization, CD music | PAK WAVs played through OpenAL (`TCastleSoundSource`), static ambient emitters and BSP leaf ambients, OGG background music | Matches original. |
| **Player Movement** | Custom Quake physics: air acceleration, strafe-jumping, bunny-hopping, water swimming | Port of the NetQuake player physics (`QuakePhysics`) tracing the BSP clipping hulls, doors and monster boxes | Matches original. |
| **Weapons & Combat** | 8 weapons: hitscan, spikes, bouncing grenades, rockets, lightning discharge | All 8 weapons from QuakeC `weapons.qc`: hull-traced hitscan, colliding nails, bouncing grenades, rockets with splash and knockback, lightning beam and discharge | Matches original. |
| **Monsters & AI** | 12 monster types + 2 bosses, state machine animations, infighting, sight tracing | All 13 monster types and both bosses with QuakeC data, line-of-sight wake up, `SV_movestep` chasing and frame-timed attacks | Infighting and sound propagation. |
| **Gibs & Gore** | Overkill (> -40 health) explodes monsters into flying head/meat gibs | `ThrowGib` / `ThrowHead` with QuakeC thresholds, bouncing gib models and blood trails | Matches original. |
| **Level Flow** | `trigger_changelevel`, locked doors with Silver/Gold keys, secret counters | Keys tracked in HUD, warp console command, submodel doors | Interactive level transitions, locked door triggers, secret trigger announcements. |
| **Intermission** | Intermission stats screen with animated tallies and sound effects | In-game status banner | Dedicated intermission view tallying kills, secrets, and time. |
| **Save / Load** | Quake binary savegame format (`.sav`) | Not yet implemented | JSON / binary serializer for player inventory, camera, and map state. |
| **Game Logic VM** | Stack-based QuakeC bytecode VM (`progs.dat`) | Native Object Pascal | Keep high-performance Pascal as primary; optional `progs.dat` interpreter. |

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
- [ ] **Monster Infighting & Sound Propagation**:
  - Monsters retaliate against other monsters when damaged by friendly fire.
  - Weapon gunfire sound propagation alerting monsters across open doorways.

### Phase 4: Progression, UI, & Game Flow
- [ ] **Episode Portals & Hub Flow**:
  - Walking into difficulty and episode portals in `start.bsp` transitions seamlessly into `e1m1`, `e2m1`, `e3m1`, or `e4m1`.
- [ ] **Intermission Screen**:
  - Authentic intermission screen showing level title, animated tallies for kills, secrets, and time, accompanied by classic Quake tally sounds.
- [ ] **Save & Load System**:
  - Savegame system recording player state, inventory, camera position, submodel states, and remaining monsters to disk or browser `localStorage`.
- [ ] **Quake Demos (`.dem`)**:
  - Support recording and playback of original Quake demo files.

### Phase 5: Advanced & Modding Features
- [ ] **Software Lightmap Rendering Option**:
  - Shader-based baked BSP lightmap blending for players who want 100% authentic WinQuake/GLQuake software-style shadowing alongside modern real-time dynamic PBR lighting.
- [ ] **QuakeC (`progs.dat`) Bytecode Interpreter**:
  - Optional VM to run community QuakeC game mods directly inside Castle Quake.
- [ ] **Multiplayer / Deathmatch**:
  - Network multiplayer support over WebSockets / UDP.
