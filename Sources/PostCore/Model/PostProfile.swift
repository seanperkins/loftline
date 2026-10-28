import CADCore
import Foundation

/// Data-driven post-processor definition (serialisable to JSON) so new machines can be added
/// without code. Template placeholders:
///   {T} tool number, {TOOL_NAME}, {S} spindle RPM, {SECONDS} dwell (the dwell template may use {MILLISECONDS} instead),
///   {SAFE_Z}, {HOME_X}, {HOME_Y},
///   {HOME_Z}, {JOB_NAME}, {POST_NAME}, {POST_VERSION}
/// Numeric placeholders are formatted with `decimals`.
public struct PostProfile: Codable, Hashable, Identifiable, Sendable {
    public enum CommentStyle: String, Codable, Sendable { case parentheses, semicolon }
    public enum ArcOutput: String, Codable, Sendable {
        /// G2/G3 with I J relative to the arc start (Mach default, GRBL).
        case incrementalIJ
        /// G2/G3 with absolute I J centre.
        case absoluteIJ
        /// No arcs: linearize with `arcTolerance`.
        case linearize
    }

    public var id: String
    public var name: String
    public var version: String
    public var fileExtension: String
    /// Output units; toolpaths are scaled from document units if different.
    public var units: LengthUnit
    public var commentStyle: CommentStyle
    public var lineNumbers: Bool
    /// Coordinate decimals (4 for inch, 3 for mm is typical).
    public var decimals: Int
    public var feedDecimals: Int
    /// Emit the header comment block (job, tools, material, Z zero, post version).
    public var headerComments: Bool
    /// Modal setup after the units code (G20/G21 is emitted automatically before these).
    public var preamble: [String]
    /// Lines emitted at every tool change (including the first tool).
    public var toolChange: [String]
    /// When true, `toolLengthOffset` is emitted after the tool change.
    public var useToolLengthOffset: Bool
    public var toolLengthOffset: String
    public var spindleOn: String
    /// Dwell after spindle start, seconds (0 = none).
    public var spindleDwellSeconds: Double
    public var dwell: String
    public var spindleOff: String
    public var minRPM: Double
    public var maxRPM: Double
    public var rapid: String
    public var linear: String
    public var arcCW: String
    public var arcCCW: String
    public var arcOutput: ArcOutput
    /// Chordal tolerance for linearized arcs, in output units.
    public var arcTolerance: Double
    /// Allow helical arcs (Z change during G2/G3); otherwise helices are linearized.
    public var helicalArcs: Bool
    /// Omit repeated G-words/feeds when unchanged.
    public var modal: Bool
    public var footer: [String]
    public var limits: MachineLimits
    /// Rapid traverse speed in output units per minute (for time estimates).
    public var rapidRate: Double
    public var maxFeed: Double
    /// Lines emitted for an operator pause (see `PauseStep`), after the post lifts to safe Z. Placeholders:
    /// {MESSAGE} (the pause's text, comment-safe) and {STOP} (M0, or M1 for an optional stop).
    /// nil = `defaultPause`, which stops the spindle first. Optional so older saved posts still load.
    public var pause: [String]?
    /// The controller this post's program runs on, declared by the post's owner (nil = not declared). Touch-plate tool changes
    /// need it: the probe sequence is written in code for that controller. Built-in posts leave it nil and are recognised by
    /// value (`BuiltInPosts.probeController(for:)`), so their bytes do not change.
    public var controller: ToolChangeProbe.Controller?
    /// The highest version of a post's JSON layout this LoftLine reads. A project or file whose copy has a higher version is
    /// refused, never read with fields or placeholders dropped. Raise it when a reader that drops a new field or placeholder
    /// could post different G-code (`controller` does not: without it a post cannot probe), and say in
    /// `requiredSchemaVersion` which content needs it. 2: `{MILLISECONDS}` in the dwell template.
    public static let currentSchemaVersion = 2
    /// Always 1 in memory: a post is written with `requiredSchemaVersion` (`toJSON`, `snapshot`) and read back as 1, so the
    /// version never takes part in value equality (`BuiltInPosts.probeController` recognises a built-in by value).
    @SchemaVersion public var schemaVersion: Int = 1
    /// The machine's park-and-probe tool change, set by `MachineDefinition.applied(to:)` when the post is used. Never read
    /// from or written to a file, so a post file or a project copy cannot switch probing on.
    @NeverCoded public var toolChangeProbe: ProbeSetting? = nil

    public init(id: String, name: String, version: String = "1.0", fileExtension: String = "tap",
                units: LengthUnit, commentStyle: CommentStyle = .parentheses, lineNumbers: Bool = false,
                decimals: Int, feedDecimals: Int = 1, headerComments: Bool = true,
                preamble: [String], toolChange: [String], useToolLengthOffset: Bool = false,
                toolLengthOffset: String = "G43 H{T}", spindleOn: String = "M3 S{S}",
                spindleDwellSeconds: Double = 3, dwell: String = "G4 P{SECONDS}", spindleOff: String = "M5",
                minRPM: Double, maxRPM: Double, rapid: String = "G0", linear: String = "G1",
                arcCW: String = "G2", arcCCW: String = "G3", arcOutput: ArcOutput = .incrementalIJ,
                arcTolerance: Double, helicalArcs: Bool = true, modal: Bool = true, footer: [String],
                limits: MachineLimits, rapidRate: Double, maxFeed: Double, pause: [String]? = nil) {
        self.id = id; self.name = name; self.version = version; self.fileExtension = fileExtension
        self.units = units; self.commentStyle = commentStyle; self.lineNumbers = lineNumbers
        self.decimals = decimals; self.feedDecimals = feedDecimals; self.headerComments = headerComments
        self.preamble = preamble; self.toolChange = toolChange; self.useToolLengthOffset = useToolLengthOffset
        self.toolLengthOffset = toolLengthOffset; self.spindleOn = spindleOn
        self.spindleDwellSeconds = spindleDwellSeconds; self.dwell = dwell; self.spindleOff = spindleOff
        self.minRPM = minRPM; self.maxRPM = maxRPM; self.rapid = rapid; self.linear = linear
        self.arcCW = arcCW; self.arcCCW = arcCCW; self.arcOutput = arcOutput; self.arcTolerance = arcTolerance
        self.helicalArcs = helicalArcs; self.modal = modal; self.footer = footer; self.limits = limits
        self.rapidRate = rapidRate; self.maxFeed = maxFeed; self.pause = pause
    }

    /// Spindle off, the message where the controller shows it, then the stop. The message is a
    /// parenthesised MSG comment (Mach3/4 and LinuxCNC display it; GRBL senders echo the comment
    /// when they stop), or a `;` comment in a post that writes its comments that way.
    public static func defaultPause(for style: CommentStyle) -> [String] {
        ["M5", style == .semicolon ? "; {MESSAGE}" : "(MSG, {MESSAGE})", "{STOP}"]
    }

    /// The post as every reader takes it: an empty pause list means the default pause. An empty template would post no stop at
    /// all, so a file or a project copy that holds one is read this way wherever a post is read (the posts folder, an import,
    /// a project's copy).
    public var normalized: PostProfile {
        var p = self
        if p.pause?.isEmpty == true { p.pause = nil }
        return p
    }

    /// The pause template in effect.
    public var pauseLines: [String] { pause ?? Self.defaultPause(for: commentStyle) }

    /// Whether the controller can stop at M1 (an Optional Stop switch); where it cannot, an optional stop writes M0 and is
    /// described as a stop that always happens.
    /// - GRBL has no switch and ignores M1 (gnea/grbl `gcode.c`: "Optional stop not supported. Ignore."), so a post that speaks
    ///   GRBL, built in or declared, writes M0 (#115). Judged by value, with the numbers a machine replaces
    ///   (`MachineDefinition.applied(to:)`) put back first, so the post export uses is still recognised as the built-in.
    /// - The Othermill, Buildbotics and Carbide Motion have no usable switch (`BuiltInPosts.secondsNoOptionalStopIDs`). Judged by
    ///   id, so an edited post that keeps the id still writes M0.
    public var honoursOptionalStop: Bool {
        if BuiltInPosts.secondsNoOptionalStopIDs.contains(id) { return false }
        var base = self
        base.toolChangeProbe = nil
        if let builtIn = BuiltInPosts.profile(id: id) {
            base.limits = builtIn.limits; base.rapidRate = builtIn.rapidRate; base.maxFeed = builtIn.maxFeed
            base.minRPM = builtIn.minRPM; base.maxRPM = builtIn.maxRPM
        }
        return BuiltInPosts.probeController(for: base) != .grbl
    }

    /// "G20" or "G21".
    public var unitsCode: String { units == .inch ? "G20" : "G21" }

    public func comment(_ text: String) -> String {
        let text = Self.asciiOnly(text)
        switch commentStyle {
        case .parentheses:
            // Parentheses cannot nest in G-code comments.
            let clean = text.replacingOccurrences(of: "(", with: "[").replacingOccurrences(of: ")", with: "]")
            return "( \(clean) )"
        case .semicolon:
            // Brackets too: a parenthesis anywhere locks up some senders (Carbide Motion, #105).
            return "; " + text.replacingOccurrences(of: "(", with: "[").replacingOccurrences(of: ")", with: "]")
        }
    }

    /// Controllers vary in how they treat non-ASCII bytes; keep comments plain ASCII. Control
    /// characters (a newline inside a tool or job name would start a new, uncommented block)
    /// become spaces.
    public static func asciiOnly(_ text: String) -> String {
        let replaced = text.replacingOccurrences(of: "°", with: " deg")
            .replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "‘", with: "'").replacingOccurrences(of: "’", with: "'")
        let stripped = replaced.applyingTransform(.stripDiacritics, reverse: false) ?? replaced
        // A line break or other control character would end the comment and start a new G-code line.
        let plain = stripped.unicodeScalars.filter { $0.isASCII }.map { s -> Character in
            s.value < 0x20 || s.value == 0x7F ? " " : Character(s)
        }
        return String(plain)
    }

    public func toJSON() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(stamped)
    }

    /// The oldest layout version that can read this post without posting different G-code: 2 for a dwell in milliseconds
    /// (an older LoftLine leaves `{MILLISECONDS}` in the text), else 1, which every LoftLine since `schemaVersion` reads.
    public var requiredSchemaVersion: Int { dwell.contains("{MILLISECONDS}") ? 2 : 1 }

    /// This post as it is written: its version is what its content needs, not what it was read with.
    private var stamped: PostProfile {
        var p = self
        p.schemaVersion = requiredSchemaVersion
        return p
    }

    /// A post as it is read: the version has done its job (refusing a newer file) and is reset, so it never takes part in
    /// value equality.
    private var unstamped: PostProfile {
        var p = self
        p.schemaVersion = 1
        return p
    }

    /// Throws `SnapshotError.newerSchema` for a file from a newer LoftLine, so a store skips it instead of loading it
    /// with the fields this version does not know dropped.
    public static func fromJSON(_ data: Data) throws -> PostProfile {
        try SnapshotDecoding.decode(PostProfile.self, from: data, supported: currentSchemaVersion).checkingBounds().unstamped
    }

    /// A post read back from the copy a project carries (`snapshot()`); refused when newer or unreadable.
    public init(snapshot: JSONValue) throws {
        self = try SnapshotDecoding.decode(PostProfile.self, from: snapshot, supported: Self.currentSchemaVersion).checkingBounds()
            .unstamped
    }

    public func snapshot() throws -> JSONValue { try JSONValue(encoding: stamped) }

    /// A post is data from anywhere (a project from someone else, a file in the posts folder): the number of decimals it
    /// asks for is what every coordinate is formatted with, so an absurd one would exhaust memory at export. 0 to 12 covers
    /// every controller. The spin-up dwell is bounded too, so `{MILLISECONDS}` always prints a number.
    func checkingBounds() throws -> PostProfile {
        for (name, value) in [("decimals", decimals), ("feedDecimals", feedDecimals)] where !(0...12).contains(value) {
            throw SnapshotError.malformed("\(name) must be 0 to 12 (found \(value))")
        }
        guard (0...Self.maxDwellSeconds).contains(spindleDwellSeconds) else {
            throw SnapshotError.malformed("the spindle dwell must be 0 to \(Int(Self.maxDwellSeconds)) s (found \(spindleDwellSeconds))")
        }
        return self
    }

    /// The longest dwell a program may hold (spin-up or toolpath): an hour. Beyond it `{MILLISECONDS}` could print `INF`.
    public static let maxDwellSeconds = 3600.0

    /// The dwell template's values: `{SECONDS}` (3 s → `3`) and `{MILLISECONDS}` (3 s → `3000`; whole, `%.0f`), for a
    /// controller whose `G4 P` is milliseconds (MASSO, NcStudio, UCCNC by default; #99 item 1).
    public func dwellValues(seconds: Double) -> [String: String] {
        ["SECONDS": NumberFormat.compact(seconds), "MILLISECONDS": NumberFormat.fixed(seconds * 1000, decimals: 0)]
    }

    /// Why this post's dwell would be written in the wrong unit, or nil. The editor lists it; the builder refuses to post with
    /// it, since a post file or a project copy never passes the editor.
    public var dwellProblem: String? {
        if !(0...Self.maxDwellSeconds).contains(spindleDwellSeconds) {
            return "The spindle dwell must be 0 to \(Int(Self.maxDwellSeconds)) s."
        }
        guard dwell.contains("{MILLISECONDS}") else { return nil }
        let others = preamble + toolChange + [toolLengthOffset, spindleOn] + footer + pauseLines
        if others.contains(where: { $0.contains("{SECONDS}") }) {
            return "A post that dwells in milliseconds cannot also write {SECONDS}: a G4 P{SECONDS} elsewhere would dwell milliseconds."
        }
        if controller == .grbl || BuiltInPosts.secondsNoOptionalStopIDs.contains(id) || BuiltInPosts.grblIDs.contains(id) {
            return "This controller reads G4 P in seconds: a dwell in milliseconds would wait a thousand times too long."
        }
        return nil
    }
}

/// Machine travel envelope in the profile's units.
public struct MachineLimits: Codable, Hashable, Sendable {
    public var xTravel: Double
    public var yTravel: Double
    public var zTravel: Double
    /// Max allowed cut below the spoilboard surface (into the spoilboard), positive value.
    public var maxSpoilboardCut: Double

    public init(xTravel: Double, yTravel: Double, zTravel: Double, maxSpoilboardCut: Double) {
        self.xTravel = xTravel; self.yTravel = yTravel; self.zTravel = zTravel
        self.maxSpoilboardCut = maxSpoilboardCut
    }
}
