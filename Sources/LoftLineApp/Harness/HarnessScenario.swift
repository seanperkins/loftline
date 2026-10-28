#if DEBUG
import Foundation

struct HarnessError: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}

/// A scripted run of the UI harness: an appearance, a window size and a list of steps, ending in
/// `capture` steps that write PNGs and text dumps, or wrapped in `record` / `endRecord` to write the
/// frames of a clip. Debug builds only. See `UIHarness` and `docs/UI-HARNESS.md`.
struct HarnessScenario: Decodable {
    struct Step: Decodable {
        var op: String
        /// A file stem (capture, captureSheet, menus, record), a sample name, or a shape / toolpath / control name.
        var name: String?
        /// An enumerated value: a mode, tab, sheet, tool, appearance, key, view direction; or text to type or show.
        var value: String?
        /// Shape names to select.
        var names: [String]?
        /// Width and height in points (size), or a window point with the origin top left (pointer).
        var size: [Double]?
        var seconds: Double?
        /// Frames per second for `record`.
        var fps: Double?
    }

    var name: String?
    /// "light", "dark" or "system" (the default).
    var appearance: String?
    /// Content size of the document window, in points.
    var window: [Double]?
    var steps: [Step]

    static let modes: Set<String> = ["2d", "split", "3d"]
    static let tabs: Set<String> = ["design", "toolpaths"]
    static let appearances: Set<String> = ["light", "dark", "system"]
    static let samples: Set<String> = ["sign"]
    static let views: Set<String> = ["threeQuarter", "iso", "top", "front", "back", "left", "right", "bottom"]
    static let keys: [String: (code: UInt16, chars: String, command: Bool)] = [
        "escape": (53, "\u{1b}", false), "return": (36, "\r", false), "tab": (48, "\t", false), "space": (49, " ", false),
        "delete": (51, "\u{7f}", false), "selectAll": (0, "a", true),
    ]
    static let sheets: Set<String> = [
        "jobSetup", "exportGCode", "saveAllToolpaths", "postProcessors", "validation", "keepOutZones", "nesting", "fixtures",
        "tiling", "partLabels", "variables", "productionPlates", "offset", "joinVectors", "inlayWizard",
    ]

    /// Each op and what it needs; `capture` and friends write `<name>.png` and `<name>.ax.txt`.
    static let ops: [String: String] = [
        "sample": "name: load a sample project (sign)",
        "project": "name: load a .loftline project file, relative to the repo root (scripts/ui.sh runs from there); harness/projects/ holds variants of the sample",
        "appearance": "value: light | dark | system",
        "size": "size: [w, h] content size of the window",
        "mode": "value: 2d | split | 3d",
        "fit": "zoom the 2D canvas to the material, or to the selection with value: selection",
        "tab": "value: design | toolpaths",
        "tool": "value: a canvas tool such as select, rectangle, nodeEdit",
        "select": "names: shapes to select by name",
        "selectToolpath": "name: a toolpath to select (also shows the Toolpaths tab)",
        "calculate": "calculate all toolpaths and wait",
        "captureWindow": "value: the title of a window other than the document's (Tool Database), opened first with press on its toolbar button; name: file stem, as <name>.png and <name>.ax.txt",
        "selectTool": "name: a tool to select in the open Tool Database window (by its name)",
        "searchTools": "value: the text to put in the open Tool Database window's search field (empty clears it)",
        "editToolpath": "value: deeper | tabs; name: the toolpath (default the first); deeper cuts a profile or pocket 0.5 below the material bottom, tabs turns on tabs as tall as a profile's cut; the toolpath form shows its warnings",
        "editTool": "value: diameter | rename | number | describe | rpm; edits the tool of the first toolpath in the Tool Database, as that window does while a sheet is open (diameter makes the toolpaths stale, rename only relabels them, number gives it another library tool's T number, describe gives it a description, rpm gives it a spindle speed no post runs)",
        "fileTarget": "name: the path that Export G-code, Save All Toolpaths and Save Tiled G-code answer their save or folder panel with, until closeSheet or an empty fileTarget (the system file panel cannot be driven)",
        "sheet": "value: " + sheets.sorted().joined(separator: " | "),
        "closeSheet": "close the open sheet or alert",
        "import": "name: a file to import as File > Import does, relative to the repo root (scripts/ui.sh runs from there). An import alert stays open until a closeSheet step",
        "press": "name: click the first control whose label, title, help or id contains this text; value: optional role such as AXButton. Does not toggle disclosure groups: use expand",
        "move": "name: move the pointer onto a control without clicking (value: optional role); shows in recordings",
        "pointer": "size: [x, y] a point from the window's top left to move the pointer to (a negative x or y counts from the right or bottom edge); value: click to click there, sheet / sheetClick to measure from the open sheet instead",
        "type": "value: text typed one key at a time into the focused field (press the field first)",
        "scroll": "name: scroll the enclosing scroll view so this control sits in the middle (value: optional role)",
        "key": "value: " + keys.keys.sorted().joined(separator: " | ") + ", sent to the open sheet (or the window)",
        "expand": "name: open a collapsible inspector section by its title (Last Pass, Ramps, Array Copies...)",
        "wait": "seconds: let the UI settle",
        "capture": "name: the window as <name>.png, its accessibility tree as <name>.ax.txt",
        "still": "name: one composed frame (window with its sheet, pointer and caption) as <name>.png, no tree",
        "captureSheet": "name: the open sheet as <name>.png and <name>.ax.txt",
        "menus": "name: the menu bar (titles, enabled state, key equivalents) as <name>.menus.txt",
        "record": "name: start recording the window (sheet, pointer and caption included) as <name>.frames/ and <name>.ffconcat; fps: frames per second (default 10)",
        "endRecord": "stop the recording and write its frame list",
        "caption": "value: text shown along the bottom of recorded frames (empty to clear)",
        "simulate": "seconds: scrub the 3D simulation from start to end over this many seconds (default 6); value: a fraction such as 0.6 jumps straight to that point of the job instead; needs mode 3d or split",
        "view": "value: a 3D view direction: " + views.sorted().joined(separator: " | "),
    ]

    static func parse(_ data: Data) throws -> HarnessScenario {
        let scenario: HarnessScenario
        do { scenario = try JSONDecoder().decode(HarnessScenario.self, from: data) } catch {
            throw HarnessError(message: "The scenario is not valid JSON of the expected shape: \(error)")
        }
        if let a = scenario.appearance, !appearances.contains(a) {
            throw HarnessError(message: "appearance must be light, dark or system, not \"\(a)\"")
        }
        if let w = scenario.window, w.count != 2 || w.contains(where: { $0 <= 0 }) {
            throw HarnessError(message: "window must be [width, height] in points")
        }
        for (i, step) in scenario.steps.enumerated() {
            try validate(step, at: i + 1)
        }
        return scenario
    }

    private static func validate(_ step: Step, at n: Int) throws {
        func fail(_ text: String) -> HarnessError { HarnessError(message: "step \(n) (\(step.op)): \(text)") }
        guard ops[step.op] != nil else {
            throw HarnessError(message: "step \(n): unknown op \"\(step.op)\". Valid ops: " + ops.keys.sorted().joined(separator: ", "))
        }
        switch step.op {
        case "sample":
            guard let n = step.name, samples.contains(n) else { throw fail("name must be one of \(samples.sorted())") }
        case "appearance":
            guard let v = step.value, appearances.contains(v) else { throw fail("value must be light, dark or system") }
        case "size":
            guard let s = step.size, s.count == 2, s.allSatisfy({ $0 > 0 }) else { throw fail("size must be [width, height]") }
        case "pointer":
            guard let s = step.size, s.count == 2 else { throw fail("size must be [x, y] in window points") }
        case "mode":
            guard let v = step.value, modes.contains(v) else { throw fail("value must be 2d, split or 3d") }
        case "tab":
            guard let v = step.value, tabs.contains(v) else { throw fail("value must be design or toolpaths") }
        case "tool":
            guard step.value?.isEmpty == false else { throw fail("value must name a tool") }
        case "select":
            guard let names = step.names, !names.isEmpty else { throw fail("names must list the shapes to select") }
        case "selectToolpath":
            guard step.name?.isEmpty == false else { throw fail("name must name a toolpath") }
        case "editTool":
            guard let v = step.value, ["diameter", "rename", "number", "describe", "rpm"].contains(v) else { throw fail("value must be diameter, rename, number, describe or rpm") }
        case "editToolpath":
            guard let v = step.value, ["deeper", "tabs"].contains(v) else { throw fail("value must be deeper or tabs") }
        case "captureWindow":
            guard step.name?.isEmpty == false, step.value?.isEmpty == false else { throw fail("name is the file stem and value the window's title") }
        case "selectTool":
            guard step.name?.isEmpty == false else { throw fail("name must be the tool's name") }
        case "searchTools":
            break
        case "sheet":
            guard let v = step.value, sheets.contains(v) else { throw fail("value must be one of \(sheets.sorted())") }
        case "press", "move", "scroll":
            guard step.name?.isEmpty == false else { throw fail("name must say which control to \(step.op)") }
        case "type":
            guard step.value?.isEmpty == false else { throw fail("value must be the text to type") }
        case "key":
            guard let v = step.value, keys[v] != nil else { throw fail("value must be one of \(keys.keys.sorted())") }
        case "expand":
            guard step.name?.isEmpty == false else { throw fail("name must be the section's title") }
        case "import":
            guard step.name?.isEmpty == false else { throw fail("name must be the path of the file to import") }
        case "project":
            guard step.name?.isEmpty == false else { throw fail("name must be the path of a .loftline file") }
        case "wait":
            guard let s = step.seconds, s >= 0 else { throw fail("seconds is required") }
        case "capture", "captureSheet", "menus", "record", "still":
            guard step.name?.isEmpty == false else { throw fail("name is required (the output file name)") }
            if step.op == "record", let f = step.fps, f <= 0 || f > 30 { throw fail("fps must be between 1 and 30") }
        case "view":
            guard let v = step.value, views.contains(v) else { throw fail("value must be one of \(views.sorted())") }
        case "simulate":
            if let s = step.seconds, s <= 0 { throw fail("seconds must be positive") }
        default:
            break
        }
    }

    /// A name made safe to use as a file name inside the output folder.
    static func fileStem(_ name: String) -> String {
        let pieces = name.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }).map(String.init)
        let stem = pieces.joined(separator: "-")
        return stem.isEmpty ? "capture" : stem
    }
}
#endif
