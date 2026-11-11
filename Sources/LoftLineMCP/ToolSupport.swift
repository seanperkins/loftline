import CADCore
import Foundation
import LoftLineKit

/// A tool's refusal, in words for the person reading it.
public struct ToolError: LocalizedError {
    public var message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// A tool's arguments, read leniently (a number may come as an integer or a decimal) and checked strictly.
struct Args {
    let raw: [String: Any]
    init(_ raw: [String: Any]) { self.raw = raw }

    func string(_ key: String) -> String? { raw[key] as? String }
    func double(_ key: String) -> Double? { (raw[key] as? NSNumber).map(\.doubleValue) }
    func int(_ key: String) -> Int? { (raw[key] as? NSNumber).map(\.intValue) }
    func bool(_ key: String) -> Bool { (raw[key] as? Bool) ?? ((raw[key] as? NSNumber)?.boolValue ?? false) }
    func object(_ key: String) -> [String: Any]? { raw[key] as? [String: Any] }
    func array(_ key: String) -> [Any]? { raw[key] as? [Any] }

    func requireString(_ key: String) throws -> String {
        guard let v = string(key), !v.isEmpty else { throw ToolError("\"\(key)\" is needed.") }
        return v
    }
    func requireDouble(_ key: String) throws -> Double {
        guard let v = double(key), v.isFinite else { throw ToolError("\"\(key)\" is needed, as a number.") }
        return v
    }
    func uuid(_ key: String) throws -> UUID? {
        guard let s = string(key) else { return nil }
        guard let id = UUID(uuidString: s) else { throw ToolError("\"\(key)\" is not an id: \(s).") }
        return id
    }
    func uuids(_ key: String) throws -> [UUID] {
        try (array(key) ?? []).map { item in
            guard let s = item as? String, let id = UUID(uuidString: s) else { throw ToolError("\"\(key)\" holds something that is not an id.") }
            return id
        }
    }
}

/// JSON Schema pieces for tool arguments.
enum Schema {
    static func object(_ properties: [String: [String: Any]], required: [String] = []) -> [String: Any] {
        var s: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
        if !required.isEmpty { s["required"] = required }
        return s
    }
    static func string(_ description: String, oneOf values: [String]? = nil) -> [String: Any] {
        var s: [String: Any] = ["type": "string", "description": description]
        if let values { s["enum"] = values }
        return s
    }
    static func number(_ description: String) -> [String: Any] { ["type": "number", "description": description] }
    static func integer(_ description: String) -> [String: Any] { ["type": "integer", "description": description] }
    static func boolean(_ description: String) -> [String: Any] { ["type": "boolean", "description": description] }
    static func array(_ description: String, of items: [String: Any]) -> [String: Any] {
        ["type": "array", "description": description, "items": items]
    }
    static let anyObject: [String: Any] = ["type": "object"]
}

/// A tool's answer: one summary line, then the details as JSON.
enum Reply {
    static func output(_ summary: String, _ details: Any? = nil) -> ToolOutput {
        guard let details, JSONSerialization.isValidJSONObject(details),
              let data = try? JSONSerialization.data(withJSONObject: details, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return ToolOutput(text: summary) }
        return ToolOutput(text: summary + "\n" + json)
    }
}

/// The engine's requests, in process, with the desktop app's own handlers (so the wording of a refusal is the app's).
struct CoreClient {
    let service: CoreService

    @discardableResult
    func call(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        let line = try JSONSerialization.data(withJSONObject: ["id": 1, "method": method, "params": params])
        let reply = service.handle(line)
        guard let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else { throw ToolError("No reply from LoftLine.") }
        if let error = object["error"] as? String { throw ToolError(error) }
        return object["result"] as? [String: Any] ?? [:]
    }
}

/// Every write an assistant asks for: all the files or none, through the folder writer, inside the allowed folders, and over
/// an existing file only when the call says `replace` (MCP spec, "Files").
enum AssistantWriter {
    @discardableResult
    static func write(_ files: [GCodeFileSet.File], into folder: URL, replace: Bool, access: AssistantAccess,
                      alwaysReplaceable: Set<String> = []) throws -> [URL] {
        try access.check(folder)
        var set = GCodeFileSet(files: files)
        set.operations = access.fileOperations()
        let existing = set.existing(in: folder)
        let blocked = existing.filter { !alwaysReplaceable.contains($0) }
        guard replace || blocked.isEmpty else {
            throw ToolError("\(blocked.joined(separator: ", ")) already \(blocked.count == 1 ? "exists" : "exist") in \(folder.path). "
                + "Pass replace: true to overwrite.")
        }
        return try set.write(to: folder, replacing: existing)
    }
}

extension LengthUnit {
    /// "inch", "in", "millimeter", "mm".
    init?(word: String) {
        switch word.lowercased() {
        case "inch", "in", "inches": self = .inch
        case "millimeter", "millimetre", "mm", "millimeters", "millimetres": self = .millimeter
        default: return nil
        }
    }
}
