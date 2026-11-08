import AppKit
import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct IOPrintTests {
    @Test @MainActor func printViewSizesAndRenders() throws {
        let doc = LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
        let actual = DesignPrintView(document: doc.shownDocument, toolpaths: [], actualSize: true,
                                     pageSize: NSSize(width: 540, height: 720))
        #expect(actual.frame.size == NSSize(width: 24 * 72, height: 18 * 72))
        let fit = DesignPrintView(document: doc.shownDocument, toolpaths: [], actualSize: false,
                                  pageSize: NSSize(width: 540, height: 720))
        #expect(fit.frame.size == NSSize(width: 540, height: 720))
        // Render through the print machinery into PDF data (no panel).
        let data = NSMutableData()
        let op = NSPrintOperation.pdfOperation(with: fit, inside: fit.bounds, to: data)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        #expect(op.run())
        let back = try PDFImporter().importVectors(from: data as Data, targetUnits: .inch)
        #expect(back.shapes.count >= 3)  // material outline + two rectangles (+ origin marker)
    }
}
