import CADCore
import CAMCore
import SwiftUI

// Parameter forms for every CAMCore operation. Each binds to its parameter struct.

struct DepthForm: View {
    @Binding var depth: DepthSettings
    var units: LengthUnit
    var showFinalPass = true
    /// The material thickness, when the form offers to keep the cut depth following it.
    var materialThickness: Double? = nil
    /// The selected tool in document units: its stepdown for the pass list, its flute length for
    /// the note under the cut depth (nil = unknown).
    var tool: Tool? = nil

    var body: some View {
        LengthField("Start depth", value: $depth.startDepth, units: units, help: "Depth below the material top where cutting starts")
        // A through cut's depth is the thickness plus its overcut, worked out by the project; shown, not typed.
        LengthField("Cut depth", value: $depth.cutDepth, units: units, help: "Final depth below the material top")
            .disabled(materialThickness != nil && depth.overcut != nil)
        FluteLengthNote(tool: tool, cutDepth: depth.cutDepth, startDepth: depth.startDepth, units: units)
        if let thickness = materialThickness {
            Toggle("Cut through the material", isOn: Binding(get: { depth.overcut != nil }, set: { on in
                if on {
                    let over = max(0, depth.cutDepth - thickness)
                    depth.overcut = over
                    depth.cutDepth = thickness + over
                } else {
                    depth.overcut = nil
                }
            }))
            .fieldHelp("Cut through the material")
            if let over = depth.overcut {
                LengthField("Past the bottom", value: Binding(get: { over }, set: { v in
                    depth.overcut = max(0, v)
                    depth.cutDepth = thickness + max(0, v)
                }), units: units)
                .fieldHelp("Past the bottom")
            }
        }
        PassEditor(depth: $depth, units: units, showFinalPass: showFinalPass, toolStepdown: tool?.stepdown)
        if depth.cutDepth <= depth.startDepth {
            Text("Cut depth must be deeper than the start depth.").font(.caption).foregroundStyle(Color.warningText)
        }
    }
}

/// "Deeper than the flutes" under a cut-depth field, when it is.
struct FluteLengthNote: View {
    var tool: Tool?
    var cutDepth: Double
    var startDepth: Double
    var units: LengthUnit

    var body: some View {
        if let problem = OperationHints.fluteLengthProblem(tool: tool, cutDepth: cutDepth, startDepth: startDepth, units: units) {
            Text(problem).font(.caption).foregroundStyle(Color.warningText).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct RampForm: View {
    @Binding var ramp: RampSettings
    var units: LengthUnit

    var body: some View {
        Toggle("Ramp plunges", isOn: $ramp.isEnabled)
            .fieldHelp("Ramp plunges")
        if ramp.isEnabled {
            Picker("Ramp type", selection: $ramp.type) {
                Text("Smooth").tag(RampType.smooth)
                Text("Zig-zag").tag(RampType.zigzag)
                Text("Spiral").tag(RampType.spiral)
            }
                .fieldHelp("Ramp type")
            LengthField("Ramp length", value: $ramp.length, units: units)
            NumberField("Max angle", value: $ramp.maxAngle, unit: "°")
        }
    }
}

struct DirectionPicker: View {
    @Binding var direction: CutDirection
    var body: some View {
        Picker("Direction", selection: $direction) {
            Text("Climb").tag(CutDirection.climb)
            Text("Conventional").tag(CutDirection.conventional)
        }
        .pickerStyle(.segmented)
            .fieldHelp("Direction")
    }
}

struct PocketStrategyForm: View {
    @Binding var strategy: PocketStrategy
    /// When given, the raster profile pass is a None / First / Last choice (Pocket only).
    var profileFirst: Binding<Bool?>? = nil

    private var isRaster: Binding<Bool> {
        Binding(get: { if case .raster = strategy { return true } else { return false } },
                set: { strategy = $0 ? .raster(angle: 0, profilePass: true) : .offset })
    }
    private var angle: Binding<Double> {
        Binding(get: { if case .raster(let a, _) = strategy { return a } else { return 0 } },
                set: { a in if case .raster(_, let p) = strategy { strategy = .raster(angle: a, profilePass: p) } })
    }
    private var profilePass: Binding<Bool> {
        Binding(get: { if case .raster(_, let p) = strategy { return p } else { return false } },
                set: { p in if case .raster(let a, _) = strategy { strategy = .raster(angle: a, profilePass: p) } })
    }

    var body: some View {
        Picker("Clearing", selection: isRaster) {
            Text("Offset").tag(false)
            Text("Raster").tag(true)
        }
        .pickerStyle(.segmented)
            .fieldHelp("Clearing")
        if isRaster.wrappedValue {
            NumberField("Raster angle", value: angle, unit: "°")
            if let profileFirst {
                Picker("Profile pass", selection: Binding(get: {
                    !profilePass.wrappedValue ? 0 : (profileFirst.wrappedValue == true ? 1 : 2)
                }, set: { v in
                    profilePass.wrappedValue = v != 0
                    profileFirst.wrappedValue = v == 1 ? true : nil
                })) {
                    Text("None").tag(0)
                    Text("First").tag(1)
                    Text("Last").tag(2)
                }
                .pickerStyle(.segmented)
                .help("Wall clean-up pass before or after the raster")
            } else {
                Toggle("Final profile pass", isOn: profilePass)
                    .fieldHelp("Final profile pass")
            }
        }
    }
}

struct ProfileForm: View {
    @Binding var params: ProfileParameters
    var units: LengthUnit
    /// The operation's vectors (to seed manual tabs).
    var shapes: [Shape] = []
    var isEditingTabs: Binding<Bool> = .constant(false)
    /// The material thickness, so the Tabs section can say what a tab really holds.
    var materialThickness: Double? = nil
    /// The selected tool in document units.
    var tool: Tool? = nil

    private var manualBinding: Binding<Bool> {
        Binding(get: { params.tabs.isManual }, set: { manual in
            params.tabs = manual ? TabEditor.makeManual(params.tabs, shapes: shapes) : TabEditor.makeAutomatic(params.tabs)
            if !manual { isEditingTabs.wrappedValue = false }
        })
    }

    var body: some View {
        InspectorSection(title: "Cutting Depths") {
            DepthForm(depth: $params.depth, units: units, materialThickness: materialThickness, tool: tool)
        }
        Divider()
        InspectorSection(title: "Machine Vectors") {
            Picker("Side", selection: $params.side) {
                Text("Outside").tag(ProfileSide.outside)
                Text("Inside").tag(ProfileSide.inside)
                Text("On").tag(ProfileSide.on)
            }
            .pickerStyle(.segmented)
                .fieldHelp("Side")
            DirectionPicker(direction: $params.direction)
            LengthField("Allowance", value: $params.allowance, units: units, help: "Material left on the part (negative removes more)")
        }
        Divider()
        InspectorSection(title: "Order & Corners", collapsedByDefault: true) {
            Picker("Open vectors", selection: Binding(get: { params.openVectorSide ?? .on },
                                                      set: { params.openVectorSide = $0 == .on ? nil : $0 })) {
                Text("On").tag(OpenVectorSide.on)
                Text("Left").tag(OpenVectorSide.left)
                Text("Right").tag(OpenVectorSide.right)
            }
            .help("Open vectors: cut on the line, or keep the tool to the left or right of the vector's direction")
            Picker("Start point", selection: Binding(get: { params.startPoint ?? .nearest },
                                                     set: { params.startPoint = $0 == .nearest ? nil : $0 })) {
                Text("Nearest (optimized)").tag(ProfileStartPoint.nearest)
                Text("Vector start node").tag(ProfileStartPoint.vectorStart)
                Text("Left side").tag(ProfileStartPoint.left)
                Text("Right side").tag(ProfileStartPoint.right)
                Text("Bottom side").tag(ProfileStartPoint.bottom)
                Text("Top side").tag(ProfileStartPoint.top)
            }
            .help("Where each closed loop starts cutting")
            Picker("Cut order", selection: Binding(get: { params.order ?? .nearest },
                                                   set: { params.order = $0 == .nearest ? nil : $0 })) {
                Text("Shortest rapids").tag(ProfileOrder.nearest)
                Text("Selection order").tag(ProfileOrder.selection)
                Text("Left to right").tag(ProfileOrder.leftToRight)
                Text("Bottom to top").tag(ProfileOrder.bottomToTop)
                Text("Grid (rows from bottom)").tag(ProfileOrder.grid)
            }
            .help("Order the parts are cut in. Holes are always cut before the part around them.")
            Toggle("Output arcs (G2/G3)", isOn: $params.preferArcs)
                .fieldHelp("Output arcs (G2/G3)")
            Toggle("Sharp external corners", isOn: Binding(get: { params.sharpCorners == true },
                                                           set: { params.sharpCorners = $0 ? true : nil }))
                .help("Run straight out to a square corner instead of rolling round the part's corners")
        }
        Divider()
        InspectorSection(title: "Last Pass", collapsedByDefault: true) { ProfileLastPassForm(lastPass: $params.lastPass, side: params.side, units: units) }
        Divider()
        InspectorSection(title: "Tabs", helpTopic: .tabs) {
            Toggle("Add tabs", isOn: $params.tabs.isEnabled)
                .fieldHelp("Add tabs")
            if params.tabs.isEnabled {
                LengthField("Length", value: $params.tabs.length, units: units)
                LengthField("Tab height", value: $params.tabs.thickness, units: units)
                    .help("Measured up from the bottom of the cut, not from the material bottom")
                if let thickness = materialThickness {
                    let note = TabHold.note(tabHeight: params.tabs.thickness, cutDepth: params.depth.cutDepth,
                                            materialThickness: thickness, units: units)
                    Text(note.text).font(.caption)
                        .foregroundStyle(note.isProblem ? Color.warningText : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Triangular (3D) tabs", isOn: $params.tabs.isTriangular)
                    .fieldHelp("Triangular (3D) tabs")
                Picker("Placement", selection: manualBinding) {
                    Text("Automatic").tag(false)
                    Text("Manual").tag(true)
                }
                .pickerStyle(.segmented)
                    .fieldHelp("Placement")
                if let manual = params.tabs.manualTabs {
                    let n = manual.count
                    Text("\(n) tab\(n == 1 ? "" : "s") placed by hand").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Toggle(isOn: isEditingTabs) { Label("Edit on Canvas", systemImage: "pin") }
                            .toggleStyle(.button)
                        Button("Clear") { params.tabs.manualTabs = [] }.disabled(n == 0)
                    }
                } else {
                    IntField("Tabs per vector", value: $params.tabs.countPerPath, range: 1...64)
                    OptionalLengthField(label: "Spacing", value: $params.tabs.spacing, units: units,
                                        defaultValue: units == .inch ? 6 : 150)
                }
            }
        }
        Divider()
        InspectorSection(title: "Ramps & Leads", helpTopic: .tabs, collapsedByDefault: true) {
            RampForm(ramp: $params.ramp, units: units)
            Picker("Lead in/out", selection: $params.lead.type) {
                Text("None").tag(LeadType.none)
                Text("Linear").tag(LeadType.linear)
                Text("Arc").tag(LeadType.arc)
            }
                .fieldHelp("Lead in/out")
            if params.lead.type != .none {
                LengthField(params.lead.type == .arc ? "Lead radius" : "Lead length", value: $params.lead.distance, units: units)
            }
            LengthField("Overcut", value: $params.lead.overcut, units: units)
        }
    }
}

struct PocketForm: View {
    @Binding var params: PocketParameters
    var units: LengthUnit
    var library: ToolLibrary
    var finishToolID: UUID?
    /// The finish tool in document units.
    var tool: Tool? = nil

    var body: some View {
        InspectorSection(title: "Cutting Depths") { DepthForm(depth: $params.depth, units: units, tool: tool) }
        Divider()
        InspectorSection(title: "Clearing") {
            PocketStrategyForm(strategy: $params.strategy, profileFirst: $params.profilePassFirst)
            DirectionPicker(direction: $params.direction)
            LengthField("Allowance", value: $params.allowance, units: units)
        }
        Divider()
        InspectorSection(title: "Tools") {
            ClearanceToolsEditor(params: $params, library: library, finishToolID: finishToolID)
        }
        Divider()
        InspectorSection(title: "Ramps", collapsedByDefault: true) { RampForm(ramp: $params.ramp, units: units) }
    }
}

struct DrillForm: View {
    @Binding var params: DrillParameters
    var units: LengthUnit
    /// The drill in document units.
    var tool: Tool? = nil

    var body: some View {
        InspectorSection(title: "Drilling") {
            LengthField("Start depth", value: $params.startDepth, units: units)
            LengthField("Cut depth", value: $params.cutDepth, units: units)
            FluteLengthNote(tool: tool, cutDepth: params.cutDepth, startDepth: params.startDepth, units: units)
            Toggle("Peck drilling", isOn: Binding(get: { params.peckDepth > 0 }, set: { on in
                params.peckDepth = on ? (units == .inch ? 0.125 : 3) : 0
            }))
                .fieldHelp("Peck drilling")
            if params.peckDepth > 0 {
                LengthField("Peck depth", value: $params.peckDepth, units: units, help: "Depth added by each peck")
                LengthField("Retract height", value: $params.retractHeight, units: units,
                            help: "Above the material top between pecks (clears chips)")
            }
            NumberField("Dwell at bottom", value: $params.dwellSeconds, unit: "s")
            Text(OperationHints.peckSummary(params, units: units)).font(.caption).foregroundStyle(.secondary)
            Text("Drills at the center of each selected vector.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct VCarveForm: View {
    @Binding var params: VCarveParameters
    var units: LengthUnit
    var library: ToolLibrary

    var body: some View {
        InspectorSection(title: "V-Carve") {
            LengthField("Start depth", value: $params.startDepth, units: units)
            OptionalLengthField(label: "Flat depth", value: $params.flatDepth, units: units,
                                defaultValue: units == .inch ? 0.125 : 3)
            if params.flatDepth != nil {
                OptionalToolPicker(title: "Flat area tool", toolID: $params.flatClearanceToolID, library: library,
                                   kinds: ClearanceToolList.kinds)
                if params.flatClearanceToolID != nil {
                    ClearanceToolList(tools: $params.extraClearanceTools, library: library)
                    PocketStrategyForm(strategy: $params.flatClearanceStrategy)
                }
            }
            OptionalLengthField(label: "Max pass depth", value: $params.passDepth, units: units,
                                defaultValue: units == .inch ? 0.1 : 2.5)
        }
        Divider()
        InspectorSection(title: "Open Vectors") {
            OptionalLengthField(label: "Engrave at depth", value: $params.openVectorDepth, units: units,
                                defaultValue: units == .inch ? 0.05 : 1.25)
            if params.openVectorDepth != nil {
                NumberField("Taper ends", value: Binding(get: { params.openVectorTaper * 100 },
                                                         set: { params.openVectorTaper = min(max($0 / 100, 0), 0.5) }),
                            unit: "%", help: "Share of each line's length over which its ends rise to the surface (0 = constant depth, max 50%)")
                Text("Open vectors are engraved along the line with the V-bit; tapered ends give sketch-style strokes.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Open vectors in the selection are ignored.").font(.caption).foregroundStyle(.secondary)
            }
        }
        Divider()
        InspectorSection(title: "Order") {
            Toggle("Use vector start points", isOn: $params.useVectorStartPoints)
                .help("Start outlines and engraved lines at each vector's start point")
            Toggle("Use vector selection order", isOn: $params.useSelectionOrder)
                .help("Carve the vectors in the order they were selected instead of the shortest route")
        }
    }
}

/// Plug outer boundary mode, its margin and the optional surface clearance.
struct PlugBoundaryFields: View {
    @Binding var boundary: InlayPlugBoundary
    @Binding var margin: Double
    @Binding var surfaceClearance: Double?
    var defaultClearance: Double
    var units: LengthUnit

    var body: some View {
        Picker("Plug boundary", selection: $boundary) {
            Text("Boundary offset").tag(InlayPlugBoundary.boundaryOffset)
            Text("Vector offset").tag(InlayPlugBoundary.vectorOffset)
            Text("Sheet limits").tag(InlayPlugBoundary.sheetLimits)
        }
            .fieldHelp("Plug boundary")
        if boundary != .sheetLimits {
            LengthField(boundary == .vectorOffset ? "Outline margin" : "Box margin", value: $margin, units: units,
                        help: boundary == .vectorOffset
                            ? "Waste cleared around the plug's own outline (least material removed; free the plug afterwards)"
                            : "Waste cleared out to the plug's bounding box grown by this margin")
        }
        OptionalLengthField(label: "Surface clearance", value: $surfaceClearance, units: units,
                            defaultValue: max(defaultClearance, units == .inch ? 0.05 : 1))
        Text("Surface clearance: how far the plug board stays above the pocket board when seated (default: pocket depth − plug start depth).")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Further flat-area clearance tools (after the first): each one only clears what the tools
/// above it could not reach, so list them largest first.
struct ClearanceToolList: View {
    static let kinds: [ToolKind] = [.endMill, .ballNose, .engraving]
    @Binding var tools: [VCarveClearanceTool]
    var library: ToolLibrary

    private var choices: [Tool] { library.tools.filter { Self.kinds.contains($0.kind) } }

    var body: some View {
        ForEach(tools.indices, id: \.self) { i in row(i) }
        Button("Add Smaller Clearance Tool") {
            if let t = choices.min(by: { $0.diameter < $1.diameter }) { tools.append(VCarveClearanceTool(toolID: t.id)) }
        }
        .disabled(choices.isEmpty)
        if !tools.isEmpty {
            Text("Tools run in this order; each one only clears what the tools before it could not reach.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One extra tool. Bindings are index-guarded: SwiftUI may re-read a row after removal.
    @ViewBuilder private func row(_ i: Int) -> some View {
        let id = i < tools.count ? tools[i].toolID : UUID()
        HStack {
            Picker("Then tool \(i + 2)", selection: Binding(get: { i < tools.count ? tools[i].toolID : id },
                                                            set: { if i < tools.count { tools[i].toolID = $0 } })) {
                if library.tool(id: id) == nil { Text("Missing tool").tag(id) }
                ForEach(choices) { t in Text("T\(t.number) · \(t.name)").tag(t.id) }
            }
            .help("A smaller tool that clears only what the tools before it could not reach")
            Button { if i < tools.count { tools.remove(at: i) } } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.icon).help("Remove this clearance tool")
        }
        if library.tool(id: id)?.angle != nil {
            Toggle("Corner sharpen", isOn: Binding(get: { i < tools.count && tools[i].cornerSharpen },
                                                   set: { if i < tools.count { tools[i].cornerSharpen = $0 } }))
                .help("Lift this tapered tool into corners it cannot reach at the flat depth, so they finish crisp")
        }
    }
}

struct InlayForm: View {
    @Binding var params: InlayParameters
    var units: LengthUnit
    var library: ToolLibrary

    var body: some View {
        InspectorSection(title: "Inlay") {
            Picker("Part", selection: $params.part) {
                Text("Pocket (female)").tag(InlayPart.female)
                Text("Plug (male)").tag(InlayPart.male)
                Text("Both").tag(InlayPart.both)
            }
                .fieldHelp("Part")
            LengthField("Pocket depth", value: $params.pocketDepth, units: units)
            LengthField("Plug start depth", value: $params.maleStartDepth, units: units)
            LengthField("Glue gap", value: $params.glueGap, units: units)
            Toggle("Mirror plug", isOn: $params.mirrorMale)
                .fieldHelp("Mirror plug")
            PlugBoundaryFields(boundary: $params.plugBoundary, margin: $params.maleBoundaryMargin,
                               surfaceClearance: $params.surfaceClearance,
                               defaultClearance: params.pocketDepth - params.maleStartDepth, units: units)
            OptionalToolPicker(title: "Flat area tool", toolID: $params.flatClearanceToolID, library: library,
                               kinds: ClearanceToolList.kinds)
            if params.flatClearanceToolID != nil {
                ClearanceToolList(tools: $params.extraClearanceTools, library: library)
            }
            let gap = params.pocketDepth - params.maleStartDepth
            if params.maleStartDepth + params.glueGap > params.pocketDepth + 1e-9 {
                Text("Plug start depth + glue gap must not exceed the pocket depth.").font(.caption).foregroundStyle(Color.warningText)
            } else {
                Text("Gap under the plug: \(RulerTicks.label((gap * 1000).rounded() / 1000)) \(units.abbreviation)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct FlutingForm: View {
    @Binding var params: FlutingParameters
    var units: LengthUnit
    /// The selected tool in document units.
    var tool: Tool? = nil

    var body: some View {
        InspectorSection(title: "Cutting Depths") { DepthForm(depth: $params.depth, units: units, showFinalPass: false, tool: tool) }
        Divider()
        InspectorSection(title: "Fluting") {
            Picker("Ramp", selection: $params.ramp) {
                Text("Start").tag(FluteRamp.start)
                Text("End").tag(FluteRamp.end)
                Text("Both").tag(FluteRamp.both)
            }
            .pickerStyle(.segmented)
                .fieldHelp("Ramp")
            NumberField("Ramp length", value: Binding(get: { params.rampFraction * 100 },
                                                      set: { params.rampFraction = min(max($0 / 100, 0), 0.5) }), unit: "%")
            Toggle("Smooth ramp", isOn: $params.smoothRamp)
                .fieldHelp("Smooth ramp")
            Text("Each selected vector is cut once, plunging gradually over the ramp length to full depth. Use a ball nose or V-bit for tapered flutes.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct TextureForm: View {
    @Binding var params: TextureParameters
    var units: LengthUnit

    var body: some View {
        InspectorSection(title: "Texture") {
            LengthField("Max depth", value: $params.maxDepth, units: units)
            LengthField("Spacing", value: $params.spacing, units: units)
            LengthField("Min stroke", value: $params.minStrokeLength, units: units)
            LengthField("Max stroke", value: $params.maxStrokeLength, units: units)
            NumberField("Angle", value: $params.angle, unit: "°")
            NumberField("Variation", value: Binding(get: { params.variation * 100 },
                                                    set: { params.variation = min(max($0 / 100, 0), 1) }), unit: "%")
            LabeledContent("Seed") {
                HStack {
                    Text("\(params.seed)").monospacedDigit()
                    Button("Shuffle") { params.seed = UInt64.random(in: 1...999_999) }
                }
            }
            Text("Fills the selected closed vectors with short random strokes at the given spacing and angle.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct Relief3DForm: View {
    @Binding var params: Relief3DParameters
    var units: LengthUnit
    var library: ToolLibrary
    var models: [PlacedModel]
    var selection: [UUID]

    private func twoSidedBinding<T>(_ kp: WritableKeyPath<TwoSidedSettings, T>, default value: T) -> Binding<T> {
        Binding(get: { params.twoSided?[keyPath: kp] ?? value }, set: { params.twoSided?[keyPath: kp] = $0 })
    }

    @ViewBuilder private var twoSidedSection: some View {
        InspectorSection(title: "Two-Sided") {
            Toggle("Machine from both sides", isOn: Binding(get: { params.twoSided != nil }, set: { on in
                params.twoSided = on ? TwoSidedSettings(web: units == .inch ? 0.04 : 1) : nil
            }))
                .fieldHelp("Machine from both sides")
            if params.twoSided != nil {
                Picker("This toolpath cuts", selection: twoSidedBinding(\.side, default: .top)) {
                    Text("Top side").tag(TwoSidedSettings.Side.top)
                    Text("Bottom side").tag(TwoSidedSettings.Side.bottom)
                }
                .pickerStyle(.segmented)
                    .fieldHelp("This toolpath cuts")
                Picker("Flip board", selection: twoSidedBinding(\.flip, default: .leftRight)) {
                    Text("Left to right").tag(TwoSidedSettings.Flip.leftRight)
                    Text("Top to bottom").tag(TwoSidedSettings.Flip.topBottom)
                }
                    .fieldHelp("Flip board")
                OptionalLengthField(label: "Split depth", value: twoSidedBinding(\.splitDepth, default: nil), units: units,
                                    defaultValue: units == .inch ? 0.25 : 6)
                LengthField("Web", value: twoSidedBinding(\.web, default: 0), units: units,
                            help: "Material left at the split plane so the part stays in the board")
                Text("Make one toolpath per side (duplicate this one and switch the side). After the top side, turn the board over as chosen, keep it against the same corner (the stock must be exactly the job size) and zero Z on the new top.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Whether `id` is machined together with the primary model (composite surface).
    private func combinedBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { params.additionalModelIDs?.contains(id) ?? false }, set: { on in
            var ids = (params.additionalModelIDs ?? []).filter { $0 != id }
            if on { ids.append(id) }
            params.additionalModelIDs = ids.isEmpty ? nil : ids
        })
    }

    var body: some View {
        InspectorSection(title: "3D Model") {
            Picker("Model", selection: $params.modelID) {
                if !models.contains(where: { $0.id == params.modelID }) { Text("Missing model").tag(params.modelID) }
                ForEach(models) { Text($0.name).tag($0.id) }
            }
                .fieldHelp("Model")
            if models.count > 1 {
                Text("Combine with").font(.caption).foregroundStyle(.secondary)
                ForEach(models.filter { $0.id != params.modelID }) { m in
                    Toggle(m.name, isOn: combinedBinding(m.id))
                }
            }
            LengthField("Resolution", value: $params.resolution, units: units, help: "Heightmap cell size")
            Text(params.boundaryShapeIDs.isEmpty ? "Boundary: whole model" : "Boundary: \(params.boundaryShapeIDs.count) vector(s)")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Use Selection as Boundary") { params.boundaryShapeIDs = selection }.disabled(selection.isEmpty)
                Button("Clear") { params.boundaryShapeIDs = [] }.disabled(params.boundaryShapeIDs.isEmpty)
            }
        }
        Divider()
        twoSidedSection
        Divider()
        InspectorSection(title: "Roughing") {
            Toggle("Rough first", isOn: $params.roughing.isEnabled)
                .fieldHelp("Rough first")
            if params.roughing.isEnabled {
                OptionalToolPicker(title: "Roughing tool", toolID: $params.roughing.toolID, library: library, kinds: [.endMill])
                LengthField("Allowance", value: $params.roughing.allowance, units: units)
                OptionalLengthField(label: "Pass depth", value: $params.roughing.passDepth, units: units,
                                    defaultValue: units == .inch ? 0.125 : 3)
                PocketStrategyForm(strategy: $params.roughing.strategy)
            }
        }
        Divider()
        InspectorSection(title: "Finishing") {
            Toggle("Finish", isOn: $params.finishing.isEnabled)
                .fieldHelp("Finish")
            if params.finishing.isEnabled {
                OptionalLengthField(label: "Stepover", value: $params.finishing.stepover, units: units,
                                    defaultValue: units == .inch ? 0.02 : 0.5)
                Picker("Pattern", selection: Binding(get: { params.finishing.strategy ?? .raster },
                                                     set: { params.finishing.strategy = $0 })) {
                    Text("Raster").tag(FinishingStrategy.raster)
                    Text("Offset").tag(FinishingStrategy.offset)
                    Text("Spiral").tag(FinishingStrategy.spiral)
                }
                .pickerStyle(.segmented)
                    .fieldHelp("Pattern")
                if (params.finishing.strategy ?? .raster) == .raster {
                    NumberField("Raster angle", value: $params.finishing.angle, unit: "°")
                }
                OptionalToolPicker(title: "Rest after", toolID: $params.finishing.restToolID, library: library,
                                   kinds: [.ballNose, .endMill, .vBit, .engraving])
                if params.finishing.restToolID != nil {
                    Text("Only the areas the larger tool could not reach are machined (run after its finishing toolpath).")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Separate last pass (finishing lap that removes a side allowance).
struct ProfileLastPassForm: View {
    @Binding var lastPass: ProfileLastPass?
    var side: ProfileSide
    var units: LengthUnit

    private var enabled: Binding<Bool> {
        Binding(get: { lastPass != nil }, set: { on in
            lastPass = on ? ProfileLastPass(allowance: units == .inch ? 0.01 : 0.25) : nil
        })
    }

    private func field<T>(_ kp: WritableKeyPath<ProfileLastPass, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { lastPass?[keyPath: kp] ?? fallback }, set: { v in lastPass?[keyPath: kp] = v })
    }

    var body: some View {
        Toggle("Separate last pass", isOn: enabled)
            .fieldHelp("Separate last pass")
        if lastPass != nil {
            LengthField("Last pass allowance", value: field(\.allowance, 0), units: units,
                        help: "Material the roughing passes leave on the wall for the last pass")
            Toggle("Reverse direction", isOn: field(\.reverseDirection, false))
                .fieldHelp("Reverse direction")
            Toggle("Last pass at full depth", isOn: field(\.fullDepth, true))
                .fieldHelp("Last pass at full depth")
            Text(side == .on
                 ? "Not used when cutting on the line."
                 : "Roughing passes stay the allowance away from the wall; one more lap then cuts the wall to size.")
                .font(.caption).foregroundStyle(side == .on ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Ordered list of pocket clearance tools (largest first). Writes `clearanceToolIDs` and keeps
/// the legacy `clearanceToolID` equal to the first entry.
struct ClearanceToolsEditor: View {
    @Binding var params: PocketParameters
    var library: ToolLibrary
    var finishToolID: UUID?

    private var ids: [UUID] { params.clearanceTools }

    private func set(_ new: [UUID]) {
        params.clearanceToolIDs = new
        params.clearanceToolID = new.first
    }

    /// Index-guarded: SwiftUI may re-read a row after it was removed.
    private func row(_ i: Int) -> Binding<UUID> {
        Binding(get: { i < ids.count ? ids[i] : UUID() },
                set: { v in guard i < ids.count else { return }; var n = ids; n[i] = v; set(n) })
    }

    private var candidates: [Tool] {
        library.tools.filter { $0.kind == .endMill || $0.kind == .ballNose }
    }

    var body: some View {
        let problems = OperationHints.pocketClearanceProblems(finish: finishToolID.flatMap { library.tool(id: $0) },
                                                              clearance: ids.map { library.tool(id: $0) })
        ForEach(Array(ids.enumerated()), id: \.offset) { i, _ in
            HStack {
                Picker("Clearance \(i + 1)", selection: row(i)) {
                    if let id = i < ids.count ? ids[i] : nil, library.tool(id: id) == nil { Text("Missing tool").tag(id) }
                    ForEach(candidates) { t in Text("T\(t.number) · \(t.name)").tag(t.id) }
                }
                .help("A larger tool that clears most of the pocket before the finish tool")
                Button { guard i < ids.count else { return }; var n = ids; n.remove(at: i); set(n) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.icon).help("Remove this clearance tool")
            }
            if let problem = problems[i] {
                Text(problem).font(.caption).foregroundStyle(Color.warningText).fixedSize(horizontal: false, vertical: true)
            }
        }
        Button { if let t = nextSuggestion { set(ids + [t.id]) } } label: { Label("Add Clearance Tool", systemImage: "plus") }
            .disabled(nextSuggestion == nil)
        Text(ids.isEmpty
             ? "The finish tool clears the whole pocket."
             : "Clearance tools cut largest first; each one only machines what the tools before it could not reach. The finish tool then cleans up the walls and corners.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    /// Largest unused tool that is smaller than the last clearance tool and larger than the finish tool.
    private var nextSuggestion: Tool? {
        func inch(_ t: Tool) -> Double { t.diameter * t.units.factor(to: .inch) }
        let finish = finishToolID.flatMap { library.tool(id: $0) }.map(inch) ?? 0
        let limit = ids.last.flatMap { library.tool(id: $0) }.map(inch) ?? .infinity
        let fits = candidates.filter { !ids.contains($0.id) && $0.id != finishToolID && inch($0) > finish + 1e-9 && inch($0) < limit - 1e-9 }
        return fits.max { inch($0) < inch($1) } ?? candidates.first { !ids.contains($0.id) && $0.id != finishToolID }
    }
}
