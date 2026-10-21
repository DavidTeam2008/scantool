# Spec: 框真相（frame-truth）

**状态**：实施中（真机验收待做，device-acceptance.md）
**前置**：`spec/folded-page-capture`（折页书四痛点第一轮）、`spec/case-b-sticky-v2`、
`spec/wysiwyg-crop`（快门一致性门禁）
**诊断来源**：2026-10-17 真机复测（iPhone 13 · iOS 26.7）逐帧遥测 + 四链路读者
+ 红队复核（wf_e0a8174f-81e）

## 背景（真机证据，2026-10-17 21:55 会话）

上一周期修复后：框不抖 ✅、不自动拍 ✅；但仍有两个新症状：

1. **框只捕获右页一部分，调整角度也捕获不到页面边框**（shot1 21:55:38：
   `cropGate displayedArea=0.0618 stillArea=0.4491 iou=0.1543 acceptedStill=false`
   → 成片 = 0.06 局部条）。
2. **成片比实际区域大、且不只是取景框里的内容**（shot2 21:55:51：
   `displayedArea=0.3810 stillArea=0.4056 iou=0.9093 acceptedStill=true`；用户确认
   照片四周/左侧折痕边露出背景）。

逐帧遥测定案的四条机理（详见 plan.md「证据锚点」）：

- **门控一票否决（获取侧根因）**：`needsDocumentSegmentation` 只看「任一非退化且
  area>0.08 的严格矩形」——0.08–0.093 的文字带完全能通过（strict minSize 0.15
  按短边归一化，minAspect 0.2 允许 5:1 长条），于是**文档分割与放宽档两条恢复
  通道同时关闭**。页面档 0.45–0.48 连续存在 18 秒、still 给出 0.4056，证明页面
  能检出——只是带子存在的帧里「从未被请求」。
- **粘滞放大器**：分支④从**未过滤 rawCandidates** 改选（`selectedArea 0.056–
  0.077` 低于 select 的 minArea=0.08，只可能来自这里）；505 条 `stickyOverride`
  （24.3% 帧）在 21:55:28–31 期间几乎每帧都用带子替换掉 select 选中的页面
  （0.34–0.56）；escape 后单帧起锚（抽签）；hold 把错锚点再保护 5 帧。
  「不抖了」部分是「稳定地错」。
- **呈现语义矛盾**：面积 0.06 时引导 `.closer`（靠近一点），但 overlay 照画
  锁定实线框 + 锁定震动；自动快门门禁也不看引导（默认关闭掩盖了洞）。
- **快门链隐藏精修**：still 路径是**无身份锚定的全局重选**（包含降权把被
  「右页+折痕」外框包含的右页 ×0.35，面积/居中偏好让外框胜出），且贴边吸附
  只在 still 发生、外向相从不测 s=0（已贴真实边的检出会被继续外推，折脊/阴影
  可达 1–2%/边）。门禁只有 bbox IoU，**原理上无法区分合法贴边精修与越界外扩**
  （既有 fixture 有 +12%/+14%/+21% 的合法精修，shot2 是 +6.5% 的越界）。

## 用户故事

- **US1**（P1）框锁定的是页面：折页书右页场景下框不锁定局部文字带；页面候选
  持续在候选池中（分割/放宽档不再被带子否决）。
- **US2**（P1）框的承诺诚实：出现「靠近一点」等无效引导时，不显示可拍摄的
  锁定框、不震动、不自动拍；手动快门视为搜索态。
- **US3**（P1）成片 = 屏幕所见：手动/自动快门的裁切框 ≡ 快门瞬间呈现框（锁定
  态 = 冻结框）；任何贴边精修都发生在锁定瞬间并**显示在屏幕上**，快门后不再
  有隐藏重检/换框。
- **US4**（P1）可取证：下一次真机会话能直接读出候选来源、逐边吸附、四角与
  sticky 判定，不再靠猜。

## 功能需求

- **FR-001 候选池单一真源**：新增 `DetectionStrategy.viablePool(rawCandidates:)`
  返回 `select` 使用的 viable 集合（`!degenerate && area > minArea`）；
  `select` 与 live 粘滞调用点共用（sticky 不再接收未过滤 rawCandidates）。
- **FR-002 页面先验门控**：新增 `DetectionStrategy.pageLikeMinArea = 0.25`；
  `needsDocumentSegmentation` 改为「**不存在**非退化且 area ≥ pageLikeMinArea 的
  严格矩形」；`needsRelaxedRectangles` 复用同一谓词。`select.minArea` 保持 0.08
  （远摄检测能力与「太远」引导语义不变）。
- **FR-003 粘滞锚点治理**（`CandidateSticky.apply` 新增可选参数，全部默认值保持
  v1/v2 语义，live 调用点显式覆盖；阈值空间 = **视频 FOV 面积**）：
  - `anchorMinArea`（默认 0，live = 0.12 ≈ 照片空间 0.09）：低于下限的候选可
    显示（透传）但不得起锚；
  - `reanchorConfirmFrames`（默认 1，live = 3）：escape/初锁后需连续 K 帧相似
    择优才起锚（消灭单帧抽签）；
  - `followMinAreaRatio`（默认 0，live = 0.8）：分支③跟随要求两框面积比
    min/max ≥ 0.8（堵包含链 30%/帧棘轮）；
  - 锚点时间生命周期：apply 间隔 > 1s（会话边界/停顿）自动清锚。
  - **不引入 override 面积比守卫**（红队：0.2 与既有窄页合法 fixture 0.284
    间隔过窄；锚点准入已从源头消灭带子锚点）。
- **FR-004 EdgeSnapper 边已在边上就不动**（FR-D，实现见 plan D4）：外向搜索前
  先测 s=0 对称梯度 `G0 = L(−δ) − L(+δ)`（δ = maxShift/12，**双线性采样**避免
  栅格量化把 ±δ 采成同一像素）；`G0 ≥ gradientThreshold` 时：外向峰未达
  1.25×G0 → 该边零位移并跳过内向相；外向峰显著更强 → 允许外移；`G0 < 阈值`
  → 既有两相逻辑不变。
- **FR-005 锁定冻结 + 精修上屏**（FR-G，用户已选型）：文档模式锁定态首次进入时，
  用**当前帧检测**（视频空间）与 **VideoFrame.cgImage** 做一次有界吸附
  （maxShiftRatio 0.04，含 FR-004 守卫），结果经 FOV 反算（video→photo）后作为
  **冻结框**显示，锁定期间 `imageQuad` 保持冻结框；解锁/搜索时清除。贴边修正
  只发生在快门前且屏幕上可见。
- **FR-006 快门 = 呈现框**：文档模式 `imageQuad != nil` 时，`capture()` **不再
  调用静帧重检**，裁切框 = 呈现框（锁定态 = 冻结框）；搜索态（`imageQuad ==
  nil`）保留既有静帧自由检测链。idCard 路径不变。`cropGate` 日志在该路径记
  `stillArea=-1 iou=-1 acceptedStill=false`（= 冻结直裁，未重检）。
- **FR-007 取景有效性契约**：`overlayIsLocked = phase.locked && directive !=
  .closer`；自动快门门禁增加 `directive != .closer`；`capture()` 在
  `directive == .closer` 时把呈现框视为无效（按搜索态处理）。`.backOff`
  （可疑近满幅/贴边）不在此列——手动拍仍尊重用户意图。
- **FR-008 取证遥测补齐**：
  - `candidateProvenance`（live 每帧一行）：strictCount/strictMaxArea、
    segArea(或 nil)、relaxedCount/relaxedMaxArea、viableCount/viableMaxArea、
    gateSeg/gateRelaxed、preStickySelectionArea、stickyDisposition、heldArea；
  - `cropQuad`（快门时）：displayed 与 still 的四角（照片空间）；
  - `snapEdge`（吸附时逐边）：edge 序号、G0、bestShift、相位；
  - `snapOnLock`：seed/post 面积与四角；
  - `stickyOverride` 增记 heldArea/selectionArea。
- **FR-009 既有断言**：除方向性翻转清单（tasks.md 记录：冻结直裁使 3 个测试
  函数的「有呈现框时静帧胜出」语义翻转）外，既有断言零修改；
  `ServiceProtocols.swift` 零改动。

## 成功标准

- **SC-001** 折页书拍右页：`selectedArea < 0.08` 零出现；0.06–0.09 段单次持续
  ≤1s 且不进入可拍摄锁定态；框捕获右页而非局部带（真机 §1）。
- **SC-002** 成片 = 快门瞬间呈现框：`cropGate stillArea=-1`（冻结直裁）路径
  ≥90% 手动拍；成片四角 = 冻结框四角（导出照片与日志四角对照，误差 ≤0.5%）。
- **SC-003** 平整 A4：锁定瞬间吸附后边缘误差 ≤ 短边 2%（`snapOnLock` 与导出
  照片对照）；锁定时可见 ≤ 短边 5% 的一次修正，无快门后隐藏变化。
- **SC-004** 有效性：`closer`/无效框不出现锁定框/震动/自动拍；
  autoCapture 显式开启时仅有效锁定帧可自动拍（真机 §2）。
- **SC-005** `make test` 全绿：386 = 385 passed + 1 expected failure + 0 failed
  （基线 377 + 新增 9；翻转清单见 tasks.md）。

## 边界与例外

- 图文带 0.12–0.24（视频空间）仍可显示但不可起锚（anchorMinArea=0.12）、不可
  锁定拍摄（photo 0.09–0.18 中 0.09–0.12 段引导可能显示"太远"，其余为
  tracking 不锁定）；这是刻意的保守取舍，真机观察后可调。
- 折脊亮度剖面若不是「亮→暗」而是「亮脊」，s=0 守卫不触发、内向相也不适用
  （签名不匹配）→ 原样返回，成片可能仍含细折痕：用户手动调框兜底。
- 锁定吸附用 405×720 视频帧（精度低于 4032×3024 静帧）；若真机显示平整文档
  贴边精度回退 >2%，评估把吸附帧源换成高质量预览流（独立周期）。
