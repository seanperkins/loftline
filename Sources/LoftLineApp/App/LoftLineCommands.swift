import AppKit
import CADCore
import CAMCore
import PostCore
import SwiftUI
import UniformTypeIdentifiers

/// Menu bar commands. They act on the focused document window via `@FocusedObject`.
struct LoftLineCommands: Commands {
    @FocusedObject private var document: LoftLineDocument?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.newDocument) private var newDocument
    @ObservedObject private var updates = UpdateController.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { UpdateWindow.checkByHand() }
                .disabled(updates.isBusy)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { document?.printDesign(actualSize: false) }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(document == nil)
            Button("Print at Actual Size…") { document?.printDesign(actualSize: true) }
                .disabled(document == nil)
        }
        CommandGroup(after: .newItem) {
            TemplateMenu(document: document) { project in newDocument { LoftLineDocument(project: project) } }
        }
        CommandGroup(after: .importExport) {
            Button("Recover Unsaved Work…") { RecoveryPrompt.offer(interactive: true) }
            Divider()
            Button("Import…") { runImportPanel() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(document == nil)
            Button("Import 3D Model as 2D Parts…") { document?.runModelPartsPanel() }
                .disabled(document == nil)
            Button("Clipart…") { document?.sheet = .io(.clipart) }
                .disabled(document == nil)
            Button("Export Vectors…") { runExportVectorsPanel() }
                .disabled(document == nil)
            Button("Export G-code…") { document?.sheet = .exportGCode(.all) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(document?.project.operations.isEmpty ?? true)
            Button("Export Job Sheet…") { document?.exportJobSheet() }
                .disabled(document == nil)
            Button("Job Notes…") { document?.sheet = .io(.jobNotes(openedWithFile: false)) }
                .disabled(document == nil)
        }
        CommandGroup(after: .pasteboard) {
            Button("Duplicate") { document?.duplicateSelection() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(document?.selection.isEmpty ?? true)
            SelectMenu(document: document)
        }
        CommandGroup(after: .toolbar) {
            Button("Zoom to Material") { document?.requestCanvas(.fit) }.keyboardShortcut("0", modifiers: .command)
            Button("Zoom to Selection") { document?.requestCanvas(.fitSelection) }.keyboardShortcut("2", modifiers: .command)
            Button("Zoom In") { document?.requestCanvas(.zoomIn) }.keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") { document?.requestCanvas(.zoomOut) }.keyboardShortcut("-", modifiers: .command)
            Divider()
            Button("Show 2D Design") { document?.centerMode = .design2D }.keyboardShortcut("1", modifiers: [.command, .option])
            Button("Show 2D and 3D Side by Side") { document?.centerMode = .split }.keyboardShortcut("2", modifiers: [.command, .option])
            Button("Show 3D Preview") { document?.centerMode = .preview3D }.keyboardShortcut("3", modifiers: [.command, .option])
            Divider()
        }
        CommandMenu("Design") {
            Button("Job Setup…") { document?.sheet = .jobSetup }
                .keyboardShortcut("j", modifiers: [.command, .shift])
            Button(document?.activeSide == .bottom ? "Show Top Side" : "Show Bottom Side") {
                if let d = document { d.showSide(d.activeSide.other) }
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(!(document?.isTwoSided ?? false))
            SheetsMenu(document: document)
            Button("Document Variables…") { document?.sheet = .variables }
                .disabled(document == nil)
            Divider()
            Menu("Draw") {
                ForEach(CanvasTool.allCases) { tool in
                    Button(tool.titleWithKey) { document?.activeTool = tool }
                }
            }
            Divider()
            Menu("Layout") {
                Button("Nest Parts…") { document?.sheet = .nesting }
                    .disabled(document?.project.document.shapes.isEmpty ?? true)
                Menu("Sheet on Material") {
                    ForEach(document.map { NestSheets.numbers(in: $0.document) } ?? [1], id: \.self) { n in
                        Button("Sheet \(n)" + (document.map { NestSheets.activeSheet(in: $0.document) == n } == true ? " ✓" : "")) {
                            document?.showSheetOnMaterial(n)
                        }
                    }
                }
                .disabled(!(document.map { NestSheets.hasSheets($0.document) } ?? false))
                Divider()
                Button("Clamps and Fixture Holes…") { document?.sheet = .fixtures }
                    .disabled(document == nil)
                Button("Label Parts…") { document?.sheet = .partLabels }
                    .disabled(document?.project.document.shapes.isEmpty ?? true)
                Button("Production Plates…") { document?.sheet = .productionPlates }
                    .disabled(document?.selection.isEmpty ?? true)
            }
            Divider()
            Toggle("Snap to Grid", isOn: Binding(get: { document?.snapToGrid ?? true }, set: { document?.snapToGrid = $0 }))
                .keyboardShortcut("'", modifiers: .command)
            Toggle("Snap to Objects", isOn: Binding(get: { document?.snapToObjects ?? true }, set: { document?.snapToObjects = $0 }))
                .keyboardShortcut("'", modifiers: [.command, .shift])
        }
        // The selection commands, split from Design (about 25 entries in one menu).
        CommandMenu("Arrange") {
            Menu("Align") {
                ForEach(AlignMode.allCases) { mode in
                    Button(mode.title) { withSelection("Align") { ids, p in DesignCommands.align(ids, mode: mode, in: &p) } }
                        .disabled(!arrange.canAlign(mode))
                }
                Divider()
                Button("Distribute Horizontally") { withSelection("Distribute") { ids, p in DesignCommands.distribute(ids, horizontally: true, in: &p) } }
                    .disabled(!arrange.triple)
                Button("Distribute Vertically") { withSelection("Distribute") { ids, p in DesignCommands.distribute(ids, horizontally: false, in: &p) } }
                    .disabled(!arrange.triple)
                Button("Equal Spacing Horizontally") { withSelection("Distribute") { ids, p in DesignCommands.distributeSpacing(ids, horizontally: true, in: &p) } }
                    .disabled(!arrange.triple)
                Button("Equal Spacing Vertically") { withSelection("Distribute") { ids, p in DesignCommands.distributeSpacing(ids, horizontally: false, in: &p) } }
                    .disabled(!arrange.triple)
            }
            Button("Group") { document?.groupSelection() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled((document?.selection.count ?? 0) < 2)
            Button("Ungroup") { document?.ungroupSelection() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!(document?.selectedShapes.contains { $0.groupID != nil } ?? false))
            Button("Combine Vectors") {
                guard let doc = document else { return }
                let order = doc.selectedShapes.map(\.id)
                var newID: UUID?
                doc.perform("Combine") { newID = DesignCommands.combine(order, in: &$0) }
                if let id = newID { doc.setSelection([id]) }
            }
            .disabled(!arrange.pair)
            Button("Break Apart") {
                guard let doc = document else { return }
                let ids = doc.selection
                var newIDs: [UUID] = []
                doc.perform("Break Apart") { newIDs = DesignCommands.explode(ids, in: &$0) }
                if !newIDs.isEmpty { doc.setSelection(newIDs) }
            }
            .disabled(!arrange.any)
            Button("Join Open Vectors…") { document?.sheet = .drawing(.joinVectors) }
                .disabled(!arrange.any)
            Button("Edit Nodes") { document?.activeTool = .nodeEdit }
                .disabled(!arrange.any)
            Divider()
            Menu("Boolean") {
                ForEach(BooleanMode.allCases) { mode in
                    Button(mode.title) {
                        guard let doc = document else { return }
                        let order = doc.selectedShapes.map(\.id)
                        var newID: UUID?
                        doc.perform(mode.title) { newID = DesignCommands.boolean(mode, ids: order, in: &$0) }
                        if let id = newID { doc.setSelection([id]) }
                    }
                }
            }
            .disabled(!arrange.pair)
            Button("Offset…") { document?.sheet = .offset }.disabled(!arrange.any)
            Button("Mirror Horizontally") { withSelection("Mirror") { ids, p in TransformCommands.mirror(ids, horizontally: true, in: &p) } }
                .disabled(!arrange.any)
            Button("Mirror Vertically") { withSelection("Mirror") { ids, p in TransformCommands.mirror(ids, horizontally: false, in: &p) } }
                .disabled(!arrange.any)
            Button("Rotate 90° Left") { withSelection("Rotate") { ids, p in TransformCommands.rotate(ids, degrees: 90, in: &p) } }
                .keyboardShortcut("[", modifiers: [.command, .option])
                .disabled(!arrange.any)
            Button("Rotate 90° Right") { withSelection("Rotate") { ids, p in TransformCommands.rotate(ids, degrees: -90, in: &p) } }
                .keyboardShortcut("]", modifiers: [.command, .option])
                .disabled(!arrange.any)
            Button("Close Open Vectors") { withSelection("Close Vectors") { ids, p in DesignCommands.close(ids, in: &p) } }
                .disabled(!arrange.any)
        }
        CommandGroup(replacing: .help) {
            Button("LoftLine Help") { showHelp(.gettingStarted) }
                .keyboardShortcut("?", modifiers: .command)
            Button("Keyboard Shortcuts") { showHelp(.shortcuts) }
            Button("Running a Safe Air Cut") { showHelp(.airCut) }
            Divider()
            Button("Welcome to LoftLine") { WelcomeView.show() }
        }
        CommandMenu("Toolpaths") {
            Menu("New Toolpath") {
                ForEach(OperationFactory.menuKinds, id: \.self) { kind in
                    Button(OperationFactory.menuTitle(kind)) { document?.addOperation(kind) }
                }
            }
            .disabled(document == nil)
            Button("Calculate All") { document?.calculateAll() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(document?.project.operations.isEmpty ?? true)
            Button("Check Toolpaths…") { document?.sheet = .validation }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(document?.project.operations.isEmpty ?? true)
            Button("Save All Toolpaths…") { document?.sheet = .saveAllToolpaths }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(document?.project.operations.isEmpty ?? true)
            Button("Save Toolpath Template…") { document?.runSaveTemplatePanel() }
                .disabled(document?.project.operations.isEmpty ?? true)
            Button("Apply Toolpath Template…") { document?.runApplyTemplatePanel() }
                .disabled(document == nil)
            Button("Keep-Out Zones…") { document?.sheet = .keepOutZones }
                .disabled(document == nil)
            Button("Merge With Next Toolpath") {
                if let doc = document, let id = doc.selectedOperationID { doc.mergeOperationWithNext(id) }
            }
            .disabled(document.flatMap { d in d.selectedOperationID.map { d.project.mergeWithNextProblem($0) == nil } } != true)
            Button("Split Merged Toolpath") {
                if let doc = document, let id = doc.selectedOperationID { doc.splitMergedOperation(id) }
            }
            .disabled(document.flatMap { $0.operation($0.selectedOperationID)?.kind } != .merge)
            Button("Save Tiled G-code…") { document?.sheet = .tiling }
                .disabled(document?.project.operations.isEmpty ?? true)
            Button("Preview G-code File…") { if let d = document { GCodePreviewWindow.run(for: d) } }
                .disabled(document == nil)
            Divider()
            Toggle("Show Toolpaths", isOn: Binding(get: { document?.showToolpaths ?? true }, set: { document?.showToolpaths = $0 }))
                .keyboardShortcut("p", modifiers: [.command, .option])
            Divider()
            Button("Tool Database…") {
                ToolLibraryModel.shared.jobMaterial = document?.document.job.material
                openWindow(id: ToolDatabaseView.windowID)
            }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Post Processors…") { document?.sheet = .postProcessors }
                .disabled(document == nil)
            Button("Reload Post Profiles") { PostProfileCatalog.shared.reload() }
            Button("Open Post Profiles Folder") { openPostFolder() }
        }
    }

    private var arrange: ArrangeAvailability { ArrangeAvailability(selectionCount: document?.selection.count ?? 0) }

    private func showHelp(_ topic: HelpTopic) { HelpNavigator.show(topic) }

    private func withSelection(_ name: String, _ change: @escaping (Set<UUID>, inout LoftLineProject) -> Void) {
        guard let doc = document, !doc.selection.isEmpty else { return }
        let ids = doc.selection
        doc.perform(name) { change(ids, &$0) }
    }

    private func runImportPanel() {
        guard let doc = document else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ImportService.allowedContentTypes
        panel.message = "Import vectors (SVG, DXF, EPS, AI, PDF), a tracing image or a 3D model"
        PanelRunner.present(panel) { response in
            guard response == .OK else { return }
            doc.importFiles(panel.urls)
        }
    }

    private func runExportVectorsPanel() {
        guard let doc = document else { return }
        let panel = NSSavePanel()
        let format = VectorFormatAccessory(panel: panel, fileName: VectorExportFormat.svg.fileName(from: doc.document.name))
        panel.message = doc.selection.isEmpty ? "Export all vectors" : "Export the selected vectors"
        PanelRunner.present(panel) { response in
            _ = format  // the accessory must outlive the panel
            guard response == .OK, let url = panel.url else { return }
            doc.exportVectors(to: url, selectionOnly: !doc.selection.isEmpty)
        }
    }

    private func openPostFolder() {
        let dir = PostProfileCatalog.shared.store.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Seed a sample the user can copy/edit.
        let sample = dir.appendingPathComponent("example-avid-inch.json.sample")
        if !FileManager.default.fileExists(atPath: sample.path), let data = try? PostCoreSample.data() {
            try? data.write(to: sample)
        }
        NSWorkspace.shared.open(dir)
    }
}

/// Sample profile JSON written next to user profiles as a starting point.
enum PostCoreSample {
    static func data() throws -> Data {
        var p = BuiltInPosts.avidMach4Inch
        p.id = "my-custom-post"
        p.name = "My Custom Post"
        return try p.toJSON()
    }
}
