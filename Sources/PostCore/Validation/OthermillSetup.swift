import CADCore
import CAMCore
import Foundation

/// What the Bantam Tools software (Othermill, #114; spec docs/specs/2026-10-28-othermill-post-design.md) assumes of a program:
/// file X0 Y0 Z0 at the stock's front-left top, a machine no bigger than the Othermill. The posts are recognised
/// by id, which a project's copy keeps, so a later change to the built-in's text cannot switch these checks off for saved
/// projects. Errors keep Save Anyway: the Z-zero convention is the vendor's documented default, not confirmed for imported
/// G-code, and an owner who set the software's offsets differently must still be able to post.
public enum OthermillSetup {
    public static let postIDs: Set<String> = [BuiltInPosts.othermillInch.id, BuiltInPosts.othermillMM.id]

    public static let zEnvelopeWarningPrefix = "The stock plus the highest Z"
    public static let limitsWarningPrefix = "The travel, feed and speed checks used"
    /// The warnings a program that is otherwise fine can carry (the samples check accepts these for the Othermill posts).
    public static let warningPrefixes = [zEnvelopeWarningPrefix, limitsWarningPrefix]

    /// The spindle range both Othermill machines span.
    static let rpmRange = 7000.0...26000.0

    /// - Parameters:
    ///   - job: the side being exported (a two-sided job's bottom has its own Z zero).
    ///   - units: the document's units; `job` and every move are in them.
    ///   - moves: every commanded move, in machine coordinates: the toolpaths after lift-overs, and the move home.
    ///   - toolpaths: the program's toolpaths (coolant is `DialectChecks`').
    ///   - profile: the post as it is posted (a machine's numbers applied).
    ///   - approachHeight: the raised approach height above the material top after a tool change, when a clamp needs one.
    public static func issues(job: JobSetup, units: LengthUnit, moves: [Toolpath], toolpaths: [Toolpath], profile: PostProfile,
                              approachHeight: Double?) -> [GCodeIssue] {
        guard let family = BuiltInPosts.family(of: profile.id), postIDs.contains(family),
              let builtIn = BuiltInPosts.profile(id: family) else { return [] }
        let eps = units == .inch ? 0.0005 : 0.01
        let u = units.abbreviation
        func f(_ v: Double) -> String { NumberFormat.compact(v, maxDecimals: units == .inch ? 4 : 2) }
        var out: [GCodeIssue] = []
        func error(_ s: String) { out.append(GCodeIssue(severity: .error, message: s)) }
        func warning(_ s: String) { out.append(GCodeIssue(severity: .warning, message: s)) }

        if job.zZero != .materialTop {
            error("The Othermill's software puts the file's Z0 at the top of the stock: set Z zero to the material top in Job Setup.")
        }
        if job.xyOrigin != .lowerLeft {
            error("The Othermill's software puts the file's X0 Y0 at the stock's front-left corner: set the XY origin to the "
                  + "lower left in Job Setup.")
        }
        if let d = job.datumOffset, d != .zero {
            error("The Othermill's software puts the file's X0 Y0 at the stock's front-left corner: remove the datum offset "
                  + "(\(f(d.x)), \(f(d.y)) \(u)) in Job Setup.")
        }

        let toMoves = profile.units.factor(to: units)
        let limits = profile.limits
        let (xTravel, yTravel, zTravel) = (limits.xTravel * toMoves, limits.yTravel * toMoves, limits.zTravel * toMoves)
        let extent = extents(moves)
        if let e = extent {
            if e.maxX > xTravel + eps {
                error("A move reaches X\(f(e.maxX)) \(u), beyond the X travel \(f(xTravel)) \(u) measured from the stock's "
                      + "front-left corner.")
            }
            if e.maxY > yTravel + eps {
                error("A move reaches Y\(f(e.maxY)) \(u), beyond the Y travel \(f(yTravel)) \(u) measured from the stock's "
                      + "front-left corner.")
            }
        }

        let coords = MachineCoordinates(job: job)
        let above = max(job.safeZ, job.homeZ, approachHeight ?? 0, (extent?.maxZ).map { $0 - coords.materialTopZ } ?? 0)
        if job.thickness + above > zTravel + eps {
            warning("\(zEnvelopeWarningPrefix) the program asks for (\(f(job.thickness)) + \(f(above)) = "
                    + "\(f(job.thickness + above)) \(u)) is more than the Z travel \(f(zTravel)) \(u): lower Home Z and Safe Z in "
                    + "Job Setup, and check clamp heights.")
        }

        let toBuiltIn = builtIn.units.factor(to: profile.units)
        let postEps = eps * units.factor(to: profile.units)   // lengths, and feeds per minute, in the post's units
        let own = builtIn.limits
        let bigger = limits.xTravel > own.xTravel * toBuiltIn + postEps || limits.yTravel > own.yTravel * toBuiltIn + postEps
            || limits.zTravel > own.zTravel * toBuiltIn + postEps
            || profile.maxFeed > builtIn.maxFeed * toBuiltIn + postEps || profile.rapidRate > builtIn.rapidRate * toBuiltIn + postEps
            || profile.minRPM < rpmRange.lowerBound || profile.maxRPM > rpmRange.upperBound
        if bigger {
            let pu = profile.units.abbreviation
            func g(_ v: Double) -> String { NumberFormat.compact(v, maxDecimals: profile.units == .inch ? 4 : 2) }
            warning("\(limitsWarningPrefix) limits larger than the Othermill's (X \(g(limits.xTravel)), Y \(g(limits.yTravel)), "
                    + "Z \(g(limits.zTravel)) \(pu); feed \(g(profile.maxFeed)), rapid \(g(profile.rapidRate)) \(pu)/min; "
                    + "\(g(profile.minRPM))–\(g(profile.maxRPM)) rpm): choose the Othermill machine in Job Setup.")
        }
        return out
    }

    /// The largest X, Y and Z any move reaches, arcs by their points.
    static func extents(_ toolpaths: [Toolpath]) -> (maxX: Double, maxY: Double, maxZ: Double)? {
        var maxX = -Double.infinity, maxY = -Double.infinity, maxZ = -Double.infinity
        func see(_ p: Vec3) { maxX = max(maxX, p.x); maxY = max(maxY, p.y); maxZ = max(maxZ, p.z) }
        for tp in toolpaths {
            var at: Vec3?
            for m in tp.moves {
                switch m {
                case .rapid(let p), .linear(let p, _):
                    see(p); at = p
                case .arcCW(let p, let c, _), .arcCCW(let p, let c, _):
                    let cw: Bool = { if case .arcCW = m { return true } else { return false } }()
                    if let a = at {
                        for q in ArcGeometry.points(from: a, to: p, center: c, clockwise: cw, tolerance: 1e-4) { see(q) }
                    }
                    see(p); at = p
                case .dwell:
                    break
                }
            }
        }
        return maxX.isFinite ? (maxX, maxY, maxZ) : nil
    }
}
