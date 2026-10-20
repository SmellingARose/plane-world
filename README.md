<div align="center">

<h1>Plane World</h1>

<p><b>Build aircraft from parts. Fly them over any terrain. Evolve their autopilots.</b></p>

<a href="https://github.com/SmellingARose/plane-world/releases/latest/download/PlaneWorld-macOS.dmg"><img src="docs/download/macos.svg" alt="Download for macOS" height="56"></a>&nbsp;&nbsp;<a href="https://github.com/SmellingARose/plane-world/releases/latest/download/PlaneWorld-Windows.msi"><img src="docs/download/windows.svg" alt="Download for Windows" height="56"></a>

<sub>One download, nothing else to install · <a href="https://github.com/SmellingARose/plane-world/releases">All releases</a></sub>

<br>

<img src="docs/screens/fly.jpg" alt="Flying a craft in Plane World" width="100%">

</div>

<details>
<summary><b>First launch shows a warning?</b> That is expected, here is the one-time fix.</summary>
<br>

The app is not signed by a paid developer account, so the first time:

- **Mac:** open the .dmg, drag **Plane World** to Applications and open it. When macOS says it cannot check the app,
  open **System Settings → Privacy & Security**, scroll down, press **Open Anyway** and confirm. After that it opens
  normally. Intel Macs are not supported.
- **Windows:** run the .msi. If SmartScreen says "Windows protected your PC", press **More info**, then **Run anyway**.
  Plane World is then in the Start menu.

</details>

## About

A flight and vehicle physics sandbox: build crafts from parts or CAD, fly them over procedural or real terrain, and
evolve controllers and designs. Aero forces come from fast analytic models: strip-theory wings, momentum props and
actuator-disk slipstream, running far above real time.

C++20 core, Qt 6 Quick UI, Metal and Direct3D 12 renderers with shaders written once in Slang.

| BUILD | FLY |
|---|---|
| ![BUILD](docs/screens/build.jpg) | ![FLY](docs/screens/fly.jpg) |
| **WORLD** | **EVOLVE** |
| ![WORLD](docs/screens/world.jpg) | ![EVOLVE](docs/screens/evolve.jpg) |

- **BUILD:** parts (wings, servos, props, motors, jets, solids, tanks, wheels, sensors, primitives), CAD import
  (STL / OBJ / glTF / GLB; USD / USDZ on macOS) with auto-rig, mesh cut, outputs with key bindings, undo / redo.
- **FLY:** 1 kHz physics, chase / orbit / cockpit cameras, per-output sliders, HUD, aero model picker and the
  EQUATIONS panel (every fast-model equation with live values).
- **WORLD:** flat, procedural (GPU erosion), heightmap or real-world terrain; sculpt and paint; ocean, lakes, rivers,
  vegetation, props and breakables; sky and wind. New → *Manhattan (Midtown)* builds a detailed, flyable Midtown.
- **EVOLVE:** GA, CMA-ES, sep-CMA-ES, OpenAI-ES, NEAT, MAP-Elites, novelty search or your own algorithm in JavaScript;
  neural controllers, craft designs or both; headless parallel training, charts, replays in the viewport.

## Using the app

The four tabs form one loop: **BUILD** a craft → shape the **WORLD** it flies in → **FLY** it there → **EVOLVE** a
controller or design, then fly the result.

- FLY always flies the craft open in BUILD, in the world open in WORLD: terrain, trees and props collide, and the
  world's wind blows. The chip at the top right of FLY names the world (click it to edit); the inspector's *World*
  card switches to flat ground for testing a design.
- WORLD edits are live, no export step. *Fly here* (`Ctrl+Shift+2`) starts a flight at the centre of the view,
  facing the way the camera looks; *Fly from spawn* uses the spawn point (spawn tool, key `O`). Save keeps a world for
  later sessions.
- EVOLVE is laid out as steps: **Set up** (① craft & world, ② what evolves, ③ goal picked in plain words —
  hold altitude, hover, fly to a target, max distance, drive to a point — or your own script, ④ algorithm) and
  **Train** (⑤ Start training with live generation / best score / time left, ⑥ fly the best with its evolved
  autopilot, replay it or save it as a craft). The default *Quick start* learns to hold altitude in about ten seconds.
- `Ctrl+1`…`4` switch tabs, `Ctrl+K` searches every action, and the welcome tour is in Settings (`Ctrl+,`).

## Platforms

| OS | GPU API | Tested on |
|---|---|---|
| macOS 14+ (Apple silicon) | Metal | Apple M4; CI on macOS 15 arm64 |
| Windows 10 / 11 x64 | Direct3D 12 (WARP software fallback) | CI on `windows-latest` (WARP) |

Any Direct3D 12 GPU (feature level 11_0+; NVIDIA, AMD, Intel) or Apple silicon GPU. Per-vendor tuning lives in `pwgpu`.

## Build and run

Only needed to work on the code: the download buttons at the top are the same app, ready to run.

Requirements: CMake 3.24+, Ninja, Qt 6.8, and the [Slang](https://github.com/shader-slang/slang/releases) release
unpacked to `~/.local/slang-<version>` or pointed at by `SLANG_DIR`.

**macOS** (Command Line Tools are enough):

```sh
brew install cmake ninja qt
cmake -S . -B build -G Ninja -DCMAKE_PREFIX_PATH=/opt/homebrew/opt/qt && cmake --build build
open "build/src/app/Plane World.app"
```

**Windows** (Visual Studio 2022 C++ workload, Qt 6.8 MSVC 2022 64-bit), from an "x64 Native Tools" prompt:

```bat
cmake -S . -B build -G Ninja -DCMAKE_PREFIX_PATH=C:/Qt/6.8.3/msvc2022_64 -DSLANG_DIR=C:/slang
cmake --build build
cmake --build build --target pwapp_deploy
build\deploy\"Plane World.exe"
```

Tests:

```sh
build/tests/pwtests                                       # unit, parity, GPU and renderer tests
QT_QPA_PLATFORM=offscreen build/src/app/pwuitests         # WORLD / EVOLVE view models
build/src/cli/pwcli --selftest all                        # self-test registry (--selftest list)
```

Installers: `packaging/macos/make_dmg.sh build` and `packaging/windows/make_msi.sh build`
([docs/PACKAGING.md](docs/PACKAGING.md)). CI (`.github/workflows/ci.yml`) builds, tests and packages both platforms
on every push to `main`; a `v*` tag publishes a GitHub release.

## Command line

```sh
pwcli --train examples/experiments/hover-pid.json --generations 10 --out /tmp/hover   # headless training, all cores
pwcli --train my.json --resume --out /tmp/hover            # continue from the checkpoint in --out
pwcli --make-experiment "Neural controller" my.json        # preset -> editable experiment
pwcli --bench all                                          # benchmarks (--bench list)
pwcli --info                                               # CPU features, GPU backend
```

`--train` also takes `--workers`, `--population`, `--seed`, `--aero <profile>`, `--script-engine`.
The app takes `--tab`, `--color-scheme`, `--size WxH`, `--command "<palette entry>"` (or `"wait <s>"`, run in order) and
`--screenshot out.png --quit-after <s>` (how the screenshots above were made).

## Docs

| File | Contents |
|---|---|
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Targets, threading, determinism, GPU backends and shaders, tests |
| [PHYSICS.md](docs/PHYSICS.md) | Every fast-model equation with code location, validity and sources ([interactive explainer](docs/explainer.html)) |
| [EVOLUTION.md](docs/EVOLUTION.md) | EVOLVE, experiment format, JavaScript API, algorithms, reward shaping |
| [SCRIPTING.md](docs/SCRIPTING.md) | JavaScript engines (JavaScriptCore, QuickJS) and their differences |
| [CRAFTS.md](docs/CRAFTS.md) | Bundled crafts and the ducted-rocket design |
| [WORLDS.md](docs/WORLDS.md) | World presets (incl. Manhattan), prop params (shape / colour / facade pattern / collide) |
| [CONTROLS.md](docs/CONTROLS.md) | Keys → axes → controller → outputs: mix tables, the multirotor flight controller, adding a controller |
| [PERF.md](docs/PERF.md) | Benchmarks and methodology |
| [PACKAGING.md](docs/PACKAGING.md) | .dmg / .msi, signing, CI release |
