// OWNED BY import builder. -------------------------------------------------------------------
import Foundation
import simd
import PWCore
import PWRender

public enum CraftSelfTests {
    public static func register() {
        SelfTestRegistry.register("craft", "presets-roundtrip") { ctx in
            for (name, json) in CraftPresets.all {
                let orig = try JSONIO.decode(JSONValue.self, from: Data(json.utf8))
                let doc = try JSONIO.decode(CraftDocument.self, from: Data(json.utf8))
                let enc = try JSONIO.encode(doc)
                let reJSON = try JSONIO.decode(JSONValue.self, from: enc), reDoc = try JSONIO.decode(CraftDocument.self, from: enc)
                ctx.expect(reJSON == orig, "\(name): re-encoded JSON differs from prototype JSON")
                ctx.expect(reDoc == doc, "\(name): decode(encode) != doc")
            }
            let t = CraftPresets.load("Trainer")!, r = CraftPresets.load("Rover")!, j = CraftPresets.load("Jet trainer")!, s = CraftPresets.load("Sounding rocket")!
            ctx.expect(t.parts.count == 16 && r.parts.count == 7 && j.parts.count == 15 && s.parts.count == 7, "preset part counts")
            ctx.expect(CraftOutputs.list(t).map(\.name) == ["Ailerons", "Elevator", "Rudder", "Engine"], "trainer outputs \(CraftOutputs.list(t).map(\.name))")
            ctx.expect(CraftOutputs.list(s).map(\.kind) == [.solid], "rocket outputs")
            ctx.expect(CraftOutputs.list(j).map(\.name) == ["Ailerons", "Elevator", "Rudder", "Turbojet"], "jet outputs")
            // derived: trainer's three unlinked wheels share one "Wheel drive" motor; rover's wheels are already driven
            ctx.expect(CraftOutputs.derive(t).map(\.name) == ["Ailerons", "Elevator", "Rudder", "Engine", "Wheel drive"], "trainer derived \(CraftOutputs.derive(t).map(\.name))")
            ctx.expect(CraftOutputs.derive(r).count == 2, "rover derived outputs")
            // rocket fin rotation reproduces rotFromBasis: fin(1,0) span +X
            let fin = s.parts.first { $0.type == "wing" }!
            ctx.expect(simd_distance(fin.rotation.act(Vec3d(0, 0, 1)), Vec3d(1, 0, 0)) < 1e-3, "rocket fin span axis")
            // euler helper inverse
            let q = Quatd(eulerXYZDegrees: [30, -50, 70]); let e = eulerXYZDegrees(q)
            ctx.expect(simd_distance(Quatd(eulerXYZDegrees: e).act([1, 2, 3]), q.act([1, 2, 3])) < 1e-6, "euler round-trip \(e)")
        }

        SelfTestRegistry.register("craft", "import-formats") { ctx in
            let cube = unitCube()
            let stl = try STLReader.parse(STLReader.binaryData(cube))
            ctx.expect(stl.triangleCount == 12 && stl.isWatertight, "binary STL")
            var ascii = "solid t\n"
            for tr in 0..<cube.triangleCount { ascii += "facet normal 0 0 0\nouter loop\n"
                for k in 0..<3 { let p = cube.positions[Int(cube.indices[tr * 3 + k])]; ascii += "vertex \(p.x) \(p.y) \(p.z)\n" }
                ascii += "endloop\nendfacet\n" }
            let a = try STLReader.parse(Data((ascii + "endsolid t\n").utf8))
            ctx.expect(a.triangleCount == 12 && a.isWatertight, "ASCII STL")
            let obj = "o body\nv 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3 4\ng fin\nv 0 0 1\nv 1 0 1\nv 0 1 1\nf -3/1/1 -2/2/2 -1/3/3\n"
            let o = try OBJReader.parse(obj)
            ctx.expect(o.map(\.name) == ["body", "fin"] && o[0].mesh.triangleCount == 2 && o[1].mesh.triangleCount == 1, "OBJ groups \(o.map(\.name))")
            let glb = try GLTFReader.parse(syntheticGLB(), baseURL: nil)
            ctx.expect(glb.count == syntheticNodes.count - 2, "GLB part count \(glb.count)")
            if let ail = glb.first(where: { $0.name == "aileron_L" }) {
                let c = (ail.mesh.bounds.min + ail.mesh.bounds.max) / 2
                ctx.expect(simd_distance(c, [-0.3, 0.5, -4.5]) < 1e-4, "glTF hierarchy transform, aileron_L centre \(c)")
            } else { ctx.fail("aileron_L missing") }
            // ModelIO path: write an OBJ and let ModelIO read it (USD files use the same code path).
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pw-craft-\(getpid())")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let u = dir.appendingPathComponent("tri.obj"); try Data(obj.utf8).write(to: u)
            let mio = try ModelIOReader.load(url: u)
            ctx.expect(!mio.isEmpty && mio.reduce(0) { $0 + $1.mesh.triangleCount } == 3, "ModelIO OBJ triangles \(mio.map { $0.mesh.triangleCount })")
            try? FileManager.default.removeItem(at: dir)
        }

        SelfTestRegistry.register("craft", "autorig-gltf") { ctx in
            let parts = try GLTFReader.parse(syntheticGLB(), baseURL: nil)
            var doc = CraftAssembler.makeCraft(name: "Synthetic", parts: parts)
            let rep = AutoRig.apply(&doc)
            let outs = CraftOutputs.derive(doc)
            let names = Set(outs.map(\.name))
            let expected: Set<String> = ["Ailerons", "Elevator", "Rudder", "Steering", "motor", "Wheel drive"]
            ctx.expect(names == expected, "outputs \(outs.map(\.name)) expected \(expected.sorted())")
            ctx.log("outputs: " + outs.map { "\($0.name) [\($0.info)]" }.joined(separator: ", "))
            func part(_ n: String) -> CraftPart? { doc.parts.first { $0.name == n } }
            let ail = doc.part(part("aileron_L")?.servo)
            ctx.expect(ail?.name == "Ailerons" && part("aileron_R")?.servo == ail?.id, "ailerons share a servo")
            ctx.expect(part("aileron_L")?.invert == false && part("aileron_R")?.invert == true, "aileron mirror inversion")
            ctx.expect(part("elevator")?.invert == true, "elevator inverted (nose-up positive)")
            if let al = part("aileron_L") {
                // hinge: local z axis of the re-based part is the span (world ±Z), origin near the leading edge
                let hz = al.rotation.act([0, 0, 1])
                ctx.expect(abs(abs(hz.z) - 1) < 1e-3, "aileron hinge axis along span \(hz)")
                ctx.expectClose(al.position.x, -0.3 + 0.2 * 0.92, tol: 1e-3, "aileron hinge near leading edge")
                ctx.expectClose(al.position.z, -4.5, tol: 1e-3, "aileron hinge z")
            }
            if let ru = part("rudder"), let rs = doc.part(ru.servo) {
                ctx.expect(abs(abs(ru.rotation.act(Vec3d(0, 0, 1)).y) - 1) < 1e-3, "rudder hinge vertical")
                ctx.expect(abs(abs(rs.rotation.act(Vec3d(0, 0, 1)).y) - 1) < 1e-3, "rudder servo axis vertical")
            } else { ctx.fail("rudder not rigged") }
            let w = part("wheel_L")
            ctx.expect(w?.type == "wheel" && abs((w?.param("r") ?? 0) - 0.3) < 1e-3 && abs((w?.param("width") ?? 0) - 0.2) < 1e-3, "wheel conversion r/width")
            ctx.expect(part("wheel_nose")?.servo == doc.parts.first { $0.name == "Steering" }?.id, "nose wheel steers")
            ctx.expect(part("prop")?.type == "prop" && part("prop")?.motor == part("motor")?.id, "prop linked to motor")
            ctx.expect(part("prop").map { simd_distance($0.rotation.act([1, 0, 0]), [1, 0, 0]) < 1e-3 } == true, "prop thrust axis +X")
            ctx.expect(part("tank")?.type == "tank" && (part("tank")?.param("capacity") ?? 0) > 100, "tank conversion")
            // geometry preserved: re-based CAD aileron still occupies the same world box
            if let al = part("aileron_L") {
                let b = CraftAssembler.worldMesh(of: al).bounds, c = (b.min + b.max) / 2
                ctx.expect(simd_distance(c, [-0.3, 0.5, -4.5]) < 1e-3, "rigged aileron world geometry \(c)")
            }
            // round-trips as prototype JSON
            let again = try JSONIO.decode(CraftDocument.self, from: JSONIO.encode(doc))
            ctx.expect(again == doc, "rigged craft JSON round-trip")
            ctx.expect(rep.warnings.isEmpty, "warnings \(rep.warnings)")
            ctx.expect(AutoRig.role(of: "dropship") == nil && AutoRig.role(of: "Left Aileron") == .aileron && AutoRig.role(of: "SRB_2") == .booster, "name rules")
        }

        SelfTestRegistry.register("craft", "meshcut-watertight") { ctx in
            let meshes: [(String, TriMesh)] = [
                ("cube", unitCube()),
                ("sphere", TriMesh(positionsOf: MeshBuilder.sphere(radius: 1, segments: 32, rings: 16)).welded()),
                ("cylinder", TriMesh(positionsOf: MeshBuilder.cylinder(radiusTop: 0.5, radiusBottom: 0.5, height: 2)).welded()),
                ("capsule", TriMesh(positionsOf: PartMeshFactory.capsule(radius: 0.4, length: 1)).welded(epsilon: 1e-4)),
            ]
            for (name, m) in meshes {
                guard m.isWatertight else { ctx.fail("\(name): input not watertight"); continue }
                for (pt, n) in [(Vec3(0.1, 0.05, 0), Vec3(1, 0.3, 0.2)), (Vec3.zero, Vec3(0, 1, 0)), (Vec3(0, 0.2, 0.1), Vec3(-0.3, 1, 0.7))] {
                    let r = MeshCut.split(m, planePoint: pt, planeNormal: n)
                    ctx.expect(r.below.isWatertight, "\(name): lower half not watertight")
                    ctx.expect(r.above.isWatertight, "\(name): upper half not watertight")
                    ctx.expect(r.below.volume > 0 && r.above.volume > 0, "\(name): positive volumes")
                    ctx.expectClose(r.below.volume + r.above.volume, m.volume, tol: abs(m.volume) * 1e-3, "\(name): volume conserved")
                }
            }
            // part-level cut keeps mass
            let box = CraftPart(id: "b", type: .box, name: "Box")
            if let (a, b) = MeshCut.split(part: box, planePoint: [0.2, 0, 0], planeNormal: [1, 0, 0]) {
                ctx.expectClose(a.mass + b.mass, box.mass, tol: 1e-6, "cut mass")
                ctx.expectClose(a.mass, box.mass * 0.7, tol: 1e-3, "cut mass split by volume")
            } else { ctx.fail("part split failed") }
            let big = TriMesh(positionsOf: MeshBuilder.sphere(radius: 1, segments: 256, rings: 128)).welded()
            let t0 = Date(); let r = MeshCut.split(big, planePoint: .zero, planeNormal: [0.2, 1, 0.1])
            ctx.log(String(format: "cut %d tris in %.1f ms (watertight %@)", big.triangleCount, Date().timeIntervalSince(t0) * 1000, String(r.below.isWatertight && r.above.isWatertight)))
        }

        SelfTestRegistry.register("craft", "world-library") { ctx in
            var w = WorldDocument(name: "Test World")
            w.terrain.kind = .procedural; w.terrain.seed = 42
            w.water.lakeSpecs = [LakeSpec(id: "l1", outline: [[0, 0], [10, 0], [10, 10]], surfaceHeight: 3)]
            w.water.riverSpecs = [RiverSpec(id: "r1", points: [[0, 0, 5, 4], [50, 10, 3, 6]])]
            w.vegetationLayers = [VegetationLayer(kind: "tree"), VegetationLayer(kind: "grass")]
            _ = w.placeProp(kind: "breakable", asset: "crate", at: Transform(position: [1, 2, 3]), breakable: true)
            var e = SculptDeltas(originX: -10, originZ: -10, cellSize: 1, width: 21, height: 21)
            e.applyBrush(x: 0, z: 0, radius: 5, amount: 2)
            ctx.expectClose(e.heightDelta(x: 0, z: 0), 2, tol: 1e-4, "brush centre")
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pw-world-\(getpid())")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = try CraftLibrary.saveWorld(w, edits: e, to: dir.appendingPathComponent("w.json"))
            let back = try CraftLibrary.loadWorld(url)
            ctx.expect(back.water.lakeSpecs == w.water.lakeSpecs && back.water.riverSpecs.count == 1 && back.vegetationLayers.count == 2, "typed world bags")
            ctx.expect(back.breakables.count == 1 && back.terrain.editsPath == "w.edits.json", "objects / edits path")
            ctx.expect(WorldIO.loadEdits(for: back, worldURL: url) == e, "sculpt deltas round-trip")
            let cu = try CraftLibrary.saveCraft(CraftPresets.load("Rover")!, to: dir.appendingPathComponent("rover.json"))
            let loaded = try CraftLibrary.loadCraft(cu)
            ctx.expect(loaded == CraftPresets.load("Rover")!, "craft save/load")
            ctx.expect(CraftLibrary.rootURL.path.hasSuffix("Application Support/PlaneWorld"), "library root \(CraftLibrary.rootURL.path)")
            try? FileManager.default.removeItem(at: dir)
            // part meshes exist for every preset part
            for d in CraftPresets.documents() { for p in d.parts { ctx.expect(PartMeshFactory.mesh(for: p).indices.count > 0, "mesh \(p.name)") } }
        }
    }

    // MARK: fixtures

    static func unitCube() -> TriMesh {
        let p: [Vec3] = [[-0.5, -0.5, -0.5], [0.5, -0.5, -0.5], [0.5, 0.5, -0.5], [-0.5, 0.5, -0.5],
                         [-0.5, -0.5, 0.5], [0.5, -0.5, 0.5], [0.5, 0.5, 0.5], [-0.5, 0.5, 0.5]]
        let i: [UInt32] = [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 3, 7, 6, 3, 6, 2, 0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5]
        return TriMesh(positions: p, indices: i)
    }

    /// (name, parent, translation, scale) — boxes; ailerons are children of wing groups to exercise the hierarchy.
    static let syntheticNodes: [(String, Int?, Vec3, Vec3)] = [
        ("fuselage", nil, [0, 0, 0], [6, 1, 1]),
        ("wing_L", 10, [0.4, 0, 0], [1.5, 0.1, 4]), ("wing_R", 11, [0.4, 0, 0], [1.5, 0.1, 4]),
        ("aileron_L", 10, [-0.3, 0, -2], [0.4, 0.08, 1.5]), ("aileron_R", 11, [-0.3, 0, 2], [0.4, 0.08, 1.5]),
        ("elevator", nil, [-3.5, 0.3, 0], [0.5, 0.06, 3]), ("rudder", nil, [-3.5, 1.0, 0], [0.5, 1.2, 0.06]),
        ("prop", nil, [3.4, 0, 0], [0.08, 1.8, 0.15]), ("motor", nil, [3.0, 0, 0], [0.5, 0.45, 0.4]),
        ("wheel_nose", nil, [2, -1, 0], [0.5, 0.5, 0.15]),
        // 10, 11: groups (no mesh)
        ("left_wing_group", nil, [0, 0.5, -2.5], [1, 1, 1]), ("right_wing_group", nil, [0, 0.5, 2.5], [1, 1, 1]),
        ("wheel_L", nil, [-0.2, -1, -1.2], [0.6, 0.6, 0.2]), ("wheel_R", nil, [-0.2, -1, 1.2], [0.6, 0.6, 0.2]),
        ("tank", nil, [1, 0, 0], [1.5, 0.5, 0.5]),
    ]

    static func syntheticGLB() -> Data {
        let cube = unitCube()
        var bin = Data()
        cube.positions.flatMap { [$0.x, $0.y, $0.z] }.withUnsafeBufferPointer { bin.append(Data(buffer: $0)) }
        let posLen = bin.count
        cube.indices.map { UInt16($0) }.withUnsafeBufferPointer { bin.append(Data(buffer: $0)) }
        while bin.count % 4 != 0 { bin.append(0) }
        var nodes: [[String: Any]] = []
        for (i, n) in syntheticNodes.enumerated() {
            var d: [String: Any] = ["name": n.0, "translation": [n.2.x, n.2.y, n.2.z]]
            if i == 10 || i == 11 { d["children"] = syntheticNodes.indices.filter { syntheticNodes[$0].1 == i } }
            else { d["mesh"] = 0; d["scale"] = [n.3.x, n.3.y, n.3.z] }
            nodes.append(d)
        }
        let roots = syntheticNodes.indices.filter { syntheticNodes[$0].1 == nil }
        let json: [String: Any] = [
            "asset": ["version": "2.0"], "scene": 0, "scenes": [["nodes": roots]], "nodes": nodes,
            "meshes": [["name": "box", "primitives": [["attributes": ["POSITION": 0], "indices": 1, "mode": 4]]]],
            "accessors": [["bufferView": 0, "componentType": 5126, "count": 8, "type": "VEC3"],
                          ["bufferView": 1, "componentType": 5123, "count": 36, "type": "SCALAR"]],
            "bufferViews": [["buffer": 0, "byteOffset": 0, "byteLength": posLen], ["buffer": 0, "byteOffset": posLen, "byteLength": 72]],
            "buffers": [["byteLength": bin.count]],
        ]
        var j = try! JSONSerialization.data(withJSONObject: json)
        while j.count % 4 != 0 { j.append(0x20) }
        var out = Data("glTF".utf8)
        func u32(_ v: Int) { var x = UInt32(v); out.append(Data(bytes: &x, count: 4)) }
        u32(2); u32(12 + 8 + j.count + 8 + bin.count)
        u32(j.count); u32(0x4E4F534A); out.append(j)
        u32(bin.count); u32(0x004E4942); out.append(bin)
        return out
    }
}
