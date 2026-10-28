import CADCore
import CAMCore
import SwiftUI

/// Edits an operation. Every change is written through to the document immediately (merged
/// into one undo step), so nothing is lost when the selection changes and Calculate All /
/// export / save use exactly what the form shows. "Revert" restores the operation as it was
/// when the editor opened.
struct OperationEditor: View {
    @ObservedObject var document: LoftLineDocument
    // What the form's warnings read through `document.postProfile`: a machine saved in Preferences, or a reloaded post,
    // changes the spindle range and the spoilboard allowance they judge by.
    @ObservedObject private var machines = MachineCatalog.shared
    @ObservedObject private var posts = PostProfileCatalog.shared
    let original: AnyOperation
    @State private var draft: AnyOperation
    /// The operation when the editor opened (for Revert).
    @State private var initial: AnyOperation

    init(document: LoftLineDocument, original: AnyOperation) {
        self.document = document
        self.original = original
        _draft = State(initialValue: original)
        _initial = State(initialValue: original)
    }

    private var units: LengthUnit { document.units }
    private var library: ToolLibrary { document.mergedLibrary }

    var body: some View {
        InspectorSection(title: draft.kind.displayName + " Toolpath", helpTopic: HelpTopic.forOperation(draft.kind)) {
            TextField("Name", text: setupBinding(\.name))
            Toggle("Include in export", isOn: setupBinding(\.isEnabled))
                .fieldHelp("Include in export")
            if draft.kind != .merge {
                ToolPicker(title: OperationFactory.primaryToolTitle(draft.kind), toolID: setupBinding(\.toolID),
                           library: library, preferred: OperationFactory.preferredToolKinds(for: draft.kind),
                           jobMaterial: document.document.job.material)
                ToolOverrideSection(override: setupBinding(\.toolOverride),
                                    tool: library.tool(id: draft.setup.toolID)?.forMaterial(document.document.job.material)
                                        .converted(to: units), units: units)
                warnings
            }
            if usesVectors {
                vectorsRow
                if !document.document.models.isEmpty || draft.setup.projectOntoModelID != nil {
                    Picker("Project onto 3D", selection: setupBinding(\.projectOntoModelID)) {
                        Text("None").tag(UUID?.none)
                        ForEach(document.document.models) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .help("Cut this toolpath's depths below the 3D model's surface instead of the material top")
                }
            }
        }
        Divider()
        // Calculate and its result sit above the parameters: with 25-45 controls below them they were
        // off-screen in the Pocket and Profile forms.
        actionRow
        resultView
        Divider()
        parameterForm
        Divider()
        InspectorSection(title: "Array Copies", collapsedByDefault: true) {
            ArrayCopyForm(array: setupBinding(\.arrayCopy), units: units)
        }
        Divider()
        InspectorSection(title: "Coolant") {
            CoolantForm(coolant: setupBinding(\.coolant))
        }
        Divider()
        InspectorSection(title: "Pause") {
            PauseStepForm(pause: setupBinding(\.pauseAfter), toolpathName: draft.setup.name, profile: document.postProfile)
        }
    }

    /// Settings the export validator would only catch at the last step, shown as they are made.
    @ViewBuilder private var warnings: some View {
        let problems = OperationWarnings.make(draft, project: document.project, library: library, profile: document.postProfile, units: units)
        if !problems.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Color.warningText).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var actionRow: some View {
        HStack {
            Button("Calculate") { save(); document.calculate([draft.id]) }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
            Button("Revert") { draft = initial }.disabled(draft == initial)
                .help("Undo every change made since this toolpath was selected")
            Spacer()
            Button(role: .destructive) { document.deleteOperation(draft.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.icon)
                .help("Delete toolpath")
                .accessibilityLabel("Delete toolpath")
        }
        .onChange(of: draft) { _, _ in save() }
        .onChange(of: original) { _, new in if new != draft { draft = new } }
        .onDisappear { save() }
    }

    /// Whether the toolpath takes vectors (a facing of the whole material, a relief and the like do not).
    private var usesVectors: Bool {
        switch draft {
        case .relief3D, .photoVCarve, .merge: return false
        case .facing(let o): return o.params.area == .vectors
        default: return true
        }
    }

    private var vectorsRow: some View {
        let count = draft.setup.shapeIDs.count
        let selCount = document.selection.count
        return VStack(alignment: .leading, spacing: 4) {
            Text(count == 0 ? "No vectors selected" : "\(count) vector\(count == 1 ? "" : "s")")
                .foregroundStyle(count == 0 ? .orange : .primary)
            HStack {
                Button("Use Current Selection (\(selCount))") {
                    var s = draft.editableSetup
                    s.shapeIDs = document.selectedShapes.map(\.id)
                    draft.editableSetup = s
                }
                .disabled(selCount == 0)
                Button("Show") { document.setSelection(draft.setup.shapeIDs) }.disabled(count == 0)
            }
        }
    }

    @ViewBuilder private var parameterForm: some View {
        switch draft {
        case .profile(let o):
            ProfileForm(params: paramsBinding(o.params) { .profile(ProfileOperation(setup: draft.setup, params: $0)) }, units: units,
                        shapes: document.document.shapes(ids: draft.setup.shapeIDs), isEditingTabs: editingTabsBinding,
                        materialThickness: document.document.job.thickness, tool: primaryTool)
        case .pocket(let o):
            PocketForm(params: paramsBinding(o.params) { .pocket(PocketOperation(setup: draft.setup, params: $0)) },
                       units: units, library: library, finishToolID: draft.setup.toolID, tool: primaryTool)
        case .drill(let o):
            DrillForm(params: paramsBinding(o.params) { .drill(DrillOperation(setup: draft.setup, params: $0)) }, units: units,
                      tool: primaryTool)
        case .vcarve(let o):
            VCarveForm(params: paramsBinding(o.params) { .vcarve(VCarveOperation(setup: draft.setup, params: $0)) },
                       units: units, library: library)
        case .inlay(let o):
            InlayForm(params: paramsBinding(o.params) { .inlay(InlayOperation(setup: draft.setup, params: $0)) },
                      units: units, library: library)
        case .fluting(let o):
            FlutingForm(params: paramsBinding(o.params) { .fluting(FlutingOperation(setup: draft.setup, params: $0)) }, units: units,
                        tool: primaryTool)
        case .texture(let o):
            TextureForm(params: paramsBinding(o.params) { .texture(TextureOperation(setup: draft.setup, params: $0)) }, units: units)
        case .photoVCarve(let o):
            PhotoVCarveForm(params: paramsBinding(o.params) { .photoVCarve(PhotoVCarveOperation(setup: draft.setup, params: $0)) },
                            units: units, job: document.document.job)
        case .engrave(let o):
            EngraveForm(params: paramsBinding(o.params) { .engrave(EngraveOperation(setup: draft.setup, params: $0)) },
                        units: units, tool: primaryTool)
        case .chamfer(let o):
            ChamferForm(params: paramsBinding(o.params) { .chamfer(ChamferOperation(setup: draft.setup, params: $0)) },
                        units: units, tool: primaryTool)
        case .holeMill(let o):
            HoleMillForm(params: paramsBinding(o.params) { .holeMill(HoleMillOperation(setup: draft.setup, params: $0)) },
                         units: units, tool: primaryTool)
        case .facing(let o):
            FacingForm(params: paramsBinding(o.params) { FacingForm.operation(draft.setup, params: $0) },
                       units: units, tool: primaryTool, multiSheet: document.document.isMultiSheet,
                       twoSided: document.document.job.isTwoSided)
        case .prism(let o):
            PrismForm(params: paramsBinding(o.params) { .prism(PrismOperation(setup: draft.setup, params: $0)) },
                      units: units)
        case .straightInlay(let o):
            StraightInlayForm(params: paramsBinding(o.params) { .straightInlay(StraightInlayOperation(setup: draft.setup, params: $0)) },
                              units: units)
        case .moulding(let o):
            MouldingForm(params: paramsBinding(o.params) { .moulding(MouldingOperation(setup: draft.setup, params: $0)) },
                         units: units, document: document.document, selection: document.selectedShapes.map(\.id))
        case .merge(let o):
            MergeForm(operation: o, onSplit: { document.splitMergedOperation(o.setup.id) })
        case .relief3D(let o):
            Relief3DForm(params: paramsBinding(o.params) { .relief3D(Relief3DOperation(setup: draft.setup, params: $0)) },
                         units: units, library: library, models: document.document.models,
                         selection: document.selectedShapes.map(\.id))
        }
    }

    @ViewBuilder private var resultView: some View {
        if document.calculating.contains(draft.id) {
            HStack { ProgressView().controlSize(.small); Text("Calculating…") }
        } else if let r = document.results[draft.id] {
            VStack(alignment: .leading, spacing: 4) {
                if let e = r.error {
                    Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    let moves = r.toolpaths.reduce(0) { $0 + $1.moves.count }
                    Label("\(r.toolpaths.count) toolpath\(r.toolpaths.count == 1 ? "" : "s"), \(moves) moves",
                          systemImage: "checkmark.circle.fill").foregroundStyle(Color.successText)
                    Text("Estimated time: " + ToolpathCalculator.formatDuration(r.estimatedSeconds))
                        .font(.caption).foregroundStyle(.secondary)
                    if r.toolpaths.count > 1 {
                        ForEach(r.toolpaths) { tp in
                            let secs = document.estimateSeconds([tp])
                            Text("• \(tp.name): T\(tp.tool.number), \(ToolpathCalculator.formatDuration(secs))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        let changes = max(0, JobSummary.sequence(of: r.toolpaths).count - 1)
                        if changes > 0 {
                            Text("\(changes) tool change\(changes == 1 ? "" : "s") within this toolpath")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(r.toolpaths.flatMap { $0.metadata.sorted { $0.key < $1.key } }, id: \.key) { kv in
                        Text("\(kv.key): \(kv.value)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if document.isStale(draft.id) {
                    Text("Parameters or design changed — recalculate.").font(.caption).foregroundStyle(Color.warningText)
                }
            }
        }
    }

    /// The operation's primary tool in document units.
    private var primaryTool: Tool? { library.tool(id: draft.setup.toolID)?.converted(to: units) }

    // MARK: Bindings

    /// On-canvas tab editing for this (Profile) operation. Turning it on saves the draft first so
    /// canvas edits start from what the form shows.
    private var editingTabsBinding: Binding<Bool> {
        Binding(get: { document.tabEditingOperationID == draft.id }, set: { on in
            if on {
                save()
                document.showDesignCanvas()
                document.tabEditingOperationID = draft.id
            } else if document.tabEditingOperationID == draft.id {
                document.tabEditingOperationID = nil
            }
        })
    }

    private func setupBinding<T>(_ kp: WritableKeyPath<OperationSetup, T>) -> Binding<T> {
        Binding(get: { draft.setup[keyPath: kp] }, set: { v in
            var s = draft.editableSetup
            s[keyPath: kp] = v
            draft.editableSetup = s
        })
    }

    private func paramsBinding<P>(_ current: P, _ wrap: @escaping (P) -> AnyOperation) -> Binding<P> {
        Binding(get: { current }, set: { draft = wrap($0) })
    }

    private func save() {
        if draft != original { document.updateOperationLive(draft) }
    }
}

/// Tool chooser: preferred kinds first, plus a "Tool Database…" shortcut.
struct ToolPicker: View {
    var title: String
    @Binding var toolID: UUID
    var library: ToolLibrary
    var preferred: [ToolKind]
    /// The job's material, handed to the Tool Database so its feeds calculator starts from the right preset.
    var jobMaterial: String? = nil
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let sorted = library.tools.sorted { a, b in
            let ia = preferred.firstIndex(of: a.kind) ?? 99, ib = preferred.firstIndex(of: b.kind) ?? 99
            return ia != ib ? ia < ib : a.number < b.number
        }
        HStack {
            Picker(title, selection: $toolID) {
                if library.tool(id: toolID) == nil { Text("Missing tool").tag(toolID) }
                ForEach(sorted) { t in Text(ToolSearch.pickerLabel(t)).tag(t.id) }
            }
            Button {
                ToolLibraryModel.shared.jobMaterial = jobMaterial
                openWindow(id: ToolDatabaseView.windowID)
            } label: { Image(systemName: "wrench.and.screwdriver") }
                .buttonStyle(.icon).help("Tool Database").accessibilityLabel("Open Tool Database")
        }
        if let t = library.tool(id: toolID) {
            Text(toolSummary(t)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func toolSummary(_ t: Tool) -> String {
        let u = t.units.abbreviation
        var s = "⌀\(RulerTicks.label(t.diameter)) \(u) · \(t.kind.displayName)"
        if let a = t.angle { s += " \(RulerTicks.label(a))°" }
        s += " · \(String(format: "%.0f", t.spindleRPM)) RPM · F\(RulerTicks.label(t.feedRate)) / P\(RulerTicks.label(t.plungeRate)) \(t.units.feedUnit)"
        return s
    }
}

/// Optional secondary tool (clearance/roughing).
struct OptionalToolPicker: View {
    var title: String
    @Binding var toolID: UUID?
    var library: ToolLibrary
    var kinds: [ToolKind]

    var body: some View {
        Picker(title, selection: $toolID) {
            Text("None").tag(UUID?.none)
            ForEach(library.tools.filter { kinds.contains($0.kind) }) { t in Text(ToolSearch.pickerLabel(t)).tag(Optional(t.id)) }
        }
    }
}
