import Foundation
import Testing
@testable import LoftLineApp

/// A document window attaches in one step (docs/implicit-state-machines.md #26): the undo manager, the file URL and the
/// crash-recovery registration are set together, so no edit can land between them.
@Suite @MainActor struct WindowAttachTests {
    @Test func attachSetsUndoURLAndRecoveryTogether() {
        let doc = LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
        let recovery = RecoveryCoordinator(store: RecoveryStore())
        let um = UndoManager()
        let url = URL(fileURLWithPath: "/tmp/attach.loftline")
        doc.attachWindow(undoManager: um, fileURL: url, recovery: recovery)
        #expect(doc.undoManager === um)
        #expect(doc.fileURL == url)
        #expect(recovery.isRegistered(doc))
        recovery.unregister(doc)
        #expect(!recovery.isRegistered(doc))
    }
}
