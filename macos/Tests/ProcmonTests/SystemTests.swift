import Foundation
import Testing
@testable import Procmon

@Suite struct SnapshotTests {
    private func process(_ app: String, memory: UInt64, pid: Int32 = 1) -> ProcessSample {
        ProcessSample(
            pid: PID(pid), name: app, app: app, executable: nil, runTime: nil,
            metrics: ProcessMetrics(memory: Bytes(memory), cpu: Percent(1), threads: 2, diskRead: .zero, diskWrite: .zero, activity: nil),
            network: nil
        )
    }

    @Test func groupsProcessesByApp() {
        let apps = [process("Helium", memory: 100), process("yes", memory: 500), process("Helium", memory: 300)].groupedByApp()
        #expect(apps.count == 2)
        #expect(apps[0].name == "yes")
        #expect(apps[1].memory == Bytes(400))
        #expect(apps[1].processes.count == 2)
        #expect(apps[1].threads == 4)
    }

    @Test func quietProcessHasNoNoise() {
        let rates = ActivityRates()
        #expect(rates.noiseReasons.isEmpty)
        #expect(rates.intensity == 0)
    }

    @Test func syscallStormIsFlagged() {
        let rates = ActivityRates(syscalls: .between(0, 80_000, over: .seconds(1)))
        #expect(rates.noiseReasons == [.syscalls])
    }

    @Test func queryMatchesNameAppOrExactPID() {
        let helper = ProcessSample(
            pid: PID(4242), name: "Helium Helper (Renderer)", app: "Helium", executable: nil, runTime: nil, metrics: nil, network: nil
        )
        #expect(ProcessQuery("").matches(helper))
        #expect(ProcessQuery("  renderer ").matches(helper))
        #expect(ProcessQuery("HELIUM").matches(helper))
        #expect(ProcessQuery("4242").matches(helper))
        #expect(!ProcessQuery("424").matches(process("a", memory: 0, pid: 4242)))
        #expect(!ProcessQuery("cursor").matches(helper))
    }

    @Test func helpersRollUpToOutermostAppBundle() {
        let exe = "/Applications/Helium.app/Contents/Frameworks/Helium Helper (Renderer).app/Contents/MacOS/Helium Helper (Renderer)"
        #expect(ProcessProbe.appName(executable: exe, processName: "Helium Helper (Renderer)") == "Helium")
        #expect(ProcessProbe.appName(executable: "/usr/bin/yes", processName: "yes") == "yes")
        #expect(ProcessProbe.appName(executable: nil, processName: "x") == "x")
    }
}

@Suite struct ThreadTrackerTests {
    private let clock = ContinuousClock()

    private func sample(_ state: ThreadRunState, cpu: Double) -> ThreadSample {
        ThreadSample(id: ThreadID(raw: 1), name: nil, state: state, cpu: Ratio(cpu))
    }

    @Test func blockedThreadAlertsOnlyAfterThreshold() {
        var tracker = ThreadTracker()
        let start = clock.now
        let blocked = [sample(.uninterruptible, cpu: 0)]
        #expect(tracker.observe(pid: PID(7), process: "disk-hog", samples: blocked, at: start).isEmpty)
        tracker.finishPass(at: start)

        let later = start + .seconds(4)
        let alerts = tracker.observe(pid: PID(7), process: "disk-hog", samples: blocked, at: later)
        tracker.finishPass(at: later)
        #expect(alerts.count == 1)
        #expect(alerts.first?.kind == .blocked)
    }

    @Test func spinningResetsWhenThreadCoolsDown() {
        var tracker = ThreadTracker()
        let start = clock.now
        var alerts: [ThreadAlert] = []
        for (seconds, cpu) in [(0, 1.0), (6, 1.0), (7, 0.1), (12, 1.0), (16, 1.0)] {
            let now = start + .seconds(seconds)
            alerts += tracker.observe(pid: PID(1), process: "spinner", samples: [sample(.running, cpu: cpu)], at: now)
            tracker.finishPass(at: now)
        }
        #expect(alerts.isEmpty, "cool-down at 7s must reset the spin timer")
    }

    @Test func spinningThreadIsFlaggedAfterTenSeconds() {
        var tracker = ThreadTracker()
        let start = clock.now
        var alerts: [ThreadAlert] = []
        for seconds in [0, 5, 11] {
            let now = start + .seconds(seconds)
            alerts = tracker.observe(pid: PID(1), process: "spinner", samples: [sample(.running, cpu: 1)], at: now)
            tracker.finishPass(at: now)
        }
        #expect(alerts.first?.kind == .spinning(cpu: Ratio(1)))
    }

    @Test func vanishedThreadsAreForgotten() {
        var tracker = ThreadTracker()
        let start = clock.now
        _ = tracker.observe(pid: PID(1), process: "p", samples: [sample(.waiting, cpu: 0)], at: start)
        tracker.finishPass(at: start)
        tracker.finishPass(at: start + .seconds(1))
        #expect(tracker.isEmpty)
    }
}

@Suite struct NetworkParsingTests {
    private let sample = """
        ,packets_in,bytes_in,packets_out,bytes_out,
        launchd.1,0,0,0,0,
        apsd.578,312,170253,291,163396,
        Weird, Name.v2.4242,1,10,2,20,

        """

    @Test func parsesByHeaderAndHandlesCommasInNames() {
        let totals = NetworkProbe.parse(csv: sample)
        #expect(totals[PID(578)] == NetworkTotals(bytesIn: 170_253, bytesOut: 163_396, packetsIn: 312, packetsOut: 291))
        #expect(totals[PID(4242)]?.bytesOut == 20)
        #expect(totals.count == 3)
    }

    @Test func missingByteColumnsYieldNothing() {
        #expect(NetworkProbe.parse(csv: ",state,\nfoo.1,up,\n").isEmpty)
        #expect(NetworkProbe.parse(csv: "").isEmpty)
    }
}

@Suite struct ProcessControlTests {
    @Test func refusesToSignalInitOrItself() {
        #expect(throws: SignalError.protected) { try ProcessControl.send(.terminate, to: PID(1)) }
        #expect(throws: SignalError.protected) { try ProcessControl.send(.kill, to: PID(0)) }
        #expect(throws: SignalError.protected) { try ProcessControl.send(.kill, to: PID(getpid())) }
    }

    @Test func terminatesAChildProcess() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        try ProcessControl.send(.terminate, to: PID(child.processIdentifier))
        child.waitUntilExit()
        #expect(child.terminationReason == .uncaughtSignal)
    }
}

/// Reads the live system: `PROCMON_LIVE=1 swift test --filter LiveSystemTests`.
@Suite(.enabled(if: Foundation.ProcessInfo.processInfo.environment["PROCMON_LIVE"] != nil))
struct LiveSystemTests {
    @Test func samplerSeesProcessesAndMemory() async throws {
        let sampler = Sampler()
        _ = await sampler.sample()
        try await Task.sleep(for: .seconds(1))
        let clock = ContinuousClock()
        let started = clock.now
        let snapshot = await sampler.sample()
        let busiest = snapshot.processes.max { ($0.cpu ?? .zero) < ($1.cpu ?? .zero) }
        print("""
            sample took \(clock.now - started): \(snapshot.processes.count) processes, \
            coverage \(snapshot.coverage), used \(snapshot.memory.used.binary) of \(snapshot.memory.total.binary), \
            cpu \(snapshot.cpu.total.percent) on \(snapshot.cpu.cores.count) cores, gpu \(String(describing: snapshot.gpu)), \
            net \(String(describing: snapshot.network)), busiest \(busiest?.name ?? "-") \(busiest?.cpu?.description ?? "-")
            """)
        #expect(!snapshot.processes.isEmpty)
        #expect(snapshot.memory.total > .zero)
        #expect(snapshot.processes.contains { $0.pid == PID(getpid()) && !$0.isRestricted })
    }

    @Test func deviceInventoryFindsHardware() {
        let inventory = DeviceInventory.collect()
        print("\(inventory.devices.count) devices, \(inventory.drivers.count) drivers, machine \(inventory.machineName ?? "?"), errors \(inventory.errors)")
        #expect(!inventory.devices.isEmpty)
    }
}
