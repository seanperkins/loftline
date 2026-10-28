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

    /// The standard footer ending with M2 (GRBL, LinuxCNC) instead of M30.
    static let m2Footer = ["G0 Z{HOME_Z}", "M5", "G0 X{HOME_X} Y{HOME_Y}", "M2"]

    /// The GRBL mm post in inches; its limits and rates are the mm post's, rounded down.
    public static let genericGRBLInch = PostProfile(
        id: "generic-grbl-inch", name: "Generic GRBL (inch)", version: "1.0",
        fileExtension: "nc", units: .inch, decimals: 4, feedDecimals: 1,
        preamble: ["G90", "G17", "G94"], toolChange: ["M5", "(Change to Tool: {TOOL_NAME})", "M0"],
        spindleDwellSeconds: 3, minRPM: 0, maxRPM: 30000, arcOutput: .incrementalIJ, arcTolerance: 0.0005,
        footer: m2Footer,
        limits: MachineLimits(xTravel: 29.5, yTravel: 29.5, zTravel: 2.55, maxSpoilboardCut: 0.039),
        rapidRate: 314.9, maxFeed: 314.9)

    /// LinuxCNC stops for a tool with M0, which pauses on every configuration (M6 may complete at once, and a T missing from
    /// the tool table aborts). Its screens show only `(MSG, …)` comments.
    static let linuxCNCToolChange = ["M5", "(MSG, Change to Tool: {TOOL_NAME})", "M0"]

    public static let linuxCNCInch = PostProfile(
        id: "linuxcnc-inch", name: "LinuxCNC (inch)", version: "1.0",
        fileExtension: "ngc", units: .inch, decimals: 4, feedDecimals: 1,
        preamble: machPreamble, toolChange: linuxCNCToolChange,
        spindleDwellSeconds: 3, minRPM: 0, maxRPM: 24000, arcOutput: .incrementalIJ, arcTolerance: 0.0005,
        footer: m2Footer,
        limits: MachineLimits(xTravel: 48, yTravel: 48, zTravel: 6, maxSpoilboardCut: 0.05),
        rapidRate: 200, maxFeed: 200)

    public static let linuxCNCMM = PostProfile(
        id: "linuxcnc-mm", name: "LinuxCNC (mm)", version: "1.0",
        fileExtension: "ngc", units: .millimeter, decimals: 3, feedDecimals: 0,
        preamble: machPreamble, toolChange: linuxCNCToolChange,
        spindleDwellSeconds: 3, minRPM: 0, maxRPM: 24000, arcOutput: .incrementalIJ, arcTolerance: 0.01,
        footer: m2Footer,
        limits: MachineLimits(xTravel: 1219.2, yTravel: 1219.2, zTravel: 152.4, maxSpoilboardCut: 1.27),
        rapidRate: 5080, maxFeed: 5080)

    /// The Othermill Pro and the original Othermill, through the Bantam Tools Milling Machine Software (formerly Otherplan)
    /// on a TinyG board (#114; spec docs/specs/2026-10-28-othermill-post-design.md). Only codes the software runs: `G55` is its
    /// one work offset, no `G40`/`G49`/`G91.1` (a line it cannot run is skipped silently), `T M6` makes it prompt for the swap
    /// and touch the tool off, helices are written as lines, and the program ends with `M30`. Limits are the Pro's.
    static let othermillPreamble = ["G90", "G94", "G17", "G55"]
    static let othermillToolChange = ["M5", "(Change to Tool: {TOOL_NAME})", "T{T} M6"]
    static let othermillFooter = ["G0 Z{HOME_Z}", "M5", "G0 X{HOME_X} Y{HOME_Y}", "M30"]

    public static let othermillInch = PostProfile(
        id: "othermill-inch", name: "Othermill (inch)", version: "1.0",
        fileExtension: "gcode", units: .inch, decimals: 4, feedDecimals: 1,
        preamble: othermillPreamble, toolChange: othermillToolChange,
        spindleDwellSeconds: 4, minRPM: 7000, maxRPM: 26000, arcOutput: .incrementalIJ, arcTolerance: 0.0005,
        helicalArcs: false, footer: othermillFooter,
        limits: MachineLimits(xTravel: 5.5, yTravel: 4.5, zTravel: 1.35, maxSpoilboardCut: 0.01),
        rapidRate: 100, maxFeed: 100)

    public static let othermillMM = PostProfile(
        id: "othermill-mm", name: "Othermill (mm)", version: "1.0",
        fileExtension: "gcode", units: .millimeter, decimals: 3, feedDecimals: 0,
        preamble: othermillPreamble, toolChange: othermillToolChange,
        spindleDwellSeconds: 4, minRPM: 7000, maxRPM: 26000, arcOutput: .incrementalIJ, arcTolerance: 0.01,
        helicalArcs: false, footer: othermillFooter,
        limits: MachineLimits(xTravel: 139.7, yTravel: 114.3, zTravel: 34.29, maxSpoilboardCut: 0.254),
        rapidRate: 2540, maxFeed: 2540)

    /// Onefinity Original/Pro on the Buildbotics controller (#104): the CAMotics planner, a LinuxCNC subset. Only the preamble
    /// words its source handles (no `G40`, `G80`); a tool change stops with M0, since owners cannot jog during BB's M6 pause;
    /// `M2` ends the program (its M30 handling is a TODO). Limits are the Woodworker's.
    static let bbPreamble = ["G90", "G91.1", "G17", "G49", "G94"]

    public static let onefinityBBInch = PostProfile(
        id: "onefinity-bb-inch", name: "Onefinity Buildbotics (inch)", version: "1.0",
        fileExtension: "ngc", units: .inch, decimals: 4, feedDecimals: 1,
        preamble: bbPreamble, toolChange: linuxCNCToolChange,
        spindleDwellSeconds: 3, minRPM: 10000, maxRPM: 30000, arcOutput: .incrementalIJ, arcTolerance: 0.0005,
        footer: m2Footer,
        limits: MachineLimits(xTravel: 32.125, yTravel: 32.125, zTravel: 5.25, maxSpoilboardCut: 0.05),
        rapidRate: 400, maxFeed: 400)

    public static let onefinityBBMM = PostProfile(
        id: "onefinity-bb-mm", name: "Onefinity Buildbotics (mm)", version: "1.0",
        fileExtension: "ngc", units: .millimeter, decimals: 3, feedDecimals: 0,
        preamble: bbPreamble, toolChange: linuxCNCToolChange,
        spindleDwellSeconds: 3, minRPM: 10000, maxRPM: 30000, arcOutput: .incrementalIJ, arcTolerance: 0.01,
        footer: m2Footer,
        limits: MachineLimits(xTravel: 815.975, yTravel: 815.975, zTravel: 133.35, maxSpoilboardCut: 1.27),
        rapidRate: 10160, maxFeed: 10160)

    /// The Shapeoko through Carbide Motion (#105), which rewrites G-code on the fly, so its supported-codes page is the dialect:
    /// `;` comments (parentheses lock up a Shapeoko 5 Pro under some senders), only listed preamble words, `T M6` (CM prompts
    /// and, with a BitSetter, measures), `M2` (its M30 may return to the machine origin). Limits are the 5 Pro 2x2's; feeds and
    /// spindle range are the GRBL posts' (Carbide publishes neither).
    static let carbidePreamble = ["G90", "G17", "G40", "G49", "G54"]
    static let carbideToolChange = ["M5", "; Change to Tool: {TOOL_NAME}", "T{T} M6"]

    public static let carbideMotionInch = PostProfile(
        id: "carbide-motion-inch", name: "Carbide Motion (inch)", version: "1.0",
        fileExtension: "nc", units: .inch, commentStyle: .semicolon, decimals: 4, feedDecimals: 1,
        preamble: carbidePreamble, toolChange: carbideToolChange,
        spindleDwellSeconds: 3, minRPM: 0, maxRPM: 30000, arcOutput: .incrementalIJ, arcTolerance: 0.0005,
        footer: m2Footer,
        limits: MachineLimits(xTravel: 24.5, yTravel: 24.5, zTravel: 6.1, maxSpoilboardCut: 0.039),
        rapidRate: 314.9, maxFeed: 314.9)

    public static let carbideMotionMM = PostProfile(
        id: "carbide-motion-mm", name: "Carbide Motion (mm)", version: "1.0",
        fileExtension: "nc", units: .millimeter, commentStyle: .semicolon, decimals: 3, feedDecimals: 0,
        preamble: carbidePreamble, toolChange: carbideToolChange,
        spindleDwellSeconds: 3, minRPM: 0, maxRPM: 30000, arcOutput: .incrementalIJ, arcTolerance: 0.01,
        footer: m2Footer,
        limits: MachineLimits(xTravel: 623, yTravel: 623, zTravel: 155, maxSpoilboardCut: 1.0),
        rapidRate: 8000, maxFeed: 8000)

    public static let all: [PostProfile] = [avidMach4Inch, avidMach4MM, genericGRBLMM,
                                            genericGRBLInch, linuxCNCInch, linuxCNCMM, othermillInch, othermillMM,
                                            onefinityBBInch, onefinityBBMM, carbideMotionInch, carbideMotionMM]

    /// Built-in posts whose controller reads `G4 P` in seconds and has no usable Optional Stop: the Othermill (TinyG treats M1
    /// as M0), Buildbotics (it resumes an "Optional pause" at once; the control that arms it is hidden) and Carbide Motion
    /// (its M1 "Sleep" is undocumented). Judged by id, so an edited copy keeping the id keeps the rules: an optional stop
    /// writes M0, and a dwell may not be in milliseconds. The GRBL posts are judged apart (#115: by value or a declared
    /// controller) for the optional stop, and by id too for the dwell (`grblIDs`).
    public static let secondsNoOptionalStopIDs: Set<String> = [othermillInch.id, othermillMM.id, onefinityBBInch.id,
                                                               onefinityBBMM.id, carbideMotionInch.id, carbideMotionMM.id]
    public static let grblIDs: Set<String> = [genericGRBLMM.id, genericGRBLInch.id]
    /// Built-in posts whose controller has no coolant: the Othermill and Carbide Motion (which ignores M7 and lacks M8).
    public static let noCoolantIDs: Set<String> = [othermillInch.id, othermillMM.id, carbideMotionInch.id, carbideMotionMM.id]

    public static func profile(id: String) -> PostProfile? { all.first { $0.id == id } }

    /// The controller a post speaks: a built-in post compared by value (not by id: a user file or a project copy can carry a
    /// built-in's id with other text) gives its own; any other post gives the controller its owner declared (nil = none).
    public static func probeController(for raw: PostProfile) -> ToolChangeProbe.Controller? {
        if let builtIn = profile(id: raw.id), builtIn == raw {
            switch raw.id {
            case avidMach4Inch.id, avidMach4MM.id: return .mach4
            case genericGRBLMM.id, genericGRBLInch.id: return .grbl
            default: break
            }
        }
        return raw.controller
    }
}
