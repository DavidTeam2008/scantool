# 纸匣 Zhixia · 项目接手手册

> 面向**刚接手的同事**：读完这一篇，你应该能说清这个项目做什么、怎么搭的、为什么这么选、
> 现在做到哪、卡在哪、下一步往哪走。
> 需要下钻时，每节都给了对应代码路径和专题文档。
>
> 最后更新：2026-09-12 · 对应代码 90 个 Swift 文件 / 约 9.3k 行 / 全量 131 passed + 1 known issue + 0 failed

---

## 0. 速览

**一句话**：把纸上的东西，干净地收进这台 iPhone。对标全能扫描王的**主体能力**，不做广告、不做账号墙。

**核心流程**：对着纸 → 自动框边 → 快门 → 透视拉正 + 增强 → 连续多页 → 入库 → OCR / 版面还原 → 导出 PDF / Word。

**现状一句话**：**扫描主链路（拍、框、拉正、增强、OCR、导出图片 PDF）已经可用**；
**「版面还原 → 导出 Word」在 iOS 26 上已经打通**（`RecognizeDocumentsRequest` 直接给表格行列结构，
实测样张读出 7 行 × 3 列），**在 iOS 18~25 上仍走几何兜底、真机依旧出不了表**——见 §6。

### 仓库地图

```
scantool/
├── Zhixia/                  主工程（90 个 .swift）
│   ├── App/                 入口、DI 容器（AppEnvironment）、路由
│   ├── Features/            按页面拆：Capture / Edit / Document / Reconstruct / Library / OCR / Settings …
│   ├── Domain/              纯逻辑：几何、模型、版面分析、表格、配图、阅读序
│   ├── Services/            副作用：Camera / Image / Vision / OCR / Persistence / Reconstruct / PDF
│   └── DesignSystem/        Tokens + 复用组件
├── ZhixiaTests/             17 个测试文件 / 132 个 @Test（含端到端断言 + 真实双栏样张）
├── docs/                    本文 + 专题文档（01~09）
├── Tools/
│   ├── ocr-dump/            从样张图导出 OCR 夹具
│   └── pdf-ocr-dump/        **从导出的 PDF 反解真机 OCR**（排障利器，见 §8.3）
├── docs/fixtures/           两张样张 + 其 OCR 夹具
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
│       ├── 还原   → ReconstructView 版面还原 + A/B/C 档位 + 导出
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

**A. 扫描链路**（已稳定）

```
AVCaptureSession 帧流
  → VisionEdgeDetector (VNDetectRectangles / VNDetectDocumentSegmentation)
  → QuadSmoother 平滑  → EdgeOverlayView 实时框
  → 快门 → CapturedPhoto
  → PageFileStore.writeOriginal（暂存会话目录）
  → ReviewView 拖角校正 / 选滤镜
  → ImagePipeline.renderPage（透视拉正 + 增强 + 缩略图）
  → PageFileStore.commit → SwiftData 写元数据
```

**B. 还原链路**（详见 §4.4）

```
页面图（rendered 优先）
  ├─ iOS 26：VisionDocumentStructureRecognizer（RecognizeDocumentsRequest）
  │    → 直接拿 lines / tables（行列结构）/ barcodes
  └─ 回退：VisionTextRecognizer → OCRPageText [(text, bbox)]
            + TableGridV2Detector（锚点驱动，失败回退 v1）
  两条通路都归一成 StructuredDocumentPage，下游完全共用 ↓
  → PageBarcodeDetector  → 条码框（与结构化结果**取并集**）
  → ReconstructSceneRouter.route → scene (plain/exam/table/packaging)
  → OCRNoiseFilter       → 丢状态栏 / UI chrome，URL 降级
  → OnDeviceReadingOrder  → 段落块流
  → FigureRegionsV2       → 配图 / 条码裁切
  → [ReconstructPage] → ReconstructDocument
  → DocxExportService (A/B/C) 或 SearchablePDFExportService
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

- `VisionEdgeDetector` 双策略：先 `VNDetectRectanglesRequest`，失败再 `VNDetectDocumentSegmentationRequest`。
- `QuadSmoother` 对连续帧的四边形做平滑，避免实时框抖动。
- 证件模式（`ScanMode.idCard`）用一个固定比例窗约束检测。
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
  └─ ReconstructPage { pageID, size, scene, usedCloud, blocks, layout: PageLayout?, anchors }
       └─ ReconstructBlock { id, kind, bbox, text, style, table, figureRelativePath,
                             barcodePayload, isChecked, semantic, anchors, confidence }

ReconstructBlockKind = heading | paragraph | list | table | figure | barcode | checkbox | handwrittenBlank
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
| 配图 | `Domain/Figure/FigureRegionsV2.swift` | 题下区域网格 flood fill 找**空白连通域** + `maxArea = 0.12` 闸门；barcode anchor 通道；v1 兜底 |
| 噪声过滤 | `Domain/OCRNoiseFilter.swift` | 状态栏/UI chrome 丢弃；URL 降级为 barcode 块 |
| 场景路由 | `Domain/ReconstructSceneRouter.swift` | 判定顺序：**exam 优先于 grid**（否则练习册被判成表格） |

### 4.5 导出

**DOCX**（`DocxExportService`）—— 手写 OOXML + `ZipArchive` 打包：
```
[Content_Types].xml · _rels/.rels · word/document.xml · word/styles.xml
word/_rels/document.xml.rels · word/media/imageN.png
```
三档产物：

| 档 | 实现 | 说明 |
|---|---|---|
| **A 结构化**（默认） | `wp:inline` | 段落流 + `w:tbl` + 内联图，最稳 |
| **B 重排版** | `wp:anchor` | 块浮在 anchor 位置，Word 兼容性略差 |
| **C 衬底图** | `wp:anchor behindDoc=1` | 原图作底，文字层正常流 |

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
| 取景 | 实时框边、手动对焦/曝光、闪光灯、连拍、相册导入 | ✅ |
| 取景 | 证件模式比例窗 | ✅ |
| 整理 | 拖角校正、五档滤镜、旋转 | ✅ |
| 库 | 文件夹、搜索、收藏、加页、删除、存储占用统计 | ✅ |
| OCR「文本」 | 本机识别 + 复制 + 质量择优 | ✅ |
| 导出 | 纯图片 PDF、可检索 PDF、系统分享 | ✅ |
| 还原 · 基础 | 段落阅读序、标题判定、列表判定 → DOCX / 可检索 PDF | ✅ |
| 还原 · IR v2 | `PageLayout`（band/region/column/anchor）、语义标签、confidence | ✅ |
| 还原 · 表格（iOS 26） | `RecognizeDocumentsRequest` 直接给行列结构 | ✅ 新增，模拟器实测样张 7×3 表（§6.2） |
| 还原 · 表格（iOS 18~25） | `TableGridV2` 锚点驱动 + v1 兜底 | ⚠️ 样张通过，**真机不过**（§6.2） |
| 还原 · 配图 | `FigureRegionsV2` 空白连通域 + barcode 通道 + v1 兜底 | ⚠️ 能出图，真机质量差 |
| 还原 · 噪声过滤 | 状态栏 / UI chrome / QR URL | ✅ |
| OCR · 预处理档 | `OCRPreprocessor`：去阴影 + 灰度 + 锐化，质量不达标时自动重跑 | ✅ 新增（§4.3） |
| 还原 · 三档 | A/B/C 导出 + 预览随档位切换 | ⚠️ 实现保留，**B/C 入口已下架**（§6.5） |
| 云解析 | TextIn | ❌ **stub**：无密钥、无网络实现，`parse` 直接 throw |
| 手写 / 勾选识别 | — | ❌ 未实现（`checkbox` / `handwrittenBlank` 类型已预留但未产出） |

### 5.1 测试现状

- 10 个测试文件 / 83 个 `@Test`，全量 **82 passed + 0 failed**。
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

### 6.2 真机表格：iOS 26 已解决，iOS 18~25 未解决（**当前最大卡点**）

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

### 6.4 架构性天花板

| 维度 | 扫描王 / WPS | 纸匣 | 差距性质 |
|---|---|---|---|
| 图像预处理 | 自动裁边 + 去阴影 + 二值化 + 锐化 | ✅ 已补 `OCRPreprocessor`（去阴影 + 灰度 + 锐化） | 已追平 |
| OCR 引擎 | 自研/定制 + 云 | Apple Vision（端侧） | **端侧差一档，需云通路才能追平** |
| 版面分析 | 深度学习版面模型 | ✅ iOS 26 用 `RecognizeDocumentsRequest`；老系统仍纯几何 | 老系统有差距 |
| 表格还原 | 深度学习表格结构识别 | ✅ iOS 26 同上 | 老系统有差距 |
| 手写 / 勾选 | 专门模型 | 无 | 缺能力 |

### 6.5 未解决：B / C 档预览效果差（2026-09-12 用户反馈）

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

---

## 7. 后续优化方向

> 2026-09-12 更新：原 P0/P1/P3 大部分已完成（见 §6.7 与下方「已完成」）。
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

### P0 · 真机验证（🔴 最优先，且只有你能做）

| # | 任务 | 说明 |
|---|---|---|
| P0-1 | **真机跑 iOS 26 结构化通路** | 模拟器已验证结构（7×3），但模拟器 ≠ 真机。拿营养表 / 练习册各拍一张，导出 Word 看 `w:tbl` 与单元格内容 |
| P0-2 | 真机验 OCR 预处理档 | 拍一张**有阴影**的纸，对比开/关预处理档的「文本」结果 |
| P0-3 | 真机验条码 | 模拟器上 `VNDetectBarcodesRequest` 恒为 0，条码裁图只能真机验 |

### P1 · 老系统兜底 + 版面结构补全

| # | 任务 | 说明 |
|---|---|---|
| P1-1 | 表格降级阶梯 | iOS 18~25 仍出不了真机表。anchor → 通用数字列（≥3 行 × ≥2 列 + 数字密度）→ v1，任何一级成功就出表 |
| P1-2 | 列/行切分改 x/y 投影找 gutter | 摆脱「每 cell 一个 OCR line」假设 |
| P1-3 | 结构化通路的**段落级**输出 | 目前刻意用 `text.lines`（行级）以对齐下游；Vision 自己的 `paragraphs` 分组可能更好，值得 A/B |
| P1-4 | 文档区域二次分割 | 用 `VNDetectDocumentSegmentationRequest` 挡掉截图的状态栏 / UI chrome（`DocumentMaskQuad` 已预埋但无调用者） |

### P2 · 导出层

| # | 任务 |
|---|---|
| P2-1 | A 档补 `w:tblPr` 样式（边框、表头底纹），现在只有裸 `w:tbl` |
| P2-2 | 表格 cell 对齐：数值列右对齐、表头加粗（`TableGridV2.headerRowIndices` 已算出但无消费者） |
| P2-3 | `w:tblGrid`；合并单元格 `gridSpan` / `vMerge`（`RecognizeDocumentsRequest` 已给出 `rowRange`/`columnRange`，导出端还没接） |
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
| V3.5 | P0 真机验证（只有你能做） | 0.5 天 |
| V3.6 | P2 导出层（表格样式 + gridSpan + C 档衬底换原图） | 3 天 |
| V3.7 | P1-1/P1-2 老系统兜底阶梯 | 5 天 |
| V4.0 | P3 工程债清理 | 3 天 |
| V4.1 | 云通路 + 手写/勾选 | 2 周+ |


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
