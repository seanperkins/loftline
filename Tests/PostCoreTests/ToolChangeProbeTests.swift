import CADCore
import CAMCore
import Foundation
import Testing
@testable import PostCore

/// The machine's park-and-probe settings: their limits, their units, and how they reach a post (never through
/// a post file or a project's post copy).
@Suite struct ToolChangeProbeTests {
    /// The Avid in inches, probing on Mach4.
    static let mach4 = ToolChangeProbe(parkX: 2, parkY: -2, parkZ: -0.5, topZ: 0, plateThickness: 0.5, plateSize: 3,
                                       probeFeed: 5, probeTravel: 0.5, controller: .mach4, mach4ZeroMacro: 199)
    static let grbl = ToolChangeProbe(parkX: 10, parkY: 10, parkZ: -5, topZ: -1, plateThickness: 12, plateSize: 60,
                                      probeFeed: 100, probeTravel: 10, controller: .grbl)

    let inchLimits = BuiltInMachines.avidPRO6096.limits     // 60 x 96 x 8 in
    let mmLimits = BuiltInMachines.genericGRBL.limits

    func problems(_ change: (inout ToolChangeProbe) -> Void, base: ToolChangeProbe = mach4, units: LengthUnit = .inch) -> [String] {
        var p = base
        change(&p)
        return p.problems(limits: units == .inch ? inchLimits : mmLimits, units: units)
    }

    @Test func theDefaultsHaveNoProblems() {
        #expect(Self.mach4.problems(limits: inchLimits, units: .inch).isEmpty)
        #expect(Self.grbl.problems(limits: mmLimits, units: .millimeter).isEmpty)
        #expect(Self.mach4.workOffset == 1)
    }

    @Test func problemsCoverEveryBound() {
        let quarter = -inchLimits.zTravel / 4   // -2 in
        let cases: [(String, (inout ToolChangeProbe) -> Void)] = [
            ("topZ above 0", { $0.topZ = 0.01 }),
            ("topZ below a quarter of Z travel", { $0.topZ = quarter - 0.01; $0.parkZ = quarter - 0.02 }),
            ("parkZ above topZ", { $0.topZ = -0.5; $0.parkZ = -0.4 }),
            ("parkZ below a quarter of Z travel", { $0.parkZ = quarter - 0.01 }),
            ("parkX beyond travel", { $0.parkX = -(inchLimits.xTravel + 0.01) }),
            ("parkY beyond travel", { $0.parkY = inchLimits.yTravel + 0.01 }),
            ("feed over 10 in/min", { $0.probeFeed = 10.01 }),
            ("travel over 1 in", { $0.plateThickness = 2; $0.probeTravel = 1.01 }),
            ("travel over the plate", { $0.probeTravel = 0.51 }),
            ("plate thickness 0", { $0.plateThickness = 0 }),
            ("plate size 0", { $0.plateSize = 0 }),
            ("feed 0", { $0.probeFeed = 0 }),
            ("travel 0", { $0.probeTravel = 0 }),
            ("work offset 0", { $0.workOffset = 0 }),
            ("work offset 7", { $0.workOffset = 7 }),
            ("macro 99", { $0.mach4ZeroMacro = 99 }),
            ("macro 1000", { $0.mach4ZeroMacro = 1000 }),
            ("no macro on Mach4", { $0.mach4ZeroMacro = nil }),
        ]
        for (name, change) in cases { #expect(!problems(change).isEmpty, "\(name)") }
        // GRBL: its traverse height stays at least 1 mm below the limit switch's trigger point.
        #expect(!problems({ $0.topZ = -0.5; $0.parkZ = -5 }, base: Self.grbl, units: .millimeter).isEmpty)
        #expect(problems({ $0.topZ = -1 }, base: Self.grbl, units: .millimeter).isEmpty)
        #expect(problems({ $0.mach4ZeroMacro = nil }, base: Self.grbl, units: .millimeter).isEmpty)
    }

    @Test func theLimitsHoldAcrossAUnitsSwitch() {
        // 10 in/min and 1 in, exactly at the limits, stay valid in millimetres (254 mm/min, 25.4 mm).
        var p = Self.mach4
        p.probeFeed = 10; p.plateThickness = 1; p.probeTravel = 1
        #expect(p.problems(limits: inchLimits, units: .inch).isEmpty)
        let mm = p.scaled(by: LengthUnit.inch.factor(to: .millimeter))
        #expect(abs(mm.probeFeed - 254) < 1e-9 && abs(mm.probeTravel - 25.4) < 1e-9)
        let mmLimits = MachineLimits(xTravel: inchLimits.xTravel * 25.4, yTravel: inchLimits.yTravel * 25.4,
                                     zTravel: inchLimits.zTravel * 25.4, maxSpoilboardCut: inchLimits.maxSpoilboardCut * 25.4)
        #expect(mm.problems(limits: mmLimits, units: .millimeter).isEmpty)
        #expect(mm.workOffset == p.workOffset && mm.mach4ZeroMacro == p.mach4ZeroMacro)
    }

    func machine(probe: ToolChangeProbe?) -> MachineDefinition {
        var m = BuiltInMachines.avidPRO6096
        m.toolChangeProbe = probe
        return m
    }

    @Test func appliedSetsOnRefusedOrNil() {
        let inch = machine(probe: Self.mach4).applied(to: BuiltInPosts.avidMach4Inch)
        #expect(inch.toolChangeProbe == .on(Self.mach4))
        let mm = machine(probe: Self.mach4).applied(to: BuiltInPosts.avidMach4MM)
        guard case .on(let scaled)? = mm.toolChangeProbe else { Issue.record("not on"); return }
        #expect(abs(scaled.plateThickness - 12.7) < 1e-9)
        var refused = machine(probe: nil)
        refused.probeRefusal = "Not set up here."
        #expect(refused.applied(to: BuiltInPosts.avidMach4Inch).toolChangeProbe == .refused("Not set up here."))
        // A machine without probing clears a value already on the profile.
        #expect(machine(probe: nil).applied(to: inch).toolChangeProbe == nil)
    }

    @Test func customOrEditedPostIsRefused() {
        var edited = BuiltInPosts.avidMach4Inch
        edited.preamble.append("G54")
        guard case .refused? = machine(probe: Self.mach4).applied(to: edited).toolChangeProbe else {
            Issue.record("an edited copy of a built-in post probed"); return
        }
        guard case .refused? = machine(probe: Self.mach4).applied(to: BuiltInPosts.genericGRBLMM).toolChangeProbe else {
            Issue.record("the GRBL post probed for Mach4"); return
        }
        #expect(BuiltInPosts.probeController(for: BuiltInPosts.avidMach4Inch) == .mach4)
        #expect(BuiltInPosts.probeController(for: BuiltInPosts.avidMach4MM) == .mach4)
        #expect(BuiltInPosts.probeController(for: BuiltInPosts.genericGRBLMM) == .grbl)
        #expect(BuiltInPosts.probeController(for: edited) == nil)
    }

    @Test func postBytesUnchangedByTheField() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let plain = try enc.encode(BuiltInPosts.avidMach4Inch)
        let probed = try enc.encode(machine(probe: Self.mach4).applied(to: BuiltInPosts.avidMach4Inch))
        #expect(!String(decoding: probed, as: UTF8.self).contains("toolChangeProbe"))
        // Only the probe differs between the two profiles; the bytes must not.
        var withoutProbe = machine(probe: Self.mach4).applied(to: BuiltInPosts.avidMach4Inch)
        withoutProbe.toolChangeProbe = nil
        #expect(try enc.encode(withoutProbe) == probed)
        #expect(plain.count > 0)
    }

    @Test func postJSONCarryingTheKeyDecodesWithoutIt() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(BuiltInPosts.avidMach4Inch)) as! [String: Any]
        json["toolChangeProbe"] = ["on": ["_0": ["parkX": 1]]]
        let back = try PostProfile.fromJSON(JSONSerialization.data(withJSONObject: json))
        #expect(back.toolChangeProbe == nil)
    }

    @Test func machineRoundTripsAtSchema1() throws {
        let m = machine(probe: Self.mach4)
        let back = try MachineDefinition.fromJSON(m.toJSON())
        #expect(back.toolChangeProbe == Self.mach4)
        #expect(back.schemaVersion == 1)
        // A machine without probing writes no key, so built-in machine files are unchanged.
        #expect(!String(decoding: try BuiltInMachines.avidPRO6096.toJSON(), as: UTF8.self).contains("toolChangeProbe"))
        var refused = m
        refused.probeRefusal = "x"
        #expect(try MachineDefinition.fromJSON(refused.toJSON()).probeRefusal == nil)
    }
}
