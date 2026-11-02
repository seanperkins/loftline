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
    }

    @Test func aRangeMustNotBeUpsideDown() {
        var m = BuiltInMachines.genericGRBL
        m.minRPM = 10000; m.maxRPM = 24000
        #expect(MachineEditor.rpmProblem(m) == nil)
        m.minRPM = 30000
        #expect(MachineEditor.rpmProblem(m) == "Min RPM is above Max RPM.")
        m.minRPM = nil
        #expect(MachineEditor.rpmProblem(m) == nil)
    }

    @Test func aMachinesMaxRPMReachesTheGRBLWarning() {
        var m = BuiltInMachines.genericGRBL
        m.maxRPM = 24000
        let post = m.applied(to: BuiltInPosts.genericGRBLMM)
        let w = DialectChecks.issues(toolpaths: [], profile: post).map(\.message)
        #expect(w.contains { $0.contains("set $30 to 24000") }, "\(w)")
    }
}
