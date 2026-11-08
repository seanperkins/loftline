import AppKit
import SwiftUI
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// HIG (Accessibility, "Offer sufficiently sized controls"): macOS controls default to 28 x 28 pt and
/// should never be smaller than 20 x 20 pt.
@Suite struct HitTargetTests {
    @Test @MainActor func iconButtonStyleHasAComfortableMinimumSize() {
        let host = NSHostingView(rootView: Button {} label: { Image(systemName: "plus") }.buttonStyle(.icon))
        let size = host.fittingSize
        #expect(size.width >= IconButtonStyle.minimumSide)
        #expect(size.height >= IconButtonStyle.minimumSide)
        #expect(IconButtonStyle.minimumSide >= 20)
    }

    @Test @MainActor func iconButtonStyleDoesNotShrinkALargeLabel() {
        let host = NSHostingView(rootView: Button {} label: { Image(systemName: "plus").frame(width: 40, height: 30) }
            .buttonStyle(.icon))
        let size = host.fittingSize
        #expect(size.width >= 40 && size.height >= 30)
    }
}
