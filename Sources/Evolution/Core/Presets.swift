// OWNED BY architect (JS templates may be polished by the script builder; keep them valid against
// docs/EVOLUTION.md §4). Ship presets: "Neural controller", "Craft design", "Co-evolve design + controller".
import Foundation
import PWCore
import PWPhysics

public enum ExperimentPresets {
    public static let names = ["Neural controller", "Craft design", "Co-evolve design + controller"]

    /// Standard flight sensors added to a craft that has none (names are what scripts read).
    public static func addStandardSensors(_ craft: CraftDocument) -> CraftDocument {
        if craft.parts.contains(where: { $0.partType == .sensor }) { return craft }
        var c = craft
        func sensor(_ id: String, _ name: String, _ kind: SensorKind) -> CraftPart {
            var p = CraftPart(id: id, type: .sensor, name: name)
            p.p["kind"] = .string(kind.rawValue); return p
        }
        c.parts += [sensor("sn-alt", "alt", .altitudeAGL), sensor("sn-att", "att", .attitude), sensor("sn-rate", "rate", .angularRate),
                    sensor("sn-air", "air", .airspeed), sensor("sn-vs", "vs", .verticalSpeed), sensor("sn-aero", "aero", .aero)]
        return c
    }

    static let flightInputScale: [String: Double] = ["alt": 100, "att.pitch": 30, "att.roll": 45, "att.yaw": 180, "rate.roll": 60,
                                                     "rate.pitch": 30, "rate.yaw": 30, "air": 40, "vs": 10, "aero.aoa": 10, "aero.sideslip": 10]

    public static func make(_ name: String, craftName: String = "Trainer") -> ExperimentDocument {
        switch name {
        case "Craft design": return craftDesign(craftName: craftName)
        case "Co-evolve design + controller": return coevolve(craftName: craftName)
        default: return neuralController(craftName: craftName)
        }
    }

    public static func neuralController(craftName: String = "Trainer") -> ExperimentDocument {
        var e = ExperimentDocument()
        e.name = "Neural controller — \(craftName)"
        e.notes = "MLP (sensors → control surfaces + throttle) learns to take off, climb to 150 m AGL and hold wings level."
        e.crafts = [CraftRef(name: craftName)]
        e.world = WorldRef(source: "current")
        e.genome.preset = "neural"
        var m = MLPSpec(); m.hidden = [12]
        m.inputs = ["alt", "att.pitch", "att.roll", "rate.roll", "rate.pitch", "rate.yaw", "air", "vs", "aero.aoa"]
        m.outputs = ["Ailerons", "Elevator", "Rudder", "Engine"]
        m.inputScale = flightInputScale
        e.genome.mlp = m
        e.controller.mode = "mlp"; e.controller.hz = 50
        e.algorithm = AlgorithmParams(kind: "sep-cmaes", values: ["sigma0": .number(0.5)])
        e.population = 64; e.generations = 200
        e.episode.duration = 40; e.episode.episodesPerCandidate = 2
        e.episode.wind.speedMax = 4; e.episode.wind.turbulence = 0.3
        e.rewardTerms = ["altitude", "speed", "level", "crash"]
        e.scripts.source = neuralJS
        return e
    }

    public static func craftDesign(craftName: String = "Trainer") -> ExperimentDocument {
        var e = ExperimentDocument()
        e.name = "Craft design — \(craftName)"
        e.notes = "Evolve wing span/chord, wing position and stabilator size; a scripted PID autopilot flies every design."
        e.crafts = [CraftRef(name: craftName)]
        e.world = WorldRef(source: "current")
        e.genome.preset = "design"; e.genome.mlp = nil
        var span = DesignGene(part: "Wing L", field: "p.span", min: 2.5, max: 6, initial: 4.2); span.mirror = ["Wing R"]
        var chord = DesignGene(part: "Wing L", field: "p.chord", min: 0.8, max: 2.2, initial: 1.5); chord.mirror = ["Wing R"]
        var wx = DesignGene(part: "Wing L", field: "pos.0", min: -0.6, max: 1.4, initial: 0.4); wx.mirror = ["Wing R", "Aileron L", "Aileron R"]
        let stab = DesignGene(part: "Stabilator", field: "p.span", min: 2, max: 4.5, initial: 3.4)
        e.genome.design = [span, chord, wx, stab]
        e.controller.mode = "script"; e.controller.hz = 50
        e.algorithm = AlgorithmParams(kind: "ga", values: ["selection": .string("tournament"), "crossover": .string("sbx"), "mutation": .string("polynomial"), "elitism": .number(2)])
        e.population = 48; e.generations = 60
        e.episode.duration = 45
        e.rewardTerms = ["climb", "efficiency", "crash"]
        e.scripts.source = designJS
        return e
    }

    public static func coevolve(craftName: String = "Trainer") -> ExperimentDocument {
        var e = neuralController(craftName: craftName)
        e.name = "Co-evolve — \(craftName)"
        e.notes = "Design genes (wing span/chord) and MLP controller weights evolved jointly in one genome."
        e.genome.preset = "coevolve"
        var span = DesignGene(part: "Wing L", field: "p.span", min: 2.5, max: 6, initial: 4.2); span.mirror = ["Wing R"]
        var chord = DesignGene(part: "Wing L", field: "p.chord", min: 0.8, max: 2.2, initial: 1.5); chord.mirror = ["Wing R"]
        e.genome.design = [span, chord]
        e.algorithm = AlgorithmParams(kind: "sep-cmaes", values: ["sigma0": .number(0.4)])
        e.scripts.source = neuralJS
        return e
    }

    public static let neuralJS = #"""
    // Neural controller preset. The native MLP (genome → weights) writes ctx.out before control() runs;
    // this script shapes the genome and scores the flight. See docs/EVOLUTION.md §4.
    function terms() { return ["altitude", "speed", "level", "crash"]; }

    // Start every MLP weight at 0 (neutral surfaces, half throttle) and let the optimiser explore with a
    // step of 0.5 per weight. Random ±3 weights saturate the network and the Trainer never leaves the runway.
    function genome(base) {
      base.genes.forEach(function (g) { if (g.group === "mlp") { g.initial = 0; g.sigma = 0.5; } });
      return base;
    }

    function control(ctx) {
      // optional post-processing of the network outputs, e.g. keep the brakes off:
      // ctx.out["Main L motor"] = 0;
    }

    function reward(ctx) {
      const s = ctx.state, dt = ctx.dt;
      return {
        altitude: -Math.min(Math.abs(s.agl - 150) / 150, 1) * dt,
        speed: Math.min(s.airspeed, 45) / 45 * dt * 0.5,
        level: -Math.min(Math.abs(s.roll) / 90, 1) * dt * 0.5,
      };
    }

    function terminate(ctx) { return ctx.state.crashed; }

    function fitness(ctx) {
      const crash = ctx.state.crashed ? -20 : 0;
      return { fitness: ctx.sum.altitude + ctx.sum.speed + ctx.sum.level + crash, terms: { crash: crash } };
    }

    function descriptor(ctx) { return [ctx.state.x / 1000, ctx.state.agl / 300]; }
    """#

    public static let designJS = #"""
    // Craft design preset. Genes are applied natively (genome.design); this script flies every design with
    // a PID autopilot and scores climb per kilogram.
    function terms() { return ["climb", "efficiency", "crash"]; }

    function init(ctx) {
      ctx.memory.pitch = pid(0.08, 0.01, 0.5);
      ctx.memory.roll = pid(0.03, 0.0, 0.2);
    }

    function control(ctx) {
      const s = ctx.state, m = ctx.memory;
      const targetPitch = s.airspeed > 30 ? 8 : 0;
      ctx.out.Engine = 1;
      ctx.out.Elevator = clamp(m.pitch.update(targetPitch - s.pitch, ctx.dt), -1, 1);
      ctx.out.Ailerons = clamp(m.roll.update(-s.roll, ctx.dt), -1, 1);
      ctx.out.Rudder = 0;
    }

    function reward(ctx) { return { climb: Math.max(0, ctx.state.vy) * ctx.dt }; }

    function terminate(ctx) { return ctx.state.crashed; }

    function fitness(ctx) {
      const crash = ctx.state.crashed ? -100 : 0;
      const eff = ctx.state.agl / Math.max(ctx.state.mass, 1) * 100;
      return { fitness: ctx.sum.climb + eff + crash, terms: { efficiency: eff, crash: crash } };
    }
    """#
}
