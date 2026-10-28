import Foundation

/// SVG import: path/rect/circle/ellipse/line/polyline/polygon, nested transforms, `<use>`,
/// viewBox + physical units → document units. Top-level groups (and Inkscape layers) become
/// layers. Output is in the document frame: Y up, the SVG page's lower-left corner at (0,0).
public struct SVGImporter: VectorImporter {
    public static let fileExtensions = ["svg"]

    /// User units per inch to assume for a file that does not fix its own size (see `scaleGuess(of:)`).
    /// nil guesses from the program that wrote the file: Inkscape 0.91 and older 90, Illustrator 72,
    /// otherwise 96 (CSS). A file with a physical size ignores it.
    public var pixelsPerInch: Double?

    public init(pixelsPerInch: Double? = nil) { self.pixelsPerInch = pixelsPerInch }

    /// The scale to assume for an SVG that does not state its own size.
    public struct ScaleGuess: Equatable, Sendable {
        /// User units per inch: the program's own, when it is recognised, else 96.
        public var pixelsPerInch: Double
        /// The program that wrote the file, when recognised ("Inkscape 0.91", "Adobe Illustrator").
        public var generator: String?
    }

    /// nil when the file states its own size: a viewBox plus a physical unit (in, mm, cm, pt, pc) on the page
    /// width or height. Otherwise the length of a user unit has to be assumed.
    public static func scaleGuess(of data: Data) throws -> ScaleGuess? {
        scaleGuess(root: try SVGNode.parse(data), data: data)
    }

    static func scaleGuess(root: SVGNode, data: Data) -> ScaleGuess? {
        let vb = root["viewBox"].map(SVGNumberScanner.numbers(in:)) ?? []
        let hasViewBox = vb.count == 4 && vb[2] > 0 && vb[3] > 0
        if hasViewBox && (SVGAttributes.hasPhysicalUnit(root["width"]) || SVGAttributes.hasPhysicalUnit(root["height"])) { return nil }
        let program = generator(root: root, data: data)
        return ScaleGuess(pixelsPerInch: program?.pixelsPerInch ?? 96, generator: program?.name)
    }

    /// The program that wrote the file, from Inkscape's version attribute or the generator comment Illustrator
    /// leaves at the top, with the user units per inch it draws in. Inkscape drew in 90 per inch up to 0.91 and
    /// has used 96 since 0.92; Illustrator uses 72.
    static func generator(root: SVGNode, data: Data) -> (name: String, pixelsPerInch: Double)? {
        if let version = root["inkscape:version"] {
            let number = version.prefix { $0.isNumber || $0 == "." }
            let parts = number.split(separator: ".").compactMap { Int($0) }
            if let major = parts.first {
                return ("Inkscape \(number)", major == 0 && (parts.count > 1 ? parts[1] : 0) < 92 ? 90 : 96)
            }
        }
        // Only the comment Illustrator writes ("<!-- Generator: Adobe Illustrator 19.0.0, ... -->"): a title or
        // a text that mentions the program does not make the file one of its.
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        if head.range(of: #"<!--\s*Generator:\s*Adobe Illustrator"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return ("Adobe Illustrator", 72)
        }
        return nil
    }

    public func importVectors(from data: Data, targetUnits: LengthUnit) throws -> ImportResult {
        let root = try SVGNode.parse(data)
        var ctx = Context(units: targetUnits)
        ctx.indexIDs(root)
        // A physical page size and a viewBox fix the scale. Otherwise a user unit is 1/scale inch, and the guess
        // is reported unless the caller chose the scale.
        let guess = Self.scaleGuess(root: root, data: data)
        let scale = guess.map { pixelsPerInch ?? $0.pixelsPerInch } ?? 96
        ctx.pixelsPerInch = scale
        ctx.viewport = Self.percentageViewport(root, pixelsPerInch: scale)
        if let guess {
            ctx.origin = .imported(format: "svg", pixelsPerInch: scale)
            if pixelsPerInch == nil {
                let source = guess.generator.map { " (\($0))" } ?? " (the web default)"
                ctx.warnings.append("This SVG has no physical size, so it was scaled at \(Int(scale)) px per inch\(source). If it comes in at the wrong size, import it again and choose another scale.")
            }
        }
        let pageToDoc = viewportTransform(root, units: targetUnits, pixelsPerInch: scale)

        let defaultLayer = Layer(name: "SVG Import", colorHex: Self.palette[0])
        for child in root.children {
            if child.name == "g", !Self.hiddenContainers.contains(child.name), isRendered(child) {
                let layer = Layer(name: child["inkscape:label"] ?? child.id ?? "Group \(ctx.layers.count + 1)",
                                  colorHex: Self.palette[(ctx.layers.count + 1) % Self.palette.count])
                let before = ctx.shapes.count
                ctx.walk(child, ctm: pageToDoc, layerID: layer.id)
                if ctx.shapes.count > before { ctx.layers.append(layer) }
            } else {
                ctx.walk(child, ctm: pageToDoc, layerID: defaultLayer.id)
            }
        }
        if ctx.shapes.contains(where: { $0.layerID == defaultLayer.id }) { ctx.layers.insert(defaultLayer, at: 0) }
        // No viewBox and no height: the page height is unknown, so flipping Y about it put everything below the
        // material. The lowest point of the content (shapes and embedded pictures) is the bottom of the page then.
        if !(ctx.viewport.h > 0) {
            var bottom = ctx.shapes.isEmpty ? Double.infinity : PathGeometry.bounds(of: ctx.shapes).min.y
            for image in ctx.images { bottom = min(bottom, image.rect.min.y) }
            if bottom.isFinite {
                ctx.warnings.append("This SVG gives no page height, so its artwork was placed on the bottom edge of the material.")
                if bottom != 0 {
                    let lift = Vec2(0, -bottom)
                    ctx.shapes = ctx.shapes.map { $0.transformed(.translation(lift)) }
                    ctx.images = ctx.images.map { var i = $0; i.rect = Rect2(min: i.rect.min + lift, max: i.rect.max + lift); return i }
                }
            }
        }
        ctx.warnings += ImportGaps.warnings(shapes: ctx.shapes, layers: ctx.layers, units: targetUnits)
        return ImportResult(layers: ctx.layers, shapes: ctx.shapes, warnings: ctx.warnings, images: ctx.images)
    }

    /// The size, in user units, that percentage lengths on shapes resolve against: the viewBox, else the root's own
    /// width and height (a user unit is a pixel then). 0 where the file does not give one.
    static func percentageViewport(_ root: SVGNode, pixelsPerInch: Double) -> (w: Double, h: Double) {
        let vb = root["viewBox"].map(SVGNumberScanner.numbers(in:)) ?? []
        if vb.count == 4, vb[2] > 0, vb[3] > 0 { return (vb[2], vb[3]) }
        return (SVGAttributes.pixels(root["width"], pixelsPerInch: pixelsPerInch) ?? 0,
                SVGAttributes.pixels(root["height"], pixelsPerInch: pixelsPerInch) ?? 0)
    }

    /// Maps root user space → document units with Y flipped (page bottom at y = 0). `pixelsPerInch` is the
    /// scale of the page's own pixels, which physical sizes on the page are converted to.
    func viewportTransform(_ root: SVGNode, units: LengthUnit, pixelsPerInch: Double) -> Transform2D {
        let pxToUnit = LengthUnit.inch.convert(1 / pixelsPerInch, to: units)
        let vb = root["viewBox"].map(SVGNumberScanner.numbers(in:)) ?? []
        let hasVB = vb.count == 4 && vb[2] > 0 && vb[3] > 0
        // Viewport size in px (width/height attributes; default to the viewBox size).
        let wAttr = SVGAttributes.pixels(root["width"], percentOf: hasVB ? vb[2] : 0, pixelsPerInch: pixelsPerInch)
        let hAttr = SVGAttributes.pixels(root["height"], percentOf: hasVB ? vb[3] : 0, pixelsPerInch: pixelsPerInch)
        // With a viewBox, a missing (or "auto") dimension is the other one scaled by the viewBox
        // aspect ratio (SVG 2 §8.3); defaulting it to the viewBox size would mis-scale the file.
        var wPx = wAttr ?? (hasVB ? vb[2] : 0)
        var hPx = hAttr ?? (hasVB ? vb[3] : 0)
        if hasVB {
            if let w = wAttr, hAttr == nil { hPx = w * vb[3] / vb[2] }
            if let h = hAttr, wAttr == nil { wPx = h * vb[2] / vb[3] }
        }
        var userToPx = Transform2D.identity
        if hasVB {
            var sx = wPx / vb[2], sy = hPx / vb[3]
            var tx = -vb[0] * sx, ty = -vb[1] * sy
            let par = root["preserveAspectRatio"]?.trimmingCharacters(in: .whitespaces) ?? "xMidYMid meet"
            if !par.hasPrefix("none") {
                let s = par.contains("slice") ? max(sx, sy) : min(sx, sy)
                let extraX = wPx - vb[2] * s, extraY = hPx - vb[3] * s
                let fx = par.contains("xMin") ? 0.0 : par.contains("xMax") ? 1.0 : 0.5
                let fy = par.contains("YMin") ? 0.0 : par.contains("YMax") ? 1.0 : 0.5
                sx = s; sy = s
                tx = -vb[0] * s + extraX * fx
                ty = -vb[1] * s + extraY * fy
            }
            userToPx = Transform2D(a: sx, b: 0, c: 0, d: sy, tx: tx, ty: ty)
        }
        let flip = Transform2D(a: pxToUnit, b: 0, c: 0, d: -pxToUnit, tx: 0, ty: hPx * pxToUnit)
        return userToPx.concatenating(flip)
    }

    static let palette = ["#1E90FF", "#E5484D", "#30A46C", "#F76B15", "#8E4EC6", "#12A594", "#D6409F", "#3E63DD"]
    static let hiddenContainers: Set<String> = ["defs", "clipPath", "mask", "symbol", "pattern", "marker",
                                                 "metadata", "title", "desc", "style", "script", "linearGradient",
                                                 "radialGradient", "filter", "namedview"]

    func isRendered(_ n: SVGNode) -> Bool {
        n.property("display") != "none" && n.property("visibility") != "hidden"
    }

    // MARK: - Walk

    struct Context {
        let units: LengthUnit
        var layers: [Layer] = []
        var shapes: [Shape] = []
        var warnings: [String] = []
        var images: [ImportedImage] = []
        /// Provenance of every shape: records the scale assumed for a file with no physical size.
        var origin = ShapeOrigin.imported(format: "svg")
        /// User units per inch: what a length written with a physical unit ("1in", "12pt") is worth.
        var pixelsPerInch = 96.0
        /// Width and height, in user units, that percentage lengths on shapes resolve against (the viewBox, else the
        /// root's size). 0 when the file does not say.
        var viewport = (w: 0.0, h: 0.0)
        var ids: [String: SVGNode] = [:]
        private var warned: Set<String> = []
        private var useDepth = 0
        /// `<use>` expansions so far: the depth guard bounds nesting, not work (a group using itself four times, #121).
        private var useCount = 0

        init(units: LengthUnit) { self.units = units }

        mutating func indexIDs(_ root: SVGNode) {
            var map: [String: SVGNode] = [:]
            root.forEach { if let id = $0.id { map[id] = $0 } }
            ids = map
        }

        /// A length attribute in user units at this file's scale.
        func length(_ s: String?, percentOf ref: Double = 0) -> Double? {
            SVGAttributes.pixels(s, percentOf: ref, pixelsPerInch: pixelsPerInch)
        }

        /// The length of attribute `key` (x, width, cy, ...): a percentage is of the viewport along that axis.
        func length(_ n: SVGNode, _ key: String) -> Double? {
            SVGAttributes.pixels(n[key], percentOf: SVGAttributes.percentReference(key, viewport: viewport),
                                 pixelsPerInch: pixelsPerInch)
        }

        mutating func warnOnce(_ msg: String) {
            if warned.insert(msg).inserted { warnings.append(msg) }
        }

        mutating func walk(_ n: SVGNode, ctm parent: Transform2D, layerID: UUID) {
            guard !SVGImporter.hiddenContainers.contains(n.name),
                  n.property("display") != "none", n.property("visibility") != "hidden" else { return }
            let ctm = (n["transform"].map(SVGAttributes.transform) ?? .identity).concatenating(parent)
            switch n.name {
            case "g", "a", "switch":
                for c in n.children { walk(c, ctm: ctm, layerID: layerID) }
            case "svg":
                // Nested viewport: honour x/y offset only.
                let off = Transform2D.translation(Vec2(length(n, "x") ?? 0, length(n, "y") ?? 0))
                for c in n.children { walk(c, ctm: off.concatenating(ctm), layerID: layerID) }
            case "use":
                let ref = (n["xlink:href"] ?? n["href"]).map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
                guard let ref, let target = ids[ref], useDepth < 16 else {
                    warnOnce("Ignored <use> with a missing reference."); return
                }
                guard useCount < 10_000 else { warnOnce("Ignored <use> references past the first 10,000."); return }
                useCount += 1
                let off = Transform2D.translation(Vec2(length(n, "x") ?? 0, length(n, "y") ?? 0))
                useDepth += 1
                if target.name == "symbol" {
                    for c in target.children { walk(c, ctm: off.concatenating(ctm), layerID: layerID) }
                } else {
                    walk(target, ctm: off.concatenating(ctm), layerID: layerID)
                }
                useDepth -= 1
            case "text":
                addText(n, ctm: ctm, layerID: layerID)
            case "image":
                addImage(n, ctm: ctm)
            default:
                if let paths = SVGImporter.geometry(of: n, pixelsPerInch: pixelsPerInch, viewport: viewport), !paths.isEmpty {
                    // A subpath that returns to its start without "Z" is still a closed vector.
                    let doc = PathGeometry.closeNearlyClosed(paths.map { $0.transformed(ctm) },
                                                             tolerance: units == .inch ? 0.0005 : 0.01)
                    shapes.append(Shape(name: n.id.map(SVGImporter.displayName(forID:)) ?? n.name, layerID: layerID, paths: doc,
                                        origin: origin))
                }
            }
        }
    }

    // MARK: - Element geometry (raw user space)

    /// Installed font for a CSS `font-family` list (generic families map to macOS fonts);
    /// bold weights prefer the family's "Bold" face. nil when none of them is installed.
    static func resolveFont(family: String?, weight: String?) -> String? {
        let generic = ["sans-serif": "Helvetica", "serif": "Times New Roman", "monospace": "Menlo",
                       "cursive": "Apple Chancery", "fantasy": "Papyrus", "system-ui": "Helvetica"]
        let names = (family ?? "sans-serif").split(separator: ",").map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }.filter { !$0.isEmpty }
        let bold = weight.map { $0 == "bold" || $0 == "bolder" || (Int($0) ?? 400) >= 600 } ?? false
        for raw in names {
            let name = generic[raw.lowercased()] ?? raw
            let tries = bold ? ["\(name) Bold", "\(name)-Bold", name] : [name]
            for t in tries where (try? TextOutliner().advance(of: "H", fontName: t, pointSize: 10)) != nil { return t }
        }
        return nil
    }

    /// A shape name from an SVG element id. LoftLine's own export writes ids as "Name-<8 hex digits>" to keep
    /// them unique; the hash is dropped so a round trip (and the sample files) keep readable names.
    /// Only a suffix with at least one letter a–f counts, so "Rev-20240101" keeps its date.
    public static func displayName(forID id: String) -> String {
        guard let dash = id.lastIndex(of: "-"), dash != id.startIndex else { return id }
        let suffix = id[id.index(after: dash)...]
        let isHash = suffix.count == 8 && suffix.allSatisfy { $0.isHexDigit && !$0.isUppercase }
            && suffix.contains { "abcdef".contains($0) }
        return isHash ? String(id[..<dash]) : id
    }

    /// The paths of a basic shape or path element; lengths with a physical unit are worth `pixelsPerInch` per inch.
    static func geometry(of n: SVGNode, pixelsPerInch: Double, viewport: (w: Double, h: Double) = (0, 0)) -> [Path]? {
        func length(_ k: String) -> Double? {
            SVGAttributes.pixels(n[k], percentOf: SVGAttributes.percentReference(k, viewport: viewport), pixelsPerInch: pixelsPerInch)
        }
        func num(_ k: String) -> Double { length(k) ?? 0 }
        switch n.name {
        case "path":
            return SVGPathParser.parse(n["d"] ?? "")
        case "rect":
            let w = num("width"), h = num("height")
            guard w > 0, h > 0 else { return nil }
            var rx = length("rx"), ry = length("ry")
            if rx == nil { rx = ry }
            if ry == nil { ry = rx }
            let r = Rect2(x: num("x"), y: num("y"), width: w, height: h)
            return [roundedRect(r, rx: min(rx ?? 0, w / 2), ry: min(ry ?? 0, h / 2))]
        case "circle":
            let r = num("r")
            guard r > 0 else { return nil }
            return [ShapeFactory.circle(center: Vec2(num("cx"), num("cy")), radius: r)]
        case "ellipse":
            let rx = num("rx"), ry = num("ry")
            guard rx > 0, ry > 0 else { return nil }
            let c = Vec2(num("cx"), num("cy"))
            return [abs(rx - ry) < 1e-12 ? ShapeFactory.circle(center: c, radius: rx)
                                         : ShapeFactory.ellipse(center: c, rx: rx, ry: ry)]
        case "line":
            return [Path(points: [Vec2(num("x1"), num("y1")), Vec2(num("x2"), num("y2"))], closed: false)]
        case "polyline", "polygon":
            let v = SVGNumberScanner.numbers(in: n["points"] ?? "")
            let pts = stride(from: 0, to: v.count - 1, by: 2).map { Vec2(v[$0], v[$0 + 1]) }
            guard pts.count > 1 else { return nil }
            return [Path(points: pts, closed: n.name == "polygon")]
        default:
            return nil
        }
    }

    /// Rectangle with elliptical corners (rx, ry); arcs when circular.
    static func roundedRect(_ r: Rect2, rx: Double, ry: Double) -> Path {
        if rx <= 0 || ry <= 0 { return ShapeFactory.rectangle(r) }
        if abs(rx - ry) < 1e-12 { return ShapeFactory.rectangle(r, cornerRadius: rx) }
        let k = 0.5522847498307936
        let (x0, y0, x1, y1) = (r.min.x, r.min.y, r.max.x, r.max.y)
        func corner(_ from: Vec2, _ to: Vec2, _ c: Vec2) -> PathSegment {
            .cubic(to: to, control1: from + (c - from) * k, control2: to + (c - to) * k)
        }
        return Path(start: Vec2(x0 + rx, y0), segments: [
            .line(to: Vec2(x1 - rx, y0)),
            corner(Vec2(x1 - rx, y0), Vec2(x1, y0 + ry), Vec2(x1, y0)),
            .line(to: Vec2(x1, y1 - ry)),
            corner(Vec2(x1, y1 - ry), Vec2(x1 - rx, y1), Vec2(x1, y1)),
            .line(to: Vec2(x0 + rx, y1)),
            corner(Vec2(x0 + rx, y1), Vec2(x0, y1 - ry), Vec2(x0, y1)),
            .line(to: Vec2(x0, y0 + ry)),
            corner(Vec2(x0, y0 + ry), Vec2(x0 + rx, y0), Vec2(x0, y0)),
        ], isClosed: true)
    }
}

// MARK: - Text and images

extension SVGImporter.Context {
    /// `<text>` (with `<tspan>` runs) → outline shape. Fonts come from the installed system fonts.
    mutating func addText(_ n: SVGNode, ctm: Transform2D, layerID: UUID) {
        var paths: [Path] = []
        var label = ""
        var cursor = Vec2(length(n, "x") ?? 0, length(n, "y") ?? 0)
        var atStart = true

        func run(_ node: SVGNode) {
            for c in node.children {
                if c.name == "#text" {
                    var s = c.data.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
                    while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
                    if atStart { s = String(s.drop { $0 == " " }) }
                    guard !s.isEmpty else { continue }
                    atStart = false
                    emit(s, style: node)
                } else if c.name == "tspan" || c.name == "textPath" {
                    if c.property("display") == "none" { continue }
                    if let x = length(c, "x") { cursor.x = x }
                    if let y = length(c, "y") { cursor.y = y }
                    cursor.x += length(c, "dx") ?? 0
                    cursor.y += length(c, "dy") ?? 0
                    run(c)
                }
            }
        }

        func emit(_ s: String, style: SVGNode) {
            let size = length(style.inherited("font-size"), percentOf: 16) ?? 16
            let family = style.inherited("font-family")
            guard let font = SVGImporter.resolveFont(family: family, weight: style.inherited("font-weight")) ?? {
                warnOnce("Font \(family ?? "?") is not installed; Helvetica was used.")
                return "Helvetica"
            }() else { return }
            let anchor = style.inherited("text-anchor")
            let align: TextAlignment = anchor == "middle" ? .center : anchor == "end" ? .right : .left
            let outliner = TextOutliner()
            guard let outline = try? outliner.outlines(for: s, fontName: font, pointSize: size, origin: .zero,
                                                       alignment: align) else { return }
            // Glyphs are Y-up; SVG user space is Y-down with the baseline at the cursor.
            let place = Transform2D(a: 1, b: 0, c: 0, d: -1, tx: cursor.x, ty: cursor.y).concatenating(ctm)
            paths += outline.map { $0.transformed(place) }
            label += s
            if align == .left { cursor.x += (try? outliner.advance(of: s, fontName: font, pointSize: size)) ?? 0 }
        }

        run(n)
        guard !paths.isEmpty else { return }
        let name = label.trimmingCharacters(in: .whitespaces)
        shapes.append(Shape(name: name.isEmpty ? "Text" : String(name.prefix(40)), layerID: layerID, paths: paths,
                            origin: origin))
    }

    /// `<image>` with an embedded (data: URI) picture → tracing image; linked files are skipped.
    mutating func addImage(_ n: SVGNode, ctm: Transform2D) {
        let x = length(n, "x") ?? 0, y = length(n, "y") ?? 0
        guard let w = length(n, "width"), let h = length(n, "height"), w > 0, h > 0 else {
            warnOnce("An <image> without a width and height was skipped.")
            return
        }
        guard let href = n["xlink:href"] ?? n["href"], href.hasPrefix("data:"), let comma = href.firstIndex(of: ",") else {
            warnOnce("Linked (not embedded) images were skipped; import the picture file itself.")
            return
        }
        let header = href[..<comma], payload = String(href[href.index(after: comma)...])
        let raw: Data? = header.contains(";base64")
            ? Data(base64Encoded: payload.filter { !$0.isWhitespace })
            : payload.removingPercentEncoding.map { Data($0.utf8) }
        guard let raw, let png = RasterCodec.png(fromEncoded: raw) else {
            warnOnce("An embedded image could not be decoded.")
            return
        }
        let corners = [Vec2(x, y), Vec2(x + w, y), Vec2(x, y + h), Vec2(x + w, y + h)].map { ctm.apply($0) }
        images.append(ImportedImage(rect: Rect2(points: corners), png: png))
    }
}
