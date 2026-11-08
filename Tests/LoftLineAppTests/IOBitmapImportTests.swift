import AppKit
import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

enum BitmapFixture {
    /// A w×h RGB PNG (red left half, blue right half), optionally tagged with a DPI.
    static func png(width: Int = 40, height: Int = 20, dpi: Double? = nil) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        let buf = rep.bitmapData!
        for x in 0..<width {
            for y in 0..<height {
                let o = y * rep.bytesPerRow + x * 4
                let red = x < width / 2
                buf[o] = red ? 255 : 0; buf[o + 1] = 0; buf[o + 2] = red ? 0 : 255; buf[o + 3] = 255
            }
        }
        if let dpi { rep.size = NSSize(width: Double(width) * 72 / dpi, height: Double(height) * 72 / dpi) }
        return rep.representation(using: .png, properties: [:])!
    }
}

@Suite struct IOBitmapImportTests {
    @Test func importsBitmapFittedToMaterial() throws {
        var p = LoftLineProject()
        let out = try ImportService.importFile(data: BitmapFixture.png(), fileName: "photo.png", into: &p)
        #expect(out.imageIDs.count == 1)
        #expect(out.shapeIDs.isEmpty && out.warnings.isEmpty)
        let img = try #require(p.document.placedImages.first)
        #expect(img.pixelWidth == 40 && img.pixelHeight == 20)
        // 24 x 18 material → 90% width = 21.6, height 10.8, centred.
        #expect(abs(img.rect.width - 21.6) < 1e-9 && abs(img.rect.height - 10.8) < 1e-9)
        #expect(abs(img.rect.center.x - 12) < 1e-9 && abs(img.rect.center.y - 9) < 1e-9)
        #expect(p.document.layer(id: img.layerID!)?.name == ImportService.bitmapLayerName)
        // A second image reuses the Bitmaps layer.
        _ = try ImportService.importFile(data: BitmapFixture.png(), fileName: "b.jpg", into: &p)
        #expect(p.document.layers.filter { $0.name == ImportService.bitmapLayerName }.count == 1)
    }

    @Test func usesRecordedDPI() throws {
        var p = LoftLineProject()
        _ = try ImportService.importFile(data: BitmapFixture.png(width: 200, height: 100, dpi: 100), fileName: "a.png", into: &p)
        let img = try #require(p.document.placedImages.first)
        #expect(abs(img.rect.width - 2) < 1e-6 && abs(img.rect.height - 1) < 1e-6)
    }

    @Test func undecodableBitmapThrows() {
        var p = LoftLineProject()
        #expect(throws: LoftLineIOError.self) {
            try ImportService.importFile(data: Data("nope".utf8), fileName: "x.png", into: &p)
        }
    }

    @Test func cropFadeAndFormRoundTrip() throws {
        var p = LoftLineProject()
        _ = try ImportService.importFile(data: BitmapFixture.png(), fileName: "photo.png", into: &p)
        let img = p.document.placedImages[0]
        var f = ImageEditForm(img)
        #expect(f.fadePercent == 40)
        f.cropLeft = 50
        f.fadePercent = 80
        f.setWidth(img.rect.width / 2)
        #expect(abs(f.height - img.rect.height / 2) < 1e-9)
        let edited = f.apply(to: img)
        #expect(abs(edited.opacity - 0.2) < 1e-9)
        #expect(abs(edited.crop.min.x - 0.5) < 1e-9)
        #expect(abs(edited.visibleRect.width - edited.rect.width / 2) < 1e-9)
        let px = edited.cropPixelRect
        #expect(px.x == 20 && px.width == 20 && px.y == 0 && px.height == 20)
        let cropped = try #require(PlacedImageRenderer.croppedImage(edited))
        #expect(cropped.width == 20)
    }

    @Test func documentsWithoutImagesDecodeAndUnitsConvert() throws {
        var p = LoftLineProject()
        let json = try p.encoded()
        #expect(!String(decoding: json, as: UTF8.self).contains("\"images\""))
        _ = try ImportService.importFile(data: BitmapFixture.png(), fileName: "photo.png", into: &p)
        let back = try LoftLineProject.decode(from: p.encoded())
        #expect(back.document.placedImages == p.document.placedImages)
        let mm = p.converted(to: .millimeter)
        #expect(abs(mm.document.placedImages[0].rect.width - 21.6 * 25.4) < 1e-6)
    }

    @Test func pdfImportBringsEmbeddedImages() throws {
        var p = LoftLineProject()
        let out = try ImportService.importFile(data: PDFAppFixture.withImage(), fileName: "art.pdf", into: &p)
        #expect(out.shapeIDs.count == 1)
        #expect(out.imageIDs.count == 1)
    }

    @Test @MainActor func canvasDrawsImage() throws {
        var p = LoftLineProject()
        _ = try ImportService.importFile(data: BitmapFixture.png(), fileName: "photo.png", into: &p)
        p.document.placedImages[0].opacity = 1
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        let view = CanvasNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 450))
        view.document = doc
        view.layout()
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        var reds = 0, blues = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 9) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 9) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent > 0.8 && c.blueComponent < 0.3 && c.greenComponent < 0.3 { reds += 1 }
                if c.blueComponent > 0.7 && c.redComponent < 0.3 { blues += 1 }
            }
        }
        #expect(reds > 10 && blues > 10)
    }
}

enum PDFAppFixture {
    static func withImage() -> Data {
        let out = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 288, height: 216)
        let ctx = CGContext(consumer: CGDataConsumer(data: out as CFMutableData)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.stroke(CGRect(x: 72, y: 72, width: 72, height: 72))
        let img = RasterCodec.cgImage(from: BitmapFixture.png())!
        ctx.draw(img, in: CGRect(x: 36, y: 144, width: 72, height: 36))
        ctx.endPDFPage()
        ctx.closePDF()
        return out as Data
    }
}
