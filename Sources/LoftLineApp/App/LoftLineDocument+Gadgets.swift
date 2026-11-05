import CADCore
import Foundation
import LoftLineKit

extension LoftLineDocument {
    /// Runs a gadget on the current design and applies everything it did as one undo step.
    /// On failure nothing changes and the error is returned for the caller to show.
    @discardableResult
    func runGadget(_ script: GadgetScript, values: [String: GadgetValue]) -> Result<GadgetRunResult, GadgetError> {
        if script.needsSelection && selection.isEmpty {
            return .failure(GadgetError(message: "\(script.name) works on selected vectors. Select some first."))
        }
        let result: GadgetRunResult
        do {
            result = try GadgetHost.run(script, values: values, project: project, selection: selectedShapes.map(\.id),
                                        library: toolLibrary.library, layerID: currentLayerID)
        } catch let e as GadgetError {
            return .failure(e)
        } catch {
            return .failure(GadgetError(message: error.localizedDescription))
        }
        perform("Gadget: \(script.name)") { $0 = result.project }
        if let sel = result.requestedSelection {
            setSelection(sel)
        } else if !result.createdShapeIDs.isEmpty {
            setSelection(result.createdShapeIDs)
        }
        if let op = result.createdOperationIDs.last {
            sidebarTab = .toolpaths
            selectedOperationID = op
        }
        let output = result.messages + result.log
        if !output.isEmpty {
            report(AlertMessage(title: script.name, message: output.joined(separator: "\n")))
        }
        return .success(result)
    }
}
