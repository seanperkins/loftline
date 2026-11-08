import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// HIG, Buttons: use a verb that says what the button does ("Apply", "Save"); "OK" is for acknowledging a
/// message, not for committing a dialog.
@Suite struct ButtonTitleTests {
    /// Files where an "OK" button only acknowledges a message.
    static let acknowledgements: Set<String> = ["ToolDatabaseView.swift"]

    @Test func noSheetCommitsWithAnOKButton() throws {
        let root = ShortcutTests.sourceRoot
        var offenders: [String] = []
        for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)! where url.pathExtension == "swift" {
            guard !Self.acknowledgements.contains(url.lastPathComponent) else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains(#"Button("OK")"#) { offenders.append(url.lastPathComponent) }
        }
        #expect(offenders.isEmpty, "Use a specific verb instead of OK in: \(offenders)")
    }
}
