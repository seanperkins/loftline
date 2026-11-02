import AppKit
import CADCore
import CAMCore
import Foundation
import SwiftUI
import Testing
@testable import LoftLineApp

@MainActor
@Test func gcodePreviewReadsTheSampleProgram() throws {
    let url = SampleFilesTests.samplesDir.appendingPathComponent("sign.tap")
    let text = try String(contentsOf: url, encoding: .utf8)
    let job = JobSetup(width: 24, height: 12, thickness: 0.75)
    let model = GCodePreviewModel(text: text, fileName: "sign.tap", units: .inch, job: job)
    // T1 pocket, T6 V-carve, T9 drill, T1 profile.
    #expect(model.tools.map(\.tool.number) == [1, 6, 9, 1])
    #expect(model.tools[1].tool.kind == .vBit)
    #expect(model.tools[2].tool.kind == .drill)
    #expect(model.reader.warnings.isEmpty)
    let tps = model.toolpaths
    #expect(tps.count == 4)
    let coords = MachineCoordinates(job: job)
    // The profile cuts through the 0.75" material (plus allowance) and nothing goes above the home Z.
    let deepest = tps.compactMap(\.minZ).min()!
    #expect(coords.depth(ofMachineZ: deepest) >= 0.75 - 1e-6)
    // Renders without crashing.
    let view = NSHostingView(rootView: GCodePreviewView(model: model, job: job, rapidRate: 300))
    view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
    view.layoutSubtreeIfNeeded()
    #expect(view.fittingSize.width > 0)
}

@Test func gcodePreviewUsesMillimetreDocumentsToo() {
    let text = "G20\nG90\nT3 M6\nS16000 M3\nG0 X1 Y1 Z0.2\nG1 Z-0.1 F20\nX2 F60\nG0 Z0.2\nM30\n"
    let job = JobSetup(width: 100, height: 100, thickness: 18)
    let model = GCodePreviewModel(text: text, fileName: "x.tap", units: .millimeter, job: job)
    #expect(model.tools.count == 1 && model.tools[0].tool.diameter == 6)
    let tp = model.toolpaths[0]
    #expect(abs((tp.minZ ?? 0) + 2.54) < 1e-9)
    #expect(tp.spindleRPM == 16000)
    #expect(model.summary.contains("inches"))
}

// MARK: - Stop tool changes (#126)

private func preview(_ text: String) -> GCodePreviewModel {
    GCodePreviewModel(text: text, fileName: "x.nc", units: .inch, job: JobSetup(width: 24, height: 12, thickness: 0.75))
}

@Test func aStopToolChangeProgramPreviewsEachToolFromTheHeader() throws {
    let url = SampleFilesTests.samplesDir.appendingPathComponent("expected/generic-grbl-inch/sign.nc")
    let model = preview(try String(contentsOf: url, encoding: .utf8))
    #expect(model.tools.map(\.tool.number) == [1, 6, 9, 1])
    #expect(model.tools.map(\.label) == ["T1 – 1/4\" End Mill [2 flute]", "T6 – 60 deg V-Bit 1/2\"", "T9 – 1/4\" Drill",
                                         "T1 – 1/4\" End Mill [2 flute]"])
    #expect(model.tools[1].tool.kind == .vBit && model.tools[2].tool.kind == .drill)
    #expect(model.toolpaths.map(\.spindleRPM) == [18000, 18000, 12000, 18000])
}

@Test func aToolChangeWithNoNumberIsLabelledAToolChange() {
    let moves = "G0 X0 Y0 Z1\nG1 Z-0.1 F10\n"
    #expect(preview("G20\n" + moves + "(Change to Tool: B)\nM0\n" + moves).tools.map(\.label) == ["No tool change", "Tool change – B"])
    #expect(preview("G20\n" + moves + "(Change to Tool:)\nM0\n" + moves).tools.map(\.label) == ["No tool change", "Tool change"])
    #expect(preview("G20\n" + moves + "(C)\nM6\n" + moves).tools.map(\.label) == ["No tool change", "Tool change – C"])
    #expect(preview("G20\n" + moves + "M6\n" + moves).tools.map(\.label) == ["No tool change", "Tool change"])
}

/// Two tools may share a number (same geometry, a warning): each stop finds its own row by name.
@Test func twoToolsOnOneNumberEachKeepTheirOwnHeaderRow() {
    let text = "( Tools: )\n(   T1: Rough - End Mill, dia 0.2500 in )\n(   T1: Drill - Drill, dia 0.2500 in )\nG20\n"
        + "(Change to Tool: Rough)\nM0\nG0 X0 Y0 Z1\nG1 Z-0.1 F10\n(Change to Tool: Drill)\nM0\nG0 X1 Y1 Z1\nG1 Z-0.1 F10\n"
    let model = preview(text)
    #expect(model.tools.map(\.label) == ["T1 – Rough", "T1 – Drill"])
    #expect(model.tools.map(\.tool.kind) == [.endMill, .drill])
}
