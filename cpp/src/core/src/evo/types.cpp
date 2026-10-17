#include "pw/evo/types.h"
#include <algorithm>
#include <cstdlib>

namespace pw::evo {

// MARK: - js helpers
namespace js {
Value arr(const std::vector<double>& v) { Value a = Value::array(); for (double x : v) a.push(Value::number(x)); return a; }
Value arrStr(const std::vector<std::string>& v) { Value a = Value::array(); for (auto& x : v) a.push(Value::string(x)); return a; }
std::vector<double> nums(const Value& v) { std::vector<double> o; if (v.isArray()) { o.reserve(v.size()); for (auto& x : v.items()) o.push_back(x.num(NAN)); } return o; }
std::vector<std::string> strs(const Value& v) { std::vector<std::string> o; if (v.isArray()) for (auto& x : v.items()) if (x.isString()) o.push_back(x.str()); return o; }
double num(const Value& o, const char* k, double d) { auto& v = o[k]; return v.isNumber() ? v.num() : d; }
int integer(const Value& o, const char* k, int d) { auto& v = o[k]; return v.isNumber() ? int(v.asI64(d)) : d; }
uint64_t u64(const Value& o, const char* k, uint64_t d) { auto& v = o[k]; return v.isNumber() ? v.asU64(d) : d; }
bool boolean(const Value& o, const char* k, bool d) { auto& v = o[k]; return v.type() == Value::Type::Bool ? v.boolean() : d; }
std::string str(const Value& o, const char* k, const std::string& d) { auto& v = o[k]; return v.isString() ? v.str() : d; }
std::optional<double> optNum(const Value& o, const char* k) { auto& v = o[k]; if (v.isNumber()) return v.num(); return std::nullopt; }
double reqNum(const Value& o, const char* k) {
    auto& v = o[k];
    if (!v.isNumber()) throw EvoError(std::string("JSON: missing number '") + k + "'");
    return v.num();
}
std::string reqStr(const Value& o, const char* k) {
    auto& v = o[k];
    if (!v.isString()) throw EvoError(std::string("JSON: missing string '") + k + "'");
    return v.str();
}
}

// MARK: - RNG
Value EvoRNG::toJson() const {
    Value o = Value::object();
    o.set("s0", Value::u64(s0)); o.set("s1", Value::u64(s1)); o.set("s2", Value::u64(s2)); o.set("s3", Value::u64(s3));
    return o;
}
EvoRNG EvoRNG::fromJson(const Value& v) {
    EvoRNG r;
    r.s0 = js::u64(v, "s0", 0); r.s1 = js::u64(v, "s1", 0); r.s2 = js::u64(v, "s2", 0); r.s3 = js::u64(v, "s3", 0);
    return r;
}

// MARK: - genes
const char* geneKindName(GeneKind k) { return k == GeneKind::Int ? "int" : k == GeneKind::Bool ? "bool" : "real"; }
GeneKind geneKindFrom(const std::string& s) {
    if (s == "real") return GeneKind::Real;
    if (s == "int") return GeneKind::Int;
    if (s == "bool") return GeneKind::Bool;
    throw EvoError("gene kind must be real, int or bool (got '" + s + "')");
}

int GenomeLayout::index(const std::string& name) const {
    for (std::size_t i = 0; i < genes.size(); ++i) if (genes[i].name == name) return int(i);
    return -1;
}
std::pair<int, int> GenomeLayout::range(const std::string& group) const {
    int a = -1, b = -1;
    for (std::size_t i = 0; i < genes.size(); ++i) if (genes[i].group == group) { if (a < 0) a = int(i); b = int(i); }
    if (a < 0) return {-1, -1};
    return {a, b + 1};
}
std::vector<double> GenomeLayout::randomValues(EvoRNG& rng) const {
    std::vector<double> v; v.reserve(genes.size());
    for (auto& g : genes) {
        if (g.initial) { v.push_back(g.legalize(*g.initial)); continue; }
        if (g.kind == GeneKind::Bool) v.push_back(rng.nextDouble() < 0.5 ? 0 : 1);
        else v.push_back(g.legalize(g.min + (g.max - g.min) * rng.nextDouble()));
    }
    return v;
}
GenomeLayout GenomeLayout::operator+(const GenomeLayout& b) const {
    GenomeLayout r; r.genes = genes; r.genes.insert(r.genes.end(), b.genes.begin(), b.genes.end());
    r.neat = neat ? neat : b.neat;
    return r;
}

Summary summarize(const std::vector<double>& xs) {
    std::vector<double> v;
    for (double x : xs) if (std::isfinite(x) && x > kFailedFitness) v.push_back(x);
    if (v.empty()) return {};
    std::vector<double> s = v;
    std::stable_sort(s.begin(), s.end());
    double n = double(v.size()), sum = 0;
    for (double x : v) sum += x;
    double mean = sum / n;
    double med = s.size() % 2 == 1 ? s[s.size() / 2] : 0.5 * (s[s.size() / 2 - 1] + s[s.size() / 2]);
    double ss = 0;
    for (double x : v) ss = ss + (x - mean) * (x - mean);
    return {s.back(), mean, med, s.front(), std::sqrt(ss / n)};
}

std::optional<int> EliteArchive::cellIndex(const std::vector<double>& d) const {
    if (d.size() != axes.size()) return std::nullopt;
    int idx = 0;
    for (std::size_t k = 0; k < axes.size(); ++k) {
        double x = d[k];
        if (!std::isfinite(x)) return std::nullopt;
        auto& a = axes[k];
        int b = std::max(1, a.bins);
        double t = (x - a.min) / smax(1e-12, a.max - a.min);
        double tb = t * double(b);
        // Swift Int(t * b) truncates toward zero (and traps when out of range); clamp first, same result in range
        int ti = tb >= 2e9 ? 2000000000 : tb <= -2e9 ? -2000000000 : int(tb);
        idx = idx * b + std::min(b - 1, std::max(0, ti));
    }
    return idx;
}
std::vector<int> EliteArchive::coordinates(int cell) const {
    std::vector<int> c(axes.size(), 0);
    int r = cell;
    for (int i = int(axes.size()) - 1; i >= 0; --i) { int b = std::max(1, axes[std::size_t(i)].bins); c[std::size_t(i)] = r % b; r /= b; }
    return c;
}

const Value* AlgorithmParams::find(const std::string& k) const {
    for (auto& kv : values) if (kv.first == k) return &kv.second;
    return nullptr;
}
void AlgorithmParams::set(const std::string& k, Value v) {
    for (auto& kv : values) if (kv.first == k) { kv.second = std::move(v); return; }
    values.emplace_back(k, std::move(v));
}
// Swift JSONValue.double: number, bool (1/0) or numeric string
static std::optional<double> jsonDouble(const Value* v) {
    if (!v) return std::nullopt;
    if (v->isNumber()) return v->num();
    if (v->type() == Value::Type::Bool) return v->boolean() ? 1.0 : 0.0;
    if (v->isString()) {
        const std::string& s = v->str();
        if (s.empty()) return std::nullopt;
        char* end = nullptr;
        double d = std::strtod(s.c_str(), &end);
        if (end == s.c_str() + s.size()) return d;
    }
    return std::nullopt;
}
double AlgorithmParams::num(const std::string& k, double d) const { auto x = jsonDouble(find(k)); return x ? *x : d; }
int AlgorithmParams::integer(const std::string& k, int d) const {
    auto x = jsonDouble(find(k));
    if (!x || !std::isfinite(*x)) return d;
    return int(std::trunc(std::clamp(*x, -2e9, 2e9)));
}
std::string AlgorithmParams::string(const std::string& k, const std::string& d) const {
    const Value* v = find(k);
    if (v && v->isString()) return v->str();
    return d;
}
bool AlgorithmParams::boolean(const std::string& k, bool d) const { auto x = jsonDouble(find(k)); return x ? *x != 0 : d; }

// MARK: - codecs
Value toJson(const GeneSpec& g) {
    Value o = Value::object();
    o.set("name", Value::string(g.name));
    o.set("kind", Value::string(geneKindName(g.kind)));
    o.set("min", Value::number(g.min)); o.set("max", Value::number(g.max));
    if (g.initial) o.set("initial", Value::number(*g.initial));
    if (g.sigma) o.set("sigma", Value::number(*g.sigma));
    o.set("group", Value::string(g.group));
    return o;
}
GeneSpec geneSpecFromJson(const Value& v) {
    GeneSpec g;
    g.name = js::reqStr(v, "name");
    g.kind = geneKindFrom(js::str(v, "kind", "real"));
    g.min = js::num(v, "min", -1); g.max = js::num(v, "max", 1);
    g.initial = js::optNum(v, "initial"); g.sigma = js::optNum(v, "sigma");
    g.group = js::str(v, "group", "script");
    return g;
}
Value toJson(const NEATLayout& l) {
    Value o = Value::object();
    o.set("inputs", js::arrStr(l.inputs)); o.set("outputs", js::arrStr(l.outputs));
    o.set("hiddenActivation", Value::string(l.hiddenActivation)); o.set("outputActivation", Value::string(l.outputActivation));
    o.set("initialConnectivity", Value::string(l.initialConnectivity)); o.set("recurrent", Value::fromBool(l.recurrent));
    return o;
}
NEATLayout neatLayoutFromJson(const Value& v) {
    NEATLayout l;
    l.inputs = js::strs(v["inputs"]); l.outputs = js::strs(v["outputs"]);
    l.hiddenActivation = js::str(v, "hiddenActivation", "tanh"); l.outputActivation = js::str(v, "outputActivation", "tanh");
    l.initialConnectivity = js::str(v, "initialConnectivity", "full"); l.recurrent = js::boolean(v, "recurrent", false);
    return l;
}
Value toJson(const GenomeLayout& l) {
    Value o = Value::object(), g = Value::array();
    for (auto& x : l.genes) g.push(toJson(x));
    o.set("genes", std::move(g));
    if (l.neat) o.set("neat", toJson(*l.neat));
    return o;
}
GenomeLayout layoutFromJson(const Value& v) {
    GenomeLayout l;
    for (auto& g : v["genes"].items()) l.genes.push_back(geneSpecFromJson(g));
    if (v["neat"].isObject()) l.neat = neatLayoutFromJson(v["neat"]);
    return l;
}
static const char* nodeKindName(NEATNodeKind k) {
    switch (k) { case NEATNodeKind::Input: return "input"; case NEATNodeKind::Bias: return "bias"; case NEATNodeKind::Output: return "output"; default: return "hidden"; }
}
static NEATNodeKind nodeKindFrom(const std::string& s) {
    if (s == "input") return NEATNodeKind::Input;
    if (s == "bias") return NEATNodeKind::Bias;
    if (s == "output") return NEATNodeKind::Output;
    if (s == "hidden") return NEATNodeKind::Hidden;
    throw EvoError("NEAT node kind '" + s + "' unknown");
}
Value toJson(const NEATGenome& g) {
    Value o = Value::object(), n = Value::array(), c = Value::array();
    for (auto& x : g.nodes) {
        Value e = Value::object();
        e.set("id", Value::i64(x.id)); e.set("kind", Value::string(nodeKindName(x.kind)));
        e.set("activation", Value::string(x.activation)); e.set("bias", Value::number(x.bias));
        n.push(std::move(e));
    }
    for (auto& x : g.connections) {
        Value e = Value::object();
        e.set("innovation", Value::i64(x.innovation)); e.set("from", Value::i64(x.from)); e.set("to", Value::i64(x.to));
        e.set("weight", Value::number(x.weight)); e.set("enabled", Value::fromBool(x.enabled));
        c.push(std::move(e));
    }
    o.set("nodes", std::move(n)); o.set("connections", std::move(c));
    if (g.species) o.set("species", Value::i64(*g.species));
    return o;
}
NEATGenome neatGenomeFromJson(const Value& v) {
    NEATGenome g;
    for (auto& e : v["nodes"].items())
        g.nodes.push_back({js::integer(e, "id", 0), nodeKindFrom(js::str(e, "kind", "hidden")), js::str(e, "activation", "tanh"), js::num(e, "bias", 0)});
    for (auto& e : v["connections"].items())
        g.connections.push_back({js::integer(e, "innovation", 0), js::integer(e, "from", 0), js::integer(e, "to", 0), js::num(e, "weight", 0), js::boolean(e, "enabled", true)});
    if (v["species"].isNumber()) g.species = js::integer(v, "species", 0);
    return g;
}
Value toJson(const Genome& g) {
    Value o = Value::object();
    o.set("id", Value::u64(g.id));
    o.set("values", js::arr(g.values));
    if (g.neat) o.set("neat", toJson(*g.neat));
    Value p = Value::array(); for (auto x : g.parents) p.push(Value::u64(x));
    o.set("parents", std::move(p));
    o.set("origin", Value::string(g.origin));
    o.set("generation", Value::i64(g.generation));
    return o;
}
Genome genomeFromJson(const Value& v) {
    Genome g;
    g.id = js::u64(v, "id", 0);
    g.values = js::nums(v["values"]);
    if (v["neat"].isObject()) g.neat = neatGenomeFromJson(v["neat"]);
    for (auto& p : v["parents"].items()) g.parents.push_back(p.asU64());
    g.origin = js::str(v, "origin", "init");
    g.generation = js::integer(v, "generation", 0);
    return g;
}
Value toJson(const Fitness& f) {
    Value o = Value::object(), t = Value::object();
    o.set("total", Value::number(f.total));
    for (auto& [k, x] : f.terms) t.set(k, Value::number(x));
    o.set("terms", std::move(t));
    if (f.descriptor) o.set("descriptor", js::arr(*f.descriptor));
    if (f.novelty) o.set("novelty", Value::number(*f.novelty));
    o.set("episodes", Value::i64(f.episodes)); o.set("simSeconds", Value::number(f.simSeconds)); o.set("controlTicks", Value::i64(f.controlTicks));
    if (f.error) o.set("error", Value::string(*f.error));
    return o;
}
Fitness fitnessFromJson(const Value& v) {
    Fitness f;
    f.total = js::num(v, "total", 0);
    for (auto& [k, x] : v["terms"].members()) f.terms[k] = x.num();
    if (v["descriptor"].isArray()) f.descriptor = js::nums(v["descriptor"]);
    f.novelty = js::optNum(v, "novelty");
    f.episodes = js::integer(v, "episodes", 0); f.simSeconds = js::num(v, "simSeconds", 0); f.controlTicks = js::integer(v, "controlTicks", 0);
    if (v["error"].isString()) f.error = v["error"].str();
    return f;
}
Value toJson(const DescriptorAxis& a) {
    Value o = Value::object();
    o.set("name", Value::string(a.name)); o.set("min", Value::number(a.min)); o.set("max", Value::number(a.max)); o.set("bins", Value::i64(a.bins));
    return o;
}
DescriptorAxis axisFromJson(const Value& v) {
    DescriptorAxis a;
    a.name = js::reqStr(v, "name"); a.min = js::reqNum(v, "min"); a.max = js::reqNum(v, "max"); a.bins = js::integer(v, "bins", 20);
    return a;
}
std::vector<DescriptorAxis> axesFromJson(const Value& v) {
    if (!v.isArray()) throw EvoError("descriptor axes must be an array");
    std::vector<DescriptorAxis> o;
    for (auto& a : v.items()) o.push_back(axisFromJson(a));
    return o;
}
Value toJson(const EliteArchive& a) {
    Value o = Value::object(), ax = Value::array(), cells = Value::object(), np = Value::array();
    for (auto& x : a.axes) ax.push(toJson(x));
    // Swift JSONEncoder writes [Int: Elite] as an object keyed by the decimal cell index
    for (auto& [k, e] : a.cells) {
        Value ev = Value::object();
        ev.set("genome", toJson(e.genome)); ev.set("fitness", toJson(e.fitness)); ev.set("generation", Value::i64(e.generation));
        cells.set(std::to_string(k), std::move(ev));
    }
    for (auto& p : a.noveltyPoints) np.push(js::arr(p));
    o.set("axes", std::move(ax)); o.set("cells", std::move(cells)); o.set("noveltyPoints", std::move(np));
    return o;
}
EliteArchive archiveFromJson(const Value& v) {
    EliteArchive a;
    for (auto& x : v["axes"].items()) a.axes.push_back(axisFromJson(x));
    auto& c = v["cells"];
    auto elite = [](const Value& e) { return Elite{genomeFromJson(e["genome"]), fitnessFromJson(e["fitness"]), js::integer(e, "generation", 0)}; };
    if (c.isObject()) for (auto& [k, e] : c.members()) a.cells[std::atoi(k.c_str())] = elite(e);
    else for (std::size_t i = 0; i + 1 < c.size(); i += 2) a.cells[int(c[i].asI64())] = elite(c[i + 1]);   // [k, v, k, v] form
    for (auto& p : v["noveltyPoints"].items()) a.noveltyPoints.push_back(js::nums(p));
    return a;
}
Value toJson(const SpeciesInfo& s) {
    Value o = Value::object();
    o.set("id", Value::i64(s.id)); o.set("size", Value::i64(s.size)); o.set("bestFitness", Value::number(s.bestFitness));
    o.set("meanFitness", Value::number(s.meanFitness)); o.set("staleness", Value::i64(s.staleness));
    return o;
}
SpeciesInfo speciesFromJson(const Value& v) {
    return {js::integer(v, "id", 0), js::integer(v, "size", 0), js::num(v, "bestFitness", 0), js::num(v, "meanFitness", 0), js::integer(v, "staleness", 0)};
}
Value toJson(const AlgorithmParams& p) {
    Value o = Value::object(), vals = Value::object();
    o.set("kind", Value::string(p.kind));
    for (auto& [k, x] : p.values) vals.set(k, x);
    o.set("values", std::move(vals));
    return o;
}
AlgorithmParams paramsFromJson(const Value& v) {
    AlgorithmParams p;
    p.kind = js::str(v, "kind", "simple-es");
    for (auto& [k, x] : v["values"].members()) p.values.emplace_back(k, x);
    return p;
}

} // namespace pw::evo
