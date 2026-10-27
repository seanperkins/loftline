import Foundation
import Testing
import UpdateCore

@Suite struct UpdateStateStoreTests {
    static func defaults() -> (UserDefaults, String) {
        let name = "loftline-tests-update-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func stateStoreRoundTripsItsValues() {
        let (defaults, name) = Self.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UpdateStateStore(defaults: defaults)
        #expect(store.lastCheck == nil && store.skippedVersion == nil && store.lastPromptedVersion == nil)

        let when = Date(timeIntervalSince1970: 1_800_000_000)
        store.lastCheck = when
        store.skippedVersion = "0.2.1"
        store.lastPromptedVersion = "0.2.2"

        let again = UpdateStateStore(defaults: defaults)
        #expect(again.lastCheck == when)
        #expect(again.skippedVersion == "0.2.1")
        #expect(again.lastPromptedVersion == "0.2.2")

        store.skippedVersion = nil
        store.lastCheck = nil
        #expect(UpdateStateStore(defaults: defaults).skippedVersion == nil)
        #expect(UpdateStateStore(defaults: defaults).lastCheck == nil)
    }

    @Test func usesTheDocumentedKeys() {
        let (defaults, name) = Self.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UpdateStateStore(defaults: defaults)
        store.lastCheck = Date(timeIntervalSince1970: 5)
        store.skippedVersion = "1.0.0"
        store.lastPromptedVersion = "1.0.1"
        #expect(defaults.object(forKey: "loftline.update.lastCheck") as? Date == Date(timeIntervalSince1970: 5))
        #expect(defaults.string(forKey: "loftline.update.skippedVersion") == "1.0.0")
        #expect(defaults.string(forKey: "loftline.update.lastPrompted") == "1.0.1")
    }

    @Test func ignoresValuesOfTheWrongType() {
        let (defaults, name) = Self.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(5, forKey: "loftline.update.skippedVersion")
        defaults.set("yesterday", forKey: "loftline.update.lastCheck")
        defaults.set(true, forKey: "loftline.update.lastPrompted")
        let store = UpdateStateStore(defaults: defaults)
        #expect(store.skippedVersion == nil)
        #expect(store.lastCheck == nil)
        #expect(store.lastPromptedVersion == nil)
    }
}
