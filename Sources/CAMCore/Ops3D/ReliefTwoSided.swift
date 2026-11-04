import CADCore
import Foundation

/// Two-sided relief machining. The second side is planned in the frame of the flipped board:
/// its material frame is the first side's mirrored about the board's centre line (X for a
/// left-right flip, Y for top-bottom), and depths are measured from the old bottom face
/// (`thickness - depth`). Each side's surface is clamped at the split plane, so the top side
/// stops at `split` and the bottom side `web` short of it.
enum ReliefTwoSided {
    /// Split depth (first-side frame) for the settings and the primary model.
    static func splitDepth(_ s: ReliefSplit, model: PlacedModel) -> Double {
        s.splitDepth ?? (model.zTop + model.depth) / 2
    }

    /// Depth limit of this side's surface, in this side's frame.
    static func clampDepth(_ s: ReliefSplit, side: TwoSidedSettings.Side, split: Double, thickness: Double) -> Double {
        side == .top ? split : thickness - split - max(0, s.web)
    }

    /// Mirrors a first-side material point into the flipped board's frame.
    static func mirror(_ p: Vec2, flip: FlipAxis, job: JobSetup) -> Vec2 {
        flip == .leftRight ? Vec2(job.width - p.x, p.y) : Vec2(p.x, job.height - p.y)
    }

    /// The model as seen from the bottom of the flipped board: mesh mirrored in XY and Z, placed
    /// so the same material maps to the mirrored position, with its top/bottom depths measured
    /// from the old bottom face.
    static func flipped(_ m: PlacedModel, flip: FlipAxis, job: JobSetup) -> PlacedModel {
        var out = m
        out.mesh.vertices = m.mesh.vertices.map { v in
            flip == .leftRight ? Vec3(-v.x, v.y, -v.z) : Vec3(v.x, -v.y, -v.z)
        }
        out.offset = flip == .leftRight ? Vec2(job.width - m.offset.x, m.offset.y) : Vec2(m.offset.x, job.height - m.offset.y)
        out.zTop = job.thickness - m.depth
        out.depth = job.thickness - m.zTop
        return out
    }

    /// Clamps every cell (and the base plane) at `limit`.
    static func clamp(_ map: inout ReliefHeightmap, at limit: Double) {
        for k in map.depths.indices where map.depths[k] > limit { map.depths[k] = limit }
        map.baseDepth = min(map.baseDepth, limit)
    }
}
