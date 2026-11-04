import CADCore
import Foundation
import Testing
@testable import CAMCore

private typealias F = Ops2DFixture

/// A through cut stores how far past the material bottom it goes (`DepthSettings.overcut`); its absolute cut depth is
/// derived from the thickness of the sheet it cuts, whatever changed the thickness (docs/implicit-state-machines.md #3).
@Suite struct ThroughDepthsTests {
    private func approx(_ a: Double?, _ b: Double, _ tol: Double = 1e-9) -> Bool { a.map { abs($0 - b) <= tol } ?? false }

    func project(thickness: Double = 0.75) -> LoftLineProject {
        let (ctx, _) = F.document([F.rect(1, 1, 2, 1), F.rect(5, 1, 2, 1)])
        var p = LoftLineProject(document: ctx.document)
        p.document.job.thickness = thickness
        return p
    }

    func profile(_ p: LoftLineProject, shapes: [UUID]? = nil, overcut: Double?, depth: Double = 0.3) -> AnyOperation {
        var params = ProfileParameters(depth: DepthSettings(cutDepth: depth))
        params.depth.overcut = overcut
        return .profile(ProfileOperation(setup: OperationSetup(name: "Cut", toolID: F.endMill.id,
                                                               shapeIDs: shapes ?? p.document.shapes.map(\.id)),
                                         params: params))
    }

    @Test func overcutGivesThicknessPlusOvercut() {
        var p = project()
        p.operations = [profile(p, overcut: 0.02), profile(p, overcut: nil, depth: 0.3)]
        var r = p.resolvingThroughDepths()
        #expect(approx(r.operations[0].editableDepth?.cutDepth, 0.77))
        #expect(approx(r.operations[1].editableDepth?.cutDepth, 0.3))
        r.document.job.thickness = 0.5
        r = r.resolvingThroughDepths()
        #expect(approx(r.operations[0].editableDepth?.cutDepth, 0.52))
        #expect(approx(r.operations[1].editableDepth?.cutDepth, 0.3))
    }

    @Test func aHandEditOfCutDepthMakesItAFixedDepth() {
        // Typing a cut depth (or linking it to an expression) on a through cut means that depth: the cut no longer
        // follows the thickness. An edit of the overcut keeps it through.
        var p = project()
        p.operations = [profile(p, overcut: 0.02), profile(p, overcut: 0.02)]
        let before = p.resolvingThroughDepths()
        var after = before
        var typed = after.operations[0].editableDepth!
        typed.cutDepth = 0.5
        after.operations[0].editableDepth = typed
        var over = after.operations[1].editableDepth!
        over.overcut = 0.05
        after.operations[1].editableDepth = over
        let r = after.resolvingThroughDepths(from: before)
        #expect(r.operations[0].editableDepth?.overcut == nil)
        #expect(approx(r.operations[0].editableDepth?.cutDepth, 0.5))
        #expect(approx(r.operations[1].editableDepth?.cutDepth, 0.8))
    }

    @Test func handPassesAtOrPastTheNewDepthAreDropped() {
        var p = project()
        var op = profile(p, overcut: 0)
        var d = op.editableDepth!
        d.customPasses = [0.25, 0.5]
        op.editableDepth = d
        p.operations = [op]
        p.document.job.thickness = 0.4
        let r = p.resolvingThroughDepths()
        #expect(approx(r.operations[0].editableDepth?.cutDepth, 0.4))
        #expect(r.operations[0].editableDepth?.customPasses == [0.25])
    }

    @Test func throughDepthsFollowTheirOwnSheet() {
        var p = project()
        p.document.addSheet(name: "B", job: JobSetup(width: 10, height: 10, thickness: 0.5), layerName: "B", colorHex: "#336699")
        p.document.shapes[1].layerID = p.document.layers.last!.id
        p.operations = [profile(p, shapes: [p.document.shapes[0].id], overcut: 0.01),
                        profile(p, shapes: [p.document.shapes[1].id], overcut: 0.01)]
        let r = p.resolvingThroughDepths()
        #expect(approx(r.operations[0].editableDepth?.cutDepth, 0.76))
        #expect(approx(r.operations[1].editableDepth?.cutDepth, 0.51))
    }

    @Test func facingWithoutVectorsUsesThePrimarySheet() throws {
        // On Sheet 2 of a two-sheet job, a whole-material facing is calculated against the primary sheet's job, so its
        // through depth comes from that sheet's thickness too.
        var p = project()
        let b = p.document.addSheet(name: "B", job: JobSetup(width: 10, height: 10, thickness: 0.5), layerName: "B",
                                    colorHex: "#336699")
        p.document.switchToSheet(b)
        var facing = FacingParameters()
        facing.depth.overcut = 0
        p.operations = [.facing(FacingOperation(setup: OperationSetup(name: "Face", toolID: F.endMill.id), params: facing))]
        #expect(p.sheetID(of: p.operations[0]) == MaterialSheet.primaryID)
        let r = p.resolvingThroughDepths()
        #expect(approx(r.operations[0].editableDepth?.cutDepth, 0.75))
    }

    @Test(arguments: [ZZeroMode.materialTop, .spoilboard])
    func mergedThroughCutResolves(zZero: ZZeroMode) throws {
        var p = project()
        p.document.job.zZero = zZero
        let parts = [profile(p, shapes: [p.document.shapes[0].id], overcut: 0.02),
                     profile(p, shapes: [p.document.shapes[1].id], overcut: nil, depth: 0.4)]
        p.operations = [.merge(try #require(MergeOperation.merging(parts, name: "M")))]
        p.document.job.thickness = 0.8
        let r = p.resolvingThroughDepths()
        guard case .merge(let m) = r.operations[0] else { Issue.record("not a merge"); return }
        #expect(approx(m.params.children[0].editableDepth?.cutDepth, 0.82))
        #expect(approx(m.params.children[1].editableDepth?.cutDepth, 0.4))
        let tps = try r.operations[0].generate(in: CAMContext(document: r.document, tools: .seeded))
        let lowest = tps.flatMap(\.moves).compactMap { $0.target?.z }.min()!
        #expect(approx(lowest, MachineCoordinates(job: r.document.job).z(depth: 0.82), 1e-6))
    }

    @Test func legacyFollowsThicknessMigrates() throws {
        // A file from before overcuts: the flag with a depth at or past the bottom becomes an overcut; a depth above
        // the bottom was edited by hand after the flag was set, which the old flag ignored, so it becomes a fixed depth.
        var p = project()
        p.operations = [profile(p, overcut: nil, depth: 0.8), profile(p, overcut: nil, depth: 0.7)]
        var json = String(decoding: try p.encoded(), as: UTF8.self)
        json = json.replacingOccurrences(of: "\"cutDepth\" : 0.8,", with: "\"cutDepth\" : 0.8, \"followsThickness\" : true,")
        json = json.replacingOccurrences(of: "\"cutDepth\" : 0.7,", with: "\"cutDepth\" : 0.7, \"followsThickness\" : true,")
        #expect(json.components(separatedBy: "followsThickness").count == 3)
        let r = try LoftLineProject.decode(from: Data(json.utf8))
        #expect(approx(r.operations[0].editableDepth?.overcut, 0.05))
        #expect(approx(r.operations[0].editableDepth?.cutDepth, 0.8))
        #expect(r.operations[1].editableDepth?.overcut == nil)
        #expect(approx(r.operations[1].editableDepth?.cutDepth, 0.7))
    }

    @Test func encodedProjectHasNoFollowsThickness() throws {
        var p = project()
        var op = profile(p, overcut: 0.02)
        var d = op.editableDepth!
        d.followsThickness = true   // a decoded legacy value still in memory
        op.editableDepth = d
        p.operations = [op]
        let json = String(decoding: try p.encoded(), as: UTF8.self)
        #expect(!json.contains("followsThickness"))
        #expect(json.contains("\"overcut\""))
    }
}
