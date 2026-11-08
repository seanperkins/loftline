import CADCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// Two library tools with one T number are shown as such in the Tool Database, and new and copied tools take a
/// number nothing else has (issue #38).
@Suite struct ToolNumbersTests {
    func tool(_ name: String, _ number: Int) -> Tool {
        Tool(name: name, kind: .endMill, number: number, diameter: 0.25, stepdown: 0.1, stepover: 0.1, feedRate: 100, plungeRate: 30)
    }

    @Test func theSeededLibraryHasNoSharedNumbers() {
        #expect(ToolNumbers.clashes(in: AppTestSupport.library().tools).isEmpty)
    }

    @Test func everyToolOfASharedNumberIsFlaggedAndTheOthersAreNamed() {
        let a = tool("A", 3), b = tool("B", 3), c = tool("C", 4), d = tool("D", 3), e = tool("E", 7), f = tool("F", 7)
        let clashes = ToolNumbers.clashes(in: [a, b, c, d, e, f])
        #expect(Set(clashes.keys) == [3, 7])
        #expect(Set(clashes[3]!.map(\.name)) == ["A", "B", "D"] && Set(clashes[7]!.map(\.name)) == ["E", "F"])
        #expect(Set(ToolNumbers.others(using: 3, besides: a.id, in: [a, b, c, d]).map(\.name)) == ["B", "D"])
        #expect(ToolNumbers.others(using: 4, besides: c.id, in: [a, b, c, d]).isEmpty)
        #expect(ToolNumbers.names([a]) == "A" && ToolNumbers.names([a, b]) == "A and B" && ToolNumbers.names([a, b, d]) == "A, B and D")
    }

    @Test func theNextFreeNumberSkipsWhatIsUsedAndTheToolBeingRenumbered() {
        let a = tool("A", 1), b = tool("B", 2), c = tool("C", 4)
        #expect(ToolNumbers.nextFree(in: [a, b, c]) == 3)
        #expect(ToolNumbers.nextFree(in: [a, b, c], besides: b.id) == 2)     // its own number is free to it
        #expect(ToolNumbers.nextFree(in: [tool("zero", 0)]) == 1)            // 0 is a number, the search starts at 1
        let all = (1...999).map { tool("T\($0)", $0) }
        #expect(ToolNumbers.nextFree(in: all) == nil)
        #expect(ToolNumbers.nextFree(in: all, besides: all[41].id) == 42)
    }

    @Test func newAndCopiedToolsTakeAFreeNumberEvenWhenTheLibraryAlreadyClashes() throws {
        let lib = AppTestSupport.library()
        let first = try #require(lib.tools.first)
        var twin = first
        twin.id = UUID(); twin.name = "Same number"          // an import or an edit made a clash
        lib.update(twin)
        #expect(ToolNumbers.clashes(in: lib.tools)[first.number]?.count == 2)
        let added = lib.add(kind: .endMill)
        let copy = try #require(lib.duplicate(id: first.id))
        #expect(ToolNumbers.others(using: added.number, besides: added.id, in: lib.tools).isEmpty)
        #expect(ToolNumbers.others(using: copy.number, besides: copy.id, in: lib.tools).isEmpty)
        #expect(added.number != copy.number && copy.number != first.number)
        // Only the clash that was already there is left.
        #expect(Set(ToolNumbers.clashes(in: lib.tools).keys) == [first.number])
    }
}
