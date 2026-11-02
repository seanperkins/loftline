import CADCore
import Foundation
import Testing
@testable import CAMCore

private typealias F = Ops2DFixture

private func square(_ x: Double, _ y: Double, _ s: Double) -> [Vec2] {
    [Vec2(x, y), Vec2(x + s, y), Vec2(x + s, y + s), Vec2(x, y + s)]
}

/// Two 1" squares profiled outside: one at (1,1), one at (6,1); the rapid between them crosses x 3…5.
private func toolpath(zZero: ZZeroMode = .materialTop, origin: XYOrigin = .lowerLeft) throws -> (Toolpath, CAMContext) {
    let (ctx, ids) = F.document([F.rect(1, 1, 1, 1), F.rect(6, 1, 1, 1)], zZero: zZero, origin: origin)
    let op = ProfileOperation(setup: OperationSetup(name: "Cut", toolID: F.endMill.id, shapeIDs: ids),
                              params: ProfileParameters(depth: DepthSettings(cutDepth: 0.25)))
    return (try op.generate(in: ctx)[0], ctx)
}

@Test(arguments: [ZZeroMode.materialTop, .spoilboard])
func ops2DKeepOutFlagsCutsNearAZone(mode: ZZeroMode) throws {
    let (tp, ctx) = try toolpath(zZero: mode, origin: .center)
    // Zone 0.075" from the first square's toolpath: within the tool radius + margin of the cut.
    let near = KeepOutZone(name: "Clamp", outline: [Vec2(0.5, 1.2), Vec2(0.8, 1.2), Vec2(0.8, 1.6), Vec2(0.5, 1.6)], height: 0.5)
    let v = KeepOut.violations([tp], zones: [near], coords: ctx.coords, margin: 0.05, tolerance: 0.0005)
    #expect(v.count == 1)
    #expect(v.first?.zoneName == "Clamp")
    #expect(v.first?.isRapid == false)
    let far = KeepOutZone(name: "Far", outline: square(10, 10, 1), height: 0.5)
    #expect(KeepOut.violations([tp], zones: [far], coords: ctx.coords, margin: 0.05, tolerance: 0.0005).isEmpty)
}

@Test func ops2DKeepOutChecksRapidsAgainstTheZoneHeight() throws {
    let (tp, ctx) = try toolpath()
    // Between the squares, under the rapid path at safe Z (0.2" above the top).
    let tall = KeepOutZone(name: "Tall clamp", outline: square(3.5, 0.5, 1.5), height: 0.5)
    let v = KeepOut.violations([tp], zones: [tall], coords: ctx.coords, margin: 0.05, tolerance: 0.0005)
    #expect(v.count == 1 && v[0].isRapid)
    // A low clamp is cleared by the safe-Z rapid.
    let low = KeepOutZone(name: "Low clamp", outline: square(3.5, 0.5, 1.5), height: 0.1)
    #expect(KeepOut.violations([tp], zones: [low], coords: ctx.coords, margin: 0.05, tolerance: 0.0005).isEmpty)
}

/// The footer's travel is written as it is: no climb to safe Z before an XY rapid from below it (#132).
@Test(arguments: [ZZeroMode.materialTop, .spoilboard])
func keepOutChecksTravelMarkedAsWrittenWithoutTheClimb(zZero: ZZeroMode) {
    let coords = MachineCoordinates(job: JobSetup(zZero: zZero, safeZ: 0.5))
    let tool = Tool(name: "1/4", kind: .endMill, number: 1, diameter: 0.25, flutes: 2, stepdown: 0.1, stepover: 0.1,
                    feedRate: 100, plungeRate: 30)
    // 0.3 in tall, between X2 and X4; the travel crosses at 0.1 in above the material, below safe Z.
    let zone = KeepOutZone(name: "Clamp", outline: [Vec2(2, 0), Vec2(4, 0), Vec2(4, 2), Vec2(2, 2)], height: 0.3)
    let low = coords.z(aboveTop: 0.1)
    var tp = Toolpath(name: "Home", kind: .profile, tool: tool,
                      moves: [.rapid(to: Vec3(6, 1, low)), .rapid(to: Vec3(0, 1, low))])
    let assumed = KeepOut.violations([tp], zones: [zone], coords: coords, margin: 0.05, tolerance: 0.0005)
    #expect(assumed.isEmpty, "the program's own rapids climb first")
    tp.metadata[KeepOut.asWrittenKey] = "1"
    let written = KeepOut.violations([tp], zones: [zone], coords: coords, margin: 0.05, tolerance: 0.0005)
    #expect(written.count == 1)
    #expect(written.first?.isRapid == true)
}
