import CADCore
import CoreGraphics
import LoftLineKit

/// How much the canvas draws, by how much there is to draw.
///
/// CoreGraphics strokes a line exactly one point wide on a fast path, and anything else (1.25 points, a dash, a round
/// cap) through its full stroker, which costs about 30 microseconds a curve segment: a traced drawing of 500,000 segments
/// took 15 seconds to draw once, and the canvas draws again on every mouse move and every selection. So a drawing with
/// more than `hairlineSegmentCount` segments is stroked at exactly one point, as hairlines in one color each (a selected
/// shape in the selection color, with no dashed copy over it), and shapes that cannot show in the view are skipped.
enum CanvasDetail {
    /// Segments above which shapes are drawn as hairlines: about what the full stroker draws in a tenth of a second.
    static let hairlineSegmentCount = 5_000

    static func usesHairlines(segmentCount: Int) -> Bool { segmentCount > hairlineSegmentCount }

    /// How many times the canvas has drawn its shapes as hairlines (main thread only): what the tests read to see which way a
    /// drawing was drawn, since how long it took depends on what else the machine is doing.
    static var hairlineDraws = 0

    /// Lines, arcs and curves in `shape`.
    static func segmentCount(of shape: Shape) -> Int { shape.paths.reduce(0) { $0 + $1.segments.count } }

    static func segmentCount(of shapes: [Shape]) -> Int { shapes.reduce(0) { $0 + segmentCount(of: $1) } }

    /// Whether something with this bounding box in the view can leave a mark inside `view` (a stroke reaches half a
    /// point past its path, a little more with a join).
    static func isVisible(_ box: CGRect, in view: CGRect) -> Bool {
        box.insetBy(dx: -2, dy: -2).intersects(view)
    }
}
