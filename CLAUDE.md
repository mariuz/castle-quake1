# CLAUDE.md

Working notes for developers and AI agents on Castle Quake: a Quake 1 port to Castle Game Engine (CGE) in Object Pascal (FPC). Read `docs/ARCHITECTURE.md` for full architectural details.

## What this is

- Quake 1 levels (`maps/*.bsp`), models (`progs/*.mdl`), textures, and audio are parsed from PAK archives at runtime.
- Bundled with open-source **LibreQuake** assets in `data/paks/` (`pak0.pak`, `pak1.pak`), and fully compatible with original **Quake 1 Demo / Shareware** (`quake1_demo.pak` / `id1/pak0.pak`).
- Served to Castle Game Engine through custom memory URL protocols (`quakepak:`, `quaketex:`).
- Map geometry is generated into X3D scene graphs (`QuakeGeometry`), dynamic lights with Quake lightstyles (`QuakeLight`), 3D Alias models (`QuakeMdl`), spatial audio with OpenAL (`QuakeSound`), and full gameplay simulation in `QuakeWorld`.

## Build and Run (Windows)

Castle Game Engine 7.0-alpha.3 snapshot with bundled FPC 3.2.2 is installed at `C:\castle-engine`:

```powershell
$env:PATH = "C:\castle-engine\bin;C:\castle-engine\tools\contrib\fpc\bin;" + $env:PATH
castle-engine compile --mode=release      # or --mode=debug
.\castle-quake1.exe
```

Audio requires `OpenAL32.dll` and `wrap_oal.dll` in the executable directory (already copied).

## Automated Headless Testing

The autotest harness allows headless verification and screenshot generation:

```powershell
.\castle-quake1.exe --autotest start C:\TMP\shot --demo "W:1.0,S,X,W:0.5,S,Q"
.\castle-quake1.exe --autotest e1m1 C:\TMP\e1 --demo "W:0.5,C:3,X,W:0.5,S,Q"
.\castle-quake1.exe --game quake --autotest start C:\TMP\hub --demo "W:1,S,Q"   # id1 hub (shareware start.bsp) instead of the LibreQuake one
```

Demo script actions:
- `W:sec` wait seconds
- `S` take screenshot
- `X` fire equipped weapon
- `F:sec` hold fire (nailguns, lightning gun)
- `U` use / activate door or button
- `C:slot` switch weapon (1: Axe, 2: Shotgun, 3: SSG, 4: Nailgun, 5: SNG, 6: GL, 7: RL, 8: LG)
- `A:deg` absolute yaw angle
- `T:deg` relative yaw turn
- `P:deg` absolute pitch (positive looks up), keeps current yaw
- `M:units` move the player along the view direction (teleport)
- `G:x;y;z` teleport the player's eyes to CGE coordinates
- `V:f;s;u` hold movement input: forward / side / up as fractions of full speed (`V:0;0;0` stops)
- `J` jump (press briefly)
- `K` cheat: give all weapons, ammo, keys
- `Y` cheat: toggle god mode
- `O:slot` save the game to a slot, `L:slot` load it (`castle-config:/save_<slot>.sav`)
- `R:name` record a demo to `castle-config:/<name>.dem`, `R` stops it
- `B:1` / `B:0` world lighting: Quake lightmaps or dynamic PBR (reloads the map)
- `I` log the viewport's transform tree with the component names (what the F8 inspector shows)
- `D:modes` debug overlay: `all`, `off`, or a list of `triggers`, `monsters`, `movers`, `leaf` (e.g. `D:triggers;monsters`)
- `E` (QuakeC mode) log the edicts in use (classname, origin, health)

QuakeC mode: `-qc e1m1` plays the map with `progs.dat` driving the entities and the player; `--autotest qc:e1m1 C:\TMP\qc --demo "W:1,S,Q"` does it headless (actions W, S, X, F, C, A, T, P, G, V, J, K, Y, O, L, R, E, Q; screenshots log health and kills; saves go to `castle-config:/qc_save_<slot>.sav`). `--qctest e1m1` only loads `progs.dat`, spawns the map's entities through their QuakeC spawn functions, runs 10 s of thinks and logs the counts (`QcTest:` lines), then exits.

Mission packs and mods: `-game hipnotic` (or `rogue`, a mod directory, or a path) loads `<dir>/pak*.pak` on top of id1 from the working directory, next to the executable, the data or the config directory; `-game hipnotic -qc start` plays the pack with its QuakeC (hipnotic keys 9 / 0 are the laser cannon / Mjolnir). The packs are not bundled.

Map export: `--export-map e1m1 C:\TMP\e1m1.x3d` writes the level as X3D (or glTF by the extension) with the textures as PNG files next to it, to inspect in the CGE editor or view3dscene.

Demo playback: `--autotest demo1.dem C:\TMP\d --demo "W:5,S,Q"` plays a PAK demo (or a file / `castle-config:` URL) with only `W`, `S` and `Q` actions; `-playdemo <name>` plays one from the menu view.

Multiplayer: `-host <map> [-port N] [-coop] [-skill N]` hosts a deathmatch (or coop) game (UDP, default port 26000) and plays in it, `-connect host[:port]` joins one. Headless: `--autotest host:start C:\TMP\h --demo "W:5,S,Q"` and, in a second process, `--autotest connect:127.0.0.1 C:\TMP\c --demo "W:3,S,X,W:1,S,Q"` (actions W, S, X, F, C, A, T, P, V, J, Q; screenshots log signon, health, frags and the client-side prediction error). `K` and `Y` are no cheats in deathmatch. `-nopredict` turns the prediction of the local player off. Behind NATs: `-rendezvous [-port N]` runs the rendezvous service (headless: `--autotest rendezvous C:\TMP\r --demo "W:30,Q"`), the host adds `-register name@rendezvous[:port]` and the client uses `-connect name@rendezvous[:port]`.
- `Q` quit application

## Conventions & Rules

- **Indentation & Formatting**: 2-space indent, `begin`/`end` on their own lines, PascalCase identifiers, no `with`.
- **Coordinate System**:
  - `CGE.X = Quake.X`
  - `CGE.Y = Quake.Z` (Height)
  - `CGE.Z = -Quake.Y` (Forward is -Z)
- **Units**:
  - `Quake*` for core asset parsing and simulation.
  - `Game*` for CGE views and lifecycle.
  - `TQuakeWorld` is declared in `code/quakeworld.pas` and implemented in `code/world/quakeworld_<subsystem>.inc` include files (game, map, player, weapons, monsters, movers, pickups, save, record, debug); add a method's body to the file of its subsystem.
- **UI**: the menu, HUD and console layouts are editor designs in `data/ui/*.castle-user-interface` (open them in the CGE editor); the code finds components by name and only sets captions, colors and visibility.
- **Paths**: Keep project paths short to avoid Windows path length issues.
