// OWNED BY import builder. -------------------------------------------------------------------
// Craft presets (prototype-identical), on-disk library folders and craft/world save/load.
//   ~/Library/Application Support/PlaneWorld/crafts/*.json   (prototype craft JSON)
//   ~/Library/Application Support/PlaneWorld/worlds/*.json   (WorldDocument JSON + optional *.edits.json sidecar)
import Foundation
import PWCore

public enum CraftPresets {
    /// The four built-in presets of reference/flightsim.html, in prototype menu order.
    public static let all: [(name: String, json: String)] = [
        ("Trainer", CraftPresetData.trainer), ("Jet trainer", CraftPresetData.jetTrainer),
        ("Rover", CraftPresetData.rover), ("Sounding rocket", CraftPresetData.soundingRocket),
    ]
    public static func load(_ name: String) -> CraftDocument? {
        all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }.flatMap { try? decode($0.json) }
    }
    public static func documents() -> [CraftDocument] { all.compactMap { try? decode($0.json) } }
    static func decode(_ s: String) throws -> CraftDocument { try JSONIO.decode(CraftDocument.self, from: Data(s.utf8)) }
}

public enum CraftLibrary {
    /// Built-in crafts: bundle JSON resources (App's Resources/Crafts) followed by presets not already present.
    public static func loadBundled(from bundle: Bundle) -> [CraftDocument] {
        let urls = (bundle.urls(forResourcesWithExtension: "json", subdirectory: "Crafts") ?? [])
        var docs = urls.sorted { $0.path < $1.path }.compactMap { try? JSONIO.decode(CraftDocument.self, file: $0) }
        for p in CraftPresets.documents() where !docs.contains(where: { $0.name == p.name }) { docs.append(p) }
        return docs
    }

    /// ~/Library/Application Support/PlaneWorld (created on demand).
    public static var rootURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("PlaneWorld", isDirectory: true)
    }
    public static var craftsURL: URL { folder("crafts") }
    public static var worldsURL: URL { folder("worlds") }
    static func folder(_ n: String) -> URL {
        let u = rootURL.appendingPathComponent(n, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static func fileName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let s = name.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        return (s.isEmpty ? "Untitled" : s) + ".json"
    }

    // Crafts
    public static func listCrafts(in dir: URL? = nil) -> [URL] { list(dir ?? craftsURL) }
    public static func loadCraft(_ url: URL) throws -> CraftDocument { try JSONIO.decode(CraftDocument.self, file: url) }
    @discardableResult public static func saveCraft(_ doc: CraftDocument, to url: URL? = nil) throws -> URL {
        let u = url ?? craftsURL.appendingPathComponent(fileName(doc.name)); try JSONIO.write(doc, to: u); return u
    }
    public static func loadUserCrafts() -> [CraftDocument] { listCrafts().compactMap { try? loadCraft($0) } }

    // Worlds
    public static func listWorlds(in dir: URL? = nil) -> [URL] { list(dir ?? worldsURL).filter { !$0.lastPathComponent.hasSuffix(".edits.json") } }
    public static func loadWorld(_ url: URL) throws -> WorldDocument { try WorldIO.load(url: url) }
    @discardableResult public static func saveWorld(_ doc: WorldDocument, edits: SculptDeltas? = nil, to url: URL? = nil) throws -> URL {
        let u = url ?? worldsURL.appendingPathComponent(fileName(doc.name)); try WorldIO.save(doc, edits: edits, url: u); return u
    }

    static func list(_ dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
