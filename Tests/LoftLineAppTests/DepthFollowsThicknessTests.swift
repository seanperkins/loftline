import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineApp

/// A through cut stores its overcut past the material bottom; every change of the thickness, by Job Setup, a variable
/// link or a live edit, moves its cut depth (docs/implicit-state-machines.md #3).
@Suite struct DepthFollowsThicknessTests {
    private func approx(_ a: Double?, _ b: Double, _ tol: Double = 1e-9) -> Bool { a.map { abs($0 - b) <= tol } ?? false }

    func project() -> LoftLineProject {
        var p = AppTestSupport.project()
        p.document.job.thickness = 0.75
        return p
    }

    func profile(_ p: LoftLineProject, depth: Double, overcut: Double?) -> AnyOperation {
        var op = OperationFactory.make(kind: .profile, project: p, library: .seeded, shapeIDs: p.document.shapes.map(\.id))!
        var d = op.editableDepth!
        d.cutDepth = depth
        d.overcut = overcut
        op.editableDepth = d
        return op
    }

    @Test func aNewProfileCutsThroughWithNoOvercut() {
        let p = project()
        let op = OperationFactory.make(kind: .profile, project: p, library: .seeded, shapeIDs: [])!
        #expect(approx(op.editableDepth?.cutDepth, 0.75))
        #expect(op.editableDepth?.overcut == 0)
        let pocket = OperationFactory.make(kind: .pocket, project: p, library: .seeded, shapeIDs: [])!
        #expect(pocket.editableDepth?.overcut == nil)
    }

    @Test func jobSetupMovesThroughCutsAndLeavesTheRest() {
        var p = project()
        p.operations = [
            profile(p, depth: 0.75, overcut: 0),        // through
            profile(p, depth: 0.77, overcut: 0.02),     // through with an overcut
            profile(p, depth: 0.75, overcut: nil),      // fixed by hand
            OperationFactory.make(kind: .pocket, project: p, library: .seeded, shapeIDs: [])!,   // 0.25, fixed
        ]
        var form = JobSetupForm(document: p.document)
        form.job.thickness = 0.5
        let out = form.apply(to: p)
        let depths = out.operations.map { $0.editableDepth!.cutDepth }
        #expect(approx(depths[0], 0.5))
        #expect(approx(depths[1], 0.52))
        #expect(approx(depths[2], 0.75))
        #expect(approx(depths[3], 0.25))
        #expect(approx(out.operations[1].editableDepth?.overcut, 0.02))
    }

    @Test func overcutScalesWithUnits() {
        var p = project()
        p.operations = [profile(p, depth: 0.77, overcut: 0.02)]
        var form = JobSetupForm(document: p.document)
        form.setUnits(.millimeter)          // 0.75 in -> 19.05 mm
        form.job.thickness = 18
        let out = form.apply(to: p)
        #expect(out.document.units == .millimeter)
        // 0.02 in past the bottom stays 0.508 mm past the bottom.
        #expect(approx(out.operations[0].editableDepth?.overcut, 0.02 * 25.4, 1e-9))
        #expect(approx(out.operations[0].editableDepth?.cutDepth, 18 + 0.02 * 25.4, 1e-6))
    }

    @Test func aUnitChangeKeepsAZeroOvercutThrough() {
        var p = project()
        p.operations = [profile(p, depth: 0.75, overcut: 0)]
        var form = JobSetupForm(document: p.document)
        form.setUnits(.millimeter)
        let out = form.apply(to: p)
        #expect(out.operations[0].editableDepth?.overcut == 0)
        #expect(approx(out.operations[0].editableDepth?.cutDepth, 19.05, 1e-9))
    }

    @Test func onlyEachSheetsOwnThicknessMovesItsCuts() {
        // Sheet A is 0.75 thick, sheet B 0.5; each has a through profile.
        var p = project()
        let bJob = JobSetup(width: 10, height: 10, thickness: 0.5)
        _ = p.document.addSheet(name: "B", job: bJob, layerName: "B", colorHex: "#336699")
        let bLayer = p.document.layers.last!.id
        p.document.shapes[1].layerID = bLayer
        let a = p.document.shapes[0].id, b = p.document.shapes[1].id
        var onA = profile(p, depth: 0.75, overcut: 0); onA.editableSetup.shapeIDs = [a]
        var onB = profile(p, depth: 0.5, overcut: 0); onB.editableSetup.shapeIDs = [b]
        p.operations = [onA, onB]
        var form = JobSetupForm(document: p.document)
        form.job.thickness = 0.78
        let out = form.apply(to: p)
        #expect(approx(out.operations[0].editableDepth?.cutDepth, 0.78))
        #expect(approx(out.operations[1].editableDepth?.cutDepth, 0.5))
    }

    @Test func variableThicknessMovesThroughCuts() {
        // A thickness written by a variable link (or a gadget) never passes Job Setup; the cut still follows it.
        var p = project()
        p.operations = [profile(p, depth: 0.75, overcut: 0.01)]
        p.document.variables = [DocumentVariable(name: "t", value: 0.75)]
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        doc.perform("Link") {
            $0.document.linkedValues = [VariableLink(target: .job(sheetID: $0.document.currentSheetID), path: ["thickness"],
                                                     expression: "=t")]
        }
        doc.perform("Change Variable") { $0.document.variables = [DocumentVariable(name: "t", value: 0.6)] }
        #expect(approx(doc.project.document.job.thickness, 0.6))
        #expect(approx(doc.project.operations[0].editableDepth?.cutDepth, 0.61))
    }

    @Test func liveEditOfOvercutMovesCutDepth() {
        var p = project()
        let op = profile(p, depth: 0.75, overcut: 0)
        p.operations = [op]
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        for overcut in [0.02, 0.03] {   // the first edit opens the live step, the second takes the fast path
            var edited = doc.project.operations[0]
            var d = edited.editableDepth!
            d.overcut = overcut
            edited.editableDepth = d
            doc.updateOperationLive(edited)
            #expect(approx(doc.project.operations[0].editableDepth?.cutDepth, 0.75 + overcut))
        }
    }

    @Test func twoJobSetupChangesInARowKeepAThroughCutThrough() {
        // Job Setup's own result is resolved again by `perform`: the depth it derived is not a hand edit.
        var p = project()
        p.operations = [profile(p, depth: 0.75, overcut: 0)]
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        for thickness in [0.5, 0.25] {
            var form = JobSetupForm(project: doc.project, machines: MachineCatalog.shared.machines)
            form.job.thickness = thickness
            doc.applyJobSetup(form)
            #expect(doc.project.operations[0].editableDepth?.overcut == 0, "\(thickness)")
            #expect(approx(doc.project.operations[0].editableDepth?.cutDepth, thickness), "\(thickness)")
        }
    }
}
