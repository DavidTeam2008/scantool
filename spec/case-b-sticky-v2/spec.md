# Feature Specification: Case B 粘滞 v2 hold-through-miss（case-b-sticky-v2）

**Created**: 2026-10-17
**Status**: Implemented（代码与单测交付；真机复测待做）
**Input**: docs/12-handover.md §2.2（Case B 两轮修复未达效）+ 2026-10 用户最新反馈
（「实线框持续跳动有改善，其它的问题都还在」——同池共存帧已被 v1 吸收，
存在性交替帧仍在跳；手动拍成片含左页大半未消）+ 四路代码级取证
（检测候选管线 / 粘滞与平滑 / 快门裁切路径 / spec 契约）：

- **根因定案（代码级证据链）**：摊开书场景下三级检测的两个条件门控
  （`DetectionStrategy.needsDocumentSegmentation` /
  `needsRelaxedRectangles`，VisionEdgeDetector.swift）使 live 候选池逐帧
  **近似单源**——矩形成功帧池里只有右页矩形（整书分割被跳过），矩形落空帧
  池里只有整书分割候选。两候选以**存在性交替**（一帧池里只有 A、下一帧
  只有 B）出现时，`CandidateSticky` v1 的同池续锚分支（④）结构性不触发，
  恒走分支⑤ miss 透传；交替回摆帧又走分支③把 missCount 清零——
  **missCount 在 0↔1 间振荡，逃逸限永不触达，锚点既不保护也不清空**，
  输出逐帧翻转。下游 `QuadSmoother` 收到的不是 nil 而是翻转 quad（面积比
  ≈2.35 > areaJump 0.35），每帧重置 stableTime → 实线框持续跳动、永不锁定。
- **`stickyOverride` 日志两轮未取得的原因**：该日志仅在分支④改写帧发射，
  miss 路径零遥测——存在性交替下分支④从不执行，日志缺席恰是池交替假设
  的**预测结果**（而非反证）。可观测性缺口本周期补齐。
- **C4（手动拍含左页大半）定性**：下游症状而非独立缺陷。振荡期
  `capture()` 快照的 `imageQuad` 是整书帧 / smoother 插值混合帧（alpha
  0.35——「左边很大部分都近图片」的几何解释）/ 搜索态 nil；
  `CropConsistencyGate` 对三种输入都按契约忠实工作。修好振荡 → 呈现框
  稳定为右页 → 门禁 IoU≈0.43 < 0.70 判不一致、呈现框优先 → 成片自然正确。
  **门禁与快门路径不动。**

## Overview

摊开书从中线取景拍右页时，实线框必须在 ≤5s 内稳定贴住单一候选（先稳者胜）
并完成锁定，不再逐帧跳动；此时手动快门的成片必须等于屏幕呈现框所框范围。
本周期把 `CandidateSticky` 升级为 v2 **hold-through-miss**：miss 窗口内
（池中连续 < missLimit 帧无锚点相似候选）维持锚点择优而非透传新择优——
与 `QuadSmoother` 既有的 miss 保留语义对齐；达限仍清空锚点逃逸
（FR-007 不粘死）。改动以参数门控交付（默认 v1 语义），既有测试断言零修改；
补齐 miss/hold/escape 三路结构化日志，使下轮真机复测一趟即可判读制式。

## User Scenarios & Testing *(mandatory)*

### User Story 1 - 存在性交替下实线框稳定可锁定（Priority: P1）

摊开书从中线取景，右页矩形与整书外轮廓两候选以存在性交替出现（一帧池里
只有右页、下一帧只有整书）。实线框应稳定贴住先稳定的候选（先稳者胜），
在既定锁定时长（0.55s）内完成锁定，不再逐帧翻转。

**Why this priority**: 这是 Case B「实线框持续跳动」的根治。v1 只吸收同池
共存交替（用户反馈「有改善」的部分），存在性交替是其结构性盲区。

**Independent Test**: 单测模拟 A/B 帧池互斥序列（池=[右页]→[整书]→[右页]…）
经 sticky v2 + smoother 端到端：输出不翻转、smoother 在锁定窗内锁定且
锁定对象为右页。

**Acceptance Scenarios**:

1. **Given** 锚点为右页、本帧池里只有整书（无锚点相似候选），**When** sticky
   v2 判定，**Then** 返回锚点择优（quad + tier 随锚），呈现框不跳变
2. **Given** 持续 A/B 存在性交替，**When** 经 sticky → smoother 链路，
   **Then** smoother 在 0.55s 稳定窗内进入锁定态且锁定对象为右页
3. **Given** 同池共存交替（v1 已吸收的场景），**When** 池中有锚点相似候选，
   **Then** 改写分支（④）行为不变（先稳者胜、评分最高者）

---

### User Story 2 - 真移场按时逃逸、不粘死（Priority: P1）

用户明显改变取景（右页离开视场、画面只剩整书）时，框必须在约 0.2s
（missLimit=3 帧 @15fps）内跟随切换，不得粘死在旧候选上；hold 期间锚点
候选回归时立即恢复跟随（miss 清零）。

**Why this priority**: hold-through-miss 加大粘滞强度，逃逸路径（FR-007）
是防「粘死」的唯一闸门，必须与止跳同周期钉死。

**Independent Test**: 单测模拟连续 3 帧池=[整书]：前 2 帧 hold 锚点、第 3 帧
透传整书并清锚、第 4 帧重新起锚；nil 间隙与池 miss 混合累计达限同样逃逸。

**Acceptance Scenarios**:

1. **Given** 锚点为右页，**When** 连续 2 帧池中无相似候选，**Then** 两帧均
   维持锚点（hold），miss 计数 1→2
2. **Given** 同上，**When** 第 3 帧仍无相似候选，**Then** 清空锚点并透传
   整书（逃逸），后续帧重新起锚
3. **Given** hold 窗口内（miss=1~2），**When** 锚点候选重新成为择优，
   **Then** 相似跟随、miss 清零（持久交替永不误判为用户移场）
4. **Given** hold 与检测间隙（selection=nil）混合出现，**When** 合计达限，
   **Then** 同样逃逸（两路径共用 miss 计数）

---

### User Story 3 - 手动抢拍成片 = 呈现框（Priority: P1）

摊开书取景框稳定贴住右页后，用户手动快门（不等锁定）的成片必须等于
拍摄瞬间屏幕呈现框所框范围——不含左页。

**Why this priority**: 这是用户可感知的最终验收（「手动拍，左边很大部分都
进图片」的消除）。本周期不动门禁与快门路径：呈现框稳定后，既有
`CropConsistencyGate` 契约（IoU < 0.70 判不一致、呈现框优先）自然产出
正确裁切。

**Independent Test**: 既有 `CropGateAtShutterTests`「跟踪态手动拍→成片 =
呈现框」用例保持绿（契约不变）；真机复测 Case B 手动拍成片对照呈现框。

**Acceptance Scenarios**:

1. **Given** 摊开书框稳定贴住右页（跟踪或锁定态），**When** 手动快门，
   **Then** 成片为右页内容、不含左页
2. **Given** 快门静帧检出整书（与呈现框 IoU ≈ 0.43 < 0.70），**When** 门禁
   判定，**Then** 呈现框优先、整书静帧弃用（既有契约，零改动）

---

## Functional Requirements *(mandatory)*

- **FR-001**: `CandidateSticky` MUST 支持 hold-through-miss（v2）：池中无锚点
  相似候选且 miss 未达限时，返回锚点择优（quad 与 tier 均随锚）而非透传
  本帧择优。
- **FR-002**: v2 MUST 保留逃逸路径（FR-007）：连续 miss 达 missLimit（默认
  3 帧，含 selection=nil 的检测间隙，两路径共用计数）即清空锚点并透传
  新择优；hold 期间锚点候选回归 MUST 立即恢复相似跟随（miss 清零）。
- **FR-003**: v2 MUST 以参数门控交付（`holdThroughMiss` 默认 false = v1
  语义）；**既有测试断言零修改**（铁律 2，无方向性翻转例外记录需求）；
  `Services/ServiceProtocols.swift` 协议签名不变（铁律 1）；检测器三级
  检测参数、`DetectionStrategy` 择优、`QuadSmoother` 参数、
  `CropConsistencyGate` 契约、idCard/相册导入路径零改动。
- **FR-004**: MUST 补齐粘滞全路径结构化日志（debug + privacy.public）：
  分支④改写 → `stickyOverride`（既有）；⑤ hold 帧 → `stickyHold`
  （miss 计数 / 锚点面积 / 被拦截择优面积）；①/⑤ 达限逃逸 →
  `stickyEscape`（触发时 miss 计数）。
- **FR-005**: 新增单元测试 MUST 覆盖：存在性交替稳定、hold 窗口边界与
  达限逃逸、hold 期间锚点回归、nil 间隙混合计数、hold 帧 tier 随锚、
  disposition 逐帧可辨、默认参数 v1 语义锚定、reset 语义、
  sticky→smoother 集成锁定、无 sticky 对照组永不锁定（Case B 机理钉住）。

## Edge Cases

- **锚点候选与整书 IoU 接近阈值**：右页占画幅比例更大的取景可能把整书
  bbox IoU 推过 0.60（fixture 实测余量 0.174）而锚到整书——按决策①
  （不加意图猜测）本轮不收紧阈值；真机复测若出现「稳稳锁住整书」，
  记录后另行评审。
- **用户先框住整书再露出右页**：先稳者胜——锚点=整书时右页帧被 hold
  拦截，用户移开相机 ≥3 帧即逃逸切换。与 v1 语义一致，不新增偏好。
- **跨拍摄/跨场景锚点携带**：sticky 锚点跨快门存活（still 路径不复位——
  复位会让恢复后首帧在交替场景重掷锚点抽签，见 plan D2）；场景切换由
  逃逸路径自清（≤3 帧），`reset()` API 备将来会话级复位使用。
- **双层 miss 时延核算**：逃逸总时延 = 粘滞 3 帧 ≈0.2s@15fps（hold 帧对
  smoother 是稳定输入，不触发其 miss 计数），满足真机验收「移场 ≤0.5s
  跟随切换」。

## Success Criteria *(mandatory)*

- **SC-001**: 测试基线 357 只增不减、既有断言零修改——交付后 total=367
  （357 + 新增 10）、0 failed、1 expected failure（既有 known issue）。
- **SC-002**: 新增 `CandidateStickyV2Tests` ×10 全绿：存在性交替序列下
  输出不翻转、达限逃逸、混合计数、tier 随锚、disposition 可辨、默认参数
  v1 锚定、reset、集成锁定、对照组不锁定。
- **SC-003**: 真机复测（device-acceptance.md）：摊开书中线取景 ≤5s 稳定
  不跳、可锁定；锁定/跟踪态手动拍成片 = 呈现框（不含左页）；`stickyHold`
  行在取景期可检索、移场后接 `stickyEscape`；同一会话顺带抄录
  `cropGate`（定案 C4 收敛）与 `reconstructPath`（L1 取证，docs/12 §2.4）。
- **SC-004**: 日志判读闭环：`stickyHold` 与 `detectionTier` 的 selectedArea
  交替节奏互补出现（交替帧被锚住）= v2 生效；hold 整段缺失而框仍跳 =
  v2 未生效（回查单测）。

## Assumptions

- 检测器本体（三级检测链、参数集、门控）不改动——消除池单源交替属
  live-edge-crop 周期 D6 省算力契约范围，改动面与帧率风险均大于粘滞层；
  若真机日志显示 B 帧整书候选实际来自放宽矩形档（`relaxedLiveProbe`
  可判别），「miss 帧补跑分割对齐锚点」作为后续增量另行评估。
- 节奏参数不变：15fps 检测、0.55s 锁定窗、0.4s=6 帧确认窗、missLimit=3。
- C4 按「下游症状随 Case B 收敛」处理；若真机复测显示呈现框稳定后
  手动拍仍含左页，再回到门禁/快门路径取证（其时 `cropGate` 日志已可判读）。
- 范式取舍（常驻框范式 wps-parity-capture）不在本周期范围；本周期取证
  结论（含「改善但未锁定」混合制式的比例）作为该评审输入。
