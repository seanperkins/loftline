import CADCore
import CAMCore
import Foundation

/// Outcome of calculating one operation. Kept in memory only (recalculated after opening).
public struct ToolpathResult: Sendable {
    public var toolpaths: [Toolpath]
    public var error: String?
    /// The operation exactly as it was when calculated (to detect parameter edits).
    public var operation: AnyOperation
    /// `LoftLineDocument.designRevision` at calculation time (to detect design/tool edits).
    public var designRevision: Int
    /// The operation's own run time, tool changes inside it included (what its row shows).
    public var estimatedSeconds: TimeInterval
    /// A rest pass's source as it was when this was calculated (`withoutPostSettings`); a later change to the source
    /// makes the rest pass stale (`LoftLineDocument.isStale`), since its rest region depends on the source's tool.
    public var restSource: AnyOperation? = nil

    public init(toolpaths: [Toolpath], error: String?, operation: AnyOperation, designRevision: Int,
         estimatedSeconds: TimeInterval) {
        self.toolpaths = toolpaths; self.error = error; self.operation = operation
        self.designRevision = designRevision; self.estimatedSeconds = estimatedSeconds
    }

    public var isOK: Bool { error == nil && !toolpaths.isEmpty }

    /// This result with each toolpath's tool carrying the name `library` gives it now; nil when
    /// no name differs.
    public func renamingTools(from library: ToolLibrary) -> ToolpathResult? {
        var out = self
        var changed = false
        for i in out.toolpaths.indices {
            guard let name = library.tool(id: out.toolpaths[i].tool.id)?.name, name != out.toolpaths[i].tool.name else { continue }
            out.toolpaths[i].tool.name = name
            changed = true
        }
        return changed ? out : nil
    }
}

public enum ToolpathCalculator {
    /// Runs the operation's generator. Never throws: failures become `error` text. A rest pass's result records its
    /// source as it was (`restSource`).
    public static func calculate(_ op: AnyOperation, project: LoftLineProject, library: ToolLibrary,
                          designRevision: Int, rapidRate: Double) -> ToolpathResult {
        var result = generate(op, project: project, library: library, designRevision: designRevision, rapidRate: rapidRate)
        if case .relief3D(let r) = op, case .operation(let id)? = r.params.finishing.rest {
            result.restSource = project.operations.flattened.first { $0.id == id }?.withoutPostSettings
        }
        return result
    }

    private static func generate(_ op: AnyOperation, project: LoftLineProject, library: ToolLibrary,
                                 designRevision: Int, rapidRate: Double) -> ToolpathResult {
        var document = project.document
        switch project.machiningJob(for: op) {
        case .success(let job): document.job = job
        case .failure(let e):
            return ToolpathResult(toolpaths: [], error: e.message, operation: op, designRevision: designRevision,
                                  estimatedSeconds: 0)
        }
        // Extra nesting sheets parked beside the material are not machined.
        let onMaterial = NestSheets.activeDocument(document)
        var context = CAMContext(document: onMaterial, tools: project.mergedTools(with: library))
        context.operations = project.operations   // a rest pass finds the finish it follows

        if onMaterial.shapes.count != project.document.shapes.count, !op.setup.shapeIDs.isEmpty,
           op.setup.shapeIDs.allSatisfy({ onMaterial.shape(id: $0) == nil && project.document.shape(id: $0) != nil }) {
            let keepOut = Fixtures.keepOutLayerIDs(in: project.document)
            let clampsOnly = op.setup.shapeIDs.allSatisfy { project.document.shape(id: $0).map { keepOut.contains($0.layerID) } ?? false }
            let why = clampsOnly
                ? "This toolpath only uses clamp / keep-out vectors, which are never machined."
                : "All of this toolpath's vectors are on a sheet that is not on the material. "
                    + "Use Design > Layout > Sheet on Material to cut that sheet."
            return ToolpathResult(toolpaths: [], error: why, operation: op, designRevision: designRevision,
                                  estimatedSeconds: 0)
        }
        do {
            let tps = try op.generate(in: context)
            let settings = TimeEstimateSettings.load()
            let secs = settings.estimate(tps, rapidRate: rapidRate, units: project.document.units)
            let err = tps.isEmpty ? "No toolpath was generated (check the selected vectors and depths)." : nil
            return ToolpathResult(toolpaths: tps, error: err, operation: op, designRevision: designRevision,
                                  estimatedSeconds: secs)
        } catch {
            return ToolpathResult(toolpaths: [], error: describe(error), operation: op,
                                  designRevision: designRevision, estimatedSeconds: 0)
        }
    }

    /// User-facing message for generator errors.
    public static func describe(_ error: Error) -> String {
        switch error {
        case CAMError.notImplemented(let what): return "\(what) is not available in this build yet."
        case CAMError.missingTool: return "The selected tool is not in the tool database."
        case CAMError.missingModel: return "The 3D model for this toolpath is missing."
        case CAMError.noGeometry: return "Select one or more vectors for this toolpath."
        case CAMError.invalidGeometry(let m): return "Invalid geometry: \(m)"
        case CAMError.invalidParameter(let m): return "Invalid parameter: \(m)"
        default: return error.localizedDescription
        }
    }

    /// "1h 02m 05s" / "3m 20s" / "45s".
    public static func formatDuration(_ s: TimeInterval) -> String { MachiningTimeEstimator.format(s) }
}
