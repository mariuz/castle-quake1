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
- **Paths**: Keep project paths short to avoid Windows path length issues.
