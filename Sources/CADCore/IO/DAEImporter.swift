import Foundation

/// COLLADA (.dae) mesh import — the open format SketchUp (and most modellers) export.
/// Reads `<triangles>`, `<polylist>` and `<polygons>` (fan-triangulated) of every geometry
/// instanced from the visual scene, applying node `<matrix>`/translate/rotate/scale transforms,
/// `<instance_node>` (SketchUp components) and the `<unit meter>` / `<up_axis>` of the asset.
public struct DAEImporter: MeshImporter {
    public static let fileExtensions = ["dae"]
    public init() {}

    /// Total node visits and triangles one import may produce, so self-referencing instances stay bounded.
    static let maxNodeVisits = 100_000
    static let maxTriangles = 20_000_000
    /// Past a limit the import fails with the reason, rather than return part of the model.
    static let tooLarge = LoftLineIOError.malformed(
        "the COLLADA file instances more than \(maxNodeVisits) nodes or \(maxTriangles) triangles (a node may instance itself)")

    public func importMesh(from data: Data, targetUnits: LengthUnit) throws -> Mesh3D {
        let tris = try parts(from: data, targetUnits: targetUnits, split: false).flatMap(\.triangles)
        guard !tris.isEmpty else { throw LoftLineIOError.malformed("the COLLADA file contains no triangles") }
        return STLImporter.indexed(tris, scale: 1)
    }

    /// One mesh per part: the scene's top-level nodes (SketchUp groups / component instances),
    /// descending through single wrapper nodes that hold no geometry of their own. Used by
    /// "Import 3D Model as 2D Parts".
    public func importParts(from data: Data, targetUnits: LengthUnit) throws -> [MeshPart] {
        let parts = try parts(from: data, targetUnits: targetUnits, split: true)
            .filter { !$0.triangles.isEmpty }
            .map { MeshPart(name: $0.name, mesh: STLImporter.indexed($0.triangles, scale: 1)) }
            .filter { $0.mesh.triangleCount > 0 }
        guard !parts.isEmpty else { throw LoftLineIOError.malformed("the COLLADA file contains no triangles") }
        return parts
    }

    private typealias RawPart = (name: String, triangles: [(Vec3, Vec3, Vec3)])

    private func parts(from data: Data, targetUnits: LengthUnit, split: Bool) throws -> [RawPart] {
        let root = try XMLTree.parse(data)
        guard root.name == "COLLADA" else { throw LoftLineIOError.malformed("not a COLLADA document") }
        var ids: [String: XMLTree] = [:]
        root.forEach { if let id = $0.attributes["id"] { ids[id] = $0 } }
        func ref(_ url: String?) -> XMLTree? { url.flatMap { ids[String($0.dropFirst())] } }

        let asset = root.child("asset")
        let meter = asset?.child("unit")?.attributes["meter"].flatMap(Double.init) ?? 1
        let up = asset?.child("up_axis")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Y_UP"
        // Metres → target units, and the up axis → +Z.
        let scale = meter * LengthUnit.millimeter.convert(1000, to: targetUnits)
        var base = Matrix4.scale(scale)
        if up == "Y_UP" { base = Matrix4.yUpToZUp.multiplied(by: base) }
        if up == "X_UP" { base = Matrix4.xUpToZUp.multiplied(by: base) }

        func local(_ node: XMLTree, _ parent: Matrix4) -> Matrix4 {
            var m = parent
            for c in node.children {
                let v = c.numbers
                switch c.name {
                case "matrix" where v.count == 16: m = m.multiplied(by: Matrix4(rowMajor: v))
                case "translate" where v.count == 3: m = m.multiplied(by: .translation(v[0], v[1], v[2]))
                case "scale" where v.count == 3: m = m.multiplied(by: .scale(v[0], v[1], v[2]))
                case "rotate" where v.count == 4:
                    m = m.multiplied(by: .rotation(axis: Vec3(v[0], v[1], v[2]), degrees: v[3]))
                default: break
                }
            }
            return m
        }

        var depth = 0
        // The depth guard bounds nesting, not work: a node instancing itself twice is 2^32 visits (#121).
        var visits = 0
        var overLimit = false
        func visit(_ node: XMLTree, _ parent: Matrix4, into tris: inout [(Vec3, Vec3, Vec3)]) {
            guard depth < 32, !overLimit else { return }
            guard visits < Self.maxNodeVisits else { overLimit = true; return }
            visits += 1
            depth += 1
            defer { depth -= 1 }
            let m = local(node, parent)
            for c in node.children {
                switch c.name {
                case "instance_geometry":
                    if let g = ref(c.attributes["url"]) {
                        let more = Self.triangles(of: g, ids: ids)
                        guard more.count <= Self.maxTriangles - tris.count else { overLimit = true; return }
                        tris += more.map { (m.apply($0.0), m.apply($0.1), m.apply($0.2)) }
                    }
                case "instance_node":
                    if let n = ref(c.attributes["url"]) { visit(n, m, into: &tris) }
                case "node":
                    visit(c, m, into: &tris)
                default: break
                }
            }
        }

        /// Child nodes of `node` (instance_node targets resolved) with their parent matrix.
        func childNodes(_ node: XMLTree, _ m: Matrix4) -> [(XMLTree, Matrix4)] {
            node.children.compactMap { c in
                switch c.name {
                case "node": return (c, m)
                case "instance_node": return ref(c.attributes["url"]).map { ($0, m) }
                default: return nil
                }
            }
        }
        /// A part's name: the node's name, or the component it instances when the node is an
        /// unnamed / generated instance wrapper.
        func name(_ node: XMLTree, index: Int) -> String {
            let own = node.attributes["name"] ?? ""
            let generic = own.isEmpty || own.lowercased().hasPrefix("instance")
            if generic, let inst = node.children.first(where: { $0.name == "instance_node" }),
               let target = ref(inst.attributes["url"]), let n = target.attributes["name"] ?? target.attributes["id"],
               !n.isEmpty {
                return n
            }
            return own.isEmpty ? "Part \(index + 1)" : own
        }

        let scene = ref(root.child("scene")?.child("instance_visual_scene")?.attributes["url"])
            ?? root.child("library_visual_scenes")?.child("visual_scene")
        guard let scene else {
            // No scene: take every geometry untransformed (one part each).
            let geoms = (root.child("library_geometries")?.children ?? []).filter { $0.name == "geometry" }
            let parts = geoms.enumerated().map { i, g in
                (g.attributes["name"] ?? "Part \(i + 1)",
                 Self.triangles(of: g, ids: ids).map { (base.apply($0.0), base.apply($0.1), base.apply($0.2)) })
            }
            guard parts.reduce(0, { $0 + $1.1.count }) <= Self.maxTriangles else { throw Self.tooLarge }
            return parts
        }
        var roots: [(XMLTree, Matrix4)] = scene.children.filter { $0.name == "node" }.map { ($0, base) }
        if !split {
            var all: [(Vec3, Vec3, Vec3)] = []
            for (n, m) in roots { visit(n, m, into: &all) }
            if overLimit { throw Self.tooLarge }
            return [("Model", all)]
        }
        // Unwrap single wrapper nodes (e.g. one "SketchUp" node around the whole model).
        var unwraps = 0
        while roots.count == 1, unwraps < 32,
              !roots[0].0.children.contains(where: { $0.name == "instance_geometry" }) {
            let kids = childNodes(roots[0].0, local(roots[0].0, roots[0].1))
            guard !kids.isEmpty else { break }
            roots = kids
            unwraps += 1
        }
        let parts = roots.enumerated().map { i, r in
            var tris: [(Vec3, Vec3, Vec3)] = []
            visit(r.0, r.1, into: &tris)
            return (name(r.0, index: i), tris)
        }
        guard !overLimit, parts.reduce(0, { $0 + $1.1.count }) <= Self.maxTriangles else { throw Self.tooLarge }
        return parts
    }

    /// Triangles of one `<geometry>` in its own coordinates.
    static func triangles(of geometry: XMLTree, ids: [String: XMLTree]) -> [(Vec3, Vec3, Vec3)] {
        guard let mesh = geometry.child("mesh") else { return [] }
        func positions(_ url: String?) -> [Vec3] {
            guard var src = url.flatMap({ ids[String($0.dropFirst())] }) else { return [] }
            if src.name == "vertices",
               let s = src.children.first(where: { $0.name == "input" && $0.attributes["semantic"] == "POSITION" })?
                .attributes["source"].flatMap({ ids[String($0.dropFirst())] }) {
                src = s
            }
            guard let arr = src.child("float_array") else { return [] }
            let v = arr.numbers
            let stride = src.child("technique_common")?.child("accessor")?.attributes["stride"].flatMap(Int.init) ?? 3
            guard stride >= 3 else { return [] }
            return Swift.stride(from: 0, to: v.count - 2, by: stride).map { Vec3(v[$0], v[$0 + 1], v[$0 + 2]) }
        }
        var out: [(Vec3, Vec3, Vec3)] = []
        for prim in mesh.children where ["triangles", "polylist", "polygons"].contains(prim.name) {
            let inputs = prim.children.filter { $0.name == "input" }
            guard let vin = inputs.first(where: { $0.attributes["semantic"] == "VERTEX" }) else { continue }
            let pts = positions(vin.attributes["source"])
            // A negative, absurd or unreadable offset indexed outside the list, overflowed the width or silently became 0
            // (#121): skip the primitive.
            let raw = inputs.compactMap { $0.attributes["offset"] }
            let offsets = raw.compactMap { Int($0) }
            guard offsets.count == raw.count, offsets.allSatisfy({ (0...255).contains($0) }) else { continue }
            let vOffset = vin.attributes["offset"].flatMap(Int.init) ?? 0
            let width = (offsets.max() ?? 0) + 1
            func polygon(_ idx: ArraySlice<Int>) {
                let verts = idx.compactMap { $0 >= 0 && $0 < pts.count ? pts[$0] : nil }
                guard verts.count >= 3 else { return }
                for k in 1..<(verts.count - 1) { out.append((verts[0], verts[k], verts[k + 1])) }
            }
            let ps = prim.children.filter { $0.name == "p" }
            switch prim.name {
            case "triangles":
                guard let p = ps.first else { continue }
                let all = p.integers
                let vIdx = Swift.stride(from: vOffset, to: all.count, by: width).map { all[$0] }
                for t in Swift.stride(from: 0, to: vIdx.count - 2, by: 3) { polygon(vIdx[t..<(t + 3)]) }
            case "polylist":
                guard let p = ps.first else { continue }
                let all = p.integers
                let vIdx = Swift.stride(from: vOffset, to: all.count, by: width).map { all[$0] }
                var at = 0
                for n in prim.child("vcount")?.integers ?? [] {
                    guard n > 0, n <= vIdx.count - at else { break }   // no `at + n`: a crafted count overflowed it (#121)
                    polygon(vIdx[at..<(at + n)])
                    at += n
                }
            default:  // polygons: one <p> per polygon
                for p in ps {
                    let all = p.integers
                    polygon(ArraySlice(Swift.stride(from: vOffset, to: all.count, by: width).map { all[$0] }))
                }
            }
        }
        return out
    }
}

/// Column-vector 4×4 affine matrix (row-major storage) for COLLADA node transforms.
struct Matrix4 {
    var m: [Double]  // 16, row-major

    init(rowMajor: [Double]) { m = rowMajor }

    static let identity = Matrix4(rowMajor: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
    static func translation(_ x: Double, _ y: Double, _ z: Double) -> Matrix4 {
        Matrix4(rowMajor: [1, 0, 0, x, 0, 1, 0, y, 0, 0, 1, z, 0, 0, 0, 1])
    }
    static func scale(_ s: Double) -> Matrix4 { scale(s, s, s) }
    static func scale(_ x: Double, _ y: Double, _ z: Double) -> Matrix4 {
        Matrix4(rowMajor: [x, 0, 0, 0, 0, y, 0, 0, 0, 0, z, 0, 0, 0, 0, 1])
    }
    /// (x, y, z) → (x, −z, y): Y-up models stand on LoftLine's XY plane with +Y becoming +Z.
    static let yUpToZUp = Matrix4(rowMajor: [1, 0, 0, 0, 0, 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, 1])
    /// COLLADA X_UP (right = −Y, up = +X) → Z-up: (x, y, z) → (−y, −z, x).
    static let xUpToZUp = Matrix4(rowMajor: [0, -1, 0, 0, 0, 0, -1, 0, 1, 0, 0, 0, 0, 0, 0, 1])

    static func rotation(axis a: Vec3, degrees: Double) -> Matrix4 {
        let len = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
        guard len > 1e-12 else { return .identity }
        let x = a.x / len, y = a.y / len, z = a.z / len
        let r = degrees * .pi / 180, c = cos(r), s = sin(r), t = 1 - c
        return Matrix4(rowMajor: [t * x * x + c, t * x * y - s * z, t * x * z + s * y, 0,
                                  t * x * y + s * z, t * y * y + c, t * y * z - s * x, 0,
                                  t * x * z - s * y, t * y * z + s * x, t * z * z + c, 0,
                                  0, 0, 0, 1])
    }

    /// self × o (apply `o` first).
    func multiplied(by o: Matrix4) -> Matrix4 {
        var r = [Double](repeating: 0, count: 16)
        for i in 0..<4 { for j in 0..<4 { for k in 0..<4 { r[i * 4 + j] += m[i * 4 + k] * o.m[k * 4 + j] } } }
        return Matrix4(rowMajor: r)
    }

    func apply(_ p: Vec3) -> Vec3 {
        Vec3(m[0] * p.x + m[1] * p.y + m[2] * p.z + m[3],
             m[4] * p.x + m[5] * p.y + m[6] * p.z + m[7],
             m[8] * p.x + m[9] * p.y + m[10] * p.z + m[11])
    }
}

/// Small generic XML element tree (element text kept) for COLLADA.
final class XMLTree {
    let name: String
    let attributes: [String: String]
    var children: [XMLTree] = []
    var text = ""

    init(name: String, attributes: [String: String]) { self.name = name; self.attributes = attributes }

    func child(_ name: String) -> XMLTree? { children.first { $0.name == name } }

    func forEach(_ body: (XMLTree) -> Void) {
        body(self)
        for c in children { c.forEach(body) }
    }

    /// Non-finite tokens ("nan", "inf", overflowing exponents) are dropped so no index or
    /// integer conversion downstream can trap; a truncated array then fails the count checks.
    var numbers: [Double] {
        text.split(whereSeparator: { $0 == " " || $0.isNewline || $0 == "\t" }).compactMap { Double($0) }.filter(\.isFinite)
    }
    var integers: [Int] { text.split(whereSeparator: { $0 == " " || $0.isNewline || $0 == "\t" }).compactMap { Int($0) } }

    static func parse(_ data: Data) throws -> XMLTree {
        let b = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = b
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = b.root else {
            throw LoftLineIOError.malformed(parser.parserError?.localizedDescription ?? "unreadable XML")
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLTree?
        var stack: [XMLTree] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let node = XMLTree(name: elementName.split(separator: ":").last.map(String.init) ?? elementName,
                               attributes: attributeDict)
            if let top = stack.last { top.children.append(node) } else { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) { _ = stack.popLast() }
    }
}
