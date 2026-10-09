# Castle Quake

A modern port of **Quake 1** using the **Castle Game Engine** (Object Pascal / Free Pascal), supporting both the original **Quake 1 Demo / Shareware** and **LibreQuake** open-source assets.

Inspired by [mariuz/castle-doom](https://github.com/mariuz/castle-doom), Castle Quake showcases the full suite of features offered by Castle Game Engine (CGE): full 3D X3D scene graphs, real-time dynamic PBR lighting with shadow mapping, Quake 1 Alias MDL 3D model loading and animation, spatial 3D audio via OpenAL, custom URL protocols (`quakepak:`, `quaketex:`), multiple camera navigation modes (First-Person, Third-Person, Free-Fly), interactive submodels (doors, platforms, buttons), particle effects, in-game developer console, authentic status bar HUD, and an automated headless testing harness (`--autotest`, `--demo`).

- 🌐 **[Play in Browser (WebAssembly)](https://mariuz.github.io/castle-quake1/)**
- 📖 **[Architecture & Engine Mapping](docs/ARCHITECTURE.md)**
- 🗺️ **[Quake 1 Comparison & Roadmap](docs/ROADMAP.md)**
- 📦 **[Download Windows & Linux Releases](https://github.com/mariuz/castle-quake1/releases)**

---

## Features Showcasing Castle Game Engine

- **3D World Geometry from BSP (v29)**:
  - Parses Quake BSP v29 maps directly from `.pak` files.
  - Generates X3D scene graphs (`TShapeNode`, `TIndexedTriangleSetNode`, `TCoordinateNode`, `TTextureCoordinateNode`, `TAppearanceNode`, `TMaterialNode`).
  - Native triangle collision and physics navigation (`PreciseCollisions`, `TCastleWalkNavigation`).
  - Interactive submodels (`func_door`, `func_plat`, `func_button`) attached to `TCastleTransform` with real-time sliding, elevation, sound, and collision.
  - Animated textures (water, lava, slime, switches) cycled dynamically.

- **Real-Time Dynamic Lighting & Shadows**:
  - Automatically converts Quake map light entities (`light`, `light_fluorospark`, `light_globe`, `light_torch_small_walltorch`) into real-time CGE point lights (`TCastlePointLight`).
  - Emulates Quake's animated light styles (steady, flicker, strobe, candle, fluorescent pulse) at 10 Hz.
  - Real-time dynamic shadow mapping toggleable in options (`F2`).
  - Dynamic weapon muzzle flash lighting illuminating dark corridors upon firing.

- **3D Animated Alias Models (MDL)**:
  - Custom loader for Quake 1 Alias `.mdl` models.
  - Decodes skins into CGE textures, builds X3D meshes, and animates vertices across keyframe sequences.
  - 3D models for weapons (`progs/v_*.mdl`, `g_*.mdl`), pickups (armor, health, ammo, keys), and all Quake monsters (grunt, dog, ogre, knight, hell knight, enforcer, rotfish, vore, spawn, fiend, scrag, shambler, zombie, Chthon, Shub-Niggurath).

- **Spatial 3D Audio**:
  - Sound effects streamed from PAK WAV files using `TCastleSound`.
  - Positional 3D audio with attenuation using `TCastleSoundSource` attached to doors, lifts, monsters, and explosions.
  - OGG background music playback on looping channels (`SoundEngine.LoopingChannel[0]`).

- **Custom URL Protocols**:
  - `quakepak:`: streams uncompressed lumps, sounds, and data files directly into CGE's loaders without writing to disk.
  - `quaketex:`: decodes 8-bit palette-indexed textures and serves uncompressed 32-bit TGA streams into CGE's GPU texture cache.

- **Multiple Camera Navigation Modes**:
  - **First-Person View**: port of Quake's player physics: ground friction and acceleration, air control (bunny-hopping, strafe-jumping), 18-unit stair stepping, swimming and water jumps, collision against the BSP clipping hulls.
  - **Third-Person View**: Over-the-shoulder chase camera.
  - **Free-Fly / Noclip**: Unconstrained exploration camera.

- **Particles & Visual Combat Effects**:
  - Bullet impact sparks and smoke puffs against stone and metal walls.
  - Blood splatters when hitting monsters.
  - Rocket explosions and fireball debris.
  - Teleport destination particle fountains.

- **Developer Console & In-Game Cheats**:
  - Drop-down console toggled with `~` / \`.
  - Commands: `map <name>`, `god`, `give all`, `shadows <0|1>`, `quit`, `help`.

- **Automated Testing Harness**:
  - `--autotest <MAP> <PREFIX>`: loads map headlessly, executes `--demo` actions, takes PNG screenshots, and exits.

- **Dual Asset Support**:
  - Bundled with open-source **LibreQuake** assets (`pak0.pak`, `pak1.pak`, and music).
  - Fully compatible with original **Quake 1 Demo / Shareware** (`quake1_demo.pak` / `id1/pak0.pak`) and commercial Quake PAKs.

---

## Controls

| Key | Action |
| --- | --- |
| **W, A, S, D** / Arrows | Move forward, strafe left/right, backward |
| **Mouse Look** | Aim / Look around |
| **Left Mouse / Ctrl** | Fire equipped weapon |
| **Space** | Jump / swim up |
| **Shift** | Walk (movement is always-run) |
| **E** | Use / Open door / Press button |
| **1 .. 8** | Select weapon (Axe, Shotgun, SSG, Nailgun, SNG, GL, RL, LG) |
| **F1 / C** | Cycle Camera (First-Person, Third-Person, Free-Fly) |
| **F2** | Toggle Dynamic Real-Time Shadows |
| **F12** | Save Screenshot |
| **~** (Tilde) | Open / Close Developer Console |
| **Escape** | Open Main Menu / Options |

---

## Building and Running

Prerequisites:
- [Castle Game Engine](https://castle-engine.io/) 7.0-alpha.3 or later.
- Free Pascal Compiler (bundled with CGE).

### Windows (PowerShell)
```powershell
$env:PATH = "C:\castle-engine\bin;C:\castle-engine\tools\contrib\fpc\bin;" + $env:PATH
castle-engine compile --mode=release
.\castle-quake1.exe
```

### Command Line Options
```powershell
.\castle-quake1.exe -warp e1m1                     # Jump directly to E1M1
.\castle-quake1.exe -warp start                    # Jump to hub map
.\castle-quake1.exe -pak custom.pak                # Load additional PAK file
.\castle-quake1.exe -game quake -warp start        # Original Quake hub with episode portals
.\castle-quake1.exe -playdemo demo1.dem            # Play a Quake demo from the PAKs

In the Options menu, "World Lighting" switches between Quake's lightmaps (lightstyles and dynamic lights blended in a shader) and dynamic PBR lighting by the map's lights with shadow maps.
.\castle-quake1.exe --autotest start test_shot     # Headless test and screenshot
```

---

## Continuous Integration & Deployment

- `.github/workflows/build.yml`: Packages Windows x86_64 and Linux x86_64 standalone release builds using the Castle Game Engine Docker container (`kambi/castle-engine-cloud-builds-tools:cge-unstable`). Pushing tags like `v*` automatically creates a GitHub Release and attaches the packaged archives.
- `.github/workflows/web.yml`: Builds the WebAssembly version using Free Pascal's wasm32 cross-compiler and Pas2js, assembling the interactive landing page and deploying directly to **GitHub Pages**.

---

## License

- Code: MIT License (matching Castle Game Engine and mariuz/castle-doom).
- LibreQuake assets: See `data/paks/COPYING.txt` and `CREDITS.txt` for LibreQuake open source licenses (GPL / BSD / CC).
- Quake is a registered trademark of id Software / ZeniMax Media.
