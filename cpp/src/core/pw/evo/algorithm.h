#pragma once
// Ask/tell optimiser contract and the built-in algorithms (ports of Sources/Evolution/Algorithms/*.swift and
// Core/Algorithm.swift). Per generation the run calls:
//     pop = algo.ask();  fit = evaluator.evaluate(pop);  algo.tell(pop, fit);
// Algorithms run on one thread only and draw randomness ONLY from their EvoRNG (state is checkpointed), so a
// given seed reproduces the Swift app's populations bit for bit (same libm), and `restore(saveState())`
// continues identically.
//
// Kinds: "random", "simple-es", "ga", "cmaes", "sep-cmaes", "openai-es", "neat", "map-elites", "novelty".
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>
#include "pw/evo/types.h"

namespace pw::evo {

/// Optional user operators (JS select/crossover/mutate). Each returns false to defer to the built-in operator.
class AlgorithmHooks {
public:
    virtual ~AlgorithmHooks() = default;
    virtual bool select(const std::vector<Genome>& pop, const std::vector<Fitness>& fit, int count, EvoRNG& rng, std::vector<int>& out) { return false; }
    virtual bool crossover(const Genome& a, const Genome& b, const GenomeLayout& layout, EvoRNG& rng, std::vector<double>& out) { return false; }
    virtual bool mutate(const Genome& g, const GenomeLayout& layout, double rate, EvoRNG& rng, std::vector<double>& out) { return false; }
};

class Algorithm {
public:
    virtual ~Algorithm() = default;
    virtual const char* kind() const = 0;
    /// Generations completed (number of tell calls).
    virtual int generation() const = 0;
    virtual std::vector<Genome> ask() = 0;
    virtual void tell(const std::vector<Genome>& genomes, const std::vector<Fitness>& fitness) = 0;
    /// Best ever (for MAP-Elites the best elite); nullptr before the first tell.
    virtual const Genome* bestGenome() const = 0;
    virtual const Fitness* bestFitness() const = 0;
    virtual const EliteArchive* archive() const { return nullptr; }
    virtual std::vector<SpeciesInfo> species() const { return {}; }
    virtual std::map<std::string, double> diagnostics() const { return {}; }
    /// Full internal state incl. RNG as JSON text; restore on a fresh instance (same layout/params) continues identically.
    virtual std::string saveState() const = 0;
    virtual void restore(const std::string& state) = 0;
    /// Distribution mean in gene space (CMA-ES family / OpenAI-ES), empty otherwise.
    virtual std::vector<double> meanValues() const { return {}; }
    AlgorithmHooks* hooks = nullptr;   // not owned
};

using AlgorithmFactory = std::function<std::unique_ptr<Algorithm>(const GenomeLayout&, const AlgorithmParams&, int population, uint64_t seed)>;

namespace registry {
/// Builds an algorithm by params.kind; throws EvoError for unknown kinds / invalid params.
std::unique_ptr<Algorithm> make(const AlgorithmParams& params, const GenomeLayout& layout, int population, uint64_t seed);
/// Extra kinds at runtime (e.g. "script" from the script runtime).
void registerKind(const std::string& kind, AlgorithmFactory f);
std::vector<std::string> kinds();
}

// MARK: - operators (Operators.swift)

enum class SelectionMethod : uint8_t { Tournament, Roulette, Rank };
enum class CrossoverMethod : uint8_t { Uniform, OnePoint, Blend, SBX };
enum class MutationMethod : uint8_t { Gaussian, Polynomial };

namespace ops {
/// Ranking score: failed / non-finite candidates become the worst.
inline double score(const Fitness& f) { return std::isfinite(f.total) ? f.total : kFailedFitness; }
std::vector<double> scores(const std::vector<Fitness>& f);
/// Indices best-first (ties keep population order).
std::vector<int> rankOrder(const std::vector<double>& s);
std::vector<int> select(SelectionMethod m, const std::vector<double>& s, int count, int tournamentSize, EvoRNG& rng);
std::vector<int> sampleWeighted(const std::vector<double>& w, int count, EvoRNG& rng);
std::vector<double> crossover(CrossoverMethod m, const std::vector<double>& a, const std::vector<double>& b, const GenomeLayout& layout,
                              double blendAlpha, double sbxEta, EvoRNG& rng);
std::vector<double> mutate(MutationMethod m, const std::vector<double>& v, const GenomeLayout& layout, double rate, double sigmaScale,
                           double polyEta, EvoRNG& rng);
std::vector<double> isoLine(const std::vector<double>& a, const std::vector<double>& b, const GenomeLayout& layout,
                            double isoSigma, double lineSigma, EvoRNG& rng);
}

// Shared serialisation of the common "best" pair.
struct BestPair {
    std::optional<Genome> genome; std::optional<Fitness> fitness;
    void offer(const Genome& g, const Fitness& f) { if (!fitness || ops::score(f) > ops::score(*fitness)) { genome = g; fitness = f; } }
    double score() const { return fitness ? ops::score(*fitness) : -INFINITY; }
};

} // namespace pw::evo
