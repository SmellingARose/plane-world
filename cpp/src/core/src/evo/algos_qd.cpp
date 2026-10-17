// NEAT (NEAT.swift), MAP-Elites with iso+line variation and CVT (MAPElites.swift), novelty search (Novelty.swift).
#include <cstdlib>
#include <algorithm>
#include <functional>
#include <set>
#include <unordered_map>
#include "algos_internal.h"

namespace pw::evo {
using namespace detail;

namespace detail {
std::vector<DescriptorAxis> axesParam(const AlgorithmParams& p) {
    const Value* a = p.find("axes");
    if (!a) return {};
    try { return axesFromJson(*a); }
    catch (const std::exception& e) { throw EvoError(std::string("invalid experiment: descriptor axes malformed: ") + e.what()); }
}
}

namespace {
template <class T, class Less> void stableSort(std::vector<T>& v, Less less) { std::stable_sort(v.begin(), v.end(), less); }

// MARK: - NEAT
class NEATAlgo final : public Algorithm {
    struct Species {
        int id = 0; NEATGenome representative; std::vector<int> members;
        double bestEver = -1.7976931348623157e308; int staleness = 0; int created = 0;
    };
    struct P {
        double c1 = 1, c2 = 1, c3 = 0.4; int targetSpecies = 0; double compatStep = 0.3, survival = 0.2, crossoverRate = 0.75;
        double wRate = 0.8, wSigma = 0.5, wReplace = 0.1, wRange = 8, bRate = 0.7, addNode = 0.03, addConn = 0.05;
        double disable = 0.01, interspecies = 0.001; int stagnation = 15, elitism = 1; double initSigma = 1, valueRate = 0.1;
    };
public:
    NEATAlgo(const GenomeLayout& layout, const AlgorithmParams& params, int population, uint64_t seed) : layout_(layout) {
        if (!layout.neat) throw EvoError("invalid experiment: neat needs a NEAT layout (controller mode 'neat' or genome.neat)");
        nl_ = *layout.neat;
        if (nl_.outputs.empty()) throw EvoError("invalid experiment: neat needs at least one output");
        pop_ = std::max(2, population);
        P q;
        q.c1 = params.num("c1", q.c1); q.c2 = params.num("c2", q.c2); q.c3 = params.num("c3", q.c3);
        q.targetSpecies = params.integer("targetSpecies", 0); q.compatStep = params.num("compatStep", q.compatStep);
        q.survival = params.num("survivalThreshold", q.survival); q.crossoverRate = params.num("crossoverRate", q.crossoverRate);
        q.wRate = params.num("weightMutateRate", q.wRate); q.wSigma = params.num("weightPerturbSigma", q.wSigma);
        q.wReplace = params.num("weightReplaceRate", q.wReplace); q.wRange = params.num("weightRange", q.wRange);
        q.bRate = params.num("biasMutateRate", q.bRate);
        q.addNode = params.num("addNodeRate", q.addNode); q.addConn = params.num("addConnRate", q.addConn);
        q.disable = params.num("disableRate", q.disable); q.interspecies = params.num("interspeciesRate", q.interspecies);
        q.stagnation = std::max(1, params.integer("stagnation", q.stagnation)); q.elitism = std::max(0, params.integer("elitismPerSpecies", q.elitism));
        q.initSigma = params.num("initialWeightSigma", q.initSigma);
        q.valueRate = params.num("valueMutationRate", smax(1 / double(std::max(1, layout.count())), 0.1));
        p_ = q;
        int nIn = int(nl_.inputs.size()), nOut = int(nl_.outputs.size());
        rng_ = EvoRNG(seed); nextNodeID_ = nIn + 1 + nOut; nextInnovation_ = 1;
        compatThreshold_ = params.num("compatThreshold", 3);
        double conn = 1;
        if (nl_.initialConnectivity == "full") conn = 1;
        else if (nl_.initialConnectivity == "none") conn = 0;
        else {
            char* end = nullptr; const std::string& s = nl_.initialConnectivity;
            double f = std::strtod(s.c_str(), &end);
            if (s.empty() || end != s.c_str() + s.size() || !(f >= 0) || !(f <= 1)) throw EvoError("invalid experiment: neat: initialConnectivity must be full|none|0..1");
            conn = f;
        }
        for (int k = 0; k < pop_; ++k) {
            NEATGenome g;
            for (int i = 0; i < nIn; ++i) g.nodes.push_back({i, NEATNodeKind::Input, "linear", 0});
            g.nodes.push_back({nIn, NEATNodeKind::Bias, "linear", 0});
            for (int o = 0; o < nOut; ++o) g.nodes.push_back({nIn + 1 + o, NEATNodeKind::Output, nl_.outputActivation, 0});
            for (int f = 0; f <= nIn; ++f) for (int o = 0; o < nOut; ++o) {
                if (!(conn >= 1 || rng_.nextDouble() < conn)) continue;
                int to = nIn + 1 + o;
                int inn = innovation(f, to);
                g.connections.push_back({inn, f, to, rng_.gaussian() * p_.initSigma, true});
            }
            sortConns(g.connections);
            Genome ge; ge.id = nextID_++; ge.values = layout.randomValues(rng_); ge.neat = std::move(g); ge.origin = "init"; ge.generation = 0;
            pending_.push_back(std::move(ge));
        }
    }
    const char* kind() const override { return "neat"; }
    int generation() const override { return gen_; }
    std::vector<Genome> ask() override { return pending_; }

    static void sortConns(std::vector<NEATConnection>& c) { stableSort(c, [](auto& a, auto& b) { return a.innovation < b.innovation; }); }
    static void sortNodes(std::vector<NEATNode>& n) { stableSort(n, [](auto& a, auto& b) { return a.id < b.id; }); }

    int innovation(int from, int to) {
        std::string k = std::to_string(from) + ">" + std::to_string(to);
        auto it = innovations_.find(k);
        if (it != innovations_.end()) return it->second;
        int i = nextInnovation_++;
        innovations_[k] = i;
        return i;
    }

    double distance(const NEATGenome& a, const NEATGenome& b) const {
        const auto& ca = a.connections; const auto& cb = b.connections;
        std::size_t i = 0, j = 0; int matching = 0, disjoint = 0, excess = 0; double wdiff = 0;
        int maxA = ca.empty() ? 0 : ca.back().innovation, maxB = cb.empty() ? 0 : cb.back().innovation;
        while (i < ca.size() || j < cb.size()) {
            if (i < ca.size() && j < cb.size()) {
                if (ca[i].innovation == cb[j].innovation) { ++matching; wdiff += std::fabs(ca[i].weight - cb[j].weight); ++i; ++j; }
                else if (ca[i].innovation < cb[j].innovation) { if (ca[i].innovation > maxB) ++excess; else ++disjoint; ++i; }
                else { if (cb[j].innovation > maxA) ++excess; else ++disjoint; ++j; }
            } else if (i < ca.size()) { ++excess; ++i; } else { ++excess; ++j; }
        }
        std::size_t n = std::max(ca.size(), cb.size());
        double N = n < 20 ? 1.0 : double(n);
        return p_.c1 * double(excess) / N + p_.c2 * double(disjoint) / N + p_.c3 * (matching > 0 ? wdiff / double(matching) : 0);
    }

    void tell(const std::vector<Genome>& genomes, const std::vector<Fitness>& fitness) override {
        if (genomes.size() != fitness.size()) throw EvoError("tell: genomes/fitness count mismatch");
        auto scores = ops::scores(fitness);
        double prevBest = best_.score();
        for (std::size_t i = 0; i < genomes.size(); ++i) best_.offer(genomes[i], fitness[i]);
        stagnation_ = best_.score() > prevBest ? 0 : stagnation_ + 1;

        // 1. speciate
        for (auto& s : species_) s.members.clear();
        for (std::size_t i = 0; i < genomes.size(); ++i) {
            if (!genomes[i].neat) throw EvoError("invalid experiment: neat: candidate " + std::to_string(genomes[i].id) + " has no NEAT genome");
            const NEATGenome& ng = *genomes[i].neat;
            bool placed = false;
            for (auto& s : species_) if (distance(ng, s.representative) < compatThreshold_) { s.members.push_back(int(i)); placed = true; break; }
            if (!placed) { Species s; s.id = nextSpeciesID_++; s.representative = ng; s.members = {int(i)}; s.created = gen_; species_.push_back(std::move(s)); }
        }
        species_.erase(std::remove_if(species_.begin(), species_.end(), [](auto& s) { return s.members.empty(); }), species_.end());

        // 2. stats + stagnation
        auto maxOf = [&](const std::vector<int>& m) { double r = scores[static_cast<std::size_t>(m[0])]; for (int x : m) if (scores[static_cast<std::size_t>(x)] > r) r = scores[static_cast<std::size_t>(x)]; return r; };
        for (auto& s : species_) {
            double b = maxOf(s.members);
            if (b > s.bestEver) { s.bestEver = b; s.staleness = 0; } else s.staleness += 1;
        }
        std::vector<int> ranked(species_.size());
        for (std::size_t i = 0; i < ranked.size(); ++i) ranked[i] = int(i);
        stableSort(ranked, [&](int a, int b) {
            auto& A = species_[static_cast<std::size_t>(a)]; auto& B = species_[static_cast<std::size_t>(b)];
            return A.bestEver != B.bestEver ? A.bestEver > B.bestEver : A.id < B.id;
        });
        std::set<int> prot;
        for (std::size_t r = 0; r < ranked.size() && r < 2; ++r) prot.insert(species_[static_cast<std::size_t>(ranked[r])].id);
        std::vector<Species> alive;
        for (auto& s : species_) if (s.staleness < p_.stagnation || prot.count(s.id)) alive.push_back(s);
        if (alive.empty()) alive = species_;

        speciesInfo_.clear();
        for (auto& s : alive) {
            double sum = 0; for (int m : s.members) sum += scores[static_cast<std::size_t>(m)];
            speciesInfo_.push_back({s.id, int(s.members.size()), maxOf(s.members), sum / double(s.members.size()), s.staleness});
        }

        // 3. offspring allocation by shared fitness
        bool first = true; double minS = 0, maxS = 0;
        for (auto& s : alive) for (int m : s.members) {
            double v = scores[static_cast<std::size_t>(m)];
            if (first) { minS = maxS = v; first = false; } else { if (v < minS) minS = v; if (v > maxS) maxS = v; }
        }
        double span = smax(maxS - minS, 1e-12);
        std::vector<double> adj;
        for (auto& s : alive) {
            double a = 0; for (int m : s.members) a = a + ((scores[static_cast<std::size_t>(m)] - minS) / span + 0.01);
            adj.push_back(a / double(s.members.size()));
        }
        double total = 0; for (double a : adj) total += a;
        std::vector<double> quota; std::vector<int> counts;
        for (double a : adj) { double q = double(pop_) * a / total; quota.push_back(q); counts.push_back(int(q)); }
        int rem = pop_; for (int c : counts) rem -= c;
        std::vector<int> byFrac(quota.size());
        for (std::size_t i = 0; i < byFrac.size(); ++i) byFrac[i] = int(i);
        stableSort(byFrac, [&](int a, int b) {
            double fa = quota[static_cast<std::size_t>(a)] - double(counts[static_cast<std::size_t>(a)]), fb = quota[static_cast<std::size_t>(b)] - double(counts[static_cast<std::size_t>(b)]);
            return fa > fb || (fa == fb && a < b);
        });
        int fi = 0;
        while (rem > 0) { counts[static_cast<std::size_t>(byFrac[static_cast<std::size_t>(fi % int(byFrac.size()))])] += 1; rem -= 1; fi += 1; }

        // 4. reproduce
        auto sortedMembers = [&](const std::vector<int>& m) {
            std::vector<int> s = m;
            stableSort(s, [&](int a, int b) { return scores[static_cast<std::size_t>(a)] != scores[static_cast<std::size_t>(b)] ? scores[static_cast<std::size_t>(a)] > scores[static_cast<std::size_t>(b)] : a < b; });
            return s;
        };
        std::vector<std::vector<int>> pools;
        for (auto& s : alive) {
            auto m = sortedMembers(s.members);
            std::size_t keep = static_cast<std::size_t>(std::max(1, int(std::ceil(double(m.size()) * p_.survival))));
            m.resize(std::min(m.size(), keep));
            pools.push_back(std::move(m));
        }
        std::vector<Genome> next;
        for (std::size_t k = 0; k < alive.size(); ++k) {
            const Species& s = alive[k];
            int n = counts[k];
            if (n <= 0) continue;
            auto sorted = sortedMembers(s.members);
            if (s.members.size() >= 5) {
                int ne = std::min(p_.elitism, n);
                for (int e = 0; e < ne && e < int(sorted.size()); ++e) {
                    Genome g = genomes[static_cast<std::size_t>(sorted[static_cast<std::size_t>(e)])];
                    g.parents = {g.id}; g.id = nextID_++;
                    g.origin = "elite"; g.generation = gen_ + 1; if (g.neat) g.neat->species = s.id;
                    next.push_back(std::move(g)); n -= 1;
                }
            }
            const auto& pool = pools[k];
            for (int c = 0; c < n; ++c) {
                int ia = pool[static_cast<std::size_t>(rng_.intBelow(int(pool.size())))];
                Genome child;
                if ((pool.size() > 1 || alive.size() > 1) && rng_.nextDouble() < p_.crossoverRate) {
                    int ib = pool[static_cast<std::size_t>(rng_.intBelow(int(pool.size())))];
                    if (alive.size() > 1 && rng_.nextDouble() < p_.interspecies) {
                        const auto& other = pools[static_cast<std::size_t>(rng_.intBelow(int(pools.size())))];
                        ib = other[static_cast<std::size_t>(rng_.intBelow(int(other.size())))];
                    }
                    int fa = ia, fb = ib;
                    if (!(scores[static_cast<std::size_t>(ia)] >= scores[static_cast<std::size_t>(ib)])) { fa = ib; fb = ia; }
                    child = crossover(genomes[static_cast<std::size_t>(fa)], genomes[static_cast<std::size_t>(fb)], scores[static_cast<std::size_t>(ia)] == scores[static_cast<std::size_t>(ib)]);
                } else {
                    child = genomes[static_cast<std::size_t>(ia)]; child.parents = {genomes[static_cast<std::size_t>(ia)].id}; child.origin = "mutation";
                }
                mutate(child);
                child.id = nextID_++;
                child.generation = gen_ + 1; if (child.neat) child.neat->species = s.id;
                next.push_back(std::move(child));
            }
        }

        // 5. representatives + threshold control
        for (auto& s : alive) {
            const auto& m = s.members;
            s.representative = *genomes[static_cast<std::size_t>(m[static_cast<std::size_t>(rng_.intBelow(int(m.size())))])].neat;
            s.members.clear();
        }
        species_ = alive;
        if (p_.targetSpecies > 0) {
            double target = double(p_.targetSpecies);
            double err = (double(alive.size()) - target) / target;
            if (std::fabs(err) > smax(1.0, 0.2 * target) / target)
                compatThreshold_ = smax(0.1, compatThreshold_ * std::exp(p_.compatStep / 3 * smax(-1, smin(1, err))));
        }
        pending_ = std::move(next);
        ++gen_;
    }

    Genome crossover(const Genome& a, const Genome& b, bool equal) {
        if (!a.neat || !b.neat) throw EvoError("invalid experiment: neat: missing NEAT genome");
        const NEATGenome& ga = *a.neat; const NEATGenome& gb = *b.neat;
        std::unordered_map<int, const NEATConnection*> bmap;
        for (auto& c : gb.connections) bmap[c.innovation] = &c;   // last one wins (Swift dictionary assignment)
        std::vector<NEATConnection> conns;
        for (auto& c : ga.connections) {
            auto it = bmap.find(c.innovation);
            if (it != bmap.end()) {
                const NEATConnection& o = *it->second;
                NEATConnection x = rng_.nextDouble() < 0.5 ? c : o;
                x.enabled = (!c.enabled || !o.enabled) ? rng_.nextDouble() >= 0.75 : true;
                conns.push_back(x);
            } else conns.push_back(c);
        }
        std::vector<NEATNode> nodes = ga.nodes;
        if (equal) {
            std::set<int> have; for (auto& c : conns) have.insert(c.innovation);
            std::set<int> nodeIDs; for (auto& n : nodes) nodeIDs.insert(n.id);
            for (auto& c : gb.connections) {
                if (have.count(c.innovation)) continue;
                for (int id : {c.from, c.to}) {
                    if (nodeIDs.count(id)) continue;
                    for (auto& n : gb.nodes) if (n.id == id) { nodes.push_back(n); nodeIDs.insert(id); break; }
                }
                conns.push_back(c);
            }
            sortNodes(nodes); sortConns(conns);
            if (!nl_.recurrent && hasCycle(nodes, conns)) {
                std::set<int> inA; for (auto& c : ga.connections) inA.insert(c.innovation);
                std::vector<NEATConnection> f; for (auto& c : conns) if (inA.count(c.innovation)) f.push_back(c);
                conns = std::move(f); nodes = ga.nodes;
            }
        }
        std::unordered_map<int, const NEATNode*> bnodes;
        for (auto& n : gb.nodes) bnodes.emplace(n.id, &n);   // first wins (uniquingKeysWith keeps the first)
        for (auto& n : nodes) {
            if (n.kind != NEATNodeKind::Hidden && n.kind != NEATNodeKind::Output) continue;
            auto it = bnodes.find(n.id);
            if (it != bnodes.end() && rng_.nextDouble() < 0.5) n.bias = it->second->bias;
        }
        std::vector<double> values = a.values;
        if (!layout_.genes.empty()) {
            std::vector<double> v;
            if (hooks && hooks->crossover(a, b, layout_, rng_, v)) values = v;
            else values = ops::crossover(CrossoverMethod::Uniform, a.values, b.values, layout_, 0.5, 15, rng_);
        }
        Genome g; g.id = 0; g.values = std::move(values);
        NEATGenome ng; ng.nodes = std::move(nodes); ng.connections = std::move(conns);
        g.neat = std::move(ng); g.parents = {a.id, b.id}; g.origin = "crossover";
        return g;
    }

    static bool hasCycle(const std::vector<NEATNode>& nodes, const std::vector<NEATConnection>& conns) {
        std::unordered_map<int, std::vector<int>> adj;
        for (auto& c : conns) if (c.enabled) adj[c.from].push_back(c.to);
        std::unordered_map<int, uint8_t> state;
        std::function<bool(int)> dfs = [&](int u) -> bool {
            state[u] = 1;
            auto it = adj.find(u);
            if (it != adj.end()) for (int v : it->second) {
                auto sv = state.find(v);
                if (sv != state.end() && sv->second == 1) return true;
                if (sv == state.end() && dfs(v)) return true;
            }
            state[u] = 2; return false;
        };
        for (auto& n : nodes) if (!state.count(n.id) && dfs(n.id)) return true;
        return false;
    }

    static bool reaches(const NEATGenome& g, int from, int to) {
        if (from == to) return true;
        std::vector<int> stack{from}; std::set<int> seen{from};
        while (!stack.empty()) {
            int u = stack.back(); stack.pop_back();
            for (auto& c : g.connections) {
                if (!c.enabled || c.from != u) continue;
                if (c.to == to) return true;
                if (seen.insert(c.to).second) stack.push_back(c.to);
            }
        }
        return false;
    }

    void mutate(Genome& child) {
        if (!child.neat) return;
        NEATGenome g = *child.neat;
        if (rng_.nextDouble() < p_.wRate) {
            for (auto& c : g.connections) {
                if (rng_.nextDouble() < p_.wReplace) c.weight = rng_.gaussian() * p_.initSigma;
                else c.weight += rng_.gaussian() * p_.wSigma;
                c.weight = smin(smax(c.weight, -p_.wRange), p_.wRange);
            }
        }
        if (rng_.nextDouble() < p_.bRate) {
            for (auto& n : g.nodes) {
                if (n.kind != NEATNodeKind::Hidden && n.kind != NEATNodeKind::Output) continue;
                if (rng_.nextDouble() < p_.wReplace) n.bias = rng_.gaussian() * p_.initSigma;
                else n.bias += rng_.gaussian() * p_.wSigma;
                n.bias = smin(smax(n.bias, -p_.wRange), p_.wRange);
            }
        }
        if (rng_.nextDouble() < p_.addConn) {
            std::vector<int> froms, tos;
            for (auto& n : g.nodes) { if (nl_.recurrent || n.kind != NEATNodeKind::Output) froms.push_back(n.id); if (n.kind == NEATNodeKind::Hidden || n.kind == NEATNodeKind::Output) tos.push_back(n.id); }
            if (!froms.empty() && !tos.empty()) for (int attempt = 0; attempt < 20; ++attempt) {
                int f = froms[static_cast<std::size_t>(rng_.intBelow(int(froms.size())))], t = tos[static_cast<std::size_t>(rng_.intBelow(int(tos.size())))];
                int k = -1;
                for (std::size_t i = 0; i < g.connections.size(); ++i) if (g.connections[i].from == f && g.connections[i].to == t) { k = int(i); break; }
                if (k >= 0) {
                    if (!g.connections[static_cast<std::size_t>(k)].enabled && (nl_.recurrent || !reaches(g, t, f))) { g.connections[static_cast<std::size_t>(k)].enabled = true; break; }
                    continue;
                }
                if (!nl_.recurrent && reaches(g, t, f)) continue;
                int inn = innovation(f, t);
                g.connections.push_back({inn, f, t, rng_.gaussian() * p_.initSigma, true});
                sortConns(g.connections);
                break;
            }
        }
        if (rng_.nextDouble() < p_.addNode) {
            std::vector<int> enabled;
            for (std::size_t i = 0; i < g.connections.size(); ++i) if (g.connections[i].enabled) enabled.push_back(int(i));
            if (!enabled.empty()) {
                int k = enabled[static_cast<std::size_t>(rng_.intBelow(int(enabled.size())))];
                NEATConnection c = g.connections[static_cast<std::size_t>(k)];
                g.connections[static_cast<std::size_t>(k)].enabled = false;
                int nid;
                auto it = splitNodes_.find(c.innovation);
                bool inGenome = false;
                if (it != splitNodes_.end()) for (auto& n : g.nodes) if (n.id == it->second) { inGenome = true; break; }
                if (it != splitNodes_.end() && !inGenome) nid = it->second;
                else { nid = nextNodeID_++; if (it == splitNodes_.end()) splitNodes_[c.innovation] = nid; }
                g.nodes.push_back({nid, NEATNodeKind::Hidden, nl_.hiddenActivation, 0});
                sortNodes(g.nodes);
                int i1 = innovation(c.from, nid);
                g.connections.push_back({i1, c.from, nid, 1, true});
                int i2 = innovation(nid, c.to);
                g.connections.push_back({i2, nid, c.to, c.weight, true});
                sortConns(g.connections);
            }
        }
        if (rng_.nextDouble() < p_.disable && !g.connections.empty()) {
            std::size_t k = static_cast<std::size_t>(rng_.intBelow(int(g.connections.size())));
            auto& c = g.connections[k];
            if (c.enabled) c.enabled = false;
            else if (nl_.recurrent || !reaches(g, c.to, c.from)) g.connections[k].enabled = true;
        }
        child.neat = std::move(g);
        if (!layout_.genes.empty()) {
            std::vector<double> v;
            if (hooks && hooks->mutate(child, layout_, p_.valueRate, rng_, v)) child.values = v;
            else child.values = ops::mutate(MutationMethod::Gaussian, child.values, layout_, p_.valueRate, 1, 20, rng_);
            if (int(child.values.size()) != layout_.count())
                throw EvoError("invalid experiment: mutate hook returned " + std::to_string(child.values.size()) + " genes, expected " + std::to_string(layout_.count()));
            layout_.legalize(child.values);
        }
    }

    const Genome* bestGenome() const override { return best_.genome && best_.fitness ? &*best_.genome : nullptr; }
    const Fitness* bestFitness() const override { return best_.genome && best_.fitness ? &*best_.fitness : nullptr; }
    std::vector<SpeciesInfo> species() const override { return speciesInfo_; }
    std::map<std::string, double> diagnostics() const override {
        int hidden = 0, conns = 0;
        if (best_.genome && best_.genome->neat) {
            for (auto& n : best_.genome->neat->nodes) if (n.kind == NEATNodeKind::Hidden) ++hidden;
            for (auto& c : best_.genome->neat->connections) if (c.enabled) ++conns;
        }
        return {{"species", double(species_.size())}, {"compatThreshold", compatThreshold_}, {"innovations", double(nextInnovation_ - 1)},
                {"bestHidden", double(hidden)}, {"bestConnections", double(conns)}, {"stagnation", double(stagnation_)}};
    }
    std::string saveState() const override {
        Value o = Value::object();
        o.set("rng", rng_.toJson()); o.set("generation", Value::i64(gen_)); o.set("nextID", Value::u64(nextID_));
        o.set("nextNodeID", Value::i64(nextNodeID_)); o.set("nextInnovation", Value::i64(nextInnovation_));
        Value inn = Value::object(); for (auto& [k, v] : innovations_) inn.set(k, Value::i64(v));
        o.set("innovations", std::move(inn));
        Value sp = Value::object(); for (auto& [k, v] : splitNodes_) sp.set(std::to_string(k), Value::i64(v));
        o.set("splitNodes", std::move(sp));
        o.set("pending", genomesJson(pending_));
        Value ss = Value::array();
        for (auto& s : species_) {
            Value e = Value::object();
            e.set("id", Value::i64(s.id)); e.set("representative", toJson(s.representative));
            Value m = Value::array(); for (int x : s.members) m.push(Value::i64(x));
            e.set("members", std::move(m)); e.set("bestEver", Value::number(s.bestEver)); e.set("staleness", Value::i64(s.staleness)); e.set("created", Value::i64(s.created));
            ss.push(std::move(e));
        }
        o.set("species", std::move(ss));
        o.set("nextSpeciesID", Value::i64(nextSpeciesID_)); o.set("compatThreshold", Value::number(compatThreshold_));
        putBest(o, "best", "bestFit", best_);
        Value si = Value::array(); for (auto& s : speciesInfo_) si.push(toJson(s));
        o.set("speciesInfo", std::move(si)); o.set("stagnation", Value::i64(stagnation_));
        return json::dump(o);
    }
    void restore(const std::string& str) override {
        Value o = parseState(str);
        rng_ = EvoRNG::fromJson(o["rng"]); gen_ = js::integer(o, "generation", 0); nextID_ = js::u64(o, "nextID", 1);
        nextNodeID_ = js::integer(o, "nextNodeID", nextNodeID_); nextInnovation_ = js::integer(o, "nextInnovation", 1);
        innovations_.clear(); for (auto& [k, v] : o["innovations"].members()) innovations_[k] = int(v.asI64());
        splitNodes_.clear(); for (auto& [k, v] : o["splitNodes"].members()) splitNodes_[std::atoi(k.c_str())] = int(v.asI64());
        pending_ = genomesFrom(o["pending"]);
        species_.clear();
        for (auto& e : o["species"].items()) {
            Species s; s.id = js::integer(e, "id", 0); s.representative = neatGenomeFromJson(e["representative"]);
            for (auto& m : e["members"].items()) s.members.push_back(int(m.asI64()));
            s.bestEver = js::num(e, "bestEver", s.bestEver); s.staleness = js::integer(e, "staleness", 0); s.created = js::integer(e, "created", 0);
            species_.push_back(std::move(s));
        }
        nextSpeciesID_ = js::integer(o, "nextSpeciesID", 1); compatThreshold_ = js::num(o, "compatThreshold", 3);
        getBest(o, "best", "bestFit", best_);
        speciesInfo_.clear(); for (auto& e : o["speciesInfo"].items()) speciesInfo_.push_back(speciesFromJson(e));
        stagnation_ = js::integer(o, "stagnation", 0);
    }
private:
    GenomeLayout layout_; NEATLayout nl_; int pop_ = 2; P p_;
    EvoRNG rng_; int gen_ = 0; uint64_t nextID_ = 1; int nextNodeID_ = 0, nextInnovation_ = 1;
    std::map<std::string, int> innovations_; std::map<int, int> splitNodes_;
    std::vector<Genome> pending_; std::vector<Species> species_; int nextSpeciesID_ = 1; double compatThreshold_ = 3;
    BestPair best_; std::vector<SpeciesInfo> speciesInfo_; int stagnation_ = 0;
};

// MARK: - MAP-Elites
int nearestCentroid(const std::vector<std::vector<double>>& c, const std::vector<double>& x) {
    int b = 0; double bd = INFINITY;
    for (std::size_t j = 0; j < c.size(); ++j) {
        double s = 0;
        for (std::size_t q = 0; q < x.size(); ++q) { double t = c[j][q] - x[q]; s += t * t; }
        if (s < bd) { bd = s; b = int(j); }
    }
    return b;
}

class MAPElites final : public Algorithm {
public:
    MAPElites(const GenomeLayout& layout, const AlgorithmParams& p, int population, uint64_t seed) : layout_(layout) {
        if (layout.count() == 0) throw EvoError("invalid experiment: map-elites needs at least one flat gene (NEAT genomes are not supported)");
        auto axes = axesParam(p);
        if (axes.empty()) throw EvoError("invalid experiment: map-elites needs descriptor axes (experiment.descriptorAxes) and a descriptor() hook");
        for (auto& a : axes) if (!(a.max > a.min) || a.bins < 1) throw EvoError("invalid experiment: descriptor axis '" + a.name + "': need max > min and bins >= 1");
        batch_ = std::max(1, p.integer("batch", population));
        initialRandom_ = std::max(1, p.integer("initialRandom", population));
        isoSigma_ = p.num("isoSigma", p.num("mutationSigma", 0.5));
        lineSigma_ = p.num("lineSigma", 0.2);
        rng_ = EvoRNG(seed);
        int cvt = p.integer("cvt", 0);
        if (cvt > 0) centroids_ = cvtCentroids(axes, cvt, rng_);
        archive_.axes = axes;
    }
    static std::vector<std::vector<double>> cvtCentroids(const std::vector<DescriptorAxis>& axes, int k, EvoRNG& rng) {
        std::size_t d = axes.size(); int ns = std::max(k * 25, 2000);
        std::vector<std::vector<double>> samples(static_cast<std::size_t>(ns), std::vector<double>(d));
        for (auto& s : samples) for (auto& x : s) x = rng.nextDouble();
        std::vector<std::vector<double>> c;
        for (int j = 0; j < k; ++j) c.push_back(samples[static_cast<std::size_t>(rng.intBelow(ns))]);
        for (int it = 0; it < 30; ++it) {
            std::vector<std::vector<double>> sum(static_cast<std::size_t>(k), std::vector<double>(d, 0.0));
            std::vector<int> cnt(static_cast<std::size_t>(k), 0);
            for (auto& s : samples) { int j = nearestCentroid(c, s); cnt[static_cast<std::size_t>(j)] += 1; for (std::size_t q = 0; q < d; ++q) sum[static_cast<std::size_t>(j)][q] += s[q]; }
            for (int j = 0; j < k; ++j) if (cnt[static_cast<std::size_t>(j)] > 0) for (std::size_t q = 0; q < d; ++q) c[static_cast<std::size_t>(j)][q] = sum[static_cast<std::size_t>(j)][q] / double(cnt[static_cast<std::size_t>(j)]);
        }
        return c;
    }
    std::optional<int> cell(const std::vector<double>& d) const {
        if (centroids_.empty()) return archive_.cellIndex(d);
        if (d.size() != archive_.axes.size()) return std::nullopt;
        for (double v : d) if (!std::isfinite(v)) return std::nullopt;
        std::vector<double> x(d.size());
        for (std::size_t i = 0; i < d.size(); ++i) { auto& a = archive_.axes[i]; x[i] = smin(1, smax(0, (d[i] - a.min) / (a.max - a.min))); }
        return nearestCentroid(centroids_, x);
    }
    const char* kind() const override { return "map-elites"; }
    int generation() const override { return gen_; }
    std::vector<Genome> ask() override {
        std::vector<Genome> out;
        std::vector<int> keys; for (auto& kv : archive_.cells) keys.push_back(kv.first);
        bool random = evaluated_ < initialRandom_ || keys.empty();
        for (int k = 0; k < batch_; ++k) {
            std::vector<double> v; std::string origin; std::vector<uint64_t> parents;
            if (random) { v = layout_.randomValues(rng_); origin = "random"; }
            else {
                const Genome& a = archive_.cells.at(keys[static_cast<std::size_t>(rng_.intBelow(int(keys.size())))]).genome;
                const Genome& b = archive_.cells.at(keys[static_cast<std::size_t>(rng_.intBelow(int(keys.size())))]).genome;
                parents = {a.id, b.id}; origin = "emitter";
                bool done = false;
                if (hooks) { std::vector<double> x; if (hooks->crossover(a, b, layout_, rng_, x)) { v = x; done = true; } }
                if (!done && hooks) { std::vector<double> m; if (hooks->mutate(a, layout_, isoSigma_, rng_, m)) { v = m; done = true; } }
                if (!done) v = ops::isoLine(a.values, b.values, layout_, isoSigma_, lineSigma_, rng_);
                if (int(v.size()) != layout_.count()) throw EvoError("invalid experiment: hook returned " + std::to_string(v.size()) + " genes, expected " + std::to_string(layout_.count()));
            }
            layout_.legalize(v);
            Genome g; g.id = nextID_++; g.values = std::move(v); g.parents = std::move(parents); g.origin = origin; g.generation = gen_;
            out.push_back(std::move(g));
        }
        return out;
    }
    void tell(const std::vector<Genome>& genomes, const std::vector<Fitness>& fitness) override {
        if (genomes.size() != fitness.size()) throw EvoError("tell: genomes/fitness count mismatch");
        int ins = 0, imp = 0;
        for (std::size_t i = 0; i < genomes.size(); ++i) {
            const Fitness& f = fitness[i];
            if (f.error || !f.descriptor) continue;
            auto c = cell(*f.descriptor);
            if (!c) continue;
            auto it = archive_.cells.find(*c);
            if (it != archive_.cells.end()) {
                if (ops::score(f) > ops::score(it->second.fitness)) { it->second = Elite{genomes[i], f, gen_}; ++imp; }
            } else { archive_.cells[*c] = Elite{genomes[i], f, gen_}; ++ins; }
        }
        lastInserted_ = ins; lastImproved_ = imp;
        evaluated_ += int(genomes.size());
        ++gen_;
    }
    const Elite* bestElite() const {
        const Elite* r = nullptr;
        for (auto& [k, e] : archive_.cells) {
            if (!r) { r = &e; continue; }
            double a = ops::score(r->fitness), b = ops::score(e.fitness);
            bool less = a != b ? a < b : r->genome.id > e.genome.id;
            if (less) r = &e;
        }
        return r;
    }
    const Genome* bestGenome() const override { auto e = bestElite(); return e ? &e->genome : nullptr; }
    const Fitness* bestFitness() const override { auto e = bestElite(); return e ? &e->fitness : nullptr; }
    const EliteArchive* archive() const override { return &archive_; }
    std::map<std::string, double> diagnostics() const override {
        int cap = centroids_.empty() ? archive_.capacity() : int(centroids_.size());
        double qd = 0; for (auto& [k, e] : archive_.cells) qd = qd + ops::score(e.fitness);
        return {{"coverage", double(archive_.cells.size()) / double(std::max(1, cap))}, {"filled", double(archive_.cells.size())},
                {"qdScore", qd}, {"inserted", double(lastInserted_)}, {"improved", double(lastImproved_)}, {"cvt", double(centroids_.size())}};
    }
    std::string saveState() const override {
        Value o = Value::object();
        o.set("rng", rng_.toJson()); o.set("generation", Value::i64(gen_)); o.set("nextID", Value::u64(nextID_));
        o.set("archive", toJson(archive_)); o.set("evaluated", Value::i64(evaluated_));
        Value c = Value::array(); for (auto& x : centroids_) c.push(js::arr(x));
        o.set("centroids", std::move(c)); o.set("lastInserted", Value::i64(lastInserted_)); o.set("lastImproved", Value::i64(lastImproved_));
        return json::dump(o);
    }
    void restore(const std::string& s) override {
        Value o = parseState(s);
        rng_ = EvoRNG::fromJson(o["rng"]); gen_ = js::integer(o, "generation", 0); nextID_ = js::u64(o, "nextID", 1);
        archive_ = archiveFromJson(o["archive"]); evaluated_ = js::integer(o, "evaluated", 0);
        centroids_.clear(); for (auto& x : o["centroids"].items()) centroids_.push_back(js::nums(x));
        lastInserted_ = js::integer(o, "lastInserted", 0); lastImproved_ = js::integer(o, "lastImproved", 0);
    }
private:
    GenomeLayout layout_; int batch_ = 1, initialRandom_ = 1; double isoSigma_ = 0.5, lineSigma_ = 0.2;
    EvoRNG rng_; int gen_ = 0; uint64_t nextID_ = 1; EliteArchive archive_; int evaluated_ = 0;
    std::vector<std::vector<double>> centroids_; int lastInserted_ = 0, lastImproved_ = 0;
};

// MARK: - novelty search
class Novelty final : public Algorithm {
public:
    Novelty(const GenomeLayout& layout, const AlgorithmParams& p, int population, uint64_t seed) : layout_(layout) {
        if (layout.count() == 0) throw EvoError("invalid experiment: novelty needs at least one flat gene");
        pop_ = std::max(2, population);
        k_ = std::max(1, p.integer("k", 15)); fitnessWeight_ = smin(1, smax(0, p.num("fitnessWeight", 0)));
        addProb_ = p.num("archiveAddProbability", 0); maxArchive_ = std::max(1, p.integer("maxArchive", 5000));
        tournament_ = std::max(1, p.integer("tournamentSize", 3)); elitism_ = std::max(0, std::min(pop_ - 1, p.integer("elitism", 1)));
        mutationRate_ = p.num("mutationRate", 1 / double(layout.count())); mutationSigma_ = p.num("mutationSigma", 1);
        crossoverRate_ = p.num("crossoverRate", 0.3);
        rng_ = EvoRNG(seed);
        archive_.axes = axesParam(p);
        threshold_ = p.num("threshold", 0);
    }
    const char* kind() const override { return "novelty"; }
    int generation() const override { return gen_; }
    Genome mk(std::vector<double> v, const char* o, std::vector<uint64_t> par) {
        Genome g; g.id = nextID_++; g.values = std::move(v); g.parents = std::move(par); g.origin = o; g.generation = gen_; return g;
    }
    std::vector<Genome> ask() override {
        std::vector<Genome> out;
        if (population_.empty()) { for (int k = 0; k < pop_; ++k) out.push_back(mk(layout_.randomValues(rng_), "init", {})); return out; }
        const auto& pop = population_;
        auto order = ops::rankOrder(scores_);
        for (int e = 0; e < elitism_ && e < int(order.size()); ++e) {
            Genome g = pop[static_cast<std::size_t>(order[static_cast<std::size_t>(e)])];
            g.parents = {g.id}; g.id = nextID_++; g.origin = "elite"; g.generation = gen_;
            out.push_back(std::move(g));
        }
        int nc = pop_ - int(out.size());
        std::vector<int> sel; bool fromHook = false;
        if (hooks) fromHook = hooks->select(pop, fitness_, 2 * nc, rng_, sel);
        if (fromHook) {
            bool bad = int(sel.size()) < 2 * nc;
            for (int x : sel) if (x < 0 || x >= int(pop.size())) bad = true;
            if (bad) throw EvoError("invalid experiment: select() must return " + std::to_string(2 * nc) + " indices in 0..<" + std::to_string(pop.size()));
        } else sel = ops::select(SelectionMethod::Tournament, scores_, 2 * nc, tournament_, rng_);
        for (int c = 0; c < nc; ++c) {
            const Genome& a = pop[static_cast<std::size_t>(sel[static_cast<std::size_t>(2 * c)])];
            const Genome& b = pop[static_cast<std::size_t>(sel[static_cast<std::size_t>(2 * c + 1)])];
            std::vector<double> v = a.values; const char* o = "mutation"; std::vector<uint64_t> par{a.id};
            if (rng_.nextDouble() < crossoverRate_) {
                std::vector<double> x;
                if (hooks && hooks->crossover(a, b, layout_, rng_, x)) v = x;
                else v = ops::crossover(CrossoverMethod::Uniform, a.values, b.values, layout_, 0.5, 15, rng_);
                o = "crossover"; par = {a.id, b.id};
            }
            Genome tmp; tmp.values = v; std::vector<double> m;
            if (hooks && hooks->mutate(tmp, layout_, mutationRate_, rng_, m)) v = m;
            else v = ops::mutate(MutationMethod::Gaussian, v, layout_, mutationRate_, mutationSigma_, 20, rng_);
            if (int(v.size()) != layout_.count()) throw EvoError("invalid experiment: hook returned " + std::to_string(v.size()) + " genes, expected " + std::to_string(layout_.count()));
            layout_.legalize(v);
            out.push_back(mk(std::move(v), o, std::move(par)));
        }
        return out;
    }
    std::vector<double> normalise(const std::vector<double>& d) const {
        const auto& ax = archive_.axes;
        if (ax.size() != d.size()) return d;
        std::vector<double> r(d.size());
        for (std::size_t i = 0; i < d.size(); ++i) r[i] = (d[i] - ax[i].min) / smax(1e-12, ax[i].max - ax[i].min);
        return r;
    }
    static double knn(const std::vector<double>& x, const std::vector<std::vector<double>>& pool, int k, int exclude) {
        std::vector<double> ds; ds.reserve(pool.size());
        for (std::size_t j = 0; j < pool.size(); ++j) {
            if (int(j) == exclude || pool[j].size() != x.size()) continue;
            double s = 0; for (std::size_t q = 0; q < x.size(); ++q) { double t = pool[j][q] - x[q]; s += t * t; }
            ds.push_back(std::sqrt(s));
        }
        if (ds.empty()) return 0;
        std::sort(ds.begin(), ds.end());
        int m = std::min(k, int(ds.size()));
        double sum = 0; for (int i = 0; i < m; ++i) sum += ds[static_cast<std::size_t>(i)];
        return sum / double(m);
    }
    void tell(const std::vector<Genome>& genomes, const std::vector<Fitness>& fitness) override {
        if (genomes.size() != fitness.size()) throw EvoError("tell: genomes/fitness count mismatch");
        std::size_t N = genomes.size();
        std::vector<std::optional<std::vector<double>>> descs(N);
        for (std::size_t i = 0; i < N; ++i) {
            auto& f = fitness[i];
            if (f.error || !f.descriptor) continue;
            bool fin = true; for (double v : *f.descriptor) if (!std::isfinite(v)) fin = false;
            if (fin) descs[i] = normalise(*f.descriptor);
        }
        std::vector<std::vector<double>> pool;
        for (auto& d : descs) if (d) pool.push_back(*d);
        pool.insert(pool.end(), archive_.noveltyPoints.begin(), archive_.noveltyPoints.end());
        std::vector<double> nov(N, 0.0);
        int pi = 0;
        for (std::size_t i = 0; i < N; ++i) if (descs[i]) { nov[i] = knn(*descs[i], pool, k_, pi); ++pi; }
        lastNovelty_ = nov;
        if (threshold_ <= 0) {
            std::vector<double> v; for (double x : nov) if (x > 0) v.push_back(x);
            std::sort(v.begin(), v.end());
            threshold_ = v.empty() ? 0 : v[v.size() / 2];
        }
        int added = 0;
        for (std::size_t i = 0; i < N; ++i) {
            if (!descs[i]) continue;
            if ((threshold_ > 0 && nov[i] > threshold_) || rng_.nextDouble() < addProb_) { archive_.noveltyPoints.push_back(*descs[i]); ++added; }
            Fitness f = fitness[i]; f.novelty = nov[i];
            if (fitness[i].descriptor) {
                auto c = archive_.cellIndex(*fitness[i].descriptor);
                if (c) {
                    auto it = archive_.cells.find(*c);
                    if (!(it != archive_.cells.end() && ops::score(it->second.fitness) >= ops::score(f))) archive_.cells[*c] = Elite{genomes[i], f, gen_};
                }
            }
        }
        if (int(archive_.noveltyPoints.size()) > maxArchive_)
            archive_.noveltyPoints.erase(archive_.noveltyPoints.begin(), archive_.noveltyPoints.begin() + std::ptrdiff_t(int(archive_.noveltyPoints.size()) - maxArchive_));
        if (added > 4) { threshold_ *= 1.2; noAddStreak_ = 0; }
        else if (added == 0) { noAddStreak_ += 1; if (noAddStreak_ >= 5) { threshold_ *= 0.95; noAddStreak_ = 0; } }
        else noAddStreak_ = 0;
        lastAdded_ = added;
        auto fs = ops::scores(fitness);
        auto ranks = [](const std::vector<double>& x) {
            std::vector<double> r(x.size(), 0.0);
            auto o = ops::rankOrder(x);
            for (std::size_t k = 0; k < o.size(); ++k) r[static_cast<std::size_t>(o[k])] = x.size() > 1 ? double(x.size() - 1 - k) / double(x.size() - 1) : 1;
            return r;
        };
        auto rn = ranks(nov), rf = ranks(fs);
        scores_.assign(N, 0.0);
        for (std::size_t i = 0; i < N; ++i) scores_[i] = (1 - fitnessWeight_) * rn[i] + fitnessWeight_ * rf[i];
        for (std::size_t i = 0; i < N; ++i)
            if (fs[i] > best_.score()) { best_.genome = genomes[i]; Fitness f = fitness[i]; f.novelty = nov[i]; best_.fitness = f; }
        population_ = genomes;
        fitness_ = fitness; for (std::size_t i = 0; i < N; ++i) fitness_[i].novelty = nov[i];
        ++gen_;
    }
    const Genome* bestGenome() const override { return best_.genome && best_.fitness ? &*best_.genome : nullptr; }
    const Fitness* bestFitness() const override { return best_.genome && best_.fitness ? &*best_.fitness : nullptr; }
    const EliteArchive* archive() const override { return &archive_; }
    std::map<std::string, double> diagnostics() const override {
        double m = 0, mx = 0;
        if (!lastNovelty_.empty()) { double s = 0; for (double x : lastNovelty_) s += x; m = s / double(lastNovelty_.size()); mx = lastNovelty_[0]; for (double x : lastNovelty_) if (x > mx) mx = x; }
        return {{"archiveSize", double(archive_.noveltyPoints.size())}, {"threshold", threshold_}, {"added", double(lastAdded_)}, {"meanNovelty", m}, {"maxNovelty", mx}};
    }
    const std::vector<double>& lastNovelty() const { return lastNovelty_; }
    std::string saveState() const override {
        Value o = Value::object();
        o.set("rng", rng_.toJson()); o.set("generation", Value::i64(gen_)); o.set("nextID", Value::u64(nextID_));
        o.set("population", genomesJson(population_)); o.set("fitness", fitnessesJson(fitness_)); o.set("scores", js::arr(scores_));
        o.set("archive", toJson(archive_)); o.set("threshold", Value::number(threshold_));
        o.set("noAddStreak", Value::i64(noAddStreak_)); o.set("lastAdded", Value::i64(lastAdded_));
        putBest(o, "best", "bestFit", best_);
        o.set("lastNovelty", js::arr(lastNovelty_));
        return json::dump(o);
    }
    void restore(const std::string& s) override {
        Value o = parseState(s);
        rng_ = EvoRNG::fromJson(o["rng"]); gen_ = js::integer(o, "generation", 0); nextID_ = js::u64(o, "nextID", 1);
        population_ = genomesFrom(o["population"]); fitness_ = fitnessesFrom(o["fitness"]); scores_ = js::nums(o["scores"]);
        archive_ = archiveFromJson(o["archive"]); threshold_ = js::num(o, "threshold", 0);
        noAddStreak_ = js::integer(o, "noAddStreak", 0); lastAdded_ = js::integer(o, "lastAdded", 0);
        getBest(o, "best", "bestFit", best_);
        lastNovelty_ = js::nums(o["lastNovelty"]);
    }
private:
    GenomeLayout layout_; int pop_ = 2, k_ = 15; double fitnessWeight_ = 0, addProb_ = 0; int maxArchive_ = 5000;
    int tournament_ = 3, elitism_ = 1; double mutationRate_ = 0.1, mutationSigma_ = 1, crossoverRate_ = 0.3;
    EvoRNG rng_; int gen_ = 0; uint64_t nextID_ = 1;
    std::vector<Genome> population_; std::vector<Fitness> fitness_; std::vector<double> scores_;
    EliteArchive archive_; double threshold_ = 0; int noAddStreak_ = 0, lastAdded_ = 0; BestPair best_; std::vector<double> lastNovelty_;
};
} // namespace

std::unique_ptr<Algorithm> makeNEAT(const GenomeLayout& l, const AlgorithmParams& p, int population, uint64_t seed) { return std::make_unique<NEATAlgo>(l, p, population, seed); }
std::unique_ptr<Algorithm> makeMAPElites(const GenomeLayout& l, const AlgorithmParams& p, int population, uint64_t seed) { return std::make_unique<MAPElites>(l, p, population, seed); }
std::unique_ptr<Algorithm> makeNovelty(const GenomeLayout& l, const AlgorithmParams& p, int population, uint64_t seed) { return std::make_unique<Novelty>(l, p, population, seed); }
} // namespace pw::evo
