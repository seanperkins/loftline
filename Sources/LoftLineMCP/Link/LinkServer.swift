import Foundation

/// The app's end of the live link (spec 2, "The link protocol"): it listens at `link/assistant.sock`, frames each connection's
/// lines on its own thread, holds no host lock while reading, checks the version, caps requests and connections, closes idle
/// unclaimed connections, and refuses Never and unknown tools before the host sees them.
public final class LinkServer: @unchecked Sendable {
    public static let version = 1

    public let folder: URL
    public var socketURL: URL { folder.appendingPathComponent("assistant.sock") }
    let host: LinkHost
    let idleTimeout: TimeInterval
    let maxRequest: Int
    let maxConnections: Int

    private let lock = NSLock()
    private var listener: LinkHandle?
    private var connections: [Int: LinkHandle] = [:]
    /// Which window each connection holds, and its generation when claimed.
    private var claimed: [Int: String] = [:]
    private var claimedGeneration: [Int: Int] = [:]
    private var nextConnection = 1

    public init(folder: URL, host: LinkHost, idleTimeout: TimeInterval = 30, maxRequest: Int = 64 << 20, maxConnections: Int = 4) {
        self.folder = folder
        self.host = host
        self.idleTimeout = idleTimeout
        self.maxRequest = maxRequest
        self.maxConnections = maxConnections
    }

    public func start() throws {
        try LinkTransport.prepareFolder(folder)
        let fd = try LinkTransport.listen(at: socketURL)
        lock.lock(); listener = fd; lock.unlock()
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    }

    /// Closes the listener and every connection, and removes the socket file.
    public func stop() {
        lock.lock()
        let fd = listener
        listener = nil
        let open = Array(connections.values)
        lock.unlock()
        if let fd { LinkTransport.shutdown(fd); LinkTransport.close(fd) }
        open.forEach(LinkTransport.shutdown)
        try? FileManager.default.removeItem(at: socketURL)
    }

    /// Ends the claim on `document`: its connection gets `released` with the reason, then closes.
    public func release(document: String, reason: String) {
        lock.lock()
        let held = claimed.first { $0.value == document }.flatMap { connections[$0.key] }
        lock.unlock()
        guard let fd = held else { return }
        try? LinkTransport.writeLine(fd, Self.error("released", reason))
        LinkTransport.shutdown(fd)
    }

    private func acceptLoop(_ listener: LinkHandle) {
        while true {
            guard let fd = try? LinkTransport.accept(listener) else { return }
            lock.lock()
            let full = connections.count >= maxConnections
            let id = nextConnection
            if !full { connections[id] = fd; nextConnection += 1 }
            lock.unlock()
            if full {
                try? LinkTransport.writeLine(fd, Self.error("busy", "LoftLine already has \(maxConnections) assistant connections."))
                LinkTransport.close(fd)
                continue
            }
            Thread.detachNewThread { [weak self] in self?.serve(fd, id) }
        }
    }

    private func serve(_ fd: LinkHandle, _ id: Int) {
        defer {
            lock.lock()
            connections[id] = nil
            claimed[id] = nil
            claimedGeneration[id] = nil
            lock.unlock()
            Self.wait { await self.host.claims.release(connection: id) }
            LinkTransport.close(fd)
        }
        do { try LinkTransport.checkPeer(fd) } catch { return }
        let reader = LinkReader(fd, max: maxRequest)
        LinkTransport.setReceiveTimeout(fd, idleTimeout)
        while true {
            let next: LinkLine?
            do { next = try reader.next() } catch { return }   // idle, or the socket failed
            guard let next else { return }
            guard case .line(let data) = next else {
                guard (try? LinkTransport.writeLine(fd, Self.error("too_large", "That request is larger than \(maxRequest) bytes."))) != nil else { return }
                continue
            }
            guard let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            let (reply, close) = answer(request, connection: id, fd: fd)
            guard (try? LinkTransport.writeLine(fd, reply)) != nil, !close else { return }
        }
    }

    /// The reply to one request, and whether the connection then closes.
    private func answer(_ request: [String: Any], connection id: Int, fd: LinkHandle) -> (Data, Bool) {
        let v = (request["v"] as? NSNumber)?.intValue ?? 0
        if v > Self.version { return (Self.error("version", "This LoftLine is older than its assistant server; update LoftLine."), false) }
        if v < Self.version {
            return (Self.error("version", "The assistant server is older than this LoftLine; point the assistant at the server inside this LoftLine."), false)
        }
        switch request["op"] as? String {
        case "list":
            let docs = host.documents()
            let rows: [[String: Any]] = Self.wait {
                var out: [[String: Any]] = []
                for d in docs {
                    out.append(["id": d.id, "name": d.name, "unsaved": d.unsaved, "claimed": await self.host.claims.holder(of: d.id) != nil])
                }
                return out
            }
            return (Self.json(["documents": rows]), true)
        case "claim":
            guard let doc = request["document"] as? String, let found = host.documents().first(where: { $0.id == doc }) else {
                return (Self.error("no_document", "No open document has that id."), false)
            }
            lock.lock(); let already = claimed[id]; lock.unlock()
            if let already, already != doc { return (Self.error("claimed", "This connection already holds another document."), false) }
            // Waiting for the user's answer: no lock held, and the idle timeout must not cut it short.
            LinkTransport.setReceiveTimeout(fd, nil)
            let generation = host.generation(of: doc)   // before the wait: an Open while the user decides makes it stale
            let result = Self.wait { await self.host.claims.claim(doc, connection: id) }
            guard result == .allowed else {
                LinkTransport.setReceiveTimeout(fd, idleTimeout)
                return (Self.error("claim", result.message(found.name)), false)
            }
            lock.lock(); claimed[id] = doc; claimedGeneration[id] = generation; lock.unlock()
            return (Self.json([:]), false)
        case "call":
            lock.lock(); let doc = claimed[id]; let generation = claimedGeneration[id] ?? 0; lock.unlock()
            guard let doc else { return (Self.error("not_claimed", "Claim a document first."), false) }
            guard Self.wait({ await self.host.claims.holder(of: doc) }) == id else {
                return (Self.error("released", "The claim on this document ended."), true)
            }
            let tool = request["tool"] as? String ?? ""
            guard let kind = LinkToolKind.of(tool), kind != .never else {
                return (Self.error("refused", tool == "undo" ? "Undo is yours: Edit ▸ Undo in LoftLine takes back the assistant's steps."
                                   : "\(tool) can't run on an open document."), false)
            }
            let call = LinkCall(kind: kind, tool: tool, arguments: request["arguments"] as? [String: Any] ?? [:], document: doc,
                                generation: generation)
            let outcome: Result<ToolOutput, Error> = Self.wait {
                do { return .success(try await self.host.run(call)) } catch { return .failure(error) }
            }
            switch outcome {
            case .success(let out):
                var body: [String: Any] = ["text": out.text]
                if let image = out.image { body["image"] = image.base64EncodedString() }
                return (Self.json(body), false)
            case .failure(let error):
                return (Self.error("tool", (error as? LocalizedError)?.errorDescription ?? "\(error)"), false)
            }
        default:
            return (Self.error("unknown_op", "Unknown request."), false)
        }
    }

    static func json(_ object: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8) }
    static func error(_ code: String, _ message: String) -> Data { json(["error": ["code": code, "message": message]]) }

    /// Runs async work from a connection's thread and waits for it.
    static func wait<T>(_ body: @escaping () async -> T) -> T {
        let done = DispatchSemaphore(value: 0)
        var value: T?
        Task {
            value = await body()
            done.signal()
        }
        done.wait()
        return value!
    }
}
