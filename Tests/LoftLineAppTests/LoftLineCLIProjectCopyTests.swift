import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp

/// The command line posts with the project's own copy of its post and machine, as the app does.
@Suite struct LoftLineCLIProjectCopyTests {
    let inch = BuiltInPosts.avidMach4Inch
    let avid = BuiltInMachines.avidPRO6096

    func signProject() throws -> LoftLineProject {
        var p = try LoftLineProject.decode(from: Data(contentsOf: URL(fileURLWithPath: LoftLineCLITests.sign)))
        p.postProfileID = inch.id
        return p
    }

    func write(_ p: LoftLineProject, name: String = "copy.loftline") throws -> String {
        let file = LoftLineCLITests.folder().appendingPathComponent(name)
        try p.encoded().write(to: file)
        return file.path
    }

    /// The sign with a copy of the inch post whose footer is not the built-in's.
    func projectWithEditedCopy() throws -> LoftLineProject {
        var p = try signProject()
        var copy = inch
        copy.footer = ["M30", "(copy footer)"]
        p.postSnapshot = try copy.snapshot()
        return p
    }

    @Test @MainActor func postsFromTheCopyAndWarnsThatItDiffers() throws {
        let project = try projectWithEditedCopy()
        let r = LoftLineCLITests.run(["export", try write(project), "--out", "-", "--builtin-only"])
        #expect(r.status == 0, "\(r.err)")
        #expect(r.out.contains("(copy footer)"))
        #expect(r.err.contains("differs from the installed"))
        // Byte for byte what the app posts for the same file.
        #expect(r.out == (try LoftLineCLITests.appExport(project)))
        // Without the copy the built-in footer posts.
        var plain = project
        plain.postSnapshot = nil
        #expect(!LoftLineCLITests.run(["export", try write(plain, name: "plain.loftline"), "--out", "-", "--builtin-only"]).out.contains("(copy footer)"))
    }

    @Test func anExplicitPostIsTheInstalledOneEvenWhenItsIDEqualsTheCopys() throws {
        let file = try write(projectWithEditedCopy())
        let r = LoftLineCLITests.run(["export", file, "--post", inch.id, "--out", "-", "--builtin-only"])
        #expect(r.status == 0, "\(r.err)")
        #expect(!r.out.contains("(copy footer)"), "the installed post posts, not the copy")
        #expect(!r.err.contains("copy of"), "the copy is not in play, so it is not warned about")
    }

    @Test func builtinOnlyKeepsTheProjectsOwnCopyOfAPostThatIsNotInstalled() throws {
        var p = try signProject()
        var ghost = inch
        ghost.id = "ghost"; ghost.name = "Ghost"; ghost.footer = ["M30", "(ghost footer)"]
        p.postProfileID = "ghost"; p.postSnapshot = try ghost.snapshot()
        let r = LoftLineCLITests.run(["export", try write(p), "--out", "-", "--builtin-only"])
        #expect(r.status == 0, "\(r.err)")
        #expect(r.out.contains("(ghost footer)") && !r.err.contains("Pick a post"), "no missing-post error")
        #expect(r.err.contains("warning:") && r.err.contains("not installed on this Mac"), "but the copy is called out")
    }

    @Test func theOverrideReplacesOnlyThePostAndNeverRewritesTheMachineTheProjectInfers() throws {
        // No chosen machine: the machine is inferred from the project's own post (Avid). An override to the GRBL post
        // keeps that machine's limits, as the command line always has, and the rapid rate stays the project's own post's.
        var p = try signProject()
        p.machineID = nil; p.postProfileID = inch.id
        let profiles = BuiltInPosts.all, machines = BuiltInMachines.all
        let r = try #require(LoftLineCLI.resolvePost(project: p, override: BuiltInPosts.genericGRBLMM.id, profiles: profiles, machines: machines))
        #expect(r.profile.limits == avid.applied(to: BuiltInPosts.genericGRBLMM).limits)
        #expect(r.profile.id == BuiltInPosts.genericGRBLMM.id)
        #expect(r.own.id == inch.id, "the rapid rate comes from the project's own post")
        #expect(r.issues.isEmpty)
        #expect(LoftLineCLI.resolvePost(project: p, override: "no-such", profiles: profiles, machines: machines) == nil)
    }

    @Test func anOverrideSilencesTheMissingPostErrorOfTheProjectsOwnPost() throws {
        var p = try signProject()
        p.postProfileID = "gone"; p.postSnapshot = nil
        let without = try #require(LoftLineCLI.resolvePost(project: p, override: nil, profiles: BuiltInPosts.all, machines: BuiltInMachines.all))
        #expect(without.issues.contains { $0.severity == .error })
        let with = try #require(LoftLineCLI.resolvePost(project: p, override: inch.id, profiles: BuiltInPosts.all, machines: BuiltInMachines.all))
        #expect(with.issues.isEmpty)
    }

    @Test func aCopyItCannotReadIsRefusedWithTheMessage() throws {
        for bad in ProjectOpeningTests.Bad.allCases {
            let (data, message) = try bad.make()
            let file = LoftLineCLITests.folder().appendingPathComponent("bad.loftline")
            try data.write(to: file)
            let r = LoftLineCLITests.run(["export", file.path, "--out", "-", "--builtin-only"])
            #expect(r.status == 2 && r.out.isEmpty, "\(bad)")
            #expect(r.err.contains(message), "\(bad): \(r.err)")
        }
    }
}
