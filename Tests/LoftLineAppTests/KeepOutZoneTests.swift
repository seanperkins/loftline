import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp

@Test func keepOutZonesBlockExportOfToolpathsThatHitThem() throws {
    var project = AppTestSupport.project() // 2x1 rectangles at (1,1) and (5,1)
    let ids = project.document.shapes.map(\.id)
    let op = AnyOperation.profile(ProfileOperation(setup: OperationSetup(name: "Cut", toolID: ToolLibrary.seeded.tools[0].id,
                                                                         shapeIDs: ids)))
    project.upsertOperation(op)
    let ctx = CAMContext(document: project.document, tools: .seeded)
    let tps = try op.generate(in: ctx)
    let profile = BuiltInPosts.avidMach4Inch
    let clean = GCodeExporter.export(project: project, toolpaths: tps, profile: profile, jobName: "T")
    #expect(!clean.issues.contains { $0.message.contains("keep-out") })
    // A clamp over the left end of the first rectangle.
    let clamp = KeepOutEditing.zones(from: [AppTestSupport.rect(0.5, 1.2, 0.8, 0.5, layer: project.document.defaultLayerID)],
                                     height: 1, tolerance: 0.0005, existing: 0)
    #expect(clamp.count == 1 && clamp[0].outline.count == 4)
    project.document.keepOutZones = clamp
    let blocked = GCodeExporter.export(project: project, toolpaths: tps, profile: profile, jobName: "T")
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
    let lifted = GCodeExporter.export(project: project, toolpaths: tps, profile: profile, jobName: "T")
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
    let blocked = GCodeExporter.export(project: project, toolpaths: plain, profile: profile, jobName: "T")
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
    let blocked = GCodeExporter.export(project: project, toolpaths: plain, profile: profile, jobName: "T")
    #expect(blocked.issues.contains { $0.severity == .error && $0.message.contains(GCodeExporter.homeMoveName) },
            "\(blocked.issues)")
    // A low zone (below Home Z) is fine.
    var low = zone
    low.height = 0.5
    project.document.keepOutZones = [low]
    let ok = GCodeExporter.export(project: project, toolpaths: plain, profile: profile, jobName: "T")
    #expect(!ok.issues.contains { $0.message.contains(GCodeExporter.homeMoveName) }, "\(ok.issues)")

    zone.liftOver = true
    project.document.keepOutZones = [zone]
    let ctx2 = CAMContext(document: project.document, tools: .seeded)
    let tps = try b.generate(in: ctx2)
    let lifted = GCodeExporter.export(project: project, toolpaths: tps, profile: profile, jobName: "T")
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
                                      profile: BuiltInPosts.avidMach4Inch, jobName: "T")
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
