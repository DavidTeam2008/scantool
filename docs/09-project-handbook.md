# 纸匣 Zhixia · 项目接手手册

> 面向**刚接手的同事**：读完这一篇，你应该能说清这个项目做什么、怎么搭的、为什么这么选、
> 现在做到哪、卡在哪、下一步往哪走。
> 需要下钻时，每节都给了对应代码路径和专题文档。
>
> 最后更新：2026-10-21 · 对应代码 108 个 Swift 文件（主工程）/ 约 14.5k 行 / 全量 436 用例 = 396 passed + 1 expected failure + 0 failed · 当前最大卡点：取景主场景仍缺“我要拍右页”的意图（见 [15](15-capture-recovery-assessment.md) 与 `spec/guided-capture/`）；frame-truth / Case B 修复已交付、真机验收待做（[12 §2.1/§2.2](12-handover.md)）。新同事第一读请先看 [12 交接文档](12-handover.md)，AI agent 从 [AGENTS.md](../AGENTS.md) 进入

---

## 0. 速览

**一句话**：把纸上的东西，干净地收进这台 iPhone。对标全能扫描王的**主体能力**，不做广告、不做账号墙。

**核心流程**：对着纸 → 自动框边 → 快门 → 透视拉正 + 增强 → 连续多页 → 入库 → OCR / 版面还原 → 导出 PDF / Word。

**现状一句话**：**扫描主链路（拍、框、拉正、增强、OCR、导出图片 PDF）已经可用**；
**「版面还原 → 导出 Word」在 iOS 26 上已经打通**（`RecognizeDocumentsRequest` 直接给表格行列结构，
实测样张读出 7 行 × 3 列），**默认导出已翻转为流式档**（对标 WPS，含丢字哨兵与通路可观测，§4.5/§6.12）；
**取景 WYSIWYG 的 Case A/B 根因已定案、修复已交付**（case-b-sticky-v2 +
folded-page-capture + frame-truth，当前总基线 436 全绿；真机验收仍待做，主清单
`spec/frame-truth/device-acceptance.md`，§6.13；2026-10-21 复核后新增引导框主线
`spec/guided-capture/`，见 §7）；**iOS 18~25 仍走几何兜底、
真机依旧出不了表**；iOS 26 结构化通路真机接通性未验证（L1 疑案，§6.12 已知限制 ③）——见 §6。

### 仓库地图

```
scantool/
├── AGENTS.md                AI coding agent 冷启动入口（定位 / 铁律 / 命令速查）
├── Makefile                 构建/测试命令固化（test / test-only / smoke / device-build / doctor）
├── Zhixia/                  主工程（108 个 .swift）
│   ├── App/                 入口、DI 容器（AppEnvironment）、路由
│   ├── Features/            按页面拆：Capture / Edit / Document / Reconstruct / Library / OCR / Settings …
│   ├── Domain/              纯逻辑：几何、模型、版面分析、表格、配图、阅读序
│   ├── Services/            副作用：Camera / Image / Vision / OCR / Persistence / Reconstruct / PDF
│   └── DesignSystem/        Tokens + 复用组件
├── ZhixiaTests/             44 个测试文件 / 436 个 @Test（含端到端断言 + 真实双栏样张 + 金标准语法页）
├── docs/                    本文 + 专题文档（00~15；12 为交接文档单入口）
├── spec/                    SDD 周期工件（14 个周期，每周期 spec/plan/tasks/device-acceptance 四件套）
├── Tools/
│   ├── ocr-dump/            从样张图导出 OCR 夹具
│   └── pdf-ocr-dump/        **从导出的 PDF 反解真机 OCR**（排障利器，见 §8.3）
├── docs/fixtures/           样张 + OCR 夹具 + 金标准语法页（grammar-worksheet + 42 段阅读流）
└── prototype/index.html     可交互界面原型
```

---

## 1. 产品与原型设计

### 1.1 定位与对标

| | 纸匣 | 全能扫描王 / WPS 拍照扫描 |
|---|---|---|
| 定位 | 干净的离线扫描工具 | 扫描 + 云 OCR + 文档处理平台 |
| 账号 | 无 | 强账号体系 |
| OCR | Apple Vision（端侧） | 自研/定制 + 云 |
| 版面还原 | iOS 26 用系统结构化识别；老系统几何启发式 | 云 + 深度学习版面模型 |
| 广告 | 无 | 有 |

### 1.2 产品承诺（写死的设计约束）

1. **操作简单** —— 主路径「对着纸 → 快门 → 完成 → 保存」。
2. **界面好看** —— 纸色画布 + 朱砂主操作（`DesignSystem/Tokens.swift`）。
3. **架构干净** —— Feature 不碰 `AVCaptureSession` / `CIFilter`；图像处理进 actor；元数据与文件分离。
4. **双通路文字** —— 详情「文本」= 本机 OCR 纯文本；「还原」= 版面 IR → Word / 可检索 PDF。

### 1.3 信息架构

```
RootView
├── LibraryView          文档库：文件夹 / 搜索 / 收藏 / 新建
│   └── DocumentView     文档详情（页缩略胶片）
│       ├── 文本   → OCRView         纯文本 OCR 结果
│       ├── 还原   → ReconstructView 版面还原 + 流式（默认）/高保真 档位 + 导出
│       ├── 分享   → ExportSheet     PDF 导出 / 系统分享
│       └── 加页   → CaptureView
├── CaptureView          取景 + 实时框 + 连拍
├── ReviewView           整理：拖角 / 五档滤镜 / 保存入库
└── SettingsSheet        偏好（保留原图等）
```

### 1.4 视觉语言

- 纸色底 `Tokens.paper`，墨色字 `Tokens.ink`，朱砂主操作 `Tokens.seal`。
- 圆角统一 `RoundedRectangle(cornerRadius:, style: .continuous)`。
- 组件集中在 `DesignSystem/Components/`：`DocumentCard` / `PageFilmstrip` / `FilterStrip` / `ScanButton`。

### 1.5 原型

- 交互原型：`prototype/index.html`（浏览器直接打开）
- 还原功能 R2 方案的界面线框：`docs/reconstruct-r2-preview.html`（8 屏 iPhone 稿）
- 产品专题文档：`docs/01-product-prototype.md`

---

## 2. 架构设计

### 2.1 分层

```
┌─────────────────────────────────────────────┐
│ App          ZhixiaApp / RootView / AppRoute │  组装 + 导航
├─────────────────────────────────────────────┤
│ Features     Capture Edit Document           │  SwiftUI View + @Observable VM
│              Reconstruct Library OCR …       │  **不直接碰 AVFoundation / CIFilter**
├─────────────────────────────────────────────┤
│ Domain       纯 Swift / CoreGraphics         │  几何、IR、版面分析、算法
│              无 I/O、无 UI、易测             │
├─────────────────────────────────────────────┤
│ Services     Camera Image Vision OCR         │  actor 隔离副作用
│              Persistence Reconstruct PDF     │
└─────────────────────────────────────────────┘
         DesignSystem（Tokens / 组件，横切）
```

**铁律**：依赖只能向下。Domain **不 import** Services / SwiftUI。

### 2.2 依赖注入

`App/AppEnvironment.swift` 是唯一的组装点，所有依赖以协议注入，VM 只认协议不认实现：

```swift
AppEnvironment(
    detector:  any EdgeDetecting        = VisionEdgeDetector(),
    pipeline:  ImagePipeline            = ImagePipeline(),
    recognizer:any TextRecognizing      = VisionTextRecognizer(),
    parser:    any DocumentParsing      = CompositeDocumentParser(onDevice: …),
    docx:      any DocxRendering        = DocxExportService(),
    searchablePDF: any SearchablePDFRendering = SearchablePDFExportService(),
    …
)
```

好处：单测可塞 Fake（`ZhixiaTests` 里的 `FakePagePaths` / `PreviewRecognizer` 就是这么用的）。

### 2.3 协议清单（`Services/ServiceProtocols.swift`）

| 协议 | 实现 | 职责 |
|---|---|---|
| `CameraCapturing` | `AVCameraSession` | 取景 / 拍照 / 闪光灯 / 帧流 |
| `CameraPreviewAttaching` | `CameraPreviewBinder` | 把预览层挂到 UIView |
| `EdgeDetecting` | `VisionEdgeDetector` | 文档边缘检测（矩形 + 文档分割） |
| `PerspectiveCorrecting` / `Enhancing` / `Thumbnailing` / `ImageRendering` | `ImagePipeline` | 拉正 / 增强 / 缩略图 / 渲染页 |
| `TextRecognizing` | `VisionTextRecognizer` | OCR（含预处理档重跑） |
| `OCRImagePreparing` | `OCRPreprocessor` | OCR 专用预处理（去阴影 / 灰度 / 锐化） |
| `DocumentStructureRecognizing` | `VisionDocumentStructureRecognizer` | iOS 26 结构化识别（表格行列结构） |
| `BarcodeDetecting` | `VisionBarcodeDetector` | 条码（⚠️ 模拟器恒为空） |
| `DocumentParsing` | `CompositeDocumentParser` → `OnDeviceDocumentParser` / `TextInDocumentParser` | 版面还原 |
| `DocxRendering` | `DocxExportService` | Word 导出（三档） |
| `SearchablePDFRendering` | `SearchablePDFExportService` | 可检索 PDF |
| `PDFRendering` | `PDFExportService` | 纯图片 PDF |
| `DocumentStore` | `SwiftDataDocumentStore`（失败降级 `InMemoryDocumentStore`） | 元数据 |
| `PageFileStoring` | `PageFileStore` | 图片文件 |
| `PermissionGranting` | `PermissionService` | 相机权限 |

### 2.4 两条主数据流

**A. 扫描链路**（已稳定；2026-09 边框精度重构后）

```
AVCaptureSession 帧流
  → VisionEdgeDetector（VNDetectRectangles；live 无可信候选时条件补跑 VNDetectDocumentSegmentation）
  → DetectionStrategy 统一择优（两级面积兜底 + 包含降权，见 §4.2）
  → CaptureViewModel 摄入边界：FOVLayout 把视频空间 quad 换算到「照片空间」（§4.2 权威空间）
  → QuadSmoother 平滑（照片空间）→ EdgeOverlayView 实时框（OverlaySpaceMap 解析映射 → 屏幕点 Shape，见 §4.2）
  → 可疑锁定门禁（近满幅/贴边不下自动快门，只提示后退）
  → 快门 → CapturedPhoto → still 检测（同上择优）→ EdgeSnapper 贴边吸附（内缩 1~3% 恢复）
  → PageFileStore.writeOriginal（暂存会话目录）
  → ReviewView 拖角校正（aspect-fit 同坐标系）/ 选滤镜
  → ImagePipeline.renderPage（透视拉正 + 增强 + 缩略图）
  → PageFileStore.commit → SwiftData 写元数据
```

**B. 还原链路**（详见 §4.4）

```
页面图（rendered 优先）
  ├─ iOS 26：VisionDocumentStructureRecognizer（RecognizeDocumentsRequest）
  │    → 直接拿 lines / tables（行列结构）/ barcodes
  └─ 回退：VisionTextRecognizer → OCRPageText [(text, bbox)]
            + TableGridV2Detector（锚点驱动；v1 聚类器已退役——几何通路不再产表，§6.12）
  两条通路都归一成 StructuredDocumentPage，下游完全共用 ↓
  → PageBarcodeDetector  → 条码框（与结构化结果**取并集**）
  → ReconstructSceneRouter.route → scene (plain/exam/table/packaging)
  → OCRNoiseFilter       → 丢状态栏 / UI chrome，URL 降级
  → OnDeviceReadingOrder  → 段落块流
  → FigureRegionsV2       → 配图 / 条码裁切
  → [ReconstructPage] → ReconstructDocument
  → DocxExportService（流式默认 / 高保真可选）或 SearchablePDFExportService
```

> **两条通路的接缝就是 `StructuredDocumentPage`**（Services/Reconstruct/）。
> 加通路时只要产出这个类型，下游（噪声过滤 / 阅读序 / 配图 / 块排序 / 导出）一行都不用改。

### 2.5 专题文档

- `docs/02-architecture.md` —— 分层 / 模块 / 数据流 / 工程结构
- 图：`docs/diagrams/layers.svg` · `pipeline.svg` · `modules.svg`

---

## 3. 技术选型

| 领域 | 选型 | 为什么 | 代价 |
|---|---|---|---|
| UI | **SwiftUI** | 声明式、与 Observation 配合好 | 复杂手势/相机预览仍需 `UIViewRepresentable` |
| 状态 | **@Observable**（非 `ObservableObject`） | Swift 5.9+ 更细粒度、更少重绘 | iOS 17+ 起步 |
| 并发 | **async/await + actor** | 图像处理/IO 隔离到 actor，主线程不卡 | 协议要标 `Sendable`，跨 actor 有摩擦 |
| 持久化 | **SwiftData**（`@Model`） | 原生、少样板 | 建容器失败会**降级到内存 store**，别以为数据丢了 |
| 相机 | **AVFoundation** 手写 | 要帧流 + 手动对焦/曝光控制 | 代码量大 |
| 边缘检测 | **Vision** `VNDetectRectanglesRequest` + `VNDetectDocumentSegmentationRequest` | 系统自带、无需模型文件 | 复杂背景漏检 |
| 透视矫正 | **Core Image** `CIFilter.perspectiveCorrection` | 系统自带 | 极端角度会拉爆 |
| OCR | **Vision** `VNRecognizeTextRequest` + 专用预处理档 | 离线、隐私、零成本 | **识别率低于专业 OCR**；几何通路上**没有 word 级 bbox** |
| 图片增强 | **Core Image** 滤镜链 | 系统自带 | 档位少 |
| 落盘 | **文件系统 + SwiftData 分离** | 大文件不进数据库 | 要做孤儿清理（`sweep`） |
| 测试 | **swift-testing**（`@Test` / `#expect`） | 比 XCTest 表达力强 | `withKnownIssue` 命中时日志是 *recorded an expected failure*，**搜 passed 找不到它** |
| **版面/表格结构** | **iOS 26 `RecognizeDocumentsRequest`**（2026-09-12 接入） | 直接返回表格行列结构，根治「真机 `w:tbl = 0`」 | 需要 iOS 26；老系统仍走几何兜底 |
| 云解析 | **TextIn**（stub 未接线） | 预留 | 当前 `parse` 直接 `throw`，没有网络实现 |

### 3.1 关键取舍记录

- **不用第三方 OCR SDK**：保持离线与隐私承诺，代价是还原质量天花板低（见 §6.4）。
- **Word 导出手拼 OOXML**（`DocxExportService` + `ZipArchive`），不引第三方库：包体小、
  可控，代价是要自己维护 `document.xml` / `rels` / `media` 的正确性，样式能力有限。
- **版面还原走纯几何启发式**，不上 Core ML 模型：先验证可行性 + 零包体成本，
  代价是泛化能力差（见 §6）。

---

## 4. 实现原理

### 4.1 三套坐标系（**最容易踩的坑**）

| 场景 | 原点 | y 轴 | 范围 |
|---|---|---|---|
| **Vision / `OCRLine.boundingBox`** | **左下** | **向上** | 归一化 0~1 |
| UIKit / SwiftUI | 左上 | 向下 | 点/像素 |
| PDF（`PDFPage.bounds` / `characterBounds`） | 左下 | 向上 | 点 |

**从 Vision 坐标画到 SwiftUI 必须翻 y**：
```swift
let y = (1 - box.maxY) * height      // 漏了这一句，整页上下颠倒
```
（`ReconstructView.LayoutCanvas` 就这么干；`NormalizedImageCrop` 裁图同理。）

### 4.2 扫描管线要点

**权威照片空间（2026-09 重构的核心约定）**：全链路的 `Quad` 一律是**照片 FOV** 的归一化
坐标（竖屏、原点左上、EXIF 校正后）。视频流检测（16:9）与照片输出（4:3）视野不同，
`CaptureViewModel` 在**摄入边界**经 `FOVLayout.convert` 一次性换算（FR-011 单点收敛），
下游 smoother / overlay / PageDraft / 裁剪全部空间一致——别在任何消费点再换算。

**候选择优（`DetectionStrategy`，VisionEdgeDetector.swift 内）**：
- 两级面积兜底：一级维持 0.96 上限（整幅误检防护）；一级为空时二级放宽 ≤1.0，
  近拍书占满画面的真实外框不再被静默丢弃（层级经 `detectionTier` 日志可读）。
- 包含降权：被另一候选高度包含（≥0.9）的内部矩形评分 ×0.35，封面设计框不再反超外框；
  互包含（近重复）不互相压分；降权不得让结果退化到更小的框（FR-003 保障）。

**live 三级检测兜底（spec/live-edge-crop，2026-09-20）**：live 链按
「严格矩形 → 条件文档分割 → 放宽矩形」三级推进——
① `VNDetectRectanglesRequest` 严格参数（置信度 0.6 / 最小尺寸 0.25 / 直角容差 20° / 候选 4）；
② 仅当①无可信候选（无非退化、面积 >0.08）时补跑 `VNDetectDocumentSegmentationRequest`
  ——圆角书/低对比度的失效信号，把神经网络算力只花在需要的帧上；
③ 仅当②也无结果时（门控纯函数 `DetectionStrategy.needsRelaxedRectangles(rectangles:segmented:)`，
  可穷举单测），以 **still 快门同源的放宽参数**（置信度 0.35 / 最小尺寸 0.08 / 直角容差 28° /
  候选上限 8——`detectRectangles(relaxed:)` 单一参数源，零新参数）再跑一次矩形检测。
折页厚书的曲面页边缘不满足矩形检测的直线假设，前两级长期落空正是该场景的失效信号——
第三级让取景器尽可能出框（用户预知裁切范围、敢按快门）。三级候选并入**同一池**经
`DetectionStrategy.select` 统一择优（两级面积兜底 / 包含降权语义不变——放宽档命中的
整幅误检同样受 0.96 上限管控）。放宽档**不做**贴边吸附（still 专属，保持 live 轻量）；
证件模式（idCard）不参与第三级，检测路径不变。
**已知限制**：曲边页「精确贴合」受矩形检测器物理上限约束——放宽档提高命中率但不保证
曲边 100% 贴合，极端场景由预览页手动调框兜底（FR-005）。

**取景整框视觉（spec/live-edge-crop）**：文档模式整框为**连续实线**（`DocumentFrameStyle`
纯数据样式，`EdgeOverlayView.swift` 内）——「dash 恒空」是类型不变量（类型不提供虚线入口）：
跟踪态 2.5pt 朱砂细实线（替换旧虚线 [8,6]）、锁定态 3pt 白面线 + 5pt 暗描边粗实线
（新增，与四角括号同风格）；四角括号、框外压暗（tracking 0.25 / locked 0.45）与
证件模式渲染路径（idMask + 专用描边）不动。

**贴边吸附（`EdgeSnapper`，Domain/）**：still 路径择优后，四边沿外法线采样亮度梯度，
把普遍内缩 1~3% 的检出框外推到真实边缘（最大位移 = 5% × 短边）；凸性/边界/位移/面积
四项校验任一失败原样返回。证件模式比例窗跳过；live 路径不动。快门检测与整理页
refine 都经 `detect(imageData:)` 单点受益。

**可疑锁定门禁**：`.locked` 且照片空间 quad 近满幅（面积 ≥0.95）或贴边（边距 <1.5%）
时，视为「书超出视场被裁切」——抑制自动快门，状态区提示「再往后移一点」（`isAutoCaptureSuppressed`）。

**自动快门确认窗（spec/overlay-frame-visibility）**：锁定后**不立即拍**——`CaptureViewModel`
继续累计连续非可疑锁定帧，默认 6 帧（≈0.4s@15fps；init 参数 `autoCaptureHoldFrames`
可注入，测试用）达阈值且 `autoCapture && !didAutoCaptureThisLock && !suspicious` 才自动快门。
语义细节：①每轮锁定首帧清零重新起算；②suspicious 帧**冻结**计数（不增也不清零，
可疑解除后从原值续算）；③清零点 = searching/tracking 转换、`capture()` 复位段、
`setMode()`；④单周期单拍（`didAutoCaptureThisLock`）与手动快门均不受窗限制
（手动拍后同样清零计数）。行为由 `CaptureViewModelTests.AutoCaptureHoldWindowTests` ×4
穷举钉死（等窗拍 / 解锁重计 / 可疑冻结 / 窗内手动拍）。

**WYSIWYG 裁切契约（spec/wysiwyg-crop）**：**屏幕呈现框 = 成片裁切基准**。文档模式
快门时刻，`CaptureViewModel.capture()` 先快照呈现框（`imageQuad`），静帧重检结果经
`CropConsistencyGate.resolve`（Domain 纯函数）仲裁：
- IoU ≥ 0.70（一致精修）→ 静帧胜：EdgeSnapper 贴边精修保留，平整文档精度不回归；
- IoU < 0.70（分歧，如折页场景静帧选整书外轮廓）→ 呈现框胜：所见即所得；
- 搜索态（无呈现框）→ 静帧自由检测照旧；呈现框与静帧双缺 → 全幅兜底。
例外路径走旧链零改动：证件模式（`detected ?? imageQuad ?? .fullImage`）与相册导入。
live 文档路径另加**候选粘滞**（`CandidateSticky`，`VisionEdgeDetector` actor 内状态）：
逐帧择优后与上次择优相似（IoU ≥ 0.60）的候选优先延续（同候选小幅漂移跟随更新，
跳变帧改选池中锚点相似候选的最高分者），连续 3 帧无相似候选（含检测间隙）逃逸清锚
——摊开书从中线取景时右页/整书双候选振荡由此止跳（先稳者胜），用户明显改变取景
仍能快速跟随切换（≈0.2s@15fps）不粘死。仲裁与改写均落日志：`cropGate`
（displayedArea/stillArea/iou/acceptedStill，文档模式每次快门一行，证件/导入无此行）
与 `stickyOverride`（粘滞改写帧）。

**overlay 映射与屏幕点契约（渲染真值 = `OverlaySpaceMap` 解析链）**：照片空间 quad 经
`OverlaySpaceMap.screenQuad`（照片→视频 `FOVLayout` 中心裁切逆换算 → 屏幕 aspectFill
解析放置）映射为**屏幕点**；旧探针（`layerRectConverted`）与 `FrameMapper` 均已退役为
诊断对照（`overlayProbeAnalytic` / `overlayProbeDelta` 日志，§6.9 #5）。
**Shape 契约**：`EdgeOverlayView` 内消费屏幕点的两个 Shape（`QuadShape` /
`CornerBracketsShape`）遵循同一约定——**输入即屏幕点，`path(in:)` 忽略 `rect` 参数、
输出点 = 输入点**，不做任何二次归一化/缩放。契约已由 `EdgeOverlayRenderingTests` 钉死
（包围盒 == 输入 quad / 与 rect 无关 / 顶点 TL→TR→BR→BL 闭合）——此前契约未成文，
`QuadShape` 旧实现把屏幕点当归一化值再乘 rect、路径放大到屏幕外，缺陷跨两个周期
无人发现（§6.10）。

**新 Domain 模块（全部纯函数）**：`CaptureGeometry`（运行时视频/照片宽高比）、
`FOVLayout`（视频↔照片空间换算）、`EdgeSnapper`（贴边吸附）；`Quad` 扩展
`isSuspiciousForAutoCapture` / `containment(in:)`。

**诊断日志（`ZhixiaLog.capture`，Console.app 按 subsystem `com.david.Zhixia` 过滤）**：
`geometry`（视频/照片宽高比，取景启动与快门各记一次）、`overlayProbeAnalytic` /
`overlayProbeDelta`（解析链渲染真值的仿射参数 + 与退役探针实测值的逐轴偏差对照，
SC-004 证据链）、`detectionTier`（候选层级）、`suspiciousLock`
（门禁抑制原因）、`relaxedLiveProbe`（live 文档模式每帧一行：`triggered` 是否触发放宽矩形
重跑（严格+分割双落空）、`candidates` 放宽档命中数——**触发率 = triggered=true 行数 ÷
本日志总行数**，与 `detectionTier`（面积兜底档位）语义正交）、`cropGate`（快门门禁：
呈现框/静帧面积、IoU 与 acceptedStill 采纳方向，文档模式每次拍摄一行，`iou=-1` 表示
无可测对）、`stickyOverride`（live 粘滞改写帧，双候选**同池**振荡止跳证据）、
`stickyHold`（v2 hold-through-miss 维持帧：miss 计数 / 锚点面积 / 被拦截择优面积——
存在性交替被吸收的直接证据，spec/case-b-sticky-v2；folded-page-capture 起调用点
missLimit 5，N 可到 4）、`stickyEscape`（粘滞达限清锚，
FR-007 不粘死证据；口径随 missLimit 5 更新为 afterMisses=5）、
`candidateProvenance`（live 每帧候选来源：strict/seg/relaxed/viable 数量与面积、
门控布尔、粘滞前择优、disposition——spec/frame-truth）、`cropQuad`（快门时
呈现框/静帧四角）、`snapEdge`（逐边 G0/两相峰/位移）、`snapOnLock`（锁定吸附
前后面积与四角；冻结直裁证据）。真机验收步骤见
`spec/scan-edge-accuracy/device-acceptance.md`、`spec/live-edge-crop/device-acceptance.md`、
`spec/wysiwyg-crop/device-acceptance.md`、`spec/case-b-sticky-v2/device-acceptance.md`
与 `spec/frame-truth/device-acceptance.md`（**下一趟真机会话主清单**：框真相四痛点
复测 + 无效框承诺 + 冻结直裁四角核对 + Case B 复测 + L1 取证合并执行）。

- `QuadSmoother` 对连续帧的四边形做平滑，避免实时框抖动（未动）。
- 证件模式（`ScanMode.idCard`）用一个固定比例窗约束检测（语义未动）。
- 五档滤镜（`Enhancement`）：`original` / `enhance` / `deskewShadow` / `grayscale` / `blackWhite`。
- **落盘三份**：`.original`（相机直出，**未矫正未增强**）、`.rendered`（拉正+增强）、`.thumbnail`。
  > ⚠️ 这三者的区别是 §6.1 那个重大 bug 的来源，务必记住。

### 4.3 OCR

`VisionTextRecognizer` 跑**两遍**再择优（`OCRTextQuality` 打分）：
```swift
(.accurate, languages, usesLanguageCorrection: false)
(.accurate, languages, usesLanguageCorrection: true)
```
- `minimumTextHeight = 0.012` —— 太小的字直接不识别（这个阈值在高分辨率图上会吃掉很多行）
- 语言：`zh-Hans` / `zh-Hant` / `en-US`
- **只有 line 级 bbox，没有 word/character 级** —— 这是表格还原做不好的**硬约束**之一（§6.3）
  这条约束**只对几何兜底成立**；iOS 26 通路不依赖它（§4.4）。

**OCR 专用预处理档 + 自动重 OCR**（2026-09-12，`Services/Image/OCRPreprocessor.swift`）：
- 「好看」与「好认」解耦。展示仍用 rendered；OCR 可以走 `CIDocumentEnhancer`（去阴影 +
  背景白化）+ 灰度 + 轻度锐化的专用档。用户选 `Enhancement.original` 时，展示照旧是原图，
  OCR 仍走这一档。
- 触发条件：这一遍质量分低于 `VisionTextRecognizer.confidentScore`（240 ≈ 30 汉字）时才重跑。
  顺带把提前退出的判据从 `cjkCount >= 12` 换成了质量分 —— 旧门槛低到「看到中文就停」，
  使这个类自己设计的两轮配置择优在中文页面上永远跑不到第二轮。

### 4.4 版面还原（R2 管线）

核心 IR（`Domain/Models/ReconstructDocument.swift`）：

```swift
ReconstructDocument { documentID, title, pages, version = 2 }
  └─ ReconstructPage { pageID, size, scene, usedCloud, blocks, layout: PageLayout?, anchors,
                       baseImageRelativePath }   // 版面还原档底座（rendered 原图路径，VM 注入）
       └─ ReconstructBlock { id, kind, bbox, text, style, table, figureRelativePath,
                             barcodePayload, isChecked, semantic, anchors, confidence }

ReconstructBlockKind = heading | paragraph | list | table | figure | barcode | artwork
                     | checkbox | handwrittenBlank   // artwork：乱码区域按原像素保留，不进文字层
ReconstructScene     = auto | plain | exam | table | packaging
```

**算法模块**（全部纯几何，不读像素）：

| 模块 | 文件 | 做法 |
|---|---|---|
| 版面分析 | `Domain/Layout/LayoutAnalyzer.swift` | 按 minY 排序 → 算 medianGap → `gapThreshold = max(medianH×1.6, medianGap×2.0, 0.012)` 切 band；遇 tableTitle 强制断带 |
| 页眉页脚 | `HeaderFooterClassifier` | 三条件 **AND**：顶部/底部 10% + 短（高 < 2.5×medianH 且行数 ≤ 4）+ 隔离（gap > 1.6×medianH） |
| 分栏 | `ColumnResolver` | 80-bin x 投影直方图找 gutter；gutter ≥ 4 bin 且 gutterRatio ≥ 6% 才算分栏 |
| 锚点 | `AnchorExtractor` | 识别 tableTitle / questionStem / optionLetter / barcode 文本 |
| 表格 | `Domain/Table/TableGridV2Detector.swift` | 找 tableTitle 锚点 → 焦点窗口 0.22 → 多尺度列聚类（0.13→0.085）→ 自适应行聚类 `clamp(0.55×medianH, 0.013, 0.025)` → x-range 过滤 → occupancy ≥ 0.30 |
| 阅读序 | `Domain/OnDeviceReadingOrder.swift` | 行级页眉剔除 → `sameRow` 阈值 0.30 + 自适应 rowThreshold → 段落聚类 → CJK-aware 标题判定 |
| 配图 | `Domain/Figure/FigureRegionsV2.swift` | 题下区域网格 flood fill 找**空白连通域** + `maxArea = 0.12` 闸门；v1 兜底（barcode 通道已删——条码改由 `.barcode` 块**单份表示**，见下） |
| 墨块 | `Domain/Figure/InkFigureDetector.swift` | 双输出：`figures` + `textCoveredInkRegions`（被文字覆盖的墨块区域，artwork 判定的证据源） |
| 乱码判定 | `Domain/Layout/GarbledRegionDetector.swift` | **双门控（AND）**：低置信（≤0.5）∧ 低质量（OCRTextQuality=0）+ 墨块重叠 ≥ 0.3 → `.artwork`；低信号行空间聚类（gap 0.02）合并；高置信/识别正确的行**永不剔除**（保守性单测钉死） |
| 条码单份 | parser 内 dedup（`FigureRegionsV2` / `OnDeviceDocumentParser`） | figure↔barcode 交叉去重（IoU>0.5 或包含）；URL 降级文本与已检条码 bbox 相交 → 并入条码说明、不另出块 |
| 坐标映射 | `Domain/Layout/PageLayoutMapper.swift` | 归一化 bbox → 画布像素 / DOCX EMU 的**唯一换算入口**（缩放+偏移+y 翻转集中于此；预览与导出共用 → 定位逐位一致） |
| 布局引擎 | `Domain/Layout/RegionLayoutEngine.swift` | 解析期四步管线：宽行拆分 → 碰撞消解（行序受让 + 重建行帧，迭代 ≤ 4 轮）→ 溢出阶梯（缩字号 → 向下空带扩块 → 保文字）→ clampToPage；产物写 `page.restoredBlocks`，装得下的块零扰动 |
| 共享排版度量 | `Domain/Layout/LayoutTypography.swift` | 实测行高 → 字号/行距的**唯一**推导处（fontPT 钳 [7,28]、溢出估算、行帧计算、表格单元格度量）；预览与 DOCX 同入口 → 「字号 / 页高」比例恒等 |
| 覆盖矩形 | `Domain/Layout/LayoutMaskBuilder.swift` | 文本/表格块 bbox 外扩 1.5% → 净化矩形，环带逐通道 **median** 采样取底色；figure/barcode/artwork 区域不进 mask |
| 噪声过滤 | `Domain/OCRNoiseFilter.swift` | 状态栏/UI chrome 丢弃；URL 降级为 barcode 块 |
| 场景路由 | `Domain/ReconstructSceneRouter.swift` | 判定顺序：**exam 优先于 grid**（否则练习册被判成表格） |

**版面还原档管线**（`.restored`，spec/layout-restore）——预览（`LayoutCanvas`）与
DOCX 导出共用 `PageLayoutMapper` 同一套几何：

- **三层预览**：底座（rendered 原图 aspect-fit，ImageIO 下采样 ≤2048px）→
  覆盖层（`LayoutMask` 净化矩形盖掉原字迹）→ 元素层（文本/表格按 bbox 原位重排；
  **字号走 `LayoutTypography` 实测行高推导**（无实测才回退页高 1.8% 兜底）；
  有 `lines` 的块**逐行帧渲染**——每行独立 Text / Word 每行一个 `w:p`，
  保实测行距与行首位置；表格按实测列宽比例绘制、行高 = bbox 高 ÷ 行数封顶
  （放不下转增长，与 Word 同构）；figure/barcode/artwork **不绘制**，底座原像素透出）。
- **底座注入**：VM 把 `PageFileStore` 的 rendered 图路径写入
  `page.baseImageRelativePath`，切档不重跑 parse；缺底座时退化纸色底、无覆盖层。
- **artwork 块**：乱码行从文字层剔除、区域不进覆盖 mask、预览/导出均按原像素透出；
  结构化档忽略 artwork（段落流里没有可表示的内容）。
- **裁图持久化**：figure/barcode 裁图落 `files/<doc>/reconstruct/<page>/`
  （`PageFileStore.reconstructCropDirectory(document:page:)`，随文档生命周期），
  不再写 tmp —— 结构化档导出「缺图」隐患根除。
- **日志**：`ZhixiaLog.reconstruct` 类目（tier / baseImage / mask / artwork / dedup /
  **layout**），真机问题按此过滤（抓取步骤见 `spec/layout-restore/device-acceptance.md`）。

**布局引擎（spec/layout-engine，2026-09-19）**——解析期把 blocks 过一遍
`RegionLayoutEngine.resolve`，产物写 `page.restoredBlocks`；预览与 `.restored`
导出**只读 `restoredBlocks ?? blocks`**（双档隔离：结构化档 / 可检索 PDF 仍读
`page.blocks`，零扰动）。四步管线（装得下的块逐位不变）：

1. **宽行拆分**：blockWidth > 0.63 × 内容宽的行级块垂直二分（阅读序、行高、
   行距保留，行 leadingOffset 按新块重定基）；
2. **碰撞消解**：相交对中下方块按行序下移让位（文本块不压 figure/barcode），
   块级行帧重建，迭代 ≤ 4 轮钉死最坏情形；
3. **溢出阶梯**（文本块装不下的降级链）：先**缩字号**（行高等比、下限 7pt）→
   仍放不下**向下扩块**（只吃下方空白带，遇任何块即止——防压图）→ 还不行
   **保文字 intact** 记 extreme；无 `lines` 块不经阶梯，走渲染期兜底
   （预览 `minimumScaleFactor(0.5)` × Word 布局期预缩 `w:sz`，双端同构、
   **不写 `normAutofit`**——QuickLook/Pages/WPS 不认，Word-only 特性 violates FR-004）；
4. **clampToPage**：越界块夹回页内。

**表格几何**（plan D8）：`w:tblGrid` 按实测 `columnRatios` 分配列宽
（识别通路无列信息 → 均分兜底，同一契约）；`w:trHeight` exact = 区域高 ÷ 行数
（**封顶**，修 Word 无界增长下坠）；单元格字号按实测列宽自适应
（`LayoutTypography.tableCellFontPT`，下限 7pt）；到 7pt 仍放不下 → **整表转
atLeast 增长** + `tableGrowthUpgrade` 日志，文字不截断——预览 `canvasTable` 用
**同一对**度量函数（tableCellFontPT / tableCellHeightPT）增长行高，FR-008 同构。

**layout 日志**（`ZhixiaLog.reconstruct` debug 级）：`layout yield`（让位计数 +
总平移量）/ `layout split` / `layout overflowShrink|overflowExpand|overflowExtreme` /
`layout tableGrowthUpgrade` / `layout figureShrink`——真机抓取步骤见
`spec/layout-engine/device-acceptance.md`。

**诊断根因 → 决策映射**（详见 `spec/layout-engine/plan.md` D1~D11）：

| 诊断根因 | 决策 |
|---|---|
| 字号走 0.018 常数 + 两端各自钳制（密集页字号虚大 ~1.7×，钳制基准不一致） | D4：`LayoutTypography` 唯一推导，页 pt 空间钳 [7,28] 只发生一次 |
| 行级块横跨多栏（阅读序 / 碰撞检测全乱） | D3：宽行拆分（0.63 × 内容宽阈值） |
| 行距用块内均分近似（密集页行距失真） | D7：行帧逐行渲染，`w:line` exact = 实测行高 × 20 twips |
| Word 表格行高无界增长 → 下坠压块 | D8：trHeight exact 封顶 + atLeast 升级链 |
| 装不下的文本块被截断 / 溢出块框 | D6：溢出阶梯 + 渲染期兜底（预缩 w:sz，二选一之 B） |
| 块相交 / 越出页面 | D5：碰撞消解（行序受让）+ clampToPage |

**扫描保真（spec/scan-fidelity，2026-09-20）**：在 R2 管线之上补行级与拍摄侧
保真——字号行级化（`lineFontPT` 逐行一档，退化回退块级）、对话行 y 跨度聚类 +
分段下划线占位（`LineSegment`）、重建后搜索 blob 回填、取景框解析式映射
（`OverlaySpaceMap`，探针退役为诊断源）、四态方向引导（`GuidanceDirective`，
面积滞回防闪烁）。根因表与已知限制（FR-012：OCR 字符级混淆 I/l/1 接受不纠错）
见 §6.9。

### 4.5 导出

**DOCX**（`DocxExportService`）—— 手写 OOXML + `ZipArchive` 打包：
```
[Content_Types].xml · _rels/.rels · word/document.xml · word/styles.xml
word/_rels/document.xml.rels · word/media/imageN.{png,jpg}
```
两档产物（旧 A/B/C 三档已删除——B 的 twips 定位事故、C 的多页衬底事故见 §6.7；
替代者 `.restored` 从坐标链路起重建，spec/layout-restore）。**默认档已翻转为流式**
（spec/wps-parity-layout，2026-09-24）：用户面 `ExportTier` **flow（流式，默认）/
highFidelity（高保真）** 一一映射内部 `.structured` / `.restored`，选择经
`@AppStorage(ExportTier.preferenceKey)` 持久化（启动即恢复）、预览与导出读**同一**
档位源（`ReconstructViewModel.setTier`）：

| 档 | 实现 | 说明 |
|---|---|---|
| **流式** = `.structured`（默认） | `wp:inline` | 段落流 + `w:tbl` + 内联图，A4 固定页 |
| **高保真** = `.restored`（可选） | 浮动对象 + 原生浮动表格 | 与预览同构（FR-009） |

`.restored` 的每页 Word 结构（z 层自下而上）：

1. **底图** behindDoc=1：铺满动态页，media 就是 `baseImageRelativePath` 原文件字节
   （扩展名保持原样，`[Content_Types].xml` 按实际扩展名声明）；
2. **srcRect 保留区** behindDoc=1：figure/barcode/artwork 引用**同一张底图** +
   `a:srcRect` 裁剪 —— 每页 media 恰一张（FR-005/FR-010）；
3. **覆盖 shape** behindDoc=1：`LayoutMask` 环带 median 色矩形盖掉原字迹
   （外扩 1.5% 会盖住保留区边缘，与预览一致）；必须留在 behindDoc 层——
   原生浮动表格在文本层渲染，shape 若在最前会整片盖住表格；
4. **文本层**：承载段落（行高 exact 10，不占版面）+ **原生浮动表格**
   （`w:tblpPr` 页面原位定位 + 表宽随 bbox + `tblGrid` 实测列宽 + `trHeight`
   exact 封顶（§4.4 表格几何），US5/FR-008，不套文本框）；
5. **浮动文本框** behindDoc=0：`wps:txbx` 内是真实段落，Word 里可直接编辑（FR-007）；
   有 `lines` 的块每行一个 `w:p`（`w:line` exact = 实测行高，FR-005）。

页面 sectPr 宽高随原图（EMU ÷ 635 = twips）且零边距；多页各配独立 section。
全部定位（posOffset EMU / tblpX·tblpY twips）都出自 `PageLayoutMapper`——
「导出定位 = 预览定位」有链路级测试钉死（`DocxRestoredLayoutTests` 夹具端到端）。

**版面对标契约**（spec/wps-parity-layout，2026-09-24；周期全貌与已知限制见 §6.12）：

1. **默认档 = 流式**：未选择时导出与预览均为 flow；`.restored` 降级为可选「高保真」。
   切档作废已生成 docx（PDF 不受影响）；预览渲染与导出**同源**——`ReconstructView`
   档位选择器写 `@AppStorage` 并同步 `ReconstructViewModel.setTier`，导出读同一档位。
2. **零假表**：几何通路 v1 表格聚类器（`OnDeviceTableCluster`）**退役**——散排编号
   文本不再被聚成假表；表只来自 iOS 26 结构化识别或锚点驱动的 `TableGridV2`
   （宁缺毋假）。休眠类与直连单测保留作回归钉。
3. **丢字哨兵 `textSentinel`**：导出（docx 与 PDF 公共漏斗）前逐页执行墨迹-文本对账
   ——`InkRegionProvider`（原始墨迹连通域，不做 figures 质量闸门）→ `InkTextReconciler`
   纯函数 → debug 日志；缺口四分类 `figureOverlap` / `structureSwallow` / `edgeBand` /
   `likelyMissed`，**只记不阻断**（FR-006）。配套解析期 containment 不变量：被表格/
   条码 bbox 剔除的行必须被结构文本携带，未覆盖行保留回文字层、违规计数进日志。
4. **通路可观测 `reconstructPath`**：每页解析恰好一条决策线——五分类
   `structuredSuccess` / `apiUnavailable` / `lowVersionFallback` / `requestFailed` /
   `invalidResult`（debug 级 + privacy.public）；真机抓取走 Console.app（步骤见
   `spec/wps-parity-layout/device-acceptance.md` §0）。
5. **段落收敛**：流式档导出侧 `FlowParagraphSplitter` 纯函数切段——三判据（条目号
   领头 / 行首回撤 ≥ 0.012 / 句末标点）+ 三不变量（恒等 / 回退 / 零丢失）；解析块
   粒度不动（scan-fidelity 红线），文本段落收敛金标准 42 段 ±30%（实测 32 段）。

**可检索 PDF**（`SearchablePDFExportService`）—— 原图渲染 + 不可见文字层（可被 `PDFKit` 选中/搜索）。

### 4.6 专题文档

- `docs/04-implementation-principles.md` —— 几何 / 管线 / 并发 / 落盘 / 编码规矩
- `docs/06-document-reconstruction.md` —— 版面还原 IR 与已知问题
- `docs/07-reconstruct-r2-optimization.md` —— **R2 完整方案**（含实测数据，还原必读）
- `docs/08-reconstruct-v3-realworld-fix.md` —— 真机回归与根因

---

## 5. 已实现功能

| 模块 | 能力 | 状态 |
|---|---|---|
| 取景 | 实时框边（三级检测兜底：严格矩形 → 条件分割 → 放宽矩形；连续实线整框：跟踪细实线 / 锁定粗双线）、手动对焦/曝光、闪光灯、连拍、相册导入 | ✅ |
| 取景 | 自动快门 6 帧确认窗（锁定后 ≈0.4s 才拍；suspicious 冻结、解锁清零、手动快门不受限）+ 四态引导（对准 / 太远 / 可疑 / 寻找，面积滞回防闪烁） | ✅ 新增（spec/overlay-frame-visibility、spec/scan-fidelity，§6.9/§6.10） |
| 取景 | **框真相契约**（spec/frame-truth 起）：呈现框唯一真值——有呈现框时快门后不重检、成片=呈现框；锁定瞬间吸附上屏并冻结（精修可见）；候选池单一真源 + 页面先验门控 + 锚点治理；`closer` 无效框不承诺可拍。`CropConsistencyGate` 保留为搜索态/回退（文档主路径不再使用） | ✅ 单测钉死（spec/wysiwyg-crop + case-b-sticky-v2 + folded-page-capture + frame-truth，§6.11/§6.13）；⏳ **真机验收待做**（主清单 spec/frame-truth/device-acceptance.md） |
| 取景 | 证件模式比例窗 | ✅ |
| 整理 | 拖角校正、五档滤镜、旋转 | ✅ |
| 库 | 文件夹、搜索、收藏、加页、删除、存储占用统计 | ✅ |
| OCR「文本」 | 本机识别 + 复制 + 质量择优 | ✅ |
| 导出 | 纯图片 PDF、可检索 PDF、系统分享 | ✅ |
| 还原 · 基础 | 段落阅读序、标题判定、列表判定 → DOCX / 可检索 PDF | ✅ |
| 还原 · IR v2 | `PageLayout`（band/region/column/anchor）、语义标签、confidence | ✅ |
| 还原 · 表格（iOS 26） | `RecognizeDocumentsRequest` 直接给行列结构 | ✅ 新增，模拟器实测样张 7×3 表（§6.2） |
| 还原 · 表格（iOS 18~25） | `TableGridV2` 锚点驱动（v1 聚类器已退役：散排编号不再产假表） | ⚠️ 锚点命中才出表，真机烂图仍不过（§6.2） |
| 还原 · 配图 | `FigureRegionsV2` 空白连通域 + barcode 通道 + v1 兜底 | ⚠️ 能出图，真机质量差 |
| 还原 · 噪声过滤 | 状态栏 / UI chrome / QR URL | ✅ |
| OCR · 预处理档 | `OCRPreprocessor`：去阴影 + 灰度 + 锐化，质量不达标时自动重跑 | ✅ 新增（§4.3） |
| 还原 · 双档 | 流式 `.structured`（**默认**）+ 高保真 `.restored`（可选；底座/覆盖/原位/浮动表格，导出同构）；@AppStorage 持久化、预览/导出同源 | ✅ 重做 + 默认档翻转（spec/layout-restore、spec/wps-parity-layout，§4.5/§6.12） |
| 还原 · 段落收敛 | 导出侧 `FlowParagraphSplitter` 切段（条目号领头 / 行首回撤 ≥ 0.012 / 句末标点，三不变量恒等/回退/零丢失）；金标准 32 段 ∈ 42 ±30% | ✅ 新增（spec/wps-parity-layout，§6.12） |
| 还原 · 图形完整 | 漫画条等细长大图形单张完整内联于阅读序原位（金标准验证）；几何回退未检出时哨兵报证 | ✅ 新增（spec/wps-parity-layout，§6.12） |
| 还原 · 通路可观测 | `reconstructPath` 每页一条五分类决策线（debug + privacy.public） | ✅ 新增（spec/wps-parity-layout，§6.12） |
| 还原 · 丢字防护 | containment 不变量 + 页眉规则收紧 + 墨迹-文本对账哨兵 `textSentinel`（只记不阻断） | ✅ 新增（spec/wps-parity-layout，§6.12） |
| 还原 · 乱码治理 | `GarbledRegionDetector` 双门控 → `.artwork` 原像素保留 | ✅ 新增 |
| 还原 · 条码单份 | figure↔barcode 交叉去重 + URL 并入 | ✅ 新增 |
| 云解析 | TextIn | ❌ **stub**：无密钥、无网络实现，`parse` 直接 throw |
| 手写 / 勾选识别 | — | ❌ 未实现（`checkbox` / `handwrittenBlank` 类型已预留但未产出） |

### 5.1 测试现状

- 44 个测试文件 / 436 个 `@Test`，全量 **396 passed + 0 failed + 1 expected failure**
  （known issue：真机 OCR 缺表格结构的历史记录用例，`recorded an expected failure`，非失败）。
  取景检测本轮（spec/live-edge-crop）新增套件：`DocumentFrameStyleTests`（实线整框样式
  纯数据断言：dash 恒空 / 两态差异 / idCard 守卫）+ `EdgeDetectionStrategyTests` 的
  `needsRelaxedRectangles` 门控穷举与放宽候选进池择优 + `CaptureFallbackChainTests`
  （快门回退链三分支替身锚定）+ `ReviewViewModelTests.autoRefineSkipsUserAdjustedQuad`
  （用户调框不被自动 refine 覆盖）；基线 280 → 295 只增不减。
  overlay-frame-visibility 续推 295 → 302（`EdgeOverlayRenderingTests` ×3 +
  `AutoCaptureHoldWindowTests` ×4，§6.10）；wysiwyg-crop 续推 302 → 317
  （`CropConsistencyGateTests` ×5 + `CandidateStickyTests` ×5 + `CropGateAtShutterTests` ×5，
  §6.11）；wps-parity-layout 续推 317 → 357（新建 `GoldenWorksheetEndToEndTests` ×10 +
  `InkTextReconcilerTests` ×12，append `OnDeviceReadingOrderRowClusteringTests` +7 /
  `ReconstructTierTests` +4 / `OCRNoiseFilterTests` +4 / `DocumentStructureTests` +3，
  §6.12）。
   版面还原链路新增套件：`PageLayoutMapperTests` / `LayoutMaskBuilderTests` /
   `GarbledRegionDetectorTests` / `BarcodeDedupTests` / `DocxRestoredLayoutTests`
   （OOXML 结构断言 + 真实样张端到端）；
   布局引擎套件（spec/layout-engine）：`RegionLayoutEngineTests`（拆分 / 消解 /
   溢出阶梯零扰动）+ `LayoutTypographyTests`（共享度量）+ `DocxRestoredLayoutTests`
   的行帧 / 字号比例 / 表格几何扩展。
- 真实样张夹具：`docs/fixtures/`（营养表 + 练习册），由 `Tools/ocr-dump/` 生成，
  固化在 `ZhixiaTests/ReconstructV2Fixtures.swift`（**勿手改**，改原图后重跑生成脚本）。
- ⚠️ **测试全绿 ≠ 真机能用** —— 见 §6.2，这个坑已经踩过一次。

---

## 6. 卡点（诚实清单）

### 6.1 已修：OCR 跑在未矫正的原图上（2026-09-08）

`ReconstructViewModel.reconstruct()` 原本**优先读 `.original`**（相机直出、未透视矫正、未去阴影），
`.rendered`（矫正+增强）永远轮不到。后果：倾斜 → 行切分错乱；阴影 → 字符误识；未裁边 → UI 全进正文。

**指纹**：关掉「保留原图」开关反而效果更好。

✅ 已修为 rendered 优先 + original 兜底（不做存在性检查，交给 `parse` 自己失败）。

### 6.2 真机表格：iOS 26 已解决，iOS 18~25 未解决

**根因**（docs/08 §3）：Vision 老的 `VNRecognizeTextRequest` **只给 line 级 bbox**。
真机把整行单元格合并成一个 line：

| 指标 | fixture | 真机（用户实拍） |
|---|---|---|
| 营养表 x 跨度 | 0.147~0.84（页宽 70%） | 0.082~0.25（**17%**） |
| 单元格粒度 | 18 个独立 cell | **7 个错位行**（`项目每100克NRV%`、`17%蛋白` 跨行粘连） |
| 「营养成分表」标题 | 完整一行 | 识别成「◎配料：…」+ 孤立「表」，**anchor 丢失** |

后果：`TableGridV2Detector` 的 `guard let titleAnchor else { return nil }` 直接 return →
**整表消失 → 导出 Word 里 `w:tbl = 0`**。这是「和扫描王差太多」的直接原因。

**✅ iOS 26 已解决**：`RecognizeDocumentsRequest` 返回二维 `Cell` 数组，**不需要那个假设** ——
所以这个问题在 iOS 26 上是「不存在」而不是「被调参调好」。实测（2026-09-12，
iPhone 17 模拟器 + `docs/fixtures/images/nutrition-mango.jpg`）：

```
table[0] rows=7 cols=3 bbox=(0.128, 0.260, 0.728, 0.177)
  row=["", "营养成分表", ""]
  row=["项目", "每100克", "NRV%"]
  row=["能量", "1429千焦", "17%"]
  row=["蛋白质", "1.5克", "3%"]
  ...
```

连真机丢失的「营养成分表」表头都恢复了。

**⚠️ iOS 18~25 仍走几何兜底，真机依旧出不了表** —— 这条被
`ReconstructEndToEndTests.realDeviceOcrStillLacksTable` 用 `withKnownIssue` 钉住了
（修好时会**反向失败**提醒删包装）。

### 6.3 未解决：几何兜底仍是 all-or-nothing，无降级阶梯

表格检测任一环节失败（锚点 / 行数 / 列数 / occupancy）就整体返回 nil，没有任何 graceful degradation。
iOS 26 通路绕过了它，但**老系统仍然吃这个亏**。

> 2026-09-19 注：**渲染侧**的降级阶梯已由布局引擎补上（文本块装不下：缩字号 →
> 扩块 → 保文字，见 §4.4）；本节说的是**检测侧**（表格识别本身）——仍是
> all-or-nothing，下方 P1-1 依旧有效。

### 6.4 架构性天花板

| 维度 | 扫描王 / WPS | 纸匣 | 差距性质 |
|---|---|---|---|
| 图像预处理 | 自动裁边 + 去阴影 + 二值化 + 锐化 | ✅ 已补 `OCRPreprocessor`（去阴影 + 灰度 + 锐化） | 已追平 |
| OCR 引擎 | 自研/定制 + 云 | Apple Vision（端侧） | **端侧差一档，需云通路才能追平** |
| 版面分析 | 深度学习版面模型 | ✅ iOS 26 用 `RecognizeDocumentsRequest`；老系统仍纯几何 | 老系统有差距 |
| 表格还原 | 深度学习表格结构识别 | ✅ iOS 26 同上 | 老系统有差距 |
| 手写 / 勾选 | 专门模型 | 无 | 缺能力 |

### 6.5 已解决（推倒重来）：B / C 档预览效果差（2026-09-12 用户反馈）

> 2026-09-18 更新：B/C 档已随 spec/layout-restore **整体删除**（枚举只剩
> `.structured` / `.restored`）。替代者 `.restored` 版面还原档重建了坐标链路
> （`PageLayoutMapper` 统一换算）、覆盖层（环带 median 净化矩形）与导出结构
> （见 §4.4/§4.5）。本节保留原始分析作历史记录。

三档能渲染三种画面了，但 **B 重排版 / C 衬底图「效果很差，没法用」**。

已知原因：
- B/C 是**纯几何还原**——块按 `bbox` 落位。真机上 bbox 本身就偏（§6.2），位置自然对不齐。
- 文本块按 `bbox.height × 0.78` 估字号，遇到行高异常或长句换行会溢出/重叠。
- C 档文字浮在扫描图上，只垫了半透明底，视觉上仍然脏。
- **语义不一致**：预览 C 档是「原图 + 块浮原位」，而 docx C 档导出是「原图衬底 + 文字正常流」，
  两者不是一回事，用户对不上号。

**结论**：B/C 在 §6.2/§6.3 解决前不可能好用——**它们的质量下限由表格/配图/阅读序的准确性决定**，
不是渲染层能单独救的。

### 6.6 其他已知缺口

- `Localizable.xcstrings` 里若有**空条目，界面会直接显示原始 key**（踩过 `reconstruct.tierHint`）。
- `SearchablePDF` 文字层偶有重复绘制（反解时观察到重叠行），原因未查。
- 真机照片常是「对着另一块屏幕拍的截图」（带状态栏、App UI、二维码），这类输入目前只能靠启发式兜。
- **`VNDetectBarcodesRequest` 在 iOS 模拟器上恒返回 0**（2026-09-12 用真实样张 +
  全部 symbology 验证）。任何「模拟器里能检出条码」的断言都是假绿 ——
  检测已抽成 `BarcodeDetecting` 协议，单测注入替身，真检测器只能真机验。
- **模拟器 ≠ 真机**：`RecognizeDocumentsRequest` 的结构识别已在模拟器验证，
  但 OCR 的字准率仍建议真机复核。

### 6.7 已修：三个数据安全级缺陷（2026-09-12，读代码时发现）

这三个都**不在原卡点清单里**，是逐行读代码读出来的。共同点：症状是「用户数据没了」
或「文件损坏」，与还原质量无关，所以优先级高于所有算法问题。

| # | 缺陷 | 位置 | 后果 |
|---|---|---|---|
| 1 🔴 | `commit` 失败时无条件 `removeItem(at: documentDirectory(document))` | `PageFileStore.swift` | 给**已有文档**追加页时若第 N 页写盘失败（典型是磁盘满），会把该文档**此前所有页的图全删掉**，而 `appendPages` 未执行 → 数据库指向不存在的文件 → **文档永久损坏** |
| 2 🔴 | `escape()` 只做五个实体转义 | `DocxExportService.swift` | OCR 输出里的 `0x00-0x08 / 0x0B / 0x0C / 0x0E-0x1F` 会写进 `document.xml` → **整个 docx 损坏，Word 拒开** |
| 3 🟠 | `document.insert(page, at: 输入下标)` | `PDFExportService.swift` | 解码失败的图会被 `continue` 跳过，输入下标与已插入页数脱钩 → 越界。**实测 PDFKit 会容忍**（表现为追加），所以这是「依赖未文档化行为」的脆弱点，不是已复现的崩溃 |

同批修的导出缺陷（原属 V3.4）：

| # | 缺陷 | 位置 | 后果 |
|---|---|---|---|
| 4 🔴 | B 档 anchor 的 `wp:posOffset` / `wp:extent` 用了 **twips 常量**（应为 EMU） | `DocxExportService.swift` | 差 **635 倍**：B 档图片全挤在页面左上角 0.33mm 内、被缩成约 1/635 |
| 5 🟠 | C 档把所有页的衬底一次性 append 到 body 最前面 | `DocxExportService.swift` | 多页文档 → 第 1 页堆 N 张 A4 互相遮挡，第 2..N 页无衬底 |
| 6 🟡 | `styles.xml` 无 `w:rFonts` / `w:eastAsia` | `DocxExportService.swift` | 中文只能靠 Word 字体回退，跨平台观感不一致 |

### 6.8 已修：真机第二轮反馈（2026-09-12）

用户实拍一页**双栏教材**做「还原」，反馈详情：
「左右两栏逐行交错」「正文里的照片整个丢了」「拍照时虚线框捕不到书的边框」。

| # | 缺陷 | 根因 | 位置 |
|---|---|---|---|
| 1 🔴 | **取景虚线框对不上书的边框**（成片却是准的） | 视频帧连接转了 90°，`emit` 又 `.oriented(.right)` 转一次 —— **转了两次**，预览只转一次。帧变成横向（720×405），`FrameMapper` 按 aspect-fill 算出 3.86 倍水平拉伸，框被推到屏幕外。成片走 `AVCapturePhotoOutput` 另一条链路，所以一直是对的 | `AVCameraSession` |
| 2 🔴 | **左右栏逐行交错** | `OnDeviceReadingOrder` 的段落聚类与 `OnDeviceDocumentParser` 的全局排序**都假设单栏**。新增 `PageColumnSplitter`（x 投影找 gutter → 按栏切 → 栏内排序 → 栏间按栏序拼）。刻意不复用 `ColumnResolver`：那是为「描述版面」设计的，只吃 body 行、丢窄栏、要求 gutter ≥6%，拿来做阅读序切分会**静默丢内容** | `Domain/Layout/PageColumnSplitter.swift` |
| 3 🔴 | **正文里的照片丢失** | 几何的「空白连通域」**区分不了照片和白纸** —— 实测整页空白连成**一整块**（bbox 覆盖 94%×96%，fill 0.27），插图的空白和页边距、行间距全部连通，照片从来没作为独立区域出现过。新增 `InkFigureDetector` 读像素 | `Domain/Figure/InkFigureDetector.swift` |
| 4 🟠 | **练习册选项句被降级成条码块** | `looksLikeURL` 原判据是「去空格后同时含 `.` 和 `/`」→ `"stopped / was stopping working."` 中招。「A / B 选出正确形式」是教材通用句式，误伤面很大。真 URL 的判据改为**不含空白** + 域名形态正则 | `OCRNoiseFilter` |
| 5 🟠 | **短行被排到整段之后** | `readingOrder` 的「同一视觉行」容差是 0.03，比教材行距（1%~2%）还大 → 所有块都被当成同行改成按 x 排。分栏后栏内文本纵向流动，本就不该有「同行」概念 → 改严格按 y | `OnDeviceDocumentParser` |

> **`InkFigureDetector` 的判据是反直觉的，值得记一笔**：最初以为「照片密、文字疏」，
> 实测恰恰相反 —— 照片 fill **0.31**（车内有大量亮部），右栏文字块 fill **0.60**。
> 密度和局部对比度在这个页面上都与预期反相关。真正把两者分开的是
> **「这块区域是不是已经被 OCR 文字盒覆盖了」**（`maxTextCoverage`）。
> 教训：阈值要用真实数据量出来，别用直觉推。

> 新增真实样张 `docs/fixtures/images/textbook-columns.jpg`（用户实拍的双栏教材页）——
> 原先两份夹具**都是单栏**，「页面是单栏」这个假设在测试里从来没被挑战过。

> 回归网：`ZhixiaTests/ExportSafetyTests.swift`、`PageColumnSplitterTests`、
> `InkFigureDetectorTests`、`TextbookFixtureTests`。其中 1/2/4/5 四条测试
> **在无修复时确实是红的**（已逐个还原验证过），第 3 条两种写法都过 —— 测试里注明了。

### 6.9 已修：扫描保真六缺陷 + 取景边框不可见（2026-09-20，spec/scan-fidelity）

> 规格与决策：`spec/scan-fidelity/spec.md`（FR-001~012 / SC-001~006）、
> `plan.md`（D1~D8）；真机验收清单 `spec/scan-fidelity/device-acceptance.md`。

用户反馈的六类扫描/还原缺陷，根因与修复：

| # | 缺陷 | 根因 | 修复（任务） | 位置 |
|---|---|---|---|---|
| 1 🔴 | 混排行叠字（标题+正文同块互相压行） | 整块一个字号：块级字号取块内代表行高，大字行被压、小字行被撑，估算与渲染同源地错 | **字号行级化**：`lineFontPT`（行实测高 × 1.05 钳 [7,28]，行高退化回退块级），DOCX `w:sz` 与预览逐行同源（T006~T008） | `LayoutTypography` / `DocxExportService` / `LayoutCanvas` |
| 2 🔴 | 对话行被拆散、填空空隙丢失 | `sameRow` 用 midY 单点比较，同排异高分段被拆成两行、再按 x 重排；分段间空隙在文本拼接时丢 | **y 跨度重叠率聚类**（overlap ≥ 0.5×min(h)）+ 行内 minX 序；`LineSegment` 模型 + 空隙**下划线占位**（DOCX 下划线空格 run / 预览基线矩形）（T010~T013） | `OnDeviceReadingOrder` / `DocxExportService` / `LayoutCanvas` |
| 3 🟠 | 同页多次扫描结构不稳 | 聚类边界窄，±5% 几何抖动即翻车 | 判定带合取容差（y 重叠 + 高度比双条件）+ 三组固定种子微扰稳定测试（T015） | `OnDeviceReadingOrder` + 测试 |
| 4 🟠 | 重建完成后全文搜索无结果 | 重建通路从不回填搜索 blob（只有手动 OCR 回填） | `recognizedTextBlob` + `onContentReady` 回调 → `applyOCRBlob`（与手动 OCR 同路径；blob 取 `displayText`，表格行列也可搜）（T016~T018） | `ReconstructViewModel` / `DocumentView` |
| 5 🔴 | 取景框系统性偏窄甚至不可见 | overlay 映射锚在运行时探针（`layerRectConverted`），surface 尺寸 0 / 布局未就绪时静默退化为恒等 | **解析式映射** `OverlaySpaceMap`（照片→视频 `FOVLayout` 中心裁切逆换算 → 屏幕 aspectFill 解析放置，y-down 全链不翻转）；探针退役为诊断对照（`overlayProbeAnalytic` / `overlayProbeDelta` 日志）；视觉升级四角括号 + 框外压暗（T019~T022） | `OverlaySpaceMap` / `EdgeOverlayView` |
| 6 🟡 | 提示只有「对准/寻找」，无方向感 | 无距离/姿态判定 | **四态引导** `GuidanceDirective`（suspicious 复用既有阈值且优先级最高；太远面积滞回 0.07 进 / 0.09 出防闪烁）+ `capture.hint.tooFar`（T024~T026） | `CaptureViewModel` / `CaptureView` |

> **为什么探针是退役而不是修复**：探针本质是「问系统实际把视频帧放在哪」，依赖
> 布局完成后回调不丢帧——任何时序窗口都会让边框短暂错位。解析式映射没有时序
> 依赖，值是确定的；探针保留为诊断对照源（真机验收直接读 `overlayProbeDelta`
> 逐轴偏差），不再参与渲染。`FrameMapper` 一并退出 overlay 渲染链（照片空间
> 换算用途与测试保留）。

**已知限制（FR-012，明确接受）**：OCR 字符级混淆（`I`/`l`/`1`、`O`/`0`、`rn`/`m`）
**不做纠错**——本机 Vision 无字典/语言模型后处理，按「纯离线、不猜测」原则接受为
已知限制：混淆字符保留 OCR 原样（结构/语序还原不受影响，搜索可用宽泛词规避）。
若后续引入本地语言模型重排，必须作为独立开关（默认关）。

> 回归网：新增 `LineTypographyPerLineTests` / `OnDeviceReadingOrderRowClusteringTests` /
> `OverlaySpaceMapTests` / `GuidanceDirectiveTests`；更新 `DocxRestoredLayoutTests`
>（w:sz 行级断言，T027）/ `ReconstructTests`（blob 回填）/ `CaptureFallbackTests`
>（geometry 断言改全等）。基线 255 → 277 passed + 1 known issue + 0 failed（只增不减）。

### 6.10 已修：取景整框不可见的最后一环 + 自动快门确认窗（2026-09-21，spec/overlay-frame-visibility）

> 规格与决策：`spec/overlay-frame-visibility/spec.md`（US1~US5 / FR-001~010）、
> `plan.md`（D1~D6）；真机重测协议 `spec/overlay-frame-visibility/device-acceptance.md`。

scan-fidelity 把 overlay 映射改成解析链后，真机上整框**仍然不可见**——映射输出（屏幕点）
是正确的，但消费端 `QuadShape` 还停留在「归一化输入」语义：`path(in:)` 把屏幕点当 [0,1]
归一化值再乘 rect，路径被放大到屏幕外。同一文件里 `CornerBracketsShape`（T020 新写）
用的是正确的屏幕点约定——**两个 Shape、两种坐标约定并存**，而契约从未成文，所以
连改过这个文件的周期都没发现（教训已在 §4.2「overlay 映射与屏幕点契约」成文）。
修复：`QuadShape` 统一到屏幕点契约，`EdgeOverlayRenderingTests` ×3 钉死。

顺带补上自动快门的节奏缺陷：锁定后第一帧即拍，锁定视觉来不及呈现、用户来不及预知
（折页错误锁定更是直接拍错）。新增 6 帧确认窗（≈0.4s@15fps；suspicious 冻结、解锁
清零、手动快门不受限，语义见 §4.2），`AutoCaptureHoldWindowTests` ×4 穷举钉死。
折页「错误锁定」因此变得**可见且可中止**（整框呈现 + 移开取消）；曲面检测本体不在
本周期范围。

> 回归网：新增 `EdgeOverlayRenderingTests` ×3 + `AutoCaptureHoldWindowTests` ×4；
> 既有断言零修改（`CaptureFallbackTests/normalLockAutoCaptures` 默认窗下依旧第 15 帧拍）。
> 基线 295 → 302 用例（301 passed + 1 known issue + 0 failed，只增不减）。

---

### 6.11 已修：所见非所得 + 双候选振荡——快门裁切门禁与候选粘滞（2026-09-21，spec/wysiwyg-crop）

> ⚠️ **2026-09-26 真机复测更新：R4/R5 修复在真机验收标准下未达效**——Case A 成片
> 仍含折起部分、Case B 实线框仍持续跳动且跟踪态手动拍成片含左页大半，同因复发。
> 详见 §6.13 与 `spec/agent-handover/device-retest-20260926.md`。本节修复内容与
> 回归网保留作历史记录与单元级证据（门禁/粘滞语义本身有测试钉死）。

> 规格与决策：`spec/wysiwyg-crop/spec.md`（US1~US5 / FR-001~010）、
> `plan.md`（D1~D6）；真机重测协议 `spec/wysiwyg-crop/device-acceptance.md`。

overlay-frame-visibility 验收时 SC-001 失败 2 例，取证出两个新根因：**R4（主因）**
快门回退链 `detected ?? imageQuad ?? .fullImage` 对静帧重检无条件优先——折页/摊开书
场景静帧选出**整书外轮廓**，直接覆盖屏幕上正确的锁定框，成片含折起部分（所见与
所得割裂，R3「错误锁定可中止」的缓解前提也随之失效）；**R5（次因）**摊开书从中线
取景时右页与整书两候选逐帧交替取胜（面积比 ≈2:1，超 smoother areaJump 重置阈值），
实线框持续跳动、永不锁定。

修复双管齐下：① 快门时刻 `CropConsistencyGate`（Domain 纯函数）——文档模式以
**呈现框快照为裁切基准**，静帧重检仅在与呈现框 IoU ≥ 0.70（一致精修）时胜出，
否则呈现框胜（所见即所得）；② live 文档路径 `CandidateSticky`（`VisionEdgeDetector`
actor 内状态）——与上次择优相似（IoU ≥ 0.60）的候选优先延续（先稳者胜），连续 3 帧
无相似候选即逃逸清锚（不粘死）。证件模式与相册导入走旧链不参与，既有语义零改动。
契约细节见 §4.2「WYSIWYG 裁切契约」。

> 回归网：新增 `CropConsistencyGateTests` ×5 + `CandidateStickyTests` ×5 +
> `CropGateAtShutterTests` ×5（快门集成替身：锁定分歧/一致、跟踪态手动拍呈现框、
> 搜索态静帧自由检测、idCard 旧链锁定）；既有断言零修改
> （`CaptureFallbackTests/stillRedetectWins` 的 IoU ≈0.83 ≥ 0.70 语义兼容，静帧照旧胜出）。
> 基线 302 → 317 用例（316 passed + 1 known issue + 0 failed，只增不减）。

---

### 6.12 已修：默认导出对标 WPS——流式档、假表与静默丢字、段落收敛（2026-09-24，spec/wps-parity-layout）

> 规格与决策：`spec/wps-parity-layout/spec.md`（US1~US5 / FR-001~010）、
> `plan.md`（R&D-D1~D11）；真机重测协议 `spec/wps-parity-layout/device-acceptance.md`；
> 金标准 fixture：`docs/fixtures/images/grammar-worksheet.jpg`（解析器确切输入）+
> `docs/fixtures/golden-wps-reading-order.txt`（42 段阅读流，均从用户 2026-09-21
> 导出的 docx 解包提取）；调研输入 `docs/11-wps-parity-research.md`。

起因：用户拿 WPS 拍同页语法练习对照本 App 导出，三个可证差距——① 默认导出是
`.restored` 像素合成档（WPS 是干净流式文档）；② 旧 v1 聚类器把散排编号文本聚成
14 行**假表格**并吞掉 "(9)…" 正文；③ 疑似静默丢字（"wrong bus!"）。契约细节见
§4.5「版面对标契约」，周期结论：

| # | 差距 | 根因 | 修复 | 回归钉 |
|---|---|---|---|---|
| 1 🔴 | 默认档不对标 | `.restored` 是默认档 | **默认档翻转**：flow（=`.structured`）默认、`.restored` 降级可选「高保真」；@AppStorage 持久化 + 预览/导出同源 + 切档作废 docx | `ReconstructTierTests` ×11 |
| 2 🔴 | 散排编号 → 假表吞字 | v1 聚类器无锚点门控 | **v1 退役**：几何通路不再产表（宁缺毋假）；休眠类保留直连单测作回归钉 | 金标准 e2e 零假表 + v1 回归钉 |
| 3 🔴 | 通路决策黑箱 | 结构化通路真机疑似静默回退（iOS 26.7 真机导出取证），无日志可查 | **`reconstructPath` 五分类决策线**（每页恰好一条，debug + privacy.public） | 通路决策替身测试 |
| 4 🟠 | 静默丢字风险 | 剔行无去处 / 页眉规则误剔 / 漏识无证据 | **三层防护**：containment 不变量（违规计数不静默）+ 页眉窄带收紧（minY > 0.93 整行 + 8 字符先 trim + 句末标点守卫）+ 墨迹-文本对账哨兵 `textSentinel`（四分类，只记不阻断） | `InkTextReconcilerTests` ×12 + `DocumentStructureTests` +3 + `OCRNoiseFilterTests` +4 |
| 5 🟡 | 段落碎片化 | 大块整段合并（41 行一块 vs 金标准 42 段） | **导出侧 `FlowParagraphSplitter`**：三判据（条目号领头 / 行首回撤 ≥ 0.012 / 句末标点）+ 三不变量（恒等 / 回退 / 零丢失）；解析块粒度不动（scan-fidelity 红线，块序是 assemble 输入） | 金标准 32 段 ∈ 42 ±30% + 阅读序锚点链 |
| 6 🟡 | 图形完整性 | 漫画条是否拆碎/漏检 | 默认通路单一细长 figure 内联于金标准 [image]① 原位（cy=3.56M EMU 全高） | `GoldenWorksheetEndToEndTests` 漫画条 ×2 |

取证修正（重要）：**"wrong bus!" 从未丢失**——OCR 原行 `wrong bus！`（全角 ！）一直在
故事块内，2026-09-21 的「丢失」是拿 ASCII `!` 检索全角输出的假阴性；但防护机制照建
（假表吞字等风险真实存在），断言做全角/半角归一 +「真丢报得出、没丢不误报」双向钉。

已知限制（记录不修）：① 几何回退通路（iOS 18~25）漫画条未检出为 figure——哨兵
likelyMissed 如实报证；为回退档强推检测需放宽文字覆盖判据，文字误并的回归风险大于
修图收益。② 右侧大图按 maxY 降序装配排在故事块前、金标准在后——assemble 既有语义
对纵贯故事区的背景插画前后均通，不属本周期验收范围。③ 结构化通路**真机**接通性仍未
验证（调研 L1 疑案：iOS 26.7 真机疑似静默回退，模拟器 iOS 26.4.1 不复现、
structuredSuccess）——真机取证步骤见 `spec/wps-parity-layout/device-acceptance.md`。

测试基建修复（顺带，零生产代码）：金标准套件的 `GoldenParseCache` actor 有重入竞态——
Swift Testing 套件内用例**并行**，并发首调各自发起重复真实 parse，双通路共用 pageID
的裁图目录（每次 parse 先清空重写）交错 wipe/写产生悬空图片引用 → 漫画图被导出静默
丢弃（comicStrip 用例批量假阳性的根因）；修复 = 在飞 Task 去重（失败清槽带 generation
防误删新任务，保留重试语义）+ 双通路独立固定 pageID（…0001 / …0002）。

> 回归网：新建 `GoldenWorksheetEndToEndTests` ×10（真实 Vision 链路端到端：零假表 /
> 通路决策 / "wrong bus!" / 漫画条 / 段落收敛 / 阅读序锚点）+ `InkTextReconcilerTests`
> ×12（四分类穷举）；append `OnDeviceReadingOrderRowClusteringTests` +7（页眉规则 +
> 切分判据回归锚，含 `leadRetreatThreshold == 0.012` 常量钉）、`ReconstructTierTests`
> +4（默认档 / 持久化 / 预览导出同源）、`OCRNoiseFilterTests` +4、`DocumentStructureTests`
> +3（containment）。既有断言零修改（唯一例外 D8：`ReconstructTierTests` 两条直断旧
> 默认档的用例按计划翻转方向，逐条记录于 tasks.md T006）。基线 317 → 357 用例
> （+40，各局部套件全绿；全量跑批由周期验证阶段核实，只增不减）。

---

### 6.13 未解决：Case A / Case B 真机复测未达效（2026-09-26；**2026-10-17 起根因已定案、修复已交付，真机验收待做**）

> **2026-10-17 更新**：Case B 池交替盲区经 case-b-sticky-v2 代码级定案并修复
> （粘滞 v2 hold-through-miss）；Case A 经 understand-folded-book 四链路合成定案
> （H1 家族：检测过严 + 近摄制式 regime c 棘轮 + 自动拍误触 + 单向吸附 + 整理页
> 穿透），folded-page-capture 周期交付全套修复（377 全绿）。两周期真机验收合并为
> 同一趟会话，主清单 `spec/folded-page-capture/device-acceptance.md`。以下为
> 2026-09-26 复测时的历史记录，保留备查。

> 逐字原文与完整归因：`spec/agent-handover/device-retest-20260926.md`；
> 上轮验收记录与待定案假设：`spec/wysiwyg-crop/device-acceptance.md`（含 2026-09-26
> 复测记录行）。

用户 2026-09-26 用**含 wysiwyg-crop + wps-parity-layout 两周期全部改动**的新构建
安装包复测（iPhone 13 · iOS 26.7），§6.11 的两项修复同因复发：

| # | 卡点 | 现象（用户逐字） | 归因 | 状态 |
|---|---|---|---|---|
| 1 🔴 P0 | **Case A：折页书拍右页，成片仍含折起部分** | 「case A，还是会有折起部分」 | **R4 修复未达效**：折页场景检测器偏好整书外轮廓——若呈现框锁定的是含折起的大框，门禁「呈现框 = 裁切基准」忠实裁出整书（错在锁定对象，上轮假设 H1）；门禁侧误纳/路径未命中（H2）未排除 | 两轮修复未达效；H1/H2 待 `cropGate` 日志定案 |
| 2 🔴 P0 | **Case B：摊开书双候选，实线框仍跳 + 手动拍成片含左页大半** | 「case B，实线框一直再跳，手动拍，左边很大部分都近图片」 | **R5 修复未达效**：双候选面积比 ≈2:1 超 smoother areaJump 阈值；上轮高置信假设——粘滞 v1「池交替」盲区（候选池存在性逐帧交替时无相似帧可改写，走 miss 分支） | 同因复发；池交替假设被复测强化，待 `stickyOverride` 日志定案 |

**共同教训**：两轮修复都缺真机日志取证闭环——`cropGate` / `stickyOverride` 行从未
取得，根因假设至今未定案。**下轮修复必须先实时抓日志（Console.app 步骤见
`spec/wysiwyg-crop/device-acceptance.md` §0）定案，再动刀。** Case B 池交替盲区
已有明确修复方向（miss 帧 hold-through-miss，与 QuadSmoother 语义对齐）；Case A
若定案 H1，则修检测器候选偏好/锁定策略，门禁契约本身无需推翻。

**关联卡点**：WPS 对标总体未达（用户第三条反馈「整体上感觉跟wps的扫描还是有差距」）
——除上述取景裁剪问题外，还原链真机验收清单（`spec/wps-parity-layout/device-acceptance.md`）
仍「待填」，L1 真机通路疑案（iOS 26.7 结构化通路疑似静默回退）未定案，见 §6.12
已知限制 ③ 与 §7 P0。

---

## 7. 后续优化方向

> **2026-10-21**：最新完整优化路线图见
> [`docs/14-project-summary-and-roadmap.md`](14-project-summary-and-roadmap.md)
>（取景稳定性 / 拍后裁切校准 / 竞品对标 / 工程债；含真机数值与优先级）。


> 2026-09-12 更新：原 P0/P1/P3 大部分已完成（见 §6.7 与下方「已完成」）。
> 2026-09-26 更新：wysiwyg-crop 的 R4/R5 修复经真机复测**未达效**（Case A/B，§6.13）
> ——新增 **P0-0 取景裁剪取证与修复**置顶（当前最大卡点），下轮必须**先实时抓
> `cropGate` / `stickyOverride` 日志定案再动刀**。取景范式的「常驻框」替代路线见
> [11 §4.2/§7](11-wps-parity-research.md)。
> 2026-10-17 更新：P0-0 已落地——Case B（case-b-sticky-v2）与 Case A
> （folded-page-capture）根因均定案、修复均交付（377 全绿）；**2026-10-18
> 追加**：第二轮真机复测暴露「框锁局部带 / 成片越界」，逐帧遥测定案并交付
> frame-truth（386 全绿：候选池单一真源 / 页面先验 / 锚点治理 / s=0 守卫 /
> 锁定冻结 + 成片=呈现框）；当前唯一待办是
> **真机验收**（主清单 `spec/folded-page-capture/device-acceptance.md`，一趟合并
> Case B 复测与 L1 取证），验收结论决定「常驻框范式」周期 2 是否立项。
> **2026-10-21 复核后**：新增 [`docs/15`](15-capture-recovery-assessment.md) +
> `spec/guided-capture/`——主场景缺“我要拍右页”的意图，先做引导框 MVP +
> 画布真值 + trace/replay，自动调参降为 A/B 失败后的备选；真机验收仍做，
> 但不再是唯一待办。
> **2026-10-21 WPS 录屏**：已提供并评估（[15 §十一](15-capture-recovery-assessment.md)）；
> 录屏支持手动快门 + 自动跟随实线框 + 拍后重裁/滤镜；我们的固定引导框是
> 替代范式而非同款复刻，不改变主线；`document` 滤镜与拍后自动裁边列为
> T040/T041 后续项。
> 下面按**当前**的真实缺口重排。

### 已完成（2026-09-12）

| 原编号 | 任务 | 产物 |
|---|---|---|
| P0-2 | OCR 专用预处理档（去阴影 + 灰度 + 锐化，与展示解耦） | `Services/Image/OCRPreprocessor.swift` |
| P0-3 | 质量不达标时自动重 OCR | `VisionTextRecognizer` + `confidentScore` |
| P1 → 被取代 | 表格行列结构 | `Services/Reconstruct/VisionDocumentStructureRecognizer.swift`（iOS 26） |
| P2-3 | B/C 档下架 | `R2OutputTier.selectable` |
| P3-1 | 真机烂图 fixture | `ReconstructEndToEndTests.RealDeviceOCR` |
| P3-2 | 端到端断言（图片 → parse → docx → `w:tbl`） | `ZhixiaTests/ReconstructEndToEndTests.swift` |
| —— | 三个数据安全级缺陷 + 导出缺陷 | 见 §6.7，回归网 `ExportSafetyTests.swift` |

### P0 · 取景裁剪质量 + 真机验证（🔴 最优先，且只有你能做）

| # | 任务 | 说明 |
|---|---|---|
| **P0-0** | **取景 Case A/B 日志取证与修复（当前最大卡点）** | 实时抓 `cropGate` / `stickyOverride` 日志（步骤：`spec/wysiwyg-crop/device-acceptance.md` §0），定案 Case A（H1 显示侧 vs H2 门禁侧）与 Case B（粘滞 v1「池交替」盲区）；按定案修复（Case B 方向：hold-through-miss 与 `QuadSmoother` miss 语义对齐；Case A 若 H1：修候选择优/锁定策略，门禁契约不动）→ 真机复测。取证也可与 P0-1 同一次真机会话完成 |
| P0-1 | **真机跑 iOS 26 结构化通路（L1 取证）** | 模拟器已验证结构（7×3），但模拟器 ≠ 真机（iOS 26.7 真机疑似静默回退）。拿营养表 / 练习册各拍一张，导出 Word 看 `w:tbl` 与单元格内容——已并入 `spec/wps-parity-layout/device-acceptance.md` §A/§B（带 `reconstructPath` 取证步骤，§6.12 已知限制 ③） |
| P0-2 | 真机验 OCR 预处理档 | 拍一张**有阴影**的纸，对比开/关预处理档的「文本」结果 |
| P0-3 | 真机验条码 | 模拟器上 `VNDetectBarcodesRequest` 恒为 0，条码裁图只能真机验 |

### P1 · 老系统兜底 + 版面结构补全

| # | 任务 | 说明 |
|---|---|---|
| P1-1 | 表格降级阶梯 | iOS 18~25 仍出不了真机表。anchor → 通用数字列（≥3 行 × ≥2 列 + 数字密度），任何一级成功就出表（v1 聚类器已退役、不再参与阶梯，§6.12） |
| P1-2 | 列/行切分改 x/y 投影找 gutter | 摆脱「每 cell 一个 OCR line」假设 |
| P1-3 | ~~结构化通路的**段落级**输出~~（✅ 2026-09-24） | wps-parity 周期以导出侧 `FlowParagraphSplitter` 达成段落收敛：32 段 ∈ 金标准 42 ±30%、阅读序锚点链一致（§4.5/§6.12）；Vision 自带 `paragraphs` 分组的 A/B 仍可后续试 |
| P1-4 | 文档区域二次分割 | 用 `VNDetectDocumentSegmentationRequest` 挡掉截图的状态栏 / UI chrome（`DocumentMaskQuad` 已预埋但无调用者） |

### P2 · 导出层

| # | 任务 |
|---|---|
| P2-1 | A 档补 `w:tblPr` 样式（边框、表头底纹），现在只有裸 `w:tbl` |
| P2-2 | 表格 cell 对齐：数值列右对齐、表头加粗（`TableGridV2.headerRowIndices` 已算出但无消费者） |
| P2-3 | ~~`w:tblGrid`~~（✅ 2026-09-19 布局引擎 D8 落地：实测列宽 + `trHeight` 封顶，见 §4.4）；合并单元格 `gridSpan` / `vMerge`（`RecognizeDocumentsRequest` 已给出 `rowRange`/`columnRange`，导出端还没接） |
| P2-4 | C 档衬底改用**页面原图**（现在用的是「本页最大的 figure」，与预览不一致） |
| P2-5 | PDF 文字层按 block 顺序写，避免 PDFKit 读出来乱序 |

### P3 · 工程债（不影响正确性，但会咬人）

| # | 任务 |
|---|---|
| P3-1 | `LibraryViewModel.reload` 每次全表加载 + 关系 N+1 + 全目录遍历；`storageBytes` 算了从不读 |
| P3-2 | `ReviewViewModel.save` 把整本文档的渲染结果握在内存（50 页 ≈ 50-150MB）；`PageFileStore.commit` 的签名强制全量驻留 |
| P3-3 | `SwiftDataDocumentStore` **零测试** + 无 `VersionedSchema`/迁移方案 |
| P3-4 | Review 点「返回」泄漏整个 tmp 会话目录（`sweep` 只扫 `files/`） |
| P3-5 | `AppEnvironment` 建库失败静默降级内存库，用户看不到任何提示 |
| P3-6 | 设计系统：`0xEFE8DC` 等 4 个颜色散落在多个 Feature；28 处 `.font(.system(size:))` 未 token 化 |
| P3-7 | `DocumentViewModel.error` 无 UI 出口（删除失败表现为「点了没反应」） |

### P4 · 长期

- **接通云解析**（TextIn / Azure DI）：端侧降为离线/隐私场景的兜底。
- 手写 / 勾选识别。
- `ScanMode.idCard` 有模型无入口（`setMode` 无调用者）。

### 建议排期

| 阶段 | 内容 | 预估 |
|---|---|---|
| V3.5 | **P0-0 + P0-1：一次真机会话抓齐 `cropGate`/`stickyOverride`/`reconstructPath` 日志 → 定案 → 修复 → 复测**（只有你能做） | 1~3 天 |
| V3.6 | P2 导出层（表格样式 + gridSpan + C 档衬底换原图） | 3 天 |
| V3.7 | P1-1/P1-2 老系统兜底阶梯 | 5 天 |
| V4.0 | P3 工程债清理 | 3 天 |
| V4.1 | 云通路 + 手写/勾选（若走「常驻框范式」的周期 2，见 [11 §7](11-wps-parity-research.md)，则先于 V3.6 评审立项） | 2 周+ |


## 8. 新人操作指南

### 8.1 构建与测试

**⚠️ 本机必须加 `-disable-sandbox`**，否则所有 Swift 宏（SwiftData `@Model` / `@Observable` / swift-testing `@Test`）
都会报 `swift-plugin-server produced malformed response` 而构建失败。
根因是编译器给宏插件套的 `sandbox-exec` 在 macOS 26.6 申请失败（`sandbox_apply: Operation not permitted`）。
与 Xcode 装在哪个卷无关（已验证：完全磁盘访问、symlink 到 `/Applications`、`-skipMacroValidation` 都无效）。

```bash
OTHER_SWIFT_FLAGS="-disable-sandbox" xcodebuild test \
  -project Zhixia.xcodeproj -scheme Zhixia \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation -skipMacroValidation
```

> **不要把 `-disable-sandbox` 提交进共享工程**（会让别人白白关掉宏沙箱），只在命令行临时加。

其他坑：
- 模拟器偶发 `Simulator device failed to launch ... reason: Busy` —— 不是代码问题，
  `xcrun simctl erase all` 后重跑即可。
- `withKnownIssue` 命中时日志是 **recorded an expected failure**，不是 `passed`——grep 时别按 passed 找。
- `Zhixia.xcodeproj` 用 `PBXFileSystemSynchronizedRootGroup`（Xcode 16+），
  **新文件自动加入编译，不需要改 pbxproj**。

### 8.2 改哪里

| 想改… | 去… |
|---|---|
| 界面 / 交互 | `Features/<模块>/<模块>View.swift` |
| 页面状态 | `Features/<模块>/<模块>ViewModel.swift` |
| 版面算法 | `Domain/Layout/` `Domain/Table/` `Domain/Figure/` |
| iOS 26 结构化识别 | `Services/Reconstruct/VisionDocumentStructureRecognizer.swift` |
| 两条通路的接缝 | `Services/Reconstruct/StructuredDocumentPage.swift` |
| OCR 预处理档 | `Services/Image/OCRPreprocessor.swift` |
| 导出格式 | `Services/Reconstruct/DocxExportService.swift` / `SearchablePDFExportService.swift` |
| 图像处理 | `Services/Image/ImagePipeline.swift` + `EnhancementRecipe.swift` |
| 依赖装配 | `App/AppEnvironment.swift` |
| 文案 | `Zhixia/Localizable.xcstrings`（**别留空条目**） |

### 8.3 真机排障工具链

真机出问题，标准流程：**导出 PDF → 反解 → 对比 fixture → 定位 → 固化新 fixture → 修 → 回归**。

```bash
cd Tools/pdf-ocr-dump
xcrun swiftc -O main.swift -target arm64-apple-macos14 -o ocrdump
./ocrdump "/path/to/导出的.pdf"
```

用 `PDFPage.characterBounds(at:)` 逐字符取矩形、按 y 聚行，把真机 Vision 的 `[(text, bbox)]` 完整还原。

**两个坑**（都踩过）：
1. y 聚类不能用「与上一个字符比」的链式写法——漂移累积会把多行粘成一行，解出来是乱码。
   必须与**本行首字符**比较硬切。
2. `page.string` 是 content stream 顺序，**不是**视觉顺序，必须用 bounds 重排。

### 8.4 阅读顺序建议

1. **本文** —— 建立全貌
2. `docs/00-getting-started.md` —— 实操细节
3. `docs/06-document-reconstruction.md` → `docs/07-reconstruct-r2-optimization.md` → `docs/08-reconstruct-v3-realworld-fix.md`
   —— 还原这条线（**接手还原必读**，含全部实测数据）
4. `docs/02-architecture.md` / `03-tech-choices.md` / `04-implementation-principles.md` —— 按需下钻
5. 打开工程，真机跑主路径；模拟器用相册导入走「理 / 出 / 还原」

---

## 9. 一句话总结

> 扫描主链路已经能用了。还原链路的瓶颈**从来不在算法调参** ——
> 是「Vision 只给 line 级 bbox」这条硬约束让「按 midX 聚类推列」永远救不回来。
> iOS 26 的 `RecognizeDocumentsRequest` 直接给出行列结构，把这个约束**绕开了**（§6.2 有实测数据）；
> 图像层也补上了 OCR 专用预处理档。
>
> 老系统（iOS 18~25）仍需几何兜底，那条路真机出不了表 —— 已用 `withKnownIssue` 钉在测试里。
> **下一步最该做的是真机验证（§7 的 P0），那是模拟器替代不了的。**
