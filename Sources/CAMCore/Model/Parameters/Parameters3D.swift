import CADCore
import Foundation

public struct Relief3DParameters: Codable, Hashable, Sendable {
    /// `Document.models` entry to machine.
    public var modelID: UUID
    /// Heightmap cell size (document units).
    public var resolution: Double
    public var roughing: RoughingSettings
    public var finishing: FinishingSettings
    /// Optional boundary vectors limiting the machined area (empty = model bounds + tool radius).
    public var boundaryShapeIDs: [UUID]
    /// Further models combined with `modelID` into one composite surface (the shallowest model
    /// wins where they overlap). nil/empty = machine `modelID` alone.
    public var additionalModelIDs: [UUID]?
    /// Two-sided machining (which side this operation cuts); nil = single-sided.
    public var twoSided: TwoSidedSettings?

    public init(modelID: UUID, resolution: Double = 0.01, roughing: RoughingSettings = RoughingSettings(),
                finishing: FinishingSettings = FinishingSettings(), boundaryShapeIDs: [UUID] = []) {
        self.modelID = modelID; self.resolution = resolution; self.roughing = roughing
        self.finishing = finishing; self.boundaryShapeIDs = boundaryShapeIDs
    }

    /// Primary model first, then the combined ones (duplicates removed).
    public var allModelIDs: [UUID] {
        var seen: Set<UUID> = [modelID]
        return [modelID] + (additionalModelIDs ?? []).filter { seen.insert($0).inserted }
    }
}

/// Z-level roughing with a flat end mill.
public struct RoughingSettings: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    /// Roughing tool; nil = use the operation's primary tool.
    public var toolID: UUID?
    /// Material left on the model for finishing.
    public var allowance: Double
    public var passDepth: Double?
    public var strategy: PocketStrategy

    public init(isEnabled: Bool = true, toolID: UUID? = nil, allowance: Double = 0.02, passDepth: Double? = nil,
                strategy: PocketStrategy = .raster(angle: 0, profilePass: false)) {
        self.isEnabled = isEnabled; self.toolID = toolID; self.allowance = allowance; self.passDepth = passDepth
        self.strategy = strategy
    }
}

/// Pattern of 3D finishing passes.
public enum FinishingStrategy: String, Codable, CaseIterable, Sendable {
    /// Parallel lines at `FinishingSettings.angle`.
    case raster
    /// Contour-parallel rings from the boundary inwards.
    case offset
    /// One continuous spiral from the boundary inwards (rings where the area splits).
    case spiral
}

/// Finishing with the operation's primary tool (ball / flat / V).
public struct FinishingSettings: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    /// Stepover; nil = the tool's stepover.
    public var stepover: Double?
    /// Raster angle in degrees.
    public var angle: Double
    /// Pass pattern; nil = raster (files from before strategies existed).
    public var strategy: FinishingStrategy?
    /// Rest machining: the earlier toolpath whose (larger) finishing tool already finished this surface; only the
    /// areas it could not reach are machined. nil = no rest machining, the whole area.
    public var rest: RestSource?

    public init(isEnabled: Bool = true, stepover: Double? = nil, angle: Double = 0,
                strategy: FinishingStrategy? = nil) {
        self.isEnabled = isEnabled; self.stepover = stepover; self.angle = angle; self.strategy = strategy
    }

    private enum CodingKeys: String, CodingKey { case isEnabled, stepover, angle, strategy, rest, restToolID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        stepover = try c.decodeIfPresent(Double.self, forKey: .stepover)
        angle = try c.decode(Double.self, forKey: .angle)
        strategy = try c.decodeIfPresent(FinishingStrategy.self, forKey: .strategy)
        rest = try c.decodeIfPresent(RestSource.self, forKey: .rest)
        // Older files named the rest tool, not the toolpath: it is never read as "no rest" (a whole-area pass).
        if rest == nil, let tool = try c.decodeIfPresent(UUID.self, forKey: .restToolID) { rest = .unresolved(toolID: tool) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encodeIfPresent(stepover, forKey: .stepover)
        try c.encode(angle, forKey: .angle)
        try c.encodeIfPresent(strategy, forKey: .strategy)
        try c.encodeIfPresent(rest, forKey: .rest)
    }
}

/// The toolpath a rest pass follows.
public enum RestSource: Codable, Hashable, Sendable {
    /// An earlier 3D finish (its operation id).
    case operation(UUID)
    /// From an older file that named only the rest tool and had no earlier finish with it. Never generates: the user
    /// chooses the toolpath this rests after.
    case unresolved(toolID: UUID)
}

/// Two-sided 3D machining: which side this toolpath cuts. The split (flip, split depth, web) is the model's
/// (`PlacedModel.reliefSplit`), shared by both sides.
public struct TwoSidedSettings: Codable, Hashable, Sendable {
    public enum Side: String, Codable, CaseIterable, Sendable {
        /// First side, as placed (material top up).
        case top
        /// Second side, after flipping the board.
        case bottom
    }

    public var side: Side
    /// An older file stored the split on each side's toolpath and the two disagreed: the model took the top side's,
    /// and this toolpath is not cut until the user confirms it (Use These Settings).
    public var splitNeedsReview: Bool?
    /// The split an older file stored on this toolpath. Decoded only, for the upgrade that moves it to the model.
    public var legacySplit: ReliefSplit?

    public init(side: Side = .top) { self.side = side }

    private enum CodingKeys: String, CodingKey { case side, splitNeedsReview, flip, splitDepth, web }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        side = try c.decode(Side.self, forKey: .side)
        splitNeedsReview = try c.decodeIfPresent(Bool.self, forKey: .splitNeedsReview)
        if let flip = try c.decodeIfPresent(FlipAxis.self, forKey: .flip) {
            legacySplit = ReliefSplit(flip: flip, splitDepth: try c.decodeIfPresent(Double.self, forKey: .splitDepth),
                                      web: try c.decodeIfPresent(Double.self, forKey: .web) ?? 0)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(side, forKey: .side)
        try c.encodeIfPresent(splitNeedsReview, forKey: .splitNeedsReview)
    }
}
