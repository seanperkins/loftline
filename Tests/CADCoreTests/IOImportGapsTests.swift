#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Testing
@testable import CADCore

/// SVG, EPS and PDF imports report open vectors whose ends nearly meet, like the DXF import does.
@Suite struct IOImportGapsTests {
    /// A 20 mm square drawn as an open polyline whose last side stops `gap` mm short of the start.
    func svg(gap: Double) -> Data {
        Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="40mm" height="40mm" viewBox="0 0 40 40">
          <polyline points="5,5 25,5 25,25 5,25 5,\(5 + gap)" fill="none" stroke="black"/>
        </svg>
        """.utf8)
    }

    @Test func svgReportsANearlyClosedOutline() throws {
        let r = try SVGImporter().importVectors(from: svg(gap: 0.2), targetUnits: .millimeter)
        #expect(r.shapes.count == 1 && !r.shapes[0].isClosed)
        #expect(r.warnings == [
            "Layer \"SVG Import\": 1 open vector has ends that nearly meet, 0.2 mm apart; a gap in the source drawing is the usual cause. Arrange ▸ Join Open Vectors… closes it.",
        ])
        // The same drawing read into an inch document reports the gap in inches.
        let inch = try SVGImporter().importVectors(from: svg(gap: 0.2), targetUnits: .inch)
        #expect(inch.warnings.first?.contains("0.0079 in apart") == true)
    }

    @Test func svgStaysQuietForClosedShapesAndLoneLines() throws {
        // Closed: no gap. Wide open (5 mm, beyond 100 x the tolerance): a line, not a slip.
        #expect(try SVGImporter().importVectors(from: svg(gap: 0), targetUnits: .millimeter).warnings.isEmpty)
        #expect(try SVGImporter().importVectors(from: svg(gap: 5), targetUnits: .millimeter).warnings.isEmpty)
        for name in ["inkscape-mm.svg", "paths-px.svg", "illustrator-pt.svg"] {
            let r = try SVGImporter().importVectors(from: IOFixtures.data(name), targetUnits: .inch)
            #expect(!r.warnings.contains { $0.contains("nearly meet") }, Comment(rawValue: name))
        }
    }

    @Test func epsReportsANearlyClosedOutline() throws {
        let eps = """
        %!PS-Adobe-3.0 EPSF-3.0
        %%BoundingBox: 0 0 144 144
        newpath 36 36 moveto 108 36 lineto 108 108 lineto 36 108 lineto 36 36.5 lineto stroke
        showpage
        """
        let r = try EPSImporter().importVectors(from: Data(eps.utf8), targetUnits: .inch)
        #expect(r.shapes.count == 1)
        // 0.5 pt short = 0.0069 in.
        #expect(r.warnings.count == 1)
        #expect(r.warnings.first?.hasPrefix("Layer \"EPS Import\": 1 open vector has ends that nearly meet, 0.0069 in apart") == true)
        #expect(try EPSImporter().importVectors(from: IOFixtures.data("simple.eps"), targetUnits: .inch).warnings.isEmpty)
    }

#if canImport(CoreGraphics)
    @Test func pdfReportsANearlyClosedOutline() throws {
        let out = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 288, height: 216)
        let consumer = CGDataConsumer(data: out as CFMutableData)!
        let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.move(to: CGPoint(x: 72, y: 72))
        ctx.addLine(to: CGPoint(x: 144, y: 72))
        ctx.addLine(to: CGPoint(x: 144, y: 144))
        ctx.addLine(to: CGPoint(x: 72, y: 144))
        ctx.addLine(to: CGPoint(x: 72, y: 72.5))
        ctx.strokePath()
        ctx.endPDFPage()
        ctx.closePDF()
        let r = try PDFImporter().importVectors(from: out as Data, targetUnits: .inch)
        #expect(r.shapes.count == 1)
        #expect(r.warnings.contains { $0.hasPrefix("Layer \"PDF Import\": 1 open vector has ends that nearly meet, 0.0069 in apart") })
    }
#endif
}
