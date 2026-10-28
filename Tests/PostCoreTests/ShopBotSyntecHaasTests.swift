import CADCore
import CAMCore
import Foundation
import Testing
@testable import PostCore

/// The ShopBot G-code, Syntec and Haas posts (#106, #110, #111) and their families' rules.
@Suite struct ShopBotSyntecHaasTests {
    static let ids = ["shopbot-gcode-inch", "syntec-inch", "syntec-mm", "haas-inch", "haas-mm"]

    func program(_ p: PostProfile, zZero: ZZeroMode = .materialTop) throws -> (text: String, lines: [String]) {
        let text = try TemplatePostProcessor(profile: p).post(PostFixtures.postJob(zZero: zZero))
        return (text, text.split(separator: "\n").map(String.init))
    }

    func copy(_ p: PostProfile, _ change: (inout PostProfile) -> Void) -> PostProfile {
        var c = p
        c.id = p.id + "-custom-1"
        change(&c)
        return c
    }

    @Test(arguments: ids) func eachPostWritesItsDwellWrapperAndUnits(_ id: String) throws {
        let p = try #require(BuiltInPosts.profile(id: id))
        for mode in [ZZeroMode.materialTop, .spoilboard] {
            let (text, lines) = try program(p, zZero: mode)
            let blocks = GCodeParser.parse(text).blocks
            switch id {
            case "shopbot-gcode-inch":
                #expect(lines.contains { $0.hasSuffix(" G4 P3") })
                #expect(!blocks.contains { $0.value("S") != nil }, "no S word")
                #expect(blocks.allSatisfy { $0.values("G").count <= 1 }, "one G word per line")
                // Every line that is not a comment is numbered.
                #expect(lines.allSatisfy { $0.hasPrefix("(") || $0.hasPrefix("N") }, "\(mode)")
                #expect(blocks.contains { $0.has("G", 20) })
            case _ where id.hasPrefix("syntec"):
                #expect(Array(lines.prefix(2)) == ["%", "O1000"] && lines.last == "%")
                #expect(lines.contains("G4 X3.000"))
                #expect(lines.contains(id.hasSuffix("inch") ? "G70" : "G71"))
                #expect(!blocks.contains { $0.has("G", 20) || $0.has("G", 21) })
                #expect(lines.contains { $0.hasPrefix("G0 G43 Z") && $0.hasSuffix(" H1") })
            default:
                #expect(Array(lines.prefix(2)) == ["%", "O01000"] && lines.last == "%")
                #expect(lines.contains("G4 P3000"))
                #expect(lines.contains(id.hasSuffix("inch") ? "G20" : "G21"))
                #expect(lines.contains { $0.hasPrefix("G0 G43 Z") && $0.hasSuffix(" H1") })
            }
            let issues = GCodeValidator(profile: p, job: PostFixtures.job(zZero: mode), units: .inch).validate(gcode: text)
            let unexpected = issues.filter { !(BuiltInPosts.noSpindleSpeedIDs.contains(id) && PostDraftReport.isNoSpeed($0)) }
            #expect(unexpected.isEmpty, "\(id) \(mode): \(unexpected)")
        }
    }

    @Test func theSchemaVersionEachNeeds() {
        #expect(BuiltInPosts.shopbotGCodeInch.requiredSchemaVersion == 1)
        for p in [BuiltInPosts.syntecInch, BuiltInPosts.syntecMM, BuiltInPosts.haasInch, BuiltInPosts.haasMM] {
            #expect(p.requiredSchemaVersion == 3, "\(p.id)")
        }
    }

    // MARK: Family rules

    @Test func aSyntecCopyKeepsItsDwellForm() throws {
        for dwell in ["G4 P{MILLISECONDS}", "G4 P{SECONDS}", "G4 P{DECIMAL_SECONDS}"] {
            let c = copy(BuiltInPosts.syntecMM) { $0.dwell = dwell }
            #expect(c.dwellProblem?.contains("G4 X{DECIMAL_SECONDS}") == true, "\(dwell)")
            let read = try PostProfile.fromJSON(c.toJSON())
            #expect(throws: PostError.self) { try TemplatePostProcessor(profile: read).post(PostFixtures.postJob()) }
        }
    }

    @Test func aSyntecOrHaasCopyKeepsTheApproachHeightInItsToolLengthLine() throws {
        for base in [BuiltInPosts.syntecInch, BuiltInPosts.haasMM] {
            #expect(base.postProblem == nil)
            let c = copy(base) { $0.toolLengthOffset = "G0 G43 Z{SAFE_Z} H{T}" }
            #expect(c.postProblem?.contains("Z{APPROACH_Z}") == true, "\(base.id)")
            let read = try PostProfile.fromJSON(c.toJSON())
            #expect(throws: PostError.self) { try TemplatePostProcessor(profile: read).post(PostFixtures.postJob()) }
            #expect(copy(base) { $0.toolLengthOffset = "H{T} Z{APPROACH_Z} G43 G0" }.postProblem == nil)
            #expect(copy(base) { $0.useToolLengthOffset = false }.postProblem == nil)
        }
        #expect(BuiltInPosts.all.allSatisfy { $0.postProblem == nil })
    }

    @Test func aShopBotCopyCannotProbe() {
        let c = copy(BuiltInPosts.shopbotGCodeInch) { $0.controller = .grbl }
        let probing = ProbeSequenceBuilderTests.profile(c, machine: BuiltInMachines.genericGRBL, probe: ProbeSequenceBuilderTests.grbl)
        #expect(throws: PostError.self) {
            try TemplatePostProcessor(profile: probing).post(PostJob(name: "P", units: .inch, job: ProbeSequenceBuilderTests.job(),
                                                                     toolpaths: [ProbeSequenceBuilderTests.cut("A")]))
        }
    }

    @Test func shopBotRefusesCoolant() {
        var tp = PostFixtures.toolpaths()[0]
        tp.coolant = .air
        let errors = DialectChecks.issues(toolpaths: [tp], profile: BuiltInPosts.shopbotGCodeInch).filter { $0.severity == .error }
        #expect(errors.count == 1 && errors.first?.message.contains("output switch 3") == true)
    }

    @Test func toolZeroIsAnErrorOnSyntecAndHaas() {
        var tp = PostFixtures.toolpaths()[0]
        tp.tool.number = 0
        for p in [BuiltInPosts.syntecInch, BuiltInPosts.haasMM, copy(BuiltInPosts.haasInch) { _ in }] {
            let errors = DialectChecks.issues(toolpaths: [tp], profile: p).filter { $0.severity == .error }
            #expect(errors.contains { $0.message.contains("T0") }, "\(p.id)")
        }
        #expect(DialectChecks.issues(toolpaths: [tp], profile: BuiltInPosts.avidMach4Inch).isEmpty)
        #expect(DialectChecks.issues(toolpaths: PostFixtures.toolpaths(), profile: BuiltInPosts.haasInch).isEmpty)
    }
}
