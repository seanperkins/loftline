import AppKit
import CADCore
import CAMCore
import LoftLineKit

/// Context menu and Edit-menu (responder chain) actions for the canvas.
extension CanvasNSView {
    static let shapesPasteboardType = NSPasteboard.PasteboardType("com.seanperkins.loftline.shapes")

    func contextMenu(_ doc: LoftLineDocument) -> NSMenu {
        let m = NSMenu()
        func item(_ title: String, _ action: Selector, enabled: Bool = true) {
            let i = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            i.target = self
            m.addItem(i)
        }
        if doc.activeTool == .nodeEdit, !doc.nodeSelection.isEmpty {
            item("Delete Node", #selector(deleteNodes(_:)))
            item("Insert Node After", #selector(insertNodes(_:)))
            item("Make Smooth", #selector(smoothNodes(_:)))
            item("Make Corner", #selector(cornerNodes(_:)))
            item("Next Segment to Curve", #selector(segmentsToCurves(_:)))
            item("Next Segment to Line", #selector(segmentsToLines(_:)))
            item("Break Path at Node", #selector(breakPath(_:)), enabled: doc.nodeSelection.count == 1)
            m.addItem(.separator())
        }
        let has = !doc.selection.isEmpty
        item("Cut", #selector(cut(_:)), enabled: has)
        item("Copy", #selector(copy(_:)), enabled: has)
        item("Paste", #selector(paste(_:)))
        item("Duplicate", #selector(duplicateShapes(_:)), enabled: has)
        item("Delete", #selector(delete(_:)), enabled: has)
        m.addItem(.separator())
        item("Group", #selector(groupShapes(_:)), enabled: doc.selection.count >= 2)
        item("Ungroup", #selector(ungroupShapes(_:)), enabled: doc.selectedShapes.contains { $0.groupID != nil })
        item("Edit Nodes", #selector(editNodes(_:)), enabled: has)
        m.addItem(.separator())
        item("Zoom to Selection", #selector(zoomToSelection(_:)), enabled: has)
        item("Zoom to Material", #selector(zoomToMaterial(_:)))
        return m
    }

    @objc func duplicateShapes(_ sender: Any?) { document?.duplicateSelection() }
    @objc func zoomToSelection(_ sender: Any?) { document?.requestCanvas(.fitSelection) }
    @objc func zoomToMaterial(_ sender: Any?) { fitMaterial() }
    @objc func groupShapes(_ sender: Any?) { document?.groupSelection() }
    @objc func ungroupShapes(_ sender: Any?) { document?.ungroupSelection() }
    @objc func editNodes(_ sender: Any?) { document?.activeTool = .nodeEdit }
    @objc func deleteNodes(_ sender: Any?) { document?.deleteSelectedNodes() }
    @objc func insertNodes(_ sender: Any?) { document?.insertNodesAfterSelection() }
    @objc func smoothNodes(_ sender: Any?) { document?.setSelectedNodes(smooth: true) }
    @objc func cornerNodes(_ sender: Any?) { document?.setSelectedNodes(smooth: false) }
    @objc func segmentsToCurves(_ sender: Any?) { document?.convertSegmentsAfterSelectedNodes(toCurve: true) }
    @objc func segmentsToLines(_ sender: Any?) { document?.convertSegmentsAfterSelectedNodes(toCurve: false) }
    @objc func breakPath(_ sender: Any?) { document?.breakAtSelectedNode() }

    override func selectAll(_ sender: Any?) {
        guard let doc = document else { return }
        if doc.activeTool == .nodeEdit, !nodeTargets.isEmpty {
            doc.nodeSelection = Set(nodeTargets.flatMap { ShapeNodes.nodes(of: $0).map(\.ref) })
        } else {
            doc.selectAll()
        }
        needsDisplay = true
    }

    @objc func delete(_ sender: Any?) {
        guard let doc = document else { return }
        if doc.activeTool == .nodeEdit, !doc.nodeSelection.isEmpty { doc.deleteSelectedNodes() } else { doc.deleteSelection() }
    }

    @objc func copy(_ sender: Any?) {
        guard let doc = document, !doc.selection.isEmpty, let data = ShapeClipboard.encode(doc.selectedShapes) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: Self.shapesPasteboardType)
    }

    @objc func cut(_ sender: Any?) {
        copy(sender)
        document?.deleteSelection()
    }

    @objc func paste(_ sender: Any?) {
        guard let doc = document, let data = NSPasteboard.general.data(forType: Self.shapesPasteboardType),
              let shapes = ShapeClipboard.decode(data) else { return }
        doc.pasteShapes(shapes)
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard let doc = document else { return false }
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)), #selector(duplicateShapes(_:)):
            return !doc.selection.isEmpty || (doc.activeTool == .nodeEdit && !doc.nodeSelection.isEmpty && item.action == #selector(delete(_:)))
        case #selector(paste(_:)):
            return NSPasteboard.general.data(forType: Self.shapesPasteboardType) != nil
        default:
            return true
        }
    }
}
