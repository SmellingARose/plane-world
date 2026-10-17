#include "pw/render/renderer.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include "pw/craft/mesh.h"

namespace pw::render {

// ---------------------------------------------------------------- math helpers

Float4x4 inverse(const Float4x4& mm) {
    // Cofactor expansion (column-major in, column-major out).
    float m[16];
    for (int c = 0; c < 4; ++c) { m[c * 4 + 0] = mm.c[c].x; m[c * 4 + 1] = mm.c[c].y; m[c * 4 + 2] = mm.c[c].z; m[c * 4 + 3] = mm.c[c].w; }
    float inv[16];
    inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10];
    inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10];
    inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9];
    inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9];
    inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10];
    inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10];
    inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9];
    inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9];
    inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6];
    inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6];
    inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5];
    inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5];
    inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6];
    inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6];
    inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5];
    inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5];
    double det = double(m[0]) * inv[0] + double(m[1]) * inv[4] + double(m[2]) * inv[8] + double(m[3]) * inv[12];
    float s = det != 0 ? float(1.0 / det) : 0.0f;
    Float4x4 r;
    for (int c = 0; c < 4; ++c) r.c[c] = {inv[c * 4 + 0] * s, inv[c * 4 + 1] * s, inv[c * 4 + 2] * s, inv[c * 4 + 3] * s};
    return r;
}

Float3 linearColor(const std::string& hexIn) {
    std::string s;
    for (char ch : hexIn) if (ch != ' ' && ch != '#') s += ch;
    if (s.size() == 3) s = std::string{s[0], s[0], s[1], s[1], s[2], s[2]};
    unsigned v = 0xcccccc;
    if (s.size() == 6) { char* end = nullptr; unsigned long x = std::strtoul(s.c_str(), &end, 16); if (end && *end == 0) v = unsigned(x); }
    auto lin = [](unsigned c) { float x = float(c) / 255.0f; return x <= 0.04045f ? x / 12.92f : std::pow((x + 0.055f) / 1.055f, 2.4f); };
    return {lin((v >> 16) & 255), lin((v >> 8) & 255), lin(v & 255)};
}

static Quatd quatFromBasis(const Vec3d& r, const Vec3d& u, const Vec3d& b) {
    // Rotation matrix with columns r, u, b (b = -forward) -> unit quaternion (Shepperd).
    double m00 = r.x, m10 = r.y, m20 = r.z, m01 = u.x, m11 = u.y, m21 = u.z, m02 = b.x, m12 = b.y, m22 = b.z;
    double tr = m00 + m11 + m22;
    Quatd q;
    if (tr > 0) {
        double s = std::sqrt(tr + 1.0) * 2;
        q = {(m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s, 0.25 * s};
    } else if (m00 > m11 && m00 > m22) {
        double s = std::sqrt(1.0 + m00 - m11 - m22) * 2;
        q = {0.25 * s, (m01 + m10) / s, (m02 + m20) / s, (m21 - m12) / s};
    } else if (m11 > m22) {
        double s = std::sqrt(1.0 + m11 - m00 - m22) * 2;
        q = {(m01 + m10) / s, 0.25 * s, (m12 + m21) / s, (m02 - m20) / s};
    } else {
        double s = std::sqrt(1.0 + m22 - m00 - m11) * 2;
        q = {(m02 + m20) / s, (m12 + m21) / s, 0.25 * s, (m10 - m01) / s};
    }
    return q.normalized();
}

void Camera::lookAt(const Vec3d& target, const Vec3d& eye) {
    position = eye;
    Vec3d d = target - eye;
    double l = length(d);
    Vec3d f = l > 0 ? d * (1.0 / l) : Vec3d{0, 0, -1};
    Vec3d r = cross(f, {0, 1, 0});
    if (length(r) < 1e-6) r = {1, 0, 0};
    r = normalize(r);
    Vec3d u = cross(r, f);
    orientation = quatFromBasis(r, u, -f);
}

Float4x4 Camera::viewMatrix() const { return Float4x4::lookAt({0, 0, 0}, Float3(forward()), Float3(up())); }

Vec3d Renderer::sunDirection(double h, double azimuthDeg) {
    double hourAngle = (h - 12) / 24 * 2 * kPi;
    double decl = 10 * kDeg, lat = 40 * kDeg;
    double el = std::asin(std::sin(lat) * std::sin(decl) + std::cos(lat) * std::cos(decl) * std::cos(hourAngle));
    double az = std::atan2(-std::sin(hourAngle), std::tan(decl) * std::cos(lat) - std::sin(lat) * std::cos(hourAngle));
    az += (azimuthDeg - 180) * kDeg;
    return normalize(Vec3d{std::cos(el) * std::sin(az), std::sin(el), -std::cos(el) * std::cos(az)});
}

float Renderer::halton(int i, int b) {
    float f = 1, r = 0;
    while (i > 0) { f /= float(b); r += f * float(i % b); i /= b; }
    return r;
}

// ---------------------------------------------------------------- meshes

namespace meshes {
void plane(float size, int divisions, std::vector<MeshVertex>& v, std::vector<uint32_t>& idx) {
    int n = std::max(1, divisions);
    for (int z = 0; z <= n; ++z)
        for (int x = 0; x <= n; ++x) {
            float u = float(x) / float(n), w = float(z) / float(n);
            v.push_back({(u - 0.5f) * size, 0, (w - 0.5f) * size, 0, 1, 0, u, w});
        }
    uint32_t row = uint32_t(n + 1);
    for (uint32_t z = 0; z < uint32_t(n); ++z)
        for (uint32_t x = 0; x < uint32_t(n); ++x) {
            uint32_t a = z * row + x;
            idx.insert(idx.end(), {a, a + row, a + 1, a + 1, a + row, a + row + 1});
        }
}
void fromMeshData(const craft::MeshData& m, std::vector<MeshVertex>& v, std::vector<uint32_t>& idx) {
    v.resize(m.positions.size());
    for (std::size_t i = 0; i < m.positions.size(); ++i) {
        const auto& p = m.positions[i];
        const auto n = i < m.normals.size() ? m.normals[i] : geo::Vec3f{0, 1, 0};
        const auto uv = i < m.uvs.size() ? m.uvs[i] : craft::Vec2f{};
        v[i] = {p.x, p.y, p.z, n.x, n.y, n.z, uv.x, uv.y};
    }
    idx = m.indices;
}
} // namespace meshes

GpuMesh::GpuMesh(gpu::Device& dev, const std::vector<MeshVertex>& v, const std::vector<uint32_t>& idx, const char* label) {
    if (v.empty() || idx.empty()) return;
    vb = dev.createBufferWithData(v.data(), v.size() * sizeof(MeshVertex), false, label);
    ib = dev.createBufferWithData(idx.data(), idx.size() * 4, true, label);
    count = int(idx.size());
    for (auto& x : v) box.expand({x.px, x.py, x.pz});
}
std::unique_ptr<GpuMesh> GpuMesh::fromMeshData(gpu::Device& dev, const craft::MeshData& m, const char* label) {
    std::vector<MeshVertex> v; std::vector<uint32_t> idx;
    meshes::fromMeshData(m, v, idx);
    auto g = std::make_unique<GpuMesh>(dev, v, idx, label);
    if (!g->valid()) return nullptr;
    return g;
}

// ---------------------------------------------------------------- frame context + mesh renderable

void FrameContext::bindFrame(gpu::CommandList& cmd) const {
    cmd.setConstantBuffer(0, uniformBuffer, uniformOffset);
    cmd.setTexture(0, shadowMap);
    cmd.setTexture(1, skyLUT);
    for (int i = 0; i < 3; ++i) cmd.setTexture(2 + i, aerial[i]);
}
bool FrameContext::transient(const void* data, std::size_t size, gpu::Buffer** buf, std::size_t* off) const {
    void* p = device->allocTransient(size, buf, off);
    if (!p) return false;
    std::memcpy(p, data, size);
    return true;
}

void MeshRenderable::prepare(FrameContext& f) {
    prepared.clear();
    for (auto& [mesh, items] : batches) {
        if (!mesh || !mesh->valid() || items.empty()) continue;
        scratch.resize(items.size());
        for (std::size_t i = 0; i < items.size(); ++i) {
            const Item& it = items[i];
            MeshInstance& m = scratch[i];
            m.model = matrixRelativeTo(it.transform.position, it.transform.rotation, f.camera.position, it.scale);
            m.color = {it.albedo, it.roughness};
            m.material = {it.metallic, it.emissive, it.pattern, 0};
        }
        gpu::Buffer* buf = nullptr; std::size_t off = 0;
        if (f.transient(scratch.data(), scratch.size() * sizeof(MeshInstance), &buf, &off)) prepared.push_back({mesh, buf, off, int(items.size())});
    }
}
void MeshRenderable::drawShadow(gpu::CommandList& cmd, FrameContext&, int) {
    if (!castsShadows) return;
    for (auto& p : prepared) {
        cmd.setBuffer(8, p.mesh->vertices());
        cmd.setBuffer(9, p.buf, p.off);
        cmd.drawIndexed(p.mesh->indices(), p.mesh->indexCount(), p.count);
    }
}
void MeshRenderable::drawOpaque(gpu::CommandList& cmd, FrameContext& f) {
    cmd.setPipeline(f.pipelines.mesh);
    f.bindFrame(cmd);
    for (auto& p : prepared) {
        cmd.setBuffer(8, p.mesh->vertices());
        cmd.setBuffer(9, p.buf, p.off);
        cmd.drawIndexed(p.mesh->indices(), p.mesh->indexCount(), p.count);
    }
}

// ---------------------------------------------------------------- debug lines

void DebugDraw::line(const Vec3d& a, const Vec3d& b, Float4 c) {
    if (!enabled) return;
    std::lock_guard<std::mutex> g(lock);
    lines.push_back({a, b, c});
}
void DebugDraw::cross(const Vec3d& p, double s, Float4 c) {
    line(p - Vec3d{s, 0, 0}, p + Vec3d{s, 0, 0}, c);
    line(p - Vec3d{0, s, 0}, p + Vec3d{0, s, 0}, c);
    line(p - Vec3d{0, 0, s}, p + Vec3d{0, 0, s}, c);
}
void DebugDraw::take(const Vec3d& origin, std::vector<Float4>& out) {
    out.clear();
    std::lock_guard<std::mutex> g(lock);
    out.reserve(lines.size() * 4);
    for (auto& l : lines) {
        out.push_back({Float3(l.a - origin), 1}); out.push_back(l.c);
        out.push_back({Float3(l.b - origin), 1}); out.push_back(l.c);
    }
    lines.clear();
}

// ---------------------------------------------------------------- renderer

namespace {
enum Timer { kTAtmosphere = 0, kTShadow0 = 1, kTHdr = 5, kTTaa = 6, kTBloom = 7, kTTonemap = 8 };
struct PassParams { uint32_t cascade, pad0, pad1, pad2; };
struct PostParams { uint32_t flag; float radius; uint32_t pad0, pad1; };
}

Renderer::Renderer(gpu::Device& d) : dev(d), fg(&d) {}
Renderer::~Renderer() { dev.waitIdle(); }

std::unique_ptr<Renderer> Renderer::create(gpu::Device& device, std::string* error) {
    std::unique_ptr<Renderer> r(new Renderer(device));
    if (!r->init(error)) return nullptr;
    return r;
}

bool Renderer::init(std::string* err) {
    using namespace gpu;
    const Format hdrF = Format::RGBA16F, depthF = Format::D32F;
    GraphicsPipelineDesc g;
    g.shader = "scene"; g.vertex = "meshVertex"; g.fragment = "meshFragment";
    g.color[0] = hdrF; g.colorCount = 1; g.depth = depthF; g.depthCompare = CompareOp::GreaterEqual; g.depthWrite = true;
    g.cull = CullMode::Back; g.frontCCW = true; g.label = "mesh";
    if (!(pMesh = dev.createPipeline(g, err))) return false;
    GraphicsPipelineDesc s;
    s.shader = "scene"; s.vertex = "shadowVertex"; s.fragment = nullptr; s.colorCount = 0; s.depth = depthF;
    s.depthCompare = CompareOp::LessEqual; s.depthWrite = true; s.cull = CullMode::None;
    s.depthBias = settings.shadowBias; s.depthBiasSlope = settings.shadowSlopeBias; s.depthBiasClamp = settings.shadowBiasClamp; s.label = "shadow";
    if (!(pShadow = dev.createPipeline(s, err))) return false;
    GraphicsPipelineDesc sky;
    sky.shader = "scene"; sky.vertex = "fullscreenVertex"; sky.fragment = "skyFragment";
    sky.color[0] = hdrF; sky.colorCount = 1; sky.depth = depthF; sky.depthCompare = CompareOp::GreaterEqual; sky.depthWrite = false; sky.label = "sky";
    if (!(pSky = dev.createPipeline(sky, err))) return false;
    GraphicsPipelineDesc ln = sky;
    ln.vertex = "lineVertex"; ln.fragment = "lineFragment"; ln.blend = BlendMode::Alpha; ln.topology = Topology::Lines; ln.label = "lines";
    if (!(pLines = dev.createPipeline(ln, err))) return false;
    GraphicsPipelineDesc tm;
    tm.shader = "tonemap"; tm.vertex = "tonemapVertex"; tm.fragment = "tonemapFragment"; tm.color[0] = Format::RGBA8; tm.colorCount = 1; tm.label = "tonemap";
    if (!(pTonemap = dev.createPipeline(tm, err))) return false;
    ComputePipelineDesc c;
    c.shader = "atmosphere"; c.entry = "skyViewLUT"; c.groupSize[0] = 16; c.groupSize[1] = 8; c.groupSize[2] = 1;
    if (!(pSkyLUT = dev.createPipeline(c, err))) return false;
    c.entry = "aerialLUT"; c.groupSize[0] = 8; c.groupSize[1] = 8; c.groupSize[2] = 2;
    if (!(pAerial = dev.createPipeline(c, err))) return false;
    const int tile = dev.caps().tuning.taaTile == 8 ? 8 : 16;
    c.shader = "taa"; c.entry = tile == 8 ? "taaResolve8" : "taaResolve16"; c.groupSize[0] = tile; c.groupSize[1] = tile; c.groupSize[2] = 1;
    if (!(pTaa = dev.createPipeline(c, err))) return false;
    c.shader = "bloom"; c.entry = "bloomDownsample"; c.groupSize[0] = 8; c.groupSize[1] = 8;
    if (!(pBloomDown = dev.createPipeline(c, err))) return false;
    c.entry = "bloomUpsample";
    if (!(pBloomUp = dev.createPipeline(c, err))) return false;
    stdPipes.mesh = pMesh.get(); stdPipes.shadow = pShadow.get();

    shadowRes = settings.shadowResolution > 0 ? settings.shadowResolution : dev.caps().tuning.shadowResolution;
    TextureDesc sd; sd.type = TextureType::Tex2DArray; sd.format = depthF; sd.width = sd.height = shadowRes; sd.depthOrLayers = 4;
    sd.usage = TexSampled | TexDepthTarget; sd.label = "shadowCascades";
    if (!(shadowMap = dev.createTexture(sd))) { if (err) *err = "shadow map"; return false; }
    for (int i = 0; i < kFramesInFlight; ++i) {
        TextureDesc ld; ld.format = Format::RGBA16F; ld.width = 256; ld.height = 128; ld.usage = TexSampled | TexStorage | TexCrossQueue; ld.label = "skyViewLUT";
        if (!(skyLUT[i] = dev.createTexture(ld))) { if (err) *err = "sky LUT"; return false; }
        const char* names[3] = {"aerialL", "aerialT", "aerialSunT"};
        for (int k = 0; k < 3; ++k) {
            TextureDesc ad; ad.type = TextureType::Tex3D; ad.format = Format::RGBA16F; ad.width = 64; ad.height = 64; ad.depthOrLayers = 48;
            ad.usage = TexSampled | TexStorage | TexCrossQueue; ad.label = names[k];
            if (!(aerial[i][k] = dev.createTexture(ad))) { if (err) *err = "aerial LUT"; return false; }
        }
    }
    const char* timerNames[] = {"atmosphere", "shadow0", "shadow1", "shadow2", "shadow3", "hdr", "taa", "bloom", "tonemap"};
    for (int i = 0; i < 9; ++i) dev.setTimerName(i, timerNames[i]);
    return true;
}

bool Renderer::usesAsyncCompute() const {
    return settings.asyncCompute < 0 ? dev.caps().tuning.asyncCompute : settings.asyncCompute > 0;
}

void Renderer::add(Renderable* r) {
    if (std::find(renderables.begin(), renderables.end(), r) == renderables.end()) renderables.push_back(r);
    std::stable_sort(renderables.begin(), renderables.end(), [](Renderable* a, Renderable* b) { return a->renderOrder() < b->renderOrder(); });
}
void Renderer::remove(Renderable* r) { renderables.erase(std::remove(renderables.begin(), renderables.end(), r), renderables.end()); }

bool Renderer::resize(int width, int height) {
    if (width <= 0 || height <= 0) return false;
    if (out && width == w && height == h) return true;
    dev.waitIdle();
    gpu::TextureDesc od; od.format = gpu::Format::RGBA8; od.width = width; od.height = height; od.usage = gpu::TexSampled | gpu::TexRenderTarget; od.label = "viewport output";
    out = dev.createTexture(od);
    for (int i = 0; i < 2; ++i) {
        gpu::TextureDesc hd; hd.format = gpu::Format::RGBA16F; hd.width = width; hd.height = height; hd.usage = gpu::TexSampled | gpu::TexStorage; hd.label = "taaHistory";
        history[i] = dev.createTexture(hd);
    }
    w = width; h = height;
    historyValid = false;
    return out && history[0] && history[1];
}

void Renderer::computeCascades(const Camera& cam, float aspect, const Vec3d& sun, Float4x4 mats[4], Float4& splitsOut) const {
    const double n = double(cam.nearZ), f = double(settings.shadowDistance), lambda = 0.85;
    double splits[4];
    for (int i = 1; i <= 4; ++i) {
        double p = double(i) / 4;
        splits[i - 1] = lambda * n * std::pow(f / n, p) + (1 - lambda) * (n + (f - n) * p);
    }
    const double tanY = std::tan(double(cam.fovY) * 0.5), tanX = tanY * double(aspect);
    const Vec3d fw = cam.forward(), up = cam.up(), rt = cam.right();
    const Vec3d lz = -sun;
    Vec3d lx = cross(Vec3d{0, 1, 0}, lz);
    if (length(lx) < 1e-4) lx = {1, 0, 0};
    lx = normalize(lx);
    const Vec3d ly = cross(lz, lx);
    double prev = n;
    for (int i = 0; i < 4; ++i) {
        const double s = splits[i];
        const double mid = (prev + s) * 0.5;
        const Vec3d center0 = fw * mid;
        double radius = 0;
        for (double d : {prev, s})
            for (double sx : {-1.0, 1.0})
                for (double sy : {-1.0, 1.0}) {
                    Vec3d corner = fw * d + rt * (sx * tanX * d) + up * (sy * tanY * d);
                    radius = std::max(radius, length(corner - center0));
                }
        radius = std::ceil(radius * 16) / 16;
        const double texel = 2 * radius / double(shadowRes);
        const Vec3d cw = center0 + cam.position;
        const double sxw = std::round(dot(cw, lx) / texel) * texel, syw = std::round(dot(cw, ly) / texel) * texel;
        const Vec3d snappedW = lx * sxw + ly * syw + lz * dot(cw, lz);
        const Vec3d center = snappedW - cam.position;
        const double back = radius + 800;
        const Vec3d eye = center - lz * back;
        Float4x4 view = Float4x4::lookAt(Float3(eye), Float3(center), Float3(ly));
        Float4x4 proj = Float4x4::orthographic(float(-radius), float(radius), float(-radius), float(radius), 0, float(back + radius));
        mats[i] = proj * view;
        prev = s;
    }
    splitsOut = {float(splits[0]), float(splits[1]), float(splits[2]), float(splits[3])};
}

void Renderer::render(const Camera& camera, double time) {
    using namespace gpu;
    if (!out) return;
    const int slot = dev.beginFrame();
    fg.reset();

    // ---- uniforms
    const float aspect = float(w) / float(h);
    const bool useTAA = settings.taa;
    float jx = 0, jy = 0;
    if (useTAA) {
        int k = int(frameIdx % 8) + 1;
        jx = (halton(k, 2) - 0.5f) * 2 / float(w);
        jy = (halton(k, 3) - 0.5f) * 2 / float(h);
    }
    const Float4x4 view = camera.viewMatrix();
    Float4x4 proj = Float4x4::perspectiveReverseZInfinite(camera.fovY, aspect, camera.nearZ);
    const Float4x4 projNJ = proj;
    proj.c[2].x += jx; proj.c[2].y += jy;
    const Vec3d sun = sunDirection(environment.timeOfDayHours, environment.sunAzimuthDeg);
    FrameUniforms u;
    u.view = view; u.proj = proj;
    u.viewProj = proj * view;
    u.viewProjNoJitter = projNJ * view;
    u.invViewProj = inverse(u.viewProj);
    const Float3 shift(camera.position - prevCameraPos);
    u.prevViewProj = historyValid ? prevViewProj * Float4x4::translation(shift) : u.viewProjNoJitter;
    Float4x4 cascades[4];
    Float4 splits;
    computeCascades(camera, aspect, sun, cascades, splits);
    if (length(sun - lastSun) > 1e-4 || settings.shadowDistance != lastShadowDistance || !settings.cacheFarCascades) {
        for (bool& v : cascadeValid) v = false;
        lastSun = sun; lastShadowDistance = settings.shadowDistance;
    }
    bool renderCascade[4] = {true, true, true, true};
    for (int c = 2; c < 4; ++c) {
        bool due = int(frameIdx % 2) == (c - 2);
        if (settings.cacheFarCascades && cascadeValid[c] && !due) {
            cascades[c] = cachedCascade[c] * Float4x4::translation(Float3(camera.position - cachedCascadePos[c]));
            renderCascade[c] = false;
        } else {
            cachedCascade[c] = cascades[c]; cachedCascadePos[c] = camera.position; cascadeValid[c] = true;
        }
    }
    for (int c = 0; c < 4; ++c) u.cascadeViewProj[c] = cascades[c];
    u.cascadeSplits = splits;
    u.cameraWorld = {Float3(camera.position), float(std::max(camera.position.y, 1.0))};
    u.sunDir = {Float3(sun), settings.sunIlluminance};
    u.sunColor = {1.0f, 0.98f, 0.95f, 0.0047f};
    u.params = {float(std::fmod(time, 3600.0)), settings.exposure, jx, jy};
    u.resolution = {float(w), float(h), 1.0f / float(w), 1.0f / float(h)};
    u.atmos = {settings.aerialPerspectiveScale * float(environment.fogDensity), settings.shadowDistance, float(frameIdx), settings.bloomStrength};
    u.cameraForward = {Float3(camera.forward()), camera.nearZ};
    u.quality = {settings.fastAtmosphere ? 1.0f : 0.0f, settings.fogPerKm, 1.0f /* sRGB-encode the RGBA8 output */, 0};
    u.fogColor = {settings.fogColor, 0};
    const double wa = environment.windDirectionDeg * kDeg;
    u.wind = {float(std::sin(wa) * environment.windSpeed), 0, float(std::cos(wa) * environment.windSpeed), float(time)};
    Buffer* ubuf = nullptr; std::size_t uoff = 0;
    void* up = dev.allocTransient(sizeof u, &ubuf, &uoff);
    std::memcpy(up, &u, sizeof u);
    prevViewProj = u.viewProjNoJitter; prevCameraPos = camera.position;

    FrameContext ctx;
    ctx.device = &dev; ctx.uniforms = &u; ctx.uniformBuffer = ubuf; ctx.uniformOffset = uoff; ctx.camera = camera; ctx.pipelines = stdPipes;
    ctx.shadowMap = shadowMap.get(); ctx.skyLUT = skyLUT[slot].get();
    for (int k = 0; k < 3; ++k) ctx.aerial[k] = aerial[slot][k].get();
    ctx.frameIndex = frameIdx; ctx.time = time; ctx.width = w; ctx.height = h;
    for (Renderable* r : renderables) r->prepare(ctx);
    debug.take(camera.position, lineScratch);
    Buffer* lineBuf = nullptr; std::size_t lineOff = 0;
    const int lineVerts = int(lineScratch.size() / 2);
    if (lineVerts > 0) ctx.transient(lineScratch.data(), lineScratch.size() * sizeof(Float4), &lineBuf, &lineOff);

    const int timer = settings.passTimings ? 0 : -1000;
    auto T = [&](int t) { return timer < 0 ? -1 : t; };

    // ---- frame graph
    using H = FrameGraph::Handle;
    const H hSky = fg.importTexture("skyLUT", skyLUT[slot].get());
    H hAp[3];
    for (int k = 0; k < 3; ++k) hAp[k] = fg.importTexture("aerial", aerial[slot][k].get());
    const H hShadow = fg.importTexture("shadowMap", shadowMap.get());
    const H hOut = fg.importTexture("output", out.get());
    const H hHistSrc = fg.importTexture("historySrc", history[frameIdx % 2].get());
    const H hHistDst = fg.importTexture("historyDst", history[(frameIdx + 1) % 2].get());
    TextureDesc hd; hd.format = Format::RGBA16F; hd.width = w; hd.height = h; hd.usage = TexSampled | TexRenderTarget;
    const H hHdr = fg.createTexture("hdr", hd);
    TextureDesc dd; dd.format = Format::D32F; dd.width = w; dd.height = h; dd.usage = TexSampled | TexDepthTarget;
    const H hDepth = fg.createTexture("depth", dd);
    const int bw = std::max(1, w / 2), bh = std::max(1, h / 2);
    const int levels = std::max(1, std::min(6, int(std::log2(double(std::min(bw, bh))))));
    TextureDesc bd; bd.format = Format::RGBA16F; bd.width = bw; bd.height = bh; bd.mips = levels; bd.usage = TexSampled | TexStorage;
    const H hBloom = fg.createTexture("bloom", bd);
    const QueueType lutQueue = usesAsyncCompute() ? QueueType::Compute : QueueType::Graphics;

    // 1. atmosphere LUTs
    fg.addPass("atmosphere", lutQueue, [&](FrameGraph::Builder& b) { b.write(hSky); for (H a : hAp) b.write(a); },
        [=, this](FrameGraph::PassContext& p) {
            p.cmd->beginComputePass("atmosphere", T(kTAtmosphere));
            p.cmd->setPipeline(pSkyLUT.get());
            p.cmd->setConstantBuffer(0, ubuf, uoff);
            p.cmd->setStorageTexture(8, p.texture(hSky));
            p.cmd->dispatchThreads(256, 128);
            p.cmd->setPipeline(pAerial.get());
            p.cmd->setConstantBuffer(0, ubuf, uoff);
            for (int k = 0; k < 3; ++k) p.cmd->setStorageTexture(9 + k, p.texture(hAp[k]));
            p.cmd->dispatchThreads(64, 64, 48);
            p.cmd->endComputePass();
        });
    // 2. shadow cascades
    static const char* shadowNames[4] = {"shadow0", "shadow1", "shadow2", "shadow3"};
    for (int c = 0; c < 4; ++c) {
        if (!renderCascade[c]) continue;
        fg.addPass(shadowNames[c], QueueType::Graphics, [&](FrameGraph::Builder& b) { b.read(hShadow); b.write(hShadow); },
            [=, this, &ctx](FrameGraph::PassContext& p) {
                RenderPassDesc rp;
                rp.depth.view = TextureView::slice(p.texture(hShadow), c);
                rp.depth.load = LoadOp::Clear; rp.depth.clear = 1; rp.depth.store = true;
                rp.timer = T(kTShadow0 + c); rp.label = shadowNames[c];
                p.cmd->beginRenderPass(rp);
                PassParams pp{uint32_t(c), 0, 0, 0};
                for (Renderable* r : renderables) {
                    p.cmd->setPipeline(pShadow.get());
                    p.cmd->setConstantBuffer(0, ubuf, uoff);
                    p.cmd->setConstants(1, &pp, sizeof pp);
                    r->drawShadow(*p.cmd, ctx, c);
                }
                p.cmd->endRenderPass();
            });
    }
    // 3. HDR scene
    fg.addPass("hdr", QueueType::Graphics,
        [&](FrameGraph::Builder& b) { b.read(hShadow); b.read(hSky); for (H a : hAp) b.read(a); b.write(hHdr); b.write(hDepth); },
        [=, this, &ctx](FrameGraph::PassContext& p) {
            RenderPassDesc rp;
            rp.colorCount = 1; rp.color[0].view = p.texture(hHdr); rp.color[0].load = LoadOp::DontCare;
            rp.depth.view = p.texture(hDepth); rp.depth.load = LoadOp::Clear; rp.depth.clear = 0; rp.depth.store = true;
            rp.timer = T(kTHdr); rp.label = "hdr";
            p.cmd->beginRenderPass(rp);
            for (Renderable* r : renderables) r->drawOpaque(*p.cmd, ctx);
            // Sky after opaque geometry at the far plane (z = 0) with a read-only greater-equal test: early-z rejects
            // every covered pixel.
            p.cmd->setPipeline(pSky.get());
            ctx.bindFrame(*p.cmd);
            p.cmd->draw(3);
            if (lineVerts > 0 && lineBuf) {
                p.cmd->setPipeline(pLines.get());
                p.cmd->setConstantBuffer(0, ubuf, uoff);
                p.cmd->setBuffer(8, lineBuf, lineOff);
                p.cmd->draw(lineVerts);
            }
            for (Renderable* r : renderables) r->drawTransparent(*p.cmd, ctx);
            p.cmd->endRenderPass();
        });
    // 4. TAA
    H resolved = hHdr;
    if (useTAA) {
        const bool reset = !historyValid;
        fg.addPass("taa", QueueType::Graphics, [&](FrameGraph::Builder& b) { b.read(hHdr); b.read(hDepth); b.read(hHistSrc); b.write(hHistDst); },
            [=, this](FrameGraph::PassContext& p) {
                p.cmd->beginComputePass("taa", T(kTTaa));
                p.cmd->setPipeline(pTaa.get());
                p.cmd->setConstantBuffer(0, ubuf, uoff);
                PostParams pp{reset ? 1u : 0u, 0, 0, 0};
                p.cmd->setConstants(1, &pp, sizeof pp);
                p.cmd->setTexture(0, p.texture(hHdr));
                p.cmd->setTexture(1, p.texture(hHistSrc));
                p.cmd->setTexture(2, p.texture(hDepth));
                p.cmd->setStorageTexture(8, p.texture(hHistDst));
                const int* g = pTaa->groupSize();
                p.cmd->dispatchGroups((w + g[0] - 1) / g[0], (h + g[1] - 1) / g[1]);
                p.cmd->endComputePass();
            });
        resolved = hHistDst;
        historyValid = true;
    } else {
        historyValid = false;
    }
    // 5. bloom
    fg.addPass("bloom", QueueType::Graphics, [&](FrameGraph::Builder& b) { b.read(resolved); b.write(hBloom); },
        [=, this](FrameGraph::PassContext& p) {
            Texture* bl = p.texture(hBloom);
            p.cmd->beginComputePass("bloom", T(kTBloom));
            for (int i = 0; i < levels; ++i) {
                p.cmd->setPipeline(pBloomDown.get());
                PostParams pp{i == 0 ? 1u : 0u, 0, 0, 0};
                p.cmd->setConstants(1, &pp, sizeof pp);
                p.cmd->setTexture(0, i == 0 ? TextureView(p.texture(resolved)) : TextureView::mipLevel(bl, i - 1));
                p.cmd->setStorageTexture(8, TextureView::mipLevel(bl, i));
                p.cmd->dispatchThreads(bl->width(i), bl->height(i));
            }
            for (int i = levels - 2; i >= 0; --i) {
                p.cmd->setPipeline(pBloomUp.get());
                PostParams pp{0, 1.0f, 0, 0};
                p.cmd->setConstants(1, &pp, sizeof pp);
                p.cmd->setTexture(0, TextureView::mipLevel(bl, i + 1));
                p.cmd->setStorageTexture(8, TextureView::mipLevel(bl, i));
                p.cmd->dispatchThreads(bl->width(i), bl->height(i));
            }
            p.cmd->endComputePass();
        });
    // 6. tonemap -> output
    fg.addPass("tonemap", QueueType::Graphics, [&](FrameGraph::Builder& b) { b.read(resolved); b.read(hBloom); b.write(hOut); },
        [=, this](FrameGraph::PassContext& p) {
            RenderPassDesc rp;
            rp.colorCount = 1; rp.color[0].view = p.texture(hOut); rp.color[0].load = LoadOp::DontCare;
            rp.timer = T(kTTonemap); rp.label = "tonemap";
            p.cmd->beginRenderPass(rp);
            p.cmd->setPipeline(pTonemap.get());
            p.cmd->setConstantBuffer(0, ubuf, uoff);
            p.cmd->setTexture(0, p.texture(resolved));
            p.cmd->setTexture(1, TextureView::mipLevel(p.texture(hBloom), 0));
            p.cmd->draw(3);
            p.cmd->endRenderPass();
            p.cmd->finishForSampling(p.texture(hOut));
        });
    fg.markOutput(hOut);
    fg.compile();
    fg.execute();
    dev.endFrame();
    ++frameIdx;
}

} // namespace pw::render
