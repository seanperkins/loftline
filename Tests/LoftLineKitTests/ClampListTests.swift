import CADCore
import Foundation
import Testing
@testable import LoftLineKit

/// Every clamp and keep-out the export checks, named and placed for the operator (issue #134).
@Suite struct ClampListTests {
    /// A 24 x 18 document with a keep-out layer called "Clamps".
    func doc(units: LengthUnit = .inch, hidden: Bool = false, height: Double = 1.5) -> (Document, UUID) {
        var d = Document(units: units)
        d.job.width = 24
        d.job.height = 18
        let layer = Layer(name: "Clamps", isVisible: !hidden, keepOut: LayerKeepOut(height: height))
        d.layers.append(layer)
        return (d, layer.id)
    }

    func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double, layer: UUID, name: String = "") -> Shape {
        Shape(name: name, layerID: layer, paths: [ShapeFactory.rectangle(Rect2(x: x, y: y, width: w, height: h))])
    }

    @Test func aHiddenKeepOutLayerIsListed() {
        var (d, clamps) = doc(hidden: true)
        d.add(box(2, 2, 1, 1, layer: clamps))
        let items = ClampList.items(in: d)
        #expect(items.map(\.name) == ["Clamps"])
        #expect(items[0].layerID == clamps)
        #expect(items[0].height == 1.5)
    }

    @Test func keepOutZonesAreListedAndOutlinesTooShortAreSkipped() {
        var (d, _) = doc()
        d.keepOutZones = [
            KeepOutZone(name: "Vise", outline: [Vec2(4, 4), Vec2(6, 4), Vec2(6, 6), Vec2(4, 6)], height: 2),
            KeepOutZone(name: "Line", outline: [Vec2(0, 0), Vec2(1, 1)], height: 0),
        ]
        let items = ClampList.items(in: d)
        #expect(items.map(\.name) == ["Vise"])
        #expect(items[0].layerID == nil)
        #expect(items[0].bounds == Rect2(min: Vec2(4, 4), max: Vec2(6, 6)))
    }

    @Test func sharedNamesAreNumberedAcrossBothSourcesAndUniqueNamesAreNot() {
        var (d, clamps) = doc()
        d.add(box(2, 2, 1, 1, layer: clamps))
        d.add(box(8, 2, 1, 1, layer: clamps, name: "Screw"))
        d.add(box(14, 2, 1, 1, layer: clamps))
        d.keepOutZones = [KeepOutZone(name: "Clamps", outline: [Vec2(4, 4), Vec2(6, 4), Vec2(6, 6)], height: 0)]
        #expect(ClampList.items(in: d).map(\.name) == ["Clamps 1", "Screw", "Clamps 2", "Clamps 3"])
    }

    /// Review finding: a number handed out must not be a name a zone already has, or two clamps share a label.
    @Test func aGeneratedNumberSkipsANameAlreadyInUse() {
        var (d, clamps) = doc()
        d.add(box(2, 2, 1, 1, layer: clamps))
        d.add(box(8, 2, 1, 1, layer: clamps))
        d.keepOutZones = [KeepOutZone(name: "Clamps 1", outline: [Vec2(4, 4), Vec2(6, 4), Vec2(6, 6)], height: 0)]
        let names = ClampList.items(in: d).map(\.name)
        #expect(names == ["Clamps 2", "Clamps 3", "Clamps 1"])
        #expect(Set(names).count == names.count)
    }

    /// Clamps and Fixture Holes names its shapes "Clamp 1"…; pressed twice it makes each name twice.
    @Test func aSharedNameEndingInANumberIsNumberedInBrackets() {
        var (d, clamps) = doc()
        d.add(box(2, 2, 1, 1, layer: clamps, name: "Clamp 1"))
        d.add(box(8, 2, 1, 1, layer: clamps, name: "Clamp 1"))
        #expect(ClampList.items(in: d).map(\.name) == ["Clamp 1 (1)", "Clamp 1 (2)"])
    }

    @Test func aClampAtTheLeftEdgeIsWordedFromThatEdge() throws {
        var (d, clamps) = doc()
        d.add(box(-2, 11, 3, 2, layer: clamps))   // 2 in outside, reaches 1 in on, centre 12 in up
        let item = try #require(ClampList.items(in: d).first)
        #expect(ClampList.position(of: item, job: d.job, units: d.units)
            == "left edge, centre 12 in from the bottom, reaches 1 in onto the material")
    }

    @Test func eachEdgeIsWordedFromItsOwnSide() {
        var (d, clamps) = doc()
        d.add(box(23, 4, 2, 2, layer: clamps))     // right: reaches 1, centre 5 up
        d.add(box(10, -1, 4, 1.5, layer: clamps))  // bottom: reaches 0.5, centre 12 across
        d.add(box(3, 17.25, 2, 1, layer: clamps))  // top: reaches 0.75, centre 4 across
        let words = ClampList.items(in: d).map { ClampList.position(of: $0, job: d.job, units: d.units) }
        #expect(words == [
            "right edge, centre 5 in from the bottom, reaches 1 in onto the material",
            "bottom edge, centre 12 in from the left, reaches 0.5 in onto the material",
            "top edge, centre 4 in from the left, reaches 0.75 in onto the material",
        ])
    }

    @Test func insideCornerAndFullWidthZonesAreWordedAsRangesFromTheLeftAndBottom() {
        var (d, clamps) = doc()
        d.add(box(2, 3, 1, 0.5, layer: clamps))     // inside
        d.add(box(-1, -1, 3, 3, layer: clamps))     // lower-left corner: two edges
        d.add(box(-1, 8, 26, 1, layer: clamps))     // across the whole width
        let words = ClampList.items(in: d).map { ClampList.position(of: $0, job: d.job, units: d.units) }
        #expect(words == [
            "2 in to 3 in from the left edge, 3 in to 3.5 in from the bottom edge",
            "-1 in to 2 in from the left edge, -1 in to 2 in from the bottom edge",
            "-1 in to 25 in from the left edge, 8 in to 9 in from the bottom edge",
        ])
    }

    @Test func aZoneOffTheMaterialSaysSo() throws {
        var (d, clamps) = doc()
        d.add(box(-4, 2, 2, 2, layer: clamps))
        let item = try #require(ClampList.items(in: d).first)
        #expect(ClampList.position(of: item, job: d.job, units: d.units)
            == "off the material, -4 in to -2 in from the left edge, 2 in to 4 in from the bottom edge")
    }

    @Test func aMillimetreDocumentIsWordedInMillimetres() throws {
        var (d, clamps) = doc(units: .millimeter, height: 30)
        d.job.width = 600
        d.job.height = 450
        d.add(box(-50, 275, 75, 50, layer: clamps))
        let item = try #require(ClampList.items(in: d).first)
        #expect(ClampList.position(of: item, job: d.job, units: d.units)
            == "left edge, centre 300 mm from the bottom, reaches 25 mm onto the material")
        #expect(ClampList.heightText(of: item, units: d.units) == "30 mm above the material")
    }

    @Test func aFlushZoneIsFlushWithTheTop() throws {
        var (d, clamps) = doc(height: 0)
        d.add(box(2, 2, 1, 1, layer: clamps))
        let item = try #require(ClampList.items(in: d).first)
        #expect(ClampList.heightText(of: item, units: d.units) == "flush with the top")
    }

    @Test func noKeepOutsMeansNoItems() {
        var d = Document()
        d.add(box(2, 2, 1, 1, layer: d.defaultLayerID))
        #expect(ClampList.items(in: d).isEmpty)
    }
}
