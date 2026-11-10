import CADCore
import CAMCore
import Foundation
import LoftLineKit
import PostCore

/// A picture of the 2D design for an assistant: the material, the vectors in their layer colours, the toolpaths' cuts, the clamps
/// and screws (filled and hatched) and the XY origin. Drawn into its own pixel buffer, the same on every platform, and encoded
/// with `RasterCodec` (MCP spec, "The picture").
public enum DesignPreview {
    public struct RGB: Equatable { public var r, g, b: UInt8 }

    public static let background = RGB(r: 255, g: 255, b: 255)
    public static let materialColor = RGB(r: 0xF3, g: 0xE7, b: 0xCF)
    public static let materialEdge = RGB(r: 0x55, g: 0x55, b: 0x55)
    public static let toolpathColor = RGB(r: 0x2B, g: 0x6C, b: 0xB0)
    public static let clampFill = RGB(r: 0xF8, g: 0xD7, b: 0xD3)
    public static let clampLine = RGB(r: 0xB0, g: 0x00, b: 0x00)
    public static let originColor = RGB(r: 0xDD, g: 0x00, b: 0x00)
    public static let maxSide = 4_096, maxPixels = 8_000_000

    /// The pixels and how material coordinates map onto them.
    public struct Picture {
        public let width: Int, height: Int
        var pixels: [UInt8]
        let scale: Double, origin: Vec2   // pixel = (p - origin) * scale, Y flipped

        func pixel(_ p: Vec2) -> (x: Double, y: Double) {
            ((p.x - origin.x) * scale, Double(height) - (p.y - origin.y) * scale)
        }

        public func color(atMaterial p: Vec2) -> RGB {
            let q = pixel(p)
            let x = Int(q.x), y = Int(q.y)
            guard x >= 0, y >= 0, x < width, y < height else { return DesignPreview.background }
            let i = (y * width + x) * 3
            return RGB(r: pixels[i], g: pixels[i + 1], b: pixels[i + 2])
        }

        mutating func set(_ x: Int, _ y: Int, _ c: RGB) {
            guard x >= 0, y >= 0, x < width, y < height else { return }
            let i = (y * width + x) * 3
            pixels[i] = c.r; pixels[i + 1] = c.g; pixels[i + 2] = c.b
        }

        mutating func line(_ a: Vec2, _ b: Vec2, _ c: RGB) {
            let p = pixel(a), q = pixel(b)
            guard p.x.isFinite, p.y.isFinite, q.x.isFinite, q.y.isFinite else { return }
            var x0 = Int(p.x.rounded()), y0 = Int(p.y.rounded())
            let x1 = Int(q.x.rounded()), y1 = Int(q.y.rounded())
            guard abs(x1 - x0) < 4 * (width + height), abs(y1 - y0) < 4 * (width + height) else { return }
            let dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1, dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1
            var err = dx + dy
            while true {
                set(x0, y0, c)
                if x0 == x1 && y0 == y1 { break }
                let e2 = 2 * err
                if e2 >= dy { err += dy; x0 += sx }
                if e2 <= dx { err += dx; y0 += sy }
            }
        }

        /// Even-odd fill of closed loops; every `hatch`-th diagonal in `hatchColor` when given.
        mutating func fill(_ loops: [[Vec2]], _ c: RGB, hatch: Int = 0, hatchColor: RGB? = nil) {
            let edges = loops.flatMap { loop in loop.indices.map { (pixel(loop[$0]), pixel(loop[($0 + 1) % loop.count])) } }
            let ys = edges.flatMap { [$0.0.y, $0.1.y] }
            guard let lo = ys.min(), let hi = ys.max(), lo.isFinite, hi.isFinite, edges.allSatisfy({ $0.0.x.isFinite && $0.1.x.isFinite }) else { return }
            for y in max(0, Int(lo.rounded(.down)))...min(height - 1, Int(hi.rounded(.up))) where y >= 0 {
                let cy = Double(y) + 0.5
                var xs: [Double] = []
                for (a, b) in edges where (a.y > cy) != (b.y > cy) {
                    xs.append(a.x + (cy - a.y) / (b.y - a.y) * (b.x - a.x))
                }
                xs.sort()
                var i = 0
                while i + 1 < xs.count {
                    let from = max(0, Int((xs[i] - 0.5).rounded(.up))), to = min(width - 1, Int((xs[i + 1] - 0.5).rounded(.down)))
                    if from <= to {
                        for x in from...to {
                            set(x, y, hatch > 0 && (x + y) % hatch == 0 ? (hatchColor ?? c) : c)
                        }
                    }
                    i += 2
                }
            }
        }
    }

    public static func png(project: LoftLineProject, toolpaths: [Toolpath], width: Int, height: Int) throws -> Data {
        let picture = try render(project: project, toolpaths: toolpaths, width: width, height: height)
        guard let png = RasterCodec.png(width: picture.width, height: picture.height, samples: picture.pixels, components: 3) else {
            throw ToolError("The picture could not be encoded.")
        }
        return png
    }

    public static func render(project: LoftLineProject, toolpaths: [Toolpath], width: Int, height: Int) throws -> Picture {
        guard width >= 16, height >= 16, width <= maxSide, height <= maxSide, width * height <= maxPixels else {
            throw ToolError("A preview is 16 to \(maxSide) pixels a side and at most \(maxPixels) pixels; \(width) x \(height) is outside that.")
        }
        let doc = project.document, job = doc.job
        let material = Rect2(x: 0, y: 0, width: max(job.width, 1e-6), height: max(job.height, 1e-6))
        let clamps = ClampList.items(in: doc)
        let visible = doc.shapes.filter { project.isVisible($0) }
        var area = material
        for c in clamps { area = area.union(c.bounds) }
        for s in visible { area = area.union(s.bounds()) }
        let pad = max(area.width, area.height) * 0.04
        let scale = min(Double(width) / (area.width + 2 * pad), Double(height) / (area.height + 2 * pad))
        guard area.width.isFinite, area.height.isFinite, pad.isFinite, scale.isFinite, scale > 0 else {
            throw ToolError("The design reaches too far to draw (its coordinates are out of range).")
        }
        // Centre the drawing in the picture.
        let origin = Vec2(area.min.x - pad - (Double(width) / scale - area.width - 2 * pad) / 2,
                          area.min.y - pad - (Double(height) / scale - area.height - 2 * pad) / 2)
        var pic = Picture(width: width, height: height,
                          pixels: [UInt8](repeating: 255, count: width * height * 3), scale: scale, origin: origin)

        let corners = [material.min, Vec2(material.max.x, material.min.y), material.max, Vec2(material.min.x, material.max.y)]
        pic.fill([corners], materialColor)
        for (a, b) in zip(corners, corners.dropFirst() + [corners[0]]) { pic.line(a, b, materialEdge) }

        let tolerance = max(area.width, area.height) / Double(max(width, height)) / 2
        let colors = Dictionary(doc.layers.map { ($0.id, rgb(hex: $0.colorHex) ?? RGB(r: 0, g: 0, b: 0)) }, uniquingKeysWith: { a, _ in a })
        let keepOut = Fixtures.keepOutLayerIDs(in: doc)
        for shape in visible where !keepOut.contains(shape.layerID) {
            let c = colors[shape.layerID] ?? RGB(r: 0, g: 0, b: 0)
            for path in shape.paths {
                let pts = path.flattened(tolerance: tolerance)
                for (a, b) in zip(pts, pts.dropFirst()) { pic.line(a, b, c) }
                if path.isClosed, let f = pts.first, let l = pts.last { pic.line(l, f, c) }
            }
        }

        let coords = MachineCoordinates(job: job)
        for tp in toolpaths {
            var prev: Vec3?
            for m in tp.moves {
                guard let t = m.target else { continue }
                defer { prev = t }
                guard let from = prev, !m.isRapid else { continue }
                var pts: [Vec3] = [t]
                switch m {
                case .arcCW(_, let c, _), .arcCCW(_, let c, _):
                    var cw = false
                    if case .arcCW = m { cw = true }
                    pts = ArcGeometry.points(from: from, to: t, center: c, clockwise: cw, tolerance: tolerance)
                default: break
                }
                var a = coords.materialXY(fromMachine: from.xy)
                for q in pts {
                    let b = coords.materialXY(fromMachine: q.xy)
                    pic.line(a, b, toolpathColor)
                    a = b
                }
            }
        }

        let hatch = max(4, min(width, height) / 100)
        for c in clamps {
            pic.fill(c.loops, clampFill, hatch: hatch, hatchColor: clampLine)
            for loop in c.loops { for (a, b) in zip(loop, loop.dropFirst() + [loop[0]]) { pic.line(a, b, clampLine) } }
        }

        let o = job.originInMaterialFrame, arm = pad * 0.6
        pic.line(Vec2(o.x - arm, o.y), Vec2(o.x + arm, o.y), originColor)
        pic.line(Vec2(o.x, o.y - arm), Vec2(o.x, o.y + arm), originColor)
        return pic
    }

    static func rgb(hex: String) -> RGB? {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return RGB(r: UInt8(v >> 16 & 0xFF), g: UInt8(v >> 8 & 0xFF), b: UInt8(v & 0xFF))
    }
}

/// preview: the picture above, as an image the assistant can look at.
enum PreviewTool {
    static func all(service: CoreService) -> [AssistantTool] {
        let session = service.session
        return [AssistantTool(
            name: "preview",
            description: "A PNG picture of the 2D design: the material, the vectors, the toolpaths' cuts (blue), the clamps and screws "
                + "(red, hatched) and the XY origin. Use it to check a design before posting.",
            inputSchema: Schema.object([
                "width": Schema.integer("Pixels wide (default 1024, at most 4096)."),
                "height": Schema.integer("Pixels high (default 768, at most 4096; 8 million pixels in all)."),
                "show_toolpaths": Schema.boolean("Draw the toolpaths' cuts (default true); calculates them first."),
            ])) { raw in
                let args = Args(raw)
                let w = args.int("width") ?? 1024, h = args.int("height") ?? 768
                let toolpaths = args.raw["show_toolpaths"] == nil || args.bool("show_toolpaths") ? session.previewToolpaths(groupByTool: false) : []
                let png = try DesignPreview.png(project: session.project, toolpaths: toolpaths, width: w, height: h)
                return ToolOutput(text: "\(w)x\(h) picture of \"\(session.project.document.name)\".", image: png)
            }]
    }
}
