import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineKit
@testable import LoftLineMCP

/// One tool on a copy of a window (spec 2, "Architecture"): the same project and the same program as file mode, and only
/// fresh results carried in.
@Suite struct AssistantRunnerTests {
    @Test func everyNameHasAKind() {
        let h = MCPHarness()
        for tool in h.tools { #expect(LinkToolKind.of(tool.name) != nil, "\(tool.name)") }
        for never in ["new_project", "open_project", "undo"] { #expect(LinkToolKind.of(never) == .never) }
        #expect(LinkToolKind.of("add_shapes") == .edit)
        #expect(LinkToolKind.of("calculate") == .calculate)
        #expect(LinkToolKind.of("post_gcode") == .writeFiles)
        #expect(LinkToolKind.of("save_project") == .save)
        #expect(LinkToolKind.of("check") == .read)
        #expect(LinkToolKind.of("rm_rf") == nil)
        #expect(LinkToolKind.undoName("add_shapes") == "Assistant: add_shapes")
    }

    @Test func snapshotRoundTripKeepsFreshResultsFresh() throws {
        let h = MCPHarness()
        try h.call("open_project", ["path": try h.sample().path])
        try h.call("calculate")
        let copy = CoreSession(snapshot: h.session.snapshot())
        for op in copy.project.operations where op.setup.isEnabled {
            let stale = copy.isStale(op.id)
            #expect(!stale, "\(op.setup.name)")
        }
        #expect(copy.isDirty == h.session.isDirty)
        #expect(copy.fileURL == h.session.fileURL)
    }

    @Test func staleResultsAreNotCarried() throws {
        let h = MCPHarness()
        try h.call("open_project", ["path": try h.sample().path])
        try h.call("calculate")
        h.session.perform("Add") { $0.document.add(Shape(layerID: $0.document.defaultLayerID, paths: [ShapeFactory.rectangle(Rect2(x: 1, y: 1, width: 1, height: 1))])) }
        let carried = h.session.snapshot().results.count
        let fresh = h.session.project.operations.filter { !h.session.isStale($0.id) }.count
        #expect(carried == fresh)
    }

    @Test func runnerEditMatchesFileMode() throws {
        let a = MCPHarness(), b = MCPHarness()
        for h in [a, b] { try h.call("new_project", ["units": "inch", "width": 24, "height": 18, "thickness": 0.75]) }
        let args: [String: Any] = ["shapes": [["type": "rectangle", "x": 1, "y": 1, "width": 2, "height": 3]]]
        try a.call("add_shapes", args)
        let run = try AssistantRunner.run(tool: "add_shapes", arguments: args, snapshot: b.session.snapshot(), access: b.access)
        // Shape and layer ids are new in each session; compare the geometry.
        #expect(run.project.document.shapes.map(\.paths) == a.session.project.document.shapes.map(\.paths))
        #expect(run.project.document.shapes.count == 1)
        #expect(run.output.text.hasPrefix("Added"))
    }

    @Test func runnerPostsTheShownSide() throws {
        let h = MCPHarness()
        try h.call("new_project", ["units": "inch", "width": 24, "height": 18, "thickness": 0.75])
        h.session.perform("Two-sided") { p in
            var form = JobSetupForm(document: p.document)
            form.job.twoSided = TwoSidedSetup(flip: .leftRight, bottomZZero: .spoilboard)
            p = form.apply(to: p)
            let bottomLayer = p.document.layers.first { $0.side == .bottom }!.id
            p.document.add(Shape(layerID: p.document.defaultLayerID, paths: [ShapeFactory.rectangle(Rect2(x: 1, y: 1, width: 2, height: 1))]))
            p.document.add(Shape(layerID: bottomLayer, paths: [ShapeFactory.rectangle(Rect2(x: 5, y: 1, width: 2, height: 1))]))
            let top = OperationFactory.make(kind: .profile, project: p, library: h.session.library, shapeIDs: [p.document.shapes[0].id])!
            let bottom = OperationFactory.make(kind: .profile, project: p, library: h.session.library, shapeIDs: [p.document.shapes[1].id])!
            p.operations = [top, bottom]
        }
        h.session.showSide(.bottom)
        let run = try AssistantRunner.run(tool: "post_gcode", arguments: ["folder": h.allowed.path, "mode": "one_file", "job_sheet": false],
                                          snapshot: h.session.snapshot(), access: h.access)
        #expect(!run.output.text.isEmpty)
        let programs = try FileManager.default.contentsOfDirectory(atPath: h.allowed.path).filter { !$0.hasSuffix(".html") }
        #expect(programs.count == 1, "\(programs)")
        let written = try String(contentsOf: h.allowed.appendingPathComponent(programs[0]), encoding: .utf8)
        let expected = try h.session.post(scope: .all, postID: nil, side: .bottom, groupByTool: false).0.text
        #expect(written == expected)
    }

    @Test func changeRevisionMovesOnAToolpathOnlyEdit() throws {
        let h = MCPHarness()
        try h.call("open_project", ["path": try h.sample().path])
        let op = try #require(h.session.project.operations.first)
        let (change, design) = (h.session.changeRevision, h.session.designRevision)
        try h.call("update_toolpath", ["id": op.id.uuidString, "enabled": !op.setup.isEnabled])
        #expect(h.session.changeRevision > change)
        #expect(h.session.designRevision == design)
    }
}
