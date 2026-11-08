import AppKit
import CADCore
import LoftLineKit

/// Draws placed tracing images (cropped, faded). Decoded images are cached by id + data size.
enum PlacedImageRenderer {
    private final class Entry {
        let key: String
        let image: CGImage
        init(key: String, image: CGImage) { self.key = key; self.image = image }
    }

    private static let cache = NSCache<NSUUID, Entry>()

    static func croppedImage(_ img: PlacedImage) -> CGImage? {
        let c = img.cropPixelRect
        // Keyed by id (a replaced image gets a new id) and byte count; hashing a 30 MB scan on
        // every pan or hover made the canvas stutter.
        let key = "\(img.png.count)-\(c.x),\(c.y),\(c.width),\(c.height)"
        if let e = cache.object(forKey: img.id as NSUUID), e.key == key { return e.image }
        guard let full = RasterCodec.cgImage(from: img.png) else { return nil }
        let cropped = img.crop == PlacedImage.fullCrop ? full
            : full.cropping(to: CGRect(x: c.x, y: c.y, width: c.width, height: c.height)) ?? full
        cache.setObject(Entry(key: key, image: cropped), forKey: img.id as NSUUID)
        return cropped
    }

    /// `transform` maps the material frame (y up) to the context's current coordinates.
    static func drawAll(_ document: Document, in ctx: CGContext, transform: CGAffineTransform) {
        guard let images = document.images, !images.isEmpty else { return }
        let hidden = Set(document.layers.filter { !$0.isVisible }.map(\.id))
        for img in images where img.isVisible {
            if let l = img.layerID, hidden.contains(l) { continue }
            guard let cg = croppedImage(img) else { continue }
            let r = img.visibleRect
            ctx.saveGState()
            ctx.concatenate(transform)
            ctx.setAlpha(CGFloat(min(max(img.opacity, 0.05), 1)))
            ctx.interpolationQuality = .medium
            // Material frame is y-up, so CG draws the picture upright.
            ctx.draw(cg, in: CGRect(x: r.min.x, y: r.min.y, width: r.width, height: r.height))
            ctx.restoreGState()
        }
    }
}
