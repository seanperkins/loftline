import Foundation
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif
import Testing
@testable import CADCore

@Suite struct DrawingTraceTests {
    /// 30×30 white image with a black 10×10 square at (5,5) holding a 4×4 white hole, a 1-pixel
    /// speck, and two diagonal-touching pixels.
    func image() -> GrayBitmap {
        var px = [UInt8](repeating: 255, count: 900)
        for y in 5..<15 { for x in 5..<15 { px[y * 30 + x] = 0 } }
        for y in 8..<12 { for x in 8..<12 { px[y * 30 + x] = 255 } }
        px[25 * 30 + 25] = 0
        for y in 20..<24 { for x in 20..<24 { px[y * 30 + x] = 0 } }
        for y in 24..<28 { for x in 24..<28 { px[y * 30 + x] = 0 } }
        return GrayBitmap(width: 30, height: 30, pixels: px)
    }

    @Test func tracesSquareWithHoleAndDropsSpecks() {
        var o = BitmapTracer.Options()
        o.smoothing = 0
        o.minArea = 4
        let paths = BitmapTracer.trace(image(), options: o)
        // Square outline + hole + two diagonal blocks kept separate.
        #expect(paths.count == 4)
        let areas = paths.map { $0.signedArea() }.sorted()
        #expect(areas.contains(100) && areas.contains(-16))
        #expect(areas.filter { $0 == 16 }.count == 2)
        // y is flipped: the square (rows 5..15 from the top) sits at y 15..25.
        let sq = paths.first { $0.signedArea() == 100 }!.bounds()
        #expect(sq.min == Vec2(5, 15) && sq.max == Vec2(15, 25))
    }

    @Test func invertAndSmoothing() {
        var o = BitmapTracer.Options()
        o.invert = true
        let inverted = BitmapTracer.trace(image(), options: o)
        #expect(!inverted.isEmpty)
        let smooth = BitmapTracer.trace(image())
        // Smoothing softens the square's corners: slightly smaller area, still about 10×10.
        let big = smooth.max { abs($0.signedArea()) < abs($1.signedArea()) }!
        #expect(abs(big.signedArea()) < 100 && abs(big.signedArea()) > 98)
        #expect(big.segments.count > 4)
        // A pixel staircase (45° edge) becomes one straight edge instead of dozens of steps.
        var px = [UInt8](repeating: 255, count: 40 * 40)
        for y in 0..<40 { for x in 0..<40 where x < y { px[y * 40 + x] = 0 } }
        let tri = BitmapTracer.trace(GrayBitmap(width: 40, height: 40, pixels: px))
        #expect(tri.count == 1 && tri[0].segments.count < 12)
    }

    @Test func decodesPNG() throws {
        // 2×1 PNG: black then white pixel, generated through ImageIO.
        let data = try #require(Self.png(width: 2, height: 1, gray: [0, 255]))
        let img = try #require(GrayBitmap.decode(data))
        #expect(img.width == 2 && img.height == 1)
        #expect(img[0, 0] < 30 && img[1, 0] > 225)
    }

#if canImport(ImageIO)
    static func png(width: Int, height: Int, gray: [UInt8]) -> Data? {
        var px = gray
        guard let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let img = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
#else
    static func png(width: Int, height: Int, gray: [UInt8]) -> Data? {
        PortableImage(width: width, height: height, rgba: gray.flatMap { [$0, $0, $0, 255] }).png
    }
#endif
}
