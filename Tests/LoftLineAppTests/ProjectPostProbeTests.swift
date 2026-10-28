import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp

/// Probe settings describe this shop's machine today (its park position, its plate), so they always come from the
/// installed machine, never from a project's copy.
@Suite struct ProjectPostProbeTests {
    let inch = BuiltInPosts.avidMach4Inch
    static let probe = ToolChangeProbe(parkX: 2, parkY: -2, parkZ: -0.5, topZ: 0, plateThickness: 0.5, plateSize: 3,
                                       probeFeed: 5, probeTravel: 0.5, controller: .mach4, mach4ZeroMacro: 199)

    func avid(probe: ToolChangeProbe? = nil, plate: Double? = nil) -> MachineDefinition {
        var m = BuiltInMachines.avidPRO6096
        m.toolChangeProbe = probe
        if let plate { m.toolChangeProbe?.plateThickness = plate; m.toolChangeProbe?.probeTravel = min(0.5, plate) }
        return m
    }

    func project(copy machine: MachineDefinition) throws -> LoftLineProject {
        var p = LoftLineProject(document: Document(name: "T", units: .inch), postProfileID: inch.id, machineID: machine.id)
        p.postSnapshot = try inch.snapshot()
        p.machineSnapshot = try machine.snapshot()
        return p
    }

    func probeOn(_ r: ProjectPost.Resolved) -> ToolChangeProbe? {
        if case .on(let p)? = r.post.toolChangeProbe { return p }
        return nil
    }

    @Test func installedProbeWinsOverTheCopy() throws {
        let p = try project(copy: avid(probe: Self.probe, plate: 0.75))
        let r = ProjectPost.resolve(p, profiles: [inch], machines: [avid(probe: Self.probe, plate: 0.5)])
        #expect(probeOn(r)?.plateThickness == 0.5)
    }

    @Test func installedProbeIsConvertedToTheCopysUnits() throws {
        // The installed Avid was switched to millimetres; the project's copy is still in inches.
        var installed = avid(probe: Self.probe)
        installed.units = .millimeter
        installed.limits = MachineLimits(xTravel: 60 * 25.4, yTravel: 96 * 25.4, zTravel: 8 * 25.4, maxSpoilboardCut: 0.05 * 25.4)
        installed.toolChangeProbe = Self.probe.scaled(by: 25.4)
        let r = ProjectPost.resolve(try project(copy: avid(probe: Self.probe)), profiles: [inch], machines: [installed])
        let got = try #require(probeOn(r))
        #expect(abs(got.plateThickness - 0.5) < 1e-9 && abs(got.parkX - 2) < 1e-9 && abs(got.probeFeed - 5) < 1e-9)
        // And the reverse: an mm copy, an inch machine installed.
        var mmCopy = installed
        mmCopy.toolChangeProbe = nil
        let r2 = ProjectPost.resolve(try project(copy: mmCopy), profiles: [inch], machines: [avid(probe: Self.probe)])
        let got2 = try #require(probeOn(r2))
        #expect(abs(got2.plateThickness - 0.5) < 1e-9 && abs(got2.parkY + 2) < 1e-9)
    }

    @Test func copyWithProbeAndMachineMissingIsRefused() throws {
        let r = ProjectPost.resolve(try project(copy: avid(probe: Self.probe)), profiles: [inch], machines: [])
        #expect(r.post.toolChangeProbe == .refused(ProjectPost.probeRefusalMessage))
    }

    @Test func copyWithProbeAndInstalledWithoutIsRefused() throws {
        // As `--builtin-only` loads: the built-in Avid, which has no probe.
        let r = ProjectPost.resolve(try project(copy: avid(probe: Self.probe)), profiles: [inch],
                                    machines: BuiltInMachines.all)
        #expect(r.post.toolChangeProbe == .refused(ProjectPost.probeRefusalMessage))
    }

    @Test func copyWithoutProbeGetsTheInstalledOne() throws {
        let r = ProjectPost.resolve(try project(copy: avid()), profiles: [inch], machines: [avid(probe: Self.probe)])
        #expect(probeOn(r) == Self.probe)
    }

    @Test func copyDifferingOnlyInProbeGivesNoWarning() throws {
        let r = ProjectPost.resolve(try project(copy: avid(probe: Self.probe, plate: 0.75)), profiles: [inch],
                                    machines: [avid(probe: Self.probe, plate: 0.5)])
        #expect(r.machineCopyDiffers == nil)
        // The rest of the copy still warns.
        var other = avid(probe: Self.probe)
        other.maxRPM = 18000
        let r2 = ProjectPost.resolve(try project(copy: other), profiles: [inch], machines: [avid(probe: Self.probe)])
        #expect(r2.machineCopyDiffers != nil)
    }

    /// A project's post copy that declares Mach4 (a custom post from another shop) can probe on a Mach4 machine set up here.
    @Test func projectCopyDeclaringMach4Probes() throws {
        var shop = inch
        shop.id = "shop-avid"; shop.footer.append("(shop)"); shop.controller = .mach4
        var p = LoftLineProject(document: Document(name: "T", units: .inch), postProfileID: shop.id, machineID: avid().id)
        p.postSnapshot = try shop.snapshot()
        p.machineSnapshot = try avid().snapshot()
        let r = ProjectPost.resolve(p, profiles: [inch], machines: [avid(probe: Self.probe)])
        #expect(probeOn(r) == Self.probe)
    }
}
