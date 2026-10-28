import CoreGraphics
import Foundation
import Testing
@testable import CADCore

/// Corrupt or hostile numbers (NaN, infinity, absurd magnitudes, too few points) must never
/// trap an integer conversion, index outside an array or abort inside Clipper. Each case here
/// crashed the process before the guard it exercises existed.
@Suite struct HostileInputTests {
    // MARK: Crafted files from the 2026-10-28 review (#121): each hung or trapped before its guard.

    static func dae(_ body: String, scene: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">
          <asset><unit name="inch" meter="0.0254"/><up_axis>Z_UP</up_axis></asset>
          <library_geometries>
            <geometry id="trig"><mesh>
              <source id="trip"><float_array id="tripa" count="9">0 0 0 1 0 0 0 1 0</float_array>
                <technique_common><accessor source="#tripa" count="3" stride="3"/></technique_common></source>
              <vertices id="triv"><input semantic="POSITION" source="#trip"/></vertices>
              \(body)
            </mesh></geometry>
          </library_geometries>
          <library_nodes>\(scene)</library_nodes>
          <library_visual_scenes><visual_scene id="scene"><node><instance_node url="#a"/></node></visual_scene></library_visual_scenes>
          <scene><instance_visual_scene url="#scene"/></scene>
        </COLLADA>
        """.utf8)
    }

    @Test(.timeLimit(.minutes(1))) func dxfEllipseWithAHugeStartAngleImports() throws {
        let dxf = "0\nSECTION\n2\nENTITIES\n0\nELLIPSE\n8\n0\n10\n0\n20\n0\n30\n0\n11\n1\n21\n0\n31\n0\n40\n0.5\n41\n1e20\n42\n0\n0\nENDSEC\n0\nEOF\n"
        _ = try? DXFImporter().importVectors(from: Data(dxf.utf8), targetUnits: .inch)
    }

    @Test func svgCubicWithAstronomicalControlPointsDoesNotTrap() throws {
        _ = try? SVGImporter().importVectors(from: Data(#"<svg><path d="M0 0 C1e50 0 0 0 1 0"/></svg>"#.utf8), targetUnits: .inch)
        var pts: [Vec2] = []
        Flattening.append(segment: .cubic(to: Vec2(1, 0), control1: Vec2(1e50, 0), control2: Vec2(0, 0)),
                          from: Vec2(0, 0), tolerance: 0.001, to: &pts)
        #expect(!pts.isEmpty && pts.count <= 1000)
    }

    @Test(.timeLimit(.minutes(1))) func svgSelfReferencingUseIsBounded() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="10in" height="10in">
          <defs><g id="a"><rect width="1" height="1"/><use href="#a"/><use href="#a"/><use href="#a"/><use href="#a"/></g></defs>
          <use href="#a"/>
        </svg>
        """
        _ = try? SVGImporter().importVectors(from: Data(svg.utf8), targetUnits: .inch)
    }

    @Test func pdfImageSizeOverflowIsRejected() {
        #expect(PDFImporter.imageByteCount(width: 2_147_483_647, height: 2_147_483_647, components: 4) == nil)
        #expect(PDFImporter.imageByteCount(width: Int.max, height: 2, components: 1) == nil)
        #expect(PDFImporter.imageByteCount(width: 4, height: 3, components: 3) == 36)
    }

    @Test func colladaNegativeOrHugeOffsetsAreSkipped() throws {
        for offset in ["-1", "9223372036854775807"] {
            let tri = """
            <triangles count="1"><input semantic="VERTEX" source="#triv" offset="\(offset)"/>\
            <input semantic="NORMAL" source="#n" offset="0"/><p>0 0 1 0 2 0</p></triangles>
            """
            _ = try? DAEImporter().importMesh(from: Self.dae(tri, scene: ##"<node id="a"><instance_geometry url="#trig"/></node>"##),
                                              targetUnits: .inch)
        }
    }

    @Test(.timeLimit(.minutes(1))) func colladaSelfReferencingNodesAreBounded() throws {
        let tri = ##"<triangles count="1"><input semantic="VERTEX" source="#triv" offset="0"/><p>0 1 2</p></triangles>"##
        let scene = ##"<node id="a"><instance_geometry url="#trig"/><instance_node url="#a"/><instance_node url="#a"/></node>"##
        // Past the limit the import fails with a reason, never returns part of the model.
        #expect(throws: LoftLineIOError.self) { try DAEImporter().importMesh(from: Self.dae(tri, scene: scene), targetUnits: .inch) }
    }

    @Test func colladaPolylistCountsThatOverflowAreSkipped() throws {
        let poly = ##"<polylist count="2"><input semantic="VERTEX" source="#triv" offset="0"/><vcount>3 9223372036854775807</vcount><p>0 1 2</p></polylist>"##
        let mesh = try DAEImporter().importMesh(from: Self.dae(poly, scene: ##"<node id="a"><instance_geometry url="#trig"/></node>"##),
                                                targetUnits: .inch)
        #expect(mesh.triangleCount == 1)
    }

    @Test func colladaOffsetThatCannotBeReadSkipsThePrimitive() {
        let tri = ##"<triangles count="1"><input semantic="VERTEX" source="#triv" offset="9223372036854775808"/><p>0 1 2</p></triangles>"##
        #expect(throws: LoftLineIOError.self) {
            try DAEImporter().importMesh(from: Self.dae(tri, scene: ##"<node id="a"><instance_geometry url="#trig"/></node>"##),
                                         targetUnits: .inch)
        }
    }

    @Test func meshIndicesOutOfRangeAreRefusedOnDecode() throws {
        let v = #"[{"x":0,"y":0,"z":0},{"x":1,"y":0,"z":0},{"x":0,"y":1,"z":0}]"#
        let json = #"{"vertices":"# + v + #","indices":[0,1,4294967295]}"#
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Mesh3D.self, from: Data(json.utf8)) }
        let good = #"{"vertices":"# + v + #","indices":[0,1,2]}"#
        #expect(try JSONDecoder().decode(Mesh3D.self, from: Data(good.utf8)).triangleCount == 1)
    }

    @Test func kernelDropsPathsClipperCannotRepresent() {
        let bad: [Vec2] = [Vec2(0, 0), Vec2(.infinity, 0), Vec2(10, 10)]
        let huge: [Vec2] = [Vec2(0, 0), Vec2(5e12, 0), Vec2(5e12, 5e12)]
        let good = ShapeFactory.rectangle(Rect2(x: 0, y: 0, width: 2, height: 2)).flattened()
        #expect(GeomKernel.offset([bad], by: 1).isEmpty)
        #expect(GeomKernel.offset([[Vec2(0, 0), Vec2(.nan, 1), Vec2(1, 1)]], by: 1).isEmpty)
        // The representable path still goes through; the others are dropped, not fatal.
        let union = GeomKernel.boolean(.union, subject: [good, huge, bad], clip: [])
        #expect(union.count == 1)
        #expect(approx(abs(Path(points: union[0], closed: true).signedArea()), 4))
    }

    @Test func zeroOffsetOfAnOpenPathIsEmptyNotAClosedPolygon() {
        let open = Path(points: [Vec2(0, 0), Vec2(1, 0), Vec2(1, 1), Vec2(0, 1)], closed: false)
        #expect(PathOps.offsetOpen([open], by: 0).isEmpty)
        #expect(PathOps.offsetOpen([open], by: 0.1).count == 1)
    }

    @Test func flatteningCorruptCurvesFallsBackToLines() {
        var pts: [Vec2] = []
        Flattening.append(segment: .arc(to: Vec2(1, 0), center: Vec2(.nan, 0), clockwise: false),
                          from: Vec2(0, 0), tolerance: 0.001, to: &pts)
        Flattening.append(segment: .cubic(to: Vec2(2, 0), control1: Vec2(.infinity, 0), control2: Vec2(1, 1)),
                          from: Vec2(1, 0), tolerance: 0.001, to: &pts)
        #expect(pts == [Vec2(1, 0), Vec2(2, 0)])
        #expect(Flattening.arcToCubics(from: Vec2(0, 0), to: Vec2(1, 0), center: Vec2(.nan, 0), clockwise: true)
                == [.line(to: Vec2(1, 0))])
    }

    @Test func svgArcWithOverflowingRadiusImportsAsALine() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20">
        <path d="M0 0 A1e999 1 0 0 1 10 10 L1e999 0 Z"/></svg>
        """
        let r = try SVGImporter().importVectors(from: Data(svg.utf8), targetUnits: .millimeter)
        #expect(r.shapes.count == 1)
        #expect(r.shapes[0].paths[0].segments.allSatisfy { if case .line = $0 { return true } else { return false } })
    }

    @Test func svgWithViewBoxAndOnlyAWidthKeepsTheViewBoxAspect() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="100mm" viewBox="0 0 100 50">
        <rect x="0" y="0" width="100" height="50"/></svg>
        """
        let r = try SVGImporter().importVectors(from: Data(svg.utf8), targetUnits: .millimeter)
        #expect(approx(r.shapes[0].bounds(), Rect2(x: 0, y: 0, width: 100, height: 50), 1e-6))
        let tall = svg.replacingOccurrences(of: "width=\"100mm\"", with: "height=\"25mm\"")
        let t = try SVGImporter().importVectors(from: Data(tall.utf8), targetUnits: .millimeter)
        #expect(approx(t.shapes[0].bounds(), Rect2(x: 0, y: 0, width: 50, height: 25), 1e-6))
    }

    @Test func dxfSplineWithFewerControlPointsThanItsDegreeImports() throws {
        // No group 71 (degree defaults to 3) and only two control points: a sloppy exporter's
        // way of writing a line as a SPLINE.
        let two = dxf(entities: [(0, "SPLINE"), (8, "0"), (70, "0"), (10, "0"), (20, "0"), (10, "10"), (20, "5")])
        let r = try DXFImporter().importVectors(from: two, targetUnits: .millimeter)
        #expect(r.shapes.count == 1)
        #expect(approx(r.shapes[0].bounds(), Rect2(x: 0, y: 0, width: 10, height: 5), 1e-6))
        let three = dxf(entities: [(0, "SPLINE"), (8, "0"), (70, "0"), (71, "3"),
                                   (10, "0"), (20, "0"), (10, "5"), (20, "5"), (10, "10"), (20, "0")])
        #expect(try DXFImporter().importVectors(from: three, targetUnits: .millimeter).shapes.count == 1)
    }

    @Test func dxfToleratesTrailingBlankLinesTextAfterEOFAndCROnlyLineEndings() throws {
        let base = String(decoding: dxf(entities: [(0, "LINE"), (8, "0"), (10, "0"), (20, "0"), (11, "4"), (21, "0")]),
                          as: UTF8.self)
        for variant in [base + "\n\n", base + "\r\n\r\n", base + "junk\n", base.replacingOccurrences(of: "\n", with: "\r")] {
            let r = try DXFImporter().importVectors(from: Data(variant.utf8), targetUnits: .millimeter)
            #expect(r.shapes.count == 1, "variant \(variant.suffix(12).debugDescription)")
        }
        let nan = dxf(entities: [(0, "LWPOLYLINE"), (8, "0"), (70, "nan"), (90, "INF"), (10, "0"), (20, "0"), (10, "1"), (20, "1")])
        _ = try? DXFImporter().importVectors(from: nan, targetUnits: .millimeter)   // must not trap
    }

    @Test func epsAndPdfFillsCloseTheSubpath() throws {
        let eps = """
        %!PS-Adobe-3.0 EPSF-3.0
        %%BoundingBox: 0 0 100 100
        10 10 moveto 50 10 lineto 50 50 lineto fill
        10 60 moveto 50 60 lineto 50 90 lineto stroke
        """
        let r = try EPSImporter().importVectors(from: Data(eps.utf8), targetUnits: .millimeter)
        #expect(r.shapes.count == 2)
        #expect(r.shapes[0].isClosed)
        #expect(!r.shapes[1].isClosed)

        let out = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let ctx = CGContext(consumer: CGDataConsumer(data: out as CFMutableData)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.move(to: CGPoint(x: 10, y: 10)); ctx.addLine(to: CGPoint(x: 50, y: 10)); ctx.addLine(to: CGPoint(x: 50, y: 50))
        ctx.fillPath()
        ctx.endPDFPage(); ctx.closePDF()
        let p = try PDFImporter().importVectors(from: out as Data, targetUnits: .millimeter)
        #expect(p.shapes.count == 1)
        #expect(p.shapes[0].isClosed)
    }

    @Test func meshImportersRejectNonFiniteVertices() {
        var d = Data(repeating: 0, count: 80)
        var n = UInt32(1).littleEndian
        d.append(Data(bytes: &n, count: 4))
        func put(_ f: Float) { var b = f.bitPattern.littleEndian; d.append(Data(bytes: &b, count: 4)) }
        for _ in 0..<3 { put(0) }
        for v in [Float(0), 0, 0, 1, 0, 0, .nan, 1, 0] { put(v) }
        d.append(contentsOf: [0, 0])
        #expect(throws: LoftLineIOError.self) { try STLImporter.parseBinary(d) }
        #expect(throws: LoftLineIOError.self) {
            try OBJImporter().importMesh(from: Data("v 0 0 0\nv 1 0 0\nv nan 1 0\nf 1 2 3\n".utf8), targetUnits: .millimeter)
        }
        // A finite but absurd vertex quantises without trapping the Int64 merge key.
        let far = STLImporter.indexed([(Vec3(0, 0, 0), Vec3(1e30, 0, 0), Vec3(0, 1, 0))], scale: 1)
        #expect(far.vertices.count == 3)
    }

    @Test func expressionNestingIsBounded() throws {
        // Deep enough to overflow a 512 KB thread stack without the depth cap.
        let deep = String(repeating: "(", count: 100_000) + "1" + String(repeating: ")", count: 100_000)
        #expect(throws: ExpressionEvaluator.ExpressionError.self) { try ExpressionEvaluator.evaluate(deep) }
        #expect(throws: ExpressionEvaluator.ExpressionError.self) {
            try ExpressionEvaluator.evaluate(String(repeating: "-", count: 100_000) + "1")
        }
        #expect(try ExpressionEvaluator.evaluate(String(repeating: "(", count: 40) + "2" + String(repeating: ")", count: 40)) == 2)
        #expect(try ExpressionEvaluator.evaluate("--3") == 3)
    }

    @Test func documentWithoutLayersIsRepairedOnLoad() throws {
        var doc = Document(name: "Empty", units: .inch)
        let orphan = Shape(layerID: UUID(), paths: [ShapeFactory.circle(center: .zero, radius: 1)])
        doc.add(orphan)
        doc.layers = []
        let back = try DocumentFile.decode(from: try DocumentFile.encode(doc))
        #expect(back.layers.count == 1)
        #expect(back.shapes.map(\.layerID) == [back.layers[0].id])
        #expect(doc.defaultLayerID != orphan.layerID)   // an empty document still answers
    }
}
