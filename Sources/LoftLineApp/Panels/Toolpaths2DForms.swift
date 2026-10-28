import CADCore
import CAMCore
import PostCore
import SwiftUI

// Forms for the 2D toolpaths added in the VCarve-parity work (toolpaths-2d).

private func fmt(_ v: Double) -> String { RulerTicks.label((v * 1000).rounded() / 1000) }

struct EngraveForm: View {
    @Binding var params: EngraveParameters
    var units: LengthUnit
    /// The selected tool in document units (for the width preview).
    var tool: Tool?

    var body: some View {
        InspectorSection(title: "Cutting Depths") {
            DepthForm(depth: $params.depth, units: units, tool: tool)
        }
        Divider()
        InspectorSection(title: "Quick Engrave") {
            DirectionPicker(direction: $params.direction)
            if let tool {
                let w = EngraveOperation.cutWidth(tool: tool, depth: params.depth.cutDepth)
                Text("Groove width at \(fmt(params.depth.cutDepth)) \(units.abbreviation) deep: \(fmt(w)) \(units.abbreviation)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Cuts along each selected vector on its centerline (no offset). Open and closed vectors both work.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ChamferForm: View {
    @Binding var params: ChamferParameters
    var units: LengthUnit
    var tool: Tool?

    /// Whether the depth and width are measured from the start depth's surface (not the material top).
    private var fromStart: Bool { params.basis == .startSurface }

    private var byDepth: Binding<Bool> {
        Binding(get: { params.depth != nil }, set: { on in
            if on {
                let fallback = units == .inch ? 0.125 : 3
                params.depth = tool.flatMap { try? ChamferOperation.size(tool: $0, params: params).depth } ?? fallback
            } else {
                params.depth = nil
            }
        })
    }

    var body: some View {
        InspectorSection(title: "Chamfer") {
            Picker("Side", selection: $params.side) {
                Text("Outside").tag(ProfileSide.outside)
                Text("Inside").tag(ProfileSide.inside)
                Text("On").tag(ProfileSide.on)
            }
            .pickerStyle(.segmented)
                .fieldHelp("Side")
            Picker("Size by", selection: byDepth) {
                Text("Width").tag(false)
                Text("Depth").tag(true)
            }
            .pickerStyle(.segmented)
                .fieldHelp("Size by")
            if let d = params.depth {
                LengthField("Depth", value: Binding(get: { d }, set: { params.depth = $0 }), units: units,
                            help: fromStart ? "Depth of the bit tip below the start depth's surface" : "Depth of the bit tip below the material top")
            } else {
                LengthField("Width", value: $params.width, units: units,
                            help: fromStart ? "Chamfer width on the surface at the start depth (the material top when it is 0)"
                                            : "Chamfer width on the top surface")
            }
            if params.side != .on {
                LengthField("Tip clearance", value: $params.tipClearance, units: units,
                            help: "How far the tip runs into the waste past the edge")
            }
            LengthField("Start depth", value: $params.startDepth, units: units,
                        help: fromStart ? "Depth of the surface the chamfer is measured from; the material above it is taken as already removed"
                                        : "Depth the first pass starts at")
            if !fromStart, params.startDepth > 0 {
                Text("This chamfer is measured from the material top, as it was when it was made: the depth and width are taken "
                     + "there and the start depth only skips the passes above it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Measure from the start depth's surface") {
                    if let tool, let converted = try? ChamferOperation.measuredFromStartSurface(params, tool: tool) { params = converted }
                }
                .help("Keeps the tip as deep as it is now; the depth is then given below the start depth and the width is read there")
            }
            OptionalLengthField(label: "Pass depth", value: $params.passDepth, units: units,
                                defaultValue: units == .inch ? 0.1 : 2.5)
            DirectionPicker(direction: $params.direction)
            summary
        }
    }

    @ViewBuilder private var summary: some View {
        if let (text, ok) = summaryText {
            Text(text).font(.caption).foregroundStyle(ok ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summaryText: (String, Bool)? {
        guard let tool else { return nil }
        do {
            let s = try ChamferOperation.size(tool: tool, params: params)
            let u = units.abbreviation
            let tip = fromStart && params.startDepth > 0
                ? "tip \(fmt(s.depth)) \(u) below the start depth (\(fmt(s.tipDepth)) \(u) below the top)"
                : "tip \(fmt(s.tipDepth)) \(u) deep"
            return ("\(fmt(s.width)) \(u) wide × \(fmt(s.height)) \(u) high; \(tip).", true)
        } catch CAMError.invalidParameter(let message) {
            return (message, false)
        } catch {
            return nil
        }
    }
}

/// Pass depth editor: even passes, exact step, or a hand-edited list of pass depths.
struct PassEditor: View {
    @Binding var depth: DepthSettings
    var units: LengthUnit
    var showFinalPass = true
    var toolStepdown: Double?

    enum Mode: Hashable { case even, exact, custom }

    private var mode: Binding<Mode> {
        Binding(get: {
            if depth.customPasses != nil { return .custom }
            return depth.exactStep == true ? .exact : .even
        }, set: { m in
            switch m {
            case .even: depth.customPasses = nil; depth.exactStep = nil
            case .exact: depth.customPasses = nil; depth.exactStep = true
            case .custom:
                // Seed the list with the passes the current settings would make.
                depth.customPasses = Array(computed.dropLast())
            }
        })
    }

    private var stepdown: Double? { depth.passDepth ?? toolStepdown }
    private var computed: [Double] {
        var d = depth
        d.customPasses = nil
        return d.passDepths(toolStepdown: stepdown ?? max(depth.cutDepth - depth.startDepth, 1e-6))
    }

    var body: some View {
        Picker("Passes", selection: mode) {
            Text("Even").tag(Mode.even)
            Text("Exact step").tag(Mode.exact)
            Text("Custom").tag(Mode.custom)
        }
        .pickerStyle(.segmented)
        .help("Even: divide the depth evenly. Exact step: every pass is the pass depth, the remainder goes last. Custom: edit each pass depth.")
        if let custom = depth.customPasses {
            ForEach(Array(custom.enumerated()), id: \.offset) { i, value in
                HStack {
                    LengthField("Pass \(i + 1)", value: Binding(get: { value }, set: { v in
                        guard var list = depth.customPasses, i < list.count else { return }
                        list[i] = v
                        depth.customPasses = list
                    }), units: units, help: "Depth of this pass below the material top")
                    Button { depth.customPasses?.remove(at: i) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.icon).help("Remove this pass")
                }
            }
            LabeledContent("Pass \(custom.count + 1)") {
                Text("\(fmt(depth.cutDepth)) \(units.abbreviation) (cut depth)").foregroundStyle(.secondary)
            }
            Button {
                let last = depth.customPasses?.last ?? depth.startDepth
                depth.customPasses?.append((last + depth.cutDepth) / 2)
            } label: { Label("Add Pass", systemImage: "plus") }
        } else {
            OptionalLengthField(label: "Pass depth", value: $depth.passDepth, units: units,
                                defaultValue: units == .inch ? 0.125 : 3)
            if showFinalPass {
                LengthField("Last pass thickness", value: $depth.finalPassDepth, units: units,
                            help: "Material left for a thin last pass (0 = none)")
            }
        }
        if depth.customPasses == nil, let s = stepdown, !(s > 0) {
            Text("Pass depth must be positive.").font(.caption).foregroundStyle(Color.errorText)
        } else if stepdown != nil || depth.customPasses != nil {
            let passes = depth.passDepths(toolStepdown: stepdown ?? 1)
            if !passes.isEmpty {
                Text("\(passes.count) pass\(passes.count == 1 ? "" : "es"): " + passes.map(fmt).joined(separator: ", ")
                     + " \(units.abbreviation)")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct HoleMillForm: View {
    @Binding var params: HoleMillParameters
    var units: LengthUnit
    var tool: Tool?

    var body: some View {
        InspectorSection(title: "Hole Milling") {
            Picker("Mode", selection: $params.mode) {
                Text("Helical bore").tag(HoleMillMode.helical)
                Text("Thread mill").tag(HoleMillMode.thread)
            }
            .pickerStyle(.segmented)
                .fieldHelp("Mode")
            LengthField("Start depth", value: $params.startDepth, units: units)
            LengthField("Cut depth", value: $params.cutDepth, units: units)
            FluteLengthNote(tool: tool, cutDepth: params.cutDepth, startDepth: params.startDepth, units: units)
            OptionalLengthField(label: params.mode == .thread ? "Major diameter" : "Hole diameter",
                                value: $params.holeDiameter, units: units, defaultValue: units == .inch ? 0.5 : 12)
            if params.mode == .helical {
                OptionalLengthField(label: "Depth per turn", value: $params.helixPitch, units: units,
                                    defaultValue: tool?.stepdown ?? (units == .inch ? 0.05 : 1.25))
            } else {
                LengthField("Thread pitch", value: $params.threadPitch, units: units, help: "Distance per turn")
                if units == .inch, params.threadPitch > 0 {
                    Text("\(RulerTicks.label((1 / params.threadPitch * 10).rounded() / 10)) threads per inch")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Right-hand thread", isOn: $params.rightHandThread)
                    .fieldHelp("Right-hand thread")
            }
            DirectionPicker(direction: $params.direction)
            Text(params.mode == .helical
                 ? "Spirals down at each selected circle's size (or the diameter above), then cleans the bottom with a flat lap. Holes smaller than the tool are skipped."
                 : "Plunges at the center of each circle (drill a pilot hole first), moves out and cuts one turn per pitch. Use a thread mill; its diameter is the tool diameter.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct FacingForm: View {
    @Binding var params: FacingParameters
    var units: LengthUnit
    var tool: Tool?
    /// The document has other sheets, or machines both sides (a toolpath without vectors cannot say which it is for).
    var multiSheet = false
    var twoSided = false

    /// The operation for `params`: a facing of the whole material takes no vectors and cannot be projected onto a
    /// model, so the sheet and side it belongs to are the ones every vectorless toolpath has and the note below is true
    /// (switching the area from Selected vectors must not leave the old vectors, or a projection, behind).
    static func operation(_ setup: OperationSetup, params: FacingParameters) -> AnyOperation {
        var setup = setup
        if params.area == .material {
            setup.shapeIDs = []
            setup.projectOntoModelID = nil
        }
        return .facing(FacingOperation(setup: setup, params: params))
    }

    /// Why a facing of the whole material may not be where it is expected: with no vectors it belongs to the first
    /// sheet and the top side, as a 3D relief does. nil when there is nothing to say.
    static func scopeNote(area: FacingArea, multiSheet: Bool, twoSided: Bool) -> String? {
        guard area == .material, multiSheet || twoSided else { return nil }
        return "With no vectors this facing belongs to the first sheet and the top side. To face another sheet or the bottom side, draw a rectangle on it and choose Selected vectors."
    }

    var body: some View {
        InspectorSection(title: "Cutting Depths") {
            DepthForm(depth: $params.depth, units: units, tool: tool)
        }
        Divider()
        InspectorSection(title: "Facing") {
            Picker("Area", selection: $params.area) {
                Text("Whole material").tag(FacingArea.material)
                Text("Selected vectors").tag(FacingArea.vectors)
            }
            .pickerStyle(.segmented)
                .fieldHelp("Area")
            Picker("Facing pattern", selection: $params.pattern) {
                Text("Along X").tag(FacingPattern.rasterX)
                Text("Along Y").tag(FacingPattern.rasterY)
                Text("Spiral").tag(FacingPattern.spiral)
            }
            .pickerStyle(.segmented)
                .fieldHelp("Facing pattern")
            NumberField("Stepover", value: Binding(get: { params.stepover * 100 },
                                                   set: { params.stepover = min(max($0 / 100, 0.01), FacingOperation.maxStepover) }),
                        unit: "%", help: "Distance between passes, as a percentage of the tool diameter")
            OptionalLengthField(label: "Overhang", value: $params.overhang, units: units,
                                defaultValue: tool?.radius ?? (units == .inch ? 0.125 : 3))
            if params.pattern == .spiral { DirectionPicker(direction: $params.direction) }
            Text(params.area == .material
                 ? "Takes a layer off the top of the whole material. The first pass is led in from outside; a raster runs out past the material before it lifts, a spiral lifts in the middle."
                 : "Takes a layer off the top of the box round the selected vectors. The cutter reaches past the box by the overhang, so face the whole material if the stock continues beyond it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let note = Self.scopeNote(area: params.area, multiSheet: multiSheet, twoSided: twoSided) {
                Text(note).font(.caption).foregroundStyle(Color.warningText).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct PrismForm: View {
    @Binding var params: PrismParameters
    var units: LengthUnit

    var body: some View {
        InspectorSection(title: "Prism Carve") {
            OptionalLengthField(label: "Max depth", value: $params.maxDepth, units: units,
                                defaultValue: units == .inch ? 0.25 : 6,
                                help: "Stop the V-bit at this depth; wider shapes keep a flat top")
            OptionalLengthField(label: "Pass depth", value: $params.passDepth, units: units,
                                defaultValue: units == .inch ? 0.1 : 2.5)
            DirectionPicker(direction: $params.direction)
            Text("The V-bit runs round each closed shape at the depth where its flanks meet along the shape's centerline, so the shape is left as a beveled prism with a sharp ridge. Each shape gets its own depth; with a max depth, wider parts keep a flat top.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Repeat the toolpath on a grid (OperationSetup.arrayCopy).
struct ArrayCopyForm: View {
    @Binding var array: ArrayCopySettings?
    var units: LengthUnit

    private func field<T>(_ kp: WritableKeyPath<ArrayCopySettings, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { array?[keyPath: kp] ?? fallback }, set: { v in array?[keyPath: kp] = v })
    }

    var body: some View {
        Toggle("Repeat on a grid", isOn: Binding(get: { array != nil }, set: { on in
            array = on ? ArrayCopySettings(spacingX: units == .inch ? 6 : 150, spacingY: units == .inch ? 6 : 150) : nil
        }))
            .fieldHelp("Repeat on a grid")
        if let a = array {
            IntField("Columns", value: field(\.columns, 1), range: 1...100)
            IntField("Rows", value: field(\.rows, 1), range: 1...100)
            LengthField("X spacing", value: field(\.spacingX, 0), units: units, help: "Distance between columns")
            LengthField("Y spacing", value: field(\.spacingY, 0), units: units, help: "Distance between rows")
            Text("\(a.count) cop\(a.count == 1 ? "y" : "ies") of this toolpath, cut row by row. The vectors are not copied; the toolpath shows a warning when copies run off the material.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// An operator stop after the toolpath (`OperationSetup.pauseAfter`): the program lifts to safe Z,
/// stops the spindle, shows the message and waits for Cycle Start.
struct PauseStepForm: View {
    @Binding var pause: PauseStep?
    var toolpathName: String
    /// The project's post: GRBL has no Optional Stop, so an optional stop there writes M0 (#115).
    var profile: PostProfile

    var body: some View {
        Toggle("Pause the machine after this toolpath", isOn: Binding(get: { pause != nil }, set: { on in
            pause = on ? PauseStep() : nil
        }))
        .help("Lift to safe Z, stop the spindle and wait for Cycle Start: flip the part, add clamps, clear chips")
        if let p = pause {
            TextField("Message", text: Binding(get: { pause?.message ?? "" }, set: { pause?.message = $0 }),
                      prompt: Text(PauseStep().text(afterToolpath: toolpathName)))
                .help("Shown on the controller while the machine waits")
            let honoured = profile.honoursOptionalStop
            Toggle(honoured ? "Optional stop (M1)" : "Optional stop (GRBL: always stops, M0)",
                   isOn: Binding(get: { pause?.isOptionalStop ?? false }, set: { pause?.isOptionalStop = $0 }))
                .help(honoured ? "Stops only when Optional Stop is switched on at the controller; otherwise the program runs straight through"
                               : "GRBL has no Optional Stop and ignores M1, so this post writes M0: the machine always stops here")
            Text("The program stops (\(profile.stopCode(for: p))) between this toolpath and the next one, and the next toolpath restarts the spindle. Nothing is added after the last toolpath. No recalculation is needed.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Coolant while this toolpath cuts (`OperationSetup.coolant`): Off, Mist (M7) or Air (M8).
struct CoolantForm: View {
    @Binding var coolant: Coolant?

    var body: some View {
        Picker("Coolant", selection: $coolant) {
            Text("Off").tag(Coolant?.none)
            ForEach(Coolant.allCases, id: \.self) { c in Text(c.displayName).tag(Coolant?.some(c)) }
        }
        .help("Turned on after the spindle starts and off (M9) before a tool change, a pause and the program's end")
        Text("Mist writes M7 and Air writes M8. A stock GRBL controller has no M7: use Air there. No recalculation is needed.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// A merged toolpath: its parts in cutting order and a Split button.
struct MergeForm: View {
    var operation: MergeOperation
    var onSplit: () -> Void

    var body: some View {
        InspectorSection(title: "Merged Toolpaths") {
            ForEach(Array(operation.params.children.enumerated()), id: \.offset) { i, c in
                Text("\(i + 1). \(c.setup.name) (\(c.kind.displayName))")
            }
            Text("Cut one after the other with one tool load. Consecutive parts with the same tool become one toolpath.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Split Into Separate Toolpaths", action: onSplit)
        }
    }
}

struct StraightInlayForm: View {
    @Binding var params: StraightInlayParameters
    var units: LengthUnit

    var body: some View {
        InspectorSection(title: "Straight-Wall Inlay") {
            Picker("Part", selection: $params.part) {
                Text("Pocket").tag(InlayPart.female)
                Text("Plug").tag(InlayPart.male)
                Text("Both").tag(InlayPart.both)
            }
            .pickerStyle(.segmented)
                .fieldHelp("Part")
            LengthField("Pocket depth", value: $params.pocketDepth, units: units)
            LengthField("Plug depth", value: $params.plugDepth, units: units, help: "Depth of the cut round the plug")
            LengthField("Clearance", value: $params.clearance, units: units, help: "Gap all round between plug and pocket")
            Toggle("Mirror plug", isOn: $params.mirrorPlug)
                .fieldHelp("Mirror plug")
            OptionalLengthField(label: "Pass depth", value: $params.passDepth, units: units,
                                defaultValue: units == .inch ? 0.125 : 3)
            Text("Both parts use the same outline with every corner rounded to the end mill's radius, so the plug drops into the pocket. Cut the pocket and the plug on separate boards (export them separately).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if params.plugDepth < params.pocketDepth {
                Text("The plug depth is less than the pocket depth; the plug will not fill the pocket.")
                    .font(.caption).foregroundStyle(Color.warningText)
            }
        }
    }
}

struct MouldingForm: View {
    @Binding var params: MouldingParameters
    var units: LengthUnit
    var document: Document
    var selection: [UUID]

    var body: some View {
        InspectorSection(title: "Moulding") {
            let section = params.sectionShapeID.flatMap { document.shape(id: $0) }
            LabeledContent("Cross-section") {
                Text(section.map { $0.name.isEmpty ? "1 vector" : $0.name } ?? "None").foregroundStyle(section == nil ? .orange : .primary)
            }
            HStack {
                Button("Use Selected Vector") { params.sectionShapeID = selection.last }.disabled(selection.count != 1)
                Button("Clear") { params.sectionShapeID = nil }.disabled(params.sectionShapeID == nil)
            }
            Picker("Section side (open rails)", selection: $params.side) {
                Text("Left").tag(OpenVectorSide.left)
                Text("Right").tag(OpenVectorSide.right)
            }
            .pickerStyle(.segmented)
                .fieldHelp("Section side (open rails)")
            LengthField("Start depth", value: $params.startDepth, units: units, help: "Extra depth under the whole section")
            OptionalLengthField(label: "Stepover", value: $params.stepover, units: units,
                                defaultValue: units == .inch ? 0.02 : 0.5)
            Toggle("Rough in levels first", isOn: $params.roughing)
                .fieldHelp("Rough in levels first")
            Text("The toolpath's vectors are the rails. The cross-section's width runs out from the rail (left or right of an open rail, inwards on a closed one) and its top is the material top. Use a ball nose for curved sections.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
