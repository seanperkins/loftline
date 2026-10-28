import CADCore
import CAMCore
import Foundation
import Testing
@testable import PostCore

/// A post whose tool change only stops (M0) cannot set Z for the next bit: a program with a second tool warns.
struct ToolChangeZTests {
    private let twoTools = PostFixtures.toolpaths()

    @Test func anM0PostWarnsWhenTheToolChanges() throws {
        for p in [BuiltInPosts.genericGRBLMM, BuiltInPosts.genericGRBLInch, BuiltInPosts.linuxCNCInch, BuiltInPosts.linuxCNCMM] {
            let w = try #require(ToolChangeZ.warning(toolpaths: twoTools, profile: p), "\(p.id)")
            #expect(w.severity == .warning)
            #expect(w.message.contains("one file per tool"))
        }
    }

    @Test func oneToolDoesNotWarn() {
        #expect(ToolChangeZ.warning(toolpaths: [twoTools[0]], profile: BuiltInPosts.linuxCNCInch) == nil)
        var again = twoTools[1]
        again.tool = twoTools[0].tool
        #expect(ToolChangeZ.warning(toolpaths: [twoTools[0], again], profile: BuiltInPosts.linuxCNCInch) == nil)
    }

    @Test func aPostThatCanSetZDoesNotWarn() {
        #expect(ToolChangeZ.warning(toolpaths: twoTools, profile: BuiltInPosts.avidMach4Inch) == nil)
        var offset = BuiltInPosts.linuxCNCInch
        offset.useToolLengthOffset = true
        #expect(ToolChangeZ.warning(toolpaths: twoTools, profile: offset) == nil)
        var probed = BuiltInPosts.genericGRBLInch
        probed.toolChangeProbe = .on(ToolChangeProbe.defaults(controller: .grbl, units: .inch,
                                                              limits: BuiltInPosts.genericGRBLInch.limits))
        #expect(ToolChangeZ.warning(toolpaths: twoTools, profile: probed) == nil)
    }

    @Test func anM6InACommentIsNotAToolChange() {
        var p = BuiltInPosts.linuxCNCInch
        p.toolChange = ["M5", "(MSG, then M6 by hand)", "M0"]
        #expect(ToolChangeZ.warning(toolpaths: twoTools, profile: p) != nil)
    }
}
