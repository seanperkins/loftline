import Foundation
import PostCore

/// The Post Processors sheet's state: which post is selected, the draft being edited and its report. Built-in posts are
/// read-only; Duplicate makes an unsaved draft, Save writes it, Cancel discards. While a draft has unsaved changes the list is
/// locked, so a selection never silently drops an edit.
@MainActor
final class PostEditorModel: ObservableObject {
    let catalog: PostProfileCatalog
    @Published private(set) var selection: String?
    @Published var draft: PostProfile? {
        didSet { report = draft.map(PostDraftReport.make) ?? PostDraftReport() }
    }
    @Published private(set) var report = PostDraftReport()
    @Published private(set) var isNew = false
    /// The saved post the draft started from (nil for a new one).
    private var original: PostProfile?

    init(catalog: PostProfileCatalog) {
        self.catalog = catalog
    }

    var isDirty: Bool { isNew || draft != original }
    var store: PostProfileStore { catalog.store }
    /// A custom post that is saved (a built-in, or a new draft, has no file to delete).
    var canDelete: Bool { !isNew && draft.map { store.isUserPost($0.id) } == true }
    /// Built-in posts are read-only: only a duplicate or a custom post can be edited.
    var isEditable: Bool { isNew || canDelete }

    /// Selects a post. Refused (false) while the draft has unsaved changes.
    @discardableResult
    func select(_ id: String?) -> Bool {
        guard !isDirty || draft == nil else { return false }
        selection = id
        original = catalog.profiles.first { $0.id == id }
        isNew = false
        draft = original
        return true
    }

    /// An unsaved copy of the selected post with a fresh id; a copy of a built-in keeps its controller, so it can still use
    /// touch-plate tool changes.
    func duplicate() {
        guard let base = draft else { return }
        var copy = base
        copy.id = store.newID(from: base.id)
        copy.name = base.name + " (custom)"
        copy.controller = BuiltInPosts.probeController(for: base) ?? base.controller
        copy.toolChangeProbe = nil
        original = nil
        isNew = true
        selection = copy.id
        draft = copy
    }

    struct CannotSave: LocalizedError {
        var problems: [String]
        var errorDescription: String? { problems.first ?? "The post cannot be saved." }
    }

    func save() throws {
        guard let d = draft else { return }
        guard report.canSave else { throw CannotSave(problems: report.problems) }
        let saved: PostProfile
        if isNew { saved = try store.saveNew(d) } else { try store.save(d); saved = d }
        catalog.reload()
        isNew = false
        original = saved
        selection = saved.id
        draft = saved
    }

    func cancel() {
        if isNew {
            isNew = false
            original = nil
            selection = nil
            draft = nil
        } else {
            draft = original
        }
    }

    func delete() throws {
        guard canDelete, let d = draft else { return }
        try store.delete(id: d.id)
        catalog.reload()
        original = nil
        selection = nil
        draft = nil
    }

    // MARK: Text areas

    /// A multi-line template from a text area: one G-code line per line, blank lines dropped.
    static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func setLines(_ keyPath: WritableKeyPath<PostProfile, [String]>, _ text: String) {
        draft?[keyPath: keyPath] = Self.lines(text)
    }

    /// An empty pause text area means the default pause (nil), never an empty template that stops nothing.
    func setPauseText(_ text: String) {
        let l = Self.lines(text)
        draft?.pause = l.isEmpty ? nil : l
    }
}
