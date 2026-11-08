import CADCore
import Foundation

/// One edit of the inspector's Position & Size fields: the box the selection should end up in.
/// Pure, so it can be tested without a view.
public enum BoxEdit {
    case x(Double), y(Double), width(Double), height(Double)

    /// The box after the edit. The lower-left corner stays put when the size changes, and with
    /// `keepAspect` the other side follows the old proportions. A size never drops below 1e-6.
    public func apply(to box: Rect2, keepAspect: Bool) -> Rect2 {
        var w = box.width, h = box.height
        switch self {
        case .x(let v): return Rect2(x: v, y: box.min.y, width: w, height: h)
        case .y(let v): return Rect2(x: box.min.x, y: v, width: w, height: h)
        case .width(let v):
            w = v
            if keepAspect, box.width > 0, box.height > 0 { h = box.height * v / box.width }
        case .height(let v):
            h = v
            if keepAspect, box.width > 0, box.height > 0 { w = box.width * v / box.height }
        }
        return Rect2(x: box.min.x, y: box.min.y, width: max(w, 1e-6), height: max(h, 1e-6))
    }

    /// False when the typed value is only the 4-decimal value the field displays for `box`, so
    /// focusing a field and leaving it does not nudge the selection by a rounding error.
    public func changes(_ box: Rect2, tolerance: Double = 5e-5) -> Bool {
        switch self {
        case .x(let v): return abs(v - box.min.x) >= tolerance
        case .y(let v): return abs(v - box.min.y) >= tolerance
        case .width(let v): return abs(v - box.width) >= tolerance
        case .height(let v): return abs(v - box.height) >= tolerance
        }
    }
}
