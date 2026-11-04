import CADCore
import Foundation
import Testing
@testable import CAMCore

@Test func ops2DArcFitterRecoversCircleAndKeepsSquares() {
    let circle = ShapeFactory.circle(center: Vec2(1, 2), radius: 0.75).flattened(tolerance: 0.0005)
    let segs = ArcFitter.fit(circle + [circle[0]], tolerance: 0.001)
    #expect(segs.count <= 5)
    var lines = 0
    for s in segs {
        if case .arc(let to, let c, let cw) = s {
            #expect(c.distance(to: Vec2(1, 2)) < 0.001)
            #expect(abs(to.distance(to: c) - 0.75) < 0.001)
            #expect(!cw)
        } else {
            lines += 1
        }
    }
    // At most a short leftover run stays linear.
    #expect(lines <= 2)
    // A square's corners lie on a circle, but its edges are far from it: stays lines.
    let square = [Vec2(0, 0), Vec2(1, 0), Vec2(1, 1), Vec2(0, 1), Vec2(0, 0)]
    #expect(ArcFitter.fit(square, tolerance: 0.001).allSatisfy { if case .line = $0 { return true } else { return false } })
}

@Test func ops2DToolpathStatsAndTimeEstimate() {
    let tool = ToolLibrary.seeded.tools[0]
    let tp = Toolpath(name: "t", kind: .profile, tool: tool, moves: [
        .rapid(to: Vec3(0, 0, 1)),
        .rapid(to: Vec3(3, 4, 1)),               // 5 rapid
        .linear(to: Vec3(3, 4, 0), feed: 10),    // 1 at 10/min
        .linear(to: Vec3(13, 4, 0), feed: 100),  // 10 at 100/min
        .arcCCW(to: Vec3(13, 4, 0), center: Vec2(12, 4), feed: 2 * .pi), // full circle r=1 → 1 min
        .dwell(seconds: 3),
    ])
    let s = ToolpathStats(tp)
    #expect(abs(s.rapidLength - 5) < 1e-9)  // the first rapid has no known start
    #expect(abs(s.cutLength - (11 + 2 * .pi)) < 1e-9)
    #expect(abs(s.cutMinutes - (0.1 + 0.1 + 1)) < 1e-9)
    #expect(abs(s.estimatedSeconds(rapidRate: 60) - ((1.2 + 5.0 / 60) * 60 + 3)) < 1e-9)
}

@Test func ops2DChainOrderingNearestNeighbourWithPrecedence() {
    let a = Chain2D(points: [Vec2(10, 0), Vec2(11, 0)], isClosed: false)
    let b = Chain2D(points: [Vec2(2, 0), Vec2(1, 0)], isClosed: false)
    let c = Chain2D(points: [Vec2(5, 0), Vec2(6, 0)], isClosed: false)
    let order = ChainOrdering.nearestNeighbour([a, b, c], from: .zero)
    #expect(order.map(\.start) == [Vec2(1, 0), Vec2(5, 0), Vec2(10, 0)])
    // c must wait for a.
    let constrained = ChainOrdering.nearestNeighbour([a, b, c], from: .zero, predecessors: [[], [], [0]])
    #expect(constrained.map(\.start) == [Vec2(1, 0), Vec2(10, 0), Vec2(6, 0)])
}

@Test func ops2DNearestNeighbourBreaksTiesByInputOrder() {
    // Four squares exactly 1 from the start (a hole grid has such ties): the first in the input goes first, every
    // run. Iterating a Set picked among them in the process's hash order, so output could differ between runs.
    func square(_ x: Double, _ y: Double) -> Chain2D {
        Chain2D(points: [Vec2(x, y), Vec2(x + 1, y), Vec2(x + 1, y + 1), Vec2(x, y + 1)], isClosed: true)
    }
    let right = square(1, -0.5), left = square(-2, -0.5), up = square(-0.5, 1), down = square(-0.5, -2)
    for chains in [[right, left, up, down], [down, up, left, right], [up, right, down, left], [left, down, right, up]] {
        // The first loop is rotated to start nearest the start (a vertex may be inserted), so compare where it is.
        let first = ChainOrdering.nearestNeighbour(chains, from: .zero)[0]
        func box(_ c: Chain2D) -> [Double] {
            [c.points.map(\.x).min()!, c.points.map(\.y).min()!, c.points.map(\.x).max()!, c.points.map(\.y).max()!]
        }
        #expect(box(first) == box(chains[0]))
    }
}

@Test func ops2DPassDepthsAndPeckDepths() {
    #expect(DrillOperation.peckDepths(start: 0, end: 0.5, peck: 0.2) == [0.2, 0.4, 0.5])
    #expect(DrillOperation.peckDepths(start: 0, end: 0.4, peck: 0.2) == [0.2, 0.4])
    #expect(DrillOperation.peckDepths(start: 0.1, end: 0.3, peck: 0) == [0.3])
}

@Test func ops2DBuilderRetractsBeforeEveryXYRapid() {
    let job = JobSetup(thickness: 0.75, zZero: .spoilboard, safeZ: 0.25)
    let coords = MachineCoordinates(job: job)
    var b = ToolpathBuilder(coords: coords, tool: ToolLibrary.seeded.tools[0], units: .inch, tolerance: 0.0005)
    b.cutChain([CutPoint(Vec2(0, 0), depth: 0.1), CutPoint(Vec2(1, 0), depth: 0.1)])
    b.cutChain([CutPoint(Vec2(5, 5), depth: 0.2), CutPoint(Vec2(6, 5), depth: 0.2)], clearedDepth: 0.1)
    let moves = b.finish()
    #expect(moves.first == .rapid(to: Vec3(0, 0, 1.0)))
    // Retract to safe Z (thickness + safeZ = 1.0) at (1,0) before moving to (5,5).
    #expect(moves.contains(.rapid(to: Vec3(1, 0, 1.0))))
    #expect(moves.contains(.rapid(to: Vec3(5, 5, 1.0))))
    // Approach rapid down to 0.05 above the cleared depth 0.1: z = 0.75 - 0.05.
    #expect(moves.contains(.rapid(to: Vec3(5, 5, 0.7))))
    #expect(moves.last == .rapid(to: Vec3(6, 5, 1.0)))
}
