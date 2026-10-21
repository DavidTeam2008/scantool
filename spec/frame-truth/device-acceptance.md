# Device Acceptance: 框真相（frame-truth）

**前置**：代码与单测已交付；本文件是真机验收清单。
**日志**：capture 遥测已为 notice 级（持久化）——可用
`log collect --device-udid <UDID> --last 1h` 事后回溯，无需实时抓取。
**合并执行**：`spec/case-b-sticky-v2` T011 遗留项（Case B 复测 +
`reconstructPath` L1 取证）并入同一会话。

## §1 折页书主场景（四痛点 + 新症状复测）

**动作**：书本折起拍右页（左缘=折痕），默认设置。取景 ≤5s 观察；复现
「框只捕获一部分」状态保持 3~5s；手动拍 2 张（近/中距）。

| # | 检查 | 通过 |
|---|---|---|
| 1 | 框 ≤5s 稳定贴住右页；**不出现**锁定在局部文字带的状态（0.06–0.09 段 ≤1s 且不显示可拍摄锁定框） | ☐ |
| 2 | `candidateProvenance` 显示 `gateSeg=true` 的帧能给出页面档候选（`segArea`≈0.4+）；`viableMaxArea` 出现 0.4 档 | ☐ |
| 3 | 无 `selectedArea<0.08` 行；`stickyOverride` 不再出现 `heldArea≈0.08 & selectionArea≈0.45` 组合 | ☐ |
| 4 | 锁定瞬间可见 ≤短边 8% 的一次吸附修正（`snapOnLock` 前后四角），之后框静止不漂移 | ☐ |
| 4b | **屏幕框 = imageQuad**：对一张平整纸，角括号四角落点与纸边偏差在截图尺度上可解释（叠加层与预览共用全屏坐标系；安全区 bug 修复后） | ☐ |
| 5 | 手动拍成片 = 冻结框：导出照片四角与 `cropQuad tag=displayed` / `snapOnLock post` 一致（≤0.5%）；左缘不含折痕带、四周无背景 | ☐ |
| 6 | `cropGate` 手动拍行为 `stillArea=-1 iou=-1 acceptedStill=false`（冻结直裁） | ☐ |
| 7 | 拍「框只捕获一部分」状态下快门：应走搜索态静帧检测（`cropQuad tag=still` 有值且面积≈页面档），成片为整页 | ☐ |

**日志判读**：
- `candidateProvenance`：`gateSeg=true` 且 `segArea≈0.45` = 页面先验生效；
  `strictMaxArea 0.08–0.09` 与 `segArea 0.45` 同帧共存 = 上一周期被一票
  否决的帧现在拿到了页面候选。
- `stickyHold heldArea≈0.08 selectionArea≈0.45` 连发 = 带子仍被锚定（回查
  anchorMinArea 是否生效；CandidateSticky 新增用例是否绿）。
- `snapEdge edge=3 g0>0.1 shift=0` = 左缘 s=0 守卫阻止了折脊外拉（预期）。
- `cropGate stillArea=-1` = 冻结直裁路径；`iou=-1 acceptedStill=false` 同义。
- `cropQuad` 四角用于与导出照片叠加核对。

## §2 无效框承诺（SC-004）

| # | 检查 | 通过 |
|---|---|---|
| 1 | 取景过远（框面积 <0.07）：提示「靠近一点」，**不出现**白色锁定框/锁定震动 | ☐ |
| 2 | 同一状态保持 6+ 帧（开启自动拍）：**不自动拍** | ☐ |
| 3 | 同状态手动拍：走静帧检测（cropQuad still 有值），成片为整页而非局部小框 | ☐ |
| 4 | 平整文档显式开启自动拍：有效锁定后 ≈0.4s 自动拍，成片=冻结框 | ☐ |

## §3 平整文档防回归（SC-003）

平整 A4 取景：锁定瞬间吸附后边缘误差 ≤短边 2%（导出照片对照 `snapOnLock
post` 四角）；无快门后隐藏变化（`cropGate stillArea=-1`）；`snapEdge g0`
在四边接近 0（内缩边，守卫不触发）或 shift 与内缩量匹配。

## §4 合并项：Case B 复测 + L1 取证

按 `spec/case-b-sticky-v2/device-acceptance.md` §1~§4 执行（`stickyEscape`
口径 afterMisses=5）；结论连同本文件一起回填。

## 复测记录（回填区）

| 日期 | 设备/iOS | 包 | §1-1 稳定 | §1-5 成片=冻结框 | §1-6 直裁日志 | §1-7 无效框快门 | §2 承诺 | §3 平整 | §4 合并项 | 日志归档 | 结论 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| （待填） | | | | | | | | | | | | |
