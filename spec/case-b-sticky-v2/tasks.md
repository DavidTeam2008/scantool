# Tasks: Case B 粘滞 v2 hold-through-miss（case-b-sticky-v2）

**Input**: Design documents from `spec/case-b-sticky-v2/`
**Prerequisites**: plan.md（D1~D5）、spec.md（US1~US3 / FR-001~005）
**测试基线**: 357 = 356 passed + 1 known issue + 0 failed，只增不减、既有断言零修改
**构建/测试**: `make test`（全量 + xcresulttool 权威计数）；局部 `make test-only T=CandidateStickyV2Tests`

## Format: `[ID] [P?] [Story] Description`

- **[P]**: 可并行（不同文件、无未完成依赖）
- **[Story]**: 归属用户故事；Setup/Foundational/Polish/Verification 无标签

## Phase 1: Foundational（粘滞 v2 核心）

- [X] T001 修改 `Zhixia/Services/Vision/CandidateSticky.swift`（plan D1/D3）：
  `apply` 追加 `holdThroughMiss: Bool = false` 参数；分支⑤ v2 下 miss
  窗口内返回锚点择优（达限仍清锚逃逸）；新增 `lastTier` 随锚存储、
  `Disposition` 嵌套枚举 + `private(set) lastDisposition`、`missCount`
  放宽 `private(set)`、新增 `reset()`（plan D2 备用品，still 路径不接线）
- [X] T002 修改 `Zhixia/Services/Vision/VisionEdgeDetector.swift`（plan D1/D3）：
  live 文档路径调用点传 `holdThroughMiss: true`；日志按 `lastDisposition`
  接线（`.override`→`stickyOverride` / `.hold`→`stickyHold` /
  `.escape`→`stickyEscape`）；still/idCard 路径零改动、sticky 不复位（D2）
- [X] T003 修改 `Zhixia/Services/ZhixiaLog.swift`（plan D3 / FR-004）：新增
  `stickyHold(missCount:heldArea:selectionArea:)` 与 `stickyEscape(afterMisses:)`
  （debug + privacy.public，与 `stickyOverride` 同区同风格，含判读注释）

## Phase 2: User Story 1+2 - 存在性交替稳定与逃逸（Priority: P1）🎯 MVP

**Goal**: A/B 池互斥交替下输出不翻转、可锁定；真移场 ≤3 帧逃逸
**Independent Test**: `CandidateStickyV2Tests` 交替序列 + 逃逸序列全绿

- [X] T004 [P] [US1] 新增 `ZhixiaTests/CandidateStickyV2Tests.swift` 交替组：
  存在性交替稳定（hold 帧返回锚点、输出不翻转）/ 集成：交替经 sticky v2
  后 smoother 锁定窗内锁定且锁定对象为右页 / 集成对照：无 sticky 交替
  smoother 永不锁定（Case B 机理钉住）
- [X] T005 [P] [US2] 同文件逃逸组：hold 窗口边界（miss 1~2 hold、3 达限
  透传清锚、重新起锚、探针帧不粘旧锚）/ hold 期间锚点回归 miss 清零 /
  nil 间隙混合计数达限逃逸
- [X] T006 [P] 同文件形态组：hold 帧 tier 随锚 / disposition 逐帧可辨
  （anchored/hold/follow/override/gapMiss/escape）/ 默认参数 v1 透传锚定
  （门控回归）/ reset 语义
- [X] T007 [US1+US2] 检查点：`make test-only T=CandidateStickyV2Tests`
  10/10 绿（build/last-test.log）

## Phase 3: User Story 3 - 手动拍收敛验证（Priority: P1）

**Goal**: 呈现框稳定后门禁既有契约自然裁对（门禁/快门零改动，plan D4）
**Independent Test**: 既有 CropGateAtShutterTests 全绿（契约不变证明）

- [X] T008 [US3] `make test` 全量验证：total=368 passed=367 failed=0
  expectedFailures=1（审查 C1 修复 +1 用例后复跑核账）——基线 357 只增不减、既有断言零修改（含
  `CropGateAtShutterTests` 跟踪态手动拍→成片=呈现框用例）

## Phase 4: 文档同步与真机验收闭环

- [X] T009 周期四件套落盘：spec.md（FR-001~005 / SC-001~004）、plan.md
  （D1~D5 + 不变式 + 风险表）、tasks.md（本文）、device-acceptance.md
  （真机复测步骤与日志判读）；`spec/feature.json` 指向本周期
- [X] T010 文档同步：docs/12-handover.md §2.2 状态更新（代码级修复交付、
  真机复测待做）+ 更新日期；docs/09-project-handbook.md 诊断日志清单
  补 `stickyHold`/`stickyEscape`
- [ ] T011 [Verification] 真机复测（需设备 + 用户配合，按
  device-acceptance.md）：Case B ≤5s 稳定不跳可锁定 / 手动拍成片=呈现框
  不含左页 / `stickyHold`+`stickyEscape`+`cropGate` 日志归档 / 同会话顺带
  `reconstructPath`（L1 取证，docs/12 §2.4）→ 结论回填
  device-acceptance.md 与 docs/12 §2.2/§2.4

## 对抗性审查修复记录（2026-10-17，工作流 wf_7adfd005-81b）

五维审查（状态机/铁律/测试质量/接线/文档一致），23 代理、17 张验证票
全部 `refuted=False`，去重后 6 项 confirmed（0 contested / 0 refuted）：

- [X] R001 **C1（代码，minor）**：分支①达限清锚后 missCount 不复位，持续
  nil 间隙逐帧重发 `stickyEscape` 且 afterMisses=4,5,… 无界爬升（仅日志
  通道，状态机无功能回归）→ 修复：逃逸判定加 `lastPick != nil` 守卫
  （锚点真实放弃仅判一次，之后回落 gapMiss）；新增用例
  `escapeFiresOncePerAnchorLoss`；`ZhixiaLog.stickyEscape` 文档补
  「每次锚点放弃仅一条」契约。既有断言零修改（无测试钉第 4+ 帧 nil）。
- [X] R002 **C2（文档）**：docs/12 §代码规模 147（107/40）→ 148（107/41）。
- [X] R003 **C3（文档）**：docs/12 §1.1 标题「8+1」→「9+1」
  （agent-handover 22/22 已收尾，进行中 = 本周期真机复测）。
- [X] R004 **C4（文档）**：docs/12 §5.1 标题计数 + 补 case-b-sticky-v2 行。
- [X] R005 **C5（文档）**：docs/09 诊断日志清单结尾指针补
  `spec/case-b-sticky-v2/device-acceptance.md`；同源计数漂移一并修
  （docs/09 头部/目录树/§6 质量行 357→368、40→41 文件、9→10 周期）。
- [X] R006 **C6（文档）**：device-acceptance §0 补 `category:reconstruct`
  检索口径（§4 `reconstructPath` 不在 capture 通道）；§1 `stickyEscape`
  判读补 nil 间隙豁免（单条 afterMisses=3 属设计内间隙逃逸）。

## 方向性翻转记录（铁律 2 例外通道）

**无**——本周期通过参数门控（plan D1）实现零既有断言修改：
`holdThroughMiss` 默认 false 保持 v1 语义，`CandidateStickyTests` ×5
原样全绿；v2 行为全部由新增 `CandidateStickyV2Tests` ×11 钉住（含审查
C1 逃逸一次性用例——该修复仅收紧「无锚点持续间隙」的 disposition 判定，
无任何既有断言触及，同样零修改）。

## 依赖与并行

- T001 → T002（调用点依赖新参数）；T001 → T004~T006（测试依赖实现）
- T003 与 T001/T002 可并行（日志通道独立）；T004/T005/T006 同文件顺序执行
- T008 依赖 T001~T007；T009/T010 依赖 T008；T011 依赖全部（需真机）
