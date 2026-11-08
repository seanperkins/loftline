import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineKit

/// The job sheet shows and lists every clamp and screw the export checks (issue #134).
@Suite struct JobSheetClampTests {
    func project(units: LengthUnit = .inch, clampsVisible: Bool = true) -> (LoftLineProject, UUID) {
        var d = Document(units: units)
        d.job.width = 24
        d.job.height = 18
        d.add(AppTestSupport.rect(4, 4, 6, 4, layer: d.defaultLayerID))
        let clamps = Layer(name: "Clamps", isVisible: clampsVisible, keepOut: LayerKeepOut(height: 1.5))
        d.layers.append(clamps)
        d.add(Shape(layerID: clamps.id, paths: [ShapeFactory.rectangle(Rect2(x: -2, y: 11, width: 3, height: 2))]))
        return (LoftLineProject(document: d), clamps.id)
    }

    func sheet(_ p: LoftLineProject) -> JobSheet {
        JobSheet.make(project: p, results: [:], profile: BuiltInPosts.avidMach4Inch, groupByTool: false, rapidRate: 600,
                      sheets: JobSheet.sheets(of: p), settings: TimeEstimateSettings())
    }

    /// Each `<svg …>…</svg>` in the page.
    func svgs(_ html: String) -> [String] {
        html.components(separatedBy: "<svg").dropFirst().map { "<svg" + $0.components(separatedBy: "</svg>")[0] }
    }

    @Test func aHiddenClampLayerIsListedAndDrawn() {
        let (p, _) = project(clampsVisible: false)
        let js = sheet(p)
        #expect(js.clamps == [JobSheet.Clamp(name: "Clamps", position: "left edge, centre 12 in from the bottom, reaches 1 in onto the material",
                                             height: "1.5 in above the material")])
        let html = JobSheetHTML.render(js)
        #expect(html.contains("<h2>Clamps and screws</h2>"))
        #expect(html.contains("<td><input type=\"checkbox\"></td><td>Clamps</td><td>left edge, centre 12 in from the bottom, reaches 1 in onto the material</td><td>1.5 in above the material</td>"))
        #expect(svgs(html).count == 1)
        #expect(svgs(html)[0].contains(">Clamps</text>"))
    }

    @Test func keepOutZonesAreListedAndDrawn() {
        var (p, _) = project()
        p.document.keepOutZones = [KeepOutZone(name: "Vise <A>", outline: [Vec2(14, 2), Vec2(18, 2), Vec2(18, 5), Vec2(14, 5)], height: 0)]
        let js = sheet(p)
        #expect(js.clamps.map(\.name) == ["Clamps", "Vise <A>"])
        #expect(js.clamps[1].position == "14 in to 18 in from the left edge, 2 in to 5 in from the bottom edge")
        #expect(js.clamps[1].height == "flush with the top")
        let html = JobSheetHTML.render(js)
        #expect(html.contains("<td>Vise &lt;A&gt;</td>"))
        #expect(svgs(html)[0].contains(">Vise &lt;A&gt;</text>"))
    }

    @Test func aNestedProjectShowsTheClampsOnEverySheet() {
        var (p, _) = project()
        let sheet2 = Layer(name: "Sheet 2", sheet: SheetSlot(number: 2, offset: Vec2(30, 0)))
        p.document.layers.append(sheet2)
        p.document.add(AppTestSupport.rect(32, 2, 4, 4, layer: sheet2.id))
        let js = sheet(p)
        #expect(js.sheets.count == 2)
        let pictures = svgs(JobSheetHTML.render(js))
        #expect(pictures.count == 2)
        #expect(pictures.allSatisfy { $0.contains(">Clamps</text>") })
    }

    @Test func aVisibleClampLayerIsDrawnAsAZoneNotAlsoAsAPart() {
        let (p, clamps) = project()
        let js = sheet(p)
        #expect(js.sheets.count == 1)
        #expect(!js.sheets[0].shapes.contains { $0.layerID == clamps })
        #expect(js.sheets[0].shapes.count == 1)
    }

    @Test func aClampPastTheMaterialEdgeWidensThePicture() throws {
        let (p, _) = project()
        let svg = try #require(svgs(JobSheetHTML.render(sheet(p))).first)
        let viewBox = try #require(svg.components(separatedBy: "viewBox=\"").dropFirst().first?.components(separatedBy: "\"").first)
        let x = try #require(Double(viewBox.split(separator: " ")[0]))
        #expect(x < -2)
    }

    @Test func positionsAreInTheDocumentsUnits() {
        var d = Document(units: .millimeter)
        d.job.width = 600
        d.job.height = 450
        let clamps = Layer(name: "Clamps", keepOut: LayerKeepOut(height: 30))
        d.layers.append(clamps)
        d.add(Shape(layerID: clamps.id, paths: [ShapeFactory.rectangle(Rect2(x: 100, y: -50, width: 50, height: 75))]))
        let js = sheet(LoftLineProject(document: d))
        #expect(js.clamps == [JobSheet.Clamp(name: "Clamps", position: "bottom edge, centre 125 mm from the left, reaches 25 mm onto the material",
                                             height: "30 mm above the material")])
    }

    @Test func aProjectWithNoKeepOutsHasNoClampSection() {
        var d = Document()
        d.add(AppTestSupport.rect(4, 4, 6, 4, layer: d.defaultLayerID))
        let html = JobSheetHTML.render(sheet(LoftLineProject(document: d)))
        #expect(!html.contains("Clamps and screws"))
        #expect(!html.contains("clamp-hatch"))
    }
}
