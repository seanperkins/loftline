import CADCore
import CAMCore
import Foundation
import LoftLineKit
import PostCore

/// list_library, add_toolpath, update_toolpath, delete_toolpath, calculate (MCP spec, "The tools").
enum ToolpathTools {
    static func all(service: CoreService, access: AssistantAccess) -> [AssistantTool] {
        let session = service.session
        let core = CoreClient(service: service)

        let listLibrary = AssistantTool(
            name: "list_library",
            description: "Lists the tools (with ids, numbers and sizes in the project's units), the posts, or the machines LoftLine has.",
            inputSchema: Schema.object(["kind": Schema.string("What to list.", oneOf: ["tools", "posts", "machines"])], required: ["kind"])) { raw in
                let u = session.project.document.units
                switch try Args(raw).requireString("kind") {
                case "tools":
                    let tools = session.project.mergedTools(with: session.library).tools.map { t0 -> [String: Any] in
                        let t = t0.converted(to: u)
                        var row: [String: Any] = ["id": t.id.uuidString, "number": t.number, "name": t.name, "kind": t.kind.displayName,
                                                  "diameter": t.diameter, "units": u.rawValue]
                        if let a = t.angle { row["angle"] = a }
                        return row
                    }
                    return Reply.output("\(tools.count) tools.", ["tools": tools])
                case "posts":
                    let posts = session.profiles.map { ["id": $0.id, "name": $0.name, "fileExtension": GCodeExporter.fileExtension(for: $0),
                                                        "units": $0.units.rawValue] }
                    return Reply.output("\(posts.count) posts; this project uses \"\(session.resolved.post.name)\".", ["posts": posts])
                case "machines":
                    let machines = session.machines.map { ["id": $0.id, "name": $0.name] }
                    return Reply.output("\(machines.count) machines.", ["machines": machines])
                case let other:
                    throw ToolError("Unknown kind \"\(other)\": tools, posts or machines.")
                }
            }

        let addToolpath = AssistantTool(
            name: "add_toolpath",
            description: "Adds a toolpath on the given shapes with LoftLine's defaults for that kind, then applies settings: a partial "
                + "toolpath object merged over the defaults, e.g. {\"params\": {\"depth\": {\"cutDepth\": 0.25}}} or "
                + "{\"setup\": {\"name\": \"Outline\"}}. The reply shows every setting the toolpath has. One change; if anything is wrong, nothing is added.",
            inputSchema: Schema.object([
                "kind": Schema.string("Toolpath kind.", oneOf: OperationKind.allCases.map(\.rawValue)),
                "shape_ids": Schema.array("The shapes it cuts.", of: Schema.string("A shape id.")),
                "tool_id": Schema.string("A tool from list_library; the kind's default tool when left out."),
                "settings": Schema.anyObject,
            ], required: ["kind", "shape_ids"])) { raw in
                let args = Args(raw)
                let word = try args.requireString("kind")
                guard let kind = OperationKind(rawValue: word) else { throw ToolError("Unknown toolpath kind \"\(word)\".") }
                let shapes = try args.uuids("shape_ids")
                let known = Set(session.project.document.shapes.map(\.id))
                if let missing = shapes.first(where: { !known.contains($0) }) { throw ToolError("No shape has the id \(missing).") }
                let library = session.project.mergedTools(with: session.library)
                guard var op = OperationFactory.make(kind: kind, project: session.project, library: library, shapeIDs: shapes) else {
                    throw ToolError("Import a 3D model before adding a 3D toolpath.")
                }
                op = try patched(op, settings: args.object("settings"), toolID: try args.uuid("tool_id"), library: library)
                session.perform("New \(kind.displayName) Toolpath") { $0.upsertOperation(op) }
                return Reply.output("Added \(op.setup.name).", ["id": op.id.uuidString, "settings": try settings(of: op)])
            }

        let updateToolpath = AssistantTool(
            name: "update_toolpath",
            description: "Changes a toolpath: settings (a partial toolpath object merged over its own, as for add_toolpath), tool_id, "
                + "enabled (in the program or not), move_by (places up or down the order). One change. Called with only an id, "
                + "it shows the toolpath's settings.",
            inputSchema: Schema.object([
                "id": Schema.string("The toolpath."), "settings": Schema.anyObject, "tool_id": Schema.string("A tool from list_library."),
                "enabled": Schema.boolean("Include it in the program."), "move_by": Schema.integer("Places to move: negative is earlier."),
            ], required: ["id"])) { raw in
                let args = Args(raw)
                let op0 = try operation(session, try args.uuid("id"))
                var op = try patched(op0, settings: args.object("settings"), toolID: try args.uuid("tool_id"),
                                     library: session.project.mergedTools(with: session.library))
                if args.raw["enabled"] != nil {
                    var setup = op.editableSetup
                    setup.isEnabled = args.bool("enabled")
                    op = op.with(setup: setup)
                }
                let delta = args.int("move_by") ?? 0
                if op != op0 || delta != 0 {
                    session.perform("Edit Toolpath") { p in
                        p.upsertOperation(op)
                        if delta != 0 { p.moveOperation(op.id, by: delta) }
                    }
                }
                return Reply.output("\(op.setup.name)\(op != op0 || delta != 0 ? " changed" : "").", ["id": op.id.uuidString, "settings": try settings(of: op)])
            }

        let deleteToolpath = AssistantTool(
            name: "delete_toolpath", description: "Deletes a toolpath.",
            inputSchema: Schema.object(["id": Schema.string("The toolpath.")], required: ["id"])) { raw in
                let op = try operation(session, try Args(raw).uuid("id"))
                session.perform("Delete Toolpath") { $0.deleteOperation(op.id) }
                return Reply.output("Deleted \(op.setup.name).")
            }

        let calculate = AssistantTool(
            name: "calculate",
            description: "Calculates toolpaths (the given ids, or every enabled one) and reports each one's state, time and warnings.",
            inputSchema: Schema.object(["ids": Schema.array("Toolpaths to calculate.", of: Schema.string("A toolpath id."))])) { raw in
                let args = Args(raw)
                let ids = try args.uuids("ids")
                try core.call("calculate", ids.isEmpty ? [:] : ["ids": ids.map(\.uuidString)])
                let settings = TimeEstimateSettings.load()
                let u = session.project.document.units
                let rows = session.project.operations.filter { ids.isEmpty ? $0.setup.isEnabled : ids.contains($0.id) }.map { op -> [String: Any] in
                    var row: [String: Any] = ["id": op.id.uuidString, "name": op.setup.name]
                    guard let r = session.results[op.id] else { row["status"] = "not calculated"; return row }
                    if let e = r.error { row["status"] = "error"; row["error"] = e; return row }
                    row["status"] = session.isStale(op.id) ? "stale" : "calculated"
                    row["time"] = ToolpathCalculator.formatDuration(settings.estimate(r.toolpaths, rapidRate: session.rapidRate, units: u, toolChanges: false))
                    let warnings = r.toolpaths.compactMap { $0.metadata["warning"] }
                    if !warnings.isEmpty { row["warnings"] = warnings }
                    return row
                }
                let failed = rows.filter { $0["status"] as? String == "error" }.count
                return Reply.output("Calculated \(rows.count) toolpath\(rows.count == 1 ? "" : "s")\(failed > 0 ? ", \(failed) with errors" : "").",
                                    ["toolpaths": rows])
            }

        return [listLibrary, addToolpath, updateToolpath, deleteToolpath, calculate]
    }

    static func operation(_ s: CoreSession, _ id: UUID?) throws -> AnyOperation {
        guard let id, let op = s.project.operations.first(where: { $0.id == id }) else { throw ToolError("No toolpath has that id.") }
        return op
    }

    /// The toolpath's own JSON object (inside its kind), as settings are given and shown.
    static func settings(of op: AnyOperation) throws -> [String: Any] {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(op)) as? [String: Any] ?? [:]
        return (json.values.first as? [String: Any])?["_0"] as? [String: Any] ?? [:]
    }

    /// `op` with `settings` merged over it and `toolID` set; its id never changes. A setting the toolpath can't take is an error.
    static func patched(_ op: AnyOperation, settings patch: [String: Any]?, toolID: UUID?, library: ToolLibrary) throws -> AnyOperation {
        guard patch != nil || toolID != nil else { return op }
        if let toolID, library.tool(id: toolID) == nil { throw ToolError("No tool has the id \(toolID); see list_library.") }
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(op)) as? [String: Any] ?? [:]
        guard let key = json.keys.first, var inner = (json[key] as? [String: Any])?["_0"] as? [String: Any] else { return op }
        if let patch { inner = JSONPatch.merge(patch, into: inner) }
        var setup = inner["setup"] as? [String: Any] ?? [:]
        setup["id"] = op.id.uuidString
        if let toolID { setup["toolID"] = toolID.uuidString }
        inner["setup"] = setup
        do {
            let data = try JSONSerialization.data(withJSONObject: [key: ["_0": inner]])
            return try JSONDecoder().decode(AnyOperation.self, from: data)
        } catch {
            throw ToolError("Those settings don't fit a \(op.kind.displayName) toolpath: \(describe(error)). "
                + "Its settings are shown by update_toolpath with only the id.")
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.typeMismatch(_, let c), DecodingError.valueNotFound(_, let c):
            return "\(c.codingPath.map(\.stringValue).joined(separator: ".")) has the wrong kind of value"
        case DecodingError.keyNotFound(let k, let c):
            return "\((c.codingPath.map(\.stringValue) + [k.stringValue]).joined(separator: ".")) is missing"
        case DecodingError.dataCorrupted(let c):
            return "\(c.codingPath.map(\.stringValue).joined(separator: ".")): \(c.debugDescription)"
        default: return error.localizedDescription
        }
    }
}
