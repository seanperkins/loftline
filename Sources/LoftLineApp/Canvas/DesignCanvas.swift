import AppKit
import CADCore
import SwiftUI
import LoftLineKit

/// SwiftUI wrapper for the AppKit canvas.
struct DesignCanvas: NSViewRepresentable {
    @ObservedObject var document: LoftLineDocument
    /// Redraws when canvas colours change in Preferences.
    @ObservedObject private var preferences = PreferencesModel.shared

    func makeNSView(context: Context) -> CanvasNSView {
        let v = CanvasNSView()
        v.document = document
        return v
    }

    func updateNSView(_ v: CanvasNSView, context: Context) {
        v.document = document
        // Clearing on every update would wipe a half-built arc or dimension as soon as the mouse
        // moved (the cursor position is published); clear only when the tool changes.
        if v.transientStateTool != document.activeTool {
            v.transientStateTool = document.activeTool
            v.clickPoints = []
            v.pen = PenPath()
        }
        v.handle(document.canvasRequest)
        v.needsDisplay = true
    }
}

/// Vertical palette of drawing tools shown over the canvas' left edge.
struct ToolPalette: View {
    @ObservedObject var document: LoftLineDocument

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(CanvasTool.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider().frame(width: 24).padding(.vertical, 2) }
                ForEach(group) { tool in
                    Button {
                        document.activeTool = tool
                    } label: {
                        ToolGlyph(tool: tool)
                            .frame(width: 28, height: 26)
                            .background(document.activeTool == tool ? Color.accentColor.opacity(0.25) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 5))
                            // A plain button only hit-tests what it draws, so without this the target was the glyph (11–17 pt).
                            .contentShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help(tool.titleWithKey)
                    .accessibilityLabel(tool.title)
                    .accessibilityAddTraits(document.activeTool == tool ? .isSelected : [])
                }
            }
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 1)
    }
}

/// A tool's icon: its SF Symbol, or a drawn glyph where no symbol fits.
struct ToolGlyph: View {
    var tool: CanvasTool

    var body: some View {
        if tool == .arc {
            ArcGlyph().stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round)).frame(width: 14, height: 14)
        } else {
            Image(systemName: tool.systemImage)
        }
    }
}

/// A quarter-circle arc with a dot at each end, so it reads as "arc" and not as a half-filled disc.
struct ArcGlyph: SwiftUI.Shape {
    func path(in rect: CGRect) -> SwiftUI.Path {
        var p = SwiftUI.Path()
        let r = min(rect.width, rect.height)
        p.addArc(center: CGPoint(x: rect.minX, y: rect.maxY), radius: r, startAngle: .degrees(-90), endAngle: .degrees(0),
                 clockwise: false)
        for end in [CGPoint(x: rect.minX, y: rect.maxY - r), CGPoint(x: rect.minX + r, y: rect.maxY)] {
            p.addEllipse(in: CGRect(x: end.x - 1.6, y: end.y - 1.6, width: 3.2, height: 3.2))
        }
        return p
    }
}
