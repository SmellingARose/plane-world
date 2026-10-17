#pragma once
// Evolution core types (port of Sources/Evolution/Core/{RNG,Fitness,Genome,Algorithm}.swift).
//  * EvoRNG: xoshiro256** seeded through SplitMix64, the ONLY randomness used by evolution (runs are reproducible).
//  * A Genome is a flat double vector described by a GenomeLayout (one GeneSpec per value), plus an optional
//    structured NEAT genome for topology-evolving algorithms.
//  * JSON codecs write the same keys as the Swift Codable types (experiments, checkpoints and exported crafts are
//    interchangeable between the Swift app and the C++ port; 64-bit integers round-trip exactly).
#include <cmath>
#include <cstdint>
#include <map>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>
#include "pw/json.h"
#include "pw/math.h"

namespace pw::evo {
using json::Value;

/// Thrown by evolution code for invalid experiments / script errors; the message is user-facing.
struct EvoError : std::runtime_error { using std::runtime_error::runtime_error; };

// MARK: - RNG

/// xoshiro256** seeded through SplitMix64. Value type: copy = fork of the stream (Swift EvoRNG, bit-identical).
struct EvoRNG {
    uint64_t s0 = 0, s1 = 0, s2 = 0, s3 = 0;
    EvoRNG() = default;
    explicit EvoRNG(uint64_t seed) {
        uint64_t x = seed;
        auto sm = [&x] { x += 0x9E3779B97F4A7C15ull; uint64_t z = x; z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull; z = (z ^ (z >> 27)) * 0x94D049BB133111EBull; return z ^ (z >> 31); };
        s0 = sm(); s1 = sm(); s2 = sm(); s3 = sm();
        if ((s0 | s1 | s2 | s3) == 0) s0 = 1;
    }
    static uint64_t rotl(uint64_t x, int k) { return (x << k) | (x >> (64 - k)); }
    uint64_t next() {
        uint64_t r = rotl(s1 * 5, 7) * 9;
        uint64_t t = s1 << 17;
        s2 ^= s0; s3 ^= s1; s1 ^= s2; s0 ^= s3; s2 ^= t; s3 = rotl(s3, 45);
        return r;
    }
    /// Uniform [0, 1).
    double nextDouble() { return double(next() >> 11) * 0x1.0p-53; }
    double uniform(double a, double b) { return a + (b - a) * nextDouble(); }
    /// Uniform integer in 0..<n (n > 0).
    int intBelow(int n) { return int(next() % uint64_t(n < 1 ? 1 : n)); }
    /// Standard normal (Box-Muller, no cached spare).
    double gaussian() {
        double u1 = smax(nextDouble(), 1e-300), u2 = nextDouble();
        return std::sqrt(-2 * std::log(u1)) * std::cos(2 * kPi * u2);
    }
    bool operator==(const EvoRNG&) const = default;
    /// Stable seed derivation: hash of a root seed and a path of integers (generation, candidate, episode...).
    static uint64_t derive(uint64_t root, std::initializer_list<int64_t> path) {
        uint64_t h = root ^ 0x6A09E667F3BCC909ull;
        for (int64_t p : path) {
            h ^= uint64_t(p) + 0x9E3779B97F4A7C15ull + (h << 6) + (h >> 2);
            h = (h ^ (h >> 33)) * 0xFF51AFD7ED558CCDull;
            h = (h ^ (h >> 33)) * 0xC4CEB9FE1A85EC53ull;
            h ^= h >> 33;
        }
        return h;
    }
    Value toJson() const;
    static EvoRNG fromJson(const Value& v);
};

// MARK: - genes

enum class GeneKind : uint8_t { Real, Int, Bool };
const char* geneKindName(GeneKind k);
GeneKind geneKindFrom(const std::string& s);   // throws on unknown

struct GeneSpec {
    std::string name;
    GeneKind kind = GeneKind::Real;
    double min = -1, max = 1;
    std::optional<double> initial;   // nil = uniform in [min, max] (real/int) or 50 % (bool)
    std::optional<double> sigma;     // mutation scale hint (absolute); nil = 10 % of (max - min)
    std::string group = "script";    // "mlp", "design", "script", ...
    double mutationScale() const { return sigma ? *sigma : smax(1e-9, (max - min) * 0.1); }
    /// Clamp/round a raw value into this gene's domain (bool: >= 0.5 -> 1).
    double legalize(double v) const {
        double x = std::isfinite(v) ? smin(smax(v, min), max) : (initial ? *initial : (min + max) / 2);
        switch (kind) {
        case GeneKind::Real: return x;
        case GeneKind::Int: return std::round(x);
        case GeneKind::Bool: return x >= 0.5 ? 1 : 0;
        }
        return x;
    }
    bool operator==(const GeneSpec&) const = default;
};

/// NEAT network input/output declaration (topology genes live in NEATGenome).
struct NEATLayout {
    std::vector<std::string> inputs, outputs;
    std::string hiddenActivation = "tanh", outputActivation = "tanh";
    std::string initialConnectivity = "full";   // "full" | "none" | fraction "0.5"
    bool recurrent = false;
    bool operator==(const NEATLayout&) const = default;
};

struct GenomeLayout {
    std::vector<GeneSpec> genes;
    std::optional<NEATLayout> neat;
    int count() const { return int(genes.size()); }
    int index(const std::string& name) const;
    /// [first, last+1) of the genes in `group`, or {-1,-1}.
    std::pair<int, int> range(const std::string& group) const;
    void legalize(std::vector<double>& v) const {
        std::size_t n = std::min(v.size(), genes.size());
        for (std::size_t i = 0; i < n; ++i) v[i] = genes[i].legalize(v[i]);
    }
    std::vector<double> randomValues(EvoRNG& rng) const;
    GenomeLayout operator+(const GenomeLayout& b) const;
    bool operator==(const GenomeLayout&) const = default;
};

// MARK: - NEAT genome (data; operators in neat.cpp)

enum class NEATNodeKind : uint8_t { Input, Bias, Hidden, Output };
struct NEATNode {
    int id = 0; NEATNodeKind kind = NEATNodeKind::Hidden; std::string activation = "tanh"; double bias = 0;
    bool operator==(const NEATNode&) const = default;
};
struct NEATConnection {
    int innovation = 0, from = 0, to = 0; double weight = 0; bool enabled = true;
    bool operator==(const NEATConnection&) const = default;
};
struct NEATGenome {
    std::vector<NEATNode> nodes;           // inputs 0..<nIn, bias nIn, outputs nIn+1..., hidden afterwards
    std::vector<NEATConnection> connections;
    std::optional<int> species;
    bool operator==(const NEATGenome&) const = default;
};

struct Genome {
    uint64_t id = 0;                       // unique within a run
    std::vector<double> values;
    std::optional<NEATGenome> neat;
    std::vector<uint64_t> parents;
    std::string origin = "init";           // "init", "mutation", "crossover", "elite", "emitter", "sample", ...
    int generation = 0;
    bool operator==(const Genome&) const = default;
};

// MARK: - fitness

constexpr double kFailedFitness = -1e12;
constexpr int kFormatVersion = 1;

struct Fitness {
    double total = 0;
    std::map<std::string, double> terms;   // named reward terms (aggregated like total)
    std::optional<std::vector<double>> descriptor;
    std::optional<double> novelty;
    int episodes = 0;
    double simSeconds = 0;
    int controlTicks = 0;
    std::optional<std::string> error;      // non-nil when evaluation failed (user-facing message)
    static Fitness failed(std::string msg) { Fitness f; f.total = kFailedFitness; f.error = std::move(msg); return f; }
    bool operator==(const Fitness&) const = default;
};

struct Summary { double best = 0, mean = 0, median = 0, worst = 0, std = 0; };
/// Order statistics over finite, non-failed values (Swift Stats.summary).
Summary summarize(const std::vector<double>& xs);

// MARK: - archives / species / params

struct DescriptorAxis {
    std::string name; double min = 0, max = 1; int bins = 20;
    bool operator==(const DescriptorAxis&) const = default;
};

struct Elite { Genome genome; Fitness fitness; int generation = 0; bool operator==(const Elite&) const = default; };

/// MAP-Elites style archive. Cells keyed by flattened bin index (ordered, so iteration is deterministic).
struct EliteArchive {
    std::vector<DescriptorAxis> axes;
    std::map<int, Elite> cells;
    std::vector<std::vector<double>> noveltyPoints;
    int capacity() const { int c = 1; for (auto& a : axes) c *= std::max(1, a.bins); return c; }
    double coverage() const { return double(cells.size()) / double(std::max(1, capacity())); }
    /// Row-major cell index (axis 0 slowest), nullopt for wrong length / non-finite.
    std::optional<int> cellIndex(const std::vector<double>& d) const;
    std::vector<int> coordinates(int cell) const;
    bool operator==(const EliteArchive&) const = default;
};

struct SpeciesInfo {
    int id = 0, size = 0; double bestFitness = 0, meanFitness = 0; int staleness = 0;
    bool operator==(const SpeciesInfo&) const = default;
};

/// Algorithm kind + free-form parameters (Swift AlgorithmParams; values keep JSON order).
struct AlgorithmParams {
    std::string kind = "simple-es";
    std::vector<std::pair<std::string, Value>> values;
    const Value* find(const std::string& k) const;
    void set(const std::string& k, Value v);
    double num(const std::string& k, double d) const;
    int integer(const std::string& k, int d) const;
    std::string string(const std::string& k, const std::string& d) const;
    bool boolean(const std::string& k, bool d) const;
};

// MARK: - JSON codecs (Swift Codable key names)

Value toJson(const GeneSpec& g);
Value toJson(const NEATLayout& l);
Value toJson(const GenomeLayout& l);
Value toJson(const NEATGenome& g);
Value toJson(const Genome& g);
Value toJson(const Fitness& f);
Value toJson(const DescriptorAxis& a);
Value toJson(const EliteArchive& a);
Value toJson(const SpeciesInfo& s);
Value toJson(const AlgorithmParams& p);
GeneSpec geneSpecFromJson(const Value& v);
NEATLayout neatLayoutFromJson(const Value& v);
GenomeLayout layoutFromJson(const Value& v);
NEATGenome neatGenomeFromJson(const Value& v);
Genome genomeFromJson(const Value& v);
Fitness fitnessFromJson(const Value& v);
DescriptorAxis axisFromJson(const Value& v);
std::vector<DescriptorAxis> axesFromJson(const Value& v);
EliteArchive archiveFromJson(const Value& v);
SpeciesInfo speciesFromJson(const Value& v);
AlgorithmParams paramsFromJson(const Value& v);

// small JSON helpers shared by the evolution codecs
namespace js {
Value arr(const std::vector<double>& v);
Value arrStr(const std::vector<std::string>& v);
std::vector<double> nums(const Value& v);
std::vector<std::string> strs(const Value& v);
double num(const Value& o, const char* k, double d);
int integer(const Value& o, const char* k, int d);
uint64_t u64(const Value& o, const char* k, uint64_t d);
bool boolean(const Value& o, const char* k, bool d);
std::string str(const Value& o, const char* k, const std::string& d);
std::optional<double> optNum(const Value& o, const char* k);
/// Strict Swift-Codable style number: throws when missing / not a number.
double reqNum(const Value& o, const char* k);
std::string reqStr(const Value& o, const char* k);
}
} // namespace pw::evo
