// OWNED BY evolve-ui builder. ------------------------------------------------------------------------
// Swift Charts views for the EVOLVE tab: fitness best/mean/median per generation, per reward term,
// NEAT species stack, MAP-Elites archive heatmap, throughput. Clicking a generation selects that
// generation's best (HallOfFameEntry) for replay; clicking a heatmap cell selects that elite.
import SwiftUI
import Charts
import PWEvolution

/// Clamp failed (-1e12) values so a single failure does not flatten the chart.
private func shown(_ v: Double, floor: Double) -> Double { v <= EvolutionConstants.failedFitness * 0.5 ? floor : v }

struct FitnessChart: View {
    let history: [GenerationRecord]
    var selectedGeneration: Int?
    var onSelect: (Int) -> Void

    private struct Pt: Identifiable { let g: Int; let v: Double; let s: String; var id: String { "\(s)\(g)" } }

    var body: some View {
        let finite = history.flatMap { [$0.best, $0.mean, $0.median] }.filter { $0 > EvolutionConstants.failedFitness * 0.5 }
        let lo = finite.min() ?? 0
        let pts = history.flatMap { r in
            [Pt(g: r.generation, v: shown(r.best, floor: lo), s: "best"), Pt(g: r.generation, v: shown(r.mean, floor: lo), s: "mean"),
             Pt(g: r.generation, v: shown(r.median, floor: lo), s: "median")]
        }
        Chart {
            ForEach(pts) { p in
                LineMark(x: .value("Generation", p.g), y: .value("Fitness", p.v)).foregroundStyle(by: .value("Series", p.s))
            }
            if let g = selectedGeneration { RuleMark(x: .value("Selected", g)).foregroundStyle(.orange.opacity(0.7)) }
        }
        .chartForegroundStyleScale(["best": Color.green, "mean": Color.blue, "median": Color.purple])
        .chartXAxisLabel("generation").chartLegend(position: .top, alignment: .leading)
        .chartOverlay { proxy in clickOverlay(proxy) }
        .frame(height: 170)
    }

    private func clickOverlay(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onTapGesture { loc in
                    guard let plot = proxy.plotFrame else { return }
                    let x = loc.x - geo[plot].origin.x
                    if let g: Double = proxy.value(atX: x) { onSelect(Int(g.rounded())) }
                }
        }
    }
}

struct TermsChart: View {
    let history: [GenerationRecord]
    let terms: [String]
    var useMean = false
    private struct Pt: Identifiable { let g: Int; let v: Double; let s: String; var id: String { "\(s)\(g)" } }
    var body: some View {
        let names = terms.isEmpty ? Array(Set(history.flatMap { $0.termsBest.keys })).sorted() : terms
        let pts = history.flatMap { r in names.map { Pt(g: r.generation, v: (useMean ? r.termsMean[$0] : r.termsBest[$0]) ?? 0, s: $0) } }
        Chart(pts) { p in
            LineMark(x: .value("Generation", p.g), y: .value("Points", p.v)).foregroundStyle(by: .value("Term", p.s))
        }
        .chartLegend(position: .top, alignment: .leading)
        .frame(height: 150)
    }
}

struct ThroughputChart: View {
    let history: [GenerationRecord]
    var body: some View {
        Chart(history, id: \.generation) { r in
            BarMark(x: .value("Generation", r.generation), y: .value("sim-s / wall-s", r.simSecondsPerWallSecond)).foregroundStyle(.teal)
        }
        .chartYAxisLabel("sim-s / wall-s")
        .frame(height: 90)
    }
}

struct SpeciesChart: View {
    let species: [[SpeciesInfo]]
    private struct Pt: Identifiable { let g: Int; let id0: Int; let n: Int; var id: String { "\(g)-\(id0)" } }
    var body: some View {
        let pts = species.enumerated().flatMap { g, list in list.map { Pt(g: g, id0: $0.id, n: $0.size) } }
        Chart(pts) { p in
            AreaMark(x: .value("Generation", p.g), y: .value("Members", p.n), stacking: .standard)
                .foregroundStyle(by: .value("Species", "s\(p.id0)"))
        }
        .chartLegend(.hidden)
        .frame(height: 130)
    }
}

/// 2-D (or 1-D) MAP-Elites archive heatmap. Colour = elite fitness. Tap a filled cell to replay it.
struct ArchiveHeatmap: View {
    let archive: EliteArchive
    var selectedCell: Int?
    var onSelect: (Int) -> Void
    private struct Cell: Identifiable { let i: Int; let x: Int; let y: Int; let f: Double; var id: Int { i } }
    var body: some View {
        let ax = archive.axes
        let cells = archive.cells.map { k, e -> Cell in
            let c = archive.coordinates(of: k)
            return Cell(i: k, x: c.first ?? 0, y: c.count > 1 ? c[1] : 0, f: e.fitness.total)
        }
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "Archive %d / %d cells (%.0f%%)", archive.cells.count, archive.capacity, archive.coverage * 100)).font(.caption2)
            Chart(cells) { c in
                RectangleMark(xStart: .value("x", c.x), xEnd: .value("x", c.x + 1), yStart: .value("y", c.y), yEnd: .value("y", c.y + 1))
                    .foregroundStyle(by: .value("Fitness", c.f))
                    .opacity(c.i == selectedCell ? 1 : 0.9)
            }
            .chartXScale(domain: 0...(ax.first?.bins ?? 1))
            .chartYScale(domain: 0...(ax.count > 1 ? ax[1].bins : 1))
            .chartXAxisLabel(ax.first?.name ?? "")
            .chartYAxisLabel(ax.count > 1 ? ax[1].name : "")
            .chartLegend(.hidden)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle()).onTapGesture { loc in
                        guard let plot = proxy.plotFrame else { return }
                        let p = CGPoint(x: loc.x - geo[plot].origin.x, y: loc.y - geo[plot].origin.y)
                        guard let (x, y): (Double, Double) = proxy.value(at: p) else { return }
                        if let hit = cells.first(where: { $0.x == Int(x) && $0.y == Int(y) }) { onSelect(hit.i) }
                    }
                }
            }
            .frame(height: 180)
        }
    }
}
