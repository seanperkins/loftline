import Foundation

/// What went wrong talking to the open app, in the words the assistant is shown.
public struct LinkClientError: LocalizedError, Equatable {
    public var code: String
    public var message: String
    public var errorDescription: String? { message }

    static let closed = LinkClientError(code: "closed", message: "LoftLine closed the link (it quit, or its engine restarted); claim the document again.")
}

/// The server's end of the live link: one connection, which lists or claims one window and then calls tools on it.
public final class LinkClient {
    let fd: LinkHandle
    let reader: LinkReader
    private var closed = false

    public init(socket: URL) throws {
        fd = try LinkTransport.connect(to: socket)
        reader = LinkReader(fd, max: Int.max)
    }

    deinit { close() }

    public func close() {
        guard !closed else { return }
        closed = true
        LinkTransport.close(fd)
    }

    /// Sends one request and returns its reply; an error reply throws.
    func request(_ object: [String: Any], maxRequest: Int = 64 << 20) throws -> [String: Any] {
        var body = object
        body["v"] = LinkServer.version
        let line = try JSONSerialization.data(withJSONObject: body)
        guard line.count < maxRequest else {
            throw LinkClientError(code: "too_large", message: "That call is larger than the \(maxRequest / (1 << 20)) MiB LoftLine takes over the link; split it up.")
        }
        // A write can fail because LoftLine ended the claim and closed: its reason may already be waiting to be read.
        let wrote = (try? LinkTransport.writeLine(fd, line)) != nil
        guard case .line(let data)? = try? reader.next(),
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LinkClientError.closed }
        if let error = reply["error"] as? [String: Any] {
            throw LinkClientError(code: error["code"] as? String ?? "error", message: error["message"] as? String ?? "LoftLine refused that.")
        }
        guard wrote else { throw LinkClientError.closed }
        return reply
    }

    /// The open windows.
    public static func list(socket: URL) throws -> [LinkDocument] {
        let client = try LinkClient(socket: socket)
        defer { client.close() }
        let rows = try client.request(["op": "list"])["documents"] as? [[String: Any]] ?? []
        return rows.compactMap { r in
            guard let id = r["id"] as? String, let name = r["name"] as? String else { return nil }
            return LinkDocument(id: id, name: name, unsaved: r["unsaved"] as? Bool ?? false)
        }
    }

    public func claim(_ document: String) throws { _ = try request(["op": "claim", "document": document]) }

    public func call(_ tool: String, _ arguments: [String: Any], maxRequest: Int = 64 << 20) throws -> ToolOutput {
        let reply = try request(["op": "call", "tool": tool, "arguments": arguments], maxRequest: maxRequest)
        return ToolOutput(text: reply["text"] as? String ?? "", image: (reply["image"] as? String).flatMap { Data(base64Encoded: $0) })
    }
}
