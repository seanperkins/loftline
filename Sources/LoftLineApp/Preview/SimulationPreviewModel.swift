// Drives the 3D preview: background simulation, play/scrub state. Owned by preview.
import CADCore
import CAMCore
import Foundation
import SwiftUI
import LoftLineKit

/// One rendered simulation state.
struct SimulationFrame: Sendable {
    var mesh: HeightfieldMesh
    /// Cutter tip in the material frame (z = -depth) and its toolpath index.
    var tip: Vec3?
    var toolpathIndex: Int?
}

/// Owns the `SimulationPlayer` off the main thread.
actor SimulationEngine {
    private var player: SimulationPlayer
    private let thickness: Double
    private let coords: MachineCoordinates
    private let maxVertices: Int
    private var appearance: StockAppearance
    private let unitsPerInch: Double

    init(player: SimulationPlayer, job: JobSetup, maxVertices: Int, appearance: StockAppearance = .default,
         unitsPerInch: Double = 1) {
        self.player = player
        thickness = job.thickness
        coords = MachineCoordinates(job: job)
        self.maxVertices = maxVertices
        self.appearance = appearance
        self.unitsPerInch = unitsPerInch
    }

    func setAppearance(_ a: StockAppearance) { appearance = a }

    /// `p` with its depth read from the current simulated stock.
    func refine(_ p: Vec3) -> Vec3 { PreviewMeasurement.refined(p, heightfield: player.heightfield) }

    func frame(at time: TimeInterval) -> SimulationFrame {
        player.seek(to: time)
        let mesh = HeightfieldMesh(heightfield: player.heightfield, thickness: thickness,
                                   maxVertices: maxVertices, appearance: appearance, unitsPerInch: unitsPerInch)
        guard let pos = player.timeline.toolPosition(at: time) else {
            return SimulationFrame(mesh: mesh)
        }
        let m = coords.material(fromMachine: pos.point)
        return SimulationFrame(mesh: mesh, tip: Vec3(m.xy, z: -m.depth), toolpathIndex: pos.toolpathIndex)
    }
}

enum PlaybackSpeed: Hashable, CaseIterable, Identifiable {
    case realTime, x10, x50, x250, fit20s

    var id: Self { self }

    var label: String {
        switch self {
        case .realTime: return "1x"
        case .x10: return "10x"
        case .x50: return "50x"
        case .x250: return "250x"
        case .fit20s: return "Fit (20 s)"
        }
    }

    func multiplier(totalTime: TimeInterval) -> Double {
        switch self {
        case .realTime: return 1
        case .x10: return 10
        case .x50: return 50
        case .x250: return 250
        case .fit20s: return max(1, totalTime / 20)
        }
    }
}

@MainActor
final class SimulationPreviewModel: ObservableObject {
    #if DEBUG
    /// The model most recently created, so the UI harness can scrub the simulation and set the view.
    static weak var harnessCurrent: SimulationPreviewModel?
    init() { Self.harnessCurrent = self }
    #endif

    @Published var time: TimeInterval = 0 {
        didSet { if time != oldValue { requestFrame(); updateMoveLabel() } }
    }
    /// "Move 12 / 340 · Feed" for the move in progress.
    @Published private(set) var moveLabel: String?
    private var moves: SimulationMoveIndex?
    /// Playback stops here (run to next retract) instead of at the end.
    private var stopTime: TimeInterval?
    @Published private(set) var totalTime: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published var speed: PlaybackSpeed = .fit20s
    @Published var showTool = true { didSet { applyTool() } }
    @Published private(set) var activeToolpathName: String?
    @Published private(set) var cellSize: Double = 0
    @Published private(set) var isBusy = false

    let stockScene = StockScene()
    private var engine: SimulationEngine?
    private var toolpaths: [Toolpath] = []
    private var shapes: [ToolShape] = []
    private var pendingTime: TimeInterval?
    private var rendering = false
    private var playTask: Task<Void, Never>?
    private var lastFrame: SimulationFrame?
    private var configuredKey: Int?
    private(set) var appearance = StockAppearance.default
    /// What a click on the 3D view does (select, draw, measure or nothing).
    @Published var tool = Preview3DTool.none {
        didSet {
            guard tool != oldValue else { return }
            if oldValue == .measure { clearMeasurement() }
            if oldValue == .draw { cancelDrawing() }
            // Drawing and selecting show the vectors (`vectorsShown`) without changing the saved preference.
            applyOverlay()
        }
    }
    var isMeasuring: Bool {
        get { tool == .measure }
        set { tool = newValue ? .measure : (tool == .measure ? .none : tool) }
    }
    @Published private(set) var measurement = PreviewMeasurement()

    // MARK: Drawing and picking in 3D

    /// The polyline being drawn in the 3D view.
    @Published private(set) var drawing = Preview3DDrawing()
    /// Called with a finished drawing (material/document frame) and whether it is closed.
    var onDrawShape: (([Vec2], Bool) -> Void)?
    /// Called with the clicked material-frame point and a pick tolerance in select mode.
    var onSelectAt: ((Vec2, Double) -> Void)?

    /// A click on the 3D view, routed by the current tool.
    func handle(_ pick: Preview3DPick) {
        switch tool {
        case .none: break
        case .measure: if pick.onStock { self.pick(pick.point) }
        case .select: onSelectAt?(pick.point.xy, pick.tolerance)
        case .draw:
            let targets = vectors.flatMap { $0 }
            let result = drawing.click(pick.point.xy, tolerance: pick.tolerance, snapTargets: targets)
            if case let .finished(points, closed) = result { onDrawShape?(points, closed) }
            stockScene.showDraft(drawing.points)
        }
    }

    /// Finishes the drawing as an open polyline (Return).
    func finishDrawing() {
        if let pts = drawing.finish() { onDrawShape?(pts, false) }
        stockScene.showDraft([])
    }

    func undoDrawingPoint() {
        drawing.undoLastPoint()
        stockScene.showDraft(drawing.points)
    }

    func cancelDrawing() {
        drawing.cancel()
        stockScene.showDraft([])
    }

    /// Selected design vectors, drawn highlighted.
    func setSelectedVectors(_ v: [[Vec2]]) {
        guard v != selectedVectors else { return }
        selectedVectors = v
        applyOverlay()
    }
    private var selectedVectors: [[Vec2]] = []

    // MARK: Toolpath and vector lines

    static let showToolpathsKey = "preview3D.showToolpaths"
    static let showRapidsKey = "preview3D.showRapids"
    static let showVectorsKey = "preview3D.showVectors"

    private static func storedFlag(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    /// Toolpath centre lines drawn in the 3D view.
    @Published var showToolpathLines = storedFlag(showToolpathsKey, default: true) {
        didSet { UserDefaults.standard.set(showToolpathLines, forKey: Self.showToolpathsKey); applyOverlay() }
    }
    /// Rapid moves drawn with the toolpath lines.
    @Published var showRapidLines = storedFlag(showRapidsKey, default: true) {
        didSet { UserDefaults.standard.set(showRapidLines, forKey: Self.showRapidsKey); applyOverlay() }
    }
    /// Design vectors drawn on the material top: the saved preference itself, with no copy here, so every window
    /// reads the same value (a window's view refreshes its overlay when another changes it, `preferenceChanged`).
    var showVectors: Bool {
        get { UserDefaults.standard.bool(forKey: Self.showVectorsKey) }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.showVectorsKey)
            applyOverlay()
        }
    }
    /// Vectors are on screen when the preference says so, and always while drawing or selecting in 3D.
    var vectorsShown: Bool { showVectors || tool == .draw || tool == .select }

    /// The preference changed (in this window or another): redraw the overlay.
    func preferenceChanged() {
        objectWillChange.send()
        applyOverlay()
    }
    private var lines = ToolpathLines3D()
    private var vectors: [[Vec2]] = []

    /// With no toolpaths the 3D toolbar is disabled: a tool chosen there (Measure, Draw, Select) ends rather than stay
    /// on with no way to switch it off.
    func toolpathsChanged(isEmpty: Bool) {
        if isEmpty { tool = .none }
    }

    /// Design vectors (material frame polylines; closed ones repeat their first point).
    func setVectors(_ v: [[Vec2]]) {
        guard v != vectors else { return }
        vectors = v
        applyOverlay()
    }

    private func applyOverlay() {
        stockScene.showOverlay(toolpaths: showToolpathLines ? lines : nil, showRapids: showRapidLines,
                               vectors: vectorsShown ? vectors : [], selected: vectorsShown ? selectedVectors : [])
    }

    /// A click on the stock while measuring (material frame, z = -depth).
    func pick(_ p: Vec3) {
        guard isMeasuring, let engine else { return }
        Task { [weak self] in
            let refined = await engine.refine(p)
            guard let self, self.isMeasuring else { return }
            self.measurement.add(refined)
            self.stockScene.showMeasurement(self.measurement.points)
        }
    }

    func clearMeasurement() {
        measurement.clear()
        stockScene.showMeasurement([])
    }

    /// Recolours the stock without re-simulating.
    func setAppearance(_ a: StockAppearance) {
        guard a != appearance else { return }
        appearance = a
        stockScene.shininess = a.shininess
        guard let engine else { return }
        Task { [weak self] in
            await engine.setAppearance(a)
            self?.requestFrame()
        }
    }

    /// Rebuilds the simulation when the inputs change (cheap no-op otherwise).
    func configure(job: JobSetup, toolpaths: [Toolpath], rapidRate: Double, units: LengthUnit,
                   timeSettings: TimeEstimateSettings = TimeEstimateSettings()) {
        let motion = timeSettings.motion(units: units)
        var hasher = Hasher()
        hasher.combine(job); hasher.combine(rapidRate)
        // A tool renamed in the database is renamed in place in its toolpaths; that is not a new simulation.
        for var tp in toolpaths { tp.tool.name = ""; hasher.combine(tp) }
        hasher.combine(motion); hasher.combine(timeSettings.toolChangeSeconds)
        let key = hasher.finalize()
        guard key != configuredKey else { return }
        configuredKey = key
        pause()
        clearMeasurement()
        self.toolpaths = toolpaths
        shapes = toolpaths.map { ToolShape(tool: $0.tool) }
        let minCell = units == .inch ? 0.004 : 0.1
        let cell = Heightfield.automaticCellSize(width: job.width, height: job.height,
                                                 targetCells: 800_000, minimum: minCell)
        cellSize = cell
        let player = SimulationPlayer(job: job, toolpaths: toolpaths, rapidRate: rapidRate, cellSize: cell,
                                      toolChangeSeconds: timeSettings.toolChangeSeconds, motion: motion)
        totalTime = player.timeline.totalTime
        moves = SimulationMoveIndex(timeline: player.timeline)
        lines = ToolpathLines3D(toolpaths: toolpaths, coords: MachineCoordinates(job: job))
        updateMoveLabel()
        engine = SimulationEngine(player: player, job: job, maxVertices: 200_000, appearance: appearance,
                                  unitsPerInch: LengthUnit.inch.factor(to: units))
        stockScene.configure(job: job)
        applyOverlay()
        // Show the finished result by default; scrub back to watch it being cut.
        if time == totalTime { requestFrame() } else { time = totalTime }
    }

    var progress: Double {
        get { totalTime > 0 ? time / totalTime : 0 }
        set { time = min(max(newValue, 0), 1) * totalTime }
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        stopTime = nil
        startPlayback()
    }

    // MARK: Stepping

    /// Jumps to the end of the move in progress.
    func stepForward() {
        guard let moves else { return }
        pause()
        time = moves.nextBoundary(after: time)
    }

    /// Jumps back to the start of the move in progress (or the previous move).
    func stepBackward() {
        guard let moves else { return }
        pause()
        time = moves.previousBoundary(before: time)
    }

    /// Plays at the current speed until the tool next retracts.
    func runToNextRetract() {
        guard let moves, totalTime > 0 else { return }
        if time >= totalTime { time = 0 }
        stopTime = moves.nextRetract(after: time)
        startPlayback()
    }

    private func updateMoveLabel() {
        guard let moves, !moves.spans.isEmpty else { moveLabel = nil; return }
        guard let i = moves.spanIndex(at: time) else {
            moveLabel = "Move \(moves.spans.count) / \(moves.spans.count) · finished"
            return
        }
        let s = moves.spans[i]
        let kind = s.isRetract ? "Retract" : (s.isRapid ? "Rapid" : (s.rise < -1e-9 ? "Plunge" : "Feed"))
        moveLabel = "Move \(i + 1) / \(moves.spans.count) · \(kind)"
    }

    private func startPlayback() {
        guard totalTime > 0 else { return }
        if time >= totalTime { time = 0 }
        isPlaying = true
        playTask?.cancel()
        playTask = Task { [weak self] in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_000_000)
                guard let self, self.isPlaying else { return }
                let now = Date()
                let dt = now.timeIntervalSince(last)
                last = now
                let next = self.time + dt * self.speed.multiplier(totalTime: self.totalTime)
                let end = min(self.stopTime ?? self.totalTime, self.totalTime)
                if next >= end {
                    self.time = end
                    self.pause()
                    return
                }
                self.time = next
            }
        }
    }

    func pause() {
        isPlaying = false
        playTask?.cancel()
        playTask = nil
    }

    func rewind() { pause(); time = 0 }
    func jumpToEnd() { pause(); time = totalTime }
    func resetCamera() { stockScene.resetCamera() }
    func setView(_ direction: PreviewViewDirection) { stockScene.setView(direction) }
    /// Parallel projection (no perspective), handy with the top / front / side views.
    @Published var isOrthographic = false { didSet { stockScene.isOrthographic = isOrthographic } }

    private func requestFrame() {
        guard engine != nil else { return }
        if rendering { pendingTime = time; return }
        render(at: time)
    }

    private func render(at t: TimeInterval) {
        guard let engine else { return }
        rendering = true
        isBusy = true
        Task { [weak self] in
            let frame = await engine.frame(at: t)
            guard let self else { return }
            self.apply(frame)
            self.rendering = false
            if let next = self.pendingTime {
                self.pendingTime = nil
                self.render(at: next)
            } else {
                self.isBusy = false
            }
        }
    }

    private func apply(_ frame: SimulationFrame) {
        lastFrame = frame
        stockScene.updateStock(frame.mesh)
        activeToolpathName = frame.toolpathIndex.flatMap { toolpaths.indices.contains($0) ? toolpaths[$0].name : nil }
        applyTool()
    }

    private func applyTool() {
        guard showTool, let f = lastFrame, let i = f.toolpathIndex, shapes.indices.contains(i) else {
            stockScene.updateTool(tip: nil, shape: nil)
            return
        }
        stockScene.updateTool(tip: f.tip, shape: shapes[i])
    }
}
