// OWNED BY collision builder.
// Dynamic AABB tree (broadphase, Box2D-style SAH insertion with fat AABBs) and a static triangle BVH.
import Foundation
import simd
import PWCore

public struct DynamicAABBTree {
    struct Node { var box: AABB; var parent = -1; var c1 = -1; var c2 = -1; var payload = -1; var height = 0
        var isLeaf: Bool { c1 < 0 } }
    private(set) var nodes: [Node] = []
    private var free: [Int] = []
    private(set) var root = -1
    public init() {}

    @inline(__always) static func area(_ b: AABB) -> Double { let e = b.max - b.min; return 2 * (e.x * e.y + e.y * e.z + e.z * e.x) }

    private mutating func alloc(_ n: Node) -> Int {
        if let i = free.popLast() { nodes[i] = n; return i }
        nodes.append(n); return nodes.count - 1
    }

    public mutating func insert(_ box: AABB, payload: Int) -> Int {
        let leaf = alloc(Node(box: box, payload: payload))
        insertLeaf(leaf); return leaf
    }
    public mutating func remove(_ leaf: Int) { removeLeaf(leaf); nodes[leaf].payload = -2; free.append(leaf) }

    /// Returns true if the leaf had to be re-inserted (tight box escaped fat box).
    @discardableResult
    public mutating func move(_ leaf: Int, tight: AABB, margin: Double, displacement: Vec3d) -> Bool {
        let fatOld = nodes[leaf].box
        if all(fatOld.min .<= tight.min) && all(tight.max .<= fatOld.max) { return false }
        var fat = AABB(min: tight.min - margin, max: tight.max + margin)
        let d = displacement * 2
        fat.min += simd_min(d, .zero); fat.max += simd_max(d, .zero)
        removeLeaf(leaf); nodes[leaf].box = fat; insertLeaf(leaf); return true
    }
    public func fatBox(_ leaf: Int) -> AABB { nodes[leaf].box }
    public func payload(_ leaf: Int) -> Int { nodes[leaf].payload }

    private mutating func insertLeaf(_ leaf: Int) {
        if root < 0 { root = leaf; nodes[leaf].parent = -1; return }
        let lb = nodes[leaf].box
        var i = root
        while !nodes[i].isLeaf {
            let c1 = nodes[i].c1, c2 = nodes[i].c2
            let a = Self.area(nodes[i].box), comb = Self.area(nodes[i].box.union(lb))
            let cost = 2 * comb, inh = 2 * (comb - a)
            func childCost(_ c: Int) -> Double {
                let u = Self.area(lb.union(nodes[c].box))
                return nodes[c].isLeaf ? u + inh : u - Self.area(nodes[c].box) + inh
            }
            let cc1 = childCost(c1), cc2 = childCost(c2)
            if cost < cc1 && cost < cc2 { break }
            i = cc1 < cc2 ? c1 : c2
        }
        let sib = i, oldParent = nodes[sib].parent
        let np = alloc(Node(box: lb.union(nodes[sib].box), parent: oldParent, c1: sib, c2: leaf, height: nodes[sib].height + 1))
        if oldParent >= 0 { if nodes[oldParent].c1 == sib { nodes[oldParent].c1 = np } else { nodes[oldParent].c2 = np } } else { root = np }
        nodes[sib].parent = np; nodes[leaf].parent = np
        refit(nodes[leaf].parent)
    }
    private mutating func refit(_ start: Int) {
        var i = start
        while i >= 0 {
            let c1 = nodes[i].c1, c2 = nodes[i].c2
            nodes[i].box = nodes[c1].box.union(nodes[c2].box)
            nodes[i].height = 1 + max(nodes[c1].height, nodes[c2].height)
            i = nodes[i].parent
        }
    }
    private mutating func removeLeaf(_ leaf: Int) {
        if leaf == root { root = -1; return }
        let p = nodes[leaf].parent, gp = nodes[p].parent
        let sib = nodes[p].c1 == leaf ? nodes[p].c2 : nodes[p].c1
        if gp >= 0 {
            if nodes[gp].c1 == p { nodes[gp].c1 = sib } else { nodes[gp].c2 = sib }
            nodes[sib].parent = gp; free.append(p); nodes[p].payload = -2; refit(gp)
        } else { root = sib; nodes[sib].parent = -1; free.append(p); nodes[p].payload = -2 }
    }

    public func query(_ box: AABB, _ visit: (Int) -> Void) {
        guard root >= 0 else { return }
        var stack = [root]; stack.reserveCapacity(64)
        while let i = stack.popLast() {
            let n = nodes[i]
            guard n.box.intersects(box) else { continue }
            if n.isLeaf { visit(n.payload) } else { stack.append(n.c1); stack.append(n.c2) }
        }
    }
    public func raycast(_ o: Vec3d, _ d: Vec3d, _ maxT: Double, _ visit: (Int) -> Void) {
        guard root >= 0 else { return }
        let inv = Vec3d(1 / d.x, 1 / d.y, 1 / d.z)
        var stack = [root]
        while let i = stack.popLast() {
            let n = nodes[i]
            guard rayAABB(o, inv, n.box, maxT) else { continue }
            if n.isLeaf { visit(n.payload) } else { stack.append(n.c1); stack.append(n.c2) }
        }
    }
}

@inline(__always) func rayAABB(_ o: Vec3d, _ inv: Vec3d, _ b: AABB, _ maxT: Double) -> Bool {
    let t1 = (b.min - o) * inv, t2 = (b.max - o) * inv
    let tmin = simd_reduce_max(simd_min(t1, t2)), tmax = simd_reduce_min(simd_max(t1, t2))
    return tmax >= max(tmin, 0) && tmin <= maxT
}

/// Static BVH over triangles (median split), for static triangle-mesh colliders.
public struct TriangleBVH: Sendable {
    struct Node: Sendable { var box: AABB; var left: Int; var count: Int; var right: Int = -1 } // leaf: left = first tri; inner: count 0, children left/right
    var nodes: [Node] = []
    public private(set) var tris: [(Vec3d, Vec3d, Vec3d)] = []
    public init(positions: [Vec3d], indices: [UInt32]) {
        var t: [(Vec3d, Vec3d, Vec3d)] = []
        for i in stride(from: 0, to: indices.count - 2, by: 3) {
            t.append((positions[Int(indices[i])], positions[Int(indices[i + 1])], positions[Int(indices[i + 2])]))
        }
        tris = t
        var order = Array(0..<t.count)
        build(&order, 0, t.count)
        tris = order.map { t[$0] }
    }
    func triBox(_ i: (Vec3d, Vec3d, Vec3d)) -> AABB { AABB(min: simd_min(i.0, simd_min(i.1, i.2)), max: simd_max(i.0, simd_max(i.1, i.2))) }
    @discardableResult
    mutating func build(_ order: inout [Int], _ s: Int, _ e: Int) -> Int {
        var box = AABB.empty
        for k in s..<e { box = box.union(triBox(tris[order[k]])) }
        let idx = nodes.count
        nodes.append(Node(box: box, left: s, count: e - s))
        if e - s <= 4 { return idx }
        let ext = box.max - box.min
        let axis = ext.x > ext.y ? (ext.x > ext.z ? 0 : 2) : (ext.y > ext.z ? 1 : 2)
        let tr = tris
        order[s..<e].sort { (tr[$0].0[axis] + tr[$0].1[axis] + tr[$0].2[axis]) < (tr[$1].0[axis] + tr[$1].1[axis] + tr[$1].2[axis]) }
        let m = (s + e) / 2
        nodes[idx].count = 0
        let l = build(&order, s, m); let r = build(&order, m, e)
        nodes[idx].left = l; nodes[idx].right = r
        return idx
    }
    public var bounds: AABB { nodes.first?.box ?? .empty }
    public func query(_ box: AABB, _ visit: (Int) -> Void) {
        guard !nodes.isEmpty else { return }
        var stack = [0]
        while let i = stack.popLast() {
            let n = nodes[i]
            guard n.box.intersects(box) else { continue }
            if n.count > 0 { for k in n.left..<(n.left + n.count) { if triBox(tris[k]).intersects(box) { visit(k) } } }
            else { stack.append(n.left); stack.append(n.right) }
        }
    }
    public func raycast(_ o: Vec3d, _ d: Vec3d, _ maxT: Double) -> (t: Double, n: Vec3d)? {
        guard !nodes.isEmpty else { return nil }
        let inv = Vec3d(1 / d.x, 1 / d.y, 1 / d.z)
        var best: (Double, Vec3d)? = nil; var bt = maxT
        var stack = [0]
        while let i = stack.popLast() {
            let n = nodes[i]
            guard rayAABB(o, inv, n.box, bt) else { continue }
            if n.count > 0 {
                for k in n.left..<(n.left + n.count) {
                    let (a, b, c) = tris[k]
                    let e1 = b - a, e2 = c - a, p = simd_cross(d, e2), det = simd_dot(e1, p)
                    if abs(det) < 1e-14 { continue }
                    let inv = 1 / det, s = o - a, u = simd_dot(s, p) * inv
                    if u < 0 || u > 1 { continue }
                    let q = simd_cross(s, e1), v = simd_dot(d, q) * inv
                    if v < 0 || u + v > 1 { continue }
                    let t = simd_dot(e2, q) * inv
                    if t >= 0 && t < bt { bt = t; var nn = simd_cross(e1, e2).normalizedSafe; if simd_dot(nn, d) > 0 { nn = -nn }; best = (t, nn) }
                }
            } else { stack.append(n.left); stack.append(n.right) }
        }
        return best.map { (t: $0.0, n: $0.1) }
    }
}
