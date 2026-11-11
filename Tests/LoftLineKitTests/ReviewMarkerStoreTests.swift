import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineKit

/// The review marker kept on disk (spec 2, "The review marker"): it survives a reopen, only Dismiss clears it, Save As takes
/// it along, and Check Toolpaths warns while it's up.
@Suite struct ReviewMarkerStoreTests {
    static func paths() -> (store: URL, job: URL) {
        let dir = AppTestSupport.tempDir()
        let job = dir.appendingPathComponent("Sign.loftline")
        FileManager.default.createFile(atPath: job.path, contents: Data("x".utf8))
        return (dir.appendingPathComponent("review.json"), job)
    }

    @Test func countSurvivesANewStore() throws {
        let (file, job) = Self.paths()
        try ReviewMarkerStore(file: file).add(2, for: job)
        try ReviewMarkerStore(file: file).add(1, for: job)
        #expect(ReviewMarkerStore(file: file).count(for: job) == 3)
    }

    @Test func dismissRemoves() throws {
        let (file, job) = Self.paths()
        let store = ReviewMarkerStore(file: file)
        try store.add(1, for: job)
        try store.dismiss(job)
        #expect(store.count(for: job) == 0)
    }

    @Test func moveFollowsSaveAs() throws {
        let (file, job) = Self.paths()
        let store = ReviewMarkerStore(file: file)
        try store.add(4, for: job)
        let to = job.deletingLastPathComponent().appendingPathComponent("Sign 2.loftline")
        FileManager.default.createFile(atPath: to.path, contents: Data("x".utf8))
        try store.move(from: job, to: to)
        #expect(store.count(for: job) == 0)
        #expect(store.count(for: to) == 4)
    }

    @Test func realPathKeysThroughALink() throws {
        let (file, job) = Self.paths()
        let link = job.deletingLastPathComponent().appendingPathComponent("Link.loftline")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: job)
        let store = ReviewMarkerStore(file: file)
        try store.add(1, for: link)
        #expect(store.count(for: job) == 1)
    }

    @Test func reportCarriesTheWarning() throws {
        let project = LoftLineProject(document: Document())
        let report = ValidationReport.make(project: project, results: [:], profile: BuiltInPosts.avidMach4Inch, groupByTool: false,
                                           assistantChanges: 5)
        let warning = report.allIssues.first { $0.message == "Changed by an assistant (5 changes)" }
        #expect(warning?.severity == .warning)
        #expect(report.errorCount == 0)
    }

    @Test func zeroAddsNoWarning() throws {
        let project = LoftLineProject(document: Document())
        let report = ValidationReport.make(project: project, results: [:], profile: BuiltInPosts.avidMach4Inch, groupByTool: false)
        #expect(!report.allIssues.contains { $0.message.hasPrefix("Changed by an assistant") })
    }

    @Test func oneChangeIsSingular() throws {
        let report = ValidationReport.make(project: LoftLineProject(document: Document()), results: [:], profile: BuiltInPosts.avidMach4Inch,
                                           groupByTool: false, assistantChanges: 1)
        #expect(report.allIssues.contains { $0.message == "Changed by an assistant (1 change)" })
    }
    /// The desktop shows the core's wording (#142), not its own copy.
    @Test func theStatusCarriesTheReportsWording() {
        #expect(ValidationReport.assistantChangesWarning(0) == nil)
        #expect(ValidationReport.assistantChangesWarning(1) == "Changed by an assistant (1 change)")
        #expect(AssistantStatus(changeRevision: 0, changes: 3).warning == "Changed by an assistant (3 changes)")
        #expect(AssistantStatus(changeRevision: 0).warning == nil)
    }

}
