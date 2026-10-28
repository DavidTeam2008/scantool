# Tasks: 取景包络跟踪（capture-envelope-tracking）

**测试基线（2026-10-28）**：518 total / 507 passed / 1 expected / 10 known failures
**构建/测试**：`make test` / `make test-only T=<Suite>` / `make smoke` / `make device-build`

## Phase 1: 包络兜底与显示

- [X] **CF-T001 证据与竞品复核**：视频 5/6 抽帧；结论见 `docs/22`；
  关键帧 `docs/media/capture-ux/video5-*`、`video6-*`。
- [X] **CF-T002 无框消失止血**：`CaptureEnvelopeObservation` /
  `EnvelopeDetecting` / `VisionEdgeDetector.observeEnvelope` /
  `CaptureViewModel.consumeEnvelope`；目标缺失仍显示包络；快门不落 fullImage。
- [X] **CF-T003 tracker 第一版**：`CaptureEnvelopeTracker` 锁定 / hold /
  平滑 / 候选切换确认 / 目标失联回退；`CaptureEnvelopeTrackerTests`。
- [X] **CF-T004 目标页显示**：`outputTargetQuad`；主框实线 + envelope 虚线；
  左页右角在书脊；屏幕外框拒绝；hold 快门置灰。提交 `b7ea065`。
- [X] **CF-T005 拍后输出意图**：`PageDraft.outputIntent`；Review 1600px
  书脊/折页拆分；高置信自动落地 + 低置信预选提案；可撤销。提交 `b7ea065`。

## Phase 2: 真机验收（当前最高优先级）

- [ ] **CF-T006 UI/快门收口**：置信度态、锁定后自动/手动快门、按下冻结
  包络、引导/手动框兜底；保证成片 = 快门瞬间呈现框。
- [ ] **CF-T007 真机与竞品验收**：
  - 视频 5/7 复核（目标框可见、左页右角、无 fullImage 误拍、左右页成片正确）；
  - 20 彩页 + 20 黑白 + 10 A4 + 10 曲面/折页；
  - 按 `docs/22` §六量化；WPS 0.906224 不回退；
  - 清单：`device-acceptance.md`。

## Phase 3: 跟踪增强

- [ ] **CF-T008 光流/单应性传播**：每帧传播上一帧包络，低频观测融合；
  先离线回放视频 5/6，再接主路径；目标单帧跳变 p95 ≤短边 0.5%。

## Phase 4: 观测增强（按需）

- [ ] **CF-T009 传统 Vision 失败率测量**：彩色/曲面/低对比页面分场景统计。
- [ ] **CF-T009b 端侧分割 mask 评估**（仅当 T009 证明不足）：离线、ANE、
  模型体积/时延 A/B；只输出 mask/几何，不做生成式像素。

## 暂停项

- [ ] PP-T032 全流程验收（用户要求暂停）
- [ ] 多条件样张回归（暂停）
- [ ] 全量 flaky 清理（暂停；当前 10 个既有失败）

## 交接提示

- 真机验收前不要继续调 `containmentPenalty` / `epsilon` / `alpha` /
  `CandidateSticky` 阈值；结构性上限已在 `docs/22` 论证。
- 真机失败先保留录屏/Console 日志；证据放 `build/capture-acceptance/<date>/`。
- `docs/media/screenrecord/` 大录像不入 Git；`build/` 证据保留。
