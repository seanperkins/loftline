import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp

@Suite struct MachineConfigTests {
    let small = MachineDefinition(id: "tiny", name: "Tiny", units: .millimeter,
                                  limits: MachineLimits(xTravel: 300, yTravel: 200, zTravel: 60, maxSpoilboardCut: 1),
                                  postIDs: [BuiltInPosts.genericGRBLMM.id])

    @Test func resolverPrefersExplicitMachineThenPost() {
        var p = LoftLineProject(document: Document(), postProfileID: BuiltInPosts.genericGRBLMM.id)
        let all = BuiltInMachines.all + [small]
        #expect(MachineResolver.machine(for: p, machines: all)?.id == BuiltInMachines.genericGRBL.id)
        p.machineID = "tiny"
        #expect(MachineResolver.machine(for: p, machines: all)?.id == "tiny")
        p.machineID = "deleted-machine"
        #expect(MachineResolver.machine(for: p, machines: all)?.id == BuiltInMachines.genericGRBL.id)
        p.postProfileID = "some-user-post"
        #expect(MachineResolver.machine(for: p, machines: all) == nil)
    }

    @Test func selectingMachineSwitchesIncompatiblePost() {
        var p = LoftLineProject(document: Document(units: .inch), postProfileID: BuiltInPosts.genericGRBLMM.id)
        MachineResolver.select(machine: BuiltInMachines.avidPRO6096, in: &p, profiles: BuiltInPosts.all)
        #expect(p.machineID == BuiltInMachines.avidPRO6096.id)
        #expect(p.postProfileID == BuiltInPosts.avidMach4Inch.id)
        // A compatible post is kept.
        p.postProfileID = BuiltInPosts.avidMach4MM.id
        MachineResolver.select(machine: BuiltInMachines.avidPRO6096, in: &p, profiles: BuiltInPosts.all)
        #expect(p.postProfileID == BuiltInPosts.avidMach4MM.id)
    }

    @Test func orderedPostsPutsMachinePostsFirst() {
        let split = MachineResolver.orderedPosts(BuiltInPosts.all, machine: BuiltInMachines.avidPRO6096)
        #expect(split.compatible.map(\.id) == [BuiltInPosts.avidMach4Inch.id, BuiltInPosts.avidMach4MM.id])
        #expect(split.other.map(\.id) == ["generic-grbl-mm", "generic-grbl-inch", "linuxcnc-inch", "linuxcnc-mm", "othermill-inch",
                                           "othermill-mm", "onefinity-bb-inch", "onefinity-bb-mm", "carbide-motion-inch",
                                           "carbide-motion-mm"])
        #expect(MachineResolver.orderedPosts(BuiltInPosts.all, machine: nil).compatible.count == BuiltInPosts.all.count)
    }

    @Test func fitProblemsConvertUnits() {
        var job = JobSetup.defaults(for: .inch)
        job.width = 24; job.height = 12; job.thickness = 0.75
        #expect(MachineResolver.fitProblems(job: job, units: .inch, machine: BuiltInMachines.avidPRO6096).isEmpty)
        #expect(MachineResolver.fitProblems(job: job, units: .inch, machine: small).count == 1)  // 11.8 x 7.9 in
        job.thickness = 3
        #expect(MachineResolver.fitProblems(job: job, units: .inch, machine: small).count == 2)
        #expect(MachineResolver.fitProblems(job: job, units: .inch, machine: nil).isEmpty)
    }

    @Test func storeSavesListsAndDeletesUserMachines() throws {
        let store = MachineStore(directory: AppTestSupport.tempDir())
        #expect(store.allMachines().map(\.id) == BuiltInMachines.all.map(\.id))
        try store.save(small)
        #expect(store.allMachines().map(\.id) == BuiltInMachines.all.map(\.id) + ["tiny"])
        #expect(store.isUserMachine("tiny") && !store.isUserMachine(BuiltInMachines.defaultID))
        // A user file with a built-in id overrides it.
        var avid = BuiltInMachines.avidPRO6096
        avid.limits.yTravel = 48
        try store.save(avid)
        #expect(store.allMachines().first { $0.id == avid.id }?.limits.yTravel == 48)
        try store.delete(id: "tiny")
        try store.delete(id: avid.id)
        #expect(store.allMachines() == BuiltInMachines.all)
    }

    @Test func documentAppliesMachineAndUndoes() {
        let doc = LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
        let um = UndoManager()
        um.groupsByEvent = false
        doc.undoManager = um
        // No machine chosen: resolved from the default Avid inch post.
        #expect(doc.machine?.id == BuiltInMachines.avidPRO6096.id)
        #expect(doc.postProfile.limits.xTravel == 60)
        um.beginUndoGrouping(); doc.setMachine(BuiltInMachines.genericGRBL.id); um.endUndoGrouping()
        #expect(doc.project.machineID == BuiltInMachines.genericGRBL.id)
        #expect(doc.project.postProfileID == BuiltInPosts.genericGRBLMM.id)
        #expect(um.undoActionName == "Change Machine")
        um.undo()
        #expect(doc.project.machineID == nil)
    }

    @Test func oldFilesDecodeWithoutMachine() throws {
        let p = LoftLineProject(document: Document(), postProfileID: BuiltInPosts.avidMach4Inch.id)
        let text = String(decoding: try p.encoded(), as: UTF8.self)
        #expect(!text.contains("machineID"))
        var q = try LoftLineProject.decode(from: try p.encoded())
        #expect(q.machineID == nil)
        q.machineID = "avid-pro6096"
        #expect(try LoftLineProject.decode(from: q.encoded()).machineID == "avid-pro6096")
    }

    /// The Machines editor's units switch scales the probe with the rest: limits are compared in the probe's own units.
    @Test func unitsSwitchScalesTheProbe() {
        var m = BuiltInMachines.avidPRO6096
        m.toolChangeProbe = ToolChangeProbe(parkX: 2, parkY: -2, parkZ: -0.5, topZ: 0, plateThickness: 1, plateSize: 3,
                                            probeFeed: 10, probeTravel: 1, controller: .mach4, mach4ZeroMacro: 199,
                                            workOffset: 3)
        let mm = m.switchingUnits(to: .millimeter)
        let p = mm.toolChangeProbe!
        #expect(abs(p.probeFeed - 254) < 1e-9 && abs(p.probeTravel - 25.4) < 1e-9 && abs(p.parkX - 50.8) < 1e-9)
        #expect(p.workOffset == 3 && p.mach4ZeroMacro == 199)
        #expect(p.problems(limits: mm.limits, units: .millimeter).isEmpty)
        #expect(abs(mm.limits.zTravel - 8 * 25.4) < 1e-9)
        let back = mm.switchingUnits(to: .inch).toolChangeProbe!
        #expect(abs(back.probeFeed - 10) < 1e-9 && abs(back.plateThickness - 1) < 1e-9)
    }

    @Test func probeDefaultsHaveNoProblems() {
        for m in BuiltInMachines.all {
            let p = ToolChangeProbe.defaults(for: m)
            #expect(p.problems(limits: m.limits, units: m.units).isEmpty, "\(m.name): \(p.problems(limits: m.limits, units: m.units))")
        }
        #expect(ToolChangeProbe.defaults(for: BuiltInMachines.genericGRBL).controller == .grbl)
        #expect(ToolChangeProbe.defaults(for: BuiltInMachines.avidPRO6096).controller == .mach4)
    }
}
