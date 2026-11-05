import CADCore
import CAMCore
import Foundation
import JavaScriptCore
import LoftLineKit

/// What a gadget run produced. The project is a modified copy; nothing touches the open
/// document until the caller applies it (one undo step).
struct GadgetRunResult {
    var project: LoftLineProject
    var createdShapeIDs: [UUID]
    var createdOperationIDs: [UUID]
    /// Selection the gadget asked for (`loftline.select`), else nil (the caller selects what it drew).
    var requestedSelection: [UUID]?
    var log: [String]
    var messages: [String]

    var changedSomething: Bool { !createdShapeIDs.isEmpty || !createdOperationIDs.isEmpty }
}

struct GadgetError: Error, Equatable, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Runs gadget scripts in a sandboxed JavaScriptCore context. The context has no file,
/// network or process access — only the `loftline` API below — and a wall-clock time limit.
enum GadgetHost {
    static let defaultTimeLimit: TimeInterval = 10
    static let maxLogLines = 500
    static let maxNewShapes = 20_000

    static func run(_ script: GadgetScript, values: [String: GadgetValue], project: LoftLineProject,
                    selection: [UUID], library: ToolLibrary, layerID: UUID? = nil,
                    timeLimit: TimeInterval = defaultTimeLimit) throws -> GadgetRunResult {
        guard let context = JSContext() else { throw GadgetError(message: "The script engine could not start.") }
        applyTimeLimit(timeLimit, to: context)
        let session = GadgetSession(script: script, project: project, selection: selection, library: library,
                                    layerID: layerID ?? project.document.defaultLayerID)
        var thrown: String?
        context.exceptionHandler = { _, exc in
            guard thrown == nil, let exc else { return }
            var msg = exc.toString() ?? "Unknown error"
            if let line = exc.objectForKeyedSubscript("line"), line.isNumber {
                // The prelude is evaluated separately, so line numbers are the script's own.
                msg = "Line \(line.toInt32()): " + msg
            }
            thrown = msg
        }
        context.setObject(session.nativeObject(in: context, values: values), forKeyedSubscript: "__loftlineNative" as NSString)
        context.evaluateScript(GadgetAPI.prelude, withSourceURL: URL(string: "loftline-prelude.js"))
        if let t = thrown { throw GadgetError(message: "Gadget API failed to load: " + t) }
        context.evaluateScript(script.source, withSourceURL: URL(string: script.name + ".js"))
        if let t = thrown {
            if t.contains("execution terminated") || t.contains("JavaScript execution terminated") {
                throw GadgetError(message: "The gadget ran longer than \(Int(timeLimit)) seconds and was stopped.")
            }
            throw GadgetError(message: t)
        }
        return GadgetRunResult(project: session.project, createdShapeIDs: session.createdShapes,
                               createdOperationIDs: session.createdOperations,
                               requestedSelection: session.requestedSelection, log: session.log,
                               messages: session.messages)
    }

    /// `JSContextGroupSetExecutionTimeLimit` is exported by JavaScriptCore but not in its public
    /// headers; look it up at run time and skip the limit if it is ever missing.
    private static func applyTimeLimit(_ seconds: TimeInterval, to context: JSContext) {
        typealias SetLimit = @convention(c) (JSContextGroupRef, Double, OpaquePointer?, UnsafeMutableRawPointer?) -> Void
        guard seconds > 0,
              let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") else { return }
        let fn = unsafeBitCast(sym, to: SetLimit.self)
        fn(JSContextGetGroup(context.jsGlobalContextRef), seconds, nil, nil)
    }
}

/// Mutable state of one run; the native functions behind `loftline.*` act on it.
private final class GadgetSession {
    let script: GadgetScript
    var project: LoftLineProject
    let selection: [UUID]
    let library: ToolLibrary
    let layerID: UUID
    var createdShapes: [UUID] = []
    var createdOperations: [UUID] = []
    var requestedSelection: [UUID]?
    var log: [String] = []
    var messages: [String] = []

    init(script: GadgetScript, project: LoftLineProject, selection: [UUID], library: ToolLibrary, layerID: UUID) {
        self.script = script; self.project = project; self.selection = selection
        self.library = library; self.layerID = layerID
    }

    var units: LengthUnit { project.document.units }
    var tolerance: Double { units == .inch ? 0.001 : 0.025 }

    private func fail(_ message: String) {
        guard let ctx = JSContext.current() else { return }
        ctx.exception = JSValue(newErrorFromMessage: message, in: ctx)
    }

    // MARK: Conversions

    private func number(_ any: Any?) -> Double? {
        guard let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue.isFinite ? n.doubleValue : nil
    }

    private func point(_ any: Any?) -> Vec2? {
        if let a = any as? [Any], a.count >= 2, let x = number(a[0]), let y = number(a[1]) { return Vec2(x, y) }
        if let d = any as? [String: Any], let x = number(d["x"]), let y = number(d["y"]) { return Vec2(x, y) }
        return nil
    }

    private func ids(_ value: JSValue) -> [UUID] {
        if value.isString, let s = value.toString(), let id = UUID(uuidString: s) { return [id] }
        return (value.toArray() ?? []).compactMap { ($0 as? String).flatMap(UUID.init(uuidString:)) }
    }

    /// `{start:[x,y], segments:[{line:[x,y]} | {arc:[x,y], center:[x,y], clockwise} |
    /// {cubic:[x,y], c1:[x,y], c2:[x,y]}], closed}`.
    private func path(_ any: Any) -> Path? {
        guard let d = any as? [String: Any], let start = point(d["start"]) else { return nil }
        var p = Path(start: start, isClosed: (d["closed"] as? Bool) ?? false)
        for raw in (d["segments"] as? [Any]) ?? [] {
            guard let s = raw as? [String: Any] else { return nil }
            if let to = point(s["line"]) {
                p.segments.append(.line(to: to))
            } else if let to = point(s["arc"]), let c = point(s["center"]) {
                p.segments.append(.arc(to: to, center: c, clockwise: (s["clockwise"] as? Bool) ?? false))
            } else if let to = point(s["cubic"]), let c1 = point(s["c1"]), let c2 = point(s["c2"]) {
                p.segments.append(.cubic(to: to, control1: c1, control2: c2))
            } else {
                return nil
            }
        }
        return p.segments.isEmpty ? nil : p
    }

    private func options(_ v: JSValue) -> [String: Any] {
        let d = (v.isObject ? v.toDictionary() as? [String: Any] : nil) ?? [:]
        return d.filter { !($0.value is NSNull) }
    }

    // MARK: Shapes

    private func resolveLayer(_ opts: [String: Any]) -> UUID? {
        guard let name = opts["layer"] as? String, !name.isEmpty else { return layerID }
        if let id = UUID(uuidString: name), project.document.layer(id: id) != nil { return id }
        return ensureLayer(name: name, color: nil)
    }

    func ensureLayer(name: String, color: String?) -> UUID {
        if let l = project.document.layers.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return l.id }
        let id = project.addLayer(named: name)
        if let i = project.document.layers.firstIndex(where: { $0.id == id }) {
            if let c = color, c.hasPrefix("#"), c.count == 7 { project.document.layers[i].colorHex = c.uppercased() }
            // A new layer lives on the same side / material sheet the gadget is drawing on.
            if let base = project.document.layer(id: layerID) {
                project.document.layers[i].side = base.side
                project.document.layers[i].sheetID = base.sheetID
            }
        }
        return id
    }

    private func add(paths: [Path], origin: ShapeOrigin, opts: [String: Any]) -> String? {
        guard createdShapes.count < GadgetHost.maxNewShapes else {
            fail("A gadget can create at most \(GadgetHost.maxNewShapes) shapes."); return nil
        }
        guard !paths.isEmpty else { fail("A shape needs at least one path with a segment."); return nil }
        guard let layer = resolveLayer(opts) else { return nil }
        let name = (opts["name"] as? String) ?? script.name
        let shape = Shape(name: name, layerID: layer, paths: paths, origin: origin)
        project.document.add(shape)
        createdShapes.append(shape.id)
        return shape.id.uuidString
    }

    private func info(_ s: Shape) -> [String: Any] {
        let b = s.bounds()
        let layer = project.document.layer(id: s.layerID)
        var out: [String: Any] = [
            "id": s.id.uuidString, "name": s.name, "layer": layer?.name ?? "", "layerId": s.layerID.uuidString,
            "closed": s.isClosed,
            "bounds": ["minX": b.min.x, "minY": b.min.y, "maxX": b.max.x, "maxY": b.max.y,
                       "width": b.width, "height": b.height,
                       "centerX": (b.min.x + b.max.x) / 2, "centerY": (b.min.y + b.max.y) / 2],
            "paths": s.paths.map { p -> [String: Any] in
                ["closed": p.isClosed, "points": p.flattened(tolerance: tolerance).map { [$0.x, $0.y] },
                 "length": p.length(tolerance: tolerance)]
            },
        ]
        switch s.origin {
        case .circle(let r): out["kind"] = "circle"; out["radius"] = r
        case .rectangle: out["kind"] = "rectangle"
        case .ellipse: out["kind"] = "ellipse"
        case .polygon: out["kind"] = "polygon"
        case .star: out["kind"] = "star"
        case .text(let t, _, _): out["kind"] = "text"; out["text"] = t
        default: out["kind"] = s.text != nil ? "text" : "vector"
        }
        return out
    }

    // MARK: Toolpaths

    private func addToolpath(kindName: String, shapeIDs: [UUID], opts: [String: Any]) -> String? {
        let key = kindName.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        guard let kind = OperationKind.allCases.first(where: {
            $0.rawValue.lowercased() == key || $0.displayName.lowercased().replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "-", with: "") == key
        }), kind != .merge else {
            fail("Unknown toolpath kind \"\(kindName)\". Use profile, pocket, drill, vcarve, engrave, chamfer, holeMill, fluting, texture…")
            return nil
        }
        let known = Set(project.document.shapes.map(\.id))
        let missing = shapeIDs.filter { !known.contains($0) }
        guard missing.isEmpty else { fail("addToolpath: \(missing.count) shape id(s) not found."); return nil }
        let lib = project.mergedTools(with: library)
        guard var op = OperationFactory.make(kind: kind, project: project, library: lib, shapeIDs: shapeIDs) else {
            fail("Could not create a \(kind.displayName) toolpath (a 3D toolpath needs a placed model)."); return nil
        }
        if let name = opts["name"] as? String, !name.isEmpty { op.editableSetup.name = name }
        if let toolKey = opts["tool"] {
            guard let tool = findTool(toolKey, in: lib) else {
                fail("No tool matches \"\(toolKey)\" in the tool database."); return nil
            }
            op.editableSetup.toolID = tool.id
            if !project.tools.contains(where: { $0.id == tool.id }) { project.tools.append(tool) }
        }
        if let depth = number(opts["depth"]) {
            guard depth >= 0 else { fail("depth must be zero or more."); return nil }
            switch op {
            case .profile(var o): o.params.depth.cutDepth = depth; op = .profile(o)
            case .pocket(var o): o.params.depth.cutDepth = depth; op = .pocket(o)
            case .drill(var o): o.params.cutDepth = depth; op = .drill(o)
            default: log.append("Note: depth is ignored for \(kind.displayName) toolpaths.")
            }
        }
        if let side = opts["side"] as? String {
            guard case .profile(var o) = op, let s = ProfileSide(rawValue: side.lowercased()) else {
                fail("side applies to profile toolpaths: outside, inside or on."); return nil
            }
            o.params.side = s
            op = .profile(o)
        }
        if let enabled = opts["enabled"] as? Bool { op.editableSetup.isEnabled = enabled }
        project.upsertOperation(op)
        createdOperations.append(op.id)
        return op.id.uuidString
    }

    private func findTool(_ key: Any, in lib: ToolLibrary) -> Tool? {
        if let n = number(key) { return lib.tools.first { $0.number == Int(n) } }
        guard let s = key as? String else { return nil }
        if let id = UUID(uuidString: s) { return lib.tools.first { $0.id == id } }
        return lib.tools.first { $0.name.caseInsensitiveCompare(s) == .orderedSame }
            ?? lib.tools.first { $0.name.localizedCaseInsensitiveContains(s) }
    }

    // MARK: Native object

    func nativeObject(in ctx: JSContext, values: [String: GadgetValue]) -> JSValue {
        let n = JSValue(newObjectIn: ctx)!
        func set(_ key: String, _ value: Any) { n.setObject(value, forKeyedSubscript: key as NSString) }
        func fn<Block>(_ key: String, _ block: Block) {
            n.setObject(unsafeBitCast(block, to: AnyObject.self), forKeyedSubscript: key as NSString)
        }
        let doc = project.document
        set("units", units == .inch ? "inch" : "mm")
        set("material", ["width": doc.job.width, "height": doc.job.height, "thickness": doc.job.thickness,
                         "zZero": doc.job.zZero == .materialTop ? "top" : "spoilboard", "safeZ": doc.job.safeZ])
        set("params", values.mapValues(\.jsValue))
        set("variables", Dictionary(doc.userVariables.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a }))
        set("gadgetName", script.name)

        let shapes: @convention(block) (Bool) -> [[String: Any]] = { [unowned self] selected in
            let list = selected ? self.project.document.shapes(ids: self.selection) : self.project.document.shapes
            return list.map(self.info)
        }
        fn("shapes", shapes)
        let layers: @convention(block) () -> [[String: Any]] = { [unowned self] in
            self.project.document.layers.map { ["id": $0.id.uuidString, "name": $0.name, "visible": $0.isVisible,
                                                "locked": $0.isLocked, "color": $0.colorHex] }
        }
        fn("layers", layers)
        let tools: @convention(block) () -> [[String: Any]] = { [unowned self] in
            self.project.mergedTools(with: self.library).tools.map {
                ["id": $0.id.uuidString, "name": $0.name, "number": $0.number, "kind": $0.kind.rawValue,
                 "diameter": $0.diameter * $0.units.factor(to: self.units)]
            }
        }
        fn("tools", tools)
        let logFn: @convention(block) (String) -> Void = { [unowned self] s in
            if self.log.count < GadgetHost.maxLogLines { self.log.append(s) }
        }
        fn("log", logFn)
        let message: @convention(block) (String) -> Void = { [unowned self] s in self.messages.append(s) }
        fn("message", message)
        let addShape: @convention(block) (JSValue, JSValue) -> String? = { [unowned self] paths, opts in
            let raw = paths.toArray() ?? []
            var out: [Path] = []
            for (i, r) in raw.enumerated() {
                guard let p = self.path(r) else { self.fail("Path \(i + 1) is not a valid path description."); return nil }
                out.append(p)
            }
            return self.add(paths: out, origin: .derived(operation: "Gadget"), opts: self.options(opts))
        }
        fn("addShape", addShape)
        let primitive: @convention(block) (String, JSValue, JSValue) -> String? = { [unowned self] kind, args, opts in
            let a = (args.toArray() ?? []).map { self.number($0) }
            guard a.allSatisfy({ $0 != nil }) else { self.fail("\(kind): arguments must be numbers."); return nil }
            let v = a.map { $0! }
            let o = self.options(opts)
            switch kind {
            case "rectangle" where v.count == 5:
                guard v[2] > 0, v[3] > 0 else { self.fail("rectangle: width and height must be positive."); return nil }
                return self.add(paths: [ShapeFactory.rectangle(Rect2(x: v[0], y: v[1], width: v[2], height: v[3]), cornerRadius: v[4])],
                                origin: .rectangle(width: v[2], height: v[3], cornerRadius: v[4]), opts: o)
            case "circle" where v.count == 3:
                guard v[2] > 0 else { self.fail("circle: radius must be positive."); return nil }
                return self.add(paths: [ShapeFactory.circle(center: Vec2(v[0], v[1]), radius: v[2])],
                                origin: .circle(radius: v[2]), opts: o)
            case "ellipse" where v.count == 4:
                guard v[2] > 0, v[3] > 0 else { self.fail("ellipse: radii must be positive."); return nil }
                return self.add(paths: [ShapeFactory.ellipse(center: Vec2(v[0], v[1]), rx: v[2], ry: v[3])],
                                origin: .ellipse(rx: v[2], ry: v[3]), opts: o)
            default:
                self.fail("Bad arguments for \(kind)."); return nil
            }
        }
        fn("primitive", primitive)
        let layer: @convention(block) (String, JSValue) -> String? = { [unowned self] name, color in
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { self.fail("layer: name is empty."); return nil }
            return self.ensureLayer(name: name, color: color.isString ? color.toString() : nil).uuidString
        }
        fn("layer", layer)
        let deleteShapes: @convention(block) (JSValue) -> Void = { [unowned self] v in
            let ids = Set(self.ids(v))
            let locked = self.project.document.shapes.filter { ids.contains($0.id) && !self.project.isEditable($0) }
            guard locked.isEmpty else { self.fail("deleteShapes: \(locked.count) shape(s) are locked or on a hidden/locked layer."); return }
            self.project.document.removeShapes(ids: ids)
            self.createdShapes.removeAll { ids.contains($0) }
            for i in self.project.operations.indices {
                self.project.operations[i].editableSetup.shapeIDs.removeAll { ids.contains($0) }
            }
        }
        fn("deleteShapes", deleteShapes)
        let transform: @convention(block) (JSValue, JSValue) -> Void = { [unowned self] v, m in
            let ids = Set(self.ids(v))
            let a = (m.toArray() ?? []).compactMap { self.number($0) }
            guard a.count == 6 else { self.fail("transform: matrix must be [a, b, c, d, tx, ty]."); return }
            let t = Transform2D(a: a[0], b: a[1], c: a[2], d: a[3], tx: a[4], ty: a[5])
            guard abs(t.determinant) > 1e-12 else { self.fail("transform: the matrix flattens the shapes."); return }
            for i in self.project.document.shapes.indices where ids.contains(self.project.document.shapes[i].id) {
                guard self.project.isEditable(self.project.document.shapes[i]) else {
                    self.fail("transform: a shape is locked or on a hidden/locked layer."); return
                }
                self.project.document.shapes[i] = self.project.document.shapes[i].transformed(t)
            }
        }
        fn("transform", transform)
        let addToolpath: @convention(block) (String, JSValue, JSValue) -> String? = { [unowned self] kind, v, opts in
            self.addToolpath(kindName: kind, shapeIDs: self.ids(v), opts: self.options(opts))
        }
        fn("addToolpath", addToolpath)
        let setVariable: @convention(block) (String, JSValue) -> Void = { [unowned self] name, value in
            guard DocumentVariable.isValidName(name) else { self.fail("\"\(name)\" is not a valid variable name."); return }
            guard value.isNumber, let d = self.number(value.toNumber()) else { self.fail("setVariable: value must be a number."); return }
            var vars = self.project.document.userVariables
            if let i = vars.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                vars[i].value = d
            } else {
                vars.append(DocumentVariable(name: name, value: d))
            }
            self.project.document.userVariables = vars
        }
        fn("setVariable", setVariable)
        let select: @convention(block) (JSValue) -> Void = { [unowned self] v in
            let known = Set(self.project.document.shapes.map(\.id))
            self.requestedSelection = self.ids(v).filter(known.contains)
        }
        fn("select", select)
        return n
    }
}
