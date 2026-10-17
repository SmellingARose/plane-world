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

## Physics core (phase 1a)

| Header | What |
|---|---|
| `pw/math.h` | `Vec3d` / `Quatd` / `Mat3d` that reproduce Apple `<simd/simd.h>` (as Swift calls it on arm64) bit for bit: the FMAs Apple's headers contract are explicit `std::fma` (correctly rounded on every platform), `simd_inverse` follows libsystem_m's `__invert_d3`, Swift `min`/`max`/`clamp` and prefix-minus semantics. Checked against `tests/parity/simd.json` (`tools/simd_reference.swift`). |
| `pw/render_math.h` | float render math: `Float4x4`, look-at, reverse-Z perspective, camera-relative model matrices |
| `pw/jobs.h` | work-stealing job system, zero-allocation `parallelFor` / reusable `ParallelLoop`, topology aware (Apple P/E clusters, Ryzen CCDs and Intel P/E on Windows with per-cluster pinning, Linux L3 groups) |
| `pw/simd_kernels.h` | runtime-dispatched kernels (scalar / NEON / AVX2 / AVX-512), each ISA in its own TU, bit-identical across ISAs (CAD panel aero today) |
| `pw/atmosphere.h` | ISA atmosphere, log-profile wind + frozen turbulence |
| `pw/sim/*` | `CraftSpec` (craft JSON / `craft::CraftDocument`), `CraftSim` (servos, wing strips with stall / flaps / ground effect, body drag, CAD panels with occlusion, props / ducts / rotor ground effect / slipstream with swirl, jets, solids, fuel and CoM, ground contact, tyres, buoyancy hook, sensors), Fast+ effects (gyro, P-factor, downwash, blockage, CAD wash), equation capture, aero profiles |

Verification: on macOS arm64 all 30 reference trajectories and the Swift self-test trajectory digests
(`pwcli --selftest physics.trajectory-digest`) are reproduced bit for bit; the step allocates nothing (tested for
every craft and profile); serial / parallel / every SIMD level give identical bits. On Windows the platform libm
differs from Apple's in the last ulp, so runs are compared with tolerances (1e-9 for the first second, 1e-6 over 3 s);
the ducted rocket with the slipstream model is excluded there because the wake cut-offs make it discontinuous.
