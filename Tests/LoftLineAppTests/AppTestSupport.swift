import AppKit
import CADCore
import CAMCore
import Foundation
@testable import LoftLineApp

enum AppTestSupport {
    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loftline-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func library() -> ToolLibraryModel {
        ToolLibraryModel(store: ToolLibraryStore(fileURL: tempDir().appendingPathComponent("tools.json")))
    }

    static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, layer: UUID) -> Shape {
        Shape(name: "R", layerID: layer, paths: [ShapeFactory.rectangle(Rect2(x: x, y: y, width: w, height: h))])
    }

    /// A project with two 2x1 rectangles at (1,1) and (5,1).
    static func project() -> LoftLineProject {
        var doc = Document()
        doc.add(rect(1, 1, 2, 1, layer: doc.defaultLayerID))
        doc.add(rect(5, 1, 2, 1, layer: doc.defaultLayerID))
        return LoftLineProject(document: doc)
    }

    /// Number of distinct colours in a coarse sample of a rendered PNG. A blank render (one
    /// background colour) scores 1, so smoke tests assert a minimum instead of a byte count,
    /// which a blank image passes just as well.
    static func distinctColours(in png: Data, step: Int = 23) -> Int {
        guard let rep = NSBitmapImageRep(data: png) else { return 0 }
        var colours = Set<String>()
        for x in stride(from: 2, to: rep.pixelsWide, by: step) {
            for y in stride(from: 2, to: rep.pixelsHigh, by: step + 4) {
                if let c = rep.colorAt(x: x, y: y) { colours.insert(c.description) }
            }
        }
        return colours.count
    }

    /// True when a rendered view is not a blank panel: at least `minimum` distinct sampled colours.
    static func looksDrawn(_ png: Data, minimum: Int = 4, step: Int = 23) -> Bool {
        distinctColours(in: png, step: step) >= minimum
    }

    /// The sampling step for a view that draws sparsely offscreen on a hosted runner (see `onHostedRunner`).
    static let finerStep = 7

    /// True on a GitHub Actions runner. Its macOS 15 draws an offscreen window without realising lazy content (the Help
    /// sidebar list and topic text), so a render that is rich on a development Mac is sparse there.
    static var onHostedRunner: Bool { ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" }

    /// Renders an AppKit view to PNG (nil when it has no backing store).
    static func png(of view: NSView) -> Data? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
