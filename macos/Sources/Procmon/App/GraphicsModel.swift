// State of the Graphics page's benchmark: the run in progress, and past
// results kept so a new run can be compared with them.

import Foundation
import Observation

@MainActor
@Observable
final class GraphicsModel {
    enum Phase: Equatable {
        case idle
        /// A quick run, on this test.
        case measuring(BenchmarkTest)
        /// A sustained run, this far in.
        case sustaining(elapsed: Duration)
        case failed(String)
    }

    /// How long the sustained run lasts.
    nonisolated static let sustainDuration = Duration.seconds(60)
    /// Past quick runs kept for comparison.
    nonisolated static let historyLimit = 12
    private static let historyKey = "benchmarkHistory"

    private(set) var phase: Phase = .idle
    /// Quick runs, newest first.
    private(set) var history: [BenchmarkResult]
    /// Values of the quick run in progress.
    private(set) var current: [BenchmarkTest: Double] = [:]
    /// TFLOPS about once a second during the last sustained run.
    private(set) var sustained: [Double] = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var benchmark: GPUBenchmark?
    @ObservationIgnored private var cancellation: Cancellation?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        history = defaults.data(forKey: Self.historyKey)
            .flatMap { try? JSONDecoder().decode([BenchmarkResult].self, from: $0) } ?? []
    }

    var isRunning: Bool {
        switch phase {
        case .measuring, .sustaining: true
        case .idle, .failed: false
        }
    }

    /// The best value any past run reached.
    func best(_ test: BenchmarkTest) -> Double? {
        history.compactMap { $0.value(test) }.max()
    }

    /// Three short tests, a few seconds in all.
    func runQuick() {
        guard !isRunning else { return }
        let cancellation = Cancellation()
        self.cancellation = cancellation
        current = [:]
        phase = .measuring(.fp32)
        Task {
            do {
                let benchmark = try await prepare()
                for test in BenchmarkTest.allCases {
                    phase = .measuring(test)
                    current[test] = try await offMain { Result { try benchmark.measure(test, cancellation: cancellation) } }.get()
                }
                record(BenchmarkResult(date: .now, gpu: benchmark.name, values: current))
                phase = .idle
            } catch {
                current = [:]
                finish(error)
            }
        }
    }

    /// 32-bit compute for a minute, to see whether the GPU slows down as it heats up.
    func runSustained() {
        guard !isRunning else { return }
        let cancellation = Cancellation()
        self.cancellation = cancellation
        sustained = []
        phase = .sustaining(elapsed: .zero)
        let start = ContinuousClock.now
        Task {
            do {
                let benchmark = try await prepare()
                try await offMain {
                    Result {
                        try benchmark.sustain(for: Self.sustainDuration, cancellation: cancellation) { tflops in
                            Task { @MainActor in
                                guard self.cancellation === cancellation, self.isRunning else { return }
                                self.sustained.append(tflops)
                                self.phase = .sustaining(elapsed: ContinuousClock.now - start)
                            }
                        }
                    }
                }.get()
                phase = .idle
            } catch {
                finish(error)
            }
        }
    }

    func cancel() {
        cancellation?.cancel()
    }

    private func prepare() async throws -> GPUBenchmark {
        if let benchmark { return benchmark }
        let made = try await offMain { Result { try GPUBenchmark() } }.get()
        benchmark = made
        return made
    }

    private func finish(_ error: Error) {
        phase = (error as? BenchmarkError) == .cancelled ? .idle : .failed(String(describing: error))
    }

    private func record(_ result: BenchmarkResult) {
        history = Array(([result] + history).prefix(Self.historyLimit))
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: Self.historyKey)
        }
    }
}

extension BenchmarkTest {
    /// Two decimals for TFLOPS, whole numbers for memory speed.
    func format(_ value: Double) -> String {
        switch self {
        case .fp32, .fp16: String(format: "%.2f", value)
        case .bandwidth: value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        }
    }
}
