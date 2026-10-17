# Script runtime

The JS API is in [EVOLUTION.md §3](EVOLUTION.md#3-javascript-api). Code: `src/core/pw/script/runtime.h` (contract),
`src/core/src/script/` (engine-neutral runtime, prelude, JavaScriptCore and QuickJS engines, presets, self-tests).

## Engines

| Platform | Default | Also available |
|---|---|---|
| macOS | JavaScriptCore (system framework, C API) | QuickJS |
| Windows | QuickJS (quickjs-ng v0.17.0, built from the official GitHub release source) | none |

`PW_SCRIPT_ENGINE=jsc|quickjs` or `pwcli --train ... --script-engine jsc|quickjs` picks one.

**Why QuickJS on Windows:** JavaScriptCore has no supported Windows SDK. Building it from WebKit means a
multi-hour WebKit build with ICU, a ~30 MB DLL and no stable C API guarantees, for one platform. QuickJS sits
behind the same interface, uses the same prelude JS, and passes the same self-tests.

## One prelude, thin engines

`prelude.js` (helpers `clamp lerp sign deg rad pid vec nn log`, and the hook plumbing) is identical on both
engines. An engine only evaluates code, calls global functions with numbers, strings and Float64Arrays (over
native memory, no copies), and exposes three natives (`nnCreate`, `nnForward`, `log`). Layouts, crafts and
populations cross as JSON text, with NaN and Infinity kept as strings.

## Behaviour differences

| | JavaScriptCore | QuickJS |
|---|---|---|
| Execution | JIT | bytecode interpreter |
| Watchdog | `JSContextGroupSetExecutionTimeLimit` (SPI, via dlsym) | interrupt handler with a steady-clock deadline |
| Error text | `Can't find variable: x` | `x is not defined` |
| Error column | JSC's column | QuickJS's column (positions can differ by a few characters; lines match) |
| Engine heap | not observable | counted (`engineAllocations()`); a control tick allocates 0 bytes |
| `Math.sin/cos/exp/log/pow` | system libm | QuickJS's own implementations; last-bit differences are possible |

What is the same, and tested (`pwcli --selftest evolution-js.`):
- `+ - * / Math.min/max/abs/sqrt` are IEEE exact on both, so the presets score bit-identically on both
  engines (`evolution-js.engines-agree`).
- `Math.random`/`ctx.rng` use the same sfc32 generator in the prelude: the same sequence on both.
- `nn.mlp`/`nn.create` run natively with the MLPPolicy arithmetic order: bit-identical.
- Error lines are relative to the user source; hooks are attributed the same way; budgets are the same
  (`callBudgetMs` per tick, 20x for init/fitness/descriptor/decode, 2 s for genome/terms/algorithm hooks/top level).

Within one build, results are deterministic for any number of workers. Across engines (or across macOS and
Windows), a script that uses transcendental functions in its reward can drift in the last bits.

## Measured (Apple M4, release build, `pwcli --selftest evolution-js.throughput --verbose`, 2026-10-17)

| per control tick | JavaScriptCore | QuickJS |
|---|---|---|
| trivial `control()` | 0.26 µs | 0.12 µs |
| neural preset (control + reward + terminate) | 0.76 µs | 0.79 µs |
| JS `control()` with native `nn.mlp` 9-12-4 | 0.82 µs | 0.56 µs |
| design preset PID autopilot | 1.10 µs | 0.97 µs |

The tick path is one call into JS with no arguments (`__tick`); C++ makes no allocation (pwtests checks this
for both engines, and that QuickJS's own heap gets none either).

## CLI

`pwcli --make-experiment "<preset>" out.json [--craft name]` writes a preset (`src/cli/train_cli.cpp:98`); the
preset documents are in `data/experiments/`. `pwcli --train` accepts `--generations --population --workers --seed
--out --resume --current-as-flat --aero --cfd-preset --script-engine` (`src/cli/train_cli.cpp:114-179`) and hands
the request to the evolution core (`src/core/src/evo/train.cpp`).
