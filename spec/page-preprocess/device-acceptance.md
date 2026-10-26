# Device Acceptance: page-preprocess

设备：iPhone 13（`00008110-000805902684801E`，iOS 27.0.1）
样张：`docs/media/IMG_7544.jpg`（2939×3961）+ 真机 rendered 页

## 1. 预处理前基线

- 记录 `rendered.jpg`、页外背景占比、四边直线度、文字行角度。
- 跑一次 OCR / Word 导出，记录表格列数、WPS SSIM。
- 证据：`build/page-preprocess/device-before/`。

## 2. 预处理后

- 同图重跑，记录 `preprocess.json`、`rendered.jpg`、OCR 行/表格、WPS SSIM。
- 证据：`build/page-preprocess/device-after/`。

## 3. 通过条件

- 页外背景 <2%；页边偏差/平行度 ≤0.5% 短边；文字行中位 ≤0.3°。
- 字符召回 ≥99%；照片/插图无裁切或明显变形。
- WPS SSIM 不低于 0.906（当前真机基线 0.907581）。
- 处理时间 ≤1.5s/页。

## 4. 失败记录

- 若页面检测失败：记录回退原因（API 不可用 / 低置信 / 面积小 / 覆盖率不足），不得静默裁字。
- 若折痕去除导致照片失真：记录区域 bbox，回退该页折痕档。

## 5. P0 折页/页外裁切结果（2026-10-26）

### 模拟器（全图路径，`IMG_7542.JPG`）

- `cropApplied=true`，`fallbackReason=fold_trim`
- `foldTrimU=0.090`，`foldTrimSource=bright_fold`
- `foldTrimTextLossRatio=5.06%`，`textCoverage=1.0`
- 输出 **1752×2200**
- 左侧折页漫画条、木桌/页边阴影已去除；标题、页码保留
- 回归证据：`build/page-preprocess/final-p0/after-fold-regression.jpg`、`report-fold-regression.json`

### iPhone 13（iOS 27.0.1）

- `VisionEdgeDetector` 页级四边形（area 0.808178）；`cropApplied=true`
- `fallbackReason=page_left_inset`，`pageLeftInset=0.01`（1% 页宽）
- `pageTextLeft=0.105622`，标题保留约 0.68% 安全边；`textCoverage=1.0`
- 输出 **1554×2200**；标题、页码、表格可见
- 表格安全门：页级 quad 正立参照 `tableSafetyReference=page_quad`，参照表 `[[5,3]]`；裁切 JPEG 偶发 0 表（`tableSafetyCroppedShapes=[]`），因所有表 bbox 在裁切线右侧，判定 `geometry_clear`；最终增强页结构表 `[[5,2]]`、解析表格块 1
- 报告内耗时 179ms；全流程 ≤1.5s/页仍归 PP-T032
- 证据：`build/page-preprocess/final-p0/device-after-inset.jpg`、`device-report.json`、`device-page-inset.json`、`build/device-inset.xcresult`

### 下游

- WPS（`original-base.jpg`）**0.906224**，与基线一致（2026-10-26 独立跑 realbase 测试 + 新 WPS 渲染）
- 证据：`build/word-fidelity/realbase-wps-p0c-20261026b/out-restored-realbase-wps.png`
- 注意：`WordFidelityExportTests` 整类顺序跑会触发已知 Vision 表格抖动（`realOCRExportArtifact` 0 表），该类产物不作为 WPS 基线。

## 6. P1 折痕/光照结果（2026-10-26）

设备：iPhone 13（iOS 27.0.1）；输入 `IMG_7542-input.JPG`；P0 输出 1554×2200。
P1 配方：p90 目标 0.8612、maxGain 1.5、覆盖率 0.8599；P0 表格安全门给出 1 个表框并强制保护区 `gain=1`。

### A/B

- off：`cropApplied=true`、`page_left_inset`、`geometry_clear`；结构表 `5×2`，OCR 1797，渲染 1552ms。
- on：`illuminationApplied=true`、`illuminationTableGuardAvailable=true`、`illuminationTableGuardSource=p0_crop_safety`、`illuminationProtectedTableCount=1`；结构表 `5×2`，OCR 1782，P1 236ms，渲染 1395ms。
- 背景场方差：0.002832 → 0.0000293（**−98.97%**）。
- OCR 归一化字符召回 **99.93%**；唯一 off-only 行是 `21m`/`2lm` 数字字母混淆；on 新增 2 条 ghost 垃圾行（`TSK00B`、`Saomt`），属已知 G1，非真实文本丢失。
- 表结构重复：off/on 各 6 次，**6/6** 均为 1 表 `5×2`（`final-p1-device-repeat.json`）。
- 性能：直接 P1 首跑 280ms / 暖跑 223–226ms；整页首跑 1764ms / 暖跑 1388ms。冷启动整页仍超过 1.5s，归 PP-T032。
- 证据：`build/page-preprocess/p1-device/final-summary.json`、
  `final-p1-device-{off,on}.jpg`、`final-p1-device-{off,on}.preprocess.json`、
  `final-p1-device-repeat.json`、`final-p1-device-bench.json`、
  `build/device-p1-final-{ab,repeat,bench}.xcresult`。

### 通用表格 guard（未裁切页）

- 未裁切页先用 `.enhance` 预览跑一次 `VisionDocumentStructureRecognizer`，表框来源记为 `vision_structure`；漏表时用深色表头块（`content_fallback`）或长横/竖线网格（`grid_fallback`）兜底；全部为空才跳过 P1（`table_guard_unavailable`）。
- 真机未裁切 `IMG_7542`（chosen quad）：guard 1 个表框、guard 696ms、P1 288ms、整页 1276ms；表 `5×2` off/on 各 **6/6**，OCR 1805→1777，归一化字符召回 **99.73%**。
- 裁切路径仍走 `p0_crop_safety`：表 `5×2` 3/3 复测（此前 6/6），P1 269ms。
- 模拟器 `IMG_7544`：结构漏表时 guard source `content_fallback`、保护 3 块、P1 applied；OCR 1794，结构表 0（与 off 持平）。guard 约 2.1s、P1 1.3s（冷启动，PP-T032 暂缓）。
- 真机未裁切表格页的“结构漏检”模拟：content fallback 保护 4 块，P1 后表 `5×2` 6/6，OCR 1792。
- 证据：`build/page-preprocess/p1-guard/final-summary.json`、`build/device-p1-guard4.xcresult`。

### WPS

- 独立 `realUIBaseExportArtifact()` + 新 WPS 渲染：
  `build/word-fidelity/realbase-wps-p1-20261026b/out-restored-realbase-standalone-wps.png`
- SHA-256 与 P0 验收 PNG 完全一致；SSIM **0.906224**，不低于基线。
- P1 只在 `renderPage`，`apply()` / `original-base.jpg` 夹具路径未变；全类顺序跑仍受已知 Vision 表格抖动影响，不得作为基线。

## 7. P2 文字行测量（2026-10-26）

- `PageTextLineAnalyzer` 用 `VNDetectTextRectanglesRequest` 四角估算行角，并写入 `preprocess.json` 的 `textLine*` 字段；不改变像素。
- iPhone 13 `IMG_7542` rendered：70 行、24 个水平带；行角中位 **0.49°**、p90 **1.11°**、max 2.01°。
- 模拟器 `IMG_7544`：71 行、24 带；中位 **0°**、p90 **1.09°**、max 3.83°。
- 模拟器 `IMG_7542`：70 行、24 带；中位 **0.62°**、p90 **1.12°**、max 3.23°。
- 报告集成开销约 **41ms/页**。
- Gate P2 要求中位 ≤0.3°、p90 ≤0.8°；当前未达标，T021 局部水平带矫正尚未接入，不能直接整页旋转（会破坏页边约束）。
- 证据：`build/page-preprocess/p2-summary.json`、`p2-analysis.json`、`p2-integration-summary.json`。
