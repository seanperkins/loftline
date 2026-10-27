import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp

/// Job Setup starts on, shows and keeps the project's own copies of its post and machine.
@Suite struct JobSetupCopyTests {
    let inch = BuiltInPosts.avidMach4Inch
    let avid = BuiltInMachines.avidPRO6096

    /// A machine that is in the file but not installed on this Mac, with a bed too small for the default material.
    var custom: MachineDefinition {
        var m = avid
        m.id = "custom-bed"; m.name = "Custom bed"
        m.limits = MachineLimits(xTravel: 20, yTravel: 20, zTravel: 4, maxSpoilboardCut: 0.1)
        return m
    }

    func customProject() throws -> LoftLineProject {
        var p = LoftLineProject(document: Document(name: "J", units: .inch), postProfileID: inch.id, machineID: "custom-bed")
        p.postSnapshot = try inch.snapshot(); p.machineSnapshot = try custom.snapshot()
        return p
    }

    func oldProject() -> LoftLineProject {
        ProjectPost.attaching(LoftLineProject(document: Document(name: "Old", units: .inch)),
                              profiles: BuiltInPosts.all, machines: BuiltInMachines.all)
    }

    @Test func theFormStartsOnTheProjectsOwnMachineWhenItIsNotInstalled() throws {
        let form = JobSetupForm(project: try customProject(), machines: [avid], profiles: BuiltInPosts.all)
        #expect(form.machineID == "custom-bed", "not swapped for a different installed machine")
        #expect(form.machine == custom)
    }

    @Test func aFormWithoutACopyResolvesThroughTheInstalledMachineAsToday() {
        let p = LoftLineProject(document: Document(name: "J"), postProfileID: inch.id)
        let form = JobSetupForm(project: p, machines: [avid], profiles: BuiltInPosts.all)
        #expect(form.machineID == avid.id && form.machine == avid)
    }

    @Test func applyingAMaterialSizeChangeWritesTheSameIDsAsTodayAndKeepsTheCopies() throws {
        for original in [oldProject(), try customProject()] {
            var form = JobSetupForm(project: original, machines: [avid], profiles: BuiltInPosts.all)
            form.job.width += 1
            let applied = form.apply(to: original)
            let synced = ProjectPost.syncing(applied, profiles: BuiltInPosts.all, machines: [avid])
            #expect(synced.postSnapshot == original.postSnapshot && synced.machineSnapshot == original.machineSnapshot,
                    "the copies stay attached")
            #expect(applied.postProfileID == inch.id, "a form built from a project holds a post id, as today")
            #expect(applied.machineID == form.machineID)
        }
        let custom = try customProject()
        var form = JobSetupForm(project: custom, machines: [avid], profiles: BuiltInPosts.all)
        form.job.thickness += 0.25
        #expect(form.apply(to: custom).machineID == "custom-bed", "the machine selection is not replaced")
    }

    @Test func aUnitsChangeInsideJobSetupKeepsThePostItOpenedWith() {
        let original = oldProject()
        var form = JobSetupForm(project: original, machines: BuiltInMachines.all, profiles: BuiltInPosts.all)
        form.setUnits(.millimeter)
        let applied = form.apply(to: original)
        #expect(applied.document.units == .millimeter)
        #expect(applied.postProfileID == inch.id, "unchanged behaviour: the form keeps the post it opened with")
    }

    @Test func theBedFitCheckAndThePostGroupingUseTheCopyOfAnUninstalledMachine() throws {
        var form = JobSetupForm(project: try customProject(), machines: [avid], profiles: BuiltInPosts.all)
        form.job.width = 48; form.job.height = 96
        #expect(form.fitProblems.contains { $0.contains("Custom bed") }, "\(form.fitProblems)")
        let grouped = MachineResolver.orderedPosts(BuiltInPosts.all, machine: form.machine)
        #expect(grouped.compatible.map(\.id) == custom.postIDs.filter { id in BuiltInPosts.all.contains { $0.id == id } })
    }

    @Test func thePickerListsAnUninstalledCopyAsNotInstalledHere() throws {
        let form = JobSetupForm(project: try customProject(), machines: [avid], profiles: BuiltInPosts.all)
        let choices = form.machineChoices(installed: [avid])
        #expect(choices.map(\.id) == [avid.id, "custom-bed"])
        #expect(choices.last?.title == "Custom bed (not installed here)")
        // An installed machine is listed once, under its own name.
        let installedForm = JobSetupForm(project: oldProject(), machines: [avid], profiles: BuiltInPosts.all)
        #expect(installedForm.machineChoices(installed: [avid]).map(\.title) == [avid.name])
    }

    @Test func theNoticeSaysWhichCopiesPostAndOffersTheUpdateWhenOneDiffers() throws {
        var changed = inch
        changed.version = "1.1"
        let env = ProjectPostDocumentTests.Env()
        let (doc, _) = env.document(oldProject())
        #expect(doc.copyNotice.lines.first == "Using this project's copy of \"\(inch.name)\" v\(inch.version)")
        #expect(doc.copyNotice.warnings.isEmpty && !doc.hasCopyDifferences)
        try env.installPost(changed)
        #expect(doc.copyNotice.warnings.count == 1 && doc.hasCopyDifferences)

        var ghost = inch
        ghost.id = "ghost"; ghost.name = "Ghost"
        var p = LoftLineProject(document: Document(name: "G"), postProfileID: "ghost")
        p.postSnapshot = try ghost.snapshot()
        let notInstalled = env.document(p).0.copyNotice
        #expect(notInstalled.lines.first?.hasSuffix("(not installed here)") == true)
        #expect(notInstalled.warnings.isEmpty)
    }
}
