import CADCore
import CAMCore
import Foundation
import Testing
@testable import PostCore

/// A post's line endings (#99 item 4). Every check is on UTF-8 bytes: Swift reads "\r\n" as one Character.
@Suite struct LineEndingTests {
    static let cr: UInt8 = 13, lf: UInt8 = 10

    @Test func crlfPutsACarriageReturnBeforeEveryLineFeed() {
        let program = "G20\nG0 Z0.2\nM30\n"
        let out = Array(PostProfile.LineEnding.crlf.apply(program).utf8)
        #expect(out == Array("G20\r\nG0 Z0.2\r\nM30\r\n".utf8))
        #expect(out.filter { $0 == Self.lf }.count == 3)
    }

    @Test func aPostWithoutASettingWritesLineFeedsOnly() throws {
        let text = try TemplatePostProcessor(profile: BuiltInPosts.avidMach4Inch).post(PostFixtures.postJob())
        #expect(!Array(text.utf8).contains(Self.cr))
        #expect(BuiltInPosts.avidMach4Inch.lineEnding == nil)
    }

    @Test func onlyMassoWritesCRLF() {
        for p in BuiltInPosts.all {
            let masso = p.id.hasPrefix("masso-g3")
            #expect((p.lineEnding == .crlf) == masso, "\(p.id)")
            if masso { #expect(p.version == "1.1", "\(p.id)") }
        }
    }

    @Test func crlfNeedsSchemaFiveWhateverElseThePostUses() {
        var p = BuiltInPosts.avidMach4Inch
        #expect(p.requiredSchemaVersion == 1)
        p.lineEnding = .crlf
        #expect(p.requiredSchemaVersion == 5)
        p.commentStyle = .apostrophe
        #expect(p.requiredSchemaVersion == 5)
        #expect(PostProfile.currentSchemaVersion == 5)
    }

    @Test func crlfSurvivesJSONAndLFCannotBeSpelledOut() throws {
        var p = BuiltInPosts.avidMach4Inch
        p.id = "crlf"; p.lineEnding = .crlf
        #expect(try PostProfile.fromJSON(p.toJSON()) == p)
        var json = try #require(String(data: p.toJSON(), encoding: .utf8))
        json = json.replacingOccurrences(of: "\"crlf\"", with: "\"lf\"")
        #expect(throws: (any Error).self) { try PostProfile.fromJSON(Data(json.utf8)) }
    }

    static let breaks = ["M5\r\nM30", "M5\rM30", "M5\nM30"]

    @Test(arguments: breaks)
    func aTemplateLineWithALineBreakIsRefused(line: String) throws {
        let message = "A template line contains a line break: put each line on its own line."
        let posts: [(String, (inout PostProfile) -> Void)] = [
            ("prelude", { $0.prelude = [line] }), ("footer", { $0.footer = ["M5", line] }),
            ("toolChange", { $0.toolChange = [line] }), ("pause", { $0.pause = [line, "M0"] }),
            ("spindleOn", { $0.spindleOn = "M3 S{S}\n" + line }),
        ]
        for (name, edit) in posts {
            var p = BuiltInPosts.avidMach4Inch
            p.id = "custom"
            edit(&p)
            #expect(p.postProblem == message, "\(name)")
            #expect(throws: PostError.self, "\(name)") { try TemplatePostProcessor(profile: p).post(PostFixtures.postJob()) }
        }
    }
}
