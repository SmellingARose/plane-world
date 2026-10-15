// Metal side of Germ War, plugged into the Plane World renderer as a Renderable.
// Every creature/building is a list of primitive parts; all parts of all entities are written
// straight into GPU instance buffers by JobSystem.parallelFor, one instanced draw per primitive.
import Metal
import simd
import Foundation
import PWCore
import PWRender

/// Per-instance data for the glow/alpha effects pipeline (must match FXInstance in MSL).
struct FXInstance { var model: Mat4; var color: Vec4; var params: Vec4 }

/// UI state the renderer draws (selection rings, placement ghost, radar coverage).
struct Overlay {
    var selected: [Ref] = []
    var attackSel: [Ref] = []
    var showAttackerInfo = false
    var ghostType: Int = -1, ghostPos: Vec3 = .zero, ghostOK = false
    var buildRingCenter: Vec3? = nil, buildR: Float = 420
}

final class GermRenderable: Renderable {
    var renderOrder: Int { 10 }
    let sim: Sim
    var overlay = Overlay()
    var camYaw: Float = 0

    private var prims: [GPUMesh] = []
    private var terrain: GPUMesh?
    private var terrainPipe: (any MTLRenderPipelineState)?
    private var fxAdd: (any MTLRenderPipelineState)?
    private var fxAlpha: (any MTLRenderPipelineState)?
    private var pipeSamples = -1

    // instance storage: [slot][prim]
    private var instBufs: [[(any MTLBuffer)?]] = Array(repeating: Array(repeating: nil, count: Part.Prim.allCases.count), count: 3)
    private var instCount = [Int](repeating: 0, count: Part.Prim.allCases.count)
    private var curSlot = 0
    private var addFX: [(Int, [FXInstance])] = []
    private var alphaFX: [(Int, [FXInstance])] = []

    // flattened model table, rebuilt when defs change
    private var parts: [Part] = []
    private var typeStart: [Int32] = [], typeLen: [Int32] = []
    private var countFull: [SIMD8<Int32>] = [], countLod: [SIMD8<Int32>] = []
    private var modelScale: [Float] = [], isCocoon: [Bool] = []
    private var defsVersion = -1
    private var offsets = UnsafeMutablePointer<SIMD8<Int32>>.allocate(capacity: 1), offCap = 0
    private var lodFlag = UnsafeMutablePointer<Bool>.allocate(capacity: 1)

    private let decor: [Terrain.Decor] = Terrain.decorations()
    private let cells = Terrain.giantCells()

    init(sim: Sim, device: any MTLDevice) {
        self.sim = sim
        let meshes: [CPUMesh] = [
            MeshBuilder.sphere(radius: 1, segments: 16, rings: 10),
            MeshBuilder.box(),
            MeshBuilder.cylinder(radiusTop: 1, radiusBottom: 1, height: 1, segments: 12),
            MeshBuilder.cylinder(radiusTop: 0.001, radiusBottom: 1, height: 1, segments: 10),
            Shapes.icosahedron(),
            Shapes.torus(major: 1, minor: 0.12, segments: 40, sides: 8),
            MeshBuilder.sphere(radius: 1, segments: 28, rings: 18),
        ]
        prims = meshes.enumerated().map { GPUMesh(device: device, mesh: $1, label: "gw.prim\($0)")! }
        terrain = GPUMesh(device: device, mesh: Terrain.mesh(), label: "gw.terrain")
    }

    // MARK: pipelines

    private func ensurePipelines(_ f: FrameContext) {
        guard pipeSamples != f.sampleCount else { return }
        pipeSamples = f.sampleCount
        do {
            let lib = try ShaderLibrary.shared.library(named: "germwar", source: GermShaders.source, device: f.device)
            func make(_ v: String, _ fr: String, blend: Int) throws -> any MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = try ShaderLibrary.shared.function(lib, v); d.fragmentFunction = try ShaderLibrary.shared.function(lib, fr)
                d.colorAttachments[0].pixelFormat = f.pipelines.hdrFormat
                d.depthAttachmentPixelFormat = f.pipelines.depthFormat
                d.rasterSampleCount = f.sampleCount
                if blend > 0 {
                    let c = d.colorAttachments[0]!
                    c.isBlendingEnabled = true
                    c.sourceRGBBlendFactor = .sourceAlpha
                    c.destinationRGBBlendFactor = blend == 1 ? .one : .oneMinusSourceAlpha
                    c.sourceAlphaBlendFactor = .zero; c.destinationAlphaBlendFactor = .one
                }
                return try f.device.makeRenderPipelineState(descriptor: d)
            }
            terrainPipe = try make("gwTerrainVertex", "gwTerrainFragment", blend: 0)
            fxAdd = try make("gwFXVertex", "gwFXFragment", blend: 1)
            fxAlpha = try make("gwFXVertex", "gwFXFragment", blend: 2)
        } catch { print("[GermWar] pipeline error: \(error)") }
    }

    private func rebuildModels() {
        guard defsVersion != sim.defs.version else { return }
        defsVersion = sim.defs.version
        parts.removeAll(); typeStart.removeAll(); typeLen.removeAll(); countFull.removeAll(); countLod.removeAll(); modelScale.removeAll(); isCocoon.removeAll()
        for d in sim.defs.defs {
            typeStart.append(Int32(parts.count)); typeLen.append(Int32(d.model.count))
            var cf = SIMD8<Int32>(repeating: 0), cl = SIMD8<Int32>(repeating: 0)
            for p in d.model { cf[p.prim.rawValue] += 1; if p.lod { cl[p.prim.rawValue] += 1 } }
            countFull.append(cf); countLod.append(cl)
            parts += d.model; modelScale.append(d.modelScale); isCocoon.append(d.brain == .cocoon)
        }
    }

    private func buffer(_ slot: Int, _ p: Int, _ count: Int, _ device: any MTLDevice) -> any MTLBuffer {
        let need = max(1, count) * MemoryLayout<MeshInstance>.stride
        if let b = instBufs[slot][p], b.length >= need { return b }
        let b = device.makeBuffer(length: max(need * 2, 64 << 10), options: .storageModeShared)!
        b.label = "gw.inst\(p)"; instBufs[slot][p] = b
        return b
    }

    // MARK: prepare (CPU, parallel)

    func prepare(_ frame: FrameContext) {
        ensurePipelines(frame)
        rebuildModels()
        let cam = frame.camera.position.float
        let slot = frame.frameIndex % 3; curSlot = slot
        let ents = sim.ents, n = ents.count
        let P = Part.Prim.allCases.count
        if offCap < n { offsets.deallocate(); lodFlag.deallocate(); offCap = max(n, offCap * 2, 1024)
            offsets = .allocate(capacity: offCap); lodFlag = .allocate(capacity: offCap) }

        // offsets: entity parts first (prefix sum), extras after
        var running = SIMD8<Int32>(repeating: 0)
        for i in 0..<n {
            let e = ents[i]
            guard e.alive, Int(e.type) < countFull.count else { continue }
            let far = simd_distance_squared(e.pos, cam) > 700 * 700
            lodFlag[i] = far; offsets[i] = running
            running &+= far ? countLod[Int(e.type)] : countFull[Int(e.type)]
        }
        // extras: decor, projectiles, health bars
        var extras = Array(repeating: [MeshInstance](), count: P)
        for d in decor { extras[d.prim.rawValue].append(MeshInstance(model: modelMatrix(d.pos - cam, yaw: 0, at: .zero, rot: d.rot, size: d.scale),
                                                                     albedo: d.color, roughness: d.rough, metallic: d.metal, emissive: d.emissive)) }
        for p in sim.projs where !p.dead {
            extras[Part.Prim.sphere.rawValue].append(MeshInstance(model: modelMatrix(p.pos - cam, yaw: 0, at: .zero, rot: .zero, size: Vec3(repeating: p.size)),
                                                                  albedo: p.color, roughness: 0.4, emissive: 4))
        }
        // plaza
        extras[Part.Prim.cyl.rawValue].append(MeshInstance(model: modelMatrix(Vec3(0, -1, 0) - cam, yaw: 0.5236, at: .zero, rot: .zero, size: [272, 3, 272]),
                                                           albedo: [0.12, 0.16, 0.2], roughness: 0.7, metallic: 0.2))
        healthBars(ents, cam, &extras)

        // allocate buffers and run the parallel fill
        var ptrs = [UnsafeMutablePointer<MeshInstance>]()
        for p in 0..<P {
            let total = Int(running[p]) + extras[p].count
            instCount[p] = total
            let b = buffer(slot, p, total, frame.device)
            let ptr = b.contents().bindMemory(to: MeshInstance.self, capacity: b.length / MemoryLayout<MeshInstance>.stride)
            ptrs.append(ptr)
            extras[p].withUnsafeBufferPointer { src in if src.count > 0 { (ptr + Int(running[p])).update(from: src.baseAddress!, count: src.count) } }
        }
        let partsBuf = parts, starts = typeStart, lens = typeLen, scales = modelScale, cocoon = isCocoon
        let offs = offsets, lods = lodFlag
        let camYaw = self.camYaw
        ents.withUnsafeBufferPointer { ep in
            partsBuf.withUnsafeBufferPointer { pp in
                let ep = ep, pp = pp
                JobSystem.shared.parallelFor(n, grain: max(128, n / (JobSystem.shared.threadCount * 4)), label: "gw.instances") { r in
                    var cursor = SIMD8<Int32>(repeating: 0)
                    for i in r {
                        let e = ep[i]
                        guard e.alive, Int(e.type) < starts.count else { continue }
                        cursor = offs[i]
                        let far = lods[i]
                        let base = e.pos - cam
                        var s = scales[Int(e.type)]
                        if cocoon[Int(e.type)] { s *= 0.3 + 0.7 * e.progress }
                        if e.hitT > 0 { s *= 1 + e.hitT * 0.8 }
                        let st = Int(starts[Int(e.type)]), ln = Int(lens[Int(e.type)])
                        let hue = Float(e.seed & 255) / 255
                        for k in st..<(st + ln) {
                            let part = pp[k]
                            if far && !part.lod { continue }
                            var at = part.at, rot = part.rot, size = part.size, em = part.emissive
                            let ph = e.phase + part.phase, t = e.t
                            switch part.anim {
                            case .none: break
                            case .bob: at.y += sin(t * part.freq + ph) * part.amp
                            case .spin: rot.y += t * part.freq
                            case .pulse: size *= 1 + sin(t * part.freq + ph) * part.amp
                            case .wiggle: at.x += sin(t * part.freq - part.phase) * part.amp
                            case .swing: rot.x += sin(t * part.freq + ph) * part.amp
                            case .orbit:
                                let a = t * part.freq + part.phase, rr = simd_length(Vec2(part.at.x, part.at.z))
                                at.x = cos(a) * rr; at.z = sin(a) * rr; at.y += sin(t * part.freq * 1.3 + ph) * part.amp
                            case .gait:
                                let g = sin(t * part.freq * (e.moving ? 1 : 0.15) + part.phase)
                                rot.x += g * part.amp; at.y += max(0, g) * part.amp * 2
                            case .aim:
                                let da = e.aimYaw - e.yaw
                                let c = cos(da), sn = sin(da)
                                at = Vec3(at.x * c + at.z * sn, at.y, -at.x * sn + at.z * c); rot.y += da
                            case .flicker: em *= 0.6 + 0.4 * sin(t * part.freq * 7 + ph) * sin(t * part.freq * 3.1)
                            }
                            var col = part.color
                            if part.hueJitter {
                                let j1: Float = 0.8 + 0.4 * hue, j2: Float = 0.8 + 0.4 * (hue * 7.3 - floor(hue * 7.3)), j3: Float = 0.8 + 0.4 * (hue * 3.7 - floor(hue * 3.7))
                                col *= Vec3(j1, j2, j3)
                            }
                            if e.hitT > 0 { col = simd_mix(col, Vec3(1, 0.15, 0.1), Vec3(repeating: 0.6)); em = max(em, 1.5) }
                            let m = modelMatrix(base, yaw: e.yaw, scale: s, at: at, rot: rot, size: size)
                            let pi = part.prim.rawValue
                            ptrs[pi][Int(cursor[pi])] = MeshInstance(model: m, albedo: col, roughness: part.rough, metallic: part.metal, emissive: em)
                            cursor[pi] += 1
                        }
                    }
                    _ = camYaw
                }
            }
        }
        buildFX(cam)
    }

    private func healthBars(_ ents: [Entity], _ cam: Vec3, _ extras: inout [[MeshInstance]]) {
        let bi = Part.Prim.box.rawValue
        let sel = Set(overlay.selected.map(\.idx)).union(overlay.attackSel.map(\.idx))
        for (i, e) in ents.enumerated() where e.alive {
            let d = sim.defs[Int(e.type)]
            let ratio = max(0, e.hp / e.maxHp)
            guard e.side == .us || d.cat == .base || ratio < 0.999 || sel.contains(Int32(i)) else { continue }
            if simd_distance_squared(e.pos, cam) > 1400 * 1400 { continue }
            let w = max(14, d.r * 1.6), y = e.pos.y + d.r * 1.4 + 16
            let c = Vec3(e.pos.x, y, e.pos.z) - cam
            extras[bi].append(MeshInstance(model: modelMatrix(c, yaw: camYaw, at: .zero, rot: .zero, size: [w, 2.2, 0.6]), albedo: [0.05, 0.01, 0.01], roughness: 1))
            let col: Vec3 = e.side == .them ? [1, 0.2, 0.3] : ratio > 0.5 ? [0.2, 1, 0.35] : ratio > 0.25 ? [1, 0.8, 0.2] : [1, 0.25, 0.2]
            extras[bi].append(MeshInstance(model: modelMatrix(c, yaw: camYaw, at: Vec3(-(w - w * ratio) / 2, 0, 0.35), rot: .zero, size: [max(0.01, w * ratio), 2.2, 0.6]),
                                           albedo: col, roughness: 1, emissive: 2.2))
        }
    }

    // MARK: effects

    private func buildFX(_ cam: Vec3) {
        var add: [[FXInstance]] = Array(repeating: [], count: Part.Prim.allCases.count)
        var alpha: [[FXInstance]] = Array(repeating: [], count: Part.Prim.allCases.count)
        let S = Part.Prim.sphere.rawValue, B = Part.Prim.box.rawValue, TO = Part.Prim.torus.rawValue, IC = Part.Prim.ico.rawValue, CY = Part.Prim.cyl.rawValue
        func fx(_ list: inout [[FXInstance]], _ p: Int, _ m: Mat4, _ c: Vec3, _ a: Float, rim: Float = 0, mode: Float = 0) { list[p].append(FXInstance(model: m, color: Vec4(c, a), params: Vec4(rim, mode, 0, 0))) }
        func beam(_ a: Vec3, _ b: Vec3, _ w: Float, _ c: Vec3, _ alpha: Float) {
            let d = b - a, l = simd_length(d); guard l > 0.01 else { return }
            fx(&add, B, segment(a - cam, b - cam, width: w), c * 3, alpha)
        }
        for f in sim.fx {
            let k = f.t / f.life
            switch f.kind {
            case .line: beam(f.a, f.b, f.size, f.color, 1 - k)
            case .bolt:
                var prev = f.a
                for s in 1...6 {
                    var p = simd_mix(f.a, f.b, Vec3(repeating: Float(s) / 6))
                    if s < 6 { p += Vec3(Float.random(in: -5...5), Float.random(in: -5...5), Float.random(in: -5...5)) }
                    beam(prev, p, f.size, f.color, 1 - k); prev = p
                }
            case .burst: fx(&add, S, modelMatrix(f.a - cam, yaw: 0, at: .zero, rot: .zero, size: Vec3(repeating: f.size * (0.25 + 0.75 * min(1, k * 3)))), f.color * 2, 1 - k, rim: 0.6)
            case .ring: fx(&add, TO, modelMatrix(f.a - cam + Vec3(0, 1.5, 0), yaw: 0, at: .zero, rot: .zero, size: Vec3(max(0.01, f.size * k), 1, max(0.01, f.size * k))), f.color * 2, 0.8 * (1 - k))
            case .particle: fx(&add, IC, modelMatrix(f.a - cam, yaw: 0, at: .zero, rot: Vec3(f.t * 5, f.t * 3, 0), size: Vec3(repeating: f.size * (1 + k))), f.color * 2, 1 - k)
            case .puff: fx(&alpha, IC, modelMatrix(f.a - cam, yaw: 0, at: .zero, rot: .zero, size: Vec3(repeating: f.size * (1 + k * 2.5))), f.color, 0.35 * (1 - k))
            }
        }
        // live beams, shields, selection, radar
        let ents = sim.ents
        for (i, e) in ents.enumerated() where e.alive {
            let d = sim.defs[Int(e.type)]
            if e.beamOn { beam(e.pos + Vec3(0, 28, 0), e.beamTo, 1.6 + Float.random(in: 0...0.6), [1, 0.15, 0.25], 0.9) }
            if d.brain == .shield {
                let r = sim.radius(e)
                fx(&alpha, S, modelMatrix(e.pos - cam, yaw: 0, at: .zero, rot: .zero, size: [r, r, r]), [0.3, 0.6, 1], 0.05 + 0.15 * e.energy / 300, rim: 1)
            }
            if overlay.showAttackerInfo {
                if d.brain == .radar || d.name == "hq", e.side == .us {
                    let r = d.brain == .radar ? sim.radius(e) : 500
                    fx(&alpha, CY, modelMatrix(Vec3(e.pos.x, 2, e.pos.z) - cam, yaw: 0, at: .zero, rot: .zero, size: [r, 0.5, r]), [0.2, 1, 0.8], 0.06)
                    fx(&add, TO, modelMatrix(Vec3(e.pos.x, 3, e.pos.z) - cam, yaw: 0, at: .zero, rot: .zero, size: [r, 2, r]), [0.2, 1, 0.8], 0.6)
                }
                if e.hasSite && d.brain == .builder {
                    let s = 14 + sin(Float(sim.time) * 5) * 3
                    fx(&add, TO, modelMatrix(Vec3(e.site.x, Terrain.height(e.site.x, e.site.y) + 2, e.site.y) - cam, yaw: 0, at: .zero, rot: .zero, size: [s, 2, s]), [1, 0.8, 0.2], 0.9)
                }
            }
            _ = i
        }
        for r in overlay.selected + overlay.attackSel {
            guard let i = sim.resolve(r) else { continue }
            let e = ents[i], d = sim.defs[Int(e.type)]
            let col: Vec3 = e.side == .us ? [0.3, 1, 0.6] : [1, 0.25, 0.4]
            let rr = d.r + 6
            fx(&add, TO, modelMatrix(Vec3(e.pos.x, Terrain.height(e.pos.x, e.pos.z) + 1.5, e.pos.z) - cam, yaw: 0, at: .zero, rot: .zero, size: [rr, 2, rr]), col, 0.9)
            if overlay.selected.count == 1, e.side == .us {
                let range = d.range > 0 ? sim.range(e) : (d.radius > 0 ? sim.radius(e) : 0)
                if range > 0 { fx(&add, TO, modelMatrix(Vec3(e.pos.x, e.pos.y + 1.2, e.pos.z) - cam, yaw: 0, at: .zero, rot: .zero, size: [range, 1.5, range]), [1, 0.65, 0.3], 0.6) }
            }
        }
        if let c = overlay.buildRingCenter {
            let r = overlay.buildR
            fx(&add, TO, modelMatrix(c + Vec3(0, 1, 0) - cam, yaw: 0, at: .zero, rot: .zero, size: [r, 1.5, r]), [0.3, 1, 0.6], 0.6)
        }
        if overlay.ghostType >= 0, overlay.ghostType < sim.defs.defs.count {
            let d = sim.defs[overlay.ghostType], col: Vec3 = overlay.ghostOK ? [0.3, 1, 0.5] : [1, 0.25, 0.2]
            for p in d.model { fx(&alpha, p.prim.rawValue, modelMatrix(overlay.ghostPos - cam, yaw: 0, at: p.at, rot: p.rot, size: p.size), col, 0.45) }
        }
        // translucent world: water and giant cells
        fx(&alpha, B, modelMatrix(Vec3(0, Terrain.waterLevel + sin(Float(sim.time) * 0.5) * 0.6, 0) - cam, yaw: 0, at: .zero, rot: .zero, size: [5200, 0.1, 5200]), [0.05, 0.35, 0.45], 0.62, rim: 0, mode: 1)
        for c in cells {
            fx(&alpha, S, modelMatrix(c.pos - cam, yaw: 0, at: .zero, rot: .zero, size: Vec3(repeating: c.radius)), c.color, 0.18, rim: 1)
            fx(&add, IC, modelMatrix(c.pos + Vec3(c.radius * 0.2, c.radius * 0.25, 0) - cam, yaw: 0, at: .zero, rot: Vec3(0, Float(sim.time) * 0.2, 0), size: Vec3(repeating: c.radius * 0.28)), c.color * 1.5, 0.5)
        }
        addFX = add.enumerated().filter { !$0.element.isEmpty }.map { ($0.offset, $0.element) }
        alphaFX = alpha.enumerated().filter { !$0.element.isEmpty }.map { ($0.offset, $0.element) }
    }

    // MARK: draw

    private func terrainInstance(_ frame: FrameContext) -> MeshInstance {
        MeshInstance(model: Mat4(translation: -frame.camera.position.float), albedo: [0.3, 0.3, 0.3])
    }

    func drawShadow(_ enc: any MTLRenderCommandEncoder, frame: FrameContext, cascade: Int) {
        if let t = terrain { var ti = terrainInstance(frame); enc.setVertexBytes(&ti, length: MemoryLayout<MeshInstance>.stride, index: 1); t.draw(enc, instanceCount: 1) }
        for (p, mesh) in prims.enumerated() where instCount[p] > 0 {
            guard let b = instBufs[curSlot][p] else { continue }
            enc.setVertexBuffer(b, offset: 0, index: 1); mesh.draw(enc, instanceCount: instCount[p])
        }
    }

    func drawOpaque(_ enc: any MTLRenderCommandEncoder, frame: FrameContext) {
        if let t = terrain, let tp = terrainPipe {
            enc.setRenderPipelineState(tp); frame.bindFrame(enc)
            var origin = Vec4(frame.camera.position.float, 0)
            enc.setVertexBytes(&origin, length: 16, index: 1)
            t.draw(enc, instanceCount: 1)
        }
        enc.setRenderPipelineState(frame.pipelines.mesh); frame.bindFrame(enc)
        for (p, mesh) in prims.enumerated() where instCount[p] > 0 {
            guard let b = instBufs[curSlot][p] else { continue }
            enc.setVertexBuffer(b, offset: 0, index: 1); mesh.draw(enc, instanceCount: instCount[p])
        }
    }

    func drawTransparent(_ enc: any MTLRenderCommandEncoder, frame: FrameContext) {
        enc.setCullMode(.none)
        for (pipe, lists) in [(fxAlpha, alphaFX), (fxAdd, addFX)] {
            guard let pipe, !lists.isEmpty else { continue }
            enc.setRenderPipelineState(pipe); frame.bindFrame(enc)
            enc.setDepthStencilState(frame.pipelines.depthReadOnly)
            for (p, list) in lists {
                guard let (buf, off) = frame.transientBuffer(list) else { continue }
                enc.setVertexBuffer(buf, offset: off, index: 1); prims[p].draw(enc, instanceCount: list.count)
            }
        }
    }
}

// MARK: - matrix helpers

@inline(__always) func eulerQuat(_ r: Vec3) -> simd_quatf {
    var q = simd_quatf(angle: r.x, axis: [1, 0, 0])
    if r.y != 0 { q = q * simd_quatf(angle: r.y, axis: [0, 1, 0]) }
    if r.z != 0 { q = q * simd_quatf(angle: r.z, axis: [0, 0, 1]) }
    return q
}
/// base (camera-relative) · yaw · uniform scale · part offset · part rotation · part size
@inline(__always) func modelMatrix(_ base: Vec3, yaw: Float, scale: Float = 1, at: Vec3, rot: Vec3, size: Vec3) -> Mat4 {
    let qy = simd_quatf(angle: yaw, axis: [0, 1, 0])
    let q = qy * eulerQuat(rot)
    let p = base + qy.act(at * scale)
    var m = simd_float4x4(q)
    m.columns.0 *= size.x * scale; m.columns.1 *= size.y * scale; m.columns.2 *= size.z * scale
    m.columns.3 = Vec4(p, 1)
    return m
}
/// Unit box stretched between two points.
@inline(__always) func segment(_ a: Vec3, _ b: Vec3, width w: Float) -> Mat4 {
    let d = b - a, l = simd_length(d), z = d / l
    var x = simd_cross(Vec3(0, 1, 0), z); if simd_length(x) < 1e-4 { x = [1, 0, 0] }
    x = simd_normalize(x); let y = simd_cross(z, x)
    return Mat4(columns: (Vec4(x * w, 0), Vec4(y * w, 0), Vec4(z * l, 0), Vec4((a + b) / 2, 1)))
}

enum Shapes {
    /// Flat-shaded icosahedron, radius 1.
    static func icosahedron() -> CPUMesh {
        let t: Float = (1 + Float(5).squareRoot()) / 2
        let vs: [Vec3] = [[-1, t, 0], [1, t, 0], [-1, -t, 0], [1, -t, 0], [0, -1, t], [0, 1, t], [0, -1, -t], [0, 1, -t], [t, 0, -1], [t, 0, 1], [-t, 0, -1], [-t, 0, 1]].map { simd_normalize($0) }
        let f: [(Int, Int, Int)] = [(0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11), (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6), (7, 1, 8),
                                    (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9), (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1)]
        var soup: [Float] = []
        for (a, b, c) in f { for v in [vs[a], vs[c], vs[b]] { soup += [v.x, v.y, v.z] } }
        var m = MeshBuilder.triangleSoup(soup)
        // make winding match the outward normal
        for k in stride(from: 0, to: m.vertices.count, by: 3) {
            let a = m.vertices[k].position, b = m.vertices[k + 1].position, c = m.vertices[k + 2].position
            let n = simd_normalize(simd_cross(b - a, c - a))
            if simd_dot(n, a) < 0 { m.vertices.swapAt(k + 1, k + 2) }
            let nn = simd_normalize(simd_cross(m.vertices[k + 1].position - a, m.vertices[k + 2].position - a))
            for j in 0..<3 { m.vertices[k + j].nx = nn.x; m.vertices[k + j].ny = nn.y; m.vertices[k + j].nz = nn.z }
        }
        return m
    }
    /// Torus lying in the XZ plane.
    static func torus(major R: Float, minor r: Float, segments: Int, sides: Int) -> CPUMesh {
        var v: [MeshVertex] = [], idx: [UInt32] = []
        for i in 0...segments { for j in 0...sides {
            let u = Float(i) / Float(segments) * 2 * .pi, w = Float(j) / Float(sides) * 2 * .pi
            let c = Vec3(cos(u), 0, sin(u)), n = c * cos(w) + Vec3(0, sin(w), 0)
            v.append(MeshVertex(c * R + n * r, n))
        } }
        let row = UInt32(sides + 1)
        for i in 0..<UInt32(segments) { for j in 0..<UInt32(sides) {
            let a = i * row + j, b = a + row
            idx += [a, a + 1, b, a + 1, b + 1, b]
        } }
        return CPUMesh(vertices: v, indices: idx)
    }
}
