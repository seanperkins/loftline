import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineApp

/// Applying a template carries the template's own tool: a template is a project, and its copy wins like any other.
@Suite struct ToolpathTemplateToolTests {
    let seeded = ToolLibrary.seeded

    func design() -> Document {
        var d = Document(units: .inch, layers: [Layer(name: "Outline")])
        d.add(Shape(layerID: d.layers[0].id, paths: [ShapeFactory.rectangle(Rect2(x: 0, y: 0, width: 10, height: 6))]))
        return d
    }

    /// A one-toolpath template whose tool (the seeded 1/4" end mill's id) has been edited by `edit`.
    func template(editingTool edit: (inout Tool) -> Void = { _ in }) -> (template: ToolpathTemplate, tool: Tool) {
        let d = design()
        let source = LoftLineProject(document: d, operations: [
            .profile(ProfileOperation(setup: OperationSetup(name: "Cut", toolID: seeded.tools[0].id, shapeIDs: d.shapes.map(\.id)))),
        ])
        var t = ToolpathTemplate.make(from: source, library: seeded)
        edit(&t.tools[0])
        return (t, t.tools[0])
    }

    @Test func theTemplatesToolIsCarriedEvenWhenTheLibraryHasThatID() throws {
        let (t, tool) = template { $0.diameter = 0.5 }
        #expect(tool.diameter != seeded.tools[0].diameter)
        var target = LoftLineProject(document: design())
        TemplateService.apply(t, to: &target, library: seeded)
        #expect(target.operations.count == 1 && target.operations[0].setup.toolID == tool.id)
        #expect(target.tools.first { $0.id == tool.id }?.diameter == 0.5, "the template's copy, not the library's")
        #expect(target.mergedTools(with: seeded).tool(id: tool.id)?.diameter == 0.5)
    }

    @Test func anIdenticalCarriedToolIsReused() {
        let (t, tool) = template()
        var target = LoftLineProject(document: design(), tools: [tool])
        TemplateService.apply(t, to: &target, library: seeded)
        #expect(target.tools == [tool] && target.operations[0].setup.toolID == tool.id)
    }

    @Test func aDifferingCarriedToolGetsAFreshIDAndTheAppliedOperationsFollowIt() throws {
        let (t, templateTool) = template { $0.diameter = 0.5 }
        var carried = seeded.tools[0]
        carried.feedRate = 99
        let existing = AnyOperation.profile(ProfileOperation(setup: OperationSetup(name: "Existing", toolID: carried.id)))
        var target = LoftLineProject(document: design(), operations: [existing], tools: [carried])
        TemplateService.apply(t, to: &target, library: seeded)

        #expect(target.tools.count == 2)
        let fresh = try #require(target.tools.first { $0.id != carried.id })
        #expect(fresh.id != templateTool.id && fresh.diameter == 0.5 && fresh.number == templateTool.number)
        #expect(target.tools.first { $0.id == carried.id } == carried, "the target's own tool is not replaced")
        let added = try #require(target.operations.first { $0.setup.name == "Cut" })
        #expect(added.setup.toolID == fresh.id && added.referencedToolIDs == [fresh.id])
        let kept = try #require(target.operations.first { $0.setup.name == "Existing" })
        #expect(kept.setup.toolID == carried.id, "the existing toolpath keeps its tool")
    }

    @Test func twoDifferentCuttersSharingATNumberAreStillCaught() throws {
        let (t, _) = template { $0.diameter = 0.5 }
        var target = LoftLineProject(document: design(), tools: [seeded.tools[0]])
        TemplateService.apply(t, to: &target, library: seeded)
        #expect(target.tools.count == 2 && Set(target.tools.map(\.number)).count == 1, "the fresh copy keeps its T number")
        #expect(PreflightChecks.duplicateToolNumbers(target.tools).count == 1)
    }

    @Test func remappingRewritesEveryReferenceToATool() throws {
        let from = UUID(), to = UUID(), other = UUID()
        var params = PocketParameters()
        params.clearanceToolIDs = [from, other]
        let op = AnyOperation.pocket(PocketOperation(setup: OperationSetup(name: "P", toolID: from), params: params))
        let mapped = op.remappingTool(from, to: to)
        #expect(mapped.referencedToolIDs == [to, to, other])
        #expect(mapped.setup.id == op.setup.id && mapped.setup.name == "P")
        #expect(op.remappingTool(UUID(), to: to) == op, "an unreferenced tool changes nothing")
    }
}
