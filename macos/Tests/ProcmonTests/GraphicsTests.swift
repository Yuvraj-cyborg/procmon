import Foundation
import Testing
@testable import Procmon

@Suite struct GPUUsageTests {
    @Test func readsThePIDOfAUserClient() {
        #expect(GPUProbe.creatorPID("pid 632, WindowServer") == PID(632))
        #expect(GPUProbe.creatorPID("pid 1, launchd") == PID(1))
        #expect(GPUProbe.creatorPID("WindowServer") == nil)
        #expect(GPUProbe.creatorPID("pid x, y") == nil)
    }

    @Test func shareIsGPUTimeOverWallTime() {
        let before: [PID: UInt64] = [PID(1): 1_000_000_000, PID(2): 5_000_000_000]
        let now: [PID: UInt64] = [PID(1): 1_500_000_000, PID(2): 4_000_000_000, PID(3): 9_000_000_000]
        let usage = Sampler.gpuUsage(from: before, to: now, over: .seconds(2))
        #expect(usage[PID(1)]?.share == Percent(25))
        // A counter that went backwards belongs to a new process with a reused PID.
        #expect(usage[PID(2)]?.share == .zero)
        // First sight: no interval to measure over yet.
        #expect(usage[PID(3)]?.share == .zero)
        #expect(usage[PID(3)]?.total == .seconds(9))
    }

    @Test func appsAddUpTheirProcessesGPUShare() {
        let apps = [
            ProcessSample.fixture(pid: 1, name: "Helper", app: "Browser", memory: 10, gpu: 12),
            ProcessSample.fixture(pid: 2, name: "Browser", memory: 20, gpu: 3),
            ProcessSample.fixture(pid: 3, name: "yes", memory: 5),
        ].groupedByApp()
        #expect(apps.first { $0.name == "Browser" }?.gpu == Percent(15))
        #expect(apps.first { $0.name == "yes" }?.gpu == .zero)
    }

    @Test func gpuColumnsSortUnknownLast() {
        let rows = [
            ProcessSample.fixture(pid: 1, name: "a", gpu: 2),
            ProcessSample.fixture(pid: 2, name: "b"),
            ProcessSample.fixture(pid: 3, name: "c", gpu: 40),
        ]
        #expect(ProcessSort.by(.gpu).apply(rows).map(\.pid.raw) == [3, 1, 2])
        #expect(ProcessColumn.gpu.text(rows[1]) == "–")
        #expect(ProcessColumn.gpu.text(rows[2]) == "40%")
    }
}

@Suite struct BenchmarkTests {
    @Test func heldSpeedComparesTheEndWithTheStart() {
        #expect(GraphicsModel.heldSpeed(Array(repeating: 3, count: 10)) == nil)
        #expect(GraphicsModel.heldSpeed(Array(repeating: 3, count: 60)) == 1)
        let throttled = Array(repeating: 4.0, count: 30) + Array(repeating: 2.0, count: 30)
        #expect(GraphicsModel.heldSpeed(throttled) == 0.5)
    }

    @Test func resultsSurviveARoundTrip() throws {
        let result = BenchmarkResult(date: Date(timeIntervalSince1970: 1_000), gpu: "Apple M4", values: [.fp32: 2.86, .bandwidth: 96])
        let data = try JSONEncoder().encode([result])
        #expect(try JSONDecoder().decode([BenchmarkResult].self, from: data) == [result])
        // Tests are stored by name, so adding a test later keeps old results readable.
        #expect(String(decoding: data, as: UTF8.self).contains("\"fp32\""))
    }

    @MainActor @Test func historyIsKeptNewestFirstAndCapped() throws {
        let defaults = try #require(UserDefaults(suiteName: "procmon-benchmark-\(UUID().uuidString)"))
        let old = (0..<GraphicsModel.historyLimit + 3).map {
            BenchmarkResult(date: Date(timeIntervalSince1970: Double($0)), gpu: "GPU", values: [.fp32: Double($0)])
        }
        defaults.set(try JSONEncoder().encode(old), forKey: "benchmarkHistory")
        let model = GraphicsModel(defaults: defaults)
        #expect(model.best(.fp32) == Double(GraphicsModel.historyLimit + 2))
        #expect(model.best(.fp16) == nil)
    }

    @Test func formatsNumbersForTheirUnit() {
        #expect(BenchmarkTest.fp32.format(2.8571) == "2.86")
        #expect(BenchmarkTest.bandwidth.format(96.14) == "96.1")
        #expect(BenchmarkTest.bandwidth.format(412.6) == "413")
    }
}

/// Runs on the real GPU: `PROCMON_LIVE=1 swift test --filter LiveGPUTests`.
@Suite(.enabled(if: Foundation.ProcessInfo.processInfo.environment["PROCMON_LIVE"] != nil))
struct LiveGPUTests {
    @Test func benchmarkMeasuresPlausibleNumbers() throws {
        let benchmark = try GPUBenchmark()
        let cancellation = Cancellation()
        var values: [BenchmarkTest: Double] = [:]
        for test in BenchmarkTest.allCases {
            values[test] = try benchmark.measure(test, runs: 3, cancellation: cancellation)
        }
        print("\(benchmark.name): " + BenchmarkTest.allCases.map { "\($0.label) \($0.format(values[$0]!)) \($0.unit)" }.joined(separator: ", "))
        #expect(values[.fp32]! > 0.1)
        #expect(values[.bandwidth]! > 10)
    }

    @Test func probeSeesTheGPUAndItsUsers() {
        let gpu = GPUProbe.sample()
        let times = GPUProbe.processTimes()
        print("\(String(describing: gpu)); \(times.count) processes have used the GPU")
        #expect(gpu != nil)
    }

    @Test func cancellingStopsBeforeTheNextCommandBuffer() throws {
        let benchmark = try GPUBenchmark()
        let cancellation = Cancellation()
        cancellation.cancel()
        #expect(throws: BenchmarkError.cancelled) { try benchmark.measure(.fp32, cancellation: cancellation) }
    }
}
