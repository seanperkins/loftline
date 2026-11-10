import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineKit

/// What the MCP server needs from the engine: one posting context for programs, job sheets and checks (spec
/// docs/superpowers/specs/2026-11-10-loftline-mcp-design.md, "Engine changes").
@Suite struct CorePostingContextTests {
    typealias T = CoreServiceTests

    static func openSign() throws -> CoreService {
        let s = T.service()
        _ = try T.result(T.call(s, "open", ["path": T.root.appendingPathComponent("samples/sign.loftline").path]))
        return s
    }

    /// The sign's toolpaths alternate tools (T1, T6, T9, T1): grouped, both T1 toolpaths come first.
    @Test func jobSheetFollowsTheProgramsGrouping() throws {
        let s = try Self.openSign()
        for grouped in [false, true] {
            let html = try s.session.jobSheetHTML(context: PostingContext(groupByTool: grouped))
            let (result, _) = try s.session.post(scope: .all, postID: nil, side: nil, groupByTool: grouped)
            #expect(result.text != nil)
            let order = s.session.previewToolpaths(groupByTool: grouped).map(\.name)
            let positions = order.compactMap { html.range(of: "<td>\($0)")?.lowerBound }
            #expect(positions.count == order.count && positions == positions.sorted(), "\(order)")
        }
        let grbl = try #require(s.session.profiles.first { $0.id == "generic-grbl-inch" })
        #expect(try s.session.jobSheetHTML(context: PostingContext(postID: grbl.id)).contains("Post: \(JobSheetHTML.escape(grbl.name))"))
    }

    @Test func checkReportFlagsAVectorOutsideTheMaterial() throws {
        let s = try Self.openSign()
        s.session.perform("Outside") { p in
            p.document.add(AppTestSupport.rect(30, 2, 2, 2, layer: p.document.defaultLayerID))
        }
        let report = try s.session.checkReport(context: PostingContext())
        #expect(report.allIssues.contains { $0.message.contains("entirely outside the material") }, "\(report.allIssues.map(\.message))")
        let reply = try T.result(T.call(s, "checkReport"))
        let sections = try #require(reply["sections"] as? [[String: Any]])
        let messages = sections.flatMap { ($0["issues"] as? [[String: Any]]) ?? [] }.compactMap { $0["message"] as? String }
        #expect(messages.contains { $0.contains("entirely outside the material") })
    }

    @Test func checkReportCarriesAMissingPost() throws {
        let s = T.service()
        try T.openSign(s) { object in
            object["postProfileID"] = "gone-post"
            object["postSnapshot"] = nil
        }
        let report = try s.session.checkReport(context: PostingContext())
        #expect(report.allIssues.first?.message.contains("\"gone-post\" is not installed") == true, "\(report.allIssues.map(\.message))")
        #expect(report.errorCount > 0)
    }

    @Test func saveUsesTheGivenWriter() throws {
        let s = try Self.openSign()
        s.session.perform("Edit") { $0.document.name = "Edited" }
        #expect(s.session.isDirty)
        var written: (Data, URL)?
        let url = URL(fileURLWithPath: "/nowhere/edited.loftline")
        try s.session.save(to: url) { data, to in written = (data, to) }
        #expect(written?.1 == url)
        #expect(try LoftLineProject.opening(from: try #require(written?.0)).document.name == "Edited")
        #expect(!s.session.isDirty)
    }
}
