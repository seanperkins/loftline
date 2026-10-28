import CADCore
import Foundation
import Testing
@testable import PostCore

@Suite struct SnapshotTests {
    private func object(_ v: JSONValue) -> [String: JSONValue] {
        guard case .object(let o) = v else { Issue.record("not an object"); return [:] }
        return o
    }

    @Test func builtInsRoundTripThroughSnapshots() throws {
        for p in BuiltInPosts.all { #expect(try PostProfile(snapshot: p.snapshot()) == p, "\(p.id)") }
        for m in BuiltInMachines.all { #expect(try MachineDefinition(snapshot: m.snapshot()) == m, "\(m.id)") }
    }

    @Test func everyFieldSurvivesTheDecoder() throws {
        var p = BuiltInPosts.avidMach4Inch
        p.id = "x"; p.name = "X"; p.version = "9.9"; p.lineNumbers = true; p.pause = ["M0"]; p.helicalArcs = false
        p.spindleDwellSeconds = 0.25; p.arcTolerance = 0.00123; p.footer = ["M30", "%"]
        #expect(try PostProfile(snapshot: p.snapshot()) == p)
        let m = MachineDefinition(id: "m", name: "M", units: .millimeter, limits: BuiltInPosts.avidMach4MM.limits, postIDs: ["a", "b"],
                                  rapidRate: 5000, maxFeed: 4000, minRPM: 1000, maxRPM: 24000, notes: "n")
        #expect(try MachineDefinition(snapshot: m.snapshot()) == m)
    }

    @Test func schemaVersionIsAlwaysWritten() throws {
        for p in BuiltInPosts.all {
            #expect(object(try p.snapshot())["schemaVersion"] == .number(1), "\(p.id)")
            #expect(object(try JSONDecoder().decode(JSONValue.self, from: p.toJSON()))["schemaVersion"] == .number(1), "\(p.id)")
        }
        #expect(object(try BuiltInMachines.all[0].snapshot())["schemaVersion"] == .number(1))
        #expect(PostProfile.currentSchemaVersion == 2 && MachineDefinition.currentSchemaVersion == 1)
    }

    /// The written version is what the content needs (#99 item 1): an older LoftLine would print `{MILLISECONDS}` literally.
    @Test func aMillisecondDwellIsWrittenAsVersionTwoAndOnlyThen() throws {
        var ms = BuiltInPosts.avidMach4Inch
        ms.id = "ms"
        ms.dwell = "G4 P{MILLISECONDS}"
        #expect(object(try ms.snapshot())["schemaVersion"] == .number(2))
        #expect(object(try JSONDecoder().decode(JSONValue.self, from: ms.toJSON()))["schemaVersion"] == .number(2))
        // Read back, it holds 1 in memory and equals what was written.
        let back = try PostProfile(snapshot: ms.snapshot())
        #expect(back == ms && back.schemaVersion == 1)
        #expect(try PostProfile.fromJSON(ms.toJSON()) == ms)
        // Switched back to seconds, it is written as 1 again.
        var seconds = try PostProfile.fromJSON(ms.toJSON())
        seconds.dwell = "G4 P{SECONDS}"
        #expect(object(try seconds.snapshot())["schemaVersion"] == .number(1))
        // A reader of version 1 refuses the millisecond post.
        #expect(throws: SnapshotError.newerSchema(found: 2, supported: 1)) {
            try SnapshotDecoding.decode(PostProfile.self, from: ms.snapshot(), supported: 1)
        }
    }

    /// A stored version never reaches value equality: a GRBL copy saved by a newer LoftLine is still the built-in, and still
    /// writes M0 for an optional stop (#115).
    @Test func aDecodedVersionDoesNotDefeatBuiltInRecognition() throws {
        var o = object(try BuiltInPosts.genericGRBLMM.snapshot())
        o["schemaVersion"] = .number(2)
        let copy = try PostProfile(snapshot: .object(o))
        #expect(copy == BuiltInPosts.genericGRBLMM)
        #expect(!copy.honoursOptionalStop)
    }

    @Test func schemaVersionAbsentDecodesAsOne() throws {
        var post = object(try BuiltInPosts.avidMach4Inch.snapshot()); post["schemaVersion"] = nil
        #expect(try PostProfile(snapshot: .object(post)).schemaVersion == 1)
        var machine = object(try BuiltInMachines.all[0].snapshot()); machine["schemaVersion"] = nil
        #expect(try MachineDefinition(snapshot: .object(machine)).schemaVersion == 1)
        let data = try JSONEncoder().encode(JSONValue.object(post))
        #expect(try PostProfile.fromJSON(data).schemaVersion == 1)
    }

    @Test func newerSchemaThrows() throws {
        let future = PostProfile.currentSchemaVersion + 1
        var post = object(try BuiltInPosts.avidMach4Inch.snapshot()); post["schemaVersion"] = .number(Double(future))
        post["aFieldFromTheFuture"] = .array([.string("x")])
        let refused = SnapshotError.newerSchema(found: future, supported: PostProfile.currentSchemaVersion)
        #expect(throws: refused) { try PostProfile(snapshot: .object(post)) }
        #expect(throws: refused) {
            try PostProfile.fromJSON(JSONEncoder().encode(JSONValue.object(post)))
        }
        var machine = object(try BuiltInMachines.all[0].snapshot()); machine["schemaVersion"] = .number(2)
        #expect(throws: SnapshotError.newerSchema(found: 2, supported: 1)) { try MachineDefinition(snapshot: .object(machine)) }
        #expect(throws: SnapshotError.newerSchema(found: 2, supported: 1)) {
            try MachineDefinition.fromJSON(JSONEncoder().encode(JSONValue.object(machine)))
        }
    }

    @Test func newerSchemaWinsOverAnUndecodableField() throws {
        var post = object(try BuiltInPosts.avidMach4Inch.snapshot())
        let future = PostProfile.currentSchemaVersion + 1
        post["schemaVersion"] = .number(Double(future)); post["decimals"] = .string("not a number any more")
        #expect(throws: SnapshotError.newerSchema(found: future, supported: PostProfile.currentSchemaVersion)) {
            try PostProfile(snapshot: .object(post))
        }
    }

    @Test func undecodableSnapshotIsMalformed() {
        for bad in [JSONValue.string("nope"), .null, .object(["id": .string("only")])] {
            do { _ = try PostProfile(snapshot: bad); Issue.record("accepted \(bad)") } catch let e as SnapshotError {
                guard case .malformed = e else { Issue.record("wrong error \(e)"); continue }
            } catch { Issue.record("not a SnapshotError: \(error)") }
            do { _ = try MachineDefinition(snapshot: bad); Issue.record("accepted \(bad)") } catch let e as SnapshotError {
                guard case .malformed = e else { Issue.record("wrong error \(e)"); continue }
            } catch { Issue.record("not a SnapshotError: \(error)") }
        }
    }
}

/// A post that asks for absurd precision would exhaust memory when numbers are formatted with it.
@Suite struct SnapshotBoundsTests {
    @Test func decimalsAreBoundedWhereverAPostIsRead() throws {
        for decimals in [1_000_000_000, 13, -1] {
            var post = BuiltInPosts.avidMach4Inch
            post.decimals = decimals
            let snapshot = try post.snapshot()
            do { _ = try PostProfile(snapshot: snapshot); Issue.record("accepted decimals \(decimals)") } catch let e as SnapshotError {
                guard case .malformed(let why) = e else { Issue.record("wrong error \(e)"); continue }
                #expect(why.contains("decimals"), "\(why)")
            }
            #expect(throws: SnapshotError.self) { try PostProfile.fromJSON(JSONEncoder().encode(snapshot)) }
            var feed = BuiltInPosts.avidMach4Inch
            feed.feedDecimals = decimals
            #expect(throws: SnapshotError.self) { try PostProfile(snapshot: feed.snapshot()) }
        }
        for decimals in [0, 3, 4, 12] {
            var post = BuiltInPosts.avidMach4Inch
            post.decimals = decimals; post.feedDecimals = decimals
            #expect(try PostProfile(snapshot: post.snapshot()) == post)
        }
    }
}
