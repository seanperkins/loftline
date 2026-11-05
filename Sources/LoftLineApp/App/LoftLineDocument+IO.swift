import AppKit
import CADCore
import CAMCore
import Foundation
import PostCore
import SwiftUI
import UniformTypeIdentifiers
import LoftLineKit

/// File-menu actions added by the io workstream (extra formats, templates, print).
extension LoftLineDocument {
    /// Enabled, calculated toolpaths (for previews and the job sheet picture).
    var calculatedToolpaths: [Toolpath] {
        let group = UserDefaults.standard.bool(forKey: GCodeExporter.groupByToolKey)
        return GCodeExporter.toolpaths(scope: .all, operations: outputProject.operations, results: results, groupByTool: group)
    }
}

// MARK: Job templates

extension LoftLineDocument {
    /// File > Save as Template…: stores this project (job, layers, vectors, toolpaths, post).
    func runSaveJobTemplatePanel(store: JobTemplateStore = JobTemplateStore()) {
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let panel = NSSavePanel()
        panel.directoryURL = store.directory
        panel.allowedContentTypes = [.loftlineProject]
        panel.nameFieldStringValue = document.name
        panel.message = "Save this job (material, layers, vectors and toolpaths) as a template"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var p = project
            p.refreshToolSnapshot(from: toolLibrary.library)
            if url.deletingLastPathComponent().standardizedFileURL == store.directory.standardizedFileURL {
                try store.save(p, name: url.deletingPathExtension().lastPathComponent)
            } else {
                try p.encoded().write(to: url, options: .atomic)
            }
        } catch {
            report(AlertMessage(title: "Template not saved", message: error.localizedDescription))
        }
    }
}

/// File > New from Template submenu and Save as Template.
struct TemplateMenu: View {
    var document: LoftLineDocument?
    var open: (LoftLineProject) -> Void
    private let store = JobTemplateStore()

    var body: some View {
        Menu("New from Template") {
            let entries = store.templates()
            if entries.isEmpty { Text("No templates yet (File > Save as Template…)") }
            ForEach(entries) { entry in
                Button(entry.name) {
                    do { open(try store.instantiate(entry)) } catch {
                        let a = NSAlert()
                        a.messageText = "The template could not be opened"
                        a.informativeText = ImportService.describe(error)
                        a.runModal()
                    }
                }
            }
            Divider()
            Button("Open Templates Folder") {
                try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
                NSWorkspace.shared.open(store.directory)
            }
        }
        Button("Save as Template…") { document?.runSaveJobTemplatePanel() }
            .disabled(document == nil)
    }
}

// MARK: Print

/// Printable 2D design: material, visible vectors, tracing images, calculated toolpaths of the
/// current sheet/side. `actualSize` draws at 1:1 (tiled over pages); otherwise it fits the page.
final class DesignPrintView: NSView {
    let document: Document
    let toolpaths: [Toolpath]
    let actualSize: Bool

    init(document: Document, toolpaths: [Toolpath], actualSize: Bool, pageSize: NSSize) {
        self.document = document; self.toolpaths = toolpaths; self.actualSize = actualSize
        let frame: NSRect
        if actualSize {
            let b = document.job.materialBounds.union(document.bounds)
            let s = document.units.convert(1, to: .inch) * 72
            frame = NSRect(x: 0, y: 0, width: b.width * s, height: b.height * s)
        } else {
            frame = NSRect(origin: .zero, size: pageSize)
        }
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        DesignSnapshot.draw(document: document, toolpaths: toolpaths, in: ctx, size: bounds.size,
                            margin: actualSize ? 0 : 16)
    }
}

extension LoftLineDocument {
    /// Document as shown: current sheet/side only.
    var shownDocument: Document {
        var d = outputProject.document
        d.shapes = d.shapes.filter { isOnActiveSide($0) }
        return d
    }

    func printDesign(actualSize: Bool) {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = actualSize ? .automatic : .fit
        info.verticalPagination = actualSize ? .automatic : .fit
        let d = shownDocument
        if !actualSize { info.orientation = d.job.width >= d.job.height ? .landscape : .portrait }
        let page = info.imageablePageBounds.size
        let view = DesignPrintView(document: d, toolpaths: showToolpaths ? calculatedToolpaths : [],
                                   actualSize: actualSize, pageSize: page)
        let op = NSPrintOperation(view: view, printInfo: info)
        op.jobTitle = document.name
        op.showsPrintPanel = true
        op.run()
    }
}
