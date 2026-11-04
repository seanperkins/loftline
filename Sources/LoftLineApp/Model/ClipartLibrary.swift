import AppKit
import CADCore
import CAMCore
import Foundation
import LoftLineKit

/// The user's own clipart (io-clipart-library): folders of vector files (SVG, DXF, EPS, AI,
/// PDF), 3D models (STL, OBJ, DAE) and LoftLine projects, browsed from File > Clipart… LoftLine ships
/// no clipart of its own.
struct ClipartLibrary {
    static let foldersKey = "loftline.clipartFolders"

    enum Kind: String { case vector, model, project }

    struct Item: Identifiable, Hashable {
        var url: URL
        var name: String
        /// Sub-folder path below the library folder ("" = top level).
        var category: String
        var kind: Kind
        var id: URL { url }
    }

    static let vectorExtensions = ImportService.vectorExtensions
    static let modelExtensions = ImportService.meshExtensions
    static let projectExtensions = [LoftLineProject.fileExtension]

    static func kind(of url: URL) -> Kind? {
        let ext = url.pathExtension.lowercased()
        if vectorExtensions.contains(ext) { return .vector }
        if modelExtensions.contains(ext) { return .model }
        if projectExtensions.contains(ext) { return .project }
        return nil
    }

    var defaults: UserDefaults = .standard

    /// ~/Library/Application Support/LoftLine/Clipart (always listed first).
    static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LoftLine/Clipart", isDirectory: true)
    }

    /// Library folders: the default one, then folders the user added.
    var folders: [URL] {
        let extra = (defaults.stringArray(forKey: Self.foldersKey) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
        return [Self.defaultFolder] + extra.filter { $0.standardizedFileURL.path != Self.defaultFolder.standardizedFileURL.path }
    }

    func addFolder(_ url: URL) {
        var list = defaults.stringArray(forKey: Self.foldersKey) ?? []
        guard !folders.contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path }) else { return }
        list.append(url.path)
        defaults.set(list, forKey: Self.foldersKey)
    }

    func removeFolder(_ url: URL) {
        let list = (defaults.stringArray(forKey: Self.foldersKey) ?? []).filter {
            URL(fileURLWithPath: $0).standardizedFileURL.path != url.standardizedFileURL.path
        }
        defaults.set(list, forKey: Self.foldersKey)
    }

    /// Clipart files under `folder` (sub-folders up to `maxDepth` deep become categories),
    /// sorted by category then name. Hidden files and packages are skipped.
    static func scan(_ folder: URL, maxDepth: Int = 4, limit: Int = 5000) -> [Item] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let base = folder.standardizedFileURL.pathComponents
        var items: [Item] = []
        for case let url as URL in e {
            let comps = url.standardizedFileURL.pathComponents
            let depth = comps.count - base.count
            if depth > maxDepth { e.skipDescendants(); continue }
            guard let kind = kind(of: url),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let category = comps.dropFirst(base.count).dropLast().joined(separator: "/")
            items.append(Item(url: url, name: url.deletingPathExtension().lastPathComponent, category: category, kind: kind))
            if items.count >= limit { break }
        }
        return items.sorted {
            ($0.category.localizedLowercase, $0.name.localizedLowercase) < ($1.category.localizedLowercase, $1.name.localizedLowercase)
        }
    }

    /// Items whose name or category contains every word of `query` (case-insensitive).
    static func filter(_ items: [Item], query: String) -> [Item] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return items }
        return items.filter { i in
            let hay = (i.name + " " + i.category).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    // MARK: Reading clipart

    /// Shapes of a vector or project clipart file, in its own coordinates (units converted).
    static func shapes(of item: Item, units: LengthUnit) throws -> (shapes: [Shape], layers: [Layer]) {
        let data = try Data(contentsOf: item.url)
        switch item.kind {
        case .vector:
            guard let imp = FileFormats.importer(forExtension: item.url.pathExtension.lowercased()) else {
                throw LoftLineIOError.unsupportedFormat(item.url.pathExtension)
            }
            let r = try imp.importVectors(from: data, targetUnits: units)
            return (r.shapes, r.layers)
        case .project:
            let p = try LoftLineProject.decode(from: data).converted(to: units)
            let hidden = Set(p.document.layers.filter { !$0.isVisible }.map(\.id))
            return (p.document.shapes.filter { !hidden.contains($0.layerID) }, p.document.layers)
        case .model:
            return ([], [])
        }
    }

    /// Adds vector/project clipart to the project, centred on the material and grouped (when it
    /// has several shapes). Shapes go on layers of the same name (created if missing), or on
    /// the first layer. Returns the new shape ids.
    static func insert(_ item: Item, into project: inout LoftLineProject) throws -> [UUID] {
        let units = project.document.units
        let (shapes, layers) = try shapes(of: item, units: units)
        guard !shapes.isEmpty else { throw LoftLineIOError.malformed("the clipart contains no vectors") }
        let layerNames = Dictionary(layers.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let bounds = shapes.reduce(Rect2.empty) { $0.union($1.bounds()) }
        let shift = Transform2D.translation(project.document.job.materialBounds.center - bounds.center)
        let group = shapes.count > 1 ? UUID() : nil
        var groupMap: [UUID: UUID] = [:]
        var fallback: UUID?
        var ids: [UUID] = []
        for s in shapes {
            var n = s.transformed(shift)
            n.id = UUID()
            if let name = layerNames[s.layerID], let existing = project.document.layers.first(where: { $0.name == name }) {
                n.layerID = existing.id
            } else if let name = layerNames[s.layerID], item.kind == .project {
                n.layerID = project.addLayer(named: name)
            } else {
                if fallback == nil { fallback = project.document.layers.first?.id ?? project.addLayer(named: item.name) }
                n.layerID = fallback!
            }
            n.isLocked = false
            // Keep the clipart's own groups nested inside the new one.
            let inner = ([s.groupID].compactMap { $0 } + (s.innerGroupIDs ?? [])).map { old -> UUID in
                if let m = groupMap[old] { return m }
                let m = UUID()
                groupMap[old] = m
                return m
            }
            if let group {
                n.groupID = group
                n.innerGroupIDs = inner.isEmpty ? nil : inner
            } else {
                n.groupID = inner.first
                n.innerGroupIDs = inner.count > 1 ? Array(inner.dropFirst()) : nil
            }
            if n.name.isEmpty { n.name = item.name }
            project.document.add(n)
            ids.append(n.id)
        }
        return ids
    }

    // MARK: Thumbnails

    /// Small picture of the clipart: vectors (filled light, outlined dark) or a 3D model's
    /// outline from above. Nil when the file cannot be read.
    static func thumbnail(of item: Item, size: CGFloat = 96) -> CGImage? {
        var paths: [Path] = []
        do {
            switch item.kind {
            case .vector, .project:
                paths = try shapes(of: item, units: .millimeter).shapes.flatMap(\.paths)
            case .model:
                let data = try Data(contentsOf: item.url)
                let mesh = try ImportService.meshImporter(for: item.url.lastPathComponent).importMesh(from: data, targetUnits: .millimeter)
                guard mesh.triangleCount <= 50_000,
                      let o = MeshParts.outline(of: MeshPart(name: item.name, mesh: mesh), view: .top) else { return nil }
                paths = o.paths
            }
        } catch {
            return nil
        }
        guard !paths.isEmpty else { return nil }
        let px = Int(size * 2)
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(px))
        ctx.scaleBy(x: 1, y: -1)
        let bounds = paths.reduce(Rect2.empty) { $0.union($1.bounds()) }
        var t = ToolpathOverlayRenderer.fitTransform(bounds: bounds, in: CGSize(width: px, height: px), margin: CGFloat(px) * 0.08)
        let shape = Shape(layerID: UUID(), paths: paths)
        guard let cg = CanvasPaths.cgPath(for: shape).copy(using: &t) else { return nil }
        let closed = paths.filter(\.isClosed)
        if !closed.isEmpty, let fill = CanvasPaths.cgPath(for: Shape(layerID: UUID(), paths: closed)).copy(using: &t) {
            ctx.addPath(fill)
            ctx.setFillColor(CGColor(red: 0.80, green: 0.86, blue: 0.95, alpha: 1))
            ctx.fillPath(using: .evenOdd)
        }
        ctx.addPath(cg)
        ctx.setStrokeColor(CGColor(gray: 0.15, alpha: 1))
        ctx.setLineWidth(max(1, CGFloat(px) / 160))
        ctx.strokePath()
        return ctx.makeImage()
    }
}
