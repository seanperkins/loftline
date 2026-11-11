import Foundation
import LoftLineKit

/// The desktop engine's end of the live link (spec 2, "The desktop host"). One window, one session, one request at a time: the
/// stdin loop and the link take `lock` around each request they hand over, never inside `CoreService.handle`, so a tool calling
/// back into the engine through `CoreClient` doesn't re-enter it. Edits run on a copy and apply as one Undo step; everything
/// else runs in place.
public final class CoreLinkHost: LinkHost, CoreAssistantLink, @unchecked Sendable {
    public static let documentID = "desktop"

    public let service: CoreService
    public let claims: ClaimBook
    /// Taken by the stdin loop and by the link around each request.
    public let lock = NSLock()
    public var server: LinkServer?
    let access: AssistantAccess
    let settingsFile: URL

    private final class Weak: @unchecked Sendable { weak var host: CoreLinkHost? }
    private let mirrorLock = NSLock()
    private var mirror = (asking: false, allowed: false, claimed: false)
    private var dialogOpen = false
    /// Assistant edits since the marker was last dismissed.
    public private(set) var changes = 0

    public init(service: CoreService, access: AssistantAccess, settingsFile: URL = AssistantSettings.fileURL) {
        self.service = service
        self.access = access
        self.settingsFile = settingsFile
        let weak = Weak()
        claims = ClaimBook { weak.host?.refreshMirror() }
        weak.host = self
        service.assistantLink = self
    }

    /// One request from the front end, under the lock.
    public func handle(_ line: Data) -> Data {
        lock.lock()
        defer { lock.unlock() }
        return service.handle(line)
    }

    var session: CoreSession { service.session }

    var title: String {
        let name = session.project.document.name
        return name.isEmpty ? (session.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled") : name
    }

    public func documents() -> [LinkDocument] {
        lock.lock()
        defer { lock.unlock() }
        return [LinkDocument(id: Self.documentID, name: title, unsaved: session.isDirty)]
    }

    public func run(_ call: LinkCall) async throws -> ToolOutput {
        lock.lock()
        defer { lock.unlock() }
        guard AssistantSettings.load(from: settingsFile).liveLink else {
            throw ToolError("\"Let assistants edit open documents\" is off in LoftLine.")
        }
        if call.kind != .read && dialogOpen { throw ToolError("Close the dialog in \(title) first.") }
        switch call.kind {
        case .edit:
            let run = try AssistantRunner.run(tool: call.tool, arguments: call.arguments, snapshot: session.snapshot(), access: access)
            let before = session.project
            session.perform(LinkToolKind.undoName(call.tool)) { $0 = run.project }
            if session.project != before { changes += 1 }
            return run.output
        case .read, .calculate, .writeFiles, .save:
            guard let tool = AssistantTools.all(service: service, access: access).first(where: { $0.name == call.tool }) else {
                throw AssistantRunner.UnknownTool(tool: call.tool)
            }
            let out = try tool.call(call.arguments)
            return call.tool == "describe_project" ? out.addingDocument(name: title, path: session.fileURL?.path) : out
        case .never:
            throw ToolError("\(call.tool) can't run on an open document.")
        }
    }

    private func refreshMirror() {
        Task {
            let asking = await claims.asking.contains(Self.documentID)
            let allowed = await claims.allowed.contains(Self.documentID)
            let claimed = await claims.holder(of: Self.documentID) != nil
            mirrorLock.lock()
            mirror = (asking, allowed, claimed)
            mirrorLock.unlock()
        }
    }

    // MARK: CoreAssistantLink (called under `lock`, from the engine's requests)

    public func status(changeRevision: Int) -> AssistantStatus {
        mirrorLock.lock()
        defer { mirrorLock.unlock() }
        return AssistantStatus(changeRevision: changeRevision, claimed: mirror.claimed, asking: mirror.asking, allowed: mirror.allowed,
                               changes: changes)
    }

    public func answer(allow: Bool) {
        Task { await claims.answer(Self.documentID, allow: allow) }
    }

    public func setDialog(open: Bool) { dialogOpen = open }

    public func documentChanged() {
        server?.release(document: Self.documentID, reason: "LoftLine opened another file in that window; claim it again.")
        Task { await claims.revoke(Self.documentID) }
        changes = 0
    }

    public func dismissMarker() { changes = 0 }

    public func switchChanged(_ on: Bool) {
        if on {
            guard server == nil else { return }
            let s = LinkServer(folder: AssistantSettings.linkFolder(for: settingsFile), host: self)
            do { try s.start(); server = s } catch {
                FileHandle.standardError.write(Data("loftline-core: the live link didn't start: \(error.localizedDescription)\n".utf8))
            }
        } else {
            server?.stop()
            server = nil
            Task { await claims.revokeAll() }
        }
    }
}

extension ToolOutput {
    /// `describe_project` on an open window names it and its file.
    func addingDocument(name: String, path: String?) -> ToolOutput {
        let parts = text.split(separator: "\n", maxSplits: 1).map(String.init)
        guard parts.count == 2, var json = (try? JSONSerialization.jsonObject(with: Data(parts[1].utf8))) as? [String: Any] else { return self }
        json["document"] = name
        if let path { json["path"] = path }
        return Reply.output(parts[0], json)
    }
}
