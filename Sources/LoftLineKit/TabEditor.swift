import CADCore
import CAMCore
import Foundation

/// Logic behind the on-canvas tab editor for Profile toolpaths: click a vector to add a tab,
/// drag a tab to move it along its vectors, option-click (or Delete) to remove it.
/// Tabs are `TabAnchor`s (vector + fraction along a path), so they follow the vector.
public enum TabEditor {
    /// Positions (material XY) of the anchors; nil for an anchor whose vector is gone.
    public static func positions(_ tabs: TabSettings, document: Document, tolerance: Double) -> [Vec2?] {
        (tabs.manualTabs ?? []).map { TabAnchors.point(of: $0, in: document, tolerance: tolerance) }
    }

    /// Index of the tab marker within `radius` of `p` (closest wins).
    public static func hit(at p: Vec2, tabs: TabSettings, document: Document, radius: Double, tolerance: Double) -> Int? {
        var best: (Int, Double)?
        for (i, q) in positions(tabs, document: document, tolerance: tolerance).enumerated() {
            guard let q else { continue }
            let d = q.distance(to: p)
            if d <= radius, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }

    /// Switches to manual tabs, seeding them with the automatic layout's count per closed path.
    public static func makeManual(_ tabs: TabSettings, shapes: [Shape]) -> TabSettings {
        guard !tabs.isManual else { return tabs }
        var t = tabs
        t.isEnabled = true
        let n = max(1, tabs.countPerPath)
        t.manualTabs = shapes.flatMap { s in
            s.paths.enumerated().filter { $0.element.isClosed }.flatMap { i, _ in
                (0..<n).map { TabAnchor(shapeID: s.id, pathIndex: i, fraction: (Double($0) + 0.5) / Double(n)) }
            }
        }
        return t
    }

    /// Back to evenly spaced automatic tabs.
    public static func makeAutomatic(_ tabs: TabSettings) -> TabSettings {
        var t = tabs
        t.manualTabs = nil
        return t
    }

    /// Adds a tab on the nearest of `shapes` within `maxDistance` of `p` (nil = nothing near).
    public static func adding(at p: Vec2, to tabs: TabSettings, shapes: [Shape], maxDistance: Double,
                       tolerance: Double) -> TabSettings? {
        guard let a = TabAnchors.anchor(nearest: p, on: shapes, maxDistance: maxDistance, tolerance: tolerance) else {
            return nil
        }
        var t = tabs
        t.isEnabled = true
        t.manualTabs = (t.manualTabs ?? []) + [a]
        return t
    }

    /// Moves tab `index` to the point of `shapes` nearest to `p` (no distance limit while dragging).
    public static func moving(_ index: Int, to p: Vec2, in tabs: TabSettings, shapes: [Shape], tolerance: Double) -> TabSettings? {
        guard var list = tabs.manualTabs, list.indices.contains(index),
              let a = TabAnchors.anchor(nearest: p, on: shapes, maxDistance: .infinity, tolerance: tolerance) else {
            return nil
        }
        list[index] = a
        var t = tabs
        t.manualTabs = list
        return t
    }

    public static func removing(_ index: Int, from tabs: TabSettings) -> TabSettings {
        guard var list = tabs.manualTabs, list.indices.contains(index) else { return tabs }
        list.remove(at: index)
        var t = tabs
        t.manualTabs = list
        return t
    }
}

extension AnyOperation {
    /// Tab settings of a Profile operation (nil for other kinds).
    public var profileTabs: TabSettings? {
        if case .profile(let o) = self { return o.params.tabs }
        return nil
    }

    /// Copy with new profile tabs (unchanged for other kinds).
    public func withProfileTabs(_ tabs: TabSettings) -> AnyOperation {
        guard case .profile(var o) = self else { return self }
        o.params.tabs = tabs
        return .profile(o)
    }
}
