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
- `N:0` / `N:1` PVS culling off (draw the whole world, like `r_novis 1`) / on
- `NC` render the current frame with PVS culling on and off and log how many pixels differ (`PVS compare:`; differing images are saved as `<prefix>_<n>_pvs.png` / `_full.png`)
- `Z` log the frame count, average and longest frame time since the previous `Z` with the PVS counts (camera leaf, clusters, shapes and entities drawn); screenshots log a `PVS:` line too
- `CMD:<command>` run a console command (e.g. `CMD:fov 110`, `CMD:gamma 0.7`, `CMD:fog 0.05`)
- `I` log the viewport's transform tree with the component names (what the F8 inspector shows)
- `D:modes` debug overlay: `all`, `off`, or a list of `triggers`, `monsters`, `movers`, `leaf` (e.g. `D:triggers;monsters`)
- `E` (QuakeC mode) log the edicts in use (classname, origin, health)
- `GL:x;y` / `GR:x;y` virtual gamepad left / right stick (-1..1, y up), `GT:v` right trigger (0..1), `GB:button` press a button for 0.2 s (`south`/`a`, `east`/`b`, `west`/`x`, `north`/`y`, `lb`, `rb`, `up`, `down`, `left`, `right`, `start`, `back`); play view screenshots log the eye, yaw, pitch, weapon and ammo

QuakeC mode: `-qc e1m1` plays the map with `progs.dat` driving the entities and the player; `--autotest qc:e1m1 C:\TMP\qc --demo "W:1,S,Q"` does it headless (actions W, S, X, F, C, A, T, P, G, V, J, K, Y, O, L, R, E, Q; screenshots log health and kills; saves go to `castle-config:/qc_save_<slot>.sav`). `--qctest e1m1` only loads `progs.dat`, spawns the map's entities through their QuakeC spawn functions, runs 10 s of thinks and logs the counts (`QcTest:` lines), then exits.

Endings: after the tallies, a button press (fire or jump, `X` / `J` headless) shows the episode text and, with all four runes, the all-runes text before the next map; telefragging Shub-Niggurath in `end.bsp` plays the ending and a button starts a new game. `--autotest e1m7 ... --demo "W:0.5,Y,G:8;46;-64,W:0.5,G:1016;-980;-52,W:1,S,W:5,X,W:3,S,X,W:3,S,Q"` runs the rune, the exit, the tallies and the text headless.

Skyboxes: a worldspawn `sky` key with `gfx/env/<name>{rt,bk,lf,ft,up,dn}.tga` in a pak (for instance a `-game` directory) replaces the scrolling sky; the log says `Skybox "<name>"`.

Audio headless: without a sound device the sound engine stays off (no music, no EFX); on Linux `ALSOFT_DRIVERS=null` gives OpenAL Soft's silent device, so music selection and the underwater low-pass filter run and log (`QuakeSound:` lines).

Mission packs and mods: `-game hipnotic` (or `rogue`, a mod directory, or a path) loads the directory on top of id1 from the working directory, next to the executable, the data or the config directory: its loose files (`<dir>/maps/x.bsp`...), then `pak0..9.pak` (overriding loose files, like Quake), then `*.pk3` zip archives in name order; `-game hipnotic -qc start` plays the pack with its QuakeC (hipnotic keys 9 / 0 are the laser cannon / Mjolnir). The packs are not bundled.

BSP2 maps: `BSP2` and `2PSB` levels load like BSP29 ones (the log says `Loaded map "..." (BSP2)`); `python3 tests/bsp2convert.py e1m1 <dir>` writes E1M1 in both formats to `<dir>/pak0.pak` for `-game <dir>` (`e1m1_bsp2`, `e1m1_2psb`).

Protocol 666: demos and network games use FitzQuake's protocol for a level with more than 255 models or sounds (16-bit numbers through extension bits), protocol 15 otherwise; `-protocol 666` always uses it. Demo playback and the network client read both.

Colored light and fog: a `maps/<name>.lit` next to a map (in a pak, a `-game` directory or a `.pk3`) colors its lightmaps (the log says `Colored lightmaps from ...`), and a worldspawn `fog` key (`density [r g b]`, FitzQuake style) fogs the level (`Fog: density ...`); the console `fog <density> [r g b]` changes it, `fog 0` turns it off. `tests/bsp2convert.py` has `make_lit` and `set_worldspawn_key` to make test maps.

Video options (`GameVideo`): `fov` (horizontal at 4:3, Hor+ on wider windows), `gamma`, `cl_bob` and `r_drawviewmodel` in Options and the console, saved under `video/` in the user config; autotest runs always use the defaults (90, 1, 0.02, on) and never save, so the reference screenshots do not depend on the developer's settings.

Lightmap atlas pages: the world's lightmaps fill 2048 x 2048 pages and a full page opens another; `-lmatlas <size>` makes the pages smaller to test that (the log says `Lightmaps of model 0: N atlas page(s) ...`).

Map export: `--export-map e1m1 C:\TMP\e1m1.x3d` writes the level as X3D (or glTF by the extension) with the textures as PNG files next to it, to inspect in the CGE editor or view3dscene.

Demo playback: `--autotest demo1.dem C:\TMP\d --demo "W:5,S,Q"` plays a PAK demo (or a file / `castle-config:` URL) with only `W`, `S` and `Q` actions; `-playdemo <name>` plays one from the menu view.

Multiplayer: `-host <map> [-port N] [-coop] [-skill N]` hosts a deathmatch (or coop) game (UDP, default port 26000) and plays in it, `-connect host[:port]` joins one. Headless: `--autotest host:start C:\TMP\h --demo "W:5,S,Q"` and, in a second process, `--autotest connect:127.0.0.1 C:\TMP\c --demo "W:3,S,X,W:1,S,Q"` (actions W, S, X, F, C, A, T, P, V, J, Q; screenshots log signon, health, frags and the client-side prediction error). `K` and `Y` are no cheats in deathmatch. The host logs `Client frames: ... entities per frame: N sent, M outside the PVS, D dropped, B bytes on average` every 10 s (it sends only the entities in each client's PVS, as differences from their baselines). `-nopredict` turns the prediction of the local player off. Browser players: `-host <map> -websocket 26001` also runs a WebSocket relay to the listen server (TCP), `-wsrelay host[:port] [-port N]` runs one alone (headless: `--autotest wsrelay:127.0.0.1:26000 C:\TMP\r --demo "W:30,S,Q"`, screenshots log the relayed message counts); the web build joins with `?connect=host[:port]` in the page URL (`wss://` needed from an https page, so put a TLS proxy in front of the relay). Behind NATs: `-rendezvous [-port N]` runs the rendezvous service (headless: `--autotest rendezvous C:\TMP\r --demo "W:30,Q"`), the host adds `-register name@rendezvous[:port]` and the client uses `-connect name@rendezvous[:port]`.
- `Q` quit application

## Web Build

The `Web` workflow builds it with FPC's main branch (wasm32-wasip1 cross compiler) and Pas2js. Locally, with that toolchain first in PATH and `PPC_CONFIG_PATH` set: `castle-engine compile --target=web --mode=release`, then serve `castle-engine-output/web/dist/` over HTTP. The trunk compiler can stop with "Compilation raised exception internally" on an incremental rebuild: delete `castle-engine-output/compilation/wasm32-wasip1` and build again. WebAssembly cannot catch exceptions, so code for the web must not raise (check before calling).

## Gameplay Scenarios

`python3 tests/scenarios.py` (after a release build, Pillow and on Linux xvfb-run needed) plays eight scripted games headless (E1M1 to E1M2, a save / load in a fight, a deathmatch host and client, QuakeC mode, E1M1 with small lightmap atlas pages, E1M1 converted to BSP2 and 2PSB, a mod directory with loose files, a pak and a .pk3, E1M1 with colored light and fog), checks their logs and compares the stable screenshots with `tests/reference/*.png`; `--only <name>` runs one, `--update` rewrites the references after an intended visual change. Output and `*_compare.png` images go to `castle-engine-output/scenarios/`. The Build workflow runs it on Linux and the release depends on it. Save and load logs print the stats they write and restore, and play view screenshots log the map, eye, angles, weapon, ammo, health, kills and the intermission state, so scenarios assert on logs rather than on pixels where they can.

## Unit Tests

`tests/quaketests.lpr` (own manifest, no window) checks the BSP tracer, the PVS rows and the server's fat PVS, the field of view and view bob, the QuakeC VM, savegame round trips and the demo writer / reader (protocol 15 and 666) against the shareware pak: `cd tests; castle-engine compile; .\quaketests ..\data\paks` (exit code = failures). The Build workflow runs it on Linux.

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
- **Input**: actions are `GameInput.Bindings[qb...]` (`TInputShortcut`, rebindable in Options > Controls, saved in the user config); views use `BindingHeld` / `BindingEvent` and the gamepad helpers, never raw keys for gameplay.
- **UI**: the menu, HUD and console layouts are editor designs in `data/ui/*.castle-user-interface` (open them in the CGE editor); the code finds components by name and only sets captions, colors and visibility.
- **Paths**: Keep project paths short to avoid Windows path length issues.
