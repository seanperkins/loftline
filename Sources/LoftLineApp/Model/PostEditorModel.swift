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
    /// The draft is the open project's post being added: it keeps its id (the project finds its post by it).
    private var keepsID = false
    /// The saved post the draft started from (nil for a new one).
    private var original: PostProfile?

    init(catalog: PostProfileCatalog) {
        self.catalog = catalog
    }

    var isDirty: Bool { isNew || draft != original }
    var store: PostProfileStore { catalog.store }
    /// A custom post that is saved (a built-in, or a new draft, has no file to delete).
    var canDelete: Bool { !isNew && draft.map { catalog.userIDs.contains($0.id) } == true }
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
        beginDraft(copy, keepingID: false)
    }

    /// An imported post as an unsaved draft: a file of an unchanged built-in keeps its controller, an empty pause list is the
    /// default pause, and the id is one no post or file here has.
    func beginImport(_ post: PostProfile) {
        var p = post.normalized
        p.controller = BuiltInPosts.probeController(for: post) ?? post.controller
        p.id = store.importID(for: post.id)
        beginDraft(p, keepingID: false)
    }

    /// The open project's own post as an unsaved draft, its id kept (`addState` says when that is possible).
    func beginAdd(_ carried: PostProfile) {
        beginDraft(carried.normalized, keepingID: true)
    }

    private func beginDraft(_ p: PostProfile, keepingID: Bool) {
        var p = p
        p.toolChangeProbe = nil
        original = nil
        isNew = true
        keepsID = keepingID
        selection = p.id
        draft = p
    }

    enum AddState: Equatable {
        case hidden, enabled
        case disabled(String)
    }

    /// Whether the open project's post can be added here, and why not.
    func addState(for carried: PostProfile?) -> AddState {
        guard let c = carried else { return .hidden }
        if isDirty && draft != nil { return .disabled("Save or Cancel the post you are editing first.") }
        guard PostProfileStore.isSafeID(c.id) else {
            return .disabled("The project's post id \"\(c.id)\" is not a plain file name.")
        }
        guard store.importID(for: c.id) == c.id else {
            return .disabled("A post or a post file here already uses the id \"\(c.id)\" (see Did not load).")
        }
        return .enabled
    }

    /// The saved custom post's file contents, for Export (nil for a built-in or an unsaved draft).
    func exportData() -> Data? {
        guard canDelete, !isDirty, let d = draft else { return nil }
        return try? d.toJSON()
    }

    struct CannotSave: LocalizedError {
        var problems: [String]
        var errorDescription: String? { problems.first ?? "The post cannot be saved." }
    }

    func save() throws {
        guard let d = draft else { return }
        guard report.canSave else { throw CannotSave(problems: report.problems) }
        // Only a loaded custom post is saved over: a built-in is read-only, and a file that did not load is kept as it is.
        guard isNew || catalog.userIDs.contains(d.id) else {
            throw CannotSave(problems: ["Built-in posts are read-only. Duplicate the post to edit a copy."])
        }
        let saved: PostProfile
        if isNew { saved = try store.saveNew(d, keepingID: keepsID) } else { try store.save(d); saved = d }
        keepsID = false
        catalog.reload()
        isNew = false
        original = saved
        selection = saved.id
        draft = saved
    }

    func cancel() {
        if isNew {
            isNew = false
            keepsID = false
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
    /// The program start: no lines is none (`PostProfile.normalized`).
    func setPreludeText(_ text: String) {
        let l = Self.lines(text)
        draft?.prelude = l.isEmpty ? nil : l
    }

    func setPauseText(_ text: String) {
        let l = Self.lines(text)
        draft?.pause = l.isEmpty ? nil : l
    }
}
