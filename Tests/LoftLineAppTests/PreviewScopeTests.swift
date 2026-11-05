import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct PreviewScopeTests {
    /// Profile on shape 0, Pocket on shape 1, Profile on shape 1 (disabled); all calculated.
    private func setup() -> (LoftLineProject, [UUID: ToolpathResult]) {
        var p = AppTestSupport.project()
        let a = p.document.shapes[0].id, b = p.document.shapes[1].id
        for (kind, ids) in [(OperationKind.profile, [a]), (.pocket, [b]), (.profile, [b])] {
            p.operations.append(OperationFactory.make(kind: kind, project: p, library: .seeded, shapeIDs: ids)!)
        }
        var s = p.operations[2].editableSetup
        s.isEnabled = false
        p.operations[2].editableSetup = s
        let results = Dictionary(uniqueKeysWithValues: p.operations.map {
            ($0.id, ToolpathCalculator.calculate($0, project: p, library: .seeded, designRevision: 0, rapidRate: 200))
        })
        return (p, results)
    }

    private func ops(_ tps: [Toolpath]) -> [UUID] {
        var out: [UUID] = []
        for tp in tps { if let id = tp.operationID, out.last != id { out.append(id) } }
        return out
    }

    @Test func allVisibleAndSelected() {
        let (p, r) = setup()
        let ids = p.operations.map(\.id)
        let all = PreviewScope.all.toolpaths(operations: p.operations, results: r, hidden: [ids[0]],
                                             selected: nil, groupByTool: false)
        #expect(ops(all) == [ids[0], ids[1]])
        let visible = PreviewScope.visible.toolpaths(operations: p.operations, results: r, hidden: [ids[0]],
                                                     selected: nil, groupByTool: false)
        #expect(ops(visible) == [ids[1]])
        // A selected toolpath is simulated even when disabled.
        let selected = PreviewScope.selected.toolpaths(operations: p.operations, results: r, hidden: [],
                                                       selected: ids[2], groupByTool: false)
        #expect(ops(selected) == [ids[2]])
        #expect(PreviewScope.selected.toolpaths(operations: p.operations, results: r, hidden: [],
                                                selected: nil, groupByTool: false).isEmpty)
        #expect(PreviewScope.selected.toolpaths(operations: p.operations, results: r, hidden: [],
                                                selected: UUID(), groupByTool: false).isEmpty)
    }
}
