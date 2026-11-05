import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct DrawingCommandTests {
    @Test func dogboneRelievesSelectedOpeningsInPlace() {
        var p = AppTestSupport.project()
        let ids = p.document.shapes.map(\.id)
        let n = VectorCommands.dogbone([ids[0]], toolDiameter: 0.25, style: .dogbone, side: .opening, maxAngle: 135, in: &p)
        #expect(n == 4)
        #expect(p.document.shapes[0].origin == .derived(operation: "dog-bone"))
        #expect(p.document.shapes[0].id == ids[0])
        #expect(p.document.shapes[1].paths == AppTestSupport.project().document.shapes[1].paths)
        // A plain rectangle cut as a part has no inside corners.
        var q = AppTestSupport.project()
        #expect(VectorCommands.dogbone(ids, toolDiameter: 0.25, style: .dogbone, side: .part, maxAngle: 135, in: &q) == 0)
    }

    @Test func textStaysEditableUntilNodeEdit() throws {
        var p = AppTestSupport.project()
        let spec = TextSpec(string: "HI", fontName: "Helvetica", size: 1, alignment: .center, anchor: Vec2(10, 5))
        let s = try TextOutliner().shape(for: spec, layerID: p.document.defaultLayerID)
        p.document.add(s)
        p.transformShapes([s.id], by: .translation(Vec2(1, 0)))
        var edited = p.document.shape(id: s.id)!.text!
        edited.string = "HELLO"
        try VectorCommands.updateText(s.id, spec: edited, in: &p)
        let after = p.document.shape(id: s.id)!
        #expect(after.text?.string == "HELLO")
        #expect(after.name == "HELLO")
        // Centre-justified: still centred on the moved anchor.
        #expect(abs(after.bounds().center.x - 11) < 0.1)
        p.moveNodes([NodeRef(shapeID: s.id, path: 0, node: 0)], by: Vec2(0.01, 0))
        #expect(p.document.shape(id: s.id)!.text == nil)
    }

    @Test func fitTextToBoundary() throws {
        var p = AppTestSupport.project()
        let s = try TextOutliner().shape(for: TextSpec(string: "WIDE", fontName: "Helvetica", size: 1, anchor: Vec2(20, 20)),
                                         layerID: p.document.defaultLayerID)
        p.document.add(s)
        let box = p.document.shapes[0]  // 2 x 1 at (1,1)
        #expect(VectorCommands.fitTextToBox([s.id, box.id], margin: 0.1, stretch: false, in: &p))
        let b = p.document.shape(id: s.id)!.bounds()
        #expect(abs(b.width - 1.8) < 1e-6 || abs(b.height - 0.8) < 1e-6)
        #expect(b.center.isApproximatelyEqual(to: Vec2(2, 1.5), tolerance: 1e-6))
        #expect(p.document.shape(id: s.id)!.text != nil)
        #expect(!VectorCommands.fitTextToBox([box.id], margin: 0, stretch: false, in: &p))
    }

    @Test func textBentIntoArc() throws {
        var p = AppTestSupport.project()
        let s = try TextOutliner().shape(for: TextSpec(string: "ARCH", fontName: "Helvetica", size: 1, alignment: .center,
                                                       anchor: Vec2(10, 5)), layerID: p.document.defaultLayerID)
        p.document.add(s)
        let id = try #require(try VectorCommands.textOnCurve(textID: s.id, curveID: nil, bendRadius: 4, convex: true,
                                                             placement: .center, offset: 0, flip: false, keepOriginal: false, in: &p))
        #expect(p.document.shape(id: s.id) == nil)
        let b = p.document.shape(id: id)!.bounds()
        #expect(abs(b.center.x - 10) < 0.2)
        #expect(b.min.y > 4.5)  // arched about a circle centred 4 below the baseline
    }

    @Test func repairDeletesDuplicatesAndPrunesOperations() {
        var p = AppTestSupport.project()
        let orig = p.document.shapes[0]
        var dup = orig
        dup.id = UUID()
        p.document.add(dup)
        let issues = VectorValidator.check(VectorCommands.validationScope([], in: p), tolerance: 0.0005)
        #expect(issues.map(\.kind) == [.duplicate])
        #expect(VectorCommands.repair(issues, in: &p) == 1)
        #expect(p.document.shapes.count == 2)
    }

    @Test func mirrorAboutMaterialCentreAndCopy() {
        var p = AppTestSupport.project()
        p.document.job.width = 10
        let first = p.document.shapes[0]  // x 1...3
        VectorCommands.mirror([first.id], horizontally: true, pivot: .materialCenter, keepOriginal: false, in: &p)
        let b = p.document.shape(id: first.id)!.bounds()
        #expect(abs(b.min.x - 7) < 1e-9 && abs(b.max.x - 9) < 1e-9)
        let copies = VectorCommands.mirror([first.id], horizontally: false, pivot: .maxEdge, keepOriginal: true, in: &p)!
        #expect(copies.count == 1 && p.document.shapes.count == 3)
        let c = p.document.shape(id: copies[0])!.bounds()
        #expect(abs(c.min.y - 2) < 1e-9 && abs(c.max.y - 3) < 1e-9)
    }

    @Test func trimClickAndTrimToBoundary() {
        var p = AppTestSupport.project()  // rectangles x 1...3 and 5...7, y 1...2
        let line = Shape(layerID: p.document.defaultLayerID, paths: [Path(points: [Vec2(0, 1.5), Vec2(8, 1.5)], closed: false)])
        p.document.add(line)
        #expect(VectorCommands.trim(at: Vec2(4, 1.5), pickTolerance: 0.05, in: &p))
        #expect(p.document.shape(id: line.id)!.paths.count == 2)
        #expect(!VectorCommands.trim(at: Vec2(40, 40), pickTolerance: 0.05, in: &p))
        // Trim the remaining line pieces to the first rectangle: only the part inside it stays.
        let rect = p.document.shapes[0].id
        #expect(VectorCommands.trimToBoundary([rect, line.id], keepInside: true, in: &p) == 1)
        let left = p.document.shape(id: line.id)!
        #expect(left.paths.count == 1)
        #expect(abs(left.bounds().min.x - 1) < 1e-6 && abs(left.bounds().max.x - 3) < 1e-6)
    }

    @Test func filletSelectedNodeOrAllCorners() {
        var p = AppTestSupport.project()
        let a = p.document.shapes[0].id, b = p.document.shapes[1].id
        VectorCommands.treatCorners(.chamfer(distance: 0.25), shapes: [], nodes: [NodeRef(shapeID: a, path: 0, node: 0)], in: &p)
        #expect(p.document.shape(id: a)!.paths[0].segments.count == 5)
        #expect(VectorCommands.treatCorners(.fillet(radius: 0.25), shapes: [b], nodes: [], in: &p) == 1)
        #expect(p.document.shape(id: b)!.paths[0].segments.filter { if case .arc = $0 { return true }; return false }.count == 4)
    }

    @Test func deleteDuplicatesOnDocument() {
        var p = AppTestSupport.project()
        var copy = p.document.shapes[1]
        copy.id = UUID()
        p.document.add(copy)
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        doc.deleteDuplicateVectors()
        #expect(doc.project.document.shapes.count == 2)
        #expect(doc.alert?.message.contains("Deleted 1") == true)
    }

    @Test func placeTraceScalesAndCentres() {
        let px = [Path(points: [Vec2(0, 0), Vec2(100, 0), Vec2(100, 50), Vec2(0, 50)], closed: true)]
        let placed = VectorCommands.placeTrace(px, imageSize: Vec2(100, 50), width: 10, center: Vec2(12, 6))
        let b = placed[0].bounds()
        #expect(b.min.isApproximatelyEqual(to: Vec2(7, 3.5), tolerance: 1e-9) && b.max.isApproximatelyEqual(to: Vec2(17, 8.5), tolerance: 1e-9))
        var p = AppTestSupport.project()
        let id = VectorCommands.addTrace(placed, name: "Trace logo", layer: p.document.defaultLayerID, in: &p)
        #expect(p.document.shape(id: id!)?.name == "Trace logo")
    }

    @Test func alignNodesOnAverage() {
        let p = AppTestSupport.project()
        let id = p.document.shapes[0].id  // corners (1,1) (3,1) (3,2) (1,2)
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        doc.activeTool = .nodeEdit
        doc.nodeSelection = [NodeRef(shapeID: id, path: 0, node: 0), NodeRef(shapeID: id, path: 0, node: 2)]
        doc.alignSelectedNodes(onX: true)
        #expect(doc.project.nodePosition(NodeRef(shapeID: id, path: 0, node: 0))?.x == 2)
        #expect(doc.project.nodePosition(NodeRef(shapeID: id, path: 0, node: 2))?.x == 2)
        doc.nodeSelection = [NodeRef(shapeID: id, path: 0, node: 1)]
        doc.convertSpansToArcs()
        #expect(doc.project.document.shape(id: id)!.paths[0].segments.count > 4)
    }

    @Test func extendOpenVectorToRectangles() {
        var p = AppTestSupport.project()  // rectangles x 1...3 and 5...7, y 1...2
        let stub = Shape(layerID: p.document.defaultLayerID, paths: [Path(points: [Vec2(3.5, 1.5), Vec2(4.5, 1.5)], closed: false)])
        p.document.add(stub)
        #expect(VectorCommands.extendToBoundaries([stub.id], in: &p) == 1)
        let e = p.document.shape(id: stub.id)!.paths[0]
        #expect(e.start.isApproximatelyEqual(to: Vec2(3, 1.5), tolerance: 1e-9) && e.end.isApproximatelyEqual(to: Vec2(5, 1.5), tolerance: 1e-9))
    }

    @Test func straightInlayPocketAndPlugMatch() throws {
        var p = AppTestSupport.project()
        let sq = p.document.shapes[0]  // 2 x 1
        let (pocketID, plugID) = try #require(VectorCommands.straightInlay([sq.id], toolDiameter: 0.25, clearance: 0.01,
                                                                          mirrorPlug: true, in: &p))
        let pocket = p.document.shape(id: pocketID)!, plug = p.document.shape(id: plugID)!
        let a = abs(pocket.paths.reduce(0) { $0 + $1.signedArea() }), b = abs(plug.paths.reduce(0) { $0 + $1.signedArea() })
        // Rounded corners lose (4 - π) r² = 0.0134; the pocket is bigger than the plug by the clearance.
        #expect(a > b && a - b < 0.07)
        #expect(abs(pocket.bounds().width - 2.01) < 1e-3)
        #expect(abs(plug.bounds().width - 1.99) < 1e-3)
        #expect(plug.bounds().min.x > pocket.bounds().max.x)
    }

    @Test func copyAlongOpenGuide() {
        var p = AppTestSupport.project()
        let obj = p.document.shapes[0]  // centre (2, 1.5)
        let guide = Shape(layerID: p.document.defaultLayerID, paths: [Path(points: [Vec2(0, 10), Vec2(0, 20)], closed: false)])
        p.document.add(guide)
        let ids = VectorCommands.copyAlong([obj.id, guide.id], count: 3, rotate: true, keepOriginal: false, in: &p)
        #expect(ids.count == 3 && p.document.shape(id: obj.id) == nil)
        let centres = ids.map { p.document.shape(id: $0)!.bounds().center }
        #expect(centres[1].isApproximatelyEqual(to: Vec2(0, 15), tolerance: 1e-9))
        // Rotated 90° to follow the vertical guide: the 2-wide rectangle is now 2 tall.
        #expect(abs(p.document.shape(id: ids[0])!.bounds().height - 2) < 1e-9)
        #expect(CopyAlong.count(along: guide.paths[0], spacing: 2.5) == 5)
    }

    @Test func vectorTextureAddsOneShape() {
        var p = AppTestSupport.project()
        var o = VectorTexture.Options()
        o.spacing = 0.2
        let id = VectorCommands.vectorTexture([p.document.shapes[0].id], options: o, in: &p)
        let s = p.document.shape(id: id!)!
        #expect(s.paths.count >= 4 && s.paths.allSatisfy { !$0.isClosed })
        #expect(VectorCommands.vectorTexture([], options: o, in: &p) == nil)
    }

    @Test func boundaryAroundSelection() {
        var p = AppTestSupport.project()
        let ids = p.document.shapes.map(\.id)
        let id = VectorCommands.boundary(ids, kind: .rectangle, margin: 0.5, gap: 0, in: &p)!
        let b = p.document.shape(id: id)!.bounds()
        #expect(b.min == Vec2(0.5, 0.5) && b.max == Vec2(7.5, 2.5))
        let wrap = VectorCommands.boundary(ids, kind: .shrinkWrap, margin: 0, gap: 1.5, in: &p)!
        #expect(p.document.shape(id: wrap)!.paths.count == 1)  // the 2-wide gap is bridged
    }

    @Test func plaqueAroundSelection() {
        var p = AppTestSupport.project()
        let ids = p.document.shapes.map(\.id)  // bounds (1,1)-(7,2)
        let id = VectorCommands.plaque(ids, style: .rounded, margin: 1, corner: 0.5, borderInset: 0.25, in: &p)!
        let s = p.document.shape(id: id)!
        #expect(s.paths.count == 2)
        let b = s.bounds()
        #expect(abs(b.min.x) < 1e-6 && abs(b.max.x - 8) < 1e-6 && abs(b.min.y) < 1e-6 && abs(b.max.y - 3) < 1e-6)
        let oval = VectorCommands.plaque(ids, style: .oval, margin: 0, corner: 0, borderInset: 0, in: &p)!
        // The ellipse contains the content's corners.
        let poly = p.document.shape(id: oval)!.paths[0].flattened()
        #expect(PathGeometry.contains(poly, Vec2(1.01, 1.01)) && PathGeometry.contains(poly, Vec2(6.99, 1.99)))
    }

    @Test func rectangularArrayCopiesWithGap() {
        var p = AppTestSupport.project()
        let first = p.document.shapes[0]
        let ids = VectorCommands.rectangularArray([first.id], rows: 2, columns: 2, x: 0.5, y: 1, spacing: .gap, in: &p)
        #expect(ids.count == 3)
        #expect(p.document.shapes.count == 5)
        let b = p.bounds(of: Set(ids + [first.id]))
        // 2x1 rectangle at (1,1): two columns with a 0.5 gap, two rows with a 1 gap.
        #expect(b.min == Vec2(1, 1) && b.max == Vec2(5.5, 4))
    }

    @Test func fitCurvesSimplifiesDenseVectorsOnly() {
        var p = AppTestSupport.project()
        let dense = Shape(layerID: p.document.defaultLayerID, paths: [Path(points: (0...100).map { Vec2(Double($0) * 0.01, 0) }, closed: false)])
        p.document.add(dense)
        let (before, after) = VectorCommands.fitCurves(p.document.shapes.map(\.id), tolerance: 0.001, in: &p)
        #expect(before - after == 99)  // the rectangles are left alone
        #expect(p.document.shape(id: dense.id)!.paths[0].segments.count == 1)
    }

    @Test func circularArrayAroundPoint() {
        var p = AppTestSupport.project()
        let first = p.document.shapes[0]  // centre (2, 1.5)
        let ids = VectorCommands.circularArray([first.id], count: 4, center: Vec2(0, 1.5), stepDegrees: 90, rotateCopies: true, in: &p)
        #expect(ids.count == 3)
        let c = p.document.shape(id: ids[1])!.bounds().center
        #expect(c.isApproximatelyEqual(to: Vec2(-2, 1.5), tolerance: 1e-9))
    }

    @Test func arrayCopiesKeepGroupsSeparate() {
        var p = AppTestSupport.project()
        let ids = p.document.shapes.map(\.id)
        p.document.group(ids)
        let new = VectorCommands.arrayCopies([ids[0]], transforms: [.translation(Vec2(0, 5)), .translation(Vec2(0, 10))], in: &p)
        #expect(new.count == 4)  // the whole group is copied twice
        let groups = Set(p.document.shapes(ids: new).compactMap(\.groupID))
        #expect(groups.count == 2 && !groups.contains(p.document.shapes[0].groupID!))
    }
}
