import Foundation
#if canImport(CoreText)
import CoreText
#endif

/// Letter-by-letter layout of live text with per-letter moves and rotations.
public enum TextKerning {
    /// Line pitch for `fontName` at cap height `size` (same rules as the normal layout).
    static func lineHeight(fontName: String, size: Double, lineSpacing: Double) throws -> Double {
        if StrokeFont.isStrokeFont(fontName) { return StrokeFont.lineHeight * size * lineSpacing }
        #if canImport(CoreText)
        let font = try TextOutliner.font(named: fontName, capHeight: size)
        return (CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)) * lineSpacing
        #else
        let (font, em) = try TextOutliner.font(named: fontName, capHeight: size)
        return font.lineHeight * em * lineSpacing
        #endif
    }

    /// Number of letters (glyphs) the adjustments can address.
    public static func letterCount(_ spec: TextSpec) throws -> Int {
        try spec.string.components(separatedBy: "\n").reduce(0) {
            $0 + (try TextOutliner().glyphs(for: $1, fontName: spec.fontName, size: spec.size, letterSpacing: spec.letterSpacing).count)
        }
    }

    static func outlines(for spec: TextSpec, adjustments: [TextSpec.LetterAdjustment], outliner: TextOutliner) throws -> [Path] {
        try letters(for: spec, adjustments: adjustments, outliner: outliner).flatMap(\.paths)
    }

    /// One laid-out letter of live text (document coordinates, adjustments applied).
    public struct Letter: Sendable {
        /// Letter number used by `TextSpec.LetterAdjustment.index`.
        public var index: Int
        /// Line the letter is on (0 = first).
        public var line: Int
        public var paths: [Path]
        public var bounds: Rect2
    }

    /// The letters of `spec` with its current adjustments, in order. Blank glyphs (spaces) are
    /// included with empty paths so indices stay aligned.
    public static func letters(for spec: TextSpec) throws -> [Letter] {
        try letters(for: spec, adjustments: spec.letterAdjustments ?? [], outliner: TextOutliner())
    }

    static func letters(for spec: TextSpec, adjustments: [TextSpec.LetterAdjustment], outliner: TextOutliner) throws -> [Letter] {
        let byIndex = Dictionary(adjustments.map { ($0.index, $0) }, uniquingKeysWith: { _, b in b })
        let pitch = try lineHeight(fontName: spec.fontName, size: spec.size, lineSpacing: spec.lineSpacing)
        var out: [Letter] = []
        var index = 0
        for (i, line) in spec.string.components(separatedBy: "\n").enumerated() {
            let glyphs = try outliner.glyphs(for: line, fontName: spec.fontName, size: spec.size, letterSpacing: spec.letterSpacing)
            guard let last = glyphs.last else { continue }
            var width = last.x + last.advance - spec.letterSpacing
            if StrokeFont.isStrokeFont(spec.fontName) { width = max(0, width - StrokeFont.gap * spec.size) }
            let factor: Double = spec.alignment == .left ? 0 : spec.alignment == .center ? 0.5 : 1
            let lineShift = Vec2(-width * factor, -Double(i) * pitch)
            for g in glyphs {
                var t = Transform2D.identity
                if let a = byIndex[index] {
                    let c = Vec2(g.x + g.advance / 2, spec.size / 2)
                    t = Transform2D.rotation(a.rotation * .pi / 180, about: c).concatenating(.translation(a.offset))
                }
                t = t.concatenating(.translation(lineShift)).concatenating(spec.transform)
                let paths = g.paths.map { $0.transformed(t) }
                out.append(Letter(index: index, line: i, paths: paths,
                                  bounds: paths.reduce(Rect2.empty) { $0.union($1.bounds()) }))
                index += 1
            }
        }
        return out
    }

    /// The letter under `point` (inside its bounding box grown by `tolerance`; the smallest box
    /// wins where boxes overlap). Blank letters are never hit.
    public static func letter(at point: Vec2, in letters: [Letter], tolerance: Double) -> Letter? {
        letters.filter { !$0.paths.isEmpty && $0.bounds.insetBy(-tolerance).contains(point) }
            .min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }

    /// `spec` with `indices` moved by a document-space `delta` (converted into layout units, so
    /// scaled, rotated or mirrored text moves with the pointer). Adjustments that end up empty are
    /// dropped; nil when none remain.
    public static func moving(_ spec: TextSpec, letters indices: Set<Int>, byDocumentDelta delta: Vec2) -> TextSpec {
        guard !indices.isEmpty, let inv = spec.transform.inverted else { return spec }
        let d = inv.applyToVector(delta)
        var byIndex = Dictionary((spec.letterAdjustments ?? []).map { ($0.index, $0) }, uniquingKeysWith: { _, b in b })
        for i in indices {
            var a = byIndex[i] ?? TextSpec.LetterAdjustment(index: i)
            a.offset = a.offset + d
            byIndex[i] = a
        }
        var out = spec
        let kept = byIndex.values.filter { $0.offset.length > 1e-12 || $0.rotation != 0 }.sorted { $0.index < $1.index }
        out.letterAdjustments = kept.isEmpty ? nil : kept
        return out
    }
}
