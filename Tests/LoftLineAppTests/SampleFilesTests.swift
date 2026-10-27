import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp

/// Builds the files in `samples/` and checks they import, calculate and post cleanly.
///
/// The files are only written when `LOFTLINE_WRITE_SAMPLES=1`:
/// `LOFTLINE_WRITE_SAMPLES=1 scripts/test.sh --filter SampleFiles`
@Suite("Sample files", .serialized)
struct SampleFilesTests {
    static let samplesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("samples", isDirectory: true)
    static var writeSamples: Bool { ProcessInfo.processInfo.environment["LOFTLINE_WRITE_SAMPLES"] == "1" }

    static func write(_ data: Data, _ name: String) throws {
        guard writeSamples else { return }
        try FileManager.default.createDirectory(at: samplesDir, withIntermediateDirectories: true)
        try data.write(to: samplesDir.appendingPathComponent(name))
    }

    // MARK: Sign (SVG + .loftline + .tap)

    /// The sign's lettering, shared by the SVG and the fit test.
    static func signText(layerID: UUID) throws -> Shape {
        try TextOutliner().shape(for: "LOFTLINE", fontName: "Helvetica-Bold", size: 2.5,
                                 origin: Vec2(12, 5), alignment: .center, layerID: layerID)
    }

    /// 24 x 12 in sign: rounded border, recessed panel, "LOFTLINE" text, hanging hole + 4 mounting holes.
    static func signSVG() throws -> Data {
        let names = ["Outline", "Pocket", "Text", "Drill"]
        let layers = names.map { Layer(name: $0) }
        let id = Dictionary(uniqueKeysWithValues: zip(names, layers.map(\.id)))
        let outline = Shape(name: "Outline", layerID: id["Outline"]!,
                            paths: [ShapeFactory.rectangle(Rect2(x: 1, y: 1, width: 22, height: 10), cornerRadius: 1)])
        let panel = Shape(name: "Panel", layerID: id["Pocket"]!,
                          paths: [ShapeFactory.rectangle(Rect2(x: 4, y: 2, width: 16, height: 1.5), cornerRadius: 0.25)])
        let text = try Self.signText(layerID: id["Text"]!)
        let holeCentres = [Vec2(12, 10), Vec2(2.25, 2.25), Vec2(21.75, 2.25), Vec2(2.25, 9.75), Vec2(21.75, 9.75)]
        let holes = holeCentres.map {
            Shape(name: "Hole", layerID: id["Drill"]!, paths: [ShapeFactory.circle(center: $0, radius: 0.125)])
        }
        return try SVGExporter().export(shapes: [outline, panel, text] + holes, layers: layers, units: .inch)
    }

    /// The project as a saved file holds it (format 2): the tools its operations use, and its post and machine as copies.
    static func withCopies(_ project: LoftLineProject, library: ToolLibrary) -> LoftLineProject {
        ToolSync.carrying(ProjectPost.attaching(project, profiles: BuiltInPosts.all, machines: BuiltInMachines.all), library: library)
    }

    static func signProject() throws -> (LoftLineProject, ToolLibrary) {
        var doc = Document()
        doc.job = JobSetup(width: 24, height: 12, thickness: 0.75)
        doc.job.zZero = .materialTop
        doc.job.xyOrigin = .lowerLeft
        var project = LoftLineProject(document: doc, postProfileID: BuiltInPosts.avidMach4Inch.id)
        _ = try ImportService.importFile(data: try signSVG(), fileName: "sign.svg", into: &project)
        let library = ToolLibrary.seeded
        func shapes(_ layer: String) -> [UUID] {
            guard let l = project.document.layers.first(where: { $0.name == layer }) else { return [] }
            return project.document.shapes.filter { $0.layerID == l.id }.map(\.id)
        }
        // Cut order: pocket, carve, drill, then cut the sign free last.
        let plan: [(OperationKind, String)] = [(.pocket, "Pocket"), (.vcarve, "Text"), (.drill, "Drill"),
                                               (.profile, "Outline")]
        for (kind, layer) in plan {
            guard var op = OperationFactory.make(kind: kind, project: project, library: library,
                                                 shapeIDs: shapes(layer)) else {
                Issue.record("could not create \(kind)"); continue
            }
            if case .pocket(var p) = op { p.params.depth.cutDepth = 0.125; op = .pocket(p) }
            if case .profile(var p) = op { p.params.tabs.isEnabled = true; op = .profile(p) }
            project.operations.append(op)
        }
        project = Self.withCopies(project, library: library)
        return (project, library)
    }

    /// The lettering sits between the recessed panel (y 2 to 3.5) and the hanging hole (x 12, y 10), inside the border.
    @Test("Sign: the text says LOFTLINE and fits the sign")
    func signTextIsLoftlineAndFitsTheSign() throws {
        let text = try Self.signText(layerID: UUID())
        #expect(text.name == "LOFTLINE")
        let room = Rect2(x: 1.5, y: 3.8, width: 21, height: 4)
        let b = text.bounds()
        #expect(b.min.x >= room.min.x && b.max.x <= room.max.x && b.min.y >= room.min.y && b.max.y <= room.max.y,
                "text bounds \(b) must lie inside \(room)")
    }

    @Test("Sign: SVG, .loftline and validator-clean .tap")
    func sign() throws {
        let svg = try Self.signSVG()
        try Self.write(svg, "sign.svg")

        let (project, library) = try Self.signProject()
        #expect(project.operations.count == 4)
        try Self.write(try project.encoded(), "sign.loftline")
        let reopened = try LoftLineProject.decode(from: try project.encoded())
        #expect(reopened.operations.count == 4)

        let profile = BuiltInPosts.avidMach4Inch
        var results: [UUID: ToolpathResult] = [:]
        for op in project.operations {
            let r = ToolpathCalculator.calculate(op, project: project, library: library, designRevision: 0,
                                                 rapidRate: profile.rapidRate)
            #expect(r.error == nil, "\(op.setup.name): \(r.error ?? "")")
            #expect(!r.toolpaths.isEmpty)
            results[op.id] = r
        }
        let tps = GCodeExporter.toolpaths(scope: .all, operations: project.operations, results: results,
                                          groupByTool: false)
        let result = GCodeExporter.export(project: project, toolpaths: tps, profile: profile,
                                          jobName: "Sign")
        #expect(result.errorMessage == nil)
        #expect(result.issues.isEmpty, "\(result.issues)")   // no warnings either: the sample ships clean
        let text = try #require(result.text)
        #expect(text.contains("G20"))
        #expect(text.contains("M30"))
        try Self.write(Data(text.utf8), "sign.tap")
    }

    // MARK: Facing

    /// 12 x 8 in board: the whole top faced 1/32 in with the widest end mill, then a 10 x 6 in plaque cut out of it.
    static func facingProject() throws -> (LoftLineProject, ToolLibrary) {
        var doc = Document()
        doc.job = JobSetup(width: 12, height: 8, thickness: 0.75)
        doc.job.zZero = .materialTop
        doc.job.xyOrigin = .lowerLeft
        let plaque = Shape(name: "Plaque", layerID: doc.defaultLayerID,
                           paths: [ShapeFactory.rectangle(Rect2(x: 1, y: 1, width: 10, height: 6), cornerRadius: 0.5)])
        doc.add(plaque)
        var project = LoftLineProject(document: doc, postProfileID: BuiltInPosts.avidMach4Inch.id)
        let library = ToolLibrary.seeded
        let face = try #require(OperationFactory.make(kind: .facing, project: project, library: library, shapeIDs: []))
        guard case .facing(var f) = face else { throw CAMError.invalidParameter("not a facing") }
        f.params.depth.cutDepth = 0.03125
        project.operations.append(.facing(f))
        let cut = try #require(OperationFactory.make(kind: .profile, project: project, library: library,
                                                     shapeIDs: [plaque.id]))
        guard case .profile(var p) = cut else { throw CAMError.invalidParameter("not a profile") }
        // The faced layer is already gone.
        p.params.depth.startDepth = 0.03125
        p.params.tabs.isEnabled = true
        project.operations.append(.profile(p))
        project = Self.withCopies(project, library: library)
        return (project, library)
    }

    /// The program the facing sample posts to.
    static func facingProgram(_ project: LoftLineProject, library: ToolLibrary) throws -> String {
        let profile = BuiltInPosts.avidMach4Inch
        var results: [UUID: ToolpathResult] = [:]
        for op in project.operations {
            let r = ToolpathCalculator.calculate(op, project: project, library: library, designRevision: 0,
                                                 rapidRate: profile.rapidRate)
            #expect(r.error == nil, "\(op.setup.name): \(r.error ?? "")")
            #expect(!r.toolpaths.isEmpty)
            results[op.id] = r
        }
        let tps = GCodeExporter.toolpaths(scope: .all, operations: project.operations, results: results,
                                          groupByTool: false)
        let result = GCodeExporter.export(project: project, toolpaths: tps, profile: profile, jobName: "Faced board")
        #expect(result.errorMessage == nil)
        #expect(result.issues.isEmpty, "\(result.issues)")
        return try #require(result.text)
    }

    @Test("Facing: faced board .loftline and validator-clean .tap")
    func facedBoard() throws {
        let (project, library) = try Self.facingProject()
        #expect(project.operations.map(\.kind) == [.facing, .profile])
        try Self.write(try project.encoded(), "faced-board.loftline")
        let text = try Self.facingProgram(project, library: library)
        try Self.write(Data(text.utf8), "faced-board.tap")
        let reopened = try LoftLineProject.decode(from: try project.encoded())
        #expect(reopened.operations == project.operations)
    }

    // MARK: Checked-in files

    /// The files in `samples/` as committed still open, and the sign's .loftline posts to exactly the
    /// committed .tap with no validator errors (catches CAM or post drift that was not re-sampled).
    @Test("Checked-in samples load and the sign .tap regenerates unchanged")
    func checkedInSamples() throws {
        func read(_ name: String) throws -> Data {
            try Data(contentsOf: Self.samplesDir.appendingPathComponent(name))
        }
        let project = try LoftLineProject.decode(from: try read("sign.loftline"))
        #expect(project.operations.count == 4)

        var scratch = LoftLineProject(document: Document(), postProfileID: BuiltInPosts.avidMach4Inch.id)
        let svg = try ImportService.importFile(data: try read("sign.svg"), fileName: "sign.svg",
                                               into: &scratch)
        #expect(!svg.shapeIDs.isEmpty)
        let dxf = try ImportService.importFile(data: try read("bracket-plate.dxf"), fileName: "bracket-plate.dxf",
                                               into: &scratch)
        #expect(dxf.shapeIDs.count >= 7)
        #expect(!dxf.warnings.contains { $0.contains("nearly meet") })  // a clean drawing raises no gap report
        let mesh = try STLImporter(sourceUnits: .millimeter).importMesh(from: try read("relief.stl"),
                                                                       targetUnits: .inch)
        #expect(mesh.indices.count / 3 > 1000)

        let profile = BuiltInPosts.avidMach4Inch
        var results: [UUID: ToolpathResult] = [:]
        for op in project.operations {
            let r = ToolpathCalculator.calculate(op, project: project, library: ToolLibrary.seeded,
                                                 designRevision: 0, rapidRate: profile.rapidRate)
            #expect(r.error == nil, "\(op.setup.name): \(r.error ?? "")")
            results[op.id] = r
        }
        let tps = GCodeExporter.toolpaths(scope: .all, operations: project.operations, results: results,
                                          groupByTool: false)
        let result = GCodeExporter.export(project: project, toolpaths: tps, profile: profile,
                                          jobName: "Sign")
        let text = try #require(result.text)
        #expect(result.issues.isEmpty, "\(result.issues)")
        let committed = String(decoding: try read("sign.tap"), as: UTF8.self)
        #expect(text == committed)
        let validator = GCodeValidator(profile: profile, job: project.document.job, units: project.document.units)
        let fileIssues = validator.validate(gcode: committed)
        #expect(fileIssues.isEmpty, "\(fileIssues)")

        // The faced board posts to exactly its committed program too.
        let faced = try LoftLineProject.decode(from: try read("faced-board.loftline"))
        #expect(faced.operations.map(\.kind) == [.facing, .profile])
        let facedText = try Self.facingProgram(faced, library: ToolLibrary.seeded)
        let facedCommitted = String(decoding: try read("faced-board.tap"), as: UTF8.self)
        #expect(facedText == facedCommitted)
        let facedIssues = GCodeValidator(profile: profile, job: faced.document.job, units: faced.document.units)
            .validate(gcode: facedCommitted)
        #expect(facedIssues.isEmpty, "\(facedIssues)")
    }

    // MARK: DXF part

    /// 8 x 5 in bracket plate: rounded outline, four 1/4" bolt holes and a 2 x 1 in slot.
    @Test("DXF part with inner holes round-trips")
    func dxfPart() throws {
        let layers = [Layer(name: "Outline"), Layer(name: "Holes")]
        let outline = Shape(name: "Plate", layerID: layers[0].id,
                            paths: [ShapeFactory.rectangle(Rect2(x: 0, y: 0, width: 8, height: 5), cornerRadius: 0.5)])
        var shapes = [outline]
        for c in [Vec2(0.75, 0.75), Vec2(7.25, 0.75), Vec2(0.75, 4.25), Vec2(7.25, 4.25)] {
            shapes.append(Shape(name: "Bolt", layerID: layers[1].id,
                                paths: [ShapeFactory.circle(center: c, radius: 0.125)]))
        }
        shapes.append(Shape(name: "Slot", layerID: layers[1].id,
                            paths: [ShapeFactory.rectangle(Rect2(x: 3, y: 2, width: 2, height: 1), cornerRadius: 0.5)]))
        shapes.append(Shape(name: "Bore", layerID: layers[1].id,
                            paths: [ShapeFactory.circle(center: Vec2(4, 3.75), radius: 0.375)]))
        let data = try DXFExporter().export(shapes: shapes, layers: layers, units: .inch)
        try Self.write(data, "bracket-plate.dxf")

        var project = LoftLineProject(document: Document(), postProfileID: BuiltInPosts.avidMach4Inch.id)
        let outcome = try ImportService.importFile(data: data, fileName: "bracket-plate.dxf", into: &project)
        #expect(outcome.shapeIDs.count >= 7)
    }

    // MARK: STL relief

    /// 75 x 75 mm heightfield (two crossed sine waves around a dome), max 6 mm tall, closed solid.
    static func reliefSTL() -> String {
        let n = 40, size = 75.0, h = 6.0
        func z(_ i: Int, _ j: Int) -> Double {
            let u = Double(i) / Double(n), v = Double(j) / Double(n)
            let dx = u - 0.5, dy = v - 0.5
            let dome = max(0, 1 - (dx * dx + dy * dy) * 4)
            let waves = 0.5 + 0.5 * sin(u * .pi * 6) * sin(v * .pi * 6)
            return 1 + (h - 1) * (0.7 * dome + 0.3 * waves * dome)
        }
        func p(_ i: Int, _ j: Int, _ zz: Double) -> (Double, Double, Double) {
            (Double(i) / Double(n) * size, Double(j) / Double(n) * size, zz)
        }
        var out = "solid loftline_relief\n"
        func tri(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ c: (Double, Double, Double)) {
            let ux = b.0 - a.0, uy = b.1 - a.1, uz = b.2 - a.2
            let vx = c.0 - a.0, vy = c.1 - a.1, vz = c.2 - a.2
            var nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx
            let len = max(1e-12, (nx * nx + ny * ny + nz * nz).squareRoot())
            nx /= len; ny /= len; nz /= len
            func f(_ x: Double) -> String { String(format: "%.5f", x) }
            out += "  facet normal \(f(nx)) \(f(ny)) \(f(nz))\n    outer loop\n"
            for q in [a, b, c] { out += "      vertex \(f(q.0)) \(f(q.1)) \(f(q.2))\n" }
            out += "    endloop\n  endfacet\n"
        }
        for i in 0..<n {
            for j in 0..<n {
                let a = p(i, j, z(i, j)), b = p(i + 1, j, z(i + 1, j))
                let c = p(i + 1, j + 1, z(i + 1, j + 1)), d = p(i, j + 1, z(i, j + 1))
                tri(a, b, c); tri(a, c, d)                                 // top
                tri(p(i, j, 0), p(i + 1, j + 1, 0), p(i + 1, j, 0))        // bottom
                tri(p(i, j, 0), p(i, j + 1, 0), p(i + 1, j + 1, 0))
            }
        }
        // Side walls.
        for k in 0..<n {
            func wall(_ a0: (Int, Int), _ a1: (Int, Int)) {
                let t0 = p(a0.0, a0.1, z(a0.0, a0.1)), t1 = p(a1.0, a1.1, z(a1.0, a1.1))
                let b0 = p(a0.0, a0.1, 0), b1 = p(a1.0, a1.1, 0)
                tri(b0, b1, t1); tri(b0, t1, t0)
            }
            wall((k, 0), (k + 1, 0))
            wall((n, k), (n, k + 1))
            wall((k + 1, n), (k, n))
            wall((0, k + 1), (0, k))
        }
        out += "endsolid loftline_relief\n"
        return out
    }

    /// Every sample is a format 2 file that carries its own post, machine and tools (so it posts the same on any Mac),
    /// and carries the tools exactly as the seeded library has them, so adding the copies moved no G-code.
    @Test("Checked-in samples carry their post, machine and tools")
    func samplesCarryTheirCopies() throws {
        for name in ["sign.loftline", "faced-board.loftline"] {
            let data = try Data(contentsOf: Self.samplesDir.appendingPathComponent(name))
            #expect(try LoftLineFile.formatVersion(of: data) == 2, "\(name)")
            let project = try LoftLineProject.opening(from: data)
            let post = try #require(project.postSnapshot.flatMap { try? PostProfile(snapshot: $0) }, "\(name): post copy")
            #expect(post == BuiltInPosts.avidMach4Inch && project.postProfileID == post.id)
            let machine = try #require(project.machineSnapshot.flatMap { try? MachineDefinition(snapshot: $0) }, "\(name): machine copy")
            #expect(machine == BuiltInMachines.avidPRO6096)
            #expect(project.machineID == nil && project.machineInferredFor == post.id, "nil ids stay nil")
            #expect(!project.tools.isEmpty)
            for tool in project.tools { #expect(ToolLibrary.seeded.tool(id: tool.id) == tool, "\(name): \(tool.name)") }
        }
    }

    /// Writes samples/relief.stl with LOFTLINE_WRITE_SAMPLES=1; the committed file is checked by
    /// `checkedInSamples`, which is where its import is asserted.
    @Test("STL relief sample is written on request")
    func stlRelief() throws {
        try Self.write(Data(Self.reliefSTL().utf8), "relief.stl")
    }
}
