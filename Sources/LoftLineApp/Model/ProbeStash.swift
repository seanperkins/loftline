import CADCore
import PostCore

/// The probe the Machines editor's toggle switched off, kept while the editor is open so switching it back on brings
/// back the calibrated values (plate thickness, zero macro, park) rather than the defaults, which pass validation and
/// would otherwise be saved over them. `units` is the machine's units when it was switched off; `machineID` keeps one
/// machine's probe from being restored into another the editor switched to.
struct ProbeStash: Equatable {
    var machineID: String
    var probe: ToolChangeProbe
    var units: LengthUnit
}

extension MachineDefinition {
    /// Switch tool-change probing on or off: off remembers the probe in `stash`; on restores it (converted if the
    /// machine's units changed meanwhile), or starts from the defaults when nothing was remembered.
    mutating func setToolChangeProbe(on: Bool, stash: inout ProbeStash?) {
        if on {
            guard toolChangeProbe == nil else { return }
            if let s = stash, s.machineID == id {
                toolChangeProbe = s.probe.scaled(by: s.units.factor(to: units))
            } else {
                toolChangeProbe = ToolChangeProbe.defaults(for: self)
            }
        } else if let probe = toolChangeProbe {
            stash = ProbeStash(machineID: id, probe: probe, units: units)
            toolChangeProbe = nil
        }
    }
}
