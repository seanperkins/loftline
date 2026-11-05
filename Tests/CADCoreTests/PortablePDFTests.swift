import Foundation
import Testing
@testable import CADCore
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The PDF reader used off the Mac. On the Mac it is held to Core Graphics' result on files Core Graphics itself wrote (compressed
/// streams, its own object layout); those files are committed, so Linux and Windows read the same bytes.
@Suite struct PortablePDFTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures-pdf")
    static func fixture(_ name: String) throws -> Data { try Data(contentsOf: folder.appendingPathComponent(name)) }

    #if canImport(CoreGraphics)
    /// Writes the fixtures when LOFTLINE_WRITE_SAMPLES=1, and otherwise checks them against what Core Graphics reads.
    static func quartzDocument() -> Data {
        let out = NSMutableData()
        var box = CGRect(x: 10, y: 20, width: 288, height: 216)
        let ctx = CGContext(consumer: CGDataConsumer(data: out as CFMutableData)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.stroke(CGRect(x: 72, y: 72, width: 72, height: 72))
        ctx.saveGState()
        ctx.translateBy(x: 200, y: 100)
        ctx.rotate(by: .pi / 6)
        ctx.addEllipse(in: CGRect(x: -36, y: -36, width: 72, height: 48))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.move(to: CGPoint(x: 20, y: 30)); ctx.addLine(to: CGPoint(x: 60, y: 40)); ctx.addCurve(to: CGPoint(x: 90, y: 30), control1: CGPoint(x: 70, y: 60), control2: CGPoint(x: 80, y: 60))
        ctx.strokePath()
        ctx.endPDFPage()
        ctx.beginPDFPage(nil)
        ctx.stroke(CGRect(x: 1, y: 1, width: 2, height: 2))
        ctx.endPDFPage()
        ctx.closePDF()
        return out as Data
    }

    @Test func matchesCoreGraphicsOnAFileItWrote() throws {
        if ProcessInfo.processInfo.environment["LOFTLINE_WRITE_SAMPLES"] == "1" {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try Self.quartzDocument().write(to: Self.folder.appendingPathComponent("quartz.pdf"))
        }
        let data = try Self.fixture("quartz.pdf")
        let (mac, _) = try PDFImporter().importPage(from: data, targetUnits: .inch, includeImages: true)
        let (ours, _) = try PortablePDFImporter.importPage(from: data, targetUnits: .inch, includeImages: true)
        #expect(ours.shapes.count == mac.shapes.count)
        #expect(ours.warnings == mac.warnings)
        for (a, b) in zip(ours.shapes, mac.shapes) {
            #expect(a.paths.count == b.paths.count)
            let x = a.bounds(tolerance: 1e-4), y = b.bounds(tolerance: 1e-4)
            #expect(abs(x.min.x - y.min.x) < 1e-6 && abs(x.min.y - y.min.y) < 1e-6 && abs(x.max.x - y.max.x) < 1e-6 && abs(x.max.y - y.max.y) < 1e-6)
            #expect(a.isClosed == b.isClosed)
        }
    }
    #endif

    @Test func readsACompressedFileWrittenByQuartz() throws {
        let r = try PDFImporter().importVectors(from: Self.fixture("quartz.pdf"), targetUnits: .inch)
        #expect(r.shapes.count == 3)
        #expect(r.warnings.contains { $0.contains("Only page 1 of 2") })
        // The square at 72, 72 on a page whose box starts at 10, 20.
        let square = r.shapes[0].bounds()
        #expect(abs(square.min.x - 62.0 / 72) < 1e-6 && abs(square.min.y - 52.0 / 72) < 1e-6 && abs(square.width - 1) < 1e-6)
        #expect(r.shapes[0].isClosed)
        #expect(!r.shapes[2].isClosed)
    }

    @Test func aDamagedOrHostileFileIsAnErrorNotACrash() throws {
        for text in ["", "not a pdf", "%PDF-1.7\n"] {
            #expect(throws: (any Error).self) { try PortablePDFImporter.importPage(from: Data(text.utf8), targetUnits: .inch, includeImages: true) }
        }
        // A cycle, a stream with no end and brackets that never close end the read, one way or another, without a crash or a hang.
        for text in ["%PDF-1.7\n1 0 obj\n<< /Type /Catalog /Pages 1 0 R >>\nendobj\n", "%PDF-1.7\n1 0 obj\n<< /Length 99999 >>\nstream\nabc",
                     "%PDF-1.7\n1 0 obj [[[[[[ endobj", "%PDF-1.7\n1 0 obj 1 0 R endobj\n2 0 obj << /Type /Catalog /Pages 1 0 R >> endobj"] {
            _ = try? PortablePDFImporter.importPage(from: Data(text.utf8), targetUnits: .inch, includeImages: true)
        }
        let encrypted = "%PDF-1.7\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n2 0 obj << /Kids [] >> endobj\ntrailer << /Encrypt 3 0 R >>"
        #expect(throws: (any Error).self) { try PortablePDFImporter.importPage(from: Data(encrypted.utf8), targetUnits: .inch, includeImages: true) }
    }

    /// A one-page file whose page holds `content`, with `extra` as more objects.
    static func document(content: String, streamDictionary: String? = nil, extra: String = "") -> Data {
        let dictionary = streamDictionary ?? "<< /Length \(content.utf8.count) >>"
        return Data("""
        %PDF-1.7
        1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
        2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
        3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R >> endobj
        4 0 obj \(dictionary)
        stream
        \(content)
        endstream
        endobj
        \(extra)
        trailer << /Root 1 0 R >>
        """.utf8)
    }

    static let square = "10 10 m 100 10 l 100 100 l 10 100 l h S"

    @Test(arguments: ["9223372036854775808", "1e300", "-1"])
    func aStreamLengthNoIntegerCanHoldIsIgnored(length: String) throws {
        let data = Self.document(content: Self.square, streamDictionary: "<< /Length \(length) >>")
        let (result, _) = try PortablePDFImporter.importPage(from: data, targetUnits: .inch, includeImages: true)
        #expect(result.shapes.count == 1)
    }

    @Test(arguments: [("9223372036854775808", "0"), ("1e300", "0"), ("-1", "0"), ("1", "9223372036854775808"), ("1", "-5")])
    func anObjectStreamWithAHostileHeaderIsSkipped(count: String, first: String) throws {
        let extra = "5 0 obj << /Type /ObjStm /N \(count) /First \(first) /Length 4 >>\nstream\n6 0 \nendstream\nendobj"
        let (result, _) = try PortablePDFImporter.importPage(from: Self.document(content: Self.square, extra: extra), targetUnits: .inch, includeImages: true)
        #expect(result.shapes.count == 1)
    }

    @Test func anInlineImageWhoseBytesSpellItsEndMarkerDoesNotEatThePage() throws {
        let content = "BI /W 1 /H 1 /CS /G /BPC 8 ID EI(\nEI\n" + Self.square
        let (result, _) = try PortablePDFImporter.importPage(from: Self.document(content: content), targetUnits: .inch, includeImages: true)
        #expect(result.shapes.count == 1)
    }

    @Test func inflateReadsStoredAndCompressedBlocks() throws {
        // zlib of "hello hello hello hello", made with Python's zlib.compress.
        let compressed: [UInt8] = [120, 156, 203, 72, 205, 201, 201, 87, 200, 64, 39, 1, 104, 3, 8, 177]
        #expect(Inflate.zlib(compressed).map { String(decoding: $0, as: UTF8.self) } == "hello hello hello hello")
        #expect(Inflate.zlib([0x78, 0x9c, 0xff, 0xff]) == nil)
        #expect(Inflate.zlib([]) == nil)
    }
}
