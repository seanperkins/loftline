import Foundation
import Testing
@testable import CADCore

@Suite struct IOSVGTextImageTests {
    func svg(_ body: String) -> Data {
        Data("""
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
             width="4in" height="2in" viewBox="0 0 384 192">\(body)</svg>
        """.utf8)
    }

    @Test func textBecomesOutlinesAtTheBaseline() throws {
        // 96 px = 1 in em size, baseline at y = 144 px (0.5 in above the page bottom).
        let r = try SVGImporter().importVectors(
            from: svg("<text x=\"96\" y=\"144\" style=\"font-family:\(testFont); font-size:96px\">HI</text>"), targetUnits: .inch)
        let s = try #require(r.shapes.first)
        #expect(s.name == "HI")
        #expect(s.isClosed && s.paths.count >= 2)
        let b = s.bounds()
        #expect(abs(b.min.y - 0.5) < 0.02)        // glyphs sit on the baseline
        #expect(b.max.y > 1.1 && b.max.y < 1.3)   // Helvetica cap height ≈ 0.72 em
        #expect(b.min.x >= 0.99 && b.min.x < 1.15)
        #expect(r.warnings.isEmpty)
    }

    @Test func tspansAnchorsAndMissingFonts() throws {
        let r = try SVGImporter().importVectors(from: svg("""
            <g font-family="'No Such Font', sans-serif" font-size="48">
              <text x="192" y="96" text-anchor="middle">Mid</text>
              <text x="10" y="180"><tspan>A</tspan><tspan x="200" font-weight="bold">B</tspan></text>
              <text x="10" y="40" font-family="Definitely Missing">Z</text>
            </g>
            """), targetUnits: .inch)
        #expect(r.shapes.count == 3)
        let mid = r.shapes[0].bounds()
        #expect(abs(mid.center.x - 2) < 0.1)
        let ab = r.shapes[1]
        #expect(ab.name == "AB")
        #expect(ab.bounds().max.x > 200.0 / 96)
        #expect(r.warnings.contains { $0.contains("Definitely Missing") })
    }

    @Test func embeddedImagesAreReturned() throws {
        // 1x1 red PNG.
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="
        let r = try SVGImporter().importVectors(from: svg("""
            <image x="96" y="0" width="192" height="96" xlink:href="data:image/png;base64,\(png)"/>
            <image x="0" y="0" width="10" height="10" href="photo.jpg"/>
            """), targetUnits: .inch)
        #expect(r.images.count == 1)
        let img = try #require(r.images.first)
        #expect(abs(img.rect.min.x - 1) < 1e-9 && abs(img.rect.width - 2) < 1e-9)
        #expect(abs(img.rect.min.y - 1) < 1e-9 && abs(img.rect.height - 1) < 1e-9)
        #expect(r.warnings.contains { $0.contains("Linked") })
    }
}
