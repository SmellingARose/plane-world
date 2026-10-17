// Keyboard bindings for craft outputs (FLY tab).
//
// Each output part may carry `"keys": { "pos": "w", "neg": "s", "mode": "spring" | "ramp", "rate": 1.5 }`
// in its JSON (stored in CraftPart.extra, so older files and other tools round-trip unchanged).
//   spring — holding a key drives the output toward its max (pos) / min (neg) at `rate` per second; released,
//            it returns toward its rest value (0, or the range minimum when 0 is outside the range).
//   ramp   — holding a key moves the output at `rate` per second; released, it stays (throttle style).
import AppKit
import SwiftUI
import PWCore

struct OutputKeybind: Equatable {
    enum Mode: String, CaseIterable, Identifiable { case spring, ramp; var id: String { rawValue } }
    var pos: String? = nil
    var neg: String? = nil
    var mode: Mode = .spring
    var rate: Double = 3

    init(pos: String? = nil, neg: String? = nil, mode: Mode = .spring, rate: Double = 3) { self.pos = pos; self.neg = neg; self.mode = mode; self.rate = rate }

    init?(_ v: JSONValue?) {
        guard case .object(let o)? = v else { return nil }
        pos = o["pos"]?.string; neg = o["neg"]?.string
        mode = Mode(rawValue: o["mode"]?.string ?? "spring") ?? .spring
        rate = o["rate"]?.double ?? (mode == .ramp ? 0.8 : 3)
    }
    var json: JSONValue {
        var o: [String: JSONValue] = ["mode": .string(mode.rawValue), "rate": .number(rate)]
        if let pos { o["pos"] = .string(pos) }
        if let neg { o["neg"] = .string(neg) }
        return .object(o)
    }
    var isEmpty: Bool { pos == nil && neg == nil }
    var label: String { isEmpty ? "—" : "\(KeyNames.display(pos)) / \(KeyNames.display(neg))" }
}

extension CraftPart {
    var keybind: OutputKeybind? {
        get { OutputKeybind(extra["keys"]) }
        set { if let k = newValue, !k.isEmpty { extra["keys"] = k.json } else { extra["keys"] = nil } }
    }
}

/// Key names <-> macOS virtual key codes. Letters/digits use their character; special keys use names.
enum KeyNames {
    static let special: [String: UInt16] = ["up": 126, "down": 125, "left": 123, "right": 124, "space": 49, "tab": 48,
                                            "return": 36, "[": 33, "]": 30, ";": 41, "'": 39, ",": 43, ".": 47, "/": 44,
                                            "-": 27, "=": 24]
    static let letters: [String: UInt16] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
                                            "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
                                            "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35,
                                            "l": 37, "j": 38, "k": 40, "n": 45, "m": 46]
    /// Keys the FLY tab uses as shortcuts (reset, pause, camera, equations). Binding one hides that shortcut for this craft.
    static let reserved: Set<String> = ["r", "p", "c", "e"]
    static func code(_ name: String?) -> UInt16? {
        guard let n = name?.lowercased() else { return nil }
        return letters[n] ?? special[n]
    }
    static func name(for code: UInt16) -> String? {
        if let n = letters.first(where: { $0.value == code })?.key { return n }
        return special.first(where: { $0.value == code })?.key
    }
    static func display(_ name: String?) -> String {
        guard let n = name else { return "·" }
        switch n { case "up": return "↑"; case "down": return "↓"; case "left": return "←"; case "right": return "→"
        case "space": return "Space"; case "tab": return "⇥"; case "return": return "↩"; default: return n.uppercased() }
    }
}

@MainActor
extension AppModel {
    /// Advance keyboard-driven outputs by dt given the currently held key codes.
    func applyOutputKeybinds(held: Set<UInt16>, dt: Double) {
        for o in outputs {
            guard let kb = craft.part(o.id)?.keybind, !kb.isEmpty else { continue }
            let up = KeyNames.code(kb.pos).map { held.contains($0) } ?? false
            let down = KeyNames.code(kb.neg).map { held.contains($0) } ?? false
            let lo = o.range.lowerBound, hi = o.range.upperBound
            var v = o.value
            switch kb.mode {
            case .ramp:
                if up != down { v += (up ? 1 : -1) * kb.rate * (hi - lo) * dt }
            case .spring:
                let rest = (lo...hi).contains(0) ? 0 : lo
                let target = up && !down ? hi : (down && !up ? lo : rest)
                let step = kb.rate * (hi - lo) * dt
                v += max(-step, min(step, target - v))
            }
            v = min(hi, max(lo, v))
            if v != o.value { setOutput(o.id, v) }
        }
    }

    func isOutputKey(_ code: UInt16) -> Bool {
        outputs.contains { o in
            guard let kb = craft.part(o.id)?.keybind else { return false }
            return KeyNames.code(kb.pos) == code || KeyNames.code(kb.neg) == code
        }
    }

    func setKeybind(_ partID: String, _ kb: OutputKeybind?) {
        guard let i = craft.parts.firstIndex(where: { $0.id == partID }) else { return }
        craft.parts[i].keybind = kb
    }
}

/// A small button that captures the next key press as a binding.
final class KeyCaptureState: ObservableObject {
    @Published var listening = false
    var monitor: Any?
    func stop() { listening = false; if let m = monitor { NSEvent.removeMonitor(m) }; monitor = nil }
}

struct KeyCaptureButton: View {
    let current: String?
    let onSet: (String?) -> Void
    @StateObject private var cap = KeyCaptureState()
    var body: some View {
        Button(cap.listening ? "press…" : KeyNames.display(current)) {
            if cap.listening { cap.stop(); return }
            cap.listening = true
            let cap = cap, onSet = onSet
            cap.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                if e.keyCode == 53 { onSet(nil) }                     // Esc clears
                else if let n = KeyNames.name(for: e.keyCode) { onSet(n) }
                cap.stop(); return nil
            }
        }
        .controlSize(.small)
        .frame(minWidth: 44)
        .help("Click, then press a key (Esc clears). Binding R, P, C or E hides that FLY shortcut (reset, pause, camera, equations) for this craft.")
    }
}

/// Editor row used in BUILD's output list.
struct KeybindEditor: View {
    @EnvironmentObject var model: AppModel
    let output: CraftOutput
    var body: some View {
        let kb = model.craft.part(output.id)?.keybind ?? OutputKeybind(mode: output.kind == .servo ? .spring : .ramp,
                                                                      rate: output.kind == .servo ? 3 : 0.8)
        let conflict = [kb.pos, kb.neg].compactMap { $0 }.contains { KeyNames.reserved.contains($0) }
        HStack(spacing: 4) {
            Image(systemName: "keyboard").foregroundStyle(.secondary).font(.caption)
            KeyCaptureButton(current: kb.pos) { n in var k = kb; k.pos = n; model.setKeybind(output.id, k) }
                .help("Key that pushes \(output.name) toward its maximum")
            Text("+").font(.caption2).foregroundStyle(.secondary)
            KeyCaptureButton(current: kb.neg) { n in var k = kb; k.neg = n; model.setKeybind(output.id, k) }
                .help("Key that pushes \(output.name) toward its minimum")
            Text("−").font(.caption2).foregroundStyle(.secondary)
            Picker("", selection: Binding(get: { kb.mode }, set: { m in var k = kb; k.mode = m; k.rate = m == .ramp ? 0.8 : 3; model.setKeybind(output.id, k) })) {
                Text("spring").tag(OutputKeybind.Mode.spring)
                Text("ramp").tag(OutputKeybind.Mode.ramp)
            }
            .labelsHidden().controlSize(.small).frame(width: 78)
            .help("spring: returns to rest when released (stick/rudder). ramp: stays where you leave it (throttle).")
            if conflict { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help("This key is also a FLY shortcut (R reset, P pause, C camera, E equations); the binding wins for this craft") }
        }
    }
}
