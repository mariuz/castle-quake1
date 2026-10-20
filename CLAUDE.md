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
.\castle-quake1.exe --game quake --autotest start C:\TMP\hub --demo "W:1,S,Q"   # id1 hub (shareware start.bsp) with id1 models and sounds (Pak.PreferOriginal) instead of the LibreQuake one
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
- `TD:id;x;y` / `TM:id;x;y` / `TU:id` touch down / moved / up at window fractions (0..1 from the bottom left): the left half is the move stick, the right half drags to look, the buttons are FIRE, JUMP, USE, `<` `>` and MENU (logs `Touch ...` with the stick and buttons)
- `GL:x;y` / `GR:x;y` virtual gamepad left / right stick (-1..1, y up), `GT:v` right trigger (0..1), `GB:button` press a button for 0.2 s (`south`/`a`, `east`/`b`, `west`/`x`, `north`/`y`, `lb`, `rb`, `up`, `down`, `left`, `right`, `start`, `back`); play view screenshots log the eye, yaw, pitch, weapon and ammo

QuakeC mode: `-qc e1m1` plays the map with `progs.dat` driving the entities and the player; `--autotest qc:e1m1 C:\TMP\qc --demo "W:1,S,Q"` does it headless (actions W, S, X, F, C, A, T, P, G, V, J, K, Y, O, L, R, E, Q; screenshots log health and kills; saves go to `castle-config:/qc_save_<slot>.sav`). `--qctest e1m1` only loads `progs.dat`, spawns the map's entities through their QuakeC spawn functions, runs 10 s of thinks and logs the counts (`QcTest:` lines), then exits.

Endings: after the tallies, a button press (fire or jump, `X` / `J` headless) shows the episode text and, with all four runes, the all-runes text before the next map; telefragging Shub-Niggurath in `end.bsp` plays the ending and a button starts a new game. `--autotest e1m7 ... --demo "W:0.5,Y,G:8;46;-64,W:0.5,G:1016;-980;-52,W:1,S,W:5,X,W:3,S,X,W:3,S,Q"` runs the rune, the exit, the tallies and the text headless.

Skyboxes: a worldspawn `sky` key with `gfx/env/<name>{rt,bk,lf,ft,up,dn}.tga` in a pak (for instance a `-game` directory) replaces the scrolling sky; the log says `Skybox "<name>"`.

Audio headless: without a sound device the sound engine stays off (no music, no EFX); on Linux `ALSOFT_DRIVERS=null` gives OpenAL Soft's silent device, so music selection and the underwater low-pass filter run and log (`QuakeSound:` lines).

Mission packs and mods: `-game hipnotic` (or `rogue`, a mod directory, or a path) loads the directory on top of id1 from the working directory, next to the executable, the data or the config directory: its loose files (`<dir>/maps/x.bsp`...), then `pak0..9.pak` (overriding loose files, like Quake), then `*.pk3` zip archives in name order; `-game hipnotic -qc start` plays the pack with its QuakeC (hipnotic keys 9 / 0 are the laser cannon / Mjolnir). The packs are not bundled.

BSP2 maps: `BSP2` and `2PSB` levels load like BSP29 ones (the log says `Loaded map "..." (BSP2)`); `python3 tests/bsp2convert.py e1m1 <dir>` writes E1M1 in both formats to `<dir>/pak0.pak` for `-game <dir>` (`e1m1_bsp2`, `e1m1_2psb`).

Protocol 666: demos and network games use FitzQuake's protocol for a level with more than 255 models or sounds, or a worldspawn `fog` or `sky` key (16-bit numbers through extension bits), protocol 15 otherwise; `-protocol 666` always uses it. Protocol 999 (RMQ: FitzQuake's messages with float coordinates and 16-bit angles, protocol flags 18) is used for a map reaching beyond +-4096 units (`MapNeedsLargeCoords`), `-protocol 999` always. Demo playback and the network client read all three (999 with any flags). `tests/bsp2convert.py` has `translate` to move a map (the `largecoords` scenario moves E1M1 by 8192 units); demo and network screenshots log `View entity N at x y z (protocol P)`.

Colored light and fog: a `maps/<name>.lit` next to a map (in a pak, a `-game` directory or a `.pk3`) colors its lightmaps (the log says `Colored lightmaps from ...`), and a worldspawn `fog` key (`density [r g b]`, FitzQuake style) fogs the level (`Fog: density ...`); the console `fog <density> [r g b]` changes it, `fog 0` turns it off, and `sky <name>` shows the skybox `gfx/env/<name>` (`sky -` the scrolling sky). A level with a `fog` or `sky` key is protocol 666 in demos and network games, which carry the sky and fog (`svc_skybox`, `svc_fog`) and the console's changes; the demo / network view applies them (and a stuffed `fog` command). `tests/bsp2convert.py` has `make_lit` and `set_worldspawn_key` to make test maps.

Video options (`GameVideo`): `fov` (horizontal at 4:3, Hor+ on wider windows), `gamma`, `cl_bob` and `r_drawviewmodel` in Options and the console, saved under `video/` in the user config; autotest runs always use the defaults (90, 1, 0.02, on) and never save, so the reference screenshots do not depend on the developer's settings.

Accessibility (`QuakeCaptions`): `captions 1` (Options > Captions) shows captions for the sounds that matter, with `< left`, `right >`, `^ ahead ^` or `[behind]` for positional ones (the log says `Caption: <text> (<direction>)`); `hud_contrast 1` gives the HUD a black and yellow high contrast look, `reduced_flashes 1` cuts the damage and pickup flashes to a third. Saved under `access/` in the user config; autotest runs start with all three off. A new caption is a line in `CaptionTable` (a file, or a directory ending with `/`).

Lightmap atlas pages: the world's lightmaps fill 2048 x 2048 pages and a full page opens another; `-lmatlas <size>` makes the pages smaller to test that (the log says `Lightmaps of model 0: N atlas page(s) ...`).

Horde mode (`code/world/quakeworld_horde.inc`): `-horde` (`?horde=1`, Single Player > Horde Mode, console `horde [0|1]`) replaces the map's monsters with waves that teleport in out of the player's sight; the log says `Horde on "<map>": N spawn spots`, `Wave N: M monsters`, `Wave N cleared: score S` and every 10 s `Wave N: A alive, T to come, nearest D units`; dying logs `Horde over ...` and restarts it. The console `killall` kills every monster (tests clear a wave with `CMD:killall`).

Speedrun and ghost (`code/world/quakeworld_ghost.inc`): `-speedrun` / `-ghost` (Options, console `speedrun`, `ghost`) show `RUN m:ss.cc` in the stats line and race the map's best run, kept in `castle-config:/ghost_<map>.ghost` when a level is finished faster; the log says `Speedrun: <map> in ... (best ..., +d.dd)`, `New best run of "<map>" kept`, `Ghost of "<map>": best ...` and `Checkpoint at m:ss.cc: +d.dd`. `ghost_reset` forgets the map's best run (tests start with `CMD:ghost_reset`).

Random maps (`QuakeRandomMap`): `maps/random<seed>.bsp` (and `.lit`) is built in memory the first time the pak is asked for it, so `-randommap [seed]` (a new seed without one), `-warp random42`, `-qc random42`, `-host random42`, `?randommap=<seed>` / `?randommap=new` in the browser and Single Player > Random Map all play the same level for a seed; its exit pad leads to `random<seed + 1>`. The log says `Random map <seed>: N rooms (N reachable), ... start x y z, exit x y z, textures ...`. Textures come from `start.bsp`'s miptex lump. Code must stay deterministic: only the builder's own `TRng`, no `Random`.

Map export: `--export-map e1m1 C:\TMP\e1m1.x3d` writes the level as X3D (or glTF by the extension) with the textures as PNG files next to it, to inspect in the CGE editor or view3dscene.

Demo playback: `--autotest demo1.dem C:\TMP\d --demo "W:5,S,Q"` plays a PAK demo (or a file / `castle-config:` URL) with only `W`, `S` and `Q` actions; `-playdemo <name>` plays one from the menu view.

Multiplayer: `-host <map> [-port N] [-coop] [-skill N]` hosts a deathmatch (or coop) game (UDP, default port 26000) and plays in it, `-connect host[:port]` joins one. Headless: `--autotest host:start C:\TMP\h --demo "W:5,S,Q"` and, in a second process, `--autotest connect:127.0.0.1 C:\TMP\c --demo "W:3,S,X,W:1,S,Q"` (actions W, S, X, F, C, A, T, P, V, J, Q; screenshots log signon, health, frags and the client-side prediction error). `K` and `Y` are no cheats in deathmatch. The host logs `Client frames: ... entities per frame: N sent, M outside the PVS, D dropped, B bytes on average` every 10 s (it sends only the entities in each client's PVS, as differences from their baselines). `-nopredict` turns the prediction of the local player off. Bots (`QuakeBots`): `-bots N` with `-host` or `--autotest host:<map>` (Multiplayer > Deathmatch vs 3 bots, `-skill N` for their skill) adds server-side fake clients that navigate the map, take items and fight; the log says `Navigation of "<map>": N spots, M links`, `Bot "<name>" joined as client E` and every 10 s `Bots: <name> N frags (health H, U units, goal G[, fighting])`. Browser players: `-host <map> -websocket 26001` also runs a WebSocket relay to the listen server (TCP), `-wsrelay host[:port] [-port N]` runs one alone (headless: `--autotest wsrelay:127.0.0.1:26000 C:\TMP\r --demo "W:30,S,Q"`, screenshots log the relayed message counts); the web build joins with `?connect=host[:port]` in the page URL (`wss://` needed from an https page, so put a TLS proxy in front of the relay). Behind NATs: `-rendezvous [-port N]` runs the rendezvous service (headless: `--autotest rendezvous C:\TMP\r --demo "W:30,Q"`), the host adds `-register name@rendezvous[:port]` and the client uses `-connect name@rendezvous[:port]`.
- `Q` quit application

Touch controls (`GameTouch`, design `data/ui/touch.castle-user-interface`): shown on touch devices and in the browser after the first touch, `-touch` / `-notouch` (`?touch=1` / `?touch=0`) force them; they feed GameInput's `TouchMove`, `TouchLookDelta` and `TouchButtons`, read through the gamepad helpers. In the browser a JS helper tracks touch pointers by `pointerId` (the engine's web backend has one pointer) and stops them from becoming mouse clicks while shown; the first touch asks for fullscreen and a landscape lock (`?fullscreen=0` does not).

UI scale (`GameScreen`): the designs are 1600 x 900; the explicit UI scale is the larger of the enclosing scale and 0.7 x the screen density (page `devicePixelRatio`, Android dpi / 160, desktop dpi / 96), keeping at least 800 x 480 design units, recomputed on every resize (log `UI scale ...`). `--geometry 1170x2532 -density 3 -touch` tries a portrait phone on a desktop.

## Android Build

`tools/android-fpc.sh <prefix> <ndk dir>` builds the FPC cross-compilers for arm and aarch64 Android from the installed FPC's version (needs `binutils-arm-linux-gnueabi` and `binutils-aarch64-linux-gnu`), then `source <prefix>/env.sh` and, with `ANDROID_HOME` set (SDK platform 36, build tools 36, NDK 27.3.13750724), `castle-engine package --target=android --mode=release` writes `castle-quake1-<version>-android-debug.apk` (debug-signed without `AndroidSigningProperties.txt`). The `build-android` job of the Build workflow does the same and the release attaches the APK. Code must compile for 32-bit ARM too (no `Int64` for loop counters).

## Web Build

The `Web` workflow builds it with FPC's main branch (wasm32-wasip1 cross compiler) and Pas2js. Locally, with that toolchain first in PATH and `PPC_CONFIG_PATH` set: `castle-engine compile --target=web --mode=release`, then serve `castle-engine-output/web/dist/` over HTTP. The trunk compiler can stop with "Compilation raised exception internally" on an incremental rebuild: delete `castle-engine-output/compilation/wasm32-wasip1` and build again. WebAssembly cannot catch exceptions, so code for the web must not raise (check before calling). The page URL takes `?warp=<map>`, `?autotest=<map>&demo=<actions>` (like the command line; screenshots only log) and `?game=quake` (the original content, like `-game quake`), and `castle-config:/` (user config, saves) is kept in the browser's `localStorage` (`QuakeWebStorage`, keys `castle-quake:<path>`). Smoke test (the `Web` workflow runs it on every push; its fourth visit plays `random42`, its fifth is a touch page where a drag on the move stick must walk): serve the dist directory, then `node tests/websmoke.js http://localhost:8765/index.html <out dir>` (Playwright with Chromium) and `python3 tests/websmoke_check.py <out dir>`.

## Gameplay Scenarios

`python3 tests/scenarios.py` (after a release build, Pillow and on Linux xvfb-run needed) plays twenty-two scripted games headless (E1M1 to E1M2, a save / load in a fight, a deathmatch host and client, QuakeC mode, E1M1 with small lightmap atlas pages, E1M1 converted to BSP2 and 2PSB, a mod directory with loose files, a pak and a .pk3, E1M1 with colored light and fog, the hub's liquid rippling and E1M1's health boxes, the id1 hub with id1's models, fog and sky in a recorded demo and a network game, E1M1 moved beyond 4096 units in a demo and a coop game, PVS counts at fixed spots on four maps against `tests/budgets.json`, the touch controls on E1M1, a random map from start to exit with QuakeC and a network client, captions and the high contrast HUD, horde mode waves on E1M1 and a random map, a speedrun against its ghost, a deathmatch host with three bots and a network client, the map browser installing and playing a release from a test catalog over HTTP, photo mode in a game and in a demo, Save and Load Game in the menu and a game started from a savegame), checks their logs and compares the stable screenshots with `tests/reference/*.png` (a scenario's `frame_checks` compare its own frames, like the rippling liquid); `--only <name>` runs one, `--update` rewrites the references (and `tests/budgets.json`) after an intended visual or culling change. The `budgets` scenario fails when the clusters, shapes or entities drawn at a spot grow past their margin or the camera lands in another leaf; its frame times are only logged (`budgets/budgets.json` and the workflow run's summary). Output and `*_compare.png` images go to `castle-engine-output/scenarios/`. The Build workflow runs it on Linux and the release depends on it. Save and load logs print the stats they write and restore, and play view screenshots log the map, eye, angles, weapon, ammo, health, kills and the intermission state, so scenarios assert on logs rather than on pixels where they can.

## Savegames

The play view's savegames are `castle-config:/save_<slot>.sav` with a 320 x 180 thumbnail `save_<slot>.png` (the viewport alone, not on the web). Main Menu > Load Game lists them the newest first (`QuakeSaveGame.ListSaveGames`) with the selected one's thumbnail, Save Game (only while playing, `TQuakeMenu.InGame`) offers slots 1..8; `-load <slot>` or `--autotest load:<slot>` start from one, console `saves` lists them (`Save <slot>: <map>, health ..., <date>, thumbnail yes|no`), and saving logs `Thumbnail of slot N saved: 320x180`. Space, a click or the gamepad's A held when the menu closes does not jump or fire until released.

## Photo Mode

`GamePhoto` (`TPhotoMode`, help line design `data/ui/photo.castle-user-interface`): P (binding `qbPhotoMode`, the gamepad's View button, console `photo [0|1]`) pauses the play view or a demo, hides the HUD and the weapon and flies the camera (movement bindings, jump up, walk down; no collisions); the wheel or `[` `]` change the field of view, Tab the effect, `+` `-` the photo size, Enter / F12 save `<prefix>_photo_N.png` rendered off-screen at 1..4 x the window (the autotest prefix, else `castle-quake`), Escape or P go back. Console / `CMD:`: `photo_fov <deg>`, `photo_effect <none|dof|gray|sepia|vignette|ao>`, `photo_scale <1..4>`, `photo_shot`; in photo mode `M:` moves only the camera. The log says `Photo mode on at ...`, `Photo: Level time T` (play view, on entering and leaving), `Photo saved to "...": WxH, fov F, <effect>, camera ...` and `Photo mode off`.

## Map Browser

Main Menu > Map Browser (`QuakeMapBrowser`) lists `data/quaddicted/maps.txt`, made by `python3 tools/quaddicted_catalog.py` from Quaddicted's `quaddicted-data` repository and the last Quake Injector database's ratings (only releases installing into `id1/maps/` without a mod). A download is checked by SHA-256, kept as `castle-config:/quaddicted_<id>.zip` and mounted with `Pak.AddPk3(Url, Mapping)` to play. Console: `maps [rating|newest|name|installed] [text]`, `maps_install <id>`, `maps_play <id> [map]`, `maps_remove <id>`; `-mapcatalog <file or URL>` uses another catalog. The log says `Map catalog "...": N maps`, `Downloading "<id>" from ...`, `Map "<id>" installed: ... SHA-256 ...` (or `does not match`), `Mounted "<id>"` and `Map "<id>" removed`. The web build only lists (no room for zips in localStorage).

## Community Maps

`python3 tests/community_maps.py` (after a release build) fetches three Quaddicted maps by SHA-256 into `castle-engine-output/community-cache` (`--cache`, `COMMUNITY_MAPS_CACHE`): `tofaz` (BSP2, .lit, fog), `digs08` (large BSP29, .lit), `grim` (BSP2). It plays each at the player start and three items (`NC` must change no pixel, `Z` counts within `tests/community_budgets.json`, frame times under 3 x budget + 50 ms) and spawns it with QuakeC; `--update` rewrites the budgets. The Build workflow's `community-maps` job runs it (not a release gate).

## Unit Tests

`tests/quaketests.lpr` (own manifest, no window) checks the BSP tracer, captions (table, directions, merging), random maps (same bytes per seed, open spaces, walking the player hull from start to exit), the player physics at frame rates from 30 to 3000 fps, the PVS rows and the server's fat PVS, the field of view and view bob, the QuakeC VM, every sample of the shareware pak loading, savegame round trips and the demo writer / reader (protocol 15, 666 and 999, fog and skybox) against the shareware pak: `cd tests; castle-engine compile; .\quaketests ..\data\paks` (exit code = failures). The Build workflow runs it on Linux.

## Conventions & Rules

- **Indentation & Formatting**: 2-space indent, `begin`/`end` on their own lines, PascalCase identifiers, no `with`.
- **Coordinate System**:
  - `CGE.X = Quake.X`
  - `CGE.Y = Quake.Z` (Height)
  - `CGE.Z = -Quake.Y` (Forward is -Z)
- **Units**:
  - `Quake*` for core asset parsing and simulation.
  - `Game*` for CGE views and lifecycle.
  - `TQuakeWorld` is declared in `code/quakeworld.pas` and implemented in `code/world/quakeworld_<subsystem>.inc` include files (game, map, player, weapons, monsters, movers, pickups, save, record, debug, horde, ghost); add a method's body to the file of its subsystem.
- **Input**: actions are `GameInput.Bindings[qb...]` (`TInputShortcut`, rebindable in Options > Controls, saved in the user config); views use `BindingHeld` / `BindingEvent` and the gamepad helpers, never raw keys for gameplay.
- **UI**: the menu, HUD and console layouts are editor designs in `data/ui/*.castle-user-interface` (open them in the CGE editor); the code finds components by name and only sets captions, colors and visibility.
- **Paths**: Keep project paths short to avoid Windows path length issues.
