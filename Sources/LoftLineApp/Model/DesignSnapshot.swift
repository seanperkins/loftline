import AppKit
import CADCore
import CAMCore
import Foundation
import PostCore
import LoftLineKit

/// Offscreen picture of the material, design vectors and toolpaths (job sheet / print).
enum DesignSnapshot {
    static func cgImage(document: Document, toolpaths: [Toolpath], size: CGSize) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Bitmap contexts are y-up: flip so fitTransform (which targets y-down) works unchanged.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        draw(document: document, toolpaths: toolpaths, in: ctx, size: size)
        return ctx.makeImage()
    }

    static func png(document: Document, toolpaths: [Toolpath], size: CGSize) -> Data? {
        guard let img = cgImage(document: document, toolpaths: toolpaths, size: size) else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }

    /// Draws into a y-down context of `size`.
    static func draw(document: Document, toolpaths: [Toolpath], in cg: CGContext, size: CGSize, margin: CGFloat = 16) {
        cg.setFillColor(CGColor(gray: 1, alpha: 1))
        cg.fill(CGRect(origin: .zero, size: size))
        let bounds = document.job.materialBounds.union(document.bounds)
        let t = ToolpathOverlayRenderer.fitTransform(bounds: bounds, in: size, margin: margin)
        let m = document.job.materialBounds
        let r = CGRect(x: m.min.x, y: m.min.y, width: m.width, height: m.height).applying(t)
        cg.setFillColor(CGColor(red: 0.97, green: 0.93, blue: 0.85, alpha: 1))
        cg.fill(r)
        cg.setStrokeColor(CGColor(gray: 0.35, alpha: 1))
        cg.setLineWidth(1)
        cg.stroke(r)
        PlacedImageRenderer.drawAll(document, in: cg, transform: t)
        let hidden = Set(document.layers.filter { !$0.isVisible }.map(\.id))
        cg.setStrokeColor(CGColor(gray: 0.1, alpha: 0.8))
        cg.setLineWidth(0.8)
        for shape in document.shapes where !hidden.contains(shape.layerID) {
            var tt = t
            if let p = CanvasPaths.cgPath(for: shape).copy(using: &tt) {
                cg.addPath(p)
                cg.strokePath()
            }
        }
        if !toolpaths.isEmpty {
            var style = ToolpathOverlayStyle()
            style.cutLineWidth = 1
            style.rapidLineWidth = 0.5
            style.plungeRadius = 2
            ToolpathOverlayRenderer.draw(ToolpathOverlay(toolpaths: toolpaths, coords: MachineCoordinates(job: document.job)),
                                         in: cg, transform: t, style: style)
        }
        // Origin marker.
        let o = document.job.originInMaterialFrame
        let c = CGPoint(x: o.x, y: o.y).applying(t)
        cg.setStrokeColor(CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1))
        cg.setLineWidth(1.5)
        cg.strokeEllipse(in: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10))
    }
}
