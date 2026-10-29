import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp

@Suite struct DeepestCutTests {
    private func approx(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) <= tol }

    func job(_ zero: ZZeroMode, thickness: Double = 0.75) -> JobSetup {
        JobSetup(thickness: thickness, zZero: zero)
    }

    /// A short inch program whose only cut goes to machine Z `z`; the rapids are deeper than the cut.
    func program(cutZ z: Double, units: String = "G20") -> String {
        "\(units)\nG90\nG0 Z0.5\nG0 X0 Y0\nG0 Z-5\nG0 Z0.1\nG1 Z\(z) F20\nG1 X2 F60\nG0 Z0.5\nM30\n"
    }

    /// An apostrophe post's comment is not read as code (#109).
    @Test func readsAnApostrophePostsProgramAsItsValidatorDoes() throws {
        let text = "G21\nG90\nG0 Z5\nG1 Z-3 F100 ' Z-9\nG0 Z5\nM30\n"
        let cut = try #require(DeepestCut.find(in: text, job: job(.materialTop), units: .millimeter, postUnits: .millimeter,
                                               comments: .apostrophe))
        #expect(approx(cut.machineZ, -3))
    }

    @Test func readsTheDeepestFeedMoveAndNotTheRapids() throws {
        let cut = try #require(DeepestCut.find(in: program(cutZ: -0.77), job: job(.materialTop), units: .inch))
        #expect(approx(cut.machineZ, -0.77))
        #expect(approx(cut.depthBelowTop, 0.77))
        #expect(approx(cut.belowBottom, 0.02))
        #expect(cut.text(units: .inch) == "Z -0.77 in (0.02 in below the material bottom)")
    }

    @Test func givesTheSamePhysicalAnswerInSpoilboardMode() throws {
        // Spoilboard zero: the material bottom is Z 0, so a cut 0.77 below the top is at Z -0.02.
        let cut = try #require(DeepestCut.find(in: program(cutZ: -0.02), job: job(.spoilboard), units: .inch))
        #expect(approx(cut.machineZ, -0.02))
        #expect(approx(cut.depthBelowTop, 0.77))
        #expect(approx(cut.belowBottom, 0.02))
        #expect(cut.text(units: .inch) == "Z -0.02 in (0.02 in below the material bottom)")
    }

    @Test func saysWhenTheCutStopsAtOrShortOfTheBottom() throws {
        let at = try #require(DeepestCut.find(in: program(cutZ: -0.75), job: job(.materialTop), units: .inch))
        #expect(at.text(units: .inch) == "Z -0.75 in (at the material bottom)")
        let short = try #require(DeepestCut.find(in: program(cutZ: -0.5), job: job(.materialTop), units: .inch))
        #expect(short.text(units: .inch) == "Z -0.5 in (0.25 in above the material bottom)")
        let shortSpoil = try #require(DeepestCut.find(in: program(cutZ: 0.25), job: job(.spoilboard), units: .inch))
        #expect(shortSpoil.text(units: .inch) == "Z 0.25 in (0.25 in above the material bottom)")
    }

    /// A Syntec program states G70/G71, which the reader does not apply: read in the post's units, the deepest cut of an inch
    /// G70 program in a mm document is the same as the G20 program's, not 25.4 times off.
    @Test func readsAG70ProgramInThePostsUnits() throws {
        let mm = JobSetup(thickness: 19.05, zZero: .materialTop)
        let g20 = try #require(DeepestCut.find(in: program(cutZ: -0.75), job: mm, units: .millimeter))
        let g70 = try #require(DeepestCut.find(in: program(cutZ: -0.75, units: "G70"), job: mm, units: .millimeter, postUnits: .inch))
        #expect(g70 == g20)
        #expect(approx(g70.depthBelowTop, 19.05, 1e-9))
    }

    @Test func readsMillimeterProgramsInTheDocumentsUnits() throws {
        let mm = JobSetup(thickness: 19.05, zZero: .materialTop)
        let cut = try #require(DeepestCut.find(in: program(cutZ: -19.5, units: "G21"), job: mm, units: .millimeter))
        #expect(approx(cut.belowBottom, 0.45, 1e-9))
        #expect(cut.text(units: .millimeter) == "Z -19.5 mm (0.45 mm below the material bottom)")
        // An inch program read into a millimeter document is converted.
        let inch = try #require(DeepestCut.find(in: program(cutZ: -0.75), job: mm, units: .millimeter))
        #expect(approx(inch.depthBelowTop, 19.05, 1e-9))
        #expect(inch.text(units: .millimeter).hasSuffix("(at the material bottom)"))
    }

    @Test func isNilWhenThereIsNoCuttingMove() {
        #expect(DeepestCut.find(in: "G20\nG90\nG0 Z0.5\nG0 X1 Y1\nM30\n", job: job(.materialTop), units: .inch) == nil)
        #expect(DeepestCut.find(in: "", job: job(.materialTop), units: .inch) == nil)
    }

    @Test func theExportCarriesItForTheSampleSign() throws {
        let url = try #require(SampleProjects.url(for: SampleProjects.sign))
        let project = try LoftLineProject.decode(from: Data(contentsOf: url))
        var results: [UUID: ToolpathResult] = [:]
        let profile = BuiltInPosts.avidMach4Inch
        for op in project.operations {
            results[op.id] = ToolpathCalculator.calculate(op, project: project, library: ToolLibrary.seeded,
                                                          designRevision: 0, rapidRate: profile.rapidRate)
        }
        let toolpaths = GCodeExporter.toolpaths(scope: .all, operations: project.operations, results: results,
                                                groupByTool: false)
        let r = GCodeExporter.export(project: project, toolpaths: toolpaths, profile: profile, jobName: "Sign")
        let cut = try #require(r.deepestCut)
        let thickness = project.document.job.thickness
        #expect(cut.depthBelowTop > 0 && cut.depthBelowTop <= thickness + 0.1)
        #expect(approx(cut.belowBottom, cut.depthBelowTop - thickness))
    }
}
