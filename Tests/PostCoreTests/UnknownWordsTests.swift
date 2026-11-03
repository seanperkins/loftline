import CADCore
import CAMCore
import Foundation
import Testing
@testable import PostCore

/// A post of a built-in family that writes a G or M code its built-in does not is warned, with what that controller does with
/// a word it does not know (#99 item 14). Compared on written programs for the same job.
@Suite struct UnknownWordsTests {
    static let masso = "MASSO skips a whole line with a word it does not know."
    static let centroid = "CNC12 cancels the job at a word it does not know (error 502)."
    static let uccnc = "UCCNC may run past, skip or stop at a code it does not know, as its settings say."
    static let general = "A controller may ignore, skip or refuse a word it does not know."

    static func copy(_ p: PostProfile, _ edit: (inout PostProfile) -> Void = { _ in }) -> PostProfile {
        var c = p
        c.id = p.id + "-custom-1"
        c.name = p.name + " copy"
        edit(&c)
        return c
    }

    static func warnings(_ p: PostProfile, job: PostJob = PostFixtures.postJob()) throws -> [String] {
        let text = try TemplatePostProcessor(profile: p).post(job)
        return UnknownWords.issues(text: text, job: job, profile: p).filter { $0.severity == .warning }.map(\.message)
    }

    @Test func aMassoCopyAddingG64IsWarnedWithMassosConsequence() throws {
        let p = Self.copy(BuiltInPosts.massoG3Inch) { $0.preamble.append("G64 P0.01") }
        #expect(try Self.warnings(p) == ["MASSO G3 (inch) copy writes G64, which the built-in MASSO G3 (inch) post does not: "
                                         + Self.masso + " Check that your controller reads them."])
    }

    @Test func absoluteArcsAreAWordToo() throws {
        let p = Self.copy(BuiltInPosts.massoG3Inch) { $0.arcOutput = .absoluteIJ }
        #expect(try Self.warnings(p).first?.contains("writes G90.1,") == true)
    }

    @Test func eachFamilySaysWhatItsControllerDoes() throws {
        let centroid = Self.copy(BuiltInPosts.centroidInch) { $0.toolChange.append("M7") }
        #expect(try Self.warnings(centroid).first?.contains("writes M7, which") == true)
        #expect(try Self.warnings(centroid).first?.contains(Self.centroid) == true)
        let uccnc = Self.copy(BuiltInPosts.uccncInch) { $0.footer.insert("G28", at: 0) }
        #expect(try Self.warnings(uccnc).first?.contains(Self.uccnc) == true)
        let mach4 = Self.copy(BuiltInPosts.avidMach4Inch) { $0.preamble.append("G64") }
        #expect(try Self.warnings(mach4).first?.contains(Self.general) == true)
    }

    @Test func aWordTheBuiltInWritesItselfIsNotWarned() throws {
        var job = PostFixtures.postJob()
        job.toolpaths = job.toolpaths.map { var t = $0; t.coolant = .mist; return t }
        #expect(try Self.warnings(BuiltInPosts.centroidInch, job: job).isEmpty)
        #expect(try Self.warnings(Self.copy(BuiltInPosts.centroidInch), job: job).isEmpty)
    }

    @Test func commentsUnitsAndStopsAreNotWords() throws {
        let commented = Self.copy(BuiltInPosts.massoG3Inch) { $0.preamble.append("(G64 is not used)") }
        #expect(try Self.warnings(commented).isEmpty)
        let otherUnits = Self.copy(BuiltInPosts.massoG3Inch) { $0.units = .millimeter }
        #expect(try Self.warnings(otherUnits, job: PostFixtures.postJob()).isEmpty)
        let manualStop = Self.copy(BuiltInPosts.centroidInch) { $0.pause = ["M5", "M0"] }
        #expect(try Self.warnings(manualStop).isEmpty)
    }

    @Test func aMachinesProbeOnTheAvidIsNotWarned() throws {
        var m = BuiltInMachines.avidPRO6096
        m.toolChangeProbe = ToolChangeProbe.defaults(for: m)
        let p = m.applied(to: BuiltInPosts.avidMach4Inch)
        var job = PostFixtures.postJob()
        job.job.touchOffSpot = Vec2(6, 4)
        let text = try TemplatePostProcessor(profile: p).post(job)
        #expect(text.contains("G31") || text.contains("G38"), "the fixture must probe")
        #expect(try Self.warnings(p, job: job).isEmpty)
    }

    @Test func aPostCarryingABuiltInsIdIsChecked() throws {
        var p = BuiltInPosts.massoG3Inch
        p.preamble.append("G64 P0.01")
        #expect(try Self.warnings(p).first?.contains("writes G64") == true)
    }

    @Test func aCodeTheValidatorDoesNotModelIsLeftToIt() throws {
        let p = Self.copy(BuiltInPosts.massoG3Inch) { $0.preamble.append("M98") }
        #expect(try Self.warnings(p).isEmpty)
    }

    @Test func everyBuiltInIsQuiet() throws {
        for p in BuiltInPosts.all {
            #expect(try Self.warnings(p).isEmpty, "\(p.id)")
        }
    }

    /// A copy that changes nothing a controller reads goes through the whole comparison and stays quiet.
    @Test func aCopyChangingOnlyFormattingIsQuiet() throws {
        for p in BuiltInPosts.all {
            let c = Self.copy(p) { $0.decimals += 1; $0.feedDecimals += 1; $0.lineNumbers.toggle(); $0.version = "9" }
            #expect(try Self.warnings(c).isEmpty, "\(p.id)")
        }
    }

    /// Units words count: a Syntec copy keeps G70/G71 (its family rule) and adding G20 is a word Syntec's manual lacks.
    @Test func anAddedUnitsWordIsWarned() throws {
        let p = Self.copy(BuiltInPosts.syntecInch) { $0.preamble.append("G20") }
        #expect(try Self.warnings(p).first?.contains("writes G20, which") == true)
    }

    /// The reference posts with the copy's precision: a probe feed only the copy's feed decimals can write is not a reason to
    /// compare against a program without the probe.
    @Test func aFinerProbeFeedOnAnAvidCopyIsQuiet() throws {
        var m = BuiltInMachines.avidPRO6096
        var probe = ToolChangeProbe.defaults(for: m)
        probe.probeFeed = 0.05
        m.toolChangeProbe = probe
        let c = m.applied(to: Self.copy(BuiltInPosts.avidMach4Inch) { $0.feedDecimals = 2; $0.controller = .mach4 })
        var job = PostFixtures.postJob()
        job.job.touchOffSpot = Vec2(6, 4)
        let text = try TemplatePostProcessor(profile: c).post(job)
        #expect(text.contains("F0.05"), "the copy must probe at its finer feed")
        #expect(try Self.warnings(c, job: job).isEmpty)
    }
}
