# Tasks: Word 导出保真度（word-fidelity）

**Input**: `spec.md`（US1~US4 / FR-001~006 / SC-001~005）、`plan.md`（D1~D6）
**评估**: [`docs/16-word-export-fidelity.md`](../../docs/16-word-export-fidelity.md)
**测试基线**: **448 = 447 passed + 1 expected failure + 0 failed**（2026-10-22 实测；
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

## Phase 1：增强（待做，依赖真机/更多样本）

- [ ] **T010** 图片版 + 隐藏文字层（可搜索的图片版）：底图照旧，文字层以
  不可见文本叠加 → Word 内可全文检索，视觉零变化。
- [ ] **T011** 夹具扩到 10–20 张真实样本（整书 / 双栏 / 表格 / 票据 / 手写），
  闸门批量跑并留档。
- [ ] **T012** 跨渲染器复测（LibreOffice → PDF → 位图）确认口径可比。

## 方向性翻转清单

| 测试 | 旧断言 | 新断言 | 理由 | 任务 |
|---|---|---|---|---|
| `ReconstructTierTests.defaultTierIsFlow` | 默认档 = `.flow`（流式） | 默认档 = `.pageImage`（图片版） | WPS 实测 + 用户实测「复杂页样式会乱」；文字检索由 App OCR 索引承担 | T004 |
| `ReconstructTierTests.tiersAreLabelled` | `R2OutputTier.allCases.count == 2` | `== 3`（增图片版） | 增档 | T004 |
| `ReconstructTierTests.selectableTiersAreRestoredAndStructured` | `selectable == [.restored, .structured]` | `== [.pageImage, .restored, .structured]` | 增档（图片版置首 = 默认档） | T004 |
| `ReconstructTierTests.reselectingSameTierKeepsDocx` | 重选 `.structured`（= 旧默认档） | 重选 `ExportTier.defaultTier.outputTier`（= 新默认档） | 默认档翻转 | T004 |
| `ReconstructTierTests.persistedTierRoundTripsThroughUserDefaults` | 垃圾值回退 `.flow` | 垃圾值回退 `ExportTier.defaultTier` | 默认档翻转（语义不变，参数随默认档） | T004 |
| `ReconstructTierTests.previewAndExportShareTierSource` | 断言默认档 = `.structured` 且默认导出是段落流 | 显式选 `.structured` 后仍断言「流式 = 段落流」；另断言默认档 = 图片版 | 默认档翻转；**用例原有语义（预览/导出同源）零修改** | T004 |
| （其余 442 条） | 零修改 | 零修改 | 纯新增用例；`DocxRestoredLayoutTests` / `SpreadSplitterTests` 未动 | — |

## 验收门

1. **Gate 0**：`make word-fidelity` → 图片版 SSIM(页面图) ≥ 0.90 **且**
   SSIM(原始照片) ≥ 0.90（实测 0.914 / 0.919）；
2. **Gate 1**：可编辑档对照 < 0.85（实测 0.767）——闸门有鉴别力；
3. **Gate 2**：`make test` 全绿（基线 448 = 447 + 1 expected failure + 0 failed）；
4. **Gate 3**：人工看渲染图 —— 表格/图/色块/页码位置与原片一致，无文字重复。
