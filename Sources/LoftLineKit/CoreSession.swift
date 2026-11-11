import CADCore
import CAMCore
import Foundation
import PostCore

/// One open project for the desktop app: what `LoftLineDocument` does on the Mac, without SwiftUI. Edits, undo, the stale check
/// and posting go through the same Kit functions, so the two can't post different programs.
public final class CoreSession {
    public private(set) var project: LoftLineProject
    public private(set) var fileURL: URL?
    public private(set) var designRevision = 0
    public private(set) var results: [UUID: ToolpathResult] = [:]
    /// The side of a two-sided job on show, which is the side that posts (`LoftLineDocument.activeSide`).
    public private(set) var activeSide: JobSide = .top
    /// Bumped by every change to the project a window's edits are built from: an edit, undo, redo, new, open, save. Not by a
    /// calculated result, which no front-end edit rests on (the 3D preview and a job sheet calculate as they go). The desktop's front
    /// end sends the one it last saw, so the core can refuse a change built on an older project (spec 2, "The desktop host").
    public private(set) var changeRevision = 0
    /// Changes an assistant made that the user hasn't dismissed (spec 2, "The review marker"): Check Toolpaths warns of them.
    /// The live link keeps it up to date.
    public var assistantChanges = 0
    public var library: ToolLibrary
    public let toolStore: ToolLibraryStore
    public let postStore: PostProfileStore
    public let machineStore: MachineStore
    public private(set) var profiles: [PostProfile]
    public private(set) var skippedPosts: [SkippedPost]
    public private(set) var machines: [MachineDefinition]

    private var undoStack: [(project: LoftLineProject, action: String)] = []
    private var redoStack: [(project: LoftLineProject, action: String)] = []
    /// The project as last opened or saved: the document is dirty while it differs.
    private var savedProject: LoftLineProject
    private static let undoLimit = 100

    public init(toolStore: ToolLibraryStore = ToolLibraryStore(), postStore: PostProfileStore = PostProfileStore(),
                machineStore: MachineStore = MachineStore()) {
        self.toolStore = toolStore
        self.postStore = postStore
        self.machineStore = machineStore
        library = (try? toolStore.load()) ?? .seeded
        let loaded = postStore.load()
        profiles = loaded.profiles
        skippedPosts = loaded.skipped
        machines = machineStore.allMachines()
        project = LoftLineProject(document: Document())
        savedProject = project
    }

    /// A session over a copy of a window, for one assistant tool (spec 2): nothing is read from disk.
    public init(snapshot: CoreSnapshot, toolStore: ToolLibraryStore = ToolLibraryStore(), postStore: PostProfileStore = PostProfileStore(),
                machineStore: MachineStore = MachineStore()) {
        self.toolStore = toolStore
        self.postStore = postStore
        self.machineStore = machineStore
        library = snapshot.library
        profiles = snapshot.profiles
        skippedPosts = []
        machines = snapshot.machines
        project = snapshot.project
        savedProject = snapshot.savedProject
        fileURL = snapshot.fileURL
        activeSide = snapshot.activeSide
        designRevision = snapshot.designRevision
        results = snapshot.results
        assistantChanges = snapshot.assistantChanges
    }

    /// This session as a snapshot, carrying only fresh results.
    public func snapshot() -> CoreSnapshot {
        CoreSnapshot(project: project, savedProject: savedProject, fileURL: fileURL, activeSide: activeSide, designRevision: designRevision,
                     library: library, profiles: profiles, machines: machines, results: results.filter { !isStale($0.key) },
                     assistantChanges: assistantChanges)
    }

    public var isDirty: Bool { project != savedProject }
    public var undoAction: String? { undoStack.last?.action }
    public var redoAction: String? { redoStack.last?.action }

    // MARK: Files

    public func newProject() {
        project = LoftLineProject(document: Document())
        reset(fileURL: nil)
    }

    public func open(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        project = try LoftLineProject.opening(from: data)
        reset(fileURL: url)
    }

    /// Saves the project; `writer` does the write (the MCP server writes through its allowed-folder writer).
    public func save(to url: URL, writer: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
        var p = project
        p.refreshToolSnapshot(from: library)
        try writer(p.encoded(), url)
        project = p
        savedProject = p
        fileURL = url
        changeRevision += 1
    }

    private func reset(fileURL: URL?) {
        self.fileURL = fileURL
        savedProject = project
        undoStack = []
        redoStack = []
        results = [:]
        activeSide = .top
        designRevision += 1
        changeRevision += 1
    }

    // MARK: Edits

    /// As `LoftLineDocument.perform`: linked fields, the post and machine copies, the carried tools and the through depths follow every
    /// edit, and one that changes nothing leaves no undo step.
    public func perform(_ action: String, _ change: (inout LoftLineProject) throws -> Void) rethrows {
        var p = project
        try change(&p)
        VariableLinks.reconcile(&p, old: project, pending: [])
        p = ProjectPost.syncing(p, profiles: profiles, machines: machines)
        p = ToolSync.carrying(p, library: library)
        p = p.resolvingThroughDepths(from: project)
        guard p != project else { return }
        undoStack.append((project, action))
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        redoStack = []
        replace(with: p)
    }

    public func undo() {
        guard let step = undoStack.popLast() else { return }
        redoStack.append((project, step.action))
        replace(with: step.project)
    }

    public func redo() {
        guard let step = redoStack.popLast() else { return }
        undoStack.append((project, step.action))
        replace(with: step.project)
    }

    private func replace(with new: LoftLineProject) {
        let old = project
        project = new
        if old.document != new.document || Self.toolContentChanged(from: old.tools, to: new.tools) { designRevision += 1 }
        let live = Set(new.operations.flatMap { op -> [UUID] in
            if case .merge(let m) = op { return [op.id] + m.params.children.map(\.id) }
            return [op.id]
        })
        results = results.filter { live.contains($0.key) }
        if !new.document.job.isTwoSided { activeSide = .top }
        changeRevision += 1
    }

    // MARK: What posts

    /// Which side of a two-sided job is on show, and so posts.
    public func showSide(_ side: JobSide) {
        guard project.document.job.isTwoSided else { return }
        activeSide = side
    }

    /// What a program covers when it isn't the whole job: the sheet and side on show. Nil for a one-sheet, one-sided job.
    public var coverage: String? {
        let d = project.document
        let parts = (d.isMultiSheet ? ["Sheet: \(d.currentSheetName)"] : []) + (d.job.isTwoSided ? ["\(activeSide.displayName) side"] : [])
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// The project as a program all of whose toolpaths are on show sees it.
    public var outputProject: LoftLineProject { project.exportProject(for: .all, side: activeSide) }

    /// The chosen post with the job's machine limits. The project's own post is the project's copy, even when a post of that id is
    /// installed or none is (`LoftLineDocument.effectiveProfile`).
    public func profile(postID: String?) throws -> PostProfile {
        let own = resolved
        guard let postID, postID != ProjectPost.effectivePostID(project), postID != own.post.id else { return own.post }
        guard let installed = profiles.first(where: { $0.id == postID }) else { throw CoreFailure("Unknown post \"\(postID)\".") }
        return MachineResolver.effectiveProfile(installed, machine: own.machine)
    }

    private static func toolContentChanged(from old: [Tool], to new: [Tool]) -> Bool {
        old.contains { t in new.first { $0.id == t.id }.map { !$0.cutsSameToolpaths(as: t) } ?? false }
    }

    // MARK: Calculating

    public var resolved: ProjectPost.Resolved { ProjectPost.resolve(project, profiles: profiles, machines: machines) }

    public var rapidRate: Double {
        let own = resolved.post
        return own.rapidRate * own.units.factor(to: project.document.units)
    }

    /// True when the operation has no result or changed since it was calculated (`LoftLineDocument.isStale`).
    public func isStale(_ id: UUID) -> Bool {
        guard let r = results[id], let op = project.operations.first(where: { $0.id == id }) else { return true }
        if r.operation.withoutPostSettings != op.withoutPostSettings || r.designRevision != designRevision { return true }
        guard case .relief3D(let rel) = op, rel.params.finishing.isEnabled, case .operation(let source)? = rel.params.finishing.rest
        else { return false }
        let ordered = project.operations.flattened
        guard let s = ordered.firstIndex(where: { $0.id == source }), let me = ordered.firstIndex(where: { $0.id == id })
        else { return true }
        return !ordered[s].setup.isEnabled || s > me || r.restSource != ordered[s].withoutPostSettings
    }

    public func calculate(_ ids: [UUID]) {
        let rapid = rapidRate
        for id in ids {
            guard let op = project.operations.first(where: { $0.id == id }) else { continue }
            let r = ToolpathCalculator.calculate(op, project: project, library: library, designRevision: designRevision, rapidRate: rapid)
            results[id] = r.renamingTools(from: project.mergedTools(with: library)) ?? r
        }
    }

    public func calculateStale(_ ids: [UUID]) { calculate(ids.filter(isStale)) }

    // MARK: Posting

    /// Posts as the Export G-code sheet does: everything stale among what the program needs is calculated first.
    public func post(scope: GCodeExportScope, postID: String?, side: JobSide?, groupByTool: Bool) throws -> (GCodeExportResult, PostProfile) {
        let profile = try profile(postID: postID)
        let isOwnPost = profile.id == resolved.post.id
        let output = project.exportProject(for: scope, side: side ?? activeSide)
        let targets: [AnyOperation]
        switch scope {
        case .all: targets = output.operations.filter(\.setup.isEnabled)
        case .operation: targets = output.operations
        }
        calculateStale(GCodeExporter.calculationTargets(project: project, exported: targets.map(\.id), scope: scope, profile: profile))
        let toolpaths = GCodeExporter.toolpaths(scope: scope, operations: output.operations, results: results, groupByTool: groupByTool)
        let sheet = GCodeExporter.sheetToolpathsIfProbing(project: project, results: results, scope: scope, profile: profile)
        let asked = targets.map { op -> AnyOperation in
            var setup = op.editableSetup
            setup.isEnabled = true
            return op.with(setup: setup)
        }
        var result = GCodeExporter.export(project: output, toolpaths: toolpaths, profile: profile, jobName: project.document.name,
                                          expected: .operations(asked, results: results), sheetToolpaths: sheet)
        result.issues.insert(contentsOf: ProjectPost.issues(for: project, profiles: profiles, machines: machines,
                                                            includingPost: isOwnPost), at: 0)
        return (result, profile)
    }

    /// The toolpaths the 3D preview simulates, in program order, as the export would order them.
    public func previewToolpaths(groupByTool: Bool) -> [Toolpath] {
        let output = outputProject
        calculateStale(output.operations.filter(\.setup.isEnabled).map(\.id))
        return GCodeExporter.toolpaths(scope: .all, operations: output.operations, results: results, groupByTool: groupByTool)
    }

    public func reloadPosts() {
        let loaded = postStore.load()
        profiles = loaded.profiles
        skippedPosts = loaded.skipped
    }

    public func reloadMachines() { machines = machineStore.allMachines() }

    public func saveLibrary(_ new: ToolLibrary) throws {
        try toolStore.save(new)
        library = new
    }
}
