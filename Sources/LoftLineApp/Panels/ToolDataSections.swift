import CADCore
import CAMCore
import SwiftUI
import LoftLineKit

// Tool database additions (toolpaths-2d): groups, feeds calculator, per-material cutting data.

struct ToolGroupSection: View {
    @Binding var tool: Tool
    var existingGroups: [String]
    var typing: FocusState<ToolEditorField?>.Binding

    var body: some View {
        Section("Organization") {
            HStack {
                TextField("Group", text: Binding(get: { tool.group ?? "" }, set: { tool.group = $0.isEmpty ? nil : $0 }),
                          prompt: Text(tool.kind.displayName))
                    .focused(typing, equals: .group)
                if !existingGroups.isEmpty {
                    Menu {
                        ForEach(existingGroups, id: \.self) { g in Button(g) { tool.group = g; typing.wrappedValue = nil } }
                        Divider()
                        Button("No Group") { tool.group = nil; typing.wrappedValue = nil }
                    } label: { Image(systemName: "folder") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
            Text("Folder in the tool list; use \"/\" for sub-folders. Empty = listed under its type.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct FeedsCalculatorSection: View {
    @Binding var tool: Tool
    /// The job's material, when the editor knows it: its preset is chosen to start with.
    var jobMaterial: String? = nil
    @State private var chipLoad: Double = 0
    @State private var presetName = ""

    /// Chip loads are 4 decimals in inches (0.0105) and 3 in millimeters (0.312).
    private func rounded(_ v: Double) -> Double {
        let f: Double = tool.units == .inch ? 10000 : 1000
        return (v * f).rounded() / f
    }

    private func startingLoad(_ p: MaterialPreset) -> Double {
        rounded(MaterialPresets.chipLoad(p, diameter: tool.diameter, units: tool.units))
    }

    var body: some View {
        let u = tool.units
        let current = FeedsAndSpeeds.chipLoad(feedRate: tool.feedRate, rpm: tool.spindleRPM, flutes: tool.flutes)
        let feed = FeedsAndSpeeds.feedRate(rpm: tool.spindleRPM, flutes: tool.flutes, chipLoad: chipLoad)
        Section("Feeds calculator") {
            LabeledContent("Current chip load") {
                Text("\(current, format: .number.precision(.fractionLength(0...4))) \(u.abbreviation)/tooth")
            }
            LabeledContent("Surface speed") {
                let s = FeedsAndSpeeds.surfaceSpeed(diameter: tool.diameter, rpm: tool.spindleRPM, units: u)
                Text("\(s, format: .number.precision(.fractionLength(0))) \(FeedsAndSpeeds.surfaceSpeedUnit(u))")
            }
            Picker("Material", selection: $presetName) {
                Text("Choose a starting point…").tag("")
                ForEach(MaterialPresets.all) { p in
                    Text("\(p.name) · \(startingLoad(p), format: .number.precision(.fractionLength(0...4))) \(u.abbreviation)/tooth")
                        .tag(p.name)
                }
            }
            .help("Starting chip loads for a sharp two-flute cutter of this diameter; the cutter, the machine and the cut decide the final number")
            .onChange(of: presetName) { _, name in
                if let p = MaterialPresets.preset(named: name) { chipLoad = startingLoad(p) }
            }
            NumberField("Target chip load", value: $chipLoad, unit: "\(u.abbreviation)/tooth",
                        help: "Advance per cutting edge; pick a material above for a starting point, or use your bit maker's chart")
            // Choosing the same material again fires no change, so once the target has drifted from
            // the preset (a hand edit, or a new diameter) this is the way back to the number shown.
            if let p = MaterialPresets.preset(named: presetName), abs(startingLoad(p) - chipLoad) > 1e-12 {
                HStack {
                    Text("\(p.name) starts at \(startingLoad(p), format: .number.precision(.fractionLength(0...4))) \(u.abbreviation)/tooth for this cutter")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Use Starting Point") { chipLoad = startingLoad(p) }
                        .help("Set the target back to the \(p.name) preset for the tool's current diameter")
                }
            }
            HStack {
                Text("Feed = \(String(format: "%.0f", tool.spindleRPM)) RPM ×\(tool.flutes) flutes × chip load = \(feed, format: .number.precision(.fractionLength(0...1))) \(u.feedUnit)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Apply") { tool.feedRate = feed }.disabled(feed <= 0)
            }
            Text("The presets are the light end of the ranges bit makers publish. Listen to the cut: a rising whine means too little chip load, chatter means too much.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            chipLoad = rounded(current)
            if let p = MaterialPresets.preset(matching: jobMaterial) {
                presetName = p.name
                chipLoad = startingLoad(p)
            }
        }
    }
}

struct MaterialDataSection: View {
    @Binding var tool: Tool
    var knownMaterials: [String]
    var typing: FocusState<ToolEditorField?>.Binding

    private var list: [MaterialCuttingData] { tool.materials ?? [] }

    /// Materials other tools have data for, then the presets not among them.
    private var offered: [String] {
        knownMaterials + MaterialPresets.all.map(\.name).filter { p in
            !knownMaterials.contains { $0.caseInsensitiveCompare(p) == .orderedSame }
        }
    }

    private func binding<T>(_ i: Int, _ kp: WritableKeyPath<MaterialCuttingData, T>) -> Binding<T> {
        Binding(get: { list[i][keyPath: kp] }, set: { v in
            var l = list
            guard l.indices.contains(i) else { return }
            l[i][keyPath: kp] = v
            tool.materials = l
        })
    }

    var body: some View {
        let u = tool.units
        Section("Cutting data per material") {
            ForEach(Array(list.enumerated()), id: \.offset) { i, _ in
                DisclosureGroup {
                    NumberField("Spindle speed", value: binding(i, \.spindleRPM), unit: "RPM")
                    NumberField("Feed rate", value: binding(i, \.feedRate), unit: u.feedUnit)
                    NumberField("Plunge rate", value: binding(i, \.plungeRate), unit: u.feedUnit)
                    LengthField("Pass depth", value: binding(i, \.stepdown), units: u)
                    LengthField("Stepover", value: binding(i, \.stepover), units: u)
                    Button("Remove", role: .destructive) {
                        var l = list
                        l.remove(at: i)
                        tool.materials = l.isEmpty ? nil : l
                    }
                } label: {
                    TextField("Material", text: binding(i, \.material))
                        .focused(typing, equals: .material(i))
                }
            }
            Menu {
                Button("New Material") { add("Material \(list.count + 1)") }
                ForEach(offered.filter { m in !list.contains { $0.material.caseInsensitiveCompare(m) == .orderedSame } },
                        id: \.self) { m in Button(m) { add(m) } }
            } label: { Label("Add Material", systemImage: "plus") }
            .fixedSize()
            Text("The values above are the defaults. When Job Setup names a material listed here, toolpaths use its values instead. A material added from the presets starts at the calculator's chip load for this tool.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A new entry copies the tool's data; a preset material gets its starting feed instead.
    private func add(_ name: String) {
        var data = MaterialCuttingData(material: name, from: tool)
        if let p = MaterialPresets.preset(matching: name) {
            let load = MaterialPresets.chipLoad(p, diameter: tool.diameter, units: tool.units)
            let feed = FeedsAndSpeeds.feedRate(rpm: tool.spindleRPM, flutes: tool.flutes, chipLoad: load)
            if feed > 0 {
                data.feedRate = (feed * 10).rounded() / 10
                data.plungeRate = min(data.plungeRate, data.feedRate)
            }
        }
        tool.materials = list + [data]
    }
}

/// Per-toolpath overrides of the primary tool's cutting data (document units).
struct ToolOverrideSection: View {
    @Binding var override: ToolOverride?
    var tool: Tool?
    var units: LengthUnit

    private func field(_ kp: WritableKeyPath<ToolOverride, Double?>) -> Binding<Double?> {
        Binding(get: { override?[keyPath: kp] }, set: { v in
            var o = override ?? ToolOverride()
            o[keyPath: kp] = v
            override = o.isEmpty ? nil : o
        })
    }

    var body: some View {
        DisclosureGroup("Tool overrides\(override == nil ? "" : " (on)")") {
            OptionalValueField(label: "Spindle speed", value: field(\.spindleRPM), unit: "RPM", defaultValue: tool?.spindleRPM ?? 18000)
            OptionalValueField(label: "Feed rate", value: field(\.feedRate), unit: units.feedUnit, defaultValue: tool?.feedRate ?? 60)
            OptionalValueField(label: "Plunge rate", value: field(\.plungeRate), unit: units.feedUnit, defaultValue: tool?.plungeRate ?? 20)
            OptionalValueField(label: "Pass depth", value: field(\.stepdown), unit: units.abbreviation, defaultValue: tool?.stepdown ?? 0.1)
            OptionalValueField(label: "Stepover", value: field(\.stepover), unit: units.abbreviation, defaultValue: tool?.stepover ?? 0.1)
            Text("Changes this toolpath only; the tool database is not changed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Optional number with a unit label: a checkbox enables it; unchecking stores nil.
struct OptionalValueField: View {
    var label: String
    @Binding var value: Double?
    var unit: String
    var defaultValue: Double

    var body: some View {
        HStack {
            Toggle(label, isOn: Binding(get: { value != nil }, set: { value = $0 ? (value ?? defaultValue) : nil }))
            Spacer()
            if value != nil {
                TextField(label, value: Binding(get: { value ?? defaultValue }, set: { value = $0 }), format: decimalFormat)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 60, maxWidth: 110)
                Text(unit).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            }
        }
        .help(FieldHelp.text(for: label) ?? label)
    }
}

/// Job material name, with a menu of the materials tools have cutting data for.
struct MaterialNameField: View {
    @Binding var material: String?
    var known: [String]

    /// Materials tools have data for, then the presets not among them.
    private var offered: [String] {
        known + MaterialPresets.all.map(\.name).filter { p in !known.contains { $0.caseInsensitiveCompare(p) == .orderedSame } }
    }

    var body: some View {
        HStack {
            TextField("Material type", text: Binding(get: { material ?? "" },
                                                    set: { material = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }),
                      prompt: Text("Any"))
            if !offered.isEmpty {
                Menu {
                    ForEach(offered, id: \.self) { m in Button(m) { material = m } }
                    Divider()
                    Button("Any (tool defaults)") { material = nil }
                } label: { Image(systemName: "list.bullet") }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
        Text("Tools with cutting data for this material use it; others use their defaults. The feeds calculator in the tool database offers a starting chip load for it.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
