import Foundation

/// What the desktop window shows about the live link, polled once a second while the switch is on (spec 2, "The desktop host").
public struct AssistantStatus: Encodable, Equatable {
    public var changeRevision: Int
    /// Moves after every assistant call, a calculation included: the window refetches when it does.
    public var assistantRevision: Int
    public var claimed: Bool
    public var asking: Bool
    public var allowed: Bool
    public var changes: Int

    public init(changeRevision: Int, assistantRevision: Int = 0, claimed: Bool = false, asking: Bool = false, allowed: Bool = false,
                changes: Int = 0) {
        self.changeRevision = changeRevision
        self.assistantRevision = assistantRevision
        self.claimed = claimed
        self.asking = asking
        self.allowed = allowed
        self.changes = changes
    }
}

/// The live link as the desktop engine's requests reach it. It lives in LoftLineMCP; the engine only holds this.
public protocol CoreAssistantLink: AnyObject {
    func status(changeRevision: Int) -> AssistantStatus
    func answer(allow: Bool)
    func setDialog(open: Bool)
    /// New or Open replaced the window's project: the claim ends and the Allow is taken back.
    func documentChanged()
    func dismissMarker()
    /// Disconnect or Revoke in the window's bar: the claim ends and the Allow is taken back.
    func revoke()
    /// The window's project was saved to `to` (by the user or the assistant): the review marker follows it there.
    func saved(from: URL?, to: URL)
    /// Starts or stops the listener; throws when it can't listen, so the switch stays off.
    func switchChanged(_ on: Bool) throws
}
