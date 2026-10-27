import Foundation
import Testing
@testable import CADCore

@Suite struct JSONValueTests {
    private func roundTrip(_ v: JSONValue) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(v))
    }

    @Test func everyKindRoundTrips() throws {
        let v: JSONValue = .object([
            "null": .null, "yes": .bool(true), "no": .bool(false), "n": .number(-12.5),
            "s": .string("tab\t quote\" \u{00E9}"), "a": .array([.number(1), .string("x")]), "o": .object(["k": .null]),
        ])
        #expect(try roundTrip(v) == v)
    }

    @Test func extremesAreKept() throws {
        let v: JSONValue = .object([
            "big": .number(1e300), "small": .number(1e-300),
            "long": .string(String(repeating: "x", count: 3000)),
            "nested": .array([.array([]), .object([:]), .string(""), .array([.array([.null])])]),
        ])
        #expect(try roundTrip(v) == v)
    }

    @Test func encodingAndDecodingGoThroughJSON() throws {
        struct Thing: Codable, Equatable { var count: Int; var ratio: Double; var tags: [String]; var maybe: Int? }
        let t = Thing(count: 4, ratio: 0.001, tags: ["a", "b"], maybe: nil)
        let v = try JSONValue(encoding: t)
        guard case .object(let o) = v else { Issue.record("not an object"); return }
        #expect(o["count"] == .number(4))
        #expect(o["maybe"] == nil)
        #expect(try v.decoded(Thing.self) == t)
    }

    @Test func aNullKeyIsKeptAsNull() throws {
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"a": null}"#.utf8))
        #expect(v == .object(["a": .null]))
    }
}
