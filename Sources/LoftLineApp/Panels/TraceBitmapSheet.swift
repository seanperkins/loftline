import AppKit
import CADCore
import CAMCore
import SwiftUI
import UniformTypeIdentifiers
import LoftLineKit

/// Trace Bitmap: pick an image, threshold it into regions and add their outlines as vectors.
struct TraceBitmapSheet: View {
    @ObservedObject var document: LoftLineDocument
    @Environment(\.dismiss) private var dismiss
    @State private var fileName = ""
    @State private var image: GrayBitmap?
    @State private var options = BitmapTracer.Options()
    @State private var resolution = 800
    @State private var width: Double
    @State private var traced: [Path] = []
    @State private var sourceData: Data?
    /// Background trace (debounced); only the newest one may publish its result.
    @State private var traceTask: Task<Void, Never>?
    @State private var generation = 0
    @State private var busy = false
    /// Why the image could not be used, shown above the buttons (an alert on the document would sit under this sheet).
    @State private var failure: String?

    init(document: LoftLineDocument) {
        self.document = document
        _width = State(initialValue: min(document.document.job.width, document.document.job.height) * 0.6)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trace Bitmap").font(.title3.bold())
            HStack {
                Button("Choose Image…") { chooseImage() }
                Text(fileName.isEmpty ? "No image" : fileName).foregroundStyle(.secondary).lineLimit(1)
            }
            if let img = image {
                preview(img)
                    .frame(height: 220)
                    .frame(maxWidth: .infinity)
                    .background(Color.white)
                    .border(Color.secondary.opacity(0.4))
                Form {
                    LabeledContent("Threshold") {
                        Slider(value: Binding(get: { Double(options.threshold) }, set: { options.threshold = Int($0) }), in: 1...254)
                            .frame(width: 180)
                    }
                    Toggle("Trace light areas instead of dark", isOn: $options.invert)
                    IntField("Ignore specks under", value: $options.minArea, range: 0...10_000)
                    NumberField("Simplify", value: $options.simplify, unit: "px", help: "Largest deviation from the pixel outline")
                    IntField("Corner smoothing", value: $options.smoothing, range: 0...6)
                    IntField("Resolution (longest side)", value: $resolution, range: 100...3000)
                    LengthField("Width", value: $width, units: document.units, help: "Size of the traced vectors (height follows)")
                }
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.small) }
                    Text("\(traced.count) outline\(traced.count == 1 ? "" : "s"), \(img.width)×\(img.height) px. Placed on the center of the material.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Choose a PNG, JPEG, TIFF or other image. Dark areas become filled regions (closed vectors) ready for pocketing, V-carving or profiling.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            SheetErrorRow(message: failure)
            HStack {
                Spacer()
                Button("Cancel") { traceTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Vectors") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || traced.isEmpty || width <= 0)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onChange(of: options.threshold) { _, _ in retrace() }
        .onChange(of: options.invert) { _, _ in retrace() }
        .onChange(of: options.minArea) { _, _ in retrace() }
        .onChange(of: options.simplify) { _, _ in retrace() }
        .onChange(of: options.smoothing) { _, _ in retrace() }
        .onChange(of: resolution) { _, _ in schedule(decode: true) }
        .onDisappear { traceTask?.cancel() }
    }

    private func preview(_ img: GrayBitmap) -> some View {
        Canvas { ctx, size in
            let s = min(size.width / CGFloat(img.width), size.height / CGFloat(img.height))
            let ox = (size.width - CGFloat(img.width) * s) / 2, oy = (size.height - CGFloat(img.height) * s) / 2
            var path = SwiftUI.Path()
            for p in traced {
                let pts = p.flattened(tolerance: 0.25)
                guard let f = pts.first else { continue }
                func v(_ q: Vec2) -> CGPoint { CGPoint(x: ox + CGFloat(q.x) * s, y: oy + (CGFloat(img.height) - CGFloat(q.y)) * s) }
                path.move(to: v(f))
                for q in pts.dropFirst() { path.addLine(to: v(q)) }
                path.closeSubpath()
            }
            ctx.fill(path, with: .color(.black.opacity(0.75)), style: FillStyle(eoFill: true))
            ctx.stroke(path, with: .color(.blue), lineWidth: 1)
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .gif, .heic, .image]
        panel.message = "Choose an image to trace"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        failure = nil
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            failure = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
            return
        }
        sourceData = data
        fileName = url.lastPathComponent
        reload()
        if image == nil { failure = "\(fileName) could not be read as an image." }
    }

    private func reload() {
        guard let data = sourceData else { return }
        image = GrayBitmap.decode(data, maxSide: resolution)
        retrace()
    }

    private func retrace() { schedule(decode: false) }

    /// Traces (and, after a resolution change, re-decodes) off the main thread, ~100 ms after the
    /// last change, so dragging the threshold slider never blocks the UI. Stale runs are dropped.
    private func schedule(decode: Bool) {
        traceTask?.cancel()
        guard let data = sourceData, let current = image else { traced = []; busy = false; return }
        generation += 1
        let gen = generation, opts = options, maxSide = resolution
        busy = true
        traceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { () -> (GrayBitmap, [Path])? in
                guard let img = decode ? GrayBitmap.decode(data, maxSide: maxSide) : current else { return nil }
                return (img, BitmapTracer.trace(img, options: opts))
            }.value
            guard !Task.isCancelled, gen == generation else { return }
            if let (img, paths) = result { image = img; traced = paths }
            busy = false
        }
    }

    private func create() {
        guard let img = image else { return }
        let placed = VectorCommands.placeTrace(traced, imageSize: Vec2(Double(img.width), Double(img.height)), width: width,
                                               center: document.document.job.materialBounds.center)
        let name = "Trace " + (fileName as NSString).deletingPathExtension
        let layer = document.currentLayerID
        var newID: UUID?
        document.perform("Trace Bitmap") { newID = VectorCommands.addTrace(placed, name: name, layer: layer, in: &$0) }
        if let id = newID { document.setSelection([id]) }
        dismiss()
    }
}
