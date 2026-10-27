import Foundation
import Testing
@testable import CADCore

@Suite struct IOLoftLineFileTests {
    func sampleDocument() -> Document {
        var d = Document(name: "Test", units: .millimeter)
        let layer = Layer(name: "Pockets", colorHex: "#00FF00")
        d.layers.append(layer)
        d.add(Shape(name: "rr", layerID: layer.id,
                    paths: [ShapeFactory.rectangle(Rect2(x: 0, y: 0, width: 50, height: 20), cornerRadius: 3)],
                    origin: .rectangle(width: 50, height: 20, cornerRadius: 3)))
        d.add(Shape(name: "open", layerID: d.defaultLayerID,
                    paths: [Path(start: .zero, segments: [.cubic(to: Vec2(10, 0), control1: Vec2(2, 5), control2: Vec2(8, 5))])]))
        d.job.zZero = .spoilboard
        d.job.xyOrigin = .upperRight
        return d
    }

    @Test func documentRoundTrips() throws {
        let d = sampleDocument()
        let data = try DocumentFile.encode(d)
        #expect(try LoftLineFile.formatVersion(of: data) == LoftLineFile.currentVersion)
        #expect(try DocumentFile.decode(from: data) == d)
        // Stable output: sorted keys, so encoding twice is byte-identical.
        #expect(try DocumentFile.encode(d) == data)
    }

    @Test func saveAndLoadFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loftline-io-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("nested/test.loftline")
        let d = sampleDocument()
        try DocumentFile.save(d, to: url)
        #expect(try DocumentFile.load(from: url) == d)
    }

    @Test func readsGoldenV1File() throws {
        let d = try DocumentFile.decode(from: IOFixtures.data("document-v1.loftline"))
        #expect(d.name == "Sign" && d.units == .inch)
        #expect(d.job.xyOrigin == .center && d.job.zZero == .spoilboard)
        #expect(d.layers.map(\.name) == ["Cut"])
        let disc = try #require(d.shapes.first)
        #expect(disc.origin == .circle(radius: 2))
        #expect(approx(disc.bounds(tolerance: 1e-6).width, 4, 1e-5))
    }

    @Test func newerVersionIsRejected() {
        let data = Data(#"{"formatVersion": 99, "document": {}}"#.utf8)
        #expect(throws: LoftLineIOError.unsupportedFormat("LoftLine file version 99 is newer than this app supports (2).")) {
            try DocumentFile.decode(from: data)
        }
    }

    @Test func documentFileReadsVersionOneAndWritesVersionTwo() throws {
        #expect(LoftLineFile.currentVersion == 2)
        let d = sampleDocument()
        let written = try DocumentFile.encode(d)
        #expect(try LoftLineFile.formatVersion(of: written) == 2)
        var obj = try #require(JSONSerialization.jsonObject(with: written) as? [String: Any])
        obj["formatVersion"] = 1
        let v1 = try JSONSerialization.data(withJSONObject: obj)
        #expect(try DocumentFile.decode(from: v1) == d)
    }

    @Test func migrationsRunInOrder() throws {
        let v1 = Data(#"{"formatVersion": 1, "title": "Old"}"#.utf8)
        struct V3: Decodable { var formatVersion: Int; var name: String; var tags: [String] }
        let migrations: [Int: LoftLineFile.Migration] = [
            1: { obj in obj["name"] = obj.removeValue(forKey: "title") },
            2: { obj in obj["tags"] = ["migrated"] },
        ]
        let v = try LoftLineFile.decode(V3.self, from: v1, migrations: migrations, currentVersion: 3)
        #expect(v.formatVersion == 3 && v.name == "Old" && v.tags == ["migrated"])
        #expect(throws: LoftLineIOError.self) {
            try LoftLineFile.decode(V3.self, from: v1, migrations: [1: migrations[1]!], currentVersion: 3)
        }
    }

    @Test func malformedFilesGiveReadableErrors() {
        #expect(throws: LoftLineIOError.self) { try DocumentFile.decode(from: Data("nope".utf8)) }
        #expect(throws: LoftLineIOError.self) { try DocumentFile.decode(from: Data("[1,2]".utf8)) }
        do {
            _ = try DocumentFile.decode(from: Data(#"{"formatVersion": 1}"#.utf8))
            Issue.record("expected an error")
        } catch LoftLineIOError.malformed(let msg) {
            #expect(msg.contains("document"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func missingVersionIsTreatedAsV1() throws {
        let data = try DocumentFile.encode(sampleDocument())
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "formatVersion")
        let legacy = try JSONSerialization.data(withJSONObject: obj)
        #expect(try LoftLineFile.formatVersion(of: legacy) == 1)
        #expect(try DocumentFile.decode(from: legacy).name == "Test")
    }
}
