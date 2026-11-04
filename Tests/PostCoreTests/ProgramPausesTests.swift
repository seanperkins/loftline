import CADCore
import CAMCore
import Foundation
import Testing
@testable import PostCore

/// Which operator pauses a program writes, worked out once from the toolpaths it writes (docs/implicit-state-machines.md #5):
/// a pause stands only between two toolpaths that cut.
@Suite struct ProgramPausesTests {
    func cut(_ name: String, pause: PauseStep? = nil, empty: Bool = false) -> Toolpath {
        let mc = MachineCoordinates(job: PostFixtures.job())
        var tp = Toolpath(name: name, kind: .profile, tool: PostFixtures.endMill, moves: empty ? [] : [
            .rapid(to: Vec3(1, 1, mc.safeZ)), .linear(to: Vec3(1, 1, mc.z(depth: 0.1)), feed: 30),
            .linear(to: Vec3(2, 1, mc.z(depth: 0.1)), feed: 100), .rapid(to: Vec3(2, 1, mc.safeZ)),
        ])
        tp.pauseAfter = pause
        return tp
    }

    let stop = PauseStep(message: "Flip")

    @Test func noPauseAfterTheLastToolpath() {
        #expect(ProgramPauses.effective([cut("A"), cut("B", pause: stop)]).map(\.pauseAfter) == [nil, nil])
        // Only empty toolpaths after it: still the last one that cuts.
        #expect(ProgramPauses.effective([cut("A", pause: stop), cut("B", empty: true)]).map(\.pauseAfter) == [nil, nil])
    }

    @Test func pauseSurvivesEmptyNeighbours() {
        let out = ProgramPauses.effective([cut("A", pause: stop), cut("E", empty: true), cut("B")])
        #expect(out.map(\.pauseAfter) == [stop, nil, nil])
        // An empty toolpath never carries one.
        #expect(ProgramPauses.effective([cut("A"), cut("E", pause: stop, empty: true), cut("B")]).map(\.pauseAfter)
                    == [nil, nil, nil])
    }

    @Test func theHeaderListsOnlyTheStopsTheProgramWrites() throws {
        let job = PostJob(name: "P", units: .inch, job: PostFixtures.job(),
                          toolpaths: [cut("A", pause: stop), cut("B", empty: true)])
        let text = try TemplatePostProcessor(profile: BuiltInPosts.avidMach4Inch).post(job)
        #expect(!text.contains("Pauses - the machine waits"))
        #expect(!text.contains("M0"))
    }
}
