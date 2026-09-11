# 00 接手指南

给第一次打开 `scantool/` 的同事：先能跑通，再知道改哪里。产品细节见 [01](01-product-prototype.md)，分层见 [02](02-architecture.md)，版面还原见 [06](06-document-reconstruction.md)。

更新：2026-09-07（与当前 `Zhixia` 工程对齐）

---

## 1. 五分钟概念

纸匣把「一张纸」变成「库里的一份文档」：

```
拍（取景）→ 理（裁切+滤镜）→ 出（库 / OCR / 分享）
                              └→ 还原（版面 IR → Word / 可检索 PDF）
```

- **文本**：本机 Vision OCR，复制字符串。不上传。
- **分享**：扫描件图片拼成 PDF（长得像纸）。
- **还原**：尝试排出段落 / 表 / 配图，导出可编辑 Word。当前全是本机启发式；云 TextIn 未实现。

---

## 2. 打开与运行

```bash
cd /path/to/ios/scantool
open Zhixia.xcodeproj
```

| 项 | 值 |
| --- | --- |
| Scheme | `Zhixia` |
| Bundle | `com.david.Zhixia` |
| 部署 | iOS 18.0+ |
| Swift | 6.0 |
| 真机 | 相机 + Vision 框检测必测 |
| 模拟器 | 相册导入可走完整「理 / 出 / 还原」；实时框不可信 |

首次启动：欢迎页申请相机。首页是文档库，底部朱砂钮进取景。

主路径验收：快门（可连拍）→ 完成 → 整理 → 保存 → 详情里 OCR / 还原 / 分享 PDF / 加页。

---

## 3. 目录地图（改代码从这里找）

```
Zhixia/
  App/                 入口、AppEnvironment、路由、Preferences、Preview 假实现
  Features/
    Onboarding/        首次引导
    Library/           首页库、文件夹、搜索
    Capture/           取景、框、连拍、相册
    Edit/              整理（裁切+滤镜）
    Document/          详情底栏：文本 | 还原 | 分享 | 加页
    OCR/               「文本」页
    Reconstruct/       「还原」预览与导出
    Export/            扫描件 PDF / 多图分享
    Settings/
  Domain/
    Models/            ScanDocument / ScanPage / Quad / ReconstructDocument …
    OnDevice*.swift    还原启发式（阅读序、表聚类、配图空洞）
    ReconstructSceneRouter.swift
    OCRTextQuality.swift
    Errors/
  Services/
    Camera/ Vision/ Image/ OCR/ PDF/ Persistence/
    Reconstruct/       解析器、裁图、条码、DOCX、可检索 PDF、ZIP
    ServiceProtocols.swift   全部能力协议
  DesignSystem/        Tokens + 组件
  Localizable.xcstrings
ZhixiaTests/           单测（含 ReconstructTests）
```

依赖方向：**Features → Domain / DesignSystem / Environment 协议**。禁止 Feature 里直接 `AVCaptureSession` / `CIFilter` / `VNRecognize…`（预览 Representable 除外）。

---

## 4. 组合根：`AppEnvironment`

`Zhixia/App/AppEnvironment.swift` 注入：

| 属性 | 默认实现 | 用途 |
| --- | --- | --- |
| `camera` / `previewAttacher` | `AVCameraSession` + Binder | 取景 |
| `detector` | `VisionEdgeDetector` | 框 |
| `pipeline` / `renderer` | `ImagePipeline` | 拉正+增强 |
| `documentStore` | SwiftData，失败则内存 | 元数据 |
| `fileStore` | `PageFileStore` | 原图/渲染/缩略图路径 |
| `recognizer` | `VisionTextRecognizer` | OCR |
| `parser` | `CompositeDocumentParser` → `OnDeviceDocumentParser` | 还原解析 |
| `docx` / `searchablePDF` | `DocxExportService` / `SearchablePDFExportService` | 还原导出 |
| `pdf` | `PDFExportService` | 扫描件 PDF |

测 ViewModel：构造时传入假 Store / 假 Recognizer / 假 Parser。

---

## 5. 常见改动对照表

| 你想改… | 优先打开 |
| --- | --- |
| 首页卡片 / 搜索 | `Features/Library/*`，`DocumentStore` |
| 框抖、锁不住、证件窗 | `QuadSmoother`、`VisionEdgeDetector`、`DocumentMaskQuad`、`FrameMapper` |
| 滤镜观感 | `EnhancementRecipe.swift`（不要散落魔法数） |
| OCR 中文乱码 / 选图策略 | `VisionTextRecognizer`、`OCRTextQuality` |
| 详情底栏入口 | `Features/Document/DocumentView.swift` |
| 还原出不出表 | `Domain/OnDeviceTableCluster.swift` |
| 还原出不出配图 | `Domain/OnDeviceFigureRegions.swift` + `NormalizedImageCrop` |
| 条码 / 二维码 | `PageBarcodeDetector.swift` |
| Word 里表/图长什么样 | `DocxExportService.swift` |
| 可检索 PDF 排版 | `SearchablePDFExportService.swift` |
| 文案 | `Localizable.xcstrings` |
| 颜色圆角 | `DesignSystem/Tokens.swift` |

---

## 6. 还原管线（当前实现）

```
优先 original.jpg（没有则 rendered）
  → Vision OCR
  → ReconstructSceneRouter（plain / exam / table / packaging）
  → OnDeviceTableCluster（OCR 盒子 → 网格）
  → OnDeviceReadingOrder（剩余行 → 段落）
  → OnDeviceFigureRegions（非文字连通域 → 裁 PNG）
  → PageBarcodeDetector（条码裁图 + payload）
  → ReconstructDocument IR
  → 预览 / DocxExportService / SearchablePDFExportService
```

`TextInDocumentParser`：**未配置密钥时不会调用**；调用也会抛 `reconstructCloudUnavailable`。不要以为云已经接通。

验收样张与失败现象见 [06 §已知问题](06-document-reconstruction.md#12-已知问题2026-09)。

---

## 7. 怎么测

> ⚠️ **本机（macOS 26.6.2 + Xcode 26.4.1）必须加 `OTHER_SWIFT_FLAGS="-disable-sandbox"`**，否则构建必失败。

```bash
# 全量单测（模拟器名称按本机调整）
xcodebuild -project Zhixia.xcodeproj -scheme Zhixia \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS="-disable-sandbox" test

# 只跑还原相关
xcodebuild -project Zhixia.xcodeproj -scheme Zhixia \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:ZhixiaTests/ReconstructV2Tests \
  CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS="-disable-sandbox" test
```

### 为什么需要 `-disable-sandbox`（踩坑记录，2026-09-07）

**症状**：所有 Swift 宏失效，构建失败：

```
External macro implementation type 'SwiftDataMacros.PersistentModelMacro' could not be found
for macro 'Model()'; '.../swift-plugin-server' produced malformed response
```

涉及 `@Model`（SwiftData）、`@Observable`（Observation）、`@Test`（swift-testing）等全部外部宏。
**Swift 本身正常**——纯 Swift 代码能编译，只有宏挂。

**排查过程与排除项**：

| 假设 | 结论 |
| --- | --- |
| 外部卷 Xcode（`/Volumes/DevDisk/...`） | ❌ 非根因。卷是 `Case-sensitive APFS` + `noowners`，虽不理想但不是主因 |
| 代码签名 / Gatekeeper | ❌ `codesign -vvv` = `valid on disk`；`spctl` = `accepted / Mac App Store` |
| 完全磁盘访问权限（TCC） | ❌ 与本错误无关 |
| 软链接到 `/Applications` | ❌ 只改路径，不改沙箱行为 |
| 工具沙箱 | ❌ `dangerouslyDisableSandbox` 后仍复现 |
| `-skipMacroValidation` | ❌ 无效 |
| 插件二进制损坏 | ❌ `DYLD_PRINT_LIBRARIES` 显示全部依赖加载成功，退出码 0 |

**真因**：编译器默认用 `sandbox-exec` 包裹宏插件进程。打开详细日志后第一行就是：

```
sandbox-exec: sandbox_apply: Operation not permitted
```

macOS 26.6 收紧后 `sandbox_apply` 被拒 → 插件服务起不来 → 编译器收到空响应 → 报 "malformed response"。
加 `-disable-sandbox` 跳过插件沙箱即可，构建与测试全部恢复正常。

**不想每次手敲**：可以在 Xcode 里给两个 target 的 `OTHER_SWIFT_FLAGS` 加 `-disable-sandbox`
（Build Settings → Other Swift Flags）。但这是**本机环境 workaround，不建议提交进共享工程**，
提交后会让别人在本来正常的机器上白白关掉宏沙箱。命令行传参更干净。

| 测试文件 | 覆盖 |
| --- | --- |
| `QuadSmootherTests` | 框锁定 |
| `ImagePipelineTests` | 拉正 / 灰度 |
| `DocumentStoreTests` | 入库、搜索、删文件 |
| `CaptureViewModelTests` / Review | 完成门槛、滤镜退出裁切 |
| `OCRViewModelTests` | 中文质量、双图择优 |
| `ReconstructTests` | 场景路由、阅读序、表聚类、配图空洞、DOCX 嵌表嵌图（**合成 bbox**） |
| `ReconstructV2Tests` | **真实样张夹具**：同上，但跑在 `docs/fixtures/` 的真机 OCR 上 |

**单测绿 ≠ 样张过关。** 营养表 / 练习册必须以真机或导入样张手验「还原 → Word」。

### 改还原时先跑夹具

`ReconstructTests` 用的是合成 `CGRect`，全绿也挡不住真机样张崩。
动 `OnDeviceTableCluster` / `OnDeviceFigureRegions` / `OnDeviceReadingOrder` / `ReconstructSceneRouter` 之前，先看真实样张的当前表现：

```bash
# 1. 用样张原图重新导出 OCR（改了 Vision 参数或换了样张时）
swift Tools/ocr-dump/main.swift docs/fixtures/images/*.jpg --out docs/fixtures

# 2. 重新生成 Swift 夹具
python3 Tools/ocr-dump/gen_fixtures.py

# 3. 免 Xcode 校验断言（本机 Xcode 插件服务异常时用这个）
python3 Tools/ocr-dump/verify_tests.py
```

已知失败已用 `withKnownIssue` 包住：**套件保持绿色，但问题一旦被修好，对应测试会反向失败**，提醒你删掉包装。
详见 [docs/fixtures/README.md](fixtures/README.md) 与 [07 §1.4](07-reconstruct-r2-optimization.md#14-实测数据m0-夹具2026-09-07)。

---

## 8. 纪律（合并前自检）

- Swift 6 严格并发：ViewModel `@MainActor @Observable`；相机 / CI / 解析 `actor`。
- 用户可见字符串进 xcstrings。
- Feature 不写 SwiftData `@Query`，走 Store。
- 图不进数据库；路径只经 `PageFileStore`。
- 「文本」路径禁止联网；还原默认也不上传。
- 不把整页截图塞进 `.docx` 冒充可编辑 Word。

---

## 9. 建议阅读顺序

1. 本文 + README  
2. [01](01-product-prototype.md) §3–5（信息架构与界面）  
3. [02](02-architecture.md) §1–5、§工程结构  
4. [06](06-document-reconstruction.md)（若动还原）  
5. [04](04-implementation-principles.md)（若动相机 / CI）  
6. [05](05-roadmap.md)（知道什么已完成、下一步是什么）
