# 智夏（Zhixia）项目总结

> **生成日期**：2026-09-21
> **当前状态**：5 个特性周期交付完毕（scan-edge-accuracy → layout-restore → layout-engine → scan-fidelity → live-edge-crop）；测试基线 **295 用例 = 294 passed + 1 known issue（豁免）+ 0 failed**；live-edge-crop 已完成实施（T001~T010），构建/部署验证（T011~T012）由验证子代理收尾。
> **配套文档**：`docs/00~09`（产品原型 / 架构 / 技术选型 / 实现原则 / 路线图 / 重建三篇 / 项目手册）；各周期 `spec/<name>/{spec,plan,tasks,device-acceptance}.md` 四件套。

---

## 1. 项目定位

**智夏** 是一款 **纯离线** 的 iPhone 文档扫描应用，核心链路：

```
拍摄（实时边缘检测 + 引导提示）
  → 边缘裁切（四级回退保证）
  → 图像增强（灰度 / 阴影均衡 / 滤镜）
  → OCR + 版面重建（行几何保真 / 阅读序 / 表格 / 图片 / 双栏 / 填空下划线）
  → 导出（可编辑 DOCX / 可搜索 PDF）
  → 文档库（文件夹 / 全文搜索 / 自动标题）
```

核心价值主张：**所见即可裁**（取景器边框 = 成片裁切范围）与 **还原保真**（预览与 Word 导出同源推导，无叠字 / 无碎片 / 无乱序）。隐私优先——所有计算在设备端完成，零网络依赖。

---

## 2. 代码架构

### 2.1 分层与目录

```
Zhixia/
├── App/                    # 装配与路由（唯一 new 发生地）
│   ├── ZhixiaApp / RootView / AppRoute
│   ├── AppEnvironment      # 服务装配：AVCameraSession + CameraPreviewBinder +
│   │                       #   VisionEdgeDetector + SwiftDataDocumentStore + ...
│   ├── PreferencesStore    # 用户偏好（自动快门/默认增强等）
│   └── PreviewSupport      # 替身实现（SwiftUI 预览与测试共用）
├── DesignSystem/           # Tokens + 通用组件（DocumentCard/FilterStrip/PageFilmstrip/ScanButton）
├── Features/               # MVVM 特性层
│   ├── Capture/            # 取景（CaptureView/ViewModel、EdgeOverlayView、相机预览）
│   ├── Edit/               # 预览调框（ReviewView + CropCanvas 四角拖拽）
│   ├── OCR/                # 纯文字识别页
│   ├── Reconstruct/        # 版面重建（ReconstructView/ViewModel、LayoutCanvas 预览画布）
│   ├── Document/           # 文档详情（导出入口/重建装配/手动 OCR 页）
│   ├── Export / Library / Settings / Onboarding
├── Services/               # 协议实现（I/O 边界）
│   ├── Camera/             # AVCameraSession、CameraPreviewBinder、CameraPreviewView
│   ├── Vision/             # VisionEdgeDetector、QuadSmoother、FrameMapper
│   ├── Image/              # ImagePipeline、OCRPreprocessor、EnhancementRecipe
│   ├── OCR/                # VisionTextRecognizer
│   ├── Reconstruct/        # DocxExportService、SearchablePDFExportService、
│   │                       #   CompositeDocumentParser、PageBarcodeDetector、ZipArchive...
│   ├── PDF/                # PDFExportService
│   ├── Persistence/        # SwiftDataDocumentStore（+ InMemory 测试替身）、PageFileStore
│   ├── Permissions/        # PermissionService
│   ├── ServiceProtocols.swift  # 全部服务协议（签名稳定契约）
│   └── ZhixiaLog.swift     # OSLog 观测通道
└── Domain/                 # 纯函数核心（零 I/O，可穷举单测）
    ├── Models/             # Quad、PageDraft、ScanDocument/Page、ReconstructDocument（含
    │                       #   BlockLine.segments/LineSegment）、Enhancement、ScanMode...
    ├── Layout/             # 布局引擎：LayoutAnalyzer、RegionLayoutEngine、LayoutTypography、
    │                       #   PageColumnSplitter、HeaderFooterClassifier、GarbledRegionDetector、
    │                       #   LayoutMaskBuilder、AnchorExtractor、PageLayoutMapper
    ├── Table/              # TableGridV2（+Detector）、TableProfile
    ├── Figure/             # InkFigureDetector、FigureRegionsV2
    ├── OnDeviceReadingOrder / OnDeviceTableCluster / OnDeviceFigureRegions
    ├── OverlaySpaceMap     # 照片→屏幕坐标解析链（渲染真值）
    ├── GuidanceDirective   # 四态引导判定 + 面积滞回
    ├── FOVLayout           # 视频↔照片 FOV 换算（单点收敛）
    ├── CaptureGeometry     # 取景几何单一真值源（videoAspect/photoAspect）
    ├── EdgeSnapper / OCRTextQuality / OCRNoiseFilter / ReconstructSceneRouter / ScanSession
    └── Errors/ZhixiaError

ZhixiaTests/                # 35 个测试文件，295 用例
```

### 2.2 依赖规则（架构铁律）

1. **依赖方向**：Features → ServiceProtocols + Domain；Domain 不依赖任何上层；对象创建只发生在 `AppEnvironment` 装配层。
2. **Domain 纯函数无 I/O**：所有算法（聚类/排版/映射/判定）以纯函数落地，同参数必同结果——这是 295 用例中大量穷举/性质断言的基础。
3. **协议签名稳定**：`ServiceProtocols` 是跨周期契约，实现可替换（如 SwiftData ↔ InMemory），签名不动则 Feature 零感知。
4. **布局解析一次完成，渲染只消费**：重建解析产物（ReconstructDocument）是唯一真值，LayoutCanvas 预览与 DocxExportService 导出消费同一份——预览 = Word 的根保证。
5. **Feature 不碰持久化**：落库一律经 ViewModel → DocumentStore。
6. **纯离线**：零网络依赖。

### 2.3 状态管理与可测性

- SwiftUI `@Observable` MVVM；无 Combine/Rx 依赖。
- `PreviewSupport` 替身（相机/检测器/存储）同时服务 SwiftUI 预览与 XCTest——「模拟器无真实相机」的拍摄链路全部以替身帧/替身快门验证。
- 两套坐标系是跨子系统最重要的隐式契约，已在多处测试钉死：
  - **OCR/文档空间 y-up**（Vision 原生，`OCRLine.boundingBox` 原点左下）
  - **拍摄/Quad 空间 y-down**（`Quad.fullImage` topLeft 原点，`VisionEdgeDetector` 出口 flipY）
  - 换算枢纽：`FOVLayout`（视频↔照片）与 `OverlaySpaceMap`（照片→屏幕），几何输入唯一来源 `CaptureGeometry`。

---

## 3. 技术原理

### 3.1 相机与 FOV 换算

- `AVCameraSession` 管理 AVCaptureSession；**视频流帧（16:9）与全分辨率照片（3:4）FOV 不同**——视频是照片的中心子区间。
- `CaptureGeometry`（videoAspect=实测帧宽高比、photoAspect=activeFormat 比例）在 `start()` 时测量缓存，是全部换算的单一真值源。
- `FOVLayout.convert` 在**摄入边界单点**完成 live 检测结果（视频空间）→ 照片空间的换算，使 `imageQuad` 与快门回退链天然空间一致。

### 3.2 边缘检测三级链（live-edge-crop 后的最终形态）

```
live（逐帧，检测器 actor 忙时丢帧）:
  一级 VNDetectRectanglesRequest  严格参数（置信度 0.6 / 最小尺寸 0.25 / 直角容差 20° / 候选 4）
  二级 VNDetectDocumentSegmentationRequest  条件触发（神经网络，仅一级无可信候选时）
  三级 VNDetectRectanglesRequest  放宽参数（0.35 / 0.08 / 28° / 8）
      —— 仅「一级+二级双失败」帧触发（needsRelaxedRectangles 纯函数门控），
         为折页厚书等曲边目标兜底；relaxedLiveProbe 日志记录触发率

候选统一择优 DetectionStrategy:
  面积下限 0.08 → 两级面积兜底（常规上限 0.96；为空放宽 ≤1.0 允许近满幅真框）
  → 包含降权（被包含 ≥0.9 的内框评分 ×0.35，外框必胜；含防退化保护）
  → 评分 = 面积 × 居中 × 方正

still（快门全分辨率）:
  放宽矩形 + 必跑文档分割 + EdgeSnapper 贴边吸附（检出框内缩 1~3%，沿外法线
  最大 5% 恢复真实边缘；EXIF 非 up 先直立化缩略，宁可不修不可错修）
```

- `QuadSmoother`：候选序列 → searching / tracking / **locked** 轨迹状态机；锁定瞬间轻震动 + 自动快门（可在设置关闭，仅 locked 且本锁定周期未拍过）。
- **安全门禁**：可疑锁定（quad 近满幅/贴边，疑似书超出视场被裁）抑制自动快门并提示后退；`GuidanceDirective` 四态（backOff/closer/locked/searching）+ 面积滞回（进入 <0.07 / 退出 >0.09）防提示闪烁。

### 3.3 取景 Overlay（所见即可裁的「所见」）

- **渲染真值 = 解析式**：`OverlaySpaceMap.screenQuad`（照片→视频 FOVLayout 逆换算 → 屏幕 aspectFill 解析放置），零运行时 API 依赖；旧探针（`layerRectConverted(fromMetadataOutputRect:)`）降级为诊断日志（`overlayProbeAnalytic/overlayProbeDelta` 与解析值逐轴对照）。
- 视觉：**连续实线整框**（`DocumentFrameStyle`，跟踪态细单线 / 锁定态粗双线，dash 恒空为类型不变量）+ 四角 L 形粗括号 + 框外压暗（跟踪 0.25 / 锁定 0.45）；证件模式 idMask 路径独立不变。

### 3.4 快门裁切回退链

```
quad = still重检测(最优，含吸附) ?? imageQuad(live跟踪框) ?? .fullImage(全幅)
```

三级兜底把折页场景的中间层（live 框）填上后，全幅退化只发生在「连放宽档也无候选」的极端场景——此时仍可手动快门拍全幅，预览页 `CropCanvas` 四角拖拽兜底（`userAdjustedQuad` 标记的页不被自动 refine 覆盖）。

### 3.5 图像增强与 OCR

- `ImagePipeline`（裁切/灰度/滤镜配方 `EnhancementRecipe`）、`OCRPreprocessor`（阴影均衡化——书脊阴影是扫描第一大敌）。
- `VisionTextRecognizer`：**两轮识别对比择优**（中英文质量打分 `OCRTextQuality`，中文识别 vs 高速档垃圾输出的实战防御）+ `OCRNoiseFilter` 噪声行过滤。
- 手动 OCR 页（OCRView）与重建流程共用识别内核，`applyOCRBlob` 把识别文本回填 `ocrSearchBlob`（全文搜索 + 自动标题「扫描·N」→ 内容主题，含防覆盖语义：已有自定义标题不被改写）。

### 3.6 版面重建（布局引擎，项目技术核心）

输入：OCR 行/分段几何 + 结构化识别（`CompositeDocumentParser` = 文本观测 + 文档结构观测 + 条码 + 墨迹图片区）。

```
OnDeviceReadingOrder（阅读序）:
  行聚类 —— sameRow = y 跨度重叠率 ≥ 0.5 × min(双方高度)
            （一个谓词同修三缺陷：同排异高分段合并 / 相邻行不误合 / 微扰稳定）
  行内 minX 排序 → 段落聚类（间距 > 1.6×中位行高 / 缩进跳变 0.18 分段）
  → PageColumnSplitter 双栏拆分 → 栏间阅读序

语义与净化:
  LayoutAnalyzer 题干/选项/标题语义 → HeaderFooterClassifier 页眉页脚
  → GarbledRegionDetector 乱码区 → AnchorExtractor 锚点（表格/条码锚）
  → BarcodeDedup / InkFigureDetector 图片区

排版（LayoutTypography，"预览=Word"的数学根基）:
  行级字号 lineFontPT = clamp(行实测高 × 页高pt × 1.05, 7, 28)
  —— 字号与行槽同源推导，DOCX w:sz 与预览 Text 共用，数学上不可能叠字
  estimatedRenderHeight 行级估算 → 溢出阶梯 / split / 消解
  BlockLine.segments（LineSegment: text/offset/width）→ 填空空隙
  ≥0.6 字符宽 → 下划线占位（DOCX w:u 空格 run + 预览基线矩形）

表格: TableGridV2(+Detector) 网格重建 → OOXML 浮动表格
图片: FigureRegionsV2 → DOCX 锚定浮动图
```

### 3.7 导出

- **DOCX**：`DocxExportService` 手写 OOXML（不依赖第三方库）：行段 w:sz 行级 + w:line exact 行距 + 多 run 下划线占位 + 浮动表格/图片；`ZipArchive` 打包。**`DocxRestoredLayoutTests` 断言「预览映射 = 导出 XML」一致性**——还原保真的测试锚点。
- **PDF**：`PDFExportService`（图像版）+ `SearchablePDFExportService`（不可见文本层，可搜索可选中）。
- 重建三档（文本还原 / 结构化 / 图像 PDF），切换档位失效缓存产物。

### 3.8 持久化与搜索

- SwiftData（`ScanEntities`）存文档/页/文件夹元数据；`PageFileStore` 文件系统存原图与导出产物；`InMemoryDocumentStore` 为测试替身。
- `ocrSearchBlob` 全文搜索；`DocumentTitle` 自动主题命名。

---

## 4. 实现方案演进（SDD 周期史）

每周期产出 `spec/<name>/` 四件套（需求 → 设计 → 任务 → 真机验收清单），实施与验证分离（子代理），**真机产物取证 → 本地同参对照 → fixture 固化为回归锚点**的闭环是质量根基。

| 周期 | 目标 | 关键交付 | 结果 |
|---|---|---|---|
| **scan-edge-accuracy** | 边缘检测精度 | 候选择优策略（两级面积兜底 / 包含降权）、still 贴边吸附 | 边框对齐精度达标 |
| **layout-restore** | 版面还原 v1 | 文本还原基本链路 | 可用 |
| **layout-engine** | 预览=Word 的布局引擎 | 37 任务：溢出阶梯 / split / 消解 / 表格模板 / 双栏；映射一致性断言 | 255 用例全绿；真机验收暴露 R1~R7 |
| **scan-fidelity** | 修复 R1~R7 还原缺陷 | 行级字号同源（R5 叠字）/ y 跨度重叠率聚类（R1 碎片+R2 乱序+R6 不稳）/ segments 下划线占位（R3）/ onContentReady→applyOCRBlob（R7 搜索失效）/ OverlaySpaceMap 解析式映射（边框不可见）/ GuidanceDirective 四态滞回；I-l-1 混淆定为已知限制（R4） | 279 用例全绿 + 真机验收（SC-001~005）+ 装机 |
| **live-edge-crop** | 折页厚书可靠裁切（真机验收反馈） | live 三级检测兜底（needsRelaxedRectangles 门控）/ 实线整框 DocumentFrameStyle / 快门回退链三分支测试钉死 / relaxedLiveProbe 观测 | T001~T010 完成，295 用例全绿；真机验收清单已产出 |

---

## 5. 质量保障体系

- **测试**：XCTest 295 用例（294 passed + 1 known issue + 0 failed），基线**只增不减**；新增能力必有纯函数或替身可测面（门控穷举 / 性质断言 / 回退链三分支 / fixture 回归锚点）。
- **取证驱动修复**：真机导出产物（DOCX 逐行比对）→ 本地 Vision 同参 OCR 对照（证明「OCR 没丢词，是聚类拆散」）→ 几何数据固化为 `DialogueRowFixture` 等永久测试锚点。
- **日志观测**：`ZhixiaLog` 通道——geometry（FOV 比对）/ detectionTier（候选档位）/ relaxedLiveProbe（放宽档触发率）/ overlayProbeAnalytic+Delta（映射对照）/ suspiciousLock（门禁触发）。真机 Console 可检索，验收清单含对照步骤。
- **验证链**：模拟器全量测试 → 部署启动（pid 存活）→ generic 真机目标编译 → 真机人工验收清单（device-acceptance.md，SC-xxx 逐项勾选）。

---

## 6. 已知限制

1. **OCR 字符级混淆**（I/l/1、O/0、rn/m）：接受为已知限制（FR-012），不做自动改写——误改风险大于收益。
2. **曲边书页精确贴合**受矩形检测器物理上限约束：三级兜底显著提高命中率，但不保证曲边 100% 贴合；极端场景由预览四角调框兜底。
3. **真机合并单元格表格**：`realDeviceOcrStillLacksTable` 豁免测试——真机 OCR 输入在几何通路上仍出不了表（known issue 跟踪中）。
4. 低对比度 / 强反光 / 暗光场景检测置信度天然下降，引导提示可缓解但无法完全消除。

---

## 7. 后续优化方向

| 方向 | 内容 | 依据 |
|---|---|---|
| **曲面展平（dewarping）** | 折页厚书的曲边是矩形检测器的物理天花板；引入曲面文档矫正（网格变形 / 文档分割模型的稠密形变场），把「检出外框」升级为「展平后再裁」，同时提升 OCR 行几何质量 | live-edge-crop 已知限制 2 |
| **真机表格修复** | 排查真机 OCR 输入下表格几何通路（模拟器替身可通过、真机真实输入失败），消除 known issue 豁免 | 已知限制 3 |
| **OCR 后处理校正** | 词典 / 上下文置信度校正 I/l/1 等字符混淆（中文文本场景误改风险低，可仅对拉丁词启用） | 已知限制 1 |
| **性能与监控面板** | relaxedLiveProbe 触发率、布局引擎耗时、OCR 两轮成本的调试面板；长文档（100+ 页）的重建吞吐 | 观测通道已就绪 |
| **批量扫描体验** | 多页连拍（锁定即拍连击）、翻页节奏引导、会话内页序管理 | 拍摄链路成熟后的自然延伸 |
| **导出能力** | PDF 文本层质量提升、Markdown 导出（行几何已具备）、页面重排（reflow）模式 | 布局引擎产物的低成本复用 |
| **验收自动化** | 真机 XCUITest 冒烟（拍一页 → 导出 → 搜索），把 device-acceptance 中可自动化的部分固化 | 真机验收目前纯人工 |
| **（远期）云同步** | iCloud 文档同步 / 备份——需权衡纯离线定位与数据安全 | 路线图候选 |

---

## 8. 工程方法论注记

- **SDD 五阶段流程**（需求澄清 → 架构设计 → 任务拆解 → 实施子代理 → 验证子代理），每阶段评审门显式确认；任务清单带依赖图 / 并行标记 / 验证范围标记（build-only / build+ui）。
- **实施与验证分离**：实施子代理只做 T001~Tn-2（每个 Checkpoint 全量回归），验证子代理独立收尾构建/部署/逐故事验证——验证结论不与实施利益绑定。
- **真机验收闭环**：每个周期以 device-acceptance.md 收口，验收反馈直接开下一周期（layout-engine 验收暴露 R1~R7 → scan-fidelity；scan-fidelity 验收暴露折页书问题 → live-edge-crop）。
