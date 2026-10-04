// Shared model that every page observes. Owns the sampling loop.

import AppKit
import Foundation
import Observation

/// A regular, windowed app as Launch Services sees it.
struct RunningApp {
    let pid: PID
    let name: String
    let bundleID: String?
    let isActive: Bool
    let application: NSRunningApplication
}

/// How busy a process has been lately, smoothed over about a minute.
struct CPUTrend: Sendable {
    /// Exponential moving average, in percent of one core.
    var average: Double
    var since: ContinuousClock.Instant
}

@MainActor
@Observable
final class Monitor {
    /// Two minutes of history.
    nonisolated static let historyLength = 120
    /// While the window is hidden, sample only this often.
    static let hiddenInterval = Duration.seconds(10)
    /// Time constant of ``cpuTrends``.
    static let trendWindow = 60.0

    /// Recent readings. Kept apart from what views observe, so a hidden
    /// window costs no SwiftUI work at all.
    struct Histories: Sendable {
        var cpu = History<Double>(capacity: historyLength)
        var memory = History<Double>(capacity: historyLength)
        var gpu = History<Double>(capacity: historyLength)
        var received = History<Double>(capacity: historyLength)
        var sent = History<Double>(capacity: historyLength)
        var diskRead = History<Double>(capacity: historyLength)
        var diskWrite = History<Double>(capacity: historyLength)
    }

    // What views observe. Only ever set by `publish()`.
    private(set) var latest: Snapshot?
    /// Number of samples published so far; views key refreshes on it.
    private(set) var samples = 0
    private(set) var histories = Histories()
    private(set) var cpuTrends: [PID: CPUTrend] = [:]
    /// Regular apps by PID, kept current from Launch Services notifications.
    private(set) var runningApps: [PID: RunningApp] = [:]

    var cpuHistory: History<Double> { histories.cpu }
    var memoryHistory: History<Double> { histories.memory }
    var gpuHistory: History<Double> { histories.gpu }
    var receivedHistory: History<Double> { histories.received }
    var sentHistory: History<Double> { histories.sent }
    var diskReadHistory: History<Double> { histories.diskRead }
    var diskWriteHistory: History<Double> { histories.diskWrite }

    var interval = Duration.seconds(2)

    @ObservationIgnored private var sampling: Task<Void, Never>?
    @ObservationIgnored private var appObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var pause: Task<Void, Never>?
    @ObservationIgnored private var lastPush: ContinuousClock.Instant?
    @ObservationIgnored private var networkDemand = 0
    @ObservationIgnored private var isVisible = true
    // Readings gathered while hidden, published when the window comes back.
    @ObservationIgnored private var pending: Snapshot?
    @ObservationIgnored private var bufferedHistories = Histories()
    @ObservationIgnored private var bufferedTrends: [PID: CPUTrend] = [:]

    func start() {
        guard sampling == nil else { return }
        observeApps()
        sampling = Task { [weak self] in
            let sampler = Sampler()
            while !Task.isCancelled {
                guard let options = self?.options else { return }
                let snapshot = await sampler.sample(options)
                guard let self else { return }
                self.push(snapshot)
                let delay = self.isVisible ? self.interval : Self.hiddenInterval
                let pause = Task { _ = try? await Task.sleep(for: delay) }
                self.pause = pause
                await pause.value
            }
        }
    }

    private var options: SampleOptions {
        SampleOptions(processNetwork: networkDemand > 0, visible: isVisible)
    }

    /// Hidden windows need almost nothing; a window coming back is refreshed at once.
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            publish()
            pause?.cancel()
        }
    }

    /// Views that show per-process network traffic ask for it while on screen.
    func needsProcessNetwork(_ needed: Bool) {
        let wasNeeded = networkDemand > 0
        networkDemand = max(0, networkDemand + (needed ? 1 : -1))
        if !wasNeeded && networkDemand > 0 {
            pause?.cancel()
        }
    }

    private func push(_ snapshot: Snapshot) {
        let now = ContinuousClock.now
        let elapsed = lastPush.map { (now - $0).seconds } ?? 0
        lastPush = now

        bufferedHistories.cpu.push(snapshot.cpu.total.value)
        bufferedHistories.memory.push(snapshot.memory.used.ratio(of: snapshot.memory.total).value)
        bufferedHistories.gpu.push(snapshot.gpu?.utilization.value ?? 0)
        bufferedHistories.received.push(Double(snapshot.network?.received.bytes.value ?? 0))
        bufferedHistories.sent.push(Double(snapshot.network?.sent.bytes.value ?? 0))
        bufferedHistories.diskRead.push(Double(snapshot.disk?.read.bytes.value ?? 0))
        bufferedHistories.diskWrite.push(Double(snapshot.disk?.written.bytes.value ?? 0))

        let weight = elapsed > 0 ? 1 - exp(-elapsed / Self.trendWindow) : 1
        var trends: [PID: CPUTrend] = [:]
        trends.reserveCapacity(snapshot.processes.count)
        for process in snapshot.processes {
            guard let cpu = process.cpu?.value else { continue }
            if var trend = bufferedTrends[process.pid] {
                trend.average += weight * (cpu - trend.average)
                trends[process.pid] = trend
            } else {
                trends[process.pid] = CPUTrend(average: cpu, since: now)
            }
        }
        bufferedTrends = trends

        pending = snapshot
        if isVisible {
            publish()
        }
    }

    /// Hands the latest readings to the views.
    private func publish() {
        guard let snapshot = pending else { return }
        pending = nil
        histories = bufferedHistories
        cpuTrends = bufferedTrends
        latest = snapshot
        samples += 1
    }

    /// Keeps ``runningApps`` current from Launch Services notifications.
    /// Reading `activationPolicy` costs a round trip to Launch Services, so
    /// the list is rebuilt only when an app starts, quits or comes forward.
    private func observeApps() {
        refreshApps()
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
        ]
        appObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshApps() }
            }
        }
    }

    private func refreshApps() {
        var apps: [PID: RunningApp] = [:]
        for application in NSWorkspace.shared.runningApplications where application.activationPolicy == .regular {
            let pid = PID(application.processIdentifier)
            apps[pid] = RunningApp(
                pid: pid,
                name: application.localizedName ?? "App",
                bundleID: application.bundleIdentifier,
                isActive: application.isActive,
                application: application
            )
        }
        runningApps = apps
    }

    func process(_ pid: PID) -> ProcessSample? {
        latest?.processes.first { $0.pid == pid }
    }
}
