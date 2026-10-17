// OWNED BY integrator. Headless training CLI (no window, no GPU needed for flat/inline/file worlds).
//   PlaneWorld --train <experiment.json> [--generations N] [--out <dir>] [--workers N] [--population N] [--seed N]
//   PlaneWorld --make-experiment "<preset name>" <out.json> [--craft <name>]
// Prints one line per generation and writes history.csv, a checkpoint and best-craft.json into --out.
// World source "current" has no live app here and falls back to the flat world (stated in the output).
import Foundation
import PWCore
import PWPhysics
import PWCraft
import PWEvolution

enum TrainCLI {
    static func value(_ args: [String], _ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func resolveCraft(_ ref: CraftRef?, experimentURL: URL?) -> CraftDocument? {
        var doc: CraftDocument? = ref?.inline
        if doc == nil, let p = ref?.path {
            let base = experimentURL?.deletingLastPathComponent()
            let url = p.hasPrefix("/") ? URL(fileURLWithPath: p) : (base?.appendingPathComponent(p) ?? URL(fileURLWithPath: p))
            doc = try? JSONIO.decode(CraftDocument.self, file: url)
        }
        if doc == nil {
            let name = ref?.name ?? "Trainer"
            let lib = CraftLibrary.loadBundled(from: .module) + CraftLibrary.loadUserCrafts()
            doc = lib.first { $0.name == name } ?? (name == "Trainer" ? PhysicsPresets.trainer() : nil)
        }
        return doc.map { CraftOutputs.prepareForFlight(ExperimentPresets.addStandardSensors($0)) }
    }

    static func makeExperiment(_ args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--make-experiment"), i + 2 < args.count else {
            print("usage: PlaneWorld --make-experiment \"<preset>\" <out.json>   presets: \(ExperimentPresets.names)"); return 2
        }
        let e = ExperimentPresets.make(args[i + 1], craftName: value(args, "--craft") ?? "Trainer")
        do { try e.save(URL(fileURLWithPath: args[i + 2])); print("wrote \(args[i + 2])"); return 0 }
        catch { print("error: \(error)"); return 1 }
    }

    static func run(_ args: [String]) -> Int32 {
        ScriptedAlgorithmRegistration.register()
        guard let path = value(args, "--train") else { print("usage: PlaneWorld --train <experiment.json> [--generations N] [--out dir] [--resume] [--current-as-flat] [--aero fast|full] [--cfd-preset draft|medium|high|ultra]"); return 2 }
        let url = URL(fileURLWithPath: path)
        do {
            var e = try ExperimentDocument.load(url)
            if let g = value(args, "--generations").flatMap(Int.init) { e.generations = g }
            if let w = value(args, "--workers").flatMap(Int.init) { e.workers = w }
            if let p = value(args, "--population").flatMap(Int.init) { e.population = p }
            if let s = value(args, "--seed").flatMap(UInt64.init) { e.seed = s }
            if let a = value(args, "--aero") {
                guard let m = AeroModel(rawValue: a) else { print("error: --aero must be fast or full"); return 2 }
                e.aero.model = m
            }
            if let pr = value(args, "--cfd-preset") {
                guard let p = CFDQualityPreset(rawValue: pr) else { print("error: --cfd-preset must be one of \(CFDQualityPreset.allCases.map(\.rawValue))"); return 2 }
                e.aero.cfd = CFDSettings.preset(p)
            }
            guard let craft = resolveCraft(e.crafts.first, experimentURL: url) else { print("error: craft not found"); return 1 }
            if e.world.source == "current" && !args.contains("--current-as-flat") {
                print("error: world source 'current' means the world open in the app, which the CLI cannot see.")
                print("       Set world.source to \"file\" (world.path) or \"inline\" (world.inline), or pass --current-as-flat to train on the flat world.")
                return 1
            }
            let world = try HeadlessWorld.resolve(e.world, experimentURL: url, options: e.headless, seed: e.seed,
                                                  current: args.contains("--current-as-flat") ? { .flat() } : nil)
            let runID = EvolutionRun.newRunID()
            let out = value(args, "--out").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? e.runDirectory(runID: runID)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let resume = args.contains("--resume") && FileManager.default.fileExists(atPath: out.appendingPathComponent("run.json").path)
            let r = resume ? try EvolutionRun.resume(from: out, world: world)
                           : try EvolutionRun(experiment: e, craft: craft, world: world, runID: runID, directory: out)
            let gens = max(1, e.generations)
            print("aero model: \(e.aero.model.rawValue)" + (e.aero.model == .full ? "  (CFD preset \(e.aero.cfd.preset.rawValue), \(e.aero.cfd.cellsPerMeter) cells/m, max \(e.aero.cfd.maxCellsPerAxis)/axis, update every \(e.aero.cfd.updateEvery) substeps; scalar sims, one GPU domain per worker)" : ""))
            print("experiment '\(e.name)'  algorithm \(e.algorithm.kind)  genes \(r.layout.count)  population \(e.population)  workers \(e.workers == 0 ? ProcessInfo.processInfo.activeProcessorCount : e.workers)  episode \(e.episode.duration)s x\(e.episode.episodesPerCandidate)  world \(world.name)")
            print("terms: \(r.termNames.joined(separator: ", "))   out: \(out.path)")
            var csv = "generation,best,mean,median,worst,failures,evaluations,wall_s,sims_per_s,simsec_per_wall_s,species,coverage," + r.termNames.map { "best_\($0)" }.joined(separator: ",") + "\n"
            let t0 = Date()
            while r.history.count < gens {
                let rec = try r.runGeneration()
                let terms = r.termNames.map { String(format: "%@=%.2f", $0, rec.termsBest[$0] ?? 0) }.joined(separator: " ")
                var extra = ""
                if rec.speciesCount > 0 { extra += " species=\(rec.speciesCount)" }
                if let c = rec.archiveCoverage { extra += String(format: " coverage=%.1f%%", c * 100) }
                print(String(format: "gen %4d  best %10.3f  mean %10.3f  median %10.3f  fail %3d  %6.1f sims/s  %7.1f sim-s/s  [%@]%@",
                             rec.generation, rec.best, rec.mean, rec.median, rec.failures, rec.simsPerSecond, rec.simSecondsPerWallSecond, terms, extra))
                if let err = rec.firstError, rec.failures > 0 { print("        first error: \(err)") }
                // (history.csv is written from r.history at the end, so resumed runs include earlier generations)
                fflush(stdout)
            }
            for rec in r.history {
                csv += "\(rec.generation),\(rec.best),\(rec.mean),\(rec.median),\(rec.worst),\(rec.failures),\(rec.evaluations),\(rec.wallSeconds),\(rec.simsPerSecond),\(rec.simSecondsPerWallSecond),\(rec.speciesCount),\(rec.archiveCoverage ?? -1),"
                    + r.termNames.map { "\(rec.termsBest[$0] ?? 0)" }.joined(separator: ",") + "\n"
            }
            try csv.write(to: out.appendingPathComponent("history.csv"), atomically: true, encoding: .utf8)
            try r.checkpoint(to: out)
            if let best = r.hallOfFame.max(by: { $0.fitness.total < $1.fitness.total }) {
                let doc = try r.exportCraft(best.genome, fitness: best.fitness)
                try JSONIO.write(doc, to: out.appendingPathComponent("best-craft.json"))
                print(String(format: "best overall: gen %d fitness %.3f  -> %@", best.generation, best.fitness.total, out.appendingPathComponent("best-craft.json").path))
                if let d = best.fitness.descriptor { print("best descriptor: \(d.map { String(format: "%.3f", $0) })") }
            }
            if let a = r.algorithm.archive { print(String(format: "archive coverage %.1f%%", a.coverage * 100)) }
            print(String(format: "total wall %.1f s", Date().timeIntervalSince(t0)))
            return 0
        } catch { print("error: \(error)"); return 1 }
    }
}
