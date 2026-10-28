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
- **D5 拍后高分辨率拆分**：Review 首轮精修在原图 1600px 矫正图上做书脊
  分析；右页单页框带折条时用 `SpreadSplitter.leftFoldTrim` /
  `leftBrightFoldTrim`。高置信 ≥0.5 自动写 quad + `userAdjustedQuad=true`
  + 撤销栈；低置信只写 `SplitProposal`（预选目标侧），首屏可见、用户确认。
- **D6 不重复拆分**：拍摄时 target 已是单页（`isSpreadLike == false`）时，
  左/右意图不再做书脊拆分；只有整摊包络才走 spine split。左页输出不使用
  leftFold（折条模型的左侧不是要输出的左页）。
- **D7 复用既有纯函数**：复用 `SpreadSplitter`、`SplitProposalConfidence`、
  `CandidateSticky`、`QuadSmoother` 的参数思想；不重写 splitter，不引入
  新的图像模型。光流/单应性传播是后续子步，先保持低频观测 + hold。
- **D8 纯离线与安全**：不接云；分割/去畸变模型只输出 mask/几何；禁止
  LLM/VLM 生成文档像素。引导/手动框路径保持不变。

## 不变式

- `Services/ServiceProtocols.swift` 协议签名不变（除本周期新增的 envelope
  协议已由前一提交加入）。
- 成片 = 快门瞬间呈现框（frame-truth）；拍后 refine 不静默扩回用户没看见的
  内容。
- 既有测试断言零修改；新增测试只增不减。
- `PageDraft` 旧数据兼容：`outputIntent` 默认 nil。
- WPS realbase 图片链 0.906224 与 docx hash 不回退。

## 风险表

| 风险 | 缓解 | 验证 |
|---|---|---|
| 左页 target 右角被整摊包络裁掉 | 主框/上下文分离；target 实线 | `CaptureOverlayQuadsTests` + 视频 7 |
| 屏幕外框被当页面 | `isScreenEdgeFrame` 四链路拒绝；快门守卫 | `PageIntentResolverTests` / `CaptureEnvelopeViewModelTests` |
| 拍后误拆单页 | 仅 spread-like 才 spine split；左页不用 fold | `ReviewSplitProposalTests` |
| 低置信静默改框 | 高置信阈值 + 可撤销；低置信只提案 | `ReviewSplitProposalTests` |
| tracker hold 被拍下 | hold 时快门置灰；capture 二次守卫 | `CaptureEnvelopeViewModelTests` |
| 真机跟手性不足 | 后续光流/单应性传播；先离线回放 | `device-acceptance.md` |
