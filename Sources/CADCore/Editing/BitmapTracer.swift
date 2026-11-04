import Foundation
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

/// A grayscale raster (0 = black, 255 = white), rows top to bottom.
public struct GrayBitmap: Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width; self.height = height; self.pixels = pixels
    }

    public subscript(x: Int, y: Int) -> UInt8 { pixels[y * width + x] }

    /// Decodes PNG/JPEG/TIFF/… data, scaled so the longer side is at most `maxSide` pixels.
    /// Transparent areas count as white.
#if canImport(ImageIO)
    public static func decode(_ data: Data, maxSide: Int = 1000) -> GrayBitmap? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let scale = min(1, Double(maxSide) / Double(max(img.width, img.height)))
        let w = max(1, Int((Double(img.width) * scale).rounded())), h = max(1, Int((Double(img.height) * scale).rounded()))
        var px = [UInt8](repeating: 255, count: w * h)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? GrayBitmap(width: w, height: h, pixels: px) : nil
    }
#else
    public static func decode(_ data: Data, maxSide: Int = 1000) -> GrayBitmap? {
        guard let image = PortableImage(data: data) else { return nil }
        let g = image.gray(maxSide: maxSide)
        return GrayBitmap(width: g.width, height: g.height, pixels: g.pixels)
    }
#endif
}

/// Vectorises a bitmap by brightness threshold: pixels darker than the threshold (or lighter,
/// when inverted) become filled regions whose outlines are returned as closed paths.
public enum BitmapTracer {
    public struct Options: Sendable {
        /// 0…255: pixels darker than this are "ink".
        public var threshold: Int = 128
        public var invert = false
        /// Ink specks and holes smaller than this many pixels are dropped.
        public var minArea = 8
        /// Outline simplification in pixels (Douglas–Peucker).
        public var simplify = 0.8
        /// Corner rounding passes (0 = sharp pixel corners kept as simplified).
        public var smoothing = 2
        public init() {}
    }

    /// Outlines in pixel units with y up (origin at the image's lower-left corner).
    public static func trace(_ img: GrayBitmap, options o: Options = Options()) -> [Path] {
        var ink = img.pixels.map { o.invert ? Int($0) >= o.threshold : Int($0) < o.threshold }
        removeSmallComponents(&ink, img.width, img.height, value: true, minArea: o.minArea)
        removeSmallComponents(&ink, img.width, img.height, value: false, minArea: o.minArea)
        let loops = contours(ink, img.width, img.height)
        var out: [Path] = []
        for loop in loops {
            var pts = loop.map { Vec2(Double($0.x), Double(img.height - $0.y)) }
            // Simplifying the unit-step outline turns pixel staircases into straight or gently
            // curving edges while true corners stay put; smoothing then rounds what is left of
            // each corner by at most about a pixel per pass.
            pts = simplifyClosed(pts, tolerance: max(o.simplify, 0.01))
            for _ in 0..<max(0, o.smoothing) { pts = cutCorners(pts, maxCut: 0.6) }
            if pts.count >= 3 { out.append(Path(points: pts, closed: true)) }
        }
        return PathGeometry.normalizedOrientation(out)
    }

    // MARK: - Steps

    /// Flood-fills (4-connected) and flips components of `value` smaller than `minArea`.
    /// Background components touching the border are never filled.
    static func removeSmallComponents(_ m: inout [Bool], _ w: Int, _ h: Int, value: Bool, minArea: Int) {
        guard minArea > 1 else { return }
        var seen = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        for start in 0..<(w * h) where m[start] == value && !seen[start] {
            var comp: [Int] = []
            var touchesBorder = false
            stack.append(start); seen[start] = true
            while let i = stack.popLast() {
                comp.append(i)
                let x = i % w, y = i / w
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { touchesBorder = true }
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < w && ny < h {
                    let j = ny * w + nx
                    if !seen[j], m[j] == value { seen[j] = true; stack.append(j) }
                }
            }
            if comp.count < minArea, value || !touchesBorder { for i in comp { m[i] = !value } }
        }
    }

    struct Corner: Hashable { var x: Int; var y: Int }

    /// Pixel-edge ("crack") contours around ink regions, in image coordinates (y down).
    static func contours(_ m: [Bool], _ w: Int, _ h: Int) -> [[Corner]] {
        func ink(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && m[y * w + x] }
        // Directed edges with ink on the right (image y down), keyed by start corner.
        var edges: [Corner: [Corner]] = [:]
        for y in 0..<h {
            for x in 0..<w where m[y * w + x] {
                if !ink(x, y - 1) { edges[Corner(x: x, y: y), default: []].append(Corner(x: x + 1, y: y)) }
                if !ink(x + 1, y) { edges[Corner(x: x + 1, y: y), default: []].append(Corner(x: x + 1, y: y + 1)) }
                if !ink(x, y + 1) { edges[Corner(x: x + 1, y: y + 1), default: []].append(Corner(x: x, y: y + 1)) }
                if !ink(x - 1, y) { edges[Corner(x: x, y: y + 1), default: []].append(Corner(x: x, y: y)) }
            }
        }
        var loops: [[Corner]] = []
        let starts = edges.keys.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
        for s in starts {
            while let first = edges[s]?.first {
                var loop = [s]
                var prev = s, cur = first
                remove(&edges, s, first)
                while cur != s {
                    loop.append(cur)
                    guard let options = edges[cur], !options.isEmpty else { break }
                    // At a saddle, turn so diagonal ink pixels stay separate.
                    let dIn = (cur.x - prev.x, cur.y - prev.y)
                    let next = options.count == 1 ? options[0] : options.first {
                        let dOut = ($0.x - cur.x, $0.y - cur.y)
                        return dIn.0 * dOut.1 - dIn.1 * dOut.0 > 0
                    } ?? options[0]
                    remove(&edges, cur, next)
                    prev = cur; cur = next
                }
                if loop.count >= 4 { loops.append(loop) }
            }
        }
        return loops
    }

    private static func remove(_ e: inout [Corner: [Corner]], _ a: Corner, _ b: Corner) {
        guard var l = e[a], let i = l.firstIndex(of: b) else { return }
        l.remove(at: i)
        e[a] = l.isEmpty ? nil : l
    }

    /// Douglas–Peucker on a closed polygon (split at the two farthest-apart points).
    static func simplifyClosed(_ pts: [Vec2], tolerance: Double) -> [Vec2] {
        guard pts.count > 4 else { return pts }
        var far = 0, best = 0.0
        for (i, p) in pts.enumerated() where p.distance(to: pts[0]) > best { best = p.distance(to: pts[0]); far = i }
        let a = dp(Array(pts[0...far]), tolerance), b = dp(Array(pts[far...]) + [pts[0]], tolerance)
        return Array(a.dropLast()) + Array(b.dropLast())
    }

    /// Douglas–Peucker simplification of an open polyline (ends kept).
    public static func simplifyPolyline(_ pts: [Vec2], tolerance: Double) -> [Vec2] { dp(pts, tolerance) }

    static func dp(_ pts: [Vec2], _ tol: Double) -> [Vec2] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true; keep[pts.count - 1] = true
        var stack = [(0, pts.count - 1)]
        while let (s, e) = stack.popLast() {
            guard e > s + 1 else { continue }
            var idx = s, dmax = 0.0
            for i in (s + 1)..<e {
                let d = VectorValidator.segmentDistance(pts[i], pts[s], pts[e])
                if d > dmax { dmax = d; idx = i }
            }
            if dmax > tol { keep[idx] = true; stack.append((s, idx)); stack.append((idx, e)) }
        }
        return pts.indices.filter { keep[$0] }.map { pts[$0] }
    }

    /// Chaikin-style corner cutting with the cut limited to `maxCut` along each edge, so long
    /// straight edges keep their position.
    static func cutCorners(_ pts: [Vec2], maxCut: Double) -> [Vec2] {
        let n = pts.count
        guard n >= 3 else { return pts }
        var out: [Vec2] = []
        out.reserveCapacity(n * 2)
        for i in 0..<n {
            let a = pts[i], b = pts[(i + 1) % n]
            let len = a.distance(to: b)
            guard len > 1e-12 else { continue }
            let cut = min(0.25, maxCut / len)
            out.append(a.lerp(to: b, cut)); out.append(a.lerp(to: b, 1 - cut))
        }
        return out
    }
}
