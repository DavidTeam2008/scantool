import Foundation

@MainActor
@Observable
final class PreferencesStore {
    private enum Key {
        static let onboarding = "zhixia.onboardingComplete"
        static let autoCapture = "zhixia.autoCapture"
        static let defaultFilter = "zhixia.defaultFilter"
        static let keepOriginals = "zhixia.keepOriginals"
    }

    private let defaults: UserDefaults

    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.onboarding) }
    }

    var autoCapture: Bool {
        didSet { defaults.set(autoCapture, forKey: Key.autoCapture) }
    }

    var defaultEnhancement: Enhancement {
        didSet { defaults.set(defaultEnhancement.rawValue, forKey: Key.defaultFilter) }
    }

    var keepOriginals: Bool {
        didSet { defaults.set(keepOriginals, forKey: Key.keepOriginals) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasCompletedOnboarding = defaults.bool(forKey: Key.onboarding)
        if defaults.object(forKey: Key.autoCapture) == nil {
            autoCapture = true
        } else {
            autoCapture = defaults.bool(forKey: Key.autoCapture)
        }
        if let raw = defaults.string(forKey: Key.defaultFilter),
           let enhancement = Enhancement(rawValue: raw)
        {
            defaultEnhancement = enhancement
        } else {
            defaultEnhancement = .enhance
        }
        if defaults.object(forKey: Key.keepOriginals) == nil {
            keepOriginals = true
        } else {
            keepOriginals = defaults.bool(forKey: Key.keepOriginals)
        }
    }
}
