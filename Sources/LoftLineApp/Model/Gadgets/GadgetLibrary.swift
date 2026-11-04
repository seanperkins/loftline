import CADCore
import Foundation
import LoftLineKit

/// Gadgets offered in the Gadgets menu: the built-in examples plus every `.js` file in
/// `~/Library/Application Support/LoftLine/Gadgets/`.
final class GadgetLibrary: ObservableObject {
    static let shared = GadgetLibrary()

    let directory: URL
    @Published private(set) var gadgets: [GadgetScript] = []
    /// Header problems per gadget id (shown in the run dialog).
    @Published private(set) var problems: [String: [String]] = [:]

    init(directory: URL = ToolLibraryStore.supportDirectory.appendingPathComponent("Gadgets", isDirectory: true)) {
        self.directory = directory
        reload()
    }

    var builtIn: [GadgetScript] { gadgets.filter { $0.origin == .builtIn } }
    var user: [GadgetScript] { gadgets.filter { $0.origin != .builtIn } }

    func reload() {
        var list: [GadgetScript] = []
        var probs: [String: [String]] = [:]
        for (name, source) in BuiltInGadgets.all {
            let (g, p) = GadgetScript.parse(source: source, fallbackName: name, origin: .builtIn)
            list.append(g)
            if !p.isEmpty { probs[g.id] = p }
        }
        for url in Self.scriptFiles(in: directory) {
            guard let g = Self.load(url) else { continue }
            list.append(g.script)
            if !g.problems.isEmpty { probs[g.script.id] = g.problems }
        }
        gadgets = list
        problems = probs
    }

    static func load(_ url: URL) -> (script: GadgetScript, problems: [String])? {
        guard let data = try? Data(contentsOf: url), let source = String(data: data, encoding: .utf8) else { return nil }
        return GadgetScript.parse(source: source, fallbackName: url.deletingPathExtension().lastPathComponent,
                                  origin: .file(url))
    }

    /// `.js` files directly in `dir`, sorted by name.
    static func scriptFiles(in dir: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "js" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Creates the folder with the API reference and an editable example the first time.
    func prepareFolder() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let readme = directory.appendingPathComponent("README.txt")
        try? GadgetAPI.reference.data(using: .utf8)?.write(to: readme)
        let example = directory.appendingPathComponent("Example - Hole Grid.js.sample")
        if !fm.fileExists(atPath: example.path), let src = BuiltInGadgets.all.first?.source {
            try? src.data(using: .utf8)?.write(to: example)
        }
    }
}

/// Example gadgets that ship with LoftLine (also the starting point for writing your own).
enum BuiltInGadgets {
    static let all: [(name: String, source: String)] = [
        ("Hole Grid", holeGrid), ("Frame Selection", frameSelection), ("Rosette", rosette),
    ]

    static let holeGrid = """
    // @name Hole Grid
    // @description Draws a grid of circles (e.g. shelf-pin or spoilboard holes) and can add a drilling toolpath for them.
    // @param columns integer 4 "Columns"
    // @param rows integer 3 "Rows"
    // @param pitchX length 2 "Spacing X"
    // @param pitchY length 2 "Spacing Y"
    // @param diameter length 0.25 "Hole diameter"
    // @param x length 1 "First hole X"
    // @param y length 1 "First hole Y"
    // @param drill bool true "Add a drilling toolpath"
    // @param depth length 0.5 "Drill depth"
    var p = loftline.params;
    if (p.columns < 1 || p.rows < 1) throw new Error("Columns and rows must be at least 1");
    if (p.diameter <= 0) throw new Error("Hole diameter must be more than zero");
    var layer = loftline.layer("Holes", "#D0312D");
    var ids = [];
    for (var r = 0; r < p.rows; r++) {
      for (var c = 0; c < p.columns; c++) {
        ids.push(loftline.circle(p.x + c * p.pitchX, p.y + r * p.pitchY, p.diameter / 2,
                             { layer: layer, name: "Hole " + (r + 1) + "-" + (c + 1) }));
      }
    }
    if (p.drill) loftline.addToolpath("drill", ids, { name: "Hole Grid Drilling", depth: p.depth });
    loftline.select(ids);
    loftline.log("Drew " + ids.length + " holes.");
    """

    static let frameSelection = """
    // @name Frame Selection
    // @description Draws a (rounded) rectangle around the selected vectors with a margin, optionally with an outside profile cut through the material.
    // @needs-selection
    // @param margin length 0.5 "Margin"
    // @param radius length 0.25 "Corner radius"
    // @param profile bool true "Add an outside profile toolpath"
    var sel = loftline.selection();
    if (sel.length === 0) throw new Error("Select the vectors to frame first");
    var b = { minX: Infinity, minY: Infinity, maxX: -Infinity, maxY: -Infinity };
    sel.forEach(function (s) {
      b.minX = Math.min(b.minX, s.bounds.minX); b.minY = Math.min(b.minY, s.bounds.minY);
      b.maxX = Math.max(b.maxX, s.bounds.maxX); b.maxY = Math.max(b.maxY, s.bounds.maxY);
    });
    var m = loftline.params.margin;
    var id = loftline.rectangle(b.minX - m, b.minY - m, b.maxX - b.minX + 2 * m, b.maxY - b.minY + 2 * m,
                            { cornerRadius: loftline.params.radius, name: "Frame" });
    if (loftline.params.profile) {
      loftline.addToolpath("profile", [id], { name: "Frame Cut-Out", side: "outside", depth: loftline.material.thickness });
    }
    loftline.select([id]);
    """

    static let rosette = """
    // @name Rosette
    // @description Draws copies of a polygon or star rotated evenly about a centre point (default: the middle of the material).
    // @param shape choice star|polygon "Shape"
    // @param copies integer 6 "Copies"
    // @param points integer 5 "Points / sides"
    // @param radius length 2 "Outer radius"
    // @param inner length 0.8 "Star inner radius"
    // @param offset length 1 "Distance from centre"
    var p = loftline.params;
    if (p.copies < 1) throw new Error("Copies must be at least 1");
    var cx = loftline.material.width / 2, cy = loftline.material.height / 2;
    var ids = [];
    for (var i = 0; i < p.copies; i++) {
      var a = i * 2 * Math.PI / p.copies;
      var x = cx + p.offset * Math.cos(a), y = cy + p.offset * Math.sin(a);
      var rot = a * 180 / Math.PI;
      ids.push(p.shape === "star"
        ? loftline.star(x, y, p.radius, p.inner, p.points, { rotation: rot })
        : loftline.polygon(x, y, p.radius, p.points, { rotation: rot }));
    }
    loftline.select(ids);
    """
}
