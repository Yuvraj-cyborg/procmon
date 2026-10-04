// Where RAM is going, who is holding it, and which idle apps could give it back.

import SwiftUI

struct MemoryPage: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool

    var body: some View {
        PageScroll {
            if let snapshot = model.monitor.latest {
                let memory = snapshot.memory
                let idle = model.cleanup.idleApps(model.monitor)
                PageHeader(title: Page.memory.title, detail: "\(memory.used.binary) of \(memory.total.binary) used") {
                    if !idle.isEmpty {
                        Button("Quit Idle Apps…") { model.confirmQuitIdle(idle) }
                            .help("Apps that have used almost no CPU for a minute but hold a lot of memory")
                    }
                }
                overview(memory)
                consumers(snapshot, idle: idle)
            } else {
                PageHeader(title: Page.memory.title)
            }
        }
        .onChange(of: model.searchRequest) { searchFocused = true }
    }

    private func overview(_ memory: MemoryStats) -> some View {
        let history = model.monitor.memoryHistory
        let level = Level.pressure(memory.pressure)
        let minutes = Int((Double(history.capacity) * model.monitor.interval.seconds / 60).rounded())
        return VStack(alignment: .leading, spacing: Space.l) {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                ValueText(value: memory.used.ratio(of: memory.total).percent.description)
                Text(level == .normal ? "No memory pressure" : "\(memory.pressure.label) memory pressure: macOS is compressing and swapping to make room")
                    .font(TextStyle.body)
                    .foregroundStyle(level == .normal ? Palette.secondaryText : level.color)
                    .lineLimit(2)
            }
            CompositionBar(portions: memory.breakdown.portions, total: memory.total)
            HStack(alignment: .bottom, spacing: Space.xxl) {
                HStack(alignment: .top, spacing: Space.xxl) {
                    StatView(label: "Available", value: memory.available.binary, hint: "\(memory.breakdown.free.binary) free")
                    StatView(
                        label: "Swap", value: memory.swapUsed.binary, hint: "of \(memory.swapTotal.binary)",
                        level: memory.swapUsed > .zero && level != .normal ? .warning : .normal
                    )
                }
                .fixedSize()
                VStack(alignment: .leading, spacing: Space.xs) {
                    Sparkline(values: history.values, capacity: history.capacity, ceiling: 1)
                        .frame(height: 36)
                    Text("Used, last \(Format.count(minutes, "minute"))")
                        .font(TextStyle.caption)
                        .foregroundStyle(Palette.tertiaryText)
                }
            }
        }
    }

    private func consumers(_ snapshot: Snapshot, idle: [IdleAppSuggestion]) -> some View {
        @Bindable var model = model
        @Bindable var preferences = model.preferences
        let query = ProcessQuery(model.memoryQuery)
        let byApp = preferences.groupByApp
        return PageSection(title: byApp ? "Apps" : "Processes", detail: idle.isEmpty ? nil : "\(Format.count(idle.count, "idle app")) holding \(idle.map(\.memory).sum().binary)") {
            HStack(spacing: Space.s) {
                Picker("Group", selection: $preferences.groupByApp) {
                    Text("Apps").tag(true)
                    Text("Processes").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                SearchField(text: $model.memoryQuery, focus: $searchFocused)
            }
        } content: {
            ViewportFrame(reserve: 96) {
                if byApp {
                    AppList(
                        apps: snapshot.apps.filter(query.matches),
                        processes: Dictionary(snapshot.processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first }),
                        totalMemory: snapshot.memory.total,
                        idle: Dictionary(idle.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
                    )
                } else {
                    ProcessList(
                        processes: snapshot.processes.filter(query.matches),
                        columns: [.name, .memory, .memoryShare, .cpu, .threads, .pid],
                        sort: $model.memorySort,
                        totalMemory: snapshot.memory.total
                    )
                }
            }
        }
    }
}
