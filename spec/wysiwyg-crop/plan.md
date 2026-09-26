# Implementation Plan: 所见即所得裁切（wysiwyg-crop）

**Input**: Feature specification from `spec/wysiwyg-crop/spec.md`

## Summary

快门成片必须等于屏幕所见。两项修复：① R4——`capture()` 静帧重检测结果无条件覆盖呈现框，新增**裁切一致性门禁** `CropConsistencyGate`（照片空间呈现框 vs 静帧框，bbox IoU ≥ 0.70 才采纳静帧精修，否则呈现框优先）；② R5——双候选逐帧交替胜出导致框跳动，检测器 live 路径新增**候选粘滞** `CandidateSticky`（与上次择优相似 IoU ≥ 0.60 的候选优先延续，3 帧无相似候选逃逸）。配套诊断日志、单测钉死（基线 302 只增不减）与真机验收协议。

## Technical Context

**Language/Version**: Swift 6（严格并发）、SwiftUI + @Observable
**Primary Dependencies**: Vision、AVFoundation、ImageIO/CoreGraphics、OSLog
**State Management**: 既有 iOS @Observable MVVM（非 HarmonyOS，N/A）
**Storage**: PageFileStore（本周期不改）
**Testing**: XCTest；基线 **302 = 301 passed + 1 known issue + 0 failed**，只增不减、既有断言零修改
**Target Platform**: iOS（真机 iPhone 13 验收；模拟器 iPhone 17 Pro 全量测试）
**Project Type**: mobile-app（纯离线）
**Performance Goals**: live 15fps 节奏不回退；门禁 O(1)、粘滞每帧 O(候选数)×IoU，无感知开销
**Constraints**: ServiceProtocols 零改动；Domain 纯函数无 I/O；检测链/评分/吸附/QuadSmoother 参数零改动；idCard 与相册导入不变
**Scale/Scope**: 改 3 源文件、增 2 源文件、增 2 测试文件 + 追加 1、增 1 验收协议、更新 1 手册

## Project Structure

### Documentation (this feature)

```text
spec/wysiwyg-crop/
├── spec.md                  # 需求（US1~US5 / FR-001~010）
├── plan.md                  # 本文件
├── tasks.md                 # Phase 3 产出
└── device-acceptance.md     # 真机验收协议
```

### Source Code (repository root)

```text
Zhixia/
├── Domain/
│   ├── CropConsistencyGate.swift          # 新增：门禁纯函数（与 GuidanceDirective 同位）
│   └── Models/Quad.swift                  # 零改动（复用 iou/boundingRect）
├── Services/
│   ├── Vision/
│   │   ├── VisionEdgeDetector.swift       # 修改：live 文档路径接入粘滞（still/idCard 不动）
│   │   └── CandidateSticky.swift          # 新增：候选粘滞（有状态 struct，与 QuadSmoother 同位）
│   └── ZhixiaLog.swift                    # 修改：cropGate / stickyOverride 日志助手
├── Features/Capture/
│   └── CaptureViewModel.swift             # 修改：capture() 门禁集成（文档模式）
ZhixiaTests/
├── CropConsistencyGateTests.swift         # 新增
├── CandidateStickyTests.swift             # 新增
└── CaptureViewModelTests.swift            # 追加（append-only）
docs/09-project-handbook.md                # 修改：WYSIWYG 契约 + 周期条目
spec/wysiwyg-crop/device-acceptance.md     # 新增
```

**Structure Decision**: 遵循既有 iOS 架构（Domain 纯函数 / Services 有状态 / Features MVVM），不引入新层级；纯逻辑入 Domain、检测器状态入 Services/Vision，与 GuidanceDirective / QuadSmoother 同位。

## Research & Decisions

### D1 一致性度量与阈值（FR-002/003）

- **Decision**: 复用 `Quad.iou(with:)`（包围盒 IoU），阈值 **0.70**，默认参数注入可测。
- **Rationale**: 同文档精修场景 IoU ≥0.8（吸附 ≤5%/边 + 帧间抖动 1~3%）；右页 vs 整书 ≈0.5（包含关系）；0.70 双侧 ≥0.1 余量。零新几何代码，与 DetectionStrategy 既有 IoU 用法同源。
- **Alternatives**: 顶点均值距离（需另定阈值、混合方案复杂）；多边形精确 IoU（过度工程）。

### D2 门禁集成点与呈现框来源（FR-001/004/005 + spec Edge Case「陈旧呈现框」）

- **Decision**: `capture()` 入口（任何复位前）读 `imageQuad` 作呈现框；`consume()` 的 `phase != .capturing` 闸保证 capturing 期间冻结 = 快门时刻所见；文档模式启用，idCard/相册导入保持原链。
- **Rationale**: `imageQuad` 即 overlay 渲染源（跟踪=smoother 输出/锁定=锁定框/搜索=nil），与屏幕所见同源；相位闸天然解决陈旧窗口问题，无需新状态。
- **Alternatives**: 独立 lastDisplayedQuad 状态（冗余）；门禁放检测器内（协议禁改且不知屏幕状态）。

### D3 候选粘滞（FR-006/007，用户决策①「仅止跳」）

- **Decision**: `CandidateSticky` 有状态 struct 挂 `VisionEdgeDetector` actor，仅 live 文档路径；相似判定 IoU ≥**0.60**；逃逸 = 连续 **3 帧**无相似候选即清空；先稳者胜，无中心偏好。
- **Rationale**: 振荡发生在检测器逐帧独立择优层——smoother 只见单 quad 无从选择，必须上游止跳；actor 状态串行安全；0.60 区分同候选跨帧（≥0.85）与右页 vs 整书（≈0.5）；3 帧 ≈0.2s 切换无感。
- **Alternatives**: smoother 层抑制（无候选池信息不足）；ViewModel 层记忆（跨层状态泄漏）；中心偏好启发式（用户已排除）。

### D4 诊断日志（FR-009）

- **Decision**: `ZhixiaLog.cropGate(displayedArea:stillArea:iou:acceptedStill:)` 文档模式每次快门一条；`stickyOverride(iou:)` 仅粘滞改写择优时一条；capture.debug + privacy.public，风格与既有通道一致。
- **Rationale**: SC-005 需可检索证据；与 detectionTier/relaxedLiveProbe 正交不合并。

### D5 测试钉死（FR-008）

- **Decision**: 新增 `CropConsistencyGateTests`（一致精修/不一致呈现框优先/无呈现框用静帧/双 nil/阈值边界）+ `CandidateStickyTests`（交替池保持/逃逸/相似更新/初锁跟随/空选计 miss）+ `CaptureViewModelTests` 追加 `CropGateAtShutterTests`（锁定+静帧分歧→裁锁定框【Case A】；锁定+一致→静帧精修【US4】；跟踪态手动拍→呈现框【Case B】；搜索态手动拍→静帧照旧；idCard 不变）+ 新 fake（live 序列/still 结果可注入）。
- **Rationale**: 纯函数/状态机/集成三层各自穷举；append-only 遵守断言零修改铁律；预期 +14~16 用例。

### D6 文档与验收闭环（FR-010）

- **Decision**: handbook §4.2 补 WYSIWYG 裁切契约、§6.11 周期条目；`device-acceptance.md` 含 Case A/B 重验 + 平整回归（SC-002/003）+ §0 Console.app 实时日志流程。
- **Rationale**: 上轮 SC-005 失证教训固化为流程。

## Data Model

```text
CropDecision（新增，值类型）
├── quad: Quad?                    // 最终裁切框（nil = 由调用方回退 .fullImage）
├── usedStillRefinement: Bool      // 是否采纳静帧精修
└── consistency: Double?           // 呈现框 vs 静帧框 IoU（无呈现框时 nil）

CandidateSticky（新增，有状态 struct，actor 持有）
├── private lastPick: Quad?        // 上次择优（粘滞锚点）
└── private missCount: Int         // 连续无相似候选帧数

常量（默认参数注入，可测）
├── 门禁一致性阈值 iouThreshold = 0.70
├── 粘滞相似阈值 similarityThreshold = 0.60
└── 粘滞逃逸 missLimit = 3
```

## Contracts & Interfaces

```text
CropConsistencyGate.resolve(displayed: Quad?, still: Quad?, iouThreshold: Double = 0.70) -> CropDecision
  纯函数（Domain，无 I/O）：
  - displayed == nil            → quad = still（搜索态，静帧自由）
  - still == nil                → quad = displayed
  - IoU(displayed, still) ≥ 阈值 → quad = still（精修采纳）
  - 否则                         → quad = displayed（WYSIWYG 优先）

CandidateSticky.apply(selection: DetectionStrategy.Selection?, pool: [Quad],
                       similarityThreshold: Double = 0.60, missLimit: Int = 3)
    -> DetectionStrategy.Selection?   // mutating
  - selection == nil → miss+1，达限清空 lastPick
  - lastPick == nil 或与 selection 相似 → 跟随并记 lastPick
  - pool 含 lastPick 相似候选 → 改选其中评分最高者（tier 沿用，同池同 tier）
  - pool 无相似候选 → miss+1，达限清空 lastPick 后跟随新选

ZhixiaLog.cropGate(displayedArea: Double, stillArea: Double, iou: Double, acceptedStill: Bool)
ZhixiaLog.stickyOverride(iou: Double)

capture() 文档模式新链（idCard/导入路径原链不变）：
  displayed = imageQuad（入口快照）→ still = detector.detect(imageData:)
  → decision = CropConsistencyGate.resolve(...) → log → quad = decision.quad ?? .fullImage
```

**不变式清单**：ServiceProtocols 零改动；DetectionStrategy 评分/两级兜底零改动；still 检测+吸附零改动；QuadSmoother 参数零改动；EdgeSnapper 零改动；idCard/相册导入零改动；既有测试断言零修改；测试基线 302 只增不减。
