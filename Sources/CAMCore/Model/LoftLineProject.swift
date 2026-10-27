import CADCore
import Foundation

/// A native `.loftline` file: the design plus its toolpath operations (JSON).
public struct LoftLineProject: Codable, Hashable, Sendable {
    public static let fileExtension = "loftline"
    public static let currentFormatVersion = 2

    public var formatVersion: Int
    public var document: Document
    public var operations: [AnyOperation]
    /// Snapshot of tools referenced by operations so the file opens on any machine.
    public var tools: [Tool]
    /// Selected post profile (`PostProfile.id`).
    public var postProfileID: String?
    /// Selected machine (`MachineDefinition.id` in PostCore). Optional so older files decode; nil
    /// means "the machine whose posts include `postProfileID`, else the post's own limits".
    public var machineID: String?
    /// The post this project posts with, as a copy (format 2): a `PostProfile` as plain JSON, because CAMCore cannot
    /// name PostCore types. The app reads it back with `PostProfile(snapshot:)`. nil = a format 1 file, or a project not
    /// yet opened in the app.
    public var postSnapshot: JSONValue?
    /// The machine, likewise (`MachineDefinition`).
    public var machineSnapshot: JSONValue?
    /// Only when `machineID` is nil and `machineSnapshot` is set: the post id the machine copy was inferred for. A
    /// project with no chosen machine takes the first installed machine that supports its post, so the copy is only
    /// right for that post.
    public var machineInferredFor: String?

    public init(document: Document = Document(), operations: [AnyOperation] = [], tools: [Tool] = [],
                postProfileID: String? = nil, machineID: String? = nil, postSnapshot: JSONValue? = nil,
                machineSnapshot: JSONValue? = nil, machineInferredFor: String? = nil) {
        self.formatVersion = Self.currentFormatVersion
        self.document = document; self.operations = operations; self.tools = tools
        self.postProfileID = postProfileID
        self.machineID = machineID
        self.postSnapshot = postSnapshot; self.machineSnapshot = machineSnapshot
        self.machineInferredFor = machineInferredFor
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    /// Decodes through `LoftLineFile` so version migrations run and newer files are rejected.
    public static func decode(from data: Data) throws -> LoftLineProject {
        var p = try LoftLineFile.decode(LoftLineProject.self, from: data)
        p.document = p.document.repairingLayers()
        return p
    }

    /// The tools this project cuts with: its own tools (the copies the file carries), and the library's for anything the
    /// project does not carry. On an ID clash the project's tool wins, so a file cuts the same on any Mac.
    public func mergedTools(with library: ToolLibrary) -> ToolLibrary {
        var lib = library
        for t in tools { lib.upsert(t) }
        return lib
    }
}
