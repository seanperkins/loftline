import Foundation
import LoftLineKit

/// Which project the server's tools act on (spec 2, "The server"): its own session (file mode), or a window open in LoftLine
/// (document mode, after `use_open_document`). Once in document mode it stays there until `open_project` or `new_project`, even
/// after the link ends, so an assistant never edits a file when it meant the window.
public final class DocumentMode {
    public let folder: URL
    public var socketURL: URL { folder.appendingPathComponent("assistant.sock") }
    /// The largest request sent over the link; a bigger call is refused here so the claim survives.
    public var maxRequest = 64 << 20
    private(set) var client: LinkClient?
    /// The window's name while in document mode.
    public private(set) var name: String?
    /// Why the link ended, told on every call until the assistant leaves document mode.
    private var ended: String?

    public init(folder: URL = AssistantSettings.linkFolder()) { self.folder = folder }

    public var isActive: Bool { name != nil }

    /// Back to file mode.
    public func leave() {
        client?.close()
        client = nil
        name = nil
        ended = nil
    }

    public func documents() throws -> [LinkDocument] {
        do { return try LinkClient.list(socket: socketURL) } catch {
            throw ToolError("LoftLine isn't listening at \(socketURL.path): it isn't running, or Help ▸ Connect an AI Assistant… ▸ "
                            + "\"Let assistants edit open documents\" is off.")
        }
    }

    /// Claims a window by id or name; the user clicks Allow in it the first time. Returns its name.
    @discardableResult
    public func use(_ reference: String) throws -> String {
        let docs = try documents()
        let byID = docs.filter { $0.id == reference }
        let byName = docs.filter { $0.name == reference }
        let match: LinkDocument
        if let d = byID.first { match = d }
        else if byName.count == 1 { match = byName[0] }
        else if byName.count > 1 {
            throw ToolError("\(byName.count) windows are named \(reference): ids \(byName.map(\.id).joined(separator: ", ")). Use an id.")
        } else {
            throw ToolError("No open document is named \(reference). Open: \(docs.map { "\($0.name) (\($0.id))" }.joined(separator: ", ")).")
        }
        // The first window's connection closes before the next claim; if that claim fails, the server stays in document mode
        // and refuses, rather than going back to its own file unasked.
        let wasActive = isActive
        client?.close()
        client = nil
        do {
            let c: LinkClient
            do { c = try LinkClient(socket: socketURL) } catch { throw ToolError("LoftLine isn't listening at \(socketURL.path).") }
            do { try c.claim(match.id) } catch { c.close(); throw error }
            client = c
            name = match.name
            ended = nil
            return match.name
        } catch {
            if wasActive { ended = "The switch to \(match.name) failed (\((error as? LocalizedError)?.errorDescription ?? "\(error)")); "
                + "use_open_document again, or open_project or new_project to work on a file." }
            throw error
        }
    }

    /// Runs `tool` on the window.
    public func call(_ tool: String, _ arguments: [String: Any]) throws -> ToolOutput {
        guard let client else { throw ToolError(ended ?? LinkClientError.closed.message) }
        do {
            return try client.call(tool, arguments, maxRequest: maxRequest)
        } catch let e as LinkClientError where e.code == "closed" || e.code == "released" {
            client.close()
            self.client = nil
            ended = e.message
            throw ToolError(e.message)
        }
    }
}
