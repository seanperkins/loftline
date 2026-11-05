// Save the 3D preview as a PNG. Owned by preview.
import AppKit
import Metal
import SceneKit
import UniformTypeIdentifiers
import LoftLineKit

enum PreviewImageExport {
    /// Renders `stockScene` offscreen from `pointOfView` (the on-screen camera when given).
    /// Returns nil when no Metal device is available.
    @MainActor
    static func render(_ stockScene: StockScene, size: CGSize, pointOfView: SCNNode? = nil) -> NSImage? {
        guard size.width >= 1, size.height >= 1, let device = MTLCreateSystemDefaultDevice() else { return nil }
        let r = SCNRenderer(device: device, options: nil)
        r.scene = stockScene.scene
        r.pointOfView = pointOfView ?? stockScene.cameraNode
        r.autoenablesDefaultLighting = false
        return r.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    /// "Sign preview.png" with characters that are unsafe in file names replaced.
    static func suggestedFileName(documentName: String) -> String {
        let base = documentName.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : documentName
        let clean = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return clean + " preview.png"
    }

    /// Asks for a file and writes the preview as PNG at twice the view size (or 1600 x 1000).
    @MainActor
    static func runSavePanel(stockScene: StockScene, documentName: String) {
        let view = stockScene.attachedView
        var size = CGSize(width: 1600, height: 1000)
        if let v = view, v.bounds.width > 10, v.bounds.height > 10 {
            let scale = max(v.window?.backingScaleFactor ?? 2, 2)
            size = CGSize(width: v.bounds.width * scale, height: v.bounds.height * scale)
        }
        guard let image = render(stockScene, size: size, pointOfView: view?.pointOfView),
              let data = pngData(image) else {
            NSSound.beep()
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = suggestedFileName(documentName: documentName)
        panel.message = "Save the 3D preview as a PNG image"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}
