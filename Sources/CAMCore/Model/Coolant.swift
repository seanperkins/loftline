/// Coolant a toolpath runs with: mist or an air blast. Off is no value (nil), so every file written before
/// coolant existed reads as Off. Applied when the program is posted, like a pause, so changing it never
/// needs a recalculation.
public enum Coolant: String, Codable, Hashable, CaseIterable, Sendable {
    case mist, air

    /// The M code that turns it on. `M9` turns either off.
    public var code: String {
        switch self {
        case .mist: return "M7"
        case .air: return "M8"
        }
    }

    public var displayName: String {
        switch self {
        case .mist: return "Mist"
        case .air: return "Air"
        }
    }
}
