import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// What the app wraps around a facing: its defaults, millimeter scaling, the job sheet's note and the help topic (issue #20).
@Suite struct FacingAppTests {
    @Test func aNewFacingFacesTheWholeMaterialWithTheWidestEndMill() throws {
        let p = AppTestSupport.project()
        let lib = ToolLibrary.seeded
        let none = try #require(OperationFactory.make(kind: .facing, project: p, library: lib, shapeIDs: []))
        guard case .facing(let whole) = none else { Issue.record("not a facing"); return }
        #expect(whole.params.area == .material)
        let widest = try #require(lib.tools.filter { $0.kind == .endMill }.max { $0.diameter < $1.diameter })
        #expect(whole.setup.toolID == widest.id)
        // Only an end mill is a facing tool by preference (a ball nose is for profiles and pockets).
        #expect(OperationFactory.preferredToolKinds(for: .facing) == [.endMill])
        // A selection makes it the box round the vectors.
        let some = try #require(OperationFactory.make(kind: .facing, project: p, library: lib, shapeIDs: [p.document.shapes[0].id]))
        guard case .facing(let box) = some else { Issue.record("not a facing"); return }
        #expect(box.params.area == .vectors)
        // The layer is not deeper than the material.
        var thin = p
        thin.document.job.thickness = 0.02
        guard case .facing(let shallow) = try #require(OperationFactory.make(kind: .facing, project: thin, library: lib, shapeIDs: [])) else {
            Issue.record("not a facing"); return
        }
        #expect(shallow.params.depth.cutDepth <= 0.02)
    }

    @Test func millimeterDocumentsGetTheirOwnLengths() {
        var params = FacingParameters(depth: DepthSettings(startDepth: 0.1, cutDepth: 0.0625, passDepth: 0.05), overhang: 0.25)
        params.stepover = 0.6
        let scaled = params.scaled(by: 25.4)
        #expect(abs(scaled.depth.cutDepth - 1.5875) < 1e-9)
        #expect(abs(scaled.depth.startDepth - 2.54) < 1e-9)
        #expect(abs((scaled.depth.passDepth ?? 0) - 1.27) < 1e-9)
        #expect(abs((scaled.overhang ?? 0) - 6.35) < 1e-9)
        // The stepover is a share of the tool, not a length.
        #expect(scaled.stepover == 0.6)
        #expect(FacingParameters().scaled(by: 25.4).overhang == nil)
    }

    @Test func theJobSheetStepSaysWhereTheTopIsAfterwards() throws {
        var p = AppTestSupport.project()
        p.document.job.thickness = 0.75
        let lib = ToolLibrary.seeded
        p.operations = [try #require(OperationFactory.make(kind: .facing, project: p, library: lib, shapeIDs: [])),
                        try #require(OperationFactory.make(kind: .profile, project: p, library: lib,
                                                           shapeIDs: [p.document.shapes[0].id]))]
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        doc.calculateNow(doc.project.operations.map(\.id))
        let sheet = JobSheet.make(project: doc.project, results: doc.results, profile: BuiltInPosts.avidMach4Inch,
                                  groupByTool: false, rapidRate: 600, settings: TimeEstimateSettings())
        let facing = try #require(sheet.steps.first { $0.kind == "Facing" })
        #expect(facing.notes.contains { $0.contains("below the original top") && $0.contains("re-zero") })
        // Other steps carry no such note.
        let others = sheet.steps.filter { $0.kind != "Facing" }
        #expect(others.allSatisfy { step in !step.notes.contains { $0.contains("below the original top") } })
    }

    @Test func aFacingHasItsOwnHelpTopicAndFollowsTheThickness() throws {
        #expect(HelpTopic.forOperation(.facing) == .facing)
        #expect(HelpTopic.facing.title == "Facing Toolpath")
        // Its cut depth moves with the material thickness when it asked to, like the other depth-based toolpaths.
        var p = AppTestSupport.project()
        let lib = ToolLibrary.seeded
        guard case .facing(var f) = try #require(OperationFactory.make(kind: .facing, project: p, library: lib, shapeIDs: [])) else {
            Issue.record("not a facing"); return
        }
        f.params.depth.cutDepth = 0.75
        f.params.depth.overcut = 0
        p.operations = [.facing(f)]
        p.document.job.thickness = 0.5
        let moved = p.resolvingThroughDepths().operations
        #expect(moved.first?.editableDepth?.cutDepth == 0.5)
    }

    @Test func aWholeMaterialFacingSaysWhichSheetAndSideItBelongsTo() {
        #expect(FacingForm.scopeNote(area: .material, multiSheet: false, twoSided: false) == nil)
        for (sheets, sides) in [(true, false), (false, true), (true, true)] {
            let note = FacingForm.scopeNote(area: .material, multiSheet: sheets, twoSided: sides)
            #expect(note?.contains("first sheet and the top side") == true)
            // With vectors the sheet and side come from them.
            #expect(FacingForm.scopeNote(area: .vectors, multiSheet: sheets, twoSided: sides) == nil)
        }
    }

    @Test func switchingToTheWholeMaterialDropsTheVectorsAndTheProjection() {
        var setup = OperationSetup(name: "Face", toolID: UUID(), shapeIDs: [UUID(), UUID()])
        setup.projectOntoModelID = UUID()
        // Selected vectors keep both.
        let boxed = FacingForm.operation(setup, params: FacingParameters(area: .vectors))
        #expect(boxed.setup.shapeIDs == setup.shapeIDs)
        #expect(boxed.setup.projectOntoModelID == setup.projectOntoModelID)
        // The whole material has neither: its sheet and side are the ones a vectorless toolpath has, and it cuts a flat plane.
        let whole = FacingForm.operation(setup, params: FacingParameters(area: .material))
        #expect(whole.setup.shapeIDs.isEmpty)
        #expect(whole.setup.projectOntoModelID == nil)
        #expect(whole.setup.id == setup.id && whole.setup.name == "Face")
    }

    @Test func aWholeMaterialFacingIsMachinedOnTheTopSideOfATwoSidedJob() throws {
        var p = AppTestSupport.project()
        p.document.job.twoSided = TwoSidedSetup()
        let lib = ToolLibrary.seeded
        let op = try #require(OperationFactory.make(kind: .facing, project: p, library: lib, shapeIDs: []))
        #expect(op.setup.shapeIDs.isEmpty)
        // No vectors: the top side (what the form says), and a job to machine it with, not a "both sides" error.
        #expect(p.side(of: op) == .top)
        guard case .success(let job) = p.machiningJob(for: op) else { Issue.record("no machining job"); return }
        #expect(job.zZero == p.document.job.zZero)
        // And it calculates.
        p.operations = [op]
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        doc.calculateNow(doc.project.operations.map(\.id))
        #expect(doc.results[op.id]?.error == nil)
        #expect(doc.results[op.id]?.toolpaths.isEmpty == false)
    }
}
