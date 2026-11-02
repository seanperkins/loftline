import CADCore
import Foundation
import Testing
@testable import CAMCore

/// Issue #96. The smooth ramp ran at least `drop / tan(max angle)` along the loop but never more than one lap, so a
/// loop shorter than that (the inside of a 1/2 in hole with a 1/4 in mill is 0.785 in round) went down steeper than
/// the maximum angle: 17.7 degrees for a 0.25 in pass with a 10 degree limit. It now keeps going round.
@Test(arguments: [0.125, 0.5, 4.0], [0.25, 0.6])
func smoothRampNeverGoesDownSteeperThanTheMaximumAngle(radius: Double, drop: Double) {
    let chain = circle(radius: radius)
    let ramp = RampSettings(isEnabled: true, type: .smooth, length: 1, maxAngle: 10)
    let pass = PassShaping.pass(on: chain, s0: 0, fromDepth: 0, toDepth: drop, ramp: ramp)
    let pts = pass.pieces.flatMap { $0 }
    let steepest = steepestSlope(pass)
    #expect(steepest <= tan(10 * Double.pi / 180) + 1e-9, "ramps at \(atan(steepest) * 180 / .pi) degrees on a loop \(chain.length) round")
    // It still arrives at the pass depth and then cuts one whole lap at that depth.
    #expect(abs(pts.last!.depth - drop) < 1e-12)
    let atDepth = zip(pts, pts.dropFirst()).filter { $0.depth > drop - 1e-12 && $1.depth > drop - 1e-12 }
        .reduce(0.0) { $0 + $1.0.xy.distance(to: $1.1.xy) }
    #expect(atDepth >= chain.length - 1e-9)
    #expect(pass.endS >= pts.last!.s - 1e-12)
}

/// The cap that stays: a loop long enough for the requested ramp is ramped exactly as before.
@Test func smoothRampOnALongLoopIsUnchanged() {
    let chain = circle(radius: 4)
    let ramp = RampSettings(isEnabled: true, type: .smooth, length: 1, maxAngle: 10)
    let pass = PassShaping.pass(on: chain, s0: 0, fromDepth: 0, toDepth: 0.25, ramp: ramp)
    let pts = pass.pieces.flatMap { $0 }
    let rampEnd = pts.first { $0.depth >= 0.25 - 1e-12 }!
    // drop / tan(10 degrees) = 1.418 in, longer than the 1 in asked for.
    #expect(abs(rampEnd.s - 0.25 / tan(10 * Double.pi / 180)) < 1e-9)
    #expect(abs(pass.endS - (chain.length + rampEnd.s)) < 1e-9)
}
