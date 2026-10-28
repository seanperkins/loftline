import CADCore
import CAMCore
import Foundation
import Testing
@testable import PostCore

/// A custom post can declare the controller it speaks, which is what touch-plate tool changes need (spec decision 4).
@Suite struct PostControllerTests {
    static let probe = ToolChangeProbeTests.mach4

    func custom(_ controller: ToolChangeProbe.Controller?) -> PostProfile {
        var p = BuiltInPosts.avidMach4Inch
        p.id = "shop"
        p.footer.append("(shop)")
        p.controller = controller
        return p
    }

    func applied(_ post: PostProfile, probe: ToolChangeProbe = probe) -> ProbeSetting? {
        var m = BuiltInMachines.avidPRO6096
        m.toolChangeProbe = probe
        return m.applied(to: post).toolChangeProbe
    }

    @Test func controllerRoundTrips() throws {
        let back = try PostProfile.fromJSON(custom(.grbl).toJSON())
        #expect(back.controller == .grbl)
    }

    @Test func noKeyWithoutController() throws {
        for p in BuiltInPosts.all {
            #expect(!String(decoding: try p.toJSON(), as: UTF8.self).contains("controller"))
        }
    }

    @Test func droppedControllerCannotProbe() throws {
        // A reader that does not know the key (an older LoftLine) gets a post with no controller, which cannot probe.
        var json = try JSONSerialization.jsonObject(with: custom(.mach4).toJSON()) as! [String: Any]
        json.removeValue(forKey: "controller")
        let older = try PostProfile.fromJSON(JSONSerialization.data(withJSONObject: json))
        guard case .refused? = applied(older) else { Issue.record("a post with no controller probed"); return }
    }

    @Test func declaredMach4Probes() {
        #expect(applied(custom(.mach4)) == .on(Self.probe))
    }

    @Test func undeclaredAndWrongControllerAreRefusedWithMessages() {
        guard case .refused(let none)? = applied(custom(nil)) else { Issue.record("undeclared probed"); return }
        #expect(none.contains("declares no controller"))
        guard case .refused(let wrong)? = applied(custom(.grbl)) else { Issue.record("wrong controller probed"); return }
        #expect(wrong.contains("declares GRBL") && wrong.contains("Mach4"))
    }

    @Test func builtInByValueUnchanged() {
        #expect(BuiltInPosts.probeController(for: BuiltInPosts.avidMach4Inch) == .mach4)
        #expect(BuiltInPosts.probeController(for: BuiltInPosts.genericGRBLMM) == .grbl)
        var edited = BuiltInPosts.avidMach4Inch
        edited.preamble.append("G54")
        #expect(BuiltInPosts.probeController(for: edited) == nil)
        edited.controller = .mach4
        #expect(BuiltInPosts.probeController(for: edited) == .mach4)
    }

    @Test func postVersionIsCommentSafe() throws {
        var p = BuiltInPosts.avidMach4Inch
        p.version = "1.0) M3"
        p.preamble.append("(post v{POST_VERSION})")
        let lines = try TemplatePostProcessor(profile: p).post(PostFixtures.postJob()).split(separator: "\n").map(String.init)
        // The version cannot close the comment and write an M3 of its own.
        #expect(lines.contains("(post v1.0] M3)"))
    }

    @Test func defaultsByControllerMatchDefaultsForMachine() {
        for m in BuiltInMachines.all {
            let byMachine = ToolChangeProbe.defaults(for: m)
            #expect(ToolChangeProbe.defaults(controller: byMachine.controller, units: m.units, limits: m.limits) == byMachine)
        }
        let grbl = ToolChangeProbe.defaults(controller: .grbl, units: .inch, limits: BuiltInMachines.avidPRO6096.limits)
        #expect(grbl.controller == .grbl && grbl.topZ < 0 && grbl.mach4ZeroMacro == nil)
        #expect(grbl.problems(limits: BuiltInMachines.avidPRO6096.limits, units: .inch).isEmpty)
    }
}
