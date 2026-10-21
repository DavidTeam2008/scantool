# Plan: 框真相（frame-truth）

**Input**: spec.md（US1~US4 / FR-001~009）
**诊断**: 2026-10-17 真机逐帧遥测 + 四读者 + 红队（wf_e0a8174f-81e）

## 证据锚点（实现与验收判读的依据）

| # | 事实 | 证据 |
|---|---|---|
| E1 | 页面能检出：0.6510 整书 → 18s 稳定 0.45–0.48 右页 → still 0.4056 | detectionTier 时间线 21:54:58–21:55:22；cropGate shot2 |
| E2 | 0.08–0.093 带子通过 strict 档（minSize 按短边归一化；minAspect 0.2 允许 5:1） | VisionEdgeDetector.swift:313-319；405×720 帧换算 |
| E3 | 带子一票否决分割+放宽：needsDocumentSegmentation 用 area>0.08 | VisionEdgeDetector.swift:69-83 |
| E4 | `selectedArea 0.056–0.077` 低于 select.minArea=0.08 → 只能来自 sticky 分支④未过滤池 | select 过滤 :37；pool: rawCandidates :224 |
| E5 | 21:55:28–31 select 几乎每帧选页面（0.34–0.56），sticky 用 0.07–0.08 带子 override（IoU 0.13–0.20） | stickyOverride 505 条 / 逐帧转储 |
| E6 | escape 后次帧单帧起锚（21:55:28.327 escape→0.3618，次帧 0.0810） | stickyEscape + detectionTier |
| E7 | 0.06 锁定态引导 `.closer` 与白色锁定框/震动同屏；自动拍不看引导 | GuidanceDirective.swift:32-53；overlayIsLocked :79-83；auto gate :351-355 |
| E8 | shot1 门禁按契约工作（弃用静帧，成片=呈现框 0.06）；错在呈现框本身 | cropGate shot1 |
| E9 | shot2 still 无身份锚全局重选（包含降权+面积/居中偏好）→ 右页+折痕外框胜出；吸附只发生在 still 且外向相跳过 s=0 | VisionEdgeDetector.swift:90-121/157-198/261-267；EdgeSnapper.swift:158-174 |
| E10 | 门禁无真值：合法精修 fixture +12%/+14%/+21%，shot2 越界 +6.5%——面积/IoU 不可分 | CropConsistencyGateTests；CaptureViewModelTests |
| E11 | 实测检测 ~29.5fps（33ms 中位），missLimit=5 ≈ 0.17s | 2082 帧 / 70.46s |
| E12 | 视频/照片双空间：真机期望 0.5625→0.75，面积因子 0.75；**任何阈值必须声明空间** | FOVLayout.swift:6-10；AVCameraSession .photo |

## 设计决策

### D1 池单一真源（FR-001）

`DetectionStrategy.viablePool(_:)` 返回 viable 集合；`select` 在此基础上做两级
面积池。传给 sticky 的 pool 用 viable 集合（**不按 tier 截断**——红队：
tier1 非空时排除 ≥0.96 候选会让近满幅锚点帧转为 hold/escape）。分支④其余
逻辑不动：v1/v2 夹具池全部 ≥0.24，零碰撞。

### D2 页面先验（FR-002）

门控谓词与 select 下限解耦：`pageLikeMinArea = 0.25`（视频空间）。带子
（≤0.24）不再具备否决分割/放宽的资格 → 页面每帧进入候选池。
EdgeDetectionStrategyTests 现有夹具 0.04/0.36/0.98：0.36/0.98 仍抑制、
0.04/空仍触发，零翻转；新增 0.24→触发、0.25→抑制边界用例。
**为什么不是全局 minArea 上调**：那会让「太远」引导不可达（进入阈值照片
0.07 ↔ 视频 0.093，任何被接受框 ≥0.12 视频 = 0.09 照片 > 0.07）并波及 still。

### D3 锚点治理（FR-003）

三个可选参数默认值保持 v1/v2（0/1/0），live 覆盖：

| 参数 | live 值 | 空间 | 作用 |
|---|---|---|---|
| anchorMinArea | 0.12 | 视频 | 0.09 带子不得起锚（照片 ≈0.09） |
| reanchorConfirmFrames | 3 | 帧 | escape/初锁后连续 3 帧相似才起锚 |
| followMinAreaRatio | 0.8 | 面积比 | ③跟随限制 ≤20%/帧面积变化 |

锚点生命周期：`apply` 间隔 >1s 自动清锚（会话边界/停顿；测试同步调用不受
影响）。**不做** override 面积比守卫（红队：观测带子 0.2 与既有窄页合法
fixture 0.284 间隔过窄；锚点准入已从源头解决）。anchorMinArea 采用
`>=` 判定；死区（照片 0.07–0.09 显示但不锚定）在 device-acceptance 观察。

### D4 s=0 守卫（FR-004）

`G0 = mean5(L_bi(−δ)) − mean5(L_bi(+δ))`，δ = maxShift/12；**新增双线性采样
专用于 G0**（红队：最近邻 + ±δ≈0.37 栅格列会把两采样采成同一像素；而
δ0≥2 栅格像素(0.0125) 会大于 1% 外扩夹具，造成假绿）。判定：

```
若 G0 ≥ 0.08：
    外向峰 < 1.25×G0 → 该边零位移（并跳过内向相）
    否则 → 允许外向位移
否则：既有外向→内向两相逻辑不变
```

8 个既有用例的 G0 均为 0（内缩/外扩 1–8% ≫ δ）→ 零翻转；新增用例：
①边已在真实边缘（G0 强）→ 不动；②1% 外扩 → 仍能内拉（守卫不触发）；
③内缩 2% → 仍外推；④双线性/量化边界。

### D5 锁定冻结 + 精修上屏（FR-005）

- **空间**：displayed（照片）→ `FOVLayout.convert(photo→video)` 得种子；对
  **当前帧 `detected`**（视频空间）做 `EdgeSnapper.snap(quad:image:maxShiftRatio:
  0.04)`（吸附当前帧检测而非 smoother 滞后框——红队：手在动时平滑框与画面有
  相位差）；结果 `FOVLayout.convert(video→photo)` 为冻结框。
- **触发**：`track == .locked` 的**首次**进入（`wasLocked == false`）且当帧
  `detected != nil` 且 `directive != .closer`；`imageQuad = frozenQuad`、
  `phase = .locked(frozenQuad)`。
- **保持**：锁定期间即使 smoother 继续插值，`imageQuad` 保持冻结框；
  tracking/searching 转换时清除。
- **锁定态相位**：可见一次 ≤maxShift 的修正，之后框静止（用户可感知、可信）。
- **风险**：重锁会重新吸附（幂等、便宜）；若真机出现锁定抖动，迭代迟滞。

### D6 快门直裁（FR-006）

`capture()` 文档模式：`displayed != nil` 时不调用 `detector.detect(imageData:)`，
裁切 = displayed（锁定态 = 冻结框）；`gateRejectedStill` **不置位**（该字段
语义保留：本周期后文档主路径不再经过门禁；若未来回退 still 链仍有意义）。
搜索态（`displayed == nil`）保留静帧自由检测 + 门禁（displayed=nil 路径）。
idCard 不变。`cropGate` 日志冻结直裁路径记 `stillArea=-1 iou=-1
acceptedStill=false`（判读口径写入 device-acceptance）。
**CropConsistencyGate 保留**：纯函数与测试不动；文档主路径不再使用，
验收报告须说明（红队：避免「门禁仍在使用」的错觉）。

### D7 有效性契约（FR-007）

`overlayIsLocked = phase.locked && directive != .closer`（overlay/震动/
`CaptureView` 均经此属性，单点生效）；auto gate 增加 `directive != .closer`；
`capture()` 在 `.closer` 时 `displayed = nil`（搜索态）。`.backOff` 不抑制
（手动拍尊重用户意图；自动拍既有 `!suspicious` 语义不变）。
**注意**：`AutoCaptureHoldWindowTests` 钉住「3 帧 nil 失锁」「手动快门不受
限」，本设计不触碰 smoother miss 语义与手动快门门禁。

### D8 遥测（FR-008）

新增 4 条日志（notice 级，沿用上一周期已抬级；全仓无日志字符串断言）：
`candidateProvenance`（live 每帧）、`cropQuad`（快门，displayed/still 四角）、
`snapEdge`（吸附逐边 G0/bestShift/相位）、`snapOnLock`（seed/post）。
`stickyOverride` 增 heldArea/selectionArea。验收判读口径同步写入
device-acceptance.md。

## 不变式

- `ServiceProtocols.swift` 零改动（铁律 1）。
- 既有断言：除 tasks.md 记录的方向性翻转（FR-005/006 必要代价）外零修改。
- `CandidateSticky` / `QuadSmoother` / `CropConsistencyGate` 默认语义不动。
- 搜索态静帧自由检测、idCard、相册导入路径不变。
- 纯离线；模拟器条码恒 0。

## 风险表

| 风险 | 缓解 | 真机观察 |
|---|---|---|
| page-like 0.25 让远景页每帧跑分割（算力/掉帧） | 分割本就是条件触发；先观察帧率 | provenance gateSeg 比例、帧率 |
| anchorMinArea 死区（显示但不锁定） | 0.09–0.12 照片段提示可能仍显示"靠近" | 锁定时间、closer 比例 |
| 锁定吸附在视频帧上精度不足 | maxShift 0.03–0.05；真机对照导出照片 | snapOnLock 前后误差 |
| 冻结框与手抖相位差 | 用当前帧检测做种子；重锁可重吸附 | 锁定抖动/重锁频率 |
| `closer` 时手动拍走搜索态 → 成片可能≠入镜框 | 无效态本无可拍摄承诺；成片=静帧检测页 | 成片内容检查 |
| 折叠页折脊为亮脊时守卫不触发 | 原样返回、用户手动调框兜底 | 左缘折痕残留 |
