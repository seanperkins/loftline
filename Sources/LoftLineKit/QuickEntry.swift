import CADCore
import Foundation

/// Values typed on the canvas while a drawing tool is active ("quick keys"):
///   `3`        one value (circle radius, polygon/star radius, line length along the cursor)
///   `3,2`      two values (width,height for boxes; x,y for the first point, dx,dy after)
///   `5<30`     length and angle in degrees (next line point)
public enum QuickEntry: Equatable {
    case one(Double)
    case pair(Double, Double)
    case polar(length: Double, degrees: Double)

    /// Characters that start or extend an entry.
    public static func accepts(_ c: Character, buffer: String) -> Bool {
        if c.isNumber || c == "." || c == "-" { return true }
        return !buffer.isEmpty && (c == "," || c == "<" || c == " ")
    }

    public static func parse(_ text: String) -> QuickEntry? {
        let t = text.replacingOccurrences(of: " ", with: "")
        func num(_ s: Substring) -> Double? { Double(s) }
        if let i = t.firstIndex(of: "<") {
            guard let l = num(t[..<i]), let a = num(t[t.index(after: i)...]) else { return nil }
            return .polar(length: l, degrees: a)
        }
        let parts = t.split(separator: ",", omittingEmptySubsequences: false)
        switch parts.count {
        case 1: return num(parts[0]).map { .one($0) }
        case 2:
            guard let a = num(parts[0]), let b = num(parts[1]) else { return nil }
            return .pair(a, b)
        default: return nil
        }
    }

    /// Shape for a drag tool from typed values. Box tools: `W,H` (or one value for a square),
    /// anchored at its lower-left corner; `direction` flips it left/down when negative.
    /// Radial tools: one value = radius, centred on `anchor`.
    public func shape(for tool: CanvasTool, anchor: Vec2, direction: Vec2 = Vec2(1, 1), options: DrawingOptions,
               layerID: UUID) -> Shape? {
        var o = options
        o.constrain = false
        if tool.isDragShape, [.circle, .polygon, .star].contains(tool) {
            let r: Double
            switch self {
            case .one(let v): r = v
            case .pair(let v, _): r = v
            case .polar(let l, _): r = l
            }
            guard r > 0 else { return nil }
            var dir = Vec2(0, 1)
            if case .polar(_, let deg) = self { dir = Vec2(cos(deg * .pi / 180), sin(deg * .pi / 180)) }
            return DrawingTools.shape(for: tool, from: anchor, to: anchor + dir * r, options: o, layerID: layerID)
        }
        guard tool.isDragShape else { return nil }
        let (w, h): (Double, Double)
        switch self {
        case .one(let v): (w, h) = (v, v)
        case .pair(let a, let b): (w, h) = (a, b)
        case .polar: return nil
        }
        guard w != 0, h != 0 else { return nil }
        let sx: Double = direction.x < 0 ? -1 : 1, sy: Double = direction.y < 0 ? -1 : 1
        return DrawingTools.shape(for: tool, from: anchor, to: anchor + Vec2(w * sx, h * sy), options: o, layerID: layerID)
    }

    /// Next polyline point. With no previous point, a pair is an absolute position. After one,
    /// a pair is an offset, a polar entry is length<angle, and one value is a length towards
    /// `cursor`.
    public func nextPoint(after last: Vec2?, cursor: Vec2?) -> Vec2? {
        switch self {
        case .pair(let a, let b): return (last ?? .zero) + Vec2(a, b)
        case .polar(let l, let deg):
            guard let last else { return nil }
            return last + Vec2(cos(deg * .pi / 180), sin(deg * .pi / 180)) * l
        case .one(let l):
            guard let last, let c = cursor, c.distance(to: last) > 1e-12 else { return nil }
            return last + (c - last).normalized * l
        }
    }
}
