// Side panel with live details for one process, including every thread's
// run state: the place to look when something is stuck.

import SwiftUI

struct ProcessInspector: View {
    @Environment(AppModel.self) private var model
    /// Threads as last read, tagged with their process: a slow read for the
    /// previous selection must never show under the next one.
    @State private var loaded: LoadedThreads?

    private struct LoadedThreads {
        let pid: PID
        /// `nil` when the process cannot be inspected.
        let threads: [ThreadSample]?
    }

    private struct Refresh: Equatable {
        let pid: PID
        let sample: Int
    }

    var body: some View {
        Group {
            if let pid = model.inspectedPID {
                ScrollView {
                    content(pid)
                        .padding(18)
                }
                .task(id: Refresh(pid: pid, sample: model.monitor.samples)) {
                    let threads = await offMain(qos: .utility) { ProcessProbe.inspectThreads(pid) }
                    guard !Task.isCancelled, model.inspectedPID == pid else { return }
                    loaded = LoadedThreads(pid: pid, threads: threads)
                }
            } else {
                EmptyState(symbol: "sidebar.trailing", title: "No process selected", detail: "Click a process to see its threads and live counters.")
            }
        }
        .background(Palette.surface)
        .toolbar {
            ToolbarItem {
                Button {
                    model.isInspectorPresented.toggle()
                } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .help(model.isInspectorPresented ? "Hide process details" : "Show process details")
            }
        }
    }

    @ViewBuilder
    private func content(_ pid: PID) -> some View {
        let process = model.monitor.process(pid)
        VStack(alignment: .leading, spacing: 18) {
            identity(pid, process: process)
            if let process {
                if process.isRestricted {
                    Label("macOS only shares this process's details with administrators. Run Procmon with sudo to see them.", systemImage: "lock")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryText)
                } else {
                    stats(process)
                }
                actions(process)
                threadList(loaded?.pid == pid ? loaded : nil)
            } else {
                Text("This process has exited.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func identity(_ pid: PID, process: ProcessSample?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ProcessIcon(executable: process?.executable, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(process?.name ?? "PID \(pid)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Palette.text)
                        .lineLimit(2)
                    Text(process.map { $0.app == $0.name ? "PID \(pid.description)" : "PID \(pid.description) · part of \($0.app)" } ?? "PID \(pid.description)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.secondaryText)
                }
            }
            if let path = process?.executable {
                HStack(spacing: 6) {
                    Text(path)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button {
                        Finder.reveal(path)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal executable in Finder")
                }
                .padding(8)
                .background(Palette.well, in: .rect(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func stats(_ process: ProcessSample) -> some View {
        let dash = "–"
        let activity = process.activity
        let network = process.network
        let metrics = process.metrics
        return Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 14) {
            GridRow {
                StatView(label: "Memory", value: process.memory?.binary ?? dash)
                StatView(label: "CPU", value: process.cpu?.description ?? dash, hint: "of one core")
            }
            GridRow {
                StatView(label: "Running for", value: process.runTime?.compact ?? dash)
                StatView(label: "Threads", value: metrics.map { "\($0.threads)" } ?? dash)
            }
            GridRow {
                StatView(label: "Disk read", value: metrics?.diskRead.description ?? dash, hint: metrics.map { "\($0.diskWrite) written" })
                StatView(label: "Network in", value: network?.received.description ?? dash, hint: network.map { "\($0.sent) sent" })
            }
            GridRow {
                StatView(label: "Syscalls", value: activity?.syscalls.description ?? dash,
                         hint: activity.map { "\($0.contextSwitches) switches" })
                StatView(label: "Wakeups", value: activity?.idleWakeups.description ?? dash,
                         hint: activity.map { "\($0.machMessages) IPC messages" })
            }
        }
    }

    private func actions(_ process: ProcessSample) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("Quit") { model.quit(process.pid, name: process.name) }
                Button("Force Quit…", role: .destructive) { model.confirmForceQuit(process.pid, name: process.name) }
            }
            .controlSize(.regular)
            Text("Quit asks politely; Force Quit cannot be ignored.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.tertiaryText)
        }
    }

    @ViewBuilder
    private func threadList(_ loaded: LoadedThreads?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let threads = loaded?.threads {
                let sorted = threads.sorted { ($0.state, -$0.cpu.value) < ($1.state, -$1.cpu.value) }
                HStack {
                    Text("Threads (\(threads.count))")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.text)
                    Spacer()
                    Text(summary(threads))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText)
                }
                LazyVStack(spacing: 0) {
                    ForEach(sorted) { thread in
                        HStack(spacing: 8) {
                            Circle().fill(color(thread.state)).frame(width: 7, height: 7)
                            Text(thread.displayName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(Palette.text)
                            Spacer(minLength: 6)
                            Text(thread.state.label)
                                .foregroundStyle(Palette.secondaryText)
                                .frame(width: 64, alignment: .leading)
                            Text(thread.cpu.percent.description)
                                .monospacedDigit()
                                .foregroundStyle(Palette.text)
                                .frame(width: 44, alignment: .trailing)
                        }
                        .font(.system(size: 11.5))
                        .frame(height: 24)
                    }
                }
            } else if loaded != nil {
                Text("Thread details need permission. Run Procmon with sudo to inspect system processes.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func summary(_ threads: [ThreadSample]) -> String {
        [ThreadRunState.running, .waiting, .uninterruptible, .stopped]
            .compactMap { state in
                let count = threads.count { $0.state == state }
                return count > 0 ? "\(count) \(state.label.lowercased())" : nil
            }
            .joined(separator: " · ")
    }

    private func color(_ state: ThreadRunState) -> Color {
        switch state {
        case .running: Tint.green.strong
        case .uninterruptible: Tint.orange.strong
        case .stopped, .halted: Tint.red.strong
        case .waiting, .unknown: Palette.tertiaryText
        }
    }
}
