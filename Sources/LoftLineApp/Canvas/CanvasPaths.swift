import AppKit
import CADCore
import CAMCore
import LoftLineKit

/// CGPath construction in DOCUMENT coordinates (Y up). Arcs and cubics are kept exact so the
/// canvas stays smooth at any zoom; callers apply the viewport transform when drawing.
enum CanvasPaths {
    static func cgPath(for path: Path) -> CGPath {
        let p = CGMutablePath()
        add(path, to: p)
        return p
    }

    static func cgPath(for shape: Shape) -> CGPath {
        let p = CGMutablePath()
        shape.paths.forEach { add($0, to: p) }
        return p
    }

    static func add(_ path: Path, to cg: CGMutablePath) {
        cg.move(to: path.start.cg)
        var current = path.start
        for seg in path.segments {
            switch seg {
            case .line(let to):
                cg.addLine(to: to.cg)
            case .cubic(let to, let c1, let c2):
                cg.addCurve(to: to.cg, control1: c1.cg, control2: c2.cg)
            case .arc(let to, let center, let clockwise):
                addArc(from: current, to: to, center: center, clockwise: clockwise, to: cg)
            }
            current = seg.end
        }
        if path.isClosed { cg.closeSubpath() }
    }

    static func addArc(from a: Vec2, to b: Vec2, center c: Vec2, clockwise: Bool, to cg: CGMutablePath) {
        let r = a.distance(to: c)
        guard r > 1e-12 else { cg.addLine(to: b.cg); return }
        let start = (a - c).angle
        var end = (b - c).angle
        if a.isApproximatelyEqual(to: b, tolerance: 1e-9) { end = start + (clockwise ? -2 * .pi : 2 * .pi) }
        cg.addArc(center: c.cg, radius: CGFloat(r), startAngle: CGFloat(start), endAngle: CGFloat(end),
                  clockwise: clockwise)
    }

    /// Toolpath geometry in the material frame: cutting moves and rapids as separate paths.
    static func toolpathPaths(_ tp: Toolpath, coords: MachineCoordinates) -> (cuts: CGPath, rapids: CGPath) {
        let cuts = CGMutablePath(), rapids = CGMutablePath()
        var last: Vec2?
        for m in tp.moves {
            guard let target = m.target else { continue }
            let to = coords.materialXY(fromMachine: target.xy)
            defer { last = to }
            guard let from = last else { continue }
            switch m {
            case .rapid:
                if !from.isApproximatelyEqual(to: to, tolerance: 1e-9) {
                    rapids.move(to: from.cg); rapids.addLine(to: to.cg)
                }
            case .linear:
                if cuts.isEmpty || cuts.currentPoint != from.cg { cuts.move(to: from.cg) }
                cuts.addLine(to: to.cg)
            case .arcCW(_, let center, _), .arcCCW(_, let center, _):
                if cuts.isEmpty || cuts.currentPoint != from.cg { cuts.move(to: from.cg) }
                let c = coords.materialXY(fromMachine: center)
                if case .arcCW = m {
                    addArc(from: from, to: to, center: c, clockwise: true, to: cuts)
                } else {
                    addArc(from: from, to: to, center: c, clockwise: false, to: cuts)
                }
            case .dwell:
                break
            }
        }
        return (cuts, rapids)
    }
}

extension Vec2 {
    var cg: CGPoint { CGPoint(x: x, y: y) }
    init(_ p: CGPoint) { self.init(Double(p.x), Double(p.y)) }
}

extension NSColor {
    /// "#RRGGBB" → colour (nil if malformed).
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255),
                      Int(c.blueComponent * 255))
    }
}
