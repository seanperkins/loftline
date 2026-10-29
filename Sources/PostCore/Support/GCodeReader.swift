import CADCore
import CAMCore
import Foundation

/// Turns a G-code program back into moves for previewing it (toolpaths-2d round 2: "import
/// toolpaths from another job" as G-code). It reads what routers usually emit: G0/G1/G2/G3
/// with I/J (incremental or G90.1 absolute) or R arcs in the XY plane, G20/G21, G90/G91,
/// G4 dwells, F/S words, T…M6 tool changes and G81/G82/G83 drilling cycles (G98/G99). Anything
/// it cannot follow is reported, never guessed silently.
public enum GCodeReader {
    public struct Segment: Sendable {
        /// Tool number (T word) in force, nil before the first tool change.
        public var toolNumber: Int?
        /// Tool name from a comment on the tool-change block, when there is one.
        public var toolComment: String?
        public var spindleRPM: Double
        /// Moves in the program's coordinates converted to `units`.
        public var moves: [Move]
    }

    public struct Result: Sendable {
        public var segments: [Segment]
        public var warnings: [String]
        /// Units the program declared (nil if it never said).
        public var programUnits: LengthUnit?
        public var moveCount: Int { segments.reduce(0) { $0 + $1.moves.count } }
    }

    /// - Parameters:
    ///   - units: units for the returned moves (the program's G20/G21 are converted).
    ///   - assumedUnits: units used until the program states G20/G21.
    ///   - startZ: Z assumed before the program first sets Z (e.g. the job's safe Z).
    ///   - absoluteArcCentres: default arc-centre mode before any G90.1/G91.1 (Mach4 keeps this
    ///     as a controller setting; incremental is the common default).
    public static func read(_ text: String, units: LengthUnit, assumedUnits: LengthUnit? = nil,
                            startZ: Double, absoluteArcCentres: Bool = false) -> Result {
        let parsed = GCodeParser.parse(text, comments: .standard)
        let comments = toolComments(text)
        var warnings: [String] = []
        func warn(_ line: Int, _ s: String) { if warnings.count < 200 { warnings.append("Line \(line): \(s)") } }
        for g in parsed.garbage.prefix(20) { warn(g.line, "unrecognised text '\(g.text)'") }
        for line in parsed.blockDeleteLines.prefix(20) {
            warn(line, "starts with '/' (block delete): shown as if Block Delete were off, which is when the controller runs it")
        }

        var progUnits: LengthUnit?
        var f: Double { (progUnits ?? assumedUnits ?? units).factor(to: units) }
        var absolute = true
        var absArcs = absoluteArcCentres
        var motion: Int? // 0,1,2,3 or 81,82,83
        var plane = 17
        var retractToR = true // G99 (default) / G98
        var pos: Vec3?        // in output units
        var known = (x: false, y: false, z: false)
        var feed = 0.0
        var rpm = 0.0
        var pendingTool: Int?
        var segments: [Segment] = [Segment(toolNumber: nil, toolComment: nil, spindleRPM: 0, moves: [])]
        var cycleR: Double?
        var cycleZ: Double?
        var cycleQ: Double?

        func emit(_ m: Move) { segments[segments.count - 1].moves.append(m) }
        // A program with no M6 changes tools with a T word alone (the park-and-probe sequence); one with M6 may name the
        // next tool early (pre-staging), so there only M6 starts a segment.
        let changesAtM6 = parsed.blocks.contains { $0.has("M", 6) }
        var currentTool: Int?
        /// Set by a probe until the zero that follows it (G10 L20, or the Mach4 zero macro's P).
        var probed = false
        var warnedUnitsWords = false

        for b in parsed.blocks {
            var nonModal = false
            if probed, let p = b.value("P"), b.values("M").contains(where: { $0 >= 100 }) {
                // The Mach4 zero macro: the plate's top is Z = P from here on.
                pos = Vec3(pos?.x ?? 0, pos?.y ?? 0, p * f)
                known.z = true
                probed = false
            }
            for g in b.values("G") {
                switch g {
                case 20: progUnits = .inch
                case 21: progUnits = .millimeter
                case 90: absolute = true
                case 91: absolute = false
                case 90.1: absArcs = true
                case 91.1: absArcs = false
                case 17: plane = 17
                case 18, 19:
                    plane = Int(g)
                    warn(b.line, "G\(Int(g)) arcs (not in the XY plane) are shown as straight lines")
                case 0, 1, 2, 3, 81, 82, 83: motion = Int(g)
                case 80: motion = nil
                case 98: retractToR = false
                case 99: retractToR = true
                case 4:
                    nonModal = true
                    if let x = b.value("X") {
                        emit(.dwell(seconds: x))   // Syntec's G4 X: seconds as written, never a length
                    } else {
                        let p = b.value("P") ?? 0
                        emit(.dwell(seconds: p > 100 ? p / 1000 : p)) // Mach treats P as seconds; >100 is likely ms
                    }
                case 70, 71:
                    if !warnedUnitsWords {
                        warnedUnitsWords = true
                        warn(b.line, "G70/G71 set inches/millimetres on a Syntec controller; not applied here, units assumed "
                             + "\((progUnits ?? assumedUnits ?? units).abbreviation)")
                    }
                case 31, 38.2:
                    // A probe stops where it touches: not drawn, and the zero that follows sets Z.
                    nonModal = true
                    probed = true
                case 53:
                    nonModal = true   // a machine-coordinate move: the work position after it is not known
                case 10 where b.value("L") == 20 && b.value("Z") != nil:
                    nonModal = true
                    pos = Vec3(pos?.x ?? 0, pos?.y ?? 0, (b.value("Z") ?? 0) * f)
                    known.z = true
                    probed = false
                case 28, 30, 10, 92:
                    nonModal = true
                    warn(b.line, "G\(NumberFormat.compact(g, maxDecimals: 1)) is not previewed (machine/offset move)")
                default: break
                }
            }
            if let s = b.value("S") { rpm = s; segments[segments.count - 1].spindleRPM = max(segments[segments.count - 1].spindleRPM, s) }
            if let fw = b.value("F") { feed = fw * f }
            if let t = b.value("T") { pendingTool = Int(exactly: t.rounded()) }
            if !changesAtM6, let t = b.value("T").flatMap({ Int(exactly: $0.rounded()) }), t != currentTool {
                segments.append(Segment(toolNumber: t, toolComment: comments[b.line], spindleRPM: rpm, moves: []))
                currentTool = t
            } else if b.has("M", 6) {
                let t = pendingTool
                segments.append(Segment(toolNumber: t, toolComment: comments[b.line], spindleRPM: rpm, moves: []))
                // Tool changes leave the position unknown in Z on many machines; keep XY.
            } else if b.has("M", 3) || b.has("M", 4), rpm > 0 {
                segments[segments.count - 1].spindleRPM = rpm
            }
            if nonModal { continue }
            let bx = b.value("X"), by = b.value("Y"), bz = b.value("Z")
            guard bx != nil || by != nil || bz != nil else { continue }
            guard let m = motion else {
                warn(b.line, "axis words without G0/G1/G2/G3; skipped")
                continue
            }
            let cur = pos ?? Vec3(0, 0, startZ)
            func axis(_ v: Double?, _ c: Double, _ isKnown: Bool) -> Double {
                guard let v else { return c }
                return absolute || !isKnown ? v * f : c + v * f
            }
            if m >= 81 {
                // Drilling cycle at (X, Y): rapid over, rapid to R, feed to Z (pecks shown as one
                // feed), back to R (G99) or the start height (G98).
                if let r = b.value("R") { cycleR = absolute ? r * f : cur.z + r * f }
                if let z = bz { cycleZ = absolute ? z * f : (cycleR ?? cur.z) + z * f }
                if let q = b.value("Q") { cycleQ = q * f }
                guard let rz = cycleR, let dz = cycleZ else { warn(b.line, "drilling cycle without R or Z; skipped"); continue }
                let x = axis(bx, cur.x, known.x), y = axis(by, cur.y, known.y)
                let top = max(cur.z, rz)
                emit(.rapid(to: Vec3(x, y, top)))
                emit(.rapid(to: Vec3(x, y, rz)))
                if m == 83, let q = cycleQ, q > 0 {
                    // At most 10 000 pecks per hole: a bad Q must not hang the preview.
                    let q = max(q, (rz - dz) / 10_000)
                    var depth = rz
                    while depth > dz + 1e-9 {
                        depth = max(dz, depth - q)
                        emit(.linear(to: Vec3(x, y, depth), feed: max(feed, 1e-6)))
                        if depth > dz + 1e-9 { emit(.rapid(to: Vec3(x, y, rz))); emit(.rapid(to: Vec3(x, y, depth))) }
                    }
                } else {
                    emit(.linear(to: Vec3(x, y, dz), feed: max(feed, 1e-6)))
                    if m == 82, let p = b.value("P"), p > 0 { emit(.dwell(seconds: p > 100 ? p / 1000 : p)) }
                }
                let back = Vec3(x, y, retractToR ? rz : top)
                emit(.rapid(to: back))
                pos = back
                known = (true, true, true)
                continue
            }
            let target = Vec3(axis(bx, cur.x, known.x), axis(by, cur.y, known.y), axis(bz, cur.z, known.z))
            switch m {
            case 0:
                emit(.rapid(to: target))
            case 1:
                emit(.linear(to: target, feed: max(feed, 1e-6)))
            default:
                if plane != 17 || pos == nil {
                    emit(.linear(to: target, feed: max(feed, 1e-6)))
                } else if let r = b.value("R") {
                    if let c = rArcCentre(from: cur.xy, to: target.xy, radius: r * f, clockwise: m == 2) {
                        emit(m == 2 ? .arcCW(to: target, center: c, feed: max(feed, 1e-6))
                                    : .arcCCW(to: target, center: c, feed: max(feed, 1e-6)))
                    } else {
                        warn(b.line, "R arc cannot reach its end point; shown as a line")
                        emit(.linear(to: target, feed: max(feed, 1e-6)))
                    }
                } else {
                    let i = b.value("I").map { $0 * f }, j = b.value("J").map { $0 * f }
                    let c = absArcs ? Vec2(i ?? cur.x, j ?? cur.y) : Vec2(cur.x + (i ?? 0), cur.y + (j ?? 0))
                    if abs(cur.xy.distance(to: c) - target.xy.distance(to: c)) > max(1e-3 * f, 0.002 * cur.xy.distance(to: c)) {
                        warn(b.line, "arc start and end radii differ (check the arc-centre mode G90.1/G91.1)")
                    }
                    emit(m == 2 ? .arcCW(to: target, center: c, feed: max(feed, 1e-6))
                                : .arcCCW(to: target, center: c, feed: max(feed, 1e-6)))
                }
            }
            if bx != nil { known.x = true }
            if by != nil { known.y = true }
            if bz != nil { known.z = true }
            pos = target
        }
        if progUnits == nil {
            warnings.insert("The program never sets G20/G21; assumed \((assumedUnits ?? units).abbreviation).", at: 0)
        }
        return Result(segments: segments.filter { !$0.moves.isEmpty }, warnings: warnings, programUnits: progUnits)
    }

    /// Centre of an R-format arc: |R| is the radius; R > 0 takes the short way (≤ 180°), R < 0
    /// the long way. Nil when the chord is longer than the diameter (beyond rounding).
    static func rArcCentre(from a: Vec2, to b: Vec2, radius r: Double, clockwise: Bool) -> Vec2? {
        let chord = b - a
        let c = chord.length
        let rr = abs(r)
        guard c > 1e-12, c <= 2 * rr * (1 + 1e-6) else { return nil }
        let h = max(rr * rr - c * c / 4, 0).squareRoot()
        let mid = a + chord * 0.5
        let left = Vec2(-chord.y, chord.x) * (1 / c)
        // A short clockwise arc bulges to the left of the chord, so its centre is on the right.
        let sign: Double = (clockwise ? -1 : 1) * (r >= 0 ? 1 : -1)
        return mid + left * (h * sign)
    }

    public typealias HeaderTool = (name: String, kind: ToolKind, diameter: Double)

    /// Tools listed in a header comment like "T1: 1/4in End Mill - End Mill, dia 0.2500 in"
    /// (LoftLine's own posts write this): number → name, kind and diameter in `units`.
    public static func headerTools(_ text: String, units: LengthUnit) -> [Int: HeaderTool] {
        var out: [Int: HeaderTool] = [:]
        let pattern = "T([0-9]+):[ ]*(.+?)[ ]+-[ ]+([A-Za-z -]+?),[ ]*dia[ ]+([0-9.]+)[ ]*(in|mm)"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return out }
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }).prefix(400) {
            let s = String(line)
            guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges == 6 else { continue }
            func group(_ k: Int) -> String? { Range(m.range(at: k), in: s).map { String(s[$0]) } }
            guard let n = group(1).flatMap({ Int($0) }), let name = group(2), let kindText = group(3),
                  let d = group(4).flatMap({ Double($0) }), let u = group(5) else { continue }
            let kind = ToolKind.allCases.first { $0.displayName.lowercased() == kindText.lowercased() } ?? .endMill
            let from: LengthUnit = u == "mm" ? .millimeter : .inch
            out[n] = (name, kind, d * from.factor(to: units))
        }
        return out
    }

    /// Text of the first comment on each line that has an M6 (the tool's name in most posts).
    static func toolComments(_ text: String) -> [Int: String] {
        var out: [Int: String] = [:]
        var lineNo = 0
        var lastComment: String?
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            lineNo += 1
            let s = String(raw)
            var comment: String?
            if let o = s.firstIndex(of: "("), let c = s[o...].firstIndex(of: ")") {
                comment = String(s[s.index(after: o)..<c]).trimmingCharacters(in: .whitespaces)
            } else if let semi = s.firstIndex(of: ";") {
                comment = String(s[s.index(after: semi)...]).trimmingCharacters(in: .whitespaces)
            }
            let code = s.uppercased().replacingOccurrences(of: " ", with: "")
            if code.range(of: #"M0?6(?![0-9])"#, options: .regularExpression) != nil {
                out[lineNo] = comment ?? lastComment
            }
            if let c = comment, !c.isEmpty { lastComment = c }
        }
        return out
    }
}
