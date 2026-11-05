import AppKit
import CADCore
import CAMCore
import Foundation
import LoftLineKit

/// Finder thumbnails for `.loftline` files: after each save the design picture is set as the file's
/// custom icon. Done as a coordinated metadata-only write that restores the exact modification
/// time, so the open document never sees an "external" change. Turn off with the
/// `loftline.fileThumbnails` default (YES unless set).
enum FileThumbnail {
    static let defaultsKey = "loftline.fileThumbnails"

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }

    /// Square picture of the design (material, vectors and tracing images).
    static func image(for document: Document, size: CGFloat = 256) -> NSImage? {
        guard let cg = DesignSnapshot.cgImage(document: document, toolpaths: [], size: CGSize(width: size, height: size))
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
    }

    /// The saved file's bytes with a Quick Look picture embedded (see `QuickLookThumbnailData`):
    /// the current sheet's top side, 256 px. Unchanged when thumbnails are turned off.
    static func withQuickLookThumbnail(_ json: Data, for document: Document, enabled: Bool = isEnabled) -> Data {
        guard enabled else { return json }
        var d = document
        let sheet = d.currentSheetID
        let shown = Set(d.layers.filter { ($0.sheetID ?? MaterialSheet.primaryID) == sheet && ($0.side ?? .top) == .top }.map(\.id))
        d.shapes = d.shapes.filter { shown.contains($0.layerID) }
        d.images = d.images?.filter { $0.layerID.map(shown.contains) ?? true }
        guard let png = DesignSnapshot.png(document: d, toolpaths: [], size: CGSize(width: 256, height: 256)) else { return json }
        return QuickLookThumbnailData.embed(png, in: json)
    }

    /// Sets `image` as the custom icon of `url` without changing its modification date.
    @discardableResult
    static func apply(_ image: NSImage, to url: URL, presenter: NSFilePresenter? = nil) -> Bool {
        var ok = false
        var error: NSError?
        NSFileCoordinator(filePresenter: presenter).coordinate(writingItemAt: url, options: .contentIndependentMetadataOnly,
                                                               error: &error) { u in
            var st = stat()
            guard stat(u.path, &st) == 0 else { return }
            ok = NSWorkspace.shared.setIcon(image, forFile: u.path, options: [])
            var times = [st.st_atimespec, st.st_mtimespec]
            _ = utimensat(AT_FDCWD, u.path, &times, 0)
        }
        return ok && error == nil
    }
}

extension LoftLineDocument {
    /// Refreshes the Finder icon shortly after a save (the write happens after `snapshot`).
    func scheduleFileThumbnail(delay: TimeInterval = 1.5) {
        guard FileThumbnail.isEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let url = self.fileURL, url.pathExtension.lowercased() == LoftLineProject.fileExtension,
                  FileManager.default.fileExists(atPath: url.path),
                  let img = FileThumbnail.image(for: self.shownDocument) else { return }
            let presenter = NSDocumentController.shared.document(for: url)
            FileThumbnail.apply(img, to: url, presenter: presenter)
        }
    }
}
