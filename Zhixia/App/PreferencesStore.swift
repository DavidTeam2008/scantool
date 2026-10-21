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
        // spec/folded-page-capture（FR-001）：默认不自动拍——取景框抖动/锁错
        // 候选时自动拍只会产出废片，快门主导权交还用户。零迁移：didSet 在
        // init 内不触发，从未显式设置的用户无持久化键 → 默认翻转自然生效；
        // 显式设置过（含设为 true）的用户键已落盘 → 选择保留，不得添加
        // 迁移代码覆盖之。
        if defaults.object(forKey: Key.autoCapture) == nil {
            autoCapture = false
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
