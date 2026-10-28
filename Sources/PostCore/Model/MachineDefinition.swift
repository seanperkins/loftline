import CADCore
import Foundation

/// A physical CNC machine: its working envelope and the post processors that drive it. Picked
/// once per job (and as an app default); the machine's limits replace the post profile's when
/// validating and estimating, so one post can serve machines of different sizes.
public struct MachineDefinition: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// Units of `limits`, `rapidRate` and `maxFeed`.
    public var units: LengthUnit
    /// Travel envelope (bed size and Z travel) in `units`.
    public var limits: MachineLimits
    /// Compatible post profiles (`PostProfile.id`), in order of preference.
    public var postIDs: [String]
    /// Rapid traverse speed, `units` per minute. nil = the post's value.
    public var rapidRate: Double?
    /// Fastest programmable feed, `units` per minute. nil = the post's value.
    public var maxFeed: Double?
    /// Spindle range. nil = the post's values.
    public var minRPM: Double?
    public var maxRPM: Double?
    public var notes: String?
    /// Park, swap by hand and re-zero Z on a touch plate at every tool change (nil = off, the post's own tool change).
    public var toolChangeProbe: ToolChangeProbe?
    /// Set when a project asked for probing that this machine cannot give (see `ProjectPost.resolve`); the post built
    /// from this machine then refuses. Never in a file.
    @NeverCoded public var probeRefusal: String? = nil
    /// See `PostProfile.currentSchemaVersion`: 1 for every file written before the key existed.
    public static let currentSchemaVersion = 1
    @SchemaVersion public var schemaVersion: Int = MachineDefinition.currentSchemaVersion

    public init(id: String, name: String, units: LengthUnit, limits: MachineLimits, postIDs: [String],
                rapidRate: Double? = nil, maxFeed: Double? = nil, minRPM: Double? = nil, maxRPM: Double? = nil,
                notes: String? = nil) {
        self.id = id; self.name = name; self.units = units; self.limits = limits; self.postIDs = postIDs
        self.rapidRate = rapidRate; self.maxFeed = maxFeed; self.minRPM = minRPM; self.maxRPM = maxRPM
        self.notes = notes
    }

    /// The first compatible post (among `available`) in `documentUnits`, else the first compatible
    /// post that exists at all. nil when none of `postIDs` is available.
    public func defaultPostID(for documentUnits: LengthUnit, available: [PostProfile]) -> String? {
        let compatible = postIDs.compactMap { id in available.first { $0.id == id } }
        return (compatible.first { $0.units == documentUnits } ?? compatible.first)?.id
    }

    public func supports(postID: String) -> Bool { postIDs.contains(postID) }

    /// None of the listed posts installed (`available`, a user file replacing a built-in of its id) speaks a controller, so
    /// probing on would refuse every export: the check export makes (`probeSetting`). A listed post that is not installed
    /// cannot be posted with, so it is not counted; false when none is installed.
    public func noListedPostCanProbe(available: [PostProfile]) -> Bool {
        let listed = postIDs.compactMap { id in available.first { $0.id == id } }
        return !listed.isEmpty && listed.allSatisfy { post in
            var base = post
            base.toolChangeProbe = nil
            return BuiltInPosts.probeController(for: base) == nil
        }
    }

    /// `profile` with this machine's limits, rapid rate, max feed and RPM range converted into the
    /// profile's output units. Everything textual (the G-code dialect) stays the post's.
    public func applied(to profile: PostProfile) -> PostProfile {
        var p = profile
        let f = units.factor(to: profile.units)
        p.limits = MachineLimits(xTravel: limits.xTravel * f, yTravel: limits.yTravel * f,
                                 zTravel: limits.zTravel * f, maxSpoilboardCut: limits.maxSpoilboardCut * f)
        if let r = rapidRate { p.rapidRate = r * f }
        if let m = maxFeed { p.maxFeed = m * f }
        if let lo = minRPM { p.minRPM = lo }
        if let hi = maxRPM { p.maxRPM = hi }
        p.toolChangeProbe = probeSetting(for: profile, factor: f)
        return p
    }

    /// The probe a post built from this machine and `raw` carries. Only a post that speaks the probe's controller can probe:
    /// a built-in post unchanged, or a post whose owner declared the controller (`PostProfile.controller`). A machine's post
    /// list is editable, so the list alone proves nothing.
    private func probeSetting(for raw: PostProfile, factor f: Double) -> ProbeSetting? {
        if let r = probeRefusal { return .refused(r) }
        guard let probe = toolChangeProbe else { return nil }
        var base = raw
        base.toolChangeProbe = nil
        guard let declared = BuiltInPosts.probeController(for: base) else {
            if BuiltInPosts.profile(id: base.id) == base {
                // A built-in with no probe sequence (LinuxCNC): declaring another controller would write its codes.
                return .refused("The built-in post \"\(raw.name)\" cannot probe tool changes: turn off park and probe for this "
                                + "machine in Preferences > Machines.")
            }
            return .refused("The post \"\(raw.name)\" declares no controller, so it cannot probe tool changes: declare \(probe.controller.displayName) "
                            + "in Toolpaths > Post Processors, or use the built-in post.")
        }
        guard declared == probe.controller else {
            return .refused("The post \"\(raw.name)\" declares \(declared.displayName); this machine probes with "
                            + "\(probe.controller.displayName).")
        }
        return .on(probe.scaled(by: f))
    }

    /// The machine in `new` units: every length and speed scaled, the probe's included (the Machines editor's switch).
    public func switchingUnits(to new: LengthUnit) -> MachineDefinition {
        guard new != units else { return self }
        var m = self
        let f = units.factor(to: new)
        m.limits = MachineLimits(xTravel: limits.xTravel * f, yTravel: limits.yTravel * f, zTravel: limits.zTravel * f,
                                 maxSpoilboardCut: limits.maxSpoilboardCut * f)
        m.rapidRate = rapidRate.map { $0 * f }
        m.maxFeed = maxFeed.map { $0 * f }
        m.toolChangeProbe = toolChangeProbe?.scaled(by: f)
        m.units = new
        return m
    }

    /// "60 x 96 x 8 in".
    public var envelopeDescription: String {
        func f(_ v: Double) -> String {
            let r = (v * 1000).rounded() / 1000
            return r == r.rounded() ? String(Int(r)) : String(r)
        }
        return "\(f(limits.xTravel)) x \(f(limits.yTravel)) x \(f(limits.zTravel)) \(units.abbreviation)"
    }

    public func toJSON() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    /// Throws `SnapshotError.newerSchema` for a file from a newer LoftLine (see `PostProfile.fromJSON`).
    public static func fromJSON(_ data: Data) throws -> MachineDefinition {
        try SnapshotDecoding.decode(MachineDefinition.self, from: data, supported: currentSchemaVersion)
    }

    /// A machine read back from the copy a project carries (`snapshot()`); refused when newer or unreadable.
    public init(snapshot: JSONValue) throws {
        self = try SnapshotDecoding.decode(MachineDefinition.self, from: snapshot, supported: Self.currentSchemaVersion)
    }

    public func snapshot() throws -> JSONValue { try JSONValue(encoding: self) }
}

/// Machines shipped with LoftLine. Their limits match the built-in posts, so jobs saved before
/// machines existed validate exactly as before.
public enum BuiltInMachines {
    /// Avid CNC PRO6096 running Mach4.
    public static let avidPRO6096 = MachineDefinition(
        id: "avid-pro6096", name: "Avid PRO6096 (Mach4)", units: .inch,
        limits: BuiltInPosts.avidMach4Inch.limits,
        postIDs: [BuiltInPosts.avidMach4Inch.id, BuiltInPosts.avidMach4MM.id],
        rapidRate: BuiltInPosts.avidMach4Inch.rapidRate, maxFeed: BuiltInPosts.avidMach4Inch.maxFeed,
        minRPM: 6000, maxRPM: 24000,
        notes: "60 x 96 in bed, single spindle, manual tool changes.")

    /// A small hobby router running GRBL 1.1.
    public static let genericGRBL = MachineDefinition(
        id: "generic-grbl", name: "Generic GRBL router", units: .millimeter,
        limits: BuiltInPosts.genericGRBLMM.limits,
        postIDs: [BuiltInPosts.genericGRBLMM.id],
        rapidRate: BuiltInPosts.genericGRBLMM.rapidRate, maxFeed: BuiltInPosts.genericGRBLMM.maxFeed)

    public static let all: [MachineDefinition] = [avidPRO6096, genericGRBL]
    public static let defaultID = avidPRO6096.id

    public static func machine(id: String) -> MachineDefinition? { all.first { $0.id == id } }
}
