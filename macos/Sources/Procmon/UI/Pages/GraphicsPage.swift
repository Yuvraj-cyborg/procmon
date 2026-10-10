// What the GPU is doing, how fast it is, and which apps are using it.

import SwiftUI

struct GraphicsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PageScroll {
            let snapshot = model.monitor.latest
            PageHeader(title: Page.graphics.title, detail: snapshot?.gpu.map(summary))
            if let snapshot {
                if let gpu = snapshot.gpu {
                    utilization(gpu, processes: snapshot.processes)
                } else {
                    Note("This Mac's GPU doesn't report how busy it is.")
                }
                BenchmarkSection(graphics: model.graphics)
                apps(snapshot)
            }
        }
    }

    private func summary(_ gpu: GPUStats) -> String {
        [gpu.name, gpu.cores.map { Format.count($0, "core") }].compactMap { $0 }.joined(separator: " · ")
    }

    private func utilization(_ gpu: GPUStats, processes: [ProcessSample]) -> some View {
        let history = model.monitor.gpuHistory
        let minutes = Int((Double(history.capacity) * model.monitor.interval.seconds / 60).rounded())
        let busiest = processes.max { ($0.gpu?.share ?? .zero) < ($1.gpu?.share ?? .zero) }
        return PageSection(title: "Utilization", detail: "Last \(Format.count(minutes, "minute"))") {
            HStack(alignment: .bottom, spacing: Space.xxl) {
                VStack(alignment: .leading, spacing: 2) {
                    ValueText(value: String(format: "%.0f", gpu.utilization.value * 100), unit: "%", level: Level.load(gpu.utilization))
                    Text([gpu.renderer.map { "Rendering \($0.percent)" }, gpu.tiler.map { "Tiling \($0.percent)" }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(TextStyle.caption)
                        .monospacedDigit()
                        .foregroundStyle(Palette.secondaryText)
                }
                .frame(minWidth: 150, alignment: .leading)
                Sparkline(values: history.values, capacity: history.capacity, ceiling: 1)
                    .frame(height: 44)
            }
            HStack(alignment: .top, spacing: Space.xxl) {
                if let inUse = gpu.memoryInUse {
                    StatView(label: "Memory", value: "\(inUse.binary) in use", hint: gpu.memoryAllocated.map { "\($0.binary) set aside" })
                }
                if let busiest, let share = busiest.gpu?.share, share > .zero {
                    StatView(label: "Busiest", value: busiest.name, hint: "\(share) of the GPU")
                }
                StatView(
                    label: "Resets since startup", value: "\(gpu.recoveries)",
                    hint: gpu.recoveries > 0 ? "The GPU hung and macOS restarted it" : "The GPU hasn't hung",
                    level: gpu.recoveries > 0 ? .warning : .normal
                )
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func apps(_ snapshot: Snapshot) -> some View {
        @Bindable var model = model
        // Many processes open the GPU and never run anything on it.
        let users = snapshot.processes.filter { ($0.gpu?.total ?? .zero) > .zero }
        return PageSection(title: "Apps using the GPU", detail: users.isEmpty ? nil : "\(users.count)") {
            if users.isEmpty {
                Note("No app has used the GPU, or this Mac doesn't report it per app.")
            } else {
                ViewportFrame(reserve: 96, minimum: 280) {
                    ProcessList(
                        processes: users,
                        columns: [.name, .gpu, .gpuTime, .cpu, .memory, .pid],
                        sort: $model.graphicsSort,
                        totalMemory: snapshot.memory.total
                    )
                }
            }
        }
    }
}

/// The benchmark's controls, its numbers, and how they compare with past runs.
private struct BenchmarkSection: View {
    let graphics: GraphicsModel

    var body: some View {
        PageSection(title: "Benchmark", detail: detail) {
            controls
        } content: {
            Text("Three short Metal tests, a few seconds in all. Run it for a minute to see whether the GPU slows down as it heats up. Other apps may stutter while a test runs.")
                .font(TextStyle.caption)
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if case .failed(let message) = graphics.phase {
                Text(message)
                    .font(TextStyle.body)
                    .foregroundStyle(Level.critical.color)
            }
            HStack(alignment: .top, spacing: Space.xxl) {
                ForEach(BenchmarkTest.allCases, id: \.self) { test in
                    result(test)
                }
            }
            if !graphics.sustained.isEmpty || isSustaining {
                SustainedChart(values: graphics.sustained, phase: graphics.phase)
            }
            if graphics.history.count > 1 {
                PastRuns(history: graphics.history)
            }
        }
    }

    private var isSustaining: Bool {
        if case .sustaining = graphics.phase { true } else { false }
    }

    private var detail: String? {
        guard let last = graphics.history.first else { return nil }
        return "Last run \(last.date.formatted(.relative(presentation: .named)))"
    }

    @ViewBuilder
    private var controls: some View {
        if graphics.isRunning {
            ProgressView().controlSize(.small)
            Button("Stop") { graphics.cancel() }
        } else {
            Button("Run for a Minute") { graphics.runSustained() }
            Button("Run Benchmark") { graphics.runQuick() }
                .buttonStyle(.borderedProminent)
        }
    }

    /// The test's number from the run in progress, else from the last run.
    private func result(_ test: BenchmarkTest) -> some View {
        let measuring = graphics.phase == .measuring(test)
        let running: Bool = if case .measuring = graphics.phase { true } else { false }
        let value = running ? graphics.current[test] : graphics.history.first?.value(test)
        let best = graphics.best(test)
        return VStack(alignment: .leading, spacing: 2) {
            Text(test.label)
                .font(TextStyle.caption)
                .foregroundStyle(Palette.secondaryText)
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                // Three numbers of equal weight, so none of them takes the hero size.
                ValueText(value: value.map(test.format) ?? "–", unit: test.unit, font: TextStyle.title)
                if measuring {
                    ProgressView().controlSize(.mini)
                }
            }
            Text(comparison(value: value, best: best, test: test))
                .font(TextStyle.caption)
                .monospacedDigit()
                .foregroundStyle(Palette.tertiaryText)
                .lineLimit(1)
        }
        .frame(minWidth: 150, alignment: .leading)
        .help(test.explanation)
    }

    private func comparison(value: Double?, best: Double?, test: BenchmarkTest) -> String {
        guard let value else { return graphics.isRunning ? "Waiting" : "Not run yet" }
        guard let best, graphics.history.count > 1 else { return test == .bandwidth ? "Read and written" : "Higher is faster" }
        let ratio = value / best
        return ratio >= 0.995 ? "Best on this Mac" : "\(Int((ratio * 100).rounded()))% of the best, \(test.format(best))"
    }
}

/// Speed across the sustained run. A line that sags means the GPU got hot
/// and lowered its clock.
private struct SustainedChart: View {
    let values: [Double]
    let phase: GraphicsModel.Phase

    var body: some View {
        let seconds = Int(GraphicsModel.sustainDuration.seconds)
        VStack(alignment: .leading, spacing: Space.xs) {
            Sparkline(values: values, capacity: seconds, ceiling: (values.max() ?? 1) * 1.1)
                .frame(height: 44)
            Text(caption)
                .font(TextStyle.caption)
                .monospacedDigit()
                .foregroundStyle(Palette.tertiaryText)
        }
    }

    private var caption: String {
        if case .sustaining(let elapsed) = phase {
            let now = values.last.map { " · \(BenchmarkTest.fp32.format($0)) TFLOPS" } ?? ""
            return "32-bit compute, \(Int(elapsed.seconds)) of \(Int(GraphicsModel.sustainDuration.seconds)) seconds\(now)"
        }
        guard let held = GraphicsModel.heldSpeed(values) else { return "32-bit compute over a minute" }
        let percent = Int((held * 100).rounded())
        return percent >= 95
            ? "Held its speed for the whole minute (\(percent)% at the end)"
            : "Slowed to \(percent)% of its starting speed as it heated up"
    }
}

/// Earlier quick runs, newest first.
private struct PastRuns: View {
    let history: [BenchmarkResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Earlier runs")
                .font(TextStyle.caption)
                .foregroundStyle(Palette.secondaryText)
                .padding(.bottom, Space.xs)
            ForEach(history.dropFirst().prefix(5)) { run in
                HStack(spacing: Space.l) {
                    Text(run.date.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(Palette.secondaryText)
                        .frame(minWidth: 150, alignment: .leading)
                    ForEach(BenchmarkTest.allCases, id: \.self) { test in
                        Text(run.value(test).map { "\(test.format($0)) \(test.unit)" } ?? "–")
                            .frame(width: 110, alignment: .trailing)
                    }
                    Spacer(minLength: 0)
                }
                .font(TextStyle.caption)
                .monospacedDigit()
                .foregroundStyle(Palette.text)
                .padding(.vertical, 3)
            }
        }
    }
}

extension GraphicsModel {
    /// Speed over the last ten seconds relative to the first five; `nil`
    /// until the run is long enough to say.
    nonisolated static func heldSpeed(_ values: [Double]) -> Double? {
        guard values.count >= 20 else { return nil }
        let start = values.prefix(5).reduce(0, +) / 5
        let end = values.suffix(10).reduce(0, +) / 10
        return start > 0 ? end / start : nil
    }
}
