import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

private let seeded = ToolLibrary.seeded

/// A design with an "Outline" rectangle, two "Holes" circles and an open "Text" line.
private func design(units: LengthUnit = .inch, outlineName: String = "Outline") -> (Document, [String: [UUID]]) {
    let f = LengthUnit.inch.factor(to: units)
    var doc = Document(units: units, layers: [Layer(name: outlineName), Layer(name: "Holes"), Layer(name: "Text")])
    var ids: [String: [UUID]] = [:]
    func add(_ path: Path, layer: Int, key: String) {
        let s = Shape(layerID: doc.layers[layer].id, paths: [path])
        doc.add(s)
        ids[key, default: []].append(s.id)
    }
    add(ShapeFactory.rectangle(Rect2(x: 0, y: 0, width: 10 * f, height: 6 * f)), layer: 0, key: "outline")
    add(ShapeFactory.circle(center: Vec2(2 * f, 2 * f), radius: 0.25 * f), layer: 1, key: "holes")
    add(ShapeFactory.circle(center: Vec2(8 * f, 2 * f), radius: 0.25 * f), layer: 1, key: "holes")
    add(Path(points: [Vec2(3 * f, 4 * f), Vec2(7 * f, 4 * f)], closed: false), layer: 2, key: "text")
    return (doc, ids)
}

private func sourceProject() -> LoftLineProject {
    let (doc, ids) = design()
    var profile = ProfileParameters(depth: DepthSettings(cutDepth: 0.75))
    profile.tabs.isEnabled = true
    profile.tabs.manualTabs = [TabAnchor(shapeID: ids["outline"]![0], fraction: 0.5)]
    let ops: [AnyOperation] = [
        .drill(DrillOperation(setup: OperationSetup(name: "Holes", toolID: seeded.tools[8].id, shapeIDs: ids["holes"]!))),
        .engrave(EngraveOperation(setup: OperationSetup(name: "Engrave", toolID: seeded.tools[7].id, shapeIDs: ids["text"]!))),
        .profile(ProfileOperation(setup: OperationSetup(name: "Cut out", toolID: seeded.tools[0].id, shapeIDs: ids["outline"]!),
                                  params: profile)),
    ]
    return LoftLineProject(document: doc, operations: ops)
}

@Test func templateSelectorsDescribeLayerAndKind() throws {
    let template = ToolpathTemplate.make(from: sourceProject(), library: seeded)
    #expect(template.entries.map(\.selector) == [
        VectorSelector(layerName: "Holes", geometry: .closed),
        VectorSelector(layerName: "Text", geometry: .open),
        VectorSelector(layerName: "Outline", geometry: .closed),
    ])
    #expect(template.entries.allSatisfy { $0.operation.setup.shapeIDs.isEmpty })
    guard case .profile(let p) = template.entries[2].operation else { Issue.record("profile"); return }
    #expect(p.params.tabs.manualTabs == nil)
    #expect(Set(template.tools.map(\.id)) == Set([seeded.tools[8].id, seeded.tools[7].id, seeded.tools[0].id]))
}

@Test func templateAppliesToANewDesignInOtherUnits() throws {
    let data = try ToolpathTemplate.make(from: sourceProject(), library: seeded).encoded()
    let template = try ToolpathTemplate.decode(from: data)
    // New design in mm; the outline layer name differs only in case.
    let (doc, ids) = design(units: .millimeter, outlineName: "OUTLINE")
    var target = LoftLineProject(document: doc, operations: [
        .pocket(PocketOperation(setup: OperationSetup(name: "Holes", toolID: seeded.tools[0].id))),
    ])
    // A library without the drill: the template's copy is added to the project.
    var lib = seeded
    lib.remove(id: seeded.tools[8].id)
    let outcome = TemplateService.apply(template, to: &target, library: lib)
    #expect(outcome == TemplateService.Outcome(added: 3, unmatched: [], skipped: 0))
    let added = Array(target.operations.dropFirst())
    #expect(added.map(\.setup.name) == ["Holes 2", "Engrave", "Cut out"])
    #expect(added[0].setup.shapeIDs == ids["holes"]!)
    #expect(added[1].setup.shapeIDs == ids["text"]!)
    #expect(added[2].setup.shapeIDs == ids["outline"]!)
    #expect(Set(added.map(\.id)).isDisjoint(with: sourceProject().operations.map(\.id)))
    guard case .profile(let p) = added[2] else { Issue.record("profile"); return }
    #expect(abs(p.params.depth.cutDepth - 0.75 * 25.4) < 1e-9)
    #expect(target.tools.contains { $0.id == seeded.tools[8].id })
    // The applied toolpaths calculate.
    let ctx = CAMContext(document: target.document, tools: target.mergedTools(with: lib))
    for op in added { #expect(try !op.generate(in: ctx).isEmpty) }
}

@Test func templateReportsUnmatchedSelectors() {
    let template = ToolpathTemplate.make(from: sourceProject(), library: seeded)
    var empty = LoftLineProject(document: Document())
    let outcome = TemplateService.apply(template, to: &empty, library: seeded)
    #expect(outcome.added == 3)
    #expect(outcome.unmatched == ["Holes", "Engrave", "Cut out"])
    #expect(TemplateService.summary(outcome).contains("No matching vectors"))
}

@Test func aWholeMaterialFacingKeepsNoVectorsWhenATemplateIsApplied() {
    var source = sourceProject()
    let tool = seeded.tools[2].id
    source.operations.insert(.facing(FacingOperation(setup: OperationSetup(name: "Face", toolID: tool),
                                                     params: FacingParameters(area: .material))), at: 0)
    source.operations.append(.facing(FacingOperation(setup: OperationSetup(name: "Box", toolID: tool,
                                                                        shapeIDs: source.document.shapes.prefix(1).map(\.id)),
                                                     params: FacingParameters(area: .vectors))))
    let template = ToolpathTemplate.make(from: source, library: seeded)
    // On a design whose layers match, the whole-material facing still has no vectors (its sheet and side must not follow
    // whatever an empty selector matches) and is not reported as unmatched, even on an empty design; the box one picks its.
    let (doc, ids) = design()
    var target = LoftLineProject(document: doc)
    let outcome = TemplateService.apply(template, to: &target, library: seeded)
    let whole = target.operations.first { $0.setup.name == "Face" }
    let box = target.operations.first { $0.setup.name == "Box" }
    #expect(whole?.setup.shapeIDs.isEmpty == true)
    #expect(box?.setup.shapeIDs == ids["outline"]!)
    #expect(!outcome.unmatched.contains("Face"))
    var empty = LoftLineProject(document: Document())
    #expect(!TemplateService.apply(template, to: &empty, library: seeded).unmatched.contains("Face"))
}
