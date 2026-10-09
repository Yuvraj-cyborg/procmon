// The window's content: a floating toolbar over the current page, plus the
// process inspector, confirmations and toasts that any page can raise.

import AppKit
import SwiftUI

struct RootView: View {
    /// The page keeps at least this much room next to the inspector; below
    /// its comfortable width, pages wrap rather than overflow.
    static let minimumPageWidth: CGFloat = 420
    static let comfortablePageWidth: CGFloat = 600
    static let inspectorWidth: CGFloat = 340

    @Environment(AppModel.self) private var model
    @State private var width: CGFloat = 1200
    @State private var window: NSWindow?

    var body: some View {
        @Bindable var model = model
        PageContainer(page: model.page)
            .frame(minWidth: Self.minimumPageWidth, maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.canvas)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .toolbar {
                // Narrow windows keep their toolbar room for the pages.
                if width >= 900 {
                    ToolbarItem(placement: .navigation) {
                        BrandMark(compact: width < 1_020)
                    }
                    .withoutSharedBackground()
                }
                ToolbarItem(placement: .principal) {
                    NavBar(selection: $model.page, compact: width < 1_020)
                }
                .withoutSharedBackground()
                ToolbarItem(placement: .primaryAction) {
                    SettingsMenu(preferences: model.preferences)
                }
            }
            .toolbar(removing: .title)
            .inspector(isPresented: $model.isInspectorPresented) {
                ProcessInspector()
                    .inspectorColumnWidth(min: 300, ideal: Self.inspectorWidth, max: 480)
            }
            .overlay(alignment: .bottom) {
                ToastOverlay()
            }
            .alert(
                model.confirmation?.title ?? "",
                isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.confirmation = nil } }),
                presenting: model.confirmation
            ) { confirmation in
                Button(confirmation.actionTitle, role: .destructive) { confirmation.action() }
                Button("Cancel", role: .cancel) {}
            } message: { confirmation in
                Text(confirmation.message)
            }
            .onAppear { model.preferences.applyAppearance() }
            .onChange(of: model.preferences.updateSpeed) { model.monitor.interval = model.preferences.updateSpeed.interval }
            // A hidden, minimised or fully covered window needs almost no work.
            .background(WindowVisibility(window: $window) { model.monitor.setVisible($0) })
            // Opening the inspector widens the window rather than crushing the page.
            .onChange(of: model.isInspectorPresented) { makeRoomForInspector() }
            .onChange(of: window) {
                // Launch restores the window frame after it appears; widen after that.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { makeRoomForInspector() }
            }
    }
}

/// Reports whether the hosting window can be seen: on screen, not covered,
/// not minimised, and the app not hidden. Checked when the window appears
/// and whenever any of those can change.
private struct WindowVisibility: NSViewRepresentable {
    @Binding var window: NSWindow?
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.changed = changed
        probe.found = { window = $0 }
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.changed = changed
    }

    final class Probe: NSView {
        var changed: ((Bool) -> Void)?
        var found: ((NSWindow?) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            let window = self.window
            DispatchQueue.main.async { [found] in found?(window) }
            guard let window else { return }
            let center = NotificationCenter.default
            let events: [(Notification.Name, AnyObject?)] = [
                (NSWindow.didChangeOcclusionStateNotification, window),
                (NSWindow.didMiniaturizeNotification, window),
                (NSWindow.didDeminiaturizeNotification, window),
                (NSApplication.didHideNotification, NSApp),
                (NSApplication.didUnhideNotification, NSApp),
            ]
            observers = events.map { name, object in
                center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
            }
            report()
        }

        private func report() {
            guard let window else { return }
            changed?(window.occlusionState.contains(.visible) && !window.isMiniaturized && !NSApp.isHidden)
        }
    }
}

extension RootView {
    private func makeRoomForInspector() {
        guard model.isInspectorPresented, let window, let screen = window.screen?.visibleFrame else { return }
        let needed = Self.comfortablePageWidth + Self.inspectorWidth + 40
        guard window.frame.width < needed else { return }
        var frame = window.frame
        frame.size.width = min(needed, screen.width)
        if frame.maxX > screen.maxX {
            frame.origin.x = max(screen.minX, screen.maxX - frame.width)
        }
        window.setFrame(frame, display: true, animate: true)
    }
}

extension ToolbarContent {
    /// On macOS 26 toolbar items share a glass platter by default; items that
    /// draw their own background opt out of it.
    @ToolbarContentBuilder
    func withoutSharedBackground() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

private struct PageContainer: View {
    let page: Page

    var body: some View {
        Group {
            switch page {
            case .overview: OverviewPage()
            case .memory: MemoryPage()
            case .activity: ActivityPage()
            case .graphics: GraphicsPage()
            case .storage: StoragePage()
            case .recovery: RecoveryPage()
            case .devices: DevicesPage()
            }
        }
        .id(page)
        .transition(.opacity)
    }
}

private struct ToastOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if let toast = model.toast {
                Text(toast.message)
                    .font(TextStyle.body)
                    .foregroundStyle(toast.kind == .success ? Palette.text : Level.critical.color)
                    .lineLimit(2)
                    .padding(.horizontal, Space.l)
                    .padding(.vertical, 10)
                .glassBackground()
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: toast.id) {
                    try? await Task.sleep(for: .seconds(3.5))
                    if model.toast?.id == toast.id {
                        model.toast = nil
                    }
                }
            }
        }
        .animation(.snappy(duration: 0.3), value: model.toast)
    }
}
