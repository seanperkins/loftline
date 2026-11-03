import AppKit
import CADCore
import Foundation
import PostCore
import SwiftUI
import Testing
@testable import LoftLineApp

/// The Machines editor's park-and-probe section draws with probing on, for each controller.
@Suite struct MachineProbeRenderTests {
    @Test @MainActor func probeSectionRenders() throws {
        for base in BuiltInMachines.all {
            var m = base
            var probe = ToolChangeProbe.defaults(for: m)
            probe.probeTravel = probe.plateThickness * 2   // one problem shown as the user types
            m.toolChangeProbe = probe
            let view = MachineEditor(machine: .constant(m), editable: true, posts: BuiltInPosts.all, onSave: { _ in }, onDelete: { _ in })
                .frame(width: 560, height: 1100)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 560, height: 1100)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            #expect(AppTestSupport.looksDrawn(png))
            if let dir = ProcessInfo.processInfo.environment["LOFTLINE_RENDER_DIR"] {
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("machine-probe-\(m.id).png"))
            }
        }
    }
}

/// Switching probing off and back on in the Machines editor brings back the calibrated values (plate thickness, zero
/// macro, park), not the defaults, so Save cannot quietly overwrite them; across a units switch they come back converted.
@Suite struct ProbeToggleTests {
    func calibrated() -> MachineDefinition {
        var m = BuiltInMachines.all[0]
        var p = ToolChangeProbe.defaults(for: m)
        p.plateThickness = 0.613; p.parkX = 12; p.mach4ZeroMacro = 1201
        m.toolChangeProbe = p
        return m
    }

    @Test func offThenOnRestoresTheCalibratedProbe() {
        var m = calibrated()
        let before = m.toolChangeProbe
        var stash: ProbeStash?
        m.setToolChangeProbe(on: false, stash: &stash)
        #expect(m.toolChangeProbe == nil)
        m.setToolChangeProbe(on: true, stash: &stash)
        #expect(m.toolChangeProbe == before)
    }

    @Test func aUnitsSwitchWhileOffConvertsTheRestoredProbe() throws {
        var m = calibrated()
        let before = try #require(m.toolChangeProbe)
        var stash: ProbeStash?
        m.setToolChangeProbe(on: false, stash: &stash)
        let from = m.units
        let other: LengthUnit = from == .inch ? .millimeter : .inch
        m = m.switchingUnits(to: other)
        m.setToolChangeProbe(on: true, stash: &stash)
        #expect(m.toolChangeProbe == before.scaled(by: from.factor(to: other)))
        #expect(m.toolChangeProbe?.mach4ZeroMacro == 1201)
    }

    @Test func anotherMachinesProbeIsNotRestored() {
        var m = calibrated()
        var stash: ProbeStash?
        m.setToolChangeProbe(on: false, stash: &stash)
        var other = BuiltInMachines.all[1]
        other.toolChangeProbe = nil
        other.setToolChangeProbe(on: true, stash: &stash)
        #expect(other.toolChangeProbe == ToolChangeProbe.defaults(for: other))
    }

    @Test func onWithNothingRememberedUsesTheDefaults() {
        var m = BuiltInMachines.all[0]
        m.toolChangeProbe = nil
        var stash: ProbeStash?
        m.setToolChangeProbe(on: true, stash: &stash)
        #expect(m.toolChangeProbe == ToolChangeProbe.defaults(for: m))
    }
}
