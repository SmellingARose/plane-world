// Headless training (port of the run part of Swift App/TrainCLI.swift): pwcli parses the flags and applies the
// overrides (cpp/src/cli/train_cli.cpp, P2b); this handler resolves craft + world, runs the generations with the
// same console output, and writes history.csv, a checkpoint and best-craft.json into --out.
#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <thread>
#include "pw/evo/run.h"
#include "pw/evo/train.h"
#include "pw/train_request.h"

namespace pw::evo {
namespace {
std::string sw(double d) { return craft::swiftDoubleString(d); }   // Swift "\(double)"

int train(const train::Request& req) {
    try {
        scripts::setDefaults(scripts::defaultMode(), req.engine);
        registerScriptedAlgorithm();
        ExperimentDocument e = ExperimentDocument::fromJson(req.experiment);
        std::string err;
        auto craft = resolveCraft(e.crafts.empty() ? nullptr : &e.crafts[0], req.experimentPath, err);
        if (!craft) { std::printf("error: craft not found (%s)\n", err.c_str()); return 1; }
        std::vector<std::string> notes;
        auto world = EvoWorld::resolve(e, req.experimentPath, req.currentAsFlat ? EvoWorld::flat() : nullptr, &notes);
        std::string runID = EvolutionRun::newRunID();
        std::string out = req.outDir.empty() ? e.runDirectory(runID) : req.outDir;
        std::error_code ec;
        std::filesystem::create_directories(out, ec);
        if (ec) { std::printf("error: I/O: cannot create %s: %s\n", out.c_str(), ec.message().c_str()); return 1; }
        bool resume = req.resume && std::filesystem::exists(out + "/run.json");
        std::unique_ptr<EvolutionRun> r = resume ? EvolutionRun::resume(out, world) : std::make_unique<EvolutionRun>(e, *craft, world, runID, out);
        const ExperimentDocument& ex = r->context()->experiment;
        int gens = std::max(1, ex.generations);
        std::printf("aero model: %s\n", ex.aero.model.c_str());
        int workers = ex.workers == 0 ? int(std::thread::hardware_concurrency()) : ex.workers;
        std::printf("experiment '%s'  algorithm %s  genes %d  population %d  workers %d  episode %ss x%d  world %s\n", ex.name.c_str(),
                    ex.algorithm.kind.c_str(), r->layout().count(), ex.population, workers, sw(ex.episode.duration).c_str(),
                    ex.episode.episodesPerCandidate, world->base.name.c_str());
        std::string terms;
        for (auto& t : r->termNames()) terms += (terms.empty() ? "" : ", ") + t;
        std::printf("terms: %s   out: %s\n", terms.c_str(), out.c_str());
        {
            EvalWorker probe(r->context(), scripts::make(ex.scripts));
            std::printf("script: %s\n", probe.runtime().engine());
        }
        for (auto& n : notes) std::printf("note: %s\n", n.c_str());
        auto t0 = std::chrono::steady_clock::now();
        while (int(r->history().size()) < gens) {
            GenerationRecord rec = r->runGeneration();
            std::string tl;
            for (auto& t : r->termNames()) {
                char b[96]; auto it = rec.termsBest.find(t);
                std::snprintf(b, sizeof b, "%s=%.2f", t.c_str(), it == rec.termsBest.end() ? 0.0 : it->second);
                tl += (tl.empty() ? "" : " ") + std::string(b);
            }
            std::string extra;
            if (rec.speciesCount > 0) extra += " species=" + std::to_string(rec.speciesCount);
            if (rec.archiveCoverage) { char b[48]; std::snprintf(b, sizeof b, " coverage=%.1f%%", *rec.archiveCoverage * 100); extra += b; }
            std::printf("gen %4d  best %10.3f  mean %10.3f  median %10.3f  fail %3d  %6.1f sims/s  %7.1f sim-s/s  [%s]%s\n", rec.generation, rec.best,
                        rec.mean, rec.median, rec.failures, rec.simsPerSecond, rec.simSecondsPerWallSecond, tl.c_str(), extra.c_str());
            if (rec.firstError && rec.failures > 0) std::printf("        first error: %s\n", rec.firstError->c_str());
            std::fflush(stdout);
        }
        std::string csv = "generation,best,mean,median,worst,failures,evaluations,wall_s,sims_per_s,simsec_per_wall_s,species,coverage";
        for (auto& t : r->termNames()) csv += ",best_" + t;
        csv += "\n";
        for (auto& rec : r->history()) {
            csv += std::to_string(rec.generation) + "," + sw(rec.best) + "," + sw(rec.mean) + "," + sw(rec.median) + "," + sw(rec.worst) + "," +
                   std::to_string(rec.failures) + "," + std::to_string(rec.evaluations) + "," + sw(rec.wallSeconds) + "," + sw(rec.simsPerSecond) + "," +
                   sw(rec.simSecondsPerWallSecond) + "," + std::to_string(rec.speciesCount) + "," + sw(rec.archiveCoverage.value_or(-1));
            for (auto& t : r->termNames()) { auto it = rec.termsBest.find(t); csv += "," + sw(it == rec.termsBest.end() ? 0.0 : it->second); }
            csv += "\n";
        }
        { std::ofstream f(out + "/history.csv", std::ios::binary); f << csv; }
        r->checkpoint(out);
        auto hall = r->hallOfFame();
        if (!hall.empty()) {
            const HallOfFameEntry* best = &hall[0];
            for (auto& h : hall) if (best->fitness.total < h.fitness.total) best = &h;
            auto doc = r->exportCraft(best->genome, &best->fitness);
            std::string werr;
            if (!craft::saveCraftFile(doc, out + "/best-craft.json", werr)) throw EvoError("I/O: " + werr);
            std::printf("best overall: gen %d fitness %.3f  -> %s\n", best->generation, best->fitness.total, (out + "/best-craft.json").c_str());
            if (best->fitness.descriptor) {
                std::string d;
                for (double v : *best->fitness.descriptor) { char b[48]; std::snprintf(b, sizeof b, "\"%.3f\"", v); d += (d.empty() ? "" : ", ") + std::string(b); }
                std::printf("best descriptor: [%s]\n", d.c_str());
            }
        }
        if (auto a = r->algorithm().archive()) std::printf("archive coverage %.1f%%\n", a->coverage() * 100);
        std::printf("total wall %.1f s\n", std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count());
        return 0;
    } catch (const std::exception& ex) {
        std::printf("error: %s\n", ex.what());
        return 1;
    }
}
} // namespace

void installTrainHandler() { train::setHandler(&train); }
} // namespace pw::evo
