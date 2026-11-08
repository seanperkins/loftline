import CADCore
import CAMCore
import PostCore
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct StatusBarTests {
    @Test func cursorReadoutCarriesTheUnit() {
        #expect(StatusReadout.cursor(Vec2(12.5, 3), units: .inch) == "X 12.5  Y 3 in")
        #expect(StatusReadout.cursor(Vec2(12.34567, 0.0004), units: .millimeter) == "X 12.346  Y 0 mm")
        #expect(StatusReadout.cursor(Vec2(-1.25, -0.5), units: .inch) == "X -1.25  Y -0.5 in")
    }

    @Test func aPostThatBelongsToTheMachineIsShownOnItsOwn() {
        // "Avid PRO6096 (Mach4) · Avid PRO6096 Mach4 (inch)" said the same thing twice.
        #expect(StatusReadout.machineAndPost(machine: BuiltInMachines.avidPRO6096, post: BuiltInPosts.avidMach4Inch)
                == BuiltInPosts.avidMach4Inch.name)
    }

    @Test func aMismatchedPostShowsBothNames() {
        let text = StatusReadout.machineAndPost(machine: BuiltInMachines.genericGRBL, post: BuiltInPosts.avidMach4Inch)
        #expect(text == "\(BuiltInMachines.genericGRBL.name) · \(BuiltInPosts.avidMach4Inch.name)")
    }

    @Test func noMachineShowsThePost() {
        #expect(StatusReadout.machineAndPost(machine: nil, post: BuiltInPosts.genericGRBLMM) == BuiltInPosts.genericGRBLMM.name)
    }
}

@Suite struct ZeroNameTests {
    @Test func shortNamesAreShorterThanTheFullOnes() {
        for mode in ZZeroMode.allCases {
            #expect(!mode.shortName.isEmpty)
            #expect(mode.shortName.count < mode.displayName.count)
        }
        #expect(ZZeroMode.materialTop.shortName == "Material")
        #expect(ZZeroMode.spoilboard.shortName == "Bed")
    }
}
