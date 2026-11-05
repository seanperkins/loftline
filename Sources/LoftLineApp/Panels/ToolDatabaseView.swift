import CADCore
import CAMCore
import PostCore
import SwiftUI
import UniformTypeIdentifiers
import LoftLineKit

/// Tool Database window: list of tools + editor. A number or choice saves to tools.json as it is made;
/// text saves when you leave the field. The editor saves once more when it closes, so switching tools
/// or closing the window never drops an edit.
struct ToolDatabaseView: View {
    static let windowID = "tool-database"
    @EnvironmentObject var library: ToolLibraryModel
    @State private var selectedID: UUID?
    @State private var pendingImport: [Tool]?
    @State private var pendingConflicts = 0
    @State private var importMessage: String?
    @State private var query = ""

    var body: some View {
        let clashes = ToolNumbers.clashes(in: library.tools)
        let shown = ToolSearch.filter(library.tools, query: query)
        // Duplicate and Delete act on what the list shows: a tool the search hides is not offered for either.
        let selectionShown = selectedID.map { id in shown.contains { $0.id == id } } ?? false
        NavigationSplitView {
            List(selection: $selectedID) {
                if shown.isEmpty {
                    Text(library.tools.isEmpty ? "No tools" : "No tool matches \"\(query)\"").foregroundStyle(.secondary)
                }
                ForEach(ToolGrouping.sections(shown), id: \.title) { section in
                    let tools = section.tools
                    if !tools.isEmpty {
                        Section(section.title) {
                            ForEach(tools) { t in
                                HStack {
                                    Text("T\(t.number)").monospacedDigit().foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(t.name).lineLimit(1)
                                        if let d = ToolSearch.description(of: t) {
                                            Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    if let shared = clashes[t.number] {
                                        // A badge on every tool that has the number, naming the others.
                                        let others = ToolNumbers.names(shared.filter { $0.id != t.id })
                                        Spacer(minLength: 4)
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(Color.warningText)
                                            .help("T\(t.number) is also the number of \(others). A program that uses both gets one tool change for two tools.")
                                            .accessibilityLabel("Tool number shared with \(others)")
                                    }
                                }
                                .tag(t.id)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Search tools")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .toolbar {
                ToolbarItem {
                    Menu {
                        ForEach(ToolKind.allCases, id: \.self) { kind in
                            Button(kind.displayName) { selectedID = library.add(kind: kind).id }
                        }
                        Divider()
                        Button("Bull Nose End Mill") { selectedID = library.add(kind: .endMill, shape: .bullNose).id }
                        Button("Tapered Ball Nose") { selectedID = library.add(kind: .ballNose, shape: .tapered).id }
                        Button("Form Tool") { selectedID = library.add(kind: .endMill, shape: .form).id }
                    } label: { Label("Add Tool", systemImage: "plus") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("Duplicate") { if let id = selectedID { selectedID = library.duplicate(id: id)?.id } }
                        .disabled(!selectionShown)
                    Button("Delete") { if let id = selectedID { library.delete(id: id); selectedID = nil } }
                        .disabled(!selectionShown)
                    Spacer()
                    Menu("Share") {
                        Button("Import Tools…") { runImport() }
                        Divider()
                        Button("Export All Tools…") { runExport(ids: nil) }
                        Button("Export Selected Tool…") { if let id = selectedID { runExport(ids: [id]) } }
                            .disabled(!selectionShown)
                    }
                    .fixedSize()
                    .help("Import or export tools as a .loftlinetools file (or CSV) to share them between machines")
                    Button("Restore Defaults") { library.restoreDefaults() }
                        .help("Re-adds any missing default tools")
                }
                .padding(8)
            }
        } detail: {
            if let id = selectedID, let tool = library.library.tool(id: id) {
                ToolEditor(original: tool).id(id)
            } else {
                Text("Select a tool").foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        // Typing in the search box that hides the tool being edited closes its editor (it saves as it closes).
        .onChange(of: query) { _, _ in
            if let id = selectedID, !ToolSearch.filter(library.tools, query: query).contains(where: { $0.id == id }) { selectedID = nil }
        }
        .confirmationDialog("\(pendingConflicts) imported tool\(pendingConflicts == 1 ? "" : "s") already exist with different settings",
                            isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } })) {
            Button("Replace Existing") { finishImport(.replace) }
            Button("Keep Both") { finishImport(.keepBoth) }
            Button("Keep Existing (Skip)") { finishImport(.skip) }
            Button("Cancel", role: .cancel) { pendingImport = nil }
        } message: {
            Text("Replace overwrites your tools with the imported ones. Keep Both adds the imported tools as new tools.")
        }
        .alert("Import Tools", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("OK") { importMessage = nil }
        } message: { Text(importMessage ?? "") }
        .overlay(alignment: .bottom) {
            if let e = library.lastError {
                Text(e).font(.caption).foregroundStyle(Color.errorText).padding(6).background(.regularMaterial)
            }
        }
        #if DEBUG
        // The UI harness has no way to click a row of this window's list (docs/UI-HARNESS.md): it names the tool.
        .onReceive(NotificationCenter.default.publisher(for: .harnessSelectTool)) { note in
            if let name = note.object as? String, let tool = library.tools.first(where: { $0.name == name }) { selectedID = tool.id }
        }
        .onReceive(NotificationCenter.default.publisher(for: .harnessSearchTools)) { note in
            query = note.object as? String ?? ""
        }
        #endif
    }
}

#if DEBUG
extension Notification.Name {
    /// Posted by the UI harness's `selectTool` step with the tool's name.
    static let harnessSelectTool = Notification.Name("loftline.harness.selectTool")
    /// Posted by the UI harness's `searchTools` step with the text to search for.
    static let harnessSearchTools = Notification.Name("loftline.harness.searchTools")
}
#endif

extension ToolDatabaseView {
    /// The post a new job starts with, as the job would use it: the machine and post chosen in Preferences (an
    /// unknown or incompatible post falls back to the machine's) with the machine's limits applied.
    static func defaultPost(prefs: AppPreferences = PreferencesModel.shared.prefs, machines: [MachineDefinition] = MachineCatalog.shared.machines,
                            profiles: [PostProfile] = PostProfileCatalog.shared.profiles) -> PostProfile {
        let project = prefs.newProject(machines: machines, profiles: profiles)
        // From the profiles given: the one the project names, else the built-in default's, else any, else the Avid's.
        let post = profiles.first { $0.id == project.postProfileID }
            ?? profiles.first { $0.id == PostProfileStore.defaultProfileID } ?? profiles.first ?? BuiltInPosts.avidMach4Inch
        return MachineResolver.effectiveProfile(post, machine: machines.first { $0.id == project.machineID })
    }

    private static var exchangeTypes: [UTType] {
        [UTType(filenameExtension: ToolLibraryExchange.fileExtension, conformingTo: .json), .json, .commaSeparatedText]
            .compactMap { $0 }
    }

    private func runImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.exchangeTypes
        panel.message = "Import tools from a .loftlinetools file, another Mac's tools.json, or a CSV file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let (tools, conflicts) = try library.readImport(url)
            if conflicts.isEmpty {
                importMessage = library.importTools(tools, policy: .keepBoth).summary
            } else {
                pendingConflicts = conflicts.count
                pendingImport = tools
            }
        } catch {
            importMessage = "Could not import \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func finishImport(_ policy: ToolImportPolicy) {
        guard let tools = pendingImport else { return }
        pendingImport = nil
        importMessage = library.importTools(tools, policy: policy).summary
    }

    private func runExport(ids: Set<UUID>?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = Self.exchangeTypes
        let base = library.exportName(for: ids)
        panel.nameFieldStringValue = base.replacingOccurrences(of: "/", with: "-") + "." + ToolLibraryExchange.fileExtension
        panel.message = "Export tools (.loftlinetools keeps everything; .csv for spreadsheets — choose by file extension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try library.export(ids: ids, to: url) } catch {
            importMessage = "Could not export: \(error.localizedDescription)"
        }
    }
}

/// The text fields of the tool editor. They write into the editor as you type, but the library
/// (and tools.json) only hears about it when the field loses focus or Return is pressed.
enum ToolEditorField: Hashable {
    case name, group, notes
    case material(Int)

    /// True when `new` differs from `old` only in the text of this field, so a keystroke waits for
    /// the field to be left. Any other change (a picker, the units, Apply in the calculator) is
    /// its own edit and saves at once, even while a text field has focus.
    func isTextEdit(from old: Tool, to new: Tool) -> Bool {
        var t = old
        switch self {
        case .name: t.name = new.name
        case .group: t.group = new.group
        case .notes: t.notes = new.notes
        case .material(let i):
            guard let n = new.materials, n.indices.contains(i), old.materials?.count == n.count else { return false }
            t.materials?[i].material = n[i].material
        }
        return t == new
    }
}

struct ToolEditor: View {
    @EnvironmentObject var library: ToolLibraryModel
    // What `ToolDatabaseView.defaultPost` reads, watched so that the spindle-range note follows a change made in Preferences.
    @ObservedObject private var preferences = PreferencesModel.shared
    @ObservedObject private var machines = MachineCatalog.shared
    @ObservedObject private var posts = PostProfileCatalog.shared
    /// The library's current copy of the tool (what Revert goes back to); the window passes it fresh on
    /// every update.
    let original: Tool
    @State private var tool: Tool
    @FocusState private var typing: ToolEditorField?

    /// Edits the library has not been told about yet (a text field is still being typed in).
    private var unsaved: Bool { tool != original }

    /// Saves the draft (a no-op when it matches the library).
    private func commit() { library.commitEdit(tool) }

    init(original: Tool) {
        self.original = original
        _tool = State(initialValue: original)
    }

    private var isAngled: Bool { tool.kind == .vBit || tool.kind == .engraving }

    /// Says when another tool in the library has this tool's number, and offers the next free one.
    @ViewBuilder private var numberClash: some View {
        let others = ToolNumbers.others(using: tool.number, besides: tool.id, in: library.tools)
        if !others.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Text("T\(tool.number) is also the number of \(ToolNumbers.names(others)).")
                    .font(.caption).foregroundStyle(Color.warningText).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if let free = ToolNumbers.nextFree(in: library.tools, besides: tool.id) {
                    Button("Use T\(free)") { tool.number = free }
                        .controlSize(.small)
                        .help("The smallest number no other tool has")
                }
            }
        }
    }

    var body: some View {
        let u = tool.units
        Form {
            Section {
                HStack {
                    TextField("Name", text: $tool.name)
                        .focused($typing, equals: .name)
                    Button { tool.name = ToolNaming.name(for: tool) } label: { Image(systemName: "wand.and.stars") }
                        .buttonStyle(.borderless)
                        .help("Name from geometry: \"\(ToolNaming.name(for: tool))\"")
                        .accessibilityLabel("Name from geometry")
                }
                Picker("Type", selection: Binding(get: { tool.kind }, set: { tool.setKind($0) })) {
                    ForEach(ToolKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                    .fieldHelp("Type")
                IntField("Tool number", value: $tool.number, range: ToolNumbers.range)
                numberClash
                Picker("Units", selection: Binding(get: { tool.units }, set: { tool = tool.converted(to: $0) })) {
                    ForEach(LengthUnit.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                    .fieldHelp("Units")
            } header: {
                HStack { Text("Tool"); Spacer(); HelpButton(topic: .toolDatabase).controlSize(.small) }
            }
            Section("Geometry") {
                LengthField("Diameter", value: $tool.diameter, units: u)
                IntField("Flutes", value: $tool.flutes, range: 1...8)
                if isAngled {
                    NumberField("Included angle", value: Binding(get: { tool.angle ?? 60 }, set: { tool.angle = $0 }), unit: "°")
                    LengthField("Tip diameter", value: $tool.tipDiameter, units: u)
                }
                OptionalLengthField(label: "Flute length", value: $tool.fluteLength, units: u, defaultValue: tool.diameter * 3)
            }
            Section("Cutting data") {
                LengthField("Pass depth (stepdown)", value: $tool.stepdown, units: u)
                if !(tool.stepdown > 0) {
                    Text("Pass depth must be positive; toolpaths using this tool will not calculate.")
                        .font(.caption).foregroundStyle(Color.errorText)
                }
                LabeledContent("Stepover") {
                    HStack {
                        TextField("Stepover", value: $tool.stepover, format: decimalFormat)
                            .labelsHidden().multilineTextAlignment(.trailing).frame(maxWidth: 90)
                        Text(u.abbreviation).foregroundStyle(.secondary)
                        TextField("%", value: Binding(get: { tool.diameter > 0 ? tool.stepover / tool.diameter * 100 : 0 },
                                                      set: { tool.stepover = tool.diameter * $0 / 100 }),
                                  format: .number.precision(.fractionLength(0...1)))
                            .labelsHidden().multilineTextAlignment(.trailing).frame(maxWidth: 60)
                        Text("%").foregroundStyle(.secondary)
                    }
                }
                NumberField("Spindle speed", value: $tool.spindleRPM, unit: "RPM")
                NumberField("Feed rate", value: $tool.feedRate, unit: u.feedUnit)
                NumberField("Plunge rate", value: $tool.plungeRate, unit: u.feedUnit)
                // The range of the post the app starts new jobs with (Preferences), not a constant.
                if let rpm = OperationWarnings.rpmProblem(tool.spindleRPM, profile: ToolDatabaseView.defaultPost()) {
                    Text(rpm).font(.caption).foregroundStyle(Color.warningText).fixedSize(horizontal: false, vertical: true)
                }
            }
            ToolShapeSection(tool: $tool)
            FeedsCalculatorSection(tool: $tool, jobMaterial: library.jobMaterial)
            MaterialDataSection(tool: $tool, knownMaterials: ToolGrouping.materialNames(library.tools), typing: $typing)
            ToolGroupSection(tool: $tool, existingGroups: Array(Set(library.tools.compactMap(\.group))).sorted(),
                             typing: $typing)
            Section("Description") {
                TextEditor(text: $tool.notes).frame(minHeight: 60)
                    .focused($typing, equals: .notes)
                Text("The first line shows in the tool list and in the tool pickers; search looks through all of it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Spacer()
                    Text(unsaved ? "Saves when you leave this field." : "Changes save automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Revert Changes") { tool = original }
                        .help("Discard the edits that are not saved yet")
                        .disabled(tool == original)
                }
            }
        }
        .formStyle(.grouped)
        // A picker or number is one edit and saves at once; the text of the focused field waits until
        // the field is left (focus moves on or Return), the editor closes, or the app quits.
        .onChange(of: tool) { old, new in
            if let field = typing, field.isTextEdit(from: old, to: new) { library.hold(new) } else { commit() }
        }
        // Something other than this editor changed the tool in the library (an import with Replace; any
        // text typed before it was saved first): show that version, whether or not a field has focus,
        // so a later save does not write the draft back over it.
        .onChange(of: library.library) { _, _ in
            if let replaced = library.replacement(for: tool) { tool = replaced }
        }
        .onChange(of: typing) { _, _ in commit() }
        .onSubmit { commit() }
        .onDisappear { commit() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in commit() }
    }
}
