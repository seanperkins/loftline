import SwiftUI
import LoftLineKit

/// Line breaking for `WrappingHStack`, kept apart from the layout so it can be tested.
enum WrapLines {
    struct Line: Equatable {
        var indices: [Int]
        var width: CGFloat
    }

    /// Greedy left-to-right breaking: an item starts a new line when it would pass `maxWidth`.
    /// An item wider than `maxWidth` gets a line of its own.
    static func lines(widths: [CGFloat], maxWidth: CGFloat, spacing: CGFloat) -> [Line] {
        var lines: [Line] = []
        for (i, w) in widths.enumerated() {
            if var last = lines.last, last.width + spacing + w <= maxWidth {
                last.indices.append(i)
                last.width += spacing + w
                lines[lines.count - 1] = last
            } else {
                lines.append(Line(indices: [i], width: w))
            }
        }
        return lines
    }
}

private struct FlexibleItemKey: LayoutValueKey {
    static let defaultValue = false
}

extension View {
    /// In a `WrappingHStack`, lets this view (a slider, say) take the spare width of its line.
    /// It is measured at its minimum width, so it never forces the row wider than the space offered.
    func flexibleInWrappingStack() -> some View {
        layoutValue(key: FlexibleItemKey.self, value: true)
    }
}

/// A row that wraps onto further lines instead of demanding more width than it was offered, so a
/// control bar cannot push its container (and the window) wider than the screen.
struct WrappingHStack: Layout {
    var spacing: CGFloat = 10
    var lineSpacing: CGFloat = 8

    private func sizes(_ subviews: Subviews) -> [CGSize] {
        subviews.map { $0[FlexibleItemKey.self] ? $0.sizeThatFits(.zero) : $0.sizeThatFits(.unspecified) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = sizes(subviews)
        let lines = WrapLines.lines(widths: sizes.map(\.width), maxWidth: proposal.width ?? .infinity, spacing: spacing)
        let widest = lines.map(\.width).max() ?? 0
        let heights = lines.map { line in line.indices.map { sizes[$0].height }.max() ?? 0 }
        let height = heights.reduce(0, +) + lineSpacing * CGFloat(max(lines.count - 1, 0))
        // Fill the offered width so flexible items can stretch; never report less than the content needs.
        let width = proposal.width.flatMap { $0.isFinite ? max($0, widest) : nil } ?? widest
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = sizes(subviews)
        var y = bounds.minY
        for line in WrapLines.lines(widths: sizes.map(\.width), maxWidth: bounds.width, spacing: spacing) {
            let flexible = line.indices.filter { subviews[$0][FlexibleItemKey.self] }
            let extra = flexible.isEmpty ? 0 : max(0, bounds.width - line.width) / CGFloat(flexible.count)
            let lineHeight = line.indices.map { sizes[$0].height }.max() ?? 0
            var x = bounds.minX
            for i in line.indices {
                let width = sizes[i].width + (flexible.contains(i) ? extra : 0)
                subviews[i].place(at: CGPoint(x: x, y: y + (lineHeight - sizes[i].height) / 2),
                                  proposal: ProposedViewSize(width: width, height: sizes[i].height))
                x += width + spacing
            }
            y += lineHeight + lineSpacing
        }
    }
}
