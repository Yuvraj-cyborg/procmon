// Side panel for one process: what it is, what to do about it, and every
// thread down to the call it is waiting in.

import SwiftUI

struct ProcessInspector: View {
    @Environment(AppModel.self) private var model
    /// Details read off the main thread, tagged with their process: a slow
    /// read for the previous selection must never show under the next one.
    @State private var loaded: LoadedDetails?
    @State private var showFiles = false
    @State private var files: LoadedFiles?

    private struct LoadedDetails {
        let pid: PID
        /// `nil` when the process cannot be inspected.
        let threads: [ThreadSample]?
        let arguments: [String]?
    }

    private struct LoadedFiles {
        let pid: PID
        /// `nil` when the process cannot be inspected.
        let files: [OpenFile]?
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
                        .padding(Space.l)
                }
                .task(id: Refresh(pid: pid, sample: model.monitor.samples)) {
                    await refresh(pid)
                }
            } else {
                Note("Select a process to see its threads.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.panel)
        .onAppear { model.monitor.needsProcessNetwork(true) }
        .onDisappear { model.monitor.needsProcessNetwork(false) }
        .toolbar {
            ToolbarItem {
                Button {
                    model.isInspectorPresented.toggle()
                } label: {
                    GlyphImage(.inspector, size: 15)
                }
                .help(model.isInspectorPresented ? "Hide the inspector" : "Show the inspector")
            }
        }
    }

    /// Re-reads threads each sample, arguments once, and open files while shown.
    private func refresh(_ pid: PID) async {
        let known = loaded?.pid == pid ? loaded?.arguments : nil
        let needsArguments = loaded?.pid != pid
        let wantsFiles = showFiles
        let result = await offMain(qos: .utility) {
            (
                threads: ProcessProbe.inspectThreads(pid),
                arguments: needsArguments ? ProcessProbe.arguments(pid) : nil,
                files: wantsFiles ? ProcessProbe.openFiles(pid) : nil
            )
        }
        guard !Task.isCancelled, model.inspectedPID == pid else { return }
        loaded = LoadedDetails(pid: pid, threads: result.threads, arguments: needsArguments ? result.arguments : known)
        if wantsFiles {
            files = LoadedFiles(pid: pid, files: result.files)
        }
    }

    @ViewBuilder
    private func content(_ pid: PID) -> some View {
        let process = model.monitor.process(pid)
        let details = loaded?.pid == pid ? loaded : nil
        VStack(alignment: .leading, spacing: Space.xxl) {
            identity(pid, process: process)
            if let process {
                actions(process, threads: details?.threads)
                if process.isRestricted {
                    Note("macOS shares this process's details only with administrators. Run Procmon with sudo to see them.")
                } else {
                    facts(process)
                }
                origin(process, arguments: details?.arguments)
                ThreadSection(pid: pid, threads: details?.threads, isLoading: details == nil)
                openFiles(pid)
            } else {
                Note("This process has exited.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func identity(_ pid: PID, process: ProcessSample?) -> some View {
        HStack(spacing: Space.m) {
            if AppIcons.icon(for: process?.executable) != nil {
                ProcessIcon(executable: process?.executable, size: 32)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(process?.name ?? "PID \(pid.description)")
                    .font(TextStyle.title)
                    .foregroundStyle(Palette.text)
                    .lineLimit(2)
                Text(subtitle(pid, process: process))
                    .font(TextStyle.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(2)
            }
        }
    }

    private func subtitle(_ pid: PID, process: ProcessSample?) -> String {
        guard let process else { return "PID \(pid.description)" }
        var parts = ["PID \(pid.description)", process.user]
        if process.isTranslated { parts.append("Intel, under Rosetta") }
        if process.app != process.name { parts.append("part of \(process.app)") }
        return parts.joined(separator: " · ")
    }

    private func actions(_ process: ProcessSample, threads: [ThreadSample]?) -> some View {
        let isPaused = threads.map { !$0.isEmpty && $0.allSatisfy { $0.state == .stopped } } ?? false
        return HStack(spacing: Space.s) {
            Button("Quit") { model.quit(process.pid, name: process.name) }
                .help("Ask it to quit. Apps can save their work first.")
            Button("Force Quit…") { model.confirmForceQuit(process.pid, name: process.name) }
                .help("Stop it at once. Unsaved work is lost.")
            if isPaused {
                Button("Resume") { model.send(.resume, to: process.pid, name: process.name) }
            } else {
                Button("Pause") { model.send(.pause, to: process.pid, name: process.name) }
                    .help("Freeze every thread until you resume it.")
            }
        }
        .controlSize(.regular)
        .disabled(process.pid.raw == getpid())
    }

    private func facts(_ process: ProcessSample) -> some View {
        let dash = "–"
        let metrics = process.metrics
        let network = process.network
        return Grid(alignment: .topLeading, horizontalSpacing: Space.xl, verticalSpacing: Space.m) {
            GridRow {
                StatView(label: "Memory", value: process.memory?.binary ?? dash, hint: metrics.map { "\($0.resident.binary) resident" })
                StatView(label: "CPU", value: process.cpu?.description ?? dash, hint: metrics.map { "\(Format.clock($0.cpuTime)) in all" })
            }
            GridRow {
                StatView(label: "Running for", value: process.runTime?.compact ?? dash)
                StatView(
                    label: "Power", value: metrics?.power.map(Format.watts) ?? dash,
                    hint: process.preventsSleep ? "Keeping the Mac awake" : nil
                )
            }
            GridRow {
                StatView(label: "Disk", value: metrics.map { "\($0.diskRead) read" } ?? dash, hint: metrics.map { "\($0.diskWrite) written" })
                StatView(label: "Network", value: network.map { "\($0.received) in" } ?? dash, hint: network.map { "\($0.sent) out" })
            }
        }
    }

    @ViewBuilder
    private func origin(_ process: ProcessSample, arguments: [String]?) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let parentPID = process.parent {
                let parent = model.monitor.process(parentPID)
                HStack(spacing: Space.xs) {
                    Text("Started by").foregroundStyle(Palette.secondaryText)
                    Button("\(parent?.name ?? "PID \(parentPID.description)")") { model.inspect(parentPID) }
                        .buttonStyle(.link)
                }
                .font(TextStyle.caption)
            }
            if let path = process.executable {
                HStack(alignment: .top, spacing: Space.s) {
                    Text(path)
                        .font(TextStyle.code)
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: Space.xs)
                    Button {
                        Finder.reveal(path)
                    } label: {
                        GlyphImage(.folder, size: 13)
                    }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                }
            }
            if let arguments, arguments.count > 1 {
                Text(arguments.dropFirst().joined(separator: " "))
                    .font(TextStyle.code)
                    .foregroundStyle(Palette.tertiaryText)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
        }
    }

    private func openFiles(_ pid: PID) -> some View {
        DisclosureGroup(isExpanded: $showFiles) {
            let current = files?.pid == pid ? files : nil
            LazyVStack(alignment: .leading, spacing: 0) {
                if let list = current?.files {
                    let shown = list.sorted { ($0.kind == .socket ? 0 : 1, $0.name) < ($1.kind == .socket ? 0 : 1, $1.name) }
                    ForEach(shown.prefix(300)) { file in
                        HStack(spacing: Space.s) {
                            Text(file.kind == .socket ? "net" : file.kind == .pipe ? "pipe" : "file")
                                .foregroundStyle(Palette.tertiaryText)
                                .frame(width: 28, alignment: .leading)
                            Text(file.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(Palette.text)
                                .textSelection(.enabled)
                            Spacer(minLength: Space.xs)
                            Text("\(file.descriptor)").foregroundStyle(Palette.tertiaryText)
                        }
                        .font(TextStyle.caption)
                        .monospacedDigit()
                        .frame(height: 22)
                    }
                    if list.count > 300 {
                        Text("and \(list.count - 300) more").font(TextStyle.caption).foregroundStyle(Palette.tertiaryText)
                    }
                } else if current != nil {
                    Note("Open files of other users' processes need sudo.")
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.top, Space.s)
        } label: {
            Text("Open files and connections")
                .font(TextStyle.emphasis)
                .foregroundStyle(Palette.text)
        }
        .onChange(of: showFiles) {
            guard showFiles else { return }
            Task {
                let list = await offMain(qos: .userInitiated) { ProcessProbe.openFiles(pid) }
                if model.inspectedPID == pid { files = LoadedFiles(pid: pid, files: list) }
            }
        }
    }
}

/// Every thread, the troubled ones first. Reading stacks samples the process
/// for a second and says what each thread is waiting in.
private struct ThreadSection: View {
    let pid: PID
    let threads: [ThreadSample]?
    let isLoading: Bool
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<ThreadID> = []

    var body: some View {
        let state = model.stacks.state(for: pid)
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text("Threads").font(TextStyle.emphasis).foregroundStyle(Palette.text)
                if let threads {
                    Text(summary(threads))
                        .font(TextStyle.caption)
                        .monospacedDigit()
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: Space.s)
                if threads != nil {
                    readButton(state)
                }
            }
            if let threads {
                if case .failed(let message) = state {
                    Text("Couldn't read stacks: \(message)")
                        .font(TextStyle.caption)
                        .foregroundStyle(Level.critical.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let stacks: [ThreadID: ThreadStack] = if case .loaded(let stacks, _) = state { stacks } else { [:] }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(ordered(threads)) { thread in
                        ThreadRow(
                            thread: thread,
                            stack: stacks[thread.id],
                            isExpanded: expanded.contains(thread.id),
                            toggle: { toggle(thread.id) }
                        )
                    }
                }
                Text("macOS doesn't let one app stop another app's threads: a thread can only be ended from inside its own process. Pause freezes all of them; Force Quit ends the process and every thread with it.")
                    .font(TextStyle.caption)
                    .foregroundStyle(Palette.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Note("Threads of other users' processes need sudo.")
            }
        }
    }

    @ViewBuilder
    private func readButton(_ state: StackModel.State?) -> some View {
        switch state {
        case .loading:
            HStack(spacing: Space.xs) {
                ProgressView().controlSize(.mini)
                Text("Reading…").font(TextStyle.caption).foregroundStyle(Palette.secondaryText)
            }
        case .loaded(_, let date):
            Button("Read again") { model.stacks.capture(pid) }
                .buttonStyle(.link)
                .font(TextStyle.caption)
                .help("Stacks read \(date.formatted(date: .omitted, time: .standard))")
        case .failed, nil:
            Button("Read stacks") { model.stacks.capture(pid) }
                .buttonStyle(.link)
                .font(TextStyle.caption)
                .help("Sample the process for a second to see what each thread is doing")
        }
    }

    private func toggle(_ id: ThreadID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    /// Blocked, then stopped, then busiest running, then waiting.
    private func ordered(_ threads: [ThreadSample]) -> [ThreadSample] {
        threads.sorted { ($0.state, -$0.cpu.value, $0.id.raw) < ($1.state, -$1.cpu.value, $1.id.raw) }
    }

    private func summary(_ threads: [ThreadSample]) -> String {
        var parts = ["\(threads.count)"]
        for state in [ThreadRunState.uninterruptible, .stopped, .running] {
            let count = threads.count { $0.state == state }
            if count > 0 { parts.append("\(count) \(state.label.lowercased())") }
        }
        return parts.joined(separator: " · ")
    }
}

private struct ThreadRow: View {
    let thread: ThreadSample
    let stack: ThreadStack?
    let isExpanded: Bool
    let toggle: () -> Void
    @State private var hovering = false

    /// Only states worth noticing are coloured.
    private var level: Level {
        switch thread.state {
        case .uninterruptible: .critical
        case .stopped: .warning
        default: .normal
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    GlyphImage(.chevron, size: 8)
                        .foregroundStyle(stack == nil ? .clear : Palette.tertiaryText)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(thread.displayName)
                            .font(TextStyle.body)
                            .foregroundStyle(Palette.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let stack {
                            Text(stack.activity.summary)
                                .font(TextStyle.caption)
                                .foregroundStyle(stack.activity.mayBeStuck ? Level.warning.color : Palette.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: Space.s)
                    Text(thread.state.label)
                        .font(TextStyle.caption)
                        .foregroundStyle(level == .normal ? Palette.tertiaryText : level.color)
                    Text(thread.cpu.value > 0.001 ? thread.cpu.percent.description : "")
                        .font(TextStyle.caption)
                        .monospacedDigit()
                        .foregroundStyle(Palette.secondaryText)
                        .frame(width: 36, alignment: .trailing)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, Space.xs)
                .background(hovering && stack != nil ? Palette.hover : .clear, in: .rect(cornerRadius: 5))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            // Nothing to expand until stacks are read; stay full strength.
            .allowsHitTesting(stack != nil)
            .onHover { hovering = $0 }
            if isExpanded, let stack {
                StackFrames(stack: stack)
                    .padding(.leading, 20)
                    .padding(.bottom, Space.s)
            }
        }
    }
}

/// A thread's heaviest call path, innermost call first, as `sample` saw it.
private struct StackFrames: View {
    let stack: ThreadStack
    /// Deep stacks are mostly run-loop plumbing; the top says what matters.
    private static let shown = 14

    var body: some View {
        let frames = Array(stack.frames.reversed())
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(frames.prefix(Self.shown).enumerated()), id: \.offset) { _, frame in
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(frame.symbol)
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: Space.xs)
                    Text(frame.library ?? "")
                        .foregroundStyle(Palette.tertiaryText)
                        .lineLimit(1)
                }
            }
            if frames.count > Self.shown {
                Text("\(frames.count - Self.shown) more frames")
                    .foregroundStyle(Palette.tertiaryText)
            }
            if stack.total > 0 {
                Text("On this path in \(stack.samples) of \(stack.total) samples")
                    .foregroundStyle(Palette.tertiaryText)
                    .padding(.top, 2)
            }
        }
        .font(TextStyle.code)
        .textSelection(.enabled)
    }
}
