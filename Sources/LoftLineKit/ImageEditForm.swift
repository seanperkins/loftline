import CADCore
import Foundation

/// Editable copy of a placed tracing image (sidebar popover). Lengths in document units,
/// fade and crop margins in percent.
public struct ImageEditForm: Equatable {
    public var name: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var lockAspect = true
    /// 0 = opaque … 95 = almost invisible.
    public var fadePercent: Double
    public var cropLeft: Double
    public var cropRight: Double
    public var cropBottom: Double
    public var cropTop: Double
    public var isVisible: Bool
    public var isLocked: Bool

    public init(_ img: PlacedImage) {
        name = img.name
        x = img.rect.min.x; y = img.rect.min.y; width = img.rect.width; height = img.rect.height
        fadePercent = ((1 - img.opacity) * 100).rounded()
        let c = PlacedImage.clampCrop(img.crop)
        cropLeft = c.min.x * 100; cropRight = (1 - c.max.x) * 100
        cropBottom = c.min.y * 100; cropTop = (1 - c.max.y) * 100
        isVisible = img.isVisible; isLocked = img.isLocked
    }

    /// Changes the width, keeping the aspect ratio when locked.
    public mutating func setWidth(_ w: Double) {
        guard w > 0 else { return }
        if lockAspect, width > 0 { height *= w / width }
        width = w
    }

    public mutating func setHeight(_ h: Double) {
        guard h > 0 else { return }
        if lockAspect, height > 0 { width *= h / height }
        height = h
    }

    /// Scales the image to fill the material (keeping aspect) and centres it.
    public mutating func fit(to job: JobSetup, pixelAspect: Double) {
        var w = job.width, h = w * pixelAspect
        if h > job.height { h = job.height; w = h / pixelAspect }
        width = w; height = h
        x = (job.width - w) / 2; y = (job.height - h) / 2
    }

    public func apply(to img: PlacedImage) -> PlacedImage {
        var i = img
        i.name = name.isEmpty ? img.name : name
        if width > 0, height > 0 { i.rect = Rect2(x: x, y: y, width: width, height: height) }
        i.opacity = 1 - min(max(fadePercent, 0), 95) / 100
        func f(_ v: Double) -> Double { min(max(v, 0), 99) / 100 }
        i.crop = PlacedImage.clampCrop(Rect2(min: Vec2(f(cropLeft), f(cropBottom)),
                                             max: Vec2(1 - f(cropRight), 1 - f(cropTop))))
        i.isVisible = isVisible
        i.isLocked = isLocked
        return i
    }
}
