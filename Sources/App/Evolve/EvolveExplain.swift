// EVOLVE explanations: which numbers the genetic algorithm mutates in each mode, and what the controller sees/drives.
import SwiftUI
import PWCore

/// Small flow diagram: genome contents for the chosen mode → one generation's loop.
struct EvolveModeDiagram: View {
    let mode: String          // neural | design | coevolve | script
    let weightCount: Int
    let designCount: Int
    let inputs: Int
    let outputs: Int

    private var brain: Bool { mode == "neural" || mode == "coevolve" }
    private var body_: Bool { mode == "design" || mode == "coevolve" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Genome (the numbers that get mutated)").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if brain { chip("\(weightCount) weights & biases", "brain.head.profile", .purple) }
                if body_ { chip("\(designCount) craft parameters", "airplane", .orange) }
                if mode == "script" { chip("genes from genome()", "curlybraces", .gray) }
            }
            Text(explanation).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            // One generation
            HStack(spacing: 3) {
                step("Random start", "dice")
                arrow
                step("Fly each", "airplane.departure")
                arrow
                step("Score", "chart.bar")
                arrow
                step("Keep best", "trophy")
                arrow
                step("Mutate + mix", "arrow.triangle.branch")
            }
            HStack { Spacer(); Label("repeat each generation", systemImage: "arrow.uturn.backward").font(.caption2).foregroundStyle(.tertiary) }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    private var explanation: String {
        switch mode {
        case "neural": return "Controller mode: the craft is identical for every candidate. Each candidate is a neural network (\(inputs) sensor inputs → \(outputs) outputs); mutation adds random noise to its weights and biases, and the best fliers go forward."
        case "design": return "Craft mode: no neural network is evolved. Each candidate is a different version of the craft — mutation adds random noise to part sizes, positions, masses, thrust… within their ranges — flown by the same fixed controller. The best designs go forward."
        case "coevolve": return "Both: each candidate is a craft and its controller in one genome. Mutation changes body and brain together, so the controller learns to fly the body it is evolving."
        default: return "Custom: your genome() script defines the genes and decode()/control() decide what they mean."
        }
    }

    private func chip(_ t: String, _ icon: String, _ c: Color) -> some View {
        Label(t, systemImage: icon).font(.caption.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(c.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(c)
    }
    private func step(_ t: String, _ icon: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.caption)
            Text(t).font(.system(size: 9)).multilineTextAlignment(.center).lineLimit(2)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 4)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
    }
    private var arrow: some View { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary) }
}

/// "What the controller sees / drives": every sensor input with meaning and unit, every output with its range.
struct ControllerIOTable: View {
    let inputs: [CraftInput]
    let outputs: [CraftOutput]
    /// Inputs the neural network actually uses (nil = not a neural mode).
    let used: Set<String>?

    var body: some View {
        DisclosureGroup("Controller sees \(inputs.count) inputs · drives \(outputs.count) outputs") {
            VStack(alignment: .leading, spacing: 3) {
                Text("Inputs (sensors)").font(.caption.bold()).padding(.top, 2)
                if inputs.isEmpty { Text("This craft has no sensors — add sensor parts in BUILD.").font(.caption2).foregroundStyle(.secondary) }
                ForEach(inputs) { i in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: used == nil || used!.contains(i.name) ? "checkmark.circle.fill" : "circle")
                            .font(.caption2).foregroundStyle(used == nil || used!.contains(i.name) ? Color.accentColor : .secondary)
                            .help(used == nil ? "" : (used!.contains(i.name) ? "Fed to the network" : "Not used by the network"))
                        Text(i.name).font(.caption.monospaced())
                        Spacer()
                        Text(Self.meaning(i)).font(.caption2).foregroundStyle(.secondary)
                        Text(i.unit).font(.caption2.monospaced()).foregroundStyle(.tertiary).frame(minWidth: 36, alignment: .trailing)
                    }
                }
                Text("Outputs (what it controls)").font(.caption.bold()).padding(.top, 4)
                ForEach(outputs) { o in
                    HStack {
                        Text(o.name).font(.caption.monospaced())
                        Spacer()
                        Text(o.kind.rawValue).font(.caption2).foregroundStyle(.secondary)
                        Text(String(format: "%g…%g", o.range.lowerBound, o.range.upperBound)).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .font(.callout)
    }

    static func meaning(_ i: CraftInput) -> String {
        switch (i.kind, i.channel) {
        case ("attitude", "pitch"): return "pitch angle"
        case ("attitude", "roll"): return "roll (bank) angle"
        case ("attitude", "yaw"): return "heading"
        case ("angularRate", let c): return "\(c) rotation rate"
        case ("altitudeAGL", _): return "height above ground"
        case ("altitudeMSL", _): return "altitude above sea level"
        case ("airspeed", _): return "speed through the air"
        case ("groundSpeed", _): return "speed over ground"
        case ("verticalSpeed", _): return "climb / sink rate"
        case ("acceleration", let c): return c == "g" ? "load factor" : "acceleration \(c)"
        case ("aero", "aoa"): return "angle of attack"
        case ("aero", "sideslip"): return "sideslip angle"
        case ("target", "dx"): return "target offset x (fwd)"
        case ("target", "dy"): return "target offset y (up)"
        case ("target", "dz"): return "target offset z (right)"
        case ("target", "distance"): return "distance to target"
        case ("target", "bearing"): return "bearing to target"
        case ("target", "elevation"): return "elevation to target"
        case ("raycast", _): return "distance along ray"
        case ("servoAngle", _): return "servo position"
        case ("wheelSpeed", _): return "wheel rim speed"
        case ("fuel", _): return "fuel remaining"
        case ("water", let c): return c == "depth" ? "depth in water" : "in water?"
        case ("contact", let c): return c == "crashed" ? "crashed?" : "touching ground?"
        default: return i.kind
        }
    }
}
