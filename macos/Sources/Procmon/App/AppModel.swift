// App-wide state: the current page, the shared models, and the requests
// (confirmations, toasts, inspector) that any page can make.

import Foundation
import Observation

/// A destructive action waiting for the user to confirm it.
struct Confirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let actionTitle: String
    let action: @MainActor () -> Void
}

/// A short message that fades away on its own.
struct Toast: Identifiable, Equatable {
    enum Kind { case success, failure }

    let id = UUID()
    let message: String
    let kind: Kind
}

@MainActor
@Observable
final class AppModel {
    var page: Page
    let monitor = Monitor()
    let storage = StorageModel()
    let devices = DevicesModel()
    let preferences = Preferences()

    /// Process shown in the details panel.
    private(set) var inspectedPID: PID?
    var isInspectorPresented = false {
        didSet { if !isInspectorPresented { inspectedPID = nil } }
    }

    var confirmation: Confirmation?
    var toast: Toast?

    /// Bumped by ⌘F; pages with a filter field focus it.
    private(set) var searchRequest = 0
    var memoryQuery = ""
    var activityQuery = ""
    var memorySort = ProcessSort.by(.memory)
    var activitySort = ProcessSort.by(.cpu)

    init(launch: LaunchOptions) {
        page = launch.initialPage
        monitor.start()
        devices.refresh()
        if let root = launch.scan {
            storage.scan(root)
        }
        if let pid = launch.inspect {
            inspect(pid)
        }
    }

    func inspect(_ pid: PID) {
        inspectedPID = pid
        isInspectorPresented = true
    }

    func requestSearch() {
        searchRequest += 1
    }

    /// ⌘R: Memory and Activity update live; the other pages reload.
    func refresh() {
        switch page {
        case .storage:
            storage.rescan()
            storage.refreshVolumes()
        case .devices, .overview:
            devices.refresh()
        case .memory, .activity:
            break
        }
    }

    func show(_ message: String, kind: Toast.Kind = .success) {
        toast = Toast(message: message, kind: kind)
    }

    /// Sends `SIGTERM` and reports the outcome.
    func quit(_ pid: PID, name: String) {
        do {
            try ProcessControl.send(.terminate, to: pid)
            show("Asked \(name) to quit.")
        } catch {
            show("Couldn't quit \(name): \(error).", kind: .failure)
        }
    }

    /// Asks for confirmation, then sends `SIGKILL`.
    func confirmForceQuit(_ pid: PID, name: String) {
        confirmation = Confirmation(
            title: "Force quit \(name)?",
            message: "It stops immediately. Any unsaved work in it will be lost.",
            actionTitle: "Force Quit"
        ) { [weak self] in
            guard let self else { return }
            do {
                try ProcessControl.send(.kill, to: pid)
                show("\(name) was force quit.")
            } catch {
                show("Couldn't force quit \(name): \(error).", kind: .failure)
            }
        }
    }

    /// Asks for confirmation, then moves a scanned item to the Trash.
    func confirmTrash(_ node: NodeID) {
        guard let browser = storage.browser, node != .root, let path = browser.tree.path(of: node) else { return }
        let item = browser.tree[node]
        let generation = browser.generation
        confirmation = Confirmation(
            title: "Move “\(item.name)” to the Trash?",
            message: "\(item.size.decimal) will be freed once you empty the Trash. You can put it back from Finder until then.",
            actionTitle: "Move to Trash"
        ) { [weak self] in
            guard let self else { return }
            do {
                try storage.trash(node, path: path, generation: generation)
                show("Moved \(item.name) to the Trash.")
            } catch {
                show("Couldn't move \(item.name) to the Trash: \(error.localizedDescription)", kind: .failure)
            }
        }
    }
}
