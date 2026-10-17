# Plane World — C++ / Qt 6 port

Phase 0 of [docs/PORT_PLAN.md](../docs/PORT_PLAN.md). The Swift app stays the shipping version.

| Target | What |
|---|---|
| `pwcore` | C++20 static lib, no Qt: math, JSON, SIMD dispatch (NEON / AVX2 / AVX-512, bit-identical reductions), ported wing/prop/wake unit physics, parity loader, self-tests |
| `pwgpu` | GPU device: Metal (Objective-C++) / Direct3D 12 (WARP fallback); Slang shaders → MSL / DXIL embedded at build time |
| `pwapp` | Qt 6 Quick app, native Qt Quick Controls style, BUILD/FLY/WORLD/EVOLVE, ⌘K/Ctrl+K command palette, GPU viewport sharing Qt's device |
| `pwtests` | doctest: core, parity (`tests/parity`), GPU readback |
| `pwcli` | `--selftest`, `--gpu-smoke [--warp]`, `--bench`, `--info` (`--train` arrives in phase 2) |

## Build (macOS)

    brew install cmake ninja qt
    # Slang: official release from github.com/shader-slang/slang, unpacked to ~/.local/slang-<ver> or SLANG_DIR
    cmake -S cpp -B cpp/build -G Ninja -DCMAKE_PREFIX_PATH=$(brew --prefix qt)
    cmake --build cpp/build
    cpp/build/tests/pwtests && cpp/build/src/cli/pwcli --selftest all
    open "cpp/build/src/app/Plane World.app"

Windows is built in CI (`.github/workflows/cpp.yml`): MSVC + Ninja, Qt via install-qt-action, Slang → HLSL → DXIL with
the Windows SDK `dxc`, tests and a WARP Direct3D 12 smoke test.

## Parity data

`tests/parity` is produced by the Swift app: `swift build -c release && .build/release/PlaneWorld --export-parity cpp/tests/parity`
(from the repo root). 5 crafts × 3 fast aero profiles × 2 scenarios (ground / air), 3 s at 1 kHz, sampled every
10 ms, plus `units.json` (wing, propeller, misc, rotor-wake samples). Doubles are shortest round-trip decimals.
Compiled with `-ffp-contract=off` / `/fp:precise`, the C++ unit physics currently reproduces all 19,441 unit values
bit-for-bit on Apple clang.
