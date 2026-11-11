import CADCore
import CAMCore
import Foundation
import LoftLineKit
import PostCore

/// set_job, add_shapes, edit_shapes, import_file, edit_layers (MCP spec, "The tools").
enum DesignTools {
    static let maxShapes = 200, maxPoints = 10_000, maxText = 1_000, maxImportBytes = 50 * 1_048_576

    static func all(service: CoreService, access: AssistantAccess) -> [AssistantTool] {
        let session = service.session
        let core = CoreClient(service: service)
        let point = Schema.object(["x": Schema.number("X"), "y": Schema.number("Y")], required: ["x", "y"])

        let setJob = AssistantTool(
            name: "set_job",
            description: "Changes Job Setup: units, material size, Z zero, XY origin, safe Z, home Z, name. A change of units converts "
                + "the job and the design first, as Job Setup does; sizes given in the same call are then in the new units.",
            inputSchema: Schema.object([
                "units": Schema.string("New units.", oneOf: ["inch", "millimeter"]),
                "width": Schema.number("Material width (X)."), "height": Schema.number("Material height (Y)."),
                "thickness": Schema.number("Material thickness."),
                "z_zero": Schema.string("Where Z0 is touched off.", oneOf: ZZeroMode.allCases.map(\.rawValue)),
                "xy_origin": Schema.string("Where X0 Y0 is on the material.", oneOf: XYOrigin.allCases.map(\.rawValue)),
                "safe_z": Schema.number("Rapid height above the material."), "home_z": Schema.number("Home height above the material."),
                "name": Schema.string("The job's name."),
            ])) { raw in
                let args = Args(raw)
                var form = JobSetupForm(project: session.project, machines: session.machines, profiles: session.profiles)
                if let word = args.string("units") {
                    guard let units = LengthUnit(word: word) else { throw ToolError("\"units\" is inch or millimeter.") }
                    if units != form.units { form.setUnits(units) }
                }
                if let v = args.double("width") { form.job.width = v }
                if let v = args.double("height") { form.job.height = v }
                if let v = args.double("thickness") { form.job.thickness = v }
                if let v = args.double("safe_z") { form.job.safeZ = v }
                if let v = args.double("home_z") { form.job.homeZ = v }
                if let v = args.string("z_zero") {
                    guard let z = ZZeroMode(rawValue: v) else { throw ToolError("Unknown z_zero \"\(v)\".") }
                    form.job.zZero = z
                }
                if let v = args.string("xy_origin") {
                    guard let o = XYOrigin(rawValue: v) else { throw ToolError("Unknown xy_origin \"\(v)\".") }
                    form.job.xyOrigin = o
                }
                if let v = args.string("name") { form.name = v }
                guard form.problems.isEmpty else { throw ToolError(form.problems.joined(separator: " ")) }
                session.perform("Job Setup") { $0 = form.apply(to: $0) }
                return Reply.output("Job Setup changed: \(ProjectTools.summaryLine(session)).")
            }

        let addShapes = AssistantTool(
            name: "add_shapes",
            description: "Draws up to 200 shapes in one change (one undo): rectangle, rounded_rectangle, circle, ellipse, polygon, star, "
                + "polyline and text. Positions and sizes are in the project's units, material frame (0,0 = the material's lower-left "
                + "corner). If any shape is wrong, none is added.",
            inputSchema: Schema.object([
                "shapes": Schema.array("The shapes.", of: Schema.object([
                    "type": Schema.string("Kind of shape.", oneOf: ["rectangle", "rounded_rectangle", "circle", "ellipse", "polygon", "star", "polyline", "text"]),
                    "x": Schema.number("Rectangle: lower-left X; circle, ellipse, polygon, star: centre X; text: start of the baseline."),
                    "y": Schema.number("As x, for Y."),
                    "width": Schema.number("Rectangle width."), "height": Schema.number("Rectangle height."),
                    "corner_radius": Schema.number("Rounded rectangle corner radius."),
                    "radius": Schema.number("Circle, polygon or star (outer) radius."),
                    "radius_x": Schema.number("Ellipse radius along X."), "radius_y": Schema.number("Ellipse radius along Y."),
                    "sides": Schema.integer("Polygon sides."), "points": [
                        "description": "Star: number of points. Polyline: the points, as [{x, y}].",
                        "anyOf": [["type": "integer"], ["type": "array", "items": point]],
                    ] as [String: Any],
                    "inner_ratio": Schema.number("Star inner radius as a share of the outer (0.05 to 0.95)."),
                    "closed": Schema.boolean("Polyline: close it."),
                    "text": Schema.string("Text: the words (up to 1,000 characters)."), "size": Schema.number("Text height."),
                    "font": Schema.string("Text font; the default font when left out."),
                    "align": Schema.string("Text alignment.", oneOf: ["left", "center", "right"]),
                ], required: ["type"])),
                "layer_id": Schema.string("The layer for every shape; the default layer when left out."),
            ], required: ["shapes"])) { raw in
                let args = Args(raw)
                let raw = args.array("shapes") ?? []
                let shapes = raw.compactMap { $0 as? [String: Any] }
                if let bad = raw.firstIndex(where: { !($0 is [String: Any]) }) { throw ToolError("Shape \(bad + 1) is not an object.") }
                guard !shapes.isEmpty else { throw ToolError("\"shapes\" is empty.") }
                guard shapes.count <= maxShapes else { throw ToolError("\(shapes.count) shapes is more than \(maxShapes) in one call.") }
                let layer = try args.uuid("layer_id")
                let items = try shapes.enumerated().map { try item(Args($0.element), number: $0.offset + 1, layer: layer) }
                let result = try core.call("addShapes", ["shapes": items])
                let ids = result["ids"] as? [String] ?? []
                return Reply.output("Added \(ids.count) shape\(ids.count == 1 ? "" : "s").", ["ids": ids])
            }

        let editShapes = AssistantTool(
            name: "edit_shapes",
            description: "One Design command on the given shapes, as one change: move (dx, dy), rotate (degrees), mirror (horizontally), "
                + "scale (factor, about their centre), align (mode), distribute (horizontally), group, ungroup, combine, break_apart, "
                + "join (tolerance), close, boolean (mode), offset (distance, sharp_corners), fillet (radius), chamfer (distance), "
                + "text_to_curves, to_layer (layer_id), delete.",
            inputSchema: Schema.object([
                "action": Schema.string("The command.", oneOf: ["move", "rotate", "mirror", "scale", "align", "distribute", "group", "ungroup",
                                                                 "combine", "break_apart", "join", "close", "boolean", "offset", "fillet",
                                                                 "chamfer", "text_to_curves", "to_layer", "delete"]),
                "ids": Schema.array("The shapes.", of: Schema.string("A shape id.")),
                "dx": Schema.number("move: X distance."), "dy": Schema.number("move: Y distance."),
                "degrees": Schema.number("rotate: counter-clockwise degrees."), "factor": Schema.number("scale: factor."),
                "horizontally": Schema.boolean("mirror, distribute: horizontally (else vertically)."),
                "mode": Schema.string("align: left, centerX, right, bottom, centerY, top, materialCenter; boolean: union, subtract, intersect."),
                "distance": Schema.number("offset (negative is inward), chamfer."), "radius": Schema.number("fillet."),
                "tolerance": Schema.number("join: gap to close."), "sharp_corners": Schema.boolean("offset: keep corners sharp."),
                "layer_id": Schema.string("to_layer: the layer."),
            ], required: ["action", "ids"])) { raw in
                let args = Args(raw)
                let ids = try args.uuids("ids")
                guard !ids.isEmpty else { throw ToolError("\"ids\" is empty.") }
                let known = Set(session.project.document.shapes.map(\.id))
                if let missing = ids.first(where: { !known.contains($0) }) { throw ToolError("No shape has the id \(missing).") }
                let idStrings = ids.map(\.uuidString)
                let action = try args.requireString("action")
                func command(_ name: String, _ extra: [String: Any] = [:]) throws {
                    try core.call("command", extra.merging(["name": name, "ids": idStrings]) { a, _ in a })
                }
                switch action {
                case "move":
                    try core.call("translateShapes", ["ids": idStrings, "by": ["x": args.double("dx") ?? 0, "y": args.double("dy") ?? 0]])
                case "rotate": try command("rotate", ["number": try args.requireDouble("degrees")])
                case "mirror": try core.call("mirrorShapes", ["ids": idStrings, "horizontally": args.bool("horizontally")])
                case "scale":
                    let f = try args.requireDouble("factor")
                    guard f > 0 else { throw ToolError("\"factor\" must be more than 0.") }
                    let c = session.project.bounds(of: Set(ids)).center
                    try core.call("transformShapes", ["ids": idStrings, "action": "Scale",
                                                      "transform": ["a": f, "b": 0, "c": 0, "d": f, "tx": c.x * (1 - f), "ty": c.y * (1 - f)]])
                case "align": try command("align", ["mode": try args.requireString("mode")])
                case "distribute": try command("distribute", ["flag": args.bool("horizontally")])
                case "group", "ungroup", "combine", "close": try command(action)
                case "break_apart": try command("breakApart")
                case "text_to_curves": try command("textToCurves")
                case "join": try command("join", args.double("tolerance").map { ["number": $0] } ?? [:])
                case "boolean": try command("boolean", ["mode": try args.requireString("mode")])
                case "offset": try command("offset", ["number": try args.requireDouble("distance"), "flag": args.bool("sharp_corners")])
                case "fillet": try command("fillet", ["number": try args.requireDouble("radius")])
                case "chamfer": try command("chamfer", ["number": try args.requireDouble("distance")])
                case "to_layer":
                    guard let layer = try args.uuid("layer_id") else { throw ToolError("\"layer_id\" is needed.") }
                    try core.call("moveShapesToLayer", ["ids": idStrings, "layer": layer.uuidString])
                case "delete": try core.call("deleteShapes", ["ids": idStrings])
                default: throw ToolError("Unknown action \"\(action)\".")
                }
                return Reply.output("\(action) done: \(ProjectTools.summaryLine(session)).")
            }

        let importFile = AssistantTool(
            name: "import_file",
            description: "Imports vectors or a bitmap (SVG, DXF, EPS, PDF, AI, PNG, JPEG…) from an allowed folder into the project, "
                + "as File > Import does. Files over 50 MB are refused.",
            inputSchema: Schema.object(["path": Schema.string("The file.")], required: ["path"])) { raw in
                let url = try access.resolve(try Args(raw).requireString("path"))
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                guard size <= maxImportBytes else { throw ToolError("\(url.lastPathComponent) is over 50 MB; LoftLine imports up to 50 MB for an assistant.") }
                let before = session.project.document.shapes.count
                let result = try core.call("import", ["path": url.path])
                let added = session.project.document.shapes.count - before
                return Reply.output("Imported \(url.lastPathComponent): \(added) shape\(added == 1 ? "" : "s").",
                                    ["warnings": result["warnings"] as? [String] ?? []])
            }

        let editLayers = AssistantTool(
            name: "edit_layers",
            description: "Layers: add (name), rename (id, name), show (id), hide (id), delete (id), clamps (id, height: marks the layer's "
                + "closed shapes as clamps and screws the tool must keep out of, standing height above the material; 0 = flush).",
            inputSchema: Schema.object([
                "action": Schema.string("What to do.", oneOf: ["add", "rename", "show", "hide", "delete", "clamps"]),
                "id": Schema.string("The layer."), "name": Schema.string("add, rename: the name."),
                "height": Schema.number("clamps: height above the material."),
            ], required: ["action"])) { raw in
                let args = Args(raw)
                let action = try args.requireString("action")
                if action == "add" {
                    let name = try args.requireString("name")
                    var id = UUID()
                    session.perform("New Layer") { id = $0.addLayer(named: name) }
                    return Reply.output("Added layer \"\(name)\".", ["id": id.uuidString])
                }
                guard let id = try args.uuid("id"), var layer = session.project.document.layer(id: id) else {
                    throw ToolError("\"id\" must name a layer of this project.")
                }
                switch action {
                case "rename": layer.name = try args.requireString("name")
                case "show": layer.isVisible = true
                case "hide": layer.isVisible = false
                case "clamps":
                    let h = try args.requireDouble("height")
                    guard h >= 0 else { throw ToolError("\"height\" can't be below the material top.") }
                    layer.keepOut = LayerKeepOut(height: h)
                case "delete":
                    session.perform("Delete Layer") { $0.deleteLayer(id) }
                    return Reply.output("Deleted layer \"\(layer.name)\".")
                default: throw ToolError("Unknown action \"\(action)\".")
                }
                session.perform("Edit Layer") { $0.updateLayer(layer) }
                return Reply.output("Layer \"\(layer.name)\": \(action) done.")
            }

        return [setJob, addShapes, editShapes, importFile, editLayers]
    }

    /// One add_shapes item as the core's `addShapes` takes it, checked against the limits first.
    static func item(_ a: Args, number n: Int, layer: UUID?) throws -> [String: Any] {
        func need(_ key: String) throws -> Double {
            guard let v = a.double(key), v.isFinite else { throw ToolError("Shape \(n): \"\(key)\" is needed.") }
            return v
        }
        func pt(_ x: Double, _ y: Double) -> [String: Any] { ["x": x, "y": y] }
        var out: [String: Any]
        let type = a.string("type") ?? ""
        switch type {
        case "rectangle", "rounded_rectangle":
            let x = try need("x"), y = try need("y")
            out = ["kind": "tool", "tool": type == "rectangle" ? "rectangle" : "roundedRectangle",
                   "from": pt(x, y), "to": pt(x + (try need("width")), y + (try need("height")))]
            if type == "rounded_rectangle" { out["options"] = ["cornerRadius": try need("corner_radius")] }
        case "circle":
            let x = try need("x"), y = try need("y")
            out = ["kind": "tool", "tool": "circle", "from": pt(x, y), "to": pt(x + (try need("radius")), y)]
        case "ellipse":
            let x = try need("x"), y = try need("y"), rx = try need("radius_x"), ry = try need("radius_y")
            out = ["kind": "tool", "tool": "ellipse", "from": pt(x - rx, y - ry), "to": pt(x + rx, y + ry)]
        case "polygon", "star":
            let x = try need("x"), y = try need("y"), r = try need("radius")
            out = ["kind": "tool", "tool": type, "from": pt(x, y), "to": pt(x, y + r)]
            out["options"] = type == "polygon" ? ["polygonSides": a.int("sides") ?? 6]
                : ["starPoints": a.int("points") ?? 5, "starInnerRatio": a.double("inner_ratio") ?? 0.5]
        case "polyline":
            let rawPoints = a.array("points") ?? []
            let points = rawPoints.compactMap { $0 as? [String: Any] }
            guard points.count == rawPoints.count else { throw ToolError("Shape \(n): every point needs x and y.") }
            guard points.count <= maxPoints else { throw ToolError("Shape \(n): \(points.count) points is more than \(maxPoints).") }
            out = ["kind": "polyline", "closed": a.bool("closed"),
                   "points": try points.map { p -> [String: Any] in
                       guard let x = (p["x"] as? NSNumber)?.doubleValue, let y = (p["y"] as? NSNumber)?.doubleValue else {
                           throw ToolError("Shape \(n): every point needs x and y.")
                       }
                       return pt(x, y)
                   }]
        case "text":
            guard let words = a.string("text"), !words.isEmpty else { throw ToolError("Shape \(n): \"text\" is needed.") }
            guard words.count <= maxText else { throw ToolError("Shape \(n): text over \(maxText) characters.") }
            let align = TextAlignment(rawValue: a.string("align") ?? "left") ?? .left
            let spec = TextSpec(string: words, fontName: a.string("font") ?? TextOutliner.defaultFontName, size: try need("size"),
                                alignment: align, anchor: Vec2(try need("x"), try need("y")))
            let json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(spec))
            out = ["kind": "text", "spec": json]
        default:
            throw ToolError("Shape \(n): unknown type \"\(type)\".")
        }
        if let layer { out["layerID"] = layer.uuidString }
        return out
    }
}
