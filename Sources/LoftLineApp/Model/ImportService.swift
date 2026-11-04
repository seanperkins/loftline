import CADCore
import CAMCore
import Foundation
import UniformTypeIdentifiers

struct ImportOutcome: Equatable {
    var shapeIDs: [UUID] = []
    var modelIDs: [UUID] = []
    var imageIDs: [UUID] = []
    var warnings: [String] = []
}

/// An SVG that does not fix its own size, held until the user confirms the scale it was drawn at.
struct SVGScaleRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    var fileName: String
    var data: Data
    var guess: SVGImporter.ScaleGuess
    var units: LengthUnit

    /// The scales programs draw in: Illustrator, Inkscape 0.91 and older, the web.
    static let choices: [Double] = [72, 90, 96]

    /// The width and height of everything the file imports (vectors and embedded images) in `units` at every
    /// choice; a choice it cannot be measured at (nothing to import, or a file that cannot be read) is missing.
    /// Physical lengths inside the drawing keep their size, so the sizes are not simply proportional to the scale.
    func drawingSizes() -> [Double: Vec2] {
        var sizes: [Double: Vec2] = [:]
        for choice in Self.choices {
            guard let result = try? SVGImporter(pixelsPerInch: choice).importVectors(from: data, targetUnits: units) else { continue }
            let boxes = result.shapes.map { $0.bounds() } + result.images.map(\.rect)
            guard let first = boxes.first else { continue }
            let all = boxes.dropFirst().reduce(first) { $0.union($1) }
            sizes[choice] = Vec2(all.width, all.height)
        }
        return sizes
    }
}

/// File > Import: vectors (SVG/DXF/EPS) become shapes on their own layers; STL becomes a
/// placed 3D model centred on the material.
enum ImportService {
    static let vectorExtensions = ["svg", "dxf", "eps", "ai", "pdf"]
    static let meshExtensions = ["stl", "obj", "dae"]
    static var imageExtensions: [String] { RasterCodec.fileExtensions }
    /// Accepted by the open panel only so a clear "export as DAE/STL" message can be shown.
    static let explainedExtensions = ["skp"]
    static var allExtensions: [String] { vectorExtensions + meshExtensions + imageExtensions + explainedExtensions }

    static var allowedContentTypes: [UTType] {
        allExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    /// STL or OBJ reader by file extension (both assume millimetres).
    static func meshImporter(for fileName: String) -> any MeshImporter {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "obj": return OBJImporter()
        case "dae": return DAEImporter()
        default: return STLImporter()
        }
    }

    static func isMesh(_ fileName: String) -> Bool {
        meshExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    /// Reads an STL into a placement form (the app shows it as the "Place 3D Model" dialog).
    static func placementForm(data: Data, fileName: String, project: LoftLineProject,
                              library: ToolLibrary) throws -> ModelPlacementForm {
        let mesh = try meshImporter(for: fileName).importMesh(from: data, targetUnits: project.document.units)
        guard mesh.triangleCount > 0 else { throw LoftLineIOError.malformed("the model contains no triangles") }
        return ModelPlacementForm(mesh: mesh, name: (fileName as NSString).deletingPathExtension,
                                  job: project.document.job, library: library)
    }

    /// The question to ask before importing an SVG whose scale the file does not state; nil for any other
    /// file, and for an SVG with a physical page size and a viewBox.
    static func scaleRequest(data: Data, fileName: String, units: LengthUnit) -> SVGScaleRequest? {
        guard (fileName as NSString).pathExtension.lowercased() == "svg",
              let guess = try? SVGImporter.scaleGuess(of: data) else { return nil }
        return SVGScaleRequest(fileName: fileName, data: data, guess: guess, units: units)
    }

    /// `svgPixelsPerInch` is the scale the user chose for an SVG with no physical size (nil = guess it).
    static func importFile(data: Data, fileName: String, into project: inout LoftLineProject,
                           svgPixelsPerInch: Double? = nil) throws -> ImportOutcome {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let base = (fileName as NSString).deletingPathExtension
        let units = project.document.units
        if meshExtensions.contains(ext) {
            let mesh = try meshImporter(for: fileName).importMesh(from: data, targetUnits: units)
            let model = place(mesh: mesh, name: base, job: project.document.job)
            project.document.models.append(model)
            return ImportOutcome(modelIDs: [model.id])
        }
        if imageExtensions.contains(ext) {
            return try importBitmap(data: data, name: base, into: &project)
        }
        guard let importer = ext == "svg" ? SVGImporter(pixelsPerInch: svgPixelsPerInch) : FileFormats.importer(forExtension: ext) else {
            throw LoftLineIOError.unsupportedFormat(ext)
        }
        let result = try importer.importVectors(from: data, targetUnits: units)
        var outcome = ImportOutcome(warnings: result.warnings)
        for (i, e) in result.images.enumerated() {
            guard let info = RasterCodec.info(of: e.png) else { continue }
            let img = PlacedImage(name: "\(base) image \(i + 1)", layerID: bitmapLayer(in: &project), png: e.png,
                                  pixelWidth: info.pixels.width, pixelHeight: info.pixels.height, rect: e.rect)
            project.document.placedImages.append(img)
            outcome.imageIDs.append(img.id)
        }
        // Keep importer layers; fall back to a layer named after the file.
        var layerMap: [UUID: UUID] = [:]
        // Layers of the current sheet only: a same-named layer of another sheet would put the vectors out of sight.
        for l in result.layers {
            if let existing = project.layerOnCurrentSheet(named: l.name) {
                layerMap[l.id] = existing
            } else {
                var added = l
                added.sheetID = project.document.currentSheetID == MaterialSheet.primaryID ? nil : project.document.currentSheetID
                project.document.layers.append(added)
                layerMap[l.id] = added.id
            }
        }
        var fallback: UUID?
        for var s in result.shapes {
            if let mapped = layerMap[s.layerID] {
                s.layerID = mapped
            } else {
                if fallback == nil { fallback = project.addLayer(named: base) }
                s.layerID = fallback!
            }
            if s.name.isEmpty { s.name = base }
            project.document.add(s)
            outcome.shapeIDs.append(s.id)
        }
        if outcome.shapeIDs.isEmpty && outcome.imageIDs.isEmpty {
            outcome.warnings.append("The file contained no supported vectors.")
        }
        return outcome
    }

    static let bitmapLayerName = "Bitmaps"

    /// The layer tracing images go on (created on first use).
    static func bitmapLayer(in project: inout LoftLineProject) -> UUID {
        project.layerOnCurrentSheet(named: bitmapLayerName) ?? project.addLayer(named: bitmapLayerName)
    }

    /// JPG/PNG/BMP/TIF/GIF/WebP → a faded tracing image centred on the material.
    static func importBitmap(data: Data, name: String, into project: inout LoftLineProject) throws -> ImportOutcome {
        guard let info = RasterCodec.info(of: data), let png = RasterCodec.png(fromEncoded: data) else {
            throw LoftLineIOError.malformed("the image could not be decoded")
        }
        let rect = PlacedImage.defaultRect(pixels: info.pixels, physicalInches: info.inches, job: project.document.job,
                                           units: project.document.units)
        let img = PlacedImage(name: name.isEmpty ? "Image" : name, layerID: bitmapLayer(in: &project), png: png,
                              pixelWidth: info.pixels.width, pixelHeight: info.pixels.height, rect: rect)
        project.document.placedImages.append(img)
        return ImportOutcome(imageIDs: [img.id])
    }

    /// Centres the mesh on the material, model top flush with the material top, and depth equal
    /// to the mesh's Z extent (clamped to the material thickness).
    static func place(mesh: Mesh3D, name: String, job: JobSetup) -> PlacedModel {
        guard let b = mesh.bounds else { return PlacedModel(name: name, mesh: mesh) }
        let size = Vec2(b.max.x - b.min.x, b.max.y - b.min.y)
        let center = Vec2(b.min.x, b.min.y) + size * 0.5
        let offset = job.materialBounds.center - center
        let depth = min(max(b.max.z - b.min.z, 0), job.thickness)
        return PlacedModel(name: name.isEmpty ? "Model" : name, mesh: mesh, offset: offset, scale: 1,
                           depth: depth > 0 ? depth : job.thickness / 2, zTop: 0)
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case LoftLineIOError.notImplemented(let what): return "\(what) is not available in this build yet."
        case LoftLineIOError.unsupportedFormat("skp"):
            return "SketchUp files cannot be read directly. In SketchUp use File > Export > 3D Model and choose COLLADA (.dae) or STL, then import that file: File > Import… places it as a 3D model; File > Import 3D Model as 2D Parts… turns each group or component into a flat outline to cut."
        case LoftLineIOError.unsupportedFormat(let ext): return "LoftLine cannot import .\(ext) files."
        case LoftLineIOError.malformed(let msg): return "The file could not be read: \(msg)"
        default: return error.localizedDescription
        }
    }
}
