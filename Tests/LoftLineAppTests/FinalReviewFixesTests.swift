import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp

/// Findings of the final whole-branch review (debate panel 6dbe3a28) that were graded Important and fixed.
@Suite struct FinalReviewFixesTests {
    typealias Env = ProjectPostDocumentTests.Env
    let inch = BuiltInPosts.avidMach4Inch
    let avid = BuiltInMachines.avidPRO6096

    var ghost: PostProfile {
        var g = inch
        g.id = "ghost"; g.name = "Ghost"
        g.limits = MachineLimits(xTravel: 10, yTravel: 10, zTravel: 2, maxSpoilboardCut: 0.1)
        return g
    }

    // MARK: the post picker lists a carried post that is not installed here

    @Test func thePostPickerListsACarriedPostThatIsNotInstalled() throws {
        let installed = BuiltInPosts.all
        let with = PostProfilePicker.entries(installed: installed, carried: ghost, machine: avid)
        #expect(with.compatible.map(\.id).contains("ghost") == false)
        #expect(with.carried?.id == "ghost" && with.carried?.title == "Ghost (not installed here)")
        let installedCarry = PostProfilePicker.entries(installed: installed, carried: inch, machine: avid)
        #expect(installedCarry.carried == nil, "an installed post is listed once, in its own place")
        #expect(PostProfilePicker.entries(installed: installed, carried: nil, machine: avid).carried == nil)
    }

    @Test func theDocumentNamesItsCarriedPostOnlyWhenItIsNotInstalled() throws {
        var p = LoftLineProject(document: Document(name: "G"), postProfileID: "ghost")
        p.postSnapshot = try ghost.snapshot()
        let env = Env()
        #expect(env.document(p).0.carriedPostNotInstalled?.id == "ghost")
        #expect(env.document(LoftLineProject(document: Document(name: "I"), postProfileID: inch.id)).0.carriedPostNotInstalled == nil)
    }

    // MARK: "post limits only" is remembered, not re-inferred on another Mac

    @Test func attachingRecordsThatNoMachineWasInferred() throws {
        let p = LoftLineProject(document: Document(name: "G"), postProfileID: "ghost", postSnapshot: try ghost.snapshot())
        let attached = ProjectPost.attaching(p, profiles: BuiltInPosts.all, machines: BuiltInMachines.all)
        #expect(attached.machineSnapshot == nil && attached.machineID == nil)
        #expect(attached.machineInferredFor == "ghost", "no machine supports it here, and the file says so")
        #expect(ProjectPost.syncing(attached, profiles: BuiltInPosts.all, machines: BuiltInMachines.all) == attached, "stable")
    }

    @Test func aProjectThatInferredNoMachineKeepsThePostsOwnLimitsOnAMacWhoseMachineListsThePost() throws {
        let p = LoftLineProject(document: Document(name: "G"), postProfileID: "ghost", postSnapshot: try ghost.snapshot())
        let saved = ProjectPost.attaching(p, profiles: BuiltInPosts.all, machines: BuiltInMachines.all)
        var bigBed = avid
        bigBed.id = "big-bed"; bigBed.postIDs = ["ghost"]
        bigBed.limits = MachineLimits(xTravel: 60, yTravel: 96, zTravel: 8, maxSpoilboardCut: 0.1)
        let other = ProjectPost.resolve(saved, profiles: BuiltInPosts.all, machines: [bigBed])
        #expect(other.machine == nil && other.machineSource == nil)
        #expect(other.post.limits == ghost.limits, "a 20 inch toolpath is not allowed through a 10 inch post")
        // A file that never said (format 1, no marker) still infers a machine, as before.
        var legacy = saved
        legacy.machineInferredFor = nil
        #expect(ProjectPost.resolve(legacy, profiles: BuiltInPosts.all, machines: [bigBed]).machine == bigBed)
        // Changing the post invalidates the "none".
        var changed = saved
        changed.postProfileID = inch.id; changed.postSnapshot = nil
        #expect(ProjectPost.resolve(changed, profiles: BuiltInPosts.all, machines: BuiltInMachines.all).machine == avid)
    }

    // MARK: a copy with no installed counterpart is a warning at export

    @Test func anUninstalledPostCopyWarnsAndIsNotAnError() throws {
        var p = LoftLineProject(document: Document(name: "G"), postProfileID: "ghost")
        p.postSnapshot = try ghost.snapshot()
        let (doc, _) = Env().document(p)
        let issue = try #require(doc.postProfileIssues.first)
        #expect(doc.postProfileIssues.count == 1 && issue.severity == .warning)
        #expect(issue.message.contains("Ghost") && issue.message.contains("not installed on this Mac"))
        #expect(doc.copyNotice.warnings.isEmpty, "Job Setup already says '(not installed here)'; no second line")
    }

    @Test func anUninstalledMachineCopySaysItsLimitsComeFromTheFile() throws {
        var custom = avid
        custom.id = "custom-bed"; custom.name = "Custom bed"
        var p = LoftLineProject(document: Document(name: "M"), postProfileID: inch.id, machineID: "custom-bed")
        p.machineSnapshot = try custom.snapshot()
        let (doc, _) = Env().document(p)
        let issue = try #require(doc.postProfileIssues.first { $0.message.contains("Custom bed") })
        #expect(issue.severity == .warning)
        #expect(issue.message.contains("not installed on this Mac") && issue.message.contains("limits come from the file"))
        #expect(issue.message.contains("Job Setup"), "it says what to do about it")
    }

    @Test func pickingAnotherPostDropsTheProjectsOwnPostNotices() throws {
        var p = LoftLineProject(document: Document(name: "G"), postProfileID: "ghost")
        p.postSnapshot = try ghost.snapshot()
        let (doc, _) = Env().document(p)
        #expect(!doc.postProfileIssues(includingPost: true).isEmpty)
        #expect(doc.postProfileIssues(includingPost: false).isEmpty, "the program is posted with another post")
        // The missing-post error is not dropped while the sheet still posts with the project's own (missing) post.
        let (missing, _) = Env().document(LoftLineProject(document: Document(name: "X"), postProfileID: "nope"))
        #expect(missing.postProfileIssues(includingPost: true).contains { $0.severity == .error })
    }

    // MARK: a file cannot ask for a number of decimals that exhausts memory

    @Test func aPostCopyWithAbsurdPrecisionIsRefusedAtOpen() throws {
        for decimals in [1_000_000_000, -1, 13] {
            var bad = inch
            bad.decimals = decimals
            let p = LoftLineProject(document: Document(name: "D"), postProfileID: inch.id, postSnapshot: try bad.snapshot())
            do { _ = try LoftLineProject.opening(from: p.encoded()); Issue.record("opened with decimals \(decimals)") } catch let e as ProjectOpenError {
                #expect(e.message.contains("decimals"), "\(e.message)")
            }
            var feed = inch
            feed.feedDecimals = decimals
            let q = LoftLineProject(document: Document(name: "F"), postProfileID: inch.id, postSnapshot: try feed.snapshot())
            #expect(throws: ProjectOpenError.self) { try LoftLineProject.opening(from: q.encoded()) }
        }
        let fine = LoftLineProject(document: Document(name: "OK"), postProfileID: inch.id, postSnapshot: try inch.snapshot())
        #expect(throws: Never.self) { try LoftLineProject.opening(from: fine.encoded()) }
    }
}
