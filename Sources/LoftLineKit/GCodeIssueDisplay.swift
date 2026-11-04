import Foundation
import PostCore

extension GCodeIssue {
    /// "Line 1156: …" for the export sheet's list. The icon already says warning or error, so the
    /// severity word `description` starts with is dropped.
    public var displayText: String { line.map { "Line \($0): \(message)" } ?? message }

    /// Issues with the same severity and message listed once, in first-seen order. The export runs
    /// each check on the toolpaths (no line) and again on the generated G-code (with a line); the
    /// copy that says where wins, and the earliest line of several.
    public static func merged(_ issues: [GCodeIssue]) -> [GCodeIssue] {
        struct Key: Hashable { var severity: Severity; var message: String }
        var order: [Key] = []
        var best: [Key: GCodeIssue] = [:]
        for issue in issues {
            let key = Key(severity: issue.severity, message: issue.message)
            guard let current = best[key] else {
                order.append(key)
                best[key] = issue
                continue
            }
            switch (current.line, issue.line) {
            case (nil, .some): best[key] = issue
            case let (.some(a), .some(b)) where b < a: best[key] = issue
            default: break
            }
        }
        return order.compactMap { best[$0] }
    }
}
