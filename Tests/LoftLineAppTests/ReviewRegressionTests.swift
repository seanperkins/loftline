import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// Regressions found in the 2026-10-20 deep review (docs/REVIEW-2026-10-20.md).
@Suite struct ReviewRegressionTests {
    private let lib = ToolLibrary.seeded

    private func twoProfiles(secondEnabled: Bool) -> LoftLineProject {
        var p = AppTestSupport.project()
        let ids = p.document.shapes.map(\.id)
        var b = OperationSetup(name: "B", toolID: lib.tools[0].id, shapeIDs: [ids[1]])
        b.isEnabled = secondEnabled
        p.operations = [
            .profile(ProfileOperation(setup: OperationSetup(name: "A", toolID: lib.tools[0].id, shapeIDs: [ids[0]]))),
            .profile(ProfileOperation(setup: b)),
        ]
        return p
    }

    /// The inlay wizard turns the plug off on purpose; merging must not turn it back on.
    @Test func mergeNeverEnablesADisabledToolpath() {
        var mixed = twoProfiles(secondEnabled: false)
        #expect(mixed.mergeWithNextProblem(mixed.operations[0].id) != nil)
        #expect(mixed.mergeWithNext(mixed.operations[0].id) == nil)
        #expect(mixed.operations.count == 2)
        var both = twoProfiles(secondEnabled: true)
        #expect(both.mergeWithNext(both.operations[0].id) != nil)
        #expect(both.operations[0].setup.isEnabled)
    }

    /// Deleting a layer keeps its shapes on the same side and drops clamp outlines rather than
    /// turning them into ordinary (machinable, unprotected) vectors.
    @Test func deletingALayerKeepsSideAndDropsKeepOutShapes() {
        var p = AppTestSupport.project()
        let bottomA = p.addLayer(named: "Bottom A"), bottomB = p.addLayer(named: "Bottom B")
        for id in [bottomA, bottomB] {
            if let i = p.document.layers.firstIndex(where: { $0.id == id }) { p.document.layers[i].side = .bottom }
        }
        let clamps = p.addLayer(named: "Clamps")
        if let i = p.document.layers.firstIndex(where: { $0.id == clamps }) { p.document.layers[i].keepOut = LayerKeepOut() }
        let part = AppTestSupport.rect(1, 5, 1, 1, layer: bottomB)
        let clamp = AppTestSupport.rect(0, 0, 1, 1, layer: clamps)
        p.document.add(part)
        p.document.add(clamp)
        p.deleteLayer(bottomB)
        #expect(p.document.shape(id: part.id)?.layerID == bottomA)
        p.deleteLayer(clamps)
        #expect(p.document.shape(id: clamp.id) == nil)
        #expect(p.document.shapes.count == 3)
    }

    /// A locked shape, or a shape on a locked layer, stays put however it was selected
    /// (sidebar rows and "Select Shapes on Layer" can select what the canvas cannot pick).
    @Test func locksAreEnforcedForDeleteTransformAndMove() {
        var p = AppTestSupport.project()
        let free = p.document.shapes[0].id, onLockedLayer = p.document.shapes[1].id
        let locked = p.addLayer(named: "Locked")
        p.moveShapes([onLockedLayer], toLayer: locked)
        if let i = p.document.layers.firstIndex(where: { $0.id == locked }) { p.document.layers[i].isLocked = true }
        let before = p.document.shape(id: onLockedLayer)!.bounds()
        p.transformShapes([free, onLockedLayer], by: .translation(Vec2(1, 1)))
        #expect(p.document.shape(id: onLockedLayer)!.bounds().min == before.min)
        #expect(p.document.shape(id: free)!.bounds().min == Vec2(2, 2))
        p.moveShapes([onLockedLayer], toLayer: p.document.defaultLayerID)
        #expect(p.document.shape(id: onLockedLayer)!.layerID == locked)
        p.deleteShapes([free, onLockedLayer])
        #expect(p.document.shape(id: onLockedLayer) != nil && p.document.shape(id: free) == nil)
        // A shape lock protects it too; deleting the layer itself still removes clamp outlines (see above).
        var q = AppTestSupport.project()
        let id = q.document.shapes[0].id
        q.document.shapes[0].isLocked = true
        q.deleteShapes([id])
        #expect(q.document.shape(id: id) != nil)
    }

    /// Intersecting two shapes that do not overlap leaves both in place.
    @Test func booleanWithAnEmptyResultKeepsTheInputs() {
        var p = AppTestSupport.project()
        let ids = p.document.shapes.map(\.id)
        #expect(DesignCommands.boolean(.intersect, ids: ids, in: &p) == nil)
        #expect(p.document.shapes.map(\.id) == ids)
    }

    /// An enabled operation that failed to calculate is an error on export, never a silent gap.
    @Test func missingOperationsAreExportErrors() throws {
        var p = AppTestSupport.project()
        let ids = p.document.shapes.map(\.id)
        let good = OperationFactory.make(kind: .profile, project: p, library: lib, shapeIDs: [ids[0]])!
        let bad = OperationFactory.make(kind: .profile, project: p, library: lib, shapeIDs: [])!   // nothing selected
        p.operations = [good, bad]
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        doc.calculateNow([good.id, bad.id])
        let issues = GCodeExporter.missingOperationIssues(doc.outputProject.operations, results: doc.results)
        #expect(issues.count == 1 && issues[0].severity == .error && issues[0].message.contains(bad.setup.name))
        // Tiled export carries the same error on every tile.
        doc.perform("wide") { $0.document.job.width = 110 }
        let files = TiledExport.files(project: doc.outputProject, results: doc.results, profile: BuiltInPosts.avidMach4Inch,
                                      groupByTool: false, settings: TilingSettings(tileWidth: 60, tileHeight: 96))
        #expect(!files.isEmpty && files.allSatisfy(\.result.hasErrors))
        // Never calculated at all counts too.
        #expect(GCodeExporter.missingOperationIssues([good], results: [:]).count == 1)
    }

    /// Exporting one toolpath from another sheet posts it with that sheet's job, not the shown one.
    @Test func singleToolpathExportUsesItsOwnSheetsJob() {
        let p = AppTestSupport.project()
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        let onSheet1 = p.document.shapes[0].id
        doc.addSheet()
        let layer2 = doc.currentSheetLayers[0].id
        let onSheet2 = p.document.shapes[1].id
        doc.perform("x") { $0.moveShapes([onSheet2], toLayer: layer2); $0.document.job.thickness = 0.5 }
        let op1 = OperationFactory.make(kind: .profile, project: doc.project, library: lib, shapeIDs: [onSheet1])!
        doc.perform("ops") { $0.operations = [op1] }
        #expect(doc.document.job.thickness == 0.5)   // sheet 2 is shown
        let single = doc.outputProject(for: .operation(op1.id))
        #expect(single.document.job.thickness == 0.75)
        #expect(single.operations.map(\.id) == [op1.id])
    }

    /// Parametric sizes follow uniform scaling and survive rotation; a shear gives them up.
    @Test func shapeOriginFollowsSimilarityTransforms() {
        let layer = UUID()
        let circle = Shape(layerID: layer, paths: [ShapeFactory.circle(center: .zero, radius: 1)], origin: .circle(radius: 1))
        #expect(circle.transformed(.scale(2, 2)).origin == .circle(radius: 2))
        #expect(circle.transformed(.rotation(0.3)).origin == .circle(radius: 1))
        #expect(circle.transformed(.translation(Vec2(3, 4))).origin == .circle(radius: 1))
        #expect(circle.transformed(.scale(2, 1)).origin == .derived(operation: "transform"))
        let rect = Shape(layerID: layer, paths: [ShapeFactory.rectangle(Rect2(x: 0, y: 0, width: 2, height: 1))],
                         origin: .rectangle(width: 2, height: 1, cornerRadius: 0.25))
        #expect(rect.transformed(.scale(0.5, 0.5)).origin == .rectangle(width: 1, height: 0.5, cornerRadius: 0.125))
        let text = Shape(layerID: layer, paths: [], origin: .text("a", fontName: "Helvetica", size: 1))
        #expect(text.transformed(.scale(2, 2)).origin == .text("a", fontName: "Helvetica", size: 1))
    }

    /// Nested or plated copies of a profile with manual tabs get the same tabs as the original.
    @Test func copiesInheritManualTabs() {
        let original = UUID(), copyA = UUID(), copyB = UUID()
        var params = ProfileParameters()
        params.tabs = TabSettings(isEnabled: true, manualTabs: [TabAnchor(shapeID: original, fraction: 0.25),
                                                                TabAnchor(shapeID: original, pathIndex: 1, fraction: 0.75)])
        var op = AnyOperation.profile(ProfileOperation(setup: OperationSetup(name: "P", toolID: lib.tools[0].id,
                                                                              shapeIDs: [original]), params: params))
        TabAnchor.addCopies([original: [copyA, copyB]], to: &op)
        guard case .profile(let p) = op, let anchors = p.params.tabs.manualTabs else { Issue.record("not a profile"); return }
        #expect(anchors.count == 6)
        #expect(anchors.contains(TabAnchor(shapeID: copyB, pathIndex: 1, fraction: 0.75)))
        TabAnchor.addCopies([original: [copyA]], to: &op)   // idempotent
        if case .profile(let again) = op { #expect(again.params.tabs.manualTabs?.count == 6) }
    }

    /// A post the project names but this Mac lacks is reported instead of silently swapped.
    @Test func missingPostProfileIsAnIssue() {
        var p = AppTestSupport.project()
        p.postProfileID = "shop-post-that-is-not-installed"
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        let issues = doc.postProfileIssues
        #expect(issues.count == 1 && issues[0].severity == .error && issues[0].message.contains("shop-post-that-is-not-installed"))
        p.postProfileID = BuiltInPosts.avidMach4Inch.id
        #expect(LoftLineDocument(project: p, toolLibrary: AppTestSupport.library()).postProfileIssues.isEmpty)
    }

    /// An unreadable tool library is copied aside before the seeded defaults can replace it.
    @Test func unreadableToolLibraryIsKeptAside() throws {
        let dir = AppTestSupport.tempDir()
        let url = dir.appendingPathComponent("tools.json")
        try Data("{ not json".utf8).write(to: url)
        let model = ToolLibraryModel(store: ToolLibraryStore(fileURL: url))
        #expect(model.lastError?.contains("kept as") == true)
        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("tools.unreadable-") }
        #expect(kept.count == 1)
        #expect(try Data(contentsOf: dir.appendingPathComponent(kept[0])) == Data("{ not json".utf8))
        model.add(kind: .endMill)
        #expect(try Data(contentsOf: dir.appendingPathComponent(kept[0])) == Data("{ not json".utf8))
    }
}
