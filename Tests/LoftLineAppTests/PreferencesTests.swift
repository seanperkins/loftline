import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct PreferencesTests {
    func freshDefaults() -> UserDefaults {
        let name = "loftline-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func defaultsWhenNothingStored() {
        let p = AppPreferences(defaults: freshDefaults())
        #expect(p == AppPreferences())
        #expect(p.defaultUnits == .inch && p.defaultMachineID == BuiltInMachines.defaultID)
    }

    @Test func roundTripsThroughUserDefaults() {
        let d = freshDefaults()
        var p = AppPreferences()
        p.defaultUnits = .millimeter
        p.defaultMachineID = "generic-grbl"
        p.defaultPostID = BuiltInPosts.genericGRBLMM.id
        p.gridSpacingMM = 10
        p.snapToGrid = false
        p.materialColorHex = "#112233"
        p.recoveryIntervalSeconds = 0
        p.showWelcomeAtLaunch = false
        p.save(to: d)
        #expect(AppPreferences(defaults: d) == p)
        p.defaultPostID = nil
        p.save(to: d)
        #expect(AppPreferences(defaults: d).defaultPostID == nil)
    }

    @Test func invalidStoredValuesFallBack() {
        let d = freshDefaults()
        d.set("furlongs", forKey: AppPreferences.Key.units)
        d.set("not-a-colour", forKey: AppPreferences.Key.materialColor)
        d.set(-3.0, forKey: AppPreferences.Key.gridInch)
        let p = AppPreferences(defaults: d)
        #expect(p.defaultUnits == .inch && p.materialColorHex == AppPreferences.defaultMaterialColor)
        #expect(p.gridSpacingInch == 0.25)
    }

    @Test func modelPersistsEveryChange() {
        let d = freshDefaults()
        let m = PreferencesModel(defaults: d)
        m.prefs.gridSpacingInch = 0.5
        #expect(PreferencesModel(defaults: d).prefs.gridSpacingInch == 0.5)
        m.resetToDefaults()
        #expect(PreferencesModel(defaults: d).prefs == AppPreferences())
    }

    @Test func newProjectUsesUnitsGridMachineAndPost() {
        var p = AppPreferences()
        p.defaultUnits = .millimeter
        p.gridSpacingMM = 2
        let a = p.newProject(machines: BuiltInMachines.all, profiles: BuiltInPosts.all)
        #expect(a.document.units == .millimeter && a.document.gridSpacing == 2)
        #expect(a.machineID == BuiltInMachines.avidPRO6096.id && a.postProfileID == BuiltInPosts.avidMach4MM.id)
        #expect(a.document.job.width > 100)  // job defaults are in mm

        p.defaultMachineID = BuiltInMachines.genericGRBL.id
        #expect(p.newProject(machines: BuiltInMachines.all, profiles: BuiltInPosts.all).postProfileID
                == BuiltInPosts.genericGRBLMM.id)

        // A default post that does not drive the machine is ignored; an unknown machine falls back.
        p.defaultPostID = BuiltInPosts.avidMach4Inch.id
        #expect(p.newProject(machines: BuiltInMachines.all, profiles: BuiltInPosts.all).postProfileID
                == BuiltInPosts.genericGRBLMM.id)
        p.defaultMachineID = "gone"
        p.defaultUnits = .inch
        let c = p.newProject(machines: BuiltInMachines.all, profiles: BuiltInPosts.all)
        #expect(c.machineID == BuiltInMachines.defaultID && c.postProfileID == BuiltInPosts.avidMach4Inch.id)
    }

    @Test func hexValidation() {
        #expect(AppPreferences.isHex("#A0b1C2") && AppPreferences.isHex("000000"))
        #expect(!AppPreferences.isHex("#12345") && !AppPreferences.isHex("#GGGGGG"))
    }
}
