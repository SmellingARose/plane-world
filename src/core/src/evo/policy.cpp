#include "pw/evo/policy.h"
#include <algorithm>
#include <map>
#include <set>

namespace pw::evo {

uint8_t activationCode(const std::string& s) {
    if (s == "relu") return 1;
    if (s == "sigmoid") return 2;
    if (s == "linear") return 3;
    return 0;
}

// MARK: - MLP
MLPPolicy::MLPPolicy(std::vector<int> sizes, const std::string& h, const std::string& o)
    : sizes_(std::move(sizes)), hiddenAct_(activationCode(h)), outAct_(activationCode(o)) {
    if (sizes_.size() < 2) throw EvoError("MLP needs at least an input and an output layer");
    weightCount_ = parameterCount(sizes_);
    w_.assign(static_cast<std::size_t>(std::max(1, weightCount_)), 0.0);
    int m = *std::max_element(sizes_.begin(), sizes_.end());
    bufA_.assign(static_cast<std::size_t>(std::max(1, m)), 0.0); bufB_ = bufA_;
}
int MLPPolicy::parameterCount(const std::vector<int>& sizes) {
    int n = 0;
    for (std::size_t l = 0; l + 1 < sizes.size(); ++l) n += sizes[l + 1] * sizes[l] + sizes[l + 1];
    return n;
}
GenomeLayout MLPPolicy::layout(const std::vector<int>& sizes, double range) {
    GenomeLayout g;
    g.genes.reserve(static_cast<std::size_t>(parameterCount(sizes)));
    for (std::size_t l = 0; l + 1 < sizes.size(); ++l) {
        double fanIn = double(sizes[l]), s = 1 / std::sqrt(fanIn);
        std::string L = std::to_string(l);
        for (int o = 0; o < sizes[l + 1]; ++o) for (int i = 0; i < sizes[l]; ++i) {
            GeneSpec gs; gs.name = "mlp." + L + ".w." + std::to_string(o) + "." + std::to_string(i);
            gs.min = -range; gs.max = range; gs.sigma = 0.1 * smax(s, 0.1); gs.group = "mlp";
            g.genes.push_back(std::move(gs));
        }
        for (int o = 0; o < sizes[l + 1]; ++o) {
            GeneSpec gs; gs.name = "mlp." + L + ".b." + std::to_string(o);
            gs.min = -range; gs.max = range; gs.initial = 0; gs.sigma = 0.1; gs.group = "mlp";
            g.genes.push_back(std::move(gs));
        }
    }
    return g;
}
void MLPPolicy::load(const double* values, int count) {
    int n = std::min(count, weightCount_);
    for (int i = 0; i < n; ++i) w_[static_cast<std::size_t>(i)] = values[i];
}
void MLPPolicy::forward(const double* x, double* y) {
    const double* src = x;
    const double* w = w_.data();
    int L = int(sizes_.size()) - 1;
    for (int l = 0; l < L; ++l) {
        int nIn = sizes_[static_cast<std::size_t>(l)], nOut = sizes_[static_cast<std::size_t>(l + 1)];
        double* dst = l == L - 1 ? y : (l % 2 == 0 ? bufA_.data() : bufB_.data());
        uint8_t act = l == L - 1 ? outAct_ : hiddenAct_;
        const double* b = w + nOut * nIn;
        for (int o = 0; o < nOut; ++o) {
            double acc = b[o];
            const double* row = w + o * nIn;
            for (int i = 0; i < nIn; ++i) acc += row[i] * src[i];
            dst[o] = activate(act, acc);
        }
        w = b + nOut;
        src = dst;
    }
}

MLPBatch::MLPBatch(const MLPPolicy& m, int lanes)
    : sizes_(m.sizes()), K_(lanes), hiddenAct_(m.hiddenAct()), outAct_(m.outAct()), weightCount_(m.weightCount()) {
    int mx = *std::max_element(sizes_.begin(), sizes_.end());
    auto buf = [](int n) { return std::vector<double>(static_cast<std::size_t>(std::max(1, n)), 0.0); };
    w_ = buf(weightCount_ * K_); bufA_ = buf(mx * K_); bufB_ = buf(mx * K_); acc_ = buf(K_);
    x_ = buf(sizes_[0] * K_); y_ = buf(sizes_.back() * K_);
}
void MLPBatch::load(int lane, const MLPPolicy& m) { for (int k = 0; k < weightCount_; ++k) w_[static_cast<std::size_t>(k * K_ + lane)] = m.weights()[k]; }
void MLPBatch::forward() {
    int K = K_;
    const double* src = x_.data();
    const double* wl = w_.data();
    int L = int(sizes_.size()) - 1;
    for (int l = 0; l < L; ++l) {
        int nIn = sizes_[static_cast<std::size_t>(l)], nOut = sizes_[static_cast<std::size_t>(l + 1)];
        double* dst = l == L - 1 ? y_.data() : (l % 2 == 0 ? bufA_.data() : bufB_.data());
        uint8_t act = l == L - 1 ? outAct_ : hiddenAct_;
        const double* b = wl + nOut * nIn * K;
        for (int o = 0; o < nOut; ++o) {
            for (int k = 0; k < K; ++k) acc_[static_cast<std::size_t>(k)] = b[o * K + k];
            const double* row = wl + o * nIn * K;
            for (int i = 0; i < nIn; ++i) {
                const double* wr = row + i * K; const double* xs = src + i * K;
                for (int k = 0; k < K; ++k) acc_[static_cast<std::size_t>(k)] += wr[k] * xs[k];
            }
            for (int k = 0; k < K; ++k) dst[o * K + k] = activate(act, acc_[static_cast<std::size_t>(k)]);
        }
        wl = b + nOut * K;
        src = dst;
    }
}

// MARK: - NEAT network
NEATNetwork::NEATNetwork(const NEATGenome& genome, const NEATLayout& layout)
    : nIn_(int(layout.inputs.size())), nOut_(int(layout.outputs.size())), recurrent_(layout.recurrent) {
    std::vector<NEATNode> nodes = genome.nodes;
    auto ensure = [&](int id, NEATNodeKind k, const std::string& a) {
        for (auto& n : nodes) if (n.id == id) return;
        nodes.push_back({id, k, a, 0});
    };
    for (int i = 0; i < nIn_; ++i) ensure(i, NEATNodeKind::Input, "linear");
    ensure(nIn_, NEATNodeKind::Bias, "linear");
    for (int o = 0; o < nOut_; ++o) ensure(nIn_ + 1 + o, NEATNodeKind::Output, layout.outputActivation);
    std::stable_sort(nodes.begin(), nodes.end(), [](auto& a, auto& b) { return a.id < b.id; });
    std::map<int, int> index;
    for (std::size_t i = 0; i < nodes.size(); ++i) {
        if (index.count(nodes[i].id)) throw EvoError("invalid experiment: NEAT genome has duplicate node id " + std::to_string(nodes[i].id));
        index[nodes[i].id] = int(i);
    }
    nodeCount_ = int(nodes.size());
    values_.assign(static_cast<std::size_t>(nodeCount_), 0.0); scratch_ = values_; bias_.resize(static_cast<std::size_t>(nodeCount_)); act_.resize(static_cast<std::size_t>(nodeCount_));
    for (std::size_t i = 0; i < nodes.size(); ++i) { bias_[i] = nodes[i].bias; act_[i] = activationCode(nodes[i].activation); }
    biasIdx_ = index[nIn_];
    for (int i = 0; i < nIn_; ++i) inputIdx_.push_back(index[i]);
    for (int o = 0; o < nOut_; ++o) outputIdx_.push_back(index[nIn_ + 1 + o]);

    std::vector<std::vector<std::pair<int, double>>> incoming(static_cast<std::size_t>(nodeCount_));
    std::vector<std::vector<int>> outgoing(static_cast<std::size_t>(nodeCount_));
    for (auto& c : genome.connections) {
        if (!c.enabled) continue;
        auto fi = index.find(c.from), ti = index.find(c.to);
        if (fi == index.end() || ti == index.end()) throw EvoError("invalid experiment: NEAT connection " + std::to_string(c.innovation) + " references a missing node");
        int f = fi->second, t = ti->second;
        if (nodes[static_cast<std::size_t>(t)].kind == NEATNodeKind::Input || nodes[static_cast<std::size_t>(t)].kind == NEATNodeKind::Bias) continue;
        incoming[static_cast<std::size_t>(t)].push_back({f, c.weight}); outgoing[static_cast<std::size_t>(f)].push_back(t);
    }
    auto isSource = [&](int i) { auto k = nodes[static_cast<std::size_t>(i)].kind; return k == NEATNodeKind::Input || k == NEATNodeKind::Bias; };
    std::vector<int> ord;
    if (recurrent_) {
        for (int i = 0; i < nodeCount_; ++i) if (!isSource(i)) ord.push_back(i);
    } else {
        std::vector<int> indeg(static_cast<std::size_t>(nodeCount_), 0);
        for (int t = 0; t < nodeCount_; ++t) if (!isSource(t)) for (auto& e : incoming[static_cast<std::size_t>(t)]) if (!isSource(e.first)) indeg[static_cast<std::size_t>(t)]++;
        std::vector<int> queue;
        for (int i = 0; i < nodeCount_; ++i) if (!isSource(i) && indeg[static_cast<std::size_t>(i)] == 0) queue.push_back(i);
        std::vector<bool> done(static_cast<std::size_t>(nodeCount_), false);
        for (std::size_t qi = 0; qi < queue.size(); ++qi) {
            int u = queue[qi]; ord.push_back(u); done[static_cast<std::size_t>(u)] = true;
            for (int t : outgoing[static_cast<std::size_t>(u)]) if (!isSource(t)) { if (--indeg[static_cast<std::size_t>(t)] == 0) queue.push_back(t); }
        }
        for (int u = 0; u < nodeCount_; ++u) if (!isSource(u) && !done[static_cast<std::size_t>(u)]) ord.push_back(u);
    }
    for (int u : ord) {
        order_.push_back(u); edgeStart_.push_back(int32_t(edgeFrom_.size()));
        for (auto& e : incoming[static_cast<std::size_t>(u)]) { edgeFrom_.push_back(e.first); edgeW_.push_back(e.second); }
    }
    edgeStart_.push_back(int32_t(edgeFrom_.size()));
    reset();
}
void NEATNetwork::reset() {
    std::fill(values_.begin(), values_.end(), 0.0);
    values_[static_cast<std::size_t>(biasIdx_)] = 1;
}
void NEATNetwork::forward(const double* x, double* y) {
    double* v = values_.data();
    for (int i = 0; i < nIn_; ++i) v[inputIdx_[static_cast<std::size_t>(i)]] = x[i];
    v[biasIdx_] = 1;
    int oc = int(order_.size());
    if (recurrent_) {
        for (int k = 0; k < oc; ++k) {
            int u = order_[static_cast<std::size_t>(k)];
            double s = bias_[static_cast<std::size_t>(u)];
            for (int e = edgeStart_[static_cast<std::size_t>(k)]; e < edgeStart_[static_cast<std::size_t>(k + 1)]; ++e) s += edgeW_[static_cast<std::size_t>(e)] * v[edgeFrom_[static_cast<std::size_t>(e)]];
            scratch_[static_cast<std::size_t>(u)] = activate(act_[static_cast<std::size_t>(u)], s);
        }
        for (int k = 0; k < oc; ++k) { int u = order_[static_cast<std::size_t>(k)]; v[u] = scratch_[static_cast<std::size_t>(u)]; }
    } else {
        for (int k = 0; k < oc; ++k) {
            int u = order_[static_cast<std::size_t>(k)];
            double s = bias_[static_cast<std::size_t>(u)];
            for (int e = edgeStart_[static_cast<std::size_t>(k)]; e < edgeStart_[static_cast<std::size_t>(k + 1)]; ++e) s += edgeW_[static_cast<std::size_t>(e)] * v[edgeFrom_[static_cast<std::size_t>(e)]];
            v[u] = activate(act_[static_cast<std::size_t>(u)], s);
        }
    }
    for (int o = 0; o < nOut_; ++o) y[o] = v[outputIdx_[static_cast<std::size_t>(o)]];
}
std::vector<double> NEATNetwork::evaluate(const std::vector<double>& x) {
    std::vector<double> y(static_cast<std::size_t>(nOut_), 0.0);
    forward(x.data(), y.data());
    return y;
}

// MARK: - design decoder
namespace design {
GenomeLayout layout(const std::vector<DesignGene>& genes) {
    GenomeLayout l;
    for (auto& g : genes) { GeneSpec s; s.name = g.geneName(); s.kind = g.kind; s.min = g.min; s.max = g.max; s.initial = g.initial; s.group = "design"; l.genes.push_back(s); }
    return l;
}
bool partMatches(const craft::CraftPart& p, const std::string& sel) {
    if (!sel.empty() && sel.back() == '*') {
        std::string pre = sel.substr(0, sel.size() - 1);
        return p.id.rfind(pre, 0) == 0 || p.name.rfind(pre, 0) == 0;
    }
    return p.id == sel || p.name == sel;
}
static void setField(craft::CraftPart& p, const std::string& field, double v, std::set<std::string>& removed) {
    if (field == "mass") { p.mass = smax(0, v); return; }
    if (field == "enabled") { if (v < 0.5) removed.insert(p.id); return; }
    if (field.rfind("p.", 0) == 0) { p.setParam(field.substr(2), v); return; }
    // "pos.N" / "rot.N" (Swift split(separator: ".") drops empty pieces)
    std::vector<std::string> comps; std::string cur;
    for (char c : field) { if (c == '.') { if (!cur.empty()) comps.push_back(cur); cur.clear(); } else cur += c; }
    if (!cur.empty()) comps.push_back(cur);
    if (comps.size() == 2 && (comps[1] == "0" || comps[1] == "1" || comps[1] == "2")) {
        std::size_t i = static_cast<std::size_t>(comps[1][0] - '0');
        if (comps[0] == "pos") { while (p.pos.size() < 3) p.pos.push_back(0); p.pos[i] = v; return; }
        if (comps[0] == "rot") { while (p.rot.size() < 3) p.rot.push_back(0); p.rot[i] = v; return; }
    }
    throw EvoError("invalid experiment: design gene field '" + field + "' not understood (mass | enabled | p.<key> | pos.N | rot.N)");
}
craft::CraftDocument apply(const std::vector<DesignGene>& genes, const double* values, const craft::CraftDocument& doc) {
    craft::CraftDocument d = doc;
    std::set<std::string> removed;
    for (std::size_t k = 0; k < genes.size(); ++k) {
        const DesignGene& g = genes[k];
        double v = values[k];
        bool hit = false;
        for (auto& p : d.parts) {
            bool direct = partMatches(p, g.part);
            bool mirrored = std::find(g.mirror.begin(), g.mirror.end(), p.name) != g.mirror.end() || std::find(g.mirror.begin(), g.mirror.end(), p.id) != g.mirror.end();
            if (!direct && !mirrored) continue;
            hit = true;
            double val = (mirrored && !direct && g.field == "pos.2") ? -v : v;
            setField(p, g.field, val, removed);
        }
        if (!hit) throw EvoError("invalid experiment: design gene '" + g.geneName() + "': no part matches '" + g.part + "'");
    }
    if (!removed.empty()) {
        d.parts.erase(std::remove_if(d.parts.begin(), d.parts.end(), [&](auto& p) { return removed.count(p.id) > 0; }), d.parts.end());
        for (auto& p : d.parts) {
            if (p.servo && removed.count(*p.servo)) p.servo.reset();
            if (p.motor && removed.count(*p.motor)) p.motor.reset();
        }
    }
    return d;
}
} // namespace design

} // namespace pw::evo
