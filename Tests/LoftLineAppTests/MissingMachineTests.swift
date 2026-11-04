import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// A project whose chosen machine is not installed here and not carried in the file
/// (docs/implicit-state-machines.md #18): the substitute is reported, and Job Setup neither hides nor saves it.
@Suite struct MissingMachineTests {
    func project() -> LoftLineProject {
        var p = AppTestSupport.project()
        p.machineID = "gone-machine"
        p.postProfileID = BuiltInPosts.avidMach4Inch.id
        p.machineSnapshot = nil
        return p
    }

    @Test func aMissingChosenMachineWarns() {
        let issues = ProjectPost.issues(for: project(), profiles: BuiltInPosts.all, machines: BuiltInMachines.all)
        let warning = issues.first { $0.message.hasPrefix("The project's machine \"gone-machine\" is not installed") }
        #expect(warning?.severity == .warning)
        #expect(warning?.message == "The project's machine \"gone-machine\" is not installed and the file has no copy of it; "
                    + "\"\(BuiltInMachines.avidPRO6096.name)\" is used instead. Pick your machine in Job Setup.")
    }

    @Test func jobSetupApplyKeepsTheProjectsMachineID() {
        let p = project()
        let form = JobSetupForm(project: p, machines: BuiltInMachines.all, profiles: BuiltInPosts.all)
        #expect(form.apply(to: p).machineID == "gone-machine")
        // Picking a machine is what changes it.
        var picked = form
        picked.selectMachine(BuiltInMachines.avidPRO6096, profiles: BuiltInPosts.all)
        #expect(picked.apply(to: p).machineID == BuiltInMachines.avidPRO6096.id)
    }

    @Test func jobSetupShowsTheMissingMachineSelected() {
        let form = JobSetupForm(project: project(), machines: BuiltInMachines.all, profiles: BuiltInPosts.all)
        #expect(form.machineID == "gone-machine")
        let choice = form.machineChoices(installed: BuiltInMachines.all).first { $0.id == "gone-machine" }
        #expect(choice?.title == "gone-machine (not installed, using \(BuiltInMachines.avidPRO6096.name))")
        // The fallback's bed still judges the fit.
        #expect(form.machine?.id == BuiltInMachines.avidPRO6096.id)
    }
}
