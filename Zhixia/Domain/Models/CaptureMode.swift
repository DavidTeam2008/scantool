import Foundation

/// 取景模式（spec/guided-capture T010 / FR-001 / D1）——用户如何表达拍摄意图。
///
/// - `auto`：**现有自动检测路径**（检测 → 粘滞 → 平滑 → 冻结 → 快门）。
///   本周期**零改动**（FR-009 不变式），作为回退路径保留。
/// - `guided`：**引导框路径**——用户用屏幕上的框表达「我要拍这一页」，
///   成片 = 引导框（WYSIWYG 由构造保证，见 `plan.md` D4）。
///
/// 默认 `auto`：翻转默认值需 SC-008 的 A/B 数据支撑（`plan.md` D9 / T032）。
enum CaptureMode: String, Codable, Sendable, CaseIterable, Hashable {
    case auto
    case guided
}
