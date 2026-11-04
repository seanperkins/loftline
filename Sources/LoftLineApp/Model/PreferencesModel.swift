import Combine
import Foundation
import LoftLineKit

/// Observable wrapper; every change is written straight to UserDefaults.
final class PreferencesModel: ObservableObject {
    static let shared = PreferencesModel(defaults: .standard)
    let defaults: UserDefaults
    @Published var prefs: AppPreferences {
        didSet { if prefs != oldValue { prefs.save(to: defaults) } }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        prefs = AppPreferences(defaults: defaults)
    }

    func resetToDefaults() { prefs = AppPreferences() }
}
