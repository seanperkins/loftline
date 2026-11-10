import CADCore
import Foundation

/// One clamp, screw or other keep-out, named the way the job sheet, the canvas and the 3D preview show it.
public struct ClampItem: Equatable, Sendable {
    public var name: String
    /// Closed loops, even-odd, document units, material frame. Set once, since `labelPoint` is worked out from them.
    public private(set) var loops: [[Vec2]]
    /// How far its top stands above the material top (0 = flush).
    public var height: Double
    /// The keep-out layer the shape is on; nil for a zone from Toolpaths > Keep-Out Zones.
    public var layerID: UUID?
    /// Where its name goes: the centre when that's on the zone, else the point inside it furthest from its edges (`PartLabels`),
    /// so an L-shaped or ring clamp's name still sits on it.
    public let labelPoint: Vec2

    public init(name: String, loops: [[Vec2]], height: Double, layerID: UUID?) {
        self.name = name; self.loops = loops; self.height = height; self.layerID = layerID
        let box = Rect2(points: loops.joined())
        let centre = box.isEmpty ? .zero : box.center
        let inside = loops.filter { $0.count > 2 && PathGeometry.contains($0, centre) }.count % 2 == 1
        labelPoint = inside ? centre : PartLabels.labelPoint(region: loops)?.point ?? centre
    }

    public var bounds: Rect2 { Rect2(points: loops.joined()) }
}

/// Every keep-out the export checks: closed shapes on keep-out layers, hidden layers included (`Fixtures.zones`), then the zones from
/// Toolpaths > Keep-Out Zones. Names the operator can tell apart, and positions they can measure (issue #134).
public enum ClampList {
    public static func items(in doc: Document) -> [ClampItem] {
        let n = numbered(in: doc)
        return n.layerZones.map { ClampItem(name: $0.name, loops: $0.loops, height: $0.height, layerID: $0.layerID) }
            + (n.keepOutZones ?? []).filter(\.isUsable)
                .map { ClampItem(name: $0.name, loops: [$0.outline], height: max(0, $0.height), layerID: nil) }
    }

    /// The export's own zone lists under the names the job sheet gives them, so an error quotes "Clamp 2" (issue #138), and the
    /// source of `items`. The same zones, in the same order and with the same geometry and ids, as `Fixtures.zones` and
    /// `Document.keepOutZones`: only `name` changes, and only on a layer zone or a Keep-Out Zone that counts (`isUsable`), so
    /// what the checks accept and refuse is unchanged. Each zone is renamed in place from one list of names built from these
    /// same arrays, so no zone can be given another's name.
    public static func numbered(in doc: Document) -> (layerZones: [Fixtures.Zone], keepOutZones: [KeepOutZone]?) {
        var layerZones = Fixtures.zones(in: doc)
        var zones = doc.keepOutZones
        // An unnamed shape takes its layer's name, and a layer names a set: one shape on "Clamps" is one clamp, "Clamp 2".
        let layerNames = Dictionary(doc.layers.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        for i in layerZones.indices where layerZones[i].layerID.map({ layerNames[$0] == layerZones[i].name }) ?? false {
            layerZones[i].name = singular(layerZones[i].name)
        }
        let usable = zones?.indices.filter { zones![$0].isUsable } ?? []
        let names = numberedNames(layerZones.map(\.name) + usable.map { zones![$0].name })
        for i in layerZones.indices { layerZones[i].name = names[i] }
        for (k, i) in usable.enumerated() { zones![i].name = names[layerZones.count + k] }
        return (layerZones, zones)
    }

    /// The names in list order, with several sharing a name numbered; a name used once stays as it is. A number is never one
    /// that would repeat a name already in use ("Clamp 1" typed by the user), and a name that ends in a number gets it in
    /// brackets ("Clamp 1 (2)", for two shapes both named "Clamp 1").
    static func numberedNames(_ names: [String]) -> [String] {
        let counts = Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +)
        var taken = Set(counts.filter { $0.value == 1 }.keys)
        var next: [String: Int] = [:]
        return names.map { name in
            guard counts[name, default: 0] > 1 else { return name }
            let bracketed = name.last?.isNumber == true
            var n = next[name, default: 1], candidate: String
            repeat {
                candidate = bracketed ? "\(name) (\(n))" : "\(name) \(n)"
                n += 1
            } while taken.contains(candidate)
            next[name] = n
            taken.insert(candidate)
            return candidate
        }
    }

    /// "Clamps" → "Clamp", "Fixture Holes" → "Fixture Hole", "Boxes" → "Box", "Supplies" → "Supply". Only the last word, and
    /// only the plain English endings; a name that doesn't end in one ("Glass", "Hold-down") is left as it is.
    static func singular(_ name: String) -> String {
        let lower = name.lowercased()
        guard name.count > 3 else { return name }
        if lower.hasSuffix("ies") { return String(name.dropLast(3)) + (name.last!.isUppercase ? "Y" : "y") }
        if ["ches", "shes", "xes", "sses"].contains(where: { lower.hasSuffix($0) }) { return String(name.dropLast(2)) }
        if lower.hasSuffix("s"), !["ss", "us", "is"].contains(where: { lower.hasSuffix($0) }) { return String(name.dropLast()) }
        return name
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
