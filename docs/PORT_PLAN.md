# Plane World: cross-platform port plan (macOS + Windows, any GPU)

Decision (Oct 2026): **option B, a shared C++ core with a single Qt 6 interface**, chosen for top speed and
simple platform support. Every GPU works through each OS's standard API, so CUDA is not required:

| Layer | macOS | Windows |
|---|---|---|
| Interface | Qt 6 Quick (QML) + Qt Quick Controls native style | same code |
| Core: physics, aero, CFD logic, evolution, crafts, worlds | C++20, shared | same code |
| GPU API | Metal | Direct3D 12 (NVIDIA, AMD Radeon, Ryzen integrated graphics, Intel) |
| Shaders | Slang → MSL | Slang → DXIL |
| Scripts | JavaScriptCore (QuickJS fallback) | same |
| CPU SIMD | NEON | AVX2, with an AVX-512 path, selected at runtime |
| Build | CMake + Ninja, Qt via `qt-cmake` | same |

Size of what moves: about 33k lines of Swift today. Evolution 6.4k, App/UI 5.2k, Physics 4.5k, Water 2.9k,
Craft 2.8k, Terrain 2.6k, Vegetation 2.1k, Render 2.0k, Collision 1.8k, Core 1.6k, Flow (CFD) 1.5k.

## Interface and UX: how "one UI that still feels native, and great" works

- **Qt Quick (QML), not Qt Widgets.** QML gives fluid, animated, modern interfaces (inspector panels,
  live charts, smooth transitions) while Qt Quick Controls 6 ships **macOS and Windows native styles**: system
  fonts, accent colour, dark mode, native menus, file dialogs and window chrome on each OS.
- **A real design system:** spacing, type scale, colours and component library in one `Theme.qml`, so every
  panel is consistent. Existing SwiftUI screens are the reference; each gets an explicit UX pass, not a
  transliteration.
- **UX targets:** every action reachable by keyboard (shortcuts shown in tooltips and menus), undo/redo in
  BUILD and WORLD, inspector-style editing with live preview, drag-and-drop import, command palette (⌘K /
  Ctrl+K), first-run tour, no blocking dialogs during simulation, 120 Hz-smooth panels.
- **3D viewport** is our own Metal or Direct3D 12 renderer embedded in the QML scene (`QQuickRhiItem`, or a
  native child surface), so the interface never costs frame time and the renderer keeps full GPU control.
- **Review gate:** each tab ships only after a side-by-side screenshot review on both OSes against a written UX
  checklist.

## Phases

| # | Phase | Output | Done when |
|---|---|---|---|
| 0 | Foundations | CMake repo layout, CI on GitHub Actions (macOS arm64 + Windows x64), Slang toolchain, Qt 6 skeleton window on both | Empty app opens on both OSes in CI artefacts |
| 1 | Core math + physics in C++ | Craft model and JSON, rigid body, wings, props, slipstream, Fast+ effects, sensors, ground contact, the zero-allocation step | Parity tests pass (below) |
| 2 | Evolution + headless training | Evaluator, GA/NEAT/CMA-ES/MAP-Elites/novelty, JS runtime, `--train`, checkpoints | Same seeds → same fitness histories as Swift within tolerance; throughput ≥ the Swift version |
| 3 | GPU backend + renderer | Thin Metal/D3D12 abstraction, Slang shaders, PBR, sky, shadows, terrain, water, vegetation, TAA | Visual parity screenshots; ≥ 60 fps at native resolution on reference GPUs |
| 4 | CFD | LBM solver ported to Slang compute; diagnostics; flow overlay | Validation numbers match the Swift solver within tolerance |
| 5 | Qt interface | BUILD, FLY, WORLD, EVOLVE, equations, keybinds, aero model list, CFD panels | UX checklist passed on both OSes |
| 6 | Polish + release | Installers (.dmg signed/notarized, .msi or MSIX), auto-update, crash reporting | Clean install on a fresh Mac and Windows PC |

The Swift app stays the shipping version until phase 5 passes, then it is archived.

## Making sure both platforms compute the same thing

- **Parity harness:** the Swift build exports reference trajectories (every craft, every preset, each aero
  profile, 3 s at 1 kHz) to JSON. The C++ core must reproduce them within 1e-9 relative, and exactly for the
  same compiler and flags.
- **Determinism rules:** `-ffp-contract=off` (no hidden fused multiply-adds) on every compiler; fixed reduction
  order; no `fast-math`; the same seeded RNG. Within one build, results stay identical whether training runs on
  1 core or many.
- **GPU (CFD, rendering)** is validated by tolerance and screenshots, not bit equality. Vendors differ.

## Performance plan

- **CPU:** data laid out in flat arrays (struct-of-arrays) with vector instructions per platform (NEON, AVX2,
  AVX-512 chosen at runtime), a work-stealing job system with P-/E-core and CCD awareness on Ryzen, and zero
  allocations per step (kept as a test).
- **GPU:** Direct3D 12 and Metal with GPU-driven culling, async compute for CFD overlapping rendering, and fp16
  where safe. A per-vendor tuning table sets threadgroup size and wave/SIMD width; one shader source covers all.
- **Benchmarks** run in CI on every commit (`--bench`); regressions over 5 % fail the build.

## Risks

| Risk | Mitigation |
|---|---|
| Full rewrite of about 33k lines | Phase order keeps a testable product at each step; parity tests catch physics drift |
| JavaScriptCore build on Windows | QuickJS fallback behind the same script interface |
| Testing on real Windows GPUs | CI covers build, headless tests and software-rendered (WARP) Direct3D 12; final UX and performance checks need a real Windows PC with an NVIDIA or AMD card |
| Qt licensing | LGPL v3, dynamic linking (fine for this open-source repo) |
