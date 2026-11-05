import AppKit
import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct IOQuickLookThumbnailTests {
    @Test func savedFilesCarryAPictureAndStillOpen() throws {
        let p = AppTestSupport.project()
        let json = try p.encoded()
        let saved = FileThumbnail.withQuickLookThumbnail(json, for: p.document, enabled: true)
        #expect(saved.count > json.count)
        // The picture is the first member, so the extension finds it in the file's first bytes.
        #expect(String(decoding: saved.prefix(40), as: UTF8.self).contains("\"quickLookThumbnail\""))
        let png = try #require(QuickLookThumbnailData.read(from: saved))
        let img = try #require(NSImage(data: png))
        #expect(img.representations.first?.pixelsWide == 256)
        // LoftLine ignores the key when reading the project back.
        #expect(try LoftLineProject.decode(from: saved) == p)
        // Reading from a file works the same.
        let url = AppTestSupport.tempDir().appendingPathComponent("job.loftline")
        try saved.write(to: url)
        #expect(QuickLookThumbnailData.read(from: url) == png)
    }

    @Test func embedAndReadEdgeCases() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 250, 251, 252])
        let empty = QuickLookThumbnailData.embed(png, in: Data("{}".utf8))
        let obj = try JSONSerialization.jsonObject(with: empty) as? [String: Any]
        #expect(obj?["quickLookThumbnail"] as? String == png.base64EncodedString())
        #expect(QuickLookThumbnailData.read(from: empty) == png)
        let compact = QuickLookThumbnailData.embed(png, in: Data("{\"a\":1}".utf8))
        #expect((try JSONSerialization.jsonObject(with: compact) as? [String: Any])?["a"] as? Int == 1)
        // Older files (no picture) and non-JSON give nothing.
        #expect(QuickLookThumbnailData.read(from: try AppTestSupport.project().encoded()) == nil)
        #expect(QuickLookThumbnailData.read(from: Data("not json".utf8)) == nil)
        // Spaced / escaped variants as another writer might produce.
        let spaced = Data("{ \"quickLookThumbnail\"\n:\t\"\(png.base64EncodedString().replacingOccurrences(of: "/", with: "\\/"))\" }".utf8)
        #expect(QuickLookThumbnailData.read(from: spaced) == png)
    }

    @Test func turningThumbnailsOffSkipsThePicture() {
        let json = Data("{\"a\":1}".utf8)
        #expect(FileThumbnail.withQuickLookThumbnail(json, for: Document(), enabled: false) == json)
    }
}
