import Foundation

/// 快门裁切一致性判定结果（spec/wysiwyg-crop，plan D1）。
///
/// `resolve` 的输出值类型——最终裁切框 + 静帧精修是否被采纳 + 一致性度量值，
/// 供 `CaptureViewModel.capture()` 消费并写 `ZhixiaLog.cropGate` 诊断日志。
struct CropDecision: Equatable, Sendable {
    /// 最终裁切框（nil = 无任何可用框，由调用方回退 `.fullImage`）。
    var quad: Quad?
    /// 是否采纳了静帧精修（true = 静帧框胜出；false = 呈现框优先或无静帧框）。
    var usedStillRefinement: Bool
    /// 呈现框 vs 静帧框的包围盒 IoU（任一输入为 nil 时无度量，置 nil）。
    var consistency: Double?
}

/// 快门裁切一致性门禁（spec/wysiwyg-crop，plan D1/D2，FR-001~004）——纯函数，
/// 无状态无 I/O（与 `GuidanceDirective` 同位同风格）。
///
/// WYSIWYG 契约：**快门成片必须等于屏幕所见**。快门时刻对高清静帧重新检测
/// 的结果（可含贴边吸附）不再无条件优先，而是与屏幕呈现框（`imageQuad`，
/// 跟踪态 = smoother 输出 / 锁定态 = 锁定框 / 搜索态 = nil）做一致性判定：
///
/// 1. **无呈现框**（搜索态）→ 静帧自由检测照旧（FR-004，行为与修复前一致）；
/// 2. **有呈现框且一致**（bbox IoU ≥ 阈值，同文档小偏差/精修级差异）→
///    采纳静帧精修（FR-002，保平整文档贴边精度，US4 不回归）；
/// 3. **有呈现框且不一致**（右页 vs 整书外轮廓级偏离，实测 IoU ≈ 0.5）→
///    呈现框优先、静帧结果弃用（FR-003，消除 Case A「锁的是右页、裁的是整书」）。
///
/// 一致性度量复用既有 `Quad.iou(with:)`（包围盒 IoU），阈值默认 **0.70**
///（plan D1：同文档精修 ≥0.8、右页 vs 整书 ≈0.5，双侧 ≥0.1 余量），默认
/// 参数注入可测。idCard 模式与相册导入不走本门禁（FR-005，由调用方分流）。
enum CropConsistencyGate {
    /// 门禁一致性阈值（plan D1 默认值；参数注入供测试穷举边界）。
    static let defaultIOUThreshold: Double = 0.70

    /// 判定呈现框与静帧框的一致性并给出最终裁切框。
    ///
    /// - Parameters:
    ///   - displayed: 屏幕呈现框（照片空间，`imageQuad` 入口快照）；nil = 搜索态。
    ///   - still: 快门静帧重检测结果（照片空间，可含贴边吸附）；nil = 静帧检测失败。
    ///   - iouThreshold: 一致性 IoU 阈值，默认 0.70。
    /// - Returns: `CropDecision`（`quad` 为 nil 时调用方回退 `.fullImage`）。
    static func resolve(
        displayed: Quad?,
        still: Quad?,
        iouThreshold: Double = CropConsistencyGate.defaultIOUThreshold
    ) -> CropDecision {
        // 搜索态（无呈现框）：静帧自由检测照旧（FR-004）——衡量「与什么一致」
        // 的基准不存在，无度量值。
        guard let displayed else {
            return CropDecision(
                quad: still,
                usedStillRefinement: still != nil,
                consistency: nil
            )
        }
        // 静帧检测失败：呈现框优先（回退链中间层，与修复前语义一致）。
        guard let still else {
            return CropDecision(
                quad: displayed,
                usedStillRefinement: false,
                consistency: nil
            )
        }
        let iou = displayed.iou(with: still)
        if iou >= iouThreshold {
            // 一致：静帧高分辨率精修（含贴边吸附）采纳——平整文档精度不回归（FR-002）。
            return CropDecision(
                quad: still,
                usedStillRefinement: true,
                consistency: iou
            )
        }
        // 不一致：呈现框优先，静帧结果弃用（FR-003 / FR-001，WYSIWYG 兜底）。
        return CropDecision(
            quad: displayed,
            usedStillRefinement: false,
            consistency: iou
        )
    }
}
