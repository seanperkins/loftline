import CADCore
import Foundation

/// Profiles shipped with LoftLine. Users can add more as JSON (see docs/specs).
public enum BuiltInPosts {
    /// G91.1: arc centres (I/J) relative to the arc start, which is what these posts write. Mach4
    /// keeps the IJ mode as a controller setting, so the program states it rather than trusting it.
    static let machPreamble = ["G90", "G91.1", "G17", "G40", "G49", "G80", "G94"]
    static let machToolChange = ["M5", "(Change to Tool: {TOOL_NAME})", "T{T} M6"]
    /// Lifts to Home Z (Job Setup keeps it at or above Safe Z) before parking at home XY.
    static let standardFooter = ["G0 Z{HOME_Z}", "M5", "G0 X{HOME_X} Y{HOME_Y}", "M30"]

    /// Avid PRO6096, Mach4, inches. 60" x 96" travel.
    public static let avidMach4Inch = PostProfile(
        id: "avid-pro6096-mach4-inch", name: "Avid PRO6096 Mach4 (inch)", version: "1.0",
        fileExtension: "tap", units: .inch, decimals: 4, feedDecimals: 1,
        preamble: machPreamble, toolChange: machToolChange, spindleDwellSeconds: 3,
        minRPM: 6000, maxRPM: 24000, arcOutput: .incrementalIJ, arcTolerance: 0.0005,
        footer: standardFooter,
        limits: MachineLimits(xTravel: 60, yTravel: 96, zTravel: 8, maxSpoilboardCut: 0.05),
        rapidRate: 600, maxFeed: 600)

    /// Same machine, millimetres.
    public static let avidMach4MM = PostProfile(
        id: "avid-pro6096-mach4-mm", name: "Avid PRO6096 Mach4 (mm)", version: "1.0",
        fileExtension: "tap", units: .millimeter, decimals: 3, feedDecimals: 0,
        preamble: machPreamble, toolChange: machToolChange, spindleDwellSeconds: 3,
        minRPM: 6000, maxRPM: 24000, arcOutput: .incrementalIJ, arcTolerance: 0.01,
        footer: standardFooter,
        limits: MachineLimits(xTravel: 1524, yTravel: 2438.4, zTravel: 203.2, maxSpoilboardCut: 1.0),
        rapidRate: 15240, maxFeed: 15240)

    /// Generic GRBL 1.1 (e.g. X-Carve). No M6: pauses with M0 for manual changes.
    public static let genericGRBLMM = PostProfile(
        id: "generic-grbl-mm", name: "Generic GRBL (mm)", version: "1.0",
        fileExtension: "nc", units: .millimeter, decimals: 3, feedDecimals: 0,
        preamble: ["G90", "G17", "G94"], toolChange: ["M5", "(Change to Tool: {TOOL_NAME})", "M0"],
        spindleDwellSeconds: 3, minRPM: 0, maxRPM: 30000, arcOutput: .incrementalIJ, arcTolerance: 0.01,
        footer: ["G0 Z{HOME_Z}", "M5", "G0 X{HOME_X} Y{HOME_Y}", "M2"],
        limits: MachineLimits(xTravel: 750, yTravel: 750, zTravel: 65, maxSpoilboardCut: 1.0),
        rapidRate: 8000, maxFeed: 8000)

    public static let all: [PostProfile] = [avidMach4Inch, avidMach4MM, genericGRBLMM]

    public static func profile(id: String) -> PostProfile? { all.first { $0.id == id } }

    /// The controller a built-in post speaks, when `raw` is that post unchanged (compared by value, not by id: a user
    /// file or a project copy can carry a built-in's id with other text). nil for any other post.
    public static func probeController(for raw: PostProfile) -> ToolChangeProbe.Controller? {
        guard let builtIn = profile(id: raw.id), builtIn == raw else { return nil }
        switch raw.id {
        case avidMach4Inch.id, avidMach4MM.id: return .mach4
        case genericGRBLMM.id: return .grbl
        default: return nil
        }
    }
}
