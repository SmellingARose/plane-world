// OWNED BY import builder. -------------------------------------------------------------------
// Derived outputs: every servo, motor, jet and solid rocket part is one named slider in FLY.
// `prepareForFlight` first gives every unlinked wheel/prop a motor so it, too, has an output.
import Foundation
import PWCore

public enum CraftOutputs {
    /// Outputs of the document as-is, in part order (prototype rules: servo -1…1, motor 0…1 or -1…1 if
    /// reversible, jet 0…1, solid 0…1 igniting above 0.5).
    public static func list(_ doc: CraftDocument) -> [CraftOutput] {
        doc.parts.compactMap { p -> CraftOutput? in
            guard let t = p.partType, t.isOutput else { return nil }
            let linked = doc.parts.filter { $0.servo == p.id || $0.motor == p.id }.count
            func n(_ k: String) -> String { let v = p.param(k); return v == v.rounded() ? String(Int(v)) : String(v) }
            switch t {
            case .servo: return CraftOutput(id: p.id, name: p.name, kind: .servo, range: -1...1, info: "servo ±\(n("range"))° · \(n("torque")) N·m · \(linked) linked")
            case .motor:
                let rev = p.param("reversible") != 0
                return CraftOutput(id: p.id, name: p.name, kind: .motor, range: rev ? -1...1 : 0...1, info: "motor \(n("torque")) N·m · \(rev ? "−1…1" : "0…1") · \(linked) linked")
            case .jet: return CraftOutput(id: p.id, name: p.name, kind: .jet, range: 0...1, info: "jet \(n("thrust")) N")
            case .solid: return CraftOutput(id: p.id, name: p.name, kind: .solid, range: 0...1, info: "solid \(n("thrust")) N × \(n("burn"))s · ignites >50%")
            default: return nil
            }
        }
    }

    /// Copy of `doc` with automatic motors for unlinked wheels/props (what FLY should load).
    public static func prepareForFlight(_ doc: CraftDocument) -> CraftDocument {
        var d = doc; AutoRig.ensureMotorOutputs(&d); return d
    }
    /// Outputs FLY will show for `doc`.
    public static func derive(_ doc: CraftDocument) -> [CraftOutput] { list(prepareForFlight(doc)) }

    /// Parts driven by an output (servo/motor links), for highlighting in BUILD.
    public static func linkedParts(_ doc: CraftDocument, output id: String) -> [CraftPart] {
        doc.parts.filter { $0.servo == id || $0.motor == id }
    }
}
