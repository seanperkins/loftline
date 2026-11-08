import CADCore
import Foundation
import Testing
@testable import LoftLineKit

/// The canvas redraws on every mouse move; the clamp list is rebuilt only when a keep-out changes.
@Suite struct ClampListCacheTests {
    @Test func theListIsRebuiltOnlyWhenAKeepOutChanges() throws {
        var d = Document()
        let part = AppTestSupport.rect(4, 4, 2, 2, layer: d.defaultLayerID)
        d.add(part)
        let clamps = Layer(name: "Clamps", keepOut: LayerKeepOut(height: 1))
        d.layers.append(clamps)
        let clamp = AppTestSupport.rect(-1, 2, 2, 1, layer: clamps.id)
        d.add(clamp)
        var cache = ClampListCache()

        #expect(cache.items(in: d).map(\.name) == ["R"])
        #expect(cache.items(in: d).map(\.name) == ["R"])
        #expect(cache.builds == 1)

        // Moving a part is not a keep-out change.
        d.shapes[0] = part.transformed(.translation(Vec2(1, 0)))
        _ = cache.items(in: d)
        #expect(cache.builds == 1)

        // Moving the clamp, hiding its layer, and adding a Keep-Out Zone each are.
        d.shapes[1] = clamp.transformed(.translation(Vec2(0, 1)))
        #expect(try #require(cache.items(in: d).first).bounds.min.y == 3)
        #expect(cache.builds == 2)
        let i = try #require(d.layers.firstIndex { $0.id == clamps.id })
        d.layers[i].isVisible = false
        _ = cache.items(in: d)
        #expect(cache.builds == 3)
        d.keepOutZones = [KeepOutZone(name: "Vise", outline: [Vec2(8, 8), Vec2(9, 8), Vec2(9, 9)], height: 0)]
        #expect(cache.items(in: d).map(\.name) == ["R", "Vise"])
        #expect(cache.builds == 4)
    }
}
