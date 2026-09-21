# Implementation Plan: 取景整框可见性与锁定确认窗（overlay-frame-visibility）

**Input**: Feature specification from `spec/overlay-frame-visibility/spec.md`

## Summary

修复 live-edge-crop 真机验收暴露的两处缺陷：① 取景整框与框外压暗因坐标空间错配（屏幕点被 `QuadShape` 当归一化坐标 ×rect）画到屏幕外——将 `QuadShape` 改为屏幕点语义单点修复（4 处调用全部归位）；② 自动快门在锁定首帧同帧立即拍摄——为 `CaptureViewModel` 增加帧计数式锁定确认窗（默认 6 帧 ≈ 0.4s@15fps，可注入阈值），窗内解锁即取消、非可疑锁定帧才计数。测试钉死 Shape 坐标契约与确认窗行为，基线 295 只增不减，装机后按 live-edge-crop 清单重验并以 Console.app 实时抓取 SC-005 日志。

## Technical Context

**Language/Version**: Swift 5.9+（SwiftUI `@Observable` MVVM，Xcode 26 工具链）
**Primary Dependencies**: SwiftUI、AVFoundation（相机）、CoreGraphics（Path/CGAffineTransform 不涉及）
**State Management**: 既有 `@Observable` MVVM（CaptureViewModel 私有状态扩展，无迁移）
**Storage**: 无新增持久化（确认窗为纯内存状态）
**Testing**: XCTest（`xcodebuild test`，iPhone 17 Pro 模拟器；构建需 `DEVELOPER_DIR` + `OTHER_SWIFT_FLAGS="-disable-sandbox"` + 双 skip 校验旗标）
**Target Platform**: iOS（模拟器全量测试 + iPhone 13 真机验收，签名 `DEVELOPMENT_TEAM=VV865TW6B3`）
**Project Type**: mobile-app（纯离线文档扫描）
**Performance Goals**: 取景渲染零新增计算（坐标修复为语义纠正非增法）；自动快门节奏增加 0.4s 确认窗（用户已确认）
**Constraints**: ServiceProtocols 协议签名零变化；QuadSmoother / DetectionStrategy / 三级检测链 / 快门回退链 / OverlaySpaceMap / FOVLayout 零行为改动（FR-008）；测试基线 ≥295 且 0 failed（FR-009）；压暗层次 0.25/0.45 数值不变
**Scale/Scope**: 2 个源文件改动（EdgeOverlayView、CaptureViewModel）+ 1 个新测试文件 + 1 个测试文件扩展 + 文档

## Project Structure

### Documentation (this feature)

```text
spec/overlay-frame-visibility/
├── spec.md              # 需求（US1~US5 / FR-001~010 / SC-001~005）
├── plan.md              # 本文件
├── tasks.md             # 任务清单（Phase 3 产出）
└── device-acceptance.md # 真机验收协议（重验 live-edge-crop 清单 + 日志实时抓取）
```

### Source Code (repository root)

```text
Zhixia/
├── Features/Capture/
│   ├── EdgeOverlayView.swift      # D1：QuadShape 坐标语义修复 + 契约文档
│   └── CaptureViewModel.swift     # D2：锁定确认窗（帧计数 + 可注入阈值）
ZhixiaTests/
├── EdgeOverlayRenderingTests.swift  # 新建：QuadShape 屏幕点契约（D3）
└── CaptureViewModelTests.swift      # 扩展：确认窗行为用例（D3）
docs/
└── 09-project-handbook.md           # 坐标契约记载更新（如现有文档涉及）
```

**Structure Decision**: 遵循既有项目架构（Features MVVM + Services 协议实现 + Domain 纯函数），不引入新目录/层级；改动集中于 Capture 特性内 2 个文件，测试按既有文件组织惯例新建 1 个 + 扩展 1 个。

## Complexity Tracking

> 无 Constitution Check 违规——改动为既有类型语义纠正 + 既有 ViewModel 状态扩展，无需豁免说明。

## Research & Decisions

### D1: QuadShape 改为屏幕点坐标语义（单点契约修复）

- **Decision**: `QuadShape.path(in:)` 改为直接消费**屏幕点坐标**（忽略 rect 参数，输出点 = 输入点），与 `CornerBracketsShape` 同约定；类型文档注释明确「输入为屏幕点空间（`OverlaySpaceMap.screenQuad` 产物）」契约。EdgeOverlayView 内 4 处调用（锁定/跟踪整框描边 ×2、压暗 reverseMask 挖孔、idCard 检测框描边）全部已传屏幕点 viewQuad，**零调用点改动**即全部修复。
- **Rationale**: 影响面已核实——全仓 grep 显示 `QuadShape` 仅 EdgeOverlayView 消费（CropCanvas 用独立的 `CanvasQuadShape`）、测试零引用；单点语义变更覆盖 FR-001~004 全部症状；「视图铺满 overlay 时局部坐标即屏幕坐标」是本文件 CornerBracketsShape 已确立的既有约定，统一而非分叉。
- **Alternatives considered**: ① 调用点将屏幕点 ÷ viewSize 转回归一化——4 处重复转换、未来调用易再错；② OverlaySpaceMap 增加屏幕→归一化逆映射 API——扩大 Domain API 面，收益相同。

### D2: 锁定确认窗 = 帧计数 + 可注入阈值（CaptureViewModel 私有状态）

- **Decision**: `CaptureViewModel` 新增私有 `lockedFrameCount: Int` 与 init 注入参数 `autoCaptureHoldFrames: Int = 6`（≈0.4s@15fps，带默认值不破坏既有调用点）。`.locked` 分支：锁定周期首帧计数清零，此后**仅非可疑锁定帧**计数 +1；计数达阈值且 `preferences.autoCapture && !didAutoCaptureThisLock && !suspicious` 才 `await capture()`。searching / tracking / `capture()` 复位段 / `setMode()` 全部将计数清零。
- **Rationale**: 帧计数与 `QuadSmoother.frameDt` 机制同构——确定性、免注入时钟即可穷举测试；「非可疑帧才计数」保证**任何自动快门前必有完整的可见确认窗**（可疑清除且仍锁定的边界场景下不会出现「无窗即拍」）；快门节奏属 ViewModel 策略层职责，不污染 QuadSmoother 的轨迹平滑职责（FR-008）。
- **Alternatives considered**: ① ContinuousClock 墙钟计时——测试需注入时钟，复杂度不值；② QuadSmoother 内实现确认窗——把快门策略塞进轨迹平滑器，职责错位；③ suspicious 帧也计数——suspicious 持续后一旦清除会无窗即拍，违背 US2 目标。
- **语义备注**: 计数在 suspicious 锁定帧冻结（不增不清零）——可疑状态提示用户后退，后退引起 quad 变化解锁后重锁，计数自然重新开始；该边界在测试用例中钉死。

### D3: 测试锚点——坐标契约 + 确认窗行为 + 基线只增不减

- **Decision**: 新建 `ZhixiaTests/EdgeOverlayRenderingTests.swift`：QuadShape 屏幕点契约（path 包围盒 == 输入 quad 包围盒、与 rect 尺寸无关、顶点顺序保持 TL→TR→BR→BL）；扩展 `CaptureViewModelTests`：确认窗 4 用例（阈值前不拍/达阈值拍、窗内解锁取消且重锁重计、suspicious 帧不计入、手动快门窗内即时可用）。驱动方式沿用既有 fake camera/detector 帧序列模式（锁定需 ~9 稳定帧 + 窗口 6 帧，每用例 ~15-20 帧）。
- **Rationale**: 回归存活两个周期的根因之一是无测试锚点——坐标契约一旦钉死，未来任何「归一化/屏幕点」混用会在单测层爆炸；确认窗语义（含 suspicious 边界）必须穷举，防止节奏行为再次漂移。
- **Alternatives considered**: 快照测试（ViewInspector 等）——引入新依赖且脆弱，契约用 path 数值断言更精准。

### D4: idCard 描边与压暗挖孔的修复归属

- **Decision**: idCard 检测框描边（EdgeOverlayView idCard 分支）与压暗挖孔（reverseMask）由 D1 同一 Shape 语义修复覆盖，不单独立项；单测锚定 QuadShape 契约即覆盖三者，真机验收覆盖视觉确认。
- **Rationale**: 三处症状同一根因、同一修复点；拆分会造成重复验证。
- **Alternatives considered**: 逐调用点分别修复+分别测试——同一语义变更拆三次，纯增工作量。

### D5: 真机验收协议与文档更新

- **Decision**: 新建 `spec/overlay-frame-visibility/device-acceptance.md`：以 live-edge-crop 清单为基线重验 SC-001~005（更新 US1/US2 相关预期：整框可见、确认窗节奏、折页中止），**SC-005 日志必须测试期间实时抓取**（Console.app 过滤 `subsystem:com.david.Zhixia category:capture` + Include Debug Messages，流程引用 live-edge-crop §0）；`docs/09-project-handbook.md` 若记载 overlay 坐标约定则同步更新为屏幕点契约。
- **Rationale**: 上轮验收 debug 级日志因无实时监听而失证；协议先行避免重蹈。文档同步是契约变更的必要沉淀（坐标约定跨 scan-fidelity/live-edge-crop 两个周期无人发现，正是因为契约未成文）。
- **Alternatives considered**: relaxedLiveProbe 升 info 级方便事后取证——改变既有观测契约、超出本周期范围（spec Assumptions 已排除）。

### D6: 零改动保证与回归防线

- **Decision**: QuadSmoother、DetectionStrategy、VisionEdgeDetector（含三级链）、OverlaySpaceMap、FOVLayout、快门回退链 `detected ?? imageQuad ?? .fullImage` 零源码改动；对应既有测试（EdgeDetectionStrategyTests / DocumentFrameStyleTests / CaptureFallbackChainTests / OverlaySpaceMap 相关 / autoRefineSkipsUserAdjustedQuad）断言零修改，全量回归只增不减。
- **Rationale**: FR-008/FR-009 的落地保证；本周期是渲染消费端与快门节奏修复，检测与映射数学已由真机括号位置佐证正确。
- **Alternatives considered**: 无——零改动本身就是决策。

## Data Model

**CaptureViewModel 状态扩展（唯一数据模型变更）**：

- `private var lockedFrameCount: Int`——当前锁定周期的非可疑锁定帧累计；进入 searching/tracking、capture() 复位段、setMode() 时清零；suspicious 锁定帧冻结；达阈值触发自动快门（与 didAutoCaptureThisLock 协同保证单周期单拍）。
- `autoCaptureHoldFrames: Int`（init 注入，默认 6）——确认窗阈值；测试注入小值/默认值穷举边界。

**状态转换**：

```text
searching/tracking ──锁定首帧──► lockedFrameCount = 0
locked(非可疑) ──每帧──► count += 1 ──count ≥ holdFrames──► 自动快门（单周期一次）
locked(可疑)   ──每帧──► count 冻结（不增不清零）
任意 locked ──解锁──► count = 0（重锁重新计时）
手动 capture() / setMode() ──► count = 0
```

**QuadShape 契约（语义变更，非结构变更）**：

- 输入：屏幕点空间四边形（`OverlaySpaceMap.screenQuad` 产物，视图铺满 overlay 区域时即局部坐标）
- 输出：`path(in:)` 忽略 rect，四顶点按 TL→TR→BR→BL 闭合连线，输出点恒等于输入点

## Contracts & Interfaces

- **CaptureViewModel.init** 新增带默认值参数 `autoCaptureHoldFrames: Int = 6`——既有调用点（AppEnvironment 装配、PreviewSupport、既有测试）零破坏；ViewModel 不在 ServiceProtocols 内，无协议签名影响。
- **QuadShape** 公开契约变更为屏幕点语义（doc comment 载明）；无新 API、无调用方迁移（唯一消费方 EdgeOverlayView 的调用即正确形态）。
- **ServiceProtocols 零变化**；`EdgeOverlayView` 对外参数（imageQuad/geometry/diagnosticProbe/isLocked/mode）零变化。
- 对外可见行为契约变化仅两处：① 取景整框/压暗从「不可见」变为「可见且贴合」（修复）；② 自动快门从「锁定即拍」变为「锁定后约 0.4s 确认窗再拍」（需求）。
