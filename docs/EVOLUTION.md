# Plane World: Evolution (EVOLVE tab)

Evolve controllers, craft designs, or both, with headless parallel simulation. The same core runs in the app's
EVOLVE tab and in `pwcli --train`. If this document and the code disagree, the code wins.

Limits: one craft per episode (`crafts.count > 1` is rejected). Trees and props are optional *static* obstacles:
touching one latches `crashed`; they never move or break, and raycast sensors ignore them.

## 1. Code map

| Area | Files |
|---|---|
| Genome, RNG, fitness (`GeneSpec`, `GenomeLayout`, `Genome`, `kFailedFitness`) | `src/core/pw/evo/types.h:75`, `:105`, `:139`, `:151` |
| Experiment document (`ExperimentDocument`, `AeroRunSettings`) | `src/core/pw/evo/experiment.h:89`, `:82`; parsing in `src/core/src/evo/experiment.cpp` |
| Algorithm interface (`Algorithm`, `AlgorithmHooks`) | `src/core/pw/evo/algorithm.h:28`, `:20` |
| Algorithms and registry | `src/core/src/evo/algos_basic.cpp` (registry at `:431`; `random`, `simple-es`, `ga`), `algos_cma.cpp` (`cmaes`, `sep-cmaes`, `openai-es`), `algos_qd.cpp` (`neat`, `map-elites`, `novelty`) |
| Native policies (`MLPPolicy`, design decoder) | `src/core/pw/evo/policy.h:33`, `src/core/src/evo/policy.cpp` |
| Evaluator (`EvalWorker`, `SimEvaluator`) | `src/core/pw/evo/evaluator.h:95`, `:132` |
| Run, checkpoints, export, replay, FLY autopilot (`EvolutionRun`, `exportCraft`, `EvolvedAutopilot`) | `src/core/pw/evo/run.h:57`, `:93`, `:139` |
| Headless training (`--train`, `history.csv`, `best-craft.json`) | `src/core/src/evo/train.cpp`, `src/cli/train_cli.cpp` |
| Headless world | `src/core/pw/world/bake.h:138` |
| Script runtime and prelude | `src/core/pw/script/runtime.h:132`, `src/core/src/script/prelude.js` (see [SCRIPTING.md](SCRIPTING.md)) |
| Presets | `src/core/src/script/presets.cpp`, documents in `data/experiments/` |
| Sensors | `src/core/src/sim/sensors.cpp`, `CraftSim::readSensors` at `src/core/pw/sim/craft_sim.h:203` |
| Self-tests | `src/core/src/evo/evolution_selftests.cpp` (`evolution.*`), `src/core/src/script/script_selftests.cpp` (`evolution-js.*`) |
| EVOLVE UI | `src/app/qml/EvolvePanel.qml`, `src/app/evolvemodel.cpp` |

Data flow per generation: `algorithm.ask()` gives genomes; the evaluator runs them in parallel (one `EvalWorker`
per job, each with its own `CraftSim`, script context and buffers: decode design genes, run script `decode()`,
then E episodes of observe, policy, script tick, set outputs, step); `algorithm.tell()` gets the fitnesses; the
run records history and hall of fame and checkpoints every k generations.

## 2. Genomes

The layout is built once per run:
1. The native part comes from `genome.preset`: `neural` (MLP weights, group `"mlp"`, when
   `controller.mode == "mlp"`), `design` (one gene per design gene, group `"design"`), `coevolve` (design genes,
   then MLP genes) or `script` (empty). With algorithm `neat` or `controller.mode == "neat"`, the NEAT layout comes
   from `genome.neat`, or every craft input and output when absent.
2. The script hook `genome(base)` may append genes or replace the layout (§3.3).

Rules:
- Legalising clamps to `[min, max]`, rounds `int` genes and thresholds `bool` genes at 0.5. Algorithms legalise
  every candidate they emit.
- The mutation scale per gene is `sigma`, or 10 % of the range.
- **MLP weights:** for each layer (in to out), W row-major `[out][in]`, then `b[out]`; names `mlp.L.w.o.i` and
  `mlp.L.b.o`. Inputs are divided by `inputScale[name]`. Output activations (tanh by default) map −1…1 onto each
  output's range: `lo + (y+1)/2·(hi−lo)`.
- **Design genes:** `field` is `mass`, `pos.N`, `rot.N`, `p.<param>` (any numeric part param) or `enabled`
  (removes the part and its links). `part` is an id, a name or `prefix*`. `mirror` lists parts that get the same
  value, with `pos.2` negated.
- **NEAT:** node ids `0..<nIn` are inputs, `nIn` is the bias, then the outputs, then hidden nodes. Innovation
  numbers are global per run. Outputs are written in craft output order and clamped to each output's range.

## 3. JavaScript API

There is one source string, `scripts.source`. Every function is optional.

### 3.1 Execution model

- Each worker has its own script context; the orchestrator has one more for `genome()`, `terms()` and the
  algorithm hooks. Engines: JavaScriptCore or QuickJS ([SCRIPTING.md](SCRIPTING.md)).
- Worker globals persist across candidates. **Do not keep cross-episode state in globals**; use `ctx.memory`,
  which is reset to `{}` before every episode.
- `Math.random()` is the episode-seeded `ctx.rng.random()` (the algorithm's RNG inside `select/crossover/mutate/ask`).
  `Date.now()` is sim time in ms.
- **Watchdog:** per-tick hooks get `scripts.callBudgetMs` (default 5 ms); `init`, `fitness`, `descriptor` and
  `decode` get 20×; `genome`, `terms` and algorithm hooks get 2 s. A timeout fails the candidate with fitness
  `kFailedFitness` (−1e12); the run continues.
- **Errors** are attributed to the hook that threw, with line and column relative to the user source. The UI marks
  the line in the editor.

### 3.2 Hooks and call order

```js
// once per run (orchestrator)
function genome(base) { return base; }               // §3.3
function terms() { return ["altitude", "speed"]; }   // reward term names; else experiment.rewardTerms

// once per candidate (worker), after native design genes were applied
function decode(g, craft) { return craft; }          // craft JSON in, modified copy out

// per episode
function init(ctx) {}
// per control tick (controller.hz, default 50 Hz), in this order:
function control(ctx) {}                             // read ctx.in / ctx.state, write ctx.out
function reward(ctx) { return { altitude: 0.1 }; }   // per-tick deltas, added to ctx.sum
function terminate(ctx) { return false; }            // true ends the episode
// end of episode
function fitness(ctx) { return ctx.sum.altitude; }   // number, or { fitness, terms: {...}, descriptor: [...] }
function descriptor(ctx) { return [ctx.state.x, ctx.state.z]; }   // MAP-Elites / novelty

// optional algorithm hooks (return undefined/null for the built-in operator)
function select(pop, count, rng) { return [0, 1]; }       // indices into pop
function crossover(a, b, layout, rng) { return values; }
function mutate(g, layout, rate, rng) { return values; }
// full custom algorithm (algorithm.kind == "script")
function ask(state, layout, rng) { return [values]; }
function tell(state, population) {}                       // [{ values, fitness, terms, descriptor }]
```

- `reward` may return term deltas, add to `ctx.reward.<term>`, or return a number (added to the first term).
  Unknown term names are an error.
- Without `fitness`, fitness is the sum of all term sums. `terms` returned from `fitness` *replace* the episode
  sums (terminal bonuses such as `crash: -20`). A `descriptor` there wins over the `descriptor()` hook.
- Built-in termination runs before `terminate()`: `crash` (when `episode.stopOnCrash` and a non-wheel impact
  exceeds `episode.crashSpeed`), `nan`, `bounds` (left the terrain), `time`. The reason is `ctx.doneReason`.
- For `kind: "script"`, `state` is a JSON object checkpointed verbatim; `ask` results are legalised.

### 3.3 `genome(base)`

`base` is `{ genes: [{name, kind, min, max, initial, sigma, group}], neat }`. Return it, push genes (use
`group: "script"`), or return a new object. Read script genes with `ctx.genome.get("name")` or
`ctx.genome.values[i]`. A changed layout invalidates checkpoints; resume refuses it.

### 3.4 `ctx` and helpers

| Name | Meaning |
|---|---|
| `ctx.in` | Sensor inputs by name (`ctx.in.alt`, `ctx.in["att.pitch"]`), read-only. Absent sensors read 0. |
| `ctx.inputs` | Float64Array of the same values in `ctx.inputNames` order (fastest). |
| `ctx.out` | Outputs by name (`ctx.out.Elevator`). Pre-filled with the native policy result (`mlp`/`neat`) or last tick's values (`script`); clamped afterwards. |
| `ctx.outputs` | Float64Array in `ctx.outputNames` order. |
| `ctx.state` | Ground truth: `t x y z vx vy vz pitch roll yaw rollRate pitchRate yawRate airspeed groundSpeed altitude agl aoa sideslip gLoad fuel mass thrust distance crashed contact impactSpeed` (m, m/s, deg, deg/s, kg; `distance` is horizontal from spawn). |
| `ctx.sum`, `ctx.reward` | Running term sums; writable per-tick deltas. |
| `ctx.t`, `ctx.dt`, `ctx.tick` | Sim time, control period, tick index. |
| `ctx.info` | `{ generation, candidate, episode, seed, duration, world, worldCount }`. `world` is the episode's index in the experiment's training worlds (§8), so a reward can treat worlds differently. |
| `ctx.memory` | Per-episode scratch, reset before `init`. |
| `ctx.rng` | `random()`, `uniform(a, b)`, `gaussian()`, `int(n)`, seeded per episode. |
| `ctx.genome` | `{ id, values: Float64Array, get(name) }`. |
| `ctx.doneReason` | In `fitness`: `"time"`, `"crash"`, `"nan"`, `"bounds"` or `"script"`. |

Prelude (`src/core/src/script/prelude.js`): `clamp lerp sign deg rad`; `pid(kp, ki, kd, iLimit = 1)` with
`update(err, dt)` and `reset()`; `nn.mlp(sizes, weights, x, act = "tanh", outAct = "tanh")` (same weight layout as
the native MLP, so a script can use a slice of `ctx.genome.values`), `nn.dense`, `nn.tanh/relu/sigmoid/softmax`;
`vec.len/norm/dot/cross`; `log(...)` (rate-limited).

### 3.5 Presets

`pwcli --make-experiment "<name>"` or the EVOLVE presets menu (`data/experiments/`):
- **Neural controller:** Trainer, MLP 9 → 12 → `Ailerons, Elevator, Rudder, Engine`, scored on holding 150 m AGL,
  speed and wings level, with a crash penalty. `sep-cmaes`.
- **Craft design:** wing span and chord (mirrored), wing x and stabilator span, flown by a JS PID autopilot. `ga`.
- **Co-evolve design + controller:** wing span and chord plus MLP weights. `sep-cmaes`.

Crafts without sensors get the standard set: `alt` (AGL), `att`, `rate`, `air`, `vs`, `aero`.

## 4. Algorithms

All maximise `Fitness.total`, draw randomness only from their checkpointed RNG, and must save and restore state
bit-identically (`evolution.run-checkpoint-resume`). Failed candidates score −1e12. Hooks (`select`, `crossover`,
`mutate`) are consulted where the step exists.

| Kind | Parameters (defaults) |
|---|---|
| `ga` | `selection` tournament\|roulette\|rank (tournament), `tournamentSize` 3, `elitism` 2, `crossover` uniform\|one-point\|blend\|sbx (sbx), `crossoverRate` 0.9, `blendAlpha` 0.5, `sbxEta` 15, `mutation` gaussian\|polynomial (gaussian), `mutationRate` 1/n, `mutationSigma` 1 (× gene scale), `polyEta` 20, `adaptive` false |
| `cmaes` | `sigma0` (relative to gene scale), `lambda`, `mu`, `restarts` none\|ipop\|bipop |
| `sep-cmaes` | as `cmaes`, diagonal covariance (genomes over ~200 genes) |
| `openai-es` | `lr`, `sigma`, `antithetic`, `weightDecay`, `optimizer` adam\|sgd, `fitnessShaping` rank\|none |
| `simple-es`, `random` | baselines |
| `neat` | parameters at the top of the NEAT class in `algos_qd.cpp`; species reported every generation; flat genes (co-evolution) get Gaussian steps |
| `map-elites` | archive over `descriptorAxes` (name, min, max, bins); candidates without a descriptor get no cell |
| `novelty` | k-NN (k = 15) novelty over descriptors with an archive |
| `script` | JS `ask`/`tell` (§3.2) |

## 5. Sensors (inputs)

A sensor is a part with `type: "sensor"` (0.05 kg point mass, no drag or collision); `p.kind` selects it. Inputs
are named `<part name>` or `<part name>.<channel>` (duplicates get `#2`, `#3`). BUILD lists them under "Inputs";
FLY shows live values. Frames: +X forward, +Y up, +Z right; positive roll = right wing down; heading 0 = +X,
90 = +Z.

| kind | channels | notes |
|---|---|---|
| `altitudeMSL`, `altitudeAGL` | – (m) | AGL is above max(terrain, water) |
| `airspeed`, `groundSpeed`, `verticalSpeed` | – (m/s) | airspeed includes rotation at the sensor and mean wind |
| `attitude` | `pitch roll yaw` (deg) | |
| `angularRate` | `roll pitch yaw` (deg/s) | body rates |
| `acceleration` | `x y z` (m/s², body specific force), `g` | |
| `aero` | `aoa sideslip` (deg) | |
| `target` | `dx dy dz distance` (m), `bearing elevation` (deg) | target `p.tx/ty/tz`; bearing relative to heading |
| `raycast` | – (m) | along `p.dir` (`down` default) to terrain or water; `p.range` (200) on a miss |
| `servoAngle` | – (−1…1) | servo `p.ref`, or the first servo |
| `wheelSpeed` | – (m/s) | wheel `p.ref`, or the first wheel |
| `fuel` | – (0…1) | across all tanks and solids |
| `water` | `contact` (0/1), `depth` (m) | |
| `contact` | `ground`, `crashed` (0/1; crashed latches until reset) | |

`p.noise` adds deterministic uniform noise (σ) to non-boolean channels, seeded at reset.

## 6. EVOLVE tab

`src/app/qml/EvolvePanel.qml` with `src/app/evolvemodel.cpp`: preset menu, craft picker, training worlds, headless
options, genome and MLP spec, design-gene table, algorithm form, script editor with error-line marking, run
controls (start, stop, resume), live charts (best/mean/median, per term, species, archive heatmap, throughput),
replay of any generation or archive cell in the viewport, and export of a craft with its controller embedded.
FLY offers "Autopilot from evolved controller" for such crafts.

**Training worlds** (`TrainingWorlds.qml`, ① Craft & worlds): a list of the worlds every candidate is tested in.
"+ Add a world" and each row's "Change" offer flat ground, the open world (as it is in WORLD when training starts),
any saved world, an embedded copy of the open world, or a world file elsewhere. With several worlds, "Each
generation" picks every world, one in turn, or a random set (the same for every candidate), and the panel shows how
many flights that makes per candidate. The replay caption names the world the replayed episode flew in.

**Aero model picker** (`EvolvePanel.qml:158`) is the same `AeroModelPicker` list as FLY
(`src/app/appcontroller.cpp:954`): Fast · classic, Fast · slipstream, Fast+ (all effects), Custom. The choice is stored in the experiment's `aero` object (§8).

## 7. Determinism, threading, files

Same experiment, craft, world and seed give the same history bit for bit on any number of workers
(`evolution.evaluator-determinism`, `evolution.run-checkpoint-resume`). Episode seeds are
`derive(seed, generation, -1, episode)` with common random numbers (default) or per candidate; every candidate
starts from a reset sim; reductions are serial in index order; the headless world is immutable with analytic
waves. Watchdog timeouts are wall-clock based, so keep scripts well under budget. Across script engines,
transcendental math in a reward can differ in the last bits.

Files (library root: `~/Library/Application Support/PlaneWorld` on macOS, `%APPDATA%\PlaneWorld` on Windows):
- Experiments: `<root>/experiments/<name>.json` (`src/core/src/evo/experiment.cpp:286`). Every key is optional;
  unknown keys are ignored; `version` is 1.
- Runs: `run.json` (experiment, craft, layout, terms, history, hall of fame), `algorithm.state`, `archive.json`.
  Checkpoints are written every `checkpointEvery` generations and on stop. Resume requires the same layout.
- Exported craft: a normal craft JSON whose first part carries `"evolvedController"` (mode, hz, script, layout,
  genome, names, MLP spec, fitness).

Hot loop: zero heap allocations per control tick and physics substep (checked by `pwtests`); allocation is fine
per episode, candidate and generation.

## 8. Experiment `aero` and `worlds`

```json
"aero": { "model": "fast", "profile": "fast.plus",
          "toggles": { "gyro": true, "pFactor": true, "downwash": true, "blockage": true, "cadWash": true, "slipstream": true } }
```

`model` is always `fast` (older files may say `full`, from the removed CFD mode; they load as fast, and a `cfd` key
is ignored). `profile` is a picker id (`fast.classic`, `fast.slipstream`, `fast.plus` or `custom`); when missing it is
inferred from the toggles (`src/core/src/evo/experiment.cpp`). Missing `aero` means fast with all toggles on.

```json
"world": { "source": "file", "path": "/…/worlds/Hills.json" },
"worlds": [ { "source": "file", "path": "/…/worlds/Hills.json" }, { "source": "flat" }, { "source": "current" } ],
"worldSchedule": { "mode": "sample", "perGeneration": 2 }
```

Each world is `{ "source": "current" | "flat" | "file" | "inline", "path"?, "inline"? }`. One world is written as
`world` only, the format older versions read. Several are written as `worlds` (with `world` = the first, which is what
older versions train in) plus `worldSchedule`:

| `mode` | Each generation, every candidate flies… |
|---|---|
| `all` (default) | `episodesPerCandidate` episodes in every world |
| `rotate` | in one world, the next one each generation |
| `sample` | in `perGeneration` worlds picked at random (seeded by the run seed and generation) |

Episodes run world by world (`ExperimentContext::episodeWorldIndex`), and the episode seeds are the same as for one
world with that many episodes, so a single-world experiment trains exactly as before. The fitness aggregates every
episode of the generation (`episode.aggregate`); `ctx.info.world` lets a reward weigh worlds differently.

## 9. Headless training CLI

```sh
build/src/cli/pwcli --make-experiment "Neural controller" my.json [--craft Trainer]
build/src/cli/pwcli --train examples/experiments/hover-pid.json --generations 10 --out /tmp/run
build/src/cli/pwcli --train my.json --generations 120 --resume --out /tmp/run   # continue from --out
```

Options (`src/cli/train_cli.cpp`): `--generations N`, `--population N`, `--workers N` (1 = single core),
`--seed N`, `--out DIR` (default: the experiment's run directory), `--resume`, `--current-as-flat`,
`--aero fast|<picker id>` (e.g. `fast.slipstream`), `--script-engine auto|quickjs|jsc`.

- One line per generation: best, mean, median, failures, sims/s, sim-s per wall-s and the best candidate's terms
  (NEAT adds `species=`, MAP-Elites/novelty `coverage=`).
- `--out` gets `history.csv` (with `best_<term>` columns), the checkpoint files and `best-craft.json` (load it in
  BUILD, then enable the evolved autopilot in FLY).
- Crafts resolve as `inline`, then `path`, then a bundled or user craft by `name`.
- World source `"current"` (the world open in the app) fails in the CLI unless `--current-as-flat` is given.

Measured on Apple M4, release build, 2026-10-17:
- `pwcli --selftest evolution.bench-headless --verbose` (Trainer, 1 kHz physics, 50 Hz MLP, flat, 30 s
  episodes): 1 core 215 sim-s/wall-s (4.65 µs per substep); 10 cores 1215 sim-s/wall-s (5.7× speedup).
- The `hover-pid.json` command above: 10 generations in 2.3 s wall; best fitness went from −18.9 (gen 0) to
  8.9 (gen 9), with 14.2 s of `hover`. Results depend on the seed and build.

### Example experiments (`examples/experiments/`)

| File | Algorithm | Task |
|---|---|---|
| `hold100-ga.json` | `ga` | MLP controller: take off and hold 100 m AGL (75 s episodes) |
| `hold100-neat.json` | `neat` | Same task, NEAT topology |
| `hold100-mapelites.json` | `map-elites` | Same script; archive over (final x, final altitude) |
| `glide-cmaes.json` | `cmaes` | Craft design: engine off from 150 m, maximise glide distance |
| `hover-ducted-rocket.json` | `sep-cmaes` | MLP for the ducted rocket ([CRAFTS.md](CRAFTS.md)): climb to 10 m and hover (20 s) |
| `hover-pid.json` | `cmaes` | Same hover task, PID-style script whose gains are the genome |
| `design.json`, `neural.json` | | Preset-derived documents |
| `hold100.js`, `glide.js`, `hover.js` | | The embedded scripts, for reading |

## 10. Reward-shaping tutorial

Reward terms ("points") are summed per episode, charted per term in EVOLVE, written to `history.csv` as
`best_<name>` and printed by the CLI. Fitness defaults to the sum of all terms.

1. **Declare the terms** so a typo fails loudly:
   ```js
   function terms() { return ["speed", "track", "hold", "level", "crash"]; }
   ```
2. **Per-tick points** in `reward(ctx)`, multiplied by `ctx.dt` so a point means "per second":
   ```js
   function reward(ctx) {
     const s = ctx.state, dt = ctx.dt, err = Math.abs(s.agl - 100);
     return {
       speed: Math.min(s.airspeed, 35) / 35 * dt * 0.3,        // shaping: start the takeoff roll
       track: Math.max(0, 1 - err / 100) * dt,                 // 1 per second at exactly 100 m
       hold:  err < 10 ? dt : 0,                               // seconds within ±10 m (headline)
       level: -Math.min(Math.abs(s.roll) / 90, 1) * dt * 0.5,  // penalties are negative points
     };
   }
   ```
3. **Terminal points and final fitness** in `fitness(ctx)`; returned terms replace the sums:
   ```js
   function fitness(ctx) {
     const crash = ctx.state.crashed ? -20 : 0;
     return { fitness: ctx.sum.speed + ctx.sum.track + ctx.sum.hold + ctx.sum.level + crash, terms: { crash } };
   }
   ```
4. **End hopeless episodes early:**
   ```js
   function terminate(ctx) { return ctx.state.crashed || (ctx.t > 30 && ctx.state.agl < 5); }
   ```
5. **Optional descriptor** for MAP-Elites or novelty, with matching `descriptorAxes`:
   ```js
   function descriptor(ctx) { return [ctx.state.x, ctx.state.agl]; }
   ```

Lessons (from `hold100.js` and `hover.js`):
- **Give a gradient from generation 0.** With only `track` and `hold`, random controllers never left the runway
  and the GA stalled; the small `speed` term fixed that. Likewise, a hover reward paid only inside a height band
  was flat almost everywhere, so `hover.js` adds an always-on `height` term (−min(|Δy|, 20)/10 per second).
- **Penalise the rate** (`calm`: vertical speed near the target), or the optimiser shoots through the goal.
- **Keep shaping terms small** next to the headline term, and make the headline readable (seconds hovering,
  metres glided).
- **Terminate bad behaviour early** (`hover.js`: crash, tilt past 80°, or above 30 m) and charge for the lost
  time.
- **Size failure penalties so trying is never worse than doing nothing.** `hover.js` charges −1 per remaining
  second and −1 more on a crash; a harsher penalty made "never take off" optimal.
- **Check a reward quickly** with `--generations 3 --population 16` and a `log()` in `control()`.

`hover-pid.json` is a useful baseline for judging whether an MLP learns anything a PID could not.
