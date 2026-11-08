import CADCore
import Foundation

/// One clamp, screw or other keep-out, named the way the job sheet, the canvas and the 3D preview show it.
public struct ClampItem: Equatable, Sendable {
    public var name: String
    /// Closed loops, even-odd, document units, material frame.
    public var loops: [[Vec2]]
    /// How far its top stands above the material top (0 = flush).
    public var height: Double
    /// The keep-out layer the shape is on; nil for a zone from Toolpaths > Keep-Out Zones.
    public var layerID: UUID?

    public var bounds: Rect2 { Rect2(points: loops.joined()) }
}

/// Every keep-out the export checks: closed shapes on keep-out layers, hidden layers included (`Fixtures.zones`), then the zones from
/// Toolpaths > Keep-Out Zones. Names the operator can tell apart, and positions they can measure (issue #134).
public enum ClampList {
    public static func items(in doc: Document) -> [ClampItem] {
        let fromLayers = Fixtures.zones(in: doc).map { ClampItem(name: $0.name, loops: $0.loops, height: $0.height, layerID: $0.layerID) }
        let fromZones = (doc.keepOutZones ?? []).filter { $0.outline.count > 2 }
            .map { ClampItem(name: $0.name, loops: [$0.outline], height: max(0, $0.height), layerID: nil) }
        var items = fromLayers + fromZones
        // Several sharing a name are numbered in list order; a name used once stays as it is.
        let counts = Dictionary(items.map { ($0.name, 1) }, uniquingKeysWith: +)
        var seen: [String: Int] = [:]
        for i in items.indices where counts[items[i].name, default: 0] > 1 {
            let name = items[i].name
            seen[name, default: 0] += 1
            items[i].name = "\(name) \(seen[name]!)"
        }
        return items
    }

    /// Where the item is, measured from the material's edges (what the operator can measure, whatever the XY origin). A clamp over
    /// exactly one edge is worded from that edge: "left edge, centre 12 in from the bottom, reaches 1 in onto the material". Any
    /// other zone is given as ranges from the left and bottom edges.
    public static func position(of item: ClampItem, job: JobSetup, units: LengthUnit) -> String {
        let b = item.bounds, w = job.width, h = job.height
        let eps = max(w, h) * 1e-9
        func f(_ v: Double) -> String { JobSheet.fmt(v, units) }
        let onMaterial = b.max.x > eps && b.min.x < w - eps && b.max.y > eps && b.min.y < h - eps
        let left = b.min.x <= eps, right = b.max.x >= w - eps, bottom = b.min.y <= eps, top = b.max.y >= h - eps
        if onMaterial, [left, right, bottom, top].filter({ $0 }).count == 1 {
            if left { return "left edge, centre \(f(b.center.y)) from the bottom, reaches \(f(b.max.x)) onto the material" }
            if right { return "right edge, centre \(f(b.center.y)) from the bottom, reaches \(f(w - b.min.x)) onto the material" }
            if bottom { return "bottom edge, centre \(f(b.center.x)) from the left, reaches \(f(b.max.y)) onto the material" }
            return "top edge, centre \(f(b.center.x)) from the left, reaches \(f(h - b.min.y)) onto the material"
        }
        let ranges = "\(f(b.min.x)) to \(f(b.max.x)) from the left edge, \(f(b.min.y)) to \(f(b.max.y)) from the bottom edge"
        return onMaterial ? ranges : "off the material, " + ranges
    }

    public static func heightText(of item: ClampItem, units: LengthUnit) -> String {
        item.height > 0 ? "\(JobSheet.fmt(item.height, units)) above the material" : "flush with the top"
    }
}
