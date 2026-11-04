import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Test func toolGroupingListsNamedGroupsBeforeTypes() {
    var tools = ToolLibrary.seeded.tools
    tools[0].group = "Favourites"
    tools[1].group = "Compression/Up-Down"
    tools[2].materials = [MaterialCuttingData(material: "Plywood", from: tools[2])]
    tools[3].materials = [MaterialCuttingData(material: "plywood", from: tools[3]),
                          MaterialCuttingData(material: "Acrylic", from: tools[3])]
    let sections = ToolGrouping.sections(tools)
    #expect(sections.prefix(2).map(\.title) == ["Compression › Up-Down", "Favourites"])
    #expect(sections[1].tools.map(\.id) == [tools[0].id])
    #expect(!sections.contains { $0.tools.isEmpty })
    #expect(sections.flatMap(\.tools).count == tools.count)
    #expect(ToolGrouping.materialNames(tools) == ["Acrylic", "Plywood"])
}

@Test func toolOverrideScalesWithDocumentUnits() {
    var setup = OperationSetup(name: "P", toolID: UUID())
    setup.toolOverride = ToolOverride(spindleRPM: 12000, feedRate: 100, stepdown: 0.1)
    let op = AnyOperation.profile(ProfileOperation(setup: setup)).scaled(by: 25.4)
    #expect(op.setup.toolOverride?.spindleRPM == 12000)
    #expect(abs((op.setup.toolOverride?.feedRate ?? 0) - 2540) < 1e-9)
    #expect(abs((op.setup.toolOverride?.stepdown ?? 0) - 2.54) < 1e-9)
}
