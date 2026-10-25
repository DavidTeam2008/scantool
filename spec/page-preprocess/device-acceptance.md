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

## 5. P0 折页/页外裁切结果（2026-10-25）

### 模拟器（全图路径，`IMG_7542.JPG`）

- `cropApplied=true`，`fallbackReason=fold_trim`
- `foldTrimU=0.090`，`foldTrimSource=bright_fold`
- `foldTrimTextLossRatio=5.06%`，`textCoverage=1.0`
- 输出 **1752×2200**
- 左侧折页漫画条、木桌/页边阴影已去除；标题、页码保留
- 证据：`build/page-preprocess/final-p0/after-fold.jpg`、`report-fold.json`

### iPhone 13（iOS 27.0.1）

- `VisionEdgeDetector` 已返回页级四边形（area 0.808），`cropApplied=false`
- 仍残留约 1% 左页边；`leftBrightFoldTrim` 在设备画像上未命中
- 原图 `RecognizeDocumentsRequest` tables=`[]`，裁切后 tables=`[5]`；
  表格同签名 A/B 无法成立，不能把该次结果当作表格安全通过
- 结论：模拟器全图 P0 已闭环；真机页级 quad 的左缘内收/EXIF 感知表格门是下一项

### 下游

- WPS（`original-base.jpg`）**0.906224**，与基线一致
- 证据：`build/word-fidelity/realbase-wps-p0c/out-restored-realbase-wps.png`
