// OWNED BY vegetation builder. ---------------------------------------------------------------
// Procedural tree generation: space-colonisation branching (Runions et al. 2007) for pine/oak/birch,
// a dedicated curved-trunk + frond generator for palms, pipe-model branch radii, generalised-cylinder
// bark meshes and alpha-tested leaf cards. Each species template yields an LOD chain:
//   LOD0: full branching (8-sided tubes, all leaf cards)
//   LOD1: branches with radius > threshold (4-sided), ~1/3 of cards enlarged to keep crown density
//   LOD2: octahedral impostor (baked on the GPU by ImpostorBaker)
//
// Vertex convention (standard MeshVertex): leaf vertices have uv.y = -(1 + 2*kind + v) (negative = leaf flag) and the
// shaders alpha-test a procedural leaf/needle silhouette inside the card. Bark uses uv.x around the trunk
// and uv.y along it (in metres) for procedural bark.
import Foundation
import simd
import PWCore
import PWRender

public enum TreeSpecies: Int, CaseIterable, Sendable, Codable {
    case pine = 0, oak = 1, birch = 2, palm = 3
    public var name: String { ["pine", "oak", "birch", "palm"][rawValue] }
    public init?(name: String) { guard let i = ["pine", "oak", "birch", "palm"].firstIndex(of: name.lowercased()) else { return nil }; self.init(rawValue: i) }
}

/// Species shape parameters (all in metres for a "unit-scale" adult tree; instances are scaled 0.7–1.3).
public struct SpeciesParams: Sendable {
    public var height: Float
    public var trunkHeight: Float          // clear trunk below the crown
    public var crownRadius: Float
    public var crownShape: Int             // 0 cone, 1 ellipsoid, 2 narrow ellipsoid
    public var attractors: Int
    public var influence: Float, kill: Float, step: Float
    public var tropism: Vec3               // gravitropism / phototropism bias added to growth direction
    public var baseRadius: Float
    public var leafSize: Vec2              // card width, length
    public var leavesPerTip: Int
    public var barkColor: Vec3, leafColor: Vec3
    public var barkRoughness: Float
    public var breakImpulse: Double        // N·s for a scale-1 tree
    public var massKg: Double              // trunk+crown mass for a scale-1 tree
    public var leafKind: Float             // 0 broadleaf, 1 needles, 2 palm frond, 3 birch (small round)

    public static func of(_ s: TreeSpecies) -> SpeciesParams {
        switch s {
        case .pine:
            return SpeciesParams(height: 18, trunkHeight: 4, crownRadius: 3.6, crownShape: 0, attractors: 700, influence: 3.0, kill: 0.9, step: 0.55,
                                 tropism: [0, -0.15, 0], baseRadius: 0.32, leafSize: [1.2, 1.6], leavesPerTip: 5,
                                 barkColor: [0.16, 0.09, 0.055], leafColor: [0.045, 0.09, 0.035], barkRoughness: 0.9,
                                 breakImpulse: 9000, massKg: 1800, leafKind: 1)
        case .oak:
            return SpeciesParams(height: 15, trunkHeight: 3.2, crownRadius: 6.5, crownShape: 1, attractors: 900, influence: 3.4, kill: 1.0, step: 0.6,
                                 tropism: [0, 0.05, 0], baseRadius: 0.45, leafSize: [1.3, 1.4], leavesPerTip: 5,
                                 barkColor: [0.13, 0.105, 0.08], leafColor: [0.07, 0.13, 0.03], barkRoughness: 0.95,
                                 breakImpulse: 16000, massKg: 3500, leafKind: 0)
        case .birch:
            return SpeciesParams(height: 16, trunkHeight: 3.5, crownRadius: 3.2, crownShape: 2, attractors: 600, influence: 2.8, kill: 0.8, step: 0.5,
                                 tropism: [0, -0.25, 0], baseRadius: 0.2, leafSize: [0.9, 1.0], leavesPerTip: 6,
                                 barkColor: [0.62, 0.6, 0.55], leafColor: [0.12, 0.2, 0.04], barkRoughness: 0.7,
                                 breakImpulse: 6000, massKg: 900, leafKind: 3)
        case .palm:
            return SpeciesParams(height: 11, trunkHeight: 10, crownRadius: 4.5, crownShape: 1, attractors: 0, influence: 0, kill: 0, step: 0.5,
                                 tropism: .zero, baseRadius: 0.22, leafSize: [0.9, 4.5], leavesPerTip: 1,
                                 barkColor: [0.3, 0.24, 0.17], leafColor: [0.09, 0.16, 0.04], barkRoughness: 0.85,
                                 breakImpulse: 7000, massKg: 700, leafKind: 2)
        }
    }
}

/// One generated tree template (one species variant) with its LOD meshes and collision proxy data.
public struct TreeTemplate: Sendable {
    public var species: TreeSpecies
    public var variant: Int
    public var lods: [CPUMesh]             // [LOD0, LOD1, shadow proxy]
    public var height: Float
    public var crownRadius: Float
    public var trunkRadius: Float
    public var boundsRadius: Float         // bounding sphere radius about (0, height/2, 0)
    public var branchCount: Int
    public var leafCount: Int
    public var params: SpeciesParams
}

/// Branch node of the space-colonisation skeleton.
struct BranchNode {
    var pos: Vec3
    var parent: Int
    var dir: Vec3
    var radius: Float = 0
    var children = 0
    var depth = 0
}

public enum TreeGenerator {
    /// Generate one template. Deterministic for (species, seed).
    public static func generate(species: TreeSpecies, seed: UInt64, variant: Int = 0) -> TreeTemplate {
        let p = SpeciesParams.of(species)
        var rng = PCG32(seed: seed &* 0x9E3779B97F4A7C15 &+ UInt64(species.rawValue * 977 + variant * 31))
        let nodes = species == .palm ? palmSkeleton(p, &rng) : colonise(p, &rng)
        let lod0 = buildMesh(nodes, p, species: species, sides: 8, minRadius: 0, leafKeep: 1, leafScale: 1, rng: PCG32(seed: seed &+ 7))
        let lod1 = buildMesh(nodes, p, species: species, sides: 4, minRadius: p.baseRadius * 0.12, leafKeep: 3, leafScale: 1.6, rng: PCG32(seed: seed &+ 7))
        // LOD "shadow proxy": major limbs only + a few large cards (cheap shadow caster).
        let lodS = buildMesh(nodes, p, species: species, sides: 3, minRadius: p.baseRadius * 0.3, leafKeep: 7, leafScale: 2.4, rng: PCG32(seed: seed &+ 7))
        var top: Float = 0, rad: Float = 0
        for v in lod0.mesh.vertices { top = max(top, v.py); rad = max(rad, simd_length(Vec2(v.px, v.pz))) }
        let br = simd_length(Vec2(rad, top * 0.5))
        return TreeTemplate(species: species, variant: variant, lods: [lod0.mesh, lod1.mesh, lodS.mesh], height: top, crownRadius: rad,
                            trunkRadius: nodes.first?.radius ?? p.baseRadius, boundsRadius: br, branchCount: nodes.count,
                            leafCount: lod0.leaves, params: p)
    }

    // MARK: space colonisation

    static func randInCrown(_ p: SpeciesParams, _ rng: inout PCG32) -> Vec3 {
        let crownH = p.height - p.trunkHeight
        while true {
            let x = Float(rng.unit() * 2 - 1), y = Float(rng.unit()), z = Float(rng.unit() * 2 - 1)
            var inside = false
            switch p.crownShape {
            case 0: inside = (x * x + z * z).squareRoot() <= (1 - y) * 1.0                    // cone
            case 2: let yy = y * 2 - 1; inside = x * x + z * z + yy * yy * 1.0 <= 1        // narrow ellipsoid (scaled below)
            default: let yy = y * 2 - 1; inside = x * x + z * z + yy * yy <= 1
            }
            if inside {
                let rScale: Float = p.crownShape == 2 ? 0.8 : 1
                return Vec3(x * p.crownRadius * rScale, p.trunkHeight + y * crownH, z * p.crownRadius * rScale)
            }
        }
    }

    static func colonise(_ p: SpeciesParams, _ rng: inout PCG32) -> [BranchNode] {
        var attractors = (0..<p.attractors).map { _ in randInCrown(p, &rng) }
        var alive = [Bool](repeating: true, count: attractors.count)
        var nodes: [BranchNode] = []
        // Trunk up to the crown base (slight lean).
        let lean = Vec3(Float(rng.unit() - 0.5) * 0.06, 1, Float(rng.unit() - 0.5) * 0.06)
        var pos = Vec3.zero
        nodes.append(BranchNode(pos: pos, parent: -1, dir: [0, 1, 0]))
        while pos.y < p.trunkHeight {
            pos += simd_normalize(lean) * p.step
            nodes.append(BranchNode(pos: pos, parent: nodes.count - 1, dir: simd_normalize(lean)))
        }
        // Pines: continue a dominant leader through the crown (excurrent growth).
        if p.crownShape == 0 {
            while pos.y < p.height * 0.97 {
                pos += Vec3(0, p.step, 0)
                nodes.append(BranchNode(pos: pos, parent: nodes.count - 1, dir: [0, 1, 0]))
            }
        }
        let infl2 = p.influence * p.influence, kill2 = p.kill * p.kill
        for _ in 0..<70 {
            var growDir = [Vec3](repeating: .zero, count: nodes.count)
            var growCnt = [Int](repeating: 0, count: nodes.count)
            var any = false
            for (ai, a) in attractors.enumerated() where alive[ai] {
                var best = -1; var bd = infl2
                for (ni, n) in nodes.enumerated() {
                    let d = simd_distance_squared(a, n.pos)
                    if d < bd { bd = d; best = ni }
                }
                if best >= 0 {
                    if bd < kill2 { alive[ai] = false; continue }
                    growDir[best] += simd_normalize(a - nodes[best].pos); growCnt[best] += 1; any = true
                }
            }
            if !any { break }
            let n0 = nodes.count
            for ni in 0..<n0 where growCnt[ni] > 0 {
                var d = simd_normalize(growDir[ni] / Float(growCnt[ni]) + p.tropism)
                if !d.x.isFinite { d = [0, 1, 0] }
                let np = nodes[ni].pos + d * p.step
                nodes.append(BranchNode(pos: np, parent: ni, dir: d, depth: nodes[ni].depth + 1))
            }
            // Drop attractors already reached.
            for ai in attractors.indices where alive[ai] {
                for ni in n0..<nodes.count where simd_distance_squared(attractors[ai], nodes[ni].pos) < kill2 { alive[ai] = false; break }
            }
            if nodes.count > 2600 { break }
        }
        attractors.removeAll()
        computeRadii(&nodes, p)
        return nodes
    }

    /// Pipe model: r_parent^2.4 = Σ r_child^2.4, tips get a fixed twig radius.
    static func computeRadii(_ nodes: inout [BranchNode], _ p: SpeciesParams) {
        for i in nodes.indices where nodes[i].parent >= 0 { nodes[nodes[i].parent].children += 1 }
        let tip = max(0.012, p.baseRadius * 0.05)
        var acc = [Float](repeating: 0, count: nodes.count)
        let e: Float = 2.4
        for i in stride(from: nodes.count - 1, through: 0, by: -1) {
            if nodes[i].children == 0 { acc[i] = pow(tip, e) }
            nodes[i].radius = pow(acc[i], 1 / e)
            if nodes[i].parent >= 0 { acc[nodes[i].parent] += acc[i] }
        }
        // Rescale so the base radius matches the species.
        let s = p.baseRadius / max(nodes[0].radius, 1e-4)
        for i in nodes.indices { nodes[i].radius = max(tip, nodes[i].radius * s) }
    }

    static func palmSkeleton(_ p: SpeciesParams, _ rng: inout PCG32) -> [BranchNode] {
        var nodes: [BranchNode] = []
        let bendDir = simd_normalize(Vec3(Float(rng.unit() - 0.5), 0, Float(rng.unit() - 0.5)) + Vec3(0.001, 0, 0))
        let segs = 22
        for i in 0...segs {
            let t = Float(i) / Float(segs)
            let pos = Vec3(0, t * p.trunkHeight, 0) + bendDir * (t * t * 1.6)
            nodes.append(BranchNode(pos: pos, parent: i - 1, dir: [0, 1, 0], radius: p.baseRadius * (1 - 0.4 * t)))
        }
        return nodes
    }

    // MARK: meshing

    static func buildMesh(_ nodes: [BranchNode], _ p: SpeciesParams, species: TreeSpecies, sides: Int, minRadius: Float,
                          leafKeep: Int, leafScale: Float, rng: PCG32) -> (mesh: CPUMesh, leaves: Int) {
        var rng = rng
        var v: [MeshVertex] = [], idx: [UInt32] = []
        v.reserveCapacity(nodes.count * sides * 2 + 4096)
        // Accumulated length along the branch for bark v-coordinate.
        var along = [Float](repeating: 0, count: nodes.count)
        for i in nodes.indices where nodes[i].parent >= 0 { along[i] = along[nodes[i].parent] + simd_distance(nodes[i].pos, nodes[nodes[i].parent].pos) }

        func frame(_ d: Vec3) -> (Vec3, Vec3) {
            let up: Vec3 = abs(d.y) < 0.95 ? [0, 1, 0] : [1, 0, 0]
            let a = simd_normalize(simd_cross(up, d)); return (a, simd_cross(d, a))
        }
        for i in nodes.indices {
            let n = nodes[i]
            guard n.parent >= 0, n.radius >= minRadius else { continue }
            let pn = nodes[n.parent]
            let d = simd_normalize(n.pos - pn.pos)
            // Use a shared frame direction for both rings so segments connect smoothly.
            let (a, b) = frame(d)
            let base = UInt32(v.count)
            for (c, r, vv) in [(pn.pos, pn.radius, along[n.parent]), (n.pos, n.radius, along[i])] {
                for s in 0...sides {
                    let ang = Float(s) / Float(sides) * 2 * .pi
                    let nrm = a * cos(ang) + b * sin(ang)
                    v.append(MeshVertex(c + nrm * r, nrm, Vec2(Float(s) / Float(sides), vv)))
                }
            }
            let row = UInt32(sides + 1)
            for s in 0..<UInt32(sides) {
                let i0 = base + s, i1 = base + s + 1, j0 = i0 + row, j1 = i1 + row
                idx += [i0, j0, i1, i1, j0, j1]
            }
        }
        // Cap the trunk base (hidden by ground normally) — skipped.

        // Leaves.
        var leaves = 0
        func card(_ c: Vec3, _ dir: Vec3, _ side: Vec3, w: Float, l: Float) {
            // Quad from c along dir (length l) with half-width w/2 along side. Leaf flag: uv.y + 10.
            let nrm = simd_normalize(simd_cross(side, dir))
            let base = UInt32(v.count)
            let hw = side * (w * 0.5)
            let quad: [(Vec3, Vec2)] = [(c - hw, [0, 0]), (c + hw, [1, 0]), (c + hw + dir * l, [1, 1]), (c - hw + dir * l, [0, 1])]
            for (pp, uv) in quad {
                // Bend normals outward from the crown centre for soft, volumetric lighting.
                let out = simd_normalize(pp - Vec3(0, p.trunkHeight + (p.height - p.trunkHeight) * 0.5, 0) + Vec3(0, 0.001, 0))
                let nn = simd_normalize(nrm * 0.4 + out * 0.6)
                v.append(MeshVertex(pp, nn, Vec2(uv.x, -1 - p.leafKind * 2 - uv.y)))
            }
            idx += [base, base + 1, base + 2, base, base + 2, base + 3]
            leaves += 1
        }
        if species == .palm {
            let crown = nodes.last!.pos
            let fronds = 14
            for f in 0..<fronds where f % max(1, leafKeep == 1 ? 1 : 2) == 0 {
                let az = Float(f) / Float(fronds) * 2 * .pi + Float(rng.unit()) * 0.3
                let droop = Float(rng.unit()) * 0.6 - 0.1
                // Frond = 3 chained cards that arch downward.
                var c = crown
                var dir = simd_normalize(Vec3(cos(az), 0.6 - droop, sin(az)))
                let side = simd_normalize(simd_cross(dir, [0, 1, 0]))
                let segL = p.leafSize.y / 3
                for _ in 0..<3 {
                    card(c, dir, side, w: p.leafSize.x * leafScale * 1.2, l: segL)
                    c += dir * segL
                    dir = simd_normalize(dir + Vec3(0, -0.45, 0))
                }
            }
        } else {
            var tipIndex = 0
            for (i, n) in nodes.enumerated() where n.children == 0 || (n.radius < p.baseRadius * 0.08 && n.depth > 2) {
                tipIndex += 1
                if tipIndex % leafKeep != 0 { continue }
                for _ in 0..<p.leavesPerTip {
                    let r = Vec3(Float(rng.unit() * 2 - 1), Float(rng.unit() * 2 - 1), Float(rng.unit() * 2 - 1))
                    var dir = simd_normalize(n.dir * 0.6 + r)
                    if p.leafKind == 1 { dir = simd_normalize(dir + Vec3(0, -0.3, 0)) }   // needles droop
                    if !dir.x.isFinite { dir = [0, 1, 0] }
                    var side = simd_cross(dir, simd_normalize(r + Vec3(0.01, 0.02, 0.03)))
                    if simd_length(side) < 1e-3 { side = [1, 0, 0] }
                    side = simd_normalize(side)
                    let sz = Float(0.8 + rng.unit() * 0.4) * leafScale
                    card(n.pos - dir * 0.1, dir, side, w: p.leafSize.x * sz, l: p.leafSize.y * sz)
                }
                _ = i
            }
        }
        return (CPUMesh(vertices: v, indices: idx), leaves)
    }
}
