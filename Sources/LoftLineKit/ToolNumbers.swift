import CADCore
import Foundation

/// Tool numbers across the library: which are shared, and the next free one. A program that uses two different
/// tools under one T number is caught by pre-flight; this is the same check one step earlier, in the Tool Database.
public enum ToolNumbers {
    /// The numbers the tool numbers range over in the editor.
    public static let range = 0...999

    /// The tools that share a number with another tool, by number.
    public static func clashes(in tools: [Tool]) -> [Int: [Tool]] {
        Dictionary(grouping: tools, by: \.number).filter { $0.value.count > 1 }
    }

    /// The other tools in `tools` that have `number`.
    public static func others(using number: Int, besides id: UUID, in tools: [Tool]) -> [Tool] {
        tools.filter { $0.number == number && $0.id != id }
    }

    /// The smallest number from 1 that none of `tools` has, leaving out the tool `id` (the one being renumbered);
    /// nil when every number in the range is taken.
    public static func nextFree(in tools: [Tool], besides id: UUID? = nil) -> Int? {
        let used = Set(tools.filter { $0.id != id }.map(\.number))
        return range.dropFirst().first { !used.contains($0) }
    }

    /// "1/4" End Mill and 1/8" End Mill" for the tools that share a number, for a message.
    public static func names(_ tools: [Tool]) -> String {
        let names = tools.map(\.name)
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return names[0] + " and " + names[1]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}
