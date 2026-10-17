// pwenv_render: Renderables for terrain, water and vegetation on the pwrender Renderer (see pw/env/render.h).
#include "pw/env/render.h"
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include "pw/env/codec.h"

namespace pw::envrender {
using namespace pw::gpu;

namespace {
constexpr float kShadowBias = 1.0f, kShadowSlope = 2.0f, kShadowClamp = 0.01f;   // as the renderer's shadow pipeline

GraphicsPipelineDesc hdrPipeline(const char* shader, const char* vs, const char* fs, const char* label) {
    GraphicsPipelineDesc g;
    g.shader = shader; g.vertex = vs; g.fragment = fs;
    g.color[0] = Format::RGBA16F; g.colorCount = 1; g.depth = Format::D32F;
    g.depthCompare = CompareOp::GreaterEqual; g.depthWrite = true; g.cull = CullMode::None; g.label = label;
    return g;
}
GraphicsPipelineDesc shadowPipeline(const char* shader, const char* vs, const char* label) {
    GraphicsPipelineDesc s;
    s.shader = shader; s.vertex = vs; s.fragment = nullptr; s.colorCount = 0; s.depth = Format::D32F;
    s.depthCompare = CompareOp::LessEqual; s.depthWrite = true; s.cull = CullMode::None;
    s.depthBias = kShadowBias; s.depthBiasSlope = kShadowSlope; s.depthBiasClamp = kShadowClamp; s.label = label;
    return s;
}
std::unique_ptr<Texture> tex2D(Device& d, Format f, int w, int h, const char* label, int layers = 1) {
    TextureDesc t;
    t.type = layers > 1 ? TextureType::Tex2DArray : TextureType::Tex2D;
    t.format = f; t.width = w; t.height = h; t.depthOrLayers = layers; t.usage = TexSampled; t.label = label;
    return d.createTexture(t);
}
/// Frustum (world space) from the renderer's camera-relative column-major viewProj.
terrain::Frustum worldFrustum(const Float4x4& vp, const Vec3d& cam) {
    double m[16];
    for (int r = 0; r < 4; ++r) {
        const float col[4] = {r == 0 ? vp.c[0].x : r == 1 ? vp.c[0].y : r == 2 ? vp.c[0].z : vp.c[0].w,
                              r == 0 ? vp.c[1].x : r == 1 ? vp.c[1].y : r == 2 ? vp.c[1].z : vp.c[1].w,
                              r == 0 ? vp.c[2].x : r == 1 ? vp.c[2].y : r == 2 ? vp.c[2].z : vp.c[2].w,
                              r == 0 ? vp.c[3].x : r == 1 ? vp.c[3].y : r == 2 ? vp.c[3].z : vp.c[3].w};
        for (int c = 0; c < 4; ++c) m[r * 4 + c] = col[c];
    }
    terrain::Frustum f = terrain::Frustum::fromViewProj(m);
    for (auto& p : f.planes) p[3] -= p[0] * cam.x + p[1] * cam.y + p[2] * cam.z;   // plane(p - cam) -> plane(p)
    return f;
}
} // namespace

// ---------------------------------------------------------------- upload ring

void UploadRing::beginFrame() { pending[std::size_t(dev.frameSlot())].clear(); }

bool UploadRing::texture(Texture* tex, int layer, const void* rows, std::size_t rowBytes, int rowCount) {
    if (!tex) return false;
    const std::size_t pitch = copyRowPitch(tex->width(), tex->desc().format);
    BufferDesc bd; bd.size = pitch * std::size_t(rowCount); bd.kind = BufferKind::Upload; bd.label = "env upload";
    auto buf = dev.createBuffer(bd);
    if (!buf || !buf->map()) return false;
    auto* dst = static_cast<uint8_t*>(buf->map());
    const auto* src = static_cast<const uint8_t*>(rows);
    for (int y = 0; y < rowCount; ++y) std::memcpy(dst + std::size_t(y) * pitch, src + std::size_t(y) * rowBytes, rowBytes);
    CommandList* cmd = dev.beginCommandList(QueueType::Graphics);
    cmd->copyBufferToTexture(buf.get(), 0, tex->layers() > 1 ? TextureView::slice(tex, layer) : TextureView::mipLevel(tex, 0));
    dev.submit(cmd);
    pending[std::size_t(dev.frameSlot())].push_back(std::move(buf));
    return true;
}

// ---------------------------------------------------------------- terrain

TerrainRenderable::TerrainRenderable(Device& dev, terrain::TerrainSystem& t) : dev_(dev), terrain_(t), ring_(dev) {
    if (!(pipe_ = dev.createPipeline(hdrPipeline("terrain", "terrainVertex", "terrainFragment", "terrain"), &err_))) return;
    if (!(shadow_ = dev.createPipeline(shadowPipeline("terrain", "terrainShadowVertex", "terrain shadow"), &err_))) return;
    ok_ = true;
}

void TerrainRenderable::upload() {
    const world::HeightField& f = terrain_.field();
    if (!heights_ || heights_->width() != f.width || heights_->height() != f.height) {
        heights_ = tex2D(dev_, Format::R32F, f.width, f.height, "terrain heights");
        splat_ = tex2D(dev_, Format::RGBA8, f.width, f.height, "terrain splat");
        moisture_ = tex2D(dev_, Format::R32F, f.width, f.height, "terrain moisture");
    }
    // Whole-texture refresh (pwgpu copies whole subresources); dirty chunks are drained so they do not pile up.
    ring_.texture(heights_.get(), 0, f.heights.data(), std::size_t(f.width) * 4, f.height);
    ring_.texture(splat_.get(), 0, f.splatW.data(), std::size_t(f.width) * 4, f.height);
    ring_.texture(moisture_.get(), 0, f.moisture.data(), std::size_t(f.width) * 4, f.height);
    terrain_.takeDirtyChunks(1 << 30);
    uploadedVersion_ = terrain_.version();
    uploadedField_ = &f;
}

void TerrainRenderable::prepare(render::FrameContext& f) {
    nodeBuf_ = nullptr;
    if (!ok_) return;
    ring_.beginFrame();
    if (terrain_.version() != uploadedVersion_ || &terrain_.field() != uploadedField_) upload();
    if (patchRes_ != lod.patchResolution) {
        patchRes_ = lod.patchResolution;
        std::vector<uint32_t> idx;
        uint32_t row = uint32_t(patchRes_ + 1);
        for (uint32_t z = 0; z < uint32_t(patchRes_); ++z)
            for (uint32_t x = 0; x < uint32_t(patchRes_); ++x) {
                uint32_t a = z * row + x;
                idx.insert(idx.end(), {a, a + row, a + 1, a + 1, a + row, a + row + 1});
            }
        patchIndices_ = dev_.createBufferWithData(idx.data(), idx.size() * 4, true, "terrain patch");
        patchIndexCount_ = int(idx.size());
    }
    const Vec3d cam = f.camera.position;
    terrain::Frustum fr = worldFrustum(f.uniforms->viewProjNoJitter, cam);
    stats_ = terrain::selectLOD(terrain_, lod, cam, &fr, nodes_);
    packed_.resize(nodes_.size() * 8);
    for (std::size_t i = 0; i < nodes_.size(); ++i) {
        const auto& n = nodes_[i];
        float* p = &packed_[i * 8];
        p[0] = float(double(n.minX) - cam.x); p[1] = float(double(n.minZ) - cam.z); p[2] = n.size; p[3] = float(n.level);
        p[4] = n.morphStart; p[5] = n.morphEnd; p[6] = n.minY; p[7] = n.maxY;
    }
    if (!nodes_.empty()) f.transient(packed_.data(), packed_.size() * 4, &nodeBuf_, &nodeOff_);
    const world::HeightField& hf = terrain_.field();
    float d[16] = {float(hf.origin.x - cam.x), float(hf.origin.y - cam.z), float(hf.spacing), float(1 / hf.spacing),
                   float(hf.width), float(hf.height), float(hf.baseLevel), float(hf.falloff),
                   float(patchRes_), 1.0f / float(patchRes_), float(cam.y), 0,
                   tint[0], tint[1], tint[2], tint[3]};
    std::memcpy(draw_, d, sizeof d);
}

void TerrainRenderable::drawOpaque(CommandList& cmd, render::FrameContext& f) {
    if (!ok_ || !nodeBuf_) return;
    cmd.setPipeline(pipe_.get());
    f.bindFrame(cmd);
    cmd.setConstants(2, draw_, sizeof draw_);
    cmd.setTexture(5, heights_.get()); cmd.setTexture(6, splat_.get()); cmd.setTexture(7, moisture_.get());
    cmd.setBuffer(8, nodeBuf_, nodeOff_);
    cmd.drawIndexed(patchIndices_.get(), patchIndexCount_, int(nodes_.size()));
}

void TerrainRenderable::drawShadow(CommandList& cmd, render::FrameContext& f, int) {
    if (!ok_ || !nodeBuf_ || !castsShadows) return;
    cmd.setPipeline(shadow_.get());
    cmd.setConstants(2, draw_, sizeof draw_);
    cmd.setTexture(5, heights_.get());
    cmd.setBuffer(8, nodeBuf_, nodeOff_);
    cmd.drawIndexed(patchIndices_.get(), patchIndexCount_, int(nodes_.size()));
    cmd.setPipeline(f.pipelines.shadow);   // restore the standard shadow pipeline for the next renderable
}

// ---------------------------------------------------------------- water

WaterRenderable::Mesh WaterRenderable::makeMesh(const water::WaterMesh& m, const char* label) {
    Mesh out;
    if (m.vertices.empty() || m.indices.empty()) return out;
    std::vector<float> v(m.vertices.size() * 8, 0.0f);
    for (std::size_t i = 0; i < m.vertices.size(); ++i) {
        const auto& s = m.vertices[i];
        float* p = &v[i * 8];
        p[0] = s.px; p[1] = s.py; p[2] = s.pz; p[3] = s.edge; p[4] = s.fx; p[5] = s.fz;
    }
    out.vb = dev_.createBufferWithData(v.data(), v.size() * 4, false, label);
    out.ib = dev_.createBufferWithData(m.indices.data(), m.indices.size() * 4, true, label);
    out.count = int(m.indices.size());
    return out;
}

WaterRenderable::WaterRenderable(Device& dev, water::WaterSystem& w) : dev_(dev), water_(w), ring_(dev) {
    auto g = hdrPipeline("water", "waterVertex", "waterFragment", "water");
    g.depthWrite = false; g.blend = BlendMode::Alpha;
    if (!(pipe_ = dev.createPipeline(g, &err_))) return;
    auto sp = hdrPipeline("water", "splashVertex", "splashFragment", "splash");
    sp.depthWrite = false; sp.blend = BlendMode::Alpha;
    if (!(splash_ = dev.createPipeline(sp, &err_))) return;
    auto fl = hdrPipeline("fluidsurface", "fluidBoxVertex", "fluidBoxFragment", "fluid zone");
    fl.blend = BlendMode::Alpha; fl.cull = CullMode::Front;   // back faces: the march starts at the camera or the box entry
    if (!(fluid_ = dev.createPipeline(fl, &err_))) return;
    ocean_ = makeMesh(water::oceanGridMesh(), "ocean grid");
    ok_ = ocean_.count > 0;
    if (!ok_) err_ = "ocean grid upload failed";
}

void WaterRenderable::prepare(render::FrameContext& f) {
    if (!ok_) return;
    ring_.beginFrame();
    water::OceanSimulation* o = water_.ocean();
    if (o) {
        water::OceanView v;
        if (!o->views(v)) { o->update(f.time); o->views(v); }
        const int N = v.N, C = v.cascades;
        if (!disp_ || disp_->width() != N || disp_->layers() != C) {
            disp_ = tex2D(dev_, Format::RGBA16F, N, N, "ocean displacement", std::max(C, 2));
            deriv_ = tex2D(dev_, Format::RGBA16F, N, N, "ocean derivatives", std::max(C, 2));
            uploadedTime_ = -1;
        }
        if (v.valid() && v.time != uploadedTime_) {
            const std::size_t nn = std::size_t(N) * std::size_t(N);
            const auto& foam = o->foam();
            halfScratch_.resize(nn * 4);
            for (int c = 0; c < C; ++c) {
                const float* d = v.disp + std::size_t(c) * nn * 4;
                for (std::size_t i = 0; i < nn; ++i) {
                    halfScratch_[i * 4] = env::floatToHalf(d[i * 4]); halfScratch_[i * 4 + 1] = env::floatToHalf(d[i * 4 + 1]);
                    halfScratch_[i * 4 + 2] = env::floatToHalf(d[i * 4 + 2]);
                    halfScratch_[i * 4 + 3] = env::floatToHalf(foam.size() == nn * std::size_t(C) ? foam[std::size_t(c) * nn + i] : 0.0f);
                }
                ring_.texture(disp_.get(), c, halfScratch_.data(), std::size_t(N) * 8, N);
                const float* g = v.deriv + std::size_t(c) * nn * 4;
                for (std::size_t i = 0; i < nn * 4; ++i) halfScratch_[i] = env::floatToHalf(g[i]);
                ring_.texture(deriv_.get(), c, halfScratch_.data(), std::size_t(N) * 8, N);
            }
            uploadedTime_ = v.time;
        }
    }
    double minX = 0, minZ = 0;
    const int res = 512;
    if (!ground_) {
        ground_ = tex2D(dev_, Format::R32F, res, res, "water ground");
        groundData_.assign(std::size_t(res) * res, -1e4f);
        ring_.texture(ground_.get(), 0, groundData_.data(), std::size_t(res) * 4, res);
        water_.markDepthDirty();   // a new texture needs the heights even if the camera has not moved
    }
    if (water_.updateDepthTexture(f.camera.position, groundData_, minX, minZ, res, 2048))
        ring_.texture(ground_.get(), 0, groundData_.data(), std::size_t(res) * 4, res);
    // splash spray (CPU particles, integrated by WaterSystem::frame)
    water_.splashes().instances(f.camera.position, splashScratch_);
    splashCount_ = int(splashScratch_.size() / 8);
    splashBuf_ = nullptr;
    if (splashCount_ > 0) f.transient(splashScratch_.data(), splashScratch_.size() * 4, &splashBuf_, &splashOff_);
    // FLIP zones: particle density -> 3D texture every frame
    std::vector<Zone> keep;
    for (const auto& zp : water_.fluidZones()) {
        water::FluidZone* z = zp.get();
        Zone zr;
        for (auto& old : zones_) if (old.zone == z) { zr.zone = z; zr.density = std::move(old.density); }
        zr.zone = z;
        if (!zr.density) {
            TextureDesc td; td.type = TextureType::Tex3D; td.format = Format::R32F; td.width = z->nx; td.height = z->ny; td.depthOrLayers = z->nz;
            td.usage = TexSampled; td.label = "fluid density";
            zr.density = dev_.createTexture(td);
        }
        if (zr.density && z->densityField(densityScratch_))
            ring_.texture(zr.density.get(), 0, densityScratch_.data(), std::size_t(z->nx) * 4, z->ny * z->nz);
        keep.push_back(std::move(zr));
    }
    zones_ = std::move(keep);
    if (lakes_.size() != water_.lakes().size()) {
        lakes_.clear();
        for (auto& l : water_.lakes()) lakes_.push_back(makeMesh(water::lakeMesh(l.radius), "lake"));
    }
    if (rivers_.size() != water_.rivers().size()) {
        rivers_.clear();
        for (auto& r : water_.rivers()) rivers_.push_back(makeMesh(water::riverMesh(r), "river"));
    }
}

void WaterRenderable::drawTransparent(CommandList& cmd, render::FrameContext& f) {
    if (!ok_ || !disp_) return;
    cmd.setPipeline(pipe_.get());
    f.bindFrame(cmd);
    cmd.setTexture(5, disp_.get()); cmd.setTexture(6, deriv_.get()); cmd.setTexture(7, ground_.get());
    const Vec3d cam = f.camera.position;
    auto draw = [&](const Mesh& m, const Vec3d& origin, float amp) {
        if (!m.count) return;
        water::WaterDrawGPU p = water_.drawParams(cam, origin, amp, f.time);
        cmd.setConstants(2, &p, sizeof p);
        cmd.setBuffer(8, m.vb.get());
        cmd.drawIndexed(m.ib.get(), m.count);
    };
    if (water_.oceanEnabled) draw(ocean_, {cam.x, water_.seaLevel, cam.z}, 1.0f);
    for (std::size_t i = 0; i < lakes_.size() && i < water_.lakes().size(); ++i) {
        const auto& l = water_.lakes()[i];
        draw(lakes_[i], {l.center.x, l.level, l.center.y}, float(l.waveScale));
    }
    for (std::size_t i = 0; i < rivers_.size() && i < water_.rivers().size(); ++i)
        if (!water_.rivers()[i].samples.empty()) draw(rivers_[i], water_.rivers()[i].samples[0], 0.08f);
    if (!zones_.empty()) {
        cmd.setPipeline(fluid_.get());
        f.bindFrame(cmd);
        for (auto& z : zones_) {
            if (!z.density) continue;
            Vec3d o = z.zone->origin - cam, sz = z.zone->size();
            float d[16] = {float(o.x), float(o.y), float(o.z), 0, float(sz.x), float(sz.y), float(sz.z), 0,
                           water_.absorption[0], water_.absorption[1], water_.absorption[2], water_.scattering,
                           float(z.zone->cellSize), 0.5f, 0, 0};
            cmd.setConstants(2, d, sizeof d);
            cmd.setTexture(5, z.density.get());
            cmd.draw(36);
        }
    }
    if (splashBuf_ && splashCount_ > 0) {
        cmd.setPipeline(splash_.get());
        f.bindFrame(cmd);
        cmd.setBuffer(9, splashBuf_, splashOff_);
        cmd.draw(6, splashCount_);
    }
}

// ---------------------------------------------------------------- vegetation

VegetationRenderable::VegetationRenderable(Device& dev, veg::ProceduralVegetation& v) : dev_(dev), veg_(v), ring_(dev) {
    auto t = hdrPipeline("vegetation", "treeVertex", "treeFragment", "trees");
    if (!(tree_ = dev.createPipeline(t, &err_))) return;
    if (!(treeShadow_ = dev.createPipeline(shadowPipeline("vegetation", "treeShadowVertex", "tree shadow"), &err_))) return;
    auto imp = hdrPipeline("vegetation", "impostorVertex", "impostorFragment", "impostors");
    if (!(impostor_ = dev.createPipeline(imp, &err_))) return;
    GraphicsPipelineDesc b;
    b.shader = "vegetation"; b.vertex = "impostorBakeVertex"; b.fragment = "impostorBakeFragment";
    b.color[0] = Format::RGBA8; b.color[1] = Format::RGBA8; b.colorCount = 2; b.depth = Format::D32F;
    b.depthCompare = CompareOp::LessEqual; b.depthWrite = true; b.cull = CullMode::None; b.label = "impostor bake";
    if (!(bake_ = dev.createPipeline(b, &err_))) return;
    if (!(grass_ = dev.createPipeline(hdrPipeline("grass", "grassVertex", "grassFragment", "grass"), &err_))) return;
    ok_ = true;
}

void VegetationRenderable::rebuildTemplates() {
    templates_.clear();
    baked_ = false;
    for (const auto& tp : veg_.templates()) {
        Template t;
        for (int l = 0; l < 3 && l < int(tp.lods.size()); ++l) {
            const auto& m = tp.lods[std::size_t(l)];
            if (m.vertices.empty() || m.indices.empty()) continue;
            t.lod[l].vb = dev_.createBufferWithData(m.vertices.data(), m.vertices.size() * sizeof(veg::MeshVertex), false, "tree");
            t.lod[l].ib = dev_.createBufferWithData(m.indices.data(), m.indices.size() * 4, true, "tree");
            t.lod[l].count = int(m.indices.size());
        }
        const auto& p = tp.params;
        auto lin = [](float c) { return c; };   // species colours are linear already
        float d[16] = {lin(p.barkColor.x), lin(p.barkColor.y), lin(p.barkColor.z), p.barkRoughness,
                       lin(p.leafColor.x), lin(p.leafColor.y), lin(p.leafColor.z), p.leafKind,
                       tp.height, tp.crownRadius, 1.0f, 0,
                       float(settings.impostorFrames), 1.0f / float(settings.impostorFrames), tp.boundsRadius, tp.height * 0.5f};
        std::memcpy(t.draw, d, sizeof d);
        for (int k = 16; k < 32; ++k) t.draw[k] = (k - 16) % 5 == 0 ? 1.0f : 0.0f;   // identity bake matrix
        templates_.push_back(std::move(t));
    }
    templatesVersion_ = veg_.templatesVersion;
    stats_.templates = int(templates_.size());
}

void VegetationRenderable::bakeImpostors() {
    const int frames = settings.impostorFrames, cell = settings.impostorCell, size = frames * cell;
    TextureDesc dd; dd.format = Format::D32F; dd.width = dd.height = size; dd.usage = TexDepthTarget; dd.label = "impostor depth";
    auto depth = dev_.createTexture(dd);
    if (!depth) return;
    for (std::size_t ti = 0; ti < templates_.size(); ++ti) {
        Template& t = templates_[ti];
        const veg::TreeTemplate& tp = veg_.templates()[ti];
        TextureDesc td; td.format = Format::RGBA8; td.width = td.height = size; td.usage = TexSampled | TexRenderTarget;
        td.label = "impostor albedo";
        t.atlasAlbedo = dev_.createTexture(td);
        td.label = "impostor normal";
        t.atlasNormal = dev_.createTexture(td);
        if (!t.atlasAlbedo || !t.atlasNormal || !t.lod[0].count) continue;
        CommandList* cmd = dev_.beginCommandList(QueueType::Graphics);
        RenderPassDesc rp;
        rp.color[0].view = t.atlasAlbedo.get(); rp.color[0].load = LoadOp::Clear;
        for (float& c : rp.color[0].clear) c = 0;
        rp.color[1].view = t.atlasNormal.get(); rp.color[1].load = LoadOp::Clear;
        rp.color[1].clear[0] = 0.5f; rp.color[1].clear[1] = 1; rp.color[1].clear[2] = 0.5f; rp.color[1].clear[3] = 0;
        rp.colorCount = 2;
        rp.depth.view = depth.get(); rp.depth.load = LoadOp::Clear; rp.depth.clear = 1; rp.depth.store = false;
        rp.label = "impostor bake";
        cmd->beginRenderPass(rp);
        cmd->setPipeline(bake_.get());
        cmd->setBuffer(8, t.lod[0].vb.get());
        float draw[32];
        std::memcpy(draw, t.draw, sizeof draw);
        for (int iy = 0; iy < frames; ++iy)
            for (int ix = 0; ix < frames; ++ix) {
                double m[16];
                veg::impostor::bakeViewProj(tp, ix, iy, frames, m);
                for (int c = 0; c < 4; ++c)
                    for (int r = 0; r < 4; ++r) draw[16 + c * 4 + r] = float(m[r * 4 + c]);   // row-major -> columns
                cmd->setViewport(ix * cell, iy * cell, cell, cell);
                cmd->setConstants(2, draw, sizeof draw);
                cmd->drawIndexed(t.lod[0].ib.get(), t.lod[0].count);
            }
        cmd->endRenderPass();
        dev_.submit(cmd);
    }
    dev_.waitIdle();
    baked_ = true;
    stats_.impostorsBaked = true;
}

void VegetationRenderable::updateGrass(const render::FrameContext& f) {
    const int res = settings.grassResolution;
    const Vec3d cam = f.camera.position;
    double texel = 2 * veg_.grassRadius / double(res);
    if (grassDensity_ && veg_.grassVersion == grassVersion_ && std::hypot(cam.x - grassCenter_.x, cam.z - grassCenter_.z) < texel * 12) return;
    std::vector<uint8_t> dens;
    veg_.grassDensityMap(cam, res, dens, grassMinX_, grassMinZ_, grassTexel_);
    std::vector<float> d(dens.size()), g(dens.size(), 0.0f);
    for (std::size_t i = 0; i < dens.size(); ++i) d[i] = float(dens[i]) / 255;
    if (veg_.terrain)
        for (int y = 0; y < res; ++y)
            for (int x = 0; x < res; ++x)
                g[std::size_t(y) * std::size_t(res) + std::size_t(x)] = float(veg_.terrain->height(grassMinX_ + (x + 0.5) * grassTexel_, grassMinZ_ + (y + 0.5) * grassTexel_));
    if (!grassDensity_ || grassDensity_->width() != res) {
        grassDensity_ = tex2D(dev_, Format::R32F, res, res, "grass density");
        grassGround_ = tex2D(dev_, Format::R32F, res, res, "grass ground");
    }
    ring_.texture(grassDensity_.get(), 0, d.data(), std::size_t(res) * 4, res);
    ring_.texture(grassGround_.get(), 0, g.data(), std::size_t(res) * 4, res);
    if (!grassPush_ || grassPush_->width() != res) {
        TextureDesc pd; pd.format = Format::RGBA16F; pd.width = pd.height = res; pd.usage = TexSampled; pd.label = "grass interaction";
        grassPush_ = dev_.createTexture(pd);
    }
    push_.assign(std::size_t(res) * std::size_t(res) * 4, 0.0f);   // the map moved: start from upright grass
    pushActive_ = true;
    grassCenter_ = cam;
    grassVersion_ = veg_.grassVersion;
}

void VegetationRenderable::prepare(render::FrameContext& f) {
    if (!ok_) return;
    ring_.beginFrame();
    if (veg_.templatesVersion != templatesVersion_) rebuildTemplates();
    if (!baked_ && !templates_.empty()) bakeImpostors();
    stats_.lod0 = stats_.lod1 = stats_.impostors = stats_.shadow = 0;
    for (auto& v : inst_) { v.resize(templates_.size()); for (auto& x : v) x.clear(); }
    const Vec3d cam = f.camera.position;
    const double d0 = settings.lod0Distance * settings.lod0Distance, d1 = settings.lod1Distance * settings.lod1Distance;
    const double dm = settings.maxDistance * settings.maxDistance, ds = settings.shadowDistance * settings.shadowDistance;
    auto push = [&](int bucket, int templ, const Vec3d& p, float yaw, float scale, float tint, float fall, const Quatd& q) {
        auto& v = inst_[bucket][std::size_t(templ)];
        const float e[12] = {float(p.x - cam.x), float(p.y - cam.y), float(p.z - cam.z), yaw, scale, tint, fall, 0,
                             float(q.x), float(q.y), float(q.z), float(q.w)};
        v.insert(v.end(), e, e + 12);
    };
    const auto& trees = veg_.trees();
    for (const auto& t : trees) {
        if (t.broken || t.templ < 0 || t.templ >= int(templates_.size())) continue;
        double dx = t.position.x - cam.x, dy = t.position.y - cam.y, dz = t.position.z - cam.z, d2 = dx * dx + dy * dy + dz * dz;
        if (d2 > dm) continue;
        Quatd q = Quatd::angleAxis(double(t.yaw), {0, 1, 0});
        int bucket = d2 < d0 ? 0 : (d2 < d1 ? 1 : 2);
        if (bucket == 2 && !baked_) bucket = 1;
        push(bucket, t.templ, t.position, t.yaw, t.scale, t.tint, 0, q);
        if (d2 < ds) push(3, t.templ, t.position, t.yaw, t.scale, t.tint, 0, q);
    }
    for (const auto& fl : veg_.snapshotFalling()) {
        const auto& t = trees[std::size_t(fl.treeID)];
        push(0, t.templ, fl.transform.position, t.yaw, t.scale, t.tint, 1, fl.transform.rotation);
        push(3, t.templ, fl.transform.position, t.yaw, t.scale, t.tint, 1, fl.transform.rotation);
    }
    for (std::size_t ti = 0; ti < templates_.size(); ++ti) {
        Template& tp = templates_[ti];
        tp.draw[11] = float(std::fmod(f.time, 3600.0));
        for (int b = 0; b < 4; ++b) {
            auto& v = inst_[b][ti];
            tp.b[b] = {};
            if (v.empty()) continue;
            tp.b[b].count = int(v.size() / 12);
            f.transient(v.data(), v.size() * 4, &tp.b[b].buf, &tp.b[b].off);
            (b == 0 ? stats_.lod0 : b == 1 ? stats_.lod1 : b == 2 ? stats_.impostors : stats_.shadow) += tp.b[b].count;
        }
    }
    if (settings.grass && veg_.enabled && veg_.grassDensity > 0 && veg_.terrain) { updateGrass(f); updateInteractions(f); }
}

void VegetationRenderable::updateInteractions(const render::FrameContext& f) {
    if (!grassPush_) return;
    const int res = settings.grassResolution;
    double dt = lastTime_ < 0 ? 0 : std::min(std::max(f.time - lastTime_, 0.0), 0.25);
    lastTime_ = f.time;
    auto hits = veg_.takeInteractors();
    if (!pushActive_ && hits.empty()) return;
    // grass springs back over ~2 s
    float decay = float(std::exp(-dt / 2.0));
    bool any = false;
    for (float& v : push_) { v *= decay; if (std::fabs(v) > 1e-3f) any = true; else v = 0; }
    for (const auto& h : hits) {
        int x0 = int(std::floor((h.position.x - h.radius - grassMinX_) / grassTexel_)), x1 = int(std::ceil((h.position.x + h.radius - grassMinX_) / grassTexel_));
        int z0 = int(std::floor((h.position.z - h.radius - grassMinZ_) / grassTexel_)), z1 = int(std::ceil((h.position.z + h.radius - grassMinZ_) / grassTexel_));
        for (int z = std::max(z0, 0); z <= std::min(z1, res - 1); ++z)
            for (int x = std::max(x0, 0); x <= std::min(x1, res - 1); ++x) {
                double wx = grassMinX_ + (x + 0.5) * grassTexel_ - h.position.x, wz = grassMinZ_ + (z + 0.5) * grassTexel_ - h.position.z;
                double d = std::hypot(wx, wz);
                if (d >= h.radius) continue;
                double k = h.strength * (1 - d / h.radius);
                double dx = h.direction.x, dz = h.direction.y;
                if (dx == 0 && dz == 0 && d > 1e-6) { dx = wx / d; dz = wz / d; }   // radial push
                float* p = &push_[(std::size_t(z) * std::size_t(res) + std::size_t(x)) * 4];
                p[0] = float(std::max(-1.0, std::min(1.0, p[0] + dx * k * 0.8)));
                p[1] = float(std::max(-1.0, std::min(1.0, p[1] + dz * k * 0.8)));
                p[2] = float(std::max(double(p[2]), k));
                any = true;
            }
    }
    pushHalf_.resize(push_.size());
    for (std::size_t i = 0; i < push_.size(); ++i) pushHalf_[i] = env::floatToHalf(push_[i]);
    ring_.texture(grassPush_.get(), 0, pushHalf_.data(), std::size_t(res) * 8, res);
    pushActive_ = any;
}

static bool vegDebug(const char* what) { const char* e = std::getenv("PW_VEG_DEBUG"); return e && std::strstr(e, what); }

void VegetationRenderable::drawShadow(CommandList& cmd, render::FrameContext& f, int) {
    if (!ok_ || vegDebug("noshadow")) return;
    bool any = false;
    for (auto& t : templates_) {
        if (!t.b[3].count || !t.lod[2].count) continue;
        if (!any) { cmd.setPipeline(treeShadow_.get()); any = true; }
        cmd.setConstants(2, t.draw, sizeof t.draw);
        cmd.setBuffer(8, t.lod[2].vb.get());
        cmd.setBuffer(9, t.b[3].buf, t.b[3].off);
        cmd.drawIndexed(t.lod[2].ib.get(), t.lod[2].count, t.b[3].count);
    }
    if (any) cmd.setPipeline(f.pipelines.shadow);
}

void VegetationRenderable::drawOpaque(CommandList& cmd, render::FrameContext& f) {
    if (!ok_) return;
    cmd.setPipeline(tree_.get());
    f.bindFrame(cmd);
    for (auto& t : templates_)
        for (int b = 0; b < 2; ++b) {
            if (!t.b[b].count || !t.lod[b].count || vegDebug(b == 0 ? "nolod0" : "nolod1")) continue;
            cmd.setConstants(2, t.draw, sizeof t.draw);
            cmd.setBuffer(8, t.lod[b].vb.get());
            cmd.setBuffer(9, t.b[b].buf, t.b[b].off);
            cmd.drawIndexed(t.lod[b].ib.get(), t.lod[b].count, t.b[b].count);
        }
    bool imp = false;
    for (auto& t : templates_) {
        if (!t.b[2].count || !t.atlasAlbedo || vegDebug("noimp")) continue;
        if (!imp) { cmd.setPipeline(impostor_.get()); f.bindFrame(cmd); imp = true; }
        cmd.setConstants(2, t.draw, sizeof t.draw);
        cmd.setTexture(5, t.atlasAlbedo.get()); cmd.setTexture(6, t.atlasNormal.get());
        cmd.setBuffer(9, t.b[2].buf, t.b[2].off);
        cmd.draw(6, t.b[2].count);
    }
    stats_.grassBlades = 0;
    if (grassDensity_ && settings.grass && veg_.enabled && !vegDebug("nograss")) {
        const Vec3d cam = f.camera.position;
        const int res = settings.grassResolution;
        float g[16] = {float(grassMinX_ - cam.x), float(grassMinZ_ - cam.z), float(grassTexel_), float(settings.bladesPerTexel),
                       float(veg_.grassHeight), 0.06f, float(res), float(veg_.grassRadius),
                       0.16f, 0.24f, 0.07f, 0.35f,
                       float(-cam.y), 0, 0, 0};
        cmd.setPipeline(grass_.get());
        f.bindFrame(cmd);
        cmd.setConstants(2, g, sizeof g);
        cmd.setTexture(5, grassDensity_.get()); cmd.setTexture(6, grassGround_.get()); cmd.setTexture(7, grassPush_.get());
        stats_.grassBlades = res * res * settings.bladesPerTexel;
        cmd.draw(stats_.grassBlades * 9);
    }
}

} // namespace pw::envrender
