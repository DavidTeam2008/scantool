# Implementation Plan: 版面还原（Layout Restore）

**Input**: Feature specification from `spec/layout-restore/spec.md`

## Summary

新增「版面还原」输出档位（默认选中，结构化档保留）：以矫正后整页原图为统一底座，文本/表格区域按块级 bbox 净化覆盖（填充色自适应）后原位重排，图画/艺术字/乱码区域新增 `.artwork` 块保留原像素，条码三通道交叉去重归一；预览（重写 LayoutCanvas）与 DOCX 导出（每页动态页面尺寸 + 底图衬底 + 浮动文本框 + srcRect 复用底图 + 浮动表格）共用同一坐标映射。底座与裁图全部迁出临时目录，根治导出缺图。

## Technical Context

**Language/Version**: Swift 6（Xcode 26.4.1，位于 `/Volumes/DevDisk/Applications/Xcode.app`，命令行需 `DEVELOPER_DIR` 指向该路径）
**Primary Dependencies**: Vision（OCR/结构化文档/条码）、CoreImage（像素采样/底座图）、SwiftUI（版面画布）、手写 OOXML + 自研 ZIP（DocxExportService 现状，零第三方依赖）
**State Management**: 沿用项目现状 @Observable（增量工作，不迁移）
**Storage**: 底座 = 已持久化的 rendered 图（PageFileStore 管辖）；figure 裁图从 temporaryDirectory 迁至 PageFileStore 文档级目录；ReconstructDocument 维持全内存不落盘（仅图片资源生命周期修复）
**Testing**: swift-testing（@Test/#expect）；`OTHER_SWIFT_FLAGS="-disable-sandbox"`；模拟器 iPhone 17 Pro；基线 **165 passed + 1 known issue（recorded an expected failure）+ 0 failed**
**Target Platform**: iOS 18+（结构化文档通路 iOS 26 优先、几何兜底维持）；仅 iPhone 竖屏
**Project Type**: 既有 iOS App 增量特性（Zhixia，约 98 Swift 文件 / 166 测试）
**Performance Goals**: 版面还原档复用同一次 parse 产物（不重跑检测）；切档只重渲染；预览底座下采样渲染；DOCX 导出每页仅引用一张底图（srcRect 裁剪，不重复嵌图）
**Constraints**: 离线承诺（无云/第三方依赖，TextIn stub 维持）；架构铁律（Feature 不碰 AVFoundation/CIFilter；Domain 无 I/O，像素读取循 InkFigureDetector 先例）；结构化档/PDF 导出/全文搜索零回归
**Scale/Scope**: 改动约 15 个文件（4~5 新增 + 10~11 修改），新增 5~6 个测试文件

## Project Structure

### Documentation (this feature)

```text
spec/layout-restore/
├── spec.md              # 需求规格（已评审通过）
├── plan.md              # 本文件
└── tasks.md             # Phase 3 产出
```

### Source Code (repository root)

```text
Zhixia/
├── Domain/
│   ├── Models/
│   │   ├── ReconstructDocument.swift     # [修改] R2OutputTier +restored −anchored −background；BlockKind +artwork；ReconstructPage +baseImageRelativePath
│   │   └── OCRPageText.swift             # [修改] OCRLine +confidence（默认 1.0，向后兼容）
│   ├── Layout/
│   │   ├── GarbledRegionDetector.swift   # [新增] 乱码区域双门控判定（置信度/质量 ∧ 墨块空间证据）
│   │   ├── LayoutMaskBuilder.swift       # [新增] 覆盖矩形 + 环带 median 填充色（读像素先例）
│   │   ├── LayoutMask.swift              # [新增] 覆盖区域值类型（rects + colors）
│   │   └── PageLayoutMapper.swift        # [新增] 原图归一化坐标 ↔ 画布/A4-动态页坐标纯映射（预览与 DOCX 共用）
│   └── Figure/
│       └── InkFigureDetector.swift       # [修改] 新增「被文字覆盖墨块」第二输出（figures 判据不变）
├── Services/
│   ├── Reconstruct/
│   │   ├── OnDeviceDocumentParser.swift  # [修改] 条码去重（去 barcodeFigures 通道/URL 并入）、.artwork 块产出、底座路径注入、裁图落盘迁移
│   │   ├── DocxExportService.swift       # [修改] 版面还原档分支：动态 sectPr + 底图衬底 + 覆盖 shape + 浮动文本框 + srcRect 浮动图 + 浮动表格
│   │   └── NormalizedImageCrop.swift     # [修改] 落盘目录参数化（tmp → PageFileStore 持久目录）
│   ├── OCR/
│   │   └── VisionTextRecognizer.swift    # [修改] 透传 Vision confidence 至 OCRLine
│   ├── Persistence/
│   │   └── PageFileStore.swift           # [修改] 提供 reconstruct 裁图持久目录（与文档生命周期一致）
│   ├── ServiceProtocols.swift            # [修改] R2OutputTier.selectable=[.restored,.structured]；默认 .restored
│   └── ZhixiaLog.swift                   # [修改] reconstruct 类目：tier/baseImage/mask/artwork/dedup
├── Features/
│   └── Reconstruct/
│       ├── ReconstructViewModel.swift    # [修改] 默认档位 .restored；切档不重跑 parse
│       ├── ReconstructView.swift         # [修改] 档位选择器恢复（两项）+ 版面还原画布接入
│       └── LayoutCanvas.swift            # [重写] 底座 + 覆盖层 + 元素原位渲染（文本/表格 overlay，图片/条码/艺术字透出底座）
└── Localizable.xcstrings                 # [修改] 档位名「版面还原」等条目（双语完整）

ZhixiaTests/
├── GarbledRegionDetectorTests.swift      # [新增] 双门控矩阵；正常文本零误杀；图上正常文字保留
├── LayoutMaskBuilderTests.swift          # [新增] 覆盖矩形生成/外扩；白纸页白底；带色底 median 填充
├── BarcodeDedupTests.swift               # [新增] figure/barcode/URL 三通道归一；单份表示断言
├── PageLayoutMapperTests.swift           # [新增] 归一化↔画布↔动态页面尺寸映射；恒等/往返/极端宽高比
├── DocxRestoredLayoutTests.swift         # [新增] OOXML 结构断言：sectPr 尺寸随原图、衬底、浮动文本框、srcRect、浮动表格、多页 section
└── 既有 ReconstructV2Tests / ReconstructTierTests / ExportSafetyTests 等   # [修改] 档位枚举迁移相关用例
```

**Structure Decision**: 遵循项目现有四层架构（App/Features/Domain/Services），不引入新分层或目录。新增 4 个 Domain 纯逻辑文件（判定/覆盖/映射/值类型）符合「算法进 Domain、副作用进 Services」铁律；LayoutCanvas 重写在原文件内（对外接口不变）；DocxExportService 增量加分支不动既有 .structured 渲染。

## Complexity Tracking

（无宪法级违规需要豁免——R2OutputTier 删除 `.anchored`/`.background` 两个从未对用户开放的 case 属死代码清理：ReconstructDocument 从不落盘、无持久化兼容问题，相关测试随枚举迁移。）

## Research & Decisions

### D1 · 档位模型：新增 `.restored` case，移除 `.anchored`/`.background` 死 case

- **Decision**: `R2OutputTier` 新增 `.restored`（版面还原），`selectable = [.restored, .structured]`，默认 `.restored`；删除从未对用户开放（`selectable` 只剩 `.structured`）的 `.anchored`/`.background`，其可复用 XML 部件（EMU 换算、y 翻转、锚定图结构）迁入新档实现。
- **Rationale**: ReconstructDocument（IR v2）从不编码落盘 → 删 case 无数据兼容风险；保留死 case 违背整洁且其语义与新档冲突（.anchored 只锚图片不锚文字，正是「竖排」根因之一）；ReconstructTierTests 的切档作废逻辑随枚举迁移。
- **Alternatives considered**: (a) 重定义 `.anchored` 语义——语义漂移误导后续维护；(b) 保留三 case 加第四个——死代码膨胀。

### D2 · 底座通道：IR 携带已持久化的 rendered 图路径，图片元素不落独立裁图

- **Decision**: `ReconstructPage` 新增 `baseImageRelativePath: String?`（指向 PageFileStore 已持久化的 rendered 图，与现有预览衬底同源）；版面还原档的图片/条码/艺术字元素**不生成独立裁图文件**——预览用底座 + 区域 clipping 透出，DOCX 用同一张底图 + `srcRect` 裁剪显示对应区域（每页 media 仅一张图）。结构化档的 figure 裁图维持现状但**落盘目录从 temporaryDirectory 迁至 PageFileStore 文档级持久目录**。
- **Rationale**: 底座本来就在持久位置（Application Support），无需新存储；srcRect 复用底图消除「同一图片存多份」与裁图丢失两类问题（FR-010）；结构化档裁图迁移根治存量隐患。
- **Alternatives considered**: (a) 每个图片元素裁独立文件——多份存储 + 生命周期又回到文件管理；(b) 底座图在导出时重新生成——parser 与导出间状态不必要耦合。

### D3 · 覆盖区域：块级 bbox 外扩矩形 + 环带 median RGB 填充

- **Decision**: 新增 `LayoutMaskBuilder`（Domain，读像素循 InkFigureDetector 先例）：对每个文本/表格块，覆盖矩形 = 块 bbox 外扩 1~2%；填充色 = bbox 环带（四周条带）像素的逐通道 median RGB（白纸页 → 白，带色底 → 局部底色）。`LayoutMask` 值类型输出（rects + colors），预览与 DOCX 共用。
- **Rationale**: 块级覆盖（而非行级）避免字迹缝隙残留——ReconstructBlock 已是行聚类后的块级 bbox；median 抗噪（字迹像素不主导）；逐通道 median 保留底色色相（彩色海报不退化成灰块）。
- **Alternatives considered**: (a) 固定白色填充——带底色页出现「白补丁」；(b) 行级覆盖——缝隙残留；(c) 修复式 inpainting——复杂度过高风险不可控。

### D4 · 乱码区域判定：置信度/质量 ∧ 墨块证据 双门控（保守）

- **Decision**: 新增 `GarbledRegionDetector`（Domain 纯逻辑）：候选区域 = 低信号文本行（Vision confidence 低于阈值 **或** OCRTextQuality 低于阈值）的空间聚类 ∩ `InkFigureDetector` 新增的「被文字覆盖墨块」区域；**双证据缺一不可**——仅低置信但无墨块（正常小字/生僻字）保留为文本，仅墨块但文字高置信（图上印的说明文字）保留为文本。判定成立的区域 → 文字行从文字层剔除 + 生成 `.artwork` 块（无独立裁图，渲染时透出底座）+ 不进覆盖 mask。
- **Rationale**: 用户痛点是乱码，但误杀正常文本更糟（spec FR-004 保守性）；`InkFigureDetector` 现有 maxTextCoverage=0.35 判据保留不动（正常 figure 检测不受影响），只是把「被拒绝的墨块」作为第二输出供判定复用；Vision 的 VNRecognizedText confidence 天然存在，只需透传。
- **Alternatives considered**: (a) 只用置信度单门控——生僻字/小字误杀风险高；(b) 只用墨块证据——图上正常文字被吞；(c) 神经网络区域分类——离线承诺内无可用端侧模型。

### D5 · 条码去重：`.barcode` 为唯一权威表示，figure 通道与 URL 降级并入

- **Decision**: `FigureRegionsV2.barcodeFigures` 通道**移除**（不再把条码 bbox 外扩输出为 figure）；URL 降级文本块若与已检条码 bbox 相交则并入该 `.barcode` 块的说明，不另出块；`.dedup` 范围扩展到 figure↔barcode 交叉（IoU > 0.5 或包含即去重）。版面还原档中条码区域不覆盖（透出底座）+ `.barcode` 块承载 payload 元数据。
- **Rationale**: 条码三份表示的根因是三通道各自为政；`DetectedBarcode` 是语义最完整的表示（有 payload）；版面还原档中「视觉一份 + 元数据一份」天然成立。
- **Alternatives considered**: (a) 只加交叉去重不动通道——治标，barcodeFigures 通道本身已无存在价值；(b) 保留 figure 份裁图——版面还原档 srcRect 已覆盖该需求。

### D6 · 预览渲染：LayoutCanvas 重写为「底座 + 覆盖层 + 原位元素」

- **Decision**: `LayoutCanvas` 重写（对外接口不变）：ZStack 三层——底座 Image（aspect-fit，下采样）→ LayoutMask 覆盖矩形层 → 元素层（文本块按 bbox 原位渲染，字号沿用 relativeFontSize 映射先例；表格原位绘制；figure/barcode/artwork **不绘制**，底座透出即视觉呈现）。坐标经 `PageLayoutMapper` 纯函数（归一化 bbox ↔ 画布空间），切档不重跑 parse 只重渲染。
- **Rationale**: 三层模型与 DOCX 渲染同构（同一 LayoutMask/同一 Mapper），预览即所得；图片区域「不绘制」是最可靠的保真（零重采样失真）。
- **Alternatives considered**: (a) 沿用旧 B/C 档画布增量改——旧画布无覆盖层/文本原位概念，重写更干净；(b) 图片区域画裁剪副本——多余且可能对不齐。

### D7 · DOCX 版面还原：每页动态 sectPr + 底图衬底 + 浮动文本框 + srcRect 浮动图 + 浮动表格

- **Decision**: 版面还原档 DOCX 结构：每页独立 `sectPr`（页面宽高比随原图，映射退化为纯线性缩放，保真最优）→ 底图 `behindDoc` 衬底（复用既有 backgroundDrawingXML 部件，改用 baseImageRelativePath）→ 覆盖矩形浮动 shape（LayoutMask）→ 文本块浮动文本框（`wp:anchor` + `wps:wsp/wps:txbx`，内含普通段落，可编辑）→ 图片元素浮动图（复用 anchoredDrawingXML + `a:srcRect` 按区域裁剪同一底图）→ 表格浮动（`w:tbl` + `w:tblpPr` 原生浮动表格定位，不套文本框）。EMU 换算与 Vision y 翻转复用既有已修复部件。
- **Rationale**: 动态页面尺寸消除 A4 定死导致的黑边/留白（多页不同宽高比 → 多 section，OOXML 原生支持）；浮动表格是 OOXML 原生能力，比文本框套表格可靠；文本框内是真实段落 → 满足「文字可编辑」（FR-007）。
- **Alternatives considered**: (a) 固定 A4 + aspect-fit 映射——留白边、保真降级；(b) 表格截图成图片——丢失可编辑性；(c) 文字保持段落流——即旧 .anchored 方案，正是竖排根因，已否决。

### D8 · 模型与协议变更面（最小化）

- **Decision**: `DocxRendering`/`DocumentParsing` 协议签名**零变更**（底座路径在 IR 内流动）；变更收敛为：`R2OutputTier`（D1）、`ReconstructBlockKind` +artwork、`ReconstructPage` +baseImageRelativePath、`OCRLine` +confidence（默认 1.0 向后兼容——既有夹具/测试无需改）、`InkFigureDetector` 输出扩展、`PageFileStore` +裁图持久目录、`FigureRegionsV2` −barcodeFigures。
- **Rationale**: 协议不动 = 测试替身与 DI 容器零波及；OCRLine 用默认值避免 165 条基线大面积改写。
- **Alternatives considered**: (a) DocxRendering 加底座参数——IR 内流动更内聚；(b) OCRLine 加 optional——默认值更 Swift 惯用。

### D9 · 性能与内存：一次 parse 双档渲染；预览下采样；导出原图

- **Decision**: parse 一次产出双档共用的块集合（.artwork 等新块对结构化档无害——结构化档忽略 artwork 块或按图处理）；切档仅重渲染；预览底座用下采样位图（目标 ≈ 屏幕点数 × scale），DOCX/PDF 导出引用持久化原图。底座下采样与像素采样均循 Domain 读像素先例，不引入新 I/O 边界。
- **Rationale**: FR-011 不阻塞 UI；大图整页位图是内存大头（4:3 4032×3024 ≈ 46MB 解码后），下采样到屏显级别可控。
- **Alternatives considered**: (a) 每档独立 parse——重复计算无必要；(b) 预览也用原图——iPhone 上多页文档内存不可控。

### D10 · 诊断日志（reconstruct 类目）

- **Decision**: `ZhixiaLog` 新增 reconstruct 类目结构化条目：`tier(...)`（档位与切换）、`baseImage(...)`（路径与尺寸）、`mask(...)`（覆盖矩形数与填充色采样）、`artwork(...)`（乱码区域判定结果：行数/墨块证据/双门控值）、`dedup(...)`（条码去重前后计数）。仅日志，无行为分支。
- **Rationale**: 真机验收（SC-001/002）与乱码判定阈值调优依赖这些数值；判定是本轮最大的启发式风险点，可观测性优先。

## Data Model

- **R2OutputTier**（修改）：`.restored`（版面还原，默认）+ `.structured`（现状保留）；`selectable = [.restored, .structured]`；删除 `.anchored`/`.background`。
- **ReconstructBlockKind**（修改）：新增 `.artwork`（无法识别为纯文本的保留区域：艺术字/手绘字/图画/图章）；`.figure`/`.barcode` 语义不变。
- **ReconstructPage**（修改）：新增 `baseImageRelativePath: String?`（底座，PageFileStore 相对路径；nil = 无底座，画布退化纯白底渲染）。
- **ReconstructBlock**（不变）：既有字段完全保留；`.artwork` 块复用 bbox/kind，无文本无独立裁图路径。
- **OCRLine**（修改）：新增 `confidence: Double`（默认 1.0）；坐标系与既有约定不变（Vision 归一化、原点左下）。
- **LayoutMask**（新增，Domain/Models 或 Layout/）：不可变值类型——覆盖矩形数组 + 逐矩形填充色（RGB）；Sendable + Equatable。
- **GarbledRegionJudgement**（新增，判定产物）：判定成立的区域集合 + 每区域的双门控证据值（供日志与测试断言）。
- **PageLayoutMap**（新增，PageLayoutMapper 产物）：归一化坐标 ↔ 目标空间（画布像素 / DOCX EMU）的线性映射参数（缩放 + 偏移 + y 翻转标记）；纯值类型可逆。
- **InkFigureDetector 输出**（扩展）：既有 figures 判据不变；新增「被文字覆盖墨块」区域列表（供 GarbledRegionDetector 复用）。
- **持久化语义**：Quad/PageDraft/ScanPage/DocumentEntity 均不变；figure 裁图迁至 PageFileStore 管辖目录（与文档同生命周期）。

## Contracts & Interfaces

> 签名按接口契约记录；不含实现逻辑。

### 协议层（ServiceProtocols.swift）

| 协议 | 变更 | 契约 |
|---|---|---|
| `DocxRendering` | 不变 | 仍收 `ReconstructDocument`；实现内按 `R2OutputTier` 分派 `.restored`/`.structured` 渲染 |
| `DocumentParsing` / `DocumentStructureRecognizing` / `TextRecognizing` / `BarcodeDetecting` | 不变 | — |
| `R2OutputTier` | 枚举变更 | `.restored` + `.structured`；`selectable = [.restored, .structured]`；默认值 `.restored` |
| 其余协议 | 不变 | — |

### 模块接口（新增/修改）

| 模块 | 入口契约 |
|---|---|
| `GarbledRegionDetector` | `detect(lines: [OCRLine], inkRegions: [CGRect]) -> GarbledRegionJudgement`：双门控判定；保守性（高置信行永不剔除）由单测钉死 |
| `LayoutMaskBuilder` | `build(blocks: [ReconstructBlock], baseImage: CGImage) -> LayoutMask`：文本/表格块 → 外扩矩形 + 环带 median 填充色；读像素循 InkFigureDetector 先例 |
| `PageLayoutMapper` | `map(for pageSize: CGSize, targetSize: CGSize) -> PageLayoutMap`：归一化 bbox ↔ 目标空间坐标；y 翻转集中在此；恒等/可逆单测覆盖 |
| `InkFigureDetector` | 既有入口不变；输出结构扩展「被文字覆盖墨块」列表 |
| `DocxExportService`（.restored 分支） | 输入 ReconstructDocument；每页：动态 sectPr + 底图衬底 + 覆盖 shape + 浮动文本框（可编辑段落）+ srcRect 浮动图 + `w:tblpPr` 浮动表格；escape/控制字符清洗复用既有 |
| `PageFileStore` | 新增 reconstruct 裁图持久目录（文档级，随文档生命周期） |
| `ReconstructViewModel` | 默认档位 `.restored`；切档不重跑 parse；底座路径注入 parse 产物 |

### UI 契约

- `ReconstructView`：档位选择器恢复渲染（两项：版面还原/结构化），版面还原默认选中；导出按钮语义不变（DOCX 按当前档位渲染）。
- `LayoutCanvas`（重写，对外接口不变）：底座 aspect-fit → 覆盖层 → 元素原位层；figure/barcode/artwork 区域不绘制（底座透出）；文本字号沿用 relativeFontSize 映射先例。
- `Localizable.xcstrings`：档位名「版面还原」/ "Restored Layout" 等条目双语完整，不留空条目。

### 诊断契约

- `ZhixiaLog.reconstruct` 结构化条目：`tier` / `baseImage` / `mask` / `artwork` / `dedup`（D10）。仅日志，无行为分支。

### 测试契约（新增测试文件）

| 文件 | 覆盖 |
|---|---|
| `GarbledRegionDetectorTests` | 双门控矩阵（低置信+墨块→artwork；仅低置信→保留文本；仅墨块+高置信→保留文本）；正常文本零误杀；区域聚类合并 |
| `LayoutMaskBuilderTests` | 白纸页→白填充；合成带色底→median 色近似；矩形外扩不越页界；图片/条码/artwork 区域不进 mask |
| `BarcodeDedupTests` | figure↔barcode 交叉去重；URL 文本并入；单份表示断言（计数==1） |
| `PageLayoutMapperTests` | 归一化↔画布/EMU 映射数值断言；y 翻转；恒等；极端宽高比；可逆 |
| `DocxRestoredLayoutTests` | OOXML 结构断言：sectPr 宽高随原图；每页独立 section；底图 behindDoc；浮动文本框存在且含段落；图片引用同一底图 + srcRect；表格 tblpPr 定位；控制字符清洗不回归 |
| 既有套件迁移 | `ReconstructTierTests`/`ReconstructV2Tests`/`DocumentStructureTests`/`ExportSafetyTests` 中引用 `.anchored`/`.background`/barcodeFigures 的用例随 D1/D5 迁移；结构化档导出断言保持原样（零回归证明） |

### 构建与验证命令（本机）

```bash
export DEVELOPER_DIR=/Volumes/DevDisk/Applications/Xcode.app/Contents/Developer
OTHER_SWIFT_FLAGS="-disable-sandbox" xcodebuild test \
  -project Zhixia.xcodeproj -scheme Zhixia \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -skipPackagePluginValidation -skipMacroValidation
```

（基线 **165 passed + 1 known issue**（recorded an expected failure）+ 0 failed；模拟器条码恒空 → 条码相关断言依赖注入替身 + 真机验收；`xcrun simctl erase all` 应对模拟器 Busy。）
