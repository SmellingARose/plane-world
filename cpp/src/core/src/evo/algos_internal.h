#pragma once
// Private glue between the algorithm translation units.
#include <memory>
#include "pw/evo/algorithm.h"

namespace pw::evo {
std::unique_ptr<Algorithm> makeCMAES(const GenomeLayout&, const AlgorithmParams&, int population, uint64_t seed, bool diagonal);
std::unique_ptr<Algorithm> makeOpenAIES(const GenomeLayout&, const AlgorithmParams&, int population, uint64_t seed);
std::unique_ptr<Algorithm> makeNEAT(const GenomeLayout&, const AlgorithmParams&, int population, uint64_t seed);
std::unique_ptr<Algorithm> makeMAPElites(const GenomeLayout&, const AlgorithmParams&, int population, uint64_t seed);
std::unique_ptr<Algorithm> makeNovelty(const GenomeLayout&, const AlgorithmParams&, int population, uint64_t seed);

namespace detail {
Value genomesJson(const std::vector<Genome>& g);
Value fitnessesJson(const std::vector<Fitness>& f);
std::vector<Genome> genomesFrom(const Value& v);
std::vector<Fitness> fitnessesFrom(const Value& v);
void putBest(Value& o, const char* gk, const char* fk, const BestPair& b);
void getBest(const Value& o, const char* gk, const char* fk, BestPair& b);
Value parseState(const std::string& s);
void requireHookCount(std::size_t got, int expected, const char* what);
/// MAP-Elites / novelty descriptor axes from params.values["axes"] (empty when absent).
std::vector<DescriptorAxis> axesParam(const AlgorithmParams& p);
}
} // namespace pw::evo
