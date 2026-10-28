import CADCore
import CAMCore
import Foundation

public struct GCodeIssue: Hashable, Sendable, CustomStringConvertible {
    public enum Severity: String, Hashable, Sendable { case warning, error }
    public var severity: Severity
    /// 1-based line number in the G-code, when applicable.
    public var line: Int?
    public var message: String

    public init(severity: Severity, line: Int? = nil, message: String) {
        self.severity = severity; self.line = line; self.message = message
    }

    public var description: String {
        "\(severity.rawValue)\(line.map { " line \($0)" } ?? ""): \(message)"
    }
}

/// Safety checks on toolpaths / generated G-code: travel extents, cut depth vs. material
/// bottom + spoilboard allowance, XY rapids below safe Z / inside the material, cutting with
/// the spindle off, missing feed, RPM range.
///
/// `job` is in `units` (the document's units). G-code is checked in the units it declares
/// (G20/G21, defaulting to the profile's units).
public struct GCodeValidator: Sendable {
    public var profile: PostProfile
    public var job: JobSetup
    public var units: LengthUnit

    public init(profile: PostProfile, job: JobSetup, units: LengthUnit) {
        self.profile = profile; self.job = job; self.units = units
    }

    /// Issues sorted errors first.
    public static func errors(in issues: [GCodeIssue]) -> [GCodeIssue] { issues.filter { $0.severity == .error } }

    // MARK: Toolpaths

    public func validate(toolpaths: [Toolpath]) -> [GCodeIssue] {
        var check = MotionChecker(profile: profile, job: job, jobUnits: units, units: units)
        var pos: Vec3?
        var previous: Toolpath?
        // Two different tools with one T number post as one tool: the controller sees no change
        // and the second geometry cuts with the first bit in the spindle.
        var byNumber: [Int: [Tool]] = [:]
        for tp in toolpaths where !byNumber[tp.tool.number, default: []].contains(where: { $0.id == tp.tool.id }) {
            byNumber[tp.tool.number, default: []].append(tp.tool)
        }
        for (number, tools) in byNumber where tools.count > 1 {
            let sameGeometry = tools.allSatisfy { $0.hasSameGeometry(as: tools[0]) }
            check.issues.add("tool-number-\(number)", sameGeometry ? .warning : .error, line: nil,
                             "T\(number) is used by \(tools.count) different tools (\(tools.map(\.name).joined(separator: ", ")))"
                                 + (sameGeometry ? "" : " with different geometry; give each tool its own number"))
        }
        for tp in toolpaths {
            if tp.moves.isEmpty {
                check.issues.add("empty-\(tp.id)", .warning, line: nil, "Toolpath '\(tp.name)' has no moves")
                continue
            }
            check.rpm(tp.spindleRPM, min: profile.minRPM, max: profile.maxRPM, line: nil)
            // Deeper than the flutes: the shank rubs the wall. An error, which the export sheets make
            // the operator accept explicitly, so a hand-edited tool or a depth typed past the flute
            // length does not reach the machine unnoticed.
            if let over = tp.cutBeyondFlute(coords: check.coords, units: units, tolerance: check.eps) {
                check.issues.add("flute-\(tp.id)", .error, line: nil, "Toolpath '\(tp.name)' \(over.description)")
            }
            // Where the post writes a tool change or an operator stop, either of which can change the bit
            // (the same stops the time estimate counts).
            if let previous, ToolpathStats.stopsBefore(tp, after: previous) { check.leaveHole() }
            previous = tp
            for move in tp.moves {
                switch move {
                case .dwell(let seconds):
                    // Posts as G4, which is not a plain move in the G-code check; the writer drops a
                    // dwell of no length, so it does not forget the hole here either.
                    if seconds > 0 { check.leaveHole() }
                    continue
                case .rapid(let p):
                    // The post retracts before a toolpath's first rapid, so an unknown start is fine.
                    if let s = pos {
                        check.rapid(from: s, to: p, xyMove: s.xy.distance(to: p.xy) > check.eps, line: nil)
                    } else {
                        check.visit(p, line: nil)
                    }
                case .linear(let p, let feed):
                    check.feedMove(from: pos, path: [p], feed: feed, spindleOn: true, line: nil, startKnown: true)
                case .arcCW(let p, let c, let feed), .arcCCW(let p, let c, let feed):
                    let path = pos.map {
                        ArcGeometry.points(from: $0, to: p, center: c, clockwise: isCW(move), tolerance: check.eps)
                    } ?? [p]
                    check.feedMove(from: pos, path: path, feed: feed, spindleOn: true, line: nil, startKnown: true)
                }
                pos = move.target ?? pos
            }
        }
        check.finish()
        let parts = Set(toolpaths.filter { $0.kind == .inlay }.compactMap { $0.metadata["part"] })
        if parts.contains("female") && parts.contains("male") {
            check.issues.add("inlay-mixed-parts", .error, line: nil,
                             "Inlay pocket (female) and plug (male) are in the same program. The plug is cut in place "
                                 + "over the pocket, so cut each part on its own board and export them separately.")
        }
        let reliefSides = Set(toolpaths.filter { $0.kind == .relief3D }.compactMap { $0.metadata["side"] })
        if reliefSides.count > 1 {
            check.issues.add("relief-mixed-sides", .error, line: nil,
                             "Two-sided 3D relief: the top and bottom sides are in the same program. The bottom side "
                                 + "is cut after turning the board over, so export each side as its own file.")
        }
        return check.issues.issues
    }

    private func isCW(_ m: Move) -> Bool { if case .arcCW = m { return true } else { return false } }

    // MARK: G-code

    public func validate(gcode: String) -> [GCodeIssue] {
        let parsed = GCodeParser.parse(gcode)
        var gUnits: LengthUnit?
        var check = MotionChecker(profile: profile, job: job, jobUnits: units, units: profile.units)
        var carried = IssueCollector()
        for g in parsed.garbage {
            carried.add("garbage", .warning, line: g.line, "Unrecognised text '\(g.text)'")
        }
        var absolute = true
        var sawAbsolute = false
        var motion: Int?
        var x: Double?, y: Double?, z: Double?
        var feed: Double?
        var spindleOn = false
        var sawSpeed = false
        var sawEnd = false
        var probeCheck: ProbeSequenceChecker?
        if case .on(let p)? = profile.toolChangeProbe {
            probeCheck = ProbeSequenceChecker(probe: p, profile: profile, job: job, jobUnits: units)
        }
        /// After a probe the motion mode is unknown (GRBL's G38.2 is modal): the next axis block must name one.
        var needMotionWord = false

        var index = 0
        while index < parsed.blocks.count {
            let b = parsed.blocks[index]
            index += 1
            if var pc = probeCheck {
                let effect = pc.step(b, next: parsed.blocks[index...], spindleOn: spindleOn, motion: motion, issues: &carried)
                probeCheck = pc
                if effect.consumed > 0 {
                    index += effect.consumed - 1
                    check.leaveHole()
                    if effect.positionUnknown { x = nil; y = nil; z = nil }
                    if let p = effect.xy { x = p.x; y = p.y }
                    if let v = effect.z { z = v }
                    if effect.afterProbe { motion = nil; absolute = true; needMotionWord = true }
                    continue
                }
            }
            if needMotionWord, b.value("X") != nil || b.value("Y") != nil || b.value("Z") != nil {
                if !b.values("G").contains(where: { Self.motionG.contains($0) }) {
                    carried.add("probe-no-motion", .error, line: b.line,
                                "Axis words after a probe with no motion mode: the controller may still be probing")
                }
                needMotionWord = false
            }
            var nonMotion = false
            if sawEnd, b.value("X") != nil || b.value("Y") != nil || b.value("Z") != nil {
                carried.add("after-end", .warning, line: b.line, "Motion after the program end (M30/M2)")
            }
            for g in b.values("G") {
                if !Self.knownG.contains(g) {
                    carried.add("unknown-g", .warning, line: b.line,
                                "G\(NumberFormat.compact(g, maxDecimals: 1)) is not a code this validator knows")
                }
                switch g {
                case 20, 21:
                    let u: LengthUnit = g == 20 ? .inch : .millimeter
                    if u != profile.units {
                        carried.add("units-mismatch", .warning, line: b.line,
                                    "Program units \(u.abbreviation) differ from the profile's \(profile.units.abbreviation)")
                    }
                    if u != (gUnits ?? profile.units) {
                        // Restart the checker in the new units, keeping what it found so far.
                        let old = check.issues
                        let f = (gUnits ?? profile.units).factor(to: u)
                        x = x.map { $0 * f }; y = y.map { $0 * f }; z = z.map { $0 * f }
                        feed = feed.map { $0 * f }
                        check = MotionChecker(profile: profile, job: job, jobUnits: units, units: u)
                        check.issues = old
                    }
                    gUnits = u
                case 90: absolute = true; sawAbsolute = true
                case 91:
                    absolute = false
                    carried.add("incremental", .warning, line: b.line, "Incremental positioning (G91) in program")
                case _ where Self.motionG.contains(g): motion = Int(g)
                case 4, 28, 30: nonMotion = true
                case 31, 38.2:
                    // A probe: it stops where the probe touches, so its target is not a position.
                    nonMotion = true
                    motion = nil
                case 92.1 where probeCheck != nil:
                    break   // the probed tool change clears any G92 offset before the spot (spec §4 step 1)
                case 10, 53, 92, 92.1, 92.2:
                    // The controller now interprets every later coordinate in a frame this
                    // validator cannot see, so the depth checks below say nothing about it.
                    nonMotion = true
                    carried.add("coordinate-shift", .warning, line: b.line,
                                "G\(NumberFormat.compact(g, maxDecimals: 1)) changes the coordinate system; depth checks no longer apply")
                default: break
                }
            }
            var stop: Int?
            // The remembered hole survives only plain moves: a block of nothing but motion-mode, axis,
            // arc, feed and line-number words. Any other G code may have moved the tool or changed what
            // the coordinates mean, a stop, M6 or T word may mean the bit changed, and a letter this
            // validator does not model is not vouched for. One rule that fails closed (an unlisted word
            // costs a warning, never a missed one), applied before the block's motion, because a frame
            // change or tool word applies to it, and again after, because a controller moves before it
            // stops.
            let plainMove = b.words.allSatisfy { Self.plainMoveLetters.contains($0.letter) }
                && b.values("G").allSatisfy { Self.motionG.contains($0) }
            if !plainMove { check.leaveHole() }
            defer { if !plainMove { check.leaveHole() } }
            for m in b.values("M") {
                if !Self.knownM.contains(m) {
                    carried.add("unknown-m", .warning, line: b.line,
                                "M\(NumberFormat.compact(m, maxDecimals: 0)) is not a code this validator knows")
                }
                switch m {
                case 3, 4: spindleOn = true
                case 5: spindleOn = false
                case 0, 1: stop = Int(m)
                case 6:
                    if spindleOn {
                        carried.add("toolchange-spindle-on", .warning, line: b.line,
                                    "Tool change (M6) with the spindle running; stop it (M5) first")
                    }
                case 2, 30:
                    sawEnd = true
                    if spindleOn {
                        carried.add("end-spindle-on", .warning, line: b.line,
                                    "Program ends with the spindle running (no M5 before M30/M2)")
                    }
                default: break
                }
            }
            if let s = b.value("S") { sawSpeed = sawSpeed || s > 0 }
            if (b.has("M", 3) || b.has("M", 4)), !sawSpeed, b.value("S") == nil {
                carried.add("spindle-no-speed", .warning, line: b.line, "Spindle started (M3/M4) with no speed (S) set")
            }
            if let s = b.value("S"), s > 0 || b.has("M", 3) || b.has("M", 4) {
                check.rpm(s, min: profile.minRPM, max: profile.maxRPM, line: b.line)
            }
            if let f = b.value("F") { feed = f }

            let bx = b.value("X"), by = b.value("Y"), bz = b.value("Z")
            if !nonMotion, bx != nil || by != nil || bz != nil {
                if let m = motion {
                    if !sawAbsolute, absolute {
                        sawAbsolute = true   // report once
                        carried.add("no-absolute", .warning, line: b.line,
                                    "Motion before G90: the controller's last distance mode (possibly G91) applies")
                    }
                    func resolve(_ v: Double?, _ cur: Double?) -> Double? {
                        guard let v else { return cur }
                        return absolute ? v : (cur ?? 0) + v
                    }
                    let tx = resolve(bx, x), ty = resolve(by, y), tz = resolve(bz, z)
                    let xyKnown = x != nil && y != nil
                    let start: Vec3? = z.map { Vec3(x ?? tx ?? 0, y ?? ty ?? 0, $0) }
                    let target = Vec3(tx ?? 0, ty ?? 0, tz ?? z ?? check.safeZ)

                    switch m {
                    case 0:
                        let xyMove = (bx != nil || by != nil)
                            && (!xyKnown || Vec2(x ?? 0, y ?? 0).distance(to: target.xy) > check.eps)
                        check.rapid(from: start, to: target, xyMove: xyMove, line: b.line)
                    case 1:
                        check.feedMove(from: start, path: [target], feed: feed, spindleOn: spindleOn, line: b.line,
                                       startKnown: xyKnown)
                    default:
                        var path = [target]
                        if let s = start, xyKnown {
                            let i = b.value("I"), j = b.value("J")
                            if i == nil && j == nil {
                                if b.value("R") == nil {
                                    check.issues.add("arc-no-centre", .error, line: b.line, "Arc without I/J or R")
                                }
                            } else {
                                let c = profile.arcOutput == .absoluteIJ
                                    ? Vec2(i ?? s.x, j ?? s.y)
                                    : Vec2(s.x + (i ?? 0), s.y + (j ?? 0))
                                let r0 = s.xy.distance(to: c), r1 = target.xy.distance(to: c)
                                if abs(r0 - r1) > check.eps * 2 {
                                    check.issues.add("arc-radius", .error, line: b.line,
                                                     "Arc start/end radii differ (\(NumberFormat.compact(r0, maxDecimals: 4)) vs \(NumberFormat.compact(r1, maxDecimals: 4)))")
                                }
                                path = ArcGeometry.points(from: s, to: target, center: c, clockwise: m == 2,
                                                          tolerance: check.eps)
                            }
                        }
                        check.feedMove(from: start, path: path, feed: feed, spindleOn: spindleOn, line: b.line,
                                       startKnown: xyKnown)
                    }
                    x = tx ?? x; y = ty ?? y; z = tz ?? z
                } else {
                    carried.add("no-motion-mode", .warning, line: b.line, "Axis words without a motion mode (G0/G1/G2/G3)")
                }
            }

            // A controller runs a block's spindle word and its motion before it stops, whatever the
            // word order (LinuxCNC's order of execution; Mach follows it), so the stop is judged on
            // the state at the end of the block. An unknown Z (nothing moved yet) is not a problem;
            // a custom post's pause template might be.
            if let stop {
                if spindleOn {
                    carried.add("stop-spindle-on", .warning, line: b.line,
                                "Program stops (M\(stop)) with the spindle running")
                }
                if let z, z < check.safeZ - check.eps {
                    carried.add("stop-below-safe-z", .warning, line: b.line,
                                "Program stops (M\(stop)) with the tool below safe Z")
                }
            }
        }
        check.finish()

        if gUnits == nil {
            carried.add("no-units", .warning, line: nil, "Program never sets units (G20/G21)")
        }
        if !sawEnd {
            carried.add("no-end", .warning, line: nil, "Program does not end with M30/M2")
        }
        var all = check.issues
        all.merge(carried)
        return all.issues
    }

    /// G-codes the checker understands or knowingly ignores. Anything else is reported, because
    /// a word the validator does not model is a word it cannot vouch for.
    static let knownG: Set<Double> = [0, 1, 2, 3, 4, 10, 17, 18, 19, 20, 21, 28, 30, 31, 38.2, 40, 41, 42, 43, 49, 53, 54, 55, 56,
                                      57, 58, 59, 61, 64, 80, 81, 82, 83, 90, 90.1, 91, 91.1, 92, 92.1, 92.2, 93, 94, 98, 99]
    static let knownM: Set<Double> = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 30]
    /// The motion modes: the only G words a block may carry and still be a plain move.
    static let motionG: Set<Double> = [0, 1, 2, 3]
    /// The word letters a plain move is made of: G, axes, arc centre and radius, feed, line number.
    static let plainMoveLetters: Set<Character> = ["G", "X", "Y", "Z", "I", "J", "K", "R", "F", "N"]
}
