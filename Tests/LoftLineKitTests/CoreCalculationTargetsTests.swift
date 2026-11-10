import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineKit

/// E (review 86da8cce): posting and checking calculate what the touch-plate check reads, as the Mac's Save All and Check Toolpaths
/// do (`GCodeExporter.calculationTargets`), so a switched-off or stale toolpath on the sheet is never judged from an old result.
@Suite struct CoreCalculationTargetsTests {
    @Test func aSwitchedOffToolpathOnTheSheetIsCalculatedBeforeTheCheck() throws {
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
        try CoreServiceTests.openSign(s) { object in
            var doc = object["document"] as! [String: Any]
            var job = doc["job"] as! [String: Any]
            job["touchOffSpot"] = ["x": 12.0, "y": 3.5]
            doc["job"] = job
            object["document"] = doc
        }
        let drill = try #require(s.session.project.operations.first { $0.kind == .drill })
        s.session.perform("Off") { p in
            var setup = drill.editableSetup
            setup.isEnabled = false
            p.upsertOperation(drill.with(setup: setup))
        }
        #expect(s.session.results[drill.id] == nil)
        let report = try s.session.checkReport(context: PostingContext())
        #expect(!report.allIssues.contains { $0.message.contains("is not calculated") }, "\(report.allIssues.map(\.message))")
        let posted = try s.session.postAll(mode: .oneFile, context: PostingContext())
        let refusal = posted.first?.result.errorMessage ?? ""
        #expect(refusal.range(of: "is not calculated") == nil, "\(refusal)")
        #expect(s.session.results[drill.id] != nil)
    }
}
