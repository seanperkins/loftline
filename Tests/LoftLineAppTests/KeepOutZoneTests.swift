import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Test func keepOutZonesBlockExportOfToolpathsThatHitThem() throws {
    var project = AppTestSupport.project() // 2x1 rectangles at (1,1) and (5,1)
    let ids = project.document.shapes.map(\.id)
    let op = AnyOperation.profile(ProfileOperation(setup: OperationSetup(name: "Cut", toolID: ToolLibrary.seeded.tools[0].id,
                                                                         shapeIDs: ids)))
    project.upsertOperation(op)
    let ctx = CAMContext(document: project.document, tools: .seeded)
    let tps = try op.generate(in: ctx)
    let profile = BuiltInPosts.avidMach4Inch
    let clean = GCodeExporter.export(project: project, toolpaths: tps, profile: profile, jobName: "T", expected: .notChecked(because: "test"))
    #expect(!clean.issues.contains { $0.message.contains("keep-out") })
    // A clamp over the left end of the first rectangle.
    let clamp = KeepOutEditing.zones(from: [AppTestSupport.rect(0.5, 1.2, 0.8, 0.5, layer: project.document.defaultLayerID)],
                                     height: 1, tolerance: 0.0005, existing: 0)
    #expect(clamp.count == 1 && clamp[0].outline.count == 4)
    project.document.keepOutZones = clamp
    let blocked = GCodeExporter.export(project: project, toolpaths: tps, profile: profile, jobName: "T", expected: .notChecked(because: "test"))
    #expect(blocked.issues.contains { $0.severity == .error && $0.message.contains("keep-out zone") })
}

@Test func keepOutZonesScaleWithDocumentUnits() {
    var doc = Document()
    doc.keepOutZones = [KeepOutZone(name: "C", outline: [Vec2(1, 1), Vec2(2, 1), Vec2(2, 2)], height: 1)]
    let mm = doc.converted(to: .millimeter)
    #expect(mm.keepOutZones?[0].outline[1] == Vec2(50.8, 25.4))
    #expect(mm.keepOutZones?[0].height == 25.4)
}

/// Each operation is re-routed alone; the exporter must lift the travel between them too.
@Test func keepOutLiftOverRaisesTravelBetweenOperationsOnExport() throws {
    var project = AppTestSupport.project() // 2x1 rectangles at (1,1) and (5,1)
    let ids = project.document.shapes.map(\.id)
    let tool = ToolLibrary.seeded.tools[0].id
    let a = AnyOperation.profile(ProfileOperation(setup: OperationSetup(name: "A", toolID: tool, shapeIDs: [ids[0]])))
    let b = AnyOperation.profile(ProfileOperation(setup: OperationSetup(name: "B", toolID: tool, shapeIDs: [ids[1]])))
    var zone = KeepOutZone(name: "TallClamp", outline: [Vec2(3.4, 0.5), Vec2(4.6, 0.5), Vec2(4.6, 2.5), Vec2(3.4, 2.5)],
                           height: 1, liftOver: true)
    project.document.keepOutZones = [zone]
    let ctx = CAMContext(document: project.document, tools: .seeded)
    let tps = try a.generate(in: ctx) + b.generate(in: ctx)
    let profile = BuiltInPosts.avidMach4Inch
    let lifted = GCodeExporter.export(project: project, toolpaths: tps, profile: profile, jobName: "T", expected: .notChecked(because: "test"))
    #expect(!lifted.issues.contains { $0.message.contains("keep-out") })
    let text = try #require(lifted.text)
    let lines = text.split(separator: "\n").map(String.init)
    let start = try #require(lines.firstIndex { $0.contains("Toolpath: B") })
    let firstXY = try #require(lines[start...].firstIndex { $0.contains("X") && $0.contains("Y") })
    #expect(lines[start..<firstXY].contains { $0.contains("Z1.1000") }, "\(lines[start...firstXY])")

    // Check-only: the same travel is reported as an error.
    zone.liftOver = nil
    project.document.keepOutZones = [zone]
    let ctx2 = CAMContext(document: project.document, tools: .seeded)
    let plain = try a.generate(in: ctx2) + b.generate(in: ctx2)
    let blocked = GCodeExporter.export(project: project, toolpaths: plain, profile: profile, jobName: "T", expected: .notChecked(because: "test"))
    #expect(blocked.issues.contains { $0.severity == .error && $0.message.contains("B rapids over keep-out zone") })
}

/// The footer's move home is a known path: a zone taller than Home Z between the last cut and
/// home is reported (check only) or lifted over (lift over). After a tool change the first XY
/// move happens above the tallest zone.
@Test(arguments: [ZZeroMode.materialTop, .spoilboard])
func keepOutHomeMoveIsCheckedAndLifted(mode: ZZeroMode) throws {
    var project = AppTestSupport.project() // 2x1 rectangles at (1,1) and (5,1)
    project.document.job.zZero = mode
    let ids = project.document.shapes.map(\.id)
    let tool = ToolLibrary.seeded.tools[0].id
    let b = AnyOperation.profile(ProfileOperation(setup: OperationSetup(name: "B", toolID: tool, shapeIDs: [ids[1]])))
    // Between the right rectangle and home (0,0); 1 in tall, Home Z is 0.8.
    var zone = KeepOutZone(name: "HomeClamp", outline: [Vec2(3.4, -1), Vec2(4.6, -1), Vec2(4.6, 3), Vec2(3.4, 3)],
                           height: 1)
    project.document.keepOutZones = [zone]
    let profile = BuiltInPosts.avidMach4Inch
    let ctx = CAMContext(document: project.document, tools: .seeded)
    let plain = try b.generate(in: ctx)
    let blocked = GCodeExporter.export(project: project, toolpaths: plain, profile: profile, jobName: "T", expected: .notChecked(because: "test"))
    #expect(blocked.issues.contains { $0.severity == .error && $0.message.contains(GCodeExporter.homeMoveName) },
            "\(blocked.issues)")
    // A low zone (below Home Z) is fine.
    var low = zone
    low.height = 0.5
    project.document.keepOutZones = [low]
    let ok = GCodeExporter.export(project: project, toolpaths: plain, profile: profile, jobName: "T", expected: .notChecked(because: "test"))
    #expect(!ok.issues.contains { $0.message.contains(GCodeExporter.homeMoveName) }, "\(ok.issues)")

    zone.liftOver = true
    project.document.keepOutZones = [zone]
    let ctx2 = CAMContext(document: project.document, tools: .seeded)
    let tps = try b.generate(in: ctx2)
    let lifted = GCodeExporter.export(project: project, toolpaths: tps, profile: profile, jobName: "T", expected: .notChecked(because: "test"))
    #expect(!lifted.issues.contains { $0.message.contains("keep-out") }, "\(lifted.issues)")
    let text = try #require(lifted.text)
    let lines = text.split(separator: "\n").map(String.init)
    let clear = MachineCoordinates(job: project.document.job).z(aboveTop: 1.1)
    let clearText = "Z" + String(format: "%.4f", clear)
    // End of program: climbs to the clearance height before the first move to X0 Y0.
    let start = try #require(lines.lastIndex { $0.contains("Toolpath: B") })
    let home = try #require(lines[start...].firstIndex { !$0.hasPrefix("(") && $0.contains("X0.0000") })
    #expect(lines[start..<home].contains { $0.contains(clearText) }, "\(lines[start...home])")
    // After the tool change: up to the clearance height, then across.
    let m6 = try #require(lines.firstIndex { $0.contains("M6") })
    let firstXY = try #require(lines[m6...].firstIndex { !$0.hasPrefix("(") && $0.contains("X") })
    #expect(lines[m6..<firstXY].contains { $0.contains(clearText) }, "\(lines[m6...firstXY])")
    #expect(!lines[firstXY].contains("Z"), "\(lines[firstXY])")
}

/// The lifted move home of `keepOutHomeMoveIsCheckedAndLifted`, pinned from the code before #132: modelling the footer
/// from its moves must not change a built-in post's output.
@Test(arguments: [ZZeroMode.materialTop, .spoilboard])
func keepOutHomeLiftIsPinned(mode: ZZeroMode) throws {
    var project = AppTestSupport.project()
    project.document.job.zZero = mode
    let ids = project.document.shapes.map(\.id)
    let tool = ToolLibrary.seeded.tools[0].id
    let b = AnyOperation.profile(ProfileOperation(setup: OperationSetup(name: "B", toolID: tool, shapeIDs: [ids[1]])))
    project.document.keepOutZones = [KeepOutZone(name: "HomeClamp", outline: [Vec2(3.4, -1), Vec2(4.6, -1), Vec2(4.6, 3),
                                                                               Vec2(3.4, 3)], height: 1, liftOver: true)]
    let ctx = CAMContext(document: project.document, tools: .seeded)
    let result = GCodeExporter.export(project: project, toolpaths: try b.generate(in: ctx),
                                      profile: BuiltInPosts.avidMach4Inch, jobName: "T", expected: .notChecked(because: "test"))
    let lines = try #require(result.text).split(separator: "\n").map(String.init)
    let start = try #require(lines.lastIndex { $0.contains("Toolpath: B") })
    let pinned: [ZZeroMode: [String]] = [
        .materialTop: ["G2 X7.0000 Y0.8750 I-0.1250 J0.0000", "G1 X5.0000", "G2 X4.8770 Y0.9778 I0.0000 J0.1250", "G0 Z0.2000",
                       "Z0.8000", "Z1.1000", "X0.0000 Y0.0000", "Z0.8000", "G0 Z0.8000", "M5", "G0 X0.0000 Y0.0000", "M30"],
        .spoilboard: ["G2 X7.0000 Y0.8750 I-0.1250 J0.0000", "G1 X5.0000", "G2 X4.8770 Y0.9778 I0.0000 J0.1250", "G0 Z0.9500",
                      "Z1.5500", "Z1.8500", "X0.0000 Y0.0000", "Z1.5500", "G0 Z1.5500", "M5", "G0 X0.0000 Y0.0000", "M30"],
    ]
    #expect(Array(lines[start...].suffix(12)) == pinned[mode] ?? [], "\(Array(lines[start...].suffix(12)))")
}

/// A custom footer's moves are checked as the machine makes them, a G28 intermediate move included (#132).
enum FooterTravelExport {
    /// Avid Mach4 with a footer that goes to Home Z, then `G28 X6 Y6`: a rapid from about (4.9, 1) to (6, 6) at Home Z.
    static let g28Post: PostProfile = {
        var p = BuiltInPosts.avidMach4Inch
        p.footer = ["G0 Z{HOME_Z}", "M5", "G28 X6 Y6", "M30"]
        return p
    }()
    /// Across the G28 move only (not the straight way home to X0 Y0), 1 in tall: above Home Z (0.8).
    static let across = [Vec2(4, 3.5), Vec2(8, 3.5), Vec2(8, 4.5), Vec2(4, 4.5)]
    static let warning = "Keep-out zones and clamps are not checked from the footer's line \"G28 X6 Y6\" on: "
        + "LoftLine cannot tell where the machine goes from there."

    static func export(_ project: LoftLineProject, profile: PostProfile = g28Post) throws -> GCodeExportResult {
        let ids = project.document.shapes.map(\.id)
        let b = AnyOperation.profile(ProfileOperation(setup: OperationSetup(name: "B", toolID: ToolLibrary.seeded.tools[0].id,
                                                                            shapeIDs: [ids[1]])))
        let tps = try b.generate(in: CAMContext(document: project.document, tools: .seeded))
        return GCodeExporter.export(project: project, toolpaths: tps, profile: profile, jobName: "T", expected: .notChecked(because: "test"))
    }

    static func project(_ mode: ZZeroMode) -> LoftLineProject {
        var p = AppTestSupport.project()
        p.document.job.zZero = mode
        return p
    }
}

@Test(arguments: [ZZeroMode.materialTop, .spoilboard])
func aKeepOutZoneOnTheFootersG28MoveIsAnError(mode: ZZeroMode) throws {
    var project = FooterTravelExport.project(mode)
    project.document.keepOutZones = [KeepOutZone(name: "Jig", outline: FooterTravelExport.across, height: 1)]
    let r = try FooterTravelExport.export(project)
    #expect(r.issues.contains { $0.severity == .error && $0.message.contains("\(GCodeExporter.homeMoveName) rapids over keep-out zone \"Jig\"") },
            "\(r.issues)")
    #expect(r.issues.contains { $0.severity == .warning && $0.message == FooterTravelExport.warning }, "\(r.issues)")
}

@Test(arguments: [ZZeroMode.materialTop, .spoilboard])
func aClampOnTheFootersG28MoveIsAnError(mode: ZZeroMode) throws {
    var project = FooterTravelExport.project(mode)
    let layer = FixtureCommands.keepOutLayer(named: "Clamps", height: 1, in: &project)
    project.document.add(AppTestSupport.rect(4, 3.5, 4, 1, layer: layer))
    let r = try FooterTravelExport.export(project)
    #expect(r.issues.contains {
        $0.severity == .error && $0.message.contains(GCodeExporter.homeMoveName)
            && $0.message.hasSuffix("raise Home Z or change the post's footer")
    }, "\(r.issues)")
    #expect(r.issues.contains { $0.message == FooterTravelExport.warning }, "\(r.issues)")
}

@Test(arguments: [ZZeroMode.materialTop, .spoilboard])
func aLiftOverZoneOnTheFootersG28MoveIsCrossedAboveIt(mode: ZZeroMode) throws {
    var project = FooterTravelExport.project(mode)
    project.document.keepOutZones = [KeepOutZone(name: "Jig", outline: FooterTravelExport.across, height: 1, liftOver: true)]
    let r = try FooterTravelExport.export(project)
    #expect(!r.issues.contains { $0.message.contains("keep-out") || $0.message.contains("clamp '") }, "\(r.issues)")
    let lines = try #require(r.text).split(separator: "\n").map(String.init)
    let g28 = try #require(lines.firstIndex(of: "G28 X6 Y6"))
    let clear = "Z" + String(format: "%.4f", MachineCoordinates(job: project.document.job).z(aboveTop: 1.1))
    let start = try #require(lines.lastIndex { $0.contains("Toolpath: B") })
    #expect(lines[start..<g28].contains { $0.contains(clear) }, "\(lines[start...g28])")
    #expect(lines[start..<g28].contains("X6.0000 Y6.0000"), "\(lines[start...g28])")
}

@Test func theFooterWarningNeedsAZoneOrAClamp() throws {
    let r = try FooterTravelExport.export(FooterTravelExport.project(.materialTop))
    #expect(!r.issues.contains { $0.message.contains("not checked from the footer") }, "\(r.issues)")
}

/// Home Z below safe Z (a project not edited through Job Setup): the footer goes down to Home Z where the last cut
/// ended and crosses at Home Z, which the check used to look at from safe Z.
@Test(arguments: [ZZeroMode.materialTop, .spoilboard])
func aBuiltInFooterBelowSafeZIsCheckedWhereItCrosses(mode: ZZeroMode) throws {
    var project = FooterTravelExport.project(mode)
    project.document.job.safeZ = 0.5
    project.document.job.homeZ = 0.1
    project.document.keepOutZones = [KeepOutZone(name: "Low", outline: [Vec2(3.4, -1), Vec2(4.6, -1), Vec2(4.6, 3),
                                                                         Vec2(3.4, 3)], height: 0.3)]
    let r = try FooterTravelExport.export(project, profile: BuiltInPosts.avidMach4Inch)
    #expect(r.issues.contains { $0.severity == .error && $0.message.contains("\(GCodeExporter.homeMoveName) rapids over keep-out zone \"Low\"") },
            "\(r.issues)")
    #expect(!r.issues.contains { $0.message.contains("not checked from the footer") }, "\(r.issues)")
}

/// A footer feed move is checked where it goes, and never routed: lift-over routing would turn it into a rapid.
@Test(arguments: [ZZeroMode.materialTop, .spoilboard])
func aFootersFeedMoveIsCheckedAndNotRouted(mode: ZZeroMode) throws {
    var project = FooterTravelExport.project(mode)
    var post = BuiltInPosts.avidMach4Inch
    post.footer = ["G0 Z{HOME_Z}", "G1 X6 Y6 F50", "M30"]
    for lift in [nil, true] as [Bool?] {
        project.document.keepOutZones = [KeepOutZone(name: "Jig", outline: FooterTravelExport.across, height: 1, liftOver: lift)]
        let r = try FooterTravelExport.export(project, profile: post)
        #expect(r.issues.contains { $0.severity == .error && $0.message.contains("\(GCodeExporter.homeMoveName) cuts into keep-out zone \"Jig\"") },
                "\(lift as Any): \(r.issues)")
        #expect(!r.issues.contains { $0.message.contains("not checked from the footer") }, "\(r.issues)")
    }
}

/// A program whose first toolpath starts over a lift-over clamp: the written G-code never has the tool over the clamp
/// (grown by the tool radius) below its top. The router used to keep the opening move as it was, so after the post
/// arrived above the clamp the tool came down into it and lifted straight up there (`docs/implicit-state-machines.md` #6).
@Test(arguments: [ZZeroMode.materialTop, .spoilboard])
func aProgramThatStartsOverALiftOverClampStaysAboveIt(mode: ZZeroMode) throws {
    var project = AppTestSupport.project() // 2x1 rectangles at (1,1) and (5,1)
    project.document.job.zZero = mode
    let tool = ToolLibrary.seeded.tools[0]
    let op = AnyOperation.profile(ProfileOperation(setup: OperationSetup(name: "A", toolID: tool.id,
                                                                         shapeIDs: [project.document.shapes[0].id])))
    let coords = MachineCoordinates(job: project.document.job)
    // A 0.4 in clamp centred on where the profile starts (and, closed, ends): 0.5 in tall, above safe Z (0.2) and below
    // Home Z (0.8), so the footer's move home is not part of this.
    let bare = try op.generate(in: CAMContext(document: project.document, tools: .seeded))
    let start = coords.materialXY(fromMachine: try #require(bare.first?.moves.first(where: { $0.target != nil })?.target).xy)
    let outline = [Vec2(-0.2, -0.2), Vec2(0.2, -0.2), Vec2(0.2, 0.2), Vec2(-0.2, 0.2)].map { $0 + start }
    project.document.keepOutZones = [KeepOutZone(name: "Clamp", outline: outline, height: 0.5, liftOver: true)]
    let tps = try op.generate(in: CAMContext(document: project.document, tools: .seeded))
    let result = GCodeExporter.export(project: project, toolpaths: tps, profile: BuiltInPosts.avidMach4Inch, jobName: "T", expected: .notChecked(because: "test"))
    #expect(!result.issues.contains { $0.message.contains("keep-out") }, "\(result.issues)")
    let text = try #require(result.text)

    // Every position the program moves through (end points, and straight moves sampled), in machine coordinates.
    let grown = GeomKernel.offset([outline.map { coords.machineXY($0) }], by: tool.radius, join: .round, arcTolerance: 0.0005)
    let top = coords.z(aboveTop: 0.5)
    var pos: Vec3?
    var low: [String] = []
    for line in text.split(separator: "\n").map(String.init) where !line.hasPrefix("(") {
        func word(_ c: Character) -> Double? {
            guard let r = line.range(of: "\(c)-?[0-9.]+", options: .regularExpression) else { return nil }
            return Double(line[r].dropFirst())
        }
        let (x, y, z) = (word("X"), word("Y"), word("Z"))
        guard x != nil || y != nil || z != nil, !line.contains("G53"), !line.contains("G28") else { continue }
        guard let from = pos else {
            if let x, let y, let z { pos = Vec3(x, y, z) } else if let z { pos = Vec3(0, 0, z) }
            continue
        }
        let to = Vec3(x ?? from.x, y ?? from.y, z ?? from.z)
        for i in 0...20 {
            let t = Double(i) / 20
            let p = Vec3(from.xy.lerp(to: to.xy, t), z: from.z + (to.z - from.z) * t)
            if p.z < top - 1e-6, Polygon2D.regionContains(grown, p.xy) { low.append(line); break }
        }
        pos = to
    }
    #expect(low.isEmpty, "\(low)")
}
