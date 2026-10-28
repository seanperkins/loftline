import CAMCore

extension PostProfile {
    /// The stop a pause writes on this post: M1 for an optional stop only where the controller has the switch, else M0.
    public func stopCode(for pause: PauseStep) -> String {
        pause.isOptionalStop && honoursOptionalStop ? "M1" : "M0"
    }

    /// The pause's stop as the program header lists it: an M1 says the machine may run on.
    func stopSummary(for pause: PauseStep) -> String {
        let code = stopCode(for: pause)
        return code == "M1" ? "M1, stops only with Optional Stop on" : code
    }
}
