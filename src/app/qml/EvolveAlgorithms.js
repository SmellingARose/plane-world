.pragma library
// EVOLVE step ④ in plain words: what each optimiser does, when to use it, its pros / cons, and a human label,
// explanation and "higher / lower" effect for every parameter in EvolveModel.algorithmSchema(kind)
// (evolvemodel.cpp schemaFor). Everything here describes src/core/src/evo/algos_*.cpp as implemented: change the
// text when the algorithm changes. Step sizes are "× gene step": each gene's own step (its sigma, else a tenth of its
// range); the neural goals give network weights a step of 0.5.

// ---- algorithms, in the order the picker lists them (unknown kinds from plugins are appended with their raw id)
const order = ["sep-cmaes", "cmaes", "ga", "openai-es", "simple-es", "neat", "map-elites", "novelty", "random", "script"]

const algorithms = {
    "sep-cmaes": {
        name: qsTr("sep-CMA-ES"),
        tagline: qsTr("Adapts its own step size. The best default for neural controllers."),
        how: qsTr("Samples candidates around a centre point, moves the centre towards the best half and learns how far to step in each gene. The step size grows while progress keeps going one way and shrinks as it homes in, so you only choose where it starts. \"sep\" means it learns one spread per gene (no correlations), which keeps it fast for hundreds or thousands of genes."),
        pros: [qsTr("Almost no tuning: the step size looks after itself"), qsTr("Fast and steady on network weights"), qsTr("Handles thousands of genes")],
        cons: [qsTr("Ignores links between genes (full CMA-ES learns them)"), qsTr("Can settle on a local best; restarts help on long runs")],
        bestFor: qsTr("Neural controllers (the presets use it)"),
        genes: qsTr("1000s"), step: qsTr("adapts"),
        family: "cma"
    },
    "cmaes": {
        name: qsTr("CMA-ES"),
        tagline: qsTr("Like sep-CMA-ES, but also learns how genes work together. Small genomes only."),
        how: qsTr("The full Covariance Matrix Adaptation evolution strategy: besides the step size, it learns which combinations of genes should change together (a tilted, stretched search cloud). That makes it the strongest choice on tricky, coupled problems, but its cost grows with the square of the gene count."),
        pros: [qsTr("Strongest on small, coupled problems (craft dimensions, PID gains)"), qsTr("Step size adapts automatically"), qsTr("Restarts make it a robust global search")],
        cons: [qsTr("Slow above a few hundred genes; refuses more than 400"), qsTr("Needs a few generations to learn the shape before it speeds up")],
        bestFor: qsTr("Under ~100 genes: designs, gains, small networks"),
        genes: qsTr("≤ 400"), step: qsTr("adapts"),
        family: "cma"
    },
    "ga": {
        name: qsTr("Genetic algorithm"),
        tagline: qsTr("Classic breeding: pick good parents, mix them, mutate. Suits craft dimensions."),
        how: qsTr("Keeps a population. Each generation the best few are copied unchanged (elitism), parents are picked by score, pairs are mixed gene by gene (crossover) and then a few genes are nudged at random (mutation). Mutation strength stays as you set it unless \"Adapt mutation\" is on."),
        pros: [qsTr("Easy to understand; every knob is visible"), qsTr("Copes with on/off and whole-number genes"), qsTr("Crossover can combine good parts of different designs")],
        cons: [qsTr("Many settings; fixed mutation can be too coarse or too fine"), qsTr("Slower than CMA-ES on network weights")],
        bestFor: qsTr("Craft design genes (the Craft design preset uses it)"),
        genes: qsTr("any"), step: qsTr("fixed or 1/5 rule"),
        family: "ga"
    },
    "openai-es": {
        name: qsTr("OpenAI-ES"),
        tagline: qsTr("Estimates the uphill direction from noisy samples and follows it, like gradient descent."),
        how: qsTr("Tests random pushes around a centre point (mirrored in pairs by default), uses the scores to estimate which way is uphill and moves the centre with the Adam optimiser. The push size (noise) stays fixed; the learning rate decides how far the centre moves each generation."),
        pros: [qsTr("Scales to very large networks"), qsTr("Smooth, predictable progress with big populations")],
        cons: [qsTr("Two settings to tune (noise and learning rate); nothing adapts"), qsTr("Needs large populations to beat CMA-ES")],
        bestFor: qsTr("Big networks with big populations"),
        genes: qsTr("10 000s"), step: qsTr("fixed"),
        family: "es"
    },
    "simple-es": {
        name: qsTr("Simple ES"),
        tagline: qsTr("Average the best, step around them, shrink the step as it improves. A baseline."),
        how: qsTr("Samples candidates around a centre, moves the centre to the weighted average of the best quarter and re-tests the best one found so far. The step size follows the 1/5 success rule: it grows when many candidates beat the best so far and shrinks when few do."),
        pros: [qsTr("Very simple, few settings"), qsTr("Self-adjusting step size")],
        cons: [qsTr("Same step for every gene"), qsTr("Usually slower than sep-CMA-ES")],
        bestFor: qsTr("A sanity check or baseline"),
        genes: qsTr("any"), step: qsTr("1/5 rule"),
        family: "es"
    },
    "neat": {
        name: qsTr("NEAT"),
        tagline: qsTr("Grows the network itself: starts tiny, adds neurons and links as needed."),
        how: qsTr("NeuroEvolution of Augmenting Topologies: every network starts with its inputs wired straight to its outputs (by default). Children may get a new connection or a new neuron, and similar networks form species that compete mostly among themselves, so new structures get time to improve before they must beat the leaders."),
        pros: [qsTr("Finds a network size for you"), qsTr("Species keep diversity, so it rarely gets stuck"), qsTr("Small, readable networks")],
        cons: [qsTr("Needs the NEAT network controller (step ②)"), qsTr("Many settings; slower on problems a fixed network solves")],
        bestFor: qsTr("Exploring which sensors and structure matter"),
        genes: qsTr("grows"), step: qsTr("fixed"),
        needs: qsTr("NEAT network controller (step ② ▸ Controller details)"),
        family: "neat"
    },
    "map-elites": {
        name: qsTr("MAP-Elites"),
        tagline: qsTr("Finds the best of many different styles of flying, not one winner."),
        how: qsTr("Quality-diversity: each flight is placed in a grid cell by how it behaved (the behaviour axes, for example final speed × height). Every cell keeps its best candidate, and new ones are bred from random cells, so the result is a map of good, different solutions."),
        pros: [qsTr("A whole map of different good solutions"), qsTr("Escapes dead ends by stepping through other cells")],
        cons: [qsTr("Needs behaviour axes and a descriptor() in the script"), qsTr("Spends effort on cells you may not care about")],
        bestFor: qsTr("Seeing what kinds of solution exist"),
        genes: qsTr("any"), step: qsTr("fixed"),
        needs: qsTr("behaviour axes (Advanced ▸ Behaviour axes) and a descriptor() in the script"),
        family: "qd"
    },
    "novelty": {
        name: qsTr("Novelty search"),
        tagline: qsTr("Rewards doing something new instead of scoring higher. Escapes deceptive goals."),
        how: qsTr("Scores each candidate by how different its behaviour is from its nearest neighbours (this generation plus an archive of past novel ones), optionally blended with the real score. Useful when chasing the score directly leads into a dead end."),
        pros: [qsTr("Escapes deceptive goals where the obvious path is a trap"), qsTr("Discovers surprising behaviours")],
        cons: [qsTr("Needs behaviour axes and a descriptor() in the script"), qsTr("Pure novelty ignores the score; blend some in")],
        bestFor: qsTr("Goals where the obvious path is a trap"),
        genes: qsTr("any"), step: qsTr("fixed"),
        needs: qsTr("behaviour axes (Advanced ▸ Behaviour axes) and a descriptor() in the script"),
        family: "qd"
    },
    "random": {
        name: qsTr("Random search"),
        tagline: qsTr("Every candidate is brand new and random. A yardstick, not a learner."),
        how: qsTr("Draws every candidate at random within the gene ranges and keeps the best ever seen. Nothing is learned from one generation to the next."),
        pros: [qsTr("No settings, no assumptions")],
        cons: [qsTr("Does not improve on what it found")],
        bestFor: qsTr("Checking the other methods really learn"),
        genes: qsTr("few"), step: qsTr("none"),
        family: "baseline"
    },
    "script": {
        name: qsTr("Your own (script)"),
        tagline: qsTr("Your ask() / tell() functions in the script decide everything."),
        how: qsTr("The JavaScript on the Script page proposes candidates (ask) and learns from their scores (tell). See docs/EVOLUTION.md §3.2 for the hooks."),
        pros: [qsTr("Complete control")],
        cons: [qsTr("You write and debug the algorithm")],
        bestFor: qsTr("Experimenting with new algorithms"),
        genes: qsTr("any"), step: qsTr("yours"),
        needs: qsTr("ask() and tell() in the script"),
        family: "script"
    }
}

function info(kind) {
    return algorithms[kind] || { name: kind, tagline: qsTr("A registered algorithm without a description."), how: "", pros: [], cons: [], bestFor: "", genes: "?", step: "?", family: "other" }
}
function name(kind) { return info(kind).name }
// Picker order: known kinds first (in `order`), then anything else the registry offers.
function ordered(kinds) {
    const k = kinds || []
    return order.filter(x => k.indexOf(x) >= 0).concat(k.filter(x => order.indexOf(x) < 0))
}
// What we would suggest for this experiment: GA for craft-design genomes, NEAT for NEAT controllers, else sep-CMA-ES.
function recommended(xp) {
    if (xp && xp.controller && xp.controller.mode === "neat") return "neat"
    if (xp && xp.genome && xp.genome.preset === "design") return "ga"
    return "sep-cmaes"
}
// "" when the experiment can run this algorithm, else why not (shown on the card).
function problem(kind, xp, genes) {
    if (kind === "cmaes" && genes > 400) return qsTr("%1 genes is too many for full CMA-ES (max 400); use sep-CMA-ES.").arg(genes)
    if (kind === "neat" && !(xp && xp.controller && xp.controller.mode === "neat")) return qsTr("Needs the NEAT network controller: step ② ▸ Controller details.")
    if ((kind === "map-elites") && !((xp && xp.descriptorAxes) || []).length) return qsTr("Needs behaviour axes (Advanced below) and a descriptor() in the script.")
    return ""
}

// ---- parameters. level: "common" (shown) or "expert" (folded). effect.up / effect.down: what raising / lowering does.
// auto: true = 0 means "automatic": the algorithm's own default applies (see autoValue()). The core treats a stored 0 like
// an absent key; the panel removes the key on 0 anyway so the saved file stays tidy.
// options: plain words for each choice value. unit is shown after the field.
const cmaParams = {
    sigma0: { label: qsTr("Starting step size"), level: "common", unit: qsTr("× gene step"), min: 0.001, max: 100, step: 0.05, decimals: 3,
              help: qsTr("How widely the first generation spreads around the starting point. 1 = one gene step (the gene's own step, or a tenth of its range); the neural goals give each weight a step of 0.5, so 0.5 here means a typical spread of 0.25. From then on CMA-ES grows or shrinks it by itself."),
              effect: { up: qsTr("explores further at first; takes longer to settle"), down: qsTr("starts by fine-tuning near the start; quick if the start is good, can get stuck") } },
    restarts: { label: qsTr("Restarts when stuck"), level: "common",
                help: qsTr("Once a search has fully converged (its step has shrunk to a millionth of a millionth of the start, its search cloud is 10 million times longer than wide, or every score for 10 + 30 × genes ÷ candidates generations is identical), start again from a new random point. That usually takes hundreds of generations, so restarts matter for long runs. The best candidate found is always kept."),
                options: { none: qsTr("Never: one long search; once it converges it keeps refining the same spot"),
                           ipop: qsTr("IPOP: restart with twice as many candidates each time; better at finding the overall best"),
                           bipop: qsTr("BIPOP: alternate big-population restarts with small ones using up to 100× finer steps; the most robust") },
                optionNames: { none: qsTr("Never"), ipop: qsTr("Bigger each time"), bipop: qsTr("Mixed sizes") } },
    lambda: { label: qsTr("Candidates per generation"), level: "expert", auto: true, min: 0, max: 100000, step: 4, decimals: 0,
              help: qsTr("Overrides Population for this method. 0 = use Population. IPOP / BIPOP restarts double it each time."),
              effect: { up: qsTr("steadier, more global search; each generation takes longer"), down: qsTr("faster generations; noisier, more local") } },
    mu: { label: qsTr("Parents"), level: "expert", auto: true, min: 0, max: 100000, step: 1, decimals: 0,
          help: qsTr("How many of the best candidates steer the next generation (weighted, best first). 0 = half of them."),
          effect: { up: qsTr("averages over more candidates: smoother, slower"), down: qsTr("follows the very best: greedier, can be fooled by a lucky flight") } }
}

const params = {
    "sep-cmaes": cmaParams,
    "cmaes": cmaParams,
    "ga": {
        mutation: { label: qsTr("Mutation type"), level: "common",
                    help: qsTr("How a gene is nudged."),
                    options: { gaussian: qsTr("Gaussian: a bell-curve step of Mutation strength"),
                               polynomial: qsTr("Polynomial: a bounded step that respects the gene's min / max; size set by Polynomial closeness") },
                    optionNames: { gaussian: qsTr("Gaussian"), polynomial: qsTr("Polynomial") } },
        mutationSigma: { label: qsTr("Mutation strength"), level: "common", unit: qsTr("× gene step"), min: 0, max: 100, step: 0.1, decimals: 3, usedWhen: { key: "mutation", value: "gaussian" },
                         help: qsTr("Size of a gaussian mutation, in gene steps. Fixed unless \"Adapt mutation\" is on."),
                         effect: { up: qsTr("bigger jumps: explores, but can wreck good candidates"), down: qsTr("fine-tuning: safe, but slow to find new ideas") } },
        mutationRate: { label: qsTr("Genes changed per child"), level: "common", auto: true, min: 0, max: 1, step: 0.01, decimals: 4,
                        help: qsTr("Chance that each gene is mutated. 0 = automatic: one gene per child on average (1 ÷ genes)."),
                        effect: { up: qsTr("changes many genes at once: more disruptive"), down: qsTr("changes few genes: careful, slower") } },
        adaptive: { label: qsTr("Adapt mutation"), level: "common",
                    help: qsTr("1/5 success rule. After each generation: if more than 1 child in 5 beat both its best parent and the previous median, strength grows ×1.22 and the per-gene chance ×1.1; otherwise they shrink ×0.85 and ×0.93. Strength stays within 0.0001–3, the chance within 0.5 ÷ genes – 0.5.") },
        elitism: { label: qsTr("Keep the best"), level: "common", unit: qsTr("candidates"), min: 0, max: 1000, step: 1, decimals: 0,
                   help: qsTr("The top N are copied unchanged into the next generation, so good candidates are never lost."),
                   effect: { up: qsTr("safer, but fewer new children each generation"), down: qsTr("more room to explore; 0 can lose the best") } },
        selection: { label: qsTr("Parent picking"), level: "common",
                     help: qsTr("How parents are chosen from the scored population."),
                     options: { tournament: qsTr("Tournament: draw a few at random, the best of them breeds. Steady; the usual choice"),
                                roulette: qsTr("Roulette: chance in proportion to score. Strong pull towards the leader"),
                                rank: qsTr("Rank: chance by position, not raw score. Gentle; ignores outliers") },
                     optionNames: { tournament: qsTr("Tournament"), roulette: qsTr("Roulette"), rank: qsTr("Rank") } },
        tournamentSize: { label: qsTr("Tournament size"), level: "expert", min: 1, max: 64, step: 1, decimals: 0, usedWhen: { key: "selection", value: "tournament" },
                          help: qsTr("Tournament picking only: how many random candidates compete for each parent slot."),
                          effect: { up: qsTr("stronger pull towards the best; diversity drops"), down: qsTr("more diversity; slower progress") } },
        crossover: { label: qsTr("Mixing method"), level: "expert",
                     help: qsTr("How two parents are combined into a child."),
                     options: { uniform: qsTr("Uniform: each gene from one parent or the other"),
                                "one-point": qsTr("One-point: genes up to a random point from one parent, the rest from the other"),
                                blend: qsTr("Blend (BLX-α): a random value around both parents' values"),
                                sbx: qsTr("SBX: children near the parents, spread set by SBX closeness; good for real numbers") },
                     optionNames: { uniform: qsTr("Uniform"), "one-point": qsTr("One-point"), blend: qsTr("Blend"), sbx: qsTr("SBX") } },
        crossoverRate: { label: qsTr("Mixing chance"), level: "expert", min: 0, max: 1, step: 0.05, decimals: 2,
                         help: qsTr("Chance a child mixes two parents; otherwise it is a mutated copy of one."),
                         effect: { up: qsTr("more recombination of good parts"), down: qsTr("more like pure mutation") } },
        blendAlpha: { label: qsTr("Blend spread (α)"), level: "expert", min: 0, max: 2, step: 0.05, decimals: 2, usedWhen: { key: "crossover", value: "blend" },
                      help: qsTr("Blend mixing only: how far beyond the two parents a child may land, as a fraction of their gap (0 = strictly between)."),
                      effect: { up: qsTr("explores outside the parents"), down: qsTr("stays between the parents") } },
        sbxEta: { label: qsTr("SBX closeness (η)"), level: "expert", min: 0, max: 200, step: 1, decimals: 1, usedWhen: { key: "crossover", value: "sbx" },
                  help: qsTr("SBX mixing only."),
                  effect: { up: qsTr("children very close to their parents"), down: qsTr("children spread further out") } },
        polyEta: { label: qsTr("Polynomial closeness (η)"), level: "expert", min: 0, max: 200, step: 1, decimals: 1, usedWhen: { key: "mutation", value: "polynomial" },
                   help: qsTr("Polynomial mutation only."),
                   effect: { up: qsTr("smaller steps"), down: qsTr("bigger steps, up to the whole range") } }
    },
    "openai-es": {
        sigma: { label: qsTr("Exploration noise"), level: "common", unit: qsTr("× gene step"), min: 0.0001, max: 100, step: 0.05, decimals: 3,
                 help: qsTr("How far each test candidate is pushed from the centre. Fixed for the whole run: it does not adapt."),
                 effect: { up: qsTr("smoother, coarser direction estimate"), down: qsTr("more precise but noisier") } },
        lr: { label: qsTr("Learning rate"), level: "common", unit: qsTr("× gene step"), min: 0.0001, max: 10, step: 0.01, decimals: 4,
              help: qsTr("How far the centre moves each generation. With Adam it moves roughly this many gene steps per gene."),
              effect: { up: qsTr("faster, but may overshoot and wobble"), down: qsTr("steadier, slower") } },
        antithetic: { label: qsTr("Mirrored pairs"), level: "expert",
                      help: qsTr("Test each random push in both directions (+ and −); cancels much of the noise. Population is rounded up to an even number.") },
        weightDecay: { label: qsTr("Weight decay"), level: "expert", min: 0, max: 1, step: 0.001, decimals: 4,
                       help: qsTr("Gently pulls every gene towards 0 each generation (L2), keeping networks small. 0 = off."),
                       effect: { up: qsTr("smaller, calmer networks; may under-fit"), down: qsTr("no pull") } },
        optimizer: { label: qsTr("Update rule"), level: "expert",
                     help: qsTr("How the estimated direction moves the centre."),
                     options: { adam: qsTr("Adam: adapts the step per gene; robust default"), sgd: qsTr("SGD: plain momentum (0.9)") },
                     optionNames: { adam: qsTr("Adam"), sgd: qsTr("SGD") } },
        fitnessShaping: { label: qsTr("Score shaping"), level: "expert",
                          help: qsTr("How scores are turned into weights."),
                          options: { rank: qsTr("Rank: only the order of scores matters; robust to outliers"), none: qsTr("None: standardised raw scores") },
                          optionNames: { rank: qsTr("Rank"), none: qsTr("Raw") } }
    },
    "simple-es": {
        sigma: { label: qsTr("Starting step size"), level: "common", unit: qsTr("× gene step"), min: 0.000001, max: 10, step: 0.05, decimals: 3,
                 help: qsTr("Spread of candidates around the centre at the start. Then the 1/5 rule adjusts it: ×1.22 when more than 1 in 5 candidates beat the best so far, ×0.85 otherwise (kept within 0.000001–10)."),
                 effect: { up: qsTr("explores further at first"), down: qsTr("fine-tunes near the start") } },
        elite: { label: qsTr("Keep the best"), level: "common",
                 help: qsTr("Re-test the best candidate found so far in every generation.") },
        mu: { label: qsTr("Parents averaged"), level: "expert", auto: true, min: 0, max: 100000, step: 1, decimals: 0,
              help: qsTr("How many of the best candidates are averaged into the new centre. 0 = a quarter of them."),
              effect: { up: qsTr("smoother, slower"), down: qsTr("greedier") } }
    },
    "neat": {
        compatThreshold: { label: qsTr("Species distance"), level: "common", min: 0.1, max: 100, step: 0.1, decimals: 2,
                           help: qsTr("How different two networks must be (in extra / missing links and weight differences) to count as separate species."),
                           effect: { up: qsTr("fewer, bigger species"), down: qsTr("more, smaller species: more diversity") } },
        addNodeRate: { label: qsTr("Add-neuron chance"), level: "common", min: 0, max: 1, step: 0.01, decimals: 3,
                       help: qsTr("Chance per child to split a connection with a new neuron: how fast networks grow."),
                       effect: { up: qsTr("grows bigger networks quickly"), down: qsTr("stays small and simple") } },
        addConnRate: { label: qsTr("Add-link chance"), level: "common", min: 0, max: 1, step: 0.01, decimals: 3,
                       help: qsTr("Chance per child to add a new connection."),
                       effect: { up: qsTr("wires more sensors in quickly"), down: qsTr("sparser networks") } },
        targetSpecies: { label: qsTr("Target species"), level: "expert", auto: true, min: 0, max: 1000, step: 1, decimals: 0,
                         help: qsTr("If set, the species distance is nudged each generation to keep about this many species. 0 = off.") },
        weightMutateRate: { label: qsTr("Weight change chance"), level: "expert", min: 0, max: 1, step: 0.05, decimals: 2,
                            help: qsTr("Chance per child that its weights are nudged (each weight then has a 10% chance to be replaced instead).") },
        weightPerturbSigma: { label: qsTr("Weight nudge size"), level: "expert", min: 0, max: 10, step: 0.05, decimals: 3,
                              help: qsTr("Size of each weight nudge. Fixed for the run."),
                              effect: { up: qsTr("bolder changes"), down: qsTr("finer tuning") } },
        survivalThreshold: { label: qsTr("Breeders per species"), level: "expert", min: 0, max: 1, step: 0.05, decimals: 2,
                             help: qsTr("Fraction of each species, best first, allowed to breed."),
                             effect: { up: qsTr("more diversity"), down: qsTr("stronger selection") } },
        stagnation: { label: qsTr("Species patience"), level: "expert", unit: qsTr("gens"), min: 1, max: 1000, step: 1, decimals: 0,
                      help: qsTr("Generations a species may go without improving before it is removed (the two best species are always kept).") }
    },
    "map-elites": {
        isoSigma: { label: qsTr("Mutation strength"), level: "common", unit: qsTr("× gene step"), min: 0, max: 100, step: 0.05, decimals: 3,
                    help: qsTr("Random nudge given to every gene of a child. Fixed for the run."),
                    effect: { up: qsTr("reaches far-away cells"), down: qsTr("improves cells already found") } },
        lineSigma: { label: qsTr("Line step"), level: "common", min: 0, max: 10, step: 0.05, decimals: 3,
                     help: qsTr("Also steps along the line between two random elites; shrinks naturally as elites become alike. 0 = off."),
                     effect: { up: qsTr("bolder jumps between styles"), down: qsTr("mostly random nudges") } },
        initialRandom: { label: qsTr("Random start"), level: "expert", auto: true, min: 0, max: 100000, step: 8, decimals: 0,
                         help: qsTr("Purely random candidates to try before breeding from the map. 0 = one population's worth.") },
        cvt: { label: qsTr("Evenly spread cells"), level: "expert", min: 0, max: 100000, step: 10, decimals: 0,
               help: qsTr("0 = a regular grid from the behaviour axes. N = N cells spread evenly (CVT); better with 3 or more axes.") }
    },
    "novelty": {
        fitnessWeight: { label: qsTr("Score blend"), level: "common", min: 0, max: 1, step: 0.05, decimals: 2,
                         help: qsTr("0 = pure novelty (the score is ignored when choosing parents), 1 = pure score; in between blends their ranks."),
                         effect: { up: qsTr("chases the goal more"), down: qsTr("chases new behaviour more") } },
        k: { label: qsTr("Neighbours compared"), level: "common", min: 1, max: 1000, step: 1, decimals: 0,
             help: qsTr("Novelty = average behaviour distance to this many nearest others (this generation plus the archive)."),
             effect: { up: qsTr("judges novelty more globally"), down: qsTr("more local") } },
        mutationSigma: { label: qsTr("Mutation strength"), level: "expert", unit: qsTr("× gene step"), min: 0, max: 100, step: 0.1, decimals: 3,
                         help: qsTr("Gaussian nudge size. Fixed for the run.") },
        archiveAddProbability: { label: qsTr("Random archive chance"), level: "expert", min: 0, max: 1, step: 0.01, decimals: 3,
                                 help: qsTr("Candidates more novel than a self-tuning threshold always join the archive; this adds a random chance for any candidate.") }
    }
}

// Plain-language metadata for one parameter (falls back to the raw key and the C++ one-line help).
function param(kind, key, fallbackHelp) {
    const p = (params[kind] || {})[key]
    return p || { label: key, level: "expert", help: fallbackHelp || "" }
}
// The schema rows for `kind` at `level` ("common" / "expert"), in the order of `params[kind]` (most useful first),
// then any keys this file does not describe (expert).
function rows(kind, schema, level) {
    const keys = Object.keys(params[kind] || {}), at = s => { const i = keys.indexOf(s.key); return i < 0 ? keys.length : i }
    return (schema || []).filter(s => param(kind, s.key).level === level).sort((a, b) => at(a) - at(b))
}
// "" when the parameter is in effect, else which setting switches it off (`vals` = experiment.algorithm.values).
function unusedBecause(kind, key, vals, schema) {
    const w = param(kind, key).usedWhen
    if (!w) return ""
    const row = (schema || []).find(s => s.key === w.key), v = vals && vals[w.key] !== undefined ? String(vals[w.key]) : (row ? String(row["default"]) : "")
    if (v === w.value) return ""
    const p = param(kind, w.key)
    return qsTr("Not used while %1 is %2.").arg(p.label).arg((p.optionNames || {})[v] || v)
}
// What an "automatic" (0) parameter currently resolves to, as the algorithm computes it.
// `vals` = the stored parameters (experiment.algorithm.values).
function autoValue(kind, key, xp, vals, genes) {
    const pop = Math.max(2, (xp && xp.population) || 2), a = vals || {}
    const lam = Math.max(4, a.lambda > 0 ? Math.trunc(a.lambda) : pop)
    if (key === "lambda") return lam
    if (key === "mu") return kind === "simple-es" ? Math.max(1, Math.floor(pop / 4)) : Math.max(1, Math.floor(lam / 2))
    if (key === "mutationRate") return genes > 0 ? +(1 / genes).toPrecision(2) : undefined
    if (key === "initialRandom") return pop
    return undefined
}

// ---- how the step size changes, in numbers for this experiment. Returns { title, text } or null.
// CMA-ES uses cumulative step-size adaptation: sigma *= exp(cs / damps * (|ps| / E|N(0,I)| - 1)) every generation,
// so the fastest it can shrink is exp(-cs / damps) per generation (when successive steps cancel out completely).
function cmaRates(genes, lambda, mu) {
    const N = Math.max(1, genes), m = Math.max(1, Math.min(lambda, mu > 0 ? Math.trunc(mu) : Math.floor(lambda / 2)))
    let w = [], ws = 0
    for (let k = 0; k < m; ++k) { w.push(Math.log(m + 0.5) - Math.log(k + 1)); ws += w[k] }
    let sq = 0
    for (const x of w) sq += (x / ws) * (x / ws)
    const mueff = 1 / sq
    const cs = (mueff + 2) / (N + mueff + 5)
    const damps = 1 + 2 * Math.max(0, Math.sqrt((mueff - 1) / (N + 1)) - 1) + cs
    return { halve: Math.LN2 * damps / cs }
}
function fmtGens(g) { return g < 10 ? g.toFixed(1) : String(Math.round(g)) }

function stepStory(kind, xp, vals, genes) {
    const a = vals || {}
    if (kind === "cmaes" || kind === "sep-cmaes") {
        const lam = autoValue(kind, "lambda", xp, vals, genes), r = cmaRates(genes, lam, a.mu)
        return { title: qsTr("Step size: automatic"),
                 text: qsTr("You set where it starts; CMA-ES then grows the step while successive moves keep pointing the same way and shrinks it when they zig-zag (it is homing in). With %1 genes and %2 candidates per generation it can at most halve every %3 generations, so it settles gradually rather than collapsing.")
                     .arg(genes).arg(lam).arg(fmtGens(r.halve)) }
    }
    if (kind === "simple-es")
        return { title: qsTr("Step size: 1/5 success rule"),
                 text: qsTr("Every generation the step grows ×1.22 if more than 1 candidate in 5 beat the best so far, otherwise it shrinks ×0.85: it halves after about 4 generations without progress and doubles after about 3.5 good ones.") }
    if (kind === "ga")
        return a.adaptive ? { title: qsTr("Mutation: adapting (1/5 rule)"),
                              text: qsTr("After a generation where more than 1 child in 5 beat its parents (and the previous median), mutation strength grows ×1.22 and the per-gene chance ×1.1; otherwise they shrink ×0.85 and ×0.93. Strength halves after about 4 poor generations and doubles after about 3.5 good ones.") }
                          : { title: qsTr("Mutation: fixed"),
                              text: qsTr("Mutation strength stays exactly as set for the whole run. Turn on \"Adapt mutation\" to let it shrink as the population converges (and grow while it keeps improving).") }
    if (kind === "openai-es")
        return { title: qsTr("Step size: fixed"),
                 text: qsTr("The exploration noise never changes. Adam adapts how far the centre moves per gene, scaled by the learning rate; lower the learning rate if the best score wobbles.") }
    if (kind === "neat" || kind === "map-elites" || kind === "novelty")
        return { title: qsTr("Step size: fixed"), text: qsTr("Mutation sizes stay as set for the whole run; diversity (species, cells or novelty) does the exploring.") }
    return null
}
