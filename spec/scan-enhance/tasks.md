# Tasks: 拍后增强（scan-enhance）

**测试基线（周期交付时）**：392 = 391 passed + 1 expected failure + 0 failed
**当前总基线**：397 = 396 passed + 1 expected failure + 0 failed（2026-10-21 实测；
本文是历史周期记录，T005 的 392 不改写）
**构建/测试**：`make test` / `make test-only T=<Suite>`

## Phase 1: 拍后重检与拆分

- [X] T001 `ReviewViewModel.refineQuads` 重写：全分辨率静帧重检 + 身份锚定
  （IoU ≥ 0.85；`.fullImage` 例外）；删除 `cropIsFinal` 跳过语义
  （字段一并移除：`PageDraft`/`CaptureViewModel`/`ReviewViewModel`）
- [X] T002 `SpreadSplitter`（Domain 纯函数）：书脊暗谷检测
  （u∈[0.32,0.68]、谷深≥0.06、160 列双线性栅格）+ `split(at:)` +
  `pixelAspect`；`SpreadSplitterTests` ×4（合成摊开书/纯色/拆分几何/宽高比）
- [X] T003 整理页接线：`applySpreadSplitIfNeeded`（透视矫正 + 书脊谷 →
  右页）+ 直立 CIImage 加载（EXIF 方向）；`reviewSplitsSpreadToRightPage`
  集成用例（合成书脊 JPEG + 固定静帧检测器）
  - 2026-10-21 真机复盘：首版在四边形空间 28 列采样，书脊暗带（~1.5% 页宽）
    被均值稀释/漏检，整轮未触发拆分 → 改**透视矫正矩形图密集列扫描**
    （0.6% 步长）+ V 形/贯穿性/谷宽/分辨率四闸；见 plan D2/D4 修订
- [X] T003b `refineStage` 遥测（每页一行）——下一轮真机可直接读出
  captured/still/iou/accepted/aspect/spineU/prominence/continuity/split
- [X] T004 既有用例调整：`autoRefineSkipsGateRejectedStill` 更名为
  `autoRefineKeepsCaptureFrameOnIdentityMismatch`（断言不变：身份不符页
  保留拍摄框、`.fullImage` 对照组被 refine）；`frameTruthDraftMarksCropFinal`
  改写为 `capturePathRedetectMatrix`（有呈现框不重检 / 搜索态重检一次）

## Phase 2: 真机复盘追加（2026-10-21）

- [X] T007 用用户实拍照片（本地诊断，已删除临时用例）验证剖面：修正「暗谷
  模型不适配左折条」——新增 `leftFoldTrim`（左侧持续明亮列 + 暗条宽度/暗度
  闸）；review 接线两模型互补；`SpreadSplitterTests` +2、review 集成 +1
- [X] T008 锁定迟滞 `QuadSmoother.unlockEpsilon`（live 3%）：
  `lockHysteresis` 用例（2% 不解锁 / 6% 解锁）；既有用例零翻转
- [X] T009 `refineStage` 增记 reason/trimU/trimDepth（拒因可读）

- [X] T010 **预览可见域钳制**（FR-004）：`previewSize` + `visiblePhotoRect` +
  逐顶点钳制（呈现框/冻结框/裁切同源）；`onGeometryChange` 上报视图尺寸；
  整理页重检「面积 ≤ 拍摄框×1.10」闸；`previewClampExcludesInvisibleContent`
  用例（390×844 视图 → 可见 x∈[0.19,0.81]）
- [X] T011 书脊改**局部凹陷评分**（左右 4% 邻域）；既有 6 例零翻转

## Phase 2b: 验证与文档

- [X] T005 `make test` 全绿（392；新增：SpreadSplitter ×4 + 整理页拆分 ×1）
- [ ] T006 真机验收（`device-acceptance.md`）：场景 1 自动拆右页 /
  场景 2 左缘贴书脊 / 可拖角修正 / 清晰化观感

## 方向性调整记录（铁律 2 通道）

- `frameTruthDraftMarksCropFinal` → `capturePathRedetectMatrix`：`cropIsFinal`
  字段移除（其「整理页不得重检」语义被「整理页可见的拍后增强」取代）。
  断言重写为快门路径三态矩阵（有呈现框不重检、搜索态重检一次）。
- `autoRefineSkipsGateRejectedStill` → `autoRefineKeepsCaptureFrameOnIdentityMismatch`：
  仅更名与注释（断言零修改）——「跳过」的依据从门禁标志变为身份锚定。
