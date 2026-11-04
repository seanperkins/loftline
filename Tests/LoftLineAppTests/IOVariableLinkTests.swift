import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineApp

@Suite @MainActor struct IOVariableLinkTests {
    static func setup() -> (LoftLineDocument, UUID) {
        var p = AppTestSupport.project()
        let op = OperationFactory.make(kind: .profile, project: p, library: .seeded, shapeIDs: [p.document.shapes[0].id])!
        p.operations = [op]
        return (LoftLineDocument(project: p, toolLibrary: AppTestSupport.library()), op.id)
    }

    static func cutDepth(_ d: LoftLineDocument, _ id: UUID) -> Double {
        guard case .profile(let o) = d.operation(id) else { return .nan }
        return o.params.depth.cutDepth
    }

    static func setCutDepth(_ d: LoftLineDocument, _ id: UUID, _ v: Double) {
        guard case .profile(var o) = d.operation(id) else { return }
        o.params.depth.cutDepth = v
        d.updateOperation(.profile(o))
    }

    /// What a numeric field does on commit: parse (noting the expression for the form's target), then write. The
    /// target is the setup's one toolpath unless given.
    static func type(_ text: String, into d: LoftLineDocument, current: Double, target: VariableLink.Target? = nil) throws -> Double {
        let style = ExpressionNumberStyle(variables: d.document.variableTable, units: d.units, recorder: d.expressionRecorder,
                                          target: target ?? .operation(d.project.operations[0].id))
        let v = try style.parseStrategy.parse(text)
        return d.expressionRecorder.valueToWrite(v, current: current)
    }

    @Test func typedVariableStaysLinkedToTheMaterial() throws {
        let (d, id) = Self.setup()
        d.perform("Job") { $0.document.job.thickness = 0.5 }
        let v = try Self.type("=thickness - 0.1", into: d, current: Self.cutDepth(d, id))
        Self.setCutDepth(d, id, v)
        #expect(abs(Self.cutDepth(d, id) - 0.4) < 1e-12)
        #expect(d.document.linkedValues.count == 1)
        #expect(d.document.linkedValues[0].expression == "=thickness - 0.1")
        d.perform("Job") { $0.document.job.thickness = 1.0 }
        #expect(abs(Self.cutDepth(d, id) - 0.9) < 1e-12)
    }

    @Test func sameValueStillLinks() throws {
        let (d, id) = Self.setup()
        d.perform("Job") { $0.document.job.thickness = Self.cutDepth(d, id) }
        let cur = Self.cutDepth(d, id)
        let v = try Self.type("=thickness", into: d, current: cur)
        #expect(v == cur.nextUp)
        Self.setCutDepth(d, id, v)
        #expect(Self.cutDepth(d, id) == cur)   // exact value restored by the link
        #expect(d.document.linkedValues.count == 1)
    }

    @Test func plainNumberUnlinksAndNumbersDoNotLink() throws {
        let (d, id) = Self.setup()
        Self.setCutDepth(d, id, try Self.type("=thickness/2", into: d, current: Self.cutDepth(d, id)))
        #expect(d.document.linkedValues.count == 1)
        Self.setCutDepth(d, id, try Self.type("0.3", into: d, current: Self.cutDepth(d, id)))
        #expect(d.document.linkedValues.isEmpty)
        d.perform("Job") { $0.document.job.thickness = 2 }
        #expect(Self.cutDepth(d, id) == 0.3)
        // Unit-only expressions are not links.
        Self.setCutDepth(d, id, try Self.type("1/4in", into: d, current: 0.3))
        #expect(d.document.linkedValues.isEmpty)
    }

    @Test func userVariablesDriveJobAndToolpaths() throws {
        let (d, id) = Self.setup()
        d.perform("Vars") { $0.document.userVariables = [DocumentVariable(name: "board", value: 0.75)] }
        let t = try Self.type("=board", into: d, current: d.document.job.thickness, target: .job(sheetID: d.document.currentSheetID))
        d.perform("Job") { $0.document.job.thickness = t }
        Self.setCutDepth(d, id, try Self.type("=thickness + 0.02", into: d, current: Self.cutDepth(d, id)))
        #expect(d.document.linkedValues.count == 2)
        d.perform("Vars") { $0.document.userVariables = [DocumentVariable(name: "board", value: 0.5)] }
        #expect(d.document.job.thickness == 0.5)
        #expect(abs(Self.cutDepth(d, id) - 0.52) < 1e-12)
        // Deleting the toolpath drops its link.
        d.deleteOperation(id)
        #expect(d.document.linkedValues.count == 1)
    }

    @Test func linksAreSavedWithTheFile() throws {
        var doc = Document()
        doc.linkedValues = [VariableLink(target: .job(sheetID: MaterialSheet.primaryID), path: ["thickness"], expression: "=a")]
        let data = try JSONEncoder().encode(doc)
        let back = try JSONDecoder().decode(Document.self, from: data)
        #expect(back.linkedValues == doc.linkedValues)
        #expect(VariableLink.usesVariables("=a*2", units: .inch))
        #expect(!VariableLink.usesVariables("1/4in + 2", units: .inch))
    }

    @Test func describeNamesTheParameter() throws {
        let (d, id) = Self.setup()
        Self.setCutDepth(d, id, try Self.type("=thickness", into: d, current: Self.cutDepth(d, id)))
        let label = VariableLinks.describe(d.document.linkedValues[0], in: d.project)
        #expect(label.hasSuffix("Depth › Cut depth"))
    }

    // MARK: Links stay within the form they were typed in (docs/implicit-state-machines.md #10)

    @Test func expressionOutsideAProjectFormLinksNothing() throws {
        // A drawing option or a transform dialog has no target: the expression typed there is not waiting to link a
        // default of the next new toolpath that happens to have its value.
        let (d, _) = Self.setup()
        let style = ExpressionNumberStyle(variables: d.document.variableTable, units: d.units, recorder: d.expressionRecorder)
        let v = try style.parseStrategy.parse("=thickness/3")   // 0.25, a new pocket's default cut depth
        #expect(v == 0.25)
        d.addOperation(.pocket)
        #expect(d.document.linkedValues.isEmpty)
    }

    @Test func twoLeavesWithTheSameValueLinkNeither() throws {
        // One edit set two fields of the toolpath to the typed value: which one the expression was typed into is not
        // known, so neither is linked and both keep the value.
        let (d, id) = Self.setup()
        guard case .profile(var o) = d.operation(id) else { return }
        let v = try Self.type("=thickness/5", into: d, current: o.params.depth.cutDepth)
        o.params.depth.cutDepth = v
        o.params.depth.startDepth = v
        d.updateOperation(.profile(o))
        #expect(d.document.linkedValues.isEmpty)
        #expect(Self.cutDepth(d, id) == v)
    }

    @Test func linkChainOfFourSettlesInOneEdit() {
        // a -> thickness -> width -> height -> safe Z, stored in the worst order: one change of a settles them all.
        let (d, _) = Self.setup()
        let sheet = d.document.currentSheetID
        d.perform("Links") {
            $0.document.userVariables = [DocumentVariable(name: "a", value: 0.5)]
            $0.document.linkedValues = [
                VariableLink(target: .job(sheetID: sheet), path: ["safeZ"], expression: "=height/100"),
                VariableLink(target: .job(sheetID: sheet), path: ["height"], expression: "=width"),
                VariableLink(target: .job(sheetID: sheet), path: ["width"], expression: "=thickness*20"),
                VariableLink(target: .job(sheetID: sheet), path: ["thickness"], expression: "=a"),
            ]
        }
        d.perform("Change a") { $0.document.userVariables = [DocumentVariable(name: "a", value: 0.8)] }
        #expect(abs(d.document.job.thickness - 0.8) < 1e-12)
        #expect(abs(d.document.job.width - 16) < 1e-9 && abs(d.document.job.height - 16) < 1e-9)
        #expect(abs(d.document.job.safeZ - 0.16) < 1e-12)
    }

    @Test func jobLinkFeedsOperationLinks() throws {
        // A thickness typed as an expression in Job Setup still feeds a toolpath link that uses `thickness`.
        let (d, id) = Self.setup()
        d.perform("Variable") { $0.document.userVariables = [DocumentVariable(name: "board", value: 0.75)] }
        Self.setCutDepth(d, id, try Self.type("=thickness - 0.1", into: d, current: Self.cutDepth(d, id)))
        let t = try Self.type("=board", into: d, current: d.document.job.thickness, target: .job(sheetID: d.document.currentSheetID))
        d.perform("Job") { $0.document.job.thickness = t }
        d.perform("Board") { $0.document.userVariables = [DocumentVariable(name: "board", value: 1.0)] }
        #expect(abs(d.document.job.thickness - 1.0) < 1e-12)
        #expect(abs(Self.cutDepth(d, id) - 0.9) < 1e-12)
    }

    @Test func conflictingLinksToOneFieldKeepTheLast() {
        // A crafted (or damaged) file with several links to one field that disagree: each pass would flip the field,
        // so evaluation never settles. One link per field is kept, the last, and evaluation is bounded.
        let (d, id) = Self.setup()
        var leaves: [[String]: Double] = [:]
        if let tree = VariableLinks.tree(of: .operation(id), in: d.project) { VariableLinks.leaves(tree, prefix: [], into: &leaves) }
        guard let path = leaves.keys.first(where: { Array($0.suffix(2)) == ["depth", "cutDepth"] }) else {
            Issue.record("no cut depth leaf"); return
        }
        d.perform("Links") {
            $0.document.linkedValues = (0..<200).map { i in
                VariableLink(target: .operation(id), path: path, expression: i % 2 == 0 ? "=0.1" : "=0.2")
            }
        }
        #expect(d.document.linkedValues.count == 1)
        #expect(d.document.linkedValues.first?.expression == "=0.2")
        #expect(abs(Self.cutDepth(d, id) - 0.2) < 1e-12)
    }
}
