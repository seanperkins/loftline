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
        let fromZones = (doc.keepOutZones ?? []).filter(\.isUsable)
            .map { ClampItem(name: $0.name, loops: [$0.outline], height: max(0, $0.height), layerID: nil) }
        var items = fromLayers + fromZones
        // Several sharing a name are numbered in list order; a name used once stays as it is. A number is never one that would
        // repeat a name already in use ("Clamps 1" typed by the user), and a name that ends in a number gets it in brackets
        // ("Clamp 1 (2)", when Clamps and Fixture Holes has been run twice).
        let counts = Dictionary(items.map { ($0.name, 1) }, uniquingKeysWith: +)
        var taken = Set(counts.filter { $0.value == 1 }.keys)
        var next: [String: Int] = [:]
        for i in items.indices where counts[items[i].name, default: 0] > 1 {
            let name = items[i].name
            let bracketed = name.last?.isNumber == true
            var n = next[name, default: 1], candidate: String
            repeat {
                candidate = bracketed ? "\(name) (\(n))" : "\(name) \(n)"
                n += 1
            } while taken.contains(candidate)
            next[name] = n
            taken.insert(candidate)
            items[i].name = candidate
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

/// Remembers the clamp list until a keep-out changes, so a view redrawn on every mouse move doesn't flatten the zones each time.
public struct ClampListCache {
    private struct Key: Equatable {
        var layers: [Layer]
        var shapes: [Shape]
        var zones: [KeepOutZone]?
    }

    /// How many times the list was built (for tests).
    public private(set) var builds = 0
    private var key: Key?
    private var cached: [ClampItem] = []

    public init() {}

    public mutating func items(in doc: Document) -> [ClampItem] {
        let ids = Fixtures.keepOutLayerIDs(in: doc)
        let k = Key(layers: doc.layers.filter { ids.contains($0.id) }, shapes: doc.shapes.filter { ids.contains($0.layerID) },
                    zones: doc.keepOutZones)
        if k != key {
            key = k
            cached = ClampList.items(in: doc)
            builds += 1
        }
        return cached
    }
}
