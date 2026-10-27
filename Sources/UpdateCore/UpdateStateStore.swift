import Foundation

/// What the updater remembers between launches: when it last checked, the version the user chose to skip, and the version it
/// last asked about. Values of the wrong type are ignored, never trusted.
public struct UpdateStateStore {
    private let defaults: UserDefaults

    enum Key {
        static let lastCheck = "loftline.update.lastCheck"
        static let skippedVersion = "loftline.update.skippedVersion"
        static let lastPrompted = "loftline.update.lastPrompted"
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// When the last successful check finished.
    public var lastCheck: Date? {
        get { defaults.object(forKey: Key.lastCheck) as? Date }
        nonmutating set { store(newValue, forKey: Key.lastCheck) }
    }

    /// A version the user chose to skip: background checks do not offer it again.
    public var skippedVersion: String? {
        get { defaults.object(forKey: Key.skippedVersion) as? String }
        nonmutating set { store(newValue, forKey: Key.skippedVersion) }
    }

    /// The version whose sheet was last shown, so each version is announced once.
    public var lastPromptedVersion: String? {
        get { defaults.object(forKey: Key.lastPrompted) as? String }
        nonmutating set { store(newValue, forKey: Key.lastPrompted) }
    }

    private func store(_ value: Any?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
