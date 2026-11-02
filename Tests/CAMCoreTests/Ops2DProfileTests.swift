import CADCore
import Foundation
import Testing
@testable import CAMCore

private typealias F = Ops2DFixture

private func profile(_ paths: [Path], side: ProfileSide = .outside, depth: Double = 0.5,
                     zZero: ZZeroMode = .materialTop, origin: XYOrigin = .lowerLeft,
                     configure: (inout ProfileParameters) -> Void = { _ in }) throws -> (Toolpath, CAMContext) {
    let (ctx, ids) = F.document(paths, zZero: zZero, origin: origin)
    var p = ProfileParameters(depth: DepthSettings(cutDepth: depth), side: side)
    configure(&p)
    let op = ProfileOperation(setup: OperationSetup(name: "Profile", toolID: F.endMill.id, shapeIDs: ids), params: p)
    let tps = try op.generate(in: ctx)
    #expect(tps.count == 1)
    return (tps[0], ctx)
}

@Test(arguments: [ZZeroMode.materialTop, .spoilboard])
func ops2DProfileDepthsFollowZZeroMode(mode: ZZeroMode) throws {
    let (tp, ctx) = try profile([F.rect(2, 2, 4, 3)], zZero: mode)
    let c = ctx.coords
    #expect(F.conventionViolations(tp, coords: c).isEmpty)
    // Deepest point is exactly the cut depth in both modes.
    #expect(abs(tp.minZ! - c.z(depth: 0.5)) < 1e-9)
    let expected = mode == .materialTop ? -0.5 : 0.25
    #expect(abs(tp.minZ! - expected) < 1e-9)
    // 0.5 deep at 0.125 stepdown = 4 passes.
    let cutZs = Set(tp.moves.filter { !$0.isRapid }.compactMap { $0.target.map { ($0.z * 1e6).rounded() } })
    let depths = cutZs.map { c.depth(ofMachineZ: $0 / 1e6) }.filter { $0 > 1e-9 }.sorted()
    #expect(depths.map { ($0 * 1000).rounded() } == [125, 250, 375, 500])
}

@Test func ops2DProfileOutsideOffsetEqualsToolRadius() throws {
    let rect = Rect2(x: 2, y: 2, width: 4, height: 3)
    let (tp, _) = try profile([F.rect(2, 2, 4, 3)])
    let pts = F.densePoints(tp.moves).filter { $0.z < -1e-9 }
    #expect(!pts.isEmpty)
    for p in pts {
        #expect(!rect.insetBy(-1e-6).contains(p.xy) || F.distanceToRectBoundary(p.xy, rect) > 0.1249)
        #expect(abs(F.distanceToRectBoundary(p.xy, rect) - F.endMill.radius) < 0.0011)
    }
    // Rounded corners come out as arcs.
    #expect(tp.moves.contains { $0.isArc })
}

@Test func ops2DProfileInsideStaysInsideByRadius() throws {
    let rect = Rect2(x: 1, y: 1, width: 3, height: 2)
    let (tp, _) = try profile([F.rect(1, 1, 3, 2)], side: .inside)
    for p in F.densePoints(tp.moves).filter({ $0.z < -1e-9 }) {
        #expect(rect.contains(p.xy))
        #expect(abs(F.distanceToRectBoundary(p.xy, rect) - F.endMill.radius) < 0.0011)
    }
}

@Test func ops2DProfileAllowanceAddsToOffset() throws {
    let rect = Rect2(x: 0, y: 0, width: 2, height: 2)
    let (tp, _) = try profile([F.rect(0, 0, 2, 2)]) { $0.allowance = 0.02 }
    for p in F.densePoints(tp.moves).filter({ $0.z < -1e-9 }) {
        #expect(abs(F.distanceToRectBoundary(p.xy, rect) - 0.145) < 0.0011)
    }
}

/// Signed area of the XY loop traced by moves at exactly `z`.
private func loopArea(_ tp: Toolpath, z: Double) -> Double {
    let pts = F.densePoints(tp.moves).filter { abs($0.z - z) < 1e-9 }.map(\.xy)
    return Polygon2D.signedArea(pts)
}

@Test func ops2DProfileClimbOutsideIsClockwise() throws {
    let (climb, _) = try profile([F.rect(0, 0, 2, 2)], depth: 0.1)
    #expect(loopArea(climb, z: -0.1) < 0)
    let (conv, _) = try profile([F.rect(0, 0, 2, 2)], depth: 0.1) { $0.direction = .conventional }
    #expect(loopArea(conv, z: -0.1) > 0)
    let (inside, _) = try profile([F.rect(0, 0, 2, 2)], side: .inside, depth: 0.1)
    #expect(loopArea(inside, z: -0.1) > 0)
}

@Test func ops2DProfileCircleUsesArcsWithOffsetRadius() throws {
    let (tp, _) = try profile([ShapeFactory.circle(center: Vec2(5, 5), radius: 1)], depth: 0.125)
    var cur: Vec3?
    var arcCount = 0
    for m in tp.moves {
        if case .arcCW(let p, let c, _) = m, let s = cur {
            arcCount += 1
            #expect(abs(c.distance(to: Vec2(5, 5))) < 0.002)
            #expect(abs(s.xy.distance(to: c) - 1.125) < 0.0011)
            #expect(abs(p.xy.distance(to: c) - 1.125) < 0.0011)
        }
        cur = m.target ?? cur
    }
    #expect(arcCount >= 2)
    #expect(tp.moves.filter { if case .linear = $0 { return true } else { return false } }.count < 6)
}

@Test func ops2DProfileTabsArePresentAtTabHeight() throws {
    let (tp, ctx) = try profile([F.rect(0, 0, 6, 4)], depth: 0.75) {
        $0.tabs = TabSettings(isEnabled: true, length: 0.25, thickness: 0.125, countPerPath: 4)
    }
    let c = ctx.coords
    let tabZ = c.z(depth: 0.625)
    let pts = F.densePoints(tp.moves)
    // Last pass: points at the final depth AND raised to the tab top.
    #expect(pts.contains { abs($0.z - c.z(depth: 0.75)) < 1e-9 })
    let tabPoints = pts.filter { abs($0.z - tabZ) < 1e-9 }
    #expect(!tabPoints.isEmpty)
    // Count tab entries in the final pass: transitions final depth -> tab top.
    var entries = 0
    for (a, b) in zip(pts, pts.dropFirst()) where abs(a.z - c.z(depth: 0.75)) < 1e-9 && abs(b.z - tabZ) < 1e-9 {
        entries += 1
    }
    #expect(entries == 4)
    // Raised section length along the path = tab length + tool diameter.
    #expect(tp.minZ! >= c.z(depth: 0.75) - 1e-9)
}

@Test func ops2DProfileTabSpacingOverridesCount() throws {
    let (tp, ctx) = try profile([F.rect(0, 0, 10, 10)], depth: 0.25) {
        $0.tabs = TabSettings(isEnabled: true, length: 0.25, thickness: 0.1, countPerPath: 2, spacing: 5)
    }
    let c = ctx.coords
    let pts = F.densePoints(tp.moves)
    var entries = 0
    for (a, b) in zip(pts, pts.dropFirst()) where abs(a.z - c.z(depth: 0.25)) < 1e-9 && abs(b.z - c.z(depth: 0.15)) < 1e-9 {
        entries += 1
    }
    // Perimeter ≈ 40.8 / spacing 5 → 8 tabs.
    #expect(entries == 8)
}

@Test func ops2DProfileTriangularTabsPeakAtTabTop() throws {
    let (tp, ctx) = try profile([F.rect(0, 0, 6, 4)], depth: 0.5) {
        $0.tabs = TabSettings(isEnabled: true, length: 0.5, thickness: 0.2, countPerPath: 3, isTriangular: true)
    }
    let c = ctx.coords
    let zs = tp.moves.compactMap { $0.target?.z }
    #expect(zs.contains { abs($0 - c.z(depth: 0.3)) < 1e-9 })
    #expect(tp.minZ! >= c.z(depth: 0.5) - 1e-9)
}

@Test func ops2DProfileOpenVectorIsCutOnTheLine() throws {
    let line = Path(points: [Vec2(1, 1), Vec2(4, 1), Vec2(4, 3)], closed: false)
    let (tp, ctx) = try profile([line], side: .outside, depth: 0.3)
    #expect(F.conventionViolations(tp, coords: ctx.coords).isEmpty)
    for p in F.densePoints(tp.moves).filter({ $0.z < -1e-9 }) {
        let onA = abs(p.y - 1) < 1e-9 && p.x >= 1 - 1e-9 && p.x <= 4 + 1e-9
        let onB = abs(p.x - 4) < 1e-9 && p.y >= 1 - 1e-9 && p.y <= 3 + 1e-9
        #expect(onA || onB)
    }
    // 3 passes, alternating direction, never retracting between them.
    #expect(tp.moves.filter(\.isRapid).count <= 3)
}

@Test func ops2DProfileSmoothRampAvoidsVerticalPlunges() throws {
    let (tp, ctx) = try profile([F.rect(0, 0, 4, 4)], depth: 0.5) {
        $0.ramp = RampSettings(isEnabled: true, type: .smooth, length: 1, maxAngle: 10)
    }
    let c = ctx.coords
    #expect(F.conventionViolations(tp, coords: c).isEmpty)
    var cur: Vec3?
    for m in tp.moves {
        if case .linear(let p, _) = m, let s = cur, p.z < s.z - 1e-9 {
            let horizontal = s.xy.distance(to: p.xy)
            if horizontal < 1e-9 {
                // Only the first entry may plunge vertically, and only to the start depth.
                #expect(c.depth(ofMachineZ: p.z) <= 1e-9)
            } else {
                // Ramp slope never steeper than maxAngle.
                #expect(atan((s.z - p.z) / horizontal) * 180 / .pi <= 10 + 1e-6)
            }
        }
        cur = m.target ?? cur
    }
    #expect(abs(tp.minZ! - c.z(depth: 0.5)) < 1e-9)
}

@Test(arguments: [RampType.zigzag, .spiral])
func ops2DProfileRampTypesReachDepth(type: RampType) throws {
    let (tp, ctx) = try profile([F.rect(0, 0, 3, 3)], depth: 0.5) {
        $0.ramp = RampSettings(isEnabled: true, type: type, length: 1, maxAngle: 15)
    }
    #expect(F.conventionViolations(tp, coords: ctx.coords).isEmpty)
    #expect(abs(tp.minZ! - ctx.coords.z(depth: 0.5)) < 1e-9)
    // Only one plunge-from-safe-Z for the whole loop.
    #expect(tp.moves.filter(\.isRapid).count <= 3)
}

@Test(arguments: [LeadType.linear, .arc])
func ops2DProfileLeadInStartsInWaste(type: LeadType) throws {
    let rect = Rect2(x: 2, y: 2, width: 4, height: 4)
    let (tp, ctx) = try profile([F.rect(2, 2, 4, 4)], depth: 0.25) {
        $0.lead = LeadSettings(type: type, distance: 0.25, overcut: 0.1)
    }
    #expect(F.conventionViolations(tp, coords: ctx.coords).isEmpty)
    // The plunge point is outside the tool-centre loop (further than r from the part).
    guard let plunge = tp.moves.first(where: { !$0.isRapid })?.target else { Issue.record("no cut"); return }
    #expect(!rect.contains(plunge.xy))
    #expect(F.distanceToRectBoundary(plunge.xy, rect) > F.endMill.radius + 0.05)
}

@Test func ops2DProfileCutsInnerLoopsBeforeOuter() throws {
    // A frame: outer square with a square hole, as one shape.
    let (ctx, ids) = F.document(shapePaths: [F.rect(0, 0, 6, 6), F.rect(2, 2, 2, 2)])
    let op = ProfileOperation(setup: OperationSetup(name: "Frame", toolID: F.endMill.id, shapeIDs: ids),
                              params: ProfileParameters(depth: DepthSettings(cutDepth: 0.125), side: .outside))
    let tp = try op.generate(in: ctx)[0]
    let cutXY = F.densePoints(tp.moves).filter { $0.z < -1e-9 }.map(\.xy)
    // The first cut points belong to the hole (inside 2..4), the last to the outside.
    #expect(Rect2(x: 1.8, y: 1.8, width: 2.4, height: 2.4).contains(cutXY.first!))
    #expect(!Rect2(x: 0, y: 0, width: 6, height: 6).contains(cutXY.last!))
    // Hole profile is offset INTO the hole (part is the frame).
    let holeRect = Rect2(x: 2, y: 2, width: 2, height: 2)
    for p in cutXY where holeRect.contains(p) {
        #expect(abs(F.distanceToRectBoundary(p, holeRect) - 0.125) < 0.0011)
    }
}

@Test func ops2DProfileXYOriginShiftsMachineCoordinates() throws {
    let (ll, _) = try profile([F.rect(2, 2, 4, 3)], depth: 0.1)
    let (cc, ctx) = try profile([F.rect(2, 2, 4, 3)], depth: 0.1, origin: .center)
    let shift = ctx.document.job.originInMaterialFrame
    #expect(abs(ll.xyBounds.min.x - shift.x - cc.xyBounds.min.x) < 1e-9)
    #expect(abs(ll.xyBounds.min.y - shift.y - cc.xyBounds.min.y) < 1e-9)
}

@Test func ops2DProfileRejectsBadInput() {
    let (ctx, ids) = F.document([F.rect(0, 0, 1, 1)])
    let bad = ProfileOperation(setup: OperationSetup(name: "P", toolID: F.endMill.id, shapeIDs: ids),
                               params: ProfileParameters(depth: DepthSettings(startDepth: 0.2, cutDepth: 0.1)))
    #expect(throws: CAMError.self) { try bad.generate(in: ctx) }
    let none = ProfileOperation(setup: OperationSetup(name: "P", toolID: F.endMill.id, shapeIDs: []))
    #expect(throws: CAMError.noGeometry) { try none.generate(in: ctx) }
    let tiny = ProfileOperation(setup: OperationSetup(name: "P", toolID: F.endMill.id, shapeIDs: ids),
                                params: ProfileParameters(side: .inside))
    let (small, sids) = F.document([F.rect(0, 0, 0.2, 0.2)])
    #expect(throws: CAMError.self) {
        try ProfileOperation(setup: OperationSetup(name: "P", toolID: F.endMill.id, shapeIDs: sids),
                             params: tiny.params).generate(in: small)
    }
}

@Test func ops2DProfileWarnsWhenOpenVectorsAreCutOnTheLine() throws {
    let open = Path(points: [Vec2(2, 2), Vec2(4, 2), Vec2(3, 4)], closed: false)
    let (outside, _) = try profile([open], side: .outside)
    #expect(outside.metadata["warning"]?.contains("open vector") == true)
    let (on, _) = try profile([open], side: .on)
    #expect(on.metadata["warning"] == nil)
}

@Test(arguments: [LeadType.linear, .arc])
func ops2DProfileInsideLeadsNeverGougeThePart(type: LeadType) throws {
    // Inside loops have sharp corners; the loop starts at one (nearest home).
    let rect = Rect2(x: 2, y: 2, width: 6, height: 4)
    let (tp, ctx) = try profile([F.rect(2, 2, 6, 4)], side: .inside, depth: 0.25) {
        $0.lead = LeadSettings(type: type, distance: 0.25, overcut: 0.1)
    }
    #expect(F.conventionViolations(tp, coords: ctx.coords).isEmpty)
    let cutXY = F.densePoints(tp.moves).filter { $0.z < -1e-9 }.map(\.xy)
    #expect(!cutXY.isEmpty)
    for p in cutXY {
        #expect(rect.contains(p))
        #expect(F.distanceToRectBoundary(p, rect) >= F.endMill.radius - 0.002)
    }
    // A lead still exists: the plunge point is off the cut loop, inside the waste.
    guard let plunge = tp.moves.first(where: { !$0.isRapid })?.target else { Issue.record("no cut"); return }
    #expect(F.distanceToRectBoundary(plunge.xy, rect) > F.endMill.radius + 0.05)
}

// MARK: - Ramps steeper than their maximum angle (issue #124)

private func polygon(radius r: Double, sides: Int = 64, center: Vec2 = Vec2(1, 1)) -> Path {
    Path(points: (0..<sides).map { i in
        let a = 2 * Double.pi * Double(i) / Double(sides)
        return center + Vec2(r * cos(a), r * sin(a))
    }, closed: true)
}

/// A loop 0.063 in round cut 0.125 per pass at 0.5 degrees needs 14.3 in of ramp; 200 laps give 12.6 in.
@Test func ops2DProfileWarnsWhenATinyLoopCannotKeepTheRampAngle() throws {
    let ramp = RampSettings(isEnabled: true, type: .spiral, length: 1, maxAngle: 0.5)
    let (tp, _) = try profile([polygon(radius: 0.01)], side: .on, depth: 0.5) { $0.ramp = ramp }
    #expect(tp.metadata["warning"]?.hasSuffix(PassShaping.steepRampWarning(ramp)) == true)
}

/// A 0.05 in open line at 0.5 degrees wants 287 zig-zag legs against the cap of 200.
@Test func ops2DProfileWarnsWhenAShortOpenVectorCannotKeepTheRampAngle() throws {
    let ramp = RampSettings(isEnabled: true, type: .zigzag, length: 1, maxAngle: 0.5)
    let line = Path(points: [Vec2(1, 1), Vec2(1.05, 1)], closed: false)
    let (tp, _) = try profile([line], side: .on, depth: 0.5) { $0.ramp = ramp }
    #expect(tp.metadata["warning"]?.contains(PassShaping.steepRampWarning(ramp)) == true)
}

@Test func ops2DProfileWithoutASteepRampHasNoRampWarning() throws {
    let (tp, _) = try profile([F.rect(0, 0, 4, 4)]) {
        $0.ramp = RampSettings(isEnabled: true, type: .spiral, length: 1, maxAngle: 10)
    }
    #expect(tp.metadata["warning"] == nil)
}

/// The inside of a 3/8 in hole with a 1/4 in mill is 0.39 in round: one lap per 0.125 in pass went down at 17.7°.
@Test(arguments: [ZZeroMode.materialTop, .spoilboard])
func ops2DProfileSpiralRampKeepsItsAngleOnASmallHole(mode: ZZeroMode) throws {
    let (tp, ctx) = try profile([polygon(radius: 0.1875, sides: 96)], side: .inside, depth: 0.5, zZero: mode) {
        $0.ramp = RampSettings(isEnabled: true, type: .spiral, length: 1, maxAngle: 10)
    }
    let c = ctx.coords
    #expect(tp.metadata["warning"] == nil)
    var cur: Vec3?
    var ramped = false
    for m in tp.moves {
        if case .linear(let p, _) = m, let s = cur, p.z < s.z - 1e-9 {
            let horizontal = s.xy.distance(to: p.xy)
            if horizontal > 1e-9 {
                ramped = true
                #expect(atan((s.z - p.z) / horizontal) * 180 / .pi <= 10 + 1e-6)
            }
        }
        cur = m.target ?? cur
    }
    #expect(ramped)
    #expect(abs(tp.minZ! - c.z(depth: 0.5)) < 1e-9)
}
