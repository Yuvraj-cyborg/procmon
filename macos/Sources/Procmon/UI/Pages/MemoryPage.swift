// Where RAM is going, and who is holding it.

import SwiftUI

struct MemoryPage: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        PageScroll {
            if let snapshot = model.monitor.latest {
                let memory = snapshot.memory
                PageHeader(title: Page.memory.title, subtitle: Page.memory.subtitle) {
                    Tag(text: "Pressure · \(memory.pressure.label)", tint: .pressure(memory.pressure))
                }
                overview(memory)
                consumers(snapshot, query: ProcessQuery(model.memoryQuery))
            } else {
                PageHeader(title: Page.memory.title, subtitle: Page.memory.subtitle)
            }
        }
        .onChange(of: model.searchRequest) { searchFocused = true }
    }

    private func overview(_ memory: MemoryStats) -> some View {
        let history = model.monitor.memoryHistory
        return Card {
            CardHeader(title: "Physical memory", symbol: "memorychip", tint: .purple) {
                Text("\(memory.used.binary) of \(memory.total.binary) used · \(memory.used.ratio(of: memory.total).percent.description)")
                    .monospacedDigit()
            }
            Meter(segments: MemorySegments.segments(memory.breakdown, total: memory.total), height: 12)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 16, alignment: .topLeading)], alignment: .leading, spacing: 12) {
                ForEach(MemorySegments.parts(memory.breakdown), id: \.label) { part in
                    StatView(label: part.label, value: part.bytes.binary, dot: part.tint.strong)
                }
                StatView(label: "Available", value: memory.available.binary, hint: "\(memory.breakdown.free.binary) completely free")
                StatView(label: "Swap used", value: memory.swapUsed.binary, hint: "of \(memory.swapTotal.binary)")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Used, last two minutes")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryText)
                Sparkline(values: history.values, capacity: history.capacity, color: Tint.purple.strong, ceiling: 1)
                    .frame(height: 56)
                    .padding(8)
                    .background(Palette.well, in: .rect(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private func consumers(_ snapshot: Snapshot, query: ProcessQuery) -> some View {
        @Bindable var model = model
        @Bindable var preferences = model.preferences
        let processes = snapshot.processes.filter(query.matches)
        return ViewportCard {
            HStack(spacing: 12) {
                CardHeader(title: "Who is using memory", symbol: "person.2", tint: .blue) {
                    Text("\(snapshot.processes.count) processes")
                }
                SearchField(text: $model.memoryQuery, focus: $searchFocused)
                Toggle("By app", isOn: $preferences.groupByApp)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize()
            }
            if preferences.groupByApp {
                AppList(
                    apps: snapshot.processes.groupedByApp().filter(query.matches),
                    processes: Dictionary(snapshot.processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first }),
                    totalMemory: snapshot.memory.total
                )
            } else {
                ProcessList(
                    processes: processes,
                    columns: [.name, .memory, .memoryShare, .threads, .cpu, .pid, .runTime],
                    sort: $model.memorySort,
                    totalMemory: snapshot.memory.total
                )
            }
        }
    }
}
