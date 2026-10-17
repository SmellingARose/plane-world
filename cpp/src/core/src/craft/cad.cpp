#include "pw/craft/cad.h"
#include <algorithm>
#include <cctype>
#include <charconv>
#include <cmath>
#include <cstring>
#include <fstream>
#include <functional>
#include <map>
#include <set>
#include "pw/json.h"

namespace pw::craft {

static constexpr float kPiF = 3.14159265358979323846f;

Mat4f CADImportOptions::matrix() const {
    Mat4f m;
    if (up == Up::Z) { float s = std::sin(-kPiF / 4), c = std::cos(-kPiF / 4); m = Mat4f::fromQuat(s, 0, 0, c); }
    float a = float(yawDegrees * kDeg);
    m = Mat4f::fromQuat(0, std::sin(a / 2), 0, std::cos(a / 2)) * m;
    return Mat4f::scale(float(scale)) * m;
}

namespace cad {

static std::string lowerExt(const std::string& path) {
    auto dot = path.find_last_of('.');
    auto sep = path.find_last_of("/\\");
    if (dot == std::string::npos || (sep != std::string::npos && dot < sep)) return {};
    std::string e = path.substr(dot + 1);
    for (auto& c : e) c = char(std::tolower((unsigned char)c));
    return e;
}
static std::string stem(const std::string& path) {
    auto sep = path.find_last_of("/\\");
    std::string f = sep == std::string::npos ? path : path.substr(sep + 1);
    auto dot = f.find_last_of('.');
    return dot == std::string::npos || dot == 0 ? f : f.substr(0, dot);
}
static std::string dirOf(const std::string& path) {
    auto sep = path.find_last_of("/\\");
    return sep == std::string::npos ? std::string(".") : path.substr(0, sep);
}

bool readBytes(const std::string& path, std::vector<uint8_t>& out) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    f.seekg(0, std::ios::end);
    auto n = f.tellg();
    if (n < 0) return false;
    f.seekg(0);
    out.resize(std::size_t(n));
    if (n > 0) f.read(reinterpret_cast<char*>(out.data()), n);
    return bool(f) || f.eof();
}

std::vector<std::string> fileExtensions() {
    std::vector<std::string> e{"stl", "obj", "gltf", "glb"};
    if (usdSupported()) e.insert(e.end(), {"usd", "usda", "usdc", "usdz"});
    return e;
}

bool load(const std::string& path, const CADImportOptions& opt, std::vector<ImportedPart>& out, std::string& err) {
    std::string ext = lowerExt(path);
    std::vector<ImportedPart> parts;
    if (ext == "stl" || ext == "obj" || ext == "gltf" || ext == "glb") {
        std::vector<uint8_t> data;
        if (!readBytes(path, data)) { err = "cannot read " + path; return false; }
        if (ext == "stl") {
            TriMesh m;
            if (!parseSTL(data, m, err)) return false;
            parts.push_back({stem(path), std::move(m)});
        } else if (ext == "obj") {
            if (!parseOBJ(std::string_view(reinterpret_cast<const char*>(data.data()), data.size()), stem(path), parts, err)) return false;
        } else if (!parseGLTF(data, dirOf(path), parts, err)) return false;
    } else if (ext == "usd" || ext == "usda" || ext == "usdc" || ext == "usdz") {
        if (!loadPlatform(path, parts, err)) return false;
    } else {
        err = "unsupported format: " + (ext.empty() ? std::string("(no extension)") : ext);
        return false;
    }
    Mat4f m = opt.matrix();
    out.clear();
    for (auto& p : parts) if (!p.mesh.isEmpty()) out.push_back({p.name, p.mesh.transformed(m)});
    if (out.empty()) { err = "no triangles found"; return false; }
    return true;
}

// ---------------------------------------------------------------- STL

static uint32_t u32le(const uint8_t* p) { return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24; }
static float f32le(const uint8_t* p) { uint32_t u = u32le(p); float f; std::memcpy(&f, &u, 4); return f; }
static void putU32(std::vector<uint8_t>& d, uint32_t v) { for (int i = 0; i < 4; ++i) d.push_back(uint8_t(v >> (8 * i))); }
static void putF32(std::vector<uint8_t>& d, float f) { uint32_t u; std::memcpy(&u, &f, 4); putU32(d, u); }

static bool parseFloat(std::string_view s, float& out) { return geo::parseFloat(s, out); }

static std::vector<std::string_view> splitWS(std::string_view line) {
    std::vector<std::string_view> t;
    std::size_t i = 0;
    while (i < line.size()) {
        while (i < line.size() && (line[i] == ' ' || line[i] == '\t')) ++i;
        std::size_t b = i;
        while (i < line.size() && line[i] != ' ' && line[i] != '\t') ++i;
        if (i > b) t.push_back(line.substr(b, i - b));
    }
    return t;
}
template <class F> static void forLines(std::string_view text, F f) {
    std::size_t i = 0;
    while (i < text.size()) {
        std::size_t e = text.find_first_of("\r\n", i);
        if (e == std::string_view::npos) e = text.size();
        if (e > i) f(text.substr(i, e - i));
        i = e + 1;
    }
}

bool parseSTL(const std::vector<uint8_t>& data, TriMesh& out, std::string& err) {
    if (data.size() >= 84) {
        uint32_t n = u32le(data.data() + 80);
        if (84 + std::size_t(n) * 50 == data.size()) {
            std::vector<Vec3f> pts;
            pts.reserve(std::size_t(n) * 3);
            for (uint32_t t = 0; t < n; ++t) {
                const uint8_t* o = data.data() + 84 + std::size_t(t) * 50 + 12;
                for (int v = 0; v < 3; ++v) pts.push_back({f32le(o + v * 12), f32le(o + v * 12 + 4), f32le(o + v * 12 + 8)});
            }
            std::vector<uint32_t> idx(pts.size());
            for (uint32_t i = 0; i < idx.size(); ++i) idx[i] = i;
            out = TriMesh(std::move(pts), std::move(idx)).welded();
            return true;
        }
    }
    std::string_view text(reinterpret_cast<const char*>(data.data()), data.size());
    if (text.find("vertex") == std::string_view::npos) { err = "malformed file: STL: neither binary nor ASCII"; return false; }
    std::vector<Vec3f> pts;
    forLines(text, [&](std::string_view line) {
        auto t = splitWS(line);
        float x, y, z;
        if (t.size() >= 4 && t[0] == "vertex" && parseFloat(t[1], x) && parseFloat(t[2], y) && parseFloat(t[3], z)) pts.push_back({x, y, z});
    });
    pts.resize(pts.size() / 3 * 3);
    std::vector<uint32_t> idx(pts.size());
    for (uint32_t i = 0; i < idx.size(); ++i) idx[i] = i;
    out = TriMesh(std::move(pts), std::move(idx)).welded();
    return true;
}

std::vector<uint8_t> stlBinary(const TriMesh& m) {
    std::vector<uint8_t> d(80, 0);
    putU32(d, uint32_t(m.triangleCount()));
    for (std::size_t t = 0; t < m.triangleCount(); ++t) {
        Vec3f a = m.positions[m.indices[t * 3]], b = m.positions[m.indices[t * 3 + 1]], c = m.positions[m.indices[t * 3 + 2]];
        Vec3f nn = geo::normalize(geo::cross(b - a, c - a));
        for (const Vec3f& v : {nn, a, b, c}) { putF32(d, v.x); putF32(d, v.y); putF32(d, v.z); }
        d.push_back(0); d.push_back(0);
    }
    return d;
}

// ---------------------------------------------------------------- OBJ

bool parseOBJ(std::string_view text, const std::string& defaultName, std::vector<ImportedPart>& out, std::string& err) {
    std::vector<Vec3f> verts;
    std::vector<std::pair<std::string, std::vector<uint32_t>>> parts{{defaultName, {}}};
    forLines(text, [&](std::string_view raw) {
        std::string_view line = raw.substr(0, raw.find('#'));
        auto t = splitWS(line);
        if (t.empty()) return;
        if (t[0] == "v" && t.size() >= 4) {
            float x = 0, y = 0, z = 0;
            if (!parseFloat(t[1], x)) x = 0;
            if (!parseFloat(t[2], y)) y = 0;
            if (!parseFloat(t[3], z)) z = 0;
            verts.push_back({x, y, z});
        } else if (t[0] == "o" || t[0] == "g") {
            std::string name;
            for (std::size_t i = 1; i < t.size(); ++i) { if (i > 1) name += ' '; name += std::string(t[i]); }
            if (parts.back().second.empty()) parts.back().first = name.empty() ? defaultName : name;
            else parts.push_back({name.empty() ? defaultName + "_" + std::to_string(parts.size()) : name, {}});
        } else if (t[0] == "f" && t.size() >= 4) {
            std::vector<uint32_t> idx;
            for (std::size_t k = 1; k < t.size(); ++k) {
                std::string_view tok = t[k].substr(0, t[k].find('/'));
                long long i = 0;
                if (tok.empty()) continue;
                const char* b = tok.data();
                if (*b == '+') ++b;
                auto r = std::from_chars(b, tok.data() + tok.size(), i);
                if (r.ec != std::errc() || r.ptr != tok.data() + tok.size()) continue;
                long long rr = i < 0 ? (long long)verts.size() + i : i - 1;
                if (rr >= 0 && rr < (long long)verts.size()) idx.push_back(uint32_t(rr));
            }
            if (idx.size() >= 3)
                for (std::size_t j = 1; j + 1 < idx.size(); ++j) parts.back().second.insert(parts.back().second.end(), {idx[0], idx[j], idx[j + 1]});
        }
    });
    if (verts.empty()) { err = "malformed file: OBJ: no vertices"; return false; }
    out.clear();
    for (auto& [name, idx] : parts) {
        if (idx.empty()) continue;
        std::map<uint32_t, uint32_t> remap;
        TriMesh m;
        for (uint32_t i : idx) {
            auto it = remap.find(i);
            if (it == remap.end()) { it = remap.emplace(i, uint32_t(m.positions.size())).first; m.positions.push_back(verts[i]); }
            m.indices.push_back(it->second);
        }
        out.push_back({name, std::move(m)});
    }
    return true;
}

// ---------------------------------------------------------------- glTF 2.0

namespace {
int asInt(const json::Value& v, int def = -1) { return v.isNumber() ? int(v.num()) : def; }

bool decodeURI(const std::string& s, std::string& out) {
    out.clear();
    for (std::size_t i = 0; i < s.size(); ++i) {
        if (s[i] == '%' && i + 2 < s.size()) {
            auto hex = [](char c) { return c >= '0' && c <= '9' ? c - '0' : (c >= 'a' && c <= 'f' ? c - 'a' + 10 : (c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1)); };
            int h = hex(s[i + 1]), l = hex(s[i + 2]);
            if (h < 0 || l < 0) return false;
            out += char(h * 16 + l);
            i += 2;
        } else out += s[i];
    }
    return true;
}
} // namespace

bool parseGLTF(const std::vector<uint8_t>& data, const std::string& baseDir, std::vector<ImportedPart>& out, std::string& err) {
    std::string_view jsonText(reinterpret_cast<const char*>(data.data()), data.size());
    std::vector<uint8_t> bin;
    bool haveBin = false;
    if (data.size() >= 12 && std::memcmp(data.data(), "glTF", 4) == 0) {
        std::size_t off = 12;
        jsonText = {};
        while (off + 8 <= data.size()) {
            std::size_t len = u32le(data.data() + off);
            uint32_t type = u32le(data.data() + off + 4);
            std::size_t b = off + 8, e = std::min(data.size(), off + 8 + len);
            if (type == 0x4E4F534Au) jsonText = std::string_view(reinterpret_cast<const char*>(data.data() + b), e - b);
            else if (type == 0x004E4942u) { bin.assign(data.begin() + std::ptrdiff_t(b), data.begin() + std::ptrdiff_t(e)); haveBin = true; }
            off += 8 + len;
        }
    }
    // trailing padding (spaces / NULs) after the JSON chunk
    while (!jsonText.empty() && (jsonText.back() == '\0' || jsonText.back() == ' ')) jsonText.remove_suffix(1);
    auto pr = json::parse(jsonText);
    if (!pr.ok || !pr.value.isObject()) { err = "malformed file: glTF JSON" + (pr.ok ? std::string() : ": " + pr.error); return false; }
    const json::Value& root = pr.value;

    std::vector<std::vector<uint8_t>> buffers;
    const auto& bufs = root["buffers"];
    for (std::size_t i = 0; i < bufs.size(); ++i) {
        const auto& b = bufs[i];
        if (b["uri"].isString()) {
            const std::string& uri = b["uri"].str();
            if (uri.rfind("data:", 0) == 0) {
                auto comma = uri.find(',');
                if (comma == std::string::npos) { err = "malformed file: data URI"; return false; }
                buffers.push_back(geo::base64Decode(std::string_view(uri).substr(comma + 1)));
                continue;
            }
            if (baseDir.empty()) { err = "malformed file: external buffer without base URL"; return false; }
            std::string dec;
            if (!decodeURI(uri, dec)) dec = uri;
            std::vector<uint8_t> d;
            if (!readBytes(baseDir + "/" + dec, d)) { err = "malformed file: cannot read buffer " + dec; return false; }
            buffers.push_back(std::move(d));
            continue;
        }
        if (i != 0 || !haveBin) { err = "malformed file: buffer " + std::to_string(i) + " missing"; return false; }
        buffers.push_back(bin);
    }
    const auto& views = root["bufferViews"];
    const auto& accessors = root["accessors"];
    const auto& meshes = root["meshes"];
    const auto& nodes = root["nodes"];

    auto readAccessor = [&](int ai, std::vector<float>& values, int& comps) -> bool {
        if (ai < 0 || std::size_t(ai) >= accessors.size()) { err = "malformed file: accessor " + std::to_string(ai); return false; }
        const auto& a = accessors[std::size_t(ai)];
        int count = asInt(a["count"], 0), ctype = asInt(a["componentType"], 5126);
        std::string type = a["type"].isString() ? a["type"].str() : "SCALAR";
        comps = type == "VEC2" ? 2 : type == "VEC3" ? 3 : type == "VEC4" ? 4 : type == "MAT4" ? 16 : 1;
        int csize = (ctype == 5120 || ctype == 5121) ? 1 : (ctype == 5122 || ctype == 5123) ? 2 : 4;
        values.clear();
        int vi = asInt(a["bufferView"]);
        if (vi < 0) { values.assign(std::size_t(count) * std::size_t(comps), 0.0f); return true; }   // sparse-only: zeros
        if (std::size_t(vi) >= views.size()) { err = "malformed file: bufferView " + std::to_string(vi); return false; }
        const auto& v = views[std::size_t(vi)];
        int bi = asInt(v["buffer"], 0);
        if (bi < 0 || std::size_t(bi) >= buffers.size()) { err = "malformed file: buffer index"; return false; }
        const auto& buf = buffers[std::size_t(bi)];
        std::size_t base = std::size_t(asInt(v["byteOffset"], 0)) + std::size_t(asInt(a["byteOffset"], 0));
        std::size_t stride = v["byteStride"].isNumber() ? std::size_t(asInt(v["byteStride"])) : std::size_t(comps * csize);
        bool normalized = a["normalized"].boolean(false);
        if (count > 0 && base + std::size_t(count - 1) * stride + std::size_t(comps * csize) > buf.size()) {
            err = "malformed file: accessor " + std::to_string(ai) + " out of range"; return false;
        }
        values.reserve(std::size_t(count) * std::size_t(comps));
        for (int e = 0; e < count; ++e)
            for (int c = 0; c < comps; ++c) {
                const uint8_t* p = buf.data() + base + std::size_t(e) * stride + std::size_t(c * csize);
                float f;
                switch (ctype) {
                case 5126: f = f32le(p); break;
                case 5125: f = float(u32le(p)); break;
                case 5123: { uint16_t u = uint16_t(p[0] | p[1] << 8); f = normalized ? float(u) / 65535 : float(u); break; }
                case 5122: { int16_t u = int16_t(uint16_t(p[0] | p[1] << 8)); f = normalized ? std::max(float(u) / 32767, -1.0f) : float(u); break; }
                case 5121: f = normalized ? float(p[0]) / 255 : float(p[0]); break;
                default: { int8_t u = int8_t(p[0]); f = normalized ? std::max(float(u) / 127, -1.0f) : float(u); break; }
                }
                values.push_back(f);
            }
        return true;
    };

    auto meshData = [&](std::size_t mi, TriMesh& m) -> bool {
        m = TriMesh();
        const auto& prims = meshes[mi]["primitives"];
        for (std::size_t k = 0; k < prims.size(); ++k) {
            const auto& prim = prims[k];
            int mode = asInt(prim["mode"], 4);
            int pa = asInt(prim["attributes"]["POSITION"]);
            if (pa < 0) continue;
            std::vector<float> pv; int comps = 0;
            if (!readAccessor(pa, pv, comps)) return false;
            std::vector<Vec3f> pos;
            for (std::size_t i = 0; i + 2 < pv.size(); i += 3) pos.push_back({pv[i], pv[i + 1], pv[i + 2]});
            std::vector<uint32_t> idx;
            int ii = asInt(prim["indices"]);
            if (ii >= 0) {
                std::vector<float> iv; int c2 = 0;
                if (!readAccessor(ii, iv, c2)) return false;
                for (float f : iv) idx.push_back(uint32_t(f));
            } else for (uint32_t i = 0; i < uint32_t(pos.size()); ++i) idx.push_back(i);
            std::vector<uint32_t> tris;
            if (mode == 4) tris.assign(idx.begin(), idx.begin() + std::ptrdiff_t(idx.size() / 3 * 3));
            else if (mode == 5) { for (std::size_t i = 0; i + 2 < idx.size(); ++i) { if (i % 2 == 0) tris.insert(tris.end(), {idx[i], idx[i + 1], idx[i + 2]}); else tris.insert(tris.end(), {idx[i + 1], idx[i], idx[i + 2]}); } }
            else if (mode == 6) { for (std::size_t i = 1; i + 1 < idx.size(); ++i) tris.insert(tris.end(), {idx[0], idx[i], idx[i + 1]}); }
            else continue;   // points / lines are not craft geometry
            bool valid = std::all_of(tris.begin(), tris.end(), [&](uint32_t t) { return t < pos.size(); });
            m.append(TriMesh(pos, valid ? tris : std::vector<uint32_t>{}));
        }
        return true;
    };

    auto localMatrix = [&](const json::Value& n) {
        const auto& mm = n["matrix"];
        if (mm.isArray() && mm.size() == 16) {
            Mat4f m;
            for (int c = 0; c < 4; ++c) for (int r = 0; r < 4; ++r) m.c[c][r] = float(mm[std::size_t(c * 4 + r)].num());
            return m;
        }
        auto vec = [&](const char* k, std::initializer_list<float> d) {
            std::vector<float> v(d);
            const auto& a = n[k];
            if (a.isArray()) { v.clear(); for (auto& x : a.items()) v.push_back(float(x.num())); }
            return v;
        };
        auto t = vec("translation", {0, 0, 0}), r = vec("rotation", {0, 0, 0, 1}), s = vec("scale", {1, 1, 1});
        if (t.size() < 3) t = {0, 0, 0};
        if (r.size() < 4) r = {0, 0, 0, 1};
        if (s.size() < 3) s = {1, 1, 1};
        Mat4f m = Mat4f::fromQuat(r[0], r[1], r[2], r[3]);
        for (int k = 0; k < 4; ++k) { m.c[0][k] *= s[0]; m.c[1][k] *= s[1]; m.c[2][k] *= s[2]; }
        m.c[3][0] = t[0]; m.c[3][1] = t[1]; m.c[3][2] = t[2]; m.c[3][3] = 1;
        return m;
    };

    out.clear();
    std::set<int> visited;
    std::string failure;
    std::function<bool(int, const Mat4f&, const std::string&)> visit = [&](int ni, const Mat4f& parent, const std::string& parentName) -> bool {
        if (ni < 0 || std::size_t(ni) >= nodes.size() || !visited.insert(ni).second) return true;
        const auto& n = nodes[std::size_t(ni)];
        Mat4f world = parent * localMatrix(n);
        int mi = asInt(n["mesh"]);
        std::string name;
        if (n["name"].isString()) name = n["name"].str();
        else if (mi >= 0 && std::size_t(mi) < meshes.size() && meshes[std::size_t(mi)]["name"].isString()) name = meshes[std::size_t(mi)]["name"].str();
        else name = parentName + "node" + std::to_string(ni);
        if (mi >= 0 && std::size_t(mi) < meshes.size()) {
            TriMesh m;
            if (!meshData(std::size_t(mi), m)) return false;
            if (!m.isEmpty()) out.push_back({name, m.transformed(world)});
        }
        for (auto& c : n["children"].items()) if (!visit(asInt(c), world, name + "/")) return false;
        return true;
    };
    std::vector<int> roots;
    const auto& scenes = root["scenes"];
    if (scenes.size() > 0) {
        int si = asInt(root["scene"], 0);
        for (auto& r : scenes[std::size_t(std::max(0, si))]["nodes"].items()) roots.push_back(asInt(r));
    }
    if (roots.empty()) {
        std::set<int> child;
        for (auto& n : nodes.items()) for (auto& c : n["children"].items()) child.insert(asInt(c));
        for (int i = 0; i < int(nodes.size()); ++i) if (!child.count(i)) roots.push_back(i);
    }
    for (int r : roots) if (!visit(r, Mat4f::identity(), "")) return false;
    if (nodes.size() == 0)
        for (std::size_t mi = 0; mi < meshes.size(); ++mi) {
            TriMesh m;
            if (!meshData(mi, m)) return false;
            out.push_back({meshes[mi]["name"].isString() ? meshes[mi]["name"].str() : "mesh" + std::to_string(mi), std::move(m)});
        }
    return true;
}

#if !defined(__APPLE__)
bool usdSupported() { return false; }
bool loadPlatform(const std::string& path, std::vector<ImportedPart>&, std::string& err) {
    err = "USD/USDZ import is not available on this platform (it uses Apple ModelIO on macOS). Convert " + stem(path) +
          " to glTF/GLB, OBJ or STL and import that instead.";
    return false;
}
#endif

} // namespace cad
} // namespace pw::craft
