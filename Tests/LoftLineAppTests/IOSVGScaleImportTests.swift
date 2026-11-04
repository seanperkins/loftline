import CADCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// File > Import of an SVG that does not state its size asks for the scale first, with the one the file's
/// program uses selected; a file that states its size imports at once.
@MainActor
@Suite struct IOSVGScaleImportTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/CADCore")

    func document() -> LoftLineDocument {
        LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
    }

    func url(_ name: String) -> URL { Self.fixtures.appendingPathComponent(name) }
    func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-4) -> Bool { abs(a - b) <= tolerance }

    /// The shapes imported by name, newest first (the document starts with two rectangles).
    func square(in doc: LoftLineDocument) -> Shape? { doc.project.document.shapes.last { $0.name == "square" } }

    func asked(_ doc: LoftLineDocument) -> SVGScaleRequest? {
        if case .io(.svgScale(let request))? = doc.sheet { return request }
        return nil
    }

    @Test func aFileThatStatesItsSizeIsNotAsked() throws {
        for name in ["inkscape-1x-mm.svg", "coreldraw-in.svg", "inkscape-mm.svg", "outline-with-gap.dxf"] {
            let data = try Data(contentsOf: url(name))
            #expect(ImportService.scaleRequest(data: data, fileName: name, units: .inch) == nil, Comment(rawValue: name))
        }
    }

    @Test func aSizelessFileIsAskedWithItsProgramsScaleSelected() throws {
        let ai = try #require(ImportService.scaleRequest(data: Data(contentsOf: url("illustrator-px.svg")),
                                                          fileName: "illustrator-px.svg", units: .inch))
        #expect(ai.guess.pixelsPerInch == 72 && ai.guess.generator == "Adobe Illustrator")
        let plain = try #require(ImportService.scaleRequest(data: Data(contentsOf: url("paths-px.svg")),
                                                             fileName: "paths-px.svg", units: .inch))
        #expect(plain.guess.pixelsPerInch == 96 && plain.guess.generator == nil)
        #expect(SVGScaleRequest.choices.contains(72) && SVGScaleRequest.choices.contains(90) && SVGScaleRequest.choices.contains(96))
    }

    @Test func theSheetShowsTheSizeTheChoiceGivesAndNothingIsImportedYet() throws {
        let doc = document()
        let before = doc.project.document.shapes.count
        doc.importFiles([url("illustrator-px.svg")])
        let ask = try #require(asked(doc))
        #expect(doc.project.document.shapes.count == before)
        // The drawing is a 216 px square: 3 in at 72 per inch, 2.25 in at 96.
        let sizes = ask.drawingSizes()
        #expect(Set(sizes.keys) == Set(SVGScaleRequest.choices))
        let at72 = try #require(sizes[72]), at90 = try #require(sizes[90]), at96 = try #require(sizes[96])
        #expect(close(at72.x, 3) && close(at72.y, 3))
        #expect(close(at90.x, 2.4) && close(at96.x, 2.25) && close(at96.y, 2.25))
    }

    @Test func confirmingTheScaleImportsAtItWithOneUndoStepAndNoQuestions() throws {
        let doc = document()
        doc.importFiles([url("illustrator-px.svg")])
        let ask = try #require(asked(doc))
        doc.importSVG(ask, pixelsPerInch: 90)
        let s = try #require(square(in: doc))
        #expect(close(s.bounds().width, 216.0 / 90, 1e-4))
        #expect(s.origin == .imported(format: "svg", pixelsPerInch: 90))
        #expect(doc.selection == [s.id])
        // The user chose, so the importer has no guess to report.
        #expect(doc.alert == nil && doc.deferredAlert == nil)
    }

    @Test func cancellingImportsNothingAndTheNextFileIsAsked() throws {
        let doc = document()
        let before = doc.project.document.shapes.count
        doc.importFiles([url("illustrator-px.svg"), url("inkscape-091-px.svg")])
        #expect(asked(doc)?.fileName == "illustrator-px.svg")
        doc.sheet = nil          // Cancel
        doc.sheetDismissed()
        #expect(asked(doc)?.fileName == "inkscape-091-px.svg")
        #expect(asked(doc)?.guess.pixelsPerInch == 90)
        doc.sheet = nil
        doc.sheetDismissed()
        #expect(doc.sheet == nil && doc.project.document.shapes.count == before)
    }

    @Test func aFileThatStatesItsSizeImportsAtOnceBesideAQueuedOne() throws {
        let doc = document()
        doc.importFiles([url("illustrator-px.svg"), url("inkscape-1x-mm.svg")])
        #expect(asked(doc)?.fileName == "illustrator-px.svg")
        let s = try #require(square(in: doc))
        #expect(close(s.bounds().width, 3, 1e-4))      // the millimetre file, already in
        #expect(s.origin == .imported(format: "svg"))
    }

    @Test func everyScaleTheImporterGuessesIsOneTheSheetOffers() throws {
        for name in ["illustrator-px.svg", "inkscape-091-px.svg", "paths-px.svg"] {
            let guess = try #require(try SVGImporter.scaleGuess(of: Data(contentsOf: url(name))))
            #expect(SVGScaleRequest.choices.contains(guess.pixelsPerInch), Comment(rawValue: name))
        }
    }

    @Test func aFileWithNothingToMeasureSaysSoRatherThanGuessing() throws {
        let empty = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>"#.utf8)
        let ask = try #require(ImportService.scaleRequest(data: empty, fileName: "empty.svg", units: .inch))
        #expect(ask.drawingSizes().isEmpty)
    }

    @Test func theSizeShownCountsEmbeddedImagesToo() throws {
        // A 96 px square and a 96 px wide picture 96 px to its right: 3 in wide at 96 per inch, and an
        // image-only file still has a size.
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="
        let image = #"<image x="192" y="0" width="96" height="96" href="data:image/png;base64,\#(png)"/>"#
        let both = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="288" height="96"><rect width="96" height="96"/>\#(image)</svg>"#.utf8)
        let ask = try #require(ImportService.scaleRequest(data: both, fileName: "both.svg", units: .inch))
        let at96 = try #require(ask.drawingSizes()[96])
        #expect(close(at96.x, 3) && close(at96.y, 1))
        let only = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="288" height="96">\#(image)</svg>"#.utf8)
        let imageOnly = try #require(ImportService.scaleRequest(data: only, fileName: "only.svg", units: .inch))
        let size = try #require(imageOnly.drawingSizes()[96])
        #expect(close(size.x, 1) && close(size.y, 1))
    }
}
