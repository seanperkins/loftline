import CADCore
import Foundation
import Testing
@testable import CAMCore

@Suite struct LoftLineProjectFormatTests {
    private let copyKeys = ["postSnapshot", "machineSnapshot", "machineInferredFor"]

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// What a LoftLine 0.2 wrote: format version 1 and none of the copy keys.
    private func versionOneData(_ p: LoftLineProject) throws -> Data {
        var obj = try object(p.encoded())
        obj["formatVersion"] = 1
        copyKeys.forEach { obj.removeValue(forKey: $0) }
        return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    private func withCopies() -> LoftLineProject {
        var p = LoftLineProject(document: Document(name: "Copies", units: .inch), postProfileID: "post-a", machineID: nil)
        p.postSnapshot = .object(["id": .string("post-a"), "schemaVersion": .number(1)])
        p.machineSnapshot = .object(["id": .string("machine-a"), "schemaVersion": .number(1)])
        p.machineInferredFor = "post-a"
        return p
    }

    @Test func formatVersionsAreTwoAndInStep() {
        #expect(LoftLineProject.currentFormatVersion == 2)
        #expect(LoftLineFile.currentVersion == LoftLineProject.currentFormatVersion)
        #expect(LoftLineProject().formatVersion == 2)
    }

    @Test func versionOneFileDecodesWithNoCopies() throws {
        let base = LoftLineProject(document: Document(name: "Old", units: .millimeter), postProfileID: "p", machineID: "m")
        let p = try LoftLineProject.decode(from: versionOneData(base))
        #expect(p.postSnapshot == nil && p.machineSnapshot == nil && p.machineInferredFor == nil)
        #expect(p.postProfileID == "p" && p.machineID == "m")
        #expect(p.document == base.document)
        #expect(p.formatVersion == 2)
    }

    @Test func projectWithCopiesEncodesVersionTwoAndRoundTrips() throws {
        let p = withCopies()
        let data = try p.encoded()
        let obj = try object(data)
        #expect(obj["formatVersion"] as? Int == 2)
        #expect(obj["postSnapshot"] is [String: Any], "the copy is nested JSON, not a string or base64")
        #expect((obj["postSnapshot"] as? [String: Any])?["id"] as? String == "post-a")
        #expect(obj["machineInferredFor"] as? String == "post-a")
        #expect(try LoftLineProject.decode(from: data) == p)
    }

    @Test func absentCopiesAreNotWritten() throws {
        let obj = try object(LoftLineProject().encoded())
        for k in copyKeys { #expect(obj[k] == nil, "\(k)") }
    }

    @Test func versionThreeIsRefused() throws {
        var obj = try object(LoftLineProject().encoded())
        obj["formatVersion"] = 3
        let data = try JSONSerialization.data(withJSONObject: obj)
        #expect(throws: LoftLineIOError.self) { try LoftLineProject.decode(from: data) }
    }

    @Test func migrationOneToTwoOnlyChangesTheNumber() throws {
        let v1 = try versionOneData(LoftLineProject(document: Document(name: "M"), postProfileID: "p"))
        var before = try object(v1)
        var after = try object(LoftLineFile.migrate(v1))
        #expect(after["formatVersion"] as? Int == 2)
        before["formatVersion"] = nil; after["formatVersion"] = nil
        #expect(NSDictionary(dictionary: before).isEqual(to: after))
    }
}
