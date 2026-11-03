import CADCore
import Foundation
import Testing
@testable import CAMCore

private let ballQuarter = ToolLibrary.seeded.tools[3]  // 1/4" ball nose
private let ballEighth = ToolLibrary.seeded.tools[4]   // 1/8" ball nose

/// Flat at depth 0 with a 0.2 in wide, 0.3 in deep slot along Y at x = 1.
private func slotMap() -> ReliefHeightmap {
    var map = ReliefHeightmap(origin: .zero, cellSize: 0.02, columns: 101, rows: 51, baseDepth: 0)
    for j in 0..<map.rows {
        for i in 0..<map.columns where abs(map.position(i, j).x - 1) < 0.1 { map[i, j] = 0.3 }
    }
    return map
}

@Test func reliefRestRegionFollowsSlotTheLargerBallCannotReach() {
    let map = slotMap()
    let boundary = [ReliefRegion.rectangle(Rect2(x: 0.2, y: 0.2, width: 1.6, height: 0.6))]
    let rest = ReliefRest.region(map: map, boundary: boundary, tool: ballEighth, previousTool: ballQuarter,
                                 margin: 0.02, threshold: 0.002, tolerance: 0.0005)
    #expect(!rest.isEmpty)
    let b = Rect2(points: rest.flatMap { $0 })
    // Around the slot only (slot ±0.08 plus the small ball's radius and the margin), full height.
    #expect(b.min.x > 1 - 0.1 - 0.0625 - 0.06)
    #expect(b.max.x < 1 + 0.1 + 0.0625 + 0.06)
    #expect(b.min.y < 0.21 && b.max.y > 0.79)
    #expect(Polygon2D.regionContains(rest, Vec2(1, 0.5)))
    #expect(!Polygon2D.regionContains(rest, Vec2(0.5, 0.5)))
    // A previous tool no larger than the rest tool leaves nothing.
    let none = ReliefRest.region(map: map, boundary: boundary, tool: ballEighth, previousTool: ballEighth,
                                 margin: 0.02, threshold: 0.002, tolerance: 0.0005)
    #expect(none.isEmpty)
}

/// Height-field mesh of `z(x, y)` over [0, w] x [0, h] (top surface only).
private func gridMesh(width w: Double, height h: Double, step: Double, z: (Vec2) -> Double) -> Mesh3D {
    let nx = Int((w / step).rounded()), ny = Int((h / step).rounded())
    var v: [Vec3] = []
    for j in 0...ny { for i in 0...nx { let p = Vec2(Double(i) * step, Double(j) * step); v.append(Vec3(p, z: z(p))) } }
    var idx: [UInt32] = []
    func at(_ i: Int, _ j: Int) -> UInt32 { UInt32(j * (nx + 1) + i) }
    for j in 0..<ny { for i in 0..<nx { idx += [at(i, j), at(i + 1, j), at(i + 1, j + 1), at(i, j), at(i + 1, j + 1), at(i, j + 1)] } }
    return Mesh3D(vertices: v, indices: idx)
}

/// 3 x 2 x 1 in job with a 0.24 in wide, 0.3 in deep slot along Y at x = 1.5 in a flat-topped block, plus a gentle
/// dome-like hump that both balls can follow.
private func grooveDoc() -> (Document, PlacedModel) {
    var doc = Document(units: .inch, job: JobSetup(width: 3, height: 2, thickness: 1))
    let mesh = gridMesh(width: 3, height: 2, step: 0.02) { p in
        if abs(p.x - 1.5) < 0.12 { return 0 }
        let r = p.distance(to: Vec2(0.6, 1))
        return 0.3 + (r < 0.4 ? 0.1 * (1 + cos(.pi * r / 0.4)) / 2 : 0)
    }
    let model = PlacedModel(name: "Groove", mesh: mesh, depth: 0.4, zTop: 0)
    doc.models = [model]
    return (doc, model)
}

/// A finishing-only relief of `model` with `tool`, resting after `rest`.
private func finish(_ name: String, _ model: PlacedModel, tool: Tool, rest: RestSource? = nil,
                    side: TwoSidedSettings.Side? = nil) -> Relief3DOperation {
    var p = Relief3DParameters(modelID: model.id, resolution: 0.02, roughing: RoughingSettings(isEnabled: false),
                               finishing: FinishingSettings(isEnabled: true, stepover: 0.03))
    p.finishing.rest = rest
    p.twoSided = side.map { TwoSidedSettings(side: $0) }
    return Relief3DOperation(setup: OperationSetup(name: name, toolID: tool.id), params: p)
}

private func context(_ doc: Document, _ ops: [Relief3DOperation]) -> CAMContext {
    var ctx = CAMContext(document: doc, tools: .seeded)
    ctx.operations = ops.map { .relief3D($0) }
    return ctx
}

@Test func reliefRestFinishingStaysNearTheGroove() throws {
    // The rest pass names the operation it follows; that operation's finishing tool is the larger tool.
    let (doc, model) = grooveDoc()
    let source = finish("Finish", model, tool: ballQuarter)
    let op = finish("Rest", model, tool: ballEighth, rest: .operation(source.setup.id))
    let ctx = context(doc, [source, op])
    let tp = try #require(op.generate(in: ctx).first)
    #expect(ReliefFixture.followsConventions(tp, coords: ctx.coords))
    let cuts = tp.moves.filter { !$0.isRapid }.compactMap { $0.target?.xy }
    #expect(!cuts.isEmpty)
    #expect(cuts.allSatisfy { abs($0.x - 1.5) < 0.25 })
    // It goes down to the bottom of the slot (0.4 below the top), which the 1/4" ball could not.
    #expect(abs((tp.minZ ?? 0) - -0.4) < 0.01)
    #expect(tp.metadata["restAfter"] == source.setup.id.uuidString)

    // A source finishing with the same tool: nothing to do.
    let same = finish("Finish", model, tool: ballEighth)
    let rest2 = finish("Rest", model, tool: ballEighth, rest: .operation(same.setup.id))
    #expect(throws: CAMError.self) { try rest2.generate(in: context(doc, [same, rest2])) }
}

private func restError(_ op: Relief3DOperation, _ ctx: CAMContext) -> String? {
    do { _ = try op.generate(in: ctx); return nil } catch let CAMError.invalidParameter(m) { return m } catch { return "\(error)" }
}

@Test func disabledOrLaterRestSourceIsAnError() {
    let (doc, model) = grooveDoc()
    var source = finish("Finish", model, tool: ballQuarter)
    let rest = finish("Rest", model, tool: ballEighth, rest: .operation(source.setup.id))
    #expect(restError(rest, context(doc, [rest, source]))?.contains("Rest after \"Finish\": that toolpath is after this one") == true)
    #expect(restError(rest, context(doc, [rest]))?.contains("was deleted") == true)
    source.setup.isEnabled = false
    #expect(restError(rest, context(doc, [source, rest]))?.contains("Rest after \"Finish\": that toolpath is off") == true)
}

@Test func unmatchedRestToolIsAnError() {
    // From an older file whose rest tool matched no earlier toolpath: never a whole-area pass with the small tool.
    let (doc, model) = grooveDoc()
    let rest = finish("Rest", model, tool: ballEighth, rest: .unresolved(toolID: ballQuarter.id))
    #expect(restError(rest, context(doc, [rest])) == "Rest after: choose the toolpath this rests after")
}

@Test func restSourceOnAnotherModelOrSideIsAnError() {
    var (doc, model) = grooveDoc()
    let other = PlacedModel(name: "Other", mesh: model.mesh, depth: 0.4, zTop: 0)
    doc.models.append(other)
    let elsewhere = finish("Finish", other, tool: ballQuarter)
    let rest = finish("Rest", model, tool: ballEighth, rest: .operation(elsewhere.setup.id))
    #expect(restError(rest, context(doc, [elsewhere, rest]))?.contains("cuts another model or side") == true)
    doc.models[0].reliefSplit = ReliefSplit(flip: .leftRight, splitDepth: 0.2, web: 0.04)
    let top = finish("Top", model, tool: ballQuarter, side: .top)
    let bottomRest = finish("Rest", model, tool: ballEighth, rest: .operation(top.setup.id), side: .bottom)
    #expect(restError(bottomRest, context(doc, [top, bottomRest]))?.contains("cuts another model or side") == true)
}

@Test func legacyRestToolIDNeverDecodesToNoRest() throws {
    let id = UUID()
    let json = #"{"isEnabled":true,"angle":0,"restToolID":"\#(id.uuidString)"}"#
    let f = try JSONDecoder().decode(FinishingSettings.self, from: Data(json.utf8))
    #expect(f.rest == .unresolved(toolID: id))
    let back = String(decoding: try JSONEncoder().encode(f), as: UTF8.self)
    #expect(!back.contains("restToolID"))
}

@Test func reliefRestSweepMatchesDropCutter() {
    var map = ReliefHeightmap(origin: .zero, cellSize: 0.01, columns: 40, rows: 30, baseDepth: 0.5)
    var rng = SplitMix64(seed: 3)
    for k in map.depths.indices { map.depths[k] = 0.2 + 0.3 * rng.next() }
    let cutter = CutterProfile(tool: ballQuarter)
    let swept = ReliefRest.sweep(map.depths, cols: map.columns, rows: map.rows,
                                 offsets: ReliefRest.offsets(cutter, cellSize: map.cellSize), deepest: false)
    let drop = DropCutter(map: map, cutter: cutter)
    for j in 0..<map.rows {
        for i in 0..<map.columns {
            #expect(abs(swept[j * map.columns + i] - drop.depth(at: map.position(i, j))) < 1e-12)
        }
    }
}
