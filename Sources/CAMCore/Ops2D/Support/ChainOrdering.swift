import CADCore
import Foundation

/// Greedy nearest-neighbour ordering of chains to shorten rapids.
public enum ChainOrdering {
    /// Orders `chains` starting from `start`. Closed loops are rotated to start at the point
    /// nearest the current position; open chains may be reversed when `allowReverse`.
    /// `predecessors[i]` lists chains that must be cut before chain i (e.g. inner loops before
    /// the loop that contains them).
    public static func nearestNeighbour(_ chains: [Chain2D], from start: Vec2, allowReverse: Bool = true,
                                        predecessors: [Set<Int>]? = nil, tolerance: Double = 1e-6) -> [Chain2D] {
        var remaining = Set(chains.indices)
        var done = Set<Int>()
        var out: [Chain2D] = []
        var cur = start
        while !remaining.isEmpty {
            var best: (i: Int, d: Double, reverse: Bool)?
            // An exact tie (a regular hole grid) goes to the earlier chain, so the order is the same on every run:
            // a Set iterates in the process's hash order.
            func better(_ i: Int, _ d: Double) -> Bool { best == nil || d < best!.d || (d == best!.d && i < best!.i) }
            for i in remaining {
                if let pre = predecessors?[i], !pre.isSubset(of: done) { continue }
                let c = chains[i]
                if c.isClosed {
                    let d = Polygon2D.distance(from: cur, toLoop: c.points)
                    if better(i, d) { best = (i, d, false) }
                } else {
                    let ds = c.start.distance(to: cur)
                    let de = allowReverse ? c.end.distance(to: cur) : .infinity
                    let d = min(ds, de)
                    if better(i, d) { best = (i, d, de < ds) }
                }
            }
            // A precedence cycle should never happen; fall back to any remaining chain.
            let pick = best ?? (remaining.min()!, 0, false)
            remaining.remove(pick.i)
            done.insert(pick.i)
            var c = chains[pick.i]
            if c.isClosed {
                c.points = Polygon2D.rotatedLoop(c.points, nearestTo: cur, tolerance: tolerance)
            } else if pick.reverse {
                c = c.reversed()
            }
            out.append(c)
            cur = c.end
        }
        return out
    }

    /// Precedence for profiles: a loop must be cut after every loop it contains.
    public static func innerFirstPredecessors(_ chains: [Chain2D]) -> [Set<Int>] {
        let areas = chains.map { abs(Polygon2D.signedArea($0.points)) }
        return chains.indices.map { j in
            guard chains[j].isClosed else { return [] }
            var s = Set<Int>()
            for i in chains.indices where i != j && areas[i] < areas[j] {
                if let p = chains[i].points.first, Polygon2D.contains(chains[j].points, p) { s.insert(i) }
            }
            return s
        }
    }
}
