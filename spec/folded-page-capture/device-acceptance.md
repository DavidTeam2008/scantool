# Device Acceptance: 折页书拍摄修复（folded-page-capture）

**前置**：本周期代码与单测已交付（377 全绿）；本文件是真机验收清单。
**⚠️ 已被 `spec/frame-truth/device-acceptance.md` 取代（2026-10-18 真机复测
后）**：§1 的四痛点检查仍有效，但快门链契约已按 frame-truth 改为「锁定冻结
+ 精修上屏 + 成片=呈现框」——§3 的 `cropGate iou≥0.70 acceptedStill=true`
期望**不再适用**（新口径 `stillArea=-1` 冻结直裁），§1-5 整理页行为以
frame-truth 验收单为准。真机执行以 `spec/frame-truth/device-acceptance.md`
为主清单。
**沿用**：`spec/wysiwyg-crop/device-acceptance.md` §0 的 Console.app 实时
抓取流程不变（capture 遥测已为 notice 级、可事后 log collect 回溯）。
**合并执行**：`spec/case-b-sticky-v2` T011 遗留项（Case B 摊开书复测 +
§4 reconstructPath L1 取证）并入同一真机会话，判读口径见其
device-acceptance.md，本文件不重复。

## §0 日志抓取

同 case-b-sticky-v2/device-acceptance.md §0：`subsystem:com.david.Zhixia
category:capture` + Include Debug Messages；§4 取证切
`category:reconstruct`。本周期新增判读：默认不自动拍下
`suspiciousLock` 应**整段缺失**（FR-002 门控证据）。

## §1 折页书主场景：书本折起拍右页（四痛点复测）

**动作**：书本折起（左页折到背面/立起），取景右页（左缘 = 折痕），
保持 ≤5s 观察实线框；手动拍一张；再重新取景拍一张近摄（右页占画面
≥2/3）。默认设置（不碰自动拍开关）。

**通过标准**（对应 spec.md SC-001~004）：

| # | 检查 | 通过 |
|---|---|---|
| 1 | 实线框 ≤5s 稳定贴住右页，不再 2~3Hz 跳动（痛点①） | ☐ |
| 2 | 框捕获的是**右页**边框（左缘贴折痕），非整书外轮廓（痛点②） | ☐ |
| 3 | **不自动拍**——锁定多久都不拍（痛点③，FR-001） | ☐ |
| 4 | 手动拍成片 = 快门瞬间呈现框；左缘**不含折痕带**，其余三边贴边（痛点④） | ☐ |
| 5 | 整理页（review）预览/保存后裁切与成片一致——不被自动精修改写（FR-007） | ☐ |

**日志判读**：

- `stickyHold miss=N heldArea=… selectionArea=…`——N 可到 4（missLimit 5
  窗内）；heldArea ≈ 右页面积档、selectionArea ≈ 整书档 = 近摄制式
  交替被锚住的直接证据（0.70 阈值判跳变走 hold，不再 follow 棘轮）。
- `stickyEscape afterMisses=5`——逃逸窗拉长到 5 后的新口径（≠ 3 不再是
  异常；连发才是异常，C1 守卫仍在）。
- `stickyOverride iou=…`——同池共存帧改写；近摄制式 IoU ∈ [0.60, 0.70)
  的行应**消失**（该区间已判不相似）。
- `detectionTier path=live tier=… candidates=…`——严格档放宽（minSize
  0.15/容差 26°）后 tier 1 命中率应上升；`relaxedLiveProbe triggered=true`
  比例应下降（第三级不再频繁兜底）。
- `suspiciousLock`——**默认不自动拍下整段缺失**；若出现 = FR-002 门控
  失效回查。
- `cropGate displayedArea=… stillArea=… iou=… acceptedStill=false`——
  手动拍各行：displayedArea 应为右页档；acceptedStill=false 且
  displayedArea 是右页档 → 整理页该页应保持呈现框（检查 5）。
- **失败分支指引**：框仍跳且 stickyHold 缺失 → 回查调用点参数是否生效
  （CandidateStickyV2Tests/closeShotRatchetFrozenByCallSiteParams 是否绿）；
  框锁定整书 → detectionTier 看右页候选是否在池（在 = 择优/评分问题
  单独立项；不在 = 严格档仍过严，评估再放宽或中间档参数）；
  左缘仍含折痕 → 折痕带宽超内拉限幅（短边 2.5%），记录带宽像素估
  值回填评估限幅。

## §2 默认不自动拍与设置保留（SC-004）

| # | 检查 | 通过 |
|---|---|---|
| 1 | 全新安装（或设置中从未碰过自动拍开关）：§1 全程不自动拍 | ☐ |
| 2 | 设置页显式开启自动拍 → 平整文档锁定 ≈0.4s 后自动拍（功能本身未删） | ☐ |
| 3 | 开启状态下整书误锁（面积 0.85~0.94）仍**不拍**且出后退提示——可疑门禁在开启态照旧（FR-002 另一侧） | ☐ |
| 4 | 杀进程重进：开启状态保留（持久化键未被默认值翻转覆盖） | ☐ |

## §3 平整文档防回归

平整 A4 取景：实线框稳定无多余跳变；`cropGate` iou≥0.70、
acceptedStill=true，精修贴边照旧（外向相语义不变）；手动拍成片贴边
精度与上周期一致。

## §4 合并项：Case B 复测 + L1 取证

按 `spec/case-b-sticky-v2/device-acceptance.md` §1~§4 执行（判读口径中
`stickyEscape afterMisses=3` 更新为 5，其余不变）；结论连同本文件
一起回填。

## 复测记录（回填区）

| 日期 | 设备/iOS | 包 | §1-1 稳定 | §1-2 右页框 | §1-3 不自动拍 | §1-4 折痕 | §1-5 整理页 | §2 设置保留 | §3 平整 | §4 合并项 | 日志归档 | 结论 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| （待填） | | | | | | | | | | | | |
