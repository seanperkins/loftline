import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineKit

@Suite struct PreviewTimeEstimateTests {
    private func defaults() -> UserDefaults {
        let name = "loftline-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func settingsRoundTripAndDefaults() {
        let d = defaults()
        #expect(TimeEstimateSettings.load(from: d) == TimeEstimateSettings())
        var s = TimeEstimateSettings()
        s.useAcceleration = false; s.accelerationInchPerSec2 = 30; s.scale = 1.2; s.toolChangeSeconds = 45
        s.save(to: d)
        #expect(TimeEstimateSettings.load(from: d) == s)
        d.set(99.0, forKey: TimeEstimateSettings.scaleKey)
        #expect(TimeEstimateSettings.load(from: d).scale == TimeEstimateSettings.scaleRange.upperBound)
    }

    @Test func motionConvertsToDocumentUnits() {
        var s = TimeEstimateSettings()
        s.accelerationInchPerSec2 = 10
        let mm = s.motion(units: .millimeter)
        #expect(abs(mm.acceleration - 254) < 1e-9)
        #expect(abs(mm.junctionDeviation - 0.0508) < 1e-9)
        s.useAcceleration = false
        #expect(s.motion(units: .inch).acceleration == 0)
    }

    @Test func calibrationMatchesActualTime() {
        let tool = Tool(name: "EM", kind: .endMill, number: 1, diameter: 0.25, stepdown: 0.1, stepover: 0.1,
                        feedRate: 60, plungeRate: 20)
        let other = Tool(name: "EM2", kind: .endMill, number: 2, diameter: 0.25, stepdown: 0.1, stepover: 0.1,
                         feedRate: 60, plungeRate: 20)
        let a = Toolpath(name: "a", kind: .profile, tool: tool, moves: [
            .rapid(to: Vec3(0, 0, 0.5)), .linear(to: Vec3(0, 0, -0.1), feed: 20),
            .linear(to: Vec3(10, 0, -0.1), feed: 60), .rapid(to: Vec3(10, 0, 0.5)),
        ])
        var b = a
        b.tool = other
        var s = TimeEstimateSettings()
        s.toolChangeSeconds = 60
        let parts = s.calibrationParts([a, b], rapidRate: 200, units: .inch)
        #expect(abs(parts.fixed - 60) < 1e-6)
        let actual = (parts.motion * 1.25 + parts.fixed)
        let scale = TimeEstimateSettings.calibratedScale(motionSeconds: parts.motion, fixedSeconds: parts.fixed,
                                                         actualSeconds: actual)
        #expect(abs((scale ?? 0) - 1.25) < 1e-9)
        s.scale = scale!
        #expect(abs(s.estimate([a, b], rapidRate: 200, units: .inch) - actual) < 1e-6)
        #expect(TimeEstimateSettings.calibratedScale(motionSeconds: 10, fixedSeconds: 60, actualSeconds: 30) == nil)
    }

    /// The tool-change allowance is clamped from the field and from the saved value, so no input reaches the
    /// duration formatter as an absurd number (issue #56).
    @Test func theToolChangeAllowanceIsClamped() {
        #expect(TimeEstimateSettings.clampToolChange(-5) == 0)
        #expect(TimeEstimateSettings.clampToolChange(45) == 45)
        #expect(TimeEstimateSettings.clampToolChange(1e300) == TimeEstimateSettings.toolChangeRange.upperBound)
        #expect(TimeEstimateSettings.clampToolChange(.nan) == MachiningTimeEstimator.defaultToolChangeSeconds)
        let defaults = UserDefaults(suiteName: "loftline-test-\(UUID().uuidString)")!
        defaults.set(1e300, forKey: TimeEstimateSettings.toolChangeKey)
        #expect(TimeEstimateSettings.load(from: defaults).toolChangeSeconds == TimeEstimateSettings.toolChangeRange.upperBound)
        defaults.set(-Double.infinity, forKey: TimeEstimateSettings.toolChangeKey)
        #expect(TimeEstimateSettings.load(from: defaults).toolChangeSeconds == 0)
        defaults.set(Double.infinity, forKey: TimeEstimateSettings.toolChangeKey)
        #expect(TimeEstimateSettings.load(from: defaults).toolChangeSeconds == TimeEstimateSettings.toolChangeRange.upperBound)
    }
}

