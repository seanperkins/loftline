import CADCore
import Foundation
import LoftLineKit

extension LoftLineDocument {
    /// Called when the document window appears: shows the notes if the file asks for it.
    func showJobNotesOnOpenIfNeeded() {
        guard document.wantsNotesOnOpen else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sheet == nil else { return }
            self.sheet = .io(.jobNotes(openedWithFile: true))
        }
    }

    func setJobNotes(_ text: String, showOnOpen: Bool) {
        perform("Edit Job Notes") {
            $0.document.jobNotes = text
            $0.document.showsNotesOnOpen = showOnOpen
        }
    }
}
