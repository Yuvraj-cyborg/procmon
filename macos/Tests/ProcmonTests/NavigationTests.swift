import AppKit
import SwiftUI
import Testing
@testable import Procmon

@MainActor
@Suite struct NavigationTests {
    private func width(compact: Bool) -> CGFloat {
        NSHostingView(rootView: NavBar(selection: .constant(.overview), compact: compact).fixedSize()).fittingSize.width
    }

    /// The toolbar shows page names only when the window has room for them,
    /// next to the window controls, the app name and the settings button.
    @Test func pageNamesFitWhereTheyAreShown() {
        let full = width(compact: false)
        let compact = width(compact: true)
        print("navigation bar: \(full) points with names, \(compact) without")
        let besides: CGFloat = 80 + 110 + 44 + 48
        #expect(full + besides <= RootView.namedPagesWidth)
        #expect(compact + 80 + 44 + 48 <= RootView.minimumWindowWidth)
    }
}
