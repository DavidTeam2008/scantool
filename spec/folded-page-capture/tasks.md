# Tasks: 折页书拍摄修复（folded-page-capture）

**Input**: Design documents from `spec/folded-page-capture/`
**Prerequisites**: plan.md（D1~D7）、spec.md（US1~US4 / FR-001~008）
**测试基线**: 368 = 367 passed + 1 known issue + 0 failed，只增不减、既有断言零修改
**构建/测试**: `make test`（全量 + xcresulttool 权威计数）；局部 `make test-only T=<Suite>`

## Format: `[ID] [P?] [Story] Description`

- **[P]**: 可并行（不同文件、无未完成依赖）
- **[Story]**: 归属用户故事；Setup/Foundational/Polish/Verification 无标签

## Phase 1: 默认不自动拍（US4）

- [X] T001 [P] [US4] `Zhixia/App/PreferencesStore.swift`：autoCapture 默认
  true→false（FR-001，零迁移注释落码）；新增
  `ZhixiaTests/PreferencesStoreTests.swift` ×3（默认 false / 显式开启
  升级后保留 / init 不写键）；`CaptureViewModelTests` 两处
  「autoCapture 默认开，须显式关」注释更新（断言零修改）
- [X] T002 [US4] `CaptureViewModel` 可疑锁定门禁整段门控
  `preferences.autoCapture`（FR-002，D2 耦合核查：全部断言该标志的
  测试显式 autoCapture: true）

## Phase 2: 边框检测与实线框稳定（US1+US2）🎯 MVP

- [X] T003 [P] [US2] `VisionEdgeDetector.detectRectangles` live 严格档
  放宽：minSize 0.25→0.15、容差 20°→26°（FR-003，D3：仅 relaxed=false
  分支，still/放宽档零影响）
- [X] T004 [US1] `VisionEdgeDetector` sticky 调用点
  `similarityThreshold: 0.70, missLimit: 5`（FR-004，D4：默认常量不动，
  注释记录 regime c 机理）；`QuadSmoother` 保持默认 3（FR-005 刻意
  非对齐，见翻转记录）
- [X] T005 [P] [US1] `CandidateStickyV2Tests` 追加
  `closeShotRatchetFrozenByCallSiteParams`：近摄 fixture closeSpread
  （IoU(rightPage) ≈ 0.630 ∈ [0.60, 0.70)）显式参数下判跳变走 hold、
  miss 5 帧才逃逸（调用点参数语义钉住）
- [X] T006 [US1+US2] 检查点：`make test-only T=CandidateStickyV2Tests`
  12/12 绿

## Phase 3: 成片=取景框（US3）

- [X] T007 [P] [US3] `EdgeSnapper` 双向两阶段（FR-006，D5）：类型文档
  + `inwardGradientThreshold`/`inwardShiftRatio` 常量 + `edgeShift`
  内向相回落；`EdgeSnapperTests` 追加 ×3（越过真实边缘内拉恢复 /
  超内拉限幅原样返回 / 外向优先相位顺序）
- [X] T008 [US3] `PageDraft.gateRejectedStill` 契约字段（FR-007，D6）+
  `CaptureViewModel.capture()` 置位（文档模式 ∧ 有呈现框 ∧ 弃用静帧）+
  `ReviewViewModel.refineQuads` 跳过置位页；`CropGateAtShutterTests`
  追加 `draftCarriesGateRejectedStillFlag`（三态置位矩阵）；
  `ReviewViewModelTests` 追加 `autoRefineSkipsGateRejectedStill`
  （跳过 + 对照组 refine 确执行）
- [X] T009 [US3] 检查点：`make test-only T=EdgeSnapperTests` 8/8、
  `T=CropGateAtShutterTests` 6/6、`T=ReviewViewModelTests` 5/5、
  `T=PreferencesStoreTests` 3/3 绿

## Phase 4: 全量验证与文档闭环

- [X] T010 `make test` 全量核账：total=377 passed=376 failed=0
  expectedFailures=1（基线 368 + 新增 9：PreferencesStore ×3 +
  EdgeSnapper ×3 + sticky 近摄 ×1 + 门禁标记 ×1 + refine 跳过 ×1）
- [X] T011 周期四件套落盘（spec.md / plan.md / tasks.md /
  device-acceptance.md）+ `spec/feature.json` 指向本周期
- [X] T012 文档同步：docs/12-handover.md（§1.1 周期计数 9+1→10+1、
  §2.x 本周期状态、§5.1 周期表 +folded-page-capture 行、代码规模
  148→149、质量 368→377、更新日期）；docs/09-project-handbook.md
  （同源计数 + 周期指针）
- [ ] T013 [Verification]（已被 `spec/frame-truth` T011 取代）真机验收
  （需设备 + 用户配合）：折页书四痛点复测 + 默认不自动拍核对 +
  合并执行 case-b-sticky-v2 T011 遗留项（Case B 复测 + reconstructPath
  L1 取证）→ 2026-10-17 复测暴露新症状后，验收契约与主清单移交
  `spec/frame-truth/device-acceptance.md`；本项结论不再单独回填

## 方向性翻转记录（铁律 2 例外通道）

**无既有断言修改**——但有一次方案级回退须记录：

- **FR-005 方案回退**：初版按读者建议将 `CaptureViewModel` 的
  `QuadSmoother()` 构造点覆盖为 `missLimit: 5`（与 sticky 调用点对齐），
  全量测试击中 `AutoCaptureHoldWindowTests/holdWindowResetsOnUnlock`
  ——该用例钉住「3 帧 nil 失锁进入 searching」的既有语义。回退为
  默认 3（刻意非对齐，plan D4）：smoother 的 miss 路径只在全帧无检出
  时触发，存在性交替场景下 sticky 每帧回传锚点择优，smoother miss
  本就不触发——同步拉长对本周期目标零收益。既有断言零修改成立。

## 依赖与并行

- T001/T003/T005/T007 互相独立（不同文件）；T002/T004 依赖各自
  Phase 内设计核查（已完成于 recon）
- T006 依赖 T003~T005；T008 内部顺序（字段 → 置位 → 跳过 → 测试）
- T009 依赖 T007/T008；T010 依赖全部实现；T011/T012 依赖 T010；
  T013 依赖全部（需真机）
