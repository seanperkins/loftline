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

    /// MASSO, UCCNC and Centroid run on many machines: these posts carry a generic 48 x 48 x 6 in envelope (the LinuxCNC
    /// posts'), which a machine replaces.
    static let genericInchLimits = MachineLimits(xTravel: 48, yTravel: 48, zTravel: 6, maxSpoilboardCut: 0.05)
    static let genericMMLimits = MachineLimits(xTravel: 1219.2, yTravel: 1219.2, zTravel: 152.4, maxSpoilboardCut: 1.27)

    /// MASSO G3 (#107): one word per preamble line (MASSO ignores a whole line with an invalid word), no G49 (it has no
    /// G43/G49), M5 before `T M6` with T first, `S M3`, dwell in milliseconds ("Dwell time in milliseconds"; read as seconds it
    /// is only a long wait), incremental I/J ("always incremental on MASSO").
    static let massoPreamble = ["G90", "G17", "G40", "G80", "G94"]
    static let massoToolChange = ["M5", "(Change to Tool: {TOOL_NAME})", "T{T} M6"]

    public static let massoG3Inch = PostProfile(
        id: "masso-g3-inch", name: "MASSO G3 (inch)", version: "1.0",
        fileExtension: "nc", units: .inch, decimals: 4, feedDecimals: 1,
        preamble: massoPreamble, toolChange: massoToolChange, spindleOn: "S{S} M3",
        spindleDwellSeconds: 3, dwell: "G4 P{MILLISECONDS}", minRPM: 0, maxRPM: 24000,
        arcOutput: .incrementalIJ, arcTolerance: 0.0005, footer: othermillFooter,
        limits: genericInchLimits, rapidRate: 200, maxFeed: 200)

    public static let massoG3MM = PostProfile(
        id: "masso-g3-mm", name: "MASSO G3 (mm)", version: "1.0",
        fileExtension: "nc", units: .millimeter, decimals: 3, feedDecimals: 1,
        preamble: massoPreamble, toolChange: massoToolChange, spindleOn: "S{S} M3",
        spindleDwellSeconds: 3, dwell: "G4 P{MILLISECONDS}", minRPM: 0, maxRPM: 24000,
        arcOutput: .incrementalIJ, arcTolerance: 0.01, footer: othermillFooter,
        limits: genericMMLimits, rapidRate: 5080, maxFeed: 5080)

    /// UCCNC (#108): arcs as lines (the manual does not say whether I/J are incremental), M0 for a tool change (UCCNC can be
    /// set to ignore M6), dwell in milliseconds (its default). Units come from the UCCNC profile: export warns.
    static let uccncPreamble = ["G90", "G17", "G40", "G49", "G80", "G94"]
    static let uccncToolChange = ["M5", "(Change to Tool: {TOOL_NAME})", "M0"]

    public static let uccncInch = PostProfile(
        id: "uccnc-inch", name: "UCCNC (inch)", version: "1.0",
        fileExtension: "nc", units: .inch, decimals: 4, feedDecimals: 1,
        preamble: uccncPreamble, toolChange: uccncToolChange,
        spindleDwellSeconds: 3, dwell: "G4 P{MILLISECONDS}", minRPM: 0, maxRPM: 24000,
        arcOutput: .linearize, arcTolerance: 0.0005, footer: othermillFooter,
        limits: genericInchLimits, rapidRate: 200, maxFeed: 200)

    public static let uccncMM = PostProfile(
        id: "uccnc-mm", name: "UCCNC (mm)", version: "1.0",
        fileExtension: "nc", units: .millimeter, decimals: 3, feedDecimals: 0,
        preamble: uccncPreamble, toolChange: uccncToolChange,
        spindleDwellSeconds: 3, dwell: "G4 P{MILLISECONDS}", minRPM: 0, maxRPM: 24000,
        arcOutput: .linearize, arcTolerance: 0.01, footer: othermillFooter,
        limits: genericMMLimits, rapidRate: 5080, maxFeed: 5080)

    /// Centroid Acorn / CNC12 (#103): `;` comments (parentheses are not documented as comments), arcs as lines (Parameter 2
    /// bit 0 decides whether I/J are absolute), `T M6` (it lifts Z and prompts; without G43 the length is not applied, so
    /// export warns on a second tool), `S M3`, dwell in seconds (the documented default; Parameter 2 bit 2 flips it).
    public static let centroidInch = PostProfile(
        id: "centroid-inch", name: "Centroid CNC12 (inch)", version: "1.0",
        fileExtension: "nc", units: .inch, commentStyle: .semicolon, decimals: 4, feedDecimals: 1,
        preamble: uccncPreamble, toolChange: carbideToolChange, spindleOn: "S{S} M3",
        spindleDwellSeconds: 3, minRPM: 0, maxRPM: 24000,
        arcOutput: .linearize, arcTolerance: 0.0005, footer: othermillFooter,
        limits: genericInchLimits, rapidRate: 200, maxFeed: 200)

    public static let centroidMM = PostProfile(
        id: "centroid-mm", name: "Centroid CNC12 (mm)", version: "1.0",
        fileExtension: "nc", units: .millimeter, commentStyle: .semicolon, decimals: 3, feedDecimals: 0,
        preamble: uccncPreamble, toolChange: carbideToolChange, spindleOn: "S{S} M3",
        spindleDwellSeconds: 3, minRPM: 0, maxRPM: 24000,
        arcOutput: .linearize, arcTolerance: 0.01, footer: othermillFooter,
        limits: genericMMLimits, rapidRate: 5080, maxFeed: 5080)

    /// ShopBot in G-code mode (#106; ShopBot User Guide SBG 00142): every line numbered (a line that does not start with N, G,
    /// M, X, Y, Z, F or > is commented out), `G90` alone (no G17, G40, G49, G80, G94 or G91.1 on its list), one G word per line
    /// (it runs only the first), `M3` alone (a switch: the router sets its speed), `G4 P` in seconds, M0 for a tool change, no
    /// helical arcs (its G02 has no Z). Inch only: the feed unit under G21 is unknown.
    public static let shopbotGCodeInch = PostProfile(
        id: "shopbot-gcode-inch", name: "ShopBot G-code (inch)", version: "1.0",
        fileExtension: "tap", units: .inch, lineNumbers: true, decimals: 4, feedDecimals: 1,
        preamble: ["G90"], toolChange: uccncToolChange, spindleOn: "M3",
        spindleDwellSeconds: 3, minRPM: 0, maxRPM: 24000,
        arcOutput: .incrementalIJ, arcTolerance: 0.0005, helicalArcs: false, footer: othermillFooter,
        limits: genericInchLimits, rapidRate: 360, maxFeed: 240)

    /// Syntec (#110; Mill Machine Program Manual v8.20): `%` and an O number first (Autodesk's post), G70/G71 for units, `G4 X`
    /// in seconds with a dot (a whole P or X is the machine's smallest time unit), `T M6` with `G43 H` moving to the approach
    /// height.
    static let fanucPreamble = ["G17", "G40", "G49", "G80", "G90", "G94", "G54"]
    static let fanucToolLength = "G0 G43 Z{APPROACH_Z} H{T}"
    static let fanucFooter = othermillFooter + ["%"]

    public static let syntecInch: PostProfile = {
        var p = PostProfile(
            id: "syntec-inch", name: "Syntec (inch)", version: "1.0",
            fileExtension: "nc", units: .inch, decimals: 4, feedDecimals: 1,
            preamble: fanucPreamble, toolChange: massoToolChange, useToolLengthOffset: true, toolLengthOffset: fanucToolLength,
            spindleDwellSeconds: 3, dwell: "G4 X{DECIMAL_SECONDS}", minRPM: 0, maxRPM: 24000,
            arcOutput: .incrementalIJ, arcTolerance: 0.0005, footer: fanucFooter,
            limits: genericInchLimits, rapidRate: 1500, maxFeed: 1500)
        p.prelude = ["%", "O1000"]
        p.unitsCodes = .g70g71
        return p
    }()

    public static let syntecMM: PostProfile = {
        var p = PostProfile(
            id: "syntec-mm", name: "Syntec (mm)", version: "1.0",
            fileExtension: "nc", units: .millimeter, decimals: 3, feedDecimals: 1,
            preamble: fanucPreamble, toolChange: massoToolChange, useToolLengthOffset: true, toolLengthOffset: fanucToolLength,
            spindleDwellSeconds: 3, dwell: "G4 X{DECIMAL_SECONDS}", minRPM: 0, maxRPM: 24000,
            arcOutput: .incrementalIJ, arcTolerance: 0.01, footer: fanucFooter,
            limits: genericMMLimits, rapidRate: 38100, maxFeed: 38100)
        p.prelude = ["%", "O1000"]
        p.unitsCodes = .g70g71
        return p
    }()

    /// Haas (#111; Haas's G04 and M06 pages, by search-result text, and Autodesk's Haas post): `%` and a five-digit O number
    /// first, `G4 P` in milliseconds (a P with no dot), `T M6` (it stops the spindle and moves Z itself) with `G43 H` moving to
    /// the approach height.
    public static let haasInch: PostProfile = {
        var p = PostProfile(
            id: "haas-inch", name: "Haas (inch)", version: "1.0",
            fileExtension: "nc", units: .inch, decimals: 4, feedDecimals: 1,
            preamble: fanucPreamble, toolChange: massoToolChange, useToolLengthOffset: true, toolLengthOffset: fanucToolLength,
            spindleDwellSeconds: 3, dwell: "G4 P{MILLISECONDS}", minRPM: 0, maxRPM: 24000,
            arcOutput: .incrementalIJ, arcTolerance: 0.0005, footer: fanucFooter,
            limits: genericInchLimits, rapidRate: 710, maxFeed: 650)
        p.prelude = ["%", "O01000"]
        return p
    }()

    public static let haasMM: PostProfile = {
        var p = PostProfile(
            id: "haas-mm", name: "Haas (mm)", version: "1.0",
            fileExtension: "nc", units: .millimeter, decimals: 3, feedDecimals: 1,
            preamble: fanucPreamble, toolChange: massoToolChange, useToolLengthOffset: true, toolLengthOffset: fanucToolLength,
            spindleDwellSeconds: 3, dwell: "G4 P{MILLISECONDS}", minRPM: 0, maxRPM: 24000,
            arcOutput: .incrementalIJ, arcTolerance: 0.01, footer: fanucFooter,
            limits: genericMMLimits, rapidRate: 18034, maxFeed: 16510)
        p.prelude = ["%", "O01000"]
        return p
    }()

    public static let all: [PostProfile] = [avidMach4Inch, avidMach4MM, genericGRBLMM,
                                            genericGRBLInch, linuxCNCInch, linuxCNCMM, othermillInch, othermillMM,
                                            onefinityBBInch, onefinityBBMM, carbideMotionInch, carbideMotionMM,
                                            massoG3Inch, massoG3MM, uccncInch, uccncMM, centroidInch, centroidMM,
                                            shopbotGCodeInch, syntecInch, syntecMM, haasInch, haasMM]

    /// The built-in a post belongs to: its own id when that is a built-in's, or the built-in a duplicate was made from
    /// (Duplicate names a copy `<built-in id>-custom-<n>`, `PostProfileStore.newID`), so a copy keeps its controller's rules.
    public static func family(of id: String) -> String? {
        if profile(id: id) != nil { return id }
        guard let r = id.range(of: #"-custom-[0-9]+$"#, options: .regularExpression) else { return nil }
        let base = String(id[..<r.lowerBound])
        return profile(id: base) != nil ? base : nil
    }

    /// The built-in families whose controller stops at M1 only with its Optional Stop switch on (Mach4, LinuxCNC). Every other
    /// built-in family writes M0 for an optional stop: GRBL ignores M1, TinyG treats it as M0, Buildbotics resumes it at once,
    /// and Carbide Motion, MASSO, UCCNC and Centroid document no switch. A built-in added later defaults to M0.
    public static let optionalStopIDs: Set<String> = [avidMach4Inch.id, avidMach4MM.id, linuxCNCInch.id, linuxCNCMM.id]
    /// Built-in families whose M6 changes the tool without applying its length (MASSO has no G43; Centroid's needs G43 H):
    /// a second tool resumes at the old Z, so `ToolChangeZ` does not count their M6.
    public static let toolChangeKeepsZIDs: Set<String> = [massoG3Inch.id, massoG3MM.id, centroidInch.id, centroidMM.id]
    /// Built-in families whose M3 is a switch with no speed (ShopBot, #106): their spindle line is M3 alone, and the speed
    /// warning every export gives is expected (the post editor's sample allows it).
    public static let noSpindleSpeedIDs: Set<String> = [shopbotGCodeInch.id]
    /// Built-in families whose controller runs only the first G word on a line (ShopBot): the probe sequence's multi-G lines
    /// cannot be written for them, so probing refuses.
    public static let oneGWordIDs: Set<String> = [shopbotGCodeInch.id]
    /// Built-in families whose tool length line must move to `Z{APPROACH_Z}` (Syntec, Haas): it runs at the tool change's
    /// unknown X Y, before the climb to the approach height (`PostProfile.postProblem`).
    public static let approachToolLengthIDs: Set<String> = [syntecInch.id, syntecMM.id, haasInch.id, haasMM.id]
    /// Built-in families where T0 selects no tool and G43 H0 applies no length (Syntec, Haas).
    public static let noToolZeroIDs: Set<String> = [syntecInch.id, syntecMM.id, haasInch.id, haasMM.id]
    /// Built-in families whose controller has no G43 (MASSO), so a Tool Length Offset line is skipped, never applied.
    public static let noToolLengthOffsetIDs: Set<String> = [massoG3Inch.id, massoG3MM.id]
    /// Built-in families whose controller has no coolant, with the reason export gives.
    public static let noCoolantReasons: [String: String] = {
        let othermill = "The Othermill has no coolant, and its G-code reference lists M7, M8 and M9 as unsupported"
        let carbide = "Carbide Motion ignores M7 and does not support M8"
        let shopbot = "ShopBot's G-code has no M7, and M8 turns on output switch 3, which may be wired to anything"
        return [othermillInch.id: othermill, othermillMM.id: othermill, carbideMotionInch.id: carbide, carbideMotionMM.id: carbide,
                shopbotGCodeInch.id: shopbot]
    }()

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
