# AGENTS.md

Working notes for contributors and AI agents on Castle Quake: a Quake 1 port to Castle Game Engine (CGE) in Object Pascal (FPC). Keep this file short; details go in `docs/`.

## Where things are

| Path | What |
| --- | --- |
| `code/quake*.pas` | Asset parsing and simulation: `QuakePak`, `QuakeBsp`, `QuakeGeometry`, `QuakeMdl`, `QuakeProgs` (QuakeC VM), `QuakeQcGame`, `QuakeNet`, `QuakeServer`... |
| `code/game*.pas` | CGE views and lifecycle: `GameViewPlay` (native gameplay), `GameViewQc` (QuakeC mode), `GameViewDemo` (demos, network client), `GameViewMenu` |
| `code/world/quakeworld_<subsystem>.inc` | `TQuakeWorld`'s methods (declared in `code/quakeworld.pas`); add a method's body to the file of its subsystem |
| `data/paks/` | Bundled LibreQuake paks; `data/ui/` editor designs; `data/lang/` translations |
| `tests/` | `quaketests.lpr` (unit tests), `scenarios.py` (scripted games), `community_maps.py`, `websmoke.js` |
| `docs/` | `ARCHITECTURE.md` (code structure), `REFERENCE.md` (test harness, log lines, builds), `ROADMAP.md`, `HISTORY.md`, `FEATURES.md`, `USAGE.md` |

Read `docs/ARCHITECTURE.md` before a larger change, and the section of `docs/REFERENCE.md` for the feature you touch: it lists the script actions and the log lines the tests assert on.

## Build and test

```sh
castle-engine compile --mode=release                  # the game (CGE 7.0-alpha.3 snapshot, FPC 3.2.2)
cd tests && castle-engine compile && ./quaketests ../data/paks   # unit tests, exit code = failures
python3 tests/scenarios.py [--only <name>]            # 38 scripted games (needs xvfb-run and Pillow on Linux)
python3 tools/lang_strings.py --check                 # translations complete and the template current
python3 tests/community_maps.py                       # Quaddicted maps and Arcane Dimensions (downloads them)
```

Headless run with screenshots and a log to assert on:

```sh
./castle-quake1 --autotest e1m1 /tmp/shot --demo "W:1,S,X,W:0.5,S,Q"
./castle-quake1 --autotest qc:e1m1 /tmp/qc --demo "W:1,E,S,Q"         # QuakeC mode
```

The web build needs FPC's main branch (wasm32-wasip1) and Pas2js; the `Web` workflow builds and smoke-tests it on every push, so rely on it when the toolchain is not installed. Do not rebuild the game while scenarios are using the executable.

## Rules

- **Style**: 2-space indent, `begin` / `end` on their own lines, PascalCase, no `with`.
- **Coordinates**: `CGE.X = Quake.X`, `CGE.Y = Quake.Z` (height), `CGE.Z = -Quake.Y`.
- **Units**: `Quake*` for parsing and simulation, `Game*` for views.
- **Input**: `GameInput.Bindings[qb...]` through `BindingHeld` / `BindingEvent` and the gamepad helpers (with their `Player` argument); never raw keys or `Controllers[0]` for gameplay. Prompts use `GamepadButtonLabel`, not fixed letters.
- **UI**: layouts are editor designs in `data/ui/*.castle-user-interface`; code finds components by name and sets captions, colors and visibility only.
- **Texts**: every shown text goes through `Tr` (or `TrItem` / `TranslateDesign`); add its translation to all five `data/lang/*.po` and run `tools/lang_strings.py`.
- **Web**: WebAssembly cannot catch exceptions, so code that runs there must not raise (check before calling).
- **Android**: must compile for 32-bit ARM (no `Int64` loop counters).
- **Random maps**: deterministic, only the builder's own `TRng`.
- **Tests assert on logs** rather than pixels where they can: log what a feature did (`WritelnLog`) and check that line.
- **Paths**: keep them short (Windows path length).

Pascal pitfalls met here: fields must come before methods in a class section; a parameter named `Name` clashes with an inherited member; a `{` inside a `{ }` comment ends compilation oddly; `for X in [Format(...), '...']` is not allowed; `IfThen` is ambiguous between `Math` and `StrUtils`; `TVector3` components are set through `.Data[I]`.

## Finishing a change

1. Build, then run the unit tests and the scenarios the change touches (all of them before a release).
2. Update the docs: tick the item in `docs/ROADMAP.md`, add how it was done to `docs/HISTORY.md`, and the new actions, options and log lines to `docs/REFERENCE.md` (`ARCHITECTURE.md`, `FEATURES.md` and `USAGE.md` when they change).
3. Bump the version in `CastleEngineManifest.xml` (`value` and `code`).
4. Commit and push to the working branch.

## Releasing

Tag pushes are not used. Merge the branch into `main` with a pull request once its Build and Web workflows are green, then run the `Build` workflow on `main` with the input `release_tag` = `vX.Y.Z`: it tests, packages Windows, Linux, macOS (x86_64, aarch64) and Android, and publishes the release with five files. Dispatch only after the merge succeeded. If a scenario fails in the release run, fix it on the branch, merge and dispatch again.

## Related work: Castle Game Engine Vulkan renderer

When working on the Castle Game Engine Vulkan RHI renderer from this workspace:

- **Primary Engine Repository**: [`e:\Work\castle-engine`](file:///e:/Work/castle-engine) (WSL: `/mnt/e/Work/castle-engine`, branch: `vulkan-renderer`)
- **Full Agent Engineering & Handover Guide**: See [`e:\Work\castle-engine\AGENTS.md`](file:///e:/Work/castle-engine/AGENTS.md)
- **Master Vulkan Roadmap & Status**: See [`e:\Work\castle-engine\PLAN.md`](file:///e:/Work/castle-engine/PLAN.md)

### Quick summary for the next agent
1. **Git Remote Policy**: In `e:\Work\castle-engine`, always push **only** to `origin vulkan-renderer` (`https://github.com/mariuz/castle-engine.git`), never `upstream`.
2. **Current Progress**: Phases 1–5 are complete; Phase 6 items **6.1** (`TVulkanDescriptorPoolAllocator`) and **6.2** (`TCastleVulkanStagingUploader`) are complete and verified with **43/43** passing unit tests in `TTestCastleVulkanRHI`.
3. **Next Task**: **6.3. Bindless Texture & Sampler Indexing (`VK_EXT_descriptor_indexing` / Vulkan 1.2 Core)** in [`e:\Work\castle-engine\PLAN.md`](file:///e:/Work/castle-engine/PLAN.md#L202-L204).
