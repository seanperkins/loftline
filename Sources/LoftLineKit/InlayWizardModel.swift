import CADCore
import CAMCore
import Foundation

/// State of the Inlay wizard: one set of inlay settings that becomes TWO toolpaths, a female
/// pocket (cut in the base board) and a mirrored male plug (cut in the insert board), so each
/// can be exported to its own file. Lengths are in document units.
public struct InlayWizardModel: Equatable {
    public var baseName: String
    public var shapeIDs: [UUID]
    public var vbitID: UUID
    public var clearanceToolID: UUID?
    public var pocketDepth: Double
    public var plugStartDepth: Double
    public var glueGap: Double
    public var mirrorPlug: Bool
    public var plugMargin: Double
    public var plugBoundary: InlayPlugBoundary = .boundaryOffset
    /// nil = pocket depth − plug start depth.
    public var surfaceClearance: Double?

    public init(project: LoftLineProject, library: ToolLibrary, shapeIDs: [UUID]) {
        let f = LengthUnit.inch.factor(to: project.document.units)
        let d = InlayParameters().scaled(by: f)
        baseName = OperationFactory.defaultName(for: .inlay, existing: project.operations)
        self.shapeIDs = shapeIDs
        vbitID = OperationFactory.defaultTool(for: .inlay, in: library)?.id ?? UUID()
        clearanceToolID = d.flatClearanceToolID
        pocketDepth = d.pocketDepth
        plugStartDepth = d.maleStartDepth
        glueGap = d.glueGap
        mirrorPlug = d.mirrorMale
        plugMargin = d.maleBoundaryMargin
    }

    /// Space under the plug once glued, which is also how far the plug board sits above the
    /// base surface before it is planed flush (pocket depth − plug start depth).
    public var bottomGap: Double { pocketDepth - plugStartDepth }

    /// Problems that block creating the toolpaths (empty = OK).
    public func problems(library: ToolLibrary) -> [String] {
        var out: [String] = []
        if shapeIDs.isEmpty { out.append("Select the closed vectors to inlay first.") }
        if let t = library.tool(id: vbitID) {
            if t.kind != .vBit && t.kind != .engraving { out.append("Inlays need a V-bit.") }
        } else {
            out.append("Choose a V-bit.")
        }
        if pocketDepth <= 0 { out.append("Pocket depth must be greater than zero.") }
        if plugStartDepth < 0 || glueGap < 0 || plugMargin < 0 {
            out.append("Start depth, glue gap and margin cannot be negative.")
        }
        if let c = surfaceClearance, c <= 0 { out.append("Surface clearance must be greater than zero.") }
        if plugStartDepth + glueGap > pocketDepth + 1e-9 {
            out.append("Plug start depth + glue gap must not exceed the pocket depth.")
        }
        return out
    }

    public func parameters(part: InlayPart) -> InlayParameters {
        InlayParameters(part: part, pocketDepth: pocketDepth, maleStartDepth: plugStartDepth, glueGap: glueGap,
                        flatClearanceToolID: clearanceToolID, mirrorMale: mirrorPlug, maleBoundaryMargin: plugMargin,
                        plugBoundary: plugBoundary, surfaceClearance: surfaceClearance)
    }

    /// Female pocket then male plug. The plug is generated in place over the pocket and is cut
    /// on a separate board, so it starts disabled: "Export all enabled toolpaths" then never
    /// carves it into the board that holds the pocket. Enable it (and disable the pocket) when
    /// the plug board is on the machine.
    public func makeOperations() -> [AnyOperation] {
        [(InlayPart.female, "Pocket"), (.male, "Plug")].map { part, suffix in
            var setup = OperationSetup(name: "\(baseName) \(suffix)", toolID: vbitID, shapeIDs: shapeIDs)
            setup.isEnabled = part == .female
            return .inlay(InlayOperation(setup: setup, params: parameters(part: part)))
        }
    }
}
