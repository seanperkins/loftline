import CADCore
import Foundation

/// Why a post or machine copy could not be read. A copy is refused, never read with fields silently dropped.
public enum SnapshotError: Error, Equatable, LocalizedError {
    /// Written by a newer LoftLine than this one (`schemaVersion` above `supported`).
    case newerSchema(found: Int, supported: Int)
    /// Not a post or machine at all, or missing what one needs.
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .newerSchema(let found, let supported):
            return "It was made with a newer LoftLine (format \(found); this LoftLine reads up to \(supported)). Update LoftLine to read it."
        case .malformed(let why):
            return "It could not be read: \(why)"
        }
    }
}

/// `schemaVersion` as it sits in a post or machine file. Files written before it existed have no such key and are
/// version 1, which the overload below decodes without hand-listing every other key of the type that carries it.
@propertyWrapper
public struct SchemaVersion: Codable, Hashable, Sendable {
    public var wrappedValue: Int
    public init(wrappedValue: Int) { self.wrappedValue = wrappedValue }
    public init(from decoder: Decoder) throws { wrappedValue = try decoder.singleValueContainer().decode(Int.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: SchemaVersion.Type, forKey key: Key) throws -> SchemaVersion {
        try decodeIfPresent(type, forKey: key) ?? SchemaVersion(wrappedValue: 1)
    }
}

/// Reads a post or machine from JSON, checking `schemaVersion` first so a newer file is reported as newer even when
/// its other fields no longer decode.
enum SnapshotDecoding {
    private struct Probe: Decodable { var schemaVersion: Int? }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, supported: Int) throws -> T {
        do {
            if let found = try JSONDecoder().decode(Probe.self, from: data).schemaVersion, found > supported {
                throw SnapshotError.newerSchema(found: found, supported: supported)
            }
            return try JSONDecoder().decode(type, from: data)
        } catch let e as SnapshotError {
            throw e
        } catch let e as DecodingError {
            throw SnapshotError.malformed(describe(e))
        } catch {
            throw SnapshotError.malformed(error.localizedDescription)
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue, supported: Int) throws -> T {
        do {
            return try decode(type, from: JSONEncoder().encode(value), supported: supported)
        } catch let e as EncodingError {
            throw SnapshotError.malformed(String(describing: e))
        }
    }

    private static func describe(_ e: DecodingError) -> String {
        func path(_ c: DecodingError.Context) -> String {
            let p = c.codingPath.map(\.stringValue).joined(separator: ".")
            return p.isEmpty ? "" : " at \(p)"
        }
        switch e {
        case .keyNotFound(let k, let c): return "missing \"\(k.stringValue)\"\(path(c))"
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c): return "\(c.debugDescription)\(path(c))"
        @unknown default: return "\(e)"
        }
    }
}
