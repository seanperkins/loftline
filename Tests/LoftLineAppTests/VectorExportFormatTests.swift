import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct VectorExportFormatTests {
    @Test func offersEveryFormatTheExporterChoosesByExtension() {
        #expect(VectorExportFormat.allCases.map(\.fileExtension) == ["svg", "dxf", "pdf", "eps", "ai"])
        #expect(Set(VectorExportFormat.allCases.map(\.title)).count == VectorExportFormat.allCases.count)
    }

    @Test func switchingFormatReplacesTheExtensionOfTheFileName() {
        #expect(VectorExportFormat.dxf.fileName(from: "Sign.svg") == "Sign.dxf")
        #expect(VectorExportFormat.pdf.fileName(from: "Sign.DXF") == "Sign.pdf")
    }

    @Test func aNameWithoutAVectorExtensionGetsOne() {
        #expect(VectorExportFormat.svg.fileName(from: "Sign") == "Sign.svg")
        // A dot that is not a vector extension belongs to the name.
        #expect(VectorExportFormat.eps.fileName(from: "Bracket v2.1") == "Bracket v2.1.eps")
    }

    @Test func theFormatOfAFileNameIsRecovered() {
        #expect(VectorExportFormat(fileName: "plate.dxf") == .dxf)
        #expect(VectorExportFormat(fileName: "plate.AI") == .ai)
        #expect(VectorExportFormat(fileName: "plate.txt") == nil)
    }
}
