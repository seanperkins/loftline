import AppKit
import CADCore
import CAMCore
import SwiftUI
import LoftLineKit

extension LoftLineDocument {
    /// Inserts clipart: vectors/projects centred on the material and selected; 3D models go
    /// through the Place 3D Model dialog (queued, shown when the browser closes).
    /// Returns an error message, or nil.
    func insertClipart(_ item: ClipartLibrary.Item) -> String? {
        do {
            if item.kind == .model {
                let data = try Data(contentsOf: item.url)
                pendingPlacements.append(try ImportService.placementForm(
                    data: data, fileName: item.url.lastPathComponent, project: project, library: mergedLibrary))
                showDesignCanvas()
                return nil
            }
            var p = project
            let ids = try ClipartLibrary.insert(item, into: &p)
            let inserted = p
            perform("Insert \(item.name)") { $0 = inserted }
            setSelection(ids)
            sidebarTab = .design
            showDesignCanvas()
            return nil
        } catch {
            return ImportService.describe(error)
        }
    }
}

/// Lists clipart files and draws their thumbnails off the main thread.
final class ClipartBrowserModel: ObservableObject {
    @Published var folders: [URL] = []
    @Published var folder: URL?
    @Published var items: [ClipartLibrary.Item] = []
    @Published var thumbnails: [URL: NSImage] = [:]
    private var requested: Set<URL> = []
    private var failed: Set<URL> = []
    var library = ClipartLibrary()

    func reload() {
        folders = library.folders
        try? FileManager.default.createDirectory(at: ClipartLibrary.defaultFolder, withIntermediateDirectories: true)
        if folder == nil || !folders.contains(where: { $0 == folder }) { folder = folders.first }
        guard let f = folder else { items = []; return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = ClipartLibrary.scan(f)
            DispatchQueue.main.async {
                guard let self, self.folder == f else { return }
                self.items = found
            }
        }
    }

    func hasFailed(_ url: URL) -> Bool { failed.contains(url) }

    func requestThumbnail(_ item: ClipartLibrary.Item) {
        guard !requested.contains(item.url) else { return }
        requested.insert(item.url)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let cg = ClipartLibrary.thumbnail(of: item)
            DispatchQueue.main.async {
                guard let self else { return }
                if let cg { self.thumbnails[item.url] = NSImage(cgImage: cg, size: NSSize(width: 96, height: 96)) }
                else { self.failed.insert(item.url) }
            }
        }
    }
}

/// File > Clipart…: the user's own clipart folders, searchable, with thumbnails.
struct ClipartBrowserSheet: View {
    @ObservedObject var document: LoftLineDocument
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ClipartBrowserModel()
    @State private var query = ""
    @State private var selected: ClipartLibrary.Item?
    @State private var error: String?

    private var shown: [ClipartLibrary.Item] { ClipartLibrary.filter(model.items, query: query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Clipart").font(.title2.bold())
                Spacer()
                TextField("Search", text: $query).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            HStack(alignment: .top, spacing: 12) {
                folderList.frame(width: 190)
                grid
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Color.warningText) }
            HStack {
                Text("Vectors (SVG, DXF, EPS, AI, PDF), 3D models (STL, OBJ, DAE) and LoftLine projects. Double-click to insert.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Insert") { if let s = selected { insert(s) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil)
            }
        }
        .padding(20)
        .frame(width: 760, height: 520)
        .onAppear { model.reload() }
        .onChange(of: model.folder) { _, _ in selected = nil; model.reload() }
    }

    private var folderList: some View {
        VStack(alignment: .leading, spacing: 6) {
            List(model.folders, id: \.self, selection: $model.folder) { f in
                Label(f == ClipartLibrary.defaultFolder ? "LoftLine Clipart" : f.lastPathComponent, systemImage: "folder")
                    .help(f.path)
                    .tag(f)
            }
            .listStyle(.bordered)
            HStack {
                Button { addFolder() } label: { Image(systemName: "plus") }
                    .help("Add a clipart folder")
                Button {
                    if let f = model.folder { model.library.removeFolder(f); model.folder = nil; model.reload() }
                } label: { Image(systemName: "minus") }
                    .help("Remove the folder from the list (files are not deleted)")
                    .disabled(model.folder == nil || model.folder == ClipartLibrary.defaultFolder)
                Spacer()
                Button { if let f = model.folder { NSWorkspace.shared.open(f) } } label: { Image(systemName: "arrow.up.forward.app") }
                    .help("Show the folder in Finder")
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Rescan")
            }
            .buttonStyle(.borderless)
        }
    }

    private var grid: some View {
        Group {
            if shown.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text(model.items.isEmpty ? "No clipart in this folder." : "Nothing matches \"\(query)\".")
                        .foregroundStyle(.secondary)
                    if model.items.isEmpty {
                        Text("Copy your own SVG/DXF/STL files or LoftLine projects into it, or add another folder with +.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                        ForEach(shown) { item in cell(item) }
                    }
                    .padding(4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .border(Color.secondary.opacity(0.3))
    }

    private func cell(_ item: ClipartLibrary.Item) -> some View {
        VStack(spacing: 4) {
            ZStack {
                if let img = model.thumbnails[item.url] {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                } else if model.hasFailed(item.url) {
                    Image(systemName: item.kind == .model ? "cube" : "questionmark.square.dashed")
                        .font(.largeTitle).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 96, height: 96)
            .background(Color.white)
            Text(item.name).font(.caption).lineLimit(1).truncationMode(.middle)
            if !item.category.isEmpty {
                Text(item.category).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected == item ? Color.accentColor.opacity(0.25) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { insert(item) }
        .onTapGesture { selected = item }
        .onAppear { model.requestThumbnail(item) }
        .help(item.url.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.name)
        .accessibilityAddTraits(.isButton)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder of clipart (vectors, 3D models or LoftLine projects)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.library.addFolder(url)
        model.folder = url
        model.reload()
    }

    private func insert(_ item: ClipartLibrary.Item) {
        if let msg = document.insertClipart(item) {
            error = "\(item.name): \(msg)"
        } else {
            dismiss()
        }
    }
}
