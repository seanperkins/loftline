import Foundation
#if canImport(CoreText)
import CoreGraphics
import CoreText
#endif

/// One laid-out character: outlines with its baseline origin at x = `x`, y = 0.
public struct TextGlyph: Sendable {
    public var paths: [Path]
    public var x: Double
    public var advance: Double
}

extension TextOutliner {
    /// Per-character outlines of a single line (newlines become spaces), baseline at y = 0.
    public func glyphs(for text: String, fontName: String, size: Double, letterSpacing: Double = 0) throws -> [TextGlyph] {
        guard size > 0 else { return [] }
        if StrokeFont.isStrokeFont(fontName) { return StrokeFont.glyphs(for: text, size: size, letterSpacing: letterSpacing) }
#if canImport(CoreText)
        let font = try Self.font(named: fontName, capHeight: size)
        var attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        if letterSpacing != 0 { attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = letterSpacing }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text.replacingOccurrences(of: "\n", with: " "),
                                                                       attributes: attrs))
        var out: [TextGlyph] = []
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let n = CTRunGetGlyphCount(run)
            guard n > 0 else { continue }
            let runAttrs = CTRunGetAttributes(run) as NSDictionary
            let runFont = runAttrs[kCTFontAttributeName as String].map { $0 as! CTFont } ?? font
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var positions = [CGPoint](repeating: .zero, count: n)
            var advances = [CGSize](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &positions)
            CTRunGetAdvances(run, CFRange(location: 0, length: n), &advances)
            for k in 0..<n {
                var t = CGAffineTransform(translationX: positions[k].x, y: positions[k].y)
                let paths = CTFontCreatePathForGlyph(runFont, glyphs[k], &t).map { PathGeometry.normalizedOrientation(Self.paths(from: $0)) } ?? []
                out.append(TextGlyph(paths: paths, x: Double(positions[k].x), advance: Double(advances[k].width)))
            }
        }
        return out
#else
        let (font, em) = try Self.font(named: fontName, capHeight: size)
        let line = text.replacingOccurrences(of: "\n", with: " ")
        return font.layout(line).enumerated().map { k, g in
            let x = g.x * em + letterSpacing * Double(k)
            return TextGlyph(paths: PathGeometry.normalizedOrientation(font.paths(glyph: g.glyph, em: em, origin: Vec2(x, 0))),
                             x: x, advance: g.advance * em + letterSpacing)
        }
#endif
    }
}

/// Lays characters along a guide vector (text on a curve / arc text).
public enum TextOnPath {
    public enum Placement: String, Codable, CaseIterable, Sendable { case start, center, end }

    /// Each glyph is rotated to the curve's direction at its centre and lifted `offset` to the
    /// left of the curve (positive = above a left-to-right curve). `flip` runs the text along the
    /// reversed curve (e.g. along the bottom of a circle, reading left to right).
    public static func layout(_ glyphs: [TextGlyph], along path: Path, placement: Placement = .center,
                              startDistance: Double = 0, offset: Double = 0, flip: Bool = false,
                              tolerance: Double = Path.defaultTolerance) -> [Path] {
        guard let last = glyphs.last, !path.isEmpty else { return [] }
        let guide = Walker(flip ? path.reversed() : path, tolerance: tolerance)
        let width = last.x + last.advance - (glyphs.first?.x ?? 0)
        let base: Double
        switch placement {
        case .start: base = startDistance
        case .center: base = (guide.length - width) / 2 + startDistance
        case .end: base = guide.length - width - startDistance
        }
        var out: [Path] = []
        for g in glyphs where !g.paths.isEmpty {
            let mid = g.x + g.advance / 2
            let (p, tangent) = guide.pointAndTangent(at: base + mid)
            let normal = tangent.perpendicular
            let rot = atan2(tangent.y, tangent.x)
            let t = Transform2D.translation(Vec2(-mid, 0))
                .concatenating(.rotation(rot))
                .concatenating(.translation(p + normal * offset))
            out += g.paths.map { $0.transformed(t) }
        }
        return out
    }

    /// Arc-length walker over a flattened path (closed paths wrap; open ones extend straight).
    struct Walker {
        var pts: [Vec2]
        var cum: [Double]
        var closed: Bool
        var length: Double { cum.last ?? 0 }

        init(_ path: Path, tolerance: Double) {
            var p = path.flattened(tolerance: tolerance)
            if path.isClosed, let f = p.first { p.append(f) }
            pts = p
            cum = [0]
            for (a, b) in zip(p, p.dropFirst()) { cum.append(cum.last! + a.distance(to: b)) }
            closed = path.isClosed
        }

        func pointAndTangent(at s: Double) -> (Vec2, Vec2) {
            guard pts.count > 1, length > 0 else { return (pts.first ?? .zero, Vec2(1, 0)) }
            var d = s
            if closed { d = d.truncatingRemainder(dividingBy: length); if d < 0 { d += length } }
            if d <= 0 {
                let t = (pts[1] - pts[0]).normalized
                return (pts[0] + t * d, t)
            }
            if d >= length {
                let n = pts.count
                let t = (pts[n - 1] - pts[n - 2]).normalized
                return (pts[n - 1] + t * (d - length), t)
            }
            var lo = 0, hi = cum.count - 1
            while hi - lo > 1 { let m = (lo + hi) / 2; if cum[m] <= d { lo = m } else { hi = m } }
            let seg = cum[hi] - cum[lo]
            let u = seg > 0 ? (d - cum[lo]) / seg : 0
            return (pts[lo].lerp(to: pts[hi], u), (pts[hi] - pts[lo]).normalized)
        }
    }
}
