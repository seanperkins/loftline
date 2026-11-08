import Foundation

/// An area the tool must stay out of, e.g. a clamp: a closed outline in the material frame plus
/// the height of its top above the material top. Toolpaths are checked against it on export
/// (toolpaths-2d addition).
public struct KeepOutZone: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Closed polygon (no repeated closing point), document units, material frame.
    public var outline: [Vec2]
    /// Top of the obstacle above the material top (0 = flush with the top).
    public var height: Double
    /// When true, toolpaths are re-routed to lift over the zone (material under it is left
    /// uncut); nil/false = only checked on export (toolpaths-2d round 2 addition).
    public var liftOver: Bool?

    /// Three or more points: the only outlines toolpaths are checked against, lifted over or shown (fewer enclose nothing).
    public var isUsable: Bool { outline.count > 2 }

    public init(id: UUID = UUID(), name: String, outline: [Vec2], height: Double, liftOver: Bool? = nil) {
        self.id = id; self.name = name; self.outline = outline; self.height = height; self.liftOver = liftOver
    }
}
