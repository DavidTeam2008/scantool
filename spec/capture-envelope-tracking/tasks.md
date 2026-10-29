# Tasks: 取景包络跟踪（capture-envelope-tracking）

**测试基线（2026-10-28）**：531 total / 520 passed / 1 expected / 10 known failures
（CF-T010/T011 实施后按新增用例更新 `Makefile` 基线；预计 +10~15 条）
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
- [X] **CF-T005b 视频 8 回归修复（2026-10-28）**：
  - `PageDraft.quadRole`（target/envelope）由快门快照写入；Review 不再用
    宽高比猜“是否目标页”，`.envelope` 必须尝试拆分；
  - `SpreadSplitter.analyzeGutter` 亮缝模型（列亮度均值），spine 失败后
    作为第二模型；接入实时 `PageIntentResolver`（含裁掉的整摊）与拍后
    Review；
  - 新增 `SpreadSplitterGutterTests` 4 条、`PageIntentResolverTests` +1、
    `ReviewSplitProposalTests` +3；全量 **526/515/1/10**；
  - 证据 `build/cf-t007/video8/`；真机复测待做。
- [X] **CF-T005c 视频 9 目标一致性（2026-10-28）**：
  - 设备日志确认 `reviewSplit proposalU=0.7594 source=gutter confidence=0.438`
    是右页栏间距误拆；拍下的仍是整摊包络；
  - 亮缝搜索限定 [0.30,0.70]（同一包络的真实亮缝 u≈0.509）；
  - `acceptTarget`：包络包含 + 意图侧 + 宽高比 0.45~1.10 + 面积 ≥8%；
  - 书脊暗谷宽度上限 20%（宽暗区是插图/照片，不是书脊）；
  - 拆分目标面积门 15% → 8%（小书/远距离一页只占 8%~12%）；
  - 实时 `cropQuad tag=target-<intent>` / `envelope` 变化日志；
  - 新增 4 条测试；全量 **531/520/1/10**；真机复测待做。

## Phase 2: 取景域 WYSIWYG（2026-10-29 新根因，最高优先级）

> 视频 11/12：预览 aspectFill 只显示 4:3 帧的 61.6% 宽，检测/成片用整帧。
> 在 T010 落地前，不要再调 `acceptTarget` 面积/宽高比或 tracker 阈值。

- [~] **CF-T010 取景域 = 成片域**（代码已落，真机复测待做）：
  - [X] **T010.1 `ViewfinderLayout` 纯函数 + 测试**：输入容器尺寸与视频宽高比，
    输出取景窗矩形（保持宽高比、宽度优先、超高时高度优先）；390×844 + 0.75
    → 390×520；0.5625 → 390×693.3；退化输入不崩溃。
  - [X] **T010.2 `CaptureView` 重构**：取景窗容器（预览 + `EdgeOverlayView` +
    `GuideOverlayView` + 闪光）按 `ViewfinderLayout` 布局；模式/意图/提示/
    快门移到窗口下方（原生相机形态）；`previewSize` = 取景窗尺寸；
    overlay 坐标与预览同容器。
  - [X] **T010.3 预览层与几何**：`AVCameraSession.bindPreview` 改
    `.resizeAspect`；容器宽高比 == 视频宽高比 → `OverlaySpaceMap` 的
    aspectFill 恰好铺满（公式与既有断言不变）；`visiblePhotoRect` 变成全幅，
    钳制路径保留为防御但不再依赖；取景窗尺寸由既有
    `overlayProbeAnalytic viewSize=...` 日志读出。
  - [X] **T010.4 完整性门（D13）**：`isClippedAtFrameEdge`（1.5% 边距）；
    整页意图包络被裁 → 不画实线 + 快门置灰 + 提示“后退，让整页入框”；
    左/右页目标除书脊侧外被裁 → 同样不就绪；新增
    `CaptureFrameClippingTests`；提示复用既有
    `capture.hint.suspicious`（“再往后移一点，把书拍完整”），不新增文案。
  - 新增测试：`ViewfinderLayoutTests` 5 条、`CaptureFrameClippingTests` 5 条、
    `CaptureEnvelopeViewModelTests` +2 条；2026-10-29 全量 **543 / 532** 已确认。
  - [ ] **T010.5 真机验收**：装机后按 `device-acceptance.md` §1.4 复测
    视频 11/12 同场景；确认照片 FOV == 视频 FOV（标记物法）；记录
    `cropQuad tag=envelope/target-*`；更新 `Makefile` 基线与证据目录
    `build/cf-t010/`。
- [~] **CF-T011a 近距单页裁切门（2026-10-29，视频 14/13；代码已落，真机复测待做）**：
  - `isFrameClipped` 区分**单页 / 整摊**：整页意图下单页被裁 → 允许拍；
    整摊/整书被裁 → 仍置灰（视频 12）；左/右页目标页单页被裁 → 允许；
  - 左/右页目标缺失 → 允许拍包络回退（Review 拆分），不再因整摊贴边把
    整个取景变成不可拍（视频 13 实线/虚线抖）；
  - 呈现框顶点越出照片域时，快门裁切框 `clamped()` 到 [0,1]；
  - 提示与快门一致：`isCaptureReady && overlayIsLocked` → “已对准”；
  - 新增 4 条测试（整摊被裁仍拦 / 近距单页可拍且钳制 / 目标缺失回退 /
    目标页贴边可拍 / `isSinglePageForCapture` 单页-整摊判定）；
    全量 **547 total**（T010 543/532 + 4）；本次 541 passed / 5 failed（均为既有债）。

- [ ] **CF-T010b 拍后逐边包含**：`refineQuads` 用逐边包含（+1% 容差）替代
  “面积 ≤1.10× + IoU ≥0.85”；不满足保留拍摄框并记
  `refineRejected=outsideCapture`；新增 `ReviewRefineContainmentTests`。
- [ ] **CF-T011 贴边单页（T010 真机复测通过后）**：
  - [ ] **T011.1 合成纯函数 + 测试**：左/右页意图、书脊侧边在帧边界 ±1.5%、
    其余三边可见、对页不在帧内 → 上/下边线与帧边界交点合成书脊侧两角；
    覆盖 <60% 帧高、两边被裁、对页入框 → nil；`FlushEdgeTargetTests`。
  - [ ] **T011.2 实时接入 + UI**：目标页书脊侧被裁时进入贴边态；1.5% 内缩
    引导线 + “贴边”徽标；未对齐快门置灰；整页意图禁用。
  - [ ] **T011.3 Review 角色**：贴边目标写 `quadRole = .target`，不再拆分；
    日志 `cropQuad tag=target-<intent>` 带 `flushEdge=true`。
  - [ ] **T011.4 真机验收**：视频 12 场景（右页贴左边界 / 左页贴右边界），
    成片不含对页内容；记录 `build/cf-t011/`。

## Phase 3: 真机验收（T010 之后）

- [ ] **CF-T006 UI/快门收口**：置信度态、锁定后自动/手动快门、按下冻结
  包络、引导/手动框兜底；保证成片 = 快门瞬间呈现框。
- [ ] **CF-T007 真机与竞品验收**：
  - 视频 5/7 复核（目标框可见、左页右角、无 fullImage 误拍、左右页成片正确）；
  - **视频 8（2026-10-28）左页失败已定位并修复代码**：左页只有左上/左下角、
    成片保留整摊包络、右页左栏漏入；修复见 CF-T005b；
  - **视频 9（2026-10-28）左右实线框定位失败**：页内栏间距/画面边缘成为目标；
    修复见 CF-T005c，待真机复测；
  - 20 彩页 + 20 黑白 + 10 A4 + 10 曲面/折页；
  - 按 `docs/22` §六量化；WPS 0.906224 不回退；
  - 清单：`device-acceptance.md`。

## Phase 4: 跟踪增强

- [ ] **CF-T008 光流/单应性传播**：每帧传播上一帧包络，低频观测融合；
  先离线回放视频 5/6，再接主路径；目标单帧跳变 p95 ≤短边 0.5%。

## Phase 5: 观测增强（按需）

- [ ] **CF-T009 传统 Vision 失败率测量**：彩色/曲面/低对比页面分场景统计。
- [ ] **CF-T009b 端侧分割 mask 评估**（仅当 T009 证明不足）：离线、ANE、
  模型体积/时延 A/B；只输出 mask/几何，不做生成式像素。

## 暂停项

- [ ] PP-T032 全流程验收（用户要求暂停）
- [ ] 多条件样张回归（暂停）
- [ ] 全量 flaky 清理（暂停；当前 10 个既有失败）

## 交接提示

- 先做 T010；在取景域修好前不要继续调 `containmentPenalty` / `epsilon` /
  `alpha` / `CandidateSticky` 阈值；结构性上限已在 `docs/22` 论证。
- T010 的 UI 布局（4:3 取景窗 + 控制区下移）需要真机截图确认；模拟器无相机，
  只能验证构建/纯函数/布局占位。
- 真机失败先保留录屏/Console 日志；证据放 `build/capture-acceptance/<date>/`。
- `docs/media/screenrecord/` 大录像不入 Git；`build/` 证据保留。
