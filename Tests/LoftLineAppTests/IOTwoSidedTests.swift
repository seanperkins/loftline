import AppKit
import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct IOTwoSidedTests {
    @Test func mirrorAndPerSideZeroInTheModel() throws {
        var job = JobSetup(width: 20, height: 10)
        job.twoSided = TwoSidedSetup(flip: .leftRight, bottomZZero: .spoilboard)
        let p = job.otherSideTransform.apply(Vec2(3, 4))
        #expect(p.isApproximatelyEqual(to: Vec2(17, 4), tolerance: 1e-12))
        job.twoSided?.flip = .topBottom
        #expect(job.otherSideTransform.apply(Vec2(3, 4)).isApproximatelyEqual(to: Vec2(3, 6), tolerance: 1e-12))
        #expect(job.forSide(.bottom).zZero == .spoilboard)
        #expect(job.forSide(.top).zZero == .materialTop)
        // Older files (no twoSided / side keys) still decode.
        let old = try JSONEncoder().encode(JobSetup())
        #expect(!String(decoding: old, as: UTF8.self).contains("twoSided"))
        #expect(try JSONDecoder().decode(JobSetup.self, from: old).twoSided == nil)
    }

    func twoSidedProject() -> (LoftLineProject, top: AnyOperation, bottom: AnyOperation) {
        var p = AppTestSupport.project()
        var form = JobSetupForm(document: p.document)
        form.job.twoSided = TwoSidedSetup(flip: .leftRight, bottomZZero: .spoilboard)
        p = form.apply(to: p)
        let bottomLayer = p.document.layers.first { $0.side == .bottom }!.id
        p.document.shapes[1].layerID = bottomLayer
        let top = OperationFactory.make(kind: .profile, project: p, library: .seeded, shapeIDs: [p.document.shapes[0].id])!
        var bottom = OperationFactory.make(kind: .profile, project: p, library: .seeded, shapeIDs: [p.document.shapes[1].id])!
        var s = bottom.editableSetup
        s.name = "Bottom profile"
        bottom.editableSetup = s
        p.operations = [top, bottom]
        return (p, top, bottom)
    }

    @Test func jobSetupAddsBottomLayerAndSidesSplitOutput() throws {
        let (p, top, bottom) = twoSidedProject()
        #expect(p.document.layers.filter { $0.side == .bottom }.map(\.name) == [LoftLineProject.bottomLayerName])
        #expect(p.side(of: top) == .top && p.side(of: bottom) == .bottom)
        #expect(p.sideProject(.top).operations.map(\.id) == [top.id])
        let b = p.sideProject(.bottom)
        #expect(b.operations.map(\.id) == [bottom.id])
        #expect(b.document.job.zZero == .spoilboard)
    }

    @Test func bottomToolpathsUseTheBottomZeroAndMixedSidesFail() throws {
        var (p, _, bottom) = twoSidedProject()
        let r = ToolpathCalculator.calculate(bottom, project: p, library: .seeded, designRevision: 0, rapidRate: 200)
        #expect(r.error == nil)
        // Spoilboard zero: the whole cut stays at or above Z 0.
        let minZ = try #require(r.toolpaths.compactMap(\.minZ).min())
        #expect(minZ >= -0.1)
        var mixed = bottom
        var s = mixed.editableSetup
        s.shapeIDs = p.document.shapes.map(\.id)
        mixed.editableSetup = s
        p.operations.append(mixed)
        let m = ToolpathCalculator.calculate(mixed, project: p, library: .seeded, designRevision: 0, rapidRate: 200)
        #expect(m.error?.contains("both sides") == true)
    }

    @Test func documentShowsOneSideAtATime() throws {
        let (p, top, bottom) = twoSidedProject()
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        #expect(doc.isOnActiveSide(top) && !doc.isOnActiveSide(bottom))
        doc.selectAll()
        #expect(doc.selection == [p.document.shapes[0].id])
        doc.showSide(.bottom)
        #expect(doc.selection.isEmpty)
        #expect(doc.document.layer(id: doc.currentLayerID)?.side == .bottom)
        #expect(doc.outputProject.operations.map(\.id) == [bottom.id])
        #expect(doc.outputProject(for: .operation(top.id)).document.job.zZero == .materialTop)
        doc.calculateNow([bottom.id])
        #expect(doc.makeJobSheet(settings: TimeEstimateSettings()).jobName.contains("Bottom side"))
        #expect(doc.makeJobSheet(settings: TimeEstimateSettings()).steps.map(\.name) == ["Bottom profile"])
        // Turning two-sided off shows everything again.
        var form = JobSetupForm(document: doc.document)
        form.job.twoSided = nil
        doc.applyJobSetup(form)
        #expect(doc.activeSide == .top && doc.outputProject.operations.count == 2)
    }

    @Test @MainActor func canvasDrawsBothSides() throws {
        let (p, _, _) = twoSidedProject()
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        doc.showSide(.bottom)
        let view = CanvasNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.document = doc
        view.layout()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        #expect(view.pickableShapes.count == 1)
    }
}
