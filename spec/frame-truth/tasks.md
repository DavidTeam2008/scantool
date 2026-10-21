# Tasks: 框真相（frame-truth）

**Input**: Design documents from `spec/frame-truth/`
**Prerequisites**: plan.md（D1~D8）、spec.md（US1~US4 / FR-001~009）
**测试基线**: 377 = 376 passed + 1 known issue + 0 failed，只增不减（方向性翻转见文末记录）
**构建/测试**: `make test`；局部 `make test-only T=<Suite>`

## Phase 1: 检测供给与择优（US1）

- [X] T001 [P] `DetectionStrategy.viablePool` 单一真源（FR-001）：
  `select` 内部与 live sticky 调用点共用；`EdgeDetectionStrategyTests` 追加
  viablePool 过滤用例（亚 minArea/退化候选不入选）
- [X] T002 [P] 页面先验门控（FR-002）：`pageLikeMinArea = 0.25`；
  `needsDocumentSegmentation`/`needsRelaxedRectangles` 改口径；
  新增 0.24→触发 / 0.25→抑制边界用例；既有 0.04/0.36/0.98 夹具零翻转
- [X] T003 粘滞锚点治理（FR-003）：`CandidateSticky.apply` 新增
  `anchorMinArea`/`reanchorConfirmFrames`/`followMinAreaRatio` + 1s 清锚；
  live 调用点 0.12/3/0.8；新增单测：亚下限不起锚、K=3 确认、面积比
  0.7 拒绝 / 0.889 放行、默认语义保持（v1/v2 全绿）

## Phase 2: 贴边吸附守卫（US3 前置）

- [X] T004 [P] EdgeSnapper s=0 守卫（FR-004）：双线性采样 G0（±δ 防量化）、
  `1.25×G0` 判定、跳过内向相；`EdgeDiagnostic` 出参；
  `EdgeSnapperTests` 追加：边已在真实边（G0 强）→ 不动、1% 外扩仍内拉
  （守卫不误触发）、内缩 2% 仍外推；既有 8 例零翻转

## Phase 3: 锁定冻结与快门直裁（US3）

- [X] T005 锁定冻结 + 精修上屏（FR-005）：`frozenQuad`；锁定首次进入用
  当前帧 detected + `frame.cgImage` 吸附（0.04→真机后 0.08）→ FOV 反算 → 上屏冻结；
  tracking/searching/拍摄复位清冻结；`snapOnLock`/`snapEdge` 日志接线
- [X] T006 快门 = 呈现框（FR-006）：document 模式 `displayed != nil` 跳过
  静帧重检，裁切 = 呈现框；`stillArea=-1` 日志口径；搜索态链路保留；
  `cropQuad` 四角日志
- [X] T007 有效性契约（FR-007）：`overlayIsLocked` 消费 `directive != .closer`；
  自动快门门禁同口径；`capture()` 在 closer 时按搜索态处理
- [X] T008 检查点：`make test` 全绿（386 = 385 passed + 1 expected failure
  + 0 failed；基线 377 + 新增 9：viablePool ×1 + 页面先验 ×1 +
  EdgeSnapper ×1 + 粘滞治理 ×4 + 冻结/承诺 ×2）

## Phase 4: 遥测与文档闭环

- [X] T009 `candidateProvenance` live 每帧遥测 + `stickyOverride` 面积字段
  （FR-008）；全仓无日志字符串断言，零碰撞
- [X] T010 周期四件套落盘 + `spec/feature.json` 指向本周期 +
  `spec/folded-page-capture/device-acceptance.md` 同步新语义（§3 静帧精修
  期望改为冻结直裁；§1-5 整理页精修说明）
- [ ] T011 [Verification] 真机验收（需设备 + 用户）：折页书四痛点复测 +
  无效框承诺 + 平整文档吸附精度 + 冻结直裁四角核对（device-acceptance.md）

## 真机复测追加（2026-10-18 晚，第二轮）

- **叠加层坐标系 bug（逐帧日志 + 截图反算定案）**：`EdgeOverlayView` 未
  `.ignoresSafeArea()`，GeometryReader 拿到安全区尺寸（≈390×763），而预览层
  是全屏（390×844）——屏幕框被整体缩小 ~10% 并下移 47pt，用户看到的框
  永远比 `imageQuad` 小一圈。截图角括号实测位置与「安全区尺寸反算」吻合
  （右上角误差 ~7pt），与「全屏反算」相差 60–200px。已在 `CaptureView`
  给 overlay 加 `.ignoresSafeArea()`；**这是「框和成片对不上」的显示侧根因**，
  与裁切链路无关。
- 分析帧 720→1080、锁定吸附预算 5%→8%：新包 `snapOnLock` 已出现真实外扩
  （seed 0.1987 → post 0.2185；右缘 outward 0.113 → shift 0.0186；下缘
  g0=0.107 被 s=0 守卫拦下）。
- geometry 实测 `videoAspect == photoAspect == 0.75`（此前 9:16↔4:3 的换算
  假设不成立；该链恒等，不引入错位）。

## 真机复测追加（2026-10-20，第三轮：抖动与左缘）

- 逐帧遥测（23596 行 / ~6 分钟 / 7623 帧）：**逐帧面积变化中位 2.4%、
  p90 11.7%、p99 31.9%**——检测噪声被 alpha=0.35 的平滑近乎原样透传，
  是「框一直抖」的直接来源；`stickyOverride` 仅 2%（候选选择稳定），
  噪声来自同候选内部。
- 左缘：81 次锁定吸附中边 3（左）**29 次向外推**（「全窗最强梯度」跳过
  折痕、命中更强的折脊轮廓 → 含折起部分）、仅 3 次内拉——用户观察到的
  「有时含折、有时切掉」在吸附层的定量签名。
- 修复（本轮回合）：
  1. `EdgeSnapper` 改**最近峰策略**：从检出边向外/向内各找**第一处**过阈值
     的边并取峰位，|s| 更小者胜；s=0 守卫保留。折痕（内侧）稳定优先于
     折脊轮廓（外侧更强），三条外缘不受影响（第一个峰=纸边）。
     新增 `foldCreaseBeatsSilhouette` 夹具（合成亮面+折痕阴影+折脊剖面）。
  2. `CaptureViewModel.consume` 文档形态**逐帧轻量贴边吸附**（1080p 帧、
     maxShift 0.06，约 1–2ms/帧）后再入 smoother——边持续锚在真实边缘上，
     从供给侧降低噪声与左缘翻转。
- **平滑参数不动**：`AutoCaptureHoldWindowTests/suspiciousLockFreezesHoldCount`
  按 alpha=0.35 的逐帧收敛轨迹精确钉死（帧预算核算），死区/重 EMA 会翻转
  其断言（铁律 2）——抖动收益改由吸附承担。
- 拍后处理（对标竞品：重检裁切/去皱/清晰化）列为下一周期，不在本轮。

## 方向性翻转记录（铁律 2 例外通道，用户已批准选型）

**冻结直裁（FR-006）使「有呈现框时静帧胜出」的既有契约失效**，以下既有
断言按新语义修改（等价行为由新用例重新钉住：有呈现框时完全不重检，
`stillDetectCount == 0`）：

1. `CaptureViewModelTests.swift` `CropGateAtShutterTests/lockedConsistentStillRefines`
   → 更名为 `lockedFrameCropsDisplayedWithoutRedetect`：断言从
   `draft.quad == refined（+14.33% 静帧外扩）` 翻转为本
   `draft.quad == rightPage`（呈现框）且 `stillDetectCount == 0`。
   原因：快门后隐藏换框是「成片比框大」的根因，用户选型「锁定冻结 +
   精修上屏」。
2. `CropGateAtShutterTests/draftCarriesGateRejectedStillFlag`
   → 更名 `frameTruthDraftMarksCropFinal`，字段更名 `cropIsFinal`：原断言
   「呈现框优先 → flag=true / 静帧精修 → refined+flag=false」翻转为本
   「有呈现框 → quad=呈现框、cropIsFinal=true；搜索态 → false」。
   原因：文档主路径不再经过门禁；帧真相拍摄的裁切在快门时刻定稿，
   整理页 refineQuads 不得重检覆盖（真机复测：整理页重检曾把排除折痕的
   取景框换成含折痕的 still 全局结果）。
3. `CaptureViewModelTests.swift` `CaptureFallbackChainTests/stillRedetectWins`
   → 更名为 `displayedFrameWinsOverStill`：断言从
   `draft.quad == still` 翻转为 `draft.quad == live` 且
   `stillDetectCount == 0`。原因同 1。
4. `stillFailureFallsBackToLiveQuad` / `doubleFailureFallsBackToFullImage`
   未改断言——新语义下依旧成立（前者成片=live；后者搜索态双落空=全幅）。

**无其它既有断言修改**；v1/v2 sticky、EdgeSnapper ×8、Strategy ×17、
Guidance、Review 等套件全部原样通过。

## 依赖与并行

- T001/T002/T004 互相独立（不同文件）；T003 独立于 T001（调用点共用）
- T005 依赖 T004；T006/T007 依赖 T005（冻结框是直裁输入）
- T008 依赖全部实现；T009 可与 T008 并行；T010/T011 依赖 T008
