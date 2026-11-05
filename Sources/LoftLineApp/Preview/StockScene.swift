// SceneKit scene for the 3D material-removal preview. Owned by the preview workstream.
import AppKit
import CADCore
import CAMCore
import SceneKit
import LoftLineKit

/// Owns the SceneKit scene: lit stock mesh, cutter marker and an orbit camera.
/// The content node uses the material frame with Z up (top at z = 0); it is rotated so that
/// material Z becomes SceneKit's +Y.
@MainActor
final class StockScene {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    /// Material-frame node (Z up, top at z = 0).
    let content = SCNNode()
    private let stockNode = SCNNode()
    private let toolNode = SCNNode()
    private let measureNode = SCNNode()
    private let overlayNode = SCNNode()
    private(set) var job = JobSetup()
    /// Specular strength of the stock (0...1), from the material appearance.
    var shininess = 0.15
    /// The on-screen view (for its camera when saving an image).
    weak var attachedView: SCNView?

    init() {
        scene.background.contents = NSColor(calibratedWhite: 0.16, alpha: 1)
        content.eulerAngles.x = -.pi / 2
        scene.rootNode.addChildNode(content)
        content.addChildNode(stockNode)
        content.addChildNode(toolNode)
        content.addChildNode(measureNode)
        content.addChildNode(overlayNode)

        let camera = SCNCamera()
        camera.zNear = 0.01
        camera.zFar = 10_000
        camera.fieldOfView = 40
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 800
        key.light?.castsShadow = false
        key.eulerAngles = SCNVector3(-1.0, 0.9, 0)
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.intensity = 300
        fill.eulerAngles = SCNVector3(-0.4, -2.4, 0)
        scene.rootNode.addChildNode(fill)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 160
        scene.rootNode.addChildNode(ambient)
    }

    /// Material centre in scene coordinates (orbit target).
    var center: SCNVector3 {
        SCNVector3(job.width / 2, -job.thickness / 2, -job.height / 2)
    }

    /// Frames the new stock from the last chosen standard direction.
    func configure(job: JobSetup) {
        self.job = job
        setView(viewDirection)
    }

    func resetCamera() { setView(.threeQuarter) }

    /// The standard direction last chosen (the camera may have been orbited since).
    private(set) var viewDirection = PreviewViewDirection.threeQuarter

    /// Scene-space point for a material-frame point (material Z becomes scene +Y).
    static func scenePoint(_ p: Vec3) -> SCNVector3 { SCNVector3(p.x, p.z, -p.y) }

    /// Width / height of the on-screen view (1.5 before it is laid out).
    private var viewAspect: Double {
        guard let v = attachedView, v.bounds.width > 1, v.bounds.height > 1 else { return 1.5 }
        return Double(v.bounds.width / v.bounds.height)
    }

    /// Moves the camera to look at the whole stock from `direction`.
    func setView(_ direction: PreviewViewDirection) {
        viewDirection = direction
        // The view may have swapped in its own free camera while orbiting; take ours back.
        if let v = attachedView, v.pointOfView !== cameraNode {
            cameraNode.camera?.usesOrthographicProjection = isOrthographic
            v.pointOfView = cameraNode
        }
        guard let camera = cameraNode.camera else { return }
        let pose = PreviewCameraPose(direction: direction, job: job, fieldOfView: Double(camera.fieldOfView),
                                     aspect: viewAspect)
        cameraNode.position = Self.scenePoint(pose.eye)
        cameraNode.look(at: Self.scenePoint(pose.target), up: Self.scenePoint(pose.up),
                        localFront: SCNVector3(0, 0, -1))
        camera.orthographicScale = pose.orthographicScale
    }

    /// The camera the view is rendering from (ours unless the view swapped in its own).
    private var activeCameraNode: SCNNode { attachedView?.pointOfView ?? cameraNode }

    /// Orthographic (parallel) projection instead of perspective. Switching keeps the view
    /// direction and roughly the same framing at the stock centre.
    var isOrthographic: Bool {
        get { activeCameraNode.camera?.usesOrthographicProjection ?? false }
        set {
            let node = activeCameraNode
            guard let camera = node.camera, camera.usesOrthographicProjection != newValue else { return }
            if newValue {
                let p = node.worldPosition, c = center
                let d = Double(SCNVector3Distance(p, c))
                camera.orthographicScale = PreviewCameraPose.orthographicScale(distance: d,
                                                                               fieldOfView: Double(camera.fieldOfView))
            }
            camera.usesOrthographicProjection = newValue
        }
    }

    func updateStock(_ mesh: HeightfieldMesh) {
        stockNode.geometry = Self.geometry(from: mesh, shininess: shininess)
    }

    /// Shows the cutter with its tip at material-frame `tip` (depth below top as negative z).
    func updateTool(tip: Vec3?, shape: ToolShape?) {
        guard let tip, let shape else { toolNode.isHidden = true; return }
        toolNode.isHidden = false
        if toolNode.name != Self.key(shape) {
            toolNode.childNodes.forEach { $0.removeFromParentNode() }
            toolNode.addChildNode(Self.cutterNode(shape, units: job))
            toolNode.name = Self.key(shape)
        }
        toolNode.position = SCNVector3(tip.x, tip.y, tip.z)
    }

    private static func key(_ s: ToolShape) -> String { "\(s)" }

    // MARK: Measuring

    /// True for hits on the stock mesh (not the cutter or markers).
    func isStock(_ node: SCNNode) -> Bool { node === stockNode }

    /// Material-frame point (z = -depth) for a scene (world) position.
    func materialPoint(fromWorld p: SCNVector3) -> Vec3 {
        let l = content.convertPosition(p, from: nil)
        return Vec3(Double(l.x), Double(l.y), Double(l.z))
    }

    /// Marker spheres at material-frame `points` and a line between the first two.
    func showMeasurement(_ points: [Vec3]) {
        measureNode.childNodes.forEach { $0.removeFromParentNode() }
        guard !points.isEmpty else { return }
        let size = CGFloat(max(job.width, job.height, 1e-3)) * 0.004
        let mat = SCNMaterial()
        mat.diffuse.contents = NSColor.systemYellow
        mat.emission.contents = NSColor.systemYellow.withAlphaComponent(0.6)
        mat.lightingModel = .constant
        mat.readsFromDepthBuffer = false
        for p in points {
            let s = SCNSphere(radius: size)
            s.materials = [mat]
            let n = SCNNode(geometry: s)
            n.position = SCNVector3(p.x, p.y, p.z)
            n.renderingOrder = 10
            measureNode.addChildNode(n)
        }
        if points.count == 2 {
            let a = points[0], b = points[1]
            let src = SCNGeometrySource(vertices: [SCNVector3(a.x, a.y, a.z), SCNVector3(b.x, b.y, b.z)])
            let el = SCNGeometryElement(indices: [UInt32(0), UInt32(1)], primitiveType: .line)
            let g = SCNGeometry(sources: [src], elements: [el])
            g.materials = [mat]
            let n = SCNNode(geometry: g)
            n.renderingOrder = 10
            measureNode.addChildNode(n)
        }
    }

    // MARK: Toolpath and vector lines

    /// Line colours of the 3D overlay.
    enum OverlayColor {
        static let rapid = CAMCore.RGBColor(1.0, 0.55, 0.05)
        static let vector = CAMCore.RGBColor(0.08, 0.08, 0.1)
        static let selected = CAMCore.RGBColor(0.1, 0.45, 1.0)
        static let draft = CAMCore.RGBColor(0.95, 0.15, 0.75)
    }

    // MARK: Drawing in 3D

    private lazy var draftNode: SCNNode = {
        let n = SCNNode()
        content.addChildNode(n)
        return n
    }()

    /// The polyline being drawn: lines plus a marker at each clicked point, on the material top.
    func showDraft(_ points: [Vec2]) {
        draftNode.childNodes.forEach { $0.removeFromParentNode() }
        guard !points.isEmpty else { return }
        var positions: [Float] = [], colors: [Float] = [], indices: [UInt32] = []
        let c = OverlayColor.draft
        for (k, p) in points.enumerated() {
            positions += [Float(p.x), Float(p.y), 0]
            colors += [c.r, c.g, c.b]
            if k > 0 { indices += [UInt32(k - 1), UInt32(k)] }
        }
        if !indices.isEmpty {
            let n = SCNNode(geometry: Self.lineGeometry(positions: positions, colors: colors, indices: indices))
            n.renderingOrder = 12
            draftNode.addChildNode(n)
        }
        let size = CGFloat(max(job.width, job.height, 1e-3)) * 0.003
        let mat = SCNMaterial()
        mat.diffuse.contents = NSColor(calibratedRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1)
        mat.lightingModel = .constant
        mat.readsFromDepthBuffer = false
        for p in points {
            let s = SCNSphere(radius: size)
            s.materials = [mat]
            let n = SCNNode(geometry: s)
            n.position = SCNVector3(p.x, p.y, 0)
            n.renderingOrder = 12
            draftNode.addChildNode(n)
        }
    }

    /// Lines of the polyline being drawn (for tests).
    var draftLineCount: Int {
        draftNode.childNodes.compactMap { n -> Int? in
            guard let e = n.geometry?.elements.first, e.primitiveType == .line else { return nil }
            return e.primitiveCount
        }.reduce(0, +)
    }

    /// Material-frame point on the material-top plane (z = 0) under a view point, or nil when the
    /// view ray is parallel to it or points away.
    func materialTopPoint(near: SCNVector3, far: SCNVector3) -> Vec3? {
        let a = materialPoint(fromWorld: near), b = materialPoint(fromWorld: far)
        let dz = b.z - a.z
        guard abs(dz) > 1e-12 else { return nil }
        let t = -a.z / dz
        guard t >= 0 else { return nil }
        return Vec3(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, 0)
    }

    /// Draws toolpath centre lines (cuts coloured by depth, rapids red when `showRapids`) and
    /// design vectors on the material top. Lines are drawn over the stock so cuts stay visible
    /// inside the simulated grooves.
    func showOverlay(toolpaths lines: ToolpathLines3D?, showRapids: Bool, vectors: [[Vec2]],
                     selected: [[Vec2]] = []) {
        overlayNode.childNodes.forEach { $0.removeFromParentNode() }
        if let g = Self.overlayGeometry(toolpaths: lines, showRapids: showRapids, vectors: vectors,
                                        selected: selected) {
            let n = SCNNode(geometry: g)
            n.renderingOrder = 5
            overlayNode.addChildNode(n)
        }
    }

    /// True when overlay lines are showing (for tests).
    var overlayLineCount: Int {
        overlayNode.childNodes.compactMap { $0.geometry?.elements.first?.primitiveCount }.reduce(0, +)
    }

    /// One line-list geometry with per-vertex colours, or nil when there is nothing to draw.
    static func overlayGeometry(toolpaths lines: ToolpathLines3D?, showRapids: Bool,
                                vectors: [[Vec2]], selected: [[Vec2]] = []) -> SCNGeometry? {
        var positions: [Float] = [], colors: [Float] = [], indices: [UInt32] = []
        func add(_ pts: [Vec3], color: (Vec3) -> CAMCore.RGBColor) {
            guard pts.count >= 2 else { return }
            let base = UInt32(positions.count / 3)
            for p in pts {
                positions += [Float(p.x), Float(p.y), Float(p.z)]
                let c = color(p)
                colors += [c.r, c.g, c.b]
            }
            for k in 0..<UInt32(pts.count - 1) { indices += [base + k, base + k + 1] }
        }
        if let lines {
            let maxDepth = max(lines.maxDepth, 1e-9)
            for l in lines.polylines {
                if l.isRapid {
                    if showRapids { add(l.points) { _ in OverlayColor.rapid } }
                } else {
                    add(l.points) { DepthColorRamp.toolpath(normalizedDepth: max(0, -$0.z) / maxDepth) }
                }
            }
        }
        for v in vectors { add(v.map { Vec3($0, z: 0) }) { _ in OverlayColor.vector } }
        for v in selected { add(v.map { Vec3($0, z: 0) }) { _ in OverlayColor.selected } }
        guard !indices.isEmpty else { return nil }
        return lineGeometry(positions: positions, colors: colors, indices: indices)
    }

    /// Unlit line list drawn over the stock (no depth test).
    private static func lineGeometry(positions: [Float], colors: [Float], indices: [UInt32]) -> SCNGeometry {
        let n = positions.count / 3
        func source(_ values: [Float], _ semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
            let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
            return SCNGeometrySource(data: data, semantic: semantic, vectorCount: n,
                                     usesFloatComponents: true, componentsPerVector: 3,
                                     bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                     dataStride: 3 * MemoryLayout<Float>.size)
        }
        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(data: indexData, primitiveType: .line,
                                         primitiveCount: indices.count / 2,
                                         bytesPerIndex: MemoryLayout<UInt32>.size)
        let g = SCNGeometry(sources: [source(positions, .vertex), source(colors, .color)], elements: [element])
        let m = SCNMaterial()
        m.diffuse.contents = NSColor.white // multiplied by the vertex colours
        m.lightingModel = .constant
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        g.materials = [m]
        return g
    }

    private static func cutterNode(_ shape: ToolShape, units job: JobSetup) -> SCNNode {
        let r = CGFloat(shape.radius)
        let shankLength = CGFloat(max(job.thickness * 2, shape.radius * 8))
        let steel = SCNMaterial()
        steel.diffuse.contents = NSColor(calibratedWhite: 0.78, alpha: 1)
        steel.specular.contents = NSColor.white
        steel.lightingModel = .blinn

        // Built along +Y with the tip at the origin, then rotated so +Y becomes material +Z.
        let root = SCNNode()
        root.eulerAngles.x = .pi / 2
        var shankBase: CGFloat = 0
        switch shape {
        case .flat:
            break
        case .ball:
            let s = SCNSphere(radius: r)
            s.materials = [steel]
            let n = SCNNode(geometry: s)
            n.position = SCNVector3(0, r, 0)
            root.addChildNode(n)
            shankBase = r
        case .vee(_, let tip, let half):
            let h = CGFloat((shape.radius - tip) / tan(half))
            let cone = SCNCone(topRadius: r, bottomRadius: CGFloat(tip), height: max(h, 1e-4))
            cone.materials = [steel]
            let n = SCNNode(geometry: cone)
            n.position = SCNVector3(0, h / 2, 0)
            root.addChildNode(n)
            shankBase = h
        case .shaped:
            // Stack of frustums following the outline (lowest height at each radius).
            let n = 24
            var prev: (r: Double, h: Double) = (0, shape.heightAboveTip(atRadius: 0) ?? 0)
            for k in 1...n {
                let rk = shape.radius * Double(k) / Double(n)
                let hk = shape.heightAboveTip(atRadius: rk) ?? prev.h
                let dh = hk - prev.h
                if dh > 1e-6 {
                    let f = SCNCone(topRadius: CGFloat(rk), bottomRadius: CGFloat(prev.r), height: CGFloat(dh))
                    f.materials = [steel]
                    let node = SCNNode(geometry: f)
                    node.position = SCNVector3(0, CGFloat(prev.h + dh / 2), 0)
                    root.addChildNode(node)
                }
                prev = (rk, hk)
            }
            shankBase = CGFloat(prev.h)
        }
        let shank = SCNCylinder(radius: r, height: shankLength)
        shank.materials = [steel]
        let sn = SCNNode(geometry: shank)
        sn.position = SCNVector3(0, shankBase + shankLength / 2, 0)
        root.addChildNode(sn)
        return root
    }

    static func geometry(from mesh: HeightfieldMesh, shininess: Double = 0.15) -> SCNGeometry {
        let n = mesh.vertexCount
        func source(_ values: [Float], _ semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
            let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
            return SCNGeometrySource(data: data, semantic: semantic, vectorCount: n,
                                     usesFloatComponents: true, componentsPerVector: 3,
                                     bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                     dataStride: 3 * MemoryLayout<Float>.size)
        }
        let indexData = mesh.indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(data: indexData, primitiveType: .triangles,
                                         primitiveCount: mesh.triangleCount,
                                         bytesPerIndex: MemoryLayout<UInt32>.size)
        let geo = SCNGeometry(sources: [source(mesh.positions, .vertex), source(mesh.normals, .normal),
                                        source(mesh.colors, .color)],
                              elements: [element])
        let m = SCNMaterial()
        m.diffuse.contents = NSColor.white // multiplied by the vertex colours
        m.specular.contents = NSColor(calibratedWhite: CGFloat(min(max(shininess, 0), 1)), alpha: 1)
        m.shininess = CGFloat(0.1 + 0.6 * min(max(shininess, 0), 1))
        m.lightingModel = .blinn
        m.isDoubleSided = true
        geo.materials = [m]
        return geo
    }
}

private func SCNVector3Distance(_ a: SCNVector3, _ b: SCNVector3) -> CGFloat {
    let dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z
    return (dx * dx + dy * dy + dz * dz).squareRoot()
}
