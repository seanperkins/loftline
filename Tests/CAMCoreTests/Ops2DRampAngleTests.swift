import CADCore
import Foundation
import Testing
@testable import CAMCore

/// A closed regular polygon standing in for a circle.
func circle(radius r: Double, sides: Int = 96) -> ArcLengthChain {
    let pts = (0..<sides).map { i -> Vec2 in
        let a = 2 * Double.pi * Double(i) / Double(sides)
        return Vec2(r * cos(a), r * sin(a))
    }
    return ArcLengthChain(Chain2D(points: pts, isClosed: true))
}

/// The steepest descent (depth per unit of XY run) between consecutive stations of a pass.
func steepestSlope(_ pass: ChainPass) -> Double {
    let pts = pass.pieces.flatMap { $0 }
    var steepest = 0.0
    for (a, b) in zip(pts, pts.dropFirst()) {
        let run = a.xy.distance(to: b.xy)
        guard run > 1e-12 else { continue }
        steepest = max(steepest, abs(b.depth - a.depth) / run)
    }
    return steepest
}

private func square(side: Double) -> ArcLengthChain {
    ArcLengthChain(Chain2D(points: [Vec2(0, 0), Vec2(side, 0), Vec2(side, side), Vec2(0, side)], isClosed: true))
}

private let tan10 = tan(10 * Double.pi / 180)

/// Issue #124. The spiral ramp went down over exactly one lap, so round a loop shorter than drop / tan(angle) it
/// was steeper than the maximum: 17.7 degrees for a 0.25 in pass inside a 1/2 in hole with a 1/4 in mill.
@Test(arguments: [0.125, 0.5, 4.0], [0.25, 0.6])
func spiralRampNeverGoesDownSteeperThanTheMaximumAngle(radius: Double, drop: Double) {
    let chain = circle(radius: radius)
    let ramp = RampSettings(isEnabled: true, type: .spiral, length: 1, maxAngle: 10)
    let pass = PassShaping.pass(on: chain, s0: 0, fromDepth: 0, toDepth: drop, ramp: ramp)
    #expect(steepestSlope(pass) <= tan10 + 1e-9, "on a loop \(chain.length) round")
    #expect(!pass.isSteeperThanMaxAngle)
    let pts = pass.pieces.flatMap { $0 }
    #expect(abs(pts.last!.depth - drop) < 1e-12)
    let atDepth = zip(pts, pts.dropFirst()).filter { $0.depth > drop - 1e-12 && $1.depth > drop - 1e-12 }
        .reduce(0.0) { $0 + $1.0.xy.distance(to: $1.1.xy) }
    #expect(atDepth >= chain.length - 1e-9)
}

/// The guard on unchanged G-code (no sample or golden file enables a ramp): a loop long enough for one lap is
/// ramped exactly as before, wherever the pass starts and whether or not it is the last.
@Test(arguments: [0.0, 0.37], [false, true])
func spiralRampOnALongLoopIsUnchanged(s0: Double, finish: Bool) {
    let chain = circle(radius: 4)
    let L = chain.length
    let ramp = RampSettings(isEnabled: true, type: .spiral, length: 1, maxAngle: 10)
    let pass = PassShaping.pass(on: chain, s0: s0, fromDepth: 0.1, toDepth: 0.35, ramp: ramp, overcut: 0.1,
                                spiralFinish: finish)
    var expected = [chain.samples(from: s0, to: s0 + L) { s in 0.1 + 0.25 * (s - s0) / L }]
    if finish { expected.append(chain.samples(from: s0 + L, to: s0 + 2 * L + 0.1) { _ in 0.35 }) }
    #expect(pass.pieces.count == expected.count)
    for (got, want) in zip(pass.pieces, expected) {
        #expect(got.count == want.count)
        for (g, w) in zip(got, want) {
            #expect(g.xy.distance(to: w.xy) < 1e-9 && abs(g.s - w.s) < 1e-9 && abs(g.depth - w.depth) < 1e-9)
        }
    }
    #expect(abs(pass.endS - (finish ? s0 + 2 * L + 0.1 : s0 + L)) < 1e-9)
    #expect(!pass.isSteeperThanMaxAngle)
}

@Test func spiralRampEndsWhereItsLengthSays() {
    let chain = circle(radius: 0.125)
    let L = chain.length
    let ramp = RampSettings(isEnabled: true, type: .spiral, length: 1, maxAngle: 10)
    let length = 0.25 / tan10
    #expect(length > L)
    let open = PassShaping.pass(on: chain, s0: 0, fromDepth: 0, toDepth: 0.25, ramp: ramp, spiralFinish: false)
    #expect(abs(open.endS - length) < 1e-9)
    #expect(abs(open.pieces.flatMap { $0 }.last!.depth - 0.25) < 1e-12)
    let last = PassShaping.pass(on: chain, s0: 0, fromDepth: 0, toDepth: 0.25, ramp: ramp, overcut: 0.1)
    #expect(abs(last.endS - (length + L + 0.1)) < 1e-9)
}

/// Past the 200-lap and 200-leg caps a ramp has to be steeper; it now says so. A 0.0015 in square is 0.006 in
/// round: spiral and smooth need 1.418 in against a 1.2 in cap, and zig-zag wants 237 legs.
@Test(arguments: [RampType.spiral, .smooth, .zigzag])
func aRampTooShortEvenAtTheCapIsFlagged(type: RampType) {
    let ramp = RampSettings(isEnabled: true, type: type, length: 1, maxAngle: 10)
    let pass = PassShaping.pass(on: square(side: 0.0015), s0: 0, fromDepth: 0, toDepth: 0.25, ramp: ramp)
    #expect(pass.isSteeperThanMaxAngle)
    #expect(steepestSlope(pass) > tan10)
}

/// An angle under the 0.5 degree floor is ramped at 0.5 degrees, steeper than asked.
@Test(arguments: [RampType.spiral, .smooth, .zigzag])
func aRampUnderTheFloorIsFlagged(type: RampType) {
    let ramp = RampSettings(isEnabled: true, type: type, length: 1, maxAngle: 0.2)
    let pass = PassShaping.pass(on: circle(radius: 1), s0: 0, fromDepth: 0, toDepth: 0.25, ramp: ramp)
    #expect(pass.isSteeperThanMaxAngle)
}

/// The flag measures the slope: a ramp gentler than asked is never flagged, even under the floor.
@Test(arguments: [RampType.spiral, .smooth, .zigzag])
func aGentleRampIsNotFlagged(type: RampType) {
    let normal = RampSettings(isEnabled: true, type: type, length: 1, maxAngle: 10)
    #expect(!PassShaping.pass(on: circle(radius: 1), s0: 0, fromDepth: 0, toDepth: 0.25, ramp: normal).isSteeperThanMaxAngle)
    let floor = RampSettings(isEnabled: true, type: type, length: 25, maxAngle: 0.2)
    let pass = PassShaping.pass(on: circle(radius: 4), s0: 0, fromDepth: 0, toDepth: 0.05, ramp: floor)
    #expect(steepestSlope(pass) <= tan(0.2 * Double.pi / 180))
    #expect(!pass.isSteeperThanMaxAngle)
}

@Test func aZeroAngleRampIsFlagged() {
    let ramp = RampSettings(isEnabled: true, type: .smooth, length: 1, maxAngle: 0)
    #expect(PassShaping.pass(on: circle(radius: 1), s0: 0, fromDepth: 0, toDepth: 0.1, ramp: ramp).isSteeperThanMaxAngle)
}

@Test func tabsKeepTheFlag() {
    let chain = circle(radius: 1)
    let ramp = RampSettings(isEnabled: true, type: .smooth, length: 1, maxAngle: 0.2)
    let pass = PassShaping.pass(on: chain, s0: 0, fromDepth: 0, toDepth: 0.25, ramp: ramp)
    #expect(pass.isSteeperThanMaxAngle)
    let tabs = TabLayout(loopLength: chain.length, centers: [chain.length / 2],
                         settings: TabSettings(isEnabled: true, thickness: 0.1), toolDiameter: 0.25, cutDepth: 0.25)
    #expect(!tabs.centers.isEmpty)
    #expect(tabs.apply(to: pass, chain: chain).isSteeperThanMaxAngle)
}

@Test func steepRampWarningFormatsTheAngle() {
    #expect(PassShaping.steepRampWarning(RampSettings(maxAngle: 7.5)).contains("the 7.5° maximum"))
    #expect(PassShaping.steepRampWarning(RampSettings(maxAngle: 10))
        == "ramps go down steeper than the 10° maximum angle on some passes (the vector is too short, or the angle "
        + "is under 0.5°); use a plunge, a steeper maximum angle, or a shallower pass depth")
}
