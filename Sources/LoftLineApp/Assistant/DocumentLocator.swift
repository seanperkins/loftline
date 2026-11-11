import AppKit

/// The `NSDocument` SwiftUI keeps behind a `LoftLineDocument`'s window, so the assistant's `save_project` saves through the
/// document's own pipeline (`snapshot`, `fileData`, `confirmSave`) and the window's name comes from the same place
/// (docs/superpowers/specs/2026-11-10-loftline-mcp-live-design.md, "The Mac host").
@MainActor
enum DocumentLocator {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// The document behind `doc`'s window: by its file, else by the undo manager the window shares with it.
    static func nsDocument(for doc: LoftLineDocument) -> NSDocument? {
        if let url = doc.fileURL, let found = NSDocumentController.shared.document(for: url) { return found }
        guard let undo = doc.undoManager else { return nil }
        return NSDocumentController.shared.documents.first { d in
            d.undoManager === undo || d.windowControllers.contains { $0.window?.undoManager === undo }
        }
    }

    /// Saves `doc` to its own file as File ▸ Save does, waits for the write, then confirms it so the window is clean and its
    /// recovery copy goes at once rather than at the next recovery tick.
    @discardableResult
    static func save(_ doc: LoftLineDocument) async throws -> Bool {
        guard let document = nsDocument(for: doc) else { throw Failure(message: "LoftLine couldn't find this window's document.") }
        guard let url = document.fileURL ?? doc.fileURL, let type = document.fileType else {
            throw Failure(message: "Use File ▸ Save As in LoftLine.")
        }
        try await write(document, to: url, type: type, operation: .saveOperation)
        return doc.confirmSave()
    }

    static func write(_ document: NSDocument, to url: URL, type: String, operation: NSDocument.SaveOperationType) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            document.save(to: url, ofType: type, for: operation) { error in
                if let error { done.resume(throwing: error) } else { done.resume() }
            }
        }
    }
}
