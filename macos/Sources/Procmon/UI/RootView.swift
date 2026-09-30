// The window's content: a floating toolbar over the current page, plus the
// process inspector, confirmations and toasts that any page can raise.

import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var width: CGFloat = 1200

    var body: some View {
        @Bindable var model = model
        PageContainer(page: model.page)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.canvas)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    BrandMark()
                }
                .withoutSharedBackground()
                ToolbarItem(placement: .principal) {
                    NavBar(selection: $model.page, compact: width < 900)
                }
                .withoutSharedBackground()
                ToolbarItem(placement: .primaryAction) {
                    SettingsMenu(preferences: model.preferences)
                }
            }
            .toolbar(removing: .title)
            .inspector(isPresented: $model.isInspectorPresented) {
                ProcessInspector()
                    .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
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
            case .storage: StoragePage()
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
                HStack(spacing: 8) {
                    Image(systemName: toast.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(toast.kind == .success ? Tint.green.strong : Tint.red.strong)
                    Text(toast.message)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Palette.text)
                        .lineLimit(2)
                }
                .padding(.horizontal, 16)
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
