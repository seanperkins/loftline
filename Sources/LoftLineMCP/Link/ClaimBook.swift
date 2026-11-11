import Foundation

/// How a claim on a window ended (spec 2, "Allow").
public enum ClaimResult: Equatable, Sendable {
    case allowed, denied, noAnswer, taken, alreadyAsking, refusedAfterDeny, closed

    /// What the assistant is told, for every result but `.allowed`.
    public func message(_ name: String) -> String {
        switch self {
        case .allowed: return "Allowed."
        case .denied: return "The user denied the assistant \(name)."
        case .noAnswer: return "Nobody answered in LoftLine within two minutes; ask the user to click Allow on \(name)."
        case .taken: return "Another assistant is working on \(name)."
        case .alreadyAsking: return "LoftLine is already asking."
        case .refusedAfterDeny: return "The user denied an assistant \(name); it can't be asked again until they turn the switch off and on or reopen it."
        case .closed: return "\(name) closed, or the user stopped the assistant."
        }
    }
}

/// The one owner of claim and Allow state for both apps (spec 2, "Allow"). Allow belongs to a window, not to an assistant: it
/// lasts until the window closes or opens another file, the app quits, or the user presses Disconnect or Revoke or turns the
/// switch off. An actor, so a claim waiting for the user's answer holds no host lock.
public actor ClaimBook {
    private struct Question {
        var token: UUID
        var connection: Int
        var continuation: CheckedContinuation<ClaimResult, Never>
    }

    private let timeout: Duration
    private let onChange: @Sendable () -> Void
    private var questions: [String: Question] = [:]
    private var allowedDocuments: Set<String> = []
    private var deniedDocuments: Set<String> = []
    private var holders: [String: Int] = [:]

    public init(timeout: Duration = .seconds(120), onChange: @escaping @Sendable () -> Void) {
        self.timeout = timeout
        self.onChange = onChange
    }

    /// The documents LoftLine is asking about now (each host draws the Allow bar for these).
    public var asking: [String] { Array(questions.keys) }
    /// The documents allowed in this session, held or not (the host shows Revoke for an allowed, unheld one).
    public var allowed: [String] { Array(allowedDocuments) }
    public func holder(of document: String) -> Int? { holders[document] }

    /// Claims `document` for `connection`: at once when the window is already allowed, otherwise after asking the user.
    public func claim(_ document: String, connection: Int) async -> ClaimResult {
        if deniedDocuments.contains(document) { return .refusedAfterDeny }
        if let held = holders[document], held != connection { return .taken }
        if questions[document] != nil { return .alreadyAsking }
        if allowedDocuments.contains(document) {
            holders[document] = connection
            onChange()
            return .allowed
        }
        let token = UUID()
        let timeout = self.timeout
        return await withCheckedContinuation { continuation in
            questions[document] = Question(token: token, connection: connection, continuation: continuation)
            onChange()
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expire(document, token: token)
            }
        }
    }

    private func expire(_ document: String, token: UUID) {
        guard let q = questions[document], q.token == token else { return }
        questions[document] = nil
        onChange()
        q.continuation.resume(returning: .noAnswer)
    }

    /// The user's Allow or Deny for `document`.
    public func answer(_ document: String, allow: Bool) {
        guard let q = questions.removeValue(forKey: document) else { return }
        if allow {
            allowedDocuments.insert(document)
            holders[document] = q.connection
        } else {
            deniedDocuments.insert(document)
        }
        onChange()
        q.continuation.resume(returning: allow ? .allowed : .denied)
    }

    /// A connection ended: it holds nothing any more. The windows it was allowed stay allowed.
    public func release(connection: Int) {
        for (doc, held) in holders where held == connection { holders[doc] = nil }
        for (doc, q) in questions where q.connection == connection {
            questions[doc] = nil
            q.continuation.resume(returning: .closed)
        }
        onChange()
    }

    /// Disconnect, Revoke, the window closing or opening another file: the claim ends and the next one asks again.
    public func revoke(_ document: String) {
        allowedDocuments.remove(document)
        deniedDocuments.remove(document)
        holders[document] = nil
        if let q = questions.removeValue(forKey: document) { q.continuation.resume(returning: .closed) }
        onChange()
    }

    /// The switch went off: every claim ends, every Allow and Deny is forgotten.
    public func revokeAll() {
        for doc in Set(allowedDocuments).union(deniedDocuments).union(holders.keys).union(questions.keys) { revoke(doc) }
    }
}
