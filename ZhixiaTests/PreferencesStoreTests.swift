import Foundation
import Testing

@testable import Zhixia

/// autoCapture 默认值翻转（spec/folded-page-capture，FR-001）：默认不自动拍。
/// 零迁移语义的三个可观测面各自钉住——默认 false / 显式开启持久化保留 /
/// 未设置用户的 init 不向 defaults 写键（didSet init 不触发 + 无迁移代码）。
@MainActor
struct PreferencesStoreTests {
    @Test("未设置过的用户 autoCapture 默认 false（默认不自动拍）")
    func autoCaptureDefaultsToFalse() {
        let defaults = UserDefaults(suiteName: "zhixia.prefs.\(UUID().uuidString)") ?? .standard
        let preferences = PreferencesStore(defaults: defaults)
        #expect(preferences.autoCapture == false)
    }

    @Test("显式开启过自动拍的用户选择保留（默认值翻转不覆盖持久化键）")
    func explicitAutoCaptureTrueSurvives() {
        let defaults = UserDefaults(suiteName: "zhixia.prefs.\(UUID().uuidString)") ?? .standard
        let first = PreferencesStore(defaults: defaults)
        first.autoCapture = true

        // 重新构造（模拟下次启动）：持久化键存在 → 读回 true，默认翻转不触及。
        let relaunched = PreferencesStore(defaults: defaults)
        #expect(relaunched.autoCapture == true)
    }

    @Test("未设置时 init 不写入持久化键（默认翻转对后续新值继续生效，无隐藏迁移）")
    func initDoesNotPersistDefault() {
        let suiteName = "zhixia.prefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        _ = PreferencesStore(defaults: defaults)
        #expect(defaults.object(forKey: "zhixia.autoCapture") == nil,
                "init 不得写入默认键——didSet 在 init 内不触发是零迁移设计的前提")
    }

    // MARK: - 取景模式 / 拍摄意图（spec/guided-capture T010 / FR-001）

    @Test("取景模式与拍摄意图默认值：auto / rightPage")
    func captureModeDefaults() {
        let defaults = UserDefaults(suiteName: "zhixia.prefs.\(UUID().uuidString)") ?? .standard
        let preferences = PreferencesStore(defaults: defaults)
        #expect(preferences.captureMode == .auto, "默认仍是自动路径（翻转需 A/B 数据）")
        #expect(preferences.captureIntent == .rightPage, "折页书右页是主场景意图")
    }

    @Test("取景模式与拍摄意图持久化：重启后读回")
    func captureModePersists() {
        let defaults = UserDefaults(suiteName: "zhixia.prefs.\(UUID().uuidString)") ?? .standard
        let first = PreferencesStore(defaults: defaults)
        first.captureMode = .guided
        first.captureIntent = .wholePage

        let relaunched = PreferencesStore(defaults: defaults)
        #expect(relaunched.captureMode == .guided)
        #expect(relaunched.captureIntent == .wholePage)
    }

    @Test("未知持久化值回退默认（老版本残留 / 手改存储不崩溃）")
    func unknownCaptureModeFallsBack() {
        let suiteName = "zhixia.prefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.set("wps-style", forKey: "zhixia.captureMode")
        defaults.set("diagonal", forKey: "zhixia.captureIntent")

        let preferences = PreferencesStore(defaults: defaults)
        #expect(preferences.captureMode == .auto)
        #expect(preferences.captureIntent == .rightPage)
    }
}
