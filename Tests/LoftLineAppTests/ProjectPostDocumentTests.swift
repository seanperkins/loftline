import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp

@Suite struct ProjectPostDocumentTests {
    let inch = BuiltInPosts.avidMach4Inch
    let mm = BuiltInPosts.avidMach4MM
    let grblPost = BuiltInPosts.genericGRBLMM
    let avid = BuiltInMachines.avidPRO6096
    let grbl = BuiltInMachines.genericGRBL

    /// Catalogs on temp folders, so an "installed" post or machine can be changed on disk and reloaded.
    struct Env {
        let posts: PostProfileCatalog
        let machines: MachineCatalog
        let library = AppTestSupport.library()
        init() {
            let root = AppTestSupport.tempDir()
            posts = PostProfileCatalog(store: PostProfileStore(directory: root.appendingPathComponent("posts")))
            machines = MachineCatalog(store: MachineStore(directory: root.appendingPathComponent("machines")))
        }
        func document(_ p: LoftLineProject) -> (LoftLineDocument, UndoManager) {
            let doc = LoftLineDocument(project: p, toolLibrary: library, postCatalog: posts, machineCatalog: machines)
            let um = UndoManager()
            um.groupsByEvent = false
            doc.undoManager = um
            return (doc, um)
        }
        func installPost(_ p: PostProfile) throws { _ = try posts.store.save(p); posts.reload() }
        func installMachine(_ m: MachineDefinition) throws { try machines.save(m) }
    }

    func project(post: String? = nil, machine: String? = nil, units: LengthUnit = .inch) -> LoftLineProject {
        LoftLineProject(document: Document(name: "T", units: units), postProfileID: post, machineID: machine)
    }

    func step(_ um: UndoManager, _ body: () -> Void) { um.beginUndoGrouping(); body(); um.endUndoGrouping() }

    func postCopy(_ doc: LoftLineDocument) -> PostProfile? { doc.project.postSnapshot.flatMap { try? PostProfile(snapshot: $0) } }
    func machineCopy(_ doc: LoftLineDocument) -> MachineDefinition? {
        doc.project.machineSnapshot.flatMap { try? MachineDefinition(snapshot: $0) }
    }

    // MARK: attach

    @Test func openingAnOldProjectAttachesCopiesKeepsNilIDsAndLeavesItUnedited() {
        let (doc, _) = Env().document(project())
        #expect(doc.project.postProfileID == nil && doc.project.machineID == nil, "nil stays nil")
        #expect(postCopy(doc) == inch)
        #expect(machineCopy(doc) == avid && doc.project.machineInferredFor == inch.id)
        #expect(!doc.needsRecovery, "attaching is in memory only")
    }

    @Test func attachingCopiesWhatTheSelectionNames() {
        let env = Env()
        let named = env.document(project(post: grblPost.id, machine: grbl.id)).0
        #expect(postCopy(named) == grblPost && machineCopy(named) == grbl)
        #expect(named.project.machineInferredFor == nil, "a chosen machine needs no marker")
        let gone = env.document(project(post: inch.id, machine: "gone")).0
        #expect(postCopy(gone) == inch && machineCopy(gone) == nil, "no copy of a machine that is not installed")
        #expect(gone.project.machineID == "gone")
    }

    @Test func anUnreadableCopyIsTreatedAsAbsent() {
        var p = project()
        p.postSnapshot = .string("junk"); p.machineSnapshot = .null
        let (doc, _) = Env().document(p)
        #expect(postCopy(doc) == inch && machineCopy(doc) == avid)
    }

    // MARK: sync

    @Test func pickingAPostAndAMachineLeaveMatchingCopies() {
        let (doc, um) = Env().document(project(post: inch.id, machine: avid.id))
        step(um) { doc.setPostProfile(mm.id) }
        #expect(postCopy(doc) == mm && machineCopy(doc) == avid)
        step(um) { doc.setMachine(grbl.id) }
        #expect(doc.project.postProfileID == grblPost.id, "the machine switched the post")
        #expect(postCopy(doc) == grblPost && machineCopy(doc) == grbl)
    }

    @Test func aTemplateAndANewProjectEndUpWithMatchingCopies() {
        let env = Env()
        let fresh = AppPreferences().newProject(machines: env.machines.machines, profiles: env.posts.profiles)
        let (doc, _) = env.document(fresh)
        #expect(postCopy(doc)?.id == doc.project.postProfileID && machineCopy(doc)?.id == doc.project.machineID)
    }

    @Test func anOldProjectSwitchingFromAvidToGRBLGetsTheGRBLMachineAsToday() {
        let env = Env()
        let (doc, um) = env.document(project())
        step(um) { doc.setPostProfile(grblPost.id) }
        #expect(doc.machine == MachineResolver.machine(for: doc.project, machines: env.machines.machines))
        #expect(machineCopy(doc) == grbl && doc.project.machineInferredFor == grblPost.id)
        #expect(doc.project.machineID == nil)
    }

    @Test func convertingANilPostProjectToMillimetresMovesToTheMMDefault() {
        let (doc, um) = Env().document(project())
        step(um) { doc.perform("Units") { $0 = $0.converted(to: .millimeter) } }
        #expect(postCopy(doc) == mm, "the default for the new units, as today")
        #expect(doc.project.machineInferredFor == mm.id)
    }

    @Test func syncLeavesAMatchingCopyAlone() throws {
        let env = Env()
        let (doc, um) = env.document(project(post: inch.id))
        var changed = inch
        changed.version = "1.1"; changed.footer = ["M30", "(new)"]
        try env.installPost(changed)
        step(um) { doc.perform("Rename") { $0.document.name = "Renamed" } }
        #expect(postCopy(doc) == inch, "the file's copy wins over the installed one")
    }

    // MARK: Update This Project

    @Test func updateReplacesEachCopyWithTheInstalledOneOfTheSameIDAndUndoes() throws {
        let env = Env()
        let (doc, um) = env.document(project(post: inch.id, machine: avid.id))
        var post = inch
        post.version = "1.1"
        var machine = avid
        machine.limits = MachineLimits(xTravel: 48, yTravel: 96, zTravel: 8, maxSpoilboardCut: 0.1)
        try env.installPost(post); try env.installMachine(machine)
        #expect(doc.hasCopyDifferences)
        step(um) { doc.updateProjectFromInstalled() }
        #expect(postCopy(doc) == post && machineCopy(doc) == machine && !doc.hasCopyDifferences)
        #expect(um.undoActionName == "Update Post")
        um.undo()
        #expect(postCopy(doc) == inch && machineCopy(doc) == avid)
    }

    @Test func updateKeepsACopyWithNoInstalledCounterpart() throws {
        let env = Env()
        var custom = avid
        custom.id = "custom-bed"; custom.name = "Custom bed"
        var p = project(post: inch.id, machine: "custom-bed")
        p.machineSnapshot = try custom.snapshot()
        let (doc, um) = env.document(p)
        var post = inch
        post.version = "1.1"
        try env.installPost(post)
        step(um) { doc.updateProjectFromInstalled() }
        #expect(postCopy(doc) == post, "the post that has an installed counterpart is replaced")
        #expect(machineCopy(doc) == custom, "the machine with none is kept")
    }

    // MARK: notices

    @Test func theWarningAppearsExactlyWhenACopyDiffers() throws {
        let env = Env()
        let (doc, _) = env.document(project(post: inch.id, machine: avid.id))
        #expect(doc.postProfileIssues.isEmpty)

        var post = inch
        post.version = "1.1"
        try env.installPost(post)
        let issue = try #require(doc.postProfileIssues.first)
        #expect(doc.postProfileIssues.count == 1 && issue.severity == .warning)
        #expect(issue.message.contains("v1.0") && issue.message.contains("v1.1") && issue.message.contains("Update This Project"))

        post.version = "1.0"; post.footer = ["M30", "(edited, same version)"]
        try env.installPost(post)
        let same = try #require(doc.postProfileIssues.first)
        #expect(!same.message.contains("v1.0"), "equal versions are left out")
        #expect(same.message.contains("differs from the installed one"))

        try env.installPost(inch)
        var machine = avid
        machine.limits = MachineLimits(xTravel: 48, yTravel: 96, zTravel: 8, maxSpoilboardCut: 0.1)
        try env.installMachine(machine)
        let m = try #require(doc.postProfileIssues.first)
        #expect(doc.postProfileIssues.count == 1 && m.severity == .warning)
        #expect(m.message.contains("60") && m.message.contains("48") && m.message.contains(avid.name))
    }

    @Test func reloadingThePostCatalogRefreshesTheNotice() throws {
        let env = Env()
        let (doc, _) = env.document(project(post: inch.id))
        var post = inch
        post.version = "1.1"
        _ = try env.posts.store.save(post)          // on disk, not yet reloaded: the catalog is read once
        #expect(doc.postProfileIssues.isEmpty)
        env.posts.reload()
        #expect(doc.postProfileIssues.count == 1)
    }

    @Test func aMissingPostWithoutACopyKeepsTheError() throws {
        let (doc, _) = Env().document(project(post: "ghost"))
        let issue = try #require(doc.postProfileIssues.first)
        #expect(issue.severity == .error)
        #expect(issue.message == "The project's post \"ghost\" is not installed; \"\(inch.name)\" is shown instead. Pick a post before saving.")
        #expect(doc.postProfile.id == inch.id)
    }

    @Test func aPostThatIsNotInstalledButCarriedPostsWithoutAnError() throws {
        var ghost = inch
        ghost.id = "ghost"; ghost.name = "Ghost"
        var p = project(post: "ghost")
        p.postSnapshot = try ghost.snapshot()
        let (doc, _) = Env().document(p)
        #expect(doc.postProfileIssues.isEmpty && doc.postProfile.id == "ghost")
    }

    // MARK: user files

    @Test func storesSkipUserPostAndMachineFilesWithANewerSchema() throws {
        let env = Env()
        func newer(_ v: JSONValue) throws -> Data {
            guard case .object(var o) = v else { return Data() }
            o["schemaVersion"] = .number(2)
            return try JSONEncoder().encode(JSONValue.object(o))
        }
        let postDir = env.posts.store.directory, machineDir = env.machines.store.directory
        try FileManager.default.createDirectory(at: postDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: machineDir, withIntermediateDirectories: true)
        try newer(inch.snapshot()).write(to: postDir.appendingPathComponent("\(inch.id).json"))
        try newer(avid.snapshot()).write(to: machineDir.appendingPathComponent("\(avid.id).json"))
        #expect(env.posts.store.allProfiles().first { $0.id == inch.id } == inch, "the built-in shows instead")
        #expect(env.machines.store.allMachines().first { $0.id == avid.id } == avid)
    }
}
