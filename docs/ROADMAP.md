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
| **Screen Effects** | Palette shifts on damage (red), pickup (gold), water (blue), biosuit (green) | Clean rendering without screen tints | Full-screen color blend tint overlay on damage and item pickup. |
| **3D Models** | Alias MDL v6 with discrete keyframes | Alias MDL v6 parser with skin mapping and X3D mesh generation | Add vertex interpolation (mesh lerping) between keyframes. |
| **Audio** | 8-bit unsigned PCM mono WAVs, OpenAL 3D spatialization, CD music | 3D OpenAL audio with `TCastleSoundSource`, OGG background music | Auto-convert 8-bit legacy Quake WAV headers for universal OpenAL compatibility. |
| **Player Movement** | Custom Quake physics: air acceleration, strafe-jumping, bunny-hopping, water swimming | `TCastleWalkNavigation` with Quake height (40), step climbing (18), gravity | Implement authentic Quake air-acceleration, friction, and swimming physics. |
| **Weapons & Combat** | 8 weapons: hitscan, spikes, bouncing grenades, rockets, lightning discharge | Axe, Shotgun, Super Shotgun, basic Rocket launcher projectile | Full ballistics (grenade bounce/fuse, spike trails, rocket jumping, lightning discharge). |
| **Monsters & AI** | 12 monster types + 2 bosses, state machine animations, infighting, sight tracing | Grunt, Dog, Ogre, Knight spawners and tracking | Add Fiend, Scrag, Hell Knight, Shambler, Vore, Tarbaby, Rotfish, and Bosses. |
| **Gibs & Gore** | Overkill (> -40 health) explodes monsters into flying head/meat gibs | Monster removal / death state | Spawn physical 3D gib entities with velocities and blood particles. |
| **Level Flow** | `trigger_changelevel`, locked doors with Silver/Gold keys, secret counters | Keys tracked in HUD, warp console command, submodel doors | Interactive level transitions, locked door triggers, secret trigger announcements. |
| **Intermission** | Intermission stats screen with animated tallies and sound effects | In-game status banner | Dedicated intermission view tallying kills, secrets, and time. |
| **Save / Load** | Quake binary savegame format (`.sav`) | Not yet implemented | JSON / binary serializer for player inventory, camera, and map state. |
| **Game Logic VM** | Stack-based QuakeC bytecode VM (`progs.dat`) | Native Object Pascal | Keep high-performance Pascal as primary; optional `progs.dat` interpreter. |

---

## 🗺️ Milestone Roadmap

### Phase 1: Authentic Look & Feel (Visual Polish)
- [x] **Dual-Layer Scrolling Sky Shader**:
  - Sky miptexes are split into a solid back layer and a transparent cloud front layer, projected onto Quake's flattened sky dome per fragment and scrolled at 8 / 16 texels per second.
- [ ] **Underwater Screen Distortion & Palette Tints**:
  - Implement full-screen screen flash overlays: red flash on player damage, gold flash on item pickup, green flash for biosuit.
  - Implement GLSL underwater wave distortion (sine lookup turbulence).
- [ ] **Model Keyframe Interpolation (Mesh Lerping)**:
  - Interpolate vertex positions between keyframes at runtime for silky-smooth 60+ FPS monster and weapon animations.
- [ ] **Ambient Map Sound Emitters**:
  - Spawn positional looping `TCastleSoundSource` entities for Quake ambient entities (`ambient_suck_wind`, `ambient_drone`, `ambient_drip`, `ambient_comp_hum`).

### Phase 2: Authentic Physics & Combat
- [ ] **Quake Movement Physics**:
  - Replicate Quake's original ground friction, acceleration, and air-acceleration enabling classic bunny-hopping and strafe-jumping.
  - Implement swimming state in `CONTENTS_WATER` with water friction, swimming up/down controls, air meter, and drowning damage.
  - Implement damaging hazard volumes for `CONTENTS_LAVA` and `CONTENTS_SLIME`.
- [ ] **Complete Weapons Arsenal**:
  - **Nailgun & Super Nailgun**: high-velocity spike projectiles with purple/blue contrails.
  - **Grenade Launcher**: bouncing physics with elasticity, floor rolling, 2.5-second fuse timer, and direct-hit detonation.
  - **Rocket Launcher**: smoke particle contrails, radius splash damage falloff, and physics knockback (enabling rocket jumping).
  - **Lightning Gun (Thunderbolt)**: continuous electric hitscan beam with water discharge catastrophe (instant suicide + area wipe if fired underwater).
- [ ] **Gib System**:
  - Monsters taking damage below -40 HP burst into 3D polygon meat and head gibs with scattering velocities and blood particle fountains.

### Phase 3: Monster Roster & AI Complete
- [ ] **Full Monster Cast**:
  - **Fiend (Demon)**: long-range leaping jump attacks and slash combos.
  - **Scrag (Wizard)**: 3D flying movement and spit projectile attacks.
  - **Hell Knight**: multi-slash projectiles and charging melee.
  - **Shambler**: long-range instant lightning spell and devastating claw melee.
  - **Vore (Shalrath)**: tracking purple homing pods.
  - **Tarbaby (Spawn)**: high-speed bouncing and explosive death.
  - **Rotfish**: aquatic swimming and biting.
  - **Chthon** (E1M7 boss) and **Shub-Niggurath** (End boss).
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
