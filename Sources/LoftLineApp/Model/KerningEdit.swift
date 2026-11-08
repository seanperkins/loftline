import CADCore
import CAMCore
import Foundation
import LoftLineKit

/// Interactive kerning: drag the letters of a live text shape on the canvas. Each drag or nudge
/// is one "Kern Letters" undo step; the text stays live (`TextSpec.letterAdjustments`).
extension LoftLineDocument {
    /// The live text shape being kerned (nil when the mode is off or the shape lost its text).
    var kerningShape: Shape? {
        guard let id = kerningShapeID, let s = project.document.shape(id: id), s.text != nil, project.isEditable(s) else { return nil }
        return s
    }

    /// Starts kerning `id` (or the single selected text shape).
    func beginKerning(_ id: UUID? = nil) {
        let target = id ?? (selectedShapes.count == 1 ? selectedShapes.first?.id : nil)
        guard let t = target, let s = project.document.shape(id: t), s.text != nil, project.isEditable(s) else {
            report(AlertMessage(title: "Kerning", message: "Select one editable text object first."))
            return
        }
        envelopeEdit = nil
        tabEditingOperationID = nil
        activeTool = .select
        setSelection([t])
        kerningShapeID = t
    }

    func endKerning() { kerningShapeID = nil }

    /// Moves letters of the kerned text by a document-space delta.
    func kernLetters(_ letters: Set<Int>, by delta: Vec2) {
        guard let s = kerningShape, let spec = s.text, !letters.isEmpty, delta != .zero else { return }
        let moved = TextKerning.moving(spec, letters: letters, byDocumentDelta: delta)
        setLetterAdjustments(of: s.id, moved.letterAdjustments, actionName: "Kern Letters")
    }

    /// Clears every letter move/rotation of the kerned text.
    func resetKerning() {
        guard let s = kerningShape, s.text?.letterAdjustments != nil else { return }
        setLetterAdjustments(of: s.id, nil, actionName: "Reset Letters")
    }

    func setLetterAdjustments(of id: UUID, _ list: [TextSpec.LetterAdjustment]?, actionName: String) {
        guard var spec = project.document.shape(id: id)?.text else { return }
        spec.letterAdjustments = list
        do {
            var p = project
            try VectorCommands.updateText(id, spec: spec, in: &p)
            let updated = p
            perform(actionName) { $0 = updated }
        } catch {
            report(AlertMessage(title: "Text", message: ImportService.describe(error)))
        }
    }

    /// Letters that a drag starting on `letter` moves: that letter, or with `restOfLine` the
    /// letter and every later letter on its line (opens or closes the gap before it).
    static func kerningGroup(_ letter: Int, in letters: [TextKerning.Letter], restOfLine: Bool) -> Set<Int> {
        guard restOfLine, let line = letters.first(where: { $0.index == letter })?.line else { return [letter] }
        return Set(letters.filter { $0.line == line && $0.index >= letter }.map(\.index))
    }
}
