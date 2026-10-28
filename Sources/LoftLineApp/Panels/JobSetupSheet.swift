import CADCore
import PostCore
import SwiftUI

/// Job Setup: material size, units, XY origin, Z zero, safe Z and home position.
struct JobSetupSheet: View {
    @ObservedObject var document: LoftLineDocument
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var machines = MachineCatalog.shared
    @ObservedObject private var posts = PostProfileCatalog.shared
    @State private var form: JobSetupForm

    init(document: LoftLineDocument) {
        self.document = document
        _form = State(initialValue: JobSetupForm(project: document.project, machines: MachineCatalog.shared.machines))
    }

    var body: some View {
        let u = form.units
        // The form's own machine: the project's copy even when that machine is not installed here.
        let machine = form.machine
        let problems = form.fitProblems + form.problems
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Job Setup").font(.title2.bold()); Spacer(); HelpButton(topic: .jobSetup) }
            // Two compact columns so every setting, including Safe Z and Home, is visible without scrolling.
            HStack(alignment: .top, spacing: 28) {
                Form {
                    FormGroup("Job") {
                        TextField("Job name", text: $form.name)
                        if form.isMultiSheet { TextField("Sheet name", text: $form.sheetName) }
                        Picker("Units", selection: Binding(get: { form.units }, set: { form.setUnits($0) })) {
                            ForEach(LengthUnit.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented)
                            .fieldHelp("Units")
                    }
                    FormGroup("Machine") {
                        Picker("Machine", selection: Binding(get: { form.machineID ?? "" }, set: { id in
                            if let m = machines.machine(id: id) { form.selectMachine(m, profiles: posts.profiles) }
                        })) {
                            if form.machineID == nil { Text("Custom (post limits)").tag("") }
                            ForEach(form.machineChoices(installed: machines.machines), id: \.id) { Text($0.title).tag($0.id) }
                        }
                        .help("Machine: bed size, travel limits and the post processors that drive it")
                        PostProfilePicker(title: "Post processor",
                                          selection: Binding(get: { form.postID ?? "" }, set: { form.postID = $0 }),
                                          machine: machine, carried: document.carriedPostNotInstalled)
                            .help("Post processor (G-code dialect) for the selected machine")
                        ProjectCopyNotice(document: document)
                    }
                    FormGroup("Material") {
                        LengthField("Width (X)", value: $form.job.width, units: u)
                        LengthField("Height (Y)", value: $form.job.height, units: u)
                        LengthField("Thickness (Z)", value: $form.job.thickness, units: u)
                        MaterialNameField(material: $form.job.material,
                                          known: ToolGrouping.materialNames(document.mergedLibrary.tools))
                    }
                    FormGroup("Drawing") {
                        LengthField("Grid spacing", value: $form.gridSpacing, units: u)
                    }
                }
                .formStyle(.columns)
                .frame(maxWidth: .infinity, alignment: .top)
                Form {
                    FormGroup("Z zero") {
                        Picker("Z zero", selection: $form.job.zZero) {
                            ForEach(ZZeroMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                            .fieldHelp("Z zero")
                        Text(form.job.zZero == .materialTop
                             ? "Touch off on top of the material. Cuts have negative Z."
                             : "Touch off on the spoilboard. The material top is Z = thickness.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    FormGroup("XY origin") {
                        HStack(alignment: .top, spacing: 20) {
                            OriginPicker(origin: $form.job.xyOrigin)
                            Text("Machine X0 Y0 is at the \(form.job.xyOrigin.displayName.lowercased()) of the material.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Toggle("Offset the datum", isOn: Binding(get: { form.job.datumOffset != nil },
                                                                 set: { form.job.datumOffset = $0 ? (form.job.datumOffset ?? .zero) : nil }))
                            .fieldHelp("Offset the datum")
                        if form.job.datumOffset != nil {
                            LengthField("Offset X", value: Binding(get: { form.job.datumOffset?.x ?? 0 },
                                                                   set: { form.job.datumOffset?.x = $0 }), units: u,
                                        help: "Distance from the chosen corner/center to machine X0 (right is positive)")
                            LengthField("Offset Y", value: Binding(get: { form.job.datumOffset?.y ?? 0 },
                                                                   set: { form.job.datumOffset?.y = $0 }), units: u,
                                        help: "Distance from the chosen corner/center to machine Y0 (up is positive)")
                        }
                    }
                    TwoSidedSection(job: $form.job)
                    if machine?.toolChangeProbe != nil {
                        FormGroup("Touch-off spot (tool changes)") {
                            LengthField("Spot X", value: Binding(get: { form.job.touchOffSpot?.x ?? form.job.width / 2 },
                                                                 set: { form.job.touchOffSpot = Vec2($0, form.job.touchOffSpot?.y ?? form.job.height / 2) }),
                                        units: u, help: "Where the touch plate goes on the material, from its lower-left corner")
                            LengthField("Spot Y", value: Binding(get: { form.job.touchOffSpot?.y ?? form.job.height / 2 },
                                                                 set: { form.job.touchOffSpot = Vec2(form.job.touchOffSpot?.x ?? form.job.width / 2, $0) }),
                                        units: u, help: "Where the touch plate goes on the material, from its lower-left corner")
                            if form.job.touchOffSpot == nil {
                                Button("Use the material's centre") { form.job.touchOffSpot = Vec2(form.job.width / 2, form.job.height / 2) }
                                    .help("Sets the spot; the export refuses until it is set")
                            }
                            Text("The plate must lie on material no toolpath on this sheet removes, off clamps and keep-out zones.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    FormGroup("Rapid heights (above material top)") {
                        LengthField("Safe Z", value: $form.job.safeZ, units: u)
                        OptionalLengthField(label: "Plunge Z (rapid down to)", value: $form.job.plungeGap, units: u,
                                            defaultValue: u == .inch ? 0.1 : 2.5)
                        LengthField("Home Z", value: $form.job.homeZ, units: u)
                        LengthField("Home X", value: $form.job.home.x, units: u, help: "Machine coordinates")
                        LengthField("Home Y", value: $form.job.home.y, units: u, help: "Machine coordinates")
                    }
                }
                .formStyle(.columns)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(Color.warningText) }
                }
            }
            HStack {
                if form.units != document.units {
                    Text("Changing units converts the design and toolpath parameters.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") { document.applyJobSetup(form); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!form.problems.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 900)
        // Expressions in these fields see the form's own values, not the saved job's.
        .environment(\.documentVariables, form.variableTable(in: document.document))
        .environment(\.expressionUnits, form.units)
        // Only expressions typed into this sheet can be linked by its Apply: whatever a field
        // noted before it opened was consumed by that edit or belongs to nothing.
        .onAppear { _ = document.expressionRecorder.take() }
    }
}

/// 3×3 grid of radio dots over a material outline; only corners and centre are selectable.
struct OriginPicker: View {
    @Binding var origin: XYOrigin

    var body: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .controlBackgroundColor)).border(Color.secondary)
                .frame(width: 120, height: 80)
            VStack {
                HStack { dot(.upperLeft); Spacer(); dot(.upperRight) }
                Spacer()
                dot(.center)
                Spacer()
                HStack { dot(.lowerLeft); Spacer(); dot(.lowerRight) }
            }
            // Each dot is a 22 pt button, so its centre sits 11 pt in from this frame's edge: 142 x 102
            // puts the centres on the corners of the 120 x 80 outline.
            .frame(width: 142, height: 102)
        }
        .frame(width: 146, height: 106)
    }

    private func dot(_ o: XYOrigin) -> some View {
        Button { origin = o } label: {
            Image(systemName: origin == o ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(origin == o ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.icon)
        .help(o.displayName)
        .accessibilityLabel(AccessibilityNames.origin(o))
        .accessibilityAddTraits(origin == o ? .isSelected : [])
    }
}

/// Job Setup: double-sided machining (flip axis and the bottom side's Z zero).
struct TwoSidedSection: View {
    @Binding var job: JobSetup

    var body: some View {
        FormGroup("Sides") {
            Toggle("Two-sided job", isOn: Binding(get: { job.twoSided != nil },
                                                  set: { job.twoSided = $0 ? (job.twoSided ?? TwoSidedSetup()) : nil }))
                .fieldHelp("Two-sided job")
            if let t = job.twoSided {
                Picker("Flip the material", selection: Binding(get: { t.flip }, set: { job.twoSided?.flip = $0 })) {
                    ForEach(FlipAxis.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                    .fieldHelp("Flip the material")
                Picker("Bottom side Z zero", selection: Binding(get: { t.bottomZZero }, set: { job.twoSided?.bottomZZero = $0 })) {
                    Text("Same as top side").tag(ZZeroMode?.none)
                    ForEach(ZZeroMode.allCases, id: \.self) { Text($0.displayName).tag(ZZeroMode?.some($0)) }
                }
                    .fieldHelp("Bottom side Z zero")
                Text("Each side is drawn as seen from above while it faces up; the other side shows mirrored and dashed. Use the center origin, or stock cut exactly to size, so the second side registers to the first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// A titled group in a `.columns` form, which shows plain `Section` headings in body weight:
/// a headline heading with room above it, so the groups read as separate.
struct FormGroup<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Section {
            content
        } header: {
            Text(title).font(.headline).padding(.top, 14)
        }
    }
}

/// What the project's own copies of its post, machine and tools say, with Update This Project when one differs from
/// the installed one. The copy posts the G-code; nothing changes until the button is used.
private struct ProjectCopyNotice: View {
    @ObservedObject var document: LoftLineDocument
    @ObservedObject private var posts = PostProfileCatalog.shared
    @ObservedObject private var machines = MachineCatalog.shared

    var body: some View {
        let notice = document.copyNotice
        if !notice.lines.isEmpty || !notice.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(notice.lines, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                ForEach(notice.warnings, id: \.self) {
                    Label($0, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Color.warningText)
                }
                if document.hasCopyDifferences {
                    Button("Update This Project") { document.updateProjectFromInstalled() }
                        .help("Replace this project's copies with the ones installed on this Mac (Undo brings them back)")
                }
            }
        }
    }
}
