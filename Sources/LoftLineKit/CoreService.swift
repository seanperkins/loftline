import CADCore
import CAMCore
import Foundation
import PostCore

/// The JSON protocol of `loftline-core`. Each request is one line: `{"id": 1, "method": "open", "params": {…}}`; each reply is one
/// line: `{"id": 1, "result": …}` or `{"id": 1, "error": "…"}`. A malformed request gets an error reply and never ends the process.
public final class CoreService {
    public let session: CoreSession
    private var simulation: CoreSimulation?

    /// Where Help > Connect an AI Assistant… keeps the allowed folders (tests point it elsewhere).
    public var assistantSettingsURL = AssistantSettings.fileURL

    public init(session: CoreSession = CoreSession()) { self.session = session }

    /// The live link, when the desktop engine hosts one (spec 2).
    public weak var assistantLink: CoreAssistantLink?

    private struct Envelope: Decodable {
        var id: Int?
        var method: String
        /// The `changeRevision` the front end's view was built from, on every request that changes something.
        var rev: Int?
    }

    private struct Wrapped<P: Decodable>: Decodable { var params: P }
    private struct Reply<R: Encodable>: Encodable { var id: Int?; var result: R }
    private struct Failure: Encodable { var id: Int?; var error: String; var code: String? }
    struct Nothing: Codable {}
    public struct UnknownMethod: LocalizedError {
        var method: String
        public var errorDescription: String? { "Unknown method \"\(method)\"." }
    }

    public func handle(_ line: Data) -> Data {
        var id: Int?
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: line)
            id = envelope.id
            // A change built on a view older than the project (an assistant changed it since): refused, so the front end refetches.
            if let rev = envelope.rev, rev < session.changeRevision {
                return (try? JSONEncoder().encode(Failure(id: id, error: "The assistant changed this; make your change again.", code: "stale")))
                    ?? encodeFailure(id: id, message: "stale")
            }
            return try dispatch(envelope.method, line: line, id: envelope.id)
        } catch {
            return encodeFailure(id: id, message: Self.describe(error))
        }
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? LocalizedError, let text = e.errorDescription { return text }
        return "\(error)"
    }

    private func encodeFailure(id: Int?, message: String) -> Data {
        (try? JSONEncoder().encode(Failure(id: id, error: message))) ?? Data(#"{"error":"could not encode the error"}"#.utf8)
    }

    private func params<P: Decodable>(_ line: Data, _ type: P.Type = P.self) throws -> P {
        try JSONDecoder().decode(Wrapped<P>.self, from: line).params
    }

    private func reply<R: Encodable>(_ id: Int?, _ value: R) throws -> Data {
        try JSONEncoder().encode(Reply(id: id, result: value))
    }

    // MARK: Replies

    /// What the front end needs after any change.
    struct State: Encodable {
        var project: LoftLineProject
        var path: String?
        var title: String
        var isDirty: Bool
        var undoAction: String?
        var redoAction: String?
        var designRevision: Int
        var post: PostSummary
        var machine: String?
        /// The side on show of a two-sided job, and what a program covers when it isn't the whole job.
        var side: JobSide
        var coverage: String?
        var statuses: [OperationStatus]
        var issues: [IssueRow]
        var job: JobTotals
        var changeRevision: Int
        var assistant: AssistantStatus
    }

    /// The sidebar's totals, the same numbers as the Mac's: the job summary times the program as the 3D preview does.
    struct JobTotals: Encodable {
        var hasEstimate: Bool
        var totalSeconds: Double
        var duration: String
        var toolLoads: Int
        var toolChanges: Int
        var sequence: [String]
    }

    private let jobMemo = JobSummary.Memo()

    private func jobTotals() -> JobTotals {
        let s = session
        let groupByTool = UserDefaults.standard.bool(forKey: GCodeExporter.groupByToolKey)
        let summary = jobMemo.summary(operations: s.project.operations, results: s.results, groupByTool: groupByTool,
                                      settings: TimeEstimateSettings.load(), rapidRate: s.rapidRate, units: s.project.document.units)
        return JobTotals(hasEstimate: summary.hasEstimate, totalSeconds: summary.totalSeconds,
                         duration: ToolpathCalculator.formatDuration(summary.totalSeconds),
                         toolLoads: summary.sequence.count, toolChanges: summary.toolChanges,
                         sequence: summary.sequence.map { "T\($0.number) · \($0.name)" })
    }

    struct PostSummary: Encodable {
        var id: String
        var name: String
        var fileExtension: String
    }

    struct OperationStatus: Encodable {
        var id: UUID
        var isStale: Bool
        var isCalculated: Bool
        var error: String?
        var toolpathCount: Int
        var moveCount: Int
        var seconds: Double
        var duration: String
        var metadata: [String: String]
    }

    struct IssueRow: Encodable {
        var severity: String
        var line: Int?
        var message: String
    }

    private func state(extraIssues: [GCodeIssue] = []) -> State {
        let s = session
        let resolved = s.resolved
        return State(project: s.project, path: s.fileURL?.path,
                     title: s.project.document.name.isEmpty ? (s.fileURL?.lastPathComponent ?? "Untitled") : s.project.document.name,
                     isDirty: s.isDirty, undoAction: s.undoAction, redoAction: s.redoAction, designRevision: s.designRevision,
                     post: PostSummary(id: resolved.post.id, name: resolved.post.name,
                                       fileExtension: GCodeExporter.fileExtension(for: resolved.post)),
                     machine: resolved.machine?.name, side: s.activeSide, coverage: s.coverage, statuses: statuses(),
                     issues: (ProjectPost.issues(for: s.project, profiles: s.profiles, machines: s.machines) + extraIssues).map(Self.row),
                     job: jobTotals(), changeRevision: s.changeRevision, assistant: assistantStatus())
    }

    func assistantStatus() -> AssistantStatus {
        assistantLink?.status(changeRevision: session.changeRevision) ?? AssistantStatus(changeRevision: session.changeRevision)
    }

    private static func row(_ issue: GCodeIssue) -> IssueRow {
        IssueRow(severity: issue.severity.rawValue, line: issue.line, message: issue.message)
    }

    private func statuses() -> [OperationStatus] {
        session.project.operations.map { op in
            let r = session.results[op.id]
            let metadata = r?.toolpaths.reduce(into: [String: String]()) { all, tp in all.merge(tp.metadata) { a, _ in a } } ?? [:]
            return OperationStatus(id: op.id, isStale: session.isStale(op.id), isCalculated: r != nil, error: r?.error,
                                   toolpathCount: r?.toolpaths.count ?? 0, moveCount: r?.toolpaths.reduce(0) { $0 + $1.moves.count } ?? 0,
                                   seconds: r?.estimatedSeconds ?? 0, duration: ToolpathCalculator.formatDuration(r?.estimatedSeconds ?? 0),
                                   metadata: metadata)
        }
    }

    // MARK: Parameters

    struct PathParam: Decodable { var path: String }
    struct IDs: Decodable { var ids: [UUID]? }
    struct OneID: Decodable { var id: UUID }
    struct AddShape: Decodable { var tool: String; var from: Vec2; var to: Vec2; var options: ShapeOptions? }
    struct ShapeOptions: Decodable { var cornerRadius: Double?; var polygonSides: Int?; var starPoints: Int?; var starInnerRatio: Double?; var constrain: Bool? }
    struct AddPolyline: Decodable { var points: [Vec2]; var closeTolerance: Double? }
    struct AddText: Decodable { var spec: TextSpec }
    struct ReplaceShape: Decodable { var shape: Shape }
    struct Transform: Decodable { var ids: [UUID]; var transform: Transform2D; var action: String? }
    struct Translate: Decodable { var ids: [UUID]; var by: Vec2 }
    struct MoveToLayer: Decodable { var ids: [UUID]; var layer: UUID }
    struct LayerName: Decodable { var name: String? }
    struct LayerParam: Decodable { var layer: Layer }
    struct Job: Decodable { var units: LengthUnit; var job: JobSetup; var gridSpacing: Double?; var name: String?; var machineID: String?; var postID: String? }
    struct AddOperation: Decodable { var kind: String; var shapeIDs: [UUID] }
    struct UpdateOperation: Decodable { var operation: AnyOperation }
    struct MoveOperation: Decodable { var id: UUID; var delta: Int }
    struct Enable: Decodable { var id: UUID; var enabled: Bool }
    struct Export: Decodable { var operation: UUID?; var postID: String?; var side: JobSide?; var groupByTool: Bool?; var path: String?; var force: Bool? }
    struct LinesParam: Decodable { var ids: [UUID]? }
    struct SimSeek: Decodable { var time: Double; var maxVertices: Int? }
    struct SimStart: Decodable { var groupByTool: Bool?; var material: String? }
    struct SaveTool: Decodable { var tool: Tool }
    struct ImportParam: Decodable { var path: String; var svgPixelsPerInch: Double? }
    struct ExportVectors: Decodable { var path: String; var ids: [UUID]? }

    // MARK: Dispatch

    private func dispatch(_ method: String, line: Data, id: Int?) throws -> Data {
        let s = session
        switch method {
        case "info":
            struct Info: Encodable { var platform: String; var fonts: [String]; var defaultFont: String; var imageExtensions: [String]; var importExtensions: [String] }
            #if os(Windows)
            let platform = "windows"
            #elseif os(Linux)
            let platform = "linux"
            #else
            let platform = "macos"
            #endif
            return try reply(id, Info(platform: platform, fonts: TextOutliner.availableFontNames(), defaultFont: TextOutliner.defaultFontName,
                                      imageExtensions: RasterCodec.fileExtensions, importExtensions: ImportService.allExtensions))
        case "state": return try reply(id, state())
        case "new":
            s.newProject()
            assistantLink?.documentChanged()
            return try reply(id, state())
        case "open":
            let path = try params(line, PathParam.self).path
            do { try s.open(URL(fileURLWithPath: path)) } catch { throw ProjectOpenError(error) }
            assistantLink?.documentChanged()
            return try reply(id, state())
        // The live link (spec 2, "The desktop host").
        case "assistantStatus":
            return try reply(id, assistantStatus())
        case "assistantAnswer":
            struct P: Decodable { var allow: Bool }
            assistantLink?.answer(allow: try params(line, P.self).allow)
            return try reply(id, assistantStatus())
        case "assistantDialog":
            struct P: Decodable { var open: Bool }
            assistantLink?.setDialog(open: try params(line, P.self).open)
            return try reply(id, Nothing())
        case "dismissAssistantMarker":
            assistantLink?.dismissMarker()
            return try reply(id, state())
        case "assistantRevoke":
            assistantLink?.revoke()
            return try reply(id, assistantStatus())
        case "save":
            let from = s.fileURL
            let to = URL(fileURLWithPath: try params(line, PathParam.self).path)
            try s.save(to: to)
            assistantLink?.saved(from: from, to: to)
            return try reply(id, state())
        case "undo":
            s.undo()
            return try reply(id, state())
        case "redo":
            s.redo()
            return try reply(id, state())

        // Shapes
        case "addShape":
            let p = try params(line, AddShape.self)
            guard let tool = CanvasTool(rawValue: p.tool) else { throw UnknownMethod(method: "tool \(p.tool)") }
            var options = DrawingOptions()
            if let v = p.options?.cornerRadius { options.cornerRadius = v }
            if let v = p.options?.polygonSides { options.polygonSides = v }
            if let v = p.options?.starPoints { options.starPoints = v }
            if let v = p.options?.starInnerRatio { options.starInnerRatio = v }
            if let v = p.options?.constrain { options.constrain = v }
            let layer = s.project.document.defaultLayerID
            guard let shape = DrawingTools.shape(for: tool, from: p.from, to: p.to, options: options, layerID: layer) else { return try reply(id, state()) }
            s.perform("Add \(tool.title)") { $0.document.add(shape) }
            return try reply(id, state())
        case "addPolyline":
            let p = try params(line, AddPolyline.self)
            let tol = p.closeTolerance ?? (s.project.document.units == .inch ? 0.05 : 1)
            if let shape = DrawingTools.polyline(points: p.points, closeTolerance: tol, layerID: s.project.document.defaultLayerID) {
                s.perform("Add Polyline") { $0.document.add(shape) }
            }
            return try reply(id, state())
        case "addText":
            let spec = try params(line, AddText.self).spec
            let shape = try TextOutliner().shape(for: spec, layerID: s.project.document.defaultLayerID)
            s.perform("Add Text") { $0.document.add(shape) }
            return try reply(id, state())
        // Several shapes as one change: every item is built first, so a bad one adds nothing (the MCP server's add_shapes).
        case "addShapes":
            struct Item: Decodable {
                var kind: String; var tool: String?; var from: Vec2?; var to: Vec2?; var options: ShapeOptions?
                var points: [Vec2]?; var closed: Bool?; var spec: TextSpec?; var layerID: UUID?
            }
            struct P: Decodable { var shapes: [Item] }
            struct Added: Encodable { var state: State; var ids: [UUID] }
            let items = try params(line, P.self).shapes
            let doc = s.project.document
            let shapes: [Shape] = try items.enumerated().map { i, item in
                let n = i + 1
                let layer = item.layerID ?? doc.defaultLayerID
                guard doc.layer(id: layer) != nil else { throw CoreFailure("Shape \(n): no layer with id \(layer).") }
                switch item.kind {
                case "tool":
                    guard let name = item.tool, let tool = CanvasTool(rawValue: name) else { throw CoreFailure("Shape \(n): unknown tool \"\(item.tool ?? "")\".") }
                    guard let from = item.from, let to = item.to else { throw CoreFailure("Shape \(n): a \(name) needs from and to.") }
                    var options = DrawingOptions()
                    if let v = item.options?.cornerRadius { options.cornerRadius = v }
                    if let v = item.options?.polygonSides { options.polygonSides = v }
                    if let v = item.options?.starPoints { options.starPoints = v }
                    if let v = item.options?.starInnerRatio { options.starInnerRatio = v }
                    if let v = item.options?.constrain { options.constrain = v }
                    guard let shape = DrawingTools.shape(for: tool, from: from, to: to, options: options, layerID: layer) else {
                        throw CoreFailure("Shape \(n): a \(name) from \(from) to \(to) has no size.")
                    }
                    return shape
                case "polyline":
                    let pts = item.points ?? []
                    let closed = item.closed ?? false
                    guard let shape = DrawingTools.polyline(points: closed && pts.count >= 3 ? pts + [pts[0]] : pts,
                                                            closeTolerance: closed ? 1e-9 : -1, layerID: layer) else {
                        throw CoreFailure("Shape \(n): a polyline needs at least two different points.")
                    }
                    return shape
                case "text":
                    guard let spec = item.spec else { throw CoreFailure("Shape \(n): text needs a spec.") }
                    do { return try TextOutliner().shape(for: spec, layerID: layer) }
                    catch { throw CoreFailure("Shape \(n): \(Self.describe(error))") }
                default:
                    throw CoreFailure("Shape \(n): unknown kind \"\(item.kind)\" (tool, polyline or text).")
                }
            }
            if !shapes.isEmpty { s.perform(shapes.count == 1 ? "Add Shape" : "Add \(shapes.count) Shapes") { p in shapes.forEach { p.document.add($0) } } }
            return try reply(id, Added(state: state(), ids: shapes.map(\.id)))
        case "updateText":
            struct P: Decodable { var id: UUID; var spec: TextSpec }
            let p = try params(line, P.self)
            try s.perform("Edit Text") { try VectorCommands.updateText(p.id, spec: p.spec, in: &$0) }
            return try reply(id, state())
        case "paste":
            struct P: Decodable { var shapes: [Shape] }
            struct Pasted: Encodable { var state: State; var selection: [UUID] }
            let shapes = try params(line, P.self).shapes
            var selection: [UUID] = []
            let doc = s.project.document
            let offset = ShapeClipboard.pasteOffset(for: shapes, existing: Set(doc.shapes.map(\.id)), grid: doc.gridSpacing)
            s.perform("Paste") { selection = $0.paste(shapes, offset: offset, fallbackLayer: doc.defaultLayerID) }
            return try reply(id, Pasted(state: state(), selection: selection))
        case "replaceShape":
            let shape = try params(line, ReplaceShape.self).shape
            s.perform("Edit Shape") { project in
                if let i = project.document.shapes.firstIndex(where: { $0.id == shape.id }) { project.document.shapes[i] = shape }
            }
            return try reply(id, state())
        case "deleteShapes":
            let ids = try params(line, IDs.self).ids ?? []
            s.perform("Delete") { $0.deleteShapes(Set(ids)) }
            return try reply(id, state())
        case "translateShapes":
            let p = try params(line, Translate.self)
            s.perform("Move") { $0.transformShapes(Set(p.ids), by: .translation(p.by)) }
            return try reply(id, state())
        case "transformShapes":
            let p = try params(line, Transform.self)
            s.perform(p.action ?? "Transform") { $0.transformShapes(Set(p.ids), by: p.transform) }
            return try reply(id, state())
        case "moveShapesToLayer":
            let p = try params(line, MoveToLayer.self)
            s.perform("Move to Layer") { $0.moveShapes(Set(p.ids), toLayer: p.layer) }
            return try reply(id, state())
        case "mirrorShapes":
            struct P: Decodable { var ids: [UUID]; var horizontally: Bool }
            let p = try params(line, P.self)
            s.perform(p.horizontally ? "Mirror Horizontally" : "Mirror Vertically") { project in
                VectorCommands.mirror(p.ids, horizontally: p.horizontally, pivot: .selectionCenter, keepOriginal: false, in: &project)
            }
            return try reply(id, state())

        // The Design menu's commands on the selection.
        case "command":
            struct Command: Decodable {
                var name: String; var ids: [UUID]; var mode: String?; var number: Double?; var count: Int?; var rows: Int?; var columns: Int?
                var x: Double?; var y: Double?; var flag: Bool?; var center: Vec2?
            }
            struct Done: Encodable { var state: State; var selection: [UUID]?; var note: String? }
            let c = try params(line, Command.self)
            let (selection, note) = try runCommand(c.name, ids: c.ids, mode: c.mode, number: c.number, count: c.count, rows: c.rows, columns: c.columns,
                                                   x: c.x, y: c.y, flag: c.flag, center: c.center)
            return try reply(id, Done(state: state(), selection: selection, note: note))

        // Layers
        case "addLayer":
            let name = try params(line, LayerName.self).name
            s.perform("New Layer") { _ = $0.addLayer(named: name) }
            return try reply(id, state())
        case "deleteLayer":
            let layer = try params(line, OneID.self).id
            s.perform("Delete Layer") { $0.deleteLayer(layer) }
            return try reply(id, state())
        case "updateLayer":
            let layer = try params(line, LayerParam.self).layer
            s.perform("Edit Layer") { $0.updateLayer(layer) }
            return try reply(id, state())

        // Job setup
        case "setJob":
            let p = try params(line, Job.self)
            var form = JobSetupForm(project: s.project, machines: s.machines, profiles: s.profiles)
            form.units = p.units
            form.job = p.job
            if let g = p.gridSpacing { form.gridSpacing = g }
            if let n = p.name { form.name = n }
            if let m = p.machineID { form.machineID = m }
            if let post = p.postID { form.postID = post }
            guard form.problems.isEmpty else { throw CoreFailure(form.problems.joined(separator: " ")) }
            s.perform("Job Setup") { $0 = form.apply(to: $0) }
            return try reply(id, state())

        // What the Job Setup form shows, and its units switch: the same conversion as the Mac's form, so no length is left behind.
        case "jobForm":
            struct Choice: Encodable { var id: String; var title: String }
            struct Form: Encodable { var machineID: String?; var machineChoices: [Choice]; var postID: String? }
            let form = JobSetupForm(project: s.project, machines: s.machines, profiles: s.profiles)
            return try reply(id, Form(machineID: form.machineID, machineChoices: form.machineChoices(installed: s.machines).map { Choice(id: $0.id, title: $0.title) },
                                      postID: form.postID))
        case "convertJob":
            struct P: Decodable { var units: LengthUnit; var job: JobSetup; var gridSpacing: Double; var to: LengthUnit }
            struct Converted: Encodable { var job: JobSetup; var gridSpacing: Double }
            let p = try params(line, P.self)
            var form = JobSetupForm(project: s.project, machines: s.machines, profiles: s.profiles)
            form.units = p.units
            form.job = p.job
            form.gridSpacing = p.gridSpacing
            form.setUnits(p.to)
            return try reply(id, Converted(job: form.job, gridSpacing: form.gridSpacing))
        case "setSide":
            struct P: Decodable { var side: JobSide }
            s.showSide(try params(line, P.self).side)
            return try reply(id, state())

        // Toolpaths
        case "addOperation":
            let p = try params(line, AddOperation.self)
            guard let kind = OperationKind(rawValue: p.kind) else { throw UnknownMethod(method: "operation kind \(p.kind)") }
            guard let op = OperationFactory.make(kind: kind, project: s.project, library: s.project.mergedTools(with: s.library), shapeIDs: p.shapeIDs) else {
                throw CoreFailure("Import a 3D model before adding a 3D toolpath.")
            }
            s.perform("New \(kind.displayName) Toolpath") { $0.upsertOperation(op) }
            return try reply(id, state())
        case "updateOperation":
            let op = try params(line, UpdateOperation.self).operation
            s.perform("Edit Toolpath") { $0.upsertOperation(op) }
            return try reply(id, state())
        case "deleteOperation":
            let op = try params(line, OneID.self).id
            s.perform("Delete Toolpath") { $0.deleteOperation(op) }
            return try reply(id, state())
        case "moveOperation":
            let p = try params(line, MoveOperation.self)
            s.perform("Move Toolpath") { $0.moveOperation(p.id, by: p.delta) }
            return try reply(id, state())
        case "enableOperation":
            let p = try params(line, Enable.self)
            guard let op = s.project.operations.first(where: { $0.id == p.id }) else { return try reply(id, state()) }
            var setup = op.editableSetup
            setup.isEnabled = p.enabled
            s.perform("Include in Export") { $0.upsertOperation(op.with(setup: setup)) }
            return try reply(id, state())
        case "calculate":
            let ids = try params(line, IDs.self).ids ?? s.project.operations.filter(\.setup.isEnabled).map(\.id)
            s.calculate(ids)
            return try reply(id, state())
        case "toolpathLines":
            struct Line: Encodable { var points: [Double]; var isRapid: Bool; var operation: UUID? }
            struct Lines: Encodable { var lines: [Line]; var maxDepth: Double }
            let want = try params(line, LinesParam.self).ids
            let output = s.outputProject
            let coords = MachineCoordinates(job: output.document.job)
            var out = Lines(lines: [], maxDepth: 0)
            for op in output.operations where want?.contains(op.id) ?? true {
                guard let tps = s.results[op.id]?.toolpaths else { continue }
                let lines = ToolpathLines3D(toolpaths: tps, coords: coords)
                out.maxDepth = max(out.maxDepth, lines.maxDepth)
                for l in lines.polylines {
                    out.lines.append(Line(points: l.points.flatMap { [$0.x, $0.y, $0.z] }, isRapid: l.isRapid, operation: op.id))
                }
            }
            return try reply(id, out)

        // Posting: the program text only ever comes from here.
        case "export":
            let p = try params(line, Export.self)
            let scope: GCodeExportScope = p.operation.map { .operation($0) } ?? .all
            let (r, profile) = try s.post(scope: scope, postID: p.postID, side: p.side, groupByTool: p.groupByTool ?? false)
            struct Posted: Encodable {
                var text: String?; var errorMessage: String?; var issues: [IssueRow]; var missingSteps: [IssueRow]
                var hasErrors: Bool; var toolpathCount: Int; var fileName: String; var post: String; var written: String?
            }
            var written: String?
            // Written here, from the post's own bytes, under the rule the command line follows: a step missing from the program is
            // never written, and a validator error only with force.
            if let path = p.path, let text = r.fileText, r.missingSteps.isEmpty, !r.hasErrors || p.force == true {
                try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
                written = path
            }
            let operationName = p.operation.flatMap { want in s.project.operations.first { $0.id == want }?.setup.name }
            return try reply(id, Posted(text: r.text, errorMessage: r.errorMessage, issues: r.issues.map(Self.row), missingSteps: r.missingSteps.map(Self.row),
                                        hasErrors: r.hasErrors, toolpathCount: r.toolpathCount,
                                        fileName: GCodeExporter.suggestedFileName(jobName: s.project.document.name, operationName: operationName, profile: profile),
                                        post: profile.name, written: written))
        // Save All: the planned files as the Mac's sheet plans them, written together or not at all (GCodeFileSet).
        case "saveAll":
            struct P: Decodable { var mode: String; var postID: String?; var groupByTool: Bool?; var folder: String?; var replacing: Bool? }
            struct FileRow: Encodable { var fileName: String; var title: String; var posted: Bool; var errorMessage: String?; var issues: [IssueRow] }
            struct Saved: Encodable { var files: [FileRow]; var existing: [String]; var invalidNames: [String]; var unposted: [String]; var written: Bool; var hasErrors: Bool }
            let p = try params(line, P.self)
            guard let mode = SaveAllMode(rawValue: p.mode) else { throw UnknownMethod(method: "save mode \(p.mode)") }
            let posted = try s.postAll(mode: mode, context: PostingContext(postID: p.postID, groupByTool: p.groupByTool ?? false))
            let set = GCodeFileSet(posted: posted)
            let hasErrors = posted.contains { $0.result.hasErrors || !$0.result.missingSteps.isEmpty }
            var written = false
            var existing: [String] = []
            if let folder = p.folder {
                let url = URL(fileURLWithPath: folder, isDirectory: true)
                existing = set.existing(in: url)
                if !hasErrors, set.unposted.isEmpty, set.invalidNames.isEmpty, existing.isEmpty || p.replacing == true {
                    _ = try set.write(to: url, replacing: existing)
                    written = true
                }
            }
            return try reply(id, Saved(files: posted.map { FileRow(fileName: $0.file.fileName, title: $0.file.title, posted: $0.result.text != nil, errorMessage: $0.result.errorMessage, issues: $0.result.issues.map(Self.row)) },
                                       existing: existing, invalidNames: set.invalidNames, unposted: set.unposted, written: written, hasErrors: hasErrors))
        case "jobSheet":
            struct P: Decodable { var path: String; var postID: String?; var groupByTool: Bool?; var side: JobSide? }
            let p = try params(line, P.self)
            let html = try s.jobSheetHTML(context: PostingContext(postID: p.postID, groupByTool: p.groupByTool ?? false, side: p.side))
            try Data(html.utf8).write(to: URL(fileURLWithPath: p.path), options: .atomic)
            return try reply(id, Nothing())
        // Toolpaths > Check Toolpaths…, for the posting context (the MCP server's `check`).
        case "checkReport":
            struct P: Decodable { var postID: String?; var groupByTool: Bool?; var side: JobSide? }
            struct Row: Encodable { var title: String; var issues: [IssueRow] }
            struct Report: Encodable { var sections: [Row]; var errorCount: Int; var warningCount: Int }
            let p = (try? params(line, P.self)) ?? P()
            let r = try s.checkReport(context: PostingContext(postID: p.postID, groupByTool: p.groupByTool ?? false, side: p.side))
            return try reply(id, Report(sections: r.sections.map { Row(title: $0.title, issues: $0.issues.map(Self.row)) },
                                        errorCount: r.errorCount, warningCount: r.warningCount))
        // Help > Connect an AI Assistant… in the desktop app: the MCP server beside this one, the settings to paste, the folders.
        case "assistantSetup", "setAssistantFolders", "setAssistantLink":
            struct Folders: Decodable { var folders: [String] }
            struct Link: Decodable { var on: Bool }
            struct Setup: Encodable {
                var serverPath: String; var config: String; var claudeCodeLine: String; var allowedFolders: [String]; var liveLink: Bool
                var socketPath: String
            }
            // Each change loads the file and changes one field, so setting folders never turns the switch off.
            if method == "setAssistantFolders" {
                var settings = AssistantSettings.load(from: assistantSettingsURL)
                settings.allowedFolders = try params(line, Folders.self).folders
                try settings.save(to: assistantSettingsURL)
            } else if method == "setAssistantLink" {
                var settings = AssistantSettings.load(from: assistantSettingsURL)
                settings.liveLink = try params(line, Link.self).on
                try settings.save(to: assistantSettingsURL)
                assistantLink?.switchChanged(settings.liveLink)
            }
            let server = AssistantSetup.serverPath(besideExecutable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            return try reply(id, Setup(serverPath: server, config: AssistantSetup.config(serverPath: server),
                                       claudeCodeLine: AssistantSetup.claudeCodeLine(serverPath: server),
                                       allowedFolders: AssistantSettings.load(from: assistantSettingsURL).allowedFolders,
                                       liveLink: AssistantSettings.load(from: assistantSettingsURL).liveLink,
                                       socketPath: AssistantSettings.linkFolder(for: assistantSettingsURL).appendingPathComponent("assistant.sock").path))
        case "help":
            struct Topic: Encodable { var id: String; var title: String; var body: String; var related: [String] }
            return try reply(id, HelpTopic.allCases.map { Topic(id: $0.rawValue, title: $0.title, body: $0.body, related: $0.related.map(\.rawValue)) })
        case "posts":
            struct Row: Encodable { var id: String; var name: String; var fileExtension: String; var units: LengthUnit }
            return try reply(id, s.profiles.map { Row(id: $0.id, name: $0.name, fileExtension: GCodeExporter.fileExtension(for: $0), units: $0.units) })
        case "machines":
            return try reply(id, s.machines)
        case "tools":
            return try reply(id, s.project.mergedTools(with: s.library).tools)
        case "saveTool":
            let tool = try params(line, SaveTool.self).tool
            var library = s.library
            library.upsert(tool)
            // As the Mac's Tool Database, a copy that matched what was edited follows the edit, and one that had diverged stays. The
            // dialog also lists tools only the project has: for those, the copy is what was edited.
            var before = s.library
            for carried in s.project.tools where before.tool(id: carried.id) == nil { before.upsert(carried) }
            try s.saveLibrary(library)
            s.perform("Update Tool from Library") { $0 = ToolSync.applyingLibraryChange(old: before, new: library, to: $0) }
            return try reply(id, s.project.mergedTools(with: s.library).tools)

        // Files in and out
        case "import":
            let p = try params(line, ImportParam.self)
            let url = URL(fileURLWithPath: p.path)
            let data = try Data(contentsOf: url)
            var warnings: [String] = []
            try s.perform("Import") { project in
                let outcome = try ImportService.importFile(data: data, fileName: url.lastPathComponent, into: &project)
                warnings = outcome.warnings
            }
            struct Imported: Encodable { var state: State; var warnings: [String] }
            return try reply(id, Imported(state: state(), warnings: warnings))
        case "exportVectors":
            let p = try params(line, ExportVectors.self)
            let url = URL(fileURLWithPath: p.path)
            guard let exporter = FileFormats.exporter(forExtension: url.pathExtension) else {
                throw CoreFailure("LoftLine cannot export .\(url.pathExtension) files.")
            }
            let doc = s.project.document
            let shapes = p.ids.map { doc.shapes(ids: $0) } ?? doc.shapes
            try exporter.export(shapes: shapes, layers: doc.layers, units: doc.units).write(to: url, options: .atomic)
            return try reply(id, Nothing())

        // The 3D preview
        case "simStart":
            let p = try params(line, SimStart.self)
            let sim = CoreSimulation(session: s, groupByTool: p.groupByTool ?? false, material: p.material)
            simulation = sim
            return try reply(id, sim.summary)
        case "simSeek":
            let p = try params(line, SimSeek.self)
            guard let sim = simulation else { throw CoreFailure("The preview has not started.") }
            return try reply(id, sim.frame(at: p.time, maxVertices: p.maxVertices ?? 120_000))

        default:
            throw UnknownMethod(method: method)
        }
    }
}

extension CoreService {
    /// One command of the Design menu, run as an undoable edit by the same function the Mac's menu calls. Returns the new selection when
    /// the command makes one, and a note for the user.
    func runCommand(_ name: String, ids: [UUID], mode: String?, number: Double?, count: Int?, rows: Int?, columns: Int?, x: Double?, y: Double?,
                    flag: Bool?, center: Vec2?) throws -> (selection: [UUID]?, note: String?) {
        let s = session
        let set = Set(ids)
        var selection: [UUID]?
        var note: String?
        func need(_ value: Double?, _ what: String) throws -> Double {
            guard let value, value.isFinite else { throw CoreFailure("\(what) needs a number.") }
            return value
        }
        switch name {
        case "align":
            guard let m = mode.flatMap(AlignMode.init(rawValue:)) else { throw UnknownMethod(method: "align \(mode ?? "")") }
            s.perform(m.title) { DesignCommands.align(set, mode: m, in: &$0) }
        case "distribute":
            s.perform(flag == true ? "Distribute Horizontally" : "Distribute Vertically") { DesignCommands.distribute(set, horizontally: flag == true, in: &$0) }
        case "group":
            s.perform("Group") { _ = DesignCommands.group(ids, in: &$0) }
        case "ungroup":
            s.perform("Ungroup") { DesignCommands.ungroup(ids, in: &$0) }
        case "combine":
            s.perform("Combine Vectors") { p in selection = DesignCommands.combine(ids, in: &p).map { [$0] } }
        case "breakApart":
            s.perform("Break Apart") { p in selection = DesignCommands.explode(set, in: &p) }
        case "join":
            let tolerance = number ?? DesignCommands.defaultJoinTolerance(s.project.document.units)
            note = DesignCommands.joinPreview(ids, tolerance: tolerance, in: s.project)?.lines(units: s.project.document.units).joined(separator: "\n")
            s.perform("Join Open Vectors") { p in selection = DesignCommands.join(ids, tolerance: tolerance, in: &p).map { [$0] } }
        case "close":
            s.perform("Close Open Vectors") { DesignCommands.close(set, in: &$0) }
        case "boolean":
            guard let m = mode.flatMap(BooleanMode.init(rawValue:)) else { throw UnknownMethod(method: "boolean \(mode ?? "")") }
            s.perform(m.title) { p in selection = DesignCommands.boolean(m, ids: ids, in: &p).map { [$0] } }
        case "offset":
            let d = try need(number, "Offset")
            s.perform("Offset") { p in selection = DesignCommands.offset(ids, distance: d, sharpCorners: flag == true, in: &p) }
        case "rotate":
            let d = try need(number, "Rotate")
            s.perform("Rotate") { TransformCommands.rotate(set, degrees: d, in: &$0) }
        case "textToCurves":
            s.perform("Convert Text to Curves") { VectorCommands.convertTextToCurves(set, in: &$0) }
        case "rectangularArray":
            s.perform("Rectangular Array") { p in
                selection = VectorCommands.rectangularArray(ids, rows: max(1, rows ?? 1), columns: max(1, columns ?? 1), x: x ?? 0, y: y ?? 0,
                                                            spacing: flag == true ? .gap : .offset, in: &p)
            }
        case "circularArray":
            let c = center ?? s.project.bounds(of: set).center
            s.perform("Circular Array") { p in
                selection = VectorCommands.circularArray(ids, count: max(1, count ?? 1), center: c, stepDegrees: number ?? 0, rotateCopies: flag == true, in: &p)
            }
        case "fillet":
            let r = try need(number, "Fillet")
            s.perform("Fillet Corners") { _ = VectorCommands.treatCorners(.fillet(radius: r), shapes: ids, nodes: [], in: &$0) }
        case "chamfer":
            let d = try need(number, "Chamfer")
            s.perform("Chamfer Corners") { _ = VectorCommands.treatCorners(.chamfer(distance: d), shapes: ids, nodes: [], in: &$0) }
        case "deleteDuplicates":
            let scope = VectorCommands.validationScope(ids, in: s.project)
            let issues = VectorValidator.duplicates(scope, tolerance: VectorCommands.tolerance(s.project.document.units))
            var fixed = 0
            s.perform("Delete Duplicate Vectors") { fixed = VectorCommands.repair(issues, in: &$0) }
            note = "\(fixed) duplicate\(fixed == 1 ? "" : "s") removed."
        default:
            throw UnknownMethod(method: "command \(name)")
        }
        return (selection, note)
    }
}

public struct CoreFailure: LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The material-removal simulation for the 3D preview: the same player and mesh as the Mac's, sent as base64 little-endian arrays.
final class CoreSimulation {
    private var player: SimulationPlayer
    private let thickness: Double
    private let unitsPerInch: Double
    private let appearance: StockAppearance
    private let coords: MachineCoordinates
    private let toolpaths: [Toolpath]

    struct Summary: Encodable {
        var totalTime: Double
        var duration: String
        var job: JobSetup
        var units: LengthUnit
        var toolpaths: [Row]
        struct Row: Encodable { var name: String; var diameter: Double; var moves: Int }
    }

    struct Frame: Encodable {
        var positions: String
        var normals: String
        var colors: String
        var indices: String
        var tip: [Double]?
        var toolpathIndex: Int?
        var time: Double
    }

    init(session: CoreSession, groupByTool: Bool, material: String?) {
        let doc = session.outputProject.document
        toolpaths = session.previewToolpaths(groupByTool: groupByTool)
        let minCell = doc.units == .inch ? 0.004 : 0.1
        let cell = Heightfield.automaticCellSize(width: doc.job.width, height: doc.job.height, targetCells: 400_000, minimum: minCell)
        let time = TimeEstimateSettings.load()
        player = SimulationPlayer(job: doc.job, toolpaths: toolpaths, rapidRate: session.rapidRate, cellSize: cell,
                                  toolChangeSeconds: time.toolChangeSeconds, motion: time.motion(units: doc.units))
        thickness = doc.job.thickness
        unitsPerInch = LengthUnit.inch.factor(to: doc.units)
        appearance = material.flatMap { StockAppearance.Material(rawValue: $0) }.map(StockAppearance.preset) ?? .default
        coords = MachineCoordinates(job: doc.job)
        summary = Summary(totalTime: player.timeline.totalTime, duration: MachiningTimeEstimator.format(player.timeline.totalTime),
                          job: doc.job, units: doc.units,
                          toolpaths: toolpaths.map { .init(name: $0.name, diameter: $0.tool.diameter, moves: $0.moves.count) })
    }

    let summary: Summary

    func frame(at time: Double, maxVertices: Int) -> Frame {
        player.seek(to: time)
        let mesh = HeightfieldMesh(heightfield: player.heightfield, thickness: thickness, maxVertices: maxVertices,
                                   appearance: appearance, unitsPerInch: unitsPerInch)
        var tip: [Double]?, index: Int?
        if let pos = player.timeline.toolPosition(at: time) {
            let m = coords.material(fromMachine: pos.point)
            tip = [m.xy.x, m.xy.y, -m.depth]
            index = pos.toolpathIndex
        }
        func base64<T>(_ values: [T]) -> String { values.withUnsafeBytes { Data($0).base64EncodedString() } }
        return Frame(positions: base64(mesh.positions), normals: base64(mesh.normals), colors: base64(mesh.colors), indices: base64(mesh.indices),
                     tip: tip, toolpathIndex: index, time: time)
    }
}
