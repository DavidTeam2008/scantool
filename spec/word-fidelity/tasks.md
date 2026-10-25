# Tasks: Word 导出保真度（word-fidelity）

**Input**: `spec.md`（US1~US4 / FR-001~006 / SC-001~005）、`plan.md`（D1~D6）
**评估**: [`docs/16-word-export-fidelity.md`](../../docs/16-word-export-fidelity.md)
**测试基线**: **449 = 448 passed + 1 expected failure + 0 failed**（2026-10-22 实测；
T001 前为 444 → 交付后 448）

## Phase 0：修复与闸门（已交付）

- [X] **T001** 静帧页面判定（FR-001 / D1）：`DetectionStrategy.stillPageCandidate`
  纯函数（大候选 = 页面 / 候选铺满整幅 → **不裁** / 否则取最大候选）；
  `VisionEdgeDetector` 静帧路径接入（相机路径不动）。
  回归断言：`WordFidelityExportTests.stillDetectionNeverCropsToSubRegion`。
  取证：`build/word-fidelity/{candidates.txt,rect-params.txt}`。
- [X] **T002** 图片版导出（FR-002 / D2）：`R2OutputTier.pageImage` +
  `ExportTier.pageImage`；`DocxExportService.pageImageBodyXML`（A4 贴合页 +
  内联图 + 行高钉图高 + 段落标记不设 1pt 字号 + 零文本框/零 mask）；
  预览同源（`PageImageCanvas`）。
  回归断言：`WordFidelityExportTests.pageImageTierIsPurePageImage`。
- [X] **T003** 保真度闸门（FR-005 / D5）：`Tools/word-fidelity/check.sh`
  （qlmanage 渲染 + ffmpeg SSIM，口径：800×800 + 模糊 sigma=3）+
  `make word-fidelity` + `WordFidelityExportTests.exportsArtifactsForHostSideComparison`。
  **实测（2026-10-22）**：图片版 SSIM(页面图) = **0.914**、SSIM(原始照片) =
  **0.919**（双口径 ≥0.90 ✓）；版面还原档对照 = 0.767 / 0.773 ✗（鉴别力成立）。
- [X] **T004** 档位体系与默认翻转（FR-004 / D3）：默认档 = 图片版；可编辑两档
  保留；方向性翻转记录见下表。
- [X] **T005** 文档与落盘（FR-006）：`docs/16-word-export-fidelity.md`
  （WPS 录屏评估 + 两处根因 + 处置 + 实测数字）、本 spec 四件套、
  `docs/12`/`AGENTS.md`/`docs/14` 指针更新。

## Phase 1：可编辑档（版面还原）保真度迭代

> 迭代方案与取证：[`docs/17-editable-tier-fidelity-iteration.md`](../../docs/17-editable-tier-fidelity-iteration.md)。
> 口径分层：图片版用 SSIM 门限（≥0.90，已达标）；**可编辑档用结构指标**
> （叠字率 / 对齐度 / 位置偏差）——它的产物按设计就不是原页像素，SSIM 门限不适用。

- [X] **T010** 归因与第一轮修复（已完成，2026-10-22）：分层归因
  （`Tools/word-fidelity/attribute.py`：L0 空白 0.722 / L1= L0 / L2 0.790）
  → 发现**本机渲染器（QuickLook）不画锚定图与 shape**（闸门对可编辑档不可信）
  + **页面尺寸是巨页**（41.5×55.9cm）；已修 G1（页面 A4 贴合，
  `restoredPageSpaces` → `fittedPageEMU`）+ 档位命名迁移（高保真=图片版）。
  **判定**：图片版 0.914/0.919 ✅；可编辑档 0.785/0.792 ✗（**未达标**，转入 R2~R5）。
  **追加取证（关键）**：App 侧离屏渲染「导出模型」（`ImageRenderer` + `LayoutCanvas`，
  与导出同源同坐标）→ **可编辑档的模型 SSIM = 0.984**、图片版 = 0.997 → **版面模型
  是好的，坏在 OOXML 导出层**（导出层损失 0.218 vs 0.083）。两个机制：① 净化遮罩是
  `wps:wsp` 形状，**部分渲染器不画**（L1==L0）→ 原文字没擦掉 → 叠字；② 文本框
  字体被替换 → 行距漂移 → 错位。**修复方向随之改为「改导出层的表达方式」**，
  不是改版面算法。
- [X] **T020**（R2）渲染器与分层归因：① `Tools/word-fidelity/attribute.py`
  （分层变体 + 逐层 SSIM）；② **App 侧离屏渲染**（`WordFidelityExportTests`
  `rendersExportModelOffscreen` → `build/word-fidelity/preview-*.png`）+
  `check.sh` 新增「SSIM(导出模型)」与「导出层损失」两栏。
  **判定**：可编辑档 模型 0.984 / docx 0.767 → 损失 0.218（责任层 = OOXML 导出层）✅
  取证成立。**未达成**：LibreOffice headless 转换在本机不出文件（连 WPS 自产 docx
  也不出）→ 宿主渲染器顺延，跨渲染器复核改由 WPS/Word 人工抽样做（T031）。
- [X] **T021**（R3）叠字归零（G3'）：**把「擦除原文字」烘进底图** ✅（2026-10-22 交付）——
  App 导出 `.restored` 时基于 `LayoutMaskBuilder` 的净化矩形，把原文字区域按环带
  median 底色直接刷到**底图像素**（`DocxExportService.registerBakedBaseImage` /
  `bakedJPEGData`，Vision 左下原点 → `CGContext` 左下原点，不再翻 y），编码为每页
  唯一 JPEG media；docx **不再发射 `name="Mask"` 形状**（宿主渲染器不画 → 旧产物
  底图原字 + 文本框叠字）；底图改**内联图**铺页（锚定图宿主同样不落图），
  figure/barcode/artwork 仍对同一张净化底图 `srcRect` 裁剪；浮动文本框 / 原生浮动
  表格原位保留、可编辑。
  **实测**：`make editable-fidelity SIM_NAME='iPhone 18 Pro' SIM_OS=27.0`
  → 可编辑档 **SSIM(页面图) = 0.961 / SSIM(原始照片) = 0.965**（门限 0.90，
  旧值 0.767/0.773；导出层损失 0.218 → **0.023**，模型真值 0.984 不变）；
  渲染图目视无叠字（`build/word-fidelity/out-restored-rendered.png`）。
  结构回归：`DocxRestoredLayoutTests` 21/21 通过；全量 `make test` = 449
  （448 passed + 1 expected failure + 0 failed）。
- [X] **T024**（R4a）可编辑档页面尺寸修正：动态页/内联底图链路已稳定；相关结构断言已随 T021 更新。
- [X] **T022**（R4）遮罩瘦身 + 字号行距（G4/G5）：已改为行/段级擦除（`LayoutMaskBuilder.granularity: .line`），保留表头/边框/照片；字号行距按实测行高。
  判定：真实 WPS 0.906/0.907；残留重影转入 page-preprocess。
- [ ] **T023**（R5）表格/图锚点（G6）+ 夹具扩到 10–20 张 + 全量回归。
  **已完成**：真机表格 3×4 → 2×5 修复（`TableStructureRepair`）、题头行序、TableBox 锚点；**未完成**：夹具扩到 10–20 张。
- [ ] **T030** 图片版 + 隐藏文字层（可搜索的图片版）：底图照旧，文字层以
  不可见文本叠加 → Word 内可全文检索，视觉零变化。
- [ ] **T031** 跨渲染器抽样复核：WPS 已完成（0.906/0.907）；Microsoft Word 未安装，待补。

## 下一阶段

- 页面预处理（页外裁切 / 折痕 / 页边拉直）：[`spec/page-preprocess/`](../page-preprocess/spec.md)、[`docs/19`](../../docs/19-page-preprocess-plan.md)。
- 导出层重影暂缓；粗体、表格内边距等小偏差见 `TODO.md`。

## 方向性翻转清单

| 测试 | 旧断言 | 新断言 | 理由 | 任务 |
|---|---|---|---|---|
| `ReconstructTierTests.defaultTierIsFlow` | 默认档 = `.flow`（流式） | 默认档 = `.pageImage`（图片版） | WPS 实测 + 用户实测「复杂页样式会乱」；文字检索由 App OCR 索引承担 | T004 |
| `ReconstructTierTests.tiersAreLabelled` | `R2OutputTier.allCases.count == 2` | `== 3`（增图片版） | 增档 | T004 |
| `ReconstructTierTests.selectableTiersAreRestoredAndStructured` | `selectable == [.restored, .structured]` | `== [.pageImage, .restored, .structured]` | 增档（图片版置首 = 默认档） | T004 |
| `ReconstructTierTests.reselectingSameTierKeepsDocx` | 重选 `.structured`（= 旧默认档） | 重选 `ExportTier.defaultTier.outputTier`（= 新默认档） | 默认档翻转 | T004 |
| `ReconstructTierTests.persistedTierRoundTripsThroughUserDefaults` | 垃圾值回退 `.flow` | 垃圾值回退 `ExportTier.defaultTier` | 默认档翻转（语义不变，参数随默认档） | T004 |
| `ReconstructTierTests.tierMappingsRoundTrip` | `ExportTier.highFidelity.outputTier == .restored` | `ExportTier.layoutEditable.outputTier == .restored`（并补 `.pageImage` 断言） | **档位重命名**（2026-10-22）：「高保真」让给图片版，可编辑版面还原改名 `layoutEditable`；旧 rawValue `"highFidelity"` 迁移到 `layoutEditable`（**老用户行为不变**） | T010 |
| `ReconstructTierTests.previewAndExportShareTierSource` | 断言默认档 = `.structured` 且默认导出是段落流 | 显式选 `.structured` 后仍断言「流式 = 段落流」；另断言默认档 = 图片版 | 默认档翻转；**用例原有语义（预览/导出同源）零修改** | T004 |
| （其余 442 条） | 零修改 | 零修改 | 纯新增用例；`DocxRestoredLayoutTests` / `SpreadSplitterTests` 未动 | — |

## 验收门

1. **Gate 0**：`make word-fidelity` → 图片版 SSIM(页面图) ≥ 0.90 **且**
   SSIM(原始照片) ≥ 0.90（实测 0.914 / 0.919）；
2. **Gate 1**：可编辑档真实 WPS ≥0.90（模拟器 **0.906224** / iPhone 13 **0.907581**）；
3. **Gate 2**：`make test` 全绿（基线 **456 = 455 passed + 1 expected failure + 0 failed**，iPhone 18 Pro / iOS 27；T004 在 iOS 26.4.1 的结构表缺失记入 TODO）；
4. **Gate 3**：人工看渲染图 —— 表格/图/色块/页码位置与原片一致；背景字重影转入 page-preprocess。
