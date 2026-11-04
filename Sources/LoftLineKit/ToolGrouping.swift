import CADCore
import Foundation

/// Section title for a tool in the database list: its group, else its type.
public enum ToolGrouping {
    public static func section(_ tool: Tool) -> String {
        if let g = tool.group?.trimmingCharacters(in: .whitespaces), !g.isEmpty {
            return g.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " › ")
        }
        return tool.kind.displayName
    }

    /// Sections in display order: named groups alphabetically, then the tool types.
    public static func sections(_ tools: [Tool]) -> [(title: String, tools: [Tool])] {
        let grouped = Dictionary(grouping: tools, by: section)
        let kindTitles = ToolKind.allCases.map(\.displayName)
        let custom = grouped.keys.filter { !kindTitles.contains($0) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return (custom + kindTitles).compactMap { title in
            grouped[title].map { (title, $0.sorted { $0.number < $1.number }) }
        }
    }

    /// Every material name used by any tool, sorted.
    public static func materialNames(_ tools: [Tool]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for t in tools {
            for m in t.materials ?? [] where !m.material.isEmpty && !seen.contains(m.material.lowercased()) {
                seen.insert(m.material.lowercased())
                out.append(m.material)
            }
        }
        return out.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
