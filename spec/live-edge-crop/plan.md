# Implementation Plan: live-edge-crop（取景实线边框与折页书可靠裁切）

**Input**: Feature specification from `spec/live-edge-crop/spec.md`

## Summary

折页厚书的曲面页边缘不满足矩形检测的直线假设：live 严格检测长期 searching、快门 still 重检也失败，成片落回全幅不裁。技术方案三点：① `VisionEdgeDetector` live 链增加第三级「放宽矩形」条件兜底（严格矩形 → 条件文档分割 → 放宽矩形，参数与 still 路径同源），三级候选进同一 `DetectionStrategy.select` 择优；② `EdgeOverlayView` 整框改连续实线（跟踪态细实线替换虚线、锁定态新增粗实线整框），样式提取为纯数据 `DocumentFrameStyle` 可测；③ 快门回退链 `detected ?? imageQuad ?? .fullImage` 与预览手动调框语义零改动，以测试钉死三分支与 US4 兜底不回退。

## Technical Context

**Language/Version**: Swift 5.9+（Xcode 工程 Zhixia.xcodeproj）
**Primary Dependencies**: SwiftUI + UIKit（UI）、AVFoundation（相机会话）、Vision（VNDetectRectanglesRequest / VNDetectDocumentSegmentationRequest）
**State Management**: N/A（非 HarmonyOS 项目；既有 @Observable MVVM 保持不变）
**Storage**: 既有文件存储（PageFileStoring 原图落盘）；本轮零新增持久化
**Testing**: XCTest（`xcodebuild test`，iPhone 17 Pro 模拟器；基线 280 用例只增不减）
**Target Platform**: iOS（真机 iPhone 13 验收 + 模拟器）
**Project Type**: mobile-app
**Performance Goals**: live 逐帧检测不显著掉帧——放宽档仅在「严格+分割双失败」帧条件触发，检测器 actor 忙时丢帧机制不变
**Constraints**: 纯离线；`EdgeDetecting` 等协议签名不变；证件模式路径不变；测试基线 280 只增不减
**Scale/Scope**: 改动 3 个源文件 + 3~4 个测试文件，单点小特性

## Project Structure

### Documentation (this feature)

```text
spec/live-edge-crop/
├── spec.md              # 需求（US1~US4 / FR-001~007 / SC-001~005）
├── plan.md              # 本文件
└── tasks.md             # Phase 3 产出
```

### Source Code (repository root)

```text
Zhixia/
├── Services/
│   ├── Vision/
│   │   └── VisionEdgeDetector.swift   # 修改：live 三级检测链（D1）+ needsRelaxedRectangles 门控（D2）+ 触发日志（D3）
│   └── ZhixiaLog.swift                # 修改：新增 relaxedLiveProbe 日志 API（D3）
└── Features/
    └── Capture/
        └── EdgeOverlayView.swift      # 修改：实线整框 + DocumentFrameStyle 样式提取（D4）

ZhixiaTests/
├── EdgeDetectionStrategyTests.swift   # 扩展：needsRelaxedRectangles 穷举 + 放宽候选进池择优语义（D6）
├── CaptureViewModelTests.swift        # 扩展：快门回退链三分支替身测试（D5）
├── DocumentFrameStyleTests.swift      # 新增：整框样式纯数据断言（D4/D6）
└── CaptureFallbackTests.swift         # 既有回归保持（overlay 映射/自动快门门禁不回退）
```

**Structure Decision**: 遵循既有 iOS 项目架构（Features/Services/Domain 分层 + @Observable MVVM），零新目录、零新模块；改动收敛在检测器与取景 overlay 两点及其测试。本特性为既有项目增量，不涉及新结构选型。

## Complexity Tracking

无 Constitution Check 违规——不适用（无新增项目/目录/模式，全部为既有文件内的增量修改）。

## Research & Decisions

### D1 三级检测兜底的接入点（FR-001）

- **Decision**: 在 `VisionEdgeDetector` 私有核心 `detect(cgImage:orientation:idCardWindow:stillImage:)` 内扩展 live 分支：既有「严格矩形 → 条件文档分割」之后新增第三级——`stillImage == false` 且严格矩形无可信候选且文档分割无结果时，以 `detectRectangles(relaxed: true)` 再执行一次（直接复用 still 路径的放宽参数集：置信度 0.35 / 最小尺寸 0.08 / 直角容差 28° / 候选上限 8，零新参数）。三级候选并入同一候选池，统一经 `DetectionStrategy.select` 择优（面积下限 / 两级面积兜底 / 包含降权语义不变）。
- **Rationale**: 单点接入使 live 与 still 共用同一择优、门禁与日志骨架；`detectRectangles(relaxed:)` 参数化已存在，live 分支只多一个条件触发；放宽档候选天然进入两级面积兜底（0.96 → ≤1.0）与包含降权，整幅误检防护不变。
- **Alternatives considered**: ① ViewModel 层串联第二次 `detect` 调用——破坏「一次 detect 一次完整检测」语义，无法共享候选池，且会把检测编排漏到 UI 层；② 独立新检测器类型——过度设计，两处调用方都要改。

### D2 触发门控纯函数（FR-002）

- **Decision**: `DetectionStrategy` 新增纯函数 `needsRelaxedRectangles(rectangles:segmented:) -> Bool`：仅当严格候选无可信项（复用 `needsDocumentSegmentation(rectangles:)` 的判定口径）且 `segmented == nil` 时返回 true。与 `needsDocumentSegmentation` 同风格、同位置。
- **Rationale**: 门控条件独立成纯函数可穷举单测（strict空+seg无→true；strict有→false；strict空+seg有→false）；避免在 actor 方法内散落复合条件。
- **Alternatives considered**: 内联布尔条件——不可穷举测试，未来调整阈值无锚点。

### D3 放宽档可观测性（FR-007）

- **Decision**: `ZhixiaLog`（`Zhixia/Services/ZhixiaLog.swift`）新增单行日志 API `relaxedLiveProbe(triggered: Bool, candidates: Int)`（命名可在实施中微调，保持单行 OSLog 语义），在 live 三级链路记录：是否触发、放宽档命中候选数。既有 `detectionTier` 日志通道完全不动（tier 字段语义仍是面积兜底档位）。
- **Rationale**: `detectionTier.tier` 语义是「两级面积兜底」，复用会污染既有验收对照口径；独立日志行可在真机 Console 直接检索放宽档触发率（SC-005 验收证据）。
- **Alternatives considered**: 扩展 `detectionTier` 加来源参数——语义混杂，破坏既有日志解析习惯。

### D4 实线整框与样式提取（FR-003）

- **Decision**: `EdgeOverlayView.documentEdgeOverlay` 的整框描边提取为纯数据样式 `DocumentFrameStyle`：跟踪态 = 单线、线宽 2.5、Tokens.seal 45%、**dash 为空**（替换现有虚线 [8,6]）；锁定态 = **新增整框**、双线风格（暗描边约 5pt + 白面约 3pt，与四角括号同风格）、**dash 为空**。「实线」性质（dash 恒空）落进类型不变量。四角括号、框外压暗（0.25/0.45）、证件模式路径全部不动。`DocumentFrameStyle` 与 `EdgeOverlayView` 同文件或紧邻，测试直接断言其字段。
- **Rationale**: FR-003 的核心可测性质是「连续实线（无 dash）+ 锁定更粗」——提取纯数据使渲染断言不依赖快照测试；两态视觉差异全部落进可断言字段。
- **Alternatives considered**: ① 直接内联改 stroke 参数——样式回归无测试锚点；② 引入 iOS 快照测试——项目无此基建，成本不成比例。

### D5 US3/US4 为测试保护型故事（FR-004/FR-005）

- **Decision**: 快门回退链 `detected ?? imageQuad ?? .fullImage`（`CaptureViewModel.capture()`）与预览调框（`CropCanvas` / `ReviewViewModel.updateQuad` / `userAdjustedQuad`）**零代码改动**。US3 的实现量为测试锚定：替身 camera/detector 下快门链三分支测试（重检成功→重检框；重检失败→live 框；双失败→全幅），追加进 `CaptureViewModelTests.swift`。US4 由既有 `CropCanvasLayoutTests` / Review 回归保持通过覆盖。
- **Rationale**: 回退链语义已存在且上一轮已验证；本轮价值 = 三级兜底把中间层（live 框）在折页场景填上 + 用测试钉死回退链不被未来改动破坏。用户已确认「快门重检优先」，不改动是其直接推论。
- **Alternatives considered**: 改为严格所见即所得（成片=取景框）——用户已明确否决。

### D6 测试策略（SC-002/SC-005）

- **Decision**: ① `EdgeDetectionStrategyTests.swift` 扩展：`needsRelaxedRectangles` 触发组合穷举 + 放宽候选进池后的择优语义（整幅误检仍受两级兜底管控）；② `CaptureViewModelTests.swift` 扩展：快门回退链三分支替身测试；③ 新增 `DocumentFrameStyleTests.swift`：实线性质（dash 空）、两态线宽/双线差异断言；④ 既有 280 用例全部保持（基线只增不减）。
- **Rationale**: 全部改动点（门控/样式/回退链）都有纯函数或替身可测面；「strict 找不到而 relaxed 找得到」的真实曲边图像无法稳定合成——真机折页场景由 device-acceptance 清单人工验收（SC-001）。
- **Alternatives considered**: 合成图像集成测试 Vision 行为——构造不可靠（Vision 对合成图像敏感，测试会 flaky），放弃。

## Data Model

- **无新持久化实体**。运行期新增：
  - `DocumentFrameStyle`：取景整框描边的纯数据配置（跟踪/锁定两态：线宽、单/双线、暗描边宽度；**dash 恒空**为类型不变量）——`EdgeOverlayView` 消费、测试直接断言字段。
  - `DetectionStrategy.needsRelaxedRectangles(rectangles:segmented:)`：纯函数门控（非数据实体）。
- **复用（语义全部不变）**：`Quad`（照片空间检测框，y-down）、`QuadTrackState`（searching/tracking/locked）、`CaptureGeometry`、`PageDraft`（含裁切 quad 与 `userAdjustedQuad`）、`DetectionStrategy.Selection`（quad + tier）。

## Contracts & Interfaces

- **`EdgeDetecting` 协议**：签名不变（`detect(frame:idCardWindow:)` / `detect(imageData:idCardWindow:)`）；`VisionEdgeDetector` live 路径行为扩展（第三级兜底），调用方零感知——返回 `Quad?` 语义不变。
- **`ZhixiaLog`**：新增 `relaxedLiveProbe(triggered:candidates:)` 单行日志 API；既有日志通道（`detectionTier` / `overlayProbeAnalytic` 等）签名与语义不变。
- **`DocumentFrameStyle`**：内部新类型（不入协议），`EdgeOverlayView` 与测试可见。
- **零改动契约**：`CameraCapturing` / `PageFileStoring` / `PermissionGranting` / `PreferencesStore` 协议；`CaptureViewModel.capture()` 的回退链表达式语义（测试钉死）；`ReviewViewModel.updateQuad` / `userAdjustedQuad` 语义；证件模式（idCard）检测与渲染路径；自动快门仅锁定态触发 + 可疑锁定门禁全链路一致（放宽档命中框同样流经 `QuadSmoother` 与 `isSuspiciousForAutoCapture`，无旁路）。
