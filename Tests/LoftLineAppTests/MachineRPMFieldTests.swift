import Foundation
import PostCore
import Testing
@testable import LoftLineApp

/// A machine can carry its spindle range (#99 item 13): the GRBL notes and export warning ask for a copy's Max RPM to match $30.
@Suite struct MachineRPMFieldTests {
    @Test func zeroMeansThePostsValue() {
        #expect(MachineEditor.rpm(0) == nil)
        #expect(MachineEditor.rpm(-5) == nil)
        #expect(MachineEditor.rpm(24000) == 24000)
        // S is written whole, so the range is too: 23,999.6 would let S24000 past a 23,999.6 limit.
        #expect(MachineEditor.rpm(23999.6) == 24000)
    }

    /// The range that applies: an unset field is the post's value, for every post the machine lists.
    @Test func aRangeMustNotBeUpsideDown() {
        var m = BuiltInMachines.avidPRO6096   // its posts run 6,000-24,000
        let posts = BuiltInPosts.all
        m.minRPM = 10000; m.maxRPM = 20000
        #expect(MachineEditor.rpmProblem(m, posts: posts) == nil)
        m.minRPM = 30000
        #expect(MachineEditor.rpmProblem(m, posts: posts) == "Min RPM is above Max RPM.")
        // Max unset is the post's 24,000.
        m.maxRPM = nil
        #expect(MachineEditor.rpmProblem(m, posts: posts)?.hasPrefix("Min RPM is above the Max RPM of ") == true)
        // Min unset is the post's 6,000.
        m.minRPM = nil; m.maxRPM = 5000
        #expect(MachineEditor.rpmProblem(m, posts: posts)?.hasPrefix("Max RPM is below the Min RPM of ") == true)
        m.maxRPM = nil
        #expect(MachineEditor.rpmProblem(m, posts: posts) == nil)
    }

    @Test func aMachinesSpindleRangeSurvivesJSON() throws {
        var m = BuiltInMachines.genericGRBL
        m.id = "grbl-copy"; m.minRPM = 8000; m.maxRPM = 24000
        let back = try JSONDecoder().decode(MachineDefinition.self, from: JSONEncoder().encode(m))
        #expect(back.minRPM == 8000 && back.maxRPM == 24000)
    }

    @Test func aMachinesMaxRPMReachesTheGRBLWarning() {
        var m = BuiltInMachines.genericGRBL
        m.maxRPM = 24000
        let post = m.applied(to: BuiltInPosts.genericGRBLMM)
        let w = DialectChecks.issues(toolpaths: [], profile: post).map(\.message)
        #expect(w.contains { $0.contains("Max RPM, 24000 (") }, "\(w)")
    }
}
