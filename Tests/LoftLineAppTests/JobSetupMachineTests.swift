import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// Machine and post processor are chosen in Job Setup (not the toolbar).
@Suite struct JobSetupMachineTests {
    let machines = BuiltInMachines.all
    let profiles = BuiltInPosts.all

    @Test func postAfterSelectingKeepsACompatiblePostAndSwitchesOthers() {
        let avid = BuiltInMachines.avidPRO6096
        #expect(MachineResolver.post(afterSelecting: avid, current: BuiltInPosts.avidMach4MM.id,
                                     units: .inch, profiles: profiles) == BuiltInPosts.avidMach4MM.id)
        #expect(MachineResolver.post(afterSelecting: avid, current: BuiltInPosts.genericGRBLMM.id,
                                     units: .inch, profiles: profiles) == BuiltInPosts.avidMach4Inch.id)
        #expect(MachineResolver.post(afterSelecting: avid, current: BuiltInPosts.genericGRBLMM.id,
                                     units: .millimeter, profiles: profiles) == BuiltInPosts.avidMach4MM.id)
    }

    @Test func formStartsFromTheProjectsMachineAndPost() {
        var p = LoftLineProject(document: Document(units: .inch), postProfileID: BuiltInPosts.genericGRBLMM.id)
        let form = JobSetupForm(project: p, machines: machines)
        #expect(form.machineID == BuiltInMachines.genericGRBL.id)
        #expect(form.postID == BuiltInPosts.genericGRBLMM.id)
        p.machineID = BuiltInMachines.avidPRO6096.id
        #expect(JobSetupForm(project: p, machines: machines).machineID == BuiltInMachines.avidPRO6096.id)
    }

    @Test func projectWithAnUnknownPostHasNoMachine() {
        let p = LoftLineProject(document: Document(), postProfileID: "some-user-post")
        let form = JobSetupForm(project: p, machines: machines)
        #expect(form.machineID == nil)
        #expect(form.postID == "some-user-post")
    }

    @Test func selectingAMachineSwitchesAnIncompatiblePost() {
        let p = LoftLineProject(document: Document(units: .inch), postProfileID: BuiltInPosts.genericGRBLMM.id)
        var form = JobSetupForm(project: p, machines: machines)
        form.selectMachine(BuiltInMachines.avidPRO6096, profiles: profiles)
        #expect(form.machineID == BuiltInMachines.avidPRO6096.id)
        #expect(form.postID == BuiltInPosts.avidMach4Inch.id)
        // A post the machine already drives is kept.
        form.postID = BuiltInPosts.avidMach4MM.id
        form.selectMachine(BuiltInMachines.avidPRO6096, profiles: profiles)
        #expect(form.postID == BuiltInPosts.avidMach4MM.id)
    }

    @Test func applyWritesMachineAndPost() {
        let p = LoftLineProject(document: Document(units: .inch), postProfileID: BuiltInPosts.genericGRBLMM.id)
        var form = JobSetupForm(project: p, machines: machines)
        form.selectMachine(BuiltInMachines.avidPRO6096, profiles: profiles)
        let applied = form.apply(to: p)
        #expect(applied.machineID == BuiltInMachines.avidPRO6096.id)
        #expect(applied.postProfileID == BuiltInPosts.avidMach4Inch.id)
    }

    @Test func aFormMadeFromADocumentLeavesMachineAndPostAlone() {
        var p = LoftLineProject(document: Document(), postProfileID: BuiltInPosts.avidMach4MM.id)
        p.machineID = BuiltInMachines.avidPRO6096.id
        let applied = JobSetupForm(document: p.document).apply(to: p)
        #expect(applied.machineID == BuiltInMachines.avidPRO6096.id)
        #expect(applied.postProfileID == BuiltInPosts.avidMach4MM.id)
    }

    @Test func jobSetupChangesTheMachineAsOneUndoStep() {
        let doc = LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
        let um = UndoManager()
        um.groupsByEvent = false
        doc.undoManager = um
        var form = JobSetupForm(project: doc.project, machines: machines)
        form.selectMachine(BuiltInMachines.genericGRBL, profiles: profiles)
        um.beginUndoGrouping(); doc.applyJobSetup(form); um.endUndoGrouping()
        #expect(doc.project.machineID == BuiltInMachines.genericGRBL.id)
        #expect(doc.project.postProfileID == BuiltInPosts.genericGRBLMM.id)
        #expect(um.undoActionName == "Job Setup")
        um.undo()
        #expect(doc.project.machineID == nil)
    }
}
