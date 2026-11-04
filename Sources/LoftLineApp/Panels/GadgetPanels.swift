import AppKit
import CADCore
import SwiftUI
import UniformTypeIdentifiers
import LoftLineKit

/// The Gadgets menu: built-in and user gadget scripts plus folder / reference helpers.
struct GadgetCommands: Commands {
    @FocusedObject private var document: LoftLineDocument?
    @ObservedObject private var library = GadgetLibrary.shared

    var body: some Commands {
        CommandMenu("Gadgets") {
            ForEach(library.builtIn) { g in
                Button(menuTitle(g)) { if let d = document { GadgetRunner.start(g, in: d) } }
                    .disabled(document == nil)
            }
            if !library.user.isEmpty {
                Divider()
                ForEach(library.user) { g in
                    Button(menuTitle(g)) { if let d = document { GadgetRunner.start(g, in: d) } }
                        .disabled(document == nil)
                }
            }
            Divider()
            Button("Run Gadget File…") { runFile() }
                .disabled(document == nil)
            Button("Reload Gadgets") { library.reload() }
            Button("Open Gadgets Folder") {
                library.prepareFolder()
                NSWorkspace.shared.open(library.directory)
            }
            Button("Gadget API Reference") { GadgetRunner.showReference() }
        }
    }

    private func menuTitle(_ g: GadgetScript) -> String { g.parameters.isEmpty ? g.name : g.name + "…" }

    private func runFile() {
        guard let doc = document else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "js") ?? .javaScript]
        panel.directoryURL = library.directory
        panel.message = "Choose a LoftLine gadget script (.js)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let loaded = GadgetLibrary.load(url) else {
            doc.report(AlertMessage(title: "Gadget", message: "\(url.lastPathComponent) could not be read as UTF-8 text."))
            return
        }
        GadgetRunner.start(loaded.script, in: doc, problems: loaded.problems)
    }
}

/// Starts gadgets: runs parameterless ones straight away, otherwise asks for the values in a
/// sheet on the document window.
enum GadgetRunner {
    private static var panel: NSWindow?

    static func start(_ script: GadgetScript, in document: LoftLineDocument, problems: [String]? = nil) {
        let problems = problems ?? GadgetLibrary.shared.problems[script.id] ?? []
        guard !script.parameters.isEmpty || !problems.isEmpty else {
            if case .failure(let e) = document.runGadget(script, values: [:]) {
                document.report(AlertMessage(title: script.name, message: e.message))
            }
            return
        }
        guard panel == nil, let parent = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = script.name
        let view = GadgetRunView(document: document, script: script, problems: problems) { [weak w, weak parent, weak document] in
            if let w { parent?.endSheet(w) }
            panel = nil
            // The gadget's output was held while this dialog was open: show it now.
            document?.platformSheetOpen = false
            document?.sheetDismissed()
        }
        .environment(\.documentVariables, document.document.variableTable)
        .environment(\.expressionUnits, document.units)
        w.contentViewController = NSHostingController(rootView: view)
        panel = w
        document.platformSheetOpen = true
        parent.beginSheet(w)
    }

    static func showReference() {
        HostedWindows.show(id: "gadget-api", title: "Gadget API Reference", size: CGSize(width: 720, height: 620)) {
            ScrollView {
                Text(GadgetAPI.reference)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }
}

/// Parameter dialog for one gadget run.
struct GadgetRunView: View {
    @ObservedObject var document: LoftLineDocument
    var script: GadgetScript
    var problems: [String]
    var close: () -> Void
    @State private var values: [String: GadgetValue]
    @State private var error: String?

    init(document: LoftLineDocument, script: GadgetScript, problems: [String], close: @escaping () -> Void) {
        self.document = document; self.script = script; self.problems = problems; self.close = close
        _values = State(initialValue: script.defaultValues(units: document.units))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !script.summary.isEmpty {
                Text(script.summary).fixedSize(horizontal: false, vertical: true)
            }
            if !script.parameters.isEmpty {
                Form {
                    ForEach(script.parameters) { p in control(for: p) }
                }
            }
            ForEach(problems, id: \.self) { p in
                Label(p, systemImage: "exclamationmark.triangle").foregroundStyle(Color.warningText).font(.callout)
            }
            if let error {
                Text(error).foregroundStyle(Color.errorText).font(.callout).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Reset") { values = script.defaultValues(units: document.units); error = nil }
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Run") { run() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    @ViewBuilder private func control(for p: GadgetParameter) -> some View {
        switch p.kind {
        case .number, .integer:
            ExpressionTextField(label: p.label, value: number(p.name))
        case .length:
            ExpressionTextField(label: "\(p.label) (\(document.units.abbreviation))", value: number(p.name))
        case .bool:
            Toggle(p.label, isOn: Binding(get: { values[p.name]?.bool ?? false }, set: { values[p.name] = .bool($0) }))
        case .text:
            TextField(p.label, text: Binding(get: { values[p.name]?.text ?? "" }, set: { values[p.name] = .text($0) }))
        case .choice(let options):
            Picker(p.label, selection: Binding(get: { values[p.name]?.text ?? options.first ?? "" },
                                               set: { values[p.name] = .text($0) })) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
        }
    }

    private func number(_ name: String) -> Binding<Double> {
        Binding(get: { values[name]?.number ?? 0 }, set: { values[name] = .number($0) })
    }

    private func run() {
        var v = values
        for p in script.parameters where p.kind == .integer {
            if let n = v[p.name]?.number { v[p.name] = .number(n.rounded()) }
        }
        switch document.runGadget(script, values: v) {
        case .success: close()
        case .failure(let e): error = e.message
        }
    }
}
