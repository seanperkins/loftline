import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineKit

/// The desktop app's protocol: G-code from the sidecar is the program the exporter makes, and bad input never ends the process.
@Suite struct CoreServiceTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func service() -> CoreService {
        let dir = AppTestSupport.tempDir()
        var posts = PostProfileStore(directory: dir.appendingPathComponent("posts"))
        posts.readsUserFiles = false
        var machines = MachineStore(directory: dir.appendingPathComponent("machines"))
        machines.readsUserFiles = false
        return CoreService(session: CoreSession(toolStore: ToolLibraryStore(fileURL: dir.appendingPathComponent("tools.json")),
                                                postStore: posts, machineStore: machines))
    }

    static func call(_ service: CoreService, _ method: String, _ params: [String: Any] = [:], id: Int = 1) throws -> [String: Any] {
        let line = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        let reply = service.handle(line)
        return try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
    }

    static func result(_ reply: [String: Any]) throws -> [String: Any] {
        #expect(reply["error"] == nil, "\(reply["error"] ?? "")")
        return try #require(reply["result"] as? [String: Any])
    }

    @Test func exportReturnsTheCommittedProgramOfTheSign() throws {
        let s = Self.service()
        _ = try Self.result(Self.call(s, "open", ["path": Self.root.appendingPathComponent("samples/sign.loftline").path]))
        let posted = try Self.result(Self.call(s, "export", ["postID": "generic-grbl-inch"]))
        let text = try #require(posted["text"] as? String)
        let expected = try String(contentsOf: Self.root.appendingPathComponent("samples/expected/generic-grbl-inch/sign.nc"), encoding: .utf8)
        #expect(text == expected)
        #expect(posted["hasErrors"] as? Bool == false)
    }

    @Test func exportWritesThePostsBytes() throws {
        let s = Self.service()
        _ = try Self.result(Self.call(s, "open", ["path": Self.root.appendingPathComponent("samples/sign.loftline").path]))
        let file = AppTestSupport.tempDir().appendingPathComponent("out.tap")
        let posted = try Self.result(Self.call(s, "export", ["postID": "masso-g3-inch", "path": file.path]))
        #expect(posted["written"] as? String == file.path)
        let expected = try Data(contentsOf: Self.root.appendingPathComponent("samples/expected/masso-g3-inch/sign.nc"))
        #expect(try Data(contentsOf: file) == expected)
    }

    @Test func aProgramWithValidatorErrorsIsWrittenOnlyWithForce() throws {
        let s = Self.service()
        _ = try Self.result(Self.call(s, "open", ["path": Self.root.appendingPathComponent("samples/sign.loftline").path]))
        // A cut deeper than the flutes is what the validator refuses.
        s.session.perform("Short flutes") { p in
            for i in p.tools.indices { p.tools[i].fluteLength = 0.01 }
        }
        let file = AppTestSupport.tempDir().appendingPathComponent("program.tap")
        let refused = try Self.result(Self.call(s, "export", ["postID": "generic-grbl-inch", "path": file.path]))
        #expect(refused["hasErrors"] as? Bool == true)
        #expect(refused["written"] == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let forced = try Self.result(Self.call(s, "export", ["postID": "generic-grbl-inch", "path": file.path, "force": true]))
        #expect(forced["written"] as? String == file.path)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func anUnknownPostIsAnError() throws {
        let s = Self.service()
        _ = try Self.result(Self.call(s, "open", ["path": Self.root.appendingPathComponent("samples/sign.loftline").path]))
        #expect((try Self.call(s, "export", ["postID": "no-such-post"])["error"] as? String)?.contains("no-such-post") == true)
    }

    @Test func windowsDeviceNamesAreMadeSafe() {
        for device in ["CON", "con", "PRN", "AUX", "NUL", "COM1", "com9", "LPT1", "lpt9", "CON.part"] {
            #expect(GCodeExporter.windowsSafeName(device) == "_" + device, "\(device)")
        }
        #expect(GCodeExporter.windowsSafeName("Sign ") == "Sign")
        #expect(GCodeExporter.windowsSafeName("Sign..") == "Sign")
        #expect(GCodeExporter.windowsSafeName("...") == "Untitled")
        #expect(GCodeExporter.windowsSafeName("CONSOLE") == "CONSOLE")
        #expect(GCodeExporter.windowsSafeName("COM10") == "COM10")
    }

    @Test func malformedInputGetsAnErrorReply() throws {
        let s = Self.service()
        for bad in ["", "not json", "{}", "{\"id\": 3}", "[1,2]"] {
            let reply = s.handle(Data(bad.utf8))
            let object = try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any], "\(bad)")
            #expect(object["error"] is String, "\(bad)")
        }
        let unknown = try Self.call(s, "noSuchMethod", id: 9)
        #expect(unknown["id"] as? Int == 9)
        #expect((unknown["error"] as? String)?.contains("noSuchMethod") == true)
    }

    @Test func aFileThatIsNotAProjectIsAnErrorNotACrash() throws {
        let s = Self.service()
        let file = AppTestSupport.tempDir().appendingPathComponent("x.loftline")
        try Data("not a project".utf8).write(to: file)
        #expect(try Self.call(s, "open", ["path": file.path])["error"] is String)
        #expect(try Self.call(s, "open", ["path": "/no/such/file.loftline"])["error"] is String)
    }

    @Test func editsUndoAndRedo() throws {
        let s = Self.service()
        _ = try Self.result(Self.call(s, "new"))
        let added = try Self.result(Self.call(s, "addShape", ["tool": "rectangle", "from": ["x": 1, "y": 1], "to": ["x": 3, "y": 2]]))
        #expect(((added["project"] as? [String: Any])?["document"] as? [String: Any])?["shapes"].flatMap { ($0 as? [Any])?.count } == 1)
        #expect(added["isDirty"] as? Bool == true)
        #expect(added["undoAction"] as? String == "Add Rectangle")
        let undone = try Self.result(Self.call(s, "undo"))
        #expect(((undone["project"] as? [String: Any])?["document"] as? [String: Any])?["shapes"].flatMap { ($0 as? [Any])?.count } == 0)
        #expect(undone["isDirty"] as? Bool == false)
        let redone = try Self.result(Self.call(s, "redo"))
        #expect(((redone["project"] as? [String: Any])?["document"] as? [String: Any])?["shapes"].flatMap { ($0 as? [Any])?.count } == 1)
    }

    @Test func aToolpathGoesStaleWhenTheDesignMoves() throws {
        let s = Self.service()
        _ = try Self.result(Self.call(s, "open", ["path": Self.root.appendingPathComponent("samples/sign.loftline").path]))
        let calculated = try Self.result(Self.call(s, "calculate"))
        let before = try #require(calculated["statuses"] as? [[String: Any]])
        #expect(before.allSatisfy { $0["isStale"] as? Bool == false })
        let shapeID = s.session.project.document.shapes[0].id.uuidString
        let moved = try Self.result(Self.call(s, "translateShapes", ["ids": [shapeID], "by": ["x": 1, "y": 0]]))
        let after = try #require(moved["statuses"] as? [[String: Any]])
        #expect(after.allSatisfy { $0["isStale"] as? Bool == true })
    }

    // MARK: The project's post and machine

    /// The sign, with its file's JSON edited before it opens.
    static func openSign(_ s: CoreService, changing change: (inout [String: Any]) -> Void) throws {
        let data = try Data(contentsOf: root.appendingPathComponent("samples/sign.loftline"))
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        change(&object)
        let file = AppTestSupport.tempDir().appendingPathComponent("edited.loftline")
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        _ = try result(call(s, "open", ["path": file.path]))
    }

    static func changingSnapshot(_ object: inout [String: Any], _ change: (inout [String: Any]) -> Void) {
        var post = object["postSnapshot"] as! [String: Any]
        change(&post)
        object["postSnapshot"] = post
    }

    @Test func aPostOnlyTheProjectCarriesPostsFromItsCopy() throws {
        let s = Self.service()
        try Self.openSign(s) { object in
            object["postProfileID"] = "carried-post"
            Self.changingSnapshot(&object) { $0["id"] = "carried-post"; $0["name"] = "Carried" }
        }
        let own = try Self.result(Self.call(s, "export", ["postID": "carried-post"]))
        #expect(own["post"] as? String == "Carried")
        let plain = try Self.result(Self.call(s, "export"))
        #expect(own["text"] as? String == plain["text"] as? String)
        _ = try Self.result(Self.call(s, "saveAll", ["mode": "oneFile", "postID": "carried-post"]))
        #expect((try Self.call(s, "export", ["postID": "no-such-post"])["error"] as? String)?.contains("no-such-post") == true)
    }

    @Test func theProjectsCopyWinsOverTheInstalledPostOfTheSameID() throws {
        let s = Self.service()
        try Self.openSign(s) { object in Self.changingSnapshot(&object) { $0["fileExtension"] = "abc" } }
        let id = s.session.resolved.post.id
        let posted = try Self.result(Self.call(s, "export", ["postID": id]))
        #expect((posted["fileName"] as? String)?.hasSuffix(".abc") == true)
        let saved = try Self.result(Self.call(s, "saveAll", ["mode": "oneFile", "postID": id]))
        let files = try #require(saved["files"] as? [[String: Any]])
        #expect((files.first?["fileName"] as? String)?.hasSuffix(".abc") == true)
    }

    @Test func theJobFormHasTheProjectsOwnMachine() throws {
        let s = Self.service()
        _ = try Self.result(Self.call(s, "open", ["path": Self.root.appendingPathComponent("samples/sign.loftline").path]))
        let own = try Self.result(Self.call(s, "jobForm"))
        #expect(own["machineID"] as? String == s.session.resolved.machine?.id)
        s.session.perform("Missing machine") { $0.machineID = "gone"; $0.machineSnapshot = nil }
        let missing = try Self.result(Self.call(s, "jobForm"))
        #expect(missing["machineID"] as? String == "gone")
        let choices = try #require(missing["machineChoices"] as? [[String: Any]])
        #expect(choices.contains { $0["id"] as? String == "gone" && ($0["title"] as? String)?.contains("not installed") == true })
    }

    // MARK: Job Setup

    static func json<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }

    @Test func switchingUnitsConvertsEveryLengthAndApplyingKeepsThem() throws {
        let s = Self.service()
        s.session.perform("Fixture") { p in
            p = AppTestSupport.project()
            p.document.job.datumOffset = Vec2(0.5, 0.25)
            p.document.job.touchOffSpot = Vec2(1, 2)
            p.document.job.plungeGap = 0.1
        }
        let original = s.session.project
        let reply = try Self.result(Self.call(s, "convertJob", ["units": "inch", "job": try Self.json(original.document.job),
                                                                "gridSpacing": original.document.gridSpacing, "to": "millimeter"]))
        let converted = try #require(reply["job"] as? [String: Any])
        #expect((converted["datumOffset"] as? [String: Double])?["x"] == 12.7)
        #expect((converted["touchOffSpot"] as? [String: Double])?["y"] == 50.8)
        #expect(converted["plungeGap"] as? Double == 0.1 * 25.4)
        #expect(reply["gridSpacing"] as? Double == original.document.gridSpacing * 25.4)
        _ = try Self.result(Self.call(s, "setJob", ["units": "millimeter", "job": converted, "gridSpacing": reply["gridSpacing"]!]))
        #expect(s.session.project.document.units == .millimeter)
        #expect(s.session.project.document.job == original.converted(to: .millimeter).document.job)
    }

    @Test func aJobThatCannotBeCutIsRefusedAsTheMacsFormRefusesIt() throws {
        let s = Self.service()
        var job = s.session.project.document.job
        job.safeZ = 0
        let reply = try Self.call(s, "setJob", ["units": "inch", "job": try Self.json(job)])
        #expect((reply["error"] as? String)?.contains("Safe Z") == true)
        #expect(s.session.project.document.job.safeZ != 0)
    }

    @Test func aLinkedFieldFollowsAnEditAsOnTheMac() throws {
        let s = Self.service()
        s.session.perform("Fixture") { p in
            p = AppTestSupport.project()
            p.document.job.thickness = 0.5
            p.document.linkedValues = [VariableLink(target: .job(sheetID: MaterialSheet.primaryID), path: ["safeZ"], expression: "=thickness*2")]
        }
        s.session.perform("Thicker") { $0.document.job.thickness = 0.75 }
        #expect(s.session.project.document.job.safeZ == 1.5)
    }

    // MARK: Tools

    /// A project whose one toolpath uses `tool`, carried.
    static func projectUsing(_ s: CoreService) throws -> Tool {
        s.session.perform("Fixture") { p in
            p = AppTestSupport.project()
            p.operations = [OperationFactory.make(kind: .profile, project: p, library: s.session.library, shapeIDs: [p.document.shapes[0].id])!]
        }
        return try #require(s.session.project.tools.first)
    }

    @Test func savingAToolThatTheProjectCarriesUnchangedChangesTheProject() throws {
        let s = Self.service()
        var tool = try Self.projectUsing(s)
        tool.feedRate += 10
        let reply = try Self.call(s, "saveTool", ["tool": try Self.json(tool)])
        #expect(reply["error"] == nil)
        #expect(s.session.project.tools.first?.feedRate == tool.feedRate)
        #expect(s.session.library.tool(id: tool.id)?.feedRate == tool.feedRate)
    }

    @Test func savingAToolOnlyTheProjectHadChangesTheProject() throws {
        let s = Self.service()
        _ = try Self.result(Self.call(s, "open", ["path": Self.root.appendingPathComponent("samples/sign.loftline").path]))
        var tool = try #require(s.session.project.tools.first)
        var library = s.session.library
        library.tools.removeAll { $0.id == tool.id }
        try s.session.saveLibrary(library)
        tool.feedRate += 10
        #expect(try Self.call(s, "saveTool", ["tool": try Self.json(tool)])["error"] == nil)
        #expect(s.session.project.tools.first { $0.id == tool.id }?.feedRate == tool.feedRate)
    }

    @Test func aToolThatHadAlreadyDivergedKeepsTheProjectsCopy() throws {
        let s = Self.service()
        let carried = try Self.projectUsing(s)
        s.session.perform("Diverge") { $0.tools[0].diameter += 0.1 }
        var edited = carried
        edited.feedRate += 10
        #expect(try Self.call(s, "saveTool", ["tool": try Self.json(edited)])["error"] == nil)
        #expect(s.session.project.tools.first?.diameter == carried.diameter + 0.1)
    }

    // MARK: Two-sided jobs and sheets

    static func twoSided(_ s: CoreService) {
        s.session.perform("Fixture") { p in
            p = AppTestSupport.project()
            var form = JobSetupForm(document: p.document)
            form.job.twoSided = TwoSidedSetup(flip: .leftRight, bottomZZero: .spoilboard)
            p = form.apply(to: p)
            let bottomLayer = p.document.layers.first { $0.side == .bottom }!.id
            p.document.shapes[1].layerID = bottomLayer
            let top = OperationFactory.make(kind: .profile, project: p, library: s.session.library, shapeIDs: [p.document.shapes[0].id])!
            var bottom = OperationFactory.make(kind: .profile, project: p, library: s.session.library, shapeIDs: [p.document.shapes[1].id])!
            var setup = bottom.editableSetup
            setup.name = "Bottom profile"
            bottom.editableSetup = setup
            p.operations = [top, bottom]
        }
    }

    @Test func theSideOnShowIsTheSideThatPosts() throws {
        let s = Self.service()
        Self.twoSided(s)
        let top = try Self.result(Self.call(s, "state"))
        #expect(top["side"] as? String == "top")
        #expect((top["coverage"] as? String)?.contains("Top side") == true)
        let topProgram = try Self.result(Self.call(s, "export"))["text"] as? String

        let bottom = try Self.result(Self.call(s, "setSide", ["side": "bottom"]))
        #expect(bottom["side"] as? String == "bottom")
        #expect((bottom["coverage"] as? String)?.contains("Bottom side") == true)
        let bottomProgram = try Self.result(Self.call(s, "export"))["text"] as? String
        #expect(bottomProgram != nil && bottomProgram != topProgram)

        let saved = try Self.result(Self.call(s, "saveAll", ["mode": "filePerToolpath"]))
        let files = try #require(saved["files"] as? [[String: Any]])
        #expect(files.map { $0["title"] as? String } == ["Bottom profile"])
        #expect(s.session.previewToolpaths(groupByTool: false).map(\.name) == ["Bottom profile"])
        let sheet = AppTestSupport.tempDir().appendingPathComponent("sheet.html")
        _ = try Self.call(s, "jobSheet", ["path": sheet.path])
        #expect(try String(contentsOf: sheet, encoding: .utf8).contains("(Bottom side)"))
    }

    @Test func aOneSidedJobIsAlwaysOnTop() throws {
        let s = Self.service()
        Self.twoSided(s)
        _ = try Self.result(Self.call(s, "setSide", ["side": "bottom"]))
        s.session.perform("One side") { $0.document.job.twoSided = nil }
        let state = try Self.result(Self.call(s, "state"))
        #expect(state["side"] as? String == "top")
        #expect(state["coverage"] == nil)
        #expect(try Self.result(Self.call(s, "setSide", ["side": "bottom"]))["side"] as? String == "top")
    }

    @Test func openingAFileShowsItsTopSide() throws {
        let s = Self.service()
        Self.twoSided(s)
        _ = try Self.result(Self.call(s, "setSide", ["side": "bottom"]))
        _ = try Self.result(Self.call(s, "open", ["path": Self.root.appendingPathComponent("samples/sign.loftline").path]))
        #expect(s.session.activeSide == .top)
    }

    @Test func aJobOfSeveralSheetsSaysWhichOneIsPosting() throws {
        let s = Self.service()
        s.session.perform("Fixture") { p in
            p = AppTestSupport.project()
            _ = p.document.addSheet(name: "Second", job: JobSetup(width: 10, height: 10, thickness: 0.5), layerName: "B", colorHex: "#336699")
        }
        let state = try Self.result(Self.call(s, "state"))
        #expect((state["coverage"] as? String)?.contains(s.session.project.document.currentSheetName) == true)
    }
}
