import CADCore
import CAMCore
import Foundation

/// VoiceOver descriptions and keyboard selection order for the design canvas. Pure.
public enum CanvasAccessibility {
    /// "Rectangle 2 by 1 in" style kind name from the shape's provenance.
    public static func kind(_ shape: Shape) -> String {
        switch shape.origin {
        case .drawn: return shape.isClosed ? "Closed vector" : "Open vector"
        case .imported(let f, _): return "Imported \(f.uppercased()) vector"
        case .rectangle: return "Rectangle"
        case .circle: return "Circle"
        case .ellipse: return "Ellipse"
        case .polygon(let sides, _): return "\(sides)-sided polygon"
        case .star(let points, _, _): return "\(points)-point star"
        case .text(let s, _, _): return "Text \u{201C}\(s)\u{201D}"
        case .derived(let op): return "\(op) result"
        }
    }

    public static func describe(_ shape: Shape, in project: LoftLineProject, selected: Bool) -> String {
        let u = project.document.units.abbreviation
        let b = shape.bounds()
        func f(_ v: Double) -> String { RulerTicks.label((v * 1000).rounded() / 1000) }
        var parts = [kind(shape)]
        if !shape.name.isEmpty, shape.name != kind(shape) { parts.append(shape.name) }
        if !b.isEmpty {
            parts.append("\(f(b.width)) by \(f(b.height)) \(u)")
            parts.append("at X \(f(b.min.x)) Y \(f(b.min.y))")
        }
        if let layer = project.document.layer(id: shape.layerID) { parts.append("layer \(layer.name)") }
        if shape.groupID != nil { parts.append("grouped") }
        if !project.isEditable(shape) { parts.append("locked") }
        if selected { parts.append("selected") }
        return parts.joined(separator: ", ")
    }

    /// One summary sentence for the canvas itself.
    public static func summary(_ project: LoftLineProject, selectionCount: Int) -> String {
        let doc = project.document
        let visible = doc.shapes.filter { project.isVisible($0) }.count
        var s = "\(visible) vector\(visible == 1 ? "" : "s") on material \(GCodeExporter.materialDescription(doc))"
        if selectionCount > 0 { s += ", \(selectionCount) selected" }
        return s
    }

    /// Shapes Tab cycles through: editable and visible, one stop per group (its first member).
    public static func tabStops(_ project: LoftLineProject) -> [UUID] {
        var seenGroups = Set<UUID>()
        return project.document.shapes.filter { project.isEditable($0) }.compactMap { s in
            if let g = s.groupID { guard seenGroups.insert(g).inserted else { return nil } }
            return s.id
        }
    }

    /// The shape Tab (forward) or Shift-Tab selects next, wrapping around. With nothing selected,
    /// the first (or last) stop.
    public static func next(after selection: [UUID], in project: LoftLineProject, forward: Bool) -> UUID? {
        let stops = tabStops(project)
        guard !stops.isEmpty else { return nil }
        let members = project.document.expandToGroups(selection)
        // Index of the stop that represents the current selection (first/last selected stop).
        let indices = stops.indices.filter { i in
            members.contains(stops[i])
        }
        guard let anchor = forward ? indices.last : indices.first else {
            return forward ? stops.first : stops.last
        }
        let n = stops.count
        return stops[(anchor + (forward ? 1 : n - 1)) % n]
    }
}
