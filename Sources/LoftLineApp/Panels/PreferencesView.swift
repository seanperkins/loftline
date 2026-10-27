import AppKit
import CADCore
import PostCore
import SwiftUI

/// LoftLine ▸ Settings… (⌘,): defaults for new documents, machines, canvas colours.
struct PreferencesView: View {
    @ObservedObject var model = PreferencesModel.shared

    var body: some View {
        TabView {
            GeneralPreferences(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            MachinePreferences(model: model)
                .tabItem { Label("Machines", systemImage: "cube") }
            ColorPreferences(model: model)
                .tabItem { Label("Colors", systemImage: "paintpalette") }
        }
        .frame(width: 640, height: 480)
    }
}

struct GeneralPreferences: View {
    @ObservedObject var model: PreferencesModel
    @ObservedObject private var updates = UpdateController.shared

    private var lastChecked: String {
        updates.lastCheck.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never"
    }

    var body: some View {
        Form {
            Section("New documents") {
                Picker("Units", selection: $model.prefs.defaultUnits) {
                    ForEach(LengthUnit.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Units for new jobs. Existing jobs keep their own units (change them in Job Setup).")
                NumberField("Grid spacing (inch jobs)", value: $model.prefs.gridSpacingInch, unit: "in")
                NumberField("Grid spacing (mm jobs)", value: $model.prefs.gridSpacingMM, unit: "mm")
            }
            Section("Snapping (each new window)") {
                Toggle("Snap to grid", isOn: $model.prefs.snapToGrid)
                Toggle("Snap to objects", isOn: $model.prefs.snapToObjects)
                    .help("Snap to nodes, midpoints and centers of other shapes")
            }
            Section("Safety net") {
                Picker("Save recovery copies", selection: $model.prefs.recoveryIntervalSeconds) {
                    ForEach(AppPreferences.recoveryIntervals, id: \.self) { s in
                        Text(s == 0 ? "Never" : s < 60 ? "Every \(s) seconds" : s == 60 ? "Every minute" : "Every \(s / 60) minutes")
                            .tag(s)
                    }
                }
                .help("Unsaved changes are copied to a recovery folder so they can be restored after a crash.")
                Toggle("Show the Welcome window at launch", isOn: $model.prefs.showWelcomeAtLaunch)
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $model.prefs.autoCheckForUpdates)
                    .help("Looks at github.com when LoftLine starts and then once a day. Nothing else is sent. LoftLine ▸ Check for Updates… looks once, on request.")
                LabeledContent("Last checked") { Text(lastChecked).foregroundStyle(.secondary) }
            }
            HStack {
                HelpButton(topic: .preferences)
                Spacer()
                Button("Restore Defaults") { model.resetToDefaults() }
                    .help("Reset every setting on all tabs (machines you added are kept)")
            }
        }
        .formStyle(.grouped)
    }
}

struct ColorPreferences: View {
    @ObservedObject var model: PreferencesModel

    var body: some View {
        Form {
            Section("Canvas") {
                colorRow("Material", \.materialColorHex, AppPreferences.defaultMaterialColor)
                colorRow("Selection", \.selectionColorHex, AppPreferences.defaultSelectionColor)
                colorRow("Rapid moves", \.rapidColorHex, AppPreferences.defaultRapidColor)
            }
            Text("Layer colors are set per layer in the Design sidebar. Toolpath colors cycle per toolpath.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private func colorRow(_ title: String, _ key: WritableKeyPath<AppPreferences, String>, _ fallback: String) -> some View {
        HStack {
            ColorPicker(title, selection: Binding(
                get: { Color(nsColor: NSColor(hex: model.prefs[keyPath: key]) ?? NSColor(hex: fallback)!) },
                set: { model.prefs[keyPath: key] = NSColor($0).hexString }), supportsOpacity: false)
            Button("Reset") { model.prefs[keyPath: key] = fallback }
                .disabled(model.prefs[keyPath: key] == fallback)
        }
    }
}

/// Default machine/post for new jobs, plus the machine list (built-ins read-only, custom editable).
struct MachinePreferences: View {
    @ObservedObject var model: PreferencesModel
    @ObservedObject private var machines = MachineCatalog.shared
    @ObservedObject private var posts = PostProfileCatalog.shared
    @State private var selectedID: String?
    @State private var draft: MachineDefinition?
    @State private var error: String?

    private var defaultMachine: MachineDefinition? { machines.machine(id: model.prefs.defaultMachineID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Form {
                Picker("Default machine", selection: $model.prefs.defaultMachineID) {
                    ForEach(machines.machines) { Text($0.name).tag($0.id) }
                }
                .help("Machine for new jobs. Each job can pick another one in the toolbar.")
                Picker("Default post", selection: Binding(get: { model.prefs.defaultPostID ?? "" },
                                                          set: { model.prefs.defaultPostID = $0.isEmpty ? nil : $0 })) {
                    Text("Machine default for the job units").tag("")
                    ForEach(MachineResolver.orderedPosts(posts.profiles, machine: defaultMachine).compatible) {
                        Text($0.name).tag($0.id)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 110)
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 4) {
                    List(machines.machines, selection: $selectedID) { m in
                        VStack(alignment: .leading) {
                            Text(m.name)
                            Text(machines.store.isUserMachine(m.id) ? "Custom" : "Built in")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(m.id)
                    }
                    .frame(width: 200)
                    HStack {
                        Button("Duplicate") { duplicate() }
                            .disabled(selectedID == nil)
                            .help("Copy the selected machine so you can edit its size and posts")
                        Button("Folder") { openFolder() }
                            .help("Open the folder that holds custom machine files (JSON)")
                        HelpButton(topic: .machines)
                    }
                }
                if let binding = Binding($draft) {
                    MachineEditor(machine: binding, editable: machines.store.isUserMachine(binding.wrappedValue.id),
                                  posts: posts.profiles, onSave: save, onDelete: delete)
                } else {
                    Text("Select a machine to see its bed size, limits and posts.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(Color.errorText) }
        }
        .padding(12)
        .onChange(of: selectedID) { _, id in draft = machines.machine(id: id); error = nil }
    }

    private func duplicate() {
        guard let base = machines.machine(id: selectedID) else { return }
        var copy = base
        copy.id = machines.newID(from: base.id)
        copy.name = base.name + " (custom)"
        do {
            try machines.save(copy)
            selectedID = copy.id
        } catch { self.error = error.localizedDescription }
    }

    private func save(_ m: MachineDefinition) {
        do { try machines.save(m); draft = m; error = nil } catch { self.error = error.localizedDescription }
    }

    private func delete(_ m: MachineDefinition) {
        do {
            try machines.delete(id: m.id)
            selectedID = nil
            draft = nil
        } catch { self.error = error.localizedDescription }
    }

    private func openFolder() {
        let dir = machines.store.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
}

struct MachineEditor: View {
    @Binding var machine: MachineDefinition
    var editable: Bool
    var posts: [PostProfile]
    var onSave: (MachineDefinition) -> Void
    var onDelete: (MachineDefinition) -> Void

    var body: some View {
        let u = machine.units
        VStack(alignment: .leading, spacing: 6) {
            Form {
                TextField("Name", text: $machine.name)
                Picker("Units", selection: Binding(get: { machine.units }, set: { setUnits($0) })) {
                    ForEach(LengthUnit.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                LengthField("X travel (bed width)", value: $machine.limits.xTravel, units: u)
                LengthField("Y travel (bed length)", value: $machine.limits.yTravel, units: u)
                LengthField("Z travel", value: $machine.limits.zTravel, units: u)
                LengthField("Allowed cut into spoilboard", value: $machine.limits.maxSpoilboardCut, units: u,
                            help: "Deeper cuts below the material bottom are reported as errors")
                NumberField("Rapid rate", value: Binding(get: { machine.rapidRate ?? 0 },
                                                         set: { machine.rapidRate = $0 > 0 ? $0 : nil }),
                            unit: "\(u.abbreviation)/min", help: "Used for time estimates (0 = the post's value)")
                Section("Post processors") {
                    ForEach(posts) { p in
                        Toggle(p.name, isOn: Binding(get: { machine.postIDs.contains(p.id) },
                                                     set: { on in
                                                         machine.postIDs.removeAll { $0 == p.id }
                                                         if on { machine.postIDs.append(p.id) }
                                                     }))
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(!editable)
            HStack {
                if editable {
                    Button("Delete", role: .destructive) { onDelete(machine) }
                    Spacer()
                    Button("Save") { onSave(machine) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isValid)
                } else {
                    Text("Built-in machines are read-only. Duplicate one to customize it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var isValid: Bool {
        !machine.name.trimmingCharacters(in: .whitespaces).isEmpty && machine.limits.xTravel > 0
            && machine.limits.yTravel > 0 && machine.limits.zTravel > 0 && machine.limits.maxSpoilboardCut >= 0
    }

    private func setUnits(_ new: LengthUnit) {
        guard new != machine.units else { return }
        let f = machine.units.factor(to: new)
        machine.limits = MachineLimits(xTravel: machine.limits.xTravel * f, yTravel: machine.limits.yTravel * f,
                                       zTravel: machine.limits.zTravel * f,
                                       maxSpoilboardCut: machine.limits.maxSpoilboardCut * f)
        machine.rapidRate = machine.rapidRate.map { $0 * f }
        machine.maxFeed = machine.maxFeed.map { $0 * f }
        machine.units = new
    }
}
