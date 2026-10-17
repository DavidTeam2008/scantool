# Implementation Plan: Case B 粘滞 v2 hold-through-miss（case-b-sticky-v2）

**Input**: spec/case-b-sticky-v2/spec.md（US1~US3 / FR-001~005）
**基线**: 357 = 356 passed + 1 expected failure + 0 failed（交付后 368；含审查 C1 修复用例）

## 技术决策

### D1：hold-through-miss 以参数门控落地 `CandidateSticky.apply`

- **决策**：`apply(selection:pool:similarityThreshold:missLimit:holdThroughMiss:)`
  追加带默认值 `false` 的 `holdThroughMiss` 参数；`VisionEdgeDetector`
  live 文档路径调用点传 `true`。分支⑤（池中无锚点相似候选）在 v2 下：
  `missCount += 1` → 达限 → 清锚 + 透传（逃逸）；未达限 → 返回锚点择优。
- **理由**：默认 false 保持 v1 语义 → 既有 `CandidateStickyTests` ×5 断言
  **零修改**（铁律 2 无需启用方向性翻转例外）；v1/v2 同码分岔、可随时
  回退；对比「原地翻转分支⑤」方案（须翻转 `escapesAfterMissLimit` 的
  透传断言并走例外记录流程），门控方案零既有资产风险。
- **锚点 tier**：新增 `lastTier` 状态随锚存储（分支②③④锚点更新时同步），
  hold 帧返回 `Selection(quad: anchor, tier: lastTier)`——不用 miss 帧择优
  的 tier（那是整书候选的层级，会污染 `detectionTier` 日志口径与「tier
  随锚」语义；分支④沿用同池层级是另一回事——改写对象与本帧择优同池）。
- **hold 窗口 = missLimit（3 帧 ≈0.2s@15fps）**：与 `QuadSmoother` miss
  保留 3 帧对齐（交接文档 §2.2 建议方向给出的默认倾向），不另设
  holdLimit——双窗口串行会推高真移场逃逸时延（真机验收上限 0.5s）。
- **分支①（selection==nil 检测间隙）不 hold**：维持返回 nil，由 smoother
  既有 3 帧 miss 保留兜底——避免双层 hold 叠加迟滞真实离开视场的响应；
  两条 miss 路径共用 `missCount`（混合达限同样逃逸，单测钉住）。

### D2：sticky 锚点在快门/still 路径不复位

- **决策**：`VisionEdgeDetector.detect(imageData:)`（still 重检）不触碰
  sticky 状态；新增 `CandidateSticky.reset()` 作为公共 API 备用。
- **理由**：快门后 live 恢复的首帧若是整书单源帧，复位后的空锚会把整书
  起锚——在存在性交替场景等于每次拍摄都重掷一次锚点抽签（且可能与
  拍摄前锁定的候选相反）。锚点携带的代价（跨场景 ≤3 帧逃逸自清）远小于
  复位引入的锚点反转风险。`CaptureViewModel.capture()` 里 smoother.reset()
  管呈现轨道，sticky 管候选延续，两者职责不同步复位。
- **备选（弃用）**：still 帧复位 sticky——上轮读者建议曾倾向此项，经上述
  抽签风险分析否决；`reset()` 保留供将来会话级（新建扫描会话）复位。

### D3：disposition 枚举驱动三路日志

- **决策**：`CandidateSticky` 新增 `Disposition` 嵌套枚举（`gapMiss /
  anchored / follow / override / hold / passthrough / escape`）与
  `private(set) var lastDisposition: Disposition?`；`missCount` 放宽为
  `private(set)`。`VisionEdgeDetector` 按 disposition 接线：
  `.override` → `stickyOverride(iou:)`（既有通道，语义收窄为仅分支④）、
  `.hold` → `stickyHold(missCount:heldArea:selectionArea:)`（新增）、
  `.escape` → `stickyEscape(afterMisses:)`（新增）。
- **理由**：v1 的日志条件「`gated.quad != selection.quad`」无法区分④改写
  与⑤ hold（v2 下两者都改写），混发会让 `stickyOverride` 失去「同池
  交替吸收」的判读口径；disposition 让三个通道语义正交。`stickyOverride`
  在 v1 下本就只在④触发，收窄无行为变化（向后兼容）。
- **可观测性补缺**：两轮复测 `stickyOverride` 整段缺失的根因是 miss 路径
  零遥测（日志缺席 = 池交替假设的预测结果）；`stickyHold`/`stickyEscape`
  上线后，真机一趟即可判读制式（hold 行 = 存在性交替直接证据）。

### D4：门禁、快门路径、检测器参数零改动（C4 下游收敛）

- **决策**：`CropConsistencyGate`、`CaptureViewModel.capture()`、
  `DetectionStrategy`、三级检测门控与参数、`QuadSmoother` 参数、
  idCard/相册导入路径全部不动。
- **理由**：C4（手动拍含左页）是呈现框振荡的下游症状——呈现框稳定为
  右页后，门禁既有契约（IoU<0.70 呈现框优先）自然裁对；「锁定帧优先于
  瞬时呈现框」等 VM 级改法会翻转 `CropGateAtShutterTests.trackingManual
  CaptureCropsDisplayedFrame`（FR-008 语义），属高代价例外通道，且与
  本修复同轮交付会失去归因能力。真机复测若显示呈现框稳定后仍裁错，
  凭 `cropGate` 日志回到门禁路径单独立项。

### D5：单测只增（append-only），新文件承载 v2 套件

- **决策**：新增 `ZhixiaTests/CandidateStickyV2Tests.swift` ×11（含审查 C1
  逃逸一次性用例）；既有 `CandidateStickyTests.swift` 等 40 个测试文件零改动。
- **覆盖矩阵**（对应 FR-005）：存在性交替稳定（US1）/ hold 窗口边界 +
  达限逃逸（US2）/ hold 期间锚点回归清零（US2）/ nil 间隙混合计数
  （US2）/ hold 帧 tier 随锚 / disposition 逐帧可辨（D3）/ 默认参数 v1
  锚定（D1 门控回归）/ reset 语义（D2）/ sticky→smoother 集成锁定
  （US1 端到端）/ 无 sticky 对照组永不锁定（Case B 机理钉住——若未来
  smoother 参数调整使对照组变绿，须重新评估 sticky 层必要性）。

## 不变式（改动红线）

- `Services/ServiceProtocols.swift` 协议签名不变（EdgeDetecting 两方法
  签名不动；`CandidateSticky` 是 actor 私有具体类型，不属协议面）。
- 既有测试断言零修改；基线只增不减（357 → 367）。
- 检测器三级检测参数 / 门控、`DetectionStrategy` 评分与两级兜底、
  `QuadSmoother` 参数、`EdgeSnapper`、`CropConsistencyGate` 契约零改动。
- 纯离线；Domain 纯函数无 I/O。

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| 真机是混合制式（同池 + 存在性交替混合），v2 后仍有残余跳变源 | `stickyHold`/`stickyOverride`/`detectionTier` 三通道一趟判读；残余源按比例结论喂范式评审 |
| IoU 0.60 阈值余量（fixture 实测 0.174）在大右页取景下锚到整书 | 决策①本轮不动阈值；真机复测出现「稳锁整书」时记录另行评审 |
| hold 引入 ≤2 帧旧框残影（用户快速移场） | 窗口=3 帧 ≈0.2s 与 smoother 对齐，真机验收 0.5s 上限内 |
| hold 帧 tier 随锚污染 detectionTier 口径 | D1 明确随锚语义；日志判读指引写入 device-acceptance.md |
