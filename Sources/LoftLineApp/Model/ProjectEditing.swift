import CADCore
import CAMCore
import Foundation

/// Pure editing operations on a project. `LoftLineDocument` wraps each call in an undoable change.
extension LoftLineProject {
    // MARK: Shapes

    /// Layers whose shapes can be picked/edited on the canvas.
    func isEditable(_ shape: Shape) -> Bool {
        guard !shape.isLocked, let layer = document.layer(id: shape.layerID) else { return !shape.isLocked }
        return layer.isVisible && !layer.isLocked
    }

    func isVisible(_ shape: Shape) -> Bool { document.layer(id: shape.layerID)?.isVisible ?? true }

    /// Removes the editable shapes among `ids` (a locked shape or layer keeps its shapes) and
    /// drops their IDs from every operation's selection.
    mutating func deleteShapes(_ ids: Set<UUID>) {
        // Callers may pass ids of shapes already gone (a removed sheet's vectors): those still
        // leave the operations below; only shapes present and protected are kept.
        let protected = Set(document.shapes.filter { ids.contains($0.id) && !isEditable($0) }.map(\.id))
        let ids = ids.subtracting(protected)
        guard !ids.isEmpty else { return }
        document.removeShapes(ids: ids)
        document.pruneSingletonGroups()
        for i in operations.indices {
            var s = operations[i].editableSetup
            s.shapeIDs.removeAll { ids.contains($0) }
            operations[i].editableSetup = s
        }
    }

    /// Transforms the editable shapes among `ids`: a locked shape, or one on a locked or hidden
    /// layer, stays put however it was selected (sidebar rows and "Select Shapes on Layer" can
    /// select what the canvas cannot pick).
    mutating func transformShapes(_ ids: Set<UUID>, by t: Transform2D) {
        for i in document.shapes.indices where ids.contains(document.shapes[i].id) && isEditable(document.shapes[i]) {
            var s = document.shapes[i].transformed(t)
            // A non-uniform transform invalidates parametric provenance.
            if !t.isConformal { s.origin = .derived(operation: "transform") }
            document.shapes[i] = s
        }
    }

    mutating func moveShapes(_ ids: Set<UUID>, toLayer layerID: UUID) {
        for i in document.shapes.indices where ids.contains(document.shapes[i].id) && isEditable(document.shapes[i]) {
            document.shapes[i].layerID = layerID
        }
    }

    /// Bounds of the given shapes (empty if none).
    func bounds(of ids: Set<UUID>) -> Rect2 {
        document.shapes.filter { ids.contains($0.id) }.reduce(Rect2.empty) { $0.union($1.bounds()) }
    }

    // MARK: Layers

    @discardableResult
    /// A new layer on the current sheet (a layer with no sheet is on the primary one, so one added while another sheet
    /// is shown would be hidden there).
    mutating func addLayer(named name: String? = nil) -> UUID {
        let palette = ["#1E90FF", "#E4572E", "#17BEBB", "#76B041", "#FFC914", "#9B5DE5"]
        let n = document.layers.count + 1
        var layer = Layer(name: name ?? "Layer \(n)", colorHex: palette[(n - 1) % palette.count])
        layer.sheetID = document.currentSheetID == MaterialSheet.primaryID ? nil : document.currentSheetID
        document.layers.append(layer)
        return layer.id
    }

    /// The current sheet's layer named `name`, if there is one (import reuses it instead of adding another).
    func layerOnCurrentSheet(named name: String) -> UUID? {
        document.layers.first { $0.name == name && document.sheetID(ofLayer: $0.id) == document.currentSheetID }?.id
    }

    /// Deletes a layer. Its shapes move to another ordinary layer of the same sheet and side so
    /// nothing jumps to the other side of a two-sided job; a keep-out layer's clamp outlines are
    /// deleted with it, because as plain vectors they would become parts and the keep-out check
    /// would silently stop covering them. The last layer stays.
    mutating func deleteLayer(_ id: UUID) {
        guard document.layers.count > 1, let idx = document.layers.firstIndex(where: { $0.id == id }) else { return }
        let gone = document.layers.remove(at: idx)
        if gone.keepOut != nil {
            // Straight removal: the layer is gone, so its lock no longer protects the outlines.
            document.removeShapes(ids: Set(document.shapes.filter { $0.layerID == id }.map(\.id)))
            document.pruneSingletonGroups()
            return
        }
        guard document.shapes.contains(where: { $0.layerID == id }) else { return }
        let ordinary = document.layers.filter { $0.keepOut == nil && $0.sheet == nil }
        // Never another side or sheet: with no ordinary layer left there, one is made.
        let target = ordinary.first { $0.side == gone.side && $0.sheetID == gone.sheetID }?.id ?? {
            var layer = Layer(name: "Layer \(document.layers.count + 1)", colorHex: gone.colorHex)
            layer.side = gone.side
            layer.sheetID = gone.sheetID
            document.layers.append(layer)
            return layer.id
        }()
        for i in document.shapes.indices where document.shapes[i].layerID == id { document.shapes[i].layerID = target }
    }

    mutating func updateLayer(_ layer: Layer) {
        if let i = document.layers.firstIndex(where: { $0.id == layer.id }) { document.layers[i] = layer }
    }

    // MARK: Operations

    func operationIndex(_ id: UUID) -> Int? { operations.firstIndex { $0.id == id } }

    mutating func upsertOperation(_ op: AnyOperation) {
        if let i = operationIndex(op.id) { operations[i] = op } else { operations.append(op) }
    }

    mutating func deleteOperation(_ id: UUID) { operations.removeAll { $0.id == id } }

    /// Moves an operation up (-1) or down (+1) in the machining order.
    mutating func moveOperation(_ id: UUID, by delta: Int) {
        guard let i = operationIndex(id) else { return }
        let j = i + delta
        guard operations.indices.contains(j) else { return }
        operations.swapAt(i, j)
    }

    /// Makes sure the embedded tool snapshot holds every tool the operations use, so the file opens on machines without
    /// them. The file's own tools are kept as they are, never overwritten from the library (`ToolSync.carrying`).
    mutating func refreshToolSnapshot(from library: ToolLibrary) {
        self = ToolSync.carrying(self, library: library)
    }
}
