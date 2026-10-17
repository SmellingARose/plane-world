#pragma once
// Native genome decoders (port of Core/Policy.swift and Algorithms/NEATNetwork.swift): MLP controller weights, the
// NEAT phenotype and craft design parameters. forward() never allocates; outputs are bit-identical to Swift.
#include <string>
#include <vector>
#include "pw/craft/document.h"
#include "pw/evo/experiment.h"
#include "pw/evo/types.h"

namespace pw::evo {

/// 0 tanh, 1 relu, 2 sigmoid, 3 linear.
uint8_t activationCode(const std::string& s);
inline double activate(uint8_t kind, double x) {
    switch (kind) {
    case 1: return smax(0, x);
    case 2: return 1 / (1 + std::exp(-x));
    case 3: return x;
    default: return std::tanh(x);
    }
}

class PolicyNetwork {
public:
    virtual ~PolicyNetwork() = default;
    virtual int inputCount() const = 0;
    virtual int outputCount() const = 0;
    virtual void reset() = 0;
    virtual void forward(const double* x, double* y) = 0;
};

/// Fully connected MLP. Genome layout (group "mlp") per layer L: W_L row-major [out][in] then b_L [out].
class MLPPolicy final : public PolicyNetwork {
public:
    MLPPolicy(std::vector<int> sizes, const std::string& hiddenActivation = "tanh", const std::string& outputActivation = "tanh");
    static int parameterCount(const std::vector<int>& sizes);
    static GenomeLayout layout(const std::vector<int>& sizes, double range);
    void load(const double* values, int count);
    int inputCount() const override { return sizes_.front(); }
    int outputCount() const override { return sizes_.back(); }
    void reset() override {}
    void forward(const double* x, double* y) override;
    const std::vector<int>& sizes() const { return sizes_; }
    int weightCount() const { return weightCount_; }
    const double* weights() const { return w_.data(); }
    uint8_t hiddenAct() const { return hiddenAct_; }
    uint8_t outAct() const { return outAct_; }
private:
    std::vector<int> sizes_;
    uint8_t hiddenAct_, outAct_;
    int weightCount_;
    std::vector<double> w_, bufA_, bufB_;
};

/// K MLPs of the same shape evaluated together, lane-minor storage ([parameter][lane]); every lane performs exactly
/// MLPPolicy::forward's operations in the same order (bit-identical to K separate forwards).
class MLPBatch {
public:
    MLPBatch(const MLPPolicy& like, int lanes);
    void load(int lane, const MLPPolicy& m);
    void forward();
    double* x() { return x_.data(); }        // [sizes[0]][lanes]
    const double* y() const { return y_.data(); }   // [sizes.back()][lanes]
    int lanes() const { return K_; }
private:
    std::vector<int> sizes_; int K_; uint8_t hiddenAct_, outAct_; int weightCount_;
    std::vector<double> w_, bufA_, bufB_, acc_, x_, y_;
};

/// NEAT phenotype: feed-forward in topological order (cycle members afterwards in id order), or one synchronous
/// update per call when recurrent. Built once per candidate; forward() is allocation-free.
class NEATNetwork final : public PolicyNetwork {
public:
    NEATNetwork(const NEATGenome& genome, const NEATLayout& layout);   // throws EvoError
    int inputCount() const override { return nIn_; }
    int outputCount() const override { return nOut_; }
    void reset() override;
    void forward(const double* x, double* y) override;
    std::vector<double> evaluate(const std::vector<double>& x);        // convenience (allocates)
private:
    int nIn_, nOut_, nodeCount_ = 0; bool recurrent_;
    std::vector<double> values_, scratch_, bias_;
    std::vector<uint8_t> act_;
    std::vector<int32_t> order_, edgeStart_, edgeFrom_, inputIdx_, outputIdx_;
    std::vector<double> edgeW_;
    int biasIdx_ = 0;
};

/// Applies design genes to a craft document (native, before the script decode hook).
namespace design {
GenomeLayout layout(const std::vector<DesignGene>& genes);
/// Modified copy; `values` are the design genes in `genes` order (already legalised). Throws EvoError.
craft::CraftDocument apply(const std::vector<DesignGene>& genes, const double* values, const craft::CraftDocument& doc);
}

} // namespace pw::evo
