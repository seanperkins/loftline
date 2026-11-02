import CADCore
import CAMCore
import Foundation

/// The footer's travel after the last toolpath, walked from the footer as the post renders it (#132), so the export's
/// keep-out and clamp checks see the moves the machine makes, in their order, a G28/G30 intermediate move included.
/// The walk is an allowlist: a block it does not know stops it, and `unmodelledFrom` names that line.
public struct FooterTravel: Sendable, Equatable {
    /// Machine frame, job units: the builder's retract, then each modelled move. Empty when the footer makes no
    /// modelled move.
    public var points: [Vec3]
    /// The footer line the walk stopped at, when it stopped before the footer's end (or its M2/M30): the machine's
    /// moves from that line on are not modelled.
    public var unmodelledFrom: String?
    /// Indices into `points` reached by a feed move (G1): checked where they go, and never routed over lift-over zones,
    /// which would turn them into rapids.
    public var feedLegs: Set<Int>

    public init(points: [Vec3], unmodelledFrom: String?, feedLegs: Set<Int> = []) {
        self.points = points; self.unmodelledFrom = unmodelledFrom; self.feedLegs = feedLegs
    }

    static let letters: Set<Character> = ["G", "M", "N", "F", "S", "T", "P", "X", "Y", "Z"]
    /// G codes that do not move the machine or change what a coordinate means (the post's units code is added).
    static let quietG: Set<Double> = [4, 17, 40, 80, 90.1, 91.1, 94]
    static let walkedG: Set<Double> = [0, 1, 28, 30, 90, 91]
    static let quietM: Set<Double> = [2, 3, 4, 5, 7, 8, 9, 30]

    /// `end` is the last toolpath's last point (machine frame, `job.units`).
    public static func model(profile: PostProfile, job: PostJob, from end: Vec3) -> FooterTravel {
        let lines = ProgramBuilder(profile: profile, job: job).renderedFooter()
        let f = job.units.factor(to: profile.units)
        let coords = MachineCoordinates(job: job.job.scaled(by: f))
        let eps = 1e-6
        let start = Vec3(end.x * f, end.y * f, end.z * f)
        // The builder's retract to safe Z is a G0 when it is written; otherwise the last move's mode is in force.
        let retracts = start.z < coords.safeZ - 1e-9
        var mode: Double? = retracts ? 0 : {
            switch job.toolpaths.last?.moves.last(where: { $0.target != nil }) {
            case .rapid?: return 0
            case .linear?: return 1
            default: return nil
            }
        }()
        let parsed = GCodeParser.parse(lines.joined(separator: "\n"), comments: profile.parserComments)
        let unitsG = Set(GCodeParser.parse(profile.unitsCode, comments: profile.parserComments).blocks.flatMap { $0.values("G") })
        let stopLines = Set(parsed.garbage.map(\.line)).union(parsed.blockDeleteLines)
        let blocks = Dictionary(parsed.blocks.map { ($0.line, $0) }, uniquingKeysWith: { a, _ in a })

        var pos = Vec3(start.xy, z: max(start.z, coords.safeZ))
        var moves: [Vec3] = []
        var feeds: Set<Int> = []
        var absolute = true
        var stoppedAt: String?
        func move(_ b: GCodeBlock) {
            func axis(_ v: Double?, _ cur: Double) -> Double { v.map { absolute ? $0 : cur + $0 } ?? cur }
            let p = Vec3(axis(b.value("X"), pos.x), axis(b.value("Y"), pos.y), axis(b.value("Z"), pos.z))
            if p.distance(to: pos) > eps {
                moves.append(p)
                if mode == 1 { feeds.insert(moves.count) }   // index in `points`, after the retract point
            }
            pos = p
        }
        walk: for n in lines.indices.map({ $0 + 1 }) {
            let text = lines[n - 1].trimmingCharacters(in: .whitespaces)
            if stopLines.contains(n) { stoppedAt = text; break }
            guard let b = blocks[n] else { continue }
            let gs = b.values("G"), ms = b.values("M")
            guard b.words.allSatisfy({ Self.letters.contains($0.letter) }),
                  gs.allSatisfy({ Self.walkedG.contains($0) || Self.quietG.contains($0) || unitsG.contains($0) }),
                  ms.allSatisfy({ Self.quietM.contains($0) }) else { stoppedAt = text; break }
            // A dwell's X or P is its time (Syntec writes `G4 X`), not an axis.
            if gs.contains(4) {
                if gs.contains(where: { [0, 1, 28, 30].contains($0) }) { stoppedAt = text; break }
                continue
            }
            if gs.contains(90) { absolute = true }
            if gs.contains(91) { absolute = false }
            if gs.contains(0) && gs.contains(1) { stoppedAt = text; break }
            if gs.contains(0) { mode = 0 }
            if gs.contains(1) { mode = 1 }
            let axes = b.value("X") != nil || b.value("Y") != nil || b.value("Z") != nil
            if gs.contains(28) || gs.contains(30) {
                // The intermediate move, then the stored position LoftLine cannot see.
                if axes, !gs.contains(0), !gs.contains(1) { let m = mode; mode = 0; move(b); mode = m }
                stoppedAt = text
                break walk
            }
            if axes {
                guard mode == 0 || mode == 1 else { stoppedAt = text; break }
                move(b)
            }
            if ms.contains(2) || ms.contains(30) { break }
        }
        let back = 1 / f
        let points = moves.isEmpty ? [] : ([Vec3(start.xy, z: max(start.z, coords.safeZ))] + moves).map {
            Vec3($0.x * back, $0.y * back, $0.z * back)
        }
        return FooterTravel(points: points, unmodelledFrom: stoppedAt, feedLegs: moves.isEmpty ? [] : feeds)
    }
}
