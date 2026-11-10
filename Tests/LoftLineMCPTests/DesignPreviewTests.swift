import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineKit
@testable import LoftLineMCP

@Suite struct DesignPreviewTests {
    /// A 24 x 18 project with one clamp over the left edge.
    static func project() -> LoftLineProject {
        var p = LoftLineProject(document: Document())
        p.document.job.width = 24
        p.document.job.height = 18
        let clamps = Layer(name: "Clamps", keepOut: LayerKeepOut(height: 1))
        p.document.layers.append(clamps)
        p.document.add(Shape(layerID: clamps.id, paths: [ShapeFactory.rectangle(Rect2(x: -1, y: 8, width: 4, height: 2))]))
        return p
    }

    @Test func thePictureDecodesAtTheAskedSize() throws {
        let png = try DesignPreview.png(project: Self.project(), toolpaths: [], width: 800, height: 600)
        let info = try #require(RasterCodec.info(of: png))
        #expect(info.pixels.width == 800 && info.pixels.height == 600)
    }

    @Test func materialAndAClampAreWhereTheyShouldBe() throws {
        let p = Self.project()
        let picture = try DesignPreview.render(project: p, toolpaths: [], width: 800, height: 600)
        #expect(picture.color(atMaterial: Vec2(12, 4)) == DesignPreview.materialColor)
        let inClamp = picture.color(atMaterial: Vec2(1, 9))
        #expect(inClamp == DesignPreview.clampFill || inClamp == DesignPreview.clampLine, "\(inClamp)")
        #expect(picture.color(atMaterial: Vec2(30, 4)) == DesignPreview.background)
    }

    @Test func anOverLargePictureIsRefusedBeforeAllocating() {
        #expect(throws: (any Error).self) { try DesignPreview.png(project: Self.project(), toolpaths: [], width: 5_000, height: 10) }
        #expect(throws: (any Error).self) { try DesignPreview.png(project: Self.project(), toolpaths: [], width: 3_000, height: 3_000) }
        #expect(throws: (any Error).self) { try DesignPreview.png(project: Self.project(), toolpaths: [], width: 0, height: 10) }
    }

    @Test func thePreviewToolAnswersWithAnImage() throws {
        let h = MCPHarness()
        try h.call("open_project", ["path": try h.sample().path])
        let out = try h.call("preview", ["width": 640, "height": 320])
        let png = try #require(out.image)
        #expect(RasterCodec.info(of: png)?.pixels.width == 640)
        #expect(out.text.contains("640x320"))
    }
}
