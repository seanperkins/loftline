#if !canImport(CoreText)
import CStb
import Foundation

/// One font face off the Mac, where CoreText is missing. stb_truetype reads TrueType and OpenType (CFF) outlines and `kern` or
/// GPOS pair kerning. It does no shaping: no ligatures, no complex scripts, and no fallback to another font for a missing
/// character (docs/PLATFORMS.md).
final class PortableFont: @unchecked Sendable {
    private let bytes: UnsafeMutableBufferPointer<UInt8>
    private let font: OpaquePointer
    let unitsPerEm: Double
    /// Capital height as a fraction of the em.
    let capHeight: Double
    /// Ascent + descent + line gap as a fraction of the em.
    let lineHeight: Double

    private init?(bytes: UnsafeMutableBufferPointer<UInt8>, index: Int) {
        guard let base = bytes.baseAddress, let font = cstb_font_open(base, Int32(index)) else { return nil }
        self.bytes = bytes
        self.font = font
        unitsPerEm = cstb_font_units_per_em(font)
        var a: Int32 = 0, d: Int32 = 0, gap: Int32 = 0
        cstb_font_vmetrics(font, &a, &d, &gap)
        lineHeight = Double(a - d + gap) / unitsPerEm
        var x0: Int32 = 0, y0: Int32 = 0, x1: Int32 = 0, y1: Int32 = 0
        let h = cstb_font_glyph_index(font, 72)   // "H"
        // The same fallback as the Mac's: a font with no measurable capital counts as 0.7 em.
        capHeight = h != 0 && cstb_font_glyph_box(font, h, &x0, &y0, &x1, &y1) != 0 && y1 > 0 ? Double(y1) / unitsPerEm : 0.7
    }

    /// A glyph set on a line: `x` and `advance` in ems before letter spacing.
    struct Placed {
        var glyph: Int32
        var x: Double
        var advance: Double
    }

    /// Lays out one line. Pair kerning goes into the left glyph's advance, as CoreText reports it.
    func layout(_ line: String) -> [Placed] {
        let glyphs = line.unicodeScalars.map { cstb_font_glyph_index(font, Int32(bitPattern: $0.value)) }
        var out: [Placed] = [], x = 0.0
        for (i, g) in glyphs.enumerated() {
            var advance = Double(cstb_font_advance(font, g))
            if i + 1 < glyphs.count { advance += Double(cstb_font_kern(font, g, glyphs[i + 1])) }
            advance /= unitsPerEm
            out.append(Placed(glyph: g, x: x, advance: advance))
            x += advance
        }
        return out
    }

    /// The glyph's contours, `em` document units to the em, moved by `origin`. Quadratics become cubics, as on the Mac.
    func paths(glyph: Int32, em: Double, origin: Vec2) -> [Path] {
        var count: Int32 = 0
        guard let vertices = cstb_font_outline(font, glyph, &count), count > 0 else { return [] }
        defer { cstb_free(vertices) }
        let scale = em / unitsPerEm
        func point(_ x: Int32, _ y: Int32) -> Vec2 { Vec2(Double(x) * scale + origin.x, Double(y) * scale + origin.y) }
        var out: [Path] = [], current: Path?
        func finish() {
            guard var p = current, !p.segments.isEmpty else { current = nil; return }
            // stb_truetype's contours return to their start.
            if case .line(let to) = p.segments.last!, to == p.start, p.segments.count > 1 { p.segments.removeLast() }
            p.isClosed = true
            out.append(p)
            current = nil
        }
        for i in 0..<Int(count) {
            let v = vertices[i]
            switch v.kind {
            case 1:
                finish()
                current = Path(start: point(v.x, v.y))
            case 2:
                current?.segments.append(.line(to: point(v.x, v.y)))
            case 3:
                if let p = current { current?.segments.append(SVGPathParser.quad(from: p.end, point(v.cx, v.cy), point(v.x, v.y))) }
            default:
                current?.segments.append(.cubic(to: point(v.x, v.y), control1: point(v.cx, v.cy), control2: point(v.cx1, v.cy1)))
            }
        }
        finish()
        return out
    }

    private func name(_ id: Int32) -> String? {
        var length: Int32 = 0, utf16: Int32 = 0
        guard let raw = cstb_font_name(font, id, &length, &utf16), length > 0 else { return nil }
        let data = Data(bytes: raw, count: Int(length))
        return String(data: data, encoding: utf16 != 0 ? .utf16BigEndian : .macOSRoman)
    }

    // MARK: finding fonts

    private struct Entry {
        var url: URL
        var index: Int
        var family: String
        var isRegular: Bool
    }

    private static let lock = NSLock()
    /// Lower-cased family, full or PostScript name → the face to use. Scanned once per process.
    nonisolated(unsafe) private static var catalog: [String: Entry]?
    nonisolated(unsafe) private static var families: [String] = []
    nonisolated(unsafe) private static var loaded: [String: PortableFont] = [:]

    /// The installed font with this family, full or PostScript name, or nil. A family name gives its regular face.
    static func named(_ name: String) -> PortableFont? {
        lock.lock(); defer { lock.unlock() }
        let key = name.lowercased()
        if let font = loaded[key] { return font }
        guard let entry = scanned()[key], let font = open(entry.url, index: entry.index) else { return nil }
        loaded[key] = font
        return font
    }

    /// Installed family names, sorted.
    static func familyNames() -> [String] {
        lock.lock(); defer { lock.unlock() }
        _ = scanned()
        return families
    }

    private static func read(_ url: URL) -> UnsafeMutableBufferPointer<UInt8>? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: data.count)
        _ = data.copyBytes(to: buffer)
        return buffer
    }

    /// The font keeps its bytes for the life of the process, like the catalog entry that found it.
    private static func open(_ url: URL, index: Int) -> PortableFont? {
        guard let bytes = read(url) else { return nil }
        guard let font = PortableFont(bytes: bytes, index: index) else { bytes.deallocate(); return nil }
        return font
    }

    private static func scanned() -> [String: Entry] {
        if let catalog { return catalog }
        var found: [String: Entry] = [:], names = Set<String>()
        let manager = FileManager.default
        for directory in fontDirectories() {
            guard let files = manager.enumerator(at: directory, includingPropertiesForKeys: nil) else { continue }
            let urls = files.compactMap { $0 as? URL }
                .filter { ["ttf", "otf", "ttc", "otc"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.path < $1.path }
            for url in urls {
                guard let bytes = read(url), let base = bytes.baseAddress else { continue }
                defer { bytes.deallocate() }
                for index in 0..<max(1, Int(cstb_font_count(base))) {
                    guard let face = PortableFont(bytes: bytes, index: index) else { continue }
                    defer { cstb_font_close(face.font) }
                    guard let family = face.name(16) ?? face.name(1) else { continue }
                    let style = (face.name(17) ?? face.name(2) ?? "Regular").lowercased()
                    let entry = Entry(url: url, index: index, family: family, isRegular: style == "regular" || style == "book" || style == "roman")
                    names.insert(family)
                    let familyKey = family.lowercased()
                    if found[familyKey] == nil || (entry.isRegular && found[familyKey]?.isRegular == false) { found[familyKey] = entry }
                    for own in [face.name(4), face.name(6)] {
                        if let own, found[own.lowercased()] == nil || own.lowercased() == familyKey && entry.isRegular { found[own.lowercased()] = entry }
                    }
                }
            }
        }
        catalog = found
        families = names.filter { !$0.hasPrefix(".") }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return found
    }

    private static func fontDirectories() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths: [URL] = []
        #if os(Windows)
        let env = ProcessInfo.processInfo.environment
        paths.append(URL(fileURLWithPath: (env["WINDIR"] ?? "C:\\Windows") + "\\Fonts"))
        if let local = env["LOCALAPPDATA"] { paths.append(URL(fileURLWithPath: local + "\\Microsoft\\Windows\\Fonts")) }
        #else
        paths += ["/usr/share/fonts", "/usr/local/share/fonts"].map { URL(fileURLWithPath: $0) }
        paths += [".fonts", ".local/share/fonts"].map { home.appendingPathComponent($0) }
        #endif
        return paths
    }
}
#endif
