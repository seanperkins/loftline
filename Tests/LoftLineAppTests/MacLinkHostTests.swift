import AppKit
import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit
@testable import LoftLineMCP

/// The Mac app's end of the live link (spec 2, "The Mac host"): an edit is one main-thread turn and one Undo step, a post
/// calculates first, a save goes through the document, and the review marker is kept on disk.
@MainActor @Suite(.serialized) struct MacLinkHostTests {
    struct Rig {
        let dir: URL
        let allowed: URL
        let host: MacLinkHost
        let doc: LoftLineDocument
        let undo = UndoManager()

        init(project: LoftLineProject = AppTestSupport.project(), fileURL: URL? = nil) throws {
            dir = AppTestSupport.tempDir()
            allowed = dir.appendingPathComponent("Jobs")
            try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
            let settings = dir.appendingPathComponent("support/assistant.json")
            try AssistantSettings(allowedFolders: [allowed.path], liveLink: true).save(to: settings)
            host = MacLinkHost(settingsFile: settings, access: AssistantAccess(settingsFile: settings),
                               markers: ReviewMarkerStore(file: dir.appendingPathComponent("support/review.json")))
            doc = LoftLineDocument(project: project, toolLibrary: AppTestSupport.library())
            undo.groupsByEvent = false   // tests group by hand unless they run the loop
            doc.undoManager = undo
            doc.fileURL = fileURL
            host.register(doc)
        }

        /// The user has clicked Allow on the window.
        func allow() async {
            let id = doc.linkID
            let claim = Task { await host.claims.claim(id, connection: 1) }
            for _ in 0..<2000 where await !host.claims.asking.contains(id) { try? await Task.sleep(for: .milliseconds(5)) }
            await host.claims.answer(id, allow: true)
            _ = await claim.value
            await host.refreshNow()
        }

        func run(_ tool: String, _ arguments: [String: Any] = [:]) async throws -> ToolOutput {
            guard let kind = LinkToolKind.of(tool) else { throw ToolError("no tool") }
            return try await host.run(LinkCall(kind: kind, tool: tool, arguments: arguments, document: doc.linkID))
        }
    }

    /// Runs the main run loop, so the undo manager closes the group it opened for this pass.
    nonisolated static func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    static let rectangle: [String: Any] = ["shapes": [["type": "rectangle", "x": 1, "y": 1, "width": 2, "height": 2]]]

    @Test func editIsOneUndoStepAndUndoRestores() async throws {
        let rig = try Rig()
        await rig.allow()
        let before = rig.doc.project
        _ = try await rig.run("add_shapes", ["shapes": [["type": "rectangle", "x": 1, "y": 1, "width": 2, "height": 2],
                                                         ["type": "circle", "x": 6, "y": 6, "radius": 1]]])
        #expect(rig.doc.project.document.shapes.count == before.document.shapes.count + 2)
        #expect(rig.undo.undoActionName == "Assistant: add_shapes")
        rig.undo.undo()
        #expect(rig.doc.project == before)
    }

    @Test func editRefusedWithoutAllow() async throws {
        let rig = try Rig()
        await #expect(throws: (any Error).self) { _ = try await rig.run("add_shapes", Self.rectangle) }
    }

    @Test func editRefusedUnderASheet() async throws {
        let rig = try Rig()
        await rig.allow()
        rig.doc.sheet = .jobSetup
        let before = rig.doc.project
        do {
            _ = try await rig.run("add_shapes", Self.rectangle)
            Issue.record("expected a refusal")
        } catch {
            #expect((error as? LocalizedError)?.errorDescription?.hasPrefix("Close the dialog") == true)
        }
        #expect(rig.doc.project == before)
    }

    @Test func editKeepsPendingExpressions() async throws {
        let rig = try Rig()
        await rig.allow()
        let layer = rig.doc.project.document.defaultLayerID
        rig.doc.expressionRecorder.note("w/2", value: 1, units: nil, target: .operation(UUID()))
        let pending = rig.doc.expressionRecorder.pending.count
        #expect(pending == 1)
        _ = try await rig.run("add_shapes", Self.rectangle)
        #expect(rig.doc.expressionRecorder.pending.count == pending)
        _ = layer
    }

    /// No tool turns two-sided off today, so the reset to the top (spec 2, "Edit" step 5) can't be reached through one; an edit
    /// that leaves the job two-sided keeps the side on show.
    @Test func twoSidedEditKeepsTheSideOnShow() async throws {
        var p = AppTestSupport.project()
        var form = JobSetupForm(document: p.document)
        form.job.twoSided = TwoSidedSetup(flip: .leftRight, bottomZZero: .spoilboard)
        p = form.apply(to: p)
        let rig = try Rig(project: p)
        rig.doc.activeSide = .bottom
        await rig.allow()
        _ = try await rig.run("add_shapes", Self.rectangle)
        #expect(rig.doc.activeSide == .bottom)
    }

    @Test func sameTurnEditKeepsALiveInspectorEdit() async throws {
        let rig = try Rig(project: try LoftLineProject.opening(from: Data(contentsOf: try #require(SampleProjects.url(for: SampleProjects.sign)))))
        await rig.allow()
        var op = try #require(rig.doc.project.operations.first)
        var setup = op.editableSetup
        setup.name = "Live 1"
        op.editableSetup = setup
        rig.undo.beginUndoGrouping()   // the user's own edits, grouped as an event would group them
        rig.doc.updateOperationLive(op)
        setup.name = "Live 2"
        op.editableSetup = setup
        rig.doc.updateOperationLive(op)
        rig.undo.endUndoGrouping()
        _ = try await rig.run("add_shapes", Self.rectangle)
        #expect(rig.doc.project.operations.first?.setup.name == "Live 2")
    }

    @Test func userActionAfterTheApplyIsItsOwnStep() async throws {
        let rig = try Rig()
        rig.undo.groupsByEvent = true
        await rig.allow()
        let call = LinkCall(kind: .edit, tool: "add_shapes", arguments: Self.rectangle, document: rig.doc.linkID)
        let applied = try rig.host.editTurn(rig.doc, call)
        #expect(applied != nil)
        rig.doc.perform("User edit") { $0.document.name = "Mine" }   // the same run-loop pass
        Self.spin(0.05)
        rig.undo.undo()
        #expect(rig.doc.project.document.name != "Mine")
        #expect(rig.undo.undoActionName == "Assistant: add_shapes")
    }

    @Test func busyRetryStopsAfterTenPasses() async throws {
        let rig = try Rig()
        await rig.allow()
        rig.undo.beginUndoGrouping()
        defer { rig.undo.endUndoGrouping() }
        do {
            _ = try await rig.run("add_shapes", Self.rectangle)
            Issue.record("expected busy")
        } catch {
            #expect((error as? LocalizedError)?.errorDescription == "LoftLine is busy; try again.")
        }
    }

    @Test func postCalculatesFirstAndMatchesExport() async throws {
        let rig = try Rig(project: try LoftLineProject.opening(from: Data(contentsOf: try #require(SampleProjects.url(for: SampleProjects.sign)))))
        await rig.allow()
        _ = try await rig.run("post_gcode", ["folder": rig.allowed.path, "mode": "one_file", "job_sheet": false])
        let programs = try FileManager.default.contentsOfDirectory(atPath: rig.allowed.path)
        #expect(programs.count == 1, "\(programs)")
        let written = try String(contentsOf: rig.allowed.appendingPathComponent(programs[0]), encoding: .utf8)
        let expected = try CoreSession(snapshot: rig.doc.linkSnapshot()).post(scope: .all, postID: nil, side: nil, groupByTool: false).0.text
        #expect(written == expected)
    }

    @Test func calculateCoversEveryEnabledToolpath() async throws {
        let rig = try Rig(project: try LoftLineProject.opening(from: Data(contentsOf: try #require(SampleProjects.url(for: SampleProjects.sign)))))
        await rig.allow()
        let out = try await rig.run("calculate")
        #expect(out.text.hasPrefix("Calculated"))
        for op in rig.doc.project.operations where op.setup.isEnabled {
            let stale = rig.doc.isStale(op.id)
            #expect(!stale, "\(op.setup.name)")
        }
    }

    @Test func saveOutsideAllowedFolderRefused() async throws {
        let outside = AppTestSupport.tempDir().appendingPathComponent("Sign.loftline")
        let rig = try Rig(fileURL: outside)
        await rig.allow()
        await #expect(throws: (any Error).self) { _ = try await rig.run("save_project") }
    }

    @Test func saveAsAndUntitledRefused() async throws {
        let rig = try Rig()
        await rig.allow()
        for args: [String: Any] in [[:], ["path": rig.allowed.appendingPathComponent("New.loftline").path]] {
            do {
                _ = try await rig.run("save_project", args)
                Issue.record("expected a refusal")
            } catch {
                #expect((error as? LocalizedError)?.errorDescription == "Use File ▸ Save As in LoftLine.")
            }
        }
    }

    @Test func markerSurvivesATickAndAReopen() async throws {
        let file = AppTestSupport.tempDir().appendingPathComponent("Sign.loftline")
        try AppTestSupport.project().encoded().write(to: file)
        let rig = try Rig(fileURL: file)
        await rig.allow()
        _ = try await rig.run("add_shapes", Self.rectangle)
        #expect(rig.doc.assistantChanges == 1)
        rig.doc.confirmSave()   // the recovery tick
        #expect(rig.host.markers.count(for: file) == 1)
        let reopened = LoftLineDocument(project: rig.doc.project, toolLibrary: AppTestSupport.library())
        reopened.fileURL = file
        rig.host.register(reopened)
        #expect(reopened.assistantChanges == 1)
        rig.host.dismissMarker(reopened)
        #expect(rig.host.markers.count(for: file) == 0)
    }

    @Test func untitledCountReachesTheRecordOnFirstSave() async throws {
        let rig = try Rig()
        await rig.allow()
        _ = try await rig.run("add_shapes", Self.rectangle)
        #expect(rig.doc.assistantChanges == 1)
        let file = rig.allowed.appendingPathComponent("Saved.loftline")
        rig.doc.fileURL = file
        #expect(rig.host.markers.count(for: file) == 1)
    }

    @Test func describeNamesTheWindow() async throws {
        let rig = try Rig()
        await rig.allow()
        let text = try await rig.run("describe_project").text
        #expect(text.contains("\"document\""))
    }
}
