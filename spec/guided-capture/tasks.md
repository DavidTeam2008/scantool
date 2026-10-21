# Tasks: 引导取景（guided-capture）

**Input**: Design documents from `spec/guided-capture/`
**Prerequisites**: `spec.md`（US1~US5 / FR-001~010）、`plan.md`（D1~D10）
**测试基线**: **417 = 416 passed + 1 expected failure + 0 failed**（2026-10-21 实测；
T000 时为 397，Phase 0 新增 20 条诊断/回放用例）
**构建/测试**: T000 前用
`make test DEST_SIM='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4.1'`；
T000 后直接 `make test`。局部：`make test-only T=<Suite>`

## Format: `[ID] [P?] [Story] Description`

- **[P]**: 可并行（不同文件、无未完成依赖）
- **[Story]**: 归属用户故事；Setup/Foundational/Polish/Verification 无标签
- 全部任务初始为未完成；每完成一项改为 `[X]`，并在提交说明里引用 ID

## Phase 0: 基线与真值（US3 / D6 / D8）

- [X] **T000** 修构建基线（D8）：`Makefile` 增加 `SIM_OS ?= 26.4.1` 并让
  `DEST_SIM` 使用 `OS=$(SIM_OS)`；基线打印 357 → 397；同步 `AGENTS.md`、
  `docs/12-handover.md`、`spec/scan-enhance/tasks.md` 的 386/392 过期计数
  （scan-enhance 只加“周期交付时/当前总基线”说明，不改写 T005 历史）。
  验证：直接 `make test`，末尾输出 `total=397 passed=396 failed=0
  expectedFailures=1`。**只改构建/文档，不改产品行为。**
  实测（2026-10-21）：通过，`total=397 passed=396 failed=0
  expectedFailures=1 skipped=0`。
- [X] **T001** [P] `CaptureTrace` 数据模型 + debug 环形缓冲（D6 / FR-007）：
  新增 `Zhixia/Diagnostics/CaptureTrace.swift`、`CaptureTraceRecorder.swift`；
  记录 timestamp/phase/directive/geometry/previewSize/guide/crop/sticky/
  smoother/frozen；默认最近 10s；release 不采集。单测：环形覆盖、Codable
  round-trip、release 空实现不分配。
  **交付（2026-10-21）**：`CaptureTrace.swift`（逐帧事实 + `CaptureTracePayload`）、
  `CaptureTraceRecorder.swift`（10s 时间窗 + 600 条上限 + 候选/帧/原图同缓冲，
  存储整段 `#if DEBUG` → release 零分配）、`CaptureTraceCoding.swift`
  （ISO8601 **带小数秒**——默认 `.iso8601` 只留整秒，会把 67ms 的帧间隔压平，
  锁定延迟判读失真）。单测 `ZhixiaTests/CaptureTraceTests.swift`（6 条）。
- [X] **T002** [P] 全候选落盘（D6 / FR-007）：`VisionEdgeDetector` 增加
  debug 回调 `onCandidateSnapshot`（默认 nil，不改 `EdgeDetecting` 协议）；
  输出全部 viable + top 8 候选四角/面积/score/containment/tier/viable，
  硬上限 16 并记 `droppedCount`；保留并扩展 `candidateProvenance` 计数。
  单测：回调顺序、top 8 截断、droppedCount、nil 默认零开销。
  **交付（2026-10-21）**：`Domain/CandidateSnapshot.swift`（纯数据模型）、
  `Services/Vision/CandidateSnapshotReporting.swift`（**新协议**，`EdgeDetecting`
  签名零改动）、`Services/Vision/CandidateSnapshotBuilder.swift`（纯函数：全部
  viable 优先占位 + top 8 补齐 + 硬上限 16 + `droppedCount`；containment 只与
  **更大**候选比较，与 `isPenalized` 同口径）、`VisionEdgeDetector` 回调
  （DEBUG 编译期、默认 nil = 零开销）+ `ZhixiaLog.candidateDump`。
  单测 `ZhixiaTests/CandidateSnapshotTests.swift`（6 条）。
- [X] **T003** [P] 诊断包导出（D6 / FR-007）：debug 设置页增加“导出诊断包”；
  本地 zip = JSON + 原图 + 最近 5s 低分辨率帧 + 当前截图；系统分享。
  验收：飞行模式可导出；release 不出现入口。依赖 T001。
  **交付（2026-10-21）**：`Diagnostics/CaptureDiagnosticsExporter.swift`（包 =
  `trace.json` + `frames/*.jpg`（1/3 帧采样 ≈10fps，短边 128px）+ `originals/*`
  + `screenshot.png`）、`Diagnostics/ZipArchiveWriter.swift`（**自研 store 模式
  zip**，零第三方依赖、纯本地可离线）、`Features/Settings/DiagnosticsShareSheet.swift`
  （系统分享）、设置页 debug 区块（`#if DEBUG` → release 不出现入口）。
  单测 `ZhixiaTests/CaptureDiagnosticsExportTests.swift`（3 条：包内容齐备 +
  zip 结构用测试内解析器逐条读回 / 空缓冲可导出 / CRC32 已知值）。
- [X] **T004** [P] Replay 基线（D6 / SC-005）：新增
  `ZhixiaTests/CaptureTraceReplayTests.swift` 与
  `ZhixiaTests/CaptureCorpusTests.swift`；读 JSON/标注图，输出四角误差、
  禁止内容入片率、锁定延迟、状态转换次数。依赖 T001/T002。
  **交付（2026-10-21）**：`Diagnostics/CaptureTraceAnalyzer.swift`（四项指标 +
  `CaptureAnnotation` 逐帧目标框/逐帧禁止区域——相机移动时标注随帧移动，
  否则「角点误差」会把场景自身运动算成误差）。
  `CaptureTraceReplayTests.swift`（3 条：JSON 往返后四项指标一致可算 / 无标注
  不猜角点误差 / 短边归一口径）。
  `CaptureCorpusTests.swift`（2 条：12 个场景跑**生产同款纯函数链**
  `DetectionStrategy.select` → `CandidateSticky.apply` → `QuadSmoother.ingest`；
  附正对照）。**合成语料基线**（附件 `capture-corpus-baseline`）：
  `right-page-only` 角点误差 0.0000 / 禁止入片 0 / 9 帧锁定；
  `spread-plus-right` 角点误差 ≈1.05 / **禁止入片 1.00**（整书胜出 → 左页全入片，
  复现 E1）/ 9 帧锁定；`existence-alternation` **永不锁定** / 禁止入片 0.357 /
  状态转换 0（复现 Case B 存在性交替）；`crease-plus-right` 误差 0.0000 /
  禁止入片 0 / 9 帧锁定。
  **缺口**：真实标注图（12–20 张真机样本）待 T005 采集后按同 JSON 结构补入
  （不改断言结构）。
- [ ] **T005** 1 小时真机验证 V1/V2/V3（D6 / docs/15 §九）：V1 屏幕边缘标记；
  V2 全部候选落盘判断右页是否在池；V3 时间戳轨迹复现慢漂移。结果回填
  `docs/15-capture-recovery-assessment.md` §九与 `device-acceptance.md` §0。
  **Checkpoint 0**：T000 全绿 + T001~T004 单测绿 + V1/V2/V3 有结论；
  未过不得进 Phase 1。依赖 T001~T004。
  **状态（2026-10-21）**：T001~T004 已交付（`make test` → 417 = 416 passed +
  1 expected failure + 0 failed）；**V1/V2/V3 待真机会话**（iPhone 13 · iOS 26.7，
  需人工配合 1 小时）——本机无真机，**不得用模拟器结果冒充**。

## Phase 1: 引导框 MVP（US1 / US2）

- [ ] **T010** 取景模式与意图（D1 / FR-001）：新增
  `Zhixia/Domain/Models/CaptureMode.swift`、`CaptureIntent.swift`；
  `PreferencesStore` 增 `captureMode`/`captureIntent` 键（默认 `.auto` /
  `.rightPage`）；`PreferencesStoreTests` 追加默认值/持久化/未知值回退。
  依赖 T000。
- [ ] **T011** 画布逆映射（D2 / FR-004）：`OverlaySpaceMap` 增
  `photoPoint(fromScreenPoint:)` / `photoQuad(fromScreenQuad:)`；
  复用 `FOVLayout.convert` 逆参数。单测 ≥6：四角 round-trip、同/异宽高比、
  屏幕边缘、零/退化输入、越界钳制语义。依赖 T010。
- [ ] **T012** 引导框 UI（D1/D3 / FR-002）：新增
  `Zhixia/Features/Capture/GuideOverlayView.swift`；四边 + 四角 44pt 命中区；
  白实线 + 暗描边；“重置/自动对位”按钮；`CaptureView` 增加“自动/引导”与
  “右页/左页/整页”入口，guided 分支显示引导框、隐藏自动四态提示，auto 隐藏
  引导框；证件模式都不显示。拖动写回 `guidePhotoQuad`，非法拖动回退。
  依赖 T011。
- [ ] **T013** 自动对位与松手吸附（D3 / FR-006）：`CaptureViewModel`
  保存最近帧；`autoFitGuide()` 只调用一次 detector；松手吸附先 photo→video
  再 `EdgeSnapper.snap`（限幅 0.03）后 video→photo；一次撤销快照；
  `guideAdjust` 日志。无候选 no-op。单测：对位成功/无候选/退化/撤销/
  吸附限幅/双空间换算。依赖 T012。
- [ ] **T014** 引导拍摄分支（D4 / FR-005）：`CaptureViewModel.capture()`
  guided 分支直接用 `guidePhotoQuad`；不调用 detector / CropConsistencyGate；
  `PageDraft.userAdjustedQuad = true`；`guidedCapture`/`cropQuad tag=guide`/
  `cropGate stillArea=-1` 日志；拍摄后保留框。单测 ≥4：裁切=引导框、零
  detector 调用、非法框不拍、拍摄后框保持。依赖 T013。
- [ ] **T015** 框生命周期（D3 / FR-002）：翻页/连续拍摄保持；`setMode`、
  证件模式、会话结束、`previewSize` 变化时重置；默认框按 intent 屏幕比例
  生成。单测：模式切换、几何失效、重置、右/左/整页默认位置。依赖 T014。
- [ ] **T016** Phase 1 验证：新增测试全绿；`make test-only
  T=CaptureViewModelTests` + `T=OverlaySpaceMapTests`；模拟器手工走
  “切引导 → 拖角 → 拍 → 切回自动”无崩溃。**Checkpoint 1**：SC-001~004
  的模拟器部分通过；真机 20 张待 T030。依赖 T010~T015。

## Phase 2: Review 拆分确认（US4）

- [ ] **T020** 拆分提案模型与计算（D5 / FR-008）：`ReviewViewModel` 增
  `SplitProposal`（u/source/prominence/continuity/confidence/quadBefore/
  quadAfter）；`refineQuads` 保留身份锚定 still 精修，但拆分只生成 proposal，
  **不写 quad**；引导页（`userAdjustedQuad`）跳过；切换页/改框/删除后清空
  proposal。单测：proposal 不修改 quad、左右/整页应用、撤销、低置信不应用、
  引导页跳过、切换页清空。依赖 T014。
- [ ] **T021** Review 拆分 UI（D5 / FR-008）：`ReviewView` 增“拆分”工具 +
  `ReviewSplitCanvas`（原图、可见分割线、可拖 u、整页/左页/右页、应用/取消/
  撤销）；低置信虚线提示；proposal 为 nil 时提供手动拆分（u=0.5）；
  `reviewSplit` 日志。依赖 T020。
- [ ] **T022** 回归与方向性翻转（D7 / FR-010）：检查 `ReviewViewModelTests`/
  `SpreadSplitterTests`；拆分从自动应用改为提案导致的断言翻转逐条记录在
  下方“方向性翻转清单”；`SpreadSplitter` 纯函数测试零改动。依赖 T021。
- [ ] **T023** Phase 2 验证：10 张整书/折页/导入 fixture 跑提案；统计
  `u` 误差、误裁、撤销率；**Checkpoint 2**：SC-006 通过（0 静默误裁、
  10/10 可修正、8/10 提案 ≤2%）。依赖 T020~T022。

## Phase 3: 真机 A/B、回归与收尾（US5）

- [ ] **T030** 真机主场景（D9 / SC-001~004）：iPhone 13 · iOS 26.7；
  引导模式折页书右页 10 张、摊开书 5 张、平整 A4 5 张；按
  `device-acceptance.md` §1~§3 执行并回填。依赖 T016。
- [ ] **T031** A/B（D9 / SC-008）：同一场景引导 20 张 vs 自动 20 张；
  记录成片正确率、耗时、修正次数；填写 `device-acceptance.md` §8；
  给出默认模式建议。依赖 T030。
- [ ] **T032** 文档与默认值（D9 / D10）：根据 T031 决定是否翻转默认
  `captureMode`；更新 `docs/12-handover.md` §1/§3/§5、`AGENTS.md` §1/§5/§6、
  `docs/14` 顶部指针、`spec/feature.json`。若翻转，记录旧/新默认值与依据。
  依赖 T031。
- [ ] **T033** L1 真机取证（并行，SC-007）：按
  `spec/wps-parity-layout/device-acceptance.md` §A 跑 `reconstructPath`；
  结论回填该文件与 `device-acceptance.md` §7。依赖 T030（同会话）。
- [ ] **T034** 性能与回归（SC-007）：引导模式帧率/拍摄延迟/内存；自动/
  证件/导入/导出/条码真机回归；`make test` 最终计数；**Checkpoint 3**：
  SC-001~008 全部有结论，0 failed。依赖 T030~T033。

## Phase 4: 后续（不阻塞本周期）

- [ ] **T040** `document` 增强预设（白平衡 + 去阴影 + 锐化 0.35 + 轻度对比）：
  独立小周期；与 WPS 同页成片对比（亮度/对比/饱和度），再决定是否设为默认；
  现在 `.enhance` 的 `saturation=0.9` 不能直接当“WPS 同款”。本周期只保留
  TODO，不实现、不写入 SC。依赖 T034 之后单独立项。
- [ ] **T041** WPS 式拍后自动裁边提案（后续，不阻塞）：在 Review 的
  身份锚定重检结果上（引导页则由按钮触发一次重检），只接受**落在拍摄/
  引导框内**且高置信的页面四边形（建议 IoU ≥0.90、四角在框内容差 2% 内、
  面积 ≤ 拍摄框），生成
  “自动裁边”提案；显示 Toast/横幅 + 撤销，**不静默改 quad**。引导页
  `userAdjustedQuad=true` 不随 `refineQuads` 自动跑；由 Review 的“自动裁边”
  按钮按需触发一次检测，结果仍只是提案。10 张折页样本目标 ≥8/10 去折边、
  0 内容丢失、10/10 可撤销。复用现有 detector/`SpreadSplitter`，不改
  `ServiceProtocols`；与 WPS 同页对照。依赖 T034 之后单独立项。

## 依赖图

```text
T000 ─┬─ T001 ─┬─ T003 ─┐
      │        └─ T004 ─┴─ T005
      ├─ T002 ─┘
      └─ T010 ─ T011 ─ T012 ─ T013 ─ T014 ─┬─ T015 ─ T016 ─ T030 ─┬─ T031 ─ T032
                                            │                       ├─ T033
                                            └─ T020 ─ T021 ─ T022 ─ T023 ─ T034
```

T040 / T041 在 T034 之后单独立项，不计入本周期依赖图与验收门。

## 方向性翻转清单

预期：自动路径零翻转。Review 拆分从“自动应用”改为“提案”若导致既有断言
翻转，逐条记录：

| 测试 | 旧断言 | 新断言 | 理由 | 任务 |
|---|---|---|---|---|
| （待填） | | | | |

## 验收门

1. **Checkpoint 0**：`make test` 417 基线可复现；trace 可导出/回放；V1/V2/V3
   有结论。
2. **Checkpoint 1**：引导拍摄 20/20 只含框内内容；框零自动移动；画布
   round-trip ≤0.5%；引导路径无 detector 调用。
3. **Checkpoint 2**：0 次静默误裁；10/10 可修正；8/10 提案 `u` 误差 ≤2%。
4. **Checkpoint 3**：A/B 完成；回归全绿；默认模式决策有数据；L1 有结论。
