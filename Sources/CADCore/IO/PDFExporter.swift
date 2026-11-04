import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Page for vector export: spans min(0, bounds.min)…bounds.max (like the SVG exporter) in
/// PostScript points, so designs in the material frame keep their position.
struct VectorPage {
    let minX: Double, minY: Double, width: Double, height: Double
    /// Document units → points.
    let scale: Double

    init(shapes: [Shape], units: LengthUnit) {
        let b = PathGeometry.bounds(of: shapes)
        minX = b.isEmpty ? 0 : min(0, b.min.x); minY = b.isEmpty ? 0 : min(0, b.min.y)
        let maxX = b.isEmpty ? 1 : max(b.max.x, minX + 1e-6), maxY = b.isEmpty ? 1 : max(b.max.y, minY + 1e-6)
        width = maxX - minX; height = maxY - minY
        scale = units.convert(1, to: .inch) * 72
    }

    func point(_ p: Vec2) -> (Double, Double) { ((p.x - minX) * scale, (p.y - minY) * scale) }

    /// Layers in export order (unknown layer ids get a default black layer).
    static func grouped(_ shapes: [Shape], layers: [Layer]) -> [(Layer, [Shape])] {
        var byLayer: [UUID: [Shape]] = [:]
        for s in shapes { byLayer[s.layerID, default: []].append(s) }
        var ordered = layers.filter { byLayer[$0.id] != nil }
        for id in Set(byLayer.keys).subtracting(layers.map(\.id)).sorted(by: { $0.uuidString < $1.uuidString }) {
            ordered.append(Layer(id: id, name: "Layer"))
        }
        return ordered.map { ($0, byLayer[$0.id] ?? []) }
    }

    static func rgb(_ hex: String) -> (Double, Double, Double) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return (0, 0, 0) }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }
}

/// PDF export (also used for `.ai`: Illustrator opens PDF-format files). Paths keep lines,
/// arcs and cubics; each shape is stroked in its layer colour with a hairline.
public struct PDFExporter: VectorExporter {
    public static let fileExtension = "pdf"
    public init() {}

#if canImport(CoreGraphics)
    public func export(shapes: [Shape], layers: [Layer], units: LengthUnit) throws -> Data {
        let page = VectorPage(shapes: shapes, units: units)
        let out = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: page.width * page.scale, height: page.height * page.scale)
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box,
                                  [kCGPDFContextCreator as String: "LoftLine"] as CFDictionary) else {
            throw LoftLineIOError.malformed("PDF: could not create the document")
        }
        ctx.beginPDFPage(nil)
        ctx.setLineWidth(0.5)
        ctx.setLineJoin(.round)
        for (layer, group) in VectorPage.grouped(shapes, layers: layers) where layer.isVisible {
            let (r, g, b) = VectorPage.rgb(layer.colorHex)
            ctx.setStrokeColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
            for s in group {
                for p in s.paths where !p.segments.isEmpty {
                    let (x, y) = page.point(p.start)
                    ctx.move(to: CGPoint(x: x, y: y))
                    var cur = p.start
                    for seg in p.segments {
                        switch seg {
                        case .line(let to):
                            let (a, b) = page.point(to)
                            ctx.addLine(to: CGPoint(x: a, y: b))
                        case .cubic(let to, let c1, let c2):
                            let (a, b) = page.point(to), (c, d) = page.point(c1), (e, f) = page.point(c2)
                            ctx.addCurve(to: CGPoint(x: a, y: b), control1: CGPoint(x: c, y: d), control2: CGPoint(x: e, y: f))
                        case .arc(let to, let center, let cw):
                            for c in Flattening.arcToCubics(from: cur, to: to, center: center, clockwise: cw) {
                                if case .cubic(let t, let c1, let c2) = c {
                                    let (a, b) = page.point(t), (c, d) = page.point(c1), (e, f) = page.point(c2)
                                    ctx.addCurve(to: CGPoint(x: a, y: b), control1: CGPoint(x: c, y: d),
                                                 control2: CGPoint(x: e, y: f))
                                }
                            }
                        }
                        cur = seg.end
                    }
                    if p.isClosed { ctx.closePath() }
                }
                ctx.strokePath()
            }
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return out as Data
    }
#else
    /// Written directly off the Mac: a single page stream of the same operators.
    public func export(shapes: [Shape], layers: [Layer], units: LengthUnit) throws -> Data {
        let page = VectorPage(shapes: shapes, units: units)
        func n(_ v: Double) -> String {
            let s = String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), v)
            return s == "-0.0000" ? "0.0000" : s
        }
        func pt(_ p: Vec2) -> String { let (x, y) = page.point(p); return "\(n(x)) \(n(y))" }
        var content = "0.5 w 1 j\n"
        for (layer, group) in VectorPage.grouped(shapes, layers: layers) where layer.isVisible {
            let (r, g, b) = VectorPage.rgb(layer.colorHex)
            content += "\(n(r)) \(n(g)) \(n(b)) RG\n"
            for s in group {
                for p in s.paths where !p.segments.isEmpty {
                    content += "\(pt(p.start)) m\n"
                    var cur = p.start
                    for seg in p.segments {
                        switch seg {
                        case .line(let to): content += "\(pt(to)) l\n"
                        case .cubic(let to, let c1, let c2): content += "\(pt(c1)) \(pt(c2)) \(pt(to)) c\n"
                        case .arc(let to, let center, let cw):
                            for c in Flattening.arcToCubics(from: cur, to: to, center: center, clockwise: cw) {
                                if case .cubic(let t, let c1, let c2) = c { content += "\(pt(c1)) \(pt(c2)) \(pt(t)) c\n" }
                            }
                        }
                        cur = seg.end
                    }
                    if p.isClosed { content += "h\n" }
                }
                content += "S\n"
            }
        }
        let body = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(n(page.width * page.scale)) \(n(page.height * page.scale))] /Contents 4 0 R /Resources << >> >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
            "<< /Creator (LoftLine) >>",
        ]
        var out = "%PDF-1.4\n", offsets: [Int] = []
        for (i, object) in body.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(body.count + 1)\n0000000000 65535 f \n"
        for o in offsets { out += String(format: "%010d 00000 n \n", o) }
        out += "trailer\n<< /Size \(body.count + 1) /Root 1 0 R /Info 5 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }
#endif
}

/// Encapsulated PostScript export (EPSF-3.0). Uses only moveto/lineto/curveto/closepath,
/// setrgbcolor and stroke, so any EPS reader (and LoftLine's own EPS importer) can open it.
public struct EPSExporter: VectorExporter {
    public static let fileExtension = "eps"
    public init() {}

    public func export(shapes: [Shape], layers: [Layer], units: LengthUnit) throws -> Data {
        let page = VectorPage(shapes: shapes, units: units)
        let w = page.width * page.scale, h = page.height * page.scale
        func n(_ v: Double) -> String {
            let s = String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), v)
            return s == "-0.0000" ? "0.0000" : s
        }
        func pt(_ p: Vec2) -> String { let (x, y) = page.point(p); return "\(n(x)) \(n(y))" }
        var out = """
        %!PS-Adobe-3.0 EPSF-3.0
        %%Creator: LoftLine
        %%BoundingBox: 0 0 \(Int(ceil(w))) \(Int(ceil(h)))
        %%HiResBoundingBox: 0 0 \(n(w)) \(n(h))
        %%Pages: 1
        %%EndComments
        gsave
        0.5 setlinewidth 1 setlinejoin

        """
        for (layer, group) in VectorPage.grouped(shapes, layers: layers) where layer.isVisible {
            let (r, g, b) = VectorPage.rgb(layer.colorHex)
            out += "% Layer: \(layer.name.filter { $0.isASCII && !$0.isNewline })\n"
            out += "\(n(r)) \(n(g)) \(n(b)) setrgbcolor\n"
            for s in group {
                out += "newpath\n"
                for p in s.paths where !p.segments.isEmpty {
                    out += "\(pt(p.start)) moveto\n"
                    var cur = p.start
                    for seg in p.segments {
                        switch seg {
                        case .line(let to): out += "\(pt(to)) lineto\n"
                        case .cubic(let to, let c1, let c2): out += "\(pt(c1)) \(pt(c2)) \(pt(to)) curveto\n"
                        case .arc(let to, let center, let cw):
                            for c in Flattening.arcToCubics(from: cur, to: to, center: center, clockwise: cw) {
                                if case .cubic(let t, let c1, let c2) = c { out += "\(pt(c1)) \(pt(c2)) \(pt(t)) curveto\n" }
                            }
                        }
                        cur = seg.end
                    }
                    if p.isClosed { out += "closepath\n" }
                }
                out += "stroke\n"
            }
        }
        out += "grestore\nshowpage\n%%EOF\n"
        return Data(out.utf8)
    }
}
