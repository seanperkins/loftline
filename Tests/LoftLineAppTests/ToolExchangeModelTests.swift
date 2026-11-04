import CADCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Test func toolLibraryExportThenImportOnAnotherMachine() throws {
    let here = AppTestSupport.library()
    let mill = here.add(kind: .endMill)
    var edited = mill
    edited.name = "Shop 1/4 compression"
    edited.group = "Compression"
    here.update(edited)
    let file = AppTestSupport.tempDir().appendingPathComponent("shop.loftlinetools")
    try here.export(ids: [mill.id], to: file)

    let there = AppTestSupport.library()
    let (tools, conflicts) = try there.readImport(file)
    #expect(tools.count == 1 && conflicts.isEmpty)
    let report = there.importTools(tools, policy: .keepBoth)
    #expect(report.added == 1)
    #expect(there.library.tool(id: mill.id)?.group == "Compression")
    // Persisted to that machine's tools.json.
    #expect(try there.store.load().tool(id: mill.id)?.name == "Shop 1/4 compression")

    // Re-importing a changed copy reports the conflict.
    edited.feedRate = 321
    try ToolLibraryExchange.write([edited], to: file)
    #expect(try there.readImport(file).conflicts.count == 1)
    there.importTools([edited], policy: .replace)
    #expect(there.library.tool(id: mill.id)?.feedRate == 321)

    let csv = AppTestSupport.tempDir().appendingPathComponent("all.csv")
    try there.export(ids: nil, to: csv)
    #expect(try ToolLibraryExchange.read(csv).count == there.tools.count)
}
