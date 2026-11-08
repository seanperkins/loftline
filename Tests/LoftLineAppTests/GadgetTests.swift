import AppKit
import CADCore
import CAMCore
import Foundation
import SwiftUI
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct GadgetScriptTests {
    @Test func parsesHeaderTagsAndParameters() {
        let src = """
        // @name Shelf Pins
        // @description Two rows of holes.
        // @needs-selection
        // @param rows integer 3 "Number of rows"
        // @param pitch length 1.25 "Spacing"
        // @param side choice outside|inside|on "Side"
        // @param side2 choice:a|b b "Pick"
        // @param label text "Hello world" "Label"
        // @param empty text "" "Blank"
        // @param drill bool true "Drill"
        // @param bad widget 1 "Nope"
        loftline.log("x");
        // @param ignored number 1 "after the header"
        """
        let (g, problems) = GadgetScript.parse(source: src, fallbackName: "file", origin: .builtIn)
        #expect(g.name == "Shelf Pins")
        #expect(g.summary == "Two rows of holes.")
        #expect(g.needsSelection)
        #expect(g.parameters.map(\.name) == ["rows", "pitch", "side", "side2", "label", "empty", "drill"])
        #expect(g.parameters[0].label == "Number of rows")
        #expect(g.parameters[2].kind == .choice(["outside", "inside", "on"]))
        #expect(problems.count == 1)
        let inch = g.defaultValues(units: .inch)
        #expect(inch["rows"] == .number(3))
        #expect(inch["pitch"] == .number(1.25))
        #expect(inch["side"] == .text("outside"))
        #expect(inch["side2"] == .text("b"))
        #expect(inch["label"] == .text("Hello world"))
        #expect(inch["empty"] == .text(""))
        #expect(inch["drill"] == .bool(true))
        let mm = g.defaultValues(units: .millimeter)
        #expect(abs((mm["pitch"]?.number ?? 0) - 31.75) < 1e-9)
        #expect(mm["rows"] == .number(3))  // plain numbers are not scaled
    }

    @Test func fallbackNameAndBadDefaults() {
        let (g, problems) = GadgetScript.parse(source: "// @param n number abc\nloftline.log(1)", fallbackName: "My File",
                                               origin: .builtIn)
        #expect(g.name == "My File")
        #expect(g.parameters.isEmpty)
        #expect(problems.count == 1)
    }

    @Test func builtInGadgetsParseCleanly() {
        for (name, src) in BuiltInGadgets.all {
            let (g, problems) = GadgetScript.parse(source: src, fallbackName: "x", origin: .builtIn)
            #expect(g.name == name)
            #expect(problems.isEmpty, "\(name): \(problems)")
        }
    }
}

@Suite struct GadgetHostTests {
    private func script(_ body: String, params: String = "") -> GadgetScript {
        GadgetScript.parse(source: params + body, fallbackName: "Test", origin: .builtIn).script
    }

    private func run(_ body: String, project: LoftLineProject = AppTestSupport.project(), selection: [UUID] = [],
                     values: [String: GadgetValue] = [:], timeLimit: TimeInterval = 5) throws -> GadgetRunResult {
        try GadgetHost.run(script(body), values: values, project: project, selection: selection,
                           library: .seeded, timeLimit: timeLimit)
    }

    /// Scripts written before the rename call `kerf.*`; the alias keeps them running for one release.
    @Test func legacyKerfNamespaceIsAnAliasOfLoftline() throws {
        let r = try run(#"kerf.log("old"); loftline.log("new");"#)
        let log = r.log.joined(separator: "\n")
        #expect(log.contains("old") && log.contains("new"))
    }

    @Test func drawsPrimitivesAsParametricShapes() throws {
        let r = try run("""
        loftline.rectangle(1, 2, 3, 4, { cornerRadius: 0.5, name: "Box" });
        loftline.circle(5, 5, 1);
        loftline.polygon(0, 0, 1, 6);
        loftline.star(0, 0, 2, 1, 5);
        loftline.polyline([[0, 0], [1, 0], [1, 1]]);
        """)
        #expect(r.createdShapeIDs.count == 5)
        let shapes = r.project.document.shapes(ids: r.createdShapeIDs)
        #expect(shapes[0].name == "Box")
        #expect(shapes[0].origin == .rectangle(width: 3, height: 4, cornerRadius: 0.5))
        let b = shapes[0].bounds()
        #expect(abs(b.min.x - 1) < 1e-6 && abs(b.max.y - 6) < 1e-6)
        #expect(shapes[1].origin == .circle(radius: 1))
        #expect(shapes[2].paths[0].segments.count == 5 && shapes[2].isClosed)
        #expect(shapes[3].paths[0].segments.count == 9)
        #expect(!shapes[4].isClosed)
        #expect(shapes.allSatisfy { $0.layerID == r.project.document.defaultLayerID })
    }

    @Test func pathBuilderMakesMultiPathShapesWithArcsAndCurves() throws {
        let r = try run("""
        var outer = loftline.path().moveTo(0, 0).lineTo(4, 0).arcTo(4, 4, 4, 2, false).curveTo(3, 5, 1, 5, 0, 4).close();
        var inner = loftline.path().moveTo(1, 1).lineTo(2, 1).lineTo(2, 2).close();
        loftline.addShape([outer, inner], { layer: "Gadget Layer" });
        """)
        let s = try #require(r.project.document.shape(id: r.createdShapeIDs[0]))
        #expect(s.paths.count == 2)
        #expect(s.paths[0].segments.count == 3)
        if case .arc(let to, let c, let cw) = s.paths[0].segments[1] {
            #expect(to == Vec2(4, 4) && c == Vec2(4, 2) && !cw)
        } else { Issue.record("expected an arc") }
        #expect(r.project.document.layer(id: s.layerID)?.name == "Gadget Layer")
    }

    @Test func readsSelectionMaterialParamsAndVariables() throws {
        var project = AppTestSupport.project()
        project.document.userVariables = [DocumentVariable(name: "gap", value: 0.25)]
        let first = project.document.shapes[0].id
        let r = try run("""
        var s = loftline.selection();
        if (s.length !== 1) throw new Error("selection " + s.length);
        loftline.log(s[0].bounds.minX, s[0].bounds.width, s[0].closed, s[0].paths[0].points.length);
        loftline.log(loftline.units, loftline.material.thickness, loftline.params.n, loftline.params.flag, loftline.variables.gap);
        loftline.log(loftline.shapes().length, loftline.layers().length, loftline.tools().length > 0);
        loftline.message("done");
        """, project: project, selection: [first], values: ["n": .number(7), "flag": .bool(true)])
        #expect(r.log == ["1 2 true 4", "inch 0.75 7 true 0.25", "2 1 true"])
        #expect(r.messages == ["done"])
        #expect(!r.changedSomething)
        #expect(r.project == project)
    }

    @Test func movesRotatesAndDeletesShapes() throws {
        let project = AppTestSupport.project()
        let a = project.document.shapes[0].id, b = project.document.shapes[1].id
        let r = try run("""
        var s = loftline.shapes();
        loftline.move(s[0], 10, 0);
        loftline.rotate([s[0].id], 90, 0, 0);
        loftline.deleteShapes(s[1].id);
        """, project: project)
        #expect(r.project.document.shape(id: b) == nil)
        let moved = try #require(r.project.document.shape(id: a)).bounds()
        // (11..13, 1..2) rotated 90° about the origin -> x in -2..-1, y in 11..13
        #expect(abs(moved.min.x + 2) < 1e-6 && abs(moved.max.x + 1) < 1e-6)
        #expect(abs(moved.min.y - 11) < 1e-6 && abs(moved.max.y - 13) < 1e-6)
    }

    @Test func addsToolpathsWithOverrides() throws {
        let r = try run("""
        var c = loftline.circle(3, 3, 0.125);
        var box = loftline.rectangle(0, 0, 6, 6);
        loftline.addToolpath("drill", [c], { name: "Holes", depth: 0.4 });
        loftline.addToolpath("Profile", box, { side: "inside", depth: 0.3, tool: 1 });
        """)
        #expect(r.createdOperationIDs.count == 2)
        let ops = r.project.operations
        guard case .drill(let d) = ops[0], case .profile(let p) = ops[1] else {
            Issue.record("unexpected kinds \(ops.map(\.kind))"); return
        }
        #expect(d.setup.name == "Holes" && d.params.cutDepth == 0.4)
        #expect(d.setup.shapeIDs == [r.createdShapeIDs[0]])
        #expect(p.params.side == .inside && p.params.depth.cutDepth == 0.3)
        let tool = ToolLibrary.seeded.tools.first { $0.number == 1 }
        #expect(p.setup.toolID == tool?.id)
    }

    @Test func setsVariablesAndSelection() throws {
        let r = try run("""
        var id = loftline.circle(1, 1, 1);
        loftline.setVariable("depth", 0.5);
        loftline.select([id]);
        """)
        #expect(r.project.document.userVariables.map(\.name) == ["depth"])
        #expect(r.requestedSelection == r.createdShapeIDs)
    }

    @Test func errorsReportTheScriptLineAndChangeNothing() {
        #expect(throws: GadgetError.self) { try run("loftline.circle(0, 0, -1);") }
        do {
            _ = try run("loftline.circle(1, 1, 1);\nundefinedFunction();")
            Issue.record("expected an error")
        } catch let e as GadgetError {
            #expect(e.message.hasPrefix("Line 2:"), "\(e.message)")
        } catch { Issue.record("\(error)") }
        #expect(throws: GadgetError.self) { try run("loftline.addToolpath('laser', [])") }
        #expect(throws: GadgetError.self) { try run("loftline.addToolpath('profile', ['\(UUID().uuidString)'])") }
        #expect(throws: GadgetError.self) { try run("loftline.setVariable('1bad', 2)") }
    }

    @Test func scriptsCanCatchApiErrors() throws {
        let r = try run("""
        try { loftline.circle(0, 0, 0); } catch (e) { loftline.log("caught: " + e.message); }
        """)
        #expect(r.log == ["caught: circle: radius must be positive."])
    }

    @Test func runawayScriptsAreStopped() {
        let start = Date()
        do {
            _ = try run("while (true) {}", timeLimit: 0.3)
            Issue.record("expected a timeout")
        } catch let e as GadgetError {
            #expect(e.message.contains("stopped"), "\(e.message)")
        } catch { Issue.record("\(error)") }
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func noHostAccessBeyondTheApi() throws {
        let r = try run("""
        loftline.log(typeof require, typeof fetch, typeof XMLHttpRequest, typeof process);
        """)
        #expect(r.log == ["undefined undefined undefined undefined"])
    }

    @Test func builtInGadgetsRun() throws {
        var project = AppTestSupport.project()
        let sel = project.document.shapes.map(\.id)
        for (name, src) in BuiltInGadgets.all {
            let g = GadgetScript.parse(source: src, fallbackName: name, origin: .builtIn).script
            let r = try GadgetHost.run(g, values: g.defaultValues(units: .inch), project: project, selection: sel,
                                       library: .seeded)
            #expect(!r.createdShapeIDs.isEmpty, "\(name)")
            if name == "Hole Grid" {
                #expect(r.createdShapeIDs.count == 12)
                #expect(r.project.operations.map(\.kind) == [.drill])
            }
            if name == "Frame Selection" {
                let b = try #require(r.project.document.shape(id: r.createdShapeIDs[0])).bounds()
                #expect(abs(b.min.x - 0.5) < 1e-6 && abs(b.max.x - 7.5) < 1e-6)
                #expect(r.project.operations.map(\.kind) == [.drill, .profile])  // Hole Grid ran first
            }
            project = r.project
        }
    }

    @Test func libraryLoadsUserScripts() throws {
        let dir = AppTestSupport.tempDir()
        try "// @name Mine\nloftline.circle(0,0,1)".write(to: dir.appendingPathComponent("b.js"), atomically: true, encoding: .utf8)
        try "loftline.circle(0,0,1)".write(to: dir.appendingPathComponent("a.js"), atomically: true, encoding: .utf8)
        try "ignored".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let lib = GadgetLibrary(directory: dir)
        #expect(lib.builtIn.count == BuiltInGadgets.all.count)
        #expect(lib.user.map(\.name) == ["a", "Mine"])
        lib.prepareFolder()
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("README.txt").path))
        lib.reload()
        #expect(lib.user.count == 2)  // the .sample example is not loaded
    }
}

@Suite struct GadgetDocumentTests {
    @Test @MainActor func runDialogRendersEveryParameterKind() throws {
        let doc = LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
        let src = """
        // @description All kinds.
        // @param a number 1 "A"
        // @param b length 2 "B"
        // @param c integer 3 "C"
        // @param d bool true "D"
        // @param e text "x" "E"
        // @param f choice p|q "F"
        loftline.log(1)
        """
        let g = GadgetScript.parse(source: src, fallbackName: "All", origin: .builtIn).script
        let view = GadgetRunView(document: doc, script: g, problems: ["a warning"]) {}
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 420)
        #expect(AppTestSupport.looksDrawn(try #require(AppTestSupport.png(of: host))))
    }

    @Test @MainActor func runIsOneUndoStepAndSelectsResult() throws {
        let doc = LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
        let um = UndoManager()
        um.groupsByEvent = false
        doc.undoManager = um
        let original = doc.project
        let g = try #require(BuiltInGadgets.all.first { $0.name == "Hole Grid" })
        let script = GadgetScript.parse(source: g.source, fallbackName: g.name, origin: .builtIn).script
        um.beginUndoGrouping()
        let result = doc.runGadget(script, values: script.defaultValues(units: .inch))
        um.endUndoGrouping()
        let r = try result.get()
        #expect(doc.selection == Set(r.createdShapeIDs))
        #expect(doc.selectedOperationID == r.createdOperationIDs.last)
        #expect(doc.alert?.message == "Drew 12 holes.")
        #expect(um.undoActionName == "Gadget: Hole Grid")
        um.undo()
        #expect(doc.project == original)
    }

    @Test @MainActor func failuresChangeNothing() {
        let doc = LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
        let original = doc.project
        let bad = GadgetScript.parse(source: "loftline.circle(1,1,1); throw new Error('boom');", fallbackName: "Bad",
                                     origin: .builtIn).script
        guard case .failure(let e) = doc.runGadget(bad, values: [:]) else { Issue.record("expected failure"); return }
        #expect(e.message.contains("boom"))
        #expect(doc.project == original)
        let needsSel = GadgetScript.parse(source: "// @needs-selection\nloftline.log(1)", fallbackName: "Sel",
                                          origin: .builtIn).script
        guard case .failure = doc.runGadget(needsSel, values: [:]) else { Issue.record("expected failure"); return }
    }
}
