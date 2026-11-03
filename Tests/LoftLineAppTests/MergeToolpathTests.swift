import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineApp

private let lib = ToolLibrary.seeded

/// Pocket on the first rectangle (with a 1/2" clearance tool), profile on the second, both 1/4".
private func project() -> LoftLineProject {
    var p = AppTestSupport.project()
    let ids = p.document.shapes.map(\.id)
    var pocket = PocketParameters(depth: DepthSettings(cutDepth: 0.1))
    pocket.clearanceToolIDs = [lib.tools[2].id]
    p.upsertOperation(.pocket(PocketOperation(setup: OperationSetup(name: "Pocket", toolID: lib.tools[0].id, shapeIDs: [ids[0]]),
                                              params: pocket)))
    p.upsertOperation(.profile(ProfileOperation(setup: OperationSetup(name: "Cut", toolID: lib.tools[0].id, shapeIDs: [ids[1]]),
                                                params: ProfileParameters(depth: DepthSettings(cutDepth: 0.2)))))
    p.upsertOperation(.drill(DrillOperation(setup: OperationSetup(name: "Drill", toolID: lib.tools[8].id, shapeIDs: [ids[1]]))))
    return p
}

@Test func mergeJoinsSameToolToolpathsInOrder() throws {
    var p = project()
    let ctx = CAMContext(document: p.document, tools: lib)
    let before = try p.operations[0].generate(in: ctx) + p.operations[1].generate(in: ctx)
    #expect(p.mergeWithNextProblem(p.operations[0].id) == nil)
    #expect(p.mergeWithNextProblem(p.operations[1].id) != nil) // drill uses another tool
    let merged = p.mergeWithNext(p.operations[0].id)
    let id = try #require(merged)
    #expect(p.operations.count == 2)
    #expect(p.operations[0].id == id && p.operations[0].kind == .merge)
    #expect(p.operations[0].setup.name == "Pocket + Cut")
    let tps = try p.operations[0].generate(in: ctx)
    // Clearance (1/2") stays separate; the 1/4" pocket finish and the profile become one toolpath.
    #expect(tps.map(\.tool.id) == [lib.tools[2].id, lib.tools[0].id])
    #expect(tps[1].moves == before[1].moves + before[2].moves)
    #expect(tps[1].kind == .profile) // keeps the profile ordering protection
    #expect(tps.allSatisfy { $0.operationID == id && $0.name == "Pocket + Cut" })
    // Round trip through the file format, then split back.
    let back = try LoftLineProject.decode(from: p.encoded())
    #expect(back == p)
    p.splitMerged(id)
    #expect(p.operations.map(\.setup.name) == ["Pocket", "Cut", "Drill"])
}

@Test func mergeTemplateStoresTheParts() {
    var p = project()
    p.mergeWithNext(p.operations[0].id)
    let t = ToolpathTemplate.make(from: p, library: lib)
    #expect(t.entries.map(\.operation.setup.name) == ["Pocket", "Cut", "Drill"])
}

@Test func splittingATurnedOffMergeLeavesItsPartsOff() throws {
    // The parts of a merge are always on (only the merge is cut or not); splitting a merge that is off must not turn
    // every part back on.
    var p = project()
    let merged = p.mergeWithNext(p.operations[0].id)
    let id = try #require(merged)
    p.operations[0].editableSetup.isEnabled = false
    p.splitMerged(id)
    #expect(p.operations.map(\.setup.isEnabled) == [false, false, true])
}

@Test func aTemplateFromAMergeKeepsItsPauseAndOnOff() {
    // A template stores a merge as its parts, so the merge's pause goes on the last part (as Split does) and a merge
    // that is off stays off.
    var p = project()
    let merged = p.mergeWithNext(p.operations[0].id)
    #expect(merged != nil)
    p.operations[0].editableSetup.pauseAfter = PauseStep(message: "Flip")
    p.operations[0].editableSetup.isEnabled = false
    let t = ToolpathTemplate.make(from: p, library: lib)
    #expect(t.entries.map { $0.operation.setup.pauseAfter?.message } == [nil, "Flip", nil])
    #expect(t.entries.map(\.operation.setup.isEnabled) == [false, false, true])
}
