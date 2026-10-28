import AppKit
import CADCore
import PostCore
import SwiftUI

/// Toolpaths ▸ Post Processors…: the posts (built in, custom, and files that did not load), a form for every field of the
/// selected post, and the G-code it writes for a fixed sample job with the validator's verdict. Built-in posts are read-only;
/// Duplicate makes an editable copy that is written only by Save.
struct PostProcessorsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var catalog = PostProfileCatalog.shared
    @StateObject private var model = PostEditorModel(catalog: PostProfileCatalog.shared)
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                postList.frame(width: 220)
                Divider()
                editor.frame(minWidth: 380)
                Divider()
                preview.frame(width: 340)
            }
            Divider()
            buttons.padding(10)
        }
        .frame(width: 980, height: 690)
        .onAppear { if model.draft == nil { model.select(catalog.profiles.first?.id) } }
    }

    // MARK: List

    private var postList: some View {
        let builtInIDs = Set(BuiltInPosts.all.map(\.id))
        let userIDs = catalog.userIDs
        let custom = catalog.profiles.filter { userIDs.contains($0.id) }
        let builtIn = catalog.profiles.filter { builtInIDs.contains($0.id) && !userIDs.contains($0.id) }
        return List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
            Section("Built in") {
                ForEach(builtIn) { Text($0.name).tag(Optional($0.id)) }
            }
            if !custom.isEmpty || model.isNew {
                Section("Custom") {
                    ForEach(custom) { p in
                        VStack(alignment: .leading) {
                            Text(p.name)
                            if builtInIDs.contains(p.id) {
                                Text("Replaces the built-in").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(Optional(p.id))
                    }
                    if model.isNew, let d = model.draft {
                        Text("\(d.name) (unsaved)").italic().tag(Optional(d.id))
                    }
                }
            }
            if !catalog.skipped.isEmpty {
                Section("Did not load") {
                    ForEach(catalog.skipped, id: \.self) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.fileName)
                            Text(s.reason).font(.caption).foregroundStyle(Color.warningText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .disabled(model.isDirty && model.draft != nil)
        .help(model.isDirty ? "Save or Cancel the post you are editing first" : "")
    }

    // MARK: Form

    private func value<T>(_ kp: WritableKeyPath<PostProfile, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { model.draft?[keyPath: kp] ?? fallback }, set: { model.draft?[keyPath: kp] = $0 })
    }

    private func lines(_ kp: WritableKeyPath<PostProfile, [String]>) -> Binding<String> {
        Binding(get: { (model.draft?[keyPath: kp] ?? []).joined(separator: "\n") }, set: { model.setLines(kp, $0) })
    }

    private func caption(_ t: PostDraftReport.Template) -> some View {
        let names = (PostDraftReport.placeholders[t] ?? []).sorted().map { "{\($0)}" }.joined(separator: " ")
        return Text(names.isEmpty ? "No placeholders" : "Placeholders: " + names)
            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var editor: some View {
        if let draft = model.draft {
            let u = draft.units
            Form {
                if !model.isEditable {
                    Text("Built-in posts are read-only. Duplicate one to edit a copy.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Post") {
                    TextField("Name", text: value(\.name, ""))
                    TextField("Version", text: value(\.version, ""))
                    TextField("File extension", text: value(\.fileExtension, ""))
                    Picker("Units", selection: value(\.units, .inch)) {
                        ForEach(LengthUnit.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Picker("Controller", selection: value(\.controller, nil)) {
                        Text("None").tag(ToolChangeProbe.Controller?.none)
                        ForEach(ToolChangeProbe.Controller.allCases, id: \.self) { Text($0.displayName).tag(Optional($0)) }
                    }
                    .help("The controller this post's program runs on; touch-plate tool changes need it")
                }
                Section("Numbers") {
                    IntField("Decimals", value: value(\.decimals, 4), range: 0...12)
                    IntField("Feed decimals", value: value(\.feedDecimals, 1), range: 0...12)
                    Toggle("Modal output (omit repeated words)", isOn: value(\.modal, true))
                    Toggle("Line numbers", isOn: value(\.lineNumbers, false))
                    Toggle("Header comments", isOn: value(\.headerComments, true))
                    Picker("Comments", selection: value(\.commentStyle, .parentheses)) {
                        Text("( … )").tag(PostProfile.CommentStyle.parentheses)
                        Text("; …").tag(PostProfile.CommentStyle.semicolon)
                    }
                }
                Section("Motion") {
                    TextField("Rapid", text: value(\.rapid, ""))
                    TextField("Linear", text: value(\.linear, ""))
                    TextField("Arc CW", text: value(\.arcCW, ""))
                    TextField("Arc CCW", text: value(\.arcCCW, ""))
                    Picker("Arcs", selection: value(\.arcOutput, .incrementalIJ)) {
                        Text("Incremental I J").tag(PostProfile.ArcOutput.incrementalIJ)
                        Text("Absolute I J").tag(PostProfile.ArcOutput.absoluteIJ)
                        Text("Lines").tag(PostProfile.ArcOutput.linearize)
                    }
                    LengthField("Arc tolerance", value: value(\.arcTolerance, 0.001), units: u)
                    Toggle("Helical arcs", isOn: value(\.helicalArcs, true))
                }
                Section("Spindle") {
                    TextField("Spindle on", text: value(\.spindleOn, ""))
                    caption(.spindleOn)
                    TextField("Spindle off (used by touch-plate tool changes)", text: value(\.spindleOff, ""))
                    TextField("Dwell", text: value(\.dwell, ""))
                    NumberField("Dwell after spindle start", value: value(\.spindleDwellSeconds, 0), unit: "s")
                    NumberField("Min RPM", value: value(\.minRPM, 0), unit: "RPM")
                    NumberField("Max RPM", value: value(\.maxRPM, 0), unit: "RPM")
                }
                Section("Program") {
                    TemplateArea(label: "Preamble", text: lines(\.preamble)); caption(.preamble)
                    TemplateArea(label: "Tool change", text: lines(\.toolChange)); caption(.toolChange)
                    Toggle("Use the tool length offset", isOn: value(\.useToolLengthOffset, false))
                    TextField("Tool length offset", text: value(\.toolLengthOffset, ""))
                    TemplateArea(label: "Pause (empty = the default pause)",
                                 text: Binding(get: { (model.draft?.pause ?? []).joined(separator: "\n") },
                                               set: { model.setPauseText($0) }))
                    caption(.pause)
                    TemplateArea(label: "Footer", text: lines(\.footer)); caption(.footer)
                }
                Section("Limits and speeds (a machine's values replace these)") {
                    LengthField("X travel", value: value(\.limits.xTravel, 0), units: u)
                    LengthField("Y travel", value: value(\.limits.yTravel, 0), units: u)
                    LengthField("Z travel", value: value(\.limits.zTravel, 0), units: u)
                    LengthField("Allowed cut into spoilboard", value: value(\.limits.maxSpoilboardCut, 0), units: u)
                    NumberField("Rapid rate", value: value(\.rapidRate, 0), unit: "\(u.abbreviation)/min")
                    NumberField("Max feed", value: value(\.maxFeed, 0), unit: "\(u.abbreviation)/min")
                }
            }
            .formStyle(.grouped)
            .disabled(!model.isEditable)
        } else {
            Text("Select a post.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sample program").font(.headline)
            if model.report.problems.isEmpty {
                Label("Posts the sample job cleanly", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.report.problems, id: \.self) { p in
                            Label(p, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(Color.warningText).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
            ScrollView {
                Text(model.report.probeProgram.map { (model.report.program ?? "") + "\n(With touch-plate tool changes)\n" + $0 }
                     ?? model.report.program ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .padding(10)
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack {
            Button("Duplicate") { model.duplicate() }
                .disabled(model.draft == nil || model.isDirty)
                .help("Make an editable copy of the selected post (written only when you save)")
            Button("Folder") { openFolder() }
                .help("Open the folder that holds custom post files (JSON)")
            Button("Delete", role: .destructive) { run { try model.delete() } }
                .disabled(!model.canDelete || model.isDirty)
                .help("Move the selected custom post's file to the Trash")
            HelpButton(topic: .machines)
            if let error { Text(error).font(.caption).foregroundStyle(Color.errorText) }
            Spacer()
            if model.isDirty && model.draft != nil {
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
                Button("Save") { run { try model.save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.report.canSave)
            } else {
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func run(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = error.localizedDescription }
    }

    private func openFolder() {
        let dir = catalog.store.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
}

/// A multi-line template field: plain text, monospaced, with macOS's automatic quote and dash substitution off (a curly
/// quote or an em dash in a G-code line would be garbage to the controller).
struct TemplateArea: View {
    var label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
            PlainTextView(text: $text).frame(minHeight: 54, maxHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                .accessibilityLabel(label)
        }
    }
}

private struct PlainTextView: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        view.delegate = context.coordinator
        view.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}
