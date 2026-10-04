import Foundation
import Testing
@testable import Procmon

@Suite struct CleanupRuleTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let idle = RunningSet(bundleIDs: [], names: [])
    private var old: Date { now.addingTimeInterval(-30 * 86_400) }

    @Test func thirdPartyCachesOfStoppedAppsAreRemovable() {
        #expect(CleanupRules.isRemovableCache(named: "com.example.Editor", running: idle, newest: old, now: now))
        #expect(CleanupRules.isRemovableCache(named: "Homebrew", running: idle, newest: old, now: now))
    }

    @Test func appleAndProtectedCachesStay() {
        #expect(!CleanupRules.isRemovableCache(named: "com.apple.Safari", running: idle, newest: old, now: now))
        #expect(!CleanupRules.isRemovableCache(named: "CloudKit", running: idle, newest: old, now: now))
        #expect(CleanupRules.isRemovableCache(named: "com.apple.dt.Xcode", running: idle, newest: old, now: now))
    }

    @Test func cachesOfRunningAppsOrHelpersStay() {
        let running = RunningSet(bundleIDs: ["com.example.editor"], names: ["slack"])
        #expect(!CleanupRules.isRemovableCache(named: "com.example.Editor", running: running, newest: old, now: now))
        #expect(!CleanupRules.isRemovableCache(named: "com.example.editor.ShipIt", running: running, newest: old, now: now))
        #expect(!CleanupRules.isRemovableCache(named: "Slack", running: running, newest: old, now: now))
    }

    @Test func recentlyWrittenCachesStay() {
        #expect(!CleanupRules.isRemovableCache(named: "com.example.Editor", running: idle, newest: now.addingTimeInterval(-60), now: now))
    }

    @Test func logAndTemporaryAgesAreRespected() {
        #expect(CleanupRules.isOldLog(newest: now.addingTimeInterval(-8 * 86_400), now: now))
        #expect(!CleanupRules.isOldLog(newest: now.addingTimeInterval(-6 * 86_400), now: now))
        #expect(CleanupRules.isStaleTemporary(named: "export-123", newest: old, now: now))
        #expect(!CleanupRules.isStaleTemporary(named: "com.apple.launchd", newest: old, now: now))
        #expect(!CleanupRules.isStaleTemporary(named: "agent.socket", newest: old, now: now))
        #expect(!CleanupRules.isStaleTemporary(named: "export-456", newest: now.addingTimeInterval(-86_400), now: now))
    }

    @Test func pathsMustStayInsideTheirRoot() {
        #expect(CleanupRules.isInside("/u/Library/Caches/foo", root: "/u/Library/Caches"))
        #expect(!CleanupRules.isInside("/u/Library/Caches", root: "/u/Library/Caches"))
        #expect(!CleanupRules.isInside("/u/Library/Caches/../Mail", root: "/u/Library/Caches"))
        #expect(!CleanupRules.isInside("/u/Library/CachesExtra/foo", root: "/u/Library/Caches"))
    }

    @Test func idleMemoryHogsNeedSizeIdlenessAndTime() {
        let ram = Bytes(16 * 1024 * 1024 * 1024)
        let big = Bytes(2 * 1024 * 1024 * 1024)
        #expect(CleanupRules.isIdleMemoryHog(memory: big, totalMemory: ram, averageCPU: 0.5, watched: 120, isActive: false))
        #expect(!CleanupRules.isIdleMemoryHog(memory: big, totalMemory: ram, averageCPU: 0.5, watched: 120, isActive: true))
        #expect(!CleanupRules.isIdleMemoryHog(memory: big, totalMemory: ram, averageCPU: 20, watched: 120, isActive: false))
        #expect(!CleanupRules.isIdleMemoryHog(memory: big, totalMemory: ram, averageCPU: 0.5, watched: 10, isActive: false))
        #expect(!CleanupRules.isIdleMemoryHog(memory: Bytes(100 * 1024 * 1024), totalMemory: ram, averageCPU: 0.5, watched: 120, isActive: false))
    }

    @Test func runawaysNeedSustainedLoadOrASymptom() {
        #expect(CleanupRules.runawayReason(averageCPU: 95, watched: 60, isSpinning: false, noise: []) != nil)
        #expect(CleanupRules.runawayReason(averageCPU: 95, watched: 10, isSpinning: false, noise: []) == nil)
        #expect(CleanupRules.runawayReason(averageCPU: 40, watched: 60, isSpinning: false, noise: []) == nil)
        #expect(CleanupRules.runawayReason(averageCPU: 5, watched: 5, isSpinning: true, noise: []) != nil)
        #expect(CleanupRules.runawayReason(averageCPU: 5, watched: 60, isSpinning: false, noise: [.syscalls]) == "Syscall storm")
    }
}

@Suite struct JunkScannerTests {
    private let fileManager = FileManager.default

    private func make(_ path: String, bytes: Int = 8192, age: TimeInterval) throws {
        try fileManager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: URL(fileURLWithPath: path))
        try fileManager.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: path)
    }

    private func age(_ path: String, by seconds: TimeInterval) throws {
        try fileManager.setAttributes([.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: path)
    }

    @Test func measuresNestedFilesButNotSymlinkTargets() throws {
        let base = fileManager.temporaryDirectory.appendingPathComponent("procmon-usage-\(UUID().uuidString)").path
        defer { try? fileManager.removeItem(atPath: base) }
        try make(base + "/root/a", bytes: 16384, age: 3600)
        try make(base + "/root/deep/er/b", bytes: 16384, age: 60)
        try make(base + "/outside/big", bytes: 1 << 20, age: 0)
        try fileManager.createSymbolicLink(atPath: base + "/root/link", withDestinationPath: base + "/outside")
        let usage = DiskUsage.measure(base + "/root")
        #expect(usage.size >= 32768)
        #expect(usage.size < 1 << 20)
        // The newest thing inside is the directory entry made last, within a minute or so.
        #expect(Date().timeIntervalSince(usage.newest) < 120)
        #expect(DiskUsage.measure(base + "/root/a").size >= 16384)
        #expect(DiskUsage.measure(base + "/missing").size == 0)
    }

    @Test func findsOnlyWhatTheRulesAllowAndRemovesIt() throws {
        let base = fileManager.temporaryDirectory.appendingPathComponent("procmon-junk-\(UUID().uuidString)").path
        defer { try? fileManager.removeItem(atPath: base) }
        let home = base + "/home"
        let temporary = base + "/tmp"
        let month: TimeInterval = 30 * 86_400

        try make(home + "/Library/Caches/com.example.old/data", age: month)
        try make(home + "/Library/Caches/com.apple.system/data", age: month)
        try make(home + "/Library/Caches/com.running.app/data", age: month)
        try make(home + "/Library/Caches/com.example.fresh/data", age: 0)
        for folder in ["com.example.old", "com.apple.system", "com.running.app"] {
            try age(home + "/Library/Caches/" + folder, by: month)
        }
        try make(home + "/Library/Logs/App/old.log", age: month)
        try make(home + "/Library/Logs/App/new.log", age: 0)
        try make(home + "/.npm/_cacache/index", age: month)
        try age(home + "/.npm/_cacache", by: month)
        try make(temporary + "/stale/file", age: month)
        try age(temporary + "/stale", by: month)
        try make(temporary + "/busy/file", age: 0)
        try make(home + "/.Trash/thrown away.txt", age: month)

        let places = JunkScanner.Places(home: home, temporary: temporary)
        let running = RunningSet(bundleIDs: ["com.running.app"], names: [])
        let groups = Dictionary(uniqueKeysWithValues: JunkScanner.scan(places, running: running).map { ($0.kind, $0) })

        #expect(groups[.appCaches]?.items.map(\.name) == ["com.example.old"])
        #expect(groups[.developerCaches]?.items.map(\.name) == ["npm cache"])
        #expect(groups[.logs]?.items.map(\.name) == ["old.log"])
        #expect(groups[.temporaryFiles]?.items.map(\.name) == ["stale"])
        #expect(groups[.trash]?.items.count == 1)

        let chosen = (groups[.appCaches]?.items ?? []) + (groups[.logs]?.items ?? [])
        let result = JunkScanner.remove(chosen, running: running)
        #expect(result.removed == 2)
        #expect(result.freed > .zero)
        #expect(!fileManager.fileExists(atPath: home + "/Library/Caches/com.example.old"))
        #expect(!fileManager.fileExists(atPath: home + "/Library/Logs/App/old.log"))
        #expect(fileManager.fileExists(atPath: home + "/Library/Logs/App/new.log"))
        #expect(fileManager.fileExists(atPath: home + "/Library/Caches/com.apple.system"))
    }

    @Test func refusesItemsOutsideTheirRootOrInUse() throws {
        let base = fileManager.temporaryDirectory.appendingPathComponent("procmon-guard-\(UUID().uuidString)").path
        defer { try? fileManager.removeItem(atPath: base) }
        try make(base + "/outside/keep", age: 0)
        try make(base + "/root/app/data", age: 0)
        let escaping = JunkItem(path: base + "/root/../outside", name: "x", size: Bytes(1), kind: .appCaches, root: base + "/root", blockedBy: [])
        let inUse = JunkItem(path: base + "/root/app", name: "app", size: Bytes(1), kind: .appCaches, root: base + "/root", blockedBy: ["editor"])
        let result = JunkScanner.remove([escaping, inUse], running: RunningSet(bundleIDs: [], names: ["editor"]))
        #expect(result.removed == 0)
        #expect(result.skipped == 2)
        #expect(fileManager.fileExists(atPath: base + "/outside/keep"))
        #expect(fileManager.fileExists(atPath: base + "/root/app/data"))
    }
}

@Suite struct ActivityViewTests {
    @Test func powerComesFromTheEnergyCounter() {
        #expect(Sampler.power(from: 0, to: 2_000_000_000, over: .seconds(2)) == 1)
        #expect(Sampler.power(from: 5, to: 1, over: .seconds(1)) == nil)
        #expect(Format.watts(0.012) == "12 mW")
        #expect(Format.watts(1.5) == "1.50 W")
        #expect(Format.clock(.seconds(3725.5)) == "1:02:05.50")
    }

    @Test func partialThreadPassesKeepUnprobedProcesses() {
        var tracker = ThreadTracker()
        let clock = ContinuousClock()
        let start = clock.now
        let blocked = [ThreadSample(id: ThreadID(raw: 9), name: nil, state: .uninterruptible, cpu: .zero)]
        _ = tracker.observe(pid: PID(5), process: "disk", samples: blocked, at: start)
        tracker.finishPass(at: start, probed: [PID(5)], alive: [PID(5)])
        // A later pass that only probed another process must not forget PID 5.
        tracker.finishPass(at: start + .seconds(2), probed: [PID(6)], alive: [PID(5), PID(6)])
        let alerts = tracker.observe(pid: PID(5), process: "disk", samples: blocked, at: start + .seconds(6))
        #expect(alerts.first?.kind == .blocked)
        tracker.finishPass(at: start + .seconds(8), probed: [], alive: [])
        #expect(tracker.isEmpty)
    }
}
