import CADCore
import Foundation
import Testing
@testable import CAMCore

private typealias F = Ops2DFixture

private func pocket(_ paths: [Path], asOneShape: Bool = false, depth: Double = 0.25, zZero: ZZeroMode = .materialTop,
                    configure: (inout PocketParameters) -> Void = { _ in }) throws -> ([Toolpath], CAMContext) {
    let (ctx, ids) = asOneShape ? F.document(shapePaths: paths, zZero: zZero) : F.document(paths, zZero: zZero)
    var p = PocketParameters(depth: DepthSettings(cutDepth: depth))
    configure(&p)
    let op = PocketOperation(setup: OperationSetup(name: "Pocket", toolID: F.endMill.id, shapeIDs: ids), params: p)
    return (try op.generate(in: ctx), ctx)
}

/// Cut segments (machine XY) at exactly machine z.
private func segments(_ tp: Toolpath, z: Double) -> [(Vec2, Vec2)] {
    var out: [(Vec2, Vec2)] = []
    let pts = F.densePoints(tp.moves, includeRapids: true)
    for (a, b) in zip(pts, pts.dropFirst()) where abs(a.z - z) < 1e-9 && abs(b.z - z) < 1e-9 {
        out.append((a.xy, b.xy))
    }
    return out
}

private func distanceToSegments(_ q: Vec2, _ segs: [(Vec2, Vec2)]) -> Double {
    segs.map { Polygon2D.closestPoint(onSegment: $0.0, $0.1, to: q).point.distance(to: q) }.min() ?? .infinity
}

@Test(arguments: [ZZeroMode.materialTop, .spoilboard])
func ops2DPocketOffsetStaysInsideAndReachesDepth(mode: ZZeroMode) throws {
    let rect = Rect2(x: 1, y: 1, width: 4, height: 3)
    let (tps, ctx) = try pocket([F.rect(1, 1, 4, 3)], depth: 0.3, zZero: mode)
    #expect(tps.count == 1)
    let tp = tps[0], c = ctx.coords
    #expect(F.conventionViolations(tp, coords: c).isEmpty)
    #expect(abs(tp.minZ! - c.z(depth: 0.3)) < 1e-9)
    #expect(abs(tp.minZ! - (mode == .materialTop ? -0.3 : 0.45)) < 1e-9)
    for p in F.densePoints(tp.moves) where p.z < c.materialTopZ - 1e-9 {
        #expect(rect.contains(p.xy))
        #expect(F.distanceToRectBoundary(p.xy, rect) >= F.endMill.radius - 0.0011)
    }
}

@Test func ops2DPocketOffsetCoversTheFloor() throws {
    let rect = Rect2(x: 0, y: 0, width: 3, height: 2)
    let (tps, ctx) = try pocket([F.rect(0, 0, 3, 2)], depth: 0.1)
    let segs = segments(tps[0], z: ctx.coords.z(depth: 0.1))
    var x = 0.06
    while x < rect.max.x - 0.05 {
        var y = 0.06
        while y < rect.max.y - 0.05 {
            let nearCorner = (x < 0.12 || x > 2.88) && (y < 0.12 || y > 1.88)
            if !nearCorner { #expect(distanceToSegments(Vec2(x, y), segs) <= F.endMill.radius + 1e-6) }
            y += 0.07
        }
        x += 0.07
    }
}

@Test func ops2DPocketAvoidsIslands() throws {
    let (tps, ctx) = try pocket([F.rect(0, 0, 6, 6), ShapeFactory.circle(center: Vec2(3, 3), radius: 1)],
                                asOneShape: true, depth: 0.2)
    let tp = tps[0]
    #expect(F.conventionViolations(tp, coords: ctx.coords).isEmpty)
    var nearIsland = false
    for p in F.densePoints(tp.moves) where p.z < -1e-9 {
        let d = p.xy.distance(to: Vec2(3, 3))
        #expect(d >= 1 + F.endMill.radius - 0.0011)
        if d < 1 + F.endMill.radius + 0.01 { nearIsland = true }
    }
    #expect(nearIsland)
}

@Test func ops2DPocketSeparateShapesAreBothCleared() throws {
    let (tps, _) = try pocket([F.rect(0, 0, 1, 1), F.rect(3, 0, 1, 1)], depth: 0.1)
    let xs = F.densePoints(tps[0].moves).filter { $0.z < -1e-9 }.map(\.x)
    #expect(xs.contains { $0 < 1 } && xs.contains { $0 > 3 })
    // Each component finished before moving on: only one transition between them.
    var transitions = 0
    var side: Bool?
    for x in xs {
        let s = x > 2
        if let prev = side, prev != s { transitions += 1 }
        side = s
    }
    #expect(transitions == 1)
}

@Test(arguments: [0.0, 45.0])
func ops2DPocketRasterStaysInsideWithProfilePass(angle: Double) throws {
    let rect = Rect2(x: 0, y: 0, width: 4, height: 2)
    let (tps, ctx) = try pocket([F.rect(0, 0, 4, 2)], depth: 0.1) {
        $0.strategy = .raster(angle: angle, profilePass: true)
    }
    let tp = tps[0]
    #expect(F.conventionViolations(tp, coords: ctx.coords).isEmpty)
    let segs = segments(tp, z: -0.1)
    #expect(segs.count > 10)
    for p in F.densePoints(tp.moves) where p.z < -1e-9 {
        #expect(F.distanceToRectBoundary(p.xy, rect) >= F.endMill.radius - 0.0011)
        #expect(rect.contains(p.xy))
    }
    // Floor coverage away from corners.
    for q in [Vec2(2, 1), Vec2(0.2, 1), Vec2(3.8, 0.5), Vec2(1.3, 1.7)] {
        #expect(distanceToSegments(q, segs) <= F.endMill.radius + 1e-6)
    }
    if angle == 0 {
        // Raster lines are horizontal: most cut segments have constant Y.
        let total = segs.reduce(0) { $0 + $1.0.distance(to: $1.1) }
        let horizontal = segs.filter { abs($0.0.y - $0.1.y) < 1e-9 }.reduce(0) { $0 + $1.0.distance(to: $1.1) }
        #expect(horizontal > total * 0.75)
        // Zig-zag lines are linked at depth, not with a retract per line.
        #expect(tp.moves.filter(\.isRapid).count < 8)
    }
}

@Test func ops2DPocketClearanceToolThenRestMachining() throws {
    let rect = Rect2(x: 0, y: 0, width: 4, height: 3)
    let (ctx, ids) = F.document([F.rect(0, 0, 4, 3)])
    let op = PocketOperation(setup: OperationSetup(name: "P", toolID: F.smallEndMill.id, shapeIDs: ids),
                             params: PocketParameters(depth: DepthSettings(cutDepth: 0.2), clearanceToolID: F.bigEndMill.id))
    let tps = try op.generate(in: ctx)
    #expect(tps.count == 2)
    #expect(tps[0].tool.id == F.bigEndMill.id)
    #expect(tps[1].tool.id == F.smallEndMill.id)
    for (tp, r) in [(tps[0], F.bigEndMill.radius), (tps[1], F.smallEndMill.radius)] {
        #expect(F.conventionViolations(tp, coords: ctx.coords).isEmpty)
        #expect(abs(tp.minZ! + 0.2) < 1e-9)
        for p in F.densePoints(tp.moves) where p.z < -1e-9 {
            #expect(F.distanceToRectBoundary(p.xy, rect) >= r - 0.0011)
        }
    }
    // The small tool reaches deeper into corners than the big one could.
    let smallPts = F.densePoints(tps[1].moves).filter { $0.z < -1e-9 }.map(\.xy)
    #expect(smallPts.contains { $0.distance(to: Vec2(0, 0)) < 0.1 })
    // The small tool does far less cutting than a full clear would.
    let full = try PocketOperation(setup: OperationSetup(name: "P", toolID: F.smallEndMill.id, shapeIDs: ids),
                                   params: PocketParameters(depth: DepthSettings(cutDepth: 0.2))).generate(in: ctx)
    #expect(ToolpathStats(tps[1]).cutLength < ToolpathStats(full[0]).cutLength / 3)
}

@Test func ops2DPocketRampsIntoEachPass() throws {
    let (tps, ctx) = try pocket([F.rect(0, 0, 3, 3)], depth: 0.375) {
        $0.ramp = RampSettings(isEnabled: true, type: .smooth, length: 0.5, maxAngle: 10)
    }
    let tp = tps[0], c = ctx.coords
    #expect(F.conventionViolations(tp, coords: c).isEmpty)
    var cur: Vec3?
    for m in tp.moves {
        if case .linear(let p, _) = m, let s = cur, p.z < s.z - 1e-9, s.xy.distance(to: p.xy) < 1e-9 {
            // Vertical feeds only down to an already cleared depth (approach), never into new material.
            let d = c.depth(ofMachineZ: p.z)
            #expect([0.0, 0.125, 0.25].contains { abs($0 - d) < 1e-9 })
        }
        cur = m.target ?? cur
    }
}

@Test func ops2DPocketRejectsOpenVectorsAndOversizedTools() {
    let (ctx, ids) = F.document([Path(points: [Vec2(0, 0), Vec2(1, 1)], closed: false)])
    let op = PocketOperation(setup: OperationSetup(name: "P", toolID: F.endMill.id, shapeIDs: ids))
    #expect(throws: CAMError.self) { try op.generate(in: ctx) }
    let (small, sids) = F.document([F.rect(0, 0, 0.2, 0.2)])
    let op2 = PocketOperation(setup: OperationSetup(name: "P", toolID: F.endMill.id, shapeIDs: sids))
    #expect(throws: CAMError.self) { try op2.generate(in: small) }
}

@Test(arguments: [PocketStrategy.offset, .raster(angle: 0, profilePass: true)])
func ops2DPocketWarnsAboutRegionsTooNarrowForTheTool(strategy: PocketStrategy) throws {
    // A 3" square and a 0.2" slot (narrower than the 1/4" tool).
    let (tps, _) = try pocket([F.rect(0, 0, 3, 3), F.rect(6, 0, 0.2, 3)]) { $0.strategy = strategy }
    #expect(tps.last?.metadata["warning"] == "1 region(s) too small for the tool")
    let (ok, _) = try pocket([F.rect(0, 0, 3, 3)]) { $0.strategy = strategy }
    #expect(ok.last?.metadata["warning"] == nil)
}

/// Issue #124: a ramp steeper than its maximum angle (here under the 0.5° floor) is reported once, last, on the
/// finish toolpath; a clearance toolpath carries no second "warning" key for the editor to collide on.
@Test func ops2DPocketWarnsOnceWhenARampCannotKeepItsAngle() throws {
    let ramp = RampSettings(isEnabled: true, type: .smooth, length: 1, maxAngle: 0.2)
    let (tps, _) = try pocket([F.rect(0, 0, 3, 3), F.rect(6, 0, 0.2, 3)]) {
        $0.ramp = ramp
        $0.clearanceToolID = F.bigEndMill.id
    }
    #expect(tps.count == 2)
    let warning = tps.last?.metadata["warning"] ?? ""
    #expect(warning.contains("1 region(s) too small for the tool"))
    #expect(warning.hasSuffix(PassShaping.steepRampWarning(ramp)))
    #expect(tps.first?.metadata["warning"] == nil)
}
