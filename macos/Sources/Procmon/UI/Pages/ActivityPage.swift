// CPU load, stuck threads and processes hammering the kernel or network.

import SwiftUI

struct ActivityPage: View {
    /// At most this many rows in the "Needs attention" card.
    static let attentionLimit = 8

    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool

    var body: some View {
        PageScroll {
            PageHeader(title: Page.activity.title, subtitle: Page.activity.subtitle)
            if let snapshot = model.monitor.latest {
                processor(snapshot.cpu)
                attention(snapshot)
                processes(snapshot)
            }
        }
        .onChange(of: model.searchRequest) { searchFocused = true }
    }

    private func processor(_ cpu: CPUStats) -> some View {
        let history = model.monitor.cpuHistory
        return Card {
            CardHeader(title: "Processor", symbol: "cpu", tint: .blue) {
                Text(String(format: "Load %.2f · %.2f · %.2f", cpu.load.one, cpu.load.five, cpu.load.fifteen))
                    .monospacedDigit()
            }
            HStack(alignment: .bottom, spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Figure(value: String(format: "%.0f", cpu.total.value * 100), unit: "%", size: 34)
                    Text(SystemInfo.current.coreSummary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.secondaryText)
                }
                .frame(minWidth: 110, alignment: .leading)
                Sparkline(values: history.values, capacity: history.capacity, color: Tint.blue.strong, ceiling: 1)
                    .frame(height: 64)
                    .padding(8)
                    .background(Palette.well, in: .rect(cornerRadius: 10, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Each core")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryText)
                CoreBars(cores: cpu.cores, height: 40)
            }
        }
    }

    private func attention(_ snapshot: Snapshot) -> some View {
        let items = AttentionItem.all(in: snapshot)
        return Card {
            CardHeader(
                title: "Needs attention",
                symbol: items.isEmpty ? "checkmark.seal" : "exclamationmark.triangle",
                tint: items.isEmpty ? .green : .red
            ) {
                Text(coverageNote(snapshot.coverage))
            }
            if items.isEmpty {
                Text("No blocked threads, and no process is flooding the kernel or network.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText)
            } else {
                VStack(spacing: 2) {
                    ForEach(items.prefix(Self.attentionLimit)) { item in
                        AttentionRow(item: item)
                    }
                }
                if items.count > Self.attentionLimit {
                    Text("and \(items.count - Self.attentionLimit) more")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText)
                }
            }
        }
    }

    private func coverageNote(_ coverage: ProbeCoverage) -> String {
        coverage.denied == 0
            ? "All processes inspected"
            : "\(coverage.denied) system processes hidden · run with sudo to include them"
    }

    private func processes(_ snapshot: Snapshot) -> some View {
        @Bindable var model = model
        let query = ProcessQuery(model.activityQuery)
        return ViewportCard {
            HStack(spacing: 12) {
                CardHeader(title: "Processes", symbol: "list.bullet", tint: .blue) {
                    Text("sorted by \(model.activitySort.column.title.lowercased())")
                }
                SearchField(text: $model.activityQuery, focus: $searchFocused)
            }
            ProcessList(
                processes: snapshot.processes.filter(query.matches),
                columns: [.name, .cpu, .syscalls, .contextSwitches, .wakeups, .received, .sent, .packets, .diskRead, .diskWrite, .threads, .pid],
                sort: $model.activitySort,
                totalMemory: snapshot.memory.total
            )
        }
    }
}

/// One line in a "Needs attention" list; clicking it opens the process.
struct AttentionRow: View {
    let item: AttentionItem
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        Button {
            model.inspect(item.pid)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(item.tint.strong)
                    .frame(width: 28, height: 28)
                    .background(item.tint.fill, in: .circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(item.process) (\(item.pid.description))")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                    Text(item.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Tag(text: item.tag, tint: item.tint)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(hovering ? Palette.surfaceHover : .clear, in: .rect(cornerRadius: 9, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
