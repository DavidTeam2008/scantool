# 06 版面还原：图、表、Word / PDF

状态：**本机 R1 已上线；表/图/条码已接线。iOS 26 结构化通路 + 流式默认档已上线（金标准端到端验证）；真机接通性待取证（L1 疑案）；iOS 18~25 几何兜底真机仍出不了表。** TextIn 为未接线 stub。  
更新：2026-09-07；2026-09-26 对齐 wysiwyg-crop / wps-parity-layout 两周期后的现状（§12.0）

动机：真机两份样张证明，「文本」是行级 OCR 字符串，不是文档。

- 练习册：配图、二维码、勾选、手写填空丢失，阅读序被拍扁。  
- 营养成分表：字大多对，三列表被拆成竖排。

产品承诺：**点「文本」仍本机、不上传。** 「还原」是用户主动路径；**当前实现也不上传**。

接手改还原：先读 [00 §还原](00-getting-started.md#6-还原管线当前实现) + 本文 §7、§12。

---

## 1. 问题定义

`VNRecognizeTextRequest` 只回答「有哪些字、每行一个盒子」，不回答阅读序、插图区域、表格网格。继续堆语言/反色只能让字符串稍干净，**出不了合格 Word 里的图和表**。

业界称 Document Understanding / 版面还原。

---

## 2. 业界对照（目标架构）

| 产品 | 做法 | 纸匣规划 | 明确不采用 |
| --- | --- | --- | --- |
| 全能扫描王 + 合合 TextIn | 文档解析 JSON + DOCX | 可选云主引擎 | 默认上传、会员墙 |
| Azure Document Intelligence | layout：段/表/figure | IR 字段对齐 | 国内默认强依赖 |
| 多模态 LLM | 语义强、数字不稳 | 只修低置信缺口 | 营养表主识别 |

当前阶段用**本机几何**顶上，验证 OOXML 与 IR；样张过关后再决定是否必须接 TextIn。

---

## 3. 系统能力边界

### 3.1 已用 / 继续用

- Vision OCR：文本页 + 还原输入  
- `VNDetectBarcodesRequest`：条码 / 二维码 → barcode block（裁图 + payload）  
- **original** 裁配图；增强图用于认字  
- 自写 OOXML DOCX；`UIGraphicsPDFRenderer` 可检索 PDF  
- 扫描件图片 PDF 仍走「分享」（另一产物）

### 3.2 本机启发式搞不定的（预期）

合并单元格、复杂分栏试卷、印刷+手写填空、设计型包装、稳定「原图感」排版。专用版面模型或云解析仍可能需要。

---

## 4. 双通路（产品）

```
详情页
  ├─ 文本  → 本机 Vision → 复制 / 搜索     （默认，不上传）
  └─ 还原  → 本机解析 IR → 预览 → Word / 可检索 PDF
              （将来可选：确认后 TextIn）
```

场景路由（`ReconstructSceneRouter`，本机）：

| 信号 | 场景 |
| --- | --- |
| 营养成分表 / NRV / 网格感 | `table` |
| Question + A/B/C、多条码等 | `exam` |
| 配料 / 保质期等 | `packaging` |
| 其余 | `plain` |

---

## 5. 中间表示（唯一真相）

```
ReconstructDocument
  pages: [ReconstructPage]
ReconstructPage
  pageID, size, scene, usedCloud, blocks[]   // 阅读序
ReconstructBlock
  kind: heading | paragraph | list | table | figure | barcode | checkbox | handwrittenBlank
  bbox, text, style
  table?: [[String]]
  figureRelativePath?: 裁切 PNG 绝对路径（临时目录）
  barcodePayload?
```

预览、DOCX、可检索 PDF **只读 IR**。插图裁 original。营养表目标：3 列，能量行含 `1429` 与 `17%`。

---

## 6. 代码地图

```
Features/Reconstruct/
  ReconstructView.swift
  ReconstructViewModel.swift          // rendered 优先（original 兜底）
Domain/Models/ReconstructDocument.swift
Domain/
  ReconstructSceneRouter.swift
  OnDeviceReadingOrder.swift
  OnDeviceTableCluster.swift          // v1 表聚类器：已退役休眠（宁缺毋假），保留直连单测作回归钉
  OnDeviceFigureRegions.swift
  Table/    TableGridV2.swift · TableGridV2Detector.swift · TableProfile.swift   // 锚点驱动 v2
  Figure/   FigureRegionsV2.swift · InkFigureDetector.swift
  Layout/   LayoutAnalyzer · PageLayoutMapper · PageColumnSplitter · LayoutTypography …
  FlowParagraphSplitter.swift        // flow 导出侧切段（三判据 + 三不变量）
  InkTextReconciler.swift            // 墨迹-文本对账哨兵 textSentinel（四分类，只记不阻断）
  OCRNoiseFilter.swift
Services/Reconstruct/
  VisionDocumentStructureRecognizer.swift  // iOS 26 RecognizeDocumentsRequest（默认通路）
  OnDeviceDocumentParser.swift        // 几何回退（iOS 18~25）
  CompositeDocumentParser.swift       // 结构化 → 本机 → 可选云
  TextInDocumentParser.swift         // stub，抛 reconstructCloudUnavailable
  PageBarcodeDetector.swift
  NormalizedImageCrop.swift           // Vision bbox → PNG
  DocxExportService.swift
  SearchablePDFExportService.swift
  ZipArchive.swift
Services/OCR/InkRegionProvider.swift  // 墨迹区域（哨兵输入）
ZhixiaTests/   ReconstructTests · ReconstructV2Tests · ReconstructEndToEndTests
               GoldenWorksheetEndToEndTests（金标准端到端）· InkTextReconcilerTests
               DocumentStructureTests · ReconstructTierTests · ExportSafetyTests …
```

协议（`ServiceProtocols.swift`）：`DocumentParsing`、`DocxRendering`、`SearchablePDFRendering`、`ReconstructRepairing`（无实现）。

---

## 7. 当前管线（实现，不是愿景）

```
rendered 优先（original 兜底）
  ├─ iOS 26：VisionDocumentStructureRecognizer（RecognizeDocumentsRequest）
  │    直接拿 lines / tables（行列结构）/ barcodes —— 默认通路（flow 流式档）
  └─ 回退：Vision OCR → TableGridV2Detector（锚点驱动；v1 聚类器已退役，
       几何通路不再产表，宁缺毋假）
  两条通路归一成 StructuredDocumentPage ↓（每页一条 reconstructPath 决策日志）
  → ReconstructSceneRouter（plain / exam / table / packaging）
  → OCRNoiseFilter（状态栏 / UI chrome / URL）
  → PageColumnSplitter（x 投影找 gutter → 按栏切）
  → OnDeviceReadingOrder（栏内：剩余行 → 段落 / 标题 / 列表）
  → FigureRegionsV2（空白连通域）+ InkFigureDetector（像素墨块）→ 裁 PNG
  → PageBarcodeDetector（条码裁图 + payload）
  → InkTextReconciler（丢字对账哨兵，只记不阻断）
  → ReconstructDocument IR
  → 预览 / DocxExportService（flow 侧 FlowParagraphSplitter 切段）/ SearchablePDFExportService
  → 档位：flow（流式，默认）/ .restored（高保真，可选）
```

`CompositeDocumentParser`：结构化通路优先，失败回退本机几何；非 plain 且 TextIn `isConfigured` 才打云。密钥未配 → 恒为本机。

---

## 8. UI

- 详情：`文本 | 还原 | 分享 | 加页`  
- 还原页：本机说明、block 预览（表用 `Grid`）、导出 Word / 可检索 PDF  
- `needsCloudHint`：场景像试卷/表但本机未产出表或配图时弱提示（文案已改为「本机可能仍不准」，非「下一版才有」）

「文本」文案保持未上传。

---

## 9. 验收标准（两张样张）

### 练习册 Word

- A/B/C 三道题配图在选项旁，不是空白  
- 右缘二维码是图且位置合理  
- 勾选 / 手写允许弱一些  

### 营养表 Word

- 「营养成分表」下是 `w:tbl`，不是竖列表  
- 行：能量 | 1429 千焦 | 17%（其余行同理）  
- 条码是图；payload 可作题注  

回归：「文本」与扫描件 PDF 行为不变。

---

## 10. 分期（对照代码）

| 阶段 | 用户可感知 | 代码状态 |
| --- | --- | --- |
| R1 | 纯文字 → 可编辑 DOCX + 文字层 PDF | **完成** |
| R2 本机 | 尝试真表、配图、条码 | **iOS 26 结构化通路样张已过（模拟器 7×3）+ 金标准端到端全绿；真机接通性待取证（L1）；iOS 18~25 真机仍 `w:tbl = 0`** |
| R2′ TextIn | 云解析嵌图嵌表 | stub |
| R3 | 试卷模型、勾选进 IR | 未做 |
| R4 | VL 修补指定 block | 协议 only |

---

## 11. 明确拒绝

- LLM Markdown 当「保留格式」  
- 点「文本」上传  
- 整页截图改后缀冒充 Word  
- OpenCV / 自训 LayoutLM 作 v1 主路径  
- Feature 内写 TextIn URL / prompt  

---

## 12. 已知问题

### 12.0 状态更新（2026-09-26，wps-parity-layout 周期后）

原 2026-09 记录（§12.1~§12.3）保留作历史快照。当前状态：

| 原问题 | 现状 |
| --- | --- |
| 营养表三列（iOS 26） | ✅ 结构化通路直接给行列结构（模拟器实测 7×3）；**真机接通性从未验证**（L1 疑案：iOS 26.7 真机疑似静默回退，已加 `reconstructPath` 决策日志，取证步骤 `spec/wps-parity-layout/device-acceptance.md` §A） |
| 营养表三列（iOS 18~25） | ❌ 几何兜底真机仍 `w:tbl = 0`——真机 OCR 把整行单元格合并成一个 line，「midX 聚类推列」假设失效（根因链见 [08](08-reconstruct-v3-realworld-fix.md)）；`withKnownIssue` 钉在 `ReconstructEndToEndTests.realDeviceOcrStillLacksTable` |
| 默认导出像「OCR 重排文档」 | ✅ **流式档默认**（wps-parity-layout）：flow 干净流式文档为默认，`.restored` 降级可选「高保真」；档位选择器 + @AppStorage 持久化、预览/导出同源 |
| 散排编号 → 假表吞字 | ✅ **v1 表格聚类器退役**：几何通路不再产表（宁缺毋假），金标准端到端钉死零假表 |
| 疑似静默丢字（"wrong bus!"） | ✅ **定案：检索假阴性**——OCR 原行是全角 `！`（`wrong bus！`），一直在故事块内，2026-09-21 用 ASCII `!` 检索全角输出造成「丢失」误判；防护机制照建（风险真实存在）：containment 不变量 + 页眉规则收紧 + 墨迹-文本对账哨兵 `textSentinel`（四分类，**只记日志不阻断**，断言「真丢报得出、没丢不误报」） |
| 段落碎片化 | ✅ 导出侧 `FlowParagraphSplitter` 切段：三判据（条目号领头 / 行首回撤 ≥ 0.012 / 句末标点）+ 三不变量；金标准 **32 段 ∈ 42 ± 30%** |
| 漫画条完整性 | ✅ 细长大图形单张完整内联于阅读序原位（金标准验证）；几何回退通路未检出为 figure 时哨兵如实报证（记录不修） |
| 通路决策黑箱 | ✅ `reconstructPath` 每页一条五分类决策线（debug + privacy.public） |
| 配图真机质量 | ⚠️ 仍待真机验证（模拟器条码恒 0 等限制见 [00 §7](00-getting-started.md#7-怎么测)） |

原 §12.3 建议的落点：①夹具化 → 已做（`ReconstructV2Fixtures` + 金标准套件）；②营养表锚点强制网格 → 已做（`TableGridV2Detector` 锚点驱动）；③配图锚点扩框 → 部分做了（`InkFigureDetector` 像素墨块）；④产品预期 → 已明确（流式档默认 = 干净流式文档，对标 WPS）；⑤TextIn → 未启（纯离线红线，云通路须独立周期评审）。

### 12.1 现象（实机，2026-09 历史快照）

| 样张 | 期望 | 实际 |
| --- | --- | --- |
| 练习册 | A/B/C 配图 + 二维码，位置靠近原版 | **往往只出二维码**；配图缺失；**位置不对** |
| 营养表 | 三列真表，能量行对齐 | **表格经常没有**；即使有字也是**样式/结构不对**（偏重排段落） |
| 整体 | 版心、块顺序接近原页 | Word 像「OCR 重排文档」，**不像原图版式** |

### 12.2 可能根因（2026-09 历史快照，便于接手排查）

1. **`OnDeviceFigureRegions`**  
   - 栅格连通域易把大空白（页边、题干间隙）当成 figure，或被文字盒膨胀掩码切碎。  
   - 条码检测成功后占用/排序，可能只剩 barcode block 看起来「只有二维码」。  
   - 裁切依赖 original；若某页无原图则配图弱。

2. **`OnDeviceTableCluster`**  
   - 依赖 OCR 盒对齐；盒飘、行距不均、标题「营养成分表」混进网格时，occupancy / `looksLikeDataTable` 会直接放弃 → **无 `w:tbl`**。  
   - 即使检出，列数/行序错会导致「样式不对」。

3. **导出与阅读序**  
   - DOCX 按 block 流式堆段落/表/图，**不做绝对定位**，天然做不到「像素级还原原图」。  
   - 当前目标是「结构正确的可编辑文档」；若产品要「所见即原图」，需另定策略（例如衬底图 + 文字层，或云版式）。

4. **单测与样张落差**  
   - `ReconstructTests` 用合成 bbox，绿不代表真机样张过关。

### 12.3 建议下一步（2026-09 历史快照，落点见 §12.0 末段）

1. 对两张样张导出 OCR `[(text, bbox)]` 夹具，写成失败单测。  
2. 先保营养表三列（可临时加「营养成分表」锚点下方强制网格）。  
3. 配图：用题号/选项字母锚点扩框，或排除 barcode 后再取 top-N 大空洞。  
4. 明确产品预期：v1 还原 = 结构文档，不是打印级复刻；若必须「像原图」，单独立项。  
5. 本机仍不够再启 TextIn（用户确认上传单页）。

### 12.4 回归时不要破坏

- 「文本」本机、不上传  
- 扫描件 PDF「分享」路径  
- R1 纯文字合同类 DOCX  
- A/B/C 单字母不被聚成假表（已有单测）
