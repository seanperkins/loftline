import Foundation
import PostCore
import Testing
@testable import LoftLineApp

/// The export sheets re-post when the post in force changes. A probe edit in Preferences changes only the probe on
/// the effective post, so the probe must take part in that comparison, or a program with the old plate thickness
/// could be saved.
@Suite struct ProbePostedInputsTests {
    @Test func probeEditChangesPostedInputs() {
        var machine = BuiltInMachines.avidPRO6096
        machine.toolChangeProbe = ToolChangeProbe(parkX: 2, parkY: -2, parkZ: -0.5, topZ: 0, plateThickness: 0.75,
                                                  plateSize: 3, probeFeed: 5, probeTravel: 0.5, controller: .mach4,
                                                  mach4ZeroMacro: 199)
        let before = LoftLineDocument.PostedInputs().stamped(profile: machine.applied(to: BuiltInPosts.avidMach4Inch))
        machine.toolChangeProbe?.plateThickness = 0.5
        let after = LoftLineDocument.PostedInputs().stamped(profile: machine.applied(to: BuiltInPosts.avidMach4Inch))
        #expect(before != after)
    }
}
