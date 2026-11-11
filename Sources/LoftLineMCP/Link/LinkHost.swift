import Foundation

/// A window as the link lists it. No path: the assistant learns it from `describe_project` after the user allows it.
public struct LinkDocument: Equatable, Sendable {
    public var id: String
    public var name: String
    public var unsaved: Bool

    public init(id: String, name: String, unsaved: Bool) {
        self.id = id
        self.name = name
        self.unsaved = unsaved
    }
}

/// One tool call for a window, already classified by the link: the host switches on `kind` and never compares tool names.
public struct LinkCall {
    public var kind: LinkToolKind
    public var tool: String
    public var arguments: [String: Any]
    public var document: String
    /// What the window held when it was claimed (`LinkHost.generation(of:)`): a host refuses the call if the window has since
    /// opened another file, so a call queued behind an Open can't edit the new one.
    public var generation: Int

    public init(kind: LinkToolKind, tool: String, arguments: [String: Any], document: String, generation: Int = 0) {
        self.kind = kind
        self.tool = tool
        self.arguments = arguments
        self.document = document
        self.generation = generation
    }
}

/// An app the link serves: the Mac app, or the desktop engine (spec 2, "Architecture"). The host draws the bars and forwards the
/// user's clicks to `claims`; the link owns everything else about connections.
public protocol LinkHost: AnyObject {
    func documents() -> [LinkDocument]
    func run(_ call: LinkCall) async throws -> ToolOutput
    var claims: ClaimBook { get }
    /// Moves whenever the window starts holding another file (the desktop's New and Open); 0 where a window keeps its file.
    func generation(of document: String) -> Int
}

public extension LinkHost {
    func generation(of document: String) -> Int { 0 }
}
