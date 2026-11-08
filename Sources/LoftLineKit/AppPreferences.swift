import CADCore
import CAMCore
import Foundation
import PostCore

/// App-level settings, persisted in UserDefaults under `loftline.pref.*`. They seed new documents
/// (units, grid, machine, post, snapping) and style the canvas; open documents keep their own values.
public struct AppPreferences: Equatable {
    public var defaultUnits: LengthUnit = .inch
    public var defaultMachineID: String = BuiltInMachines.defaultID
    /// nil = the machine's default post for the document units.
    public var defaultPostID: String?
    public var gridSpacingInch: Double = 0.25
    public var gridSpacingMM: Double = 5
    public var snapToGrid = true
    public var snapToObjects = true
    /// Canvas colours, "#RRGGBB".
    public var materialColorHex = Self.defaultMaterialColor
    public var selectionColorHex = Self.defaultSelectionColor
    public var rapidColorHex = Self.defaultRapidColor
    /// Crash-recovery snapshot interval in seconds (0 = off).
    public var recoveryIntervalSeconds: Int = 60
    /// Show the Welcome window when LoftLine starts.
    public var showWelcomeAtLaunch = true
    /// Look for a newer release at launch and then daily (release builds only).
    public var autoCheckForUpdates = true

    public static let defaultMaterialColor = "#FCF7ED"
    public static let defaultSelectionColor = "#007AFF"
    public static let defaultRapidColor = "#FF3B30"
    public static let recoveryIntervals = [0, 30, 60, 120, 300]

    public enum Key {
        public static let units = "loftline.pref.defaultUnits"
        public static let machine = "loftline.pref.defaultMachine"
        public static let post = "loftline.pref.defaultPost"
        public static let gridInch = "loftline.pref.gridSpacingInch"
        public static let gridMM = "loftline.pref.gridSpacingMM"
        public static let snapGrid = "loftline.pref.snapToGrid"
        public static let snapObjects = "loftline.pref.snapToObjects"
        public static let materialColor = "loftline.pref.materialColor"
        public static let selectionColor = "loftline.pref.selectionColor"
        public static let rapidColor = "loftline.pref.rapidColor"
        public static let recoveryInterval = "loftline.pref.recoveryInterval"
        public static let showWelcome = "loftline.pref.showWelcome"
        public static let autoCheckForUpdates = "loftline.pref.autoCheckForUpdates"
    }

    public init() {}

    public init(defaults d: UserDefaults) {
        if let u = d.string(forKey: Key.units).flatMap(LengthUnit.init(rawValue:)) { defaultUnits = u }
        if let m = d.string(forKey: Key.machine), !m.isEmpty { defaultMachineID = m }
        if let p = d.string(forKey: Key.post), !p.isEmpty { defaultPostID = p }
        if let g = d.object(forKey: Key.gridInch) as? Double, g > 0 { gridSpacingInch = g }
        if let g = d.object(forKey: Key.gridMM) as? Double, g > 0 { gridSpacingMM = g }
        if let b = d.object(forKey: Key.snapGrid) as? Bool { snapToGrid = b }
        if let b = d.object(forKey: Key.snapObjects) as? Bool { snapToObjects = b }
        if let c = d.string(forKey: Key.materialColor), Self.isHex(c) { materialColorHex = c }
        if let c = d.string(forKey: Key.selectionColor), Self.isHex(c) { selectionColorHex = c }
        if let c = d.string(forKey: Key.rapidColor), Self.isHex(c) { rapidColorHex = c }
        if let i = d.object(forKey: Key.recoveryInterval) as? Int, i >= 0 { recoveryIntervalSeconds = i }
        if let b = d.object(forKey: Key.showWelcome) as? Bool { showWelcomeAtLaunch = b }
        if let b = d.object(forKey: Key.autoCheckForUpdates) as? Bool { autoCheckForUpdates = b }
    }

    public func save(to d: UserDefaults) {
        d.set(defaultUnits.rawValue, forKey: Key.units)
        d.set(defaultMachineID, forKey: Key.machine)
        if let p = defaultPostID { d.set(p, forKey: Key.post) } else { d.removeObject(forKey: Key.post) }
        d.set(gridSpacingInch, forKey: Key.gridInch)
        d.set(gridSpacingMM, forKey: Key.gridMM)
        d.set(snapToGrid, forKey: Key.snapGrid)
        d.set(snapToObjects, forKey: Key.snapObjects)
        d.set(materialColorHex, forKey: Key.materialColor)
        d.set(selectionColorHex, forKey: Key.selectionColor)
        d.set(rapidColorHex, forKey: Key.rapidColor)
        d.set(recoveryIntervalSeconds, forKey: Key.recoveryInterval)
        d.set(showWelcomeAtLaunch, forKey: Key.showWelcome)
        d.set(autoCheckForUpdates, forKey: Key.autoCheckForUpdates)
    }

    public static func isHex(_ s: String) -> Bool {
        var t = s
        if t.hasPrefix("#") { t.removeFirst() }
        return t.count == 6 && UInt32(t, radix: 16) != nil
    }

    public func gridSpacing(for units: LengthUnit) -> Double { units == .inch ? gridSpacingInch : gridSpacingMM }

    /// A new, empty project using these defaults. An unknown machine falls back to the built-in
    /// default; an unknown or incompatible default post falls back to the machine's post.
    public func newProject(machines: [MachineDefinition], profiles: [PostProfile]) -> LoftLineProject {
        let doc = Document(units: defaultUnits, gridSpacing: gridSpacing(for: defaultUnits))
        var project = LoftLineProject(document: doc, postProfileID: PostProfileStore.defaultID(for: defaultUnits))
        let machine = machines.first { $0.id == defaultMachineID } ?? machines.first { $0.id == BuiltInMachines.defaultID }
        if let machine { MachineResolver.select(machine: machine, in: &project, profiles: profiles) }
        if let post = defaultPostID, profiles.contains(where: { $0.id == post }),
           machine?.supports(postID: post) ?? true {
            project.postProfileID = post
        }
        return project
    }
}
