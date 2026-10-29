import CADCore
import CAMCore
import Foundation
import Testing
@testable import PostCore

/// The `'` comment style NcStudio reads (#109, #99 item 5).
@Suite struct ApostropheCommentTests {
    /// The Avid mm post's fields under an id no built-in family claims.
    func apostrophePost(_ change: (inout PostProfile) -> Void = { _ in }) -> PostProfile {
        var p = BuiltInPosts.avidMach4MM
        p.id = "my-apostrophe-post"
        p.commentStyle = .apostrophe
        change(&p)
        return p
    }

    @Test func apostropheCommentRunsToTheEndOfTheLine() {
        let p = apostrophePost()
        #expect(p.comment("Bob's (1/4) bit") == "' Bob's [1/4] bit")
        #expect(!p.comment("a\nb").contains("\n"))
    }

    @Test func oneMessageFormPerStyle() {
        #expect(PostProfile.CommentStyle.parentheses.message("x") == "(MSG, x)")
        #expect(PostProfile.CommentStyle.semicolon.message("x") == "; x")
        #expect(PostProfile.CommentStyle.apostrophe.message("x") == "' x")
        #expect(PostProfile.defaultPause(for: .apostrophe) == ["M5", "' {MESSAGE}", "{STOP}"])
        #expect(PostProfile.defaultPause(for: .parentheses) == ["M5", "(MSG, {MESSAGE})", "{STOP}"])
        #expect(PostProfile.defaultPause(for: .semicolon) == ["M5", "; {MESSAGE}", "{STOP}"])
    }

    @Test func anApostrophePostNeedsSchemaFour() throws {
        #expect(apostrophePost().requiredSchemaVersion == 4)
        let both = apostrophePost {
            $0.dwell = "G4 P{MILLISECONDS}"
            $0.toolLengthOffset = "G0 G43 Z{APPROACH_Z} H{T}"
        }
        #expect(both.requiredSchemaVersion == 4)
        let json = String(decoding: try both.toJSON(), as: UTF8.self)
        #expect(json.contains("\"schemaVersion\" : 4"))
        #expect(json.contains("\"commentStyle\" : \"apostrophe\""))
    }
}
