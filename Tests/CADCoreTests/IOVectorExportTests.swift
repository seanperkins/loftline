import Foundation
import Testing
@testable import CADCore

@Suite struct IOVectorExportTests {
    func design() -> ([Shape], [Layer]) {
        let red = Layer(name: "Cut", colorHex: "#FF0000")
        let square = Shape(name: "sq", layerID: red.id, paths: [ShapeFactory.rectangle(Rect2(x: 1, y: 1, width: 2, height: 1))])
        let circle = Shape(name: "c", layerID: red.id, paths: [ShapeFactory.circle(center: Vec2(5, 2), radius: 0.5)])
        return ([square, circle], [red])
    }

    @Test func pdfRoundTripsThroughTheImporter() throws {
        let (shapes, layers) = design()
        let data = try PDFExporter().export(shapes: shapes, layers: layers, units: .inch)
        #expect(data.starts(with: Data("%PDF".utf8)))
        let back = try PDFImporter().importVectors(from: data, targetUnits: .inch)
        #expect(back.shapes.count == 2)
        #expect(approx(back.shapes[0].bounds(), Rect2(x: 1, y: 1, width: 2, height: 1), 1e-4))
        #expect(approx(back.shapes[1].bounds(tolerance: 1e-5), Rect2(x: 4.5, y: 1.5, width: 1, height: 1), 2e-3))
        // .ai is written as PDF and read back through the AI (EPS) importer.
        let ai = try #require(FileFormats.exporter(forExtension: "AI")).export(shapes: shapes, layers: layers, units: .inch)
        #expect(try EPSImporter().importVectors(from: ai, targetUnits: .inch).shapes.count == 2)
    }

    @Test func epsRoundTripsInMillimetres() throws {
        let (inch, layers) = design()
        let shapes = inch.map { $0.transformed(.scale(25.4, 25.4)) }
        let data = try EPSExporter().export(shapes: shapes, layers: layers, units: .millimeter)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("%!PS-Adobe-3.0 EPSF-3.0"))
        #expect(text.contains("%%BoundingBox: 0 0 396 180"))
        #expect(text.contains("1.0000 0.0000 0.0000 setrgbcolor"))
        let back = try EPSImporter().importVectors(from: data, targetUnits: .millimeter)
        #expect(back.shapes.count == 2)
        #expect(approx(back.shapes[0].bounds(), Rect2(x: 25.4, y: 25.4, width: 50.8, height: 25.4), 1e-3))
        #expect(approx(back.shapes[1].bounds(tolerance: 1e-4), Rect2(x: 114.3, y: 38.1, width: 25.4, height: 25.4), 0.05))
    }

    @Test func registry() {
        #expect(FileFormats.exporter(forExtension: "pdf") is PDFExporter)
        #expect(FileFormats.exporter(forExtension: "eps") is EPSExporter)
        #expect(FileFormats.exporter(forExtension: "svg") is SVGExporter)
        #expect(FileFormats.exporter(forExtension: "png") == nil)
    }
}
