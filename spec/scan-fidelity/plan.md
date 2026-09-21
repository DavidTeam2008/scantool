# Implementation Plan: scan-fidelity（扫描保真：还原缺陷修复 + 取景边框可靠性）

**Input**: Feature specification from `spec/scan-fidelity/spec.md`

## Summary

一轮修复两侧保真缺陷：**还原侧**——行级字号与行槽同源推导（消除行叠字）、行聚类改用垂直跨度重叠率判定（消除碎片块与乱序）、行分段空隙渲染下划线占位、重建流程回填全文搜索数据；**拍摄侧**——取景器边框映射重构为纯函数解析链（照片空间→视频空间→屏幕，摆脱对 `layerRectConverted` 元数据方向行为的依赖）+ 四角括号外压暗视觉升级 + 方向感知引导提示（带滞回）。所有几何/推导改动收敛为 Domain 纯函数，预览与导出共用同一推导源。

## Technical Context

**Language/Version**: Swift 5（Xcode 工程，iOS 17+ 目标）  
**Primary Dependencies**: SwiftUI、AVFoundation、Vision、SwiftData  
**State Management**: N/A（既有 `@Observable` MVVM 体系保持不变）  
**Storage**: SwiftData（`DocumentEntity.ocrSearchBlob` 既有字段，本轮只修回填链路）+ PageFileStore 文件  
**Testing**: XCTest（模拟器 `iPhone 17 Pro`，`xcodebuild test -project Zhixia.xcodeproj -scheme Zhixia`）  
**Target Platform**: iOS（真机 iPhone 13 验收）  
**Project Type**: mobile-app（既有工程增量修改）  
**Performance Goals**: 取景器 overlay 逐帧重绘不掉帧（单 Path 绘制，无新增逐帧分配热点）；还原侧改动不增加 parse 耗时（聚类 O 不变）  
**Constraints**: 纯离线；布局引擎既有能力（溢出阶梯/split/消解/表格模板字节不变）不回退；测试基线 255 passed + 1 known issue + 0 failed 只增不减；预览层 `videoGravity` 保持 `.resizeAspectFill` 且层铺满全屏 ZStack（D5 解析式前提，实施时以日志校验）；下划线占位仅依赖 `w:u` 标准行为（Word/QuickLook/Pages 均支持）  
**Scale/Scope**: 还原链 4 文件改造 + 拍摄链 4 文件改造 + 测试 4 个新文件

## Project Structure

### Documentation (this feature)

```text
/Users/tanwei/Documents/code/ios/scantool/spec/scan-fidelity/
├── spec.md              # 已完成（Phase 1）
├── plan.md              # 本文件
└── tasks.md             # Phase 3 产出
```

### Source Code (repository root)

```text
/Users/tanwei/Documents/code/ios/scantool/
├── Zhixia/
│   ├── Domain/
│   │   ├── OnDeviceReadingOrder.swift        # [改] sameRow 判定重写 + segments 采集
│   │   ├── Layout/
│   │   │   └── LayoutTypography.swift        # [改] 行级字号推导入口 + 分段空隙判定
│   │   ├── Models/
│   │   │   └── ReconstructDocument.swift     # [改] BlockLine.segments + LineSegment
│   │   └── OverlaySpaceMap.swift             # [新] 照片→视频→屏幕纯函数映射
│   ├── Services/
│   │   ├── Reconstruct/
│   │   │   └── DocxExportService.swift       # [改] 行段字号行级化 + 下划线占位 run
│   │   └── Camera/
│   │       └── CameraPreviewBinder.swift     # [改] 探针降级为诊断对照（映射真值改走解析式）
│   ├── Features/
│   │   ├── Reconstruct/
│   │   │   ├── LayoutCanvas.swift            # [改] 逐行渲染字号行级化 + 分段定位 + 空隙下划线
│   │   │   ├── ReconstructViewModel.swift    # [改] 识别全文暴露 + 完成回调
│   │   │   └── ReconstructView.swift         # [改] 完成回调接线 → applyOCRBlob
│   │   ├── Document/
│   │   │   └── DocumentView.swift            # [改] ReconstructView 回调装配
│   │   └── Capture/
│   │       ├── EdgeOverlayView.swift         # [改] 四角括号+外压暗+解析式映射
│   │       ├── CaptureViewModel.swift        # [改] 引导状态判定（滞回）暴露
│   │       └── CaptureView.swift             # [改] hint 文案映射 + overlay 入参
│   └── Localizable.xcstrings                 # [改] 新增 capture.hint.tooFar（zh/en）
└── ZhixiaTests/
    ├── OnDeviceReadingOrderRowClusteringTests.swift   # [新] 行聚合/分段/稳定性质
    ├── LineTypographyPerLineTests.swift               # [新] 行级字号/占位推导
    ├── OverlaySpaceMapTests.swift                     # [新] 映射解析链
    └── GuidanceDirectiveTests.swift                   # [新] 引导状态滞回
```

**Structure Decision**: 既有工程，沿用当前架构（Domain 纯函数 / Services 协议化 / Features MVVM），不引入目录重构。新增 1 个 Domain 纯函数文件（OverlaySpaceMap）与 4 个测试文件；其余为就地修改。

## Complexity Tracking

> 无 Constitution Check 违规——全部改动落在既有分层内。

## Research & Decisions

### D1 — 行级字号与行槽同源（FR-001 / US1 / 根因 R5）

**Decision**: 新增行级推导入口：行字号 = `clamp(行实测高 × 页高pt × 1.05, 7, 28)`（与既有 `fontPT(measuredLineHeight:)` 同族，输入从块中位行高换成该行实测高）。DOCX 行段的 `w:sz` 与预览逐行 Text 的字号都改走该入口；`w:line` exact 与 `resolvedLineFrames` 行槽维持实测。宽度封顶 `fittedFontPT` 与溢出估算 `estimatedRenderHeight` 的基准字号同步行级化（估算与渲染同字号）。无 `lines` 的回退段落路径不变（块级字号 + 预缩）。

**Rationale**: 叠字的充要条件是"字号 > 行槽"。行级同源后 `字号 = 行槽 × 1.05`（吸收系数 1.05，字号 ascent/descent 余量内），数学上不可能再叠；预览与导出共用同一入口，双端恒等是 layout-engine D4 约束的自然延伸。

**Alternatives considered**: ① 行距改从块级字号推导（w:line = 字号×1.2）——破坏"行距保真"（Word 每行一段可编辑的实测行距语义），且标题行与正文行同槽会压扁标题；② normAutofit 让 Word 自缩——上轮已否决（查看器普遍不支持）。

### D2 — 行聚类判定重写：垂直跨度重叠率（FR-002/003/005 / US2/US3 / 根因 R1/R2/R6）

**Decision**: `sameRow` 从「midY 差 < max(0.012, 0.3×h)」改为「y 跨度重叠 ≥ 0.5 × min(双方高度)」：`overlap = min(a.maxY, b.maxY) − max(a.minY, b.minY) ≥ 0.5 × min(a.height, b.height)`。聚类时来行与当前行的**并集 bbox** 做重叠判定；行内分段维持 minX 排序。段落聚类阈值（gap > 1.6×中位行高、缩进跳变 0.18）不变。

**Rationale**: 取证数据直接验证：同排异高分段（"yOu" h=0.0102 与 "the maths problems？" h=0.0176，基线一致）重叠率 ≈ 0.98 ≥ 0.5 ✓ 合并；相邻视觉行（行距 0.013、行高 ~0.015）重叠率 ≈ 0.34 < 0.5 ✓ 分行。现判定的两个失败模式（固定下限 0.012 误合相邻行、又漏掉 midY 偏移的同排分段）同源于"点比较"对高度差不鲁棒——"跨度重叠"对基线一致的高度差天然鲁棒，这也是 R6 稳定性的主要来源。

**Alternatives considered**: ① 调大/调小现阈值——取证数据显示固定下限在该页同时产生两类错误，无两全值；② 按基线（boundingBox 原点 y）聚类——Vision 的 bbox 原点受字形高低影响，与 midY 同样脆弱。

### D3 — 行分段模型与下划线占位（FR-004 / US2 / 根因 R3）

**Decision**: `BlockLine` 新增可选 `segments: [LineSegment]?`（`LineSegment { text, offset, width }`，offset 与 `leadingOffset` 同基准=块相对）；`blockLines(for:)` 从 `row.lines` 逐 OCR 分段采集。空隙判定与渲染：相邻分段间隙 ≥ 0.6 × 估算字符宽（`字号 × 0.6 / 页宽pt` 归一化）→ 占位 run；否则普通空格。DOCX 行段渲染为多 run：文本 run + 下划线空格 run（`<w:u w:val="single"/>`，空格数 = `round(空隙pt ÷ (字号 × 0.25))`，下限 2 上限 60，`xml:space="preserve"`）。预览在行帧内按分段 offset 定位各段 Text，空隙处画基线下划线矩形。

**Rationale**: 用户已确认下划线占位。下划线**空格**（w:u）优于字面 `_` 字符：视觉连续、Word 中可直接点击填入答案、宽度估算走空格单位与既有 `charUnits` 一致。可选字段保持旧存档 JSON 解码兼容（缺省 nil → 渲染走整行文本，行为不变）。

**Alternatives considered**: ① 字面下划线字符——字体渲染宽度不可控、混排时断续；② 空 gap 什么都不渲染——"缺词"体感仍在（本轮验收明确的负体验）。

### D4 — 重建流程回填搜索数据（FR-006 / US4 / 根因 R7）

**Decision**: `ReconstructViewModel` 暴露识别全文（`reconstructed.pages` 各块 text 以 "\n" 连接）与完成回调 `onContentReady`；`DocumentView` 装配时把回调接到既有 `DocumentViewModel.applyOCRBlob`（与手动 OCR 页同一条落库路径——含"标题含『扫描』才改写"的既有防覆盖语义）。重建失败（`hasContent == false`）不触发回调。

**Rationale**: `applyOCRBlob` 是已验证的落库+自动标题唯一实现，复用它保证两条流程行为一致；取证证实重建流程从未调用它（用户文档全部 blob 空 + 标题保持"扫描 · N"）。回调注入而非 ViewModel 直连 store，维持 Feature 层不碰持久化的既有边界。

**Alternatives considered**: ① 在 parser/service 层直接写 store——Service 无文档标题上下文且违反"解析纯、落库在 ViewModel"的既有分层；② 重建页面 onDisappear 时回填——离开即写，失败态也会误写半截内容。

### D5 — 边框映射重构为纯函数解析链（FR-008 / US5 / 根因：探针 API 行为不可依赖）

**Decision**: 新建 Domain 纯函数 `OverlaySpaceMap`：照片空间 quad → 屏幕坐标 = **照片→视频**（`FOVLayout` 逆换算，宽高比不同时 x 中心子区间映射）⊕ **视频→屏幕**（`.resizeAspectFill` 解析式放置：以 `geometry.videoAspect` 与 viewSize 计算，无 API 调用）。`EdgeOverlayView` 改以 `CaptureGeometry`（videoAspect+photoAspect）+ viewSize 走解析链为映射真值；`CameraPreviewBinder.overlayTransform`（`layerRectConverted(fromMetadataOutputRect:)`）**降级为诊断对照**——仅输出日志与解析式比对（复用既有 `ZhixiaLog.overlayProbe` 通道），不参与渲染。同时以回归测试固化坐标约定：检测器输出 y-down（`VisionEdgeDetector` 已 flipY）→ smoother → FOVLayout → overlay 全链不翻转。`photoEstimate ?? 1` 的恒等回退不可达（configure 后 activeFormat 必有值），仅加标注日志不动语义。

**Rationale**: 取证无法在静态分析下确证探针失效的具体形态（`layerRectConverted(fromMetadataOutputRect:)` 在无 metadataOutput/不同 iOS 版本下方向行为未定义；回退路径的归一化 aspect-fill 在 16:9 视频下有横向压缩误差）——但**渲染真值不该依赖一个行为未定义的 API**。预览层 videoGravity 固定 aspectFill、层铺满视图、`geometry` 由会话实测——解析式是确定性真值，且纯函数可全组合单测（0.5625/0.75/1 宽高比交叉）。诊断对照日志保留给真机验收核对（SC-004 证据链）。

**Alternatives considered**: ① 保留探针为真值、只修回退——真机上探针行为正是嫌疑本体，未消除不确定性；② 真机抓日志定位后再修——诊断依赖 sudo 日志权限（上次验收已受阻），且无论探针何种失效形态，解析式都是正确答案。

### D6 — 边框视觉升级：四角括号 + 外压暗（FR-007 / US5）

**Decision**: `EdgeOverlayView` 重绘：检测框外区域压暗（复用 idMask 的 reverseMask 手法，路径换成 QuadShape 填充黑 0.45）；四角 L 形粗括号（臂长 ≈ min(viewSize) × 3%，线宽 4pt，白色 + 轻微暗描边保证亮背景下对比）；状态区分：tracking=虚线整框（细）+弱压暗 0.25，locked=仅实线角括+压暗 0.45。证件模式 idMask 路径完全不变。

**Rationale**: 用户已确认四角括号+外压暗样式（iOS 系统扫描仪同款心智）。外压暗同时是"检测框位置"的强视觉锚点——即使边框线本身在复杂背景中不显眼，压暗边界也让用户立即看到检测区域；这也让映射修复的效果在真机上**可肉眼验收**。

**Alternatives considered**: ① 只加粗现有虚线整框——用户已明确不选；② 压暗 + 整框描边——边框线在书页纹理上易"消失"，角括集中于四角信息量最高。

### D7 — 方向感知引导提示（FR-009/010 / US6）

**Decision**: 新增 Domain 纯函数 `GuidanceDirective` 判定：输入（trackState, quad）→ 输出 `.backOff`（locked + 既有 suspicious 判定：面积 ≥ 0.95 或任一边距 < 0.015）/ `.closer`（locked + 面积 < far 阈值，**滞回**：进入 < 0.07、退出 > 0.09）/ `.locked` / `.searching`。`CaptureViewModel` 持有滞回状态并暴露 directive；`CaptureView.hintText` 映射四态文案（新增 `capture.hint.tooFar` 本地化 key，zh「靠近一点」/ en "Move closer"；既有 suspicious/locked/search 沿用）。自动快门抑制逻辑与 suspicious 判定共用既有阈值，不重复实现。

**Rationale**: 用户实拍反馈"该往前还是往后都只提示往后移"——现有三态文案缺"太远"分支。滞回是防闪烁的标准手法（面积比在阈值附近随持机抖动 ±10%，无滞回必然闪烁）。判定收敛为纯函数可穷举单测（含滞回穿越序列）。

**Alternatives considered**: ① 提示带具体偏移方向（左移/右移）——需要稳定的相对方位判定，误报率高且超出本轮反馈范围；② 无滞回直接比较——临界抖动导致文案反复翻转。

### D8 — 测试策略（SC-006）

**Decision**: 新增 4 个测试文件：① 行聚类（用取证页真实 OCR 分段几何做 fixture——108 行本地对照数据中的对话行样本，验证同排合并/相邻分行/三组扰动全过结构检查）；② 行级字号（异构行高块逐行字号 ≤ 行槽 × 1.05 的性质断言 + 下划线占位空格数换算 + 阈值两侧）；③ OverlaySpaceMap（0.5625/0.75/1 宽高比全交叉 + y-down 约定 + 视频满屏/裁切两种 viewSize）；④ GuidanceDirective（四态 + 滞回穿越序列 + suspicious 联动）。既有 `DocxRestoredLayoutTests` 的 w:sz 断言按行级化更新（基线计数只增不减）。

**Rationale**: 几何/推导全部纯函数化后，测试就是行为的可执行规格；取证数据转 fixture 让"练习册对话页"成为永久的回归锚点（R6 稳定性从"感觉"变成"断言"）。

**Alternatives considered**: 真机端到端自动化——超出本轮环境（无 XCUITest 基建），真机验收按 device-acceptance 清单人工执行。

## Data Model

- **LineSegment**（新增，`ReconstructDocument.swift`）: `text: String`、`offset: Double`（块相对归一化 x，与 `BlockLine.leadingOffset` 同基准）、`width: Double`（归一化宽）。Codable + Equatable + Sendable。
- **BlockLine**（扩展）: 新增可选字段 `segments: [LineSegment]?`——缺省 nil 保持旧存档解码兼容；有值时 `text` 仍为整行拼接文本（既有互切语义不变），segments 供定位渲染与空隙占位。
- **GuidanceDirective**（新增枚举，Domain）: `backOff / closer / locked / searching`，由纯函数从 (trackState, quad, 滞回状态) 推导。
- **CaptureGeometry**（既有，结构不变）: overlay 映射新增消费方（EdgeOverlayView 直接读取 videoAspect/photoAspect）。
- **ocrSearchBlob**（既有字段）: 回填链路新增触发点（重建完成），存储结构不变。

## Contracts & Interfaces

- **LayoutTypography**（扩展，纯函数）:
  - `lineFontPT(line: BlockLine, block: ReconstructBlock, pageHeightPT: Double) -> Double`——行级字号唯一入口（行实测高优先，退化回退块级推导）
  - `gapPlaceholderSpaces(gapWidthNormalized: Double, fontPT: Double, pageWidthPT: Double) -> Int?`——空隙 → 下划线空格数（nil = 普通空格）
- **OverlaySpaceMap**（新模块，纯函数）:
  - `screenQuad(fromPhotoQuad: Quad, geometry: CaptureGeometry, viewSize: CGSize) -> Quad`——屏幕坐标 quad（点单位）
  - `videoFramePlacement(geometry: CaptureGeometry, viewSize: CGSize) -> CGRect`——aspectFill 解析放置（诊断与映射共用）
- **GuidanceDirective**（新模块，纯函数 + 滞回状态）:
  - `evaluate(track: QuadTrackState, hysteresis: inout FarHysteresis) -> GuidanceDirective`
- **ReconstructViewModel**（扩展）:
  - `var recognizedTextBlob: String`（pages 块文本聚合）
  - `var onContentReady: ((String) -> Void)?`——`reconstruct()` 成功且 hasContent 时回调一次
- **CameraPreviewAttaching**（协议签名不变）: `overlayTransform` 实现降级为诊断日志源；`EdgeOverlayView` 的 `spaceProbe` 入参退役，改收 `CaptureGeometry`。
- **本地化**: 新增 key `capture.hint.tooFar`（zh: 「靠近一点」；en: "Move closer"）；其余沿用既有 key。
