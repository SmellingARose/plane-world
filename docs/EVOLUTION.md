# Plane World: Evolution (EVOLVE tab)

This is the contract for the evolution feature. Four builders work against it in parallel. If something here
disagrees with the code, the code in `Sources/Evolution/Core`, `Sources/Evolution/Run` and
`Sources/Evolution/Headless` is authoritative. Raise the conflict with the architect; do not fork the contract.

Status (integration):
- **Done:** everything below is implemented and wired: sensors, headless world, evaluator, run, checkpoint
  and resume, replay, export and the FLY autopilot (MLP and NEAT controllers, ticked per physics substep), the
  JavaScriptCore runtime, all algorithms (`ga`, `cmaes`, `sep-cmaes`, `simple-es`, `openai-es`, `neat`,
  `map-elites`, `novelty`, `script`, `random`), the EVOLVE UI and the headless `--train` CLI (§10).
- **Headless simplifications:** trees, props and breakables are optional *static* obstacles. Touching one
  latches `crashed`; they never move or break, and raycast sensors do not see them. Only one craft per
  episode is supported, and an experiment with `crafts.count > 1` is rejected.
- Example experiments are in `examples/experiments/` (§10.2). The tutorial is §11.

## 1. Owners

| Area | Files | Owner |
|---|---|---|
| Contract types, run, evaluator, headless world, replay, presets | `Sources/Evolution/Core/*`, `Run/*`, `Headless/*`, `Algorithms/Baseline.swift`, `EvolutionSelfTests.swift` | architect |
| Sensors | `Sources/Physics/Sensors.swift`, `SensorSelfTests.swift`, sensor parts in `Core/Documents.swift` | architect, then aero/physics builder |
| JavaScriptCore runtime | `Sources/Evolution/Script/*` (`JSScriptRuntime`, `JSPrelude`, `ScriptedAlgorithm` + `JSAlgorithmHooks`) | **script builder** |
| GA, ES family | `Algorithms/ClassicGA.swift`, `CMAES.swift` (`CMAES`, `SeparableCMAES`, `OpenAIES`), `Operators.swift` | **ga-es builder** |
| NEAT, quality-diversity | `Algorithms/NEAT.swift`, `NEATNetwork.swift`, `MAPElites.swift`, `Novelty.swift` | **neat-qd builder** |
| EVOLVE UI | `Sources/App/Evolve/*` (`EvolvePanel`, `EvolveModel`, `EvolveCharts`, `EvolveScriptEditor`) | **evolve-ui builder** |
| App bridge | `Sources/App/AppModel+Evolve.swift`, the tab switch in `Panels.swift`, `AppModel.evolve` | architect, then integrator |

Builder rules:
- Edit only your files. If you need a contract change, ask the architect.
- You may *add* files in your directory, and *add* self-tests: group `evolution-js` for the script builder,
  `evolution-algo` for both algorithm builders, `app` for the UI builder. Register them from your own
  `register()`; the architect wires the call into `App/main.swift`. Ask once.
- Every stubbed piece says `TODO(<owner>)`. Remove the marker when you implement it.

## 2. Architecture

```
            EVOLVE UI (main thread)
               │  ExperimentDocument, start/stop, charts, replay
               ▼
   EvolutionRun ── orchestrator Thread ──────────────────────────────────────────┐
     │ algorithm.ask() → [Genome]                                               │
     │ evaluator.evaluate(pop) ──► JobSystem.parallelFor(workers)                │
     │      EvalWorker × N  (own CraftSim, own ScriptRuntime/JSContext,          │
     │                       MLP buffers, ControlFrame)                          │
     │        prepare(genome): DesignDecoder → script decode() → CraftSim.load   │
     │        runEpisode × E: reset → [observe → policy → script tick →          │
     │                        setOutput → CraftSim.step(1/hz)]                   │
     │ algorithm.tell(pop, fitness)                                              │
     │ record history + hall of fame, checkpoint every k generations             │
     └──────────────────────────────────────────────────────────────────────────┘
   HeadlessWorld (immutable and shared): BakedTerrain + HeadlessWater + spawn + environment
   ReplayRecorder: re-simulates one episode deterministically → Trajectory → normal renderer
```

Module: `PWEvolution` (`Sources/Evolution`). It depends on PWCore, PWPhysics, PWCollision, PWTerrain and
PWWater, and links JavaScriptCore. Only the App imports it.

### 2.1 Key types (all public)

| Type | File | Role |
|---|---|---|
| `Genome`, `GenomeLayout`, `GeneSpec`, `NEATGenome`/`NEATNode`/`NEATConnection`, `NEATLayout` | Core/Genome.swift | Representation. A flat `[Double]` plus an optional NEAT graph. |
| `EvoRNG` | Core/RNG.swift | The only randomness source. Codable. `EvoRNG.derive(root, path...)` builds seeds. |
| `Fitness`, `EvolutionError`, `Stats` | Core/Fitness.swift | Per-candidate result: total, named terms, descriptor, error. |
| `EvolutionAlgorithm`, `AlgorithmHooks`, `EliteArchive`, `SpeciesInfo`, `AlgorithmRegistry` | Core/Algorithm.swift | Ask/tell interface plus Codable state. |
| `ExperimentDocument` (+ `CraftRef`, `WorldRef`, `HeadlessOptions`, `DesignGene`, `MLPSpec`, `GenomeSource`, `ControllerSpec`, `EpisodeSettings`, `SpawnSettings`, `WindRandomization`, `ScriptBundle`, `AlgorithmParams`, `DescriptorAxis`) | Core/Experiment.swift | The JSON document. |
| `ScriptRuntime`, `ScriptError`, `ScriptHook`, `ControlFrame`, `CraftStateSnapshot`, `EpisodeInfo`, `EpisodeOutcome`, `NullScriptRuntime`, `NativeScriptRuntime`, `ScriptRuntimes` | Core/ScriptRuntime.swift | Script contract. |
| `PolicyNetwork`, `MLPPolicy`, `DesignDecoder` | Core/Policy.swift | Native genome decoders. |
| `ExperimentPresets` | Core/Presets.swift | The three shipped presets, with their JS. |
| `ExperimentContext`, `Evaluator`, `SimEvaluator`, `EvalWorker`, `EvalStats` | Run/Evaluator.swift | Parallel headless evaluation. |
| `EvolutionRun`, `GenerationRecord`, `HallOfFameEntry`, `RunCheckpoint`, `EmbeddedController` | Run/Run.swift | Orchestration, history, checkpoints and export. |
| `ReplayRecorder`, `Trajectory`, `ReplayFrame`, `EvolvedAutopilot` | Run/Replay.swift | 3D replay, and the autopilot used in FLY. |
| `HeadlessWorld`, `BakedTerrain`, `HeadlessWater` | Headless/HeadlessWorld.swift | CPU-only world. |

## 3. Genomes

The **layout** is built once per run:
1. The native part comes from `experiment.genome.preset`:
   - `neural`: MLP weights (genes in group `"mlp"`). Applies when `controller.mode == "mlp"`.
   - `design`: one gene per `DesignGene` (group `"design"`).
   - `coevolve`: design genes first, then MLP genes.
   - `script`: empty.

   When the algorithm is `neat` or `controller.mode == "neat"`, `layout.neat` is set from
   `genome.neat`. If that is nil, every craft input and output is used.
2. The script hook `genome(base)` may append genes or replace the layout (§4.3).

Gene semantics:
- `GeneSpec.legalize` clamps to `[min, max]`, rounds `int` genes, and thresholds `bool` genes at 0.5.
- Algorithms must call `layout.legalize(&values)` on every candidate they emit.
- `mutationScale` is the per-gene step hint: `sigma`, or 10 % of the range.
- On/off genes are `kind: .bool`. A design gene with `field: "enabled"` removes the part and its links.

**MLP weight layout.** For each layer `L` (in → out), the genes are W row-major `[out][in]`, then `b[out]`.
Gene names are `mlp.L.w.o.i` and `mlp.L.b.o`.
- Inputs are divided by `MLPSpec.inputScale[name]`.
- Output activations (tanh by default) map from −1…1 onto each output's range:
  `lo + (y+1)/2·(hi−lo)`. A throttle of 0…1 is therefore `(y+1)/2`.

**Design genes.** The `field` is one of `mass`, `pos.N`, `rot.N`, `p.<param>` (any numeric part param, for
example `p.span`, `p.thrust`, `p.range` or `p.torque`) or `enabled`.
- `part` is a part id, a part name, or a `prefix*`.
- `mirror` lists more parts that get the same value. Their `pos.2` is negated.
- A design that changes the parts loads a fresh `CraftSim` per candidate. Allocation is fine there; it is not
  in the step loop.

**NEAT genome.** Node ids are fixed:
- `0..<nIn` are the inputs.
- `nIn` is the bias.
- `nIn+1 ..< nIn+1+nOut` are the outputs.
- Hidden nodes follow.

Innovation numbers are global per run and live in the NEAT algorithm's state. `NEATNetwork.forward` writes the
outputs straight into `frame.outputs`, so `NEATLayout.outputs` must equal the craft outputs in order (the
default). Output values are used as-is and then clamped to each output's range.

## 4. JavaScript API (what the user writes)

There is one source string, `experiment.scripts.source`. Every function is optional. Define only what you
need. The runtime calls them in the order shown in §4.2.

### 4.1 Execution model

- Each evaluator worker has its own `JSVirtualMachine` and `JSContext`. The orchestrator has one more, for
  `genome()`, `terms()` and the algorithm hooks. Each source is compiled once per context.
- The global state of a worker persists across candidates. **Do not keep cross-episode state in globals**:
  results would then depend on scheduling. Use `ctx.memory`, which is reset to `{}` before every episode.
- `Math.random()` is replaced by the episode-seeded `ctx.rng.random()`. Inside `select/crossover/mutate/ask`
  it uses the algorithm's RNG. `Date.now()` returns the simulation time in milliseconds.
- **Watchdog.** Per-tick hooks get `scripts.callBudgetMs` (default 5 ms) per call. `init`, `fitness`,
  `descriptor` and `decode` get 20× that. `genome`, `terms` and the algorithm hooks get 2 s. When a call
  exceeds its budget, the candidate fails with `ScriptError(timedOut: true)`. Its fitness becomes
  `EvolutionConstants.failedFitness` (−1e12) and the run continues.
- **Errors.** Syntax errors fail `compile`. Exceptions are attributed to the hook that threw. Errors carry
  `line`/`column` relative to the user source (the prelude's lines are subtracted). The UI marks that line in
  the editor and shows `GenerationRecord.firstError`.

### 4.2 Hooks and call order

```js
// once per run (orchestrator)
function genome(base) { return base; }            // §4.3
function terms() { return ["altitude", "speed"]; }  // reward term names; else experiment.rewardTerms

// once per candidate (worker), after native design genes were applied
function decode(g, craft) { return craft; }        // craft = plain CraftDocument JSON; return modified copy

// per episode
function init(ctx) {}                                 // set up ctx.memory, PIDs, ...
// per control tick (controller.hz, default 50 Hz), in this order:
function control(ctx) {}                              // read ctx.in / ctx.state, write ctx.out
function reward(ctx) { return { altitude: 0.1 }; }   // per-tick deltas, added to ctx.sum
function terminate(ctx) { return false; }             // true → end the episode now
// end of episode
function fitness(ctx) { return ctx.sum.altitude; }    // number, or { fitness, terms: {...}, descriptor: [...] }
function descriptor(ctx) { return [ctx.state.x, ctx.state.z]; }   // MAP-Elites / novelty

// optional algorithm hooks (orchestrator; return undefined/null to use the built-in operator)
function select(pop, count, rng) { return [0, 1, ...]; }   // indices into pop
function crossover(a, b, layout, rng) { return values; }   // child gene array
function mutate(g, layout, rate, rng) { return values; }
// full custom algorithm (algorithm.kind == "script")
function ask(state, layout, rng) { return [values, ...]; }
function tell(state, population) {}                        // population = [{ values, fitness, terms, descriptor }]
```

Details:
- `reward` may return an object of term deltas, or add to `ctx.reward.<term>` directly. Returning a number
  adds it to the first term.
- Unknown term names are a `ScriptError` (declare them in `terms()`).
- If `fitness` is absent, fitness is the sum of all term sums.
- `fitness` may return `terms` with *final* values that override the episode sums, for terminal bonuses such
  as `crash: -20`.
- `descriptor` in `fitness`'s object wins over the `descriptor()` hook.
- **Built-in termination** runs before `terminate()` on the next tick:
  - `crash`, when `episode.stopOnCrash` is set and a non-wheel ground impact exceeds `episode.crashSpeed`.
  - `nan`.
  - `bounds`, when the craft leaves the baked terrain.
  - `time`.

  The reason is available as `ctx.doneReason` in `fitness()`.

### 4.3 `genome(base)`

`base` is a `GenomeLayout` as JSON: `{ genes: [{name, kind, min, max, initial, sigma, group}], neat }`.
- Return it unchanged, push genes (use `group: "script"`), or return a new object.
- Script genes are read in `decode`/`control` through `ctx.genome.get("name")` or `ctx.genome.values[i]`.
- Layout changes invalidate checkpoints. Resume refuses a checkpoint whose layout differs.

### 4.4 The `ctx` object and helpers

| Name | Type | Meaning |
|---|---|---|
| `ctx.in` | object, read-only | Sensor inputs by name, e.g. `ctx.in.alt`, `ctx.in["att.pitch"]`. These are the craft's **inputs** (§6). Absent sensors read 0. |
| `ctx.inputs` | Float64Array | The same values in `ctx.inputNames` order. This is the fastest path. |
| `ctx.out` | object, writable | Outputs by name (the slider names: `ctx.out.Elevator`, `ctx.out["Main L motor"]`). Pre-filled with the native policy result (`mlp`/`neat`), or with the previous tick's values (`script`). Values are clamped to the output's range afterwards. |
| `ctx.outputs` | Float64Array | The same values in `ctx.outputNames` order. |
| `ctx.state` | object | Ground truth from `CraftStateSnapshot`: `t x y z vx vy vz pitch roll yaw rollRate pitchRate yawRate airspeed groundSpeed altitude agl aoa sideslip gLoad fuel mass thrust distance crashed contact impactSpeed`. Units are m, m/s, deg, deg/s and kg. `distance` is the horizontal distance from spawn. |
| `ctx.sum` | object | Running term sums for the episode. |
| `ctx.reward` | object | Writable per-tick deltas (an alternative to returning them). |
| `ctx.t`, `ctx.dt`, `ctx.tick` | number | Sim time, control period, tick index. |
| `ctx.info` | object | `{ generation, candidate, episode, seed, duration }`. |
| `ctx.memory` | object | Scratch space for one episode. Reset before `init`. |
| `ctx.rng` | object | `random()`, `uniform(a, b)`, `gaussian()`, `int(n)`. Seeded per episode. |
| `ctx.genome` | object | `{ id, values: Float64Array, get(name) }`. |
| `ctx.doneReason` | string | In `fitness`: `"time"`, `"crash"`, `"nan"`, `"bounds"` or `"script"`. |

Prelude globals (`JSPrelude.source`):
- `clamp(x, a, b)`, `lerp(a, b, t)`, `sign(x)`, `deg(rad)`, `rad(deg)`.
- `pid(kp, ki, kd, iLimit = 1)` returns `{ update(err, dt), reset() }`.
- `nn.mlp(sizes, weights, x, act = "tanh", outAct = "tanh")` returns a Float64Array. `weights` uses the same
  layout as the native MLP (§3), so a script can read a slice of `ctx.genome.values`.
- `nn.dense(W, b, x, act)` and `nn.tanh / relu / sigmoid / softmax`.
- `vec.len(x, y, z)`, `vec.norm`, `vec.dot`, `vec.cross`.
- `log(...)` sends output to the run log. It is rate-limited and dropped from the hot path in training runs.

Performance targets (script builder):
- Typed arrays are bound with no copy over `ControlFrame` buffers (`JSObjectMakeTypedArrayWithBytesNoCopy`).
- `ctx.in` and `ctx.out` are objects with accessors over those arrays.
- JS values for the hooks are created once per context.
- Aim for under 3 µs of overhead per tick for a trivial `control`.

### 4.5 Presets

`ExperimentPresets.make(name)` creates each preset:
- **Neural controller.** Trainer plus standard sensors. The MLP maps 9 inputs → 12 hidden → `Ailerons,
  Elevator, Rudder, Engine`. Scored on holding 150 m AGL, speed and wings level, with a crash penalty.
  Algorithm `sep-cmaes`.
- **Craft design.** Wing span and chord (mirrored), wing x-position and stabilator span, flown by a JS PID
  autopilot. Algorithm `ga`.
- **Co-evolve design + controller.** Wing span and chord plus the MLP weights in one genome. Algorithm
  `sep-cmaes`.

`ExperimentPresets.addStandardSensors(craft)` adds sensors named `alt` (AGL), `att` (attitude), `rate`,
`air`, `vs` and `aero` when the craft has no sensors.

### 4.6 Custom algorithm (`kind: "script"`)

`ScriptedAlgorithm` (script builder) adapts JS `ask` and `tell`:
- `state` is a JSON object that is checkpointed verbatim (`saveState` serialises it, with the RNG).
- `ask` returns arrays of gene values, which are legalised.
- `tell` receives the population with fitnesses.

## 5. Algorithms

All algorithms implement `EvolutionAlgorithm` (Core/Algorithm.swift) and **maximise** `Fitness.total`.
- Draw randomness only from an `EvoRNG` stored in your state. `init(seed:)` gets `derive(experiment.seed, -100)`.
- `ask()` may return any count of at least 1, but should honour `population`.
- `tell()` receives the same genomes in the same order.
- Assign unique, increasing `Genome.id`s and set `origin`, `parents` and `generation`.
- `saveState()` and `restore()` must round-trip bit-identically: resuming must continue exactly. The
  `run-checkpoint-resume` test runs this with `simple-es`. Add the same test for your kinds.
- Failed candidates have `total = -1e12`. Treat them as worst; never as NaN.
- Expose `diagnostics` (step size, rates, stagnation), `species` (NEAT) and `archive` (MAP-Elites, novelty)
  for the UI.
- Consult `hooks` where the step exists (`select` / `crossover` / `mutate`). A nil result means "use the
  built-in operator".
- `Baseline.swift` shows the expected shape: a `State: Codable` struct and JSON `saveState`.

### 5.1 ClassicGA (`"ga"`, ga-es builder)

Parameters, with defaults:

| Parameter | Values | Default |
|---|---|---|
| `selection` | `tournament`, `roulette`, `rank` | `tournament` |
| `tournamentSize` | | 3 |
| `elitism` | | 2 |
| `crossover` | `uniform`, `one-point`, `blend`, `sbx` | `sbx` |
| `crossoverRate` | | 0.9 |
| `blendAlpha` | | 0.5 |
| `sbxEta` | | 15 |
| `mutation` | `gaussian`, `polynomial` | `gaussian` |
| `mutationRate` | | 1/n |
| `mutationSigma` | multiplier of `GeneSpec.mutationScale` | 1 |
| `polyEta` | | 20 |
| `adaptive` | rates adapt from the success of offspring vs parents; report in diagnostics | false |

Bool and int genes go through `legalize`.

### 5.2 ES family (ga-es builder)

| Kind | Parameters |
|---|---|
| `cmaes` | `sigma0` (relative to `mutationScale`), `lambda`, `mu`, `restarts: none\|ipop\|bipop` |
| `sep-cmaes` | the same, with a diagonal covariance (use it for genomes over ~200) |
| `openai-es` | `lr`, `sigma`, `antithetic`, `weightDecay`, `optimizer: adam\|sgd`, `fitnessShaping: rank\|none` |

`simple-es` (`Baseline.swift`) already exists.

### 5.3 NEAT (`"neat"`, neat-qd builder)

The parameters are listed in the `NEAT.swift` header.
- The genomes' `neat` field holds the graph. `values` holds the flat genes when present (co-evolution).
  Mutate those with Gaussian steps.
- `species` is reported every generation.
- `NEATNetwork` must not allocate in `forward`.

### 5.4 MAP-Elites (`"map-elites"`) and novelty search (`"novelty"`) (neat-qd builder)

- The run passes `experiment.descriptorAxes` as `params.values["axes"]`.
- `EliteArchive.cellIndex` is the binning. Use it so the UI heatmap matches.
- Novelty uses k-NN over descriptors (`k = 15`) with an archive in `EliteArchive.noveltyPoints`, and fills
  `Fitness.novelty`.
- A candidate without a descriptor gets no cell.

## 6. Sensors (inputs)

A sensor is a part with `type: "sensor"`. It is a 0.05 kg point mass with no drag or collision. `p.kind`
selects the measurement. Each sensor contributes one or more **inputs**, named `<part name>` or
`<part name>.<channel>`. Duplicate names get `#2`, `#3` and so on.

The input list has the same order in the document (`CraftInputs.list(doc)`) and in the sim
(`CraftSim.inputs`). BUILD shows it under "Inputs (auto, from sensors)". FLY shows live values.

Frames: +X forward, +Y up, +Z right. Positive roll means the right wing is down, positive pitch means nose
up, and yaw/heading 0 is +X with 90 meaning the nose points to +Z.

| kind | channels | notes |
|---|---|---|
| `altitudeMSL` | – (m) | world y of the sensor point |
| `altitudeAGL` | – (m) | above max(terrain, water surface) |
| `airspeed` | – (m/s) | including rotation at the sensor point, mean wind |
| `groundSpeed`, `verticalSpeed` | – (m/s) | |
| `attitude` | `pitch roll yaw` (deg) | |
| `angularRate` | `roll pitch yaw` (deg/s) | body rates |
| `acceleration` | `x y z` (m/s², body specific force), `g` | |
| `aero` | `aoa sideslip` (deg) | |
| `target` | `dx dy dz distance` (m), `bearing elevation` (deg) | target `p.tx/ty/tz` in world m; bearing is relative to heading, ±180 |
| `raycast` | – (m) | along `p.dir` (`down` by default; `forward/back/up/left/right`) in the part's frame, to terrain or water; `p.range` (default 200) when nothing is hit |
| `servoAngle` | – (−1…1) | servo `p.ref`, or the servo linked to `p.ref`, or the first servo |
| `wheelSpeed` | – (m/s) | rim speed of wheel `p.ref`, or the first wheel |
| `fuel` | – (0…1) | remaining over capacity, across all tanks and solids |
| `water` | `contact` (0/1), `depth` (m) | sensor point below the surface |
| `contact` | `ground` (0/1), `crashed` (0/1, latched until reset) | |

`p.noise` adds deterministic uniform noise with standard deviation σ to the non-boolean channels. It is seeded
from `CraftSim.sensorNoiseSeed` at reset.

Hot path: `CraftSim.readSensors(env:into:)` fills a caller-owned buffer with no allocation.
`updateInputValues(env:)` is for the UI only.

Other physics additions:
- `setOutput(index:value:)` writes an output without allocating.
- `outputIndex(_:)` and `inputIndex(_:)` look up indices by name.
- `crashed`, `groundContact`, `maxImpactSpeed` and `crashSpeed`.
- `clone()` copies a sim; CAD panel meshes are deep-copied.

JSON stays backwards-compatible. A sensor is just another part type. Old files never contain one, and unknown
types still load.

## 7. EVOLVE UI (evolve-ui builder)

The tab exists: `AppTab.evolve`, and `SidePanel` shows `EvolvePanel()`. `AppModel.evolve` is a lazy
`EvolveModel`. The architect added `AppModel+Evolve.swift`:
- `makeHeadlessWorld(options:seed:)` bakes the open world, which is world source `"current"`.
- `resolveCraft(_:)` returns the craft prepared for flight with `CraftOutputs.prepareForFlight`, as FLY would.

Required features:
1. **Experiment editor.**
   - Presets menu (`ExperimentPresets.names`), craft picker from `model.library`, world source
     (`current`/`flat`/`file`), headless options.
   - Genome preset and MLP spec: pick inputs and outputs from `CraftSim.inputs`/`outputs`.
   - Design gene table: part picker, field picker from the part's numeric params, min, max, mirror.
   - Algorithm kind with a parameter form generated from `AlgorithmParams.values`, population, generations,
     episode settings, seed.
   - Save and load as JSON in `ExperimentDocument.directory`. Embed `CraftRef.inline` on save.
2. **Script editor** (`EvolveScriptEditor`): monospaced, with line numbers. Highlight `ScriptError.line` and
   show the message. Add a "Check" button that compiles with a fresh `JSScriptRuntime`.
3. **Run controls.**
   - Start: build `EvolutionRun(experiment:craft:world:)` on a background queue, since a world bake of a
     2049² field takes about 100 ms. Pause/stop with `stop()`. Resume from a run directory with
     `EvolutionRun.resume`.
   - Show the run state and `lastError`.
4. **Live charts** (Swift Charts):
   - best, mean and median per generation;
   - per reward term (`termsBest`/`termsMean`);
   - species counts (NEAT), and the archive heatmap (`EliteArchive`, 2-D axes);
   - throughput: `simsPerSecond` and `simSecondsPerWallSecond`.

   Feed them from `run.onGeneration`, which fires on the orchestrator thread, so hop to main.
5. **Replay.** Click a generation (`hallOfFame[g]`) or an archive cell, then call
   `ReplayRecorder.record(context: run.context, genome:, generation:, trainingFitness:)` on a background
   queue. Then play the `Trajectory` in the viewport:
   - load `trajectory.craft` into the scene (`AppScene.rebuildCraft`);
   - feed `trajectory.sample(at:)` part poses to `scene.updateCraft` each frame;
   - add a timeline scrubber and speed control;
   - show `fitnessMatches`.
6. **Export.** `run.exportCraft(genome)` gives a craft with an embedded controller. Save it to the craft
   library.
7. **FLY "Autopilot from evolved controller" toggle**, shown when `EmbeddedController.find(in: craft)` is
   non-nil. Create an `EvolvedAutopilot(craft:sim:)` and call `update(sim:env:dt:)` each frame before
   `sim.step`. The integrator wires it into `AppModel.tick`.

## 8. Threading, determinism, files

### 8.1 Threading
- **Main thread:** UI and replay playback.
- **Orchestrator thread** (`EvolutionRun.start`): the algorithm, the orchestrator `ScriptRuntime`, history and
  checkpoints.
- **Evaluation:** `JobSystem.shared.parallelFor(workers)`. Each job owns exactly one `EvalWorker` and pulls
  candidate indices from a shared counter. A worker (its CraftSim, its JSContext) is never used by two threads
  at once. It may still run on different OS threads over time; JSC allows that.
- **Shared read-only data:** `ExperimentContext`, `HeadlessWorld`, and the base craft document.

### 8.2 Determinism

Same experiment JSON, same craft, same world, same seed: same history, bit for bit, on any number of workers.
This is enforced by `evaluator-determinism` (1 vs N workers) and `run-checkpoint-resume`. It holds because:
- Episode seeds are `derive(seed, generation, -1, episode)` with common random numbers (the default), or
  `derive(seed, generation, candidate, episode)`. They drive spawn jitter, wind, sensor noise and `ctx.rng`.
- Every candidate starts from `CraftSim.reset` with all outputs zeroed. No state survives across candidates
  except in JS globals, which are forbidden (§4.1).
- The order of floating-point operations does not depend on the thread. CraftSim parallelises strips and
  panels only above `parallelThreshold`, and its reductions are serial in index order.
- `HeadlessWorld` is immutable. Water waves are analytic functions of (x, z, t). The GPU ocean is never used.
- Algorithms use only their checkpointed `EvoRNG`.

Not deterministic: wall-clock statistics, and watchdog timeouts, which are wall-clock based. A candidate that
times out on a loaded machine can pass on an idle one. Keep scripts well under budget.

### 8.3 Files
- **Experiment:** `~/Library/Application Support/PlaneWorld/experiments/<name>.json`. This is
  `ExperimentDocument`. Every key is optional, unknown keys are ignored, and `version` is 1.
- **Run:** `experiments/<name>.runs/<runID>/` holds:
  - `run.json`, the `RunCheckpoint`: experiment copy, craft, layout, term names, history, hall of fame.
  - `algorithm.state`, the opaque algorithm state.
  - `archive.json`, when there is an archive.

  A checkpoint is written every `checkpointEvery` generations and at stop or finish. Resume requires the same
  genome layout.
- **Exported craft:** a normal craft JSON whose first part carries
  `"evolvedController": EmbeddedController`. That holds the mode, hz, script bundle, layout, genome,
  input/output/term names, MLP spec and fitness. The key rides in `CraftPart.extra`, so older builds keep it
  round-tripping.

## 9. Headless world and performance

`HeadlessWorld` has three sources:
- `bake(field:water:...)`: a copy of the live height field. This is the "current" world.
- `load(WorldDocument)`: CPU `TerrainSystem` without a renderer.
- `flat()`.

Headless differs from the live world in these ways:
- **Terrain:** `BakedTerrain` uses the same `sampleHeight`, `material` and `raycast` as `TerrainSystem`, so
  replays match.
- **Water:** flat sea, or an analytic 4-component swell (`HeadlessOptions.oceanWaves`), plus lakes and
  rivers. The FFT ocean, FLIP zones and splashes are not simulated.
- **Obstacles (`HeadlessObstacles`):** `headless.vegetation` adds tree trunks as vertical capsules (from
  `ProceduralVegetation`, generated on the CPU from the world's saved vegetation params, or the live trees for
  "current"). `headless.breakables` adds every placed world object (props and breakables) as an oriented box
  sized like `AppModel.addObject`. Imported meshes are approximated by a box. Obstacles are static, with no
  contact response, fracture, debris or falling trees. Part corners are swept between control ticks, so fast
  craft cannot tunnel through, and any contact latches `crashed`. Raycast sensors ignore obstacles.
- **Not implemented:** the full RigidWorld (dynamic bodies) headless, and multi-craft episodes. More than
  one entry in `crafts` is rejected with an error.

Hot-loop rules:
- Zero heap allocations per control tick and per physics substep. This is measured with libmalloc's
  `malloc_logger` hook in `evolution.zero-alloc-step`.
- Allocation is allowed per episode (a few arrays), per candidate (a design change makes a new CraftSim) and
  per generation.
- Exception: `HeadlessWater.submergedForces` allocates one closure per substep while a hull is within about
  1 m of water.

Two hot-path fixes landed while building this:
- `CraftPart.param` defaults are cached. They used to build a dictionary on every miss.
- Wing strips are evaluated in a value-type `StripJob` inside `runStrips`. Before, the closure capture forced
  a copy-on-write copy of `parts` every substep.

Benchmark (`PlaneWorld --selftest evolution.bench-headless`, release, Apple M4 with 10 cores):
- Trainer, 1 kHz physics, 50 Hz MLP control, flat baked terrain, 30 s episodes, crash stop off.
- Numbers as measured on 2026-10-15:

| | episodes | wall | sim-s per wall-s | sims/s |
|---|---|---|---|---|
| 1 core | 4 | 2.96 s | **41** | 1.35 (24.7 µs per 1 kHz substep) |
| 10 cores | 40 | 5.40 s | **222** | 7.4 (5.5× speedup) |

A 64-candidate × 2 × 40 s generation is about 5,100 sim-s, roughly 23 s of wall time. Raising control
substeps or using `physicsHz = 500` scales roughly linearly.

## 10. Headless training CLI

```sh
PlaneWorld --make-experiment "Neural controller" my.json      # write a preset as an editable document
PlaneWorld --train my.json --generations 60 --out runs/my     # train with no window, all cores
PlaneWorld --train my.json --generations 120 --resume --out runs/my   # continue from the checkpoint in --out
```

Options: `--generations N`, `--population N`, `--workers N` (1 = single core), `--seed N`, `--out DIR`
(default: the experiment's run directory under Application Support), `--resume`.

- Each generation prints one line: best, mean and median fitness, failures, sims/s, sim-seconds per wall
  second, and the best candidate's named points. NEAT adds `species=`, MAP-Elites and novelty add `coverage=`.
- `--out` receives `history.csv` (one row per generation, including `best_<term>` columns), the checkpoint
  (`run.json`, `algorithm.state`, `archive.json`), and `best-craft.json`. That is the best candidate exported
  with its controller embedded. Load it in BUILD, then switch on "Autopilot from evolved controller" in FLY.
- Crafts resolve as in the app: `inline`, then `path`, then a bundled or user craft by `name`. Standard
  sensors are added when the craft has none, and auto motors are added as in FLY.
- World source `"current"` means "the world open in the app". The CLI has no app, so it **fails** on
  `"current"` unless you pass `--current-as-flat`, which trains on the flat world explicitly. Use `"flat"`, `"file"`
  or `"inline"` for headless runs.

### 10.1 Throughput

`PlaneWorld --selftest evolution.bench-headless` measures the evaluator: 1 kHz physics, a 50 Hz neural
controller, Trainer, flat world. The integration numbers are in the README.

### 10.2 Example experiments (`examples/experiments/`)

| File | Algorithm | Task |
|---|---|---|
| `hold100-ga.json` | `ga` | MLP controller: take off and hold 100 m AGL (75 s episodes) |
| `hold100-neat.json` | `neat` | The same task; NEAT evolves the topology |
| `hold100-mapelites.json` | `map-elites` | The same script; archive over (final x, final altitude) |
| `glide-cmaes.json` | `cmaes` | Craft design: engine off from 150 m, maximise glide distance |
| `hover-ducted-rocket.json` | `sep-cmaes` | MLP controller for the ducted rocket: lift off, climb to 10 m and hover upright over the start point (20 s) |
| `hover-pid.json` | `cmaes` | The same hover task with a scripted (PID-style) controller whose gains are the genome |
| `design.json`, `neural.json` | | Preset-derived starting documents (`--make-experiment`) |
| `hold100.js`, `glide.js`, `hover.js` | | The scripts embedded in those documents, for reading |

## 11. Tutorial: writing your own reward with named points

A reward is built from named **points** (reward terms). Each point is summed over the episode, plotted on its
own chart in EVOLVE, written to `history.csv` as `best_<name>`, and printed by the CLI. Fitness is what the
algorithm maximises. By default it is the sum of all points, and you can shape it yourself.

**1. Declare the points.** Every name you use must be declared, so a typo fails loudly instead of silently
scoring 0:

```js
function terms() { return ["speed", "track", "hold", "level", "crash"]; }
```

**2. Give per-tick points in `reward(ctx)`.** It runs every control tick (50 Hz by default). Return the
*deltas* for this tick and multiply by `ctx.dt`, so a point means "per second" whatever the controller rate:

```js
function reward(ctx) {
  const s = ctx.state, dt = ctx.dt;
  const err = Math.abs(s.agl - 100);                       // metres from the target altitude
  return {
    speed: Math.min(s.airspeed, 35) / 35 * dt * 0.3,       // shaping: get the takeoff roll going
    track: Math.max(0, 1 - err / 100) * dt,                // 0..1 per second, 1 = exactly at 100 m
    hold:  err < 10 ? dt : 0,                              // seconds inside +-10 m (the number you report)
    level: -Math.min(Math.abs(s.roll) / 90, 1) * dt * 0.5, // a penalty is just a negative point
  };
}
```

`ctx.state` has the ground truth (`agl`, `airspeed`, `pitch`, `roll`, `vy`, `distance`, `crashed`,
`contact`...; see §4.4). `ctx.in` has the craft's sensors by name, the same values a controller sees.

**3. Give one-off points and the final fitness in `fitness(ctx)`.** Terms returned here *replace* the summed
value. Use this for terminal bonuses and penalties:

```js
function fitness(ctx) {
  const crash = ctx.state.crashed ? -20 : 0;
  return {
    fitness: ctx.sum.speed + ctx.sum.track + ctx.sum.hold + ctx.sum.level + crash,
    terms: { crash: crash },
  };
}
```

**4. End episodes early with `terminate(ctx)`.** This saves simulation time and stops rewarding hopeless
candidates:

```js
function terminate(ctx) { return ctx.state.crashed || (ctx.t > 30 && ctx.state.agl < 5); }
```

**5. Optional: add a behaviour descriptor** for MAP-Elites or novelty search. Set the matching
`descriptorAxes` (name, min, max, bins) in the experiment:

```js
function descriptor(ctx) { return [ctx.state.x, ctx.state.agl]; }
```

**Tips from the example runs**
- **Give a gradient from the very first generation.** With only `track` and `hold`, no random controller
  ever left the runway, so every candidate scored the same and the GA stalled for 14 generations. Adding the
  small `speed` point made takeoff emerge at generation 18.
- **Keep shaping points small** next to the goal point, or the optimiser settles for the shaping alone.
- **Make the headline point readable** (seconds held, metres glided), so the per-term chart answers "is it
  doing the task?" directly.
- **Check a reward quickly** with a short CLI run (`--generations 3 --population 16`) and a `log()` call in
  `control()`. `log` is rate-limited per worker.

## 12. Hover experiment and the reward-shaping lesson

`examples/experiments/hover-ducted-rocket.json` (script: `hover.js`) trains an MLP (9 inputs, 16 tanh hidden,
4 outputs: `Lift upper`, `Lift lower`, `Vane X`, `Vane Z`) to fly the ducted rocket (`docs/CRAFTS.md`) from the
ground to a hover at 10 m over the start point. Settings: sep-CMA-ES, 20 s episodes, 2 episodes per candidate with
common random numbers, wind up to 2 m/s with turbulence 0.2.

### What went wrong first

The first reward paid only for time spent **within ±10 m** of the target height. Most random controllers either
stayed on the ground (0 reward) or went full throttle and **shot straight through the band** in under a second
(also about 0). The landscape was flat almost everywhere, so CMA-ES had no gradient to follow, and the few
candidates that got any reward did it by passing through the band on the way up.

### The shaped reward (current `hover.js`)

| Term | Per second | Why |
|---|---|---|
| `height` | −min(|Δy|, 20)/10, **always on** | Every candidate gets a gradient toward 10 m, wherever it is |
| `hover` | +1 inside ±1.5 m vertically and 2 m horizontally | The headline number (seconds hovering) |
| `calm` | −min(|vs|/5, 1) × 0.5, full weight within 3 m of the target, 0.3 outside | Penalises vertical speed, so shooting through the target is worse than arriving slowly |
| `drift` | −min(dist/10, 1) × 0.5 | Stay over the start point |
| `upright` | −tilt/90° | Stay vertical |
| `spin` | −min(|yaw rate|/180, 1) × 0.3 | Use the differential motors to stop yaw |
| `crash` | one-off | See below |

**Fly-away termination.** The episode ends early if the craft crashes, tilts past 80°, or climbs above 30 m.
Without the altitude cap, "climb forever" was a local optimum the height cap alone did not remove, and it wasted
sim time.

**Crash penalty size.** The remaining episode time is charged at −1 per second (the same rate as sitting on the
ground with a 10 m height error), plus 1. An earlier, harsher penalty of −2/s − 5 made "never take off" the best
strategy, because any attempt to fly risked a bigger loss than doing nothing.

The general lessons:
- Reward **distance to the goal continuously**, not only a band around it.
- Penalise the **rate** (vertical speed), or the optimiser learns to pass through the goal.
- **Terminate** obviously bad behaviour early and charge for the lost time.
- Size failure penalties so that **trying is never worse than doing nothing**.

`hover-pid.json` is the same task with a hand-written controller structure and CMA-ES over its gains. It is a
useful baseline for judging whether the MLP is learning anything a PID could not.

## 13. Aero model in training (fast or full)

An experiment can carry `"aero": { "model": "fast" | "full", "cfd": { ... }, "toggles": { ... } }`
(`AeroRunSettings`, see `docs/CFD.md` §4). The CLI overrides are `--aero fast|full` and `--cfd-preset draft|medium|high|ultra`. Missing keys mean fast with
default toggles, so every existing experiment is unchanged. Full mode gives each worker its own CFD domain on the scalar sim (batch lanes forced to 1); it is about 3000× slower than fast, see `docs/CFD.md` §6 for measured throughput.
