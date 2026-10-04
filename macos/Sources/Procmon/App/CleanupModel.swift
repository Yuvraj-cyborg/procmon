// What the clean-up rules find, for the pages that act on it: reclaimable
// files for Storage, idle apps for Memory, runaway processes for Activity.

import AppKit
import Dispatch
import Foundation
import Observation

/// A windowed app holding a lot of memory while doing nothing.
struct IdleAppSuggestion: Identifiable {
    let pid: PID
    let name: String
    let executable: String?
    let memory: Bytes
    let averageCPU: Double
    let application: NSRunningApplication

    var id: PID { pid }
}

/// A process burning CPU, and why the rules flagged it.
struct RunawaySuggestion: Identifiable {
    let pid: PID
    let name: String
    let executable: String?
    let reason: String
    let averageCPU: Double
    let isSpinning: Bool
    /// Set for windowed apps, which are asked to quit the proper way.
    let application: NSRunningApplication?

    var id: PID { pid }
}

@MainActor
@Observable
final class CleanupModel {
    enum Phase: Equatable { case idle, scanning, ready, cleaning }

    private(set) var phase: Phase = .idle
    private(set) var groups: [JunkGroup] = []
    var selectedKinds: Set<JunkKind> = Set(JunkKind.allCases.filter(\.isRecommended))
    /// Items unticked one by one inside a selected group.
    var excludedItems: Set<String> = []

    var junkFound: Bytes { groups.map(\.size).sum() }

    var selectedJunk: [JunkItem] {
        groups.filter { selectedKinds.contains($0.kind) }.flatMap(\.items).filter { !excludedItems.contains($0.path) }
    }

    @ObservationIgnored private var scheduled: Task<Void, Never>?

    /// Scans the disk once, the first time a page asks.
    func scanIfNeeded(_ monitor: Monitor) {
        if phase == .idle { scan(monitor) }
    }

    /// For the Overview and Storage: measure a little after launch, so
    /// starting Procmon never competes with what the user is doing.
    func scanSoon(_ monitor: Monitor) {
        guard phase == .idle, scheduled == nil else { return }
        scheduled = Task { [weak self, weak monitor] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, let monitor, self.phase == .idle else { return }
            // Utility, not background: background work runs on slowed-down
            // efficiency cores and takes four to five times the CPU time.
            self.scan(monitor)
        }
    }

    func scan(_ monitor: Monitor, qos: DispatchQoS.QoSClass = .utility) {
        guard phase != .scanning && phase != .cleaning else { return }
        phase = .scanning
        let running = Self.running(monitor)
        Task {
            groups = await offMain(qos: qos) { JunkScanner.scan(.current, running: running) }
            excludedItems = []
            phase = .ready
        }
    }

    // MARK: Suggestions

    func idleApps(_ monitor: Monitor) -> [IdleAppSuggestion] {
        guard let snapshot = monitor.latest else { return [] }
        let now = ContinuousClock.now
        return monitor.runningApps.values.compactMap { app -> IdleAppSuggestion? in
            guard app.pid.raw != getpid(), app.bundleID != "com.apple.finder",
                  let bundle = app.application.bundleURL?.path
            else { return nil }
            let members = snapshot.processes.filter { $0.pid == app.pid || $0.executable?.hasPrefix(bundle + "/") == true }
            let memory = members.compactMap(\.memory).sum()
            let trends = members.compactMap { monitor.cpuTrends[$0.pid] }
            let average = trends.map(\.average).reduce(0, +)
            let watched = monitor.cpuTrends[app.pid].map { (now - $0.since).seconds } ?? 0
            guard CleanupRules.isIdleMemoryHog(
                memory: memory, totalMemory: snapshot.memory.total, averageCPU: average, watched: watched, isActive: app.isActive
            ) else { return nil }
            let executable = members.first { $0.pid == app.pid }?.executable
            return IdleAppSuggestion(pid: app.pid, name: app.name, executable: executable, memory: memory, averageCPU: average, application: app.application)
        }
        .sorted { $0.memory > $1.memory }
    }

    func runaways(_ monitor: Monitor) -> [RunawaySuggestion] {
        guard let snapshot = monitor.latest else { return [] }
        let now = ContinuousClock.now
        let spinning = Set(snapshot.threadAlerts.compactMap { alert -> PID? in
            if case .spinning = alert.kind { return alert.pid } else { return nil }
        })
        // The app in front is the one being used; it is never suggested.
        let frontmost = monitor.runningApps.values.first(where: \.isActive)?.application.bundleURL?.path
        return snapshot.processes.compactMap { process -> RunawaySuggestion? in
            guard process.isOwn, !process.isRestricted, process.pid.raw != getpid(),
                  !CleanupRules.essentialProcesses.contains(process.name.lowercased())
            else { return nil }
            if let frontmost, process.executable?.hasPrefix(frontmost + "/") == true { return nil }
            let trend = monitor.cpuTrends[process.pid]
            let watched = trend.map { (now - $0.since).seconds } ?? 0
            guard let reason = CleanupRules.runawayReason(
                averageCPU: trend?.average ?? 0, watched: watched, isSpinning: spinning.contains(process.pid), noise: process.noiseReasons
            ) else { return nil }
            return RunawaySuggestion(
                pid: process.pid, name: process.name, executable: process.executable, reason: reason,
                averageCPU: trend?.average ?? 0, isSpinning: spinning.contains(process.pid),
                application: monitor.runningApps[process.pid]?.application
            )
        }
        .sorted { $0.averageCPU > $1.averageCPU }
    }

    // MARK: Cleaning

    /// Deletes the selected files, skipping any whose app has started since
    /// the scan, and reports what happened.
    func clean(_ monitor: Monitor, report: @escaping (String, Toast.Kind) -> Void) {
        guard phase == .ready else { return }
        let junk = selectedJunk
        guard !junk.isEmpty else { return }
        phase = .cleaning
        let running = Self.running(monitor)
        Task {
            let result = await offMain(qos: .userInitiated) { JunkScanner.remove(junk, running: running) }
            var message = result.removed > 0 ? "Freed \(result.freed.decimal)." : "Nothing was deleted."
            if result.skipped > 0 { message += " Skipped \(result.skipped) in use." }
            report(message, result.removed > 0 ? .success : .failure)
            phase = .ready
            scan(monitor)
        }
    }

    /// Names and bundle ids of everything running, for the in-use rules.
    static func running(_ monitor: Monitor) -> RunningSet {
        let applications = NSWorkspace.shared.runningApplications
        var names = Set(monitor.latest?.processes.map { $0.name.lowercased() } ?? [])
        names.formUnion(applications.compactMap { $0.localizedName?.lowercased() })
        return RunningSet(bundleIDs: Set(applications.compactMap { $0.bundleIdentifier?.lowercased() }), names: names)
    }
}
