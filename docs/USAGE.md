# Castle Quake: Usage

How to run, control and build the game. The full feature list is in [FEATURES.md](FEATURES.md).

## Running

```
castle-quake1 -warp e1m1                      Jump to E1M1
castle-quake1 -warp start                     The LibreQuake hub
castle-quake1 -game quake -warp start         The original Quake hub with the episode portals
castle-quake1 -randommap 42                   A random level from seed 42 (no seed: a new one)
castle-quake1 -horde -warp e1m1               Horde mode: waves of monsters on E1M1
castle-quake1 -pak custom.pak                 Load another PAK (mods, the registered id1 paks)
castle-quake1 -playdemo demo1.dem             Play a demo from the PAKs
castle-quake1 -qc e1m1                        QuakeC mode: progs.dat runs the game
castle-quake1 -game hipnotic -qc start        A mission pack or mod (a directory of loose files, pak*.pak and *.pk3) with its QuakeC
castle-quake1 -host start                     Host a deathmatch game on UDP port 26000 and play in it
castle-quake1 -host e1m1 -coop -skill 2       Host a cooperative game
castle-quake1 -connect 192.168.1.10           Join a game (host[:port])
castle-quake1 -host start -websocket 26001    Host and accept players from the web build (.../play/?connect=yourhost)
castle-quake1 -wsrelay 192.168.1.10:26000     Only a WebSocket relay for a game hosted elsewhere
castle-quake1 --export-map e1m1 e1m1.x3d           Export a level as X3D (or .gltf) for the editor / view3dscene
castle-quake1 --autotest e1m1 shot --demo "W:1,S,X,W:0.5,S,Q"   Headless test with screenshots
```
The Options menu switches the world lighting between Quake's lightmaps and dynamic PBR lighting.

More options, by topic (details in [REFERENCE.md](REFERENCE.md)):

| Topic | Options |
| --- | --- |
| Single player | `-warp <map>`, `-skill N`, `-load <slot>`, `-randommap [seed]`, `-horde`, `-speedrun`, `-ghost` |
| Content | `-game <dir>` (mission pack or mod), `-pak <file>`, `-qc <map>` (QuakeC mode), `-mapcatalog <file or URL>` |
| Multiplayer | `-host <map>`, `-connect host[:port]`, `-port N`, `-coop`, `-bots N`, `-teamplay 1`, `-fraglimit N`, `-timelimit M`, `-maps a,b,c`, `-splitscreen`, `-splitplayers 3`, `-spectate`, `-name <name>`, `-color <shirt> <pants>`, `-record <name>` |
| Browser players and NAT | `-websocket <port>`, `-wsrelay host[:port]`, `-rendezvous`, `-register name@host`, `-netloopback` |
| Display and input | `-lang <code>`, `-touch` / `-notouch`, `-density N`, `--geometry WxH` |
| Tools | `-playdemo <name>`, `--export-map <map> <file>`, `--autotest ...`, `--qctest <map>`, `-spawnspot N` (fixed spawn spots for tests) |

## Console

`~` opens the developer console; `help` lists the commands. The ones used most:

| Command | What it does |
| --- | --- |
| `map <name>`, `maps`, `maps_play <id>` | Change the level; list and play Map Browser releases |
| `god`, `give all`, `killall` | Cheats (not in deathmatch) |
| `save <slot>`, `load <slot>`, `saves` | Savegames |
| `fov`, `gamma`, `fog`, `sky`, `shadows`, `gl_texturemode`, `gl_texture_anisotropy`, `vid_fsaa` | Video |
| `captions`, `hud_contrast`, `reduced_flashes`, `lang` | Accessibility and language |
| `horde`, `speedrun`, `ghost`, `records`, `photo` | Game modes and tools |
| `name`, `color`, `lan`, `lan_join <n>` | Multiplayer |
| `r_lerpmodels`, `r_lerpmove`, `r_effectinfo`, `pr_checkextension` | QuakeC mode and mods |

As the host of a network game, a chat line starting with a slash runs a host command: `/status`, `/kick <name>`, `/map <name>`, `/fraglimit N`, `/timelimit M`, `/teamplay N`, `/addbot`.

## Controls

| Key | Action |
| --- | --- |
| **W, A, S, D** / Arrows | Move forward, strafe left / right, backward |
| **Mouse** | Look around |
| **Left Mouse / Ctrl** | Fire |
| **Space** | Jump / swim up |
| **Shift** | Walk (running is the default) |
| **E** | Use: doors, buttons |
| **1 .. 8** | Weapons: Axe, Shotgun, Super Shotgun, Nailgun, Super Nailgun, Grenade Launcher, Rocket Launcher, Lightning Gun |
| **F1 / C** | Camera: first person, third person, free fly |
| **F2** | Dynamic shadows on / off |
| **F6 / F9** | Quicksave / quickload |
| **F8** | Engine inspector (component tree, live properties) |
| **F12** | Screenshot |
| **P** | Photo mode (wheel: field of view, Tab: effect, + -: size, Enter: photo) |
| **~** | Developer console |
| **Touch** | Move stick on the left (where the finger lands), drag on the right to look, FIRE / JUMP / USE / weapon / MENU buttons; on by themselves on touch screens and in the browser after the first touch (`-touch`, `?touch=1`), which also goes fullscreen in landscape; the HUD and menus scale with the phone's pixel density |
| **Gamepad** | Left stick moves, right stick turns, A jumps, X uses, RB / right trigger fires, D-pad changes weapons, Start opens the menu, View is photo mode; the prompts use your pad's names (Xbox, PlayStation or Nintendo, from its name or Options > Controls) and a Nintendo pad confirms with A; sensitivity, dead zone, inverted look, button names and the confirm button in Options > Controls |
| **Escape** | Menu |

Every key can be rebound in Options > Controls (saved in the user config).

## Building

Prerequisites: [Castle Game Engine](https://castle-engine.io/) 7.0-alpha.3 or later (the snapshot bundles FPC 3.2.2).

### Windows (PowerShell)
```powershell
$env:PATH = "C:\castle-engine\bin;C:\castle-engine\tools\contrib\fpc\bin;" + $env:PATH
castle-engine compile --mode=release
.\castle-quake1.exe
```
Audio needs `OpenAL32.dll` and `wrap_oal.dll` next to the executable (included in the releases).

### Linux
```sh
export CASTLE_ENGINE_PATH=/path/to/castle-engine
$CASTLE_ENGINE_PATH/tools/build-tool/castle-engine compile --mode=release
./castle-quake1
```

### macOS
The releases include app bundles for Intel and Apple Silicon Macs. They are not signed or notarized: on the first start use right-click > Open, or `xattr -dr com.apple.quarantine "Castle Quake.app"`. Building locally is the same `castle-engine compile` with the engine set up for macOS.

### Web
With FPC's main branch (wasm32-wasip1 cross compiler) and Pas2js first in `PATH`: `castle-engine compile --target=web --mode=release`, then serve `castle-engine-output/web/dist/` over HTTP. The page takes the command line as URL parameters: `?warp=e1m1`, `?host=e1m1&bots=3`, `?randommap=new`, `?lang=de`...

### Android
`tools/android-fpc.sh` builds the cross-compilers; `castle-engine package --target=android --mode=release` writes the APK. See [REFERENCE.md](REFERENCE.md#android-build).

### Headless testing
`--autotest <map|qc:map|host:map|connect:host|name.dem> <prefix> --demo "<actions>"` loads a level without any input, runs the comma separated actions and exits. Actions: `W:sec` wait, `S` screenshot, `X` fire, `F:sec` hold fire, `U` use, `C:slot` weapon, `A:deg` / `T:deg` / `P:deg` yaw, turn, pitch, `M:units` / `G:x;y;z` teleport, `V:f;s;u` move, `J` jump, `K` / `Y` cheats, `O:slot` / `L:slot` save and load, `R:name` / `R` record a demo, `B:1` / `B:0` world lighting, `I` log the scene tree, `Q` quit. All the actions are in [REFERENCE.md](REFERENCE.md#headless-testing).

## Continuous integration

- `.github/workflows/build.yml`: Windows x86_64, Linux x86_64, macOS x86_64 / aarch64 (app bundle zips) and Android (APK, cross-compilers from `tools/android-fpc.sh`) packages on GitHub's runners (FPC and the CGE snapshot set up by `castle-build-ci`). A tag `v*`, or a manual run with a `release_tag`, creates the GitHub Release with the packages.
- `.github/workflows/web.yml`: the WebAssembly build and the GitHub Pages deployment.

The `test` job builds `tests/quaketests` (the BSP tracer, the QuakeC VM, savegames, the demo writer and reader against the shareware pak) and runs it before the packages are released; locally: `cd tests && castle-engine compile && ./quaketests ../data/paks`.

The `Web` workflow builds the WebAssembly version with FPC's wasm32 cross compiler and Pas2js, smoke-tests it in headless Chromium (`tests/websmoke.js`: E1M1 starts, renders, saves, and the save loads after a reload) and deploys it from main to GitHub Pages: [mariuz.github.io/castle-quake1](https://mariuz.github.io/castle-quake1/). In the browser, savegames, controls and video options are kept in the browser's local storage between visits; `?warp=e1m1` in the page URL starts a map, `?randommap=new` a random one.
