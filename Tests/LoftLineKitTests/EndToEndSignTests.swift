import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineKit

/// Headless end-to-end run of the app pipeline on a sign:
/// SVG import → Profile / Pocket / V-Carve / Drill → calculate → post (Avid Mach4 inch) → validate.
///
/// Fixtures live in Tests/Fixtures/e2e and Tests/Fixtures/golden. Regenerate them with
/// `LOFTLINE_UPDATE_GOLDEN=1 scripts/test.sh --filter EndToEnd` after an intentional output change.
@Suite("End to end: sign", .serialized)
struct EndToEndSignTests {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
    static let svgURL = fixtures.appendingPathComponent("e2e/sign.svg")
    static var updateGolden: Bool { ProcessInfo.processInfo.environment["LOFTLINE_UPDATE_GOLDEN"] == "1" }

    /// Layer names in the fixture, each selecting one toolpath's vectors.
    enum SignLayer: String, CaseIterable { case outline = "Outline", pocket = "Pocket", text = "Text", drill = "Drill" }

    /// Builds the sign design (24 x 12 in): rounded-rect outline, a recessed panel along the bottom,
    /// "LOFTLINE" as outlines and a hanging hole.
    static func makeSignSVG() throws -> Data {
        var layers: [SignLayer: Layer] = [:]
        for l in SignLayer.allCases { layers[l] = Layer(name: l.rawValue) }
        let outline = Shape(name: "Outline", layerID: layers[.outline]!.id,
                            paths: [ShapeFactory.rectangle(Rect2(x: 1, y: 1, width: 22, height: 10), cornerRadius: 1)])
        let panel = Shape(name: "Panel", layerID: layers[.pocket]!.id,
                          paths: [ShapeFactory.rectangle(Rect2(x: 4, y: 2, width: 16, height: 1.5), cornerRadius: 0.25)])
        let text = try TextOutliner().shape(for: "LOFTLINE", fontName: "Helvetica-Bold", size: 2.5,
                                            origin: Vec2(12, 5), alignment: .center,
                                            layerID: layers[.text]!.id)
        let hole = Shape(name: "Hole", layerID: layers[.drill]!.id,
                         paths: [ShapeFactory.circle(center: Vec2(12, 10), radius: 0.125)])
        return try SVGExporter().export(shapes: [outline, panel, text, hole],
                                        layers: SignLayer.allCases.map { layers[$0]! }, units: .inch)
    }

    static func signSVG() throws -> Data {
        if updateGolden {
            try FileManager.default.createDirectory(at: svgURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try makeSignSVG().write(to: svgURL)
        }
        // Never regenerate silently: a missing fixture must fail, not rebuild from the current code.
        return try Data(contentsOf: svgURL)
    }

    /// Imports the fixture into a fresh inch project and adds the four toolpaths.
    static func project(zZero: ZZeroMode) throws -> (LoftLineProject, ToolLibrary) {
        var doc = Document()
        doc.job = JobSetup(width: 24, height: 12, thickness: 0.75)
        doc.job.zZero = zZero
        var project = LoftLineProject(document: doc, postProfileID: BuiltInPosts.avidMach4Inch.id)
        let outcome = try ImportService.importFile(data: try signSVG(), fileName: "sign.svg", into: &project)
        #expect(!outcome.shapeIDs.isEmpty)

        let library = ToolLibrary.seeded
        func shapes(_ layer: SignLayer) -> [UUID] {
            guard let l = project.document.layers.first(where: { $0.name == layer.rawValue }) else { return [] }
            return project.document.shapes.filter { $0.layerID == l.id }.map(\.id)
        }
        let plan: [(OperationKind, SignLayer)] = [(.pocket, .pocket), (.vcarve, .text), (.drill, .drill),
                                                  (.profile, .outline)]
        for (kind, layer) in plan {
            let ids = shapes(layer)
            #expect(!ids.isEmpty, "layer \(layer.rawValue) should have vectors")
            guard var op = OperationFactory.make(kind: kind, project: project, library: library, shapeIDs: ids) else {
                Issue.record("could not create \(kind)"); continue
            }
            if case .pocket(var p) = op { p.params.depth.cutDepth = 0.125; op = .pocket(p) }
            if case .profile(var p) = op {
                p.params.tabs.isEnabled = true
                op = .profile(p)
            }
            project.operations.append(op)
        }
        return (project, library)
    }

    static func post(zZero: ZZeroMode) throws -> GCodeExportResult {
        let (project, library) = try project(zZero: zZero)
        let profile = BuiltInPosts.avidMach4Inch
        var results: [UUID: ToolpathResult] = [:]
        for op in project.operations {
            let r = ToolpathCalculator.calculate(op, project: project, library: library, designRevision: 0,
                                                 rapidRate: profile.rapidRate)
            #expect(r.error == nil, "\(op.setup.name): \(r.error ?? "")")
            #expect(!r.toolpaths.isEmpty, "\(op.setup.name) produced no toolpaths")
            results[op.id] = r
        }
        let tps = GCodeExporter.toolpaths(scope: .all, operations: project.operations, results: results,
                                          groupByTool: true)
        return GCodeExporter.export(project: project, toolpaths: tps, profile: profile, jobName: "Sign", expected: .notChecked(because: "test"))
    }

    @Test("Fixture SVG imports onto four layers")
    func fixtureImports() throws {
        let (project, _) = try Self.project(zZero: .materialTop)
        #expect(project.operations.count == 4)
        let names = Set(project.document.layers.map(\.name))
        for l in SignLayer.allCases { #expect(names.contains(l.rawValue)) }
        // "LOFTLINE" has 8 letters plus a counter in O.
        let textLayer = project.document.layers.first { $0.name == "Text" }!
        let textPaths = project.document.shapes.filter { $0.layerID == textLayer.id }.flatMap(\.paths)
        #expect(textPaths.count >= 9, "the fixture should hold LOFTLINE: \(textPaths.count) paths")
    }

    @Test("Posts with the Avid inch profile with zero validator errors", arguments: ZZeroMode.allCases)
    func postsCleanly(zZero: ZZeroMode) throws {
        let result = try Self.post(zZero: zZero)
        #expect(result.errorMessage == nil, "\(result.errorMessage ?? "")")
        let errors = result.issues.filter { $0.severity == .error }
        #expect(errors.isEmpty, "\(errors)")
        let text = try #require(result.text)

        #expect(text.contains("G20"))
        #expect(text.contains("T9 M6"))     // drill
        #expect(text.contains("T6 M6"))     // 60 deg V-bit
        #expect(text.contains("T1 M6"))     // 1/4" end mill
        #expect(text.hasSuffix("M30\n") || text.hasSuffix("M30"))
        // Grouping by tool must not cut the sign free before it is carved and drilled.
        let profileAt = try #require(text.range(of: "Toolpath: Profile 1")?.lowerBound)
        let vcarveAt = try #require(text.range(of: "Toolpath: V-Carve 1")?.lowerBound)
        let drillAt = try #require(text.range(of: "Toolpath: Drilling 1")?.lowerBound)
        #expect(vcarveAt < profileAt && drillAt < profileAt)
        // Deepest Z: profile through the 0.75" stock (+ any cut-through allowance).
        let zs = text.split(separator: "\n").compactMap { line -> Double? in
            guard let r = line.range(of: #"Z(-?\d+(\.\d+)?)"#, options: .regularExpression),
                  !line.hasPrefix("(") else { return nil }
            return Double(line[r].dropFirst())
        }
        let minZ = try #require(zs.min())
        switch zZero {
        case .materialTop: #expect(minZ <= -0.75 + 1e-6 && minZ > -0.80)
        case .spoilboard: #expect(minZ <= 1e-6 && minZ > -0.05)
        }

        let golden = Self.fixtures.appendingPathComponent("golden/sign-\(zZero.rawValue).tap")
        if Self.updateGolden {
            try FileManager.default.createDirectory(at: golden.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: golden, atomically: true, encoding: .utf8)
        }
        // A missing golden is a failure, never a silent regeneration that compares the output to itself.
        #expect(FileManager.default.fileExists(atPath: golden.path), "\(golden.lastPathComponent) is missing; create it on purpose with LOFTLINE_UPDATE_GOLDEN=1")
        let expected = try String(contentsOf: golden, encoding: .utf8)
        #expect(text == expected, "G-code differs from \(golden.lastPathComponent); rerun with LOFTLINE_UPDATE_GOLDEN=1 if intended")
    }

    @Test("Spoilboard program is the material-top program shifted by the thickness")
    func zModesAgree() throws {
        let top = try #require(try Self.post(zZero: .materialTop).text).split(separator: "\n")
        let bed = try #require(try Self.post(zZero: .spoilboard).text).split(separator: "\n")
        #expect(top.count == bed.count)
        // Every motion line matches word for word except Z, which is exactly 0.75 higher.
        var zLines = 0
        for (t, b) in zip(top, bed) where !t.hasPrefix("(") {
            let tw = t.split(separator: " "), bw = b.split(separator: " ")
            #expect(tw.count == bw.count, "\(t) vs \(b)")
            for (x, y) in zip(tw, bw) {
                if x.hasPrefix("Z"), let zt = Double(x.dropFirst()), let zb = Double(y.dropFirst()) {
                    #expect(abs(zb - zt - 0.75) < 1e-9, "\(t) vs \(b)")
                    zLines += 1
                } else {
                    #expect(x == y, "\(t) vs \(b)")
                }
            }
        }
        #expect(zLines > 100)
    }
}
