import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp

/// The command line posts a project the way the Export G-code sheet does (issue #17). Every test runs the entry point
/// in-process and reads what it printed.
@Suite struct LoftLineCLITests {
    static let samples = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("samples", isDirectory: true)
    static var sign: String { samples.appendingPathComponent("sign.loftline").path }

    /// What a run printed and its status.
    struct Run {
        var status: Int32
        var out: String
        var err: String
    }

    static func run(_ arguments: [String]) -> Run {
        var out = "", err = ""
        let status = LoftLineCLI.run(arguments, output: LoftLineCLI.Output(standardOutput: { out += $0 }, standardError: { err += $0 }))
        return Run(status: status, out: out, err: err)
    }

    static func folder() -> URL { AppTestSupport.tempDir() }

    /// What the Export G-code sheet makes of `project`: calculate, collect, post (`ExportGCodeSheet.post`).
    @MainActor static func appExport(_ project: LoftLineProject, scope: GCodeExportScope = .all,
                                     library: ToolLibraryModel = AppTestSupport.library()) throws -> String {
        let doc = LoftLineDocument(project: project, toolLibrary: library)
        doc.calculateNow(doc.outputProject(for: scope).operations.filter(\.setup.isEnabled).map(\.id))
        let tps = GCodeExporter.toolpaths(scope: scope, operations: doc.outputProject.operations, results: doc.results,
                                          groupByTool: false)
        let r = GCodeExporter.export(project: doc.outputProject(for: scope), toolpaths: tps, profile: doc.postProfile,
                                     jobName: doc.document.name)
        return try #require(r.text)
    }

    @Test @MainActor func exportWritesTheBytesTheAppsExportMakes() throws {
        let folder = Self.folder()
        let r = Self.run(["export", Self.sign, "--out", folder.path])
        #expect(r.status == 0, "\(r.err)")
        let written = try String(contentsOf: folder.appendingPathComponent("sign.tap"), encoding: .utf8)
        #expect(r.out == "wrote \(folder.appendingPathComponent("sign.tap").path)\n")
        let project = try LoftLineProject.decode(from: Data(contentsOf: URL(fileURLWithPath: Self.sign)))
        #expect(written == (try Self.appExport(project)))
        // And it is the committed golden program, under the name that program was posted with.
        let golden = try String(contentsOf: Self.samples.appendingPathComponent("sign.tap"), encoding: .utf8)
        let named = Self.run(["export", Self.sign, "--name", "Sign", "--out", "-"])
        #expect(named.status == 0 && named.out == golden)
        #expect(written != golden)   // the header's job name is the project's: "Untitled"
    }

    @Test @MainActor func aSingleToolpathIsPostedOnItsOwnLikeTheExportSheetDoes() throws {
        let folder = Self.folder()
        // Matches the name without regard to case.
        let r = Self.run(["export", Self.sign, "--operation", "pocket 1", "--out", folder.path, "--quiet"])
        #expect(r.status == 0 && r.out.isEmpty, "\(r.err)")
        let written = try String(contentsOf: folder.appendingPathComponent("sign_Pocket_1.tap"), encoding: .utf8)
        let project = try LoftLineProject.decode(from: Data(contentsOf: URL(fileURLWithPath: Self.sign)))
        let pocket = try #require(project.operations.first { $0.setup.name == "Pocket 1" })
        #expect(written == (try Self.appExport(project, scope: .operation(pocket.id))))
        #expect(written.contains("Pocket 1") && !written.contains("Profile 1"))
    }

    @Test @MainActor func aToolEditedInTheProjectIsThePostedTool() throws {
        // A seeded tool edited in the app is saved in the project's snapshot; the command line must cut with that tool, not
        // with the seeded original of the same id (library entries win over a snapshot in `mergedTools`).
        var project = try LoftLineProject.decode(from: Data(contentsOf: URL(fileURLWithPath: Self.sign)))
        let id = ToolLibrary.seeded.tools[0].id
        let at = try #require(project.tools.firstIndex { $0.id == id })
        project.tools[at].feedRate = 55
        let folder = Self.folder()
        let file = folder.appendingPathComponent("edited.loftline")
        try project.encoded().write(to: file)
        let r = Self.run(["export", file.path, "--out", "-", "--builtin-only"])
        #expect(r.status == 0, "\(r.err)")
        #expect(r.out.contains("F55.0"))
        // The app with that edit in its library posts the same program.
        let library = AppTestSupport.library()
        library.update(project.tools[at])
        #expect(r.out == (try Self.appExport(project, library: library)))
        // And the unedited sample does not have that feed.
        let plain = Self.run(["export", Self.sign, "--out", "-", "--builtin-only"])
        #expect(!plain.out.contains("F55.0"))
    }

    @Test func aSwitchedOffToolpathThatFailsIsReportedWhenAskedFor() throws {
        var project = try LoftLineProject.decode(from: Data(contentsOf: URL(fileURLWithPath: Self.sign)))
        let i = try #require(project.operations.firstIndex { $0.setup.name == "Profile 1" })
        var setup = project.operations[i].editableSetup
        setup.isEnabled = false
        setup.shapeIDs = []   // nothing to cut: the toolpath fails to calculate
        project.operations[i] = project.operations[i].with(setup: setup)
        let folder = Self.folder()
        let file = folder.appendingPathComponent("failing.loftline")
        try project.encoded().write(to: file)
        let r = Self.run(["export", file.path, "--operation", "Profile 1", "--out", folder.path])
        #expect(r.status == 1)
        #expect(r.err.contains("Profile 1 is missing from the program"))
        // Left out of the whole program, as the Export sheet leaves out a switched-off toolpath.
        let all = Self.run(["export", file.path, "--out", folder.path, "--quiet"])
        #expect(all.status == 0, "\(all.err)")
    }

    @Test @MainActor func aPostThatIsNotInstalledFallsBackAsTheAppDoes() throws {
        // A millimeter project whose saved post is gone: the app's catalog falls back to the default post (the inch Avid),
        // not to the millimeter one; the command line must write what the sheet would (the missing post is an error: forced).
        var project = try LoftLineProject.decode(from: Data(contentsOf: URL(fileURLWithPath: Self.sign)))
        project = project.converted(to: .millimeter)
        project.postProfileID = "no-such-post"
        let folder = Self.folder()
        let file = folder.appendingPathComponent("gone.loftline")
        try project.encoded().write(to: file)
        let refused = Self.run(["export", file.path, "--out", "-", "--builtin-only"])
        #expect(refused.status == 1 && refused.err.contains("post \"no-such-post\" is not installed") && refused.out.isEmpty)
        let r = Self.run(["export", file.path, "--out", "-", "--builtin-only", "--force"])
        #expect(r.status == 1)
        #expect(r.out == (try Self.appExport(project)))
        // The inch Avid post, though the project is in millimeters (the header names the post's own units).
        #expect(r.out.contains("Post: Avid PRO6096 Mach4 [inch]"))
    }

    @Test @MainActor func aProjectThatNamesNoPostUsesTheDefaultForItsUnits() throws {
        // Valid file state (`postProfileID` is optional): a millimeter project gets the millimeter Avid post, as in the app.
        var project = try LoftLineProject.decode(from: Data(contentsOf: URL(fileURLWithPath: Self.sign))).converted(to: .millimeter)
        project.postProfileID = nil
        let folder = Self.folder()
        let file = folder.appendingPathComponent("nopost.loftline")
        try project.encoded().write(to: file)
        let r = Self.run(["export", file.path, "--out", "-", "--builtin-only"])
        #expect(r.status == 0, "\(r.err)")
        #expect(r.out.contains("Post: Avid PRO6096 Mach4 [mm]"))
        #expect(r.out == (try Self.appExport(project)))
        // An inch project gets the inch one.
        project = try LoftLineProject.decode(from: Data(contentsOf: URL(fileURLWithPath: Self.sign)))
        project.postProfileID = nil
        try project.encoded().write(to: file)
        #expect(Self.run(["export", file.path, "--out", "-", "--builtin-only"]).out.contains("Post: Avid PRO6096 Mach4 [inch]"))
    }

    @Test func anExplicitPostAnswersTheNotInstalledPostError() throws {
        // The saved post is gone: without --post that is an error to settle ("Pick a post before saving"); naming an installed
        // post is the settling, so the run is clean (the file would be saved with the post chosen, as the sheet does).
        var project = try LoftLineProject.decode(from: Data(contentsOf: URL(fileURLWithPath: Self.sign)))
        project.postProfileID = "no-such-post"
        let folder = Self.folder()
        let file = folder.appendingPathComponent("gone.loftline")
        try project.encoded().write(to: file)
        #expect(Self.run(["export", file.path, "--out", "-", "--builtin-only"]).status == 1)
        let chosen = Self.run(["export", file.path, "--post", BuiltInPosts.avidMach4Inch.id, "--out", "-", "--builtin-only"])
        #expect(chosen.status == 0, "\(chosen.err)")
        #expect(chosen.out.contains("Post: Avid PRO6096 Mach4 [inch]"))
    }

    @Test func forceNeverWritesAProgramThatIsShortOfAToolpath() throws {
        // An enabled toolpath that cannot calculate is a step missing from the program, whatever --force is for.
        var project = try LoftLineProject.decode(from: Data(contentsOf: URL(fileURLWithPath: Self.sign)))
        let i = try #require(project.operations.firstIndex { $0.setup.name == "Profile 1" })
        var setup = project.operations[i].editableSetup
        setup.shapeIDs = []
        project.operations[i] = project.operations[i].with(setup: setup)
        let folder = Self.folder()
        let file = folder.appendingPathComponent("short.loftline")
        try project.encoded().write(to: file)
        for flags in [[String](), ["--force"]] {
            let r = Self.run(["export", file.path, "--out", folder.path] + flags)
            #expect(r.status == 1 && r.err.contains("Profile 1 is missing from the program") && r.err.contains("nothing written"))
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("short.tap").path))
        }
    }

    @Test func builtinOnlyStoresDoNotReadTheUsersFiles() throws {
        let folder = Self.folder()
        var override = BuiltInPosts.avidMach4Inch
        override.name = "A user's Avid"
        try override.toJSON().write(to: folder.appendingPathComponent("\(override.id).json"))   // a post file is named after its id
        var store = PostProfileStore(directory: folder)
        #expect(store.allProfiles().first { $0.id == override.id }?.name == "A user's Avid")
        store.readsUserFiles = false
        #expect(store.allProfiles() == BuiltInPosts.all)
        var machines = MachineStore(directory: folder)
        machines.readsUserFiles = false
        #expect(machines.allMachines() == BuiltInMachines.all)
    }

    @Test func aPostIsChosenByIdAndListed() throws {
        let posts = Self.run(["posts", "--builtin-only"])
        #expect(posts.status == 0)
        #expect(posts.out.split(separator: "\n").map { $0.split(separator: "\t")[0] }
                == BuiltInPosts.all.map { Substring($0.id) })
        let folder = Self.folder()
        let r = Self.run(["export", Self.sign, "--post", "generic-grbl-mm", "--builtin-only", "--out", folder.path])
        #expect(r.status == 0 || r.status == 1, "\(r.err)")
        let text = try String(contentsOf: folder.appendingPathComponent("sign.\(BuiltInPosts.genericGRBLMM.fileExtension)"),
                              encoding: .utf8)
        #expect(text.contains("Generic GRBL"))
        // An unknown post names the ones there are, and writes nothing.
        let unknown = Self.run(["export", Self.sign, "--post", "nope", "--builtin-only", "--out", Self.folder().path])
        #expect(unknown.status == 2)
        #expect(unknown.err.contains("unknown post \"nope\"") && unknown.err.contains("generic-grbl-mm"))
    }

    /// The sign with its profile cut far past the spoilboard: the validator reports an error.
    static func deepSign(into folder: URL) throws -> String {
        var project = try LoftLineProject.decode(from: Data(contentsOf: URL(fileURLWithPath: sign)))
        for i in project.operations.indices {
            guard case .profile(var p) = project.operations[i] else { continue }
            p.params.depth.cutDepth = project.document.job.thickness + 1
            project.operations[i] = .profile(p)
        }
        let url = folder.appendingPathComponent("deep.loftline")
        try project.encoded().write(to: url)
        return url.path
    }

    @Test func validatorErrorsFailTheRunAndWriteNothingUnlessForced() throws {
        let folder = Self.folder()
        let file = try Self.deepSign(into: folder)
        let out = folder.appendingPathComponent("out")
        let refused = Self.run(["export", file, "--out", out.path])
        #expect(refused.status == 1)
        #expect(refused.err.contains("error:") && refused.err.contains("nothing written"))
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("deep.tap").path))
        // --force writes it and still says it failed.
        let forced = Self.run(["export", file, "--out", out.path, "--force"])
        #expect(forced.status == 1)
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("deep.tap").path))
    }

    @Test func warningsAreReportedButDoNotFailTheRun() throws {
        // The sign cut out with its tabs off: a through cut with nothing holding the part is a pre-flight warning.
        var project = try LoftLineProject.decode(from: Data(contentsOf: URL(fileURLWithPath: Self.sign)))
        for i in project.operations.indices {
            guard case .profile(var p) = project.operations[i] else { continue }
            p.params.tabs.isEnabled = false
            project.operations[i] = .profile(p)
        }
        let folder = Self.folder()
        let file = folder.appendingPathComponent("untabbed.loftline")
        try project.encoded().write(to: file)
        let r = Self.run(["export", file.path, "--out", folder.path, "--quiet"])
        #expect(r.status == 0, "\(r.err)")
        #expect(r.err.contains("warning:"))
        #expect(!r.err.contains("error:"))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("untabbed.tap").path))
        // Every report line is `severity: message`.
        for line in r.err.split(separator: "\n") { #expect(line.hasPrefix("warning:") || line.hasPrefix("error:"), "\(line)") }
    }

    @Test func badInvocationsExitTwoAndSayWhy() throws {
        let cases: [([String], String)] = [
            ([], "usage:"),
            (["frobnicate"], "unknown command"),
            (["export"], "needs a .loftline file"),
            (["export", Self.sign, "--side", "middle"], "--side is top or bottom"),
            (["export", Self.sign, "--bogus"], "unknown option --bogus"),
            (["export", Self.sign, "--post"], "--post needs a value"),
            (["export", Self.sign, "--out", "--force"], "--out needs a value"),
            (["posts", "--force"], "posts takes only --builtin-only"),
            (["posts", "sign.loftline"], "posts takes only --builtin-only"),
            (["export", Self.sign, "--force=yes"], "takes no value"),
            (["export", Self.sign, "extra.loftline"], "unexpected argument"),
            (["export", "/nonexistent/none.loftline"], "cannot read"),
            (["export", Self.sign, "--operation", "Nothing"], "no toolpath named"),
        ]
        for (arguments, expected) in cases {
            let r = Self.run(arguments)
            #expect(r.status == 2 && r.err.contains(expected), "\(arguments): \(r.status) \(r.err)")
        }
        // A file that is not a project.
        let junk = Self.folder().appendingPathComponent("junk.loftline")
        try Data("not json".utf8).write(to: junk)
        let r = Self.run(["export", junk.path])
        #expect(r.status == 2 && r.err.contains("is not a LoftLine project"))
        // Help is not an error.
        #expect(Self.run(["help"]).status == 0)
    }

    /// `scripts/check-samples.sh` in a test: every sample posted with every built-in post is the committed program, so the
    /// whole app (CAM, posts, validator) is guarded by the suite as well as by CI. After an intended change:
    /// `scripts/check-samples.sh --update`.
    @Test func everySampleWithEveryBuiltInPostIsTheCommittedProgram() throws {
        let expected = Self.samples.appendingPathComponent("expected", isDirectory: true)
        let sampleNames = try FileManager.default.contentsOfDirectory(atPath: Self.samples.path)
            .filter { $0.hasSuffix(".loftline") }.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }.sorted()
        #expect(sampleNames.count >= 2)
        var compared = 0
        for post in BuiltInPosts.all {
            for name in sampleNames {
                let r = Self.run(["export", Self.samples.appendingPathComponent(name + ".loftline").path, "--post", post.id,
                                  "--builtin-only", "--out", "-"])
                // The one expected message: a post that only stops for a tool change warns on a sample with two tools.
                let other = r.err.split(separator: "\n").filter { !$0.hasPrefix("warning: This program changes tools") }
                #expect(r.status == 0 && other.isEmpty, "\(name) with \(post.id): \(r.err)")
                let file = expected.appendingPathComponent(post.id).appendingPathComponent(
                    GCodeExporter.suggestedFileName(jobName: name, operationName: nil, profile: post))
                let committed = try String(contentsOf: file, encoding: .utf8)
                #expect(r.out == committed, "\(name) with \(post.id) differs from \(file.path)")
                compared += 1
            }
        }
        #expect(compared == BuiltInPosts.all.count * sampleNames.count)
    }

    @Test func theCommandLineIsOnlyAskedForByItsNameOrItsCommand() {
        // The app binary starts the app for anything else (Finder passes its own arguments).
        #expect(LoftLineCLI.runIfRequested(["/Applications/LoftLine.app/Contents/MacOS/LoftLine"]) == nil)
        #expect(LoftLineCLI.runIfRequested(["LoftLine", "-NSDocumentRevisionsDebugMode", "YES"]) == nil)
        #expect(LoftLineCLI.runIfRequested(["LoftLine", "/tmp/a.loftline"]) == nil)
    }

    @Test func twoSidedJobsPostEachSideAndTheOtherSideHasItsOwnToolpaths() throws {
        var project = try LoftLineProject.decode(from: Data(contentsOf: URL(fileURLWithPath: Self.sign)))
        project.document.job.twoSided = TwoSidedSetup()
        let folder = Self.folder()
        let file = folder.appendingPathComponent("two.loftline")
        try project.encoded().write(to: file)
        // Every toolpath of the sign is on the top side: the bottom has nothing to export.
        let top = Self.run(["export", file.path, "--out", folder.path, "--quiet"])
        #expect(top.status == 0, "\(top.err)")
        let bottom = Self.run(["export", file.path, "--side", "bottom", "--out", folder.path])
        #expect(bottom.status == 1 && bottom.err.contains("no calculated toolpaths"))
    }

    @Test @MainActor func eachSideOfATwoSidedJobHasItsOwnToolpathsAndItsOwnZZero() throws {
        // The drill holes are on a bottom-side layer; everything else is on top. Both sides have enabled toolpaths.
        var project = try LoftLineProject.decode(from: Data(contentsOf: URL(fileURLWithPath: Self.sign)))
        project.document.job.twoSided = TwoSidedSetup(flip: .leftRight, bottomZZero: .spoilboard)
        let layer = try #require(project.document.layers.firstIndex { $0.name == "Drill" })
        project.document.layers[layer].side = .bottom
        let folder = Self.folder()
        let file = folder.appendingPathComponent("both.loftline")
        try project.encoded().write(to: file)
        let top = Self.run(["export", file.path, "--out", "-", "--builtin-only"])
        let bottom = Self.run(["export", file.path, "--side", "bottom", "--out", "-", "--builtin-only"])
        #expect(top.status == 0 && bottom.status == 0, "\(top.err) \(bottom.err)")
        for name in ["Pocket 1", "V-Carve 1", "Profile 1"] {
            #expect(top.out.contains(name) && !bottom.out.contains(name), "\(name)")
        }
        #expect(bottom.out.contains("Drilling 1") && !top.out.contains("Drilling 1"))
        // Each is the app's program for that side (the bottom's Z zero is the spoilboard, the top's the material top).
        #expect(top.out.contains("Z zero: material top") && bottom.out.contains("Z zero: spoilboard"))
        let doc = LoftLineDocument(project: project, toolLibrary: AppTestSupport.library())
        #expect(top.out == (try Self.appExport(project)))
        doc.showSide(.bottom)
        doc.calculateNow(doc.outputProject.operations.filter(\.setup.isEnabled).map(\.id))
        let tps = GCodeExporter.toolpaths(scope: .all, operations: doc.outputProject.operations, results: doc.results,
                                          groupByTool: false)
        let app = GCodeExporter.export(project: doc.outputProject(for: .all), toolpaths: tps, profile: doc.postProfile,
                                       jobName: doc.document.name)
        #expect(bottom.out == app.text)
    }
}
