// What the processor is doing, what is stuck, and every process, with a way
// to act on each.

import AppKit
import SwiftUI

/// A process worth a look: a thread stuck or spinning, or the whole process
/// burning CPU or flooding the kernel. One per process, worst finding first.
struct AttentionItem: Identifiable {
    /// The one thing most likely to help.
    enum Remedy { case quit, resume, inspect }

    let pid: PID
    let name: String
    let executable: String?
    /// A few words, for tight spaces.
    let headline: String
    /// A full sentence saying what was seen.
    let detail: String
    let level: Level
    let remedy: Remedy

    var id: PID { pid }

    static func all(in snapshot: Snapshot, runaways: [RunawaySuggestion]) -> [AttentionItem] {
        let processes = Dictionary(snapshot.processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var items: [AttentionItem] = []
        var seen: Set<PID> = []

        for (pid, alerts) in Dictionary(grouping: snapshot.threadAlerts, by: \.pid) {
            guard let item = threads(alerts, process: processes[pid]) else { continue }
            items.append(item)
            seen.insert(pid)
        }
        for runaway in runaways where !seen.contains(runaway.pid) {
            let isBusy = runaway.averageCPU >= CleanupRules.runawayCPU
            items.append(AttentionItem(
                pid: runaway.pid, name: runaway.name, executable: runaway.executable,
                headline: isBusy ? String(format: "%.0f%% CPU", runaway.averageCPU) : runaway.reason,
                detail: runaway.reason + ".",
                level: isBusy ? .warning : .normal,
                remedy: isBusy ? .quit : .inspect
            ))
            seen.insert(runaway.pid)
        }
        // Noisy system processes are shown but never offered a quit.
        for process in snapshot.processes where !seen.contains(process.pid) && !process.noiseReasons.isEmpty && !process.isOwn {
            items.append(AttentionItem(
                pid: process.pid, name: process.name, executable: process.executable,
                headline: process.noiseReasons[0].label,
                detail: noise(process),
                level: .normal,
                remedy: .inspect
            ))
        }
        return items.sorted { lhs, rhs in
            lhs.level.rank != rhs.level.rank ? lhs.level.rank > rhs.level.rank : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func threads(_ alerts: [ThreadAlert], process: ProcessSample?) -> AttentionItem? {
        guard let first = alerts.first else { return nil }
        let name = first.process
        let executable = process?.executable
        func longest(_ matching: [ThreadAlert]) -> String { (matching.map(\.duration).max() ?? .zero).compact }
        func who(_ matching: [ThreadAlert]) -> String {
            matching.count == 1 ? "Thread “\(matching[0].threadName ?? "\(matching[0].thread)")”" : "\(matching.count) threads"
        }

        let spinning = alerts.filter { if case .spinning = $0.kind { true } else { false } }
        if !spinning.isEmpty {
            return AttentionItem(
                pid: first.pid, name: name, executable: executable,
                headline: "Spinning",
                detail: "\(who(spinning)) \(spinning.count == 1 ? "has" : "have") run flat out for \(longest(spinning)), likely stuck in a loop.",
                level: .critical, remedy: .quit
            )
        }
        let blocked = alerts.filter { $0.kind == .blocked }
        if !blocked.isEmpty {
            return AttentionItem(
                pid: first.pid, name: name, executable: executable,
                headline: "\(blocked.count) blocked",
                detail: "\(who(blocked)) \(blocked.count == 1 ? "has" : "have") waited in the kernel for \(longest(blocked)), usually on a slow disk or network volume.",
                level: .warning, remedy: .inspect
            )
        }
        let stopped = alerts.filter { $0.kind == .stopped }
        return AttentionItem(
            pid: first.pid, name: name, executable: executable,
            headline: "Paused",
            detail: "Stopped for \(longest(stopped)). It does nothing until resumed.",
            level: .normal, remedy: .resume
        )
    }

    private static func noise(_ process: ProcessSample) -> String {
        let activity = process.activity ?? ActivityRates()
        var parts = ["\(activity.syscalls) syscalls", "\(activity.contextSwitches) switches", "\(activity.idleWakeups) wakeups"]
        if let network = process.network {
            parts.append("\(network.packets) packets")
        }
        return parts.joined(separator: " · ")
    }
}

extension Level {
    fileprivate var rank: Int {
        switch self {
        case .critical: 2
        case .warning: 1
        case .normal: 0
        }
    }
}

struct ActivityPage: View {
    /// At most this many rows under "Needs attention".
    static let attentionLimit = 6

    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool

    var body: some View {
        PageScroll {
            if let snapshot = model.monitor.latest {
                PageHeader(
                    title: Page.activity.title,
                    detail: "\(Format.count(snapshot.processes.count, "process", "processes")) · \(Format.count(snapshot.threadCount, "thread"))"
                )
                processor(snapshot.cpu)
                attention(snapshot)
                processes(snapshot)
            } else {
                PageHeader(title: Page.activity.title)
            }
        }
        .onChange(of: model.searchRequest) { searchFocused = true }
    }

    private func processor(_ cpu: CPUStats) -> some View {
        let history = model.monitor.cpuHistory
        return PageSection(title: "Processor", detail: String(format: "Load %.2f  %.2f  %.2f", cpu.load.one, cpu.load.five, cpu.load.fifteen)) {
            HStack(alignment: .bottom, spacing: Space.xxl) {
                VStack(alignment: .leading, spacing: 2) {
                    ValueText(value: String(format: "%.0f", cpu.total.value * 100), unit: "%", level: Level.load(cpu.total))
                    Text("Apps \(cpu.user.percent.description) · System \(cpu.system.percent.description)")
                        .font(TextStyle.caption)
                        .monospacedDigit()
                        .foregroundStyle(Palette.secondaryText)
                }
                .frame(minWidth: 150, alignment: .leading)
                Sparkline(values: history.values, capacity: history.capacity, ceiling: 1)
                    .frame(height: 44)
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                CoreBars(cores: cpu.cores, height: 28)
                Text(SystemInfo.current.coreSummary)
                    .font(TextStyle.caption)
                    .foregroundStyle(Palette.tertiaryText)
            }
        }
    }

    private func attention(_ snapshot: Snapshot) -> some View {
        let items = AttentionItem.all(in: snapshot, runaways: model.cleanup.runaways(model.monitor))
        let hidden = snapshot.coverage.denied
        return PageSection(title: "Needs attention", detail: items.isEmpty ? nil : "\(items.count)") {
            if items.isEmpty {
                Note("Nothing is stuck. Threads that block or spin, and processes that burn CPU in the background, appear here.")
            } else {
                VStack(spacing: 0) {
                    ForEach(items.prefix(Self.attentionLimit)) { item in
                        AttentionRow(item: item)
                        if item.id != items.prefix(Self.attentionLimit).last?.id {
                            Divider().padding(.leading, 28)
                        }
                    }
                }
                if items.count > Self.attentionLimit {
                    Text("and \(items.count - Self.attentionLimit) more")
                        .font(TextStyle.caption)
                        .foregroundStyle(Palette.secondaryText)
                }
            }
            if hidden > 0 {
                Text("\(Format.count(hidden, "system process", "system processes")) can't be looked into without sudo.")
                    .font(TextStyle.caption)
                    .foregroundStyle(Palette.tertiaryText)
            }
        }
    }

    private func processes(_ snapshot: Snapshot) -> some View {
        @Bindable var model = model
        let query = ProcessQuery(model.activityQuery)
        let shown = snapshot.processes.filter(query.matches)
        return PageSection(
            title: "Processes",
            detail: query.isEmpty ? nil : "\(shown.count) of \(snapshot.processes.count)"
        ) {
            SearchField(text: $model.activityQuery, focus: $searchFocused)
        } content: {
            ViewportFrame(reserve: 96) {
                ProcessList(
                    processes: shown,
                    columns: [.name, .cpu, .memory, .threads, .blocked, .pid],
                    sort: $model.activitySort,
                    totalMemory: snapshot.memory.total
                )
            }
        }
    }
}

/// A process that needs attention, what was seen, and the fix most likely
/// to help, one click away.
struct AttentionRow: View {
    let item: AttentionItem
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            ProcessIcon(executable: item.executable)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(item.name).font(TextStyle.emphasis).foregroundStyle(Palette.text)
                    Text(item.headline)
                        .font(TextStyle.body)
                        .foregroundStyle(item.level == .normal ? Palette.secondaryText : item.level.color)
                }
                .lineLimit(1)
                Text(item.detail)
                    .font(TextStyle.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.m)
            HStack(spacing: Space.m) {
                Button("Inspect") { model.inspect(item.pid) }
                switch item.remedy {
                case .quit:
                    Button("Quit") { model.quit(item.pid, name: item.name) }
                    Button("Force Quit…") { model.confirmForceQuit(item.pid, name: item.name) }
                case .resume:
                    Button("Resume") { model.send(.resume, to: item.pid, name: item.name) }
                case .inspect:
                    EmptyView()
                }
            }
            .buttonStyle(.link)
            .font(TextStyle.body)
        }
        .padding(.vertical, Space.s)
    }
}
