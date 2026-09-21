# Implementation Plan: 版面布局引擎（Layout Engine）

**Input**: spec/layout-engine/spec.md（US1~US5 / FR-001~012 / SC-001~006）；诊断报告（layout-restore 真机验收缺陷，根因 1~7 已定位至 file:line）

## Summary

在解析层组装点（`OnDeviceDocumentParser` 装配处）挂载**确定性区域布局引擎**：跨栏宽行拆分 → 块间碰撞消解（阅读序让位）→ 溢出阶梯（布局期缩放/扩展 + 渲染期兜底），并以**共享排版度量模块**统一字号/行距推导（实测 medianH 校准、双端钳制基准合一）。行几何（行高/行距/行首偏移）随块上 IR：预览逐行定位渲染、Word 每行一段精确行距（可编辑）。表格接回实测列宽并加行高封顶。预览/DOCX/mask 三方消费同一份布局后 blocks，自动同构。**零扰动不变量**：无冲突简单页上引擎为恒等映射，既有断言与观感零变化。

## Technical Context

**Language/Version**: Swift 5.x / SwiftUI（Xcode 26.4.1，`/Volumes/DevDisk/Applications/Xcode.app`）
**Primary Dependencies**: Vision（iOS 26 RecognizeDocumentsRequest 结构化通路 + VisionTextRecognizer/TableGridV2Detector 几何回退）、SwiftUI Canvas
**State Management**: 既有 MVVM 分层（Feature/Domain/Services）；引擎为 Domain 纯函数，无状态
**Storage**: PageFileStore（文档级持久目录，本特性不新增存储；IR Optional 字段向后兼容旧数据）
**Testing**: XCTest via xcodebuild；基线 **212 passed + 1 known issue（`recorded an expected failure`）+ 0 failed**
**Target Platform**: iOS（iPhone 主力；模拟器 iPhone 17 Pro 跑测试）
**Project Type**: mobile-app（既有工程增量，非 HarmonyOS——**禁止使用任何 HarmonyOS 工具**）
**Performance Goals**: 布局引擎额外耗时 ≤ 100ms/页（FR-011，实际按 10 倍余量设计）；预览无可感知卡顿
**Constraints**: 纯离线；ServiceProtocols 协议签名零变更；布局解析层一次完成、渲染层只消费（切档不重跑 parse 不变）；结构化档/可搜索 PDF/全文搜索零回归
**Scale/Scope**: 页均块数 ≤ ~100；块内行数 ≤ ~50；单文件增量 < 400 行

**构建命令**（实施与验证均用此命令）：

```bash
export DEVELOPER_DIR=/Volumes/DevDisk/Applications/Xcode.app/Contents/Developer
# 全量测试（检查点必须全量；快速迭代加 -only-testing:ZhixiaTests/<Suite>）
OTHER_SWIFT_FLAGS="-disable-sandbox" xcodebuild test -project Zhixia.xcodeproj -scheme Zhixia -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -skipPackagePluginValidation -skipMacroValidation
# 真机可部署性（无签名环境必须带 CODE_SIGNING_ALLOWED=NO）
xcodebuild build -project Zhixia.xcodeproj -scheme Zhixia -destination 'generic/platform=iOS' -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

- 模拟器 Busy：稍候重试或 `xcrun simctl erase all`
- 模拟器条码检测恒空（既有约定不变）；新增 .swift 文件自动入编译（pbxproj 为 PBXFileSystemSynchronizedRootGroup，objectVersion 77）

## Project Structure

### Documentation (this feature)

```text
spec/layout-engine/
├── spec.md               # 需求（已过评审）
├── plan.md               # 本文件
└── tasks.md              # /spec-tasks 产出
```

### Source Code (repository root)

```text
Zhixia/Domain/Layout/
├── RegionLayoutEngine.swift        # 【新增】区域布局引擎：宽行拆分/碰撞消解/溢出估算（纯函数）
├── LayoutTypography.swift          # 【新增】共享排版度量：实测行高→字号/行距/钳制（纯函数，预览与 DOCX 共用）
├── PageLayoutMapper.swift          # 既有（坐标底座，零改动）
├── LayoutMask.swift                # 既有（零改动自动同构）
├── LayoutMaskBuilder.swift         # 既有（零改动自动同构）
├── GarbledRegionDetector.swift     # 既有（零改动）
├── LayoutAnalyzer.swift            # 既有（medianLineHeight/columns 复用其产物）
└── LayoutTypes.swift               # 既有（PageLayout 承载页级实测度量）
Zhixia/Domain/Models/
├── ReconstructDocument.swift       # 修改：+BlockLine / +lines / +measuredLineHeight / +columnRatios
└── OCRPageText.swift               # 既有（OCRLine 为行几何源头，零改动）
Zhixia/Services/Reconstruct/
├── OnDeviceDocumentParser.swift    # 修改：挂载引擎、page.layout 赋值、装配顺序
├── OnDeviceReadingOrder.swift      # 修改：行聚类时采集行几何上块（Row.lines→BlockLine）
├── DocxExportService.swift         # 修改：行段渲染/统一字号函数/normAutofit/表格 tblGrid+trHeight
└── NormalizedImageCrop.swift       # 既有（零改动）
Zhixia/Services/OCR/
└── VisionDocumentStructureRecognizer.swift  # 修改：flatten 时提取 columnRatios（不再丢弃列边界）
Zhixia/Features/Reconstruct/
├── LayoutCanvas.swift              # 修改：块内逐行渲染/minimumScaleFactor/表格实测列宽
├── ReconstructViewModel.swift      # 既有（零改动——切档不重跑 parse 不变）
└── ReconstructView.swift           # 既有（零改动）
Zhixia/Services/
└── ZhixiaLog.swift                 # 修改：+reconstruct layout 类目条目
ZhixiaTests/
├── RegionLayoutEngineTests.swift   # 【新增】消解/拆分/阶梯/确定性/恒等性
├── LayoutTypographyTests.swift     # 【新增】实测推导/兜底/钳制统一
├── DocxRestoredLayoutTests.swift   # 扩展：行段 spacing/ind 数值、autofit、表格几何断言
├── ReconstructTests.swift          # 既有 join 断言保持（行上块不改文本拼接）
└── （其余既有套件全部保持原样 = 零回归证明）
docs/09-project-handbook.md         # 修改：布局引擎章节
```

**Structure Decision**: 遵循既有 MVVM 分层架构（Feature/Domain/Services），不引入新分层与新目录。引擎与排版度量入 `Domain/Layout/`（与 PageLayoutMapper/LayoutMaskBuilder 同域，纯函数、无 I/O，读像素先例不需要——本特性不读像素）。新增仅 2 个源码文件 + 2 个测试文件，其余全部为既有文件定点修改。

## Complexity Tracking

无宪法违规（不新增项目/目录/分层；2 个新文件均为单一职责纯函数模块）。

## Research & Decisions

> 依据：诊断报告（explore 会话 ses_f4b4b8b4effeqLJeLJ5HBi5p8f，全部结论带 file:line 证据）。

### D1 引擎挂载点与纯函数边界

- **Decision**: 引擎为 `Zhixia/Domain/Layout/RegionLayoutEngine.swift` 纯函数模块，挂载于 `OnDeviceDocumentParser` 装配点（`assemble` 之后、`ReconstructPage` 构造之前，即 OnDeviceDocumentParser.swift:216 一带）。输入：布局前 blocks + 页级实测度量（PageLayout：medianLineHeight/columns）+ 页尺寸；输出：布局后 blocks + `LayoutReport`（消解/拆分/阶梯统计，仅日志不持久化）。无 I/O、无随机、无时钟——同输入同输出（FR-010）。
- **Rationale**: 诊断 F1 确认该位置是唯一能让预览（map.rect(block.bbox) + mask 从 blocks 构建）、DOCX（同一 map.rect → txbx/tblpPr/srcRect）、mask（LayoutMaskBuilder.build(blocks:)）三方自动同源的位置；下游全部只读 `page.blocks`。
- **Alternatives considered**: ①渲染层各自消解——复刻 y 翻转散落、posOffset 误用的历史事故模式（PageLayoutMapper.swift:5-7 注释、handbook §6.7 #4）；②VM 层——行数据已不可得；③ReadingOrder 内——只见单栏行，见不到表格/figure，无法跨种类消解。

### D2 跨栏宽行治理（引擎上游 normalize）

- **Decision**: 两级防御。①行聚类层（`OnDeviceReadingOrder`）：sameRow 合并增加栏约束——两碎片 midX 间距超过栏宽判定阈值时不合并（利用 `LayoutAnalyzer` 的 columns 产物；分栏器未切刀但 bands 检出双栏时抑制跨栏合并）；②引擎层：残余的"块宽 > 版心 70% 且成员行 midX 双峰"宽块按栏确定性拆分为两块。拆分只在版面还原档生效（结构化档块构造不变）。
- **Rationale**: 宽块文本是两栏内容的串接（OnDeviceReadingOrder.swift:60, 133-136 join），重排必然横向大范围错位（诊断 B3；PageColumnSplitter.swift:6-12 文档注释正是此场景）；上游抑制治本，引擎拆分兜底治残余。
- **Alternatives considered**: ①只做引擎层拆分——行已串接，拆分依据弱化且文本切分易错；②放宽 PageColumnSplitter 支持多刀——动既有分栏器风险大，本轮不动；③维持现状——双栏页必然错位。

### D3 数据模型扩展（IR 向后兼容，Optional 先例）

- **Decision**: 
  - `ReconstructBlock` + `lines: [BlockLine]?` 与 `measuredLineHeight: Double?`（块级实测中位行高）
  - `BlockLine` 值类型：`text / height / gapToPrevious / leadingOffset`（全归一化；leadingOffset = 行 minX − 块 minX）
  - `ReconstructTable` + `columnRatios: [Double]?`（实测列宽比例，和为 1）
  - `ReconstructPage.layout` 赋值（字段已存在且从未被赋值——诊断 E；`PageLayout.medianLineHeight` 已 Codable）
  - `ReconstructPage` + `restoredBlocks: [ReconstructBlock]?`（**布局后块集**：承载拆分/位移/扩展结果；nil = 退化用 blocks。版面还原档渲染与 mask 消费 `restoredBlocks ?? blocks`，结构化档读 blocks——**拆分与位移对结构化档零扰动**的结构保证，FR-012 落点）
  - 全部 Optional 默认 nil：旧持久化数据、既有夹具、既有测试零破坏
- **Rationale**: IR v2 Optional 字段是既定兼容模式（ReconstructDocument.swift:60-64 注释先例）；medianH 目前三处算出即弃（OnDeviceReadingOrder.swift:7、OnDeviceDocumentParser.swift:390-391、LayoutAnalyzer.swift:20），本次收敛到 `PageLayout` 一处持久化、块级一份精化；restoredBlocks 是"双档共享 page.blocks"与"结构化档零回归"同时成立的唯一干净解（拆分若直接替换 blocks 会改变结构化档分段，破坏 ReconstructTests 钉死的 join 断言）。
- **Alternatives considered**: 新版 IR 结构体替换——迁移成本高且无语义收益。

### D4 字号与行距统一推导（共享排版度量模块）

- **Decision**: 新增 `Zhixia/Domain/Layout/LayoutTypography.swift` 纯函数集：
  - `fontPT(measuredLineHeightNormalized:pageHeightPT:)`：字号 = 实测行高 × 页高pt × 吸收系数（≈1.05，吸收 OCR 行框含上下伸部），**钳制基准统一为文档页 pt**、区间 [7, 28]pt；预览换算 = 同一 pt 值 ÷ 画布缩放，DOCX 直接用——同一函数两个空间，根除钳制基准不一致（诊断 D4）
  - 行距：实测行高主导（渲染行距 = 实测行高 − 字号标称行高，负值取 0）；无实测数据的块回退页高 1.8% 常数（现状公式兜底）
  - `relativeFontSize` 语义重定义：从档位常数 {1, 1.4} 改为"块实测行高 ÷ 页中位行高"的实测缩放系数（标题判定启发式保留，但字号始终走实测）；heading 样式（bold/Heading1）不变
  - 预览（LayoutCanvas.swift:26, 125-127）与 DOCX（DocxExportService.swift:438-445）两处本地公式全部删除，改调共享函数
- **Rationale**: 根因 1（字号从不实测）+ 根因 6（钳制基准不一致——预览钳画布 pt、Word 钳页 pt，照片页 Word 标题被钳至与正文同大）；两处分散公式是结构性缺陷，收敛为单一可测试函数。
- **Alternatives considered**: 各渲染器分别改公式——重演不一致；保留常数仅调系数——密集页放大 1.5~1.8 倍问题不解决。

### D5 碰撞消解算法（规则式、确定性、阅读序让位）

- **Decision**: 引擎消解管线（固定顺序、迭代上限 4 轮）：
  1. **收集**：实心块 = text + table；figure/barcode/artwork 为"透出区"不参与让位（FR-002 说明字例外语义）
  2. **两两相交检测**（O(n²)，n ≤ ~100）：按阅读序（assemble 顺序，OnDeviceDocumentParser.swift:315-320）处理冲突对
  3. **让位规则**：后序块让位，方向 = 沿 Y 轴向"与相交块相反一侧"平移最小距离（上块向上收底边/下块向下移顶边；text-table 相交 text 让位；table-table 后序让位）；平移越页界 → 改为收缩自身高度；table-figure 相交 → **figure 区域收缩剔除相交部分**（表格 bbox 来自 iOS 26 结构化识别、可信度高；收缩量记入日志）——双方内容均不丢失
  4. **链式传播**：让位后产生的新相交继续按同规则消解，至不动点或迭代上限
  5. **页界夹取**：所有区域夹回页内
- **Rationale**: OCR bbox 已是良好初始解，规则式微调即可——不需要区域重分配；"上方内容优先原地 + 后序让位"符合还原语义；**零扰动不变量**：无冲突输入 → 恒等映射（简单页既有观感与数值断言零变化）；确定性使每条规则可被独立单测。
- **Alternatives considered**: ①guillotine/bin-packing 区域重分配——过度工程且大改观感；②先序块让位——上方内容漂移，违背"原位还原"；③相交即剔除文本（并入表格）——文字丢失风险，被 FR-006 否决。

### D6 溢出阶梯（布局期估算 + 渲染期兜底双层）

- **Decision**:
  - **布局期**（引擎内）：块渲染高度估算 = max(Σ实测行高, 字号下限 × 行数 × 行距系数) × 宽度换行因子（按块宽与实测行宽估算换行增量，保守放大）；超出区域时依序：①等比缩字号/行距至下限（7pt）②区域向下扩展吸收空白带（扩展量 = 到下方最近实心块/页底的间隙；扩展后该块重入消解管线）。估算依赖的吸收系数/换行因子参数化，单测钉死
  - **渲染期兜底**：预览文本行容器加 `minimumScaleFactor`（SwiftUI 原生缩放至放得下）；Word txbx `<a:bodyPr>` 增加 `<a:normAutofit>`（Word 原生自动缩放）。两端语义同为"缩到放得下"，双端均不裁剪文字
  - **极端情形**（下限字号 + 空白带耗尽仍不足）：保持文字完整不截断，结构化日志记录（FR-006）
  - **风险注记**：`normAutofit` 在 Word 首次打开时的自动缩放行为需实施期实测验证；若 Word 不主动缩放，则回退为"布局期把预估缩放直接写入 w:sz"（布局期估算已尽力精确，此为等价兜底），双端仍同构
- **Rationale**: 字体度量只有渲染时才精确可得，单层布局期估算必然漏；双层设计 = 布局期保证 mask/区域同构，渲染期保证最终不溢出。min 截断被用户决策明确否决（文字完整优先）。
- **Alternatives considered**: ①仅布局期估算——精度不足必漏；②仅渲染期兜底——mask 与区域不同构，重叠回归。

### D7 行级渲染（预览逐行定位、Word 每行一段）

- **Decision**:
  - **预览**（LayoutCanvas）：有 `lines` 的块改为块内逐行渲染——每行独立 `Text`，y = 块内累积实测行高（前一行 y + gapToPrevious + height），x = 块 minX + leadingOffset，字号/行距走 LayoutTypography；块仍是单元素（单 mask 矩形、单 txbx 语义不变）
  - **Word**（DocxExportService）：有 `lines` 的块 txbx 内**每行一个 `<w:p>`**：`<w:spacing w:line="实测行高×20 twips" w:lineRule="exact"/>` + `<w:ind w:left="leadingOffset×页宽dxa"/>`，段前段后 0——保行距与行首位置，且是可编辑普通段落（FR-005）
  - 无 `lines` 数据的块（旧数据/兜底路径）回退现有单段渲染——行为不劣化
  - 既有 `ReconstructTests.swift:43-53` 钉死的行 join 文本行为**不变**（行上块只附加几何，不改拼接文本）
- **Rationale**: US3 澄清决策（行几何保真，禁 Word 逐行浮动 shape）；SwiftUI `lineSpacing` 无法逐行控制，预览逐行定位是唯一精确方案；Word 精确行距 + 行首缩进以最小 OOXML 成本保真。
- **Alternatives considered**: ①块级重排 + 实测行距——行首偏移丢失，水平漂移仍在；②Word 逐行 txbx——shape 数暴涨（数百行=数百框），编辑体验崩坏，已被用户决策否决。

### D8 表格几何（实测列宽 + 行高封顶）

- **Decision**:
  - **列宽上 IR**：`VisionDocumentStructureRecognizer.flatten`（:141-171）提取 columnRange 的列边界 → `columnRatios`（归一化比例），不再丢弃；几何回退通路无列信息 → nil
  - **Word**：`<w:tblGrid><w:gridCol>` 按 columnRatios 分配总宽（dxa，nil 时均分兜底）；行高默认 `<w:trHeight w:hRule="exact">` = 表格区域高 ÷ 行数（**封顶**，根因 5 的 Word 下坠修复）；单元格字号按实测列宽自适应（共享函数，下限 7pt）；某行内容放不下时**该表行高整体转 `atLeast` 增长**并记日志——预览网格同步增长（双端同构，FR-008），文字不截断
  - **预览**（canvasTable）：网格列宽按 columnRatios 绘制；行高均分逻辑保留；cellFont 自适应保留；`.clipped()` 仅在字号已到下限时兜底（正常路径内容经布局期估算已放得下）
- **Rationale**: 行高封顶消除 Word 无界增长下坠压块（诊断 C2 表格行）；列宽实测消除"均分导致窄列截断"；exact→atLeast 升级链在"封顶"与"文字完整"（用户决策）间取得确定性平衡；合并单元格 gridSpan/vMerge 本轮不做（spec Assumption，维持首格归并现状）。
- **Alternatives considered**: ①恒 atLeast——不封顶，下坠回归；②恒 exact——截字违反 FR-006/008；③全做合并单元格——模型扩展大，收益面窄，留待下轮。

### D9 mask 与保留区自动同构

- **Decision**: mask（LayoutMaskBuilder.build(blocks:)）与 DOCX 保留区（srcRect）继续从布局后 blocks 构建，**代码零改动自动同构**；FR-003"覆盖实际渲染范围"由 D6/D7 保证（行几何渲染范围 ⊆ 布局区域）；mask 外扩 1.5% 保留。
- **Rationale**: 诊断 F1——引擎在块进页之前改好 bbox，mask 自动跟随；渲染范围被溢出阶梯约束在区域内，mask=bbox 即覆盖。
- **Alternatives considered**: mask 改为按渲染范围构建——引入渲染期反馈依赖，破坏解析层一次完成的架构不变量。

### D10 布局日志

- **Decision**: `ZhixiaLog.reconstruct` 新增 layout 类目：让位计数与总平移量、跨栏拆分数、溢出阶梯触发（缩放/扩展/极端各计一次）、表格行高策略切换（exact→atLeast）、figure 收缩量。debug 级，与既有 tier/baseImage/mask/artwork/dedup 并列。
- **Rationale**: FR-006/FR-011 可观测性；沿用 device-acceptance 的日志定位模式（reconstruct 类目为 debug 级，Console 需 Include Debug Messages）。
- **Alternatives considered**: 无（低成本必做项）。

### D11 性能设计

- **Decision**: 消解两两检测 O(n²)（n ≤ ~100 → ≤ 万次浮点比较，<1ms）；宽行拆分与溢出估算 O(n×行数)；不做空间索引；迭代上限 4 轮钉死最坏情形。FR-011 的 100ms 门槛按 10 倍以上余量达成。
- **Rationale**: 页级块数量级小，索引与增量化是无收益复杂度。
- **Alternatives considered**: sweep-line 相交检测——复杂度收益为零。

## Data Model

```text
BlockLine（新增值类型，Sendable+Equatable，归一化坐标）
├── text: String                  # 该行文本（来自既有 Row.lines join 产物，不改拼接规则）
├── height: Double                # 实测行高（归一化）
├── gapToPrevious: Double         # 与上一行的间距（块首行 = 0）
└── leadingOffset: Double         # 行首偏移 = 行 minX − 块 minX

ReconstructBlock（扩展，全部 Optional 默认 nil）
├── lines: [BlockLine]?           # 行几何（无数据 = 渲染回退单段）
└── measuredLineHeight: Double?   # 块级实测中位行高（字号精化依据）

ReconstructTable（扩展）
└── columnRatios: [Double]?       # 实测列宽比例（和=1；nil=均分兜底）

ReconstructPage（激活既有字段 + 扩展）
├── layout: PageLayout?           # 赋值：medianLineHeight（页级实测行高）+ columns（栏结构）
└── restoredBlocks: [ReconstructBlock]?  # 布局后块集（拆分/位移/扩展结果；nil=退化用 blocks）

LayoutReport（引擎输出伴生值类型，仅日志不持久化）
├── yields: Int / totalShift: Double      # 让位块数与总平移量
├── splits: Int                           # 跨栏宽行拆分数
├── overflowShrinks / overflowExpands / overflowExtremes: Int
├── tableGrowthUpgrades: Int              # 表格 exact→atLeast 切换数
└── figureShrinks: Double                 # figure 区域收缩总量

LayoutTypography（纯函数集，无状态）
├── fontPT(measuredLineHeight:pageHeightPT:) -> Double        # 实测→字号（统一钳制 [7,28] 页 pt）
├── fallbackFontPT(pageHeightPT:) -> Double                   # 无实测兜底（页高 1.8%）
├── lineSpacing(measuredLineHeight:fontPT:) -> Double         # 行距补偿
└── estimatedRenderHeight(lines:width:fontPT:) -> Double      # 溢出估算（保守）

RegionLayoutEngine（纯函数入口）
└── resolve(blocks:pageLayout:pageSize:) -> (blocks: [ReconstructBlock], report: LayoutReport)
    # 不变量：无冲突输入 → 恒等映射（零扰动）；同输入 → 同输出（确定性）
```

## Contracts & Interfaces

### 模块契约

| 契约 | 签名要点 | 消费方 |
|---|---|---|
| RegionLayoutEngine.resolve | 纯函数；输入布局前 blocks + PageLayout + 页尺寸；输出布局后 blocks + LayoutReport | OnDeviceDocumentParser 装配点（唯一调用方） |
| LayoutTypography.fontPT 等 | 纯函数；页 pt 空间输出；预览换算 ÷ 画布缩放、DOCX ×2 半磅 | LayoutCanvas 与 DocxExportService **共同消费**（钳制基准统一的落点） |
| OnDeviceReadingOrder 产块 | Block 构造时同步填充 lines（Row.lines → BlockLine 映射）与 measuredLineHeight；join 文本规则不变 | ReconstructTests 既有断言零改动 |
| VisionDocumentStructureRecognizer.flatten | 提取 columnRange → ReconstructTable.columnRatios | 结构化通路表格；回退通路 nil |
| ServiceProtocols | **零变更**（D8 既有约束延续） | — |

### 测试契约（fail-first：先写并确认失败，再实现转绿）

- **RegionLayoutEngineTests（新增）**：恒等性（无冲突输入输出相等）/ 两两不相交（合成冲突夹具全对断言）/ 阅读顺序不变 / 让位方向正确（上收下移）/ 链式传播收敛 / 页界夹取 / 表格边缘骑跨行让位 / 跨栏宽行双峰拆分 / table-figure 相交 figure 收缩 / 确定性（同输入两次调用输出相等）/ 迭代上限不失控
- **LayoutTypographyTests（新增）**：密集页字号 ≤ 实测行高 × 1.2 比例（SC-003 数值）/ 无实测兜底 / 钳制区间与统一基准（同一输入在预览换算与 DOCX 换算下相对页高比例相等）/ 行距补偿非负 / 溢出估算保守性
- **DocxRestoredLayoutTests（扩展）**：有 lines 的块 → 每行一个 w:p、w:line=实测行高×20（数值断言）、w:left=leadingOffset 换算（数值断言）/ normAutofit 或布局期预缩存在（按 D6 风险注记二选一断言）/ tblGrid 按比例（非均分，结构化通路夹具）/ trHeight exact 封顶数值 / 无 lines 块回退单段（既有断言原样）
- **既有套件零回归**：ReconstructTests（join 行为）、ReconstructTierTests、LayoutMaskBuilderTests、PageLayoutMapperTests、GarbledRegionDetectorTests、BarcodeDedupTests、ExportSafetyTests、ReconstructEndToEndTests（known issue 维持 expected failure）全部原样通过；`DocxRestoredLayoutTests` 既有数值断言（posOffset == mapper 输出、tblpPr 数值）依赖恒等映射在无冲突夹具上成立——**夹具保持无冲突构造，断言不改**
- **结构化档断言**：全部原样（结构化档块构造零变化——D2 的栏约束与行采集只影响版面还原档的布局管线，结构化档走相同 blocks 但其渲染是段落流不受 bbox 影响）

### 验收对照（SC 追溯）

| SC | 落点 |
|---|---|
| SC-001 夹具 100% 不相交 | RegionLayoutEngineTests 全对断言 |
| SC-002 双端同构 | LayoutTypography 共享函数 + DocxRestoredLayoutTests 数值断言 |
| SC-003 密集页 ≤20% 偏差 | LayoutTypographyTests 密集页断言 |
| SC-004 零截断 | D6 阶梯 + 渲染期兜底 + 极端日志 |
| SC-005 零回归（212+1KI 只增不减） | 既有套件原样 + 新增套件全绿 |
| SC-006 ≤100ms/页 | D11 设计余量 + 实施期日志观测 |

### 架构不变量（实施期必须保持）

1. 布局在解析层一次完成；渲染层（LayoutCanvas/DocxExportService）只消费布局产物，**不得反向修改区域**
2. 零扰动：无冲突页引擎恒等映射——这是既有数值断言与真机观感零变化的保证
3. ServiceProtocols 协议签名零变更；Feature 层不碰 AVFoundation/CIFilter；Domain 层无 I/O（本特性不读像素）
4. 切档不重跑 parse（ReconstructViewModel 零改动）
