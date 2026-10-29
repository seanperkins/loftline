import CADCore
import CAMCore
import Foundation
import Testing
@testable import PostCore

/// The NcStudio post (#109) and its family's rules.
@Suite struct NcStudioTests {
    func copy(_ change: (inout PostProfile) -> Void) -> PostProfile {
        var c = BuiltInPosts.ncstudioMM
        c.id = "ncstudio-mm-custom-1"
        change(&c)
        return c
    }

    func errors(_ p: PostProfile, _ tps: [Toolpath]) -> [String] {
        DialectChecks.issues(toolpaths: tps, profile: p).filter { $0.severity == .error }.map(\.message)
    }

    func tooled(_ number: Int, coolant: Coolant? = nil) -> Toolpath {
        var t = PostFixtures.endMill
        t.number = number
        var tp = Toolpath(name: "T\(number)", kind: .profile, tool: t,
                          moves: [.rapid(to: Vec3(1, 1, 5)), .linear(to: Vec3(1, 1, -2), feed: 500)])
        tp.coolant = coolant
        return tp
    }

    @Test func theRulesAtBuild() {
        #expect(BuiltInPosts.ncstudioMM.postProblem == nil)
        #expect(copy { _ in }.postProblem == nil)
        #expect(copy { $0.commentStyle = .parentheses }.postProblem?.contains("reads only ' comments") == true)
        #expect(copy { $0.arcOutput = .incrementalIJ }.postProblem?.contains("keep arcs as lines") == true)
        #expect(copy { $0.arcOutput = .absoluteIJ }.postProblem?.contains("keep arcs as lines") == true)
        #expect(copy { $0.units = .inch }.postProblem?.contains("keep the post in millimetres") == true)
        #expect(copy { $0.useToolLengthOffset = true; $0.toolLengthOffset = "G43 H{T}" }.postProblem?.contains("G43") == true)
        #expect(copy { $0.useToolLengthOffset = true }.postProblem == nil)
    }

    @Test func theRulesAtExport() throws {
        for p in [BuiltInPosts.ncstudioMM, copy { _ in }] {
            #expect(errors(p, [tooled(1, coolant: .mist)]).contains { $0.hasPrefix("NcStudio documents M8 but not M7") }, "\(p.id)")
            #expect(errors(p, [tooled(1, coolant: .air)]).isEmpty, "\(p.id)")
            var tlo = p
            tlo.useToolLengthOffset = true
            #expect(errors(tlo, [tooled(7)]).isEmpty, "\(p.id)")
            #expect(errors(tlo, [tooled(8)]).contains { $0.contains("G43 takes H00 to H07") }, "\(p.id)")
            #expect(errors(tlo, [tooled(0)]).contains { $0.contains("G43 takes H00 to H07") }, "\(p.id)")
            #expect(errors(p, [tooled(0), tooled(8)]).isEmpty, "\(p.id): no offset, no H word")
        }
        let job = PostJob(name: "Air", units: .millimeter, job: PostFixtures.job(), toolpaths: [tooled(1, coolant: .air)])
        let lines = try TemplatePostProcessor(profile: BuiltInPosts.ncstudioMM).post(job).split(separator: "\n").map(String.init)
        let m8 = try #require(lines.firstIndex(of: "M8"))
        #expect(lines[m8...].contains("M9"))
    }

    @Test(arguments: [ZZeroMode.materialTop, .spoilboard]) func itWritesOnlyItsCodes(_ mode: ZZeroMode) throws {
        let p = BuiltInPosts.ncstudioMM
        var job = PostFixtures.postJob(zZero: mode)
        job.toolpaths[0].pauseAfter = PauseStep(message: "Flip (side)", isOptionalStop: true)
        let text = try TemplatePostProcessor(profile: p).post(job)
        let blocks = GCodeParser.parse(text, comments: p.parserComments).blocks
        for (letter, value) in [("G", 2.0), ("G", 3), ("G", 17), ("G", 90.1), ("G", 91.1), ("G", 94), ("M", 1), ("M", 6), ("M", 7)]
            as [(Character, Double)] {
            #expect(!blocks.contains { $0.has(letter, value) }, "\(mode) writes \(letter)\(value)")
        }
        #expect(!blocks.contains { $0.value("T") != nil }, "a T word")
        #expect(!text.contains("(") && !text.contains(";"))
        #expect(blocks.contains { $0.has("M", 0) })
        #expect(text.contains("\nG4 P3000\n"))
        let read = GCodeReader.read(text, units: .millimeter, startZ: 5, comments: p.parserComments)
        #expect(read.warnings.isEmpty, "\(read.warnings)")
        let issues = GCodeValidator(profile: p, job: job.job, units: job.units).validate(gcode: text)
        #expect(!issues.contains { $0.severity == .error }, "\(issues)")
    }

    @Test func theSampleRunsWithAir() throws {
        let report = PostDraftReport.make(BuiltInPosts.ncstudioMM)
        #expect(report.problems.isEmpty, "\(report.problems)")
        let program = try #require(report.program)
        let blocks = GCodeParser.parse(program, comments: .apostrophe).blocks
        #expect(blocks.contains { $0.has("M", 8) } && blocks.contains { $0.has("M", 9) })
        #expect(!blocks.contains { $0.has("M", 7) })
    }

    @Test func itNeedsSchemaFour() {
        #expect(BuiltInPosts.ncstudioMM.requiredSchemaVersion == 4)
    }
}
