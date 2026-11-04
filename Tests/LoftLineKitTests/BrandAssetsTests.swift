import Foundation
import Testing

/// The brand kit and the app icon are committed files; a bundle built without the icon would ship the generic one.
@Suite("Brand assets")
struct BrandAssetsTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let brand = root.appendingPathComponent("docs/brand", isDirectory: true)

    static let masters: [String] = [
        "wordmark-light.svg", "wordmark-dark.svg",
        "mark-light.svg", "mark-dark.svg", "mark-small-light.svg", "mark-small-dark.svg",
        "lockup-h-light.svg", "lockup-h-dark.svg", "lockup-v-light.svg", "lockup-v-dark.svg",
        "icon.svg", "icon-small.svg", "doc-icon.svg",
        "editable/loftline-icon.svg", "editable/loftline-icon.pdf",
        "editable/loftline-lockup-light.svg", "editable/loftline-lockup-light.pdf",
        "editable/loftline-lockup-dark.svg", "editable/loftline-lockup-dark.pdf",
        "editable/loftline-mark.svg",
        "editable/loftline-wordmark.svg", "editable/loftline-wordmark.pdf",
        "editable/loftline-wordmark-dark.svg", "editable/loftline-wordmark-with-guides.svg",
        "png/icon-16.png", "png/icon-32.png", "png/icon-64.png", "png/icon-128.png", "png/icon-256.png", "png/icon-512.png",
        "png/doc-icon-512.png",
        "README.md",
    ]

    @Test func appIconExistsAndIsAnIcns() throws {
        let icon = Self.root.appendingPathComponent("Resources/AppIcon.icns")
        let data = try Data(contentsOf: icon)
        #expect(data.prefix(4) == Data("icns".utf8))
    }

    @Test func brandKitHasTheMasters() {
        let missing = Self.masters.filter {
            !FileManager.default.fileExists(atPath: Self.brand.appendingPathComponent($0).path)
        }
        #expect(missing.isEmpty, "missing under docs/brand: \(missing)")
    }

    @Test func everyBrandSVGIsWellFormedXML() throws {
        let walker = try #require(FileManager.default.enumerator(at: Self.brand, includingPropertiesForKeys: nil))
        let svgs = walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "svg" }
        #expect(svgs.count >= 13, "expected the brand SVGs, found \(svgs.count)")
        for url in svgs {
            let parser = XMLParser(data: try Data(contentsOf: url))
            #expect(parser.parse(), "\(url.lastPathComponent): \(parser.parserError?.localizedDescription ?? "not well formed")")
        }
    }
}
