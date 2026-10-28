import CADCore
import CAMCore
import Foundation

/// Line-level G-code writer: formatting, optional line numbers, modal suppression and the
/// safe-Z retract rule for rapids. All coordinates are already in output units.
struct GCodeWriter {
    let profile: PostProfile
    /// Machine Z of the rapid clearance plane.
    let safeZ: Double

    private(set) var lines: [String] = []
    private var lineNumber = 0
    private var x: Double?
    private var y: Double?
    private var z: Double?
    private var lastMotion: String?
    private var lastFeed: String?

    init(profile: PostProfile, safeZ: Double) {
        self.profile = profile
        self.safeZ = safeZ
    }

    var currentZ: Double? { z }

    // MARK: Raw lines

    mutating func comment(_ text: String) { lines.append(profile.comment(text)) }

    /// Emits a code line (numbered when the profile asks for it). Template lines that are
    /// pure comments are passed through unnumbered.
    mutating func code(_ text: String) {
        // Any non-motion line (spindle, dwell, template) makes the next motion restate its G-word.
        lastMotion = nil
        append(text)
    }

    /// A line written as it is, never numbered: the post's program wrapper (`prelude`), which a controller reads before any
    /// numbered block.
    mutating func raw(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { lines.append(trimmed) }
    }

    private mutating func append(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // A `%` is the tape's end marker, never a numbered block.
        if trimmed.hasPrefix("(") || trimmed.hasPrefix(";") || trimmed == "%" || !profile.lineNumbers {
            lines.append(trimmed)
        } else {
            lineNumber += 10
            lines.append("N\(lineNumber) \(trimmed)")
        }
    }

    /// Forget modal state (after a tool change the controller may have moved and the feed
    /// should be restated).
    mutating func resetModalState(keepPosition: Bool = false) {
        lastMotion = nil
        lastFeed = nil
        if !keepPosition { x = nil; y = nil; z = nil }
    }

    // MARK: Motion

    func fmt(_ v: Double) -> String { NumberFormat.fixed(v, decimals: profile.decimals) }

    private func same(_ a: Double?, _ b: Double) -> Bool { a.map { fmt($0) == fmt(b) } ?? false }

    /// Unconditional Z retract (used after tool changes) — always emitted.
    mutating func forceRapidZ(_ target: Double) {
        lastMotion = nil
        emit(motion: profile.rapid, x: nil, y: nil, z: target, feed: nil, extra: [], forceAxes: true)
    }

    /// Rapid with the safety rule: never move XY below safe Z.
    mutating func rapid(to p: Vec3) {
        let xyChanged = !same(x, p.x) || !same(y, p.y)
        guard xyChanged else {
            emit(motion: profile.rapid, x: nil, y: nil, z: p.z, feed: nil, extra: [])
            return
        }
        if z.map({ $0 < safeZ - 1e-9 }) ?? true, !same(z, max(safeZ, p.z)) {
            emit(motion: profile.rapid, x: nil, y: nil, z: max(safeZ, p.z), feed: nil, extra: [])
        }
        if p.z < safeZ - 1e-9 {
            emit(motion: profile.rapid, x: p.x, y: p.y, z: nil, feed: nil, extra: [])
            emit(motion: profile.rapid, x: nil, y: nil, z: p.z, feed: nil, extra: [])
        } else {
            emit(motion: profile.rapid, x: p.x, y: p.y, z: p.z, feed: nil, extra: [])
        }
    }

    /// A rapid that always names both X and Y and never Z (the touch-off spot: the writer's position is unknown after a
    /// machine-coordinate move, and the bit must cross at the height it is at).
    mutating func rapidXY(_ p: Vec2) {
        lastMotion = nil
        emit(motion: profile.rapid, x: p.x, y: p.y, z: nil, feed: nil, extra: [], forceXY: true)
    }

    mutating func retract(to height: Double) {
        if z.map({ $0 < height - 1e-9 }) ?? true { rapidZ(height) }
    }

    private mutating func rapidZ(_ h: Double) {
        emit(motion: profile.rapid, x: nil, y: nil, z: h, feed: nil, extra: [])
    }

    mutating func linear(to p: Vec3, feed: Double) {
        emit(motion: profile.linear, x: p.x, y: p.y, z: p.z, feed: feed, extra: [])
    }

    mutating func arc(to p: Vec3, center: Vec2, clockwise: Bool, feed: Double) {
        guard let sx = x, let sy = y, let sz = z else {
            linear(to: p, feed: feed)   // unknown start: cannot express an arc safely
            return
        }
        let start = Vec3(sx, sy, sz)
        let radius = start.xy.distance(to: center)
        // Rounding to the output precision can make a tiny arc's end coincide with (or fall just
        // behind) its start, which a controller executes as a full circle at cut depth. Below
        // two output digits of arc length a straight move is exact enough.
        let sweep = ArcGeometry.sweep(from: start.xy, to: p.xy, center: center, clockwise: clockwise)
        let resolution = pow(10, -Double(profile.decimals))
        if abs(sweep) * radius < 2 * resolution {   // a true full circle has length 2*pi*r
            linear(to: p, feed: feed)
            return
        }
        let isHelix = !same(sz, p.z)
        let mustLinearize = profile.arcOutput == .linearize || (isHelix && !profile.helicalArcs)
            || radius < max(1e-6, pow(10, -Double(profile.decimals)))
        if mustLinearize {
            let tol = profile.arcTolerance > 0 ? profile.arcTolerance : pow(10, -Double(profile.decimals))
            for q in ArcGeometry.points(from: start, to: p, center: center, clockwise: clockwise, tolerance: tol) {
                linear(to: q, feed: feed)
            }
            return
        }
        let (i, j) = profile.arcOutput == .absoluteIJ
            ? (center.x, center.y)
            : (center.x - sx, center.y - sy)
        let code = clockwise ? profile.arcCW : profile.arcCCW
        lastMotion = nil   // arcs always state their G-word
        emit(motion: code, x: p.x, y: p.y, z: p.z, feed: feed,
             extra: ["I" + fmt(i), "J" + fmt(j)], forceXY: true)
    }

    mutating func dwell(seconds: Double) {
        guard profile.writesDwell(seconds: seconds) else { return }
        code(TemplateRenderer(values: profile.dwellValues(seconds: seconds)).render(profile.dwell))
    }

    // MARK: Word assembly

    private mutating func emit(motion: String, x nx: Double?, y ny: Double?, z nz: Double?, feed: Double?,
                               extra: [String], forceXY: Bool = false, forceAxes: Bool = false) {
        var words: [String] = []
        let modal = profile.modal && !forceAxes
        if let v = nx, forceXY || !modal || !same(x, v) { words.append("X" + fmt(v)) }
        if let v = ny, forceXY || !modal || !same(y, v) { words.append("Y" + fmt(v)) }
        if let v = nz, !modal || !same(z, v) { words.append("Z" + fmt(v)) }
        words += extra
        guard !words.isEmpty else { return }
        if let f = feed {
            let fs = NumberFormat.fixed(f, decimals: profile.feedDecimals)
            if !profile.modal || fs != lastFeed { words.append("F" + fs); lastFeed = fs }
        }
        let showCode = !profile.modal || motion != lastMotion
        lastMotion = motion
        append(((showCode ? [motion] : []) + words).joined(separator: " "))
        if let v = nx { x = v }
        if let v = ny { y = v }
        if let v = nz { z = v }
    }
}
