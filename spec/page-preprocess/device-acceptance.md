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
