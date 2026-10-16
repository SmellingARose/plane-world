// OWNED BY script builder. ---------------------------------------------------------------------------
// JavaScriptCore implementation of `ScriptRuntime` (Core/ScriptRuntime.swift); JS API in docs/EVOLUTION.md §4.
//
//  * One JSVirtualMachine + JSContext per instance. Instances are per worker and never used by two threads at
//    once. The prelude (JSPrelude.swift, "prelude.js") and the user source ("user.js", line 1) are evaluated
//    once in `compile`; error line numbers therefore refer to the user source directly.
//  * Hot path: one C-API call per control tick (`__tick`, no arguments). ctx.in/out/reward/sum are JS accessor
//    objects over Float64Arrays created with JSObjectMakeTypedArrayWithBytesNoCopy over the ControlFrame
//    buffers; the ground-truth state, time, tick and episode info live in a runtime-owned scalar Float64Array.
//    Swift writes ~30 doubles per tick and makes no allocation of its own.
//  * Math.random → episode-seeded (or algorithm-seeded) sfc32 generator; Date.now() → sim time in ms.
//  * Watchdog: JSContextGroupSetExecutionTimeLimit (JavaScriptCore SPI, resolved with dlsym). Per-tick hooks get
//    `callBudgetMs`, init/fitness/descriptor/decode 20×, genome/terms/algorithm hooks/top-level code 2 s.
//    A timeout throws ScriptError(timedOut: true); the context stays usable.
//  * nn.create/nn.mlp forward passes run natively (`__native.nnForward`) over typed arrays, no copies.
import Foundation
import JavaScriptCore
import PWCore

// MARK: - watchdog SPI

private typealias JSShouldTerminate = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
private typealias JSSetTimeLimit = @convention(c) (JSContextGroupRef?, Double, JSShouldTerminate?, UnsafeMutableRawPointer?) -> Void
private let jsSetTimeLimit: JSSetTimeLimit? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") else { return nil }
    return unsafeBitCast(sym, to: JSSetTimeLimit.self)
}()
private let watchdogCallback: JSShouldTerminate = { _, info in
    if let info { Unmanaged<WatchdogFlag>.fromOpaque(info).takeUnretainedValue().fired = true }
    return true
}
final class WatchdogFlag { var fired = false }

// MARK: - native functions exposed to JS

final class NativeFn {
    enum Kind { case nnCreate, nnForward, log }
    unowned let runtime: JSScriptRuntime
    let kind: Kind
    init(_ r: JSScriptRuntime, _ k: Kind) { runtime = r; kind = k }
}

/// Native MLP evaluated over a caller-provided weight pointer (genome slice); buffers owned here.
final class NativeNet {
    let sizes: [Int]; let act: UInt8, outAct: UInt8
    let paramCount: Int
    let bufA: UnsafeMutablePointer<Double>, bufB: UnsafeMutablePointer<Double>
    init(sizes: [Int], act: String, outAct: String) {
        self.sizes = sizes; self.act = activationCode(act); self.outAct = activationCode(outAct)
        paramCount = MLPPolicy.parameterCount(sizes)
        let m = sizes.max() ?? 1
        bufA = .allocate(capacity: m); bufB = .allocate(capacity: m)
        bufA.initialize(repeating: 0, count: m); bufB.initialize(repeating: 0, count: m)
    }
    deinit { bufA.deallocate(); bufB.deallocate() }
    /// Same weight layout and arithmetic order as MLPPolicy.forward.
    @inline(__always) func forward(_ weights: UnsafePointer<Double>, _ x: UnsafePointer<Double>, _ y: UnsafeMutablePointer<Double>) {
        var src = x, w = weights
        let L = sizes.count - 1
        for l in 0..<L {
            let nIn = sizes[l], nOut = sizes[l + 1]
            let dst = l == L - 1 ? y : (l % 2 == 0 ? bufA : bufB)
            let a = l == L - 1 ? outAct : act
            let b = w + nOut * nIn
            for o in 0..<nOut {
                var acc = b[o]; let row = w + o * nIn
                for i in 0..<nIn { acc += row[i] * src[i] }
                dst[o] = activate(a, acc)
            }
            w = b + nOut
            src = UnsafePointer(dst)
        }
    }
}

private func jsString(_ s: String) -> JSStringRef { JSStringCreateWithUTF8CString(s) }

private func throwJS(_ ctx: JSContextRef?, _ exception: UnsafeMutablePointer<JSValueRef?>?, _ msg: String) -> JSValueRef? {
    let s = jsString(msg); defer { JSStringRelease(s) }
    var arg: JSValueRef? = JSValueMakeString(ctx, s)
    exception?.pointee = JSObjectMakeError(ctx, 1, &arg, nil)
    return JSValueMakeUndefined(ctx)
}

/// Pointer + element count of a Float64Array argument (view-relative), nil if not a Float64Array.
private func float64Array(_ ctx: JSContextRef?, _ v: JSValueRef?) -> (UnsafeMutablePointer<Double>, Int)? {
    guard let v, JSValueIsObject(ctx, v) else { return nil }
    let o = JSValueToObject(ctx, v, nil)
    guard JSValueGetTypedArrayType(ctx, v, nil) == kJSTypedArrayTypeFloat64Array else { return nil }
    let n = JSObjectGetTypedArrayLength(ctx, o, nil)
    guard let buf = JSObjectGetTypedArrayBuffer(ctx, o, nil), let base = JSObjectGetArrayBufferBytesPtr(ctx, buf, nil) else {
        return n == 0 ? (UnsafeMutablePointer<Double>(bitPattern: 8)!, 0) : nil
    }
    let off = JSObjectGetTypedArrayByteOffset(ctx, o, nil)
    return ((base + off).assumingMemoryBound(to: Double.self), n)
}

private let nativeCallback: JSObjectCallAsFunctionCallback = { ctx, function, _, argc, argv, exception in
    guard let p = JSObjectGetPrivate(function) else { return JSValueMakeUndefined(ctx) }
    let fn = Unmanaged<NativeFn>.fromOpaque(p).takeUnretainedValue()
    func arg(_ i: Int) -> JSValueRef? { i < argc ? argv?[i] : nil }
    switch fn.kind {
    case .nnForward:
        // (handle, weights: Float64Array, offset, x: Float64Array, out: Float64Array)
        let h = Int(JSValueToNumber(ctx, arg(0), nil)), off = JSValueToNumber(ctx, arg(2), nil)
        let nets = fn.runtime.nets
        guard h >= 0 && h < nets.count else { return throwJS(ctx, exception, "nn: invalid network handle") }
        let net = nets[h]
        guard let (w, wn) = float64Array(ctx, arg(1)) else { return throwJS(ctx, exception, "nn.forward: weights must be a Float64Array or array") }
        guard let (x, xn) = float64Array(ctx, arg(3)), let (y, yn) = float64Array(ctx, arg(4)) else { return throwJS(ctx, exception, "nn.forward: bad input/output arrays") }
        guard off.isFinite, off >= 0, off == off.rounded() else { return throwJS(ctx, exception, "nn.forward: offset must be a non-negative integer") }
        let o = Int(off)
        guard o + net.paramCount <= wn else {
            return throwJS(ctx, exception, "nn: network \(net.sizes) needs \(net.paramCount) weights from offset \(o), but only \(wn - min(o, wn)) are available")
        }
        guard xn >= net.sizes[0], yn >= net.sizes.last! else { return throwJS(ctx, exception, "nn: input needs \(net.sizes[0]) values") }
        net.forward(UnsafePointer(w + o), UnsafePointer(x), y)
        return JSValueMakeUndefined(ctx)
    case .nnCreate:
        guard let c = ctx, let jctx = JSContext(jsGlobalContextRef: JSContextGetGlobalContext(c)) else { return JSValueMakeUndefined(ctx) }
        let sizesV = JSValue(jsValueRef: arg(0), in: jctx)
        let sizes = (sizesV?.toArray() ?? []).compactMap { ($0 as? NSNumber)?.intValue }
        guard sizes.count >= 2, sizes.allSatisfy({ $0 >= 1 && $0 <= 4096 }) else {
            return throwJS(ctx, exception, "nn: sizes must be an array of at least 2 positive layer sizes (got \(sizesV?.toString() ?? "?"))")
        }
        let act = JSValue(jsValueRef: arg(1), in: jctx)?.toString() ?? "tanh", outAct = JSValue(jsValueRef: arg(2), in: jctx)?.toString() ?? "tanh"
        for a in [act, outAct] where !["tanh", "relu", "sigmoid", "linear"].contains(a) {
            return throwJS(ctx, exception, "nn: activation '\(a)' unknown (tanh, relu, sigmoid, linear)")
        }
        fn.runtime.nets.append(NativeNet(sizes: sizes, act: act, outAct: outAct))
        return JSValueMakeNumber(ctx, Double(fn.runtime.nets.count - 1))
    case .log:
        guard let c = ctx, let jctx = JSContext(jsGlobalContextRef: JSContextGetGlobalContext(c)) else { return JSValueMakeUndefined(ctx) }
        fn.runtime.emitLog(JSValue(jsValueRef: arg(0), in: jctx)?.toString() ?? "")
        return JSValueMakeUndefined(ctx)
    }
}

private let nativeClass: JSClassRef = {
    var def = kJSClassDefinitionEmpty
    def.className = ("PWNativeFunction" as NSString).utf8String
    def.callAsFunction = nativeCallback
    return JSClassCreate(&def)
}()

// MARK: - shared registries

/// Gene names per (source, genome settings): filled by the orchestrator's genome(base:) so worker runtimes can
/// serve `ctx.genome.get(name)` (workers never call genome()). Used only when the value count matches.
private final class GeneNameRegistry: @unchecked Sendable {
    let lock = NSLock()
    var names: [String: [String]] = [:]
    static let shared = GeneNameRegistry()
    func set(_ k: String, _ v: [String]) { lock.lock(); names[k] = v; lock.unlock() }
    func get(_ k: String) -> [String]? { lock.lock(); defer { lock.unlock() }; return names[k] }
}

final class CompiledScriptBox { let bundle: ScriptBundle; let experiment: ExperimentDocument
    init(_ b: ScriptBundle, _ e: ExperimentDocument) { bundle = b; experiment = e } }

// MARK: - runtime

public final class JSScriptRuntime: ScriptRuntime {
    /// Receives `log(...)` output (rate-limited per runtime). Default: stdout.
    nonisolated(unsafe) public static var logHandler: ((String) -> Void)? = { print("[js] \($0)") }
    /// Max log lines per runtime instance before further output is dropped.
    public var logLimit = 50
    public static let userSourceURL = "user.js"

    let vm: JSVirtualMachine
    let context: JSContext
    let ctxRef: JSGlobalContextRef
    let scalars: UnsafeMutablePointer<Double>
    var genomeBuf: UnsafeMutablePointer<Double>
    var genomeCap = 0
    var nets: [NativeNet] = []
    var natives: [NativeFn] = []
    let watchdog = WatchdogFlag()
    var currentLimit = -1.0
    var hooks = Set<ScriptHook>()
    var compiled = false
    var bundle = ScriptBundle()
    var experiment = ExperimentDocument()
    var registryKey = ""
    var geneNames: [String]? = nil
    var geneNamesBoundCount = -1
    weak var boundFrame: ControlFrame?
    var fnBegin: JSObjectRef?, fnTick: JSObjectRef?
    var tickNeeded = false
    var logged = 0

    var tickBudget: Double { max(0.01, bundle.callBudgetMs) }
    var episodeBudget: Double { tickBudget * 20 }
    static let longBudget = 2000.0

    public init() {
        vm = JSVirtualMachine()
        context = JSContext(virtualMachine: vm)
        ctxRef = context.jsGlobalContextRef
        scalars = .allocate(capacity: JSPrelude.Slot.count); scalars.initialize(repeating: 0, count: JSPrelude.Slot.count)
        genomeBuf = .allocate(capacity: 1); genomeBuf.initialize(to: 0)
        context.exceptionHandler = { c, e in c?.exception = e }
    }
    deinit {
        if let f = fnBegin { JSValueUnprotect(ctxRef, f) }
        if let f = fnTick { JSValueUnprotect(ctxRef, f) }
        // Typed arrays alias these buffers; the context dies with this object (we hold the only references).
        context.exceptionHandler = nil
        scalars.deallocate(); genomeBuf.deallocate()
    }

    /// Whether the JavaScriptCore watchdog SPI is available (it is on every supported macOS).
    public static var watchdogAvailable: Bool { jsSetTimeLimit != nil }

    // MARK: helpers

    func setLimit(_ ms: Double) {
        guard ms != currentLimit, let f = jsSetTimeLimit else { return }
        currentLimit = ms
        f(JSContextGetGroup(ctxRef), ms / 1000, watchdogCallback, Unmanaged.passUnretained(watchdog).toOpaque())
    }

    func emitLog(_ s: String) {
        logged += 1
        if logged <= logLimit { Self.logHandler?(s) } else if logged == logLimit + 1 { Self.logHandler?("(further log output from this worker suppressed)") }
    }

    func makeTypedArray(_ p: UnsafeMutablePointer<Double>, _ n: Int) -> JSValueRef? {
        var exc: JSValueRef?
        return JSObjectMakeTypedArrayWithBytesNoCopy(ctxRef, kJSTypedArrayTypeFloat64Array, p, n * MemoryLayout<Double>.stride, nil, nil, &exc)
    }

    /// Converts a JS exception into a ScriptError (user-source line numbers, hook attribution, timeouts).
    func scriptError(_ exc: JSValue, hook defaultHook: String, budgetMs: Double) -> ScriptError {
        let phase = Int(scalars[JSPrelude.Slot.phase])
        scalars[JSPrelude.Slot.phase] = 0
        let hook = phase > 0 && phase < JSPrelude.phaseHooks.count ? JSPrelude.phaseHooks[phase] : defaultHook
        var line: Int? = nil, column: Int? = nil
        let stack = exc.isObject ? exc.objectForKeyedSubscript("stack")?.toString() : nil
        if exc.isObject, exc.objectForKeyedSubscript("sourceURL")?.toString() == Self.userSourceURL {
            line = exc.objectForKeyedSubscript("line")?.toNumber().map { Int(truncating: $0) }
            column = exc.objectForKeyedSubscript("column")?.toNumber().map { Int(truncating: $0) }
        } else if let st = stack, let r = st.range(of: Self.userSourceURL + ":") {
            let rest = st[r.upperBound...].prefix { $0.isNumber || $0 == ":" }
            let parts = rest.split(separator: ":")
            line = parts.first.flatMap { Int($0) }; column = parts.dropFirst().first.flatMap { Int($0) }
        }
        if watchdog.fired {
            watchdog.fired = false
            return ScriptError(hook: hook, message: "\(hook)() exceeded its time budget of \(budgetMs.formatted()) ms (runaway loop?)",
                               line: line, column: column, stack: stack, timedOut: true)
        }
        var msg = exc.toString() ?? "unknown JavaScript error"
        if msg.hasPrefix("Error: ") { msg.removeFirst(7) }
        return ScriptError(hook: hook, message: msg, line: line, column: column, stack: stack)
    }

    /// Call a prelude function through the Objective-C API (per-episode / per-generation paths only).
    @discardableResult
    func callJS(_ name: String, _ args: [Any], hook: String, budgetMs: Double) throws -> JSValue {
        setLimit(budgetMs); watchdog.fired = false
        context.exception = nil
        guard let fn = context.objectForKeyedSubscript(name) else { throw ScriptError(hook: hook, message: "internal: \(name) missing") }
        let r = fn.call(withArguments: args)
        if let exc = context.exception { context.exception = nil; throw scriptError(exc, hook: hook, budgetMs: budgetMs) }
        return r ?? JSValue(undefinedIn: context)
    }

    @inline(__always) func callC(_ fn: JSObjectRef, hook: String, budgetMs: Double) throws -> JSValueRef? {
        setLimit(budgetMs)
        var exc: JSValueRef?
        let r = JSObjectCallAsFunction(ctxRef, fn, nil, 0, nil, &exc)
        if let exc { throw scriptError(JSValue(jsValueRef: exc, in: context), hook: hook, budgetMs: budgetMs) }
        return r
    }

    func evaluate(_ src: String, url: String, hook: String, budgetMs: Double) throws {
        setLimit(budgetMs); watchdog.fired = false
        let s = jsString(src), u = jsString(url); defer { JSStringRelease(s); JSStringRelease(u) }
        var exc: JSValueRef?
        _ = JSEvaluateScript(ctxRef, s, nil, u, 1, &exc)
        if let exc { throw scriptError(JSValue(jsValueRef: exc, in: context), hook: hook, budgetMs: budgetMs) }
    }

    func installNatives() {
        let obj = JSObjectMake(ctxRef, nil, nil)
        for (name, kind) in [("nnCreate", NativeFn.Kind.nnCreate), ("nnForward", .nnForward), ("log", .log)] {
            let box = NativeFn(self, kind); natives.append(box)
            let f = JSObjectMake(ctxRef, nativeClass, Unmanaged.passUnretained(box).toOpaque())
            let n = jsString(name); JSObjectSetProperty(ctxRef, obj, n, f, JSPropertyAttributes(kJSPropertyAttributeReadOnly), nil); JSStringRelease(n)
        }
        let n = jsString("__native"); JSObjectSetProperty(ctxRef, JSContextGetGlobalObject(ctxRef), n, obj, JSPropertyAttributes(kJSPropertyAttributeDontEnum), nil); JSStringRelease(n)
    }

    func protectedFunction(_ name: String) -> JSObjectRef? {
        guard let v = context.objectForKeyedSubscript(name), v.isObject else { return nil }
        let o = JSValueToObject(ctxRef, v.jsValueRef, nil)
        if let o { JSValueProtect(ctxRef, o) }
        return o
    }

    // MARK: ScriptRuntime

    public func compile(_ bundle: ScriptBundle, experiment: ExperimentDocument) throws {
        _ = ScriptedAlgorithmRegistration.once
        guard !compiled else { throw ScriptError(hook: "compile", message: "a JSScriptRuntime compiles exactly one source; create a new runtime") }
        guard bundle.language.lowercased() == "javascript" || bundle.language.lowercased() == "js" else {
            throw ScriptError(hook: "compile", message: "unsupported script language '\(bundle.language)' (only javascript)")
        }
        self.bundle = bundle; self.experiment = experiment
        installNatives()
        try evaluate(JSPrelude.source, url: "prelude.js", hook: "prelude", budgetMs: Self.longBudget)
        _ = try callJS("__bindScalars", [JSValue(jsValueRef: makeTypedArray(scalars, JSPrelude.Slot.count), in: context)!], hook: "prelude", budgetMs: Self.longBudget)
        try evaluate(bundle.source, url: Self.userSourceURL, hook: "compile", budgetMs: Self.longBudget)
        let names = try callJS("__collect", [], hook: "compile", budgetMs: Self.longBudget).toString() ?? ""
        hooks = Set(names.split(separator: ",").compactMap { ScriptHook(rawValue: String($0)) })
        fnBegin = protectedFunction("__begin"); fnTick = protectedFunction("__tick")
        tickNeeded = !hooks.isDisjoint(with: [.control, .reward, .terminate])
        registryKey = bundle.source + "\u{1}" + ((try? JSONIO.encode(experiment.genome, pretty: false)).map { String(decoding: $0, as: UTF8.self) } ?? "")
            + "\u{1}" + experiment.controller.mode + "\u{1}" + experiment.algorithm.kind
        geneNames = GeneNameRegistry.shared.get(registryKey)
        Thread.current.threadDictionary["PWEvolution.lastCompiledScript"] = CompiledScriptBox(bundle, experiment)
        compiled = true
    }

    public var definedHooks: Set<ScriptHook> { hooks }

    func requireCompiled(_ hook: String) throws { if !compiled { throw ScriptError(hook: hook, message: "script not compiled") } }

    public func genome(base: GenomeLayout) throws -> GenomeLayout {
        try requireCompiled("genome")
        var out = base
        if hooks.contains(.genome) {
            let json = String(decoding: try JSONIO.encode(base, pretty: false), as: UTF8.self)
            let r = try callJS("__callGenome", [json], hook: "genome", budgetMs: Self.longBudget).toString() ?? ""
            do { out = try JSONIO.decode(GenomeLayout.self, from: Data(r.utf8)) }
            catch { throw ScriptError(hook: "genome", message: "genome() returned an invalid layout: \(error)") }
            let dup = Dictionary(grouping: out.genes.map(\.name), by: { $0 }).first { $0.value.count > 1 }
            if let dup { throw ScriptError(hook: "genome", message: "duplicate gene name '\(dup.key)'") }
        }
        geneNames = out.genes.map(\.name)
        GeneNameRegistry.shared.set(registryKey, geneNames!)
        return out
    }

    public func termNames(default d: [String]) throws -> [String] {
        try requireCompiled("terms")
        guard hooks.contains(.terms) else { return d }
        let v = try callJS("__callTerms", [], hook: "terms", budgetMs: Self.longBudget)
        let t = (v.toArray() ?? []).map { "\($0)" }
        if Set(t).count != t.count { throw ScriptError(hook: "terms", message: "terms() returned duplicate names: \(t)") }
        return t
    }

    /// Copies genome values into the runtime-owned Float64Array (rebinding when it grows or names change).
    func loadGenome(_ g: Genome, names: [String]?) throws {
        let n = g.values.count
        let namesToBind = names ?? (geneNames?.count == n ? geneNames : nil)
        if n > genomeCap || n != geneNamesBoundCount || (names != nil && names != geneNames) {
            if n > genomeCap {
                genomeBuf.deallocate(); genomeCap = max(n, 1)
                genomeBuf = .allocate(capacity: genomeCap); genomeBuf.initialize(repeating: 0, count: genomeCap)
            }
            if let names { geneNames = names }
            let arr = JSValue(jsValueRef: makeTypedArray(genomeBuf, n), in: context)!
            try callJS("__bindGenome", [arr, namesToBind.map { $0 as Any } ?? NSNull()], hook: "init", budgetMs: Self.longBudget)
            geneNamesBoundCount = n
        }
        g.values.withUnsafeBufferPointer { if n > 0 { genomeBuf.update(from: $0.baseAddress!, count: n) } }
        scalars[JSPrelude.Slot.genomeID] = Double(g.id)
    }

    public func decode(genome g: Genome, layout: GenomeLayout, craft: CraftDocument) throws -> CraftDocument {
        try requireCompiled("decode")
        guard hooks.contains(.decode) else { return craft }
        try loadGenome(g, names: layout.genes.map(\.name))
        let json = String(decoding: try JSONIO.encode(craft, pretty: false), as: UTF8.self)
        let r = try callJS("__callDecode", [json], hook: "decode", budgetMs: episodeBudget).toString() ?? ""
        do { return try JSONIO.decode(CraftDocument.self, from: Data(r.utf8)) }
        catch { throw ScriptError(hook: "decode", message: "decode() returned something that is not a craft document: \(error)") }
    }

    func bind(_ frame: ControlFrame) throws {
        if boundFrame === frame { return }
        func ta(_ b: UnsafeMutableBufferPointer<Double>) -> JSValue { JSValue(jsValueRef: makeTypedArray(b.baseAddress!, b.count), in: context)! }
        try callJS("__bind", [ta(frame.inputs), ta(frame.outputs), ta(frame.terms), ta(frame.termSums),
                              frame.inputNames, frame.outputNames, frame.termNames, CraftStateSnapshot.fieldNames],
                   hook: "init", budgetMs: Self.longBudget)
        boundFrame = frame
    }

    @inline(__always) func writeState(_ frame: ControlFrame) {
        let S = scalars, s = frame.state, b = JSPrelude.Slot.stateBase
        S[JSPrelude.Slot.t] = s.t; S[JSPrelude.Slot.tick] = Double(frame.tick)
        S[b + 0] = s.t; S[b + 1] = s.x; S[b + 2] = s.y; S[b + 3] = s.z; S[b + 4] = s.vx; S[b + 5] = s.vy; S[b + 6] = s.vz
        S[b + 7] = s.pitch; S[b + 8] = s.roll; S[b + 9] = s.yaw; S[b + 10] = s.rollRate; S[b + 11] = s.pitchRate; S[b + 12] = s.yawRate
        S[b + 13] = s.airspeed; S[b + 14] = s.groundSpeed; S[b + 15] = s.altitude; S[b + 16] = s.agl
        S[b + 17] = s.aoa; S[b + 18] = s.sideslip; S[b + 19] = s.gLoad; S[b + 20] = s.fuel; S[b + 21] = s.mass; S[b + 22] = s.thrust
        S[b + 23] = s.distance; S[b + 24] = s.crashed ? 1 : 0; S[b + 25] = s.contact ? 1 : 0; S[b + 26] = s.impactSpeed
    }

    public func beginEpisode(genome g: Genome, frame: ControlFrame) throws {
        try requireCompiled("init")
        try bind(frame)
        try loadGenome(g, names: nil)
        let S = scalars, i = frame.info
        S[JSPrelude.Slot.dt] = i.controlDt; S[JSPrelude.Slot.generation] = Double(i.generation)
        S[JSPrelude.Slot.candidate] = Double(i.candidate); S[JSPrelude.Slot.episode] = Double(i.episode)
        S[JSPrelude.Slot.seedLo] = Double(UInt32(truncatingIfNeeded: i.seed)); S[JSPrelude.Slot.seedHi] = Double(UInt32(truncatingIfNeeded: i.seed >> 32))
        S[JSPrelude.Slot.duration] = i.duration; S[JSPrelude.Slot.doneReason] = 0
        writeState(frame)
        watchdog.fired = false
        _ = try callC(fnBegin!, hook: "init", budgetMs: episodeBudget)
    }

    public func tick(_ frame: ControlFrame) throws {
        guard tickNeeded else { return }
        writeState(frame)
        let r = try callC(fnTick!, hook: "control", budgetMs: tickBudget)
        if JSValueToNumber(ctxRef, r, nil) != 0 { frame.done = true }
    }

    public func endEpisode(_ frame: ControlFrame) throws -> EpisodeOutcome {
        try requireCompiled("fitness")
        guard hooks.contains(.fitness) || hooks.contains(.descriptor) else { return EpisodeOutcome() }
        writeState(frame)
        scalars[JSPrelude.Slot.doneReason] = Double(JSPrelude.doneReasons.firstIndex(of: frame.doneReason) ?? 0)
        let r = try callJS("__end", [], hook: "fitness", budgetMs: episodeBudget)
        var out = EpisodeOutcome()
        if let f = r.objectForKeyedSubscript("fitness"), !f.isNull, !f.isUndefined { out.fitness = f.toDouble() }
        if let t = r.objectForKeyedSubscript("terms"), t.isObject, let d = t.toDictionary() {
            for (k, v) in d { if let k = k as? String, let n = v as? NSNumber { out.terms[k] = n.doubleValue } }
        }
        if let d = r.objectForKeyedSubscript("descriptor"), d.isArray { out.descriptor = (d.toArray() ?? []).map { ($0 as? NSNumber)?.doubleValue ?? .nan } }
        return out
    }

    // MARK: algorithm hooks (orchestrator thread)

    struct PopEntry: Encodable {
        var id: UInt64; var values: [Double]; var fitness: Double; var terms: [String: Double]
        var descriptor: [Double]?; var novelty: Double?; var error: String?; var origin: String; var generation: Int
    }
    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"); return e
    }()
    func popJSON(_ pop: [Genome], _ fit: [Fitness]) throws -> String {
        let es = zip(pop, fit).map { g, f in PopEntry(id: g.id, values: g.values, fitness: f.total, terms: f.terms, descriptor: f.descriptor, novelty: f.novelty,
                                                      error: f.error, origin: g.origin, generation: g.generation) }
        return String(decoding: try Self.encoder.encode(es), as: UTF8.self)
    }
    func genomeJSON(_ g: Genome) throws -> String {
        String(decoding: try Self.encoder.encode(PopEntry(id: g.id, values: g.values, fitness: 0, terms: [:], descriptor: nil, novelty: nil, error: nil,
                                                         origin: g.origin, generation: g.generation)), as: UTF8.self)
    }
    func layoutJSON(_ l: GenomeLayout) throws -> String { String(decoding: try JSONIO.encode(l, pretty: false), as: UTF8.self) }
    static func seedArgs(_ rng: inout EvoRNG) -> [Any] { let x = rng.next(); return [Double(UInt32(truncatingIfNeeded: x)), Double(UInt32(truncatingIfNeeded: x >> 32))] }
    func doubles(_ v: JSValue, hook: String) throws -> [Double]? {
        if v.isNull || v.isUndefined { return nil }
        return (v.toArray() ?? []).map { ($0 as? NSNumber)?.doubleValue ?? .nan }
    }

    func select(population: [Genome], fitness: [Fitness], count: Int, rng: inout EvoRNG) throws -> [Int]? {
        guard hooks.contains(.select) else { return nil }
        let v = try callJS("__callSelect", [try popJSON(population, fitness), count] + Self.seedArgs(&rng), hook: "select", budgetMs: Self.longBudget)
        guard let d = try doubles(v, hook: "select") else { return nil }
        let idx = d.map { Int(exactly: $0) ?? -1 }
        if let bad = idx.first(where: { $0 < 0 || $0 >= population.count }) {
            throw ScriptError(hook: "select", message: "select() returned index \(bad) outside 0..<\(population.count)")
        }
        return idx
    }
    func crossover(_ a: Genome, _ b: Genome, layout: GenomeLayout, rng: inout EvoRNG) throws -> [Double]? {
        guard hooks.contains(.crossover) else { return nil }
        let v = try callJS("__callCrossover", [try genomeJSON(a), try genomeJSON(b), try layoutJSON(layout)] + Self.seedArgs(&rng), hook: "crossover", budgetMs: Self.longBudget)
        return try checkedVector(v, layout, "crossover")
    }
    func mutate(_ g: Genome, layout: GenomeLayout, rate: Double, rng: inout EvoRNG) throws -> [Double]? {
        guard hooks.contains(.mutate) else { return nil }
        let v = try callJS("__callMutate", [try genomeJSON(g), try layoutJSON(layout), rate] + Self.seedArgs(&rng), hook: "mutate", budgetMs: Self.longBudget)
        return try checkedVector(v, layout, "mutate")
    }
    func checkedVector(_ v: JSValue, _ layout: GenomeLayout, _ hook: String) throws -> [Double]? {
        guard var d = try doubles(v, hook: hook) else { return nil }
        if d.count != layout.count { throw ScriptError(hook: hook, message: "\(hook)() returned \(d.count) genes, layout has \(layout.count)") }
        layout.legalize(&d)
        return d
    }

    /// Custom algorithm: returns (new state JSON, gene vectors).
    func ask(state: String, layout: GenomeLayout, info: String, rng: inout EvoRNG) throws -> (String, [[Double]]) {
        let r = try callJS("__callAsk", [state, try layoutJSON(layout), info] + Self.seedArgs(&rng), hook: "ask", budgetMs: Self.longBudget).toString() ?? ""
        struct R: Decodable { var state: String; var values: [[Double]] }
        do { let x = try JSONIO.decode(R.self, from: Data(r.utf8)); return (x.state, x.values) }
        catch { throw ScriptError(hook: "ask", message: "ask() result could not be read: \(error)") }
    }
    func tell(state: String, population: [Genome], fitness: [Fitness], rng: inout EvoRNG) throws -> String {
        try callJS("__callTell", [state, try popJSON(population, fitness)] + Self.seedArgs(&rng), hook: "tell", budgetMs: Self.longBudget).toString() ?? "{}"
    }
}
