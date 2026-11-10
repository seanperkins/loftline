import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineKit

/// The Windows and Linux app's Save All runs the checks the Mac's Save All runs (found reviewing the MCP spec).
@Suite struct CoreSaveAllTests {
    typealias T = CoreServiceTests

    static func issues(_ saved: [String: Any]) -> [String] {
        ((saved["files"] as? [[String: Any]]) ?? []).flatMap { ($0["issues"] as? [[String: Any]]) ?? [] }.compactMap { $0["message"] as? String }
    }

    /// A project whose post is neither carried nor installed must not be written with the fallback post, as the Mac refuses.
    @Test func aMissingPostIsRefusedAndNothingIsWritten() throws {
        let s = T.service()
        try T.openSign(s) { object in
            object["postProfileID"] = "gone-post"
            object["postSnapshot"] = nil
        }
        let folder = AppTestSupport.tempDir()
        let saved = try T.result(T.call(s, "saveAll", ["mode": "oneFile", "folder": folder.path]))
        #expect(saved["hasErrors"] as? Bool == true)
        #expect(saved["written"] as? Bool == false)
        #expect(Self.issues(saved).contains { $0.contains("\"gone-post\" is not installed") }, "\(Self.issues(saved))")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    /// A touch-plate post checks the touch-off spot against every toolpath on the sheet: Save All gives the same answer as
    /// posting the one file, not "this export has none".
    @Test func aProbingPostIsCheckedAsTheSingleFileExportIs() throws {
        let dir = AppTestSupport.tempDir()
        var posts = PostProfileStore(directory: dir.appendingPathComponent("posts"))
        posts.readsUserFiles = false
        let machines = MachineStore(directory: dir.appendingPathComponent("machines"))
        var avid = BuiltInMachines.avidPRO6096
        avid.toolChangeProbe = ToolChangeProbe(parkX: 2, parkY: -2, parkZ: -0.5, topZ: 0, plateThickness: 0.5, plateSize: 3,
                                               probeFeed: 5, probeTravel: 0.5, controller: .mach4, mach4ZeroMacro: 199)
        _ = try machines.save(avid)
        let s = CoreService(session: CoreSession(toolStore: ToolLibraryStore(fileURL: dir.appendingPathComponent("tools.json")),
                                                 postStore: posts, machineStore: machines))
        try T.openSign(s) { object in
            var doc = object["document"] as! [String: Any]
            var job = doc["job"] as! [String: Any]
            job["touchOffSpot"] = ["x": 12.0, "y": 3.5]
            doc["job"] = job
            object["document"] = doc
        }
        #expect(s.session.project.document.job.touchOffSpot != nil)
        let single = try T.result(T.call(s, "export"))
        let singleIssues = ((single["issues"] as? [[String: Any]]) ?? []).compactMap { $0["message"] as? String }
        // The probe is on: the program probes (G31) or the touch-off check refused it.
        #expect((single["text"] as? String)?.contains("G31") == true || single["errorMessage"] != nil, "\(singleIssues)")
        #expect(s.session.resolved.post.toolChangeProbe != nil)
        let saved = try T.result(T.call(s, "saveAll", ["mode": "oneFile"]))
        #expect(!Self.issues(saved).contains { $0.contains("this export has none") }, "\(Self.issues(saved))")
        #expect(Self.issues(saved) == singleIssues)
        // The spot lies on Pocket 1's cut: Save All refuses for that reason, and says so, as the single export does.
        let file = try #require((saved["files"] as? [[String: Any]])?.first)
        let reason = try #require(single["errorMessage"] as? String)
        #expect(reason.contains("touch plate"))
        #expect(file["errorMessage"] as? String == reason)
        #expect(file["posted"] as? Bool == false)
    }
}
