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
        #expect(items.map(\.name) == ["Clamp"])   // one shape on the "Clamps" layer is one clamp
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
        d.keepOutZones = [KeepOutZone(name: "Clamp", outline: [Vec2(4, 4), Vec2(6, 4), Vec2(6, 6)], height: 0)]
        #expect(ClampList.items(in: d).map(\.name) == ["Clamp 1", "Screw", "Clamp 2", "Clamp 3"])
    }

    /// Review finding: a number handed out must not be a name a zone already has, or two clamps share a label.
    @Test func aGeneratedNumberSkipsANameAlreadyInUse() {
        var (d, clamps) = doc()
        d.add(box(2, 2, 1, 1, layer: clamps))
        d.add(box(8, 2, 1, 1, layer: clamps))
        d.keepOutZones = [KeepOutZone(name: "Clamp 1", outline: [Vec2(4, 4), Vec2(6, 4), Vec2(6, 6)], height: 0)]
        let names = ClampList.items(in: d).map(\.name)
        #expect(names == ["Clamp 2", "Clamp 3", "Clamp 1"])
        #expect(Set(names).count == names.count)
    }

    /// Two shapes named "Clamp 1" by hand: the number goes in brackets so it doesn't read as "Clamp 1 1".
    @Test func aSharedNameEndingInANumberIsNumberedInBrackets() {
        var (d, clamps) = doc()
        d.add(box(2, 2, 1, 1, layer: clamps, name: "Clamp 1"))
        d.add(box(8, 2, 1, 1, layer: clamps, name: "Clamp 1"))
        #expect(ClampList.items(in: d).map(\.name) == ["Clamp 1 (1)", "Clamp 1 (2)"])
    }

    /// The name goes inside the zone: an L-shaped clamp's bounding-box centre is off it.
    @Test func theLabelPointIsInsideTheZone() throws {
        var (d, clamps) = doc()
        let l = [Vec2(0, 0), Vec2(4, 0), Vec2(4, 1), Vec2(1, 1), Vec2(1, 4), Vec2(0, 4)]
        d.keepOutZones = [KeepOutZone(name: "Angle", outline: l, height: 0)]
        d.add(box(10, 10, 2, 1, layer: clamps))
        let items = ClampList.items(in: d)
        let angle = try #require(items.first { $0.name == "Angle" })
        #expect(!PathGeometry.contains(l, angle.bounds.center))
        #expect(PathGeometry.contains(l, angle.labelPoint))
        let block = try #require(items.first { $0.name == "Clamp" })
        #expect(block.labelPoint.distance(to: Vec2(11, 10.5)) < 1e-6)
    }

    /// `ClampItem` is public: one built with no loops gets a finite label point, not NaN from an empty box's centre.
    @Test func anItemWithNoLoopsHasAFiniteLabelPoint() {
        let item = ClampItem(name: "Empty", loops: [], height: 0, layerID: nil)
        #expect(item.labelPoint.x.isFinite && item.labelPoint.y.isFinite)
    }

    /// A layer names a set; one unnamed shape on it is one of them. A name the user gave a shape or a zone is left alone.
    @Test func aNameTakenFromTheLayerIsSingular() {
        var d = Document()
        for name in ["Clamps", "Screws", "Fixture Holes", "Vises", "Boxes", "Supplies", "Glass", "Hold-down"] {
            let layer = Layer(name: name, keepOut: LayerKeepOut(height: 0))
            d.layers.append(layer)
            d.add(box(2, 2, 1, 1, layer: layer.id))
        }
        let clamps = d.layers.first { $0.name == "Clamps" }!.id
        d.add(box(8, 2, 1, 1, layer: clamps, name: "Corner clamps"))
        d.keepOutZones = [KeepOutZone(name: "Stops", outline: [Vec2(4, 4), Vec2(6, 4), Vec2(6, 6)], height: 0)]
        #expect(ClampList.items(in: d).map(\.name)
            == ["Clamp", "Corner clamps", "Screw", "Fixture Hole", "Vise", "Box", "Supply", "Glass", "Hold-down", "Stops"])
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
