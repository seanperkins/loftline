import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct SavePanelNameTests {
    @Test func theExtensionTheAllowedTypeAddsIsLeftOffTheSuggestedName() {
        // The panel appends the allowed type's extension itself: "Untitled.tap" showed as "Untitled.tap.tap".
        #expect(SavePanelName.suggested("Untitled.tap", allowedExtension: "tap") == "Untitled")
        #expect(SavePanelName.suggested("Sign.TAP", allowedExtension: "tap") == "Sign")
        #expect(SavePanelName.suggested("plate.v2.nc", allowedExtension: "nc") == "plate.v2")
    }

    @Test func otherExtensionsAndBareNamesAreKept() {
        #expect(SavePanelName.suggested("plate.nc", allowedExtension: "tap") == "plate.nc")
        #expect(SavePanelName.suggested("plate", allowedExtension: "tap") == "plate")
    }
}
