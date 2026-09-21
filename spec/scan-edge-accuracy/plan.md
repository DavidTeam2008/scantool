# Implementation Plan: 扫描框边与成片裁剪精度修复（Scan Edge Accuracy）

**Input**: Feature specification from `spec/scan-edge-accuracy/spec.md`

## Summary

修复「扫书时虚线框比书小、成片比书小」：以**照片视野空间为唯一权威坐标空间**重构扫描链路的坐标体系；重写检测候选策略（面积分级兜底 + 内部矩形降权 + live 文档分割）；新增边缘吸附（still 路径、受限搜索、失败回退）与可疑锁定防误拍；修复整理页拖角轮廓坐标系错位。技术路线全部基于 Apple 端侧框架（AVFoundation / Vision / CoreImage），运行时测量各空间宽高比而非硬编码假设，并补齐诊断日志与单元测试回归网。

## Technical Context

**Language/Version**: Swift 6（Xcode 26.4.1，位于 `/Volumes/DevDisk/Applications/Xcode.app`，命令行需 `DEVELOPER_DIR` 指向该路径）
**Primary Dependencies**: AVFoundation（相机/预览/照片）、Vision（矩形检测/文档分割/轮廓）、CoreImage（透视矫正/像素采样）、SwiftUI（取景与整理 UI）
**State Management**: 沿用项目现状 @Observable（增量工作，不迁移）
**Storage**: 无新增持久化；`Quad`/`PageDraft` 序列化语义保持向后兼容
**Testing**: swift-testing（`@Test`/`#expect`）；构建必须加 `OTHER_SWIFT_FLAGS="-disable-sandbox"`；模拟器 iPhone 17 Pro 可用
**Target Platform**: iOS 18+，仅 iPhone 竖屏；真机 = 用户 iPhone（.photo 预设，4:3 照片），模拟器视频流已知为 16:9（代码注释 720×405 为实测证据）
**Project Type**: 既有 iOS App 增量修复（Zhixia，90 Swift 文件 / 132 测试）
**Performance Goals**: 实时检测维持现有帧率表现（检测在 actor 内、忙时丢帧的既有机制不变）；still 路径新增的文档分割与边缘吸附总耗时 ≤ 500ms（快门后异步执行，用户无感）
**Constraints**: 离线承诺（不引入云/第三方模型）；架构铁律（Feature 不碰 AVFoundation/CIFilter；Domain 无 I/O——像素读取沿用 `InkFigureDetector` 先例）；现有 132 测试不得变红
**Scale/Scope**: 改动约 12 个文件（4 新增纯逻辑文件 + 8 个修改），新增 5~6 个测试文件

## Project Structure

### Documentation (this feature)

```text
spec/scan-edge-accuracy/
├── spec.md              # 需求规格（已评审通过）
├── plan.md              # 本文件
└── tasks.md             # Phase 3 产出
```

### Source Code (repository root)

```text
Zhixia/
├── Domain/                          # 纯逻辑层（无 I/O，像素读取循 InkFigureDetector 先例）
│   ├── FOVLayout.swift              # [新增] 视频↔照片视野中心裁切换算（纯几何，可逆）
│   ├── EdgeSnapper.swift            # [新增] 检出框四边向外梯度搜索吸附（读像素，受限位移，校验回退）
│   ├── CaptureGeometry.swift        # [新增] 运行时测得的各空间宽高比（视频/照片）
│   └── Models/Quad.swift            # [修改] 新增：触边/近满幅可疑判定、候选包含度计算（纯扩展）
├── Services/
│   ├── Vision/VisionEdgeDetector.swift   # [修改] 候选面积分级兜底；包含关系降权；live 跑文档分割；still 路径集成边缘吸附
│   ├── Vision/FrameMapper.swift          # [保留] 作为 overlay 映射的回退路径（现测试不破坏）
│   ├── Vision/QuadSmoother.swift         # [保留不动] 时序平滑职责不变
│   ├── Camera/AVCameraSession.swift      # [修改] 暴露运行时测量的 CaptureGeometry；预览层探针支持
│   ├── Camera/CameraPreviewBinder.swift  # [修改] 持有预览层引用，提供「照片空间→屏幕」实测映射
│   └── ServiceProtocols.swift            # [修改] CameraCapturing 增加几何查询；CameraPreviewAttaching 增加 overlay 映射探针
├── Features/
│   ├── Capture/CaptureViewModel.swift    # [修改] imageQuad 改存照片空间；快门 fallback 直接可用；可疑锁定门禁自动快门
│   ├── Capture/CaptureView.swift         # [修改] 可疑锁定提示文案（新增 xcstrings 条目）
│   ├── Capture/EdgeOverlayView.swift     # [修改] 映射改为注入式：探针优先、FrameMapper 回退
│   └── Edit/CropCanvas.swift             # [修改] 四边形轮廓绘制收进图像实际显示区（与手柄/裁剪一致）
└── Localizable.xcstrings                 # [修改] 新增提示条目（不留空条目）

ZhixiaTests/
├── FOVLayoutTests.swift             # [新增] 16:9↔4:3 换算数值、恒等、可逆、极端宽高比
├── EdgeSnapperTests.swift           # [新增] 合成图像吸附恢复边缘；无梯度回退；位移/凸性/边界校验
├── EdgeDetectionStrategyTests.swift # [新增] 分级兜底触发、包含降权改变择优、可疑判定
├── CaptureFallbackTests.swift       # [新增] 静态检测失败时 live 框经视野换算入库；可疑锁定不自动拍
└── QuadSmootherTests.swift          # [修改] 保留现有用例，补充 Quad 扩展的用例
```

**Structure Decision**: 遵循项目现有四层架构（App/Features/Domain/Services + DesignSystem），不引入任何新分层或目录结构。新增 3 个 Domain 纯逻辑文件（换算/吸附/几何度量）+ 1 处 Quad 扩展，符合「算法进 Domain、副作用进 Services、Feature 只认协议」的既有铁律；不创建多余的包装层。

## Complexity Tracking

（无宪法级违规需要豁免——全部改动都在既有架构边界内。）

## Research & Decisions

### D1 · 权威坐标空间 = 照片视野归一化空间（canonical space）

- **Decision**: `PageDraft.quad` 与一切成片裁剪用框，唯一权威空间为「照片视野归一化空间」（与现状的 still 检测输出一致）。live 检测结果在进入 ViewModel 状态前即换算到该空间；快门 fallback（`detected ?? imageQuad`）因此天然空间一致，不再需要事后修正。
- **Rationale**: 现状 still 检测已在照片空间（正确），出错的只有「静态失败回退 live 框」这一条注入路径（视频 16:9 vs 照片 4:3 时上下/左右各错 12.5%）。把换算收敛到检测边界处一次完成，比在每个消费点各自换算更不易错。
- **Alternatives considered**: (a) 在 ImagePipeline 裁剪时按需换算——分散、易漏；(b) 全链路改用视频空间——会破坏已保存数据的兼容语义（FR-012）。

### D2 · 视频↔照片视野换算采用「同传感器中心裁切」规则，运行时测量宽高比

- **Decision**: 新增 `FOVLayout`（纯几何）：给定视频帧与照片的竖屏宽高比，按「宽高比更小（相对更窄长）者共享长轴、短轴为中心裁切」规则做可逆换算；宽高比相等时恒等。视频/照片宽高比由 `AVCameraSession` 运行时测量（帧尺寸 / 设备 activeFormat 尺寸），快门时用 `CapturedPhoto.pixelSize` 复核。不硬编码 16:9 或 4:3 假设。
- **Rationale**: 竖屏下 16:9 视频与 4:3 照片共享纵向视野、横向为中心裁切 75%（数学推导：16:9 裁切保留传感器全宽，旋转后即竖屏全高）。规则对「真机 4:3=4:3」退化为恒等、对「模拟器 16:9 vs 4:3」给出正确换算，任何设备组合都成立。上轮「3.86× 拉伸」与本轮「框偏窄」都是空间假设破裂，测量是唯一可靠手段。
- **Alternatives considered**: (a) 预设固定 16:9/4:3 常量——设备/系统组合不可枚举；(b) 强制改 session preset 让视频=照片宽高比——.photo 预设下视频格式不可直接指定，且会影响照片质量。

### D3 · overlay 映射：预览层实测探针优先，FrameMapper 回退

- **Decision**: `CameraPreviewBinder` 持有预览层引用，新增「照片空间四边形 → 屏幕坐标」的实测映射（基于预览层自带的坐标转换 API 对全幅矩形探针标定，推导逐轴缩放与偏移）；`EdgeOverlayView` 接受注入的映射闭包，探针不可用时回退 `FrameMapper`（以照片宽高比做 aspect-fill）。
- **Rationale**: 预览层实际显示的视野是 overlay 对齐的真值来源；探针让映射不依赖「预览格式 == 视频格式」这一设备相关假设（FR-006）。回退路径保证无预览层（单测、极端时序）时行为确定。
- **Alternatives considered**: (a) 维持现状（视频帧宽高比 aspect-fill）——在预览与视频格式不一致的设备上系统性偏窄；(b) 只加日志不修正——不满足 FR-006 的 MUST。

### D4 · 候选面积上限分级兜底（而非直接放宽阈值）

- **Decision**: `VisionEdgeDetector` 候选过滤分两级：第一级维持现状上限 0.96；结果为空时第二级放宽到 1.0（允许贴边/近满幅）再选。两级择优规则一致。
- **Rationale**: 0.96 上限的原始目的是过滤「整幅误检」（如屏幕截图的全帧矩形），盲目放宽会放大该误检；分级兜底只在「没有任何其他候选」时才放行近满幅候选——恰好对应「近拍书占满画面」的场景（FR-002）。
- **Alternatives considered**: (a) 直接放宽到 1.0——截图类输入退化；(b) 阈值改可配置——过度设计，无用户可感知差异。

### D5 · 内部矩形降权（而非重写评分公式）

- **Decision**: 择优仍用现有 `score = 面积 × 居中 × 方正`，但在评分前对「被另一候选高度包含（包含度 ≥ 0.9）」的候选乘降权系数（约 0.35），使外框候选在同一候选集内必胜。
- **Rationale**: 症状二（封面设计框/文字块反超真外框）的根因是包含关系未被建模，而不是评分维度缺失。降权保持评分函数纯净（`Quad.score` 不动），规则独立可测；外框缺失时内部矩形仍可胜出（配合 D4 兜底）。
- **Alternatives considered**: (a) 面积权重平方化——影响所有场景包括证件窗匹配，回归面大；(b) 一律取最大面积——丢失「居中/方正」对误检的抑制。

### D6 · live 路径条件性启用文档分割

- **Decision**: live 帧先跑矩形检测；仅当矩形检测无可信候选（无非退化、面积达标的候选）时，对该帧补跑 `VNDetectDocumentSegmentationRequest`，结果并入候选择优。still 路径维持现状（两者都跑）并集成边缘吸附。
- **Rationale**: 文档分割是神经网络请求，逐帧必跑在部分设备上会压帧率；矩形检测「找不到」恰是书类目标（圆角/低对比度）的失效信号，条件触发把算力花在需要的帧上（FR-004）。检测器 actor 已有忙时丢帧机制，风险可控。
- **Alternatives considered**: (a) live 逐帧必跑分割——帧率风险；(b) live 完全不跑（现状）——书的实时检出率无法提升，P2 故事不成立。

### D7 · 边缘吸附：仅 still 路径、受限搜索、校验失败即回退

- **Decision**: 新增 `EdgeSnapper`（Domain，读像素循 `InkFigureDetector` 先例）：对四条边沿外法线方向在受限距离（画面短边 3~5%）内采样亮度梯度，取最强梯度处外扩；结果必须通过凸性、图像边界、最大位移、面积变化四项校验，任一不过即返回原框。集成点：`VisionEdgeDetector` 的 still 路径（快门后检测与整理页 refine 都经此路径，成片天然受益）。live 路径不吸附（逐帧成本与抖动风险，收益仅装饰性）。证件模式跳过（比例窗是产品定义的取景约束）。
- **Rationale**: 成片边缘误差（SC-002）由 still 路径决定，吸附作用在源头一处即覆盖快门与 refine 两个消费点；受限搜索 + 校验回退保证「尽力而为、绝不引入新误差」（FR-010 / 假设条款）。
- **Alternatives considered**: (a) 用 `VNDetectContoursRequest` 做轮廓贴合——对复杂背景（桌面纹理）易吸到错误边缘，且计算更重；(b) live 也吸附——每帧梯度搜索成本高且平滑器会被外扩抖动干扰。

### D8 · 可疑锁定门禁放在 ViewModel 层（不动 QuadSmoother）

- **Decision**: `QuadSmoother` 职责保持纯时序平滑；「可疑」判定为 Quad 上的纯函数（任一边距图像边缘 < 1.5% 或面积 ≥ 0.95），由 `CaptureViewModel` 在收到 `.locked` 时求值：可疑 → 不触发自动快门 + 提示文案；正常 → 行为与现状一致。
- **Rationale**: 平滑器现有时序语义（锁定/失锁/面积跳变）已被单测钉死，混入业务门禁会破坏纯度与既有测试；门禁本质是「自动快门策略」而非「检测时序」，归 ViewModel 合适（FR-008）。
- **Alternatives considered**: (a) 在 QuadTrackState 增加可疑态——状态机扩散、四态枚举污染所有消费方；(b) 直接改 autoCapture 默认值为关——用户已确认保持默认开。

### D9 · CropCanvas 轮廓收进图像实际显示区

- **Decision**: 拖角模式中，四边形轮廓路径改在「aspect-fit 后的图像显示矩形」内绘制（与拖角手柄同一坐标系），消除全画布坐标错位（FR-009）。映射逻辑抽为纯函数并入现有文件，单测覆盖「图像宽高比 ≠ 画布宽高比」用例。
- **Rationale**: 最小改动消除「所见非所得」；不引入新文件。
- **Alternatives considered**: 让手柄也用全画布坐标——会破坏「quad 是图像归一化空间」的语义，影响成片裁剪正确性。

### D10 · 诊断日志（FR-007）

- **Decision**: 取景启动与快门时经 `ZhixiaLog.capture` 输出：视频帧宽高比、照片宽高比、预览探针映射参数、候选两级触发情况、选中候选面积、可疑判定结果。仅调试日志，不改产品行为。
- **Rationale**: 真机现场排障（SC 验收）依赖这些数值；上两轮问题的定位成本主要耗在猜测设备行为上。

## Data Model

- **CaptureGeometry**（新增，`Domain/CaptureGeometry.swift`）：不可变值类型。字段：视频帧竖屏宽高比、照片竖屏宽高比。来源：运行时测量（帧尺寸 / activeFormat 尺寸），快门时以 `CapturedPhoto.pixelSize` 复核并记录差异日志。相等性可比较、Sendable。
- **Quad 扩展**（`Domain/Models/Quad.swift` 内新增，不改既有成员）：
  - 可疑判定：给定边距阈值与面积阈值，判定「触边/近满幅」——纯函数，供自动快门门禁。
  - 包含度：两 Quad 包围盒交集面积 / 自身包围盒面积——纯函数，供候选降权。
- **FOVLayout**（新增，`Domain/FOVLayout.swift`）：无状态枚举 + 静态方法。职责：两个竖屏归一化空间间的可逆四边形换算（中心裁切规则，D2）。恒等情形零成本。
- **EdgeSnapper**（新增，`Domain/EdgeSnapper.swift`）：不可变配置（最大位移比例、采样步数、校验阈值）+ 单一入口方法：输入 Quad 与 CGImage，输出吸附后 Quad（或原样返回）。纯计算、无外部状态。
- **QuadSpaceTransform**（overlay 探针产物，轻量值类型，随协议定义）：照片空间 → 屏幕空间的逐轴线性映射（每轴缩放 + 偏移），由预览层探针标定；可逆性不要求（overlay 单向）。
- **既有模型不变**：`Quad`（持久化语义 = 照片空间归一化，FR-012）、`PageDraft`、`CapturedPhoto`、`QuadTrackState`。

## Contracts & Interfaces

> 签名按接口契约记录；不含实现逻辑。

### 协议变更（`Services/ServiceProtocols.swift`）

| 协议 | 变更 | 契约 |
|---|---|---|
| `CameraCapturing` | 新增几何查询 | `func geometry() async -> CaptureGeometry`：返回运行时测量的视频/照片宽高比；未配置时返回退火默认值（1:1 组合，恒等换算） |
| `CameraPreviewAttaching` | 新增 overlay 映射探针 | `func overlayTransform(forViewSize: CGSize) -> QuadSpaceTransform?`：预览层有效时返回「照片空间→该视图尺寸屏幕坐标」的实测映射；无有效预览层时返回 nil（调用方走 FrameMapper 回退） |
| `EdgeDetecting` | 签名不变，行为契约更新 | live 帧（`detect(frame:)`）输出为**视频帧空间**归一化 Quad（由调用方立即换算到照片空间）；静态图（`detect(imageData:)`）输出为**照片空间**归一化 Quad，且**已含边缘吸附**（证件窗匹配时跳过吸附）。候选策略：两级面积兜底 + 包含降权 + 条件性文档分割 |
| 其余协议 | 不变 | — |

### 模块接口（新增文件）

| 模块 | 入口契约 |
|---|---|
| `FOVLayout` | `convert(quad:fromAspect:toAspect:) -> Quad` 与逆运算；宽高比相等时恒等；输入非法（≤0）时原样返回 |
| `EdgeSnapper` | `snap(quad:image:maxShiftRatio:) -> Quad`；四项校验（凸性/边界/最大位移/面积变化）任一失败返回原 quad |
| `Quad` 扩展 | `isSuspiciousForAutoCapture(edgeMargin:maxArea:) -> Bool`；`containment(in:) -> Double` |
| `CaptureGeometry` | 纯值类型；两宽高比字段；构造自测量值 |

### UI 契约

- `EdgeOverlayView`：新增可选注入映射（照片空间 Quad + 视图尺寸 → 屏幕 Quad）；nil 时回退 FrameMapper（照片宽高比做 aspect-fill）。绘制逻辑本身不变。
- `CaptureView` 提示文案：新增「可疑锁定」条目（xcstrings 完整填写，不留空条目）；既有「搜索中/已锁定」文案不变。
- `CropCanvas`：轮廓与手柄同坐标系（aspect-fit 图像矩形）；对外接口（image + quad Binding）不变。

### 诊断契约

- `ZhixiaLog.capture` 新增结构化条目：`geometry(video:photo:)`、`overlayProbe(...)`、`detectionTier(...)`、`suspiciousLock(...)`。仅日志，无行为分支依赖。

### 测试契约（新增测试文件）

| 文件 | 覆盖 |
|---|---|
| `FOVLayoutTests` | 16:9→4:3 数值断言（横向中心 75% 跨度）、恒等、往返可逆、极端/非法宽高比 |
| `EdgeSnapperTests` | 合成亮块图内缩框吸附恢复；同色无梯度回退；位移越界回退；非凸结果回退 |
| `EdgeDetectionStrategyTests` | 一级为空触发二级；包含降权改变择优结果；可疑判定矩阵 |
| `CaptureFallbackTests` | 静态检测失败 → live 框经 FOVLayout 换算后入库（照片空间断言）；可疑锁定不触发自动快门（fake 时钟/偏好） |
| `QuadSmootherTests`（扩展） | Quad 新扩展用例；既有 3 用例不改动 |

### 构建与验证命令（本机）

```bash
export DEVELOPER_DIR=/Volumes/DevDisk/Applications/Xcode.app/Contents/Developer
OTHER_SWIFT_FLAGS="-disable-sandbox" xcodebuild test \
  -project Zhixia.xcodeproj -scheme Zhixia \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -skipPackagePluginValidation -skipMacroValidation
```

（模拟器偶发 Busy：`xcrun simctl erase all` 后重跑。`withKnownIssue` 命中显示为 recorded an expected failure，勿按 passed 检索。）
