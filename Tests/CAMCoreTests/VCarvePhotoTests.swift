import CADCore
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif
import Foundation
import Testing
@testable import CAMCore

private typealias F = VCarveFixture

/// 20 x 10 px: left half black, right half white.
private let halfBlack: GrayImage = {
    var px = [UInt8](repeating: 255, count: 200)
    for y in 0..<10 { for x in 0..<10 { px[y * 20 + x] = 0 } }
    return GrayImage(width: 20, height: 10, pixels: Data(px))
}()

private func photo(_ params: PhotoVCarveParameters, zZero: ZZeroMode = .materialTop) throws -> (Toolpath, CAMContext) {
    var doc = Document(units: .inch)
    doc.job.zZero = zZero
    let ctx = CAMContext(document: doc, tools: .seeded)
    let op = PhotoVCarveOperation(setup: OperationSetup(name: "Photo", toolID: F.vbit60.id), params: params)
    let tps = try op.generate(in: ctx)
    #expect(tps.count == 1)
    return (try #require(tps.first), ctx)
}

@Test(arguments: [ZZeroMode.materialTop, .spoilboard])
func photoVCarveDarkAreasCarveFullWidthLightAreasNothing(zZero: ZZeroMode) throws {
    let params = PhotoVCarveParameters(image: halfBlack, origin: Vec2(1, 1), width: 4, lineSpacing: 0.1)
    let (tp, ctx) = try photo(params, zZero: zZero)
    let full = 0.05 / F.tan30
    let pts = F.cutPoints(tp, coords: ctx.coords)
    #expect(abs((pts.map(\.depth).max() ?? 0) - full) < 1e-6)
    // Picture is 4 x 2 in at (1,1): grooves only over the black left half, inside the picture.
    for p in pts {
        #expect(p.xy.x >= 1 - 1e-6 && p.xy.x <= 3.1)
        #expect(p.xy.y >= 1 - 1e-6 && p.xy.y <= 3 + 1e-6)
    }
    // Horizontal grooves every 0.1 in: 20 lines through a 2 in tall picture.
    let ys = Set(pts.filter { abs($0.depth - full) < 1e-6 }.map { ($0.xy.y * 1000).rounded() })
    #expect(ys.count == 20)
    #expect(tp.metadata["grooves"] == "20")
    F.expectSafeMotion(tp, coords: ctx.coords)
}

@Test func photoVCarveInvertCarvesTheLightSide() throws {
    let params = PhotoVCarveParameters(image: halfBlack, origin: Vec2(1, 1), width: 4, lineSpacing: 0.1, invert: true)
    let (tp, ctx) = try photo(params)
    let deep = F.cutPoints(tp, coords: ctx.coords).filter { $0.depth > 0.05 }
    #expect(!deep.isEmpty)
    #expect(deep.allSatisfy { $0.xy.x >= 2.9 })
}

@Test func photoVCarveGreyGivesProportionalWidth() throws {
    let grey = GrayImage(width: 2, height: 2, pixels: Data([128, 128, 128, 128]))
    let params = PhotoVCarveParameters(image: grey, origin: Vec2(0, 0), width: 1, lineSpacing: 0.2)
    let (tp, ctx) = try photo(params)
    let dark = 1 - 128.0 / 255
    let expected = dark * 0.2 / 2 / F.tan30
    let depths = F.cutPoints(tp, coords: ctx.coords).map(\.depth).filter { $0 > 0.01 }
    #expect(!depths.isEmpty)
    #expect(depths.allSatisfy { abs($0 - expected) < 1e-3 })
}

@Test func photoVCarveRequiresImage() {
    #expect(throws: CAMError.self) { try photo(PhotoVCarveParameters()) }
}

@Test func photoImageLoaderReadsPNGAsGrey() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loftline-photo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    // 4 x 2 RGB: top row red, bottom row white.
    var rgba: [UInt8] = []
    for y in 0..<2 { for _ in 0..<4 { rgba += y == 0 ? [255, 0, 0, 255] : [255, 255, 255, 255] } }
    let url = dir.appendingPathComponent("t.png")
#if canImport(ImageIO)
    let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
    let cg = try #require(CGImage(width: 4, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(dest, cg, nil)
    #expect(CGImageDestinationFinalize(dest))
#else
    try #require(PortableImage(width: 4, height: 2, rgba: rgba).png).write(to: url)
#endif
    let g = try PhotoImageLoader.load(url)
    #expect(g.width == 4 && g.height == 2)
    #expect(g.brightness(u: 0.5, v: 0.95) < 0.6)    // top row is red (darker grey)
    #expect(g.brightness(u: 0.5, v: 0.05) > 0.95)   // bottom row white
}

@Test func photoVCarveRoundTripsThroughAnyOperation() throws {
    let op = AnyOperation.photoVCarve(PhotoVCarveOperation(setup: OperationSetup(name: "P", toolID: F.vbit60.id),
                                                           params: PhotoVCarveParameters(image: halfBlack, imageName: "x.png")))
    let back = try JSONDecoder().decode(AnyOperation.self, from: JSONEncoder().encode(op))
    #expect(back == op)
    #expect(back.kind == .photoVCarve)
}
