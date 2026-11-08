// Click-to-measure on the simulated stock. Owned by preview.
import CADCore
import CAMCore
import Foundation
import LoftLineKit

/// One or two picked points on the carved stock, in the material frame
/// (x, y from the stock's lower-left corner; z = -depth below the material top).
struct PreviewMeasurement: Equatable {
    var points: [Vec3] = []

    var isEmpty: Bool { points.isEmpty }

    /// Adds a pick; a third pick starts a new measurement.
    mutating func add(_ p: Vec3) {
        if points.count >= 2 { points = [] }
        points.append(p)
    }

    mutating func clear() { points = [] }

    var distance: Double? { points.count == 2 ? points[0].distance(to: points[1]) : nil }
    var planarDistance: Double? { points.count == 2 ? points[0].xy.distance(to: points[1].xy) : nil }
    /// Second point's depth minus the first's (positive = deeper).
    var depthChange: Double? { points.count == 2 ? (-points[1].z) - (-points[0].z) : nil }

    /// Readout lines in document `units`.
    func lines(units: LengthUnit, thickness: Double) -> [String] {
        let u = units.abbreviation
        let dec = units == .inch ? 3 : 2
        func f(_ v: Double) -> String { String(format: "%.\(dec)f", abs(v) < 0.5 * pow(10, -Double(dec)) ? 0 : v) }
        func point(_ name: String, _ p: Vec3) -> String {
            let depth = -p.z
            return "\(name): X \(f(p.x))  Y \(f(p.y))  depth \(f(depth)) \(u)  (\(f(thickness - depth)) \(u) left)"
        }
        guard let a = points.first else { return ["Click the stock to measure a depth; click again for a distance."] }
        var out = [point("A", a)]
        if points.count == 2, let d = distance, let xy = planarDistance, let dz = depthChange {
            out.append(point("B", points[1]))
            out.append("Distance \(f(d)) \(u)  ·  XY \(f(xy)) \(u)  ·  ΔDepth \(f(dz)) \(u)")
        }
        return out
    }

    /// Depth at `p` from the simulated heightfield (more exact than the decimated mesh).
    static func refined(_ p: Vec3, heightfield hf: Heightfield) -> Vec3 {
        guard hf.cell(containing: p.xy) != nil else { return p }
        return Vec3(p.x, p.y, -Double(hf.depth(at: p.xy)))
    }
}
