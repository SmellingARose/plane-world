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
| Run, checkpoints, export, replay, behaviours, FLY pilots (`EvolutionRun`, `exportCraft`, `behaviours`, `EvolvedAutopilot`, `LivePilot`) | `src/core/pw/evo/run.h:91`, `:139`, `:64`, `:192`, `:216` |
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
3. **Hover trim** (rotor and rocket crafts, MLP controllers): the output biases of throttle outputs (motor, jet,
   rocket) start at the hover throttle instead of 0, so the first generation can hold height (a network with all
   weights 0 outputs its biases, and 0 is mid-range: 50 % throttle, below New Shepard's ~76 %, so every first
   candidate fell or never left the pad). The hover throttle is measured in the sim at the start height: the craft
   is held still and the throttle bisected until total thrust equals weight (props: power ∝ throttle and static
   thrust ∝ power^(2/3), so the Racer quad at T/W 9.5 trims to ≈ 3.4 %). Only genes still at 0 change (a
   `genome()` that set a value wins); planes and the parity references are unchanged
   (`ExperimentContext::hoverTrimGenes`, `evolution.hover-trim`).
4. **Angle mode** (`controller.assist: "angle"`, MLP controllers on crafts with a built-in flight controller): the
   network flies the craft like a FLY pilot in angle mode instead of driving the motors / engine itself. Its first
   outputs are the sticks of the multirotor controller (`MultirotorFC`: climb, yaw, pitch, roll) or the rocket
   controller (`RocketFC`: climb, pitch, yaw), then one per selected control the flight controller doesn't drive.
   Each stick is −1…1: pitch / roll tilt up to the controller's limit (35° drone, 20° rocket) and self-level when
   centred, climb commands a climb rate (6 m/s drone, 5 m/s rocket) around a hover throttle the loop learns in
   flight (started at the measured one), so centred sticks hold the height; landed with the climb stick at or below
   centre, the motors / engine are off. The standard sensors have no horizontal velocity, so the controller also
   leans against drift (0.04 tilt sine per m/s): centred sticks hover in place. The sticks start centred (no hover
   trim; a directly driven throttle still trims). It applies only when the network was given every control the
   flight controller drives (else it is ignored), and the drone controller needs ≥ 100 Hz (it limit-cycles below; FLY
   runs it at 240 Hz). Choosing a drone or rocket in the craft picker turns it on (and a drone's control rate up to
   200 Hz); Set up › Controller details has the check box. FLY's autopilot rebuilds the training context, so the
   exported controller flies the same way (a controller that can't rebuild it refuses to start rather than misfly).
   (`EvalWorker::applyNativePolicy`, `evolution.angle-assist`.)

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

There is one source string, `scripts.source`. Every function is optional. An experiment built with EVOLVE goal blocks
(§6) also stores the block program as `scripts.blocks`; the core ignores it and runs the generated `source`.

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
  speed and wings level, with a crash penalty of −20 plus 2 per second not flown (so crashing early never pays).
  `sep-cmaes`. The native preset runtime recognises the script; the pre-2026-10 version (flat −20, e.g. the parity
  experiments and older saved files) is the preset kind `neural-v1`, kept bit-identical.
- **Craft design:** wing span and chord (mirrored), wing x and stabilator span, flown by a JS PID autopilot. `ga`.
- **Co-evolve design + controller:** wing span and chord plus MLP weights. `sep-cmaes`.

Crafts without sensors get the standard set: `alt` (AGL), `att`, `rate`, `air`, `vs`, `aero`.

## 4. Algorithms

All maximise `Fitness.total`, draw randomness only from their checkpointed RNG, and must save and restore state
bit-identically (`evolution.run-checkpoint-resume`). Failed candidates score −1e12.
Parameters documented "0 = automatic" (`lambda`, `mu`, `mutationRate`, `initialRandom`) treat a stored 0 exactly like
an absent key (`evolution-algo.zero-means-automatic`). Hooks (`select`, `crossover`,
`mutate`) are consulted where the step exists.

| Kind | Parameters (`algorithm.values`; defaults) |
|---|---|
| `ga` | `selection` tournament\|roulette\|rank (tournament), `tournamentSize` 3, `elitism` 2, `crossover` uniform\|one-point\|blend\|sbx (sbx), `crossoverRate` 0.9, `blendAlpha` 0.5, `sbxEta` 15, `mutation` gaussian\|polynomial (gaussian), `mutationRate` 1/n (0 = 1/n), `mutationSigma` 1 (× gene scale, gaussian only), `polyEta` 20, `adaptive` false (1/5 rule: sigma ×1.22 / ×0.85, rate ×1.1 / ×0.93) |
| `cmaes` | `sigma0` 1 (× gene scale; then cumulative step-size adaptation), `lambda` population (0 = population), `mu` λ/2 (0 = λ/2), `restarts` none\|ipop\|bipop (none; trigger on tolX / conditionCov / tolFun / numerical) |
| `sep-cmaes` | as `cmaes`, diagonal covariance (genomes over ~200 genes; `cmaes` refuses more than 400) |
| `openai-es` | `lr` 0.05, `sigma` 0.5 (fixed), `antithetic` true, `weightDecay` 0, `optimizer` adam\|sgd, `fitnessShaping` rank\|none |
| `simple-es` | `sigma` 1 (1/5 rule: ×1.22 / ×0.85), `mu` λ/4 (0 = λ/4), `elite` 1 |
| `random` | baseline (no parameters) |
| `neat` | `compatThreshold` 3, `targetSpecies` 0, `addNodeRate` 0.03, `addConnRate` 0.05, `weightMutateRate` 0.8, `weightPerturbSigma` 0.5, `survivalThreshold` 0.2, `stagnation` 15; the rest at the top of the NEAT class in `algos_qd.cpp`; species reported every generation; flat genes (co-evolution) get Gaussian steps |
| `map-elites` | archive over `descriptorAxes` (name, min, max, bins); `initialRandom` population (0 = population), `isoSigma` 0.5, `lineSigma` 0.2, `cvt` 0 (grid); candidates without a descriptor get no cell |
| `novelty` | k-NN novelty over descriptors with an archive: `k` 15, `fitnessWeight` 0, `archiveAddProbability` 0, `mutationSigma` 1 |
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
| `velocity` | `forward right` (m/s) | horizontal ground velocity along / across the heading (drift; like GPS or optical flow) |

`p.noise` adds deterministic uniform noise (σ) to non-boolean channels, seeded at reset.

**Standard sensors** (`presets::addStandardSensors`, every EVOLVE craft): `alt` (altitudeAGL), `att`, `rate`, `air`,
`vs`, `aero` and `vel` (velocity), each added only if the craft has none of that kind. `vel` is always massless, so a
craft that gets the whole set keeps the mass its reference histories were recorded with. Switching to a drone or rocket
(angle mode) adds `vel.forward` / `vel.right` to the network's inputs, scaled so 10 m/s reads as 1: without them a
hover cannot see, and so cannot stop, a sideways drift (`evolution.velocity-sensor`).

## 6. EVOLVE tab

`src/app/qml/EvolvePanel.qml` with `src/app/evolvemodel.cpp`: preset menu, craft picker, training worlds, headless
options, genome and MLP spec, design-gene table, algorithm form, the goal as blocks or JavaScript (error-line
marking), run controls (start, stop, resume), live charts (best/mean/median, per term, species, archive heatmap,
throughput), replay of any generation or archive cell in the viewport, and export of a craft with its controller
embedded. FLY offers "Autopilot from evolved controller" for such crafts. Pages: Set up (steps 1–4), Train (5–6),
Goal (Alt+1..3). Step ① also holds how each flight starts (length, runway or air start); step ④ is only the search
(population, generations, method).

**Craft picker** (① Craft & worlds) calls `EvolveModel::setCraft`, which re-fits the experiment to the new craft
(`evo::switchCraft`, `src/core/src/evo/experiment.cpp`): MLP / NEAT inputs the craft lacks are dropped, and if any
selected output is missing the controller drives every control of the new craft (a plane's `Ailerons` mean nothing
to New Shepard, and a partial list would leave controls undriven). Design genes for parts the craft lacks are dropped too; a Craft / Both
experiment left with none evolves the mass of the new craft's heaviest part (±50 %). If the goal is a preset that
doesn't suit the new craft (see craft kinds below), it becomes that kind's preset (planes: Hold, drones and rockets:
Hover at the air-start height, ground vehicles: Drive); your own blocks and hand-written scripts are kept, and so
is how each flight starts. An MLP controller flies a drone or rocket in angle mode (§2; a drone at ≥ 200 Hz) and
any other craft directly. A name ending in the old craft's name follows the new one, and the status bar lists what
changed.

**Wiring canvas** (② What evolves › Sensors → controls, `src/app/qml/WiringCanvas.qml`): the controller's inputs
and outputs as an n8n-style node graph — the craft's sensors (plain name, raw channel id, unit, a ÷ scale field) on
the left, the controller (MLP neurons and hidden layers, or NEAT / script) in the middle, the craft's controls (kind
and range, or rotor position and spin for multirotors) on the right, with a curved wire for each one in use. Click a
node or its port (or Tab to it and press Space) to wire it in or out (`EvolveModel::toggleIO`); drag a port onto the
controller to connect, or a wired port away to disconnect. Columns lay themselves out to the inspector width and
scroll inside the section; the controller stays in view while you scroll the sensors. No controls or no sensors
turns the controller red with a message, and a mis-wired document shows its error with "Re-wire for <craft>". The
Goal page's wiring card ("Change") and the palette entry "EVOLVE: show controller wiring" open it.

**Craft kinds** (`evo::craftKind`, `evolution.craft-kind`): rocket (rocket or solid motor), rotor (propellers
pushing up that can lift it, e.g. multirotors and the ducted tail-sitter), plane (wings), ground (wheels), else
other. Presets are by craft: the three preset lists (Set up › ③ Goal, the Goal page's "Start from…" and the JavaScript
view's "Start from…") show only the presets that suit the craft, plus the goal in use even when it is for another
kind; "Show presets for other crafts" (a check box under ③'s list, a menu entry in both menus) adds the rest, faded,
with who they are for. An "other" craft sees every preset. By kind: planes — Hold a height, Fly to a target, Fly as
far as possible, Take off and climb, Hold a speed and heading; drones — Hover, Fly to a target, Hold position in
wind; rockets — Hover, Hop and land softly; ground vehicles — Drive to a point, Drive fast without flipping. A document that still names controls or sensors the craft lacks
(an opened file, a hand edit) shows the problem under the craft picker, with a "Re-wire for <craft>" button, instead
of failing at Start
(`evolution.switch-craft-rewires`, pwuitests "goal blocks").

**Goal blocks** (Goal page, `EvolveBlockEditor.qml` + `EvolveBlocks.js`): the reward script as stacked blocks that
read as sentences, compiled to JavaScript on every edit. Top to bottom: the wiring (sensors → controller →
controls, from the craft), an optional target point (ahead / to the side of the start), scores every second ("Stay
near", "More is better, up to", "Earn for every", "Penalise while below / above", "Get closer to the target", "Stay
over the start", each with a weight), reasons to end the flight early (crash, target reached, tipped over, too low,
too high, hasn't taken off by N s — ground contact, so a rocket standing on its legs counts), one-off points when the flight ends (optionally plus a bonus for time left, or "charge the seconds it didn't fly":
the sum of the per-second weights for every second left, so crashing early never beats flying on; every preset
uses it, and the Neural preset script (= Hold) does the same natively — without it, New Shepard learned to cut the
engine and dive. Experiments saved with the older flat −20 open as Hold, "edited", with an update offer), and a custom-code block for
anything else (helpers, `control()`, `descriptor()`). Two signals keep per-flight memory (a signal's `init` /
`update` code in `EvolveBlocks.js`, emitted only when a term uses it): "highest height so far" and "turn from the
start heading" (−180…180°). Set up › ③ Goal picks a preset (each is a block program, tagged with the craft kinds it
suits), shows its one main setting (hover height, target distance, top speed…) and lists in plain language how it
scores and when a flight ends. "Hold" at 150 m compiles
to the Neural-controller preset script verbatim, so the native fast path still applies. The JavaScript view shows
what the blocks generate; editing it there marks the goal "edited": training uses the edited script and the blocks
are shown faded until you "Discard my edits" (back to the blocks) or "Keep my edits" (drop the blocks). A hand-written script that blocks can't represent stays JavaScript; "Start from…"
replaces it with a preset or an empty goal. Scripts written by the earlier goal picker (`// Goal: <id> <param>`) open
as their preset's blocks.

Hover is tuned for drones and rockets from either start: "still" (sideways speed near 0, soft: half the penalty at
10 m/s, more the faster, so an air start at 35 m/s still has a slope) keeps it over the start, "drift" (distance
from the start, full at 100 m) is a light backstop, and "hasn't taken off by 3 s" ends the flight with −20 plus the
per-second charge, so sitting on the pad is as bad as crashing (before it, New Shepard from a runway start sat still
for 40 generations). Hover and Hold position in wind learn within the quick start's 40 generations because drones
and rockets fly in angle mode (§2): unassisted, nearly every New Shepard candidate tipped over and the Racer quad
flipped within 2 s (§10). A "Stay near" block's "soft" check makes its penalty off / (off + range) instead of
min(off / range, 1).

The other presets (setting in brackets; every crash / flip / never-took-off end charges the seconds not flown):

| Preset | Craft | Scores |
|---|---|---|
| Take off and climb (height, 300 m) | plane | height up to the setting (1/s), airspeed up to 40 m/s (0.3/s, starts the take-off roll from gen 0), wings level (0.5/s); still below 3 m after 25 s ends it like a crash |
| Hold a speed and heading (airspeed, 40 m/s) | plane | airspeed near the setting (full penalty at ±half of it), turn from the start heading (full at 90°, 0.5/s), wings level, penalised below 20 m once above; best from an air start |
| Hold position in wind (height, 10 m) | drone | Hover on a short leash: height, distance from the start (full at 10 m, weight 1), sideways speed (full at 5 m/s), upright; wind is Set up › Advanced (Wind max, Turbulence) |
| Hop and land softly (height, 30 m) | rocket | highest height so far up to the setting (1/s, kept after coming down), height now (−0.5/s at the setting, so landing beats hovering), sinking faster than 3 m/s, upright; a touchdown above the experiment's crash speed is a crash |
| Drive fast without flipping (top speed, 15 m/s) | ground | ground speed up to the setting (1/s, any direction), tilt (0.25/s); tipping past 70° ends it |

**Saved presets** ("Save as preset…" on the Goal page header, shown while the goal is blocks): names the current
block program and stores it as `<experiment library>/goal-presets/<name>.json` (`{ name, suits, program }`; the same
name replaces it) through `EvolveModel::saveGoalPreset`; `goalPresets` lists them and `removeGoalPreset` deletes one.
It is saved for the current craft kind (an "other" craft: every craft) and appears in the preset lists after the
built-in ones as "<name>  (yours)", without a setting. The × in ③'s list, or next to "Save as preset…" while it is the
goal in use, deletes it (the goal keeps its blocks). A craft switch never replaces a saved preset goal.

**Training worlds** (`TrainingWorlds.qml`, ① Craft & worlds): a list of the worlds every candidate is tested in.
"+ Add a world" and each row's "Change" offer flat ground, the open world (as it is in WORLD when training starts),
any saved world, an embedded copy of the open world, or a world file elsewhere. With several worlds, "Each
generation" picks every world, one in turn, or a random set (the same for every candidate), and the panel shows how
many flights that makes per candidate. The replay caption names the world the replayed episode flew in.

**Algorithm** (④, `AlgorithmSettings.qml`, words in `EvolveAlgorithms.js`): the optimiser is a card with a plain name,
what it does and a "Recommended" badge (sep-CMA-ES; GA for craft-design genomes; NEAT for NEAT controllers); "Choose
a different method" lists every registered kind as cards, each with ⓘ (how it works, good at / watch out / best for /
genes / step size / needs) and a warning when the experiment cannot run it (cmaes over 400 genes, NEAT without the NEAT
controller, MAP-Elites without axes), with a one-click fix under it ("Use sep-CMA-ES", "Switch the controller to
NEAT", "Add a behaviour axis"; the fix also picks that method). "Compare all" (`AlgorithmCompare.qml`) shows them in one table. The folded
"Tune …" section starts with how the step size changes, with this experiment's numbers (CMA-ES: at most halves every
ln 2 · damps / c_σ generations; the 1/5 rules; fixed), then each parameter of `EvolveModel.algorithmSchema` with a
plain label (raw key on hover), unit, explanation, higher / lower effect and ↺ default; settings another setting
switches off are dimmed, "0 = automatic" fields show the value they resolve to, and expert ones are folded. Parameter
keys and defaults in `schemaFor` (`evolvemodel.cpp`) are the ones the algorithms read; edits go to
`algorithm.values.<key>` and ↺ removes the key. Palette: "EVOLVE: show algorithm settings (step size, mutation…)", "EVOLVE: compare algorithms
(CMA-ES, GA, NEAT…)".

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
  unknown keys are ignored; `version` is 1. Exception: an `algorithm` entry that is not an object with a `kind`
  string and a `values` object refuses to load and says how to fix it (it used to fall back to Simple ES silently). `scripts.blocks` (optional) is the goal-block program behind
  `scripts.source`.
- Runs: `run.json` (experiment, craft, layout, terms, history, hall of fame), `algorithm.state`, `archive.json`.
  Checkpoints are written every `checkpointEvery` generations and on stop. Resume requires the same layout.
- Exported craft: a normal craft JSON with a top-level `"behaviours"` array; each entry is `{ name, key, controller }`
  and `controller` holds mode, hz, script, layout, genome, names, MLP spec, fitness and the training experiment
  (crafts dropped, world flat). Format and key rules: docs/CRAFTS.md › Behaviours. Crafts exported before behaviours
  carry one `"evolvedController"` on their first part; they read as one behaviour on O.
- Train › Results › "Add to craft as a behaviour…" (`EvolveModel::addBehaviour`): name (default: the goal preset in
  short words, e.g. "Hover", else the experiment's name), key (a free one suggested; FLY's keys are refused and
  listed) and target: the experiment's saved craft (updated in the library), another saved craft, or a new copy
  (the only choice when the run reshapes the craft). "Add and fly" then opens it in FLY with the behaviour flying.
- FLY flies a behaviour with `LivePilot` (`src/core/pw/evo/run.h:216`): the experiment context rebuilt on the flight
  craft and `EvalWorker::bindLive`, the code training uses, so it flies bit-identically to EVOLVE's own context
  (`evolution.behaviours`). If the craft no longer matches the trained genes it falls back to `EvolvedAutopilot`.

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
- `--out` gets `history.csv` (with `best_<term>` columns), the checkpoint files and `best-craft.json` (the best candidate
  as a behaviour named after the experiment: open it and press its key in FLY).
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

- **Let the craft balance before the network learns the task.** Hover with a network driving New Shepard's engine
  and gimbals, or the Racer quad's four motors, failed in the 40-generation quick start: nearly every candidate
  tipped over or flipped (the quad within 2 s: its motors hover at 3.4 % throttle, so a small weight change shifts
  a rotor's thrust by tens of percent, and any bias difference between motors is a constant torque). Smaller steps
  (`sigma0` 0.1) and longer runs got the quad there — a level hover after 60–130 generations at 50–200 Hz, with a
  third of each generation still crashing — but New Shepard only learned to survive by climbing away (30–75 m) and
  drifting 80–400 m. A faster control rate alone did not help the unassisted quad. Flying the network in angle mode
  (§2) made generation 0 crash-free for both: the quad holds 10 m within ±0.3 m and 1 m of the start by generation
  10–15 (median −5 by 40), and New Shepard climbs off the pad to 20–28 m, upright, with the median −60 → −11…−17 in
  40 generations.
- **Don't score what the network can't sense.** "still" and "drift" need horizontal velocity, which the standard
  sensors lack. Angle mode's drift lean helps (an 8 m/s start stops within 13 m), but a stick offset the network
  hasn't learned to centre leaves a steady drift of offset × tilt limit / 0.04 m/s: the 40-generation New Shepard
  hovers drifted 10–50 m. A stronger lean (0.1) makes New Shepard's slow attitude loop limit-cycle (±17°).

`hover-pid.json` is a useful baseline for judging whether an MLP learns anything a PID could not.
