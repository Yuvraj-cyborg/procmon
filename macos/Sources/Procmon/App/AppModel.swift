// App-wide state: the current page, the shared models, and the requests
// (confirmations, toasts, inspector) that any page can make.

import AppKit
import Foundation
import Observation
import SwiftUI

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
    let cleanup = CleanupModel()
    let stacks = StackModel()
    let preferences = Preferences()

    /// Process shown in the details panel.
    private(set) var inspectedPID: PID?
    var isInspectorPresented = false {
        didSet { if !isInspectorPresented { inspectedPID = nil } }
    }

    var confirmation: Confirmation?
    var toast: Toast?
    /// The reclaimable-files sheet is open.
    var isReviewingJunk = false
    /// A scan waiting on the one-time Full Disk Access question.
    var diskAccessRequest: String?

    /// Bumped by ⌘F; pages with a filter field focus it.
    private(set) var searchRequest = 0
    var memoryQuery = ""
    var activityQuery = ""
    var memorySort = ProcessSort.by(.memory)
    var activitySort = ProcessSort.by(.cpu)

    init(launch: LaunchOptions) {
        page = launch.initialPage
        monitor.interval = preferences.updateSpeed.interval
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
            cleanup.scan(monitor)
        case .devices, .overview:
            devices.refresh()
        case .memory, .activity:
            break
        }
    }

    func show(_ message: String, kind: Toast.Kind = .success) {
        toast = Toast(message: message, kind: kind)
    }

    /// Scans `path`, first asking once for Full Disk Access if the scan
    /// would reach folders macOS guards one by one.
    func scan(_ path: String) {
        if !preferences.askedForDiskAccess, !Permissions.hasFullDiskAccess, Permissions.touchesProtectedFolders(path) {
            diskAccessRequest = path
        } else {
            storage.scan(path)
        }
    }

    /// Answers the Full Disk Access question: open Settings to grant it, or
    /// scan now without the protected folders. Either way it is not asked again.
    func answerDiskAccess(grant: Bool) {
        preferences.askedForDiskAccess = true
        let path = diskAccessRequest
        diskAccessRequest = nil
        if grant {
            Permissions.openFullDiskAccessSettings()
        } else if let path {
            storage.scan(path)
        }
    }

    /// Opens the reclaimable-files review on the Storage page.
    func reviewJunk() {
        withAnimation(.snappy(duration: 0.3)) { page = .storage }
        cleanup.scanIfNeeded(monitor)
        isReviewingJunk = true
    }

    /// Quits an app the way its own Quit command would.
    func quitApp(_ app: IdleAppSuggestion) {
        if app.application.terminate() {
            show("Asked \(app.name) to quit.")
        } else {
            show("\(app.name) didn't accept the request to quit.", kind: .failure)
        }
    }

    /// Asks for confirmation, then quits every idle app.
    func confirmQuitIdle(_ apps: [IdleAppSuggestion]) {
        guard !apps.isEmpty else { return }
        let names = apps.prefix(3).map(\.name).joined(separator: ", ") + (apps.count > 3 ? " and \(apps.count - 3) more" : "")
        confirmation = Confirmation(
            title: "Quit \(apps.count == 1 ? apps[0].name : "\(apps.count) idle apps")?",
            message: "\(names) \(apps.count == 1 ? "has" : "have") used almost no CPU for a while and hold \(apps.map(\.memory).sum().binary). Each app can save its work before it quits.",
            actionTitle: "Quit"
        ) { [weak self] in
            for app in apps { app.application.terminate() }
            self?.show("Asked \(apps.count == 1 ? apps[0].name : "\(apps.count) apps") to quit.")
        }
    }

    /// Asks an app to quit through AppKit, so it can save first; other
    /// processes get `SIGTERM`.
    func quit(_ pid: PID, name: String) {
        if let application = monitor.runningApps[pid]?.application {
            if application.terminate() {
                show("Asked \(name) to quit.")
            } else {
                show("\(name) didn't accept the request to quit.", kind: .failure)
            }
            return
        }
        do {
            try ProcessControl.send(.terminate, to: pid)
            show("Asked \(name) to quit.")
        } catch {
            show("Couldn't quit \(name): \(error).", kind: .failure)
        }
    }

    func send(_ signal: ProcessSignal, to pid: PID, name: String) {
        do {
            try ProcessControl.send(signal, to: pid)
            show("Sent \(signal.label) to \(name).")
        } catch {
            show("Couldn't signal \(name): \(error).", kind: .failure)
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
