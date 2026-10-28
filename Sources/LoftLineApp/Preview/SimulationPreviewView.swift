// 3D material-removal preview with play/scrub controls. Owned by the preview workstream.
import AppKit
import CADCore
import CAMCore
import PostCore
import SceneKit
import SwiftUI

/// SCNView wrapper with built-in orbit (drag), zoom (scroll/pinch) and pan (option-drag).
struct StockSceneView: NSViewRepresentable {
    let stockScene: StockScene
    /// When set, a click reports its material-frame point: on the stock when it was hit, else on
    /// the material-top plane (z = 0).
    var onPick: ((Preview3DPick) -> Void)? = nil

    final class Coordinator: NSObject {
        var parent: StockSceneView
        weak var view: SCNView?
        init(_ parent: StockSceneView) { self.parent = parent }

        @MainActor @objc func clicked(_ g: NSClickGestureRecognizer) {
            guard let view, let onPick = parent.onPick else { return }
            let loc = g.location(in: view)
            let scene = parent.stockScene
            let hits = view.hitTest(loc, options: [.searchMode: SCNHitTestSearchMode.all.rawValue,
                                                   .ignoreHiddenNodes: true])
            let world: SCNVector3
            let point: Vec3
            let onStock: Bool
            if let hit = hits.first(where: { scene.isStock($0.node) }) {
                world = hit.worldCoordinates
                point = scene.materialPoint(fromWorld: world)
                onStock = true
            } else {
                let near = view.unprojectPoint(SCNVector3(loc.x, loc.y, 0))
                let far = view.unprojectPoint(SCNVector3(loc.x, loc.y, 1))
                guard let p = scene.materialTopPoint(near: near, far: far) else { return }
                point = p
                world = scene.content.convertPosition(SCNVector3(p.x, p.y, p.z), to: nil)
                onStock = false
            }
            // About 8 pixels at the clicked depth, in material units.
            let screen = view.projectPoint(world)
            let side = view.unprojectPoint(SCNVector3(screen.x + 8, screen.y, screen.z))
            let tolerance = point.distance(to: scene.materialPoint(fromWorld: side))
            onPick(Preview3DPick(point: point, tolerance: tolerance.isFinite && tolerance > 0 ? tolerance : 1e-3,
                                 onStock: onStock))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SCNView {
        let v = SCNView()
        context.coordinator.view = v
        stockScene.attachedView = v
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        v.addGestureRecognizer(click)
        v.scene = stockScene.scene
        v.pointOfView = stockScene.cameraNode
        v.allowsCameraControl = true
        v.defaultCameraController.interactionMode = .orbitTurntable
        v.defaultCameraController.inertiaEnabled = true
        v.antialiasingMode = .multisampling4X
        v.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1)
        v.autoenablesDefaultLighting = false
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) {
        context.coordinator.parent = self
        if v.scene !== stockScene.scene { v.scene = stockScene.scene }
        v.defaultCameraController.target = stockScene.center
        v.defaultCameraController.worldUp = SCNVector3(0, 1, 0)
    }
}

/// 3D simulation of the given toolpaths on the job's stock.
/// `rapidRate` is in document units per minute (see `rapidRate(for:units:)`).
struct SimulationPreviewView: View {
    var job: JobSetup
    var units: LengthUnit
    var toolpaths: [Toolpath]
    var rapidRate: Double
    /// When set, a picker chooses which toolpaths are simulated (all / visible / selected).
    var scope: Binding<PreviewScope>? = nil
    var emptyMessage = "No toolpaths to simulate"
    /// Used for the default file name when saving an image.
    var documentName = "Untitled"
    /// Design vectors (material-frame polylines) that "Show ▸ Vectors" draws on the stock top.
    var vectors: [[Vec2]] = []
    /// Selected design vectors, drawn highlighted.
    var selectedVectors: [[Vec2]] = []
    /// When set, the Draw tool is offered; called with each finished polyline and whether it closed.
    var onDrawShape: (([Vec2], Bool) -> Void)? = nil
    /// When set, the Select tool is offered; called with the clicked point and a pick tolerance.
    var onSelectAt: ((Vec2, Double) -> Void)? = nil

    @StateObject private var model = SimulationPreviewModel()
    @ObservedObject private var timeStore = TimeEstimateStore.shared
    @State private var showTimeSettings = false
    @ObservedObject private var appearanceStore = PreviewAppearanceStore.shared
    @State private var showAppearance = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                StockSceneView(stockScene: model.stockScene, onPick: pickHandler)
                infoBadge.padding(8)
                if model.isMeasuring {
                    measureBadge.padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
                if model.tool == .draw {
                    drawBadge.padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            Divider()
            controls.padding(.horizontal, 12).padding(.vertical, 8)
        }
        .onAppear(perform: configure)
        .onChange(of: toolpaths) { _, _ in configure() }
        .onChange(of: job) { _, _ in configure() }
        .onChange(of: rapidRate) { _, _ in configure() }
        .onChange(of: vectors) { _, v in model.setVectors(v) }
        .onChange(of: selectedVectors) { _, v in model.setSelectedVectors(v) }
        .onChange(of: timeStore.settings) { _, _ in configure() }
        .onChange(of: appearanceStore.settings) { _, s in model.setAppearance(s.appearance) }
    }

    private var pickHandler: ((Preview3DPick) -> Void)? {
        guard model.tool != .none else { return nil }
        let m = model
        return { p in m.handle(p) }
    }

    private func configure() {
        model.setAppearance(appearanceStore.settings.appearance)
        model.setVectors(vectors)
        model.setSelectedVectors(selectedVectors)
        model.onDrawShape = onDrawShape
        model.onSelectAt = onSelectAt
        model.configure(job: job, toolpaths: toolpaths, rapidRate: rapidRate, units: units,
                        timeSettings: timeStore.settings)
    }

    private var infoBadge: some View {
        VStack(alignment: .leading, spacing: 2) {
            if toolpaths.isEmpty {
                Text(emptyMessage).font(.callout.bold())
            } else {
                Text(model.activeToolpathName ?? "—").font(.callout.bold())
                if let m = model.moveLabel { Text(m).monospacedDigit() }
                Text("Estimated time \(MachiningTimeEstimator.format(model.totalTime))")
                Text(String(format: "Resolution %.3g %@", model.cellSize, units.abbreviation))
            }
        }
        .font(.caption)
        .foregroundStyle(.white)
        .padding(6)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
    }

    private var measureBadge: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.measurement.lines(units: units, thickness: job.thickness), id: \.self) { Text($0) }
            }
            .font(.caption.monospacedDigit())
            if !model.measurement.isEmpty {
                Button("Clear") { model.clearMeasurement() }.controlSize(.small)
            }
        }
        .foregroundStyle(.white)
        .padding(6)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
    }

    private var drawBadge: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(model.drawing.isEmpty
                 ? "Click the stock to start a line. Click the first point to close it, the last point (or Return) to finish."
                 : "\(model.drawing.points.count) point\(model.drawing.points.count == 1 ? "" : "s") · click the first point to close, the last point or Return to finish")
                .font(.caption)
            if !model.drawing.isEmpty {
                Button("Undo Point") { model.undoDrawingPoint() }.controlSize(.small)
                Button("Finish") { model.finishDrawing() }
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: [])
                Button("Cancel") { model.cancelDrawing() }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .foregroundStyle(.white)
        .padding(6)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Select / draw buttons (only where the host can apply them to the design).
    @ViewBuilder private var designTools: some View {
        if onSelectAt != nil {
            Toggle(isOn: toolBinding(.select)) { Image(systemName: "cursorarrow") }
                .toggleStyle(.button)
                .help("Select vectors by clicking them in the 3D view")
                .accessibilityLabel("Select vectors in the 3D view")
        }
        if onDrawShape != nil {
            Toggle(isOn: toolBinding(.draw)) { Image(systemName: "pencil.line") }
                .toggleStyle(.button)
                .help("Draw a polyline on the material top by clicking points in the 3D view")
                .accessibilityLabel("Draw a polyline in the 3D view")
        }
    }

    private func toolBinding(_ t: Preview3DTool) -> Binding<Bool> {
        Binding(get: { model.tool == t }, set: { model.tool = $0 ? t : .none })
    }

    /// Wraps onto further lines in a narrow pane (the sidebar and inspector leave about 430 pt at the
    /// minimum window width) rather than forcing the whole window layout wider than the screen.
    private var controls: some View {
        WrappingHStack(spacing: 10, lineSpacing: 8) {
            if let scope {
                Picker("Simulate", selection: scope) {
                    ForEach(PreviewScope.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
                .help("Which toolpaths to simulate")
            }
            playbackControls
            designTools
        }
    }

    @ViewBuilder private var playbackControls: some View {
        Group {
            Button(action: model.rewind) { Image(systemName: "backward.end.fill") }
                .help("Back to start")
                .accessibilityLabel("Back to start")
            Button(action: model.togglePlay) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help(model.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            Button(action: model.stepBackward) { Image(systemName: "backward.frame.fill") }
                .help("Step back one move")
                .accessibilityLabel("Step back one move")
            Button(action: model.stepForward) { Image(systemName: "forward.frame.fill") }
                .help("Step forward one move")
                .accessibilityLabel("Step forward one move")
            Button(action: model.runToNextRetract) { Image(systemName: "arrow.up.to.line") }
                .help("Run to the next retract")
                .accessibilityLabel("Run to the next retract")
            Button(action: model.jumpToEnd) { Image(systemName: "forward.end.fill") }
                .help("Show finished result")
                .accessibilityLabel("Show finished result")
            Slider(value: Binding(get: { model.progress }, set: { model.pause(); model.progress = $0 }),
                   in: 0...1)
                .frame(minWidth: 160)
                .flexibleInWrappingStack()
            PlaybackTimeLabel(time: model.time, total: model.totalTime)
            Picker("Speed", selection: $model.speed) {
                ForEach(PlaybackSpeed.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 100)
            Toggle("Tool", isOn: $model.showTool).toggleStyle(.checkbox)
            showMenu
            Button { PreviewImageExport.runSavePanel(stockScene: model.stockScene, documentName: documentName) } label: {
                Image(systemName: "camera")
            }
            .help("Save the preview as an image…")
                .accessibilityLabel("Save the preview as an image")
            Toggle(isOn: toolBinding(.measure)) { Image(systemName: "ruler") }
                .toggleStyle(.button)
                .help("Measure: click the stock for a depth, click again for a distance")
                .accessibilityLabel("Measure")
            Button { showAppearance.toggle() } label: { Image(systemName: "paintpalette") }
                .help("Material appearance")
                .accessibilityLabel("Material appearance")
                .popover(isPresented: $showAppearance) { PreviewAppearancePopover(store: appearanceStore) }
            Button { showTimeSettings.toggle() } label: { Image(systemName: "stopwatch") }
                .help("Time estimate settings (acceleration, calibration)")
                .accessibilityLabel("Time estimate settings")
                .popover(isPresented: $showTimeSettings) {
                    TimeEstimatePopover(store: timeStore, toolpaths: toolpaths, rapidRate: rapidRate, units: units)
                }
            viewMenu
            BusyIndicator(isBusy: model.isBusy)
        }
        .disabled(toolpaths.isEmpty)
    }

    /// What is drawn over the simulated stock.
    private var showMenu: some View {
        Menu {
            Toggle("Toolpath Lines", isOn: $model.showToolpathLines)
            Toggle("Rapid Moves", isOn: $model.showRapidLines).disabled(!model.showToolpathLines)
            Toggle("Vectors", isOn: $model.showVectors)
        } label: {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
        }
        .menuIndicator(.visible)
        .fixedSize()
        .help("Show toolpath lines, rapids and design vectors in the 3D view")
                .accessibilityLabel("Show in the 3D view")
    }

    /// Standard view directions and the orthographic switch.
    private var viewMenu: some View {
        Menu {
            ForEach(PreviewViewDirection.allCases) { d in
                Button { model.setView(d) } label: { Label(d.title, systemImage: d.systemImage) }
            }
            Divider()
            Toggle("Orthographic", isOn: $model.isOrthographic)
        } label: {
            Image(systemName: "cube.transparent")
        } primaryAction: {
            model.resetCamera()
        }
        .menuIndicator(.visible)
        .fixedSize()
        .help("Reset the view (the arrow lists top, front, side and isometric views and orthographic mode)")
        .accessibilityLabel("View direction")
    }

    /// Profile rapid rate converted to `units` per minute.
    static func rapidRate(for profile: PostProfile, units: LengthUnit) -> Double {
        profile.units.convert(profile.rapidRate, to: units)
    }
}

/// Preview panel with 2D overlay and 3D simulation tabs, for the app shell to embed.
struct ToolpathPreviewPanel: View {
    enum Mode: String, CaseIterable, Identifiable {
        case twoD = "2D Toolpaths", threeD = "3D Simulation"
        var id: Self { self }
    }

    var document: Document
    var toolpaths: [Toolpath]
    var postProfile: PostProfile = BuiltInPosts.avidMach4Inch
    @State private var mode: Mode = .threeD
    @State private var showRapids = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280)
                Spacer()
                if mode == .twoD { Toggle("Rapids", isOn: $showRapids).toggleStyle(.checkbox) }
            }
            .padding(8)
            Divider()
            switch mode {
            case .twoD:
                ToolpathOverlayView(document: document, toolpaths: toolpaths, showRapids: showRapids)
            case .threeD:
                SimulationPreviewView(
                    job: document.job, units: document.units, toolpaths: toolpaths,
                    rapidRate: SimulationPreviewView.rapidRate(for: postProfile, units: document.units))
            }
        }
    }
}

/// "1m 02s / 15m 37s" under the 3D preview. Its width is that of the total time on both sides, which no running time
/// exceeds, so it keeps one width for the whole simulation: the playback bar wraps in a narrow pane, and a label that
/// grew as the clock ran re-wrapped the bar mid-playback, shrinking the 3D view so the stock seemed to jump with the tool.
struct PlaybackTimeLabel: View {
    var time: TimeInterval
    var total: TimeInterval

    static func text(time: TimeInterval, total: TimeInterval) -> String {
        "\(MachiningTimeEstimator.format(time)) / \(MachiningTimeEstimator.format(total))"
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Text(Self.text(time: total, total: total)).hidden()
            Text(Self.text(time: time, total: total))
        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
        .fixedSize()
    }
}

/// Shown while a simulation frame is being rendered. It always takes the same room and only fades in: in the wrapping
/// playback bar a spinner that came and went with every frame reflowed the bar, the 3D view above it changed height, and
/// the stock seemed to jump with the tool.
struct BusyIndicator: View {
    var isBusy: Bool

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(width: 16, height: 16)
            .opacity(isBusy ? 1 : 0)
            .accessibilityHidden(!isBusy)
    }
}
