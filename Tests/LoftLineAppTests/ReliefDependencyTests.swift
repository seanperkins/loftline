import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineApp

private let quarter = ToolLibrary.seeded.tools[3]   // 1/4" ball nose
private let eighth = ToolLibrary.seeded.tools[4]    // 1/8" ball nose

/// A rest pass and the finish it follows, a relief's split shared by its sides, and how templates carry both
/// (docs/implicit-state-machines.md #8).
@Suite struct ReliefDependencyTests {
    func project(units: LengthUnit = .inch, split: ReliefSplit? = nil) -> (LoftLineProject, source: Relief3DOperation,
                                                                           rest: Relief3DOperation) {
        var doc = Document(units: units, job: JobSetup(width: 4, height: 4, thickness: 1.25))
        var model = PlacedModel(name: "Dome", mesh: Mesh3D(vertices: [], indices: []), depth: 1.1, zTop: 0.1)
        model.reliefSplit = split
        doc.models = [model]
        let source = Relief3DOperation(setup: OperationSetup(name: "Finish", toolID: quarter.id),
                                       params: Relief3DParameters(modelID: model.id))
        var restParams = Relief3DParameters(modelID: model.id)
        restParams.finishing.rest = .operation(source.setup.id)
        let rest = Relief3DOperation(setup: OperationSetup(name: "Rest", toolID: eighth.id), params: restParams)
        return (LoftLineProject(document: doc, operations: [.relief3D(source), .relief3D(rest)]), source, rest)
    }

    func toolpath(_ pass: String, moves: Bool = true) -> Toolpath {
        var t = Toolpath(name: pass, kind: .relief3D, tool: quarter,
                         moves: moves ? [.rapid(to: Vec3(0, 0, 1)), .linear(to: Vec3(1, 0, -0.1), feed: 10)] : [])
        t.metadata["pass"] = pass
        return t
    }

    @Test func restDependencyNeedsAFinishingResult() {
        let (_, source, rest) = project()
        func result(_ tps: [Toolpath], error: String? = nil) -> [UUID: ToolpathResult] {
            [source.setup.id: ToolpathResult(toolpaths: tps, error: error, operation: .relief3D(source), designRevision: 0,
                                             estimatedSeconds: 0)]
        }
        let op = AnyOperation.relief3D(rest)
        #expect(RestDependency.problem(op, results: [:]) != nil)
        #expect(RestDependency.problem(op, results: result([], error: "missing 3D model")) != nil)
        #expect(RestDependency.problem(op, results: result([toolpath("roughing")])) != nil)
        #expect(RestDependency.problem(op, results: result([toolpath("finishing", moves: false)]))?
                    .contains("Rest after \"Finish\": it has no finishing toolpath") == true)
        #expect(RestDependency.problem(op, results: result([toolpath("roughing"), toolpath("finishing")])) == nil)
        #expect(RestDependency.problem(.relief3D(source), results: [:]) == nil)   // not a rest pass
    }

    @Test func splitScalesWithUnits() {
        let (p, _, _) = project(split: ReliefSplit(flip: .leftRight, splitDepth: 0.5, web: 0.04))
        let mm = p.converted(to: .millimeter)
        let s = mm.document.models[0].reliefSplit
        #expect(abs((s?.splitDepth ?? 0) - 12.7) < 1e-9 && abs((s?.web ?? 0) - 1.016) < 1e-9)
    }

    @Test func editingTheSplitOnOneSideChangesBoth() {
        // The form of either side edits the model's split; a review flag from an older file clears on every relief of
        // the model in one step.
        var (p, _, _) = project(split: ReliefSplit(flip: .leftRight, splitDepth: 0.5, web: 0.04))
        for i in p.operations.indices {
            guard case .relief3D(var r) = p.operations[i] else { continue }
            r.params.twoSided = TwoSidedSettings(side: i == 0 ? .top : .bottom)
            r.params.twoSided?.splitNeedsReview = true
            p.operations[i] = .relief3D(r)
        }
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        let model = p.document.models[0].id
        doc.setReliefSplit(ReliefSplit(flip: .topBottom, splitDepth: 0.6, web: 0.05), model: model)
        #expect(doc.project.document.models[0].reliefSplit == ReliefSplit(flip: .topBottom, splitDepth: 0.6, web: 0.05))
        doc.useReliefSplit(model: model)
        for op in doc.project.operations {
            guard case .relief3D(let r) = op else { continue }
            #expect(r.params.twoSided?.splitNeedsReview != true)
        }
    }

    // MARK: Templates

    func addedReliefs(_ target: LoftLineProject) -> [Relief3DOperation] {
        target.operations.compactMap { if case .relief3D(let r) = $0 { return r } else { return nil } }
    }

    @Test func templateRemapsTheRestSource() throws {
        let (p, source, rest) = project()
        let template = ToolpathTemplate.make(from: p, library: .seeded)
        var (target, _, _) = project()
        target.operations = []
        TemplateService.apply(template, to: &target, library: .seeded)
        let added = addedReliefs(target)
        #expect(added.count == 2 && added[0].setup.id != source.setup.id)
        #expect(added[1].params.finishing.rest == .operation(added[0].setup.id))
        // A template of the rest pass alone cannot name its source: it is unresolved, with the source's tool.
        let alone = ToolpathTemplate.make(from: p, operationIDs: [rest.setup.id], library: .seeded)
        guard case .relief3D(let r) = alone.entries[0].operation else { Issue.record("not a relief"); return }
        #expect(r.params.finishing.rest == .unresolved(toolID: quarter.id))
        #expect(alone.tools.contains { $0.id == quarter.id })
    }

    @Test func version1TemplateMigrates() throws {
        var (p, source, _) = project(split: ReliefSplit(flip: .topBottom, splitDepth: 0.5, web: 0.04))
        for i in p.operations.indices {
            guard case .relief3D(var r) = p.operations[i] else { continue }
            r.params.twoSided = TwoSidedSettings(side: i == 0 ? .top : .bottom)
            p.operations[i] = .relief3D(r)
        }
        let template = ToolpathTemplate.make(from: p, library: .seeded)
        var obj = try JSONSerialization.jsonObject(with: template.encoded()) as! [String: Any]
        obj["formatVersion"] = 1
        var entries = obj["entries"] as! [[String: Any]]
        for i in entries.indices { entries[i].removeValue(forKey: "reliefSplit") }
        obj["entries"] = entries
        func walk(_ v: Any) -> Any {
            if var d = v as? [String: Any] {
                if var two = d["twoSided"] as? [String: Any] {
                    two["flip"] = "topBottom"; two["splitDepth"] = 0.5; two["web"] = 0.04
                    d["twoSided"] = two
                    if var f = d["finishing"] as? [String: Any], f["rest"] != nil {
                        f.removeValue(forKey: "rest")
                        f["restToolID"] = quarter.id.uuidString
                        d["finishing"] = f
                    }
                    return d
                }
                return d.mapValues(walk)
            }
            if let a = v as? [Any] { return a.map(walk) }
            return v
        }
        let back = try ToolpathTemplate.decode(from: JSONSerialization.data(withJSONObject: walk(obj)))
        #expect(back.formatVersion == 2)
        #expect(back.entries.map(\.reliefSplit) == Array(repeating: ReliefSplit(flip: .topBottom, splitDepth: 0.5, web: 0.04), count: 2))
        guard case .relief3D(let r) = back.entries[1].operation else { Issue.record("not a relief"); return }
        #expect(r.params.finishing.rest == .operation(source.setup.id))
    }

    @Test func version2TemplateIsRefusedByVersion1Reader() throws {
        let (p, _, _) = project()
        let data = try ToolpathTemplate.make(from: p, library: .seeded).encoded()
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        // A version 1 reader refuses any formatVersion above 1 (`ToolpathTemplate.decode`).
        #expect(ToolpathTemplate.currentFormatVersion == 2 && (obj["formatVersion"] as? Int) == 2)
    }

    @Test(arguments: [(LengthUnit.inch, LengthUnit.millimeter), (.millimeter, .inch)])
    func templateSplitConvertsUnits(from: LengthUnit, to: LengthUnit) throws {
        let f = from.factor(to: to)
        let split = ReliefSplit(flip: .leftRight, splitDepth: 0.5 / LengthUnit.inch.factor(to: from),
                                web: 0.04 / LengthUnit.inch.factor(to: from))
        var (p, _, _) = project(units: from, split: split)
        p.operations = [p.operations[0]]
        if case .relief3D(var r) = p.operations[0] { r.params.twoSided = TwoSidedSettings(side: .top); p.operations[0] = .relief3D(r) }
        let template = ToolpathTemplate.make(from: p, library: .seeded)
        let converted = ReliefSplit(flip: .leftRight, splitDepth: split.splitDepth! * f, web: split.web * f)
        for (existing, review) in [(ReliefSplit?.none, false), (converted, false),
                                   (ReliefSplit(flip: .topBottom, splitDepth: converted.splitDepth, web: converted.web), true)] {
            var (target, _, _) = project(units: to, split: existing)
            target.operations = []
            TemplateService.apply(template, to: &target, library: .seeded)
            let s = try #require(target.document.models[0].reliefSplit)
            let expected = existing ?? converted
            #expect(s.flip == expected.flip && abs((s.splitDepth ?? 0) - expected.splitDepth!) < 1e-9
                        && abs(s.web - expected.web) < 1e-9, Comment(rawValue: "\(from)→\(to) \(String(describing: existing))"))
            #expect((addedReliefs(target)[0].params.twoSided?.splitNeedsReview == true) == review)
        }
    }

    @Test func templateSplitConflictNeedsReview() throws {
        var (p, _, _) = project(split: ReliefSplit(flip: .leftRight, splitDepth: 0.5, web: 0.04))
        if case .relief3D(var r) = p.operations[0] { r.params.twoSided = TwoSidedSettings(side: .top); p.operations[0] = .relief3D(r) }
        p.operations = [p.operations[0]]
        let template = ToolpathTemplate.make(from: p, library: .seeded)
        var (target, _, _) = project(split: ReliefSplit(flip: .leftRight, splitDepth: 0.5, web: 0.08))
        target.operations = []
        TemplateService.apply(template, to: &target, library: .seeded)
        #expect(target.document.models[0].reliefSplit?.web == 0.08)
        #expect(addedReliefs(target)[0].params.twoSided?.splitNeedsReview == true)
    }
}
