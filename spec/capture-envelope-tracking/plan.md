# Plan: 取景包络跟踪（capture-envelope-tracking）

**Input**: `spec.md`（FR-001~007）
**详细论证**: `docs/22-capture-envelope-tracking.md`

## 设计决策

- **D1 包络优先，而非实时单页锁定**：实时只维护一个稳定的书/整摊/单页
  envelope；左/右页是输出语义。目标页暂时不可靠时仍显示包络，tracker 用
  hold/平滑/候选切换确认维持视觉连续；不因 target=nil 清空取景框。
- **D2 绝不回退 `.fullImage`**：整幅画面外框/四边贴边 frame 不是页面。
  `PageIntentResolver.isScreenEdgeFrame` 在 envelope 选择、resolve 拆分、
  tracker 摄入、`capture()` 全链路拒绝；无当前帧包络或 hold 时快门置灰。
  没有可信页面时允许搜索态——这是正确行为。
- **D3 目标与包络分离显示**：`imageQuad` 保持包络；`outputTargetQuad` 是
  实际输出目标。overlay 主框 = `target ?? envelope`，实线/压暗/角括号；
  envelope 仅在 target 存在时画淡虚线上下文。左页 target 的右角落在书脊上。
- **D4 输出意图持久化**：`PageDraft.outputIntent` 记录 left/right；whole 为
  nil。旧数据/导入/引导框默认 nil，语义保持“整页或手动拆分”。
- **D5 拍后高分辨率拆分**：Review 首轮精修在原图 1600px 矫正图上先做书脊
  暗谷分析（`analyzeSpine`），失败再做亮缝（`analyzeGutter`）；右页单页框
  带折条时用 `SpreadSplitter.leftFoldTrim` / `leftBrightFoldTrim`。高置信
  ≥0.5 自动写 quad + `userAdjustedQuad=true` + 撤销栈；低置信只写
  `SplitProposal`（预选目标侧），首屏可见、用户确认。
- **D6 角色优先，不重复拆分**：`PageDraft.quadRole` 由快门快照写入：
  `.target`（左/右页目标已解析）不再拆分，右页仅做折条清理；`.envelope`
  （目标缺失，拍的是整摊）**必须尝试**书脊/亮缝拆分，找不到证据保留包络并
  记录 `envelopeNoSplit`。`nil`（旧数据）保留原宽高比推断。左页输出不使用
  leftFold（折条模型的左侧不是要输出的左页）。
- **D9 亮缝模型（视频 8）**：真实摊开书的中缝常是**白内边距**，不是暗谷；
  `SpreadSplitter.analyzeGutter` 用列亮度均值（Raster 160 列，降采样稳定）
  找“比左右 6% 邻域更亮”的空白带，半高宽估带宽，置信度 = 0.40×带宽 +
  0.45×对比 + 0.15×居中。接入两处：`PageIntentResolver.splitSpread` /
  `splitClippedSpread`（实时目标）与 Review `applyOutputIntentSplit`（拍后）。
  单页两栏的栏间距也会形成亮缝：搜索限定在中线 `0.30~0.70`（视频 9 的
  0.759 栏缝直接被排除），实时只对“裁掉的整摊”（宽高比 ≥0.95 + 中心偏移）
  或整摊使用，拍后只对 `quadRole == .envelope` 使用。
- **D11 页对包络（视频 10）**：检测器常分别给出左页/右页干净矩形，而最大
  的“场景矩形”会把背景墙也包进来（宽高比 0.93、上缘 0.05，单看也像一页）。
  `pagePairEnvelope` 用两页（宽高比 0.40~1.05、面积 ≥6%、相邻 x、y 重叠）
  的并集组成倾斜整摊；`envelope` 在整摊之后、单页之前使用它。`resolve` 的
  ①b 先信池里符合意图的页候选（`!isSpreadLike`、宽高比 0.45~1.10、面积 ≥6%），
  再做整摊拆分——大矩形的拆分目标会带墙，不能抢先。目标面积门 6%（视频 10
  左页被边缘裁到 0.071）。
- **D10 目标一致性校验（视频 9）**：`resolve` 的每个候选在返回前过
  `acceptTarget`：目标在包络内、落在意图侧、宽高比 0.45~1.10、拆分目标面积
  ≥8%。照片是 3:4，竖版书页在归一化坐标里可以接近 1.0（视频 9 左页 0.991），
  所以拆分目标的上限是 1.10 而不是页面候选的 0.98。书脊暗谷宽度上限 20%：
  宽暗区（插图/照片）不是书脊。
- **D12 取景域 = 成片域（视频 11/12，CF-T010）**：预览容器按运行时视频宽高比
  布局（4:3 → iPhone 13 390×520），预览层 `.resizeAspect`，overlay/引导框与
  预览同一容器；因为容器宽高比 == 视频宽高比，`OverlaySpaceMap` 的 aspectFill
  放置退化为整容器（fill == fit），映射公式与既有断言不变。检测/包络/快门/
  裁切共用该域；`visiblePhotoRect` 退化为全幅（钳制保留为防御，不再依赖）。
  真机确认照片 FOV == 视频 FOV（SC-007）；若照片更宽，快门时按视频 FOV 裁
  照片（后续子步，不在 D12 写死）。
- **D13 完整性门（视频 12/13/14，CF-T010/T011a）**：新增
  `isClippedAtFrameEdge`（任一边距帧边界 <1.5% 即被裁）。**区分单页与整摊**：
  整页意图下包络被裁但是单页（`isPageLike` 且非 `isSpreadLike`）→ 允许拍
  （视频 14：近距单页，裁掉的是纸边白边），并把呈现框钳到 [0,1] 后裁切；
  整摊/整书被裁 → 不画实线、快门置灰、提示后退（视频 12：拆页需要完整整摊）。
  左/右页意图下目标页是单页 → 允许贴边拍；目标缺失 → 允许拍包络回退
  （Review 拆分），不再因整摊贴边把整个取景变成不可拍（视频 13：目标短暂
  缺失导致实线/虚线抖）。允许搜索态虚线，但“整摊被裁”不得给出可拍实线。
- **D14 贴边单页（视频 12，CF-T011）**：左/右页意图且目标页书脊侧边落在
  帧边界 ±1.5%、其余三边可见、对页不在帧内（或 ≤2% 宽）时，取上/下边线与
  帧边界的交点合成书脊侧两角，得到目标四边形；1.5% 内缩引导线 + “贴边”
  徽标；未对齐或覆盖 <60% 帧高 → 不就绪。这是高清单页模式，不进整页路径；
  Review 侧 `quadRole` 记 `.target`，不再拆分。
- **D15 拍后逐边包含（CF-T010b）**：`refineQuads` 采纳静帧框前要求逐边落在
  拍摄框内（+1% 容差），替代“面积 ≤1.10× + IoU ≥0.85”。面积门无法区分
  “更宽更矮”的扩框；逐边包含直接对应 frame-truth 的“不得把用户没看见的
  内容扩回成片”。不满足保留拍摄框并记 `refineRejected=outsideCapture`。
- **D7 复用既有纯函数**：复用 `SpreadSplitter`、`SplitProposalConfidence`、
  `CandidateSticky`、`QuadSmoother` 的参数思想；不重写 splitter，不引入
  新的图像模型。光流/单应性传播是后续子步，先保持低频观测 + hold。
- **D8 纯离线与安全**：不接云；分割/去畸变模型只输出 mask/几何；禁止
  LLM/VLM 生成文档像素。引导/手动框路径保持不变。

## 不变式

- `Services/ServiceProtocols.swift` 协议签名不变（除本周期新增的 envelope
  协议已由前一提交加入）。
- 成片 = 快门瞬间呈现框（frame-truth）；拍后 refine 不静默扩回用户没看见的
  内容。**取景域 = 成片域**（D12）：预览容器宽高比恒等于视频宽高比，
  预览层不得再把 4:3 帧裁进全屏。
- 既有测试断言零修改；新增测试只增不减。D12 走“容器宽高比 == 视频宽高比”，
  `OverlaySpaceMap` 的 aspectFill 公式与既有断言保持原语义（fill 恰好铺满），
  不产生方向性翻转；新增 `ViewfinderLayout` / 完整性门 / 贴边合成 / 逐边包含
  用例，全量总数按实际增量更新 `Makefile` 基线。
- `PageDraft` 旧数据兼容：`outputIntent` / `quadRole` 默认 nil。
- 目标框 = 包络内的意图侧页面；画面边缘/页内竖条不得成为实线目标。
- WPS realbase 图片链 0.906224 与 docx hash 不回退。

## 风险表

| 风险 | 缓解 | 验证 |
|---|---|---|
| 左页 target 右角被整摊包络裁掉 | 主框/上下文分离；target 实线 | `CaptureOverlayQuadsTests` + 视频 7 |
| 屏幕外框被当页面 | `isScreenEdgeFrame` 四链路拒绝；快门守卫 | `PageIntentResolverTests` / `CaptureEnvelopeViewModelTests` |
| 拍后误拆单页 | `quadRole == .target` 不走拆分；左页不用 fold | `ReviewSplitProposalTests` |
| 单页两栏被亮缝误拆 | 亮缝搜索限 [0.30,0.70]；目标宽高比 ≥0.45；拍后仅 envelope 角色 | `SpreadSplitterGutterTests` / `PageIntentResolverTests` |
| 画面边缘/页内竖条成为目标 | `acceptTarget` 包络包含 + 意图侧 + 面积/宽高比 | `PageIntentResolverTests` |
| 亮缝模型在低对比/彩色页失效 | 暗谷 → 亮缝两级 fallback；失败保留包络不硬拆 | `SpreadSplitterGutterTests` |
| 低置信静默改框 | 高置信阈值 + 可撤销；低置信只提案 | `ReviewSplitProposalTests` |
| tracker hold 被拍下 | hold 时快门置灰；capture 二次守卫 | `CaptureEnvelopeViewModelTests` |
| 预览仍裁切/照片比视频宽 | 容器宽高比 == 视频宽高比；真机 FOV 标记物验收；必要时快门裁照片 | `ViewfinderLayoutTests` + `device-acceptance.md` §1.4 |
| 书未全入屏仍画实线 | D13 完整性门（1.5% 边距）；整页置灰 + 提示 | `CaptureFrameClippingTests` + 视频 12 |
| 贴边单页对齐误差带对页一条 | 1.5% 引导线 + 徽标 + 未对齐不就绪；只允许左/右意图 | `FlushEdgeTargetTests` + 视频 12 |
| 拍后静帧框扩回屏外内容 | D15 逐边包含（+1% 容差） | `ReviewRefineContainmentTests` |
| 真机跟手性不足 | 后续光流/单应性传播；先离线回放 | `device-acceptance.md` |
