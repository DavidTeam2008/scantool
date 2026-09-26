# Implementation Plan: 版面还原对标 WPS（wps-parity-layout）

**Input**: Feature specification from `spec/wps-parity-layout/spec.md`

## Summary

默认导出从 restored 像素合成档切换为流式档（原 structured），restored 降级为可选「高保真」档；根治假表格（v1 聚类器摘除）、静默丢字（containment 不变量 + 页眉规则收紧 + 墨迹-文本对账哨兵）、段落碎片化（金标准驱动的聚类调参）；结构化识别通路决策全程可观测。金标准输入（语法练习页渲染图，已从用户 2026-09-21 导出的 docx 中提取）作为 fixture 驱动端到端测试。

## Technical Context

**Language/Version**: Swift 5.x（Xcode 26 工具链，DEVELOPER_DIR 外置）  
**Primary Dependencies**: SwiftUI、AVFoundation、Vision（`VNRecognizeTextRequest` 几何通路 + iOS 26 `RecognizeDocumentsRequest` 结构化通路）、CoreImage、SwiftData；零第三方依赖  
**State Management**: N/A（SwiftUI 既有模式：@Observable ViewModel + 环境注入，延续现状）  
**Storage**: 既有磁盘文件（`PageFileStore`）+ SwiftData（`ScanDocument/ScanPage`）；档位偏好用轻量持久化（@AppStorage 级）  
**Testing**: XCTest；构建命令 `xcodebuild test -project Zhixia.xcodeproj -scheme Zhixia -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -skipPackagePluginValidation -skipMacroValidation`；基线 317 = 316 passed + 1 known issue + 0 failed，只增不减  
**Target Platform**: iOS 18.0+（部署目标）；结构化通路 iOS 26+ 优先生效，低版本走几何回退；真机 iPhone 13（iOS 26.7）验收  
**Project Type**: mobile-app（既有 iOS 扫描 app，增量改造）  
**Performance Goals**: 单页解析耗时不劣化（哨兵对账为每页一次 O(区域数) 级匹配，无像素级重扫）  
**Constraints**: 纯离线；`ServiceProtocols` 协议签名不变；Domain 纯函数无 I/O；既有测试断言零修改（唯一例外见 R&D-D8）  
**Scale/Scope**: 版面还原/导出链约 20 个既有文件 + 3 个新文件 + 2 个 fixture；单页级处理

## Project Structure

### Documentation (this feature)

```text
spec/wps-parity-layout/
├── spec.md              # Phase 1 产物（已过评审门）
├── plan.md              # 本文件
└── tasks.md             # Phase 3 产物
```

### Source Code (repository root)

```text
docs/fixtures/
├── images/grammar-worksheet.jpg          # NEW 金标准输入（1683×2200，从用户 docx media 提取，即解析器确切输入）
└── golden-wps-reading-order.txt          # NEW WPS 产物阅读流对照（44 行段落文本）

Zhixia/
├── Domain/
│   ├── InkTextReconciler.swift           # NEW 墨迹-文本对账纯函数（区域匹配+原因分类）
│   ├── Models/ReconstructDocument.swift  # MOD 档位语义（flow 默认/highFidelity）+ MissingTextReport 类型
│   ├── OnDeviceReadingOrder.swift        # MOD 段落聚类调参（金标准驱动）
│   ├── OnDeviceTableCluster.swift        # MOD 仅标注休眠（调用点摘除，类与单测保留保基线）
│   └── OCRNoiseFilter.swift              # MOD 页眉短行规则收紧（位置约束+字符边界）
├── Services/
│   ├── Reconstruct/
│   │   ├── OnDeviceDocumentParser.swift  # MOD 通路决策日志 / v1 调用点摘除 / containment 不变量
│   │   ├── VisionDocumentStructureRecognizer.swift  # MOD 失败原因捕获（不可用/异常/无效 分类）
│   │   └── DocxExportService.swift       # MOD 档位映射（默认 flow）+ 哨兵触发点
│   ├── OCR/
│   │   └── InkRegionProvider.swift       # NEW 墨迹提取服务（协议化复用 InkFigureDetector 墨块能力）
│   └── ZhixiaLog.swift                   # MOD +reconstructPath / textSentinel 日志助手
├── Features/Reconstruct/
│   ├── ReconstructView.swift             # MOD 档位选择 UI（流式默认/高保真，预览+导出一致）
│   └── ReconstructViewModel.swift        # MOD 档位状态与持久化、导出走所选档

ZhixiaTests/
├── InkTextReconcilerTests.swift          # NEW 对账分类纯函数测试
├── GoldenWorksheetEndToEndTests.swift    # NEW 金标准端到端（零假表/丢字/段落对照/漫画条/通路日志）
├── ReconstructTierTests.swift            # 既有：默认档断言若受 FR-001 影响按 D8 处置
└── （其余既有测试 append-only 扩展）
```

**Structure Decision**: 既有 iOS 项目，完全遵循现有架构（Domain 纯函数 / Services 含 Vision 与 Reconstruct / Features-MVVM / ZhixiaTests），不引入新目录层级；新增仅 3 个源文件（对账纯函数、墨迹提取服务、对应测试），改动集中于既有 Reconstruct 链文件。

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| 无 Constitution 违例 | — | — |

## Research & Decisions

- **R&D-D1 档位语义与默认翻转**：内部 tier 枚举命名保留（restored/structured），用户面标签「流式（默认）/高保真」；默认导出与默认预览 = 流式；用户选择以 @AppStorage 键持久化，预览与导出读同一键。备选「会话级临时态」被否：跨会话记忆成本低、体验更稳。
- **R&D-D2 金标准输入已就位**：用户 2026-09-21 导出 docx 内嵌的 image1.jpg（1683×2200）就是解析器消费的确切渲染图——直接提取为 fixture，**无需等待用户提供原图**（spec Open Question 1 的 W1/W3 部分提前解锁）；WPS 产物阅读流文本提取为对照 fixture。结构化通路诊断顺序：先用该 fixture 在模拟器（iOS 26 runtime）复现 → 复现则代码修复；不复现则差异在真机环境，Phase 5 真机日志取证定案。
- **R&D-D3 v1 退役策略**：仅摘除几何通路调用点（`OnDeviceDocumentParser` 不再调 `OnDeviceTableCluster`），类与单测保留为休眠态（标 deprecated 注释）——保 317 基线只增不减。新增断言测试：几何通路对散排编号文本不产出表格；`realDeviceOcrStillLacksTable` known-issue 包装零修改（v1 退役后其期望仍成立）。
- **R&D-D4 丢字防护三层**：① v1 退役消除最大吞字源（14 行假表格吞 "(9)…" 正文）；② containment 不变量：任何被表格/条码 bbox 剔除的行，必须被携带文本的结构（单元格集合/条码块说明）覆盖，运行时违规计数进哨兵日志；③ 页眉短行规则收紧：位置约束限定页顶窄带 + 字符边界复核（"wrong bus!"=10 字符踩线教训），配套单测。
- **R&D-D5 墨迹-文本对账哨兵**：纯域函数 `InkTextReconciler`（输入：墨迹区域集 + 文字行覆盖 + 结构区域；输出：MissingTextReport，原因分类 figureOverlap/structureSwallow/edgeBand/likelyMissed）；墨迹提取协议化复用 `InkFigureDetector` 既有墨块能力（避免重复造图像处理轮子）；导出前逐页执行，只记日志不阻断（FR-006）；"wrong bus!" 若为 Vision 行级漏识，哨兵输出 likelyMissed 证据即验收通过（用户已决策）。
- **R&D-D6 段落聚类调参**：以金标准对照（42 段量级 vs 碎片化 83 段）驱动 `clusterParagraphs` 收紧同块行合并；红线：不得回退 2026-09-12 行距教训（教材行距 1~2% 时整页按 x 排序的错序 bug，代码注释在案）；对照表测试固化收敛结果。
- **R&D-D7 漫画条整块内联**：restored 档曾在同图检出 1.40×3.21in 漫画区域（srcRect 二次锚放即证据），说明检测器可见该区域——流式档内联验证为主，若 fixture 上被拆碎/漏检则增强 `InkFigureDetector`/`FigureRegionsV2` 的细长区域合并；防文字列误并入图形（maxTextCoverage 判据复核）。
- **R&D-D8 既有断言与默认翻转冲突处置**：`ReconstructTierTests` 等若存在「默认档 = restored」语义断言，属 FR-001 明示契约变更——仅允许修改直接断言默认档语义的最小测试点，逐条记录于 tasks；除此之外断言零修改、总数只增不减。
- **R&D-D9 通路决策可观测**：新日志前缀 `reconstructPath`（page/path/reason，reason 分类：API 不可用/请求异常/结果无效/其他），在 `resolveInputs` 决策点与 `VisionDocumentStructureRecognizer` 失败捕获点发射；debug 级 + privacy.public，与既有 `ZhixiaLog` 模式一致；真机验收用 Console.app 检索。

## Data Model

- **导出档位（ExportTier，既有枚举语义扩展）**: `flow`（流式，默认；对应现 structured 产物）/ `highFidelity`（高保真，对应现 restored 像素合成）；用户可选，预览与导出共用；持久化键记录用户偏好，未设置时为 flow。
- **通路决策（PathDecision）**: 每页解析产出一行可观测记录：页索引、通路（structured/geometric）、原因分类（API 不可用/请求异常/结果无效/结构化成功/低版本回退）。
- **墨迹缺口（InkGap）**: 归一化矩形、面积占比、原因分类（figureOverlap=图形区属预期 / structureSwallow=结构吞噬违规 / edgeBand=页缘带 / likelyMissed=疑似 OCR 漏识）。
- **对账报告（MissingTextReport）**: 页索引 + InkGap 列表 + 汇总计数；只进日志，不阻断导出。
- **金标准资产（fixture）**: `grammar-worksheet.jpg`（解析器确切输入）+ `golden-wps-reading-order.txt`（段落顺序/粒度对照金标准）。

## Contracts & Interfaces

- **`ServiceProtocols` 协议签名不变**（全局铁律）：`DocumentParser` 等对外协议零改动，本周期全部为内部行为变更与新增内部组件。
- **墨迹提取（新内部契约）**: 服务侧提供「渲染页 → 归一化墨迹区域集」能力（协议化复用 `InkFigureDetector` 墨块逻辑）；Domain 侧不接触图像 I/O。
- **对账纯函数（新内部契约）**: `InkTextReconciler` 接收墨迹区域集、文字行 bbox 集、结构区域集（表格/条码/图形），返回 `MissingTextReport`；确定性纯函数，无副作用，可单测穷举分类分支。
- **containment 不变量（内部行为契约）**: 表格/条码 bbox 内被剔行的文字必须可在对应结构文本中检索到；违规计入哨兵报告的 structureSwallow 类。
- **日志契约**: `ZhixiaLog` 新增 `reconstructPath` 与 `textSentinel` 两个前缀助手（debug 级、privacy.public 字段化参数），模式与既有 `detectionTier`/`cropGate` 一致。
- **UI 契约**: 还原预览页提供「流式（默认）/高保真」档位选择，选择持久化且同时作用于预览渲染与导出产物；导出入口不再单独询问档位。
- **导出安全契约（保持）**: 非法字符清洗、损坏文件防护、高保真档每页单图约束不变（FR-010）。
