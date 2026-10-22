# Plan: 引导取景（guided-capture）

**Input**: `spec.md`（US1~US5 / FR-001~010）
**诊断**: `docs/15-capture-recovery-assessment.md`（2026-10-21 代码级复核 + 基线实测）
**实施原则**: 增量路径，不动自动拍摄路径；先取证，再让用户表达意图；WYSIWYG 由构造保证

## 证据锚点（实现与验收判读的依据）

| # | 事实 | 证据 |
|---|---|---|
| E1 | 评分偏好整书：包含降权 ×0.35 + 面积×居中×方正 | `VisionEdgeDetector.swift` `DetectionStrategy.bestCandidate` / `Quad.score` |
| E2 | 粘滞“先稳者胜”可稳定错候选 | `CandidateSticky.swift` 分支④/⑤；`spec/case-b-sticky-v2` |
| E3 | 锁定判据是逐帧差，不是累计漂移；`frameDt=1/15` | `QuadSmoother.ingest` / `init` |
| E4 | 预览可见域为解析钳制，真机出现过 `x_min=0.159 < 0.192` 的矛盾 | `CaptureViewModel.visiblePhotoRect`；`docs/14` 记录 |
| E5 | 引导框当前不可拖 | `EdgeOverlayView.swift` `.allowsHitTesting(false)` |
| E6 | 拍后拆分静默改写 quad，无 UI/撤销 | `ReviewViewModel.refineQuads` / `applySpreadSplitIfNeeded` |
| E7 | 书脊搜索区 0.12–0.88，左折条切点在“第一个持续明亮列” | `SpreadSplitter.searchRange` / `leftFoldTrim` |
| E8 | 真机检测约 29.5fps；基线 397 | 2026-10-17 遥测；2026-10-21 `make test` |
| E9 | `make test` 未指定 OS 会解析到 27.0 而失败 | `Makefile` `DEST_SIM`；本机仅 26.4.1 |
| E10 | WPS 录屏：手动快门；单实线自动跟随框可粗可细；框会在右页/整页间切换；拍后重裁 + 滤镜，左折边靠裁切去除 | `docs/15` §十一；`docs/media/43f328c65e28765077cf4ea9760b44b4.mp4` |

## 设计决策

### D1 增量引导路径，自动模式冻结（FR-001 / FR-009）

- 新增 `CaptureMode`（`.auto` / `.guided`）与 `CaptureIntent`
  （`.rightPage` / `.leftPage` / `.wholePage`），放 `Domain/Models/`；
  `PreferencesStore` 增两个键，默认 `.auto` / `.rightPage`。
- `CaptureViewModel.consume(_:)` 在 guided 下**提前返回**：不跑 detector、
  sticky、smoother、冻结状态机；只保存最近帧引用，供显式自动对位使用。
- `CaptureViewModel.capture()` 在 guided 下走独立分支（D4）；auto 分支逐行
  保持现状。这样回归面被限制在“新增分支”，不需要改自动路径的阈值。
- `CaptureView` 在 guided 下隐藏 `EdgeOverlayView` 的自动框，显示新的
  `GuideOverlayView`；两者不共用交互状态，避免自动框的 `allowsHitTesting`
  与状态语言污染引导框。引导模式隐藏自动四态提示，改为固定对位提示；顶部
  增加“自动/引导”与“右页/左页/整页”入口（证件模式隐藏）。
- 默认仍 `.auto`；只有 SC-008 的 A/B 数据支持时才在后续提交翻转文档模式
  默认值，翻转记录写入 `tasks.md` 与 `docs/12`。

### D2 屏幕 ↔ 照片的显式画布（FR-004）

现有正向链是：

```
照片归一化 → FOVLayout(photo→video) → videoFramePlacement(aspectFill) → 屏幕点
```

引导需要逆向：

```
屏幕点 → 逆 videoFramePlacement → FOVLayout(video→photo) → 照片归一化
```

- 在 `OverlaySpaceMap` 增加 `photoPoint(fromScreenPoint:geometry:viewSize:)`
  与 `photoQuad(fromScreenQuad:geometry:viewSize:)`；复用 `FOVLayout.convert`
  的逆参数，不另写一套宽高比公式。
- 规范存储用**照片空间** `guidePhotoQuad`；屏幕框由正向映射派生。拖动时
  把屏幕角点逆映射后写回；这样 `PageDraft.quad` 与屏幕框天然同源。
- 退化保护：`previewSize` 为零、`videoAspect/photoAspect` 非有限/≤0、
  逆映射后 `Quad.isDegenerate`、round-trip 误差 > 短边 0.5% → 不更新框；
  首次就绪前快门置灰。
- `CameraPreviewAttaching.overlayTransform` 只作诊断对照。若真机长期偏差
  >0.5%，以实际预览 `videoFormat` 修解析链；禁止“探针失效 → 恒等映射”。
- 单测：四角 round-trip、视频/照片同/异宽高比、零/退化输入、屏幕边缘点、
  框完全在可见域内。`OverlaySpaceMapTests` 追加，不改既有断言。

### D3 引导框静止，自动只做一次对位（FR-002 / FR-003 / FR-006）

- 引导状态只有 `guidePhotoQuad`；屏幕框是派生值，不存第二份。
- 改动入口严格限定：拖动角、重置、自动对位。无逐帧吸附、无锁定/解锁、
  无自动快门。
- 拖动约束：保持凸性、照片面积 ≥0.02、屏幕任一边 ≥8% 短边；非法拖动
  回退到上一有效框，并记 `guideAdjust rejected=...`。
- 默认框按屏幕比例给出（右页 0.50…0.98 / 0.12…0.92 等），再逆映射到照片；
  默认框永远在可见预览内，避免“照片比预览宽”导致初始框包含不可见内容。
- WPS 录屏证据（E10）：其框是自动跟随页面，10fps 下平滑，但会在右页/整页间
  切换，快门时也不紧；因此**不增加逐帧吸附/自动移动**。用户手动快门 + 静态
  引导框是本项目更确定的意图表达；WPS 的自动跟随不是本周期要复刻的目标。
- 自动对位：点击时用最近一帧调用一次 `detector.detect(frame:)`，结果经
  视频→照片换算、钳制到可见域后替换框；无候选/退化 no-op。保留一次
  `undoAutoFit` 快照。
- 松手吸附：仅角拖动结束触发一次 `EdgeSnapper.snap(maxShiftRatio: 0.03)`；
  先把 `guidePhotoQuad` 经 `FOVLayout` 换算到视频空间，对最近帧吸附后再
  换算回照片空间；退化/失败保留用户框。吸附结果立即上屏，快门时不再改。
- 翻页/连续拍摄保持框；`setMode`、证件模式、会话结束、画布几何变化时重置。

### D4 引导拍摄 = 引导框（FR-005）

`capture()` 的 guided 分支顺序：

1. 读取当前 `guidePhotoQuad`（缺失/退化 → 不拍，提示重新对位）；
2. `camera.capturePhoto()`；
3. 写原图；
4. `quad = guidePhotoQuad`，**不调用** `detector.detect(imageData:)`，
   **不调用** `CropConsistencyGate`；
5. `PageDraft(quad: guidePhotoQuad, ..., userAdjustedQuad: true)`；
6. 记 `guidedCapture` / `cropQuad(tag:"guide")` /
   `cropGate(displayedArea: guide.area, stillArea: -1, iou: -1,
   acceptedStill: false)`；
7. 复位 phase/闪光，但保留 `guidePhotoQuad`，下一张继续用。

`userAdjustedQuad = true` 复用现有字段，让 `ReviewViewModel.refineQuads`
跳过自动重检/拆分；不新增 `PageDraft` 字段，不做数据迁移。若未来需要区分
“用户拖过”与“引导模式默认框”，再独立加元数据，不在本周期引入。

WPS 式“拍后自动紧裁”不进入 guided 分支：本路径成片 = 引导框。T041 才在
Review 做“框内自动裁边”提案，且必须由用户按钮按需触发、可见、可撤销；
不得把 WPS 的静默换框带回拍摄路径，也不让 `refineQuads` 对引导页自动跑。

### D5 Review 拆分提案，不静默改写（FR-008）

保留既有**身份锚定静帧精修**（`refineQuads` 中对未调整页的 still 重检，
IoU≥0.85 且面积≤拍摄框×1.10）；这是既有契约，不扩出拍摄框。只把**拆分**
从“直接改写 quad”改为提案：

- 新增 `SplitProposal`（值类型，不持久化）：
  `u`、`source`（`.leftFold` / `.spine`）、`prominence`、`continuity`、
  `confidence`、`quadBefore`、`quadAfter`、`selection`。置信度：
  spine = `0.6×clamp((prominence−0.06)/0.09) + 0.4×clamp((continuity−0.70)/0.25)`，
  leftFold = `clamp((stripDepth−0.15)/0.25)`；`clamp` 到 `[0,1]`；`≥0.5` 实线，
  `<0.5` 虚线提示。
- `refineQuads` 仍做 still 精修，然后调用现有 `leftFoldTrim` /
  `analyzeSpine` 生成 proposal；**不写** `drafts[index].quad`。
- `ReviewViewModel` 增 `splitProposal`、`isAdjustingSplit`；
  `applySplit(selection:)` 才写 quad（`.whole` 恢复 `quadBefore`，
  `.left`/`.right` 用 `SpreadSplitter.split`），并置
  `userAdjustedQuad = true`；`undoSplit()` 恢复。切换页、手动改框或删除页
  后清空 proposal，不跨页复用。
- `ReviewView` 增“拆分”工具与 `ReviewSplitCanvas`：在矫正前的原图上画
  可见分割线，可拖 `u`；底部“整页 / 左页 / 右页”+“应用/取消”。
  低置信（接近阈值）用虚线提示，不自动应用；proposal 为 nil 时也给
  “手动拆分”（默认 `u=0.5`）。
- 引导页因 `userAdjustedQuad=true` 不生成 proposal；自动模式整书页照常
  生成，但必须用户确认。
- 单测覆盖：proposal 不修改 quad；应用右/左/整页；撤销；低置信不应用；
  引导页跳过；既有 `SpreadSplitter` 纯函数测试不动。

### D6 Trace / replay 先建真值（FR-007）

- 新增 debug-only `CaptureTrace`（Codable）与 `CaptureTraceRecorder`
  （环形缓冲，默认 10s；release 编译为空实现/不分配）。
- `VisionEdgeDetector` 增加 debug 回调 `onCandidateSnapshot`（默认 nil；
  不改 `EdgeDetecting` 协议签名）：输出全部 viable + top 8 候选四角、面积、
  score、containment、tier、viable；硬上限 16，超出记 `droppedCount`；
  同时保留计数/最大面积。
- `CaptureViewModel` 增可选 `traceRecorder` 注入（init 默认 nil，既有测试
  零改动）；每帧写 timestamp/phase/directive/geometry/previewSize/
  guide/crop；sticky/smoother 输出在现有调用点补记。
- 导出：debug 设置页“导出诊断包”，本地生成 zip（JSON + 原图 + 最近 5s
  低分辨率帧 + 当前截图），走系统分享；不联网。
- Replay 分两层：
  1. `CaptureTraceReplayTests`：读 JSON，重算四角误差/禁止内容入片率/
     锁定延迟/转换次数（不需要相机）；
  2. `CaptureCorpusTests`：12–20 个真实标注图 + `VisionEdgeDetector`/
     `EdgeSnapper` 跑纯函数链，输出同样指标。
- 日志字段名先按 `canvasMap` / `guideAdjust` / `guidedCapture` /
  `reviewSplit` / `candidateDump` 落地；实现时可微调，但 device-acceptance
  的判读字段必须保留。

### D7 测试治理（FR-010）

- 契约测试（不可改）：WYSIWYG、不可见内容不入片、无效框不自动拍、证件/
  导入/导出、纯离线。
- 调参测试（可随 spec 改）：具体阈值、帧数、候选分数；改动必须在
  `tasks.md` 记录理由与旧/新值。
- 本周期预期：自动路径零翻转；Review 拆分从“自动应用”改为“提案”会让
  既有 `ReviewViewModelTests` 中依赖自动拆分的断言方向性翻转，逐条记录。
- 新增测试至少覆盖 spec FR-010 列出的七类；最终计数以 T000 修好的
  `make test` 输出的 xcresulttool 为准。

### D8 基线与构建先行（T000）

- `Makefile`：增加 `SIM_OS ?= 26.4.1`（可覆盖），`DEST_SIM` 使用
  `OS=$(SIM_OS)`；基线打印从 357 改为 397。这样 `make test` 在本机可直接
  跑，不再要求手工拼 `DEST_SIM`。
- 同步 `AGENTS.md` / `docs/12-handover.md` / `spec/scan-enhance/tasks.md`
  的过期计数（386/392/357 → 397；scan-enhance 只加历史说明，不改写 T005）。
- T000 只改构建/文档，不改产品行为；完成后先跑一次全量，确认
  `total=397 passed=396 failed=0 expectedFailures=1`，再开始 T001。

### D9 A/B 决策门（SC-008）

同一台 iPhone 13、同一批场景各 20 张：

| 指标 | 引导 | 自动 |
|---|---|---|
| 成片只含目标页 | 目标 ≥19/20 | 基线记录 |
| 左页/折痕入片 | 目标 0 | 基线记录 |
| 对位 + 拍摄耗时 | 目标 ≤5s | 基线记录 |
| 用户修正次数 | 目标 ≤1/页 | 基线记录 |
| 崩溃/卡顿 | 0 | 0 |

决策规则：

- 引导达到 SC-001/002，且引导耗时不超过自动 +2s → 文档模式默认 `.guided`；
  自动保留为设置项。
- 引导未达标或用户明显抗拒多一步 → 默认仍 `.auto`；按以下顺序开自动
  恢复周期，**不得先调 alpha**：
  1. canvas/坐标真值；
  2. 单状态机（稳定窗口累计范围 + 相对冻结框漂移 + 真实时间戳 + 单一
     显示真值）；
  3. 候选意图/页面侧评分；
  4. 最后才是滤波参数。
- 若目标升级为 WPS 式**自动跟随框**（单实线、手动快门、允许候选切换），
  另立检测/模型/语料周期；不要把它压缩成 sticky/alpha 调参（E10）。
- 无论哪种结果，引导模式都保留可用，不删除。

### D10 范围、回退与后续

- 本周期只做：引导路径、画布映射、trace/replay、Review 拆分确认。
- 不做：自动 sticky/smoother/评分重写、ML 分割、云、Review 全量改版、
  iPad/横屏。
- `document` 增强预设（白平衡/去阴影/锐化/对比）列入 T040 后续小周期；
  WPS 式拍后自动裁边提案列入 T041；两者都不阻塞本周期验收。
- WPS 参考采纳边界（E10）：手动快门、单实线自动跟随框的显示原则、拍后重裁/
  滤镜方向可参考；自动快门、静默换框、逐帧候选优化、生成式去皱不采纳。
  注意 WPS 是自动跟随框，本项目引导模式是固定框，不是同款复刻。
- 回退：设置切回 `.auto` 即恢复现有行为；`PageDraft` schema 不变；
  trace/Review 提案均为增量，无数据迁移。

## 不变式

- `Services/ServiceProtocols.swift` 既有签名零改动；新诊断能力用新协议/
  debug 回调/可选注入。
- 自动模式（`.auto`）的检测、粘滞、平滑、冻结、快门路径零改动。
- 证件模式、相册导入、导出、OCR/还原、条码路径不变。
- 引导路径快门后不重检、不拆分、不改框。
- `PageDraft` 持久化字段不变；复用 `userAdjustedQuad`。
- 纯离线；trace/留样只在本地，用户主动导出。
- 基线只增不减（当前 449 = 448 passed + 1 expected failure + 0 failed）；Review 拆分的必要翻转逐条记录。

## 风险表

| 风险 | 缓解 | 真机观察 |
|---|---|---|
| 屏幕↔照片映射在真机上偏差 | round-trip 测试 + 边缘标记 + `canvasMap` 探针对照；>0.5% 禁用拍摄 | 标记是否入片、逐轴偏差 |
| 默认右页框不符合真实构图 | 默认框只做初值；可拖/重置；A/B 后调比例 | 首屏对位耗时、拖动次数 |
| 用户不愿多一步对位 | 默认框 + 一次自动对位 + 翻页保持；与自动模式 A/B | 对位耗时、放弃率 |
| 自动对位选错候选 | 可撤销；no-op 不阻塞；只跑一次 | 对位后手动修正率 |
| 角手柄遮挡/误触 | 44pt 命中区；只在外侧半区响应；拖动中禁用相机手势 | 误触/遮挡反馈 |
| 画布几何后到导致首拍错 | `previewSize` 就绪前快门置灰；几何变化重置 | 首拍等待时间 |
| Review 拆分改动回归 | 保留 `SpreadSplitter` 纯函数；提案/应用分离；逐条翻转记录 | 提案准确率、撤销率 |
| WPS 式自动裁边误裁 | 只做框内、高置信、可见 Toast + 撤销；T041 后续；本周期不实现 | 折边去除率、内容丢失 |
| trace 影响帧率 | debug-only、环形缓冲、viable+top 8/硬上限 16；release 空实现 | 帧率对比 |
| 基线继续漂移 | T000 修 Makefile + 文档；每次任务后跑局部，阶段末跑全量 | 444→最终计数 |

## 验收流程

1. T000 后跑全量，确认 397 基线（Phase 0 后 417，Phase 1 后 436，Phase 2 后 444）。
2. Phase 0 结束：跑 V1/V2/V3，trace 可导出/回放；未过不得进 Phase 1。
3. Phase 1 结束：模拟器单测 + 真机 20 张引导拍摄；未达 SC-001/002/003/004
   不得进 Phase 2。
4. Phase 2 结束：Review 拆分 10 张 + 撤销；未达 SC-006 不得进 Phase 3。
5. Phase 3：A/B 20+20、回归、L1 取证、文档回填；SC-007/008 全过才可
   翻转默认模式。
6. 任何阶段失败：保留引导模式可用，默认仍 `.auto`；按 D9 的自动恢复顺序
   另开周期，不把本周期改成“再调一轮阈值”。
