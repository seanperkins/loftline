import CADCore
import Foundation
import Testing
@testable import CAMCore

private typealias F = Ops2DFixture

/// L-shape: 3x1 bar with a 1x2 leg; the inner (concave) corner is at (1,1).
private let lShape = Path(points: [Vec2(0, 0), Vec2(3, 0), Vec2(3, 1), Vec2(1, 1), Vec2(1, 3), Vec2(0, 3)], closed: true)

@Test func ops2DStraightInlayMatchedOutlineRoundsBothKindsOfCorner() {
    let region = Polygon2D.region(fromLoops: [lShape.flattened(tolerance: 0.0005)])
    let m = StraightInlayOperation.matchedOutline(region, radius: 0.125, tolerance: 0.0005)
    #expect(m.count == 1)
    let r = 0.125
    // Convex corner (0,0): rounded, so the outline keeps r(√2 − 1) away from the vertex.
    #expect(abs(Polygon2D.distance(from: Vec2(0, 0), toLoop: m[0]) - r * (2.0.squareRoot() - 1)) < 0.002)
    // Concave corner (1,1): filled with a fillet of radius r, same distance on the other side.
    #expect(abs(Polygon2D.distance(from: Vec2(1, 1), toLoop: m[0]) - r * (2.0.squareRoot() - 1)) < 0.002)
    #expect(!Polygon2D.contains(m[0], Vec2(0.01, 0.01)))
    #expect(Polygon2D.contains(m[0], Vec2(1.01, 1.01)))
}

@Test(arguments: [ZZeroMode.materialTop, .spoilboard])
func ops2DStraightInlayPocketAndPlugFit(mode: ZZeroMode) throws {
    let (ctx, ids) = F.document([lShape], zZero: mode)
    let params = StraightInlayParameters(part: .both, pocketDepth: 0.125, plugDepth: 0.1875, clearance: 0.005)
    let tps = try StraightInlayOperation(setup: OperationSetup(name: "In", toolID: F.endMill.id, shapeIDs: ids), params: params)
        .generate(in: ctx)
    #expect(tps.map { $0.metadata["part"] } == ["female", "male"])
    #expect(tps.allSatisfy { $0.kind == .inlay })
    let region = Polygon2D.region(fromLoops: [lShape.flattened(tolerance: 0.0005)])
    let m = StraightInlayOperation.matchedOutline(region, radius: 0.125, tolerance: 0.0005)
    for tp in tps { #expect(F.conventionViolations(tp, coords: ctx.coords).isEmpty) }
    #expect(abs(tps[0].minZ! - ctx.coords.z(depth: 0.125)) < 1e-9)
    #expect(abs(tps[1].minZ! - ctx.coords.z(depth: 0.1875)) < 1e-9)
    // Pocket: the tool never leaves the matched outline (tool centre ≥ r inside it).
    for p in F.densePoints(tps[0].moves) where ctx.coords.depth(ofMachineZ: p.z) > 1e-9 {
        #expect(Polygon2D.contains(m[0], p.xy))
        #expect(Polygon2D.distance(from: p.xy, toLoop: m[0]) >= 0.125 - 0.002)
    }
    // Plug: the tool centre runs r + clearance outside the matched outline.
    for p in F.densePoints(tps[1].moves) where ctx.coords.depth(ofMachineZ: p.z) > 1e-9 {
        #expect(!Polygon2D.contains(m[0], p.xy))
        #expect(abs(Polygon2D.distance(from: p.xy, toLoop: m[0]) - (0.125 - 0.005)) < 0.003)
    }
}

@Test func ops2DStraightInlayMergeKeepsEachPartsMarker() throws {
    // A merge must not erase which part a cut belongs to: the validator refuses pocket and plug in
    // one program by reading this marker, so pocket and plug stay separate toolpaths, each marked.
    let (ctx, ids) = F.document([lShape], zZero: .materialTop)
    let params = StraightInlayParameters(part: .both, pocketDepth: 0.125, plugDepth: 0.1875, clearance: 0.005)
    let inlay = AnyOperation.straightInlay(StraightInlayOperation(
        setup: OperationSetup(name: "In", toolID: F.endMill.id, shapeIDs: ids), params: params))
    let merged = try AnyOperation.merge(MergeOperation(setup: OperationSetup(name: "M", toolID: F.endMill.id),
                                                       params: MergeParameters(children: [inlay]))).generate(in: ctx)
    #expect(merged.map { $0.metadata["part"] } == ["female", "male"])
}

@Test func ops2DStraightInlayMergeJoinsAnUnmarkedCutIntoTheMarkedOne() throws {
    // A same-tool cut with no marker still joins the pocket, as before markers were kept, and the joined toolpath
    // keeps the pocket's marker.
    let (ctx, ids) = F.document([lShape, F.rect(5, 0, 1, 1)], zZero: .materialTop)
    let pocket = AnyOperation.straightInlay(StraightInlayOperation(
        setup: OperationSetup(name: "In", toolID: F.endMill.id, shapeIDs: [ids[0]]),
        params: StraightInlayParameters(part: .female, pocketDepth: 0.125, plugDepth: 0.1875, clearance: 0.005)))
    let cut = AnyOperation.profile(ProfileOperation(setup: OperationSetup(name: "Cut", toolID: F.endMill.id, shapeIDs: [ids[1]]),
                                                    params: ProfileParameters(depth: DepthSettings(cutDepth: 0.1))))
    let alone = try pocket.generate(in: ctx) + cut.generate(in: ctx)
    try #require(alone.count == 2 && alone.allSatisfy { ($0.clearedDepth ?? 0) == 0 })
    let merged = try AnyOperation.merge(MergeOperation(setup: OperationSetup(name: "M", toolID: F.endMill.id),
                                                       params: MergeParameters(children: [pocket, cut]))).generate(in: ctx)
    #expect(merged.count == 1)
    #expect(merged.first?.metadata["part"] == "female")
}
