import CADCore
import Combine
import Foundation
import LoftLineKit

/// The shared, persisted tool database (CRUD + autosave). One instance per app.
final class ToolLibraryModel: ObservableObject {
    @Published private(set) var library: ToolLibrary
    /// Bumped when a change can alter toolpaths (a tool added or removed, or edited in more than
    /// its name, notes or folder), so documents mark their toolpaths stale.
    @Published private(set) var revision = 0
    /// How many times tools.json was written successfully (what the tests count).
    private(set) var writes = 0
    /// True while tools.json is behind the library because the last save failed, so the next change,
    /// or an editor save of an unchanged tool, retries it even when it changes nothing.
    private var unsaved = false
    /// The Tool Database editor's text edit that the library has not heard about yet; duplicate, export
    /// and import flush it first.
    private var draft: Tool?
    @Published var lastError: String?
    /// The material of the job whose window opened the Tool Database last, so the feeds calculator
    /// can start from its preset (the database window has no document of its own).
    @Published var jobMaterial: String?
    let store: ToolLibraryStore

    static let shared = ToolLibraryModel(store: ToolLibraryStore())

    init(store: ToolLibraryStore) {
        self.store = store
        do { library = try store.load() } catch {
            library = .seeded
            // The next edit saves the seeded library over the file; keep the user's copy first.
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = store.fileURL.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
            let kept = (try? FileManager.default.copyItem(at: store.fileURL, to: backup)) != nil
            lastError = "Could not read \(store.fileURL.path): \(error.localizedDescription). Using default tools"
                + (kept ? "; the unreadable file was kept as \(backup.lastPathComponent)." : ".")
        }
    }

    var tools: [Tool] { library.tools }

    /// Smallest tool number not used yet (past the editor's range when the library has a tool of every number in it).
    var nextToolNumber: Int {
        ToolNumbers.nextFree(in: library.tools) ?? (library.tools.map(\.number).max() ?? 0) + 1
    }

    /// A reasonable starting tool of `kind` in `units`.
    static func template(kind: ToolKind, units: LengthUnit, number: Int) -> Tool {
        let base: Tool
        switch kind {
        case .endMill:
            base = Tool(name: "New End Mill", kind: .endMill, diameter: 0.25, stepdown: 0.125, stepover: 0.1,
                        feedRate: 100, plungeRate: 30)
        case .ballNose:
            base = Tool(name: "New Ball Nose", kind: .ballNose, diameter: 0.25, stepdown: 0.1, stepover: 0.025,
                        feedRate: 100, plungeRate: 30)
        case .vBit:
            base = Tool(name: "New V-Bit", kind: .vBit, diameter: 0.5, angle: 60, stepdown: 0.1, stepover: 0.02,
                        feedRate: 80, plungeRate: 30)
        case .engraving:
            base = Tool(name: "New Engraving Bit", kind: .engraving, diameter: 0.125, flutes: 1, angle: 30,
                        tipDiameter: 0.01, stepdown: 0.02, stepover: 0.005, spindleRPM: 20000, feedRate: 40,
                        plungeRate: 15)
        case .drill:
            base = Tool(name: "New Drill", kind: .drill, diameter: 0.25, stepdown: 0.125, stepover: 0,
                        spindleRPM: 12000, feedRate: 30, plungeRate: 20)
        }
        var t = base.converted(to: units)
        t.number = number
        return t
    }

    @discardableResult
    func add(kind: ToolKind, units: LengthUnit = .inch) -> Tool {
        let t = Self.template(kind: kind, units: units, number: nextToolNumber)
        mutate { $0.upsert(t) }
        return t
    }

    /// Adds a tool of `kind` with a special outline (bull nose, tapered ball nose, form).
    @discardableResult
    func add(kind: ToolKind, shape: ToolShapeChoice, units: LengthUnit = .inch) -> Tool {
        var t = Self.template(kind: kind, units: units, number: nextToolNumber)
        t.shape = shape.defaultShape(for: t)
        switch shape {
        case .bullNose: t.name = "New Bull Nose"
        case .tapered: t.name = "New Tapered Ball Nose"; t.diameter *= 0.5
                       t.shape = shape.defaultShape(for: t); t.stepover = t.diameter * 0.1
        case .form: t.name = "New Form Tool"; t.diameter *= 2; t.shape = shape.defaultShape(for: t)
        case .standard: break
        }
        mutate { $0.upsert(t) }
        return t
    }

    func update(_ tool: Tool) { mutate { $0.upsert(tool) } }

    /// Saves an edit from the Tool Database editor when it differs from the stored tool.
    /// A tool deleted meanwhile is not brought back. Returns whether the library changed.
    @discardableResult
    func commitEdit(_ tool: Tool) -> Bool {
        if draft?.id == tool.id { draft = nil }
        guard let stored = library.tool(id: tool.id) else { return false }
        guard stored != tool else {
            retryFailedSave()
            return false
        }
        update(tool)
        return true
    }

    /// Writes the library again if the last save failed; does nothing otherwise.
    private func retryFailedSave() { mutate { _ in } }

    /// The library's copy of `tool`, when something other than the editor holding `tool` changed it
    /// (an import with Replace) and no text edit of its own is still held: the editor shows that version.
    func replacement(for tool: Tool) -> Tool? {
        guard draft?.id != tool.id, let stored = library.tool(id: tool.id), stored != tool else { return nil }
        return stored
    }

    /// Notes a text edit the editor is still typing, so the library actions below see it.
    func hold(_ tool: Tool) { draft = tool }

    private func flushDraft() {
        if let d = draft { commitEdit(d) }
    }

    @discardableResult
    func duplicate(id: UUID) -> Tool? {
        flushDraft()
        guard var t = library.tool(id: id) else { return nil }
        t.id = UUID()
        t.name += " copy"
        t.number = nextToolNumber
        mutate { $0.upsert(t) }
        return t
    }

    func delete(id: UUID) {
        if draft?.id == id { draft = nil }
        mutate { $0.remove(id: id) }
    }

    /// Adds any of the seeded defaults that are missing (by id); never deletes user tools.
    func restoreDefaults() {
        mutate { lib in for t in ToolLibrary.seeded.tools where lib.tool(id: t.id) == nil { lib.upsert(t) } }
    }

    /// Imports tools from a project snapshot into the library (skips IDs already present).
    func importTools(_ tools: [Tool]) {
        let missing = tools.filter { library.tool(id: $0.id) == nil }
        guard !missing.isEmpty else { return }
        mutate { lib in missing.forEach { lib.upsert($0) } }
    }

    /// Tools in a `.loftlinetools`/`tools.json`/`.csv` file, and which of them would overwrite a
    /// different library tool with the same id.
    func readImport(_ url: URL) throws -> (tools: [Tool], conflicts: [Tool]) {
        flushDraft()   // conflicts are judged against the tool as typed, as the merge will see it
        let tools = try ToolLibraryExchange.read(url)
        return (tools, library.conflicts(with: tools))
    }

    /// Merges imported tools into the library (see `ToolLibrary.merge`).
    @discardableResult
    func importTools(_ tools: [Tool], policy: ToolImportPolicy) -> ToolImportReport {
        flushDraft()
        var lib = library
        let report = lib.merge(tools, policy: policy)
        mutate { $0 = lib }
        return report
    }

    /// Writes the tools with `ids` (all tools when nil) in the format of `url`'s extension.
    /// The name to suggest for the exported file: the one tool's name, else "LoftLine Tools". A name still being
    /// typed counts: it is saved first, the way `export` saves it, so the suggestion matches the file's contents.
    func exportName(for ids: Set<UUID>?) -> String {
        flushDraft()
        return ids.flatMap { $0.first }.flatMap { library.tool(id: $0)?.name } ?? "LoftLine Tools"
    }

    func export(ids: Set<UUID>?, to url: URL) throws {
        flushDraft()
        let tools = ids.map { ids in library.tools.filter { ids.contains($0.id) } } ?? library.tools
        try ToolLibraryExchange.write(tools, to: url)
    }

    /// Applies `change` and saves. A change that leaves the library as it was writes nothing,
    /// unless an earlier save failed and the file is still behind.
    private func mutate(_ change: (inout ToolLibrary) -> Void) {
        var next = library
        change(&next)
        // A tool with no name (cleared in the editor, or in an imported file) is named from its geometry.
        for t in next.tools where t.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var named = t
            named.name = ToolNaming.name(for: t)
            next.upsert(named)
        }
        if next != library {
            let alters = next.changesToolpaths(from: library)
            library = next
            if alters { revision += 1 }
            unsaved = true
        }
        guard unsaved else { return }
        do {
            try store.save(library)
            unsaved = false; writes += 1; lastError = nil
        } catch {
            lastError = "Could not save tools: \(error.localizedDescription)"
        }
    }
}
