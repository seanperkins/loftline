import AppKit
import CADCore
import LoftLineKit

/// One VoiceOver element per visible shape; "press" selects it.
final class CanvasShapeElement: NSAccessibilityElement {
    let shapeID: UUID
    weak var canvas: CanvasNSView?

    init(shapeID: UUID, canvas: CanvasNSView) {
        self.shapeID = shapeID
        self.canvas = canvas
        super.init()
    }

    override func accessibilityPerformPress() -> Bool {
        guard let doc = canvas?.document else { return false }
        doc.select(shapeID, extending: false)
        canvas?.needsDisplay = true
        return true
    }
}

extension CanvasNSView {
    /// Shapes beyond this count are summarised instead of listed (keeps VoiceOver responsive).
    static let maxAccessibilityChildren = 400

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityRoleDescription() -> String? { "design canvas" }
    override func accessibilityLabel() -> String? { "Design canvas" }

    override func accessibilityValue() -> Any? {
        guard let doc = document else { return nil }
        return CanvasAccessibility.summary(doc.project, selectionCount: doc.selection.count)
    }

    override func accessibilityHelp() -> String? {
        "Tab and Shift-Tab select the next or previous vector, arrow keys nudge the selection, Delete removes it. Control-Tab leaves the canvas."
    }

    override func accessibilityChildren() -> [Any]? {
        guard let doc = document else { return [] }
        let project = doc.project
        let shapes = project.document.shapes.filter { project.isVisible($0) }.prefix(Self.maxAccessibilityChildren)
        return shapes.map { s -> CanvasShapeElement in
            let e = CanvasShapeElement(shapeID: s.id, canvas: self)
            e.setAccessibilityParent(self)
            e.setAccessibilityRole(.button)
            e.setAccessibilityRoleDescription("vector")
            e.setAccessibilityLabel(CanvasAccessibility.describe(s, in: project, selected: doc.selection.contains(s.id)))
            e.setAccessibilitySelected(doc.selection.contains(s.id))
            let b = s.bounds()
            if !b.isEmpty { e.setAccessibilityFrameInParentSpace(viewRect(b).insetBy(dx: -2, dy: -2)) }
            return e
        }
    }

    override func accessibilitySelectedChildren() -> [Any]? {
        accessibilityChildren()?.compactMap { $0 as? CanvasShapeElement }
            .filter { document?.selection.contains($0.shapeID) ?? false }
    }

    /// Tab / Shift-Tab: select the next / previous editable vector (one stop per group).
    /// Returns false when the key should go to the window (Control-Tab leaves the canvas).
    func handleTabKey(_ event: NSEvent) -> Bool {
        guard let doc = document, !event.modifierFlags.contains(.control) else { return false }
        let forward = !event.modifierFlags.contains(.shift)
        guard let id = CanvasAccessibility.next(after: doc.selectedShapes.map(\.id), in: doc.project, forward: forward)
        else { return true }
        doc.select(id, extending: false)
        if let s = doc.document.shape(id: id) {
            NSAccessibility.post(element: self, notification: .valueChanged)
            NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
                .announcement: CanvasAccessibility.describe(s, in: doc.project, selected: true),
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
        }
        return true
    }
}
