#if canImport(CoreGraphics)
// PDF import is Mac-only so far (docs/PLATFORMS.md).
import CoreGraphics
import Foundation
import Testing
@testable import CADCore

enum PDFFixture {
    /// A 4 x 3 in page: a stroked 1 in square at (1,1) in, a filled circle (r 0.5 in) at (3,1.5) in
    /// drawn under a translate, and optionally a 2x2 px image in the rect (0.5,2)–(1.5,2.5) in.
    static func make(withImage: Bool = false, clipOnly: Bool = false) -> Data {
        let out = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 288, height: 216)
        let consumer = CGDataConsumer(data: out as CFMutableData)!
        let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.stroke(CGRect(x: 72, y: 72, width: 72, height: 72))
        ctx.saveGState()
        ctx.translateBy(x: 216, y: 108)
        ctx.addEllipse(in: CGRect(x: -36, y: -36, width: 72, height: 72))
        ctx.fillPath()
        ctx.restoreGState()
        if clipOnly {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: 0, width: 10, height: 10))
            ctx.restoreGState()
        }
        if withImage {
            let px: [UInt8] = [255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255]
            let provider = CGDataProvider(data: Data(px) as CFData)!
            let img = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: 6,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            ctx.draw(img, in: CGRect(x: 36, y: 144, width: 72, height: 36))
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return out as Data
    }
}

@Suite struct IOPDFTests {
    @Test func importsStrokedAndFilledPathsInInches() throws {
        let r = try PDFImporter().importVectors(from: PDFFixture.make(), targetUnits: .inch)
        #expect(r.shapes.count == 2)
        #expect(r.layers.count == 1)
        let square = r.shapes[0]
        #expect(square.isClosed)
        #expect(approx(square.bounds(), Rect2(x: 1, y: 1, width: 1, height: 1), 1e-4))
        let circle = r.shapes[1]
        #expect(circle.isClosed)
        #expect(approx(circle.bounds(tolerance: 1e-5), Rect2(x: 2.5, y: 1, width: 1, height: 1), 2e-3))
    }

    @Test func millimetresAndClipPathsIgnored() throws {
        let r = try PDFImporter().importVectors(from: PDFFixture.make(clipOnly: true), targetUnits: .millimeter)
        #expect(r.shapes.count == 2)
        #expect(approx(r.shapes[0].bounds().width, 25.4, 1e-3))
    }

    @Test func pdfBasedAIGoesThroughEPSImporter() throws {
        let r = try EPSImporter().importVectors(from: PDFFixture.make(), targetUnits: .inch)
        #expect(r.shapes.count == 2)
        #expect(FileFormats.importer(forExtension: "pdf") is PDFImporter)
        #expect(FileFormats.importer(forExtension: "ai") is EPSImporter)
    }

    @Test func embeddedImagesAreReturnedWhenAsked() throws {
        let data = PDFFixture.make(withImage: true)
        let plain = try PDFImporter().importPage(from: data, targetUnits: .inch, includeImages: false)
        #expect(plain.images.isEmpty)
        #expect(plain.result.warnings.contains { $0.contains("image") })
        let r = try PDFImporter().importPage(from: data, targetUnits: .inch, includeImages: true)
        #expect(r.images.count == 1)
        let img = try #require(r.images.first)
        #expect(approx(img.rect, Rect2(x: 0.5, y: 2, width: 1, height: 0.5), 1e-4))
        #expect(RasterCodec.info(of: img.png)?.pixels.width == 2)
    }

    @Test func garbageThrows() {
        #expect(throws: LoftLineIOError.self) {
            try PDFImporter().importVectors(from: Data("%PDF-1.5\n".utf8), targetUnits: .inch)
        }
    }
}
#endif
