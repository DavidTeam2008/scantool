# Device Acceptance: Case B 粘滞 v2 hold-through-miss（case-b-sticky-v2）

**前置**：本周期代码与单测已交付（368 全绿）；本文件是真机复测清单。
**沿用**：`spec/wysiwyg-crop/device-acceptance.md` §0 的 Console.app 实时抓取
流程不变（debug 级日志不落盘，必须测试期间实时抓取），本节仅更新判读口径。

## §0 日志抓取（一次会话抄齐四类）

1. 手机连 Mac → Console.app 选设备 → 搜索
   `subsystem:com.david.Zhixia category:capture` → 勾选 **Include Debug
   Messages** → 开始流式抓取。
   （`stickyHold`/`stickyEscape`/`stickyOverride`/`cropGate`/`detectionTier`
   均在 `category:capture` 下；`reconstructPath` 在 `category:reconstruct`
   下——§4 取证时把检索框改作 `subsystem:com.david.Zhixia category:reconstruct`，
   或直接去掉 category 条件只留 subsystem。审查 confirmed C6。）
2. 保持抓取，依次执行 §1~§3 场景；每场景结束立刻检索对应前缀确认可读。
3. File → Save 按场景分段导出，与成片对照归档。
4. 同会话顺带执行 §4（L1 取证，`reconstructPath`，检索口径见第 1 步）——
   docs/12-handover.md §2.4 要求合并进同一真机会话。

## §1 Case B 主场景：摊开书中线取景拍右页

**动作**：摊开书放中线，取景右页，保持 ≤5s 观察实线框；锁定后自动拍一张；
重新取景，跟踪态（不等锁定）手动抢拍一张；最后把右页移出视场。

**通过标准**（对应 spec.md SC-003）：

| # | 检查 | 通过 |
|---|---|---|
| 1 | 实线框 ≤5s 稳定贴住单一候选，不再逐帧跳动 | ☐ |
| 2 | 0.55s 锁定窗内进入锁定态（白粗实线 + 压暗） | ☐ |
| 3 | 锁定自动拍成片 = 右页（不含左页） | ☐ |
| 4 | 跟踪态手动拍成片 = 拍摄瞬间呈现框（不含左页大半） | ☐ |
| 5 | 右页移出视场后框 ≤0.5s 跟随切换（不粘死） | ☐ |

**日志判读**：

- `stickyHold miss=N heldArea=… selectionArea=…`——取景期应连续出现：
  **存在性交替被 v2 吸收的直接证据**。heldArea ≈ 右页面积档、
  selectionArea ≈ 整书面积档（与 `detectionTier` 的 selectedArea 交替
  节奏互补：交替帧被锚住）。
- `stickyOverride iou=…`——同池共存帧的改写（若出现，说明真机是混合
  制式；记录两类日志的比例结论供范式评审）。
- `stickyEscape afterMisses=3`——**每次锚点放弃仅一条**（分支① `lastPick
  != nil` 守卫，审查 C1 修复后成立；连发或 afterMisses≠3 = 异常回查）。
  设计内豁免：取景期短暂失焦/遮挡造成 ≥3 连续零候选帧会产生**单条**
  afterMisses=3（间隙逃逸，CandidateSticky 类文档明言检测间隙计入逃逸），
  不判误逃逸；取景期候选池非空却出现 escape（锚点候选回归未清零 miss）
  才是误逃逸，回查 `anchorReturnResumesFollow` 用例。
- `cropGate displayedArea=… stillArea=… iou=… acceptedStill=…`——手动拍
  各行：displayedArea 应是右页面积档（≈0.36 量级）；若 displayedArea 是
  整书档（≈0.84）而框视觉稳定，回查 H1 类「锁定对象」问题（转 Case A
  取证路径）。
- **失败分支指引**：框仍跳且 `stickyHold` 整段缺失 → v2 未生效（回查
  `CandidateStickyV2Tests` 是否绿、`VisionEdgeDetector` 调用点是否传
  `holdThroughMiss: true`）；框稳定但成片仍含左页 → 凭 `cropGate` 行
  回门禁/快门路径单独立项（plan D4 的预设出口）。

## §2 Case A 顺带复验（不新增动作）

折页书拍右页场景本周期未动其链路；若同会话方便，按
`spec/wysiwyg-crop/device-acceptance.md` §A 复验并抄 `cropGate`
（其 H1/H2 定案仍待取证，docs/12 §2.1）。

## §3 平整文档防回归

平整 A4 文档取景 + 快门：`cropGate` 典型 iou≥0.70、acceptedStill=true，
精修更贴边属预期（不算不一致）；取景无不必要跳变（单候选场景
`stickyHold` 不应出现）。

## §4 L1 通路取证（docs/12 §2.4 合并项）

导出一页含表格的语法页 docx，检索 `reconstructPath` 行（每页一条五分类
决策线）：确认 iOS 26 真机是否静默回退几何通路；结论回填
docs/12-handover.md §2.4。

## 复测记录（回填区）

| 日期 | 设备/iOS | 包 | §1-1 稳定 | §1-2 锁定 | §1-3 自动拍 | §1-4 手动拍 | §1-5 移场 | 日志归档 | 结论 |
|---|---|---|---|---|---|---|---|---|---|
| （待填） | | | | | | | | | |
