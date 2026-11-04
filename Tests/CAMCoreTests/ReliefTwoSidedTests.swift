import CADCore
import Foundation
import Testing
@testable import CAMCore

private let ballNose = ToolLibrary.seeded.tools[3]  // 1/4" ball nose

/// 4 x 4 x 1.25 in job; unit dome centred at (1.5, 2), top 0.1 below the material top, flat
/// underside 1.1 below it. The model carries the two-sided split both sides share.
private func offCentreDome(flip: FlipAxis = .leftRight, split: Double? = 0.6, web: Double = 0.04) -> (Document, PlacedModel) {
    var doc = Document(units: .inch, job: JobSetup(width: 4, height: 4, thickness: 1.25))
    var model = PlacedModel(name: "Dome", mesh: ReliefFixture.hemisphere(radius: 1, center: Vec2(1.5, 2)),
                            depth: 1.1, zTop: 0.1)
    model.reliefSplit = ReliefSplit(flip: flip, splitDepth: split, web: web)
    doc.models = [model]
    return (doc, model)
}

private func sideOp(_ model: PlacedModel, side: TwoSidedSettings.Side) -> Relief3DOperation {
    var p = Relief3DParameters(modelID: model.id, resolution: 0.02, roughing: RoughingSettings(isEnabled: false),
                               finishing: FinishingSettings(isEnabled: true, stepover: 0.1))
    p.twoSided = TwoSidedSettings(side: side)
    return Relief3DOperation(setup: OperationSetup(name: "Dome", toolID: ballNose.id), params: p)
}

private func cuts(_ tp: Toolpath, _ c: MachineCoordinates) -> [(xy: Vec2, depth: Double)] {
    ReliefFixture.cutSamples(tp, coords: c, step: 0.05).map { (xy: $0.0, depth: $0.1) }
}

@Test func reliefTwoSidedTopStopsAtSplit() throws {
    let (doc, model) = offCentreDome()
    let ctx = CAMContext(document: doc, tools: .seeded)
    let tp = try #require(sideOp(model, side: .top).generate(in: ctx).first)
    #expect(tp.metadata["side"] == "top")
    let pts = cuts(tp, ctx.coords)
    #expect(abs(pts.map(\.depth).max()! - 0.6) < 1e-6)            // clamped at the split
    #expect(pts.map(\.depth).min()! < 0.12)                        // dome top (0.1 deep)
    #expect(pts.allSatisfy { $0.xy.x < 2.6 })                      // dome is on the left
}

@Test(arguments: [FlipAxis.leftRight, .topBottom])
func reliefTwoSidedBottomIsMirroredAndStopsShortOfSplit(flip: FlipAxis) throws {
    let (doc, model) = offCentreDome(flip: flip)
    let ctx = CAMContext(document: doc, tools: .seeded)
    let tp = try #require(sideOp(model, side: .bottom).generate(in: ctx).first)
    #expect(tp.metadata["side"] == "bottom")
    #expect(ReliefFixture.followsConventions(tp, coords: ctx.coords))
    let pts = cuts(tp, ctx.coords)
    // Seen from below: the flat underside is 1.25 - 1.1 = 0.15 deep; around it the cut stops at
    // 1.25 - 0.6 - 0.04 = 0.61 (leaving the web).
    #expect(abs(pts.map(\.depth).max()! - 0.61) < 1e-6)
    let centre = flip == .leftRight ? Vec2(2.5, 2) : Vec2(1.5, 2)
    let under = pts.filter { $0.xy.distance(to: centre) < 0.6 }
    #expect(!under.isEmpty)
    #expect(under.allSatisfy { abs($0.depth - 0.15) < 0.01 })
    // The footprint is mirrored.
    let b = Rect2(points: pts.map(\.xy))
    if flip == .leftRight {
        #expect(b.min.x > 1.4 && b.max.x < 3.6)
    } else {
        #expect(b.min.x < 0.6 && b.max.x < 2.6)
    }
}

@Test func reliefTwoSidedRejectsBadSplit() {
    for (split, web, side) in [(0.05, 0.04, TwoSidedSettings.Side.top), (1.2, 0.04, .bottom), (0.6, 0.7, .bottom)] {
        let (doc, model) = offCentreDome(split: split, web: web)
        let ctx = CAMContext(document: doc, tools: .seeded)
        #expect(throws: CAMError.self) { try sideOp(model, side: side).generate(in: ctx) }
    }
    // Default split: halfway between top (0.1) and bottom (1.1).
    let (_, model) = offCentreDome()
    #expect(abs(ReliefTwoSided.splitDepth(ReliefSplit(), model: model) - 0.6) < 1e-12)
}

/// Characterization (docs/superpowers/plans/2026-11-03-implicit-state-gcode.md Task 4): the toolpaths of both sides for
/// both flips, pinned before the split moved from the operation to the model. They must not change.
@Test(arguments: [FlipAxis.leftRight, .topBottom])
func reliefTwoSidedOutputIsPinned(flip: FlipAxis) throws {
    let (doc, model) = offCentreDome(flip: flip)
    let ctx = CAMContext(document: doc, tools: .seeded)
    var digests: [String] = []
    for side in [TwoSidedSettings.Side.top, .bottom] {
        let tps = try sideOp(model, side: side).generate(in: ctx)
        let pts = tps.flatMap(\.moves).compactMap(\.target)
        let sum = pts.reduce(0.0) { $0 + $1.x * 3 + $1.y * 5 + $1.z * 7 }
        digests.append("\(pts.count):\(String(format: "%.4f", sum))")
    }
    let pinned: [FlipAxis: [String]] = [.leftRight: ["780:9302.9127", "331:5300.2959"],
                                                     .topBottom: ["780:9302.9127", "331:4307.2959"]]
    #expect(digests == pinned[flip], Comment(rawValue: "\(flip): \(digests)"))
}

@Test func bothSidesShareTheModelsSplit() throws {
    // One split for the model: changing it changes both sides' cuts, and the bottom side follows the model's flip.
    var (doc, model) = offCentreDome(split: 0.6)
    let top = sideOp(model, side: .top), bottom = sideOp(model, side: .bottom)
    func deepest(_ op: Relief3DOperation) throws -> Double {
        let ctx = CAMContext(document: doc, tools: .seeded)
        return cuts(try #require(op.generate(in: ctx).first), ctx.coords).map(\.depth).max()!
    }
    var t = try deepest(top), b = try deepest(bottom)
    #expect(abs(t - 0.6) < 1e-6 && abs(b - 0.61) < 1e-6)
    doc.models[0].reliefSplit?.splitDepth = 0.5
    t = try deepest(top); b = try deepest(bottom)
    #expect(abs(t - 0.5) < 1e-6 && abs(b - 0.71) < 1e-6)
}

@Test func aSplitThatNeedsReviewIsNotCut() {
    let (doc, model) = offCentreDome()
    var op = sideOp(model, side: .top)
    op.params.twoSided?.splitNeedsReview = true
    #expect(throws: CAMError.self) { try op.generate(in: CAMContext(document: doc, tools: .seeded)) }
}
