import CADCore
import CAMCore
import Combine
import CryptoKit
import Foundation
import PostCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Native project file (JSON). Declared in Info.plist by scripts/bundle.sh.
    static let loftlineProject = UTType(exportedAs: "com.seanperkins.loftline.project", conformingTo: .json)
}

enum SidebarTab: String, CaseIterable, Identifiable {
    case design = "Design", toolpaths = "Toolpaths"
    var id: String { rawValue }
}

enum CenterMode: String, CaseIterable, Identifiable {
    case design2D = "2D", preview3D = "3D"
    /// 2D design and 3D preview side by side.
    case split = "2D | 3D"
    var id: String { rawValue }

    var showsDesign: Bool { self != .preview3D }
    var showsPreview: Bool { self != .design2D }
}

enum DocumentSheet: Identifiable, Equatable {
    case jobSetup
    case exportGCode(GCodeExportScope)
    case offset
    case inlayWizard
    case placeModel(ModelPlacementForm)
    case saveAllToolpaths
    case validation
    case keepOutZones
    case nesting
    case fixtures
    case tiling
    case partLabels
    case variables
    case productionPlates
    /// Drawing-tool dialogs (dog-bones, arrays, validator, …).
    case drawing(DrawingSheet)
    /// File / IO dialogs (model parts, job notes, clipart…), see `IOSheets.swift`.
    case io(IOSheet)

    var id: String {
        switch self {
        case .jobSetup: return "job"
        case .exportGCode: return "export"
        case .offset: return "offset"
        case .inlayWizard: return "inlay"
        case .placeModel(let f): return "place-\(f.modelID)"
        case .saveAllToolpaths: return "saveAll"
        case .validation: return "validation"
        case .keepOutZones: return "keepOut"
        case .nesting: return "nesting"
        case .fixtures: return "fixtures"
        case .tiling: return "tiling"
        case .partLabels: return "partLabels"
        case .variables: return "variables"
        case .productionPlates: return "productionPlates"
        case .drawing(let d): return "drawing-\(d.rawValue)"
        case .io(let s): return "io-\(s.id)"
        }
    }
}

struct AlertMessage: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// Requests from menus/toolbar to the canvas (zoom etc.). `serial` makes repeats observable.
struct CanvasRequest: Equatable {
    enum Kind: Equatable { case fit, zoomIn, zoomOut, fitSelection }
    var kind: Kind
    var serial: Int
}

/// What SwiftUI takes when it saves and hands back to encode: the project to write, and which save it belongs to
/// (the id ties the encoded bytes to this save however saves overlap).
struct LoftLineSnapshot {
    var project: LoftLineProject
    var saveID: Int
}

/// One open `.loftline` document: the project plus per-window editing state. All project edits go
/// through `perform`, which registers snapshot-based undo with the window's undo manager.
final class LoftLineDocument: ReferenceFileDocument {
    typealias Snapshot = LoftLineSnapshot

    static var readableContentTypes: [UTType] { [.loftlineProject] }
    static var writableContentTypes: [UTType] { [.loftlineProject] }

    @Published private(set) var project: LoftLineProject
    /// Bumped whenever the design (not the operations) changes; toolpaths compare against it.
    @Published private(set) var designRevision = 0

    // Editing state (not saved).
    @Published var selection: Set<UUID> = []
    /// Selection order (first = primary, e.g. the shape others are subtracted from).
    private(set) var selectionOrder: [UUID] = []
    @Published var selectedOperationID: UUID?
    @Published var hiddenToolpaths: Set<UUID> = []
    /// Profile operation whose tabs the canvas is editing (click to add, drag to move).
    @Published var tabEditingOperationID: UUID?
    /// Envelope distortion with draggable corners in progress on the canvas.
    @Published var envelopeEdit: EnvelopeEdit?
    /// Live text whose letters are being dragged on the canvas (interactive kerning).
    @Published var kerningShapeID: UUID?
    /// STL imports waiting for the placement dialog (shown one after another).
    var pendingPlacements: [ModelPlacementForm] = []
    /// SVG files with no physical size, waiting for their scale to be confirmed (`IOSheet.svgScale`).
    var pendingScales: [SVGScaleRequest] = []
    var deferredAlert: AlertMessage?
    /// Expressions typed into numeric fields, linked to parameters on the next edit (io).
    let expressionRecorder = ExpressionRecorder()
    @Published var showToolpaths = true
    @Published var results: [UUID: ToolpathResult] = [:]
    /// The last job summary, rebuilt only when what it is made from changes (`jobSummary(groupByTool:settings:)`).
    let jobSummaryMemo = JobSummary.Memo()
    @Published var calculating: Set<UUID> = []
    /// Operations asked to recalculate while already calculating.
    private var pendingRecalculation: Set<UUID> = []
    /// Monotonic stamp per calculation; a result is stored only if newer than the current one.
    private var generationCounter = 0
    private var resultGeneration: [UUID: Int] = [:]
    @Published var activeTool: CanvasTool = .select {
        didSet { if activeTool != .nodeEdit { nodeSelection = [] } }
    }
    /// Selected anchors while the node-edit tool is active.
    @Published var nodeSelection: Set<NodeRef> = []
    /// Snap to nodes, midpoints and centres of other shapes (before falling back to the grid).
    @Published var snapToObjects = true
    @Published var drawingOptions = DrawingOptions()
    @Published var snapToGrid = true
    @Published var sidebarTab: SidebarTab = .design
    @Published var centerMode: CenterMode = .design2D
    /// Side shown and edited in a two-sided job.
    @Published var activeSide: JobSide = .top
    @Published var sheet: DocumentSheet?
    /// Shown by ContentView on the document window. Never set it while a sheet is up: SwiftUI drops an
    /// alert under a sheet. A sheet shows its own failure (`SheetErrorRow`) or reports with `report(_:)`.
    @Published var alert: AlertMessage?
    @Published var canvasRequest = CanvasRequest(kind: .fit, serial: 0)
    /// Cursor position in document units (for the status bar).
    @Published var cursorPosition: Vec2?
    /// Problem locations circled on the canvas (vector validator); cleared by the user.
    @Published var highlightMarkers: [Vec2] = []
    /// Snap to guides (and, with object snapping, to horizontal/vertical lines through nodes).
    @Published var snapToGuides = true
    /// Last Measure-tool reading (shown on the canvas and in the inspector).
    @Published var measurement: Measurement?

    weak var undoManager: UndoManager?
    /// Where the document is saved (from the window's document configuration), for the Finder icon.
    var fileURL: URL?
    /// Bumped by every undoable change (including undo/redo).
    private var editSerial = 0
    /// Bumped whenever `project` or an entry of `results` changes, by any path (see `postedInputs`).
    private var outputSerial = 0
    /// The operation whose live edits are being merged into the current undo step.
    private var liveOperationEdit: (id: UUID, serial: Int)?
    let toolLibrary: ToolLibraryModel
    /// The library as this document last saw it, so a Tool Database edit can be told from a difference that was
    /// already there (`ToolSync.applyingLibraryChange`).
    private var lastLibrary: ToolLibrary
    /// The installed posts and machines the project's copies are compared with (`.shared` in the app).
    let postCatalog: PostProfileCatalog
    let machineCatalog: MachineCatalog
    private var cancellables: Set<AnyCancellable> = []

    /// Identifies this window's crash-recovery copy.
    let recoveryID = UUID()
    /// The project as last opened or saved; unsaved changes = `project` differs from it. A save moves it only
    /// once the file is seen to hold the saved bytes (`confirmSave`), so a write that failed leaves the document
    /// dirty and its recovery copy in place.
    private(set) var lastSavedProject: LoftLineProject
    /// True when the project differs from the saved one, or when the saved one is not known: a save that may have
    /// reached the file was forgotten (see `pendingLimit`), so equality with `lastSavedProject` proves nothing.
    var needsRecovery: Bool {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return savedStateUnknown || project != lastSavedProject
    }

    /// A save SwiftUI has taken (`snapshot`) that is not known to be on disk. The system writes the bytes after
    /// `fileWrapper` returns and reports nothing back, so each save waits here, by its id, until the file is seen
    /// to hold what it handed over. `bytes` is the size and SHA-256 of that data once `fileData` has produced it.
    private struct PendingSave {
        var id: Int
        var project: LoftLineProject
        var bytes: (count: Int, digest: SHA256Digest)?
    }
    /// Oldest first, kept to the last few. A save stays in the list after it is matched, so a late older write
    /// that replaces a newer one is noticed too.
    private static let pendingLimit = 8
    /// `snapshot` runs on the main actor and `fileWrapper` may not, so the pending saves have their own lock
    /// (it also guards the two flags below).
    private let pendingLock = NSLock()
    /// One confirmation at a time: it reads the file and then promotes, and two interleaved could promote the older.
    private let confirmLock = NSLock()
    private var pendingSaves: [PendingSave] = []
    private var lastSaveID = 0
    /// The size and digest of the file when it was last seen to hold a save: the evidence for `lastSavedProject`,
    /// kept apart from the bounded list so it survives the list forgetting that save.
    private var confirmedBytes: (count: Int, digest: SHA256Digest)?
    /// Set when the file may hold something no known save explains: a save that was encoded and may have landed
    /// was dropped from the list, or the file no longer holds what it held when `lastSavedProject` was set. The
    /// document then stays "needs recovery" until the file is seen to hold a known save again.
    private var savedStateUnknown = false

    init(project: LoftLineProject, toolLibrary: ToolLibraryModel = .shared,
         postCatalog: PostProfileCatalog = .shared, machineCatalog: MachineCatalog = .shared) {
        // The project's post and machine copies are attached here, in memory: the file is not rewritten until a save,
        // and the document starts unedited (the baseline is the attached project).
        let attached = ToolSync.carrying(
            ProjectPost.attaching(project, profiles: postCatalog.profiles, machines: machineCatalog.machines),
            library: toolLibrary.library)
        self.project = attached
        self.lastSavedProject = attached
        self.lastLibrary = toolLibrary.library
        self.postCatalog = postCatalog
        self.machineCatalog = machineCatalog
        self.toolLibrary = toolLibrary
        toolLibrary.$revision.dropFirst().sink { [weak self] _ in self?.designRevision += 1 }.store(in: &cancellables)
        toolLibrary.$library.dropFirst().sink { [weak self] lib in self?.libraryChanged(to: lib) }.store(in: &cancellables)
    }

    convenience init() {
        let prefs = PreferencesModel.shared.prefs
        self.init(project: prefs.newProject(machines: MachineCatalog.shared.machines,
                                            profiles: PostProfileCatalog.shared.profiles))
        applyWindowPreferences(prefs)
    }

    required convenience init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try self.init(opening: data)
        applyWindowPreferences(PreferencesModel.shared.prefs)
    }

    /// Opens a project file's bytes, refusing a post or machine copy this LoftLine cannot read (`ProjectOpenError`).
    convenience init(opening data: Data, toolLibrary: ToolLibraryModel = .shared) throws {
        self.init(project: try LoftLineProject.opening(from: data), toolLibrary: toolLibrary)
    }

    /// Per-window editing defaults from Preferences (snapping).
    func applyWindowPreferences(_ prefs: AppPreferences) {
        snapToGrid = prefs.snapToGrid
        snapToObjects = prefs.snapToObjects
    }

    func snapshot(contentType: UTType) throws -> LoftLineSnapshot {
        // After a save, the next live toolpath edit opens a new undo step (re-dirtying the file).
        liveOperationEdit = nil
        scheduleFileThumbnail()
        pendingLock.lock()
        lastSaveID += 1
        let id = lastSaveID
        pendingSaves.append(PendingSave(id: id, project: project, bytes: nil))
        if pendingSaves.count > Self.pendingLimit {
            // An encoded save may have landed; with it forgotten, equality with the saved project proves nothing.
            if pendingSaves.removeFirst().bytes != nil { savedStateUnknown = true }
        }
        pendingLock.unlock()
        var p = project
        p.refreshToolSnapshot(from: toolLibrary.library)
        return LoftLineSnapshot(project: p, saveID: id)
    }

    func fileWrapper(snapshot: LoftLineSnapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try fileData(for: snapshot))
    }

    /// The bytes the system is asked to write for `snapshot`; their size and digest are kept against that save
    /// (not against whichever save is newest) so the file can be checked later.
    func fileData(for snapshot: LoftLineSnapshot) throws -> Data {
        let data = FileThumbnail.withQuickLookThumbnail(try snapshot.project.encoded(), for: snapshot.project.document)
        let digest = SHA256.hash(data: data)
        pendingLock.lock()
        if let i = pendingSaves.firstIndex(where: { $0.id == snapshot.saveID }) {
            // Encoded before with different bytes (a preference read at encoding time): both may land.
            if let old = pendingSaves[i].bytes, old.count != data.count || old.digest != digest { savedStateUnknown = true }
            pendingSaves[i].bytes = (data.count, digest)
        } else {
            // The list dropped this save before it was encoded; these bytes can still reach the file.
            savedStateUnknown = true
        }
        pendingLock.unlock()
        return data
    }

    /// Looks at the file at `fileURL`. When it holds exactly what one of the pending saves handed over (the newest
    /// that matches), that save's project is the saved one, so the document is clean if it still equals it and its
    /// recovery copy goes at the next tick. The file's content decides: a late older write that replaced a newer
    /// one moves the saved project back. When the file holds neither a known save nor what it held when the saved
    /// project was last set, or, before any save was matched, none of the saves handed over (an older save that was
    /// forgotten landed, the file was replaced or removed), the saved state is unknown and the document stays dirty. A write that failed or has not happened leaves the file
    /// as it was, which changes nothing. Returns whether the file holds a known save.
    @discardableResult
    func confirmSave() -> Bool {
        confirmLock.lock()
        defer { confirmLock.unlock() }
        pendingLock.lock()
        let candidates = pendingSaves.filter { $0.bytes != nil }
        let baseline = confirmedBytes
        pendingLock.unlock()
        guard let url = fileURL, !candidates.isEmpty || baseline != nil else { return false }
        var sizes = Set(candidates.compactMap { $0.bytes?.count })
        if let baseline { sizes.insert(baseline.count) }
        guard let onDisk = Self.regularFileDigest(at: url, ofSizes: sizes) else {
            markSavedStateUnknown()   // gone, unreadable, changing, or a size nothing we saved had
            return false
        }
        if let match = candidates.last(where: { $0.bytes?.count == onDisk.count && $0.bytes?.digest == onDisk.digest }) {
            pendingLock.lock()
            confirmedBytes = onDisk
            savedStateUnknown = false
            pendingLock.unlock()
            lastSavedProject = match.project
            return true
        }
        if let baseline, baseline.count == onDisk.count, baseline.digest == onDisk.digest {
            pendingLock.lock()
            savedStateUnknown = false        // still exactly the project last seen saved
            pendingLock.unlock()
            return true
        }
        markSavedStateUnknown()
        return false
    }

    private func markSavedStateUnknown() {
        pendingLock.lock()
        savedStateUnknown = true
        pendingLock.unlock()
    }

    /// Size and SHA-256 of the file at `url`, read in chunks, or nil unless it is a regular file of one of
    /// `sizes` bytes that was read to its end without error and without changing length. A file of any other
    /// size is not read at all, and a pipe or device put in the file's place is not waited on (`O_NONBLOCK` opens
    /// a pipe at once; it is then refused for not being a regular file).
    static func regularFileDigest(at url: URL, ofSizes sizes: Set<Int>) -> (count: Int, digest: SHA256Digest)? {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, sizes.contains(Int(info.st_size)) else { return nil }
        var hasher = SHA256()
        var count = 0
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
                count += chunk.count
            }
        } catch {
            return nil
        }
        guard count == Int(info.st_size) else { return nil }
        // The path must still name the file that was read, unchanged: a replacement or rewrite while hashing is no
        // observation of either version.
        var after = stat()
        guard stat(url.path, &after) == 0, after.st_dev == info.st_dev, after.st_ino == info.st_ino,
              after.st_size == info.st_size, after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else { return nil }
        return (count, hasher.finalize())
    }

    // MARK: Undoable edits

    /// Applies `change` to a copy of the project; registers undo only if something changed.
    func perform(_ actionName: String, _ change: (inout LoftLineProject) -> Void) {
        var p = project
        change(&p)
        VariableLinks.reconcile(&p, old: project, pending: expressionRecorder.take())
        // Keep the post and machine copies what the (possibly changed) selection means: a picked post, a machine that
        // switches the post, a unit conversion and a template all end up with the right copy without knowing about it.
        p = ProjectPost.syncing(p, profiles: postCatalog.profiles, machines: machineCatalog.machines)
        p = ToolSync.carrying(p, library: toolLibrary.library)
        guard p != project else { return }
        replaceProject(p, actionName: actionName)
    }

    /// A Tool Database edit reaching this project: a carried tool that was in step with the library follows the edit, as
    /// one undoable step ("Update Tool from Library"); a difference that already existed is left for the warning.
    private func libraryChanged(to lib: ToolLibrary) {
        let old = lastLibrary
        lastLibrary = lib
        // `lib` is passed on rather than read back: this runs while the library is changing, and a tool the project
        // lacked may now be available.
        perform("Update Tool from Library") { p in
            p = ToolSync.applyingLibraryChange(old: old, new: lib, to: p)
            p = ToolSync.carrying(p, library: lib)
        }
    }

    /// True when a tool the project carried before is carried now with a change that can alter its toolpaths (anything
    /// but the name, notes and folder, which only label a tool: `Tool.cutsSameToolpaths`). Calculated toolpaths are then
    /// stale. A tool that was only added (a new operation's) or dropped does not touch the others; a rename reaches the
    /// calculated toolpaths by `showToolNames` without recalculating.
    private static func toolContentChanged(from old: [Tool], to new: [Tool]) -> Bool {
        old.contains { t in new.first { $0.id == t.id }.map { !$0.cutsSameToolpaths(as: t) } ?? false }
    }

    /// Job Setup > Update This Project: each post and machine copy is replaced with the installed one of the same id
    /// (a copy with no installed counterpart is kept). One undo step.
    func updateProjectFromInstalled() {
        perform("Update Post") {
            $0 = ToolSync.updated(ProjectPost.updated($0, profiles: postCatalog.profiles, machines: machineCatalog.machines),
                                  library: toolLibrary.library)
        }
    }

    private func replaceProject(_ new: LoftLineProject, actionName: String) {
        editSerial += 1
        outputSerial += 1
        let old = project
        if old.document != new.document || Self.toolContentChanged(from: old.tools, to: new.tools) { designRevision += 1 }
        project = new
        if old.tools != new.tools { showToolNames(of: mergedLibrary) }   // names in the results follow the carried tools
        undoManager?.registerUndo(withTarget: self) { doc in doc.replaceProject(old, actionName: actionName) }
        undoManager?.setActionName(actionName)
        pruneState()
    }

    private func pruneState() {
        let ids = Set(project.document.shapes.map(\.id))
        if !selection.isSubset(of: ids) { setSelection(selectionOrder.filter(ids.contains)) }
        let nodes = project.validNodes(nodeSelection)
        if nodes != nodeSelection { nodeSelection = nodes }
        let opIDs = Set(project.operations.map(\.id))
        if let sel = selectedOperationID, !opIDs.contains(sel) { selectedOperationID = nil }
        if let t = tabEditingOperationID, operation(t)?.profileTabs == nil { tabEditingOperationID = nil }
        results = results.filter { opIDs.contains($0.key) }
    }

    // MARK: Derived

    var document: Document { project.document }
    var units: LengthUnit { project.document.units }
    var mergedLibrary: ToolLibrary { project.mergedTools(with: toolLibrary.library) }

    /// The post and machine this job posts with: the copies the project carries while they are still what it selects,
    /// else the installed ones (`ProjectPost`).
    var resolvedPost: ProjectPost.Resolved {
        ProjectPost.resolve(project, profiles: postCatalog.profiles, machines: machineCatalog.machines)
    }

    /// The post profile with the job's machine limits applied (what validation and export use).
    var postProfile: PostProfile { resolvedPost.post }

    /// The machine this job is set up for (nil = a custom post with its own limits).
    var machine: MachineDefinition? { resolvedPost.machine }

    /// An error when the project's post is neither carried nor installed (`postProfile` then falls back to the
    /// default, which may be a different dialect and machine), and a warning for each copy that differs from the
    /// installed post or machine of the same id.
    var postProfileIssues: [GCodeIssue] { postProfileIssues(includingPost: true) }

    /// The same, for a sheet that posts with another post than the project's own: the project's own post's notices (its
    /// copy differing, or not being installed) do not apply to that program, so they are left out; the machine's and the
    /// tools' stay.
    func postProfileIssues(includingPost: Bool) -> [GCodeIssue] {
        ProjectPost.issues(for: project, profiles: postCatalog.profiles, machines: machineCatalog.machines,
                           includingPost: includingPost)
            + ToolSync.issues(for: project, library: toolLibrary.library)
    }

    /// The project's own post when it is carried but not installed on this Mac, so a post picker can still list it.
    var carriedPostNotInstalled: PostProfile? {
        let r = resolvedPost
        return r.postSource == .projectCopy && !r.postInstalledHere ? r.post : nil
    }

    /// What Job Setup says about the project's copies.
    var copyNotice: ProjectPost.Notice {
        var notice = ProjectPost.notice(for: project, profiles: postCatalog.profiles, machines: machineCatalog.machines)
        notice.warnings += ToolSync.issues(for: project, library: toolLibrary.library).map(\.message)
        return notice
    }

    /// True when a copy the project carries differs from the installed one (Job Setup then offers Update This Project).
    var hasCopyDifferences: Bool {
        let r = resolvedPost
        return r.postCopyDiffers != nil || r.machineCopyDiffers != nil
            || !ToolSync.differences(project, library: toolLibrary.library).isEmpty
    }

    /// Post `id` with this job's machine limits applied; the project's own post when `id` is the one it selects.
    func effectiveProfile(id: String?) -> PostProfile {
        if let id, id == ProjectPost.effectivePostID(project) { return postProfile }
        return MachineResolver.effectiveProfile(postCatalog.profile(id: id), machine: machine)
    }

    /// Profile rapid rate converted to document units per minute.
    var rapidRateInDocumentUnits: Double {
        postProfile.rapidRate * postProfile.units.factor(to: units)
    }

    func operation(_ id: UUID?) -> AnyOperation? {
        guard let id else { return nil }
        return project.operations.first { $0.id == id }
    }

    var selectedShapes: [Shape] { project.document.shapes(ids: selectionOrder) }

    // MARK: Selection

    func setSelection(_ ids: [UUID]) {
        var seen = Set<UUID>()
        selectionOrder = ids.filter { seen.insert($0).inserted }
        selection = Set(selectionOrder)
    }

    /// Selects a shape (and its group mates). Extending toggles the whole group.
    func select(_ id: UUID, extending: Bool) {
        let members = project.document.expandToGroups([id])
        if extending {
            if selection.contains(id) {
                let drop = Set(members)
                setSelection(selectionOrder.filter { !drop.contains($0) })
            } else {
                setSelection(selectionOrder + members)
            }
        } else {
            setSelection(members)
        }
    }

    func addToSelection(_ ids: [UUID]) { setSelection(selectionOrder + project.document.expandToGroups(ids)) }

    func selectAll() {
        setSelection(project.document.shapes.filter { project.isEditable($0) && isOnActiveSide($0) }.map(\.id))
    }

    func clearSelection() { setSelection([]) }

    // MARK: Shape edits

    func addShape(_ shape: Shape, actionName: String) {
        var s = shape
        if project.document.layer(id: s.layerID) == nil { s.layerID = currentLayerID }
        perform(actionName) { $0.document.add(s) }
        setSelection([s.id])
    }

    /// Layer new shapes go to: the layer of the primary selection, else the first unlocked visible one.
    var currentLayerID: UUID {
        if let first = selectedShapes.first { return first.layerID }
        let onSide = currentSheetLayers.filter { !isTwoSided || ($0.side ?? .top) == activeSide }
        return onSide.first { $0.isVisible && !$0.isLocked }?.id ?? onSide.first?.id ?? project.document.defaultLayerID
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        let ids = selection
        perform(ids.count == 1 ? "Delete Shape" : "Delete Shapes") { $0.deleteShapes(ids) }
    }

    func translateSelection(by d: Vec2, actionName: String = "Move") {
        guard !selection.isEmpty, d != .zero else { return }
        let ids = selection
        perform(actionName) { $0.transformShapes(ids, by: .translation(d)) }
    }

    func duplicateSelection() {
        guard !selection.isEmpty else { return }
        let shapes = selectedShapes
        var newIDs: [UUID] = []
        let g = project.document.gridSpacing, layer = currentLayerID
        perform("Duplicate") { newIDs = $0.paste(shapes, offset: Vec2(g, -g), fallbackLayer: layer) }
        setSelection(newIDs)
    }

    /// Pastes clipboard shapes (offset when the originals are still in the document).
    func pasteShapes(_ shapes: [Shape]) {
        guard !shapes.isEmpty else { return }
        let offset = ShapeClipboard.pasteOffset(for: shapes, existing: Set(project.document.shapes.map(\.id)),
                                                grid: project.document.gridSpacing)
        var newIDs: [UUID] = []
        let layer = currentLayerID
        perform("Paste") { newIDs = $0.paste(shapes, offset: offset, fallbackLayer: layer) }
        setSelection(newIDs)
    }

    func groupSelection() {
        let order = selectionOrder
        perform("Group") { _ = DesignCommands.group(order, in: &$0) }
    }

    func ungroupSelection() {
        let order = selectionOrder
        perform("Ungroup") { DesignCommands.ungroup(order, in: &$0) }
    }

    /// Applies `change` to the whole selection as one undoable step.
    func editSelection(_ actionName: String, _ change: @escaping (Set<UUID>, inout LoftLineProject) -> Void) {
        guard !selection.isEmpty else { return }
        let ids = selection
        perform(actionName) { change(ids, &$0) }
    }

    func transformSelection(by t: Transform2D, actionName: String) {
        editSelection(actionName) { ids, p in p.transformShapes(ids, by: t) }
    }

    // MARK: Node edits

    func moveSelectedNodes(by d: Vec2) {
        guard !nodeSelection.isEmpty, d != .zero else { return }
        let refs = nodeSelection, mirror = drawingOptions.nodeMirror
        perform("Move Nodes") { $0.moveNodes(refs, by: d, mirror: mirror) }
    }

    func deleteSelectedNodes() {
        guard !nodeSelection.isEmpty else { return }
        let refs = nodeSelection
        perform("Delete Nodes") { $0.deleteNodes(refs) }
        nodeSelection = []
    }

    func setSelectedNodes(smooth: Bool) {
        let refs = nodeSelection
        perform(smooth ? "Smooth Nodes" : "Corner Nodes") { $0.setNodes(refs, smooth: smooth) }
    }

    func convertSegmentsAfterSelectedNodes(toCurve: Bool) {
        let refs = nodeSelection
        perform(toCurve ? "Convert to Curve" : "Convert to Line") { $0.convertSegments(after: refs, toCurve: toCurve) }
    }

    func insertNodesAfterSelection() {
        let refs = nodeSelection
        var new: Set<NodeRef> = []
        perform("Insert Nodes") { new = $0.insertNodesAfter(refs) }
        nodeSelection = new
    }

    func breakAtSelectedNode() {
        guard nodeSelection.count == 1, let r = nodeSelection.first else { return }
        perform("Break Path") { _ = $0.editNodes(of: r.shapeID) { ShapeNodes.breakAt($0, r) } }
        nodeSelection = []
    }

    /// Replaces one shape (node drags, handle drags, inserts on the canvas).
    func replaceShape(_ shape: Shape, actionName: String) {
        perform(actionName) { p in p.editNodes(of: shape.id) { _ in shape } }
    }

    // MARK: Operations

    func addOperation(_ kind: OperationKind) {
        if kind == .inlay { sheet = .inlayWizard; return }
        if kind == .straightInlay { addStraightInlayPair(); return }
        guard let op = OperationFactory.make(kind: kind, project: project, library: mergedLibrary,
                                             shapeIDs: selectionOrder) else {
            report(AlertMessage(title: "No 3D model",
                                 message: "Import an STL model (File > Import) before adding a 3D toolpath."))
            return
        }
        perform("New \(kind.displayName) Toolpath") { $0.upsertOperation(op) }
        sidebarTab = .toolpaths
        selectedOperationID = op.id
    }

    func updateOperation(_ op: AnyOperation) {
        perform("Edit Toolpath") { $0.upsertOperation(op) }
    }

    /// Live edit from the toolpath editor: committed immediately so Calculate All, export and
    /// save always see what the form shows. Consecutive edits of the same operation, with no
    /// other change (or save) in between, merge into one "Edit Toolpath" undo step.
    func updateOperationLive(_ op: AnyOperation) {
        guard operation(op.id) != nil else { return }  // deleted meanwhile: never resurrect it
        if let live = liveOperationEdit, live.id == op.id, live.serial == editSerial {
            var p = project
            p.upsertOperation(op)
            VariableLinks.reconcile(&p, old: project, pending: expressionRecorder.take())
            p = ToolSync.carrying(p, library: toolLibrary.library)
            guard p != project else { return }
            if Self.toolContentChanged(from: project.tools, to: p.tools) { designRevision += 1 }
            project = p  // the open undo step already restores the state before the first edit
            outputSerial += 1
            return
        }
        perform("Edit Toolpath") { $0.upsertOperation(op) }
        liveOperationEdit = (op.id, editSerial)
    }

    /// Adds several operations as one undo step and selects the first.
    func addOperations(_ ops: [AnyOperation], actionName: String) {
        guard let first = ops.first else { return }
        perform(actionName) { p in ops.forEach { p.upsertOperation($0) } }
        sidebarTab = .toolpaths
        selectedOperationID = first.id
    }

    /// Inlay wizard: female pocket + male plug toolpaths.
    func addInlay(_ wizard: InlayWizardModel) {
        addOperations(wizard.makeOperations(), actionName: "New Inlay Toolpaths")
    }

    /// Replaces the tab settings of a Profile operation (one undo step).
    func setProfileTabs(_ tabs: TabSettings, for id: UUID, actionName: String = "Edit Tabs") {
        guard let op = operation(id), op.profileTabs != nil else { return }
        let new = op.withProfileTabs(tabs)
        perform(actionName) { $0.upsertOperation(new) }
    }

    // MARK: 3D models

    /// Adds (or updates) a placed model and creates the form's Roughing/Finishing toolpaths.
    func applyPlacement(_ form: ModelPlacementForm) {
        let model = form.placedModel
        let ops = form.makeOperations(existing: project.operations, units: units)
        let isNew = project.document.model(id: model.id) == nil
        perform(isNew ? "Place 3D Model" : "Edit 3D Model") { p in
            if let i = p.document.models.firstIndex(where: { $0.id == model.id }) {
                p.document.models[i] = model
            } else {
                p.document.models.append(model)
            }
            ops.forEach { p.upsertOperation($0) }
        }
        if let first = ops.first {
            sidebarTab = .toolpaths
            selectedOperationID = first.id
        }
    }

    /// Shows the next queued placement dialog (after an STL import).
    func showNextPlacement() {
        guard sheet == nil, !pendingPlacements.isEmpty else { return }
        sheet = .placeModel(pendingPlacements.removeFirst())
    }

    /// Shows the next SVG whose scale the file does not state.
    func showNextScaleRequest() {
        guard sheet == nil, !pendingScales.isEmpty else { return }
        sheet = .io(.svgScale(pendingScales.removeFirst()))
    }

    func editPlacement(of modelID: UUID) {
        guard let m = project.document.model(id: modelID) else { return }
        sheet = .placeModel(ModelPlacementForm(editing: m, job: project.document.job, library: mergedLibrary))
    }

    func deleteOperation(_ id: UUID) {
        perform("Delete Toolpath") { $0.deleteOperation(id) }
    }

    func duplicateOperation(_ id: UUID) {
        guard var op = operation(id) else { return }
        var s = op.editableSetup
        s.id = UUID()
        s.name = OperationFactory.defaultName(for: op.kind, existing: project.operations)
        op.editableSetup = s
        let copy = op
        perform("Duplicate Toolpath") { $0.operations.append(copy) }
        selectedOperationID = copy.id
    }

    func setOperationEnabled(_ id: UUID, _ enabled: Bool) {
        guard var op = operation(id) else { return }
        var s = op.editableSetup
        s.isEnabled = enabled
        op.editableSetup = s
        let o = op
        perform(enabled ? "Enable Toolpath" : "Disable Toolpath") { $0.upsertOperation(o) }
    }

    func toggleToolpathVisibility(_ id: UUID) {
        if hiddenToolpaths.contains(id) { hiddenToolpaths.remove(id) } else { hiddenToolpaths.insert(id) }
    }

    /// What a program posted from this document is made from. An export sheet keeps the value it posted
    /// with and posts again when the document's differs: an edit or an undo, a design or Tool Database
    /// change (the Tool Database is a window of its own, open while a sheet is), or a toolpath result that
    /// was stored or took a renamed tool.
    struct PostedInputs: Equatable {
        var serial = 0, design = 0
        var side: JobSide = .top
        /// What a sheet posts with besides the document: the post processor in force (reloading the catalog, or a
        /// machine, changes it) and the app-wide group-by-tool preference, which sets the order. A sheet stamps
        /// them on with `stamped(profile:groupedByTool:)`.
        var profile: PostProfile?
        var groupedByTool = false

        func stamped(profile: PostProfile, groupedByTool: Bool = false) -> PostedInputs {
            var copy = self
            copy.profile = profile
            copy.groupedByTool = groupedByTool
            return copy
        }

        /// Shown by a sheet that would not write a program posted before the document changed: the save panel is
        /// document-modal, the Tool Database window is not, so an edit can land while the panel is up.
        static let changedWhileSaving = "The job changed while you were choosing where to save, so the program was posted again. Save once more."
    }

    var postedInputs: PostedInputs { PostedInputs(serial: outputSerial, design: designRevision, side: activeSide) }

    /// True when the operation has no result or was edited after its last calculation.
    func isStale(_ id: UUID) -> Bool {
        guard let r = results[id], let op = operation(id) else { return true }
        // The pause is applied when the program is posted, so editing it leaves the result valid.
        return r.operation.withoutPause != op.withoutPause || r.designRevision != designRevision
    }

    /// Generates toolpaths off the main thread; results arrive asynchronously. A request for an
    /// operation that is already calculating is queued and runs when the current one finishes.
    func calculate(_ ids: [UUID]) {
        let snapshot = project, library = toolLibrary.library, rev = designRevision
        let rapid = rapidRateInDocumentUnits
        for id in ids {
            guard let op = operation(id) else { continue }
            if calculating.contains(id) { pendingRecalculation.insert(id); continue }
            calculating.insert(id)
            let generation = nextGeneration()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let r = ToolpathCalculator.calculate(op, project: snapshot, library: library, designRevision: rev,
                                                     rapidRate: rapid)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.calculating.remove(id)
                    self.store(r, for: id, generation: generation)
                    if self.pendingRecalculation.remove(id) != nil { self.calculate([id]) }
                }
            }
        }
    }

    func calculateAll() { calculate(project.operations.filter(\.setup.isEnabled).map(\.id)) }

    /// Calculates synchronously (tests and small jobs). The UI uses `calculateAndWait`.
    func calculateNow(_ ids: [UUID]) {
        for id in ids {
            guard let op = operation(id) else { continue }
            let generation = nextGeneration()
            let r = ToolpathCalculator.calculate(op, project: project, library: toolLibrary.library,
                                                 designRevision: designRevision, rapidRate: rapidRateInDocumentUnits)
            store(r, for: id, generation: generation)
        }
    }

    /// Calculates `ids` on a background queue and returns when all results are stored. Returns
    /// false when the calling task was cancelled (results finished so far are still kept).
    @MainActor
    func calculateAndWait(_ ids: [UUID]) async -> Bool {
        let snapshot = project, library = toolLibrary.library, rev = designRevision
        let rapid = rapidRateInDocumentUnits
        let jobs = ids.compactMap { id in operation(id).map { (id, $0, nextGeneration()) } }
        let flag = CancellationFlag()
        let finished: [(UUID, ToolpathResult, Int)] = await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    var out: [(UUID, ToolpathResult, Int)] = []
                    for (id, op, g) in jobs {
                        if flag.isCancelled { break }
                        out.append((id, ToolpathCalculator.calculate(op, project: snapshot, library: library,
                                                                     designRevision: rev, rapidRate: rapid), g))
                    }
                    cont.resume(returning: out)
                }
            }
        } onCancel: {
            flag.cancel()
        }
        for (id, r, g) in finished { store(r, for: id, generation: g) }
        return !Task.isCancelled && finished.count == jobs.count
    }

    /// Calculates what is stale among `targets` until none of them is, so a program is never posted from a toolpath
    /// computed before a later change: a result that lands after an edit (a Tool Database edit, a setting) carries the
    /// old `designRevision`, is stale on arrival, and is calculated again. Which targets are stale is re-evaluated before
    /// every pass, since a change can make toolpaths stale that were fresh when the export began; at most five passes.
    /// True only when nothing in `targets` is stale; false when the calling task was cancelled or the project kept
    /// changing. A target deleted meanwhile is left out. `afterPass` runs after each pass (tests change the project there).
    @MainActor
    func calculateUntilFresh(targets: [UUID], afterPass: () -> Void = {}) async -> Bool {
        func stale() -> [UUID] { targets.filter { operation($0) != nil && isStale($0) } }
        for _ in 0..<5 {
            let pending = stale()
            if pending.isEmpty { return true }
            guard await calculateAndWait(pending) else { return false }
            afterPass()
        }
        return stale().isEmpty
    }

    private func nextGeneration() -> Int {
        generationCounter += 1
        return generationCounter
    }

    /// Stores a result unless a newer calculation of the same operation already landed.
    private func store(_ r: ToolpathResult, for id: UUID, generation: Int) {
        guard operation(id) != nil, generation > resultGeneration[id] ?? 0 else { return }
        results[id] = r.renamingTools(from: mergedLibrary) ?? r
        resultGeneration[id] = generation
        outputSerial += 1
    }

    /// A rename in the Tool Database does not make toolpaths stale (the name is a label), so the
    /// calculated toolpaths, which carry a copy of their tool, take the new name in place. The
    /// program comments, the job sheet and the checks then read the current name.
    private func showToolNames(of library: ToolLibrary) {
        for (id, r) in results {
            if let renamed = r.renamingTools(from: library) { results[id] = renamed; outputSerial += 1 }
        }
    }

    var totalEstimatedSeconds: TimeInterval {
        project.operations.filter(\.setup.isEnabled).compactMap { results[$0.id]?.estimatedSeconds }.reduce(0, +)
    }

    func setPostProfile(_ id: String) {
        perform("Change Post Processor") { $0.postProfileID = id }
    }

    /// Picks the machine (and its default post if the current post does not drive it).
    func setMachine(_ id: String) {
        guard let m = machineCatalog.machine(id: id) else { return }
        let profiles = postCatalog.profiles
        perform("Change Machine") { MachineResolver.select(machine: m, in: &$0, profiles: profiles) }
    }

    // MARK: Job setup

    func applyJobSetup(_ form: JobSetupForm) {
        perform("Job Setup") { $0 = form.apply(to: $0) }
        if !isTwoSided { activeSide = .top }
        requestCanvas(.fit)
    }

    /// Makes sure the 2D canvas is on screen (keeps the side-by-side view if it is showing).
    func showDesignCanvas() {
        if !centerMode.showsDesign { centerMode = .design2D }
    }

    func requestCanvas(_ kind: CanvasRequest.Kind) {
        canvasRequest = CanvasRequest(kind: kind, serial: canvasRequest.serial + 1)
    }

    // MARK: Import / export

    func importFiles(_ urls: [URL]) {
        var messages: [String] = []
        var newShapes: [UUID] = []
        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                if ImportService.isMesh(url.lastPathComponent) {
                    pendingPlacements.append(try ImportService.placementForm(
                        data: data, fileName: url.lastPathComponent, project: project, library: mergedLibrary))
                    continue
                }
                // An SVG that does not say how big it is waits for the user to confirm the scale.
                if let ask = ImportService.scaleRequest(data: data, fileName: url.lastPathComponent, units: units) {
                    pendingScales.append(ask)
                    continue
                }
                let outcome = try commitImport(data: data, fileName: url.lastPathComponent)
                newShapes += outcome.shapeIDs
                if !outcome.imageIDs.isEmpty && outcome.shapeIDs.isEmpty { requestCanvas(.fit) }
                messages += outcome.warnings.map { "\(url.lastPathComponent): \($0)" }
            } catch {
                messages.append("\(url.lastPathComponent): \(ImportService.describe(error))")
            }
        }
        if !newShapes.isEmpty { setSelection(newShapes); sidebarTab = .design; requestCanvas(.fit) }
        let message = messages.isEmpty ? nil : AlertMessage(title: "Import", message: messages.joined(separator: "\n"))
        if pendingPlacements.isEmpty && pendingScales.isEmpty {
            if let message { report(message) }
        } else {
            // A sheet and an alert cannot show together: report after the placement and scale dialogs.
            hold(message)
            showDesignCanvas()
            showNextPlacement()
            showNextScaleRequest()
        }
    }

    /// Imports one file as one undo step. `svgPixelsPerInch` is the scale the user confirmed for an SVG with no
    /// physical size (nil: the importer guesses).
    func commitImport(data: Data, fileName: String, svgPixelsPerInch: Double? = nil) throws -> ImportOutcome {
        var p = project
        let outcome = try ImportService.importFile(data: data, fileName: fileName, into: &p, svgPixelsPerInch: svgPixelsPerInch)
        let imported = p
        perform("Import \(fileName)") { $0 = imported }
        return outcome
    }

    /// A sheet attached to the window by AppKit, which `sheet` does not know about (the gadget run dialog): while it
    /// is open a report waits for it, like one under a SwiftUI sheet.
    var platformSheetOpen = false

    /// Reports a result to the user: at once, or after the open sheet closes (`sheetDismissed()` shows
    /// it), because an alert cannot show over a sheet. Every message for the user goes through here: a command
    /// that can run while a sheet is up (a menu item, a dialog's own action) never sets `alert` itself.
    func report(_ message: AlertMessage) {
        if sheet == nil && !platformSheetOpen { alert = message } else { hold(message) }
    }

    /// Keeps a report for `sheetDismissed()`. Reports held together are joined, each under its own
    /// title after the first, so none is lost.
    func hold(_ message: AlertMessage?) {
        guard let message else { return }
        if var held = deferredAlert {
            held.message += "\n\n\(message.title): \(message.message)"
            deferredAlert = held
        } else {
            deferredAlert = message
        }
    }

    /// Called when any sheet closes. Expressions typed into a sheet but never applied are dropped
    /// (an applied sheet consumed them in its edit; the Job Setup sheet also drops them when it
    /// opens), so they cannot latch onto whatever parameter next takes their value. Then the next
    /// queued placement, then any deferred import report.
    func sheetDismissed() {
        _ = expressionRecorder.take()
        if !pendingPlacements.isEmpty {
            showNextPlacement()
        } else if !pendingScales.isEmpty {
            showNextScaleRequest()
        } else if sheet == nil, !platformSheetOpen, let a = deferredAlert {
            // Only when no sheet of either kind is up: closing one of two leaves the report waiting for the other.
            deferredAlert = nil
            alert = a
        }
    }

    func exportVectors(to url: URL, selectionOnly: Bool) {
        let ext = url.pathExtension.lowercased()
        let shapes = selectionOnly && !selection.isEmpty ? selectedShapes : project.document.shapes
        do {
            guard let exporter = FileFormats.exporter(forExtension: ext) else { throw LoftLineIOError.unsupportedFormat(ext) }
            let data = try exporter.export(shapes: shapes, layers: project.document.layers, units: units)
            try data.write(to: url, options: .atomic)
        } catch {
            report(AlertMessage(title: "Export failed", message: ImportService.describe(error)))
        }
    }
}

/// App-wide list of post profiles (built-ins + user JSON). Loaded once; `reload()` re-reads.
final class PostProfileCatalog: ObservableObject {
    static let shared = PostProfileCatalog()
    @Published private(set) var profiles: [PostProfile]
    let store: PostProfileStore

    init(store: PostProfileStore = PostProfileStore()) {
        self.store = store
        profiles = store.allProfiles()
    }

    func reload() { profiles = store.allProfiles() }

    func profile(id: String?) -> PostProfile {
        profiles.first { $0.id == id } ?? profiles.first { $0.id == PostProfileStore.defaultProfileID }
            ?? BuiltInPosts.avidMach4Inch
    }
}

/// Thread-safe cancel flag shared with a background calculation.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
