# Plan: 折页书拍摄修复（folded-page-capture）

**Input**: spec.md（US1~US4 / FR-001~008）
**诊断**: understand-folded-book 工作流四读者合成（wf_ff79605d-f9e）

## 设计决策

### D1 默认值翻转零迁移（FR-001）

`PreferencesStore.autoCapture` 的 didSet 在 init 内不触发 → 从未显式
设置的用户 defaults 里无 `zhixia.autoCapture` 键 → init 的
`object(forKey:) == nil` 分支直接决定默认值。翻转该分支 true→false
即完成迁移，且**必须不**写迁移代码：任何「若无键则写入 false」的
迁移都会把键落盘，将来再调默认值时这批用户被冻结在 false。
显式设置过的用户（含设为 true）键已存在，读回 preserved。

### D2 可疑门禁整段门控在 autoCapture（FR-002）

`preferences.autoCapture && quad.isSuspiciousForAutoCapture()` 单点
短路。autoCapture 关时：suspicious 恒 false → 提示不置位、
`suspiciousLock` 日志不发射、确认窗计数不冻结（计数此时无消费者，
冻结与否不可观测）。**铁律 2 耦合核查**：全部断言
`isAutoCaptureSuppressed` 的测试（CaptureFallbackTests ×3、
CaptureViewModelTests/suspiciousLockFreezesHoldCount）都显式
`autoCapture: true`；`disabledAutoCaptureNeverFires`（false）不断言
该标志 → 零碰撞。

### D3 live 检测参数分层（FR-003）

`detectRectangles(relaxed:)` 是单一参数源：relaxed=false 仅 live 首档
使用（still 首跑即 relaxed=true，live 第三级也走 relaxed=true）→
改 false 分支参数只触及 live 首档，still 与放宽档零影响。取值居中
（minSize 0.15 ∈ (0.08, 0.25)、容差 26° ∈ (20°, 28°)）：折页曲面页
角点出画/微弯时候选可得，又不至跌入放宽档噪声水平。

### D4 粘滞/平滑参数：调用点覆盖 + 刻意非对齐（FR-004/005）

- `CandidateSticky` 默认常量（0.60 / 3）**不动**——v1
  `CandidateStickyTests` ×5 与 v2 `CandidateStickyV2Tests` 全部用例
  依赖默认值；live 调用点（VisionEdgeDetector 唯一 apply 调用点）
  传 `similarityThreshold: 0.70, missLimit: 5`。
- **0.70 的 fixture 带核查**：v1/v2 全部 fixture IoU ∈ {0.875, 0.75,
  0.70(含边界), 0.63, 0.50, 0.426}——无一落在开区间 (0.60, 0.70)；
  0.70 恰为 v1 fixture 下界且 `>=` 判定含边界 → 即使误改默认常量
  也不破断言（双保险，但仍选调用点覆盖保持默认语义钉住）。
- **smoother 刻意非对齐**（FR-005）：初版同步 `QuadSmoother(missLimit:
  5)` 被 `holdWindowResetsOnUnlock`（钉住 3 帧 nil 失锁）击回——
  回退默认 3。机理自洽：smoother miss 路径只在 selection 为 nil 的
  全帧间隙触发；存在性交替下 sticky 每帧回传锚点（非 nil），
  smoother miss 不触发。拉长 smoother 只改变「全帧无检出时呈现框
  多留 0.13s」的 UX，非本周期目标，且代价是动既有断言。
- **missLimit 5 的边界**：逃逸 ≤5 帧 ≈0.33s@15fps < 0.5s 移场接受
  上限（spec/case-b-sticky-v2 §SC-001 检查 5 口径）。

### D5 EdgeSnapper 双向两阶段（FR-006）

梯度签名对称性：G(s) = L(s−δ) − L(s+δ) 中 s−δ 更靠页内——「页内亮、
页外暗」的真实边缘在 s 正负两侧都呈正峰，内外两相找的是同一签名，
仅搜索区间与阈值不同。相位顺序**外向优先**：内缩是 Vision 检出框的
常态缺陷（既有 US6 场景），外向相可达时内向相不参与（新增
`outwardPhaseKeepsPriority` 用例钉死）。内向相三重文字防御：
限幅 0.5×maxShift ≈ 短边 2.5%（页边距普遍 ≥5%）、阈值 1.5× = 0.12、
沿边 5 点均值模糊孤立笔画。既有 5 用例逐一走查零碰撞（内缩框走
外向、均匀图两相皆空、凸性/面积校验在前）。

### D6 WYSIWYG 贯穿：契约字段随草稿落盘（FR-007）

穿透点不是门禁而是 `ReviewViewModel.refineQuads`（整理页 appear 时
无条件 still 重检覆盖，仅跳过 userAdjustedQuad）。修复 = 门禁决策
随草稿落盘：`PageDraft.gateRejectedStill`（Domain 模型加字段带默认
值——非 ServiceProtocols 签名，铁律 1 不触及；无 PageDraft 整体
相等断言，铁律 2 不触及）。置位条件 = 文档模式 ∧ displayed ≠ nil
∧ !usedStillRefinement（含静帧检测失败帧——呈现框同样是赢家，
语义一致）。搜索态/精修采纳/idCard 不置位，refine 照旧兜底。

### D7 参数取值汇总与论证

| 参数 | 旧 | 新 | 论证 |
|---|---|---|---|
| autoCapture 默认 | true | false | 锁错候选时自动拍必出废片；快门主导权交还用户 |
| live strict minSize | 0.25 | 0.15 | 折页页角出画可得候选；(0.08, 0.25) 中间 |
| live strict 容差 | 20° | 26° | 曲面页微弯可得候选；(20°, 28°) 中间 |
| sticky similarity | 0.60 | 0.70（调用点） | 同候选 ≥0.85 vs 近摄异候选 0.60~0.70，双侧余量 |
| sticky missLimit | 3 | 5（调用点） | 0.33s < 0.5s 移场上限；与交替节奏匹配 |
| snapper 内向限幅 | — | 0.5×maxShift | ≈短边 2.5% ≪ 页边距 |
| snapper 内向阈值 | — | 0.12 | 1.5× 外向，内拉保守 |

## 不变式

- `ServiceProtocols.swift` 零改动（铁律 1）。
- 既有断言零修改（铁律 2；唯一碰撞 `holdWindowResetsOnUnlock` 经
  回退 smoother 覆盖方案消解，见 tasks.md 翻转记录）。
- still / idCard / 相册导入检测路径零改动。
- `CandidateSticky` / `QuadSmoother` 默认常量不动。
- EdgeSnapper 外向相与四项校验语义不变。
- 纯离线；模拟器条码恒 0。

## 风险表

| 风险 | 缓解 | 真机观察 |
|---|---|---|
| live 首档放宽引入假矩形候选 | 面积上限门控/粘滞/relaxedLiveProbe 通道仍在 | detectionTier 候选数 |
| 0.70 阈值下极端近摄（IoU 0.70~0.85）损失跟随漂移 | hold 输出不翻转，仅框略滞后 | stickyHold 比例 |
| 内向相误吸文字笔画 | 限幅+阈值+5点均值三重防御 | 成片左缘检查 |
| 折痕带宽于限幅够不着 | 原样返回（宁缺毋滥），手动调框兜底 | §1 检查 4 |
| gateRejectedStill 页 refine 不再修正偏差呈现框 | 用户手动调框（userAdjustedQuad）路径不变 | §1 检查 3 |
