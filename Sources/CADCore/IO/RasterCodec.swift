import Foundation
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Raster image helpers (ImageIO): decode any format macOS reads, re-encode as PNG.
public enum RasterCodec {
    public static let fileExtensions = ["png", "jpg", "jpeg", "bmp", "tif", "tiff", "gif", "webp", "heic"]

    public static func cgImage(from data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0 else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    public static func png(from image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// 8-bit Gray, RGB or CMYK samples → PNG.
    public static func png(width: Int, height: Int, samples: [UInt8], components: Int) -> Data? {
        let space: CGColorSpace = components == 1 ? CGColorSpaceCreateDeviceGray()
            : components == 4 ? CGColorSpaceCreateDeviceCMYK() : CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(samples) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * components, bytesPerRow: width * components,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) else { return nil }
        return png(from: image)
    }

    /// Any readable image → PNG (nil when ImageIO cannot decode it).
    public static func png(fromEncoded data: Data) -> Data? {
        cgImage(from: data).flatMap(png(from:))
    }

    /// Pixel size and, when the file records it, the physical size in inches (from its DPI).
    public static func info(of data: Data) -> (pixels: (width: Int, height: Int), inches: (width: Double, height: Double)?)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        var inches: (Double, Double)?
        if let dx = props[kCGImagePropertyDPIWidth] as? Double, let dy = props[kCGImagePropertyDPIHeight] as? Double,
           dx > 0, dy > 0, abs(dx - 72) > 0.5 || abs(dy - 72) > 0.5 {
            inches = (Double(w) / dx, Double(h) / dy)
        }
        return ((w, h), inches)
    }
}
#else
/// Raster image helpers off the Mac: fewer formats than ImageIO reads (docs/PLATFORMS.md).
public enum RasterCodec {
    public static let fileExtensions = ["png", "jpg", "jpeg", "bmp", "gif"]

    /// Any readable image → PNG (nil when it cannot be decoded).
    public static func png(fromEncoded data: Data) -> Data? { PortableImage(data: data)?.png }

    /// 8-bit Gray, RGB or CMYK samples → PNG. CMYK by the plain formula: the Mac's goes through a colour profile (docs/PLATFORMS.md).
    public static func png(width: Int, height: Int, samples: [UInt8], components: Int) -> Data? {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            let s = i * components, o = i * 4
            switch components {
            case 1: rgba[o] = samples[s]; rgba[o + 1] = samples[s]; rgba[o + 2] = samples[s]
            case 4:
                let k = 255 - Int(samples[s + 3])
                rgba[o] = UInt8((255 - Int(samples[s])) * k / 255)
                rgba[o + 1] = UInt8((255 - Int(samples[s + 1])) * k / 255)
                rgba[o + 2] = UInt8((255 - Int(samples[s + 2])) * k / 255)
            default: rgba[o] = samples[s]; rgba[o + 1] = samples[s + 1]; rgba[o + 2] = samples[s + 2]
            }
        }
        return PortableImage(width: width, height: height, rgba: rgba).png
    }

    /// Pixel size and, when the file records it, the physical size in inches (from its DPI).
    public static func info(of data: Data) -> (pixels: (width: Int, height: Int), inches: (width: Double, height: Double)?)? {
        guard let image = PortableImage(data: data) else { return nil }
        var inches: (Double, Double)?
        if let (dx, dy) = PortableImage.dpi(of: data), dx > 0, dy > 0, abs(dx - 72) > 0.5 || abs(dy - 72) > 0.5 {
            inches = (Double(image.width) / dx, Double(image.height) / dy)
        }
        return ((image.width, image.height), inches)
    }
}
#endif
