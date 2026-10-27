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
        #expect(object(try BuiltInPosts.avidMach4Inch.snapshot())["schemaVersion"] == .number(1))
        #expect(object(try BuiltInMachines.all[0].snapshot())["schemaVersion"] == .number(1))
        #expect(PostProfile.currentSchemaVersion == 1 && MachineDefinition.currentSchemaVersion == 1)
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
        var post = object(try BuiltInPosts.avidMach4Inch.snapshot()); post["schemaVersion"] = .number(2)
        post["aFieldFromTheFuture"] = .array([.string("x")])
        #expect(throws: SnapshotError.newerSchema(found: 2, supported: 1)) { try PostProfile(snapshot: .object(post)) }
        #expect(throws: SnapshotError.newerSchema(found: 2, supported: 1)) {
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
        post["schemaVersion"] = .number(3); post["decimals"] = .string("not a number any more")
        #expect(throws: SnapshotError.newerSchema(found: 3, supported: 1)) { try PostProfile(snapshot: .object(post)) }
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
