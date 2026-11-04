import CADCore
import Foundation
import Testing
@testable import CAMCore

/// V-carve against real letters. A glyph is carved correctly when
///  - the operation produces a cut, and every piece of the letter (the dot of an i, the two halves of a %)
///    has some of it in it,
///  - the cut reaches the whole glyph: at every point inside it the V-bit has taken out the depth the outline
///    allows there (the distance to the nearest edge, up to the bit's own radius) to within a small fraction
///    of the letter's height, and every point of the outline lies within reach of a groove, so no stroke,
///    counter or serif is left uncarved, and
///  - the runs of the cut that touch (one groove reaches the other's axis) form as many connected cuts as the
///    glyph has connected pieces: an O is one ring, not two unrelated circles.
/// The expected letter is worked out from the font's own outlines, not from the region the operation builds.
/// Run for A-Z, a-z, 0-9 and & @ % in five fonts at three sizes.

private let glyphGroups: [[Character]] = ["ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz", "0123456789&@%"].map(Array.init)
#if canImport(CoreText)
private let fonts = ["Times New Roman", "Helvetica", "Snell Roundhand", "Avenir Next Condensed", "Impact"]   // serif, sans, script, condensed, display
private let twoFonts = ["Times New Roman", "Helvetica"]
#else
private let fonts = ["Liberation Serif", "Liberation Sans", "Liberation Mono"]
private let twoFonts = ["Liberation Serif", "Liberation Sans"]
#endif
private let sizes = [0.25, 1.0, 2.0]                        // capital height, inches
private let slope = tan(30.0 * .pi / 180)                   // the 60 degree V-bit of VCarveFixture

/// One groove point: where the bit's axis passes and how wide the groove is there (depth x slope).
private struct Groove { var xy: Vec2; var radius: Double; var run: Int; var sideways: Bool; var vertex: Bool }

/// Cut points (xy, groove radius) of `tp` at or below the surface, densified to `step`; `run` numbers the
/// runs of cutting moves between rapids.
private func grooves(_ tp: Toolpath, coords: MachineCoordinates, step: Double) -> [Groove] {
    var out: [Groove] = []
    var run = 0
    var last: Vec3?
    var open = false
    for m in tp.moves {
        guard let t = m.target else { continue }
        defer { last = t }
        if m.isRapid { if open { run += 1; open = false }; continue }
        guard let a = last else { continue }
        let n = max(1, Int((a.xy.distance(to: t.xy) / step).rounded(.up)))
        let sideways = a.xy.distance(to: t.xy) > 1e-9   // a plunge or a lift moves straight down or up
        for k in 0...n {
            let mat = coords.material(fromMachine: a + (t - a) * (Double(k) / Double(n)))
            if mat.depth > -1e-9 { out.append(Groove(xy: mat.xy, radius: max(0, mat.depth) * slope, run: run, sideways: sideways, vertex: k == 0 || k == n)) }
        }
        open = true
    }
    return out
}

/// Grooves bucketed on a grid: a covered point finds its groove in the first few buckets. A plain scan of
/// every groove for every sample costs minutes in a debug build over the whole matrix.
private struct GrooveGrid {
    let cell: Double
    var buckets: [Int64: [Int]] = [:]

    init(_ points: [Groove], cell: Double) {
        self.cell = cell
        for (i, g) in points.enumerated() { buckets[Self.key(Int(floor(g.xy.x / cell)), Int(floor(g.xy.y / cell))), default: []].append(i) }
    }

    static func key(_ ix: Int, _ iy: Int) -> Int64 { Int64(ix) &* 1_000_003 &+ Int64(iy) }

    /// Visits the points whose cell lies within `r` of `p`, nearest cells first, until `visit` returns false.
    func forEachNear(_ p: Vec2, within r: Double, _ visit: (Int) -> Bool) {
        let span = Int(ceil(r / cell))
        let cx = Int(floor(p.x / cell)), cy = Int(floor(p.y / cell))
        for ring in 0...span {
            for ix in (cx - ring)...(cx + ring) {
                for iy in (cy - ring)...(cy + ring) where max(abs(ix - cx), abs(iy - cy)) == ring {
                    for i in buckets[Self.key(ix, iy)] ?? [] {
                        if !visit(i) { return }
                    }
                }
            }
        }
    }
}

/// The segments of the letter's outline bucketed on a grid, for distance queries that look at a few cells
/// instead of every segment.
private struct OutlineGrid {
    let cell: Double
    var buckets: [Int64: [(Vec2, Vec2)]] = [:]
    let extent: Int
    /// The last cell column that holds any of the outline: a ray to the right of a point ends there.
    let lastColumn: Int

    init(loops: [[Vec2]], cell: Double) {
        self.cell = cell
        for loop in loops {
            for i in loop.indices {
                let a = loop[i], b = loop[(i + 1) % loop.count]
                let x0 = Int(floor(min(a.x, b.x) / cell)), x1 = Int(floor(max(a.x, b.x) / cell))
                let y0 = Int(floor(min(a.y, b.y) / cell)), y1 = Int(floor(max(a.y, b.y) / cell))
                for ix in x0...x1 { for iy in y0...y1 { buckets[GrooveGrid.key(ix, iy), default: []].append((a, b)) } }
            }
        }
        let all = loops.flatMap { $0 }
        let box = Rect2(points: all)
        extent = Int(ceil(max(box.width, box.height) / cell)) + 2
        lastColumn = Int(floor(box.max.x / cell))
    }

    /// Even-odd containment: the outline segments a ray to the right of `p` crosses, counted cell by cell.
    func contains(_ p: Vec2) -> Bool {
        let cx = Int(floor(p.x / cell)), cy = Int(floor(p.y / cell))
        var crossings = 0
        for ix in cx...max(cx, lastColumn) {
            for (a, b) in buckets[GrooveGrid.key(ix, cy)] ?? [] where (a.y > p.y) != (b.y > p.y) {
                // Kept within the segment's own columns so rounding cannot put it in a cell the segment is not in.
                let x = min(max(a.x + (p.y - a.y) * (b.x - a.x) / (b.y - a.y), min(a.x, b.x)), max(a.x, b.x))
                // Counted in the cell that holds the crossing, once, although a long segment is in several cells.
                if x > p.x, Int(floor(x / cell)) == ix { crossings += 1 }
            }
        }
        return crossings % 2 == 1
    }

    func distance(from p: Vec2) -> Double {
        var best = Double.infinity
        let cx = Int(floor(p.x / cell)), cy = Int(floor(p.y / cell))
        for ring in 0...(extent + Int(ceil(max(abs(p.x), abs(p.y)) / cell))) {
            for ix in (cx - ring)...(cx + ring) {
                for iy in (cy - ring)...(cy + ring) where max(abs(ix - cx), abs(iy - cy)) == ring {
                    for (a, b) in buckets[GrooveGrid.key(ix, iy)] ?? [] {
                        best = min(best, Polygon2D.closestPoint(onSegment: a, b, to: p).point.distance(to: p))
                    }
                }
            }
            if best <= Double(ring) * cell { break }
        }
        return best
    }
}

private struct Verdict {
    var cutLength = 0.0
    /// The most any interior point is short of the depth the outline allows there, in inches of groove radius.
    var worstShortfall = 0.0
    var shortfallAt = Vec2.zero
    /// The farthest any point of the outline is from every groove's edge.
    var worstOutlineGap = 0.0
    /// The most any groove is wider than the outline allows where it is (a groove outside the letter counts as all of it).
    var worstOvercut = 0.0
    /// The most any groove along the cut is narrower than the outline allows where it is, beyond the margin.
    var worstUndercut = 0.0
    var cuts = 0
    var pieces = 0
    /// Pieces of the glyph with no cut in them.
    var uncutPieces = 0
}

/// How well `tp` carves the glyph `paths`.
private func judge(_ tp: Toolpath, paths: [Path], context: CAMContext, size: Double) -> Verdict {
    var v = Verdict()
    // The letter from the font's contours alone (outer loops counter-clockwise, counters and islands
    // alternating inside them), not from the region the operation builds from them.
    // No union is applied: a point is inside when an odd number of contours enclose it (even-odd, which is the
    // font's own nonzero fill here because no contours of these fonts overlap), and its distance to the
    // letter's edge is its distance to the nearest contour.
    let region = paths.map { $0.flattened(tolerance: context.tolerance) }.filter { $0.count > 2 }
    // Pieces of the letter: the contours an even number of the others enclose.
    let outers = region.filter { loop in region.filter { $0 != loop && Polygon2D.contains($0, loop[0]) }.count % 2 == 0 }
    v.pieces = outers.count
    let outline = OutlineGrid(loops: region, cell: size * 0.05)
    func inside(_ p: Vec2) -> Bool { outline.contains(p) }
    func outlineDistance(_ p: Vec2) -> Double { outline.distance(from: p) }

    let g = grooves(tp, coords: context.coords, step: size * 0.01)
    for (a, b) in zip(g, g.dropFirst()) where a.run == b.run { v.cutLength += a.xy.distance(to: b.xy) }
    // Each piece must hold some cut.
    v.uncutPieces = outers.filter { outer in !g.contains { $0.radius > 0 && Polygon2D.contains(outer, $0.xy) } }.count

    let grid = GrooveGrid(g, cell: size * 0.05)
    let bitRadius = VCarveFixture.vbit60.radius
    let allowed = size * 0.02

    // Overcut and undercut along the cut. Every sample (moves are densified to 1% of the height), a plunge or
    // lift included, has its axis inside the letter. Every end of a move and every sixth sample between is also
    // no wider than the outline allows there (or than the bit can cut), within 10% of that and a small absolute
    // margin (half a percent of the height and three chord tolerances: the operation simplifies strokes by one
    // tolerance); a defect on one sample shows on its neighbours. Where the bit moves sideways it is also no
    // narrower (a plunge or a lift grows from nothing to the axis).
    for (i, groove) in g.enumerated() {
        let within = inside(groove.xy)
        guard !within || groove.vertex || i % 6 == 0 else { continue }
        let room = within ? min(outlineDistance(groove.xy), bitRadius) : 0
        let margin = size * 0.005 + 3 * context.tolerance + 0.1 * room
        v.worstOvercut = max(v.worstOvercut, groove.radius - room - margin)
        if groove.sideways { v.worstUndercut = max(v.worstUndercut, room - groove.radius - margin) }
    }

    // Interior: at q the outline allows a groove of radius min(d, bit radius) (a stroke wider than the bit is
    // cleared flat at the bit's full depth); the groove at s leaves r_s - |q - s| of its radius at q.
    let bounds = Rect2(points: region.flatMap { $0 })
    let h = size / 18
    var y = bounds.min.y + h / 2
    while y < bounds.max.y {
        var x = bounds.min.x + h / 2
        while x < bounds.max.x {
            let q = Vec2(x, y)
            if inside(q) {
                // The thin rim is skipped (the groove narrows to nothing at the edge); the outline check
                // below covers it.
                let d = outlineDistance(q)
                if d > size * 0.02 {
                    let want = min(d, bitRadius)
                    var best = 0.0
                    grid.forEachNear(q, within: want + size * 0.3) { i in
                        best = max(best, g[i].radius - g[i].xy.distance(to: q))
                        return best < want - allowed   // enough: stop looking
                    }
                    if want - best > v.worstShortfall { v.worstShortfall = want - best; v.shortfallAt = q }
                }
            }
            x += h
        }
        y += h
    }

    // Outline: every point of every contour is within reach of some groove (its edge touches or passes it),
    // which also sees a thin stroke or serif the interior grid steps over.
    let step = size / 45
    let outlineReach = size * 0.01 + 2 * context.tolerance
    for loop in region {
        var carried = 0.0
        for i in loop.indices {
            let a = loop[i], b = loop[(i + 1) % loop.count]
            let len = a.distance(to: b)
            var t = carried
            while t < len {
                let p = a.lerp(to: b, t / len)
                var gap = Double.infinity
                grid.forEachNear(p, within: size * 0.3) { j in
                    gap = min(gap, g[j].xy.distance(to: p) - g[j].radius)
                    return gap > outlineReach   // reached: stop looking
                }
                v.worstOutlineGap = max(v.worstOutlineGap, gap)
                t += step
            }
            carried = t - len
        }
    }

    // Connected cuts: the runs of cutting moves, joined where one run's groove reaches the axis of another's
    // and the floor between the two axes is carved (a run starts at a junction of the skeleton, and at a
    // reflex corner of a letter the next groove just touches the first). A gap in the skeleton that leaves
    // a ridge between its ends is not a join, and neither are two unrelated strokes close together.
    var byRun: [[Groove]] = []
    for groove in g {
        if let last = byRun.last?.first, last.run == groove.run { byRun[byRun.count - 1].append(groove) } else { byRun.append([groove]) }
    }
    var parent = Array(byRun.indices)
    func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
    // Runs of one skeleton share the vertices where they meet, so first join the runs that start or end on a
    // point another run passes through.
    var holders: [Int64: Int] = [:]
    func key(_ p: Vec2) -> Int64 { Int64((p.x * 1e6).rounded()) &* 1_000_003 &+ Int64((p.y * 1e6).rounded()) }
    for (r, run) in byRun.enumerated() { for pt in run { holders[key(pt.xy)] = r } }
    for (r, run) in byRun.enumerated() {
        for pt in [run[0], run[run.count - 1]] { if let other = holders[key(pt.xy)], other != r { parent[find(r)] = find(other) } }
    }
    let slack = size * 0.004
    let boxes = byRun.map { run in Rect2(points: run.map(\.xy)).insetBy(-((run.map(\.radius).max() ?? 0) + slack)) }
    // Only when that leaves more cuts than the letter has pieces, look for grooves that reach each other.
    let joinedByVertices = Set(byRun.indices.map(find)).count
    for a in byRun.indices where joinedByVertices > v.pieces {
        for b in byRun.indices where b > a && find(a) != find(b) && boxes[a].intersects(boxes[b]) {
            search: for p in byRun[a] {
                for q in byRun[b] where p.xy.distance(to: q.xy) <= max(p.radius, q.radius) + slack {
                    let m = p.xy.lerp(to: q.xy, 0.5)
                    let carved = max(p.radius - m.distance(to: p.xy), q.radius - m.distance(to: q.xy))
                    if inside(m), carved >= min(outlineDistance(m), bitRadius) - allowed {
                        parent[find(a)] = find(b)
                        break search
                    }
                }
            }
        }
    }
    v.cuts = Set(byRun.indices.map(find)).count
    return v
}

/// Glyph outlines, asked of CoreText one at a time: the font daemon answers each request over XPC and
/// stops answering when a dozen test threads ask at once. nil when the font is not installed.
private let fontLock = NSLock()
private func glyphOutlines(_ text: String, font: String, size: Double) -> [Path]? {
    fontLock.withLock { try? TextOutliner().outlines(for: text, fontName: font, size: size, origin: Vec2(1, 1)) }
}

/// The glyph carved with the 60 degree V-bit, with its outlines and context.
private func carve(_ paths: [Path], shapesApart: [Int]? = nil, params: VCarveParameters = VCarveParameters()) throws
    -> (tp: Toolpath, context: CAMContext) {
    var doc = Document()
    var ids: [UUID] = []
    if let order = shapesApart {
        // Each contour a shape of its own, selected in this order.
        for i in order {
            let shape = Shape(layerID: doc.defaultLayerID, paths: [paths[i]])
            doc.add(shape); ids.append(shape.id)
        }
    } else {
        let shape = Shape(layerID: doc.defaultLayerID, paths: paths)
        doc.add(shape); ids.append(shape.id)
    }
    let context = CAMContext(document: doc, tools: .seeded)
    let setup = OperationSetup(name: "V", toolID: VCarveFixture.vbit60.id, shapeIDs: ids)
    return (try #require(try VCarveOperation(setup: setup, params: params).generate(in: context).first), context)
}

/// A size and a group of glyphs: the unit a test runs, so the work spreads over the cores.
struct VCarveGlyphCell: Sendable, CustomTestStringConvertible {
    var size: Double
    var group: Int
    var testDescription: String { "\(size) in, glyphs \(String(glyphGroups[group]))" }
}

let vcarveGlyphCells = sizes.flatMap { size in glyphGroups.indices.map { VCarveGlyphCell(size: size, group: $0) } }

/// The fonts ship with macOS; a machine that lacks them would otherwise pass by carving nothing.
@Test func vcarveGlyphFontsAreInstalled() {
    let present = fonts.filter { glyphOutlines("A", font: $0, size: 1) != nil }
    #expect(present.count >= min(4, fonts.count) && present.contains(testFont), Comment(rawValue: "only \(present) of \(fonts) are installed"))
}

@Test(arguments: fonts, vcarveGlyphCells)
func vcarveCarvesEveryGlyph(font: String, cell: VCarveGlyphCell) throws {
    guard glyphOutlines("A", font: font, size: 1) != nil else { return }   // not installed: vcarveGlyphFontsAreInstalled decides
    for ch in glyphGroups[cell.group] {
        let name = "\(font) '\(ch)' at \(cell.size) in"
        guard let paths = glyphOutlines(String(ch), font: font, size: cell.size), !paths.isEmpty else {
            Issue.record(Comment(rawValue: "\(name): no outline")); continue
        }
        let tp: Toolpath, context: CAMContext
        do { (tp, context) = try carve(paths) } catch {
            Issue.record(Comment(rawValue: "\(name): the operation failed: \(error)")); continue
        }
        let v = judge(tp, paths: paths, context: context, size: cell.size)
        #expect(v.cutLength > 0, Comment(rawValue: "\(name): no cut"))
        #expect(v.worstOvercut <= 0, Comment(rawValue: "\(name): a groove is \(v.worstOvercut) in wider than the outline allows"))
        #expect(v.worstUndercut <= 0, Comment(rawValue: "\(name): a groove is \(v.worstUndercut) in narrower than the outline allows"))
        #expect(v.uncutPieces == 0, Comment(rawValue: "\(name): \(v.uncutPieces) of \(v.pieces) glyph piece(s) have no cut in them"))
        #expect(v.worstShortfall <= cell.size * 0.02,
                Comment(rawValue: "\(name): carve is \(v.worstShortfall) in short near \(v.shortfallAt)"))
        #expect(v.worstOutlineGap <= cell.size * 0.01 + 2 * context.tolerance, Comment(rawValue: "\(name): an outline point is \(v.worstOutlineGap) in from every groove"))
        #expect(v.cuts == v.pieces, Comment(rawValue: "\(name): \(v.cuts) connected cut(s) for \(v.pieces) glyph piece(s)"))
    }
}

/// The judge sees a groove that is too deep at the end of a plunge, not only along sideways moves: a good carve
/// with one extra feed plunge at its last point (no sideways move, so neither coverage nor connection changes)
/// is overcut.
@Test func vcarveGlyphJudgeCatchesAnExtraDeepPlunge() throws {
    let paths = try #require(glyphOutlines("O", font: testFont, size: 1))
    let (tp, context) = try carve(paths)
    #expect(judge(tp, paths: paths, context: context, size: 1).worstOvercut <= 0)
    var bad = tp
    let at = try #require(bad.moves.lastIndex { !$0.isRapid && $0.target != nil })
    let end = try #require(bad.moves[at].target)
    let spot = context.coords.material(fromMachine: end)
    let deeper = context.coords.machine(spot.xy, depth: spot.depth + 0.1)
    bad.moves.insert(contentsOf: [.linear(to: deeper, feed: 30), .linear(to: end, feed: 30)], at: at + 1)
    #expect(judge(bad, paths: paths, context: context, size: 1).worstOvercut > 0.03)
}

private func permutations<T>(_ items: [T]) -> [[T]] {
    guard items.count > 1 else { return [items] }
    return items.indices.flatMap { i -> [[T]] in
        var rest = items
        let head = rest.remove(at: i)
        return permutations(rest).map { [head] + $0 }
    }
}

/// O, B and 8 have an outline and one or two counters. Each contour as a shape of its own, selected in every
/// order, with and without "start at the vectors' start points" and "in selection order": the carve is
/// the same whole letter, one connected cut, every time. (The operation carves one region built from all
/// the selected shapes, so the order cannot change what is cut; this guards against a region built per
/// shape, which would carve the counters as filled discs, and against strokes lost in the ordering. That the
/// order is followed is checked by `vcarveSelectionOrderFollowsTheSelectedLetters`.)
@Test(arguments: twoFonts, ["O", "B", "8"])
func vcarveKeepsAMultiContourGlyphWholeInEveryOrder(font: String, glyph: String) throws {
    guard let paths = glyphOutlines(glyph, font: font, size: 1) else { return }
    #expect(paths.count >= 2, Comment(rawValue: "\(font) \(glyph) should have a counter"))
    for order in permutations(Array(paths.indices)) {
        for startPoints in [false, true] {
            for selectionOrder in [false, true] {
                let params = VCarveParameters(useVectorStartPoints: startPoints, useSelectionOrder: selectionOrder)
                let (tp, context) = try carve(paths, shapesApart: order, params: params)
                let v = judge(tp, paths: paths, context: context, size: 1)
                let name = "\(font) '\(glyph)' contours \(order) startPoints=\(startPoints) selectionOrder=\(selectionOrder)"
                #expect(v.cutLength > 0, Comment(rawValue: "\(name): no cut"))
                #expect(v.worstOvercut <= 0, Comment(rawValue: "\(name): a groove is \(v.worstOvercut) in wider than the outline allows"))
                #expect(v.worstUndercut <= 0, Comment(rawValue: "\(name): a groove is \(v.worstUndercut) in narrower than the outline allows"))
                #expect(v.worstShortfall <= 0.02, Comment(rawValue: "\(name): carve is \(v.worstShortfall) in short near \(v.shortfallAt)"))
                #expect(v.worstOutlineGap <= 0.01 + 2 * context.tolerance, Comment(rawValue: "\(name): an outline point is \(v.worstOutlineGap) in from every groove"))
                #expect(v.cuts == 1 && v.pieces == 1, Comment(rawValue: "\(name): \(v.cuts) connected cut(s) for \(v.pieces) glyph piece(s)"))
            }
        }
    }
}

/// With "selection order" on, the letters are carved in the order they were selected: all of one, then all of the
/// other, whichever was selected first.
@Test(arguments: [[0, 1], [1, 0]])
func vcarveSelectionOrderFollowsTheSelectedLetters(order: [Int]) throws {
    guard let o = glyphOutlines("O", font: testFont, size: 1), let b = glyphOutlines("B", font: testFont, size: 1) else { return }
    let letters = [o, b.map { $0.transformed(.translation(Vec2(2.5, 0))) }]
    var doc = Document()
    var ids: [UUID] = []
    for i in order {
        let shape = Shape(layerID: doc.defaultLayerID, paths: letters[i])
        doc.add(shape); ids.append(shape.id)
    }
    let context = CAMContext(document: doc, tools: .seeded)
    let setup = OperationSetup(name: "V", toolID: VCarveFixture.vbit60.id, shapeIDs: ids)
    let params = VCarveParameters(useSelectionOrder: true)
    let tp = try #require(try VCarveOperation(setup: setup, params: params).generate(in: context).first)
    let g = grooves(tp, coords: context.coords, step: 0.05)
    // The letter each run of cuts is in (the O is left of x = 2.2, the B right of it), in cutting order.
    var seen: [Int] = []
    var lastRun = -1
    for groove in g where groove.run != lastRun {
        lastRun = groove.run
        let letter = groove.xy.x < 2.2 ? 0 : 1
        if seen.last != letter { seen.append(letter) }
    }
    #expect(seen == order, Comment(rawValue: "selected \(order) (0 = O, 1 = B) but cut \(seen)"))
}

/// A stroke along a curved open vector, simplified to a few vertices, still belongs to its vector: the check
/// uses the stroke's own vertices, which lie on the vector, not the middle of a segment, which does not.
@Test func vcarveSelectionOrderKeepsASimplifiedStrokeOnItsCurvedOpenVector() {
    let layer = UUID()
    let curve = (0...200).map { i in Vec2(5 * cos(0.002 * Double(i)), 5 * sin(0.002 * Double(i))) }
    let shapes = [Shape(layerID: layer, paths: [Path(points: curve, closed: false)]),
                  Shape(layerID: layer, paths: [Path(points: [Vec2(1, 3), Vec2(2, 3)], closed: false)])]
    let ordering = VCarveOrdering(shapes: shapes, useStartPoints: false, useSelectionOrder: true, tolerance: 0.0005, units: .inch)
    let simplified = [0, 51, 102, 153, 200].map { VCarveStroke(points: [Vec3(curve[$0], z: 0.05)], isClosed: false).points[0] }
    let stroke = VCarveStroke(points: simplified, isClosed: false)
    #expect(ordering.group(of: stroke) == 0)
    // A two-point spur inside a closed shape is grouped too (its end lies on the outline).
    let square = Shape(layerID: layer, paths: [Path(points: [Vec2(0, 0), Vec2(1, 0), Vec2(1, 1), Vec2(0, 1)], closed: true)])
    let inside = VCarveOrdering(shapes: [shapes[1], square], useStartPoints: false, useSelectionOrder: true, tolerance: 0.0005, units: .inch)
    let spur = VCarveStroke(points: [Vec3(Vec2(0, 0), z: 0), Vec3(Vec2(0.1, 0.1), z: 0.05)], isClosed: false)
    #expect(inside.group(of: spur) == 1)
}

/// A stroke simplified for the toolpath stays within the tolerance of every point it replaces, however gently
/// it curves. (The old simplifier compared each point with the segment from the last kept point to the next raw
/// point, so a long shallow arc drifted by many tolerances: a hairline of Snell Roundhand's L was cut 0.013 in
/// off its axis.)
@Test func vcarveSimplifiedStrokesStayWithinToleranceOfTheOriginal() {
    // A shallow arc: 200 points over 1.4 in, sagitta 0.03 in.
    let radius = 8.0
    let arc = (0...200).map { i -> Vec3 in
        let a = Double(i) * 0.007 / radius
        return Vec3(x: radius * sin(a), y: radius * (1 - cos(a)), z: 0.02 + 0.00002 * Double(i))
    }
    for tolerance in [0.0005, 0.002] {
        let kept = VCarveStrokes.simplified(arc, tolerance: tolerance)
        #expect(kept.count > 2 && kept.count < arc.count)
        // Every original point lies within the tolerance of the simplified polyline.
        for p in arc {
            var best = Double.infinity
            for (a, b) in zip(kept, kept.dropFirst()) {
                let ab = b - a, ap = p - a
                let t = max(0, min(1, ap.dot(ab) / max(ab.dot(ab), 1e-300)))
                best = min(best, p.distance(to: a + ab * t))
            }
            #expect(best <= tolerance + 1e-12, Comment(rawValue: "tolerance \(tolerance): a point is \(best) from the simplified stroke"))
        }
    }
}
