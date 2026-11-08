import CADCore
import CAMCore
import SwiftUI
import LoftLineKit

/// Left sidebar: Design (layers / objects / models) and Toolpaths tabs.
struct SidebarView: View {
    @ObservedObject var document: LoftLineDocument

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $document.sidebarTab) {
                ForEach(SidebarTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            switch document.sidebarTab {
            case .design: DesignSidebar(document: document)
            case .toolpaths: ToolpathsSidebar(document: document)
            }
        }
    }
}

// MARK: Design tab

struct DesignSidebar: View {
    @ObservedObject var document: LoftLineDocument

    private var selectionBinding: Binding<Set<UUID>> {
        Binding(get: { document.selection }, set: { new in
            // Keep the existing order for already-selected shapes, append the rest.
            let kept = document.selectedShapes.map(\.id).filter(new.contains)
            document.setSelection(kept + new.subtracting(kept).sorted { $0.uuidString < $1.uuidString })
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            LayersList(document: document)
                .frame(minHeight: 120, idealHeight: 170, maxHeight: 260)
            Divider()
            HStack {
                Text("Objects").font(.headline)
                Spacer()
                Text("\(document.document.shapes.count)").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.top, 8)
            List(selection: selectionBinding) {
                ForEach(document.currentSheetLayers) { layer in
                    let shapes = document.document.shapes(inLayer: layer.id)
                    if !shapes.isEmpty {
                        Section(layer.name) {
                            ForEach(shapes) { s in ShapeRow(shape: s).tag(s.id) }
                        }
                    }
                }
                if !document.document.models.isEmpty {
                    Section("3D Models") {
                        ForEach(document.document.models) { m in
                            HStack {
                                Image(systemName: "cube")
                                Text(m.name)
                                Spacer()
                                Text("\(m.mesh.triangleCount) tris").font(.caption).foregroundStyle(.secondary)
                            }
                            .contextMenu {
                                Button("Size and Position…") { document.editPlacement(of: m.id) }
                                Button("Create 3D Toolpaths…") {
                                    if var f = document.document.model(id: m.id).map({
                                        ModelPlacementForm(editing: $0, job: document.document.job, library: document.mergedLibrary)
                                    }) {
                                        f.createToolpaths = true
                                        document.sheet = .placeModel(f)
                                    }
                                }
                                Divider()
                                Button("Delete Model") {
                                    document.perform("Delete Model") { $0.document.models.removeAll { $0.id == m.id } }
                                }
                            }
                        }
                    }
                }
                PlacedImagesSection(document: document)
            }
            .listStyle(.sidebar)
            .overlay {
                if document.document.shapes.isEmpty && document.document.models.isEmpty && document.document.placedImages.isEmpty {
                    ContentUnavailableView {
                        Label(EmptyState.noObjects.title, systemImage: EmptyState.noObjects.systemImage)
                    } description: {
                        Text(EmptyState.noObjects.detail)
                    }
                }
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if !ids.isEmpty {
                    Menu("Move to Layer") {
                        ForEach(document.document.layers) { l in
                            Button(l.name) { document.perform("Move to Layer") { $0.moveShapes(ids, toLayer: l.id) } }
                        }
                    }
                    Button("Duplicate") { document.setSelection(Array(ids)); document.duplicateSelection() }
                    Button("Delete") { document.perform("Delete Shapes") { $0.deleteShapes(ids) } }
                }
            }
        }
    }
}

struct ShapeRow: View {
    var shape: Shape

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
            Text(shape.name.isEmpty ? "Vector" : shape.name).lineLimit(1)
            Spacer()
            if shape.isLocked { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
            if !shape.isClosed { Text("open").font(.caption2).foregroundStyle(Color.warningText) }
        }
    }

    private var icon: String {
        switch shape.origin {
        case .rectangle: return "rectangle"
        case .circle: return "circle"
        case .ellipse: return "oval"
        case .polygon: return "hexagon"
        case .star: return "star"
        case .text: return "textformat"
        case .imported: return "square.and.arrow.down"
        case .derived: return "square.on.square"
        case .drawn: return "scribble"
        }
    }
}

struct LayersList: View {
    @ObservedObject var document: LoftLineDocument
    @State private var editingID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Layers").font(.headline)
                Spacer()
                Button { document.perform("Add Layer") { $0.addLayer() } } label: { Image(systemName: "plus") }
                    .buttonStyle(.icon).help("Add layer").accessibilityLabel("Add layer")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            List {
                ForEach(document.currentSheetLayers) { layer in
                    LayerRow(document: document, layer: layer)
                }
            }
            .listStyle(.plain)
        }
    }
}

struct LayerRow: View {
    @ObservedObject var document: LoftLineDocument
    var layer: Layer
    @State private var name = ""

    var body: some View {
        HStack(spacing: 6) {
            Button { update { $0.isVisible.toggle() } } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
            }
            .buttonStyle(.icon).help(layer.isVisible ? "Hide layer" : "Show layer")
            .accessibilityLabel(layer.isVisible ? "Hide layer \(layer.name)" : "Show layer \(layer.name)")
            Button { update { $0.isLocked.toggle() } } label: {
                Image(systemName: layer.isLocked ? "lock.fill" : "lock.open")
            }
            .buttonStyle(.icon).help(layer.isLocked ? "Unlock layer" : "Lock layer")
            .accessibilityLabel(layer.isLocked ? "Unlock layer \(layer.name)" : "Lock layer \(layer.name)")
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: NSColor(hex: layer.colorHex) ?? .black) },
                set: { c in update { $0.colorHex = NSColor(c).hexString } }), supportsOpacity: false)
                .labelsHidden().frame(width: 44)
                .accessibilityLabel("Color of layer \(layer.name)")
            TextField("Layer", text: $name, onCommit: { update { $0.name = name.isEmpty ? layer.name : name } })
                .textFieldStyle(.plain)
            Spacer()
            if layer.keepOut != nil {
                Image(systemName: "hand.raised.fill").foregroundStyle(.red).help("Clamp / keep-out zones: never cut, tool must stay clear")
            }
            if document.isTwoSided {
                Text(layer.side == .bottom ? "B" : "T").font(.caption2.bold()).foregroundStyle(.secondary)
                    .help(layer.side == .bottom ? "Bottom side" : "Top side")
            }
            Text("\(document.document.shapes(inLayer: layer.id).count)").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { name = layer.name }
        .onChange(of: layer.name) { _, n in name = n }
        .contextMenu {
            Button("Select Shapes on Layer") {
                document.setSelection(document.document.shapes(inLayer: layer.id).map(\.id))
            }
            Button("Move Selection to This Layer") {
                let ids = document.selection
                document.perform("Move to Layer") { $0.moveShapes(ids, toLayer: layer.id) }
            }
            .disabled(document.selection.isEmpty)
            Button(layer.keepOut == nil ? "Make Clamp / Keep-Out Layer" : "Stop Using as Clamp / Keep-Out Layer") {
                update { $0.keepOut = $0.keepOut == nil ? LayerKeepOut() : nil }
            }
            .disabled(layer.sheet != nil)
            Divider()
            Button("Move Layer Up") { document.perform("Reorder Layers") { $0.moveLayer(layer.id, by: -1) } }
                .disabled(document.document.layers.first?.id == layer.id)
            Button("Move Layer Down") { document.perform("Reorder Layers") { $0.moveLayer(layer.id, by: 1) } }
                .disabled(document.document.layers.last?.id == layer.id)
            if document.isTwoSided {
                Divider()
                Button(layer.side == .bottom ? "Move Layer to Top Side" : "Move Layer to Bottom Side") {
                    document.setLayerSide(layer.id, layer.side == .bottom ? .top : .bottom)
                }
            }
            Divider()
            Button("Delete Layer") { document.perform("Delete Layer") { $0.deleteLayer(layer.id) } }
                .disabled(document.document.layers.count <= 1)
        }
    }

    private func update(_ change: (inout Layer) -> Void) {
        var l = layer
        change(&l)
        document.perform("Edit Layer") { $0.updateLayer(l) }
    }
}

// MARK: Toolpaths tab

struct ToolpathsSidebar: View {
    @ObservedObject var document: LoftLineDocument
    @EnvironmentObject var toolLibrary: ToolLibraryModel

    private var selectedOp: Binding<UUID?> {
        Binding(get: { document.selectedOperationID }, set: { document.selectedOperationID = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Menu {
                    ForEach(OperationFactory.menuKinds, id: \.self) { kind in
                        Button(OperationFactory.menuTitle(kind)) { document.addOperation(kind) }
                    }
                } label: {
                    Label("New Toolpath", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                Toggle(isOn: $document.showToolpaths) { Image(systemName: "eye") }
                    .toggleStyle(.button).help("Show toolpaths on the canvas")
                    .accessibilityLabel("Show toolpaths on the canvas")
            }
            .padding(8)
            if document.project.operations.isEmpty {
                ContentUnavailableView {
                    Label(EmptyState.noToolpaths.title, systemImage: EmptyState.noToolpaths.systemImage)
                } description: {
                    Text(EmptyState.noToolpaths.detail)
                }
                // Fill the column: unlike the Spacers it replaces, it would otherwise let the whole stack centre.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: selectedOp) {
                    ForEach(Array(document.project.operations.enumerated()), id: \.element.id) { i, op in
                        ToolpathRow(document: document, operation: op, colorIndex: i).tag(Optional(op.id))
                            .contextMenu { rowMenu(op) }
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    footerButtons(calculate: "Calculate All", save: "Save All…")
                    footerButtons(calculate: "Calculate", save: "Save…")
                }
                .disabled(document.project.operations.isEmpty)
                ToolChangeSummaryView(document: document)
            }
            .padding(8)
        }
    }

    /// Short labels fit the sidebar's 220 pt minimum, where "Calculate All" was cut to "Calculate…".
    private func footerButtons(calculate: String, save: String) -> some View {
        HStack {
            Button(calculate) { document.calculateAll() }
                .help("Calculate all toolpaths")
            Spacer()
            Button { document.sheet = .validation } label: { Image(systemName: "checkmark.shield") }
                .help("Check toolpaths with the validator")
                .accessibilityLabel("Check toolpaths")
            Button(save) { document.sheet = .saveAllToolpaths }
                .help("Save all toolpaths: one combined file or one file per toolpath/tool")
        }
    }

    @ViewBuilder private func rowMenu(_ op: AnyOperation) -> some View {
        Button("Recalculate") { document.calculate([op.id]) }
        Button("Export G-code…") { document.sheet = .exportGCode(.operation(op.id)) }
        Button("Select Vectors") { document.setSelection(op.setup.shapeIDs) }
        Divider()
        Button("Move Up") { document.perform("Reorder Toolpaths") { $0.moveOperation(op.id, by: -1) } }
        Button("Move Down") { document.perform("Reorder Toolpaths") { $0.moveOperation(op.id, by: 1) } }
        Button("Duplicate") { document.duplicateOperation(op.id) }
        Divider()
        Button("Delete", role: .destructive) { document.deleteOperation(op.id) }
    }
}

struct ToolpathRow: View {
    @ObservedObject var document: LoftLineDocument
    var operation: AnyOperation
    var colorIndex: Int

    var body: some View {
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(get: { operation.setup.isEnabled },
                                     set: { document.setOperationEnabled(operation.id, $0) }))
                .labelsHidden().toggleStyle(.checkbox).help("Include in export")
                .accessibilityLabel("Include \(operation.setup.name) in export")
            Button { document.toggleToolpathVisibility(operation.id) } label: {
                Image(systemName: document.hiddenToolpaths.contains(operation.id) ? "eye.slash" : "eye")
            }
            .buttonStyle(.icon).help("Show/hide on canvas")
            .accessibilityLabel(document.hiddenToolpaths.contains(operation.id) ? "Show \(operation.setup.name) on canvas" : "Hide \(operation.setup.name) on canvas")
            Circle().fill(Color(nsColor: ToolpathColors.color(forIndex: colorIndex))).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(operation.setup.name).lineLimit(1)
                    if let pause = operation.setup.pauseAfter {
                        Image(systemName: "pause.circle").foregroundStyle(.secondary)
                            .help("The machine pauses after this toolpath: " + pause.text(afterToolpath: operation.setup.name))
                            .accessibilityLabel("Pauses after \(operation.setup.name)")
                    }
                }
                // The time goes first when the sidebar is narrow: the tool number matters more.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        Text(summary).lineLimit(1).fixedSize()
                        Spacer(minLength: 4)
                        if let duration { Text(duration).fixedSize() }
                    }
                    Text(summary).lineLimit(1)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            status
        }
        .opacity(operation.setup.isEnabled ? 1 : 0.55)
    }

    private var summary: String {
        let lib = document.mergedLibrary
        let tools = operation.referencedToolIDs.map { id in lib.tool(id: id).map { "T\($0.number)" } ?? "missing tool" }
        return ToolpathRowText.summary(kind: operation.kind.displayName, tools: tools)
    }

    /// The calculated time, once it is current; kept apart from the summary so a narrow sidebar
    /// truncates the tools, not the time.
    private var duration: String? {
        guard let r = document.results[operation.id], r.error == nil, !document.isStale(operation.id) else { return nil }
        return ToolpathCalculator.formatDuration(r.estimatedSeconds)
    }

    @ViewBuilder private var status: some View {
        if document.calculating.contains(operation.id) {
            ProgressView().controlSize(.small)
        } else if let r = document.results[operation.id] {
            if let err = r.error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(err)
                    .accessibilityLabel("Failed: \(err)")
            } else if document.isStale(operation.id) {
                Image(systemName: "arrow.clockwise.circle").foregroundStyle(.secondary).help("Needs recalculating")
                    .accessibilityLabel("Needs recalculating")
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .help("Calculated · " + ToolpathCalculator.formatDuration(r.estimatedSeconds))
                    .accessibilityLabel("Calculated, " + ToolpathCalculator.formatDuration(r.estimatedSeconds))
            }
        } else {
            Button { document.calculate([operation.id]) } label: { Image(systemName: "play.circle") }
                .buttonStyle(.icon).help("Calculate").accessibilityLabel("Calculate \(operation.setup.name)")
        }
    }
}

/// Text for a toolpath row, kept apart from the view so it can be tested.
enum ToolpathRowText {
    /// "Pocket · T1+T6": the kind and the tools it uses, each once. A toolpath that uses none (a merged
    /// one) is just its kind.
    static func summary(kind: String, tools: [String]) -> String {
        var unique: [String] = []
        for t in tools where !unique.contains(t) { unique.append(t) }
        return unique.isEmpty ? kind : "\(kind) · \(unique.joined(separator: "+"))"
    }
}

/// The wording of the sidebar's empty states: what is missing and the next step.
struct EmptyState {
    var title: String
    var systemImage: String
    var detail: String

    static let noToolpaths = EmptyState(title: "No Toolpaths", systemImage: "square.stack.3d.up",
                                        detail: "Select vectors on the canvas, then choose New Toolpath.")
    static let noObjects = EmptyState(title: "No Objects", systemImage: "scribble.variable",
                                      detail: "Draw with the tool palette, or bring in vectors with File ▸ Import….")
}
