import Foundation
#if canImport(CoreText)
import CoreGraphics
import CoreText
#endif

/// Horizontal alignment of text relative to the origin X.
public enum TextAlignment: String, Codable, CaseIterable, Sendable {
    case left, center, right
}

/// Converts text to vector outlines using CoreText (any installed font).
///
/// `size` is the CAP HEIGHT in document units (the height of a capital "H"), which is what a
/// CNC user measures on the finished piece; the font's point size is derived from it.
/// Multi-line text (separated by "\n") stacks downward from the first baseline at `origin`.
/// Outer contours are counter-clockwise, holes clockwise.
public struct TextOutliner: Sendable {
    public init() {}

    public enum TextError: Error, Equatable, Sendable {
        case fontNotFound(String)
    }

    /// Outline paths for `text` with the first baseline's left end at `origin`.
    public func outlines(for text: String, fontName: String, size: Double, origin: Vec2) throws -> [Path] {
        try outlines(for: text, fontName: fontName, size: size, origin: origin, alignment: .left)
    }

#if canImport(CoreText)
    /// Outline paths for `text`; `alignment` positions each line relative to `origin.x`.
    /// `lineSpacing` multiplies the font's natural line height.
    public func outlines(for text: String, fontName: String, size: Double, origin: Vec2,
                         alignment: TextAlignment, lineSpacing: Double = 1, letterSpacing: Double = 0) throws -> [Path] {
        guard size > 0 else { return [] }
        let font = try Self.font(named: fontName, capHeight: size)
        let lineHeight = (CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)) * lineSpacing
        var out: [Path] = []
        for (i, line) in text.components(separatedBy: "\n").enumerated() where !line.isEmpty {
            var attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
            if letterSpacing != 0 { attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = letterSpacing }
            let attr = NSAttributedString(string: line, attributes: attrs)
            let ctLine = CTLineCreateWithAttributedString(attr)
            // Kerning follows every character, the last included: not part of the visible width.
            let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil) - letterSpacing
            let factor: Double = alignment == .left ? 0 : alignment == .center ? 0.5 : 1
            let lineOrigin = Vec2(origin.x - width * factor, origin.y - Double(i) * lineHeight)
            out += glyphOutlines(ctLine, at: lineOrigin, fallback: font)
        }
        return out
    }

    /// Outlines for one line of text set at a font POINT size (em size, e.g. SVG `font-size`),
    /// with the baseline's anchor at `origin`. Throws `fontNotFound` for unknown fonts.
    public func outlines(for text: String, fontName: String, pointSize: Double, origin: Vec2,
                         alignment: TextAlignment) throws -> [Path] {
        guard pointSize > 0, !text.isEmpty else { return [] }
        let probe = try Self.font(named: fontName, capHeight: 70)
        let font = CTFontCreateCopyWithAttributes(probe, pointSize, nil, nil)
        let attr = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let ctLine = CTLineCreateWithAttributedString(attr)
        let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
        let factor: Double = alignment == .left ? 0 : alignment == .center ? 0.5 : 1
        return glyphOutlines(ctLine, at: Vec2(origin.x - width * factor, origin.y), fallback: font)
    }

    /// Advance width of one line at a font point size.
    public func advance(of text: String, fontName: String, pointSize: Double) throws -> Double {
        guard pointSize > 0, !text.isEmpty else { return 0 }
        let font = CTFontCreateCopyWithAttributes(try Self.font(named: fontName, capHeight: 70), pointSize, nil, nil)
        let attr = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attr), nil, nil, nil)
    }
#else
    /// Outline paths for `text`; `alignment` positions each line relative to `origin.x`.
    /// `lineSpacing` multiplies the font's natural line height.
    public func outlines(for text: String, fontName: String, size: Double, origin: Vec2,
                         alignment: TextAlignment, lineSpacing: Double = 1, letterSpacing: Double = 0) throws -> [Path] {
        guard size > 0 else { return [] }
        let (font, em) = try Self.font(named: fontName, capHeight: size)
        let lineHeight = font.lineHeight * em * lineSpacing
        var out: [Path] = []
        for (i, line) in text.components(separatedBy: "\n").enumerated() where !line.isEmpty {
            let placed = font.layout(line)
            let width = (placed.last.map { $0.x + $0.advance } ?? 0) * em + letterSpacing * Double(max(0, placed.count - 1))
            let factor: Double = alignment == .left ? 0 : alignment == .center ? 0.5 : 1
            let o = Vec2(origin.x - width * factor, origin.y - Double(i) * lineHeight)
            for (k, g) in placed.enumerated() {
                let at = Vec2(o.x + g.x * em + letterSpacing * Double(k), o.y)
                out += PathGeometry.normalizedOrientation(font.paths(glyph: g.glyph, em: em, origin: at))
            }
        }
        return out
    }

    /// Outlines for one line of text set at a font POINT size (em size, e.g. SVG `font-size`),
    /// with the baseline's anchor at `origin`. Throws `fontNotFound` for unknown fonts.
    public func outlines(for text: String, fontName: String, pointSize: Double, origin: Vec2,
                         alignment: TextAlignment) throws -> [Path] {
        guard pointSize > 0, !text.isEmpty else { return [] }
        let (font, _) = try Self.font(named: fontName, capHeight: 70)
        let placed = font.layout(text)
        let width = (placed.last.map { $0.x + $0.advance } ?? 0) * pointSize
        let factor: Double = alignment == .left ? 0 : alignment == .center ? 0.5 : 1
        let o = Vec2(origin.x - width * factor, origin.y)
        return placed.flatMap { g in
            PathGeometry.normalizedOrientation(font.paths(glyph: g.glyph, em: pointSize, origin: Vec2(o.x + g.x * pointSize, o.y)))
        }
    }

    /// Advance width of one line at a font point size.
    public func advance(of text: String, fontName: String, pointSize: Double) throws -> Double {
        guard pointSize > 0, !text.isEmpty else { return 0 }
        let (font, _) = try Self.font(named: fontName, capHeight: 70)
        return (font.layout(text).last.map { $0.x + $0.advance } ?? 0) * pointSize
    }
#endif

    /// Outlines of live text, in document coordinates.
    public func outlines(for spec: TextSpec) throws -> [Path] {
        if let adj = spec.letterAdjustments, !adj.isEmpty {
            return try TextKerning.outlines(for: spec, adjustments: adj, outliner: self)
        }
        if StrokeFont.isStrokeFont(spec.fontName) {
            return StrokeFont.outlines(for: spec.string, size: spec.size, origin: .zero, alignment: spec.alignment,
                                       lineSpacing: spec.lineSpacing, letterSpacing: spec.letterSpacing)
                .map { $0.transformed(spec.transform) }
        }
        return try outlines(for: spec.string, fontName: spec.fontName, size: spec.size, origin: .zero, alignment: spec.alignment,
                     lineSpacing: spec.lineSpacing, letterSpacing: spec.letterSpacing)
            .map { $0.transformed(spec.transform) }
    }

    /// An editable text `Shape` built from `spec`.
    public func shape(for spec: TextSpec, layerID: UUID) throws -> Shape {
        Shape(name: spec.string.replacingOccurrences(of: "\n", with: " "), layerID: layerID, paths: try outlines(for: spec),
              origin: .text(spec.string, fontName: spec.fontName, size: spec.displayedSize), text: spec)
    }

    /// A text `Shape` (provenance recorded for re-editing).
    public func shape(for text: String, fontName: String, size: Double, origin: Vec2,
                      alignment: TextAlignment = .left, layerID: UUID) throws -> Shape {
        let paths = try outlines(for: text, fontName: fontName, size: size, origin: origin, alignment: alignment)
        return Shape(name: text, layerID: layerID, paths: paths, origin: .text(text, fontName: fontName, size: size))
    }

#if canImport(CoreText)
    /// Installed font family names for the UI picker (sorted, hidden system fonts removed).
    public static func availableFontNames() -> [String] {
        let names = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Font whose capital height equals `capHeight`. Accepts family, full or PostScript names.
    static func font(named name: String, capHeight: Double) throws -> CTFont {
        let probe = CTFontCreateWithName(name as CFString, 100, nil)
        let wanted = name.lowercased()
        let candidates = [CTFontCopyFamilyName(probe), CTFontCopyPostScriptName(probe), CTFontCopyFullName(probe)]
            .map { ($0 as String).lowercased() }
        guard candidates.contains(wanted) else { throw TextError.fontNotFound(name) }
        var cap = CTFontGetCapHeight(probe) / 100
        if cap <= 0 { cap = 0.7 }
        return CTFontCreateWithName(name as CFString, capHeight / cap, nil)
    }

    private func glyphOutlines(_ line: CTLine, at o: Vec2, fallback: CTFont) -> [Path] {
        var out: [Path] = []
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        for run in runs {
            let n = CTRunGetGlyphCount(run)
            guard n > 0 else { continue }
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let runFont = attrs[kCTFontAttributeName as String].map { $0 as! CTFont } ?? fallback
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var positions = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &positions)
            for k in 0..<n {
                var t = CGAffineTransform(translationX: positions[k].x + o.x, y: positions[k].y + o.y)
                guard let cg = CTFontCreatePathForGlyph(runFont, glyphs[k], &t) else { continue }
                out += PathGeometry.normalizedOrientation(Self.paths(from: cg))
            }
        }
        return out
    }

    /// Convert a CGPath into `Path`s (quadratics become cubics).
    static func paths(from cg: CGPath) -> [Path] {
        var out: [Path] = []
        var cur: Path?
        func finish() {
            if var p = cur, !p.segments.isEmpty {
                if p.isClosed, case .line(let to) = p.segments.last!, to == p.start, p.segments.count > 1 {
                    p.segments.removeLast()
                }
                out.append(p)
            }
            cur = nil
        }
        cg.applyWithBlock { el in
            let e = el.pointee
            func pt(_ i: Int) -> Vec2 { Vec2(Double(e.points[i].x), Double(e.points[i].y)) }
            switch e.type {
            case .moveToPoint:
                finish()
                cur = Path(start: pt(0))
            case .addLineToPoint:
                cur?.segments.append(.line(to: pt(0)))
            case .addQuadCurveToPoint:
                if let p = cur {
                    cur?.segments.append(SVGPathParser.quad(from: p.end, pt(0), pt(1)))
                }
            case .addCurveToPoint:
                cur?.segments.append(.cubic(to: pt(2), control1: pt(0), control2: pt(1)))
            case .closeSubpath:
                cur?.isClosed = true
                finish()
            @unknown default:
                break
            }
        }
        finish()
        return out
    }
#else
    /// Installed font family names for the UI picker (sorted, hidden system fonts removed).
    public static func availableFontNames() -> [String] { PortableFont.familyNames() }

    /// The font and em size whose capital height equals `capHeight`. Accepts family, full or PostScript names.
    static func font(named name: String, capHeight: Double) throws -> (font: PortableFont, em: Double) {
        guard let font = PortableFont.named(name) else { throw TextError.fontNotFound(name) }
        return (font, capHeight / font.capHeight)
    }
#endif
}
