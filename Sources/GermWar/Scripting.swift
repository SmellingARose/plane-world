// Live modding for the native build:
//   - mods/*.js run in JavaScriptCore (built into macOS) and declare all content through `GW.type`
//   - the mods folder is polled; a saved file is re-evaluated in the running game, no restart
//   - a tiny HTTP server on :8787 runs JS sent to POST /eval and returns the result,
//     so Claude can inspect and command a running game:  curl -s localhost:8787/eval -d 'GW.money += 1000'
import Foundation
import JavaScriptCore
import Network
import PWCore

final class Scripting {
    let ctx: JSContext
    unowned let game: Game
    let modsDir: URL
    private var mtimes: [String: Date] = [:]
    private var timer: Timer?
    private var listener: NWListener?
    private(set) var serverPort: UInt16 = 0
    var lastError: String?

    init(game: Game) {
        self.game = game
        ctx = JSContext()!
        ctx.name = "GermWar"
        modsDir = Scripting.findMods()
        installNatives()
    }

    static func findMods() -> URL {
        if let env = ProcessInfo.processInfo.environment["GERMWAR_MODS"] { return URL(fileURLWithPath: env) }
        // Prefer the source tree so edits to Sources/GermWar/mods hot-reload while developing.
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("mods")
        if FileManager.default.fileExists(atPath: src.path) { return src }
        return Bundle.module.resourceURL!.appendingPathComponent("mods")
    }

    // MARK: natives

    private func installNatives() {
        ctx.exceptionHandler = { [weak self] _, ex in
            let msg = ex?.toString() ?? "error"
            let line = ex?.objectForKeyedSubscript("line")?.toString() ?? "?"
            let src = ex?.objectForKeyedSubscript("sourceURL")?.toString() ?? ""
            self?.lastError = "\((src as NSString).lastPathComponent):\(line) \(msg)"
            self?.game.toast("⚠ \(self?.lastError ?? msg)")
            print("[JS] \(self?.lastError ?? msg)")
        }
        let g = game
        func fn(_ name: String, _ block: Any) { ctx.setObject(block, forKeyedSubscript: name as NSString) }
        let type: @convention(block) (String, String) -> Void = { name, json in
            guard let data = json.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            g.defs.upsert(TypeDef.from(name: name, json: obj, base: g.defs.def(name)))
        }
        let spawn: @convention(block) (String, Double, Double) -> Int = { name, x, z in
            Int(g.sim.spawn(name, Vec2(Float(x), Float(z))).idx)
        }
        let spawnBase: @convention(block) (String) -> Int = { Int(g.sim.spawnBase($0).idx) }
        let get: @convention(block) (String) -> Any = { k in g.value(k) }
        let set: @convention(block) (String, JSValue) -> Void = { k, v in g.setValue(k, v) }
        let count: @convention(block) (String) -> Int = { g.sim.count($0 == "them" ? .them : .us) }
        let ents: @convention(block) (String) -> [[String: Any]] = { side in
            g.sim.ents.enumerated().compactMap { i, e in
                guard e.alive, side.isEmpty || (side == "them") == (e.side == .them) else { return nil }
                return ["id": i, "type": g.defs[Int(e.type)].name, "x": Double(e.pos.x), "z": Double(e.pos.z), "hp": Double(e.hp), "lvl": Int(e.lvl)]
            }
        }
        let kill: @convention(block) (Int) -> Void = { i in if i >= 0, i < g.sim.ents.count { g.sim.kill(i) } }
        let order: @convention(block) (Int, Double, Double) -> Void = { i, x, z in
            guard i >= 0, i < g.sim.ents.count, g.sim.ents[i].alive else { return }
            if g.sim.ents[i].side == .them { g.sim.ents[i].orderKind = 1; g.sim.ents[i].orderP = Vec2(Float(x), Float(z)) }
            else { g.sim.ents[i].hasDest = true; g.sim.ents[i].dest = Vec2(Float(x), Float(z)) }
        }
        let attack: @convention(block) (Int, Int) -> Void = { i, t in
            guard i >= 0, i < g.sim.ents.count, t >= 0, t < g.sim.ents.count else { return }
            g.sim.ents[i].orderKind = 2; g.sim.ents[i].orderRef = g.sim.ref(t)
        }
        let toast: @convention(block) (String) -> Void = { g.toast($0) }
        let restart: @convention(block) () -> Void = { g.restart() }
        let stats: @convention(block) () -> [String: Any] = {
            var s: [String: Any] = ["threads": g.sim.threads, "entities": g.sim.aliveCount, "stepMs": g.sim.lastStepMs, "fps": g.fps]
            for (k, v) in JobSystem.shared.stats.snapshot() { s[k] = v }
            return s
        }
        fn("_type", type); fn("_spawn", spawn); fn("_spawnBase", spawnBase); fn("_get", get); fn("_set", set)
        fn("_count", count); fn("_ents", ents); fn("_kill", kill); fn("_order", order); fn("_attack", attack)
        fn("_toast", toast); fn("_restart", restart); fn("_stats", stats)
        ctx.evaluateScript("""
        var GW = { director: null,
          type: function(n, d){ _type(n, JSON.stringify(d)); },
          spawn: _spawn, spawnBase: _spawnBase, count: _count, ents: _ents, kill: _kill,
          order: _order, attack: _attack, toast: _toast, restart: _restart, stats: _stats };
        ['money','bio','wave','waveT','paused','speed','god','aiWaves','autoBuilders','strategy','buildPref','time','kills','mode'].forEach(function(k){
          Object.defineProperty(GW, k, { get: function(){ return _get(k); }, set: function(v){ _set(k, v); } });
        });
        """)
    }

    // MARK: mods

    func loadAll() {
        for f in modFiles() { load(f) }
    }
    private func modFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: modsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "js" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    @discardableResult
    func load(_ url: URL) -> Bool {
        guard let src = try? String(contentsOf: url, encoding: .utf8) else { return false }
        mtimes[url.lastPathComponent] = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        lastError = nil
        ctx.evaluateScript(src, withSourceURL: url)
        return lastError == nil
    }
    func startWatching() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.poll() }
    }
    private func poll() {
        for f in modFiles() {
            let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if m != mtimes[f.lastPathComponent] { if load(f) { game.toast("🔧 Live update: \(f.lastPathComponent)") } }
        }
    }

    /// Called by the game loop (~10 Hz) so JS can run wave logic.
    func director(_ dt: Double) {
        guard let d = ctx.objectForKeyedSubscript("GW")?.objectForKeyedSubscript("director"), !d.isNull, !d.isUndefined else { return }
        d.call(withArguments: [dt])
    }

    func eval(_ code: String) -> String {
        lastError = nil
        guard let v = ctx.evaluateScript(code) else { return lastError ?? "undefined" }
        if let e = lastError { return "Error: \(e)" }
        if v.isUndefined { return "undefined" }
        if v.isObject, let j = ctx.objectForKeyedSubscript("JSON")?.invokeMethod("stringify", withArguments: [v, NSNull(), 1]), j.isString { return j.toString() }
        return v.toString()
    }

    // MARK: HTTP server

    func startServer(port: UInt16 = 8787) {
        guard let p = NWEndpoint.Port(rawValue: port), let l = try? NWListener(using: .tcp, on: p) else { print("[GermWar] port \(port) unavailable"); return }
        l.newConnectionHandler = { [weak self] c in c.start(queue: .global(qos: .userInitiated)); self?.receive(c, Data()) }
        l.stateUpdateHandler = { [weak self] s in if case .ready = s { self?.serverPort = port; print("[GermWar] live server on http://localhost:\(port)") } }
        l.start(queue: .global(qos: .userInitiated))
        listener = l
    }
    private func receive(_ c: NWConnection, _ acc: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { c.cancel(); return }
            var buf = acc; if let data { buf.append(data) }
            if let req = HTTPRequest(buf) { self.handle(req, c); return }
            if done || err != nil { c.cancel(); return }
            self.receive(c, buf)
        }
    }
    private func handle(_ r: HTTPRequest, _ c: NWConnection) {
        func reply(_ s: String, _ type: String = "text/plain") {
            let body = Data((s.hasSuffix("\n") ? s : s + "\n").utf8)
            var h = "HTTP/1.1 200 OK\r\nContent-Type: \(type); charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".data(using: .utf8)!
            h.append(body)
            c.send(content: h, completion: .contentProcessed { _ in c.cancel() })
        }
        switch (r.method, r.path) {
        case ("POST", "/eval"):
            DispatchQueue.main.async { reply(self.eval(r.body)) }
        case ("GET", "/state"):
            DispatchQueue.main.async { reply(self.eval("JSON.stringify({money:GW.money|0,bio:GW.bio|0,wave:GW.wave,stats:GW.stats()})")) }
        default:
            reply("Germ War live server\nPOST /eval   run JavaScript in the game (GW.*)\nGET  /state  quick status\n")
        }
    }
}

struct HTTPRequest {
    var method = "", path = "", body = ""
    init?(_ d: Data) {
        guard let range = d.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: d[..<range.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return nil }
        method = String(first[0]); path = String(first[1])
        var len = 0
        for l in lines.dropFirst() where l.lowercased().hasPrefix("content-length:") { len = Int(l.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0 }
        let bodyData = d[range.upperBound...]
        guard bodyData.count >= len else { return nil }
        body = String(decoding: bodyData.prefix(len), as: UTF8.self)
    }
}
