#if !canImport(ImageIO)
import CStb
import Foundation

/// A decoded image off the Mac, where ImageIO is missing: stb_image reads PNG, JPEG, BMP and GIF (first frame).
public struct PortableImage: Sendable {
    public var width: Int
    public var height: Int
    /// RGBA, top row first.
    public var rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        self.width = width; self.height = height; self.rgba = rgba
    }

    public init?(data: Data) {
        var w: Int32 = 0, h: Int32 = 0
        let decoded: UnsafeMutablePointer<UInt8>? = data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress, raw.count <= Int(Int32.max) else { return nil }
            return cstb_image_load(base, Int32(raw.count), &w, &h)
        }
        guard let decoded, w > 0, h > 0 else { return nil }
        defer { cstb_free(decoded) }
        width = Int(w); height = Int(h)
        rgba = Array(UnsafeBufferPointer(start: decoded, count: width * height * 4))
    }

    public var png: Data? {
        var length: Int32 = 0
        let encoded = rgba.withUnsafeBufferPointer { cstb_png_encode($0.baseAddress, Int32(width), Int32(height), &length) }
        guard let encoded else { return nil }
        defer { cstb_free(encoded) }
        return Data(bytes: encoded, count: Int(length))
    }

    /// Grey values (0 = black), scaled so the longer side is at most `maxSide` by averaging; transparent areas count as white.
    /// Rec. 709 weights on the stored values. The Mac's result comes from Core Graphics' colour conversion and can differ by
    /// a few levels (docs/PLATFORMS.md).
    public func gray(maxSide: Int) -> (width: Int, height: Int, pixels: [UInt8]) {
        let scale = min(1, Double(maxSide) / Double(max(width, height)))
        let w = max(1, Int((Double(width) * scale).rounded())), h = max(1, Int((Double(height) * scale).rounded()))
        var out = [UInt8](repeating: 255, count: w * h)
        for y in 0..<h {
            let y0 = y * height / h, y1 = max(y0 + 1, (y + 1) * height / h)
            for x in 0..<w {
                let x0 = x * width / w, x1 = max(x0 + 1, (x + 1) * width / w)
                var sum = 0.0
                for sy in y0..<y1 {
                    for sx in x0..<x1 {
                        let i = (sy * width + sx) * 4
                        let a = Double(rgba[i + 3]) / 255
                        let v = 0.2126 * Double(rgba[i]) + 0.7152 * Double(rgba[i + 1]) + 0.0722 * Double(rgba[i + 2])
                        sum += v * a + 255 * (1 - a)
                    }
                }
                out[y * w + x] = UInt8(max(0, min(255, (sum / Double((x1 - x0) * (y1 - y0))).rounded())))
            }
        }
        return (w, h, out)
    }

    /// Dots per inch the file records: PNG `pHYs` or JPEG JFIF. Nil when it records none.
    public static func dpi(of data: Data) -> (x: Double, y: Double)? {
        let b = [UInt8](data)
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            var i = 8
            while i + 8 <= b.count {
                let n = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
                if b[i + 4] == 0x70, b[i + 5] == 0x48, b[i + 6] == 0x59, b[i + 7] == 0x73, n == 9, i + 17 <= b.count {
                    let px = Int(b[i + 8]) << 24 | Int(b[i + 9]) << 16 | Int(b[i + 10]) << 8 | Int(b[i + 11])
                    let py = Int(b[i + 12]) << 24 | Int(b[i + 13]) << 16 | Int(b[i + 14]) << 8 | Int(b[i + 15])
                    return b[i + 16] == 1 ? (Double(px) * 0.0254, Double(py) * 0.0254) : nil   // pixels per metre
                }
                i += 12 + n
            }
            return nil
        }
        if b.starts(with: [0xFF, 0xD8]), b.count > 18, b[6] == 0x4A, b[7] == 0x46, b[8] == 0x49, b[9] == 0x46 {
            let x = Double(Int(b[14]) << 8 | Int(b[15])), y = Double(Int(b[16]) << 8 | Int(b[17]))
            if b[13] == 1 { return (x, y) }
            if b[13] == 2 { return (x * 2.54, y * 2.54) }
        }
        return nil
    }
}
#endif
