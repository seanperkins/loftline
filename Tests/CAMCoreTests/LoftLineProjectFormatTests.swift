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

    @Test func formatVersionsAreThreeAndInStep() {
        #expect(LoftLineProject.currentFormatVersion == 3)
        #expect(LoftLineFile.currentVersion == LoftLineProject.currentFormatVersion)
        #expect(LoftLineProject().formatVersion == 3)
    }

    // MARK: Version 2 -> 3: rest passes name their operation; a relief's split is stored on its model (#8)

    /// A two-sided relief project: `top` finishes with the 1/4 in ball, `bottom` with the 1/8 in ball.
    private func reliefProject() -> (LoftLineProject, top: UUID, bottom: UUID) {
        var doc = Document(units: .inch, job: JobSetup(width: 4, height: 4, thickness: 1.25))
        doc.models = [PlacedModel(name: "Dome", mesh: Mesh3D(vertices: [], indices: []), depth: 1.1, zTop: 0.1)]
        func relief(_ side: TwoSidedSettings.Side, _ tool: Int) -> Relief3DOperation {
            var p = Relief3DParameters(modelID: doc.models[0].id)
            p.twoSided = TwoSidedSettings(side: side)
            return Relief3DOperation(setup: OperationSetup(name: "\(side)", toolID: ToolLibrary.seeded.tools[tool].id), params: p)
        }
        let top = relief(.top, 3), bottom = relief(.bottom, 4)
        var p = LoftLineProject(document: doc)
        p.operations = [.relief3D(top), .relief3D(bottom)]
        return (p, top.setup.id, bottom.setup.id)
    }

    /// `p` written as a version 2 file: each relief's split on its `twoSided`, `restToolID` instead of `rest`.
    private func versionTwoData(_ p: LoftLineProject, splits: [[String: Any]], restToolID: [UUID?]) throws -> Data {
        var obj = try JSONSerialization.jsonObject(with: p.encoded()) as! [String: Any]
        obj["formatVersion"] = 2
        var reliefIndex = 0
        func walk(_ v: Any) -> Any {
            if var d = v as? [String: Any] {
                if var two = d["twoSided"] as? [String: Any] {
                    for (k, value) in splits[reliefIndex] { two[k] = value }
                    two.removeValue(forKey: "splitNeedsReview")
                    d["twoSided"] = two
                    if var f = d["finishing"] as? [String: Any] {
                        f.removeValue(forKey: "rest")
                        if let r = restToolID[reliefIndex] { f["restToolID"] = r.uuidString }
                        d["finishing"] = f
                    }
                    reliefIndex += 1
                    return d
                }
                d.removeValue(forKey: "reliefSplit")
                return d.mapValues(walk)
            }
            if let a = v as? [Any] { return a.map(walk) }
            return v
        }
        obj = walk(obj) as! [String: Any]
        return try JSONSerialization.data(withJSONObject: obj)
    }

    @Test func version2FileMigrates() throws {
        let (p, top, bottom) = reliefProject()
        let split: [String: Any] = ["flip": "topBottom", "splitDepth": 0.5, "web": 0.04]
        let data = try versionTwoData(p, splits: [split, split], restToolID: [nil, ToolLibrary.seeded.tools[3].id])
        let back = try LoftLineProject.decode(from: data)
        #expect(back.document.models[0].reliefSplit == ReliefSplit(flip: .topBottom, splitDepth: 0.5, web: 0.04))
        guard case .relief3D(let t) = back.operations[0], case .relief3D(let b) = back.operations[1] else {
            Issue.record("not reliefs"); return
        }
        #expect(t.setup.id == top && b.setup.id == bottom)
        #expect(b.params.finishing.rest == .operation(top))
        #expect(t.params.twoSided?.splitNeedsReview != true && b.params.twoSided?.splitNeedsReview != true)
        #expect(!String(decoding: try back.encoded(), as: UTF8.self).contains("restToolID"))
    }

    @Test func conflictingSidesMigrateToReview() throws {
        // The sides disagree on the web: the model takes the top side's, and both sides wait for review.
        let (p, _, _) = reliefProject()
        let data = try versionTwoData(p, splits: [["flip": "leftRight", "web": 0.04], ["flip": "leftRight", "web": 0.06]],
                                      restToolID: [nil, nil])
        let back = try LoftLineProject.decode(from: data)
        #expect(back.document.models[0].reliefSplit == ReliefSplit(flip: .leftRight, splitDepth: nil, web: 0.04))
        for op in back.operations {
            guard case .relief3D(let r) = op else { continue }
            #expect(r.params.twoSided?.splitNeedsReview == true)
        }
    }

    @Test func version3FileIsRefusedByVersion2Reader() throws {
        let (p, _, _) = reliefProject()
        #expect(throws: (any Error).self) {
            try LoftLineFile.decode(LoftLineProject.self, from: p.encoded(), currentVersion: 2)
        }
    }

    @Test func versionOneFileDecodesWithNoCopies() throws {
        let base = LoftLineProject(document: Document(name: "Old", units: .millimeter), postProfileID: "p", machineID: "m")
        let p = try LoftLineProject.decode(from: versionOneData(base))
        #expect(p.postSnapshot == nil && p.machineSnapshot == nil && p.machineInferredFor == nil)
        #expect(p.postProfileID == "p" && p.machineID == "m")
        #expect(p.document == base.document)
        #expect(p.formatVersion == LoftLineProject.currentFormatVersion)
    }

    @Test func projectWithCopiesEncodesTheCurrentVersionAndRoundTrips() throws {
        let p = withCopies()
        let data = try p.encoded()
        let obj = try object(data)
        #expect(obj["formatVersion"] as? Int == LoftLineProject.currentFormatVersion)
        #expect(obj["postSnapshot"] is [String: Any], "the copy is nested JSON, not a string or base64")
        #expect((obj["postSnapshot"] as? [String: Any])?["id"] as? String == "post-a")
        #expect(obj["machineInferredFor"] as? String == "post-a")
        #expect(try LoftLineProject.decode(from: data) == p)
    }

    @Test func absentCopiesAreNotWritten() throws {
        let obj = try object(LoftLineProject().encoded())
        for k in copyKeys { #expect(obj[k] == nil, "\(k)") }
    }

    @Test func aNewerVersionIsRefused() throws {
        var obj = try object(LoftLineProject().encoded())
        obj["formatVersion"] = LoftLineProject.currentFormatVersion + 1
        let data = try JSONSerialization.data(withJSONObject: obj)
        #expect(throws: LoftLineIOError.self) { try LoftLineProject.decode(from: data) }
    }

    @Test func migrationFromOneOnlyChangesTheNumber() throws {
        let v1 = try versionOneData(LoftLineProject(document: Document(name: "M"), postProfileID: "p"))
        var before = try object(v1)
        var after = try object(LoftLineFile.migrate(v1))
        #expect(after["formatVersion"] as? Int == LoftLineFile.currentVersion)
        before["formatVersion"] = nil; after["formatVersion"] = nil
        #expect(NSDictionary(dictionary: before).isEqual(to: after))
    }
}
