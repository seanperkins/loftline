import AppKit
import CAMCore
import Foundation
import LoftLineKit
import LoftLineMCP

/// The Mac app's end of the live link (spec 2, "The Mac host"). Edits, posts and saves each run in one main-thread turn, so
/// nothing the user does lands between the snapshot and the apply; reads run on a background copy; nothing comes back from a
/// copy but an edit's project. The review marker is kept on disk, keyed by the window's file.
final class MacLinkHost: LinkHost, @unchecked Sendable {
    static let shared = MacLinkHost()

    let claims: ClaimBook
    let markers: ReviewMarkerStore
    let access: AssistantAccess
    let settingsFile: URL
    private(set) var server: LinkServer?

    private final class Weak { weak var doc: LoftLineDocument?; init(_ d: LoftLineDocument) { doc = d } }
    private final class WeakHost: @unchecked Sendable { weak var host: MacLinkHost? }
    /// Main thread only.
    private var registered: [String: Weak] = [:]
    /// What the claim book says, mirrored on the main thread for the guard and the bars.
    private var held: Set<String> = []
    private var allowed: Set<String> = []
    private var asking: Set<String> = []

    init(settingsFile: URL = AssistantSettings.fileURL, access: AssistantAccess? = nil, markers: ReviewMarkerStore? = nil) {
        self.settingsFile = settingsFile
        self.access = access ?? AssistantAccess(settingsFile: settingsFile)
        self.markers = markers ?? ReviewMarkerStore(file: settingsFile.deletingLastPathComponent().appendingPathComponent("review.json"))
        let weak = WeakHost()
        claims = ClaimBook { Task { await weak.host?.refreshNow() } }
        weak.host = self
    }

    // MARK: Windows

    func register(_ doc: LoftLineDocument) {
        dispatchPrecondition(condition: .onQueue(.main))
        registered[doc.linkID] = Weak(doc)
        doc.link = self
        doc.assistantChanges = doc.fileURL.map { markers.count(for: $0) } ?? 0
        doc.assistantBars = bars(for: doc.linkID)
    }

    /// The window closed: its claim ends and its Allow goes.
    func unregister(_ doc: LoftLineDocument) {
        registered[doc.linkID] = nil
        let id = doc.linkID
        server?.release(document: id, reason: "\(name(of: doc)) closed.")
        Task { await claims.revoke(id) }
    }

    /// Disconnect or Revoke in a window's bar.
    func revoke(_ doc: LoftLineDocument) {
        let id = doc.linkID
        server?.release(document: id, reason: "The user disconnected the assistant from \(name(of: doc)).")
        Task { await claims.revoke(id) }
    }

    func answer(_ doc: LoftLineDocument, allow: Bool) {
        let id = doc.linkID
        Task { await claims.answer(id, allow: allow) }
    }

    func dismissMarker(_ doc: LoftLineDocument) {
        if let url = doc.fileURL { try? markers.dismiss(url) }
        doc.assistantChanges = 0
    }

    /// The window's file changed (its first save, or Save As): the marker follows it.
    func fileURLChanged(_ doc: LoftLineDocument, from old: URL?) {
        guard let new = doc.fileURL, old?.standardizedFileURL != new.standardizedFileURL else { return }
        if let old { try? markers.move(from: old, to: new) } else if doc.assistantChanges > 0 { try? markers.add(doc.assistantChanges, for: new) }
        doc.assistantChanges = markers.count(for: new)
    }

    /// The switch in Help ▸ Connect an AI Assistant…: starts or stops the listener. Off takes back every Allow.
    func setSwitch(_ on: Bool) throws {
        if on {
            guard server == nil else { return }
            let s = LinkServer(folder: AssistantSettings.linkFolder(for: settingsFile), host: self)
            try s.start()
            server = s
        } else {
            server?.stop()
            server = nil
            Task { await claims.revokeAll() }
        }
    }

    @MainActor func refreshNow() async {
        let a = Set(await claims.asking), al = Set(await claims.allowed)
        var h: Set<String> = []
        for id in registered.keys where await claims.holder(of: id) != nil { h.insert(id) }
        asking = a
        allowed = al
        held = h
        for w in registered.values { if let d = w.doc { d.assistantBars = bars(for: d.linkID) } }
    }

    private func bars(for id: String) -> AssistantBars {
        AssistantBars(asking: asking.contains(id), claimed: held.contains(id), allowed: allowed.contains(id))
    }

    func name(of doc: LoftLineDocument) -> String {
        if Thread.isMainThread, let d = MainActor.assumeIsolated({ DocumentLocator.nsDocument(for: doc) }) { return d.displayName }
        return doc.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    static func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }

    // MARK: LinkHost

    func documents() -> [LinkDocument] {
        Self.onMain {
            registered.values.compactMap(\.doc).map { LinkDocument(id: $0.linkID, name: name(of: $0), unsaved: $0.needsRecovery) }
        }
    }

    func run(_ call: LinkCall) async throws -> ToolOutput {
        guard let doc = await MainActor.run(body: { registered[call.document]?.doc }) else {
            throw ToolError("That window closed.")
        }
        switch call.kind {
        case .edit:
            for attempt in 0..<10 {
                if attempt > 0 { await Self.nextPass() }
                if let out = try await MainActor.run(body: { try editTurn(doc, call) }) { return out }
            }
            throw ToolError("LoftLine is busy; try again.")
        case .calculate:
            try await MainActor.run { try guardWindow(doc) }
            let ids = (call.arguments["ids"] as? [String])?.compactMap(UUID.init(uuidString:)) ?? []
            _ = await doc.calculateUntilFresh(targets: ids.isEmpty ? doc.project.operations.filter(\.setup.isEnabled).map(\.id) : ids)
            return await MainActor.run { AssistantRunner.calculationReply(snapshot: doc.linkSnapshot(), ids: ids) }
        case .writeFiles:
            try await MainActor.run { try guardWindow(doc) }
            _ = await doc.calculateUntilFresh(targets: doc.project.operations.filter(\.setup.isEnabled).map(\.id))
            return try await MainActor.run {
                try guardWindow(doc)
                return try AssistantRunner.run(tool: call.tool, arguments: call.arguments, snapshot: doc.linkSnapshot(), access: access).output
            }
        case .read:
            if call.tool == "check" || call.tool == "preview" {
                _ = await doc.calculateUntilFresh(targets: doc.project.operations.filter(\.setup.isEnabled).map(\.id))
            }
            let (snapshot, title) = await MainActor.run { (doc.linkSnapshot(), name(of: doc)) }
            let access = self.access
            let out = try await Task.detached {
                try AssistantRunner.run(tool: call.tool, arguments: call.arguments, snapshot: snapshot, access: access).output
            }.value
            return call.tool == "describe_project" ? out.addingDocument(name: title, path: snapshot.fileURL?.path) : out
        case .save:
            try await MainActor.run {
                try guardWindow(doc)
                guard call.arguments["path"] == nil, let url = doc.fileURL else { throw ToolError("Use File ▸ Save As in LoftLine.") }
                try access.check(url)
            }
            try await DocumentLocator.save(doc)
            return ToolOutput(text: "Saved \(await MainActor.run { name(of: doc) }).")
        case .never:
            throw ToolError("\(call.tool) can't run on an open document.")
        }
    }

    /// The guard (spec 2): the claim held and allowed, the switch on, the window open, nothing modal on it.
    @MainActor func guardWindow(_ doc: LoftLineDocument) throws {
        guard registered[doc.linkID]?.doc != nil else { throw ToolError("That window closed.") }
        guard held.contains(doc.linkID), allowed.contains(doc.linkID) else { throw ToolError("The claim on \(name(of: doc)) ended.") }
        guard AssistantSettings.load(from: settingsFile).liveLink else {
            throw ToolError("\"Let assistants edit open documents\" is off in LoftLine.")
        }
        let window = DocumentLocator.nsDocument(for: doc)?.windowControllers.first?.window
        guard doc.presentedSheet == nil, window?.attachedSheet == nil, NSApp?.modalWindow == nil else {
            throw ToolError("Close the dialog in \(name(of: doc)) first.")
        }
    }

    /// One edit in one main-thread turn; nil when an undo group is open (the caller tries again next pass).
    @MainActor func editTurn(_ doc: LoftLineDocument, _ call: LinkCall) throws -> ToolOutput? {
        try guardWindow(doc)
        guard let undo = doc.undoManager else { throw ToolError("\(name(of: doc)) isn't ready yet.") }
        guard undo.groupingLevel == 0 else { return nil }
        let run = try AssistantRunner.run(tool: call.tool, arguments: call.arguments, snapshot: doc.linkSnapshot(), access: access)
        let before = doc.project
        let byEvent = undo.groupsByEvent
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        doc.perform(LinkToolKind.undoName(call.tool), pending: []) { $0 = run.project }
        undo.endUndoGrouping()
        undo.groupsByEvent = byEvent
        if !doc.project.document.job.isTwoSided, doc.activeSide != .top { doc.activeSide = .top }
        if doc.project != before {
            if let url = doc.fileURL { try? markers.add(1, for: url); doc.assistantChanges = markers.count(for: url) }
            else { doc.assistantChanges += 1 }
        }
        return run.output
    }

    /// A later run-loop pass, so an undo group the system opened for this one has closed.
    static func nextPass() async {
        await withCheckedContinuation { c in DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { c.resume() } }
    }
}

/// What a window's assistant bars show.
struct AssistantBars: Equatable {
    var asking = false
    var claimed = false
    var allowed = false
}
