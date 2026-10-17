// Port of Sources/Physics/CraftSim.swift (+ the load-time parts of Slipstream.swift). Expression order and
// operation choice follow the Swift source line by line; see pw/math.h for the simd-equivalent primitives.
#include "pw/sim/craft_sim.h"
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <limits>
#include <map>

namespace pw::sim {

namespace {
constexpr double kInf = std::numeric_limits<double>::infinity();
inline bool isBodyType(std::optional<PartType> t) {
    if (!t) return false;
    switch (*t) {
    case PartType::Box: case PartType::Cylinder: case PartType::Cone: case PartType::Sphere: case PartType::Cad:
    case PartType::Tank: case PartType::Jet: case PartType::Solid: case PartType::Motor: return true;
    default: return false;
    }
}
/// Swift `Int(x)` description for output info strings.
std::string intStr(double v) { return std::to_string((long long)v); }
std::string swiftDouble(double v) { ParamValue p{v}; return *p.asString(); }
}

const char* outputKindName(OutputKind k) {
    switch (k) { case OutputKind::Servo: return "servo"; case OutputKind::Motor: return "motor"; case OutputKind::Jet: return "jet"; default: return "solid"; }
}

bool CraftSim::slipstreamDefault() {
    const char* e = std::getenv("PW_SLIPSTREAM");
    return !(e && std::string(e) == "0");
}

CraftSim::CraftSim() = default;
CraftSim::~CraftSim() = default;

// MARK: load / outputs ---------------------------------------------------------------------------------------------

bool CraftSim::load(const CraftSpec& craft, std::string* err) {
    craft_ = craft;
    loaded_ = true;
    std::map<std::string, int> idIndex;
    for (int i = 0; i < int(craft_.parts.size()); ++i) idIndex.emplace(craft_.parts[std::size_t(i)].id, i);   // first wins
    auto lookup = [&](const std::optional<std::string>& id) -> int {
        if (!id) return -1;
        auto it = idIndex.find(*id);
        return it == idIndex.end() ? -1 : it->second;
    };
    parts_.clear();
    meshes_.clear();
    for (int di = 0; di < int(craft_.parts.size()); ++di) {
        const PartSpec& d = craft_.parts[std::size_t(di)];
        auto t = d.partType();
        SimPart sp;
        sp.doc = di; sp.type = t;
        sp.basePos = d.position(); sp.baseQ = d.rotation(); sp.effQ = sp.baseQ;
        auto [sz, ct] = bounds(d);
        sp.size = sz; sp.ctr = ct;
        sp.servo = lookup(d.servo);
        sp.motor = lookup(d.motor);
        if (t == PartType::Wing) {
            std::string lower = d.name;
            for (auto& c : lower) c = char(std::tolower(static_cast<unsigned char>(c)));
            bool named = lower.find("flap") != std::string::npos;
            auto f = d.rawDouble("flap");
            sp.flapChord = f ? *f : (named ? 0.3 : 0);
        }
        if (t == PartType::Cad && d.cad) {
            if (auto soup = PanelMesh::decodePrototypeCAD(*d.cad, d.param("scale", 1))) {
                auto m = std::make_unique<PanelMesh>(*soup);
                if (m->count() > 0) { sp.mesh = int(meshes_.size()); meshes_.push_back(std::move(m)); }
            }
        }
        if ((t == PartType::Wheel || t == PartType::Prop) && sp.motor < 0) sp.autoMotor = true;
        if (isBodyType(t ? t : std::optional<PartType>(PartType::Box)) || t == PartType::Wing) {
            Vec3d h = sp.size * 0.5;
            for (double sx : {-1.0, 1.0}) for (double sy : {-1.0, 1.0}) for (double sz2 : {-1.0, 1.0})
                sp.corners.push_back(sp.ctr + hadamard(Vec3d{sx, sy, sz2}, h));
        }
        parts_.push_back(std::move(sp));
    }
    for (auto& p : parts_) {
        if (p.servo >= 0 && !parts_[std::size_t(p.servo)].is(PartType::Servo)) p.servo = -1;
        if (p.motor >= 0 && !parts_[std::size_t(p.motor)].is(PartType::Motor)) {
            p.motor = -1;
            if (p.is(PartType::Wheel) || p.is(PartType::Prop)) p.autoMotor = true;
        }
    }
    bakeParts();
    detectDucts(); allocWakes(); buildWingGroups();
    rebuildPanelBatch();
    rebuildStrips();
    wheelCount_ = 0;
    for (auto& p : parts_) if (p.is(PartType::Wheel)) ++wheelCount_;
    outputs_ = makeOutputs(craft_);
    // output -> part
    std::map<std::string, int> targets;
    for (int i = 0; i < int(parts_.size()); ++i) {
        SimPart& p = parts_[std::size_t(i)];
        const PartSpec& d = docOf(p);
        if (p.type && isOutputType(*p.type)) targets[d.id] = i;
        if (p.autoMotor) {
            std::string id = "auto-motor:" + d.id;
            targets[id] = i;
            std::string info = p.is(PartType::Prop) ? "auto motor \xC2\xB7 prop " + intStr(d.param("thrust")) + " N static"
                                                    : "auto motor \xC2\xB7 " + intStr(autoWheelTorque) + " N\xC2\xB7m";
            CraftOutput o; o.id = id; o.name = d.name + " motor"; o.kind = OutputKind::Motor;
            o.lo = p.is(PartType::Wheel) ? -1 : 0; o.hi = 1; o.info = info;
            outputs_.push_back(o);
        }
    }
    outputTargets_.assign(outputs_.size(), -1);
    for (std::size_t i = 0; i < outputs_.size(); ++i) { auto it = targets.find(outputs_[i].id); if (it != targets.end()) outputTargets_[i] = it->second; }
    buildHull();
    buildSensors();
    resetFuel();
    updateMassProperties(false);
    reset(restingSpawn());
    if (err) err->clear();
    return true;
}

void CraftSim::bake(SimPart& sp) {
    const PartSpec& d = docOf(sp);
    auto p = [&](const char* k, double def = 0) { return d.param(k, def); };
    auto t = sp.type;
    sp.isBody = isBodyType(t);
    sp.isWing = t == PartType::Wing;
    sp.invert = d.invert; sp.docMass = d.mass;
    sp.kRange = p("range"); sp.kTorque = p("torque"); sp.kSpeed = p("speed");
    sp.kCd = p("cd", 0.3);
    sp.kThrust = p("thrust"); sp.kD = p("d"); sp.kPropVmax = p("vmax", 80); sp.kSpin = p("spin", 1) < 0 ? -1 : 1;
    sp.kFlow = p("flow"); sp.kBurn = p("burn");
    sp.kR = p("r"); sp.kGrip = p("grip", 0.9); sp.kRoll = p("roll", 0.02);
    sp.kReversible = p("reversible"); sp.kMotorVmax = p("vmax", 20);
    sp.kChord = p("chord"); sp.kSpan = p("span");
    if (t == PartType::Wing)
        sp.wing = aero::WingConst(aero::WingParams(p("ar", 7), p("camber"), p("thick") / smax(sp.kChord, 1e-3), sp.flapChord));
    sp.baseQN = sp.baseQ.normalized();
    std::string axisName = d.paramString("axis", "z");
    sp.servoAxis = axisName == "x" ? Vec3d{1, 0, 0} : axisName == "y" ? Vec3d{0, 1, 0} : Vec3d{0, 0, 1};
    sp.servoAxisBase = sp.baseQ.act(sp.servoAxis);
    sp.kPropPower = aero::propPower(sp.kThrust, smax(0.1, sp.kD));
    if (t == PartType::Prop) { double R = smax(0.05, sp.kD / 2); sp.kIrot = sp.docMass * R * R / 3; }
    else if (t == PartType::Wheel) sp.kIrot = 0.5 * sp.docMass * sp.kR * sp.kR;
    else sp.kIrot = 0;
    sp.isBlocker = sp.isBody && t != PartType::Motor;
}

void CraftSim::bakeParts() {
    cornerFlat_.clear();
    for (auto& p : parts_) {
        bake(p);
        p.cornerStart = int(cornerFlat_.size()); p.cornerCount = int(p.corners.size());
        cornerFlat_.insert(cornerFlat_.end(), p.corners.begin(), p.corners.end());
    }
    double r = 0;
    for (auto& p : parts_) {
        for (auto& c : p.corners) r = smax(r, length(p.basePos) + length(c));
        if (p.is(PartType::Wheel)) r = smax(r, length(p.basePos) + smax(0.02, p.kR));
    }
    contactRadius_ = r;
    cornerTmp_.assign(std::max<std::size_t>(1, cornerFlat_.size()) * 4, 0.0);
}

void CraftSim::rebuildPanelBatch() {
    batchMesh_.clear(); items_.clear(); totalPanels_ = 0;
    int item = 0;
    for (auto& p : parts_) {
        p.meshSlot = -1; p.itemStart = 0; p.itemCount = 0;
        if (!p.isBody || p.mesh < 0) continue;
        const PanelMesh& m = *meshes_[std::size_t(p.mesh)];
        p.meshSlot = int(batchMesh_.size()); batchMesh_.push_back(p.mesh);
        int n = std::max(1, (m.count() + kPanelChunk - 1) / kPanelChunk);
        p.itemStart = item; p.itemCount = n; item += n;
    }
    for (int slot = 0; slot < int(batchMesh_.size()); ++slot) {
        const PanelMesh& m = *meshes_[std::size_t(batchMesh_[std::size_t(slot)])];
        int lo = 0;
        do { int hi = std::min(m.count(), lo + kPanelChunk); items_.push_back({slot, lo, hi}); lo = hi; } while (lo < m.count());
        totalPanels_ += m.count();
    }
    slotQ_.assign(std::max<std::size_t>(1, batchMesh_.size()), Quatd::identity());
    slotO_.assign(std::max<std::size_t>(1, batchMesh_.size()), Vec3d{});
    itemOut_.assign(std::max<std::size_t>(1, items_.size()), ForceTorque{});
    if (!panelLoop_) panelLoop_ = std::make_unique<jobs::ParallelLoop>([this](int lo, int hi) { runPanelItems(lo, hi); });
}

void CraftSim::runPanelItems(int lo, int hi) {
    for (int k = lo; k < hi; ++k) {
        const PanelItem& it = items_[std::size_t(k)];
        const PanelMesh& m = *meshes_[std::size_t(batchMesh_[std::size_t(it.slot)])];
        if (pbWashOn_)
            itemOut_[std::size_t(k)] = m.evaluate(it.lo, it.hi, slotQ_[std::size_t(it.slot)], slotO_[std::size_t(it.slot)], pbCom_, pbLin_, pbAng_, pbWind_, pbWash_, pbRho_, pbNu_, pbSos_);
        else
            itemOut_[std::size_t(k)] = m.evaluate(it.lo, it.hi, slotQ_[std::size_t(it.slot)], slotO_[std::size_t(it.slot)], pbCom_, pbLin_, pbAng_, pbWind_, pbRho_, pbNu_, pbSos_);
    }
}

std::vector<CraftOutput> CraftSim::makeOutputs(const CraftSpec& craft) {
    std::vector<CraftOutput> out;
    for (auto& p : craft.parts) {
        auto t = p.partType();
        if (!t || !isOutputType(*t)) continue;
        int linked = 0;
        for (auto& q : craft.parts) if ((q.servo && *q.servo == p.id) || (q.motor && *q.motor == p.id)) ++linked;
        CraftOutput o; o.id = p.id; o.name = p.name;
        switch (*t) {
        case PartType::Servo:
            o.kind = OutputKind::Servo; o.lo = -1; o.hi = 1;
            o.info = "servo \xC2\xB1" + intStr(p.param("range")) + "\xC2\xB0 \xC2\xB7 " + intStr(p.param("torque")) + " N\xC2\xB7m \xC2\xB7 " + std::to_string(linked) + " linked";
            break;
        case PartType::Motor: {
            bool rev = p.param("reversible") != 0;
            o.kind = OutputKind::Motor; o.lo = rev ? -1 : 0; o.hi = 1;
            o.info = "motor " + intStr(p.param("torque")) + " N\xC2\xB7m \xC2\xB7 " + std::to_string(linked) + " linked";
            break;
        }
        case PartType::Jet: o.kind = OutputKind::Jet; o.lo = 0; o.hi = 1; o.info = "jet " + intStr(p.param("thrust")) + " N"; break;
        default:
            o.kind = OutputKind::Solid; o.lo = 0; o.hi = 1;
            o.info = "solid " + intStr(p.param("thrust")) + " N \xC3\x97 " + swiftDouble(p.param("burn")) + "s \xC2\xB7 ignites >50%";
            break;
        }
        out.push_back(o);
    }
    return out;
}

void CraftSim::setOutput(const std::string& id, double value) {
    for (int i = 0; i < int(outputs_.size()); ++i) if (outputs_[std::size_t(i)].id == id) { setOutput(i, value); return; }
}

int CraftSim::outputIndex(const std::string& s) const {
    for (int i = 0; i < int(outputs_.size()); ++i) if (outputs_[std::size_t(i)].id == s) return i;
    for (int i = 0; i < int(outputs_.size()); ++i) if (outputs_[std::size_t(i)].name == s) return i;
    return -1;
}

void CraftSim::setOutput(int i, double value) {
    if (i < 0 || i >= int(outputs_.size())) return;
    CraftOutput& o = outputs_[std::size_t(i)];
    double v = clamp(std::isfinite(value) ? value : 0, o.lo, o.hi);
    o.value = v;
    int pi = outputTarget(i);
    if (pi >= 0) parts_[std::size_t(pi)].out = v;
}

void CraftSim::setPartMesh(const std::string& partID, const std::vector<Vec3d>& soup) {
    for (auto& p : parts_) {
        if (docOf(p).id != partID) continue;
        auto m = std::make_unique<PanelMesh>(soup);
        if (m->count() > 0) {
            Vec3d mn{kInf, kInf, kInf}, mx{-kInf, -kInf, -kInf};
            for (auto& t : m->tris()) for (const Vec3d& v : {t.a, t.b, t.c}) {
                mn = {std::fmin(mn.x, v.x), std::fmin(mn.y, v.y), std::fmin(mn.z, v.z)};
                mx = {std::fmax(mx.x, v.x), std::fmax(mx.y, v.y), std::fmax(mx.z, v.z)};
            }
            p.size = mx - mn; p.ctr = (mn + mx) * 0.5;
            if (p.mesh >= 0) meshes_[std::size_t(p.mesh)] = std::move(m);
            else { p.mesh = int(meshes_.size()); meshes_.push_back(std::move(m)); }
        } else p.mesh = -1;
        rebuildPanelBatch();
        buildHull(); updateMassProperties(true);
        return;
    }
}

// MARK: geometry ---------------------------------------------------------------------------------------------------

std::pair<Vec3d, Vec3d> CraftSim::bounds(const PartSpec& d) {
    auto p = [&](const char* k) { return d.param(k); };
    auto t = d.partType();
    if (!t) return {Vec3d::splat(0.2), {}};
    switch (*t) {
    case PartType::Box: return {{p("sx"), p("sy"), p("sz")}, {}};
    case PartType::Cylinder: case PartType::Cone: return {{2 * p("r"), p("h"), 2 * p("r")}, {}};
    case PartType::Sphere: return {Vec3d::splat(2 * p("r")), {}};
    case PartType::Wing: return {{p("chord"), p("thick"), p("span")}, {}};
    case PartType::Servo: return {{0.14, 0.08, 0.08}, {}};
    case PartType::Wheel: return {{2 * p("r"), 2 * p("r"), p("width")}, {}};
    case PartType::Motor: return {{0.5, 0.5, 0.5}, {}};
    case PartType::Prop: return {{0.06, p("d"), 0.14}, {}};
    case PartType::Jet: case PartType::Tank: case PartType::Solid: return {{p("len"), 2 * p("r"), 2 * p("r")}, {}};
    case PartType::Cad:
        if (d.cad) {
            auto s = PanelMesh::decodePrototypeCAD(*d.cad, d.param("scale", 1));
            if (s && !s->empty()) {
                Vec3d mn{kInf, kInf, kInf}, mx{-kInf, -kInf, -kInf};
                for (auto& v : *s) {
                    mn = {std::fmin(mn.x, v.x), std::fmin(mn.y, v.y), std::fmin(mn.z, v.z)};
                    mx = {std::fmax(mx.x, v.x), std::fmax(mx.y, v.y), std::fmax(mx.z, v.z)};
                }
                Vec3d e = mx - mn;
                return {{std::fmax(e.x, 0.01), std::fmax(e.y, 0.01), std::fmax(e.z, 0.01)}, (mn + mx) * 0.5};
            }
        }
        return {Vec3d::splat(0.5), {}};
    case PartType::Sensor: return {Vec3d::splat(0.12), {}};
    }
    return {Vec3d::splat(0.2), {}};
}

void CraftSim::rebuildStrips() {
    strips_.clear();
    for (int i = 0; i < int(parts_.size()); ++i) {
        const SimPart& p = parts_[std::size_t(i)];
        if (!p.is(PartType::Wing)) continue;
        int n = std::max(1, stripsPerWing);
        double span = docOf(p).param("span"), chord = docOf(p).param("chord");
        for (int k = 0; k < n; ++k) {
            double off = -span / 2 + span * (double(k) + 0.5) / double(n);
            strips_.push_back({i, off, span * chord / double(n)});
        }
    }
    stripBuf_.assign(std::max<std::size_t>(1, strips_.size()), StripResult{});
}

void CraftSim::buildHull() {
    std::vector<Vec3d> soup;
    double r = 0.5;
    for (auto& p : parts_) {
        if (p.mesh >= 0) {
            for (auto& t : meshes_[std::size_t(p.mesh)]->tris()) {
                soup.push_back(p.basePos + p.baseQ.act(t.a)); soup.push_back(p.basePos + p.baseQ.act(t.b)); soup.push_back(p.basePos + p.baseQ.act(t.c));
            }
        } else if (!p.is(PartType::Prop) && !p.is(PartType::Servo) && !p.is(PartType::Sensor)) {
            auto b = PanelMesh::boxSoup(p.basePos + p.baseQ.act(p.ctr), p.size, p.baseQ);
            soup.insert(soup.end(), b.begin(), b.end());
        }
        r = smax(r, length(p.basePos) + length(p.size) / 2);
    }
    boundingRadius_ = r;
    hull_.positions.clear(); hull_.indices.clear();
    hull_.positions.reserve(soup.size() * 3); hull_.indices.reserve(soup.size());
    for (std::size_t i = 0; i < soup.size(); ++i) {
        hull_.positions.push_back(float(soup[i].x)); hull_.positions.push_back(float(soup[i].y)); hull_.positions.push_back(float(soup[i].z));
        hull_.indices.push_back(uint32_t(i));
    }
}

void CraftSim::resetFuel() {
    for (auto& p : parts_) {
        if (p.is(PartType::Tank)) { p.fuelCapacity = docOf(p).param("capacity"); p.fuel = p.fuelCapacity * clamp(docOf(p).param("fill"), 0, 1); }
        else if (p.is(PartType::Solid)) { p.fuelCapacity = docOf(p).param("fuel"); p.fuel = p.fuelCapacity; p.burning = false; }
        p.angle = 0; p.spinAngle = 0; p.omega = 0; p.spool = 0; p.load = 0; p.vi = 0; p.wakeQ = 0;
    }
}

Vec3d CraftSim::shapeInertia(const SimPart& p, double m) {
    Vec3d s = p.size;
    if (p.is(PartType::Sphere)) { double r = s.x / 2; return Vec3d::splat(0.4 * m * r * r); }
    if (p.is(PartType::Cylinder) || p.is(PartType::Cone)) {
        bool cone = p.is(PartType::Cone);
        double r = s.x / 2, h = s.y, k = cone ? 0.3 : 0.5;
        double ia = k * m * r * r, it = m * (3 * r * r + h * h) / 12 * (cone ? 0.8 : 1);
        return {it, ia, it};
    }
    if (p.is(PartType::Wheel)) { double r = s.x / 2, w = s.z; return {m * (3 * r * r + w * w) / 12, m * (3 * r * r + w * w) / 12, 0.5 * m * r * r}; }
    return {m / 12 * (s.y * s.y + s.z * s.z), m / 12 * (s.x * s.x + s.z * s.z), m / 12 * (s.x * s.x + s.y * s.y)};
}

void CraftSim::updateMassProperties(bool keepOrigin) {
    Vec3d oldOrigin = position_ - orientation_.act(comLocal_);
    Vec3d oldOmega = angularVelocityWorld();
    double M = 0;
    Vec3d com;
    for (auto& p : parts_) { double m = partMass(p); M += m; com += (p.basePos + p.baseQ.act(p.ctr)) * m; }
    M = smax(M, 1e-3); com /= M;
    Mat3d I = Mat3d::diagonal({0, 0, 0});
    for (auto& p : parts_) {
        Mat3d R = Mat3d::fromQuat(p.baseQ);
        Mat3d D = Mat3d::diagonal(shapeInertia(p, docOf(p).mass));
        I += R * D * R.transpose();
        Vec3d d = p.basePos + p.baseQ.act(p.ctr) - com;
        double m = partMass(p);
        I += (Mat3d::diagonal(Vec3d::splat(dot(d, d))) - Mat3d::columns(d * d.x, d * d.y, d * d.z)) * m;
    }
    I += Mat3d::diagonal(Vec3d::splat(1e-4 * M));
    mass_ = M; comLocal_ = com; inertia_ = I; inertiaInv_ = I.inverse();
    if (keepOrigin) {
        position_ = oldOrigin + orientation_.act(comLocal_);
        Mat3d R = Mat3d::fromQuat(orientation_);
        angularMomentum_ = R * inertia_ * R.transpose() * oldOmega;
    }
}

Vec3d CraftSim::angularVelocityWorld() const { Mat3d R = Mat3d::fromQuat(orientation_); return R * (inertiaInv_ * (R.transpose() * angularMomentum_)); }
Vec3d CraftSim::omegaWorld(const Quatd& q) const { Mat3d R = Mat3d::fromQuat(q); return R * (inertiaInv_ * (R.transpose() * angularMomentum_)); }

// MARK: reset / state ----------------------------------------------------------------------------------------------

Vec3d CraftSim::restingSpawn(double groundHeight) const {
    double minY = kInf;
    for (auto& p : parts_) {
        for (auto& c : p.corners) minY = smin(minY, p.basePos.y + p.baseQ.act(c).y);
        if (p.is(PartType::Wheel)) minY = smin(minY, p.basePos.y - docOf(p).param("r"));
    }
    if (!std::isfinite(minY)) minY = 0;
    return {0, groundHeight - minY + 0.02, 0};
}

void CraftSim::reset(const Vec3d& spawnPosition, const Quatd& spawnRotation) {
    resetFuel();
    for (auto& p : parts_) { p.burning = false; p.thrustNow = 0; }
    orientation_ = spawnRotation.normalized();
    updateMassProperties(false);
    position_ = spawnPosition + orientation_.act(comLocal_);
    velocity_ = {}; angularMomentum_ = {}; time_ = 0; stepCounter_ = 0;
    crashed_ = false; groundContact_ = false; maxImpactSpeed_ = 0; lastForce_ = {}; noiseState_ = sensorNoiseSeed | 1;
    for (auto& p : parts_) { p.contact = false; p.compression = 0; }
    for (auto& g : groupState_) g = WingGroupState{};
    horseshoeCount_ = 0;
    telemetry_ = CraftTelemetry{};
    updateEffective();
}

int CraftSim::cornerCount() const { int n = 0; for (auto& p : parts_) n += int(p.corners.size()); return n; }

int CraftSim::writeWorldCorners(Vec3d* out, int capacity) const {
    Quatd q = orientation_;
    Vec3d origin = position_ - q.act(comLocal_);
    int n = 0;
    for (auto& p : parts_) {
        if (p.corners.empty()) continue;
        Quatd qp = q * p.effQ;
        Vec3d op = origin + q.act(p.basePos);
        for (auto& c : p.corners) { if (n >= capacity) return n; out[n++] = op + qp.act(c); }
    }
    return n;
}

void CraftSim::markObstacleHit(double impactSpeed) { crashed_ = true; if (impactSpeed > maxImpactSpeed_) maxImpactSpeed_ = impactSpeed; }

void CraftSim::setVelocity(const Vec3d& linear, const Vec3d& angular) {
    velocity_ = linear;
    Mat3d R = Mat3d::fromQuat(orientation_);
    angularMomentum_ = R * inertia_ * R.transpose() * angular;
}

void CraftSim::holdState(const Vec3d& p, const Quatd& q, const Vec3d& v) {
    position_ = p; orientation_ = q.normalized(); velocity_ = v; angularMomentum_ = {};
}

BodyState CraftSim::bodyState() const {
    BodyState s;
    s.position = position_ - orientation_.act(comLocal_); s.rotation = orientation_;
    s.linearVelocity = velocity_; s.angularVelocity = angularVelocityWorld(); s.centerOfMass = position_;
    return s;
}

double CraftSim::mechanicalEnergy(const Vec3d& g) const {
    return 0.5 * mass_ * lengthSquared(velocity_) + 0.5 * dot(angularVelocityWorld(), angularMomentum_) - mass_ * dot(g, position_);
}

std::vector<PartPose> CraftSim::partPoses() const {
    Vec3d op = position_ - orientation_.act(comLocal_);
    Quatd oq = orientation_;
    std::vector<PartPose> out;
    out.reserve(parts_.size());
    for (auto& p : parts_) {
        Quatd q = p.effQ;
        if (p.is(PartType::Prop)) q = q * Quatd::angleAxis(p.spinAngle, {1, 0, 0});
        if (p.is(PartType::Wheel)) q = q * Quatd::angleAxis(-p.spinAngle, {0, 0, 1});
        // Transform composition: o * (basePos, q)
        out.push_back({docOf(p).id, op + oq.act(p.basePos), (oq * q).normalized()});
    }
    return out;
}

double CraftSim::pitchDeg() const { return std::asin(clamp(heading().y, -1, 1)) / kDeg; }
double CraftSim::totalFuel() const { double f = 0; for (auto& p : parts_) f += p.fuel; return f; }
std::vector<std::string> CraftSim::overloadedServos() const {
    std::vector<std::string> v;
    for (auto& p : parts_) if (p.overload) v.push_back(docOf(p).name);
    return v;
}
std::optional<double> CraftSim::servoAngleDeg(const std::string& id) const {
    for (auto& p : parts_) if (docOf(p).id == id) return p.angle / kDeg;
    return std::nullopt;
}
std::optional<double> CraftSim::partFuel(const std::string& id) const {
    for (auto& p : parts_) if (docOf(p).id == id) return p.fuel;
    return std::nullopt;
}

// MARK: stepping ---------------------------------------------------------------------------------------------------

void CraftSim::step(double dt, const SimEnvironment& env) {
    if (parts_.empty() || !(dt > 0)) return;
    int n = std::max(1, int(std::ceil(dt * substepHz - 1e-9)));
    double h = dt / double(n);
    SimEnvironment e = env;
    for (int k = 0; k < n; ++k) { e.time = env.time + double(k) * h; substep(h, e); }
}

void CraftSim::updateEffective() {
    for (auto& p : parts_) {
        if (p.servo >= 0 && p.flapChord == 0) {
            const SimPart& s = parts_[std::size_t(p.servo)];
            Quatd q = Quatd::angleAxis(s.angle * (p.invert ? -1 : 1), s.servoAxisBase) * p.baseQ;
            p.effQ = q.normalized();
        } else {
            p.effQ = p.baseQN;
        }
    }
}

void CraftSim::substep(double h, const SimEnvironment& env) {
    SubstepOut o = substepCore(h, env);
    if (o.massDirty && stepCounter_ % 10 == 0) updateMassProperties(true);
    updateTelemetry(o.atm, o.windHere, o.stalled, o.thrust, o.fuel);
}

Quatd CraftSim::rotate(const Quatd& q, const Vec3d& w, double dt) {
    double a = length(w) * dt;
    if (a < 1e-15) return q;
    return (Quatd::angleAxis(a, w / length(w)) * q).normalized();
}

void CraftSim::runStrips(int lo, int hi, const Quatd& q, const Vec3d& origin, const Vec3d& wW, const WindField::Prepared& wind,
                         double sos, double rho, double nu, const TerrainProvider* terrain) {
    // Per-part frame, reused by consecutive strips of the same wing (strips are part-ordered).
    int lastPart = -1;
    Vec3d nrm, c, s, pacBase;
    double chord = 0, span = 0, flapChord = 0, flapDelta = 0; bool hasServo = false;
    const aero::WingConst* wing = nullptr;
    double geSpan = 0;
    int group = -1;
    const Vec3d pos = position_, vel = velocity_;
    for (int si = lo; si < hi; ++si) {
        const WingStrip& st = strips_[std::size_t(si)];
        if (st.part != lastPart) {
            lastPart = st.part;
            const SimPart& p = parts_[std::size_t(st.part)];
            Quatd qw = q * p.effQ;
            nrm = qw.act({0, 1, 0}); c = qw.act({1, 0, 0}); s = qw.act({0, 0, 1});
            chord = p.kChord; span = p.kSpan;
            pacBase = origin + q.act(p.basePos) + c * (chord * 0.25);
            flapChord = p.flapChord;
            hasServo = p.servo >= 0;
            flapDelta = 0;
            if (flapChord > 0 && p.servo >= 0) flapDelta = parts_[std::size_t(p.servo)].angle * (p.invert ? -1 : 1);
            wing = &p.wing;
            geSpan = smax(2 * span, chord);
            group = p.wingGroup;
        }
        Vec3d pac = pacBase + s * st.spanOffset;
        double gh = terrain ? terrain->height(pac.x, pac.z) : 0;
        Vec3d wl = wind.velocity(pac, pac.y - gh);
        if (wakeView_.count > 0) wl += wakeView_.velocity(pac);
        if (dwView_.count > 0) wl += dwView_.velocity(pac, group);
        Vec3d a3 = -(vel + cross(wW, pac - pos) - wl);
        a3 -= s * dot(a3, s);
        double sp = length(a3);
        if (sp < 0.3) { stripBuf_[std::size_t(si)] = StripResult{}; continue; }
        double alpha = std::atan2(dot(a3, nrm), -dot(a3, c));
        aero::GroundEffect ge = aero::groundEffect(pac.y - gh, geSpan);
        aero::WingCoefficients co = aero::wing(alpha, sp / sos, sp * chord / nu, *wing, flapDelta, ge.phi, ge.liftGain);
        double qS = 0.5 * rho * sp * sp * st.area;
        Vec3d dd = a3 / sp;
        Vec3d ld = normalize(cross(dd, s));
        Vec3d f = ld * (co.cl * qS) + dd * (co.cd * qS);
        Vec3d pcp = pac + c * (chord * (0.25 - co.centerOfPressure));
        double hinge = 0;
        if (hasServo) {
            if (flapChord > 0) { double cf = flapChord * chord; hinge = std::fabs(co.hingeCh) * 0.5 * rho * sp * sp * st.area * flapChord * cf; }
            else hinge = length(f) * 0.12 * chord + std::fabs(co.cl) * qS * 0.02;
        }
        StripResult& r = stripBuf_[std::size_t(si)];
        r.ft = {f, cross(pcp - pos, f)}; r.hinge = hinge;
        r.stalled = co.stalled; r.bigStall = co.stalled && span * chord > 2;
        r.lift = ld * (co.cl * qS); r.pac = pac; r.alpha = alpha; r.speed = sp; r.cl = co.cl; r.cd = co.cd;
        r.cp = co.centerOfPressure; r.ch = co.hingeCh; r.re = sp * chord / nu; r.phi = ge.phi; r.gain = ge.liftGain; r.flap = flapDelta;
    }
}

CraftSim::SubstepOut CraftSim::substepCore(double h, const SimEnvironment& env) {
    SubstepOut out;
    EquationCapture* cap = equationCapture;
    bool capOn = cap && cap->requested;
    if (capOn) cap->begin();
    const FastAeroToggles tg = fastToggles;
    const int np = int(parts_.size());
    SimPart* P = parts_.data();
    // --- servos (torque/speed limited, back-driven by the previous step's hinge load)
    for (int i = 0; i < np; ++i) {
        if (!P[i].is(PartType::Servo)) continue;
        double tgt = clamp(P[i].out, -1, 1) * P[i].kRange * kDeg, capT = smax(1e-3, P[i].kTorque), load = P[i].load;
        double a = P[i].angle;
        bool overload = load > capT;
        if (!overload) { double rate = P[i].kSpeed * kDeg * smax(0.05, 1 - 0.8 * load / capT); a += clamp(tgt - a, -rate * h, rate * h); }
        else { double rate = P[i].kSpeed * kDeg * smin(1, load / capT - 1); a += clamp(-a, -rate * h, rate * h); }
        P[i].angle = a; P[i].overload = overload; P[i].loadShown = load; P[i].load = 0;
    }
    updateEffective();

    const Quatd q = orientation_;
    const Vec3d origin = position_ - q.act(comLocal_);
    const Vec3d wW = omegaWorld(q);
    const Atmosphere atm = env.atmosphere(position_.y);
    const double rho = atm.density, nu = aero::viscosity(atm.temperature) / smax(rho, 1e-9);
    const double groundUnder = groundHeight(env, position_.x, position_.z);
    const WindField wind(env.wind, turbulence);
    const Vec3d windHere = wind.velocity(position_, position_.y - groundUnder, env.time);
    const Vec3d position = position_, velocity = velocity_;
    Vec3d F, T;
    auto apply = [&](const Vec3d& f, const Vec3d& pw) { F += f; T += cross(pw - position, f); };
    auto pointVel = [&](const Vec3d& pw) { return velocity + cross(wW, pw - position); };
    const bool air = rho > 1e-6 && aeroEnabled;
    const bool fastAero = air;   // AeroModel::Full (CFD) is phase 4

    // --- rotor wakes from the previous substep's disk state
    wakeCount_ = 0;
    if (air && slipstream) {
        for (int i = 0; i < np; ++i) {
            if (!(P[i].is(PartType::Prop) && P[i].vi > 1e-6)) continue;
            Vec3d dir = q.act(P[i].effQ.act({1, 0, 0})), pw = origin + q.act(P[i].basePos);
            Vec3d rel = windHere - (velocity + cross(wW, pw - position));
            Vec3d axis = -dir;
            double va = smax(0, dot(rel, axis));
            double R = smax(0.05, P[i].kD / 2);
            if (wakeCount_ < int(wakeBuf_.size())) {
                RotorWake w;
                w.center = pw; w.axis = axis; w.radius = R; w.vi = P[i].vi; w.vAxial = va; w.cross = rel - axis * dot(rel, axis);
                w.swirl = (P[i].omega >= 0 ? 1 : -1) * P[i].wakeQ / (rho * kPi * R * R);
                w.ducted = P[i].kDucted; w.owner = i;
                w.swirl0 = w.swirl;
                wakeBuf_[std::size_t(wakeCount_++)] = w;
            }
        }
        if (tg.blockage && wakeCount_ > 0) applyBlockage(q, origin, capOn ? cap : nullptr);
    }
    wakeView_ = WakeView{wakeCount_ > 0 ? wakeBuf_.data() : nullptr, wakeCount_};
    int stalledCount = 0;
    double thrustTotal = 0;
    // --- wing downwash: horseshoes from the previous substep's group lift
    horseshoeCount_ = 0;
    const bool dwOn = air && slipstream && tg.downwash && !wingGroups_.empty();
    if (dwOn) buildHorseshoes(q, origin, rho);
    dwView_ = DownwashView{horseshoeCount_ > 0 ? horseshoes_.data() : nullptr, horseshoeCount_};

    // --- wing strips
    const int ns = int(strips_.size());
    if (fastAero && ns > 0) {
        const WindField::Prepared wp(wind, env.time);
        const TerrainProvider* terrain = env.terrain;
        if (ns >= parallelThreshold) {
            auto body = [&](int lo, int hi) { runStrips(lo, hi, q, origin, wW, wp, atm.speedOfSound, rho, nu, terrain); };
            pool().parallelFor(ns, 32, body);
        } else {
            runStrips(0, ns, q, origin, wW, wp, atm.speedOfSound, rho, nu, terrain);
        }
        for (int si = 0; si < ns; ++si) {
            const StripResult& r = stripBuf_[std::size_t(si)];
            F += r.ft.force; T += r.ft.torque;
            if (r.hinge > 0) { int sv = P[strips_[std::size_t(si)].part].servo; if (sv >= 0) P[sv].load += r.hinge; }
            if (r.bigStall) stalledCount += 1;
        }
        if (dwOn) accumulateGroupLift(ns, q, origin, windHere, velocity, wW);
        if (capOn) captureStrips(ns, rho, atm.speedOfSound, *cap);
    }

    // --- bodies: projected-area drag, or mesh panels for CAD
    if (fastAero) {
        if (totalPanels_ > 0) {
            for (int i = 0; i < np; ++i) {
                if (P[i].meshSlot < 0) continue;
                int slot = P[i].meshSlot;
                PanelMesh& m = *meshes_[std::size_t(batchMesh_[std::size_t(slot)])];
                Quatd qp = q * P[i].effQ;
                Vec3d op = origin + q.act(P[i].basePos);
                Vec3d vb = qp.inverse().act(velocity - windHere);
                if (length(vb) > 0.5) m.updateShadows(-normalize(vb));
                slotQ_[std::size_t(slot)] = qp; slotO_[std::size_t(slot)] = op;
            }
            pbCom_ = position; pbLin_ = velocity; pbAng_ = wW; pbWind_ = windHere;
            pbRho_ = rho; pbNu_ = nu; pbSos_ = atm.speedOfSound;
            pbWashOn_ = air && slipstream && tg.cadWash && (wakeCount_ > 0 || horseshoeCount_ > 0);
            pbWash_ = PanelWash{wakeView_, dwView_};
            if (items_.size() > 1 && totalPanels_ >= std::max(parallelThreshold, kPanelParallelMin))
                pool().run(*panelLoop_, int(items_.size()), 1);
            else
                runPanelItems(0, int(items_.size()));
        }
        for (int i = 0; i < np; ++i) {
            if (!P[i].isBody) continue;
            if (P[i].meshSlot >= 0) {
                int s0 = P[i].itemStart, nItems = P[i].itemCount;
                ForceTorque ft = itemOut_[std::size_t(s0)];
                if (nItems > 1) { ft = ForceTorque{}; for (int k = s0; k < s0 + nItems; ++k) ft = ft + itemOut_[std::size_t(k)]; }
                F += ft.force; T += ft.torque;
                if (capOn) capturePanels(i, ft, rho, nu, atm.speedOfSound, *cap);
            } else {
                Vec3d pw = origin + q.act(P[i].basePos + P[i].effQ.act(P[i].ctr));
                Vec3d v = pointVel(pw) - windHere - wakeView_.velocity(pw);
                double sp = length(v);
                if (sp < 0.1) continue;
                Vec3d vl = (q * P[i].effQ).inverse().act(v) / sp, s = P[i].size;
                double A = std::fabs(vl.x) * s.y * s.z + std::fabs(vl.y) * s.x * s.z + std::fabs(vl.z) * s.x * s.y;
                double cd = P[i].kCd * (sp / atm.speedOfSound > 0.8 ? 1 + 6 * std::pow(sp / atm.speedOfSound - 0.8, 2) : 1);
                apply(v * (-0.5 * rho * sp * cd * A), pw);
                if (capOn) captureBodyDrag(i, rho, sp, cd, A, v, pw, *cap);
            }
        }
    }

    // --- propulsion
    double liquid = 0;
    for (int i = 0; i < np; ++i) if (P[i].is(PartType::Tank)) liquid += P[i].fuel;
    double liquidUse = 0;
    for (int i = 0; i < np; ++i) {
        P[i].thrustNow = 0;
        if (!P[i].type) continue;
        switch (*P[i].type) {
        case PartType::Prop: {
            double thr = P[i].autoMotor ? P[i].out : (P[i].motor >= 0 ? clamp(P[P[i].motor].out, -1, 1) : 0);
            Vec3d dir = q.act(P[i].effQ.act({1, 0, 0})), pw = origin + q.act(P[i].basePos);
            Vec3d inflowWind = windHere + wakeView_.velocity(pw, i);
            double vax = dot(pointVel(pw) - inflowWind, dir);
            double P0 = P[i].kPropPower * std::fabs(thr) * (rho / 1.225);
            bool slip = slipstream && air;
            double dEff = smax(0.1, P[i].kD) * (slip && P[i].kDucted ? std::sqrt(2.0) : 1);
            aero::PropResult r = aero::propThrust(P0, dEff, smax(rho, 1e-6), thr >= 0 ? vax : -vax, P[i].kPropVmax);
            double Tn = (thr >= 0 ? 1 : -0.5) * r.thrust;
            if (slip && Tn > 0) {
                Tn *= aero::rotorGroundEffectGain(pw.y - groundHeight(env, pw.x, pw.z), smax(0.05, P[i].kD / 2), dir.y);
                double Rd = smax(0.05, P[i].kD / 2);
                P[i].vi = aero::diskVelocity(Tn, rho, kPi * Rd * Rd, vax, P[i].kDucted);
            } else P[i].vi = 0;
            double targetOmega = 2 * kPi * r.rps * std::fabs(thr) * (thr >= 0 ? 1 : -1) * P[i].kSpin;
            P[i].omega += (targetOmega - P[i].omega) * smin(1, h / 0.4);
            if (slip && tg.pFactor && Tn > 0 && std::fabs(P[i].omega) > 1) {
                Vec3d rel = inflowWind - pointVel(pw);
                PFactorLoads pf = pFactorLoads(dir, rel, Tn, P[i].omega, smax(0.05, P[i].kD / 2), rho, vax, P[i].vi);
                apply(dir * Tn, pw + pf.offset);
                apply(pf.normal, pw);
                if (capOn) capturePFactor(i, pf, dir, pw, Tn, *cap);
            } else {
                apply(dir * Tn, pw);
            }
            if (capOn) captureProp(i, dir, pw, P0, vax, Tn, dEff, targetOmega, rho, slip, pw.y - groundHeight(env, pw.x, pw.z),
                                   wakeView_.velocity(pw, i), *cap);
            P[i].spinAngle = std::fmod(P[i].spinAngle + P[i].omega * h, 2 * kPi);
            if (std::fabs(P[i].omega) > 1) {
                if (slip) {
                    double Q = std::fabs(targetOmega) > 1 ? P0 * 0.75 / std::fabs(targetOmega) : 0;
                    P[i].wakeQ = Q;
                    T -= dir * (Q * (P[i].omega >= 0 ? 1 : -1));
                } else {
                    P[i].wakeQ = 0;
                    T -= dir * (P0 * 0.75 / P[i].omega) * 0.25;
                }
            } else P[i].wakeQ = 0;
            P[i].thrustNow = std::fabs(Tn); thrustTotal += std::fabs(Tn);
            break;
        }
        case PartType::Jet: {
            double cmd = liquid > 0 ? clamp(P[i].out, 0, 1) : 0;
            P[i].spool = aero::spool(P[i].spool, cmd, h);
            if (liquid > 0 && P[i].spool > 0.01) {
                Vec3d dir = q.act(P[i].effQ.act({1, 0, 0})), pw = origin + q.act(P[i].basePos);
                double M = length(velocity - windHere) / atm.speedOfSound;
                double Tn = P[i].kThrust * P[i].spool * aero::jetLapse(rho, M);
                apply(dir * Tn, pw);
                liquidUse += P[i].kFlow * (0.05 + 0.95 * P[i].spool) * h * (rho / 1.225 * 0.5 + 0.5);
                P[i].thrustNow = Tn; thrustTotal += Tn;
            }
            P[i].spinAngle += P[i].spool * 300 * h;
            break;
        }
        case PartType::Solid: {
            if (!P[i].burning && P[i].out > 0.5 && P[i].fuel > 0) { P[i].burning = true; P[i].ignitedAt = time_; }
            if (P[i].burning) {
                Vec3d dir = q.act(P[i].effQ.act({1, 0, 0})), pw = origin + q.act(P[i].basePos);
                double frac = P[i].fuel / smax(P[i].fuelCapacity, 1e-9);
                double k = aero::solidProfile(frac, time_ - P[i].ignitedAt, atm.pressure);
                double Tn = P[i].kThrust * k;
                apply(dir * Tn, pw);
                P[i].fuel -= P[i].fuelCapacity / smax(P[i].kBurn, 1e-3) * k * h;
                if (P[i].fuel <= 0) { P[i].fuel = 0; P[i].burning = false; }
                P[i].thrustNow = Tn; thrustTotal += Tn;
            }
            break;
        }
        default: break;
        }
    }
    bool massDirty = false;
    if (liquidUse > 0 && liquid > 0) {
        double k = smax(0, 1 - liquidUse / liquid);
        for (int i = 0; i < np; ++i) if (P[i].is(PartType::Tank)) P[i].fuel *= k;
        massDirty = true;
    }
    for (int i = 0; i < np; ++i) if (P[i].burning) { massDirty = true; break; }

    // --- gravity
    F += env.gravity * mass_;

    // --- ground: rigid bounding-box corners (penalty spring-damper + Coulomb friction)
    if (groundEnabled) {
        int nContact = 0;
        bool anyContact = false;
        double ceiling = env.terrain ? env.terrain->maxHeight() : 0;
        bool clear = origin.y - contactRadius_ > ceiling + 1;
        if (!cornerFlat_.empty() && !clear) {
            double* tmp = cornerTmp_.data();
            for (int i = 0; i < np; ++i) {
                if (P[i].cornerCount <= 0) continue;
                Quatd qp = q * P[i].effQ;
                Vec3d op = origin + q.act(P[i].basePos);
                int c0 = P[i].cornerStart;
                for (int k = c0; k < c0 + P[i].cornerCount; ++k) {
                    Vec3d pw = op + qp.act(cornerFlat_[std::size_t(k)]);
                    double gh = groundHeight(env, pw.x, pw.z);
                    tmp[4 * k] = pw.x; tmp[4 * k + 1] = pw.y; tmp[4 * k + 2] = pw.z; tmp[4 * k + 3] = gh;
                    if (pw.y < gh) nContact += 1;
                }
            }
            double share = 1.0 / double(std::max(1, nContact));
            double kB = mass_ * 2000 * share, cB = mass_ * 60 * share;
            for (int k = 0; k < int(cornerFlat_.size()); ++k) {
                Vec3d pw{tmp[4 * k], tmp[4 * k + 1], tmp[4 * k + 2]};
                double gh = tmp[4 * k + 3];
                if (pw.y >= gh) continue;
                Vec3d n = groundNormal(env, pw.x, pw.z);
                double pen = (gh - pw.y) * n.y;
                Vec3d vp = pointVel(pw);
                double vn = dot(vp, n);
                anyContact = true;
                if (-vn > maxImpactSpeed_) maxImpactSpeed_ = -vn;
                if (-vn > crashSpeed) crashed_ = true;
                double N = smax(0, pen * kB - vn * cB);
                if (N <= 0) continue;
                double mu = env.terrain ? env.terrain->material(pw.x, pw.z).friction : 0.6;
                Vec3d vt = vp - n * vn;
                double vts = length(vt);
                Vec3d f = n * N;
                if (vts > 1e-4) f -= vt * (smin(mu * N, vts * cB) / vts);
                apply(f, pw);
            }
        }
        // --- wheels: suspension + Pacejka-lite tyre with implicit wheel-spin DOF
        int nW = std::max(1, wheelCount_);
        double kW = mass_ * kGravity / (double(nW) * 0.08);
        double cW = 2 * 0.6 * std::sqrt(kW * mass_ / double(nW));
        for (int i = 0; i < np; ++i) {
            if (!P[i].is(PartType::Wheel)) continue;
            double r = smax(0.02, P[i].kR), Iw = smax(0.05, 0.5 * P[i].docMass * r * r);
            Vec3d hub = origin + q.act(P[i].basePos);
            Vec3d axle = q.act(P[i].effQ.act({0, 0, 1}));
            double omega = P[i].omega;
            bool contact = false;
            double motorT = 0;
            if (P[i].autoMotor) motorT = autoWheelTorque * clamp(P[i].out, -1, 1);
            else if (P[i].motor >= 0) {
                const SimPart& m = P[P[i].motor];
                double lo = m.kReversible != 0 ? -1.0 : 0;
                motorT = m.kTorque * clamp(m.out, lo, 1);
                double vmax = m.kMotorVmax;
                motorT *= clamp(1 - (omega * r * (motorT >= 0 ? 1 : -1)) / smax(vmax, 0.1), 0, 1);
            }
            Vec3d n = clear ? Vec3d{0, 1, 0} : groundNormal(env, hub.x, hub.z);
            Vec3d down = -n + axle * dot(axle, n);
            if (!clear && lengthSquared(down) > 1e-4) {
                down = normalize(down);
                Vec3d cp = hub + down * r;
                double gh = groundHeight(env, cp.x, cp.z);
                double pen = (gh - cp.y) * n.y;
                Vec3d fwdRaw = cross(n, axle);
                if (pen > 0 && lengthSquared(fwdRaw) > 1e-6) {
                    contact = true;
                    Vec3d fwd = normalize(fwdRaw), lat = cross(fwd, n);
                    Vec3d vp = pointVel(cp);
                    double N = smax(0, pen * kW - dot(vp, n) * cW);
                    TerrainMaterialSample mat = env.terrain ? env.terrain->material(cp.x, cp.z) : TerrainMaterialSample{};
                    double mu = P[i].kGrip * mat.friction / 0.9;
                    double D = mu * N;
                    double vf = dot(vp, fwd), vl = dot(vp, lat);
                    double den = smax(std::fabs(vf), 1.0);
                    const double Bx = 10.0, Cx = 1.65;
                    double kappa0 = (omega * r - vf) / den;
                    double fx0 = D * std::sin(Cx * std::atan(Bx * kappa0));
                    double slope = D * Cx * Bx * r / den;
                    omega = omega + h * (motorT - r * fx0) / (Iw + h * r * slope);
                    double kappa = (omega * r - vf) / den;
                    double fx = D * std::sin(Cx * std::atan(Bx * kappa));
                    double alpha = std::atan2(vl, den);
                    double fy = -D * std::sin(1.3 * std::atan(8 * alpha));
                    double mag = std::sqrt(fx * fx + fy * fy);
                    if (mag > D && mag > 0) { fx *= D / mag; fy *= D / mag; }
                    double roll = -clamp(vf * 4, -1, 1) * P[i].kRoll * mat.rollingResistance * N;
                    apply(n * N + fwd * (fx + roll) + lat * fy, cp);
                    P[i].compression = pen;
                    if (P[i].servo >= 0) P[P[i].servo].load += std::fabs(fy) * 0.04;
                }
            }
            if (!contact) { omega += h * motorT / Iw; omega *= (1 - 0.2 * h); }
            P[i].omega = omega; P[i].contact = contact;
            if (contact) anyContact = true;
            P[i].spinAngle = std::fmod(P[i].spinAngle + omega * h, 2 * kPi);
        }
        groundContact_ = anyContact;
    }

    // --- gyroscopic coupling of spinning rotors / wheels
    if (slipstream && tg.gyro) T += gyroTorque(q, wW, capOn ? cap : nullptr);

    // --- buoyancy / hydrodynamics
    if (env.water && !hull_.indices.empty()) {
        WaterSample ws = env.water->sample(position.x, position.z, env.time);
        if (position.y - boundingRadius_ < ws.surfaceHeight + 1) {
            BodyState st;
            st.position = position_ - orientation_.act(comLocal_); st.rotation = orientation_;
            st.linearVelocity = velocity; st.angularVelocity = wW; st.centerOfMass = position;
            ForceTorque ft = env.water->submergedForces(hull_, st, env.time, nullptr);
            F += ft.force; T += ft.torque;
        }
    }

    // --- integrate: velocity Verlet (linear), angular momentum + midpoint exp-map (angular)
    Vec3d vOld = velocity_;
    velocity_ += F / mass_ * h;
    position_ += (vOld + velocity_) * (0.5 * h);
    angularMomentum_ += T * h;
    Vec3d w0 = omegaWorld(orientation_);
    Quatd qHalf = rotate(orientation_, w0, h * 0.5);
    Vec3d wHalf = omegaWorld(qHalf);
    orientation_ = rotate(orientation_, wHalf, h);
    time_ += h; stepCounter_ += 1;
    lastForce_ = F - env.gravity * mass_;

    double fuel = 0;
    for (int i = 0; i < np; ++i) fuel += P[i].fuel;
    out.massDirty = massDirty; out.stalled = stalledCount; out.thrust = thrustTotal; out.fuel = fuel;
    out.windHere = windHere; out.ground = groundUnder; out.atm = atm;
    if (capOn) cap->finish();
    return out;
}

void CraftSim::updateTelemetry(const Atmosphere& atm, const Vec3d& windHere, int stalled, double thrust, double fuel) {
    CraftTelemetry t;
    Vec3d vAir = velocity_ - windHere;
    Vec3d vb = orientation_.inverse().act(vAir);
    t.airspeed = length(vAir);
    t.groundSpeed = std::sqrt(velocity_.x * velocity_.x + velocity_.z * velocity_.z);
    t.altitude = position_.y;
    t.verticalSpeed = velocity_.y;
    t.angleOfAttackDeg = t.airspeed > 0.5 ? std::atan2(-vb.y, vb.x) / kDeg : 0;
    t.sideslipDeg = t.airspeed > 0.5 ? std::asin(clamp(vb.z / t.airspeed, -1, 1)) / kDeg : 0;
    t.mach = t.airspeed / atm.speedOfSound;
    t.gLoad = dot(lastForce_ / mass_, orientation_.act({0, 1, 0})) / kGravity;
    t.fuelKg = fuel;
    t.massKg = mass_;
    t.thrustN = thrust;
    t.stalledSurfaces = stalled;
    telemetry_ = t;
}

// MARK: ducts / wakes / wing groups (Slipstream.swift) ------------------------------------------------------------

void CraftSim::detectDucts() {
    for (int i = 0; i < int(parts_.size()); ++i) {
        SimPart& pi = parts_[std::size_t(i)];
        if (!pi.is(PartType::Prop)) continue;
        double forced = docOf(pi).param("duct", -1);
        if (forced >= 0) { pi.kDucted = forced >= 0.5; continue; }
        Vec3d axis = normalize(pi.baseQ.act({1, 0, 0}));
        Vec3d c0 = pi.basePos;
        double R = smax(0.05, pi.kD / 2);
        Vec3d ref = std::fabs(axis.y) < 0.9 ? Vec3d{0, 1, 0} : Vec3d{1, 0, 0};
        Vec3d e1 = normalize(cross(axis, ref)), e2 = cross(axis, e1);
        bool bins[12] = {};
        for (int j = 0; j < int(parts_.size()); ++j) {
            const SimPart& pj = parts_[std::size_t(j)];
            if (j == i || !(pj.isBody || pj.isWing) || pj.is(PartType::Prop)) continue;
            Vec3d c = pj.basePos + pj.baseQ.act(pj.ctr) - c0;
            double s = dot(c, axis);
            double halfLen = 0.5 * smax(pj.size.x, smax(pj.size.y, pj.size.z));
            if (std::fabs(s) > halfLen + 0.25 * R) continue;
            Vec3d rv = c - axis * s;
            double r = length(rv);
            if (r < 1.0 * R || r > 1.7 * R) continue;
            double ext[3] = {pj.size.x, pj.size.y, pj.size.z};
            std::sort(ext, ext + 3);
            double halfAng = std::asin(smin(1, 0.5 * ext[1] / r));
            double ang = std::atan2(dot(rv, e2), dot(rv, e1));
            for (int k = 0; k < 12; ++k) {
                double mid = -kPi + (double(k) + 0.5) * (2 * kPi / 12);
                double dA = std::fabs(mid - ang);
                if (dA > kPi) dA = 2 * kPi - dA;
                if (dA <= halfAng + kPi / 12 * 0.5) bins[k] = true;
            }
        }
        int filled = 0;
        for (bool b : bins) filled += b ? 1 : 0;
        pi.kDucted = filled >= 9;
    }
}

void CraftSim::allocWakes() {
    int n = 0;
    for (auto& p : parts_) if (p.is(PartType::Prop)) ++n;
    wakeBuf_.assign(std::size_t(std::max(1, n)), RotorWake{});
    wakeCount_ = 0;
}

void CraftSim::buildWingGroups() {
    std::vector<int> groupOf(parts_.size(), -1);
    std::vector<WingGroup> groups;
    std::vector<int> wings;
    for (int i = 0; i < int(parts_.size()); ++i) if (parts_[std::size_t(i)].is(PartType::Wing)) wings.push_back(i);
    auto qc = [&](int i) { const SimPart& p = parts_[std::size_t(i)]; return p.basePos + p.baseQ.act({1, 0, 0}) * (p.kChord * 0.25); };
    auto zAxis = [&](int i) { return normalize(parts_[std::size_t(i)].baseQ.act({0, 0, 1})); };
    std::map<int, int> parent;
    for (int i : wings) parent[i] = i;
    auto find = [&](int i) { int r = i; while (parent[r] != r) r = parent[r]; return r; };
    for (std::size_t ai = 0; ai < wings.size(); ++ai) {
        int i = wings[ai];
        for (std::size_t bj = ai + 1; bj < wings.size(); ++bj) {
            int j = wings[bj];
            Vec3d zi = zAxis(i), zj = zAxis(j);
            if (std::fabs(dot(zi, zj)) < 0.985) continue;
            Vec3d d = qc(j) - qc(i);
            double along = dot(d, zi);
            double perp = length(d - zi * along);
            double cmax = smax(parts_[std::size_t(i)].kChord, parts_[std::size_t(j)].kChord);
            if (perp > 0.5 * cmax) continue;
            double gap = std::fabs(along) - 0.5 * (parts_[std::size_t(i)].kSpan + parts_[std::size_t(j)].kSpan);
            if (gap > cmax) continue;
            parent[find(j)] = find(i);
        }
    }
    std::map<int, int> rootToGroup;
    for (int i : wings) {
        int r = find(i);
        auto it = rootToGroup.find(r);
        if (it != rootToGroup.end()) { groupOf[std::size_t(i)] = it->second; continue; }
        rootToGroup[r] = int(groups.size()); groupOf[std::size_t(i)] = int(groups.size()); groups.push_back(WingGroup{});
    }
    for (int g = 0; g < int(groups.size()); ++g) {
        std::vector<int> members;
        for (int i : wings) if (groupOf[std::size_t(i)] == g) members.push_back(i);
        Vec3d ax = zAxis(members[0]), ref = qc(members[0]);
        double lo = kInf, hi = -kInf, area = 0;
        Vec3d perpSum;
        for (int i : members) {
            const SimPart& p = parts_[std::size_t(i)];
            double along = dot(qc(i) - ref, ax);
            lo = smin(lo, along - p.kSpan / 2); hi = smax(hi, along + p.kSpan / 2);
            double a = p.kSpan * p.kChord;
            perpSum += (qc(i) - ax * dot(qc(i), ax)) * a; area += a;
        }
        Vec3d perp = area > 0 ? perpSum / area : ref - ax * dot(ref, ax);
        double mid = dot(ref, ax) + 0.5 * (lo + hi);
        WingGroup G;
        G.center = perp + ax * mid; G.axis = ax; G.span = hi - lo; G.chord = area / smax(hi - lo, 1e-6); G.area = area;
        groups[std::size_t(g)] = G;
    }
    for (std::size_t i = 0; i < parts_.size(); ++i) parts_[i].wingGroup = groupOf[i];
    wingGroups_ = groups;
    groupState_.assign(std::max<std::size_t>(1, groups.size()), WingGroupState{});
    horseshoes_.assign(std::max<std::size_t>(1, groups.size()), Horseshoe{});
    horseshoeCount_ = 0;
}

int CraftSim::partIndex(const std::string& id) const {
    for (int i = 0; i < int(parts_.size()); ++i) if (docOf(parts_[std::size_t(i)]).id == id) return i;
    return -1;
}

ForceTorque CraftSim::panelForce(int part) const {
    if (part < 0 || part >= int(parts_.size()) || parts_[std::size_t(part)].meshSlot < 0) return {};
    const SimPart& p = parts_[std::size_t(part)];
    ForceTorque ft = itemOut_[std::size_t(p.itemStart)];
    if (p.itemCount > 1) { ft = ForceTorque{}; for (int k = p.itemStart; k < p.itemStart + p.itemCount; ++k) ft = ft + itemOut_[std::size_t(k)]; }
    return ft;
}

int CraftSim::wingGroupIndex(const std::string& partID) const {
    for (auto& p : parts_) if (docOf(p).id == partID) return p.wingGroup;
    return -1;
}

Vec3d CraftSim::downwashVelocity(const Vec3d& p, int excludeGroup) const {
    return DownwashView{horseshoeCount_ > 0 ? horseshoes_.data() : nullptr, horseshoeCount_}.velocity(p, excludeGroup);
}

// MARK: clone ------------------------------------------------------------------------------------------------------

std::unique_ptr<CraftSim> CraftSim::clone() const {
    auto c = std::make_unique<CraftSim>();
    c->substepHz = substepHz; c->aeroEnabled = aeroEnabled; c->groundEnabled = groundEnabled;
    c->slipstream = slipstream; c->turbulence = turbulence; c->stripsPerWing = stripsPerWing;
    c->parallelThreshold = parallelThreshold; c->fastToggles = fastToggles; c->crashSpeed = crashSpeed;
    c->sensorNoiseSeed = sensorNoiseSeed; c->jobSystem = jobSystem;
    if (!loaded_) return c;
    c->load(craft_);
    // CAD meshes replaced through setPartMesh are re-created from their triangles (fresh shadow state).
    for (std::size_t i = 0; i < parts_.size(); ++i) {
        const SimPart& p = parts_[i];
        if (p.mesh >= 0 && (c->parts_[i].mesh < 0 || c->meshes_[std::size_t(c->parts_[i].mesh)]->count() != meshes_[std::size_t(p.mesh)]->count())) {
            std::vector<Vec3d> soup;
            for (auto& t : meshes_[std::size_t(p.mesh)]->tris()) { soup.push_back(t.a); soup.push_back(t.b); soup.push_back(t.c); }
            c->setPartMesh(docOf(p).id, soup);
        }
    }
    // State.
    for (std::size_t i = 0; i < parts_.size(); ++i) {
        SimPart& d = c->parts_[i];
        int mesh = d.mesh;
        d = parts_[i];
        d.mesh = mesh;
    }
    c->rebuildPanelBatch();
    c->outputs_ = outputs_; c->outputTargets_ = outputTargets_; c->telemetry_ = telemetry_;
    c->groupState_ = groupState_;
    c->mass_ = mass_; c->comLocal_ = comLocal_; c->inertia_ = inertia_; c->inertiaInv_ = inertiaInv_;
    c->position_ = position_; c->orientation_ = orientation_; c->velocity_ = velocity_; c->angularMomentum_ = angularMomentum_;
    c->time_ = time_; c->stepCounter_ = stepCounter_; c->lastForce_ = lastForce_;
    c->crashed_ = crashed_; c->groundContact_ = groundContact_; c->maxImpactSpeed_ = maxImpactSpeed_;
    c->inputs_ = inputs_; c->noiseState_ = noiseState_;
    return c;
}

} // namespace pw::sim
