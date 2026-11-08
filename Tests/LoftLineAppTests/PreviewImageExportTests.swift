import AppKit
import CADCore
import CAMCore
import Foundation
import Metal
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct PreviewImageExportTests {
    @Test func fileName() {
        #expect(PreviewImageExport.suggestedFileName(documentName: "Sign") == "Sign preview.png")
        #expect(PreviewImageExport.suggestedFileName(documentName: " ") == "Untitled preview.png")
        #expect(PreviewImageExport.suggestedFileName(documentName: "a/b:c") == "a-b-c preview.png")
    }

    /// Renders a carved, painted stock offscreen. Set LOFTLINE_RENDER_DIR to keep the PNG.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
    @MainActor func rendersStockToPNG() throws {
        let job = JobSetup(width: 12, height: 8, thickness: 0.75)
        var hf = Heightfield(width: job.width, height: job.height, cellSize: 0.05)
        for i in 0..<hf.columns { for j in 0..<hf.rows {
            let p = hf.cellCenter(i, j)
            if p.distance(to: Vec2(6, 4)) < 2.5 { hf[i, j] = 0.25 }
            if abs(p.x - 2) < 0.1, p.y > 1, p.y < 7 { hf[i, j] = 0.1 }
        } }
        var look = StockAppearance.preset(.oak)
        look.paint = StockColor(0.1, 0.2, 0.45)
        let scene = StockScene()
        scene.configure(job: job)
        scene.updateStock(HeightfieldMesh(heightfield: hf, thickness: job.thickness, appearance: look))
        scene.showMeasurement([Vec3(6, 4, -0.25), Vec3(9, 4, 0)])
        let image = try #require(PreviewImageExport.render(scene, size: CGSize(width: 480, height: 320)))
        let data = try #require(PreviewImageExport.pngData(image))
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let rep = try #require(NSBitmapImageRep(data: data))
        #expect(rep.pixelsWide == 480)
        // Not a blank frame: the stock differs from the background somewhere in the middle.
        let bg = rep.colorAt(x: 2, y: 2)
        let mid = rep.colorAt(x: 240, y: 160)
        #expect(bg != nil && mid != nil && bg != mid)
        if let dir = ProcessInfo.processInfo.environment["LOFTLINE_RENDER_DIR"] {
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("preview-stock.png"))
        }
    }
}
