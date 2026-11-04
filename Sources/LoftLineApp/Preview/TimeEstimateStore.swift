import CADCore
import CAMCore
import Combine
import Foundation
import LoftLineKit

/// Live, observable copy of the settings for the UI. Writes go straight to UserDefaults so
/// background calculations (`ToolpathCalculator`) see them.
@MainActor
final class TimeEstimateStore: ObservableObject {
    static let shared = TimeEstimateStore()

    @Published var settings: TimeEstimateSettings {
        didSet { if settings != oldValue { settings.save() } }
    }

    init(defaults: UserDefaults = .standard) { settings = .load(from: defaults) }
}

extension LoftLineDocument {
    /// Estimate for `toolpaths` with the user's time-estimate settings and this document's post.
    func estimateSeconds(_ toolpaths: [Toolpath]) -> TimeInterval {
        TimeEstimateSettings.load().estimate(toolpaths, rapidRate: rapidRateInDocumentUnits, units: units)
    }

    /// The job summary of the output project with `settings` (the live store's, so the sidebar and
    /// the preview agree), timed over the toolpaths in program order and reused until something it
    /// is made from changes.
    func jobSummary(groupByTool: Bool, settings: TimeEstimateSettings) -> JobSummary {
        jobSummaryMemo.summary(operations: outputProject.operations, results: results, groupByTool: groupByTool,
                               settings: settings, rapidRate: rapidRateInDocumentUnits, units: units)
    }

    /// Recomputes the stored per-operation estimates (after the settings or machine change).
    func refreshTimeEstimates() {
        let s = TimeEstimateSettings.load()
        let rapid = rapidRateInDocumentUnits
        var changed = results
        for (id, r) in results where r.isOK {
            changed[id]?.estimatedSeconds = s.estimate(r.toolpaths, rapidRate: rapid, units: units)
        }
        if changed.contains(where: { results[$0.key]?.estimatedSeconds != $0.value.estimatedSeconds }) {
            results = changed
        }
    }
}
