import CoreGraphics
import Foundation

/// PDF and PDF-based Illustrator (.ai) import. Reads the vector paths of the first page with
/// Core Graphics' content-stream scanner (m l c v y h re + paint operators, q/Q, cm, Form
/// XObjects). Each painted path becomes one shape; clip-only paths (`W n`) and text are skipped.
/// Units are PDF points (1/72 in); the page's crop box lower-left becomes (0,0).
/// Embedded raster images are returned in `images` (placement rectangle + encoded data).
public struct PDFImporter: VectorImporter {
    public static let fileExtensions = ["pdf"]
    public init() {}

    /// A raster image drawn on the page (`Do` of an Image XObject), in target units.
    public typealias EmbeddedImage = ImportedImage

    /// Vectors of page 1 plus its embedded images (in `ImportResult.images`).
    /// Bytes an uncompressed image of these dimensions needs, or nil when the product overflows (a crafted /Width and /Height
    /// near Int32.max would trap the multiplication before the size check, #121).
    static func imageByteCount(width: Int, height: Int, components: Int) -> Int? {
        let (wh, o1) = width.multipliedReportingOverflow(by: height)
        let (n, o2) = wh.multipliedReportingOverflow(by: components)
        return o1 || o2 ? nil : n
    }

    public func importVectors(from data: Data, targetUnits: LengthUnit) throws -> ImportResult {
        let (r, images) = try importPage(from: data, targetUnits: targetUnits, includeImages: true)
        var result = r
        result.images = images
        return result
    }

    /// Vectors plus (optionally) embedded images of the first page.
    public func importPage(from data: Data, targetUnits: LengthUnit,
                           includeImages: Bool) throws -> (result: ImportResult, images: [EmbeddedImage]) {
        guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider) else {
            throw LoftLineIOError.malformed("PDF: not a readable PDF document")
        }
        if pdf.isEncrypted && !pdf.isUnlocked { throw LoftLineIOError.malformed("PDF: the document is password protected") }
        guard pdf.numberOfPages >= 1, let page = pdf.page(at: 1) else { throw LoftLineIOError.malformed("PDF: no pages") }

        let state = ScanState()
        state.includeImages = includeImages
        let box = page.getBoxRect(.cropBox)
        let ptToUnit = LengthUnit.inch.convert(1.0 / 72, to: targetUnits)
        state.ctm = Transform2D.translation(Vec2(-Double(box.minX), -Double(box.minY)))
            .concatenating(.scale(ptToUnit, ptToUnit))
        state.scan(CGPDFContentStreamCreateWithPage(page))

        let layer = Layer(name: "PDF Import", colorHex: SVGImporter.palette[0])
        let shapes = state.shapes.map {
            Shape(name: "Path", layerID: layer.id, paths: $0, origin: .imported(format: "pdf"))
        }
        var warnings: [String] = []
        if pdf.numberOfPages > 1 { warnings.append("Only page 1 of \(pdf.numberOfPages) was imported.") }
        if state.textObjects > 0 {
            warnings.append("\(state.textObjects) text object(s) were skipped; convert text to outlines first.")
        }
        if state.skippedImages > 0 { warnings.append("\(state.skippedImages) embedded image(s) were skipped.") }
        warnings += ImportGaps.warnings(shapes: shapes, layers: [layer], units: targetUnits)
        let images = state.images.map {
            EmbeddedImage(rect: $0.rect, png: $0.png)
        }
        return (ImportResult(layers: shapes.isEmpty ? [] : [layer], shapes: shapes, warnings: warnings), images)
    }
}

/// Mutable interpreter state handed to the C scanner callbacks through `info`.
private final class ScanState {
    var ctm = Transform2D.identity
    var stack: [Transform2D] = []
    var paths: [Path] = []
    var sub: Path?
    var point = Vec2.zero
    var shapes: [[Path]] = []
    var textObjects = 0
    var skippedImages = 0
    var includeImages = false
    var images: [(rect: Rect2, png: Data)] = []
    var resources: [CGPDFContentStreamRef] = []
    var formDepth = 0

    func map(_ x: Double, _ y: Double) -> Vec2 {
        Vec2(ctm.a * x + ctm.c * y + ctm.tx, ctm.b * x + ctm.d * y + ctm.ty)
    }

    func endSub() {
        if let s = sub, !s.segments.isEmpty { paths.append(s) }
        sub = nil
    }

    func moveTo(_ p: Vec2) { endSub(); sub = Path(start: p); point = p }
    func lineTo(_ p: Vec2) {
        if sub == nil { sub = Path(start: point) }
        sub?.segments.append(.line(to: p)); point = p
    }
    func curveTo(_ c1: Vec2, _ c2: Vec2, _ p: Vec2) {
        if sub == nil { sub = Path(start: point) }
        sub?.segments.append(.cubic(to: p, control1: c1, control2: c2)); point = p
    }
    func close() {
        guard var s = sub else { return }
        if let last = s.segments.last?.end, last.isApproximatelyEqual(to: s.start, tolerance: 1e-9),
           case .line = s.segments.last! { s.segments.removeLast() }
        if !s.segments.isEmpty { s.isClosed = true; paths.append(s) }
        sub = nil
        point = s.start
    }

    func paint(closing: Bool) {
        if closing { close() } else { endSub() }
        if !paths.isEmpty { shapes.append(paths) }
        paths = []
    }

    func discard() { sub = nil; paths = [] }

    func scan(_ stream: CGPDFContentStreamRef) {
        guard formDepth < 8 else { return }
        let table = Self.table
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
        resources.append(stream)
        CGPDFScannerScan(scanner)
        resources.removeLast()
        CGPDFScannerRelease(scanner)
    }

    static func state(_ info: UnsafeMutableRawPointer?) -> ScanState {
        Unmanaged<ScanState>.fromOpaque(info!).takeUnretainedValue()
    }

    static func pop(_ s: CGPDFScannerRef, _ n: Int) -> [Double]? {
        var out = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var v: CGPDFReal = 0
            guard CGPDFScannerPopNumber(s, &v) else { return nil }
            out[i] = Double(v)
        }
        return out
    }

    static let table: CGPDFOperatorTableRef = {
        let t = CGPDFOperatorTableCreate()!
        CGPDFOperatorTableSetCallback(t, "q") { _, info in let st = ScanState.state(info); st.stack.append(st.ctm) }
        CGPDFOperatorTableSetCallback(t, "Q") { _, info in
            let st = ScanState.state(info); if let m = st.stack.popLast() { st.ctm = m }
        }
        CGPDFOperatorTableSetCallback(t, "cm") { s, info in
            let st = ScanState.state(info)
            guard let n = ScanState.pop(s, 6) else { return }
            st.ctm = Transform2D(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5]).concatenating(st.ctm)
        }
        CGPDFOperatorTableSetCallback(t, "m") { s, info in
            let st = ScanState.state(info); guard let n = ScanState.pop(s, 2) else { return }
            st.moveTo(st.map(n[0], n[1]))
        }
        CGPDFOperatorTableSetCallback(t, "l") { s, info in
            let st = ScanState.state(info); guard let n = ScanState.pop(s, 2) else { return }
            st.lineTo(st.map(n[0], n[1]))
        }
        CGPDFOperatorTableSetCallback(t, "c") { s, info in
            let st = ScanState.state(info); guard let n = ScanState.pop(s, 6) else { return }
            st.curveTo(st.map(n[0], n[1]), st.map(n[2], n[3]), st.map(n[4], n[5]))
        }
        CGPDFOperatorTableSetCallback(t, "v") { s, info in
            let st = ScanState.state(info); guard let n = ScanState.pop(s, 4) else { return }
            st.curveTo(st.point, st.map(n[0], n[1]), st.map(n[2], n[3]))
        }
        CGPDFOperatorTableSetCallback(t, "y") { s, info in
            let st = ScanState.state(info); guard let n = ScanState.pop(s, 4) else { return }
            let p = st.map(n[2], n[3])
            st.curveTo(st.map(n[0], n[1]), p, p)
        }
        CGPDFOperatorTableSetCallback(t, "h") { _, info in ScanState.state(info).close() }
        CGPDFOperatorTableSetCallback(t, "re") { s, info in
            let st = ScanState.state(info); guard let n = ScanState.pop(s, 4) else { return }
            let (x, y, w, h) = (n[0], n[1], n[2], n[3])
            st.moveTo(st.map(x, y))
            st.lineTo(st.map(x + w, y)); st.lineTo(st.map(x + w, y + h)); st.lineTo(st.map(x, y + h))
            st.close()
        }
        // Only a plain stroke keeps an open subpath; every fill implicitly closes it.
        CGPDFOperatorTableSetCallback(t, "S") { _, info in ScanState.state(info).paint(closing: false) }
        for op in ["s", "f", "F", "f*", "b", "b*", "B", "B*"] {
            CGPDFOperatorTableSetCallback(t, op) { _, info in ScanState.state(info).paint(closing: true) }
        }
        CGPDFOperatorTableSetCallback(t, "n") { _, info in ScanState.state(info).discard() }
        CGPDFOperatorTableSetCallback(t, "BT") { _, info in ScanState.state(info).textObjects += 1 }
        CGPDFOperatorTableSetCallback(t, "Do") { s, info in
            let st = ScanState.state(info)
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(s, &name), let name, let stream = st.resources.last,
                  let obj = CGPDFContentStreamGetResource(stream, "XObject", name) else { return }
            var xo: CGPDFStreamRef?
            guard CGPDFObjectGetValue(obj, .stream, &xo), let xo, let dict = CGPDFStreamGetDictionary(xo) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype else { return }
            switch String(cString: subtype) {
            case "Form":
                let saved = st.ctm
                var arr: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dict, "Matrix", &arr), let arr, CGPDFArrayGetCount(arr) == 6 {
                    var m = [Double](repeating: 0, count: 6)
                    for i in 0..<6 { var v: CGPDFReal = 0; _ = CGPDFArrayGetNumber(arr, i, &v); m[i] = Double(v) }
                    st.ctm = Transform2D(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]).concatenating(st.ctm)
                }
                let sub = CGPDFContentStreamCreateWithStream(xo, dict, stream)
                st.formDepth += 1
                st.scan(sub)
                st.formDepth -= 1
                CGPDFContentStreamRelease(sub)
                st.ctm = saved
            case "Image":
                guard st.includeImages, let png = PDFImageDecoder.png(stream: xo, dict: dict) else {
                    st.skippedImages += 1
                    return
                }
                // Images occupy the unit square in their user space.
                let corners = [st.map(0, 0), st.map(1, 0), st.map(0, 1), st.map(1, 1)]
                st.images.append((Rect2(points: corners), png))
            default: break
            }
        }
        return t
    }()
}

/// Decodes an Image XObject to PNG: JPEG (DCTDecode) streams are re-encoded through ImageIO;
/// raw 8-bit Gray/RGB/CMYK samples are rebuilt into a CGImage. Anything else returns nil.
enum PDFImageDecoder {
    static func png(stream: CGPDFStreamRef, dict: CGPDFDictionaryRef) -> Data? {
        var format = CGPDFDataFormat.raw
        guard let cf = CGPDFStreamCopyData(stream, &format) else { return nil }
        let data = cf as Data
        if format == .jpegEncoded || format == .JPEG2000 {
            return RasterCodec.png(fromEncoded: data)
        }
        var w: CGPDFInteger = 0, h: CGPDFInteger = 0, bpc: CGPDFInteger = 8
        guard CGPDFDictionaryGetInteger(dict, "Width", &w), CGPDFDictionaryGetInteger(dict, "Height", &h),
              w > 0, h > 0 else { return nil }
        _ = CGPDFDictionaryGetInteger(dict, "BitsPerComponent", &bpc)
        guard bpc == 8 else { return nil }
        var csName: UnsafePointer<CChar>?
        var comps = 3
        if CGPDFDictionaryGetName(dict, "ColorSpace", &csName), let csName {
            switch String(cString: csName) {
            case "DeviceGray": comps = 1
            case "DeviceCMYK": comps = 4
            default: comps = 3
            }
        }
        guard let needed = PDFImporter.imageByteCount(width: Int(w), height: Int(h), components: comps),
              data.count >= needed else { return nil }
        let space: CGColorSpace = comps == 1 ? CGColorSpaceCreateDeviceGray()
            : comps == 4 ? CGColorSpaceCreateDeviceCMYK() : CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: data as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8 * comps,
                                bytesPerRow: w * comps, space: space, bitmapInfo: CGBitmapInfo(rawValue: 0),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return RasterCodec.png(from: img)
    }
}
