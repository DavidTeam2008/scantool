# 12 交接文档（单入口）

> 面向**接手的 AI 工程师 / 新同事**：这一篇是全貌入口——项目是什么、质量现状、卡在哪、
> 下一步往哪走、上手怎么走。每项都可下钻到证据（spec/ 周期工件与 docs/ 专题）。
> AI agent 请从 [`AGENTS.md`](../AGENTS.md) 进入（铁律与命令速查）；人读细节下钻
> [`09 接手手册`](09-project-handbook.md)。
>
> 更新：2026-10-22 · 代码基线：C1 `c5a60ac`「WYSIWYG 裁剪与 WPS 对标两周期改动」
> （wysiwyg-crop + wps-parity-layout 两周期产物入库点）+ case-b-sticky-v2 周期
> 改动（§2.2 修复，待入库）+ folded-page-capture 周期改动（§2.1 第一轮定案与修复）
> + frame-truth 周期改动（§2.1 第二轮：框真相与冻结直裁，待入库）
> + **guided-capture 周期**（2026-10-21 复核后新增：引导框 MVP + 画布真值 +
> trace/replay；**Phase 0 + Phase 1 代码已交付**（2026-10-22），真机验收待做；
> 先读 [`15`](15-capture-recovery-assessment.md)）

---

## 1. 项目全貌

**一句话**：把纸上的东西干净地收进 iPhone 的**纯离线**扫描工具——取景自动框边、透视拉正、
增强、OCR、版面还原、导出 PDF / Word；对标 WPS 扫描 / 全能扫描王的主体能力，
不做账号墙、不接云。

| 关键事实 | 值 |
|---|---|
| 语言 / 最低部署 | Swift 6 · iOS 18.0+（结构化识别用 iOS 26 `RecognizeDocumentsRequest`） |
| bundle id | `com.david.Zhixia` |
| 网络依赖 | **零**（纯离线；TextIn 云解析是 stub，`parse` 直接 throw） |
| 架构分层 | App → Features（SwiftUI MVVM）→ Domain（纯函数）→ Services（actor 副作用），依赖只向下 |
| 代码规模 | 152 个 Swift 文件（主工程 108 / 测试 44）/ 主工程约 14.5k 行 |
| 质量现状 | **444 用例 = 443 passed + 1 expected failure + 0 failed**（Swift Testing；2026-10-21 实测；基线只增不减） |

### 1.1 SDD 周期一览（9 个已交付 + 4 个进行中 + 1 个待实施）

| # | 周期 | 主题 | 关键交付 | 基线 | 验收 |
|---|---|---|---|---|---|
| 1 | `scan-edge-accuracy` | 取景框/成片比书小 | 候选择优（两级面积兜底/包含降权）、still 贴边吸附、可疑锁定不自动拍 | — | `spec/scan-edge-accuracy/device-acceptance.md` |
| 2 | `layout-restore` | 版面还原 v1 | 文本还原基本链路 | — | 同名目录 |
| 3 | `layout-engine` | 预览 = Word 的布局引擎 | 溢出阶梯 / split / 消解 / 表格模板 / 双栏；映射一致性断言 | →255 | 同名目录 |
| 4 | `scan-fidelity` | 扫描保真六缺陷 | 行级字号同源 / y 跨度重叠聚类 / 下划线占位 / 搜索回填 / `OverlaySpaceMap` 解析映射 / 四态引导 | 255→277 | 同名目录（SC-001~006） |
| 5 | `live-edge-crop` | 折页厚书可靠裁切 | live 三级检测兜底（严格矩形→文档分割→放宽矩形）、连续实线整框、快门回退链 | →295 | 同名目录 |
| 6 | `overlay-frame-visibility` | 整框可见最后一环 + 快门节奏 | `QuadShape` 屏幕点契约统一、自动快门 6 帧确认窗 | 295→302 | 同名目录 |
| 7 | `wysiwyg-crop` | 所见即所得 | R4 快门裁切门禁 `CropConsistencyGate`、R5 候选粘滞 `CandidateSticky` | 302→317 | 同名目录（⚠️ 真机复测未达效，见 §2） |
| 8 | `wps-parity-layout` | 默认导出对标 WPS | 流式档默认 / v1 假表聚类器退役 / 丢字哨兵 `textSentinel` / `FlowParagraphSplitter` 段落收敛 / 漫画条内联 / `reconstructPath` 通路日志 / 金标准端到端套件 | 317→357 | 同名目录（真机取证待做，见 §2.4） |
| 9 | `agent-handover` | 交接与项目 Agent 化 | 复测结论落盘、AGENTS.md + Makefile、全量文档同步、本文 | 357 不变 | `spec/agent-handover/` |
| 10 | `case-b-sticky-v2`（进行中） | Case B 粘滞 v2 hold-through-miss | 池交替根因代码级定案、`CandidateSticky` v2 参数门控、`stickyHold`/`stickyEscape` 遥测补缺、存在性交替单测 ×11 | 357→368 | `spec/case-b-sticky-v2/`（真机复测并入周期 11） |
| 11 | `folded-page-capture`（进行中） | 折页书四痛点：框抖 / 边框捕获 / 自动拍 / 折痕入片 | 四链路根因定案（regime c 近摄交替被相似跟随吞并等）、autoCapture 默认关（零迁移）、live 严格档放宽（0.15/26°）、粘滞调用点 0.70/5 止棘轮、`EdgeSnapper` 双向两阶段内拉、`gateRejectedStill` 贯穿 WYSIWYG | 368→377 | `spec/folded-page-capture/`（真机验收已被周期 12 取代） |
| 12 | `frame-truth`（进行中） | 框真相：框锁局部带 / 成片越界 | 逐帧遥测定案（门控一票否决 + 粘滞④改选 + 逃逸抽签）、`viablePool` 单一真源、页面先验门控 0.25、锚点治理（0.12/3帧/0.8）、EdgeSnapper s=0 守卫（双线性）、**锁定冻结 + 精修上屏 + 成片=呈现框**、无效框承诺、来源/四角遥测 | 377→386 | `spec/frame-truth/`（真机验收待做，合并 Case B 复测 + L1 取证） |
| 13 | `scan-enhance`（进行中） | 拍后增强 / 拍后拆分 / 清晰化 | 全分辨率静帧重检 + 身份锚定、书脊/左折条拆分、document 增强档、Review 可见可调 | 386→392 | `spec/scan-enhance/`（真机验收 T006 待做） |
| 14 | `guided-capture`（**Phase 0~2 已交付**，真机验收待做） | 引导取景：用户框定右页 + 画布真值 + 取证/回放 + Review 拆分确认 | **Phase 0**：trace 环形缓冲 / 全候选落盘（全部 viable + top 8）/ 诊断包导出 / 回放基线；**Phase 1**：引导模式与意图、屏幕↔照片逆映射、引导框 UI（可拖）、自动对位 + 松手吸附、引导拍摄分支（成片 = 框）、框生命周期；**Phase 2**：拆分从「静默应用」改为「提案 + 用户确认 + 可撤销」；自动路径零改动 | 417→444（真机计数待 T030） | `spec/guided-capture/`（先读 `docs/15`） |

> 基线说明：表中“377→386”等是各周期交付时的计数；2026-10-21 全量实测总基线
> 为 **444 = 443 passed + 1 expected failure + 0 failed**。`guided-capture`
> 的最终计数在 T030/T034 回填。

---

## 2. 当前卡点（诚实清单，按优先级）

> **2026-10-21 复核（先读 [`15`](15-capture-recovery-assessment.md)）**：Case A/B
> 的既有修复仍在等待真机验收，但复核认为主场景的根因不只是“框不够稳”——管线
> 缺少“我要拍右页”的意图，评分/粘滞会稳定地锁错；`QuadSmoother` 的锁定判据
> 是逐帧差，慢漂移不会解锁；Review 拆分仍会静默改 quad。因此新增
> `spec/guided-capture/`：先做引导框 MVP + trace/replay，自动模式的 sticky/
> smoother 调参暂缓；原 P0-1/P0-2 降级为 A/B 失败后的备选路线。

### 2.1 🔴 P0 · Case A：折页书（两轮定案；frame-truth 冻结直裁已交付，真机验收待做）

> **第二轮（2026-10-17 真机复测 → `spec/frame-truth`）**：第一轮修复后「框不抖 ✅、
> 不自动拍 ✅」，但暴露两个新症状：①框只捕获右页一部分、调角度也不恢复；②成片比
> 实际区域大、且露出取景框外内容（用户确认四周/左侧折痕边露背景）。逐帧遥测
> （2082 帧）定案四条机理：**a. 门控一票否决**——任一 area>0.08 的严格矩形（文字带
> 0.08–0.093 完全能通过）让文档分割与放宽档**同时不运行**，页面候选不是检不出而是
> 「从未被请求」（页面档 0.45–0.48 连续 18 秒、still 0.4056 为证）；**b. 粘滞放大器**
> ——分支④从**未过滤原始池**改选（0.056–0.077 低于 select.minArea，只能来自这里），
> 21:55:28–31 期间 select 几乎每帧选中页面（0.34–0.56）却被带子 override（505 条、
> IoU 0.00–0.15）；escape 后单帧起锚（抽签）；hold 保护错锚点——「不抖」部分是
> 「稳定地错」；**c. 呈现矛盾**——面积 0.06 时引导 `.closer` 与白色锁定框/震动同屏，
> 自动拍门禁不看引导；**d. 快门隐藏换框**——still 是无身份锚的全局重选（包含降权
> 使「右页+折痕」外框胜出），且吸附只在 still 发生、外向相从不测 s=0（已贴边的检出
> 被继续外推 δ~1–2%），门禁只有 bbox IoU 无法分辨合法精修与越界。
> **修复（frame-truth，交付时 386 全绿；当前总基线 444）**：`viablePool` 单一真源；页面先验门控 0.25；
> 锚点治理（anchorMinArea 0.12 / 起锚 3 帧确认 / 跟随面积比 0.8 / 1s 清锚）；
> EdgeSnapper s=0 守卫（双线性 G0）；**锁定瞬间吸附上屏并冻结、成片=呈现框**
> （快门后不重检）；无效框（closer）不画锁定框/不自动拍/手动拍走搜索态；
> `candidateProvenance`/`cropQuad`/`snapEdge`/`snapOnLock` 遥测。验收主清单：
> `spec/frame-truth/device-acceptance.md`（T011 待做）。

### 2.1.1 第一轮记录（folded-page-capture）

- **现象**：折页书翻中间、左侧折起拍右页，成片包含折起部分（2026-09-26 复测用户逐字：
  「case A，还是会有折起部分」；2026-10-17 最新反馈逐字：「取景框一直在抖动，没有捕获到
  页面边框，会自动拍，拍出来的效果左边折痕还是有一点，其它地方沿着边框裁剪的」）。
- **根因（2026-10-17 四链路合成定案，understand-folded-book 工作流 wf_ff79605d-f9e）**：
  四条独立机理——① **抖动**：近摄制式右页/整书 bbox IoU ∈ [0.60, 0.70)，粘滞分支③
  「相似跟随」（阈值 0.60）把存在性交替吞成跟随，锚点逐帧棘轮、areaJump 反复重置、
  永不锁定（regime c，case-b-sticky-v2 未覆盖的制式）；② **边框捕获失败**：live 严格
  矩形档（minSize 0.25/容差 20°）对折页曲面页结构性过严，正确候选不在池中；
  ③ **自动拍**：整书 quad（面积 0.85~0.94）绕过 `isSuspiciousForAutoCapture`，6 帧
  确认窗后自动拍出废片；④ **折痕入片**：`EdgeSnapper` 仅外向搜索，检出左缘越过
  折痕带时真实边缘在内侧够不着；外加 WYSIWYG 穿透：门禁「呈现框优先」决策在整理页
  被 `refineQuads` 无条件 still 重检改写。原 H1/H2 之争收敛为 H1 家族（显示侧 +
  检测侧），门禁契约本身未被判错。
- **修复（folded-page-capture 周期，已交付）**：autoCapture 默认关（零迁移翻转 +
  可疑提示门控）；live 严格档放宽 minSize 0.15/容差 26°；粘滞调用点
  `similarityThreshold: 0.70, missLimit: 5`（默认常量不动）止近摄棘轮；
  `EdgeSnapper` 双向两阶段（外向优先，内向相 ≤0.5×maxShift @ 阈值 0.12）；
  `PageDraft.gateRejectedStill` 随草稿落盘、整理页 refine 跳过置位页。全量 377 全绿。
- **证据**：`spec/folded-page-capture/`（四件套：四痛点机理图 / D1~D7 决策 /
  验收清单）；`spec/wysiwyg-crop/spec.md` · `spec/agent-handover/device-retest-20260926.md`。
- **复测状态**：代码与单测交付（2026-10-17）；**真机验收待做**——按
  `spec/folded-page-capture/device-acceptance.md`：折页书四痛点复测（§1）+ 默认不自动拍
  与设置保留（§2）+ 平整文档防回归（§3），同会话合并 Case B 复测与 `reconstructPath`
  L1 取证（§4），日志判读口径见该文。

### 2.2 🟠 P0 · Case B：摊开书实线框持续跳动、手动拍含左页大半（粘滞 v2 已交付，真机复测待做）

- **现象**：摊开书从中线取景拍右页，实线框在右页与整书两候选间持续跳动、永不锁定；
  手动拍成片含左页大半（复测用户逐字：「case B，实线框一直再跳，手动拍，左边很大部分都近图片」；
  2026-10 最新反馈：「实线框持续跳动有改善，其它的问题都还在」——同池共存帧已被 v1 吸收，
  存在性交替帧仍在跳）。
- **根因（2026-10-17 代码级定案）**：池交替盲区**确认**——三级检测门控
  （`needsDocumentSegmentation`/`needsRelaxedRectangles`）使 live 候选池逐帧近似单源，
  两候选以存在性交替出现时 `CandidateSticky` v1 的同池续锚分支结构性不触发，恒走
  miss 透传、回摆帧又把 missCount 清零——逃逸永不触发、锚点永不保护、输出逐帧翻转；
  下游 `QuadSmoother` 每帧 areaJump 重置 → 永不锁定。`stickyOverride` 两轮未取得的
  原因：只在改写帧发射、miss 路径零遥测——日志缺席恰是池交替假设的预测结果。
  C4（手动拍含左页）定性为下游症状：振荡期快门快照到整书帧/插值混合帧/nil，
  门禁按契约忠实工作，修好振荡即收敛（门禁与快门路径未动）。
- **修复（case-b-sticky-v2 周期，已交付）**：`CandidateSticky` v2 **hold-through-miss**
  ——miss 窗口内维持锚点（与 `QuadSmoother` miss 语义对齐），达限仍逃逸；
  参数门控（默认 v1 语义）→ 既有断言零修改；新增 `stickyHold`/`stickyEscape`
  遥测补缺（真机一趟可判读制式）；存在性交替单测 ×10（含 sticky→smoother
  集成锁定与对照组机理钉住）。全量 367 全绿。
- **证据**：`spec/case-b-sticky-v2/`（四件套：根因证据链 / D1~D5 决策 /
  复测清单）；`ZhixiaTests/CandidateStickyV2Tests.swift`。
- **复测状态**：代码与单测交付（2026-10-17）；**真机复测待做，已并入
  frame-truth 同一真机会话**——按 `spec/case-b-sticky-v2/device-acceptance.md`：
  ≤5s 稳定不跳可锁定 / 手动拍成片=呈现框 / `stickyHold`+`cropGate` 日志归档
  （`stickyEscape` 口径随本周期 missLimit 5 更新为 afterMisses=5），同会话顺带
  `reconstructPath`（§2.4 L1 取证）。

### 2.3 🟠 P1 · WPS 对标剩余差距（总体观感未达）

- **现象**：复测用户逐字：「整体上感觉跟wps的扫描还是有差距」。
- **拆解**：**还原链已达标**（金标准级：流式档默认 / 零假表 / "wrong bus!" 未丢 /
  段落 32∈42±30% / 漫画条内联，`GoldenWorksheetEndToEndTests` ×10 真实 Vision 链路验证）；
  差距主缺口在**取景拍照环节**（= §2.1/§2.2）与 **L1 通路未定案**（= §2.4）。
- **证据**：[11 §7 周期 1 实施后真机复测](11-wps-parity-research.md)（W1~W6 交付核对表）。
- **复测状态**：还原侧金标准全绿、真机验收待做；取景侧见 §2.1/§2.2。
- **WPS 录屏补充（2026-10-21）**：49s 录屏已收到并评估（[15 §十一](15-capture-recovery-assessment.md)）。
  黑盒事实：手动快门；单实线框是**自动跟随页面**（无角手柄），10fps 下平滑，
  但会在右页/整页间切换，快门时也不紧；成片比预览框更紧，Toast 明示自动裁剪 +
  最佳滤镜；左折边靠裁切去除。结论：我们的固定引导框是替代范式，不是 WPS 同款；
  引导框 + 手动快门 + Review 可见裁边/滤镜仍是主线，WPS 的静默换框不照搬。
- **建议方向**：取景侧范式决策——调研报告提出「固定引导框范式」（框常驻 +
  用户对位 + 边缘吸附，结构性绕开候选振荡）作为周期 2（wps-parity-capture）的
  候选方向；注意 WPS 录屏实际是自动跟随框，不是同款。**先完成 §2.1/§2.2 的
  日志取证**再评审取舍（7 个周期范式内修补真机仍败 vs 切范式的迁移成本）。

### 2.4 🟠 P1 · L1 真机通路疑案（iOS 26 结构化识别疑似静默回退）

- **现象**：iPhone 13（iOS 26.7）2026-09-21 真机导出的 docx 走了几何回退通路；
  模拟器（iOS 26.4.1）同输入结构化通路正常（structuredSuccess，样张 7×3 表）。
- **根因**：**未知**（失败 / 超时 / 结果被判无效均有可能）；真机接通性从未验证。
- **证据**：[11 §3.1 L1](11-wps-parity-research.md) · `spec/wps-parity-layout/device-acceptance.md`
  §A（取证步骤）。
- **复测状态**：未取证。诊断基建已就位——`reconstructPath` 每页一条五分类决策线
  （debug + privacy.public），真机跑一次语法页导出、Console 抄录即可定案。
- **建议方向**：与 §2.1/§2.2 的取证**合并进同一次真机会话**（一趟抄齐
  `reconstructPath` + `cropGate` + `stickyOverride`）；若确认回退，按失败分支修复接通；
  若 Apple 通路对该输入确实失败，固化判定并保证几何回退质量。

### 2.5 🟡 P2 · 几何兜底老系统与工程债

- **iOS 18~25 真机表格**：几何通路真机仍 `w:tbl = 0`（真机 OCR 把整行单元格合并成
  一个 line，「midX 聚类推列」假设失效；根因链见 [08](08-reconstruct-v3-realworld-fix.md)），
  `ReconstructEndToEndTests.realDeviceOcrStillLacksTable` 用 `withKnownIssue` 钉住；
  降级阶梯（anchor → 通用数字列）未建，v1 聚类器已退役不再参与。
- **工程债**：`LibraryViewModel.reload` 全表加载 + N+1；`ReviewViewModel.save` 全量驻留
  内存（50 页 ≈ 50-150MB）；`SwiftDataDocumentStore` 零测试无迁移；Review 返回泄漏
  tmp 会话目录。完整清单见 [09 §7 P1/P3](09-project-handbook.md#7-后续优化方向)。
- **建议方向**：按 §3 路线图 P2 排期处理；动表格兜底前先读 `spec/scan-fidelity` 与
  `docs/08` 的根因链，避免回到「阈值过拟合」老路。

---

## 3. 路线图（按优先级）

> **执行顺序更新（2026-10-21）**：以 [`docs/15`](15-capture-recovery-assessment.md)
> 与 `spec/guided-capture/` 为准。P0 先做引导框 MVP + trace/replay + 真机
> A/B；自动检测的 alpha/显示死区等调参不在当前主线，只有引导未胜出时才按
> `spec/guided-capture/plan.md` D9 的顺序启动自动恢复周期。

| 阶段 | 内容 | 前置 |
|---|---|---|
| **P0 裁剪质量** | Case A：✅ 两轮定案 + frame-truth 已交付（交付时 386 全绿；当前总基线 444：候选池单一真源 / 页面先验门控 / 锚点治理 / s=0 守卫 / **锁定冻结+成片=呈现框** / 无效框承诺）→ **真机验收**（`spec/frame-truth/device-acceptance.md`）；Case B：✅ 粘滞 v2 已交付 → **真机复测并入同一会话**（一趟抄齐 `stickyHold`/`stickyEscape`/`candidateProvenance`/`snapOnLock`）；**新增 guided-capture：引导框 MVP + 画布真值 + trace/replay + Review 拆分确认（当前主线；Phase 0+1 代码已交付 417→436，待真机验收）** | 三周期修复均已交付待入库；验收主清单 `spec/frame-truth/device-acceptance.md`（含合并项 §4）；引导验收 `spec/guided-capture/device-acceptance.md` |
| **P1 真机取证与对标收尾** | L1 通路取证（`reconstructPath`，可与 P0 同一会话）；iOS 26 表格真机验证；阴影场景 OCR 预处理档验证；条码真机验证（模拟器恒 0）；取证后评审「常驻框范式」周期 2（wps-parity-capture，WPS 录屏已提供并评估，见 §2.3） | P0 日志会话顺带完成取证 |
| **P2 老系统兜底与工程债** | 表格降级阶梯（anchor → 通用数字列）；列/行切分改投影找 gutter；导出层表格样式（`w:tblPr`/表头加粗/数值右对齐）与 `gridSpan`/`vMerge`；Library/Review/SwiftData 工程债 | P0/P1 收尾后 |
| **P3 云通路** | 接通 TextIn（低置信 block 走 `ReconstructRepairing`，禁止整页 LLM 重打表数字）；手写 / 勾选识别 | **独立周期评审**——纯离线是铁律，云通路须单独立项（含隐私披露与用户确认 UX） |

---

## 4. AI 工程师上手路径

### 4.1 读什么（按序）

1. [`AGENTS.md`](../AGENTS.md) —— 定位 + 索引 + 铁律（冷启动第一篇）
2. 本文 —— 全貌 / 卡点 / 路线图
3. [`09 接手手册`](09-project-handbook.md) —— 架构原理 + 卡点史（§4 契约、§6 卡点清单最常被引用）
4. [`00 接手指南`](00-getting-started.md) —— 实操：目录地图 / 怎么测
5. [`15 取景复盘`](15-capture-recovery-assessment.md) —— 2026-10-21 复核：为什么先做引导框、代码证据、10 天计划
6. 动 **capture 侧**前：`spec/guided-capture/` 四件套 + `spec/wysiwyg-crop/spec.md` + [09 §4.2](09-project-handbook.md)（WYSIWYG 裁切契约 / overlay 屏幕点契约）
7. 动 **reconstruct 侧**前：`spec/wps-parity-layout/spec.md` + [09 §4.5](09-project-handbook.md)（版面对标契约）+ [`06`](06-document-reconstruction.md)

### 4.2 跑什么

```bash
make doctor    # 环境自检（Xcode / 模拟器 / Busy 提示）
make test      # 全量单测 + 自动 xcresulttool 计数（基线：total=444 passed=443 failed=0 expectedFailures=1）
make test-only T=GoldenWorksheetEndToEndTests   # 局部单测
make smoke     # 装机冒烟（build + install + launch + 存活检查）
make device-build   # 真机目标编译（generic/platform=iOS，免签名）
```

- **本机 destination**：`iPhone 17 Pro` 只装了 iOS 26.4.1，而 `make test` 未指定
  OS 时 xcodebuild 可能解析到 27.0 并失败。T000 修好前用：
  `make test DEST_SIM='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4.1'`。
- 环境坑已固化进 Makefile：`DEVELOPER_DIR` 默认注入；`OTHER_SWIFT_FLAGS="-disable-sandbox"`
  必加（macOS 26.x 宏沙箱失效，不加所有宏报错）；模拟器 `Busy` 不是代码问题，
  `xcrun simctl erase all` 后重跑。
- **计数陷阱**：known issue 用例日志是 `recorded an expected failure`，不是 `passed`——
  按 `passed` 搜日志会少算 1 条；以 `make test` 末尾 xcresulttool 计数为准。

### 4.3 铁律（违反任何一条都会破坏既有资产）

1. **`Services/ServiceProtocols.swift` 协议签名不变**——全部依赖经协议注入，签名一动全部替身测试连锁崩。
2. **既有测试断言零修改**——基线 444 只增不减；方向性翻转属唯一例外，须在周期 tasks.md 逐条记录（先例：`ReconstructTierTests` 默认档翻转）。
3. **纯离线**——不引任何网络依赖、不加云调用；云通路是 P3 路线图，须独立周期评审。
4. **模拟器条码恒 0 是假绿**——`VNDetectBarcodesRequest` 模拟器永远返回空；条码断言只能靠 `BarcodeDetecting` 协议注入替身 + 真机验收。
5. **`withKnownIssue` ≠ failed ≠ passed**——见 4.2 计数陷阱。
6. **动 capture / reconstruct 侧前先读对应 spec**——每轮修复都钉在 `spec/<周期>/spec.md`（FR/SC 编号）；跳过 spec 直接改代码是历次回归的根因。

### 4.4 怎么开 SDD 周期

```
spec/feature.json → 指向新周期目录（spec/<name>/）
周期内五阶段：spec.md（需求 + 验收标准）→ plan.md（技术决策 D1~Dn）
  → tasks.md（任务拆解，带依赖/并行/验证标记）→ 实施（子代理逐任务勾选）
  → 验证（子代理收尾构建/部署/逐故事验证 + device-acceptance.md 真机清单）
```

- **实施与验证分离**：验证结论不与实施利益绑定。
- **真机验收闭环**：真机产物取证 → 本地同参对照 → fixture 固化为回归锚点
  （先例：金标准语法页 42 段阅读流从用户导出的 docx 解包提取）。
- **先取证再动刀**：Case A/B 两轮修复都在无日志定案状态下进行、真机复测均未达效——
  这是本周期最重要的教训，任何下轮修复必须先实时抓日志定案。

---

## 5. 证据索引

### 5.1 spec/ 周期工件（9 个已交付周期 + 4 个进行中周期 + 1 个待实施周期）

| 周期 | 四件套位置 | 一句话 |
|---|---|---|
| scan-edge-accuracy | `spec/scan-edge-accuracy/` | 取景框/成片比书小 → 边缘吸附 + 择优修正 |
| layout-restore | `spec/layout-restore/` | 版面还原 v1 |
| layout-engine | `spec/layout-engine/` | 预览 = Word 布局引擎 |
| scan-fidelity | `spec/scan-fidelity/` | 扫描保真六缺陷（FR-001~012） |
| live-edge-crop | `spec/live-edge-crop/` | 三级检测兜底 + 实线整框 |
| overlay-frame-visibility | `spec/overlay-frame-visibility/` | 屏幕点契约 + 6 帧确认窗 |
| wysiwyg-crop | `spec/wysiwyg-crop/` | 裁切门禁 + 候选粘滞（**§0 = 日志取证步骤，下轮必读**） |
| wps-parity-layout | `spec/wps-parity-layout/` | 默认导出对标 WPS（**§A = L1 取证步骤**） |
| agent-handover | `spec/agent-handover/` | 复测落盘（`device-retest-20260926.md`）+ Agent 化 |
| case-b-sticky-v2 | `spec/case-b-sticky-v2/` | Case B 池交替根因定案 + 粘滞 v2 hold-through-miss（真机复测并入下行周期） |
| folded-page-capture | `spec/folded-page-capture/` | 第一轮：默认不自动拍 / 检测放宽 / 粘滞 0.70·5 / 双向吸附（验收单已被 frame-truth 取代） |
| frame-truth | `spec/frame-truth/` | 第二轮框真相：候选供给 / 锚点治理 / s=0 守卫 / 冻结直裁 / 无效框承诺（**真机验收单 = 下一趟真机会话主清单**） |
| scan-enhance | `spec/scan-enhance/` | 拍后重检 / 书脊与左折条拆分 / document 增强（T006 真机验收待做；周期基线 392） |
| guided-capture | `spec/guided-capture/` | **2026-10-21 新主线**：引导框 MVP + 画布真值 + trace/replay + Review 拆分确认（**Phase 0+1 已交付**：trace/候选落盘/诊断包/回放基线 + 引导模式/逆映射/引导框 UI/自动对位/引导拍摄/框生命周期；基线 417→436；真机验收 T005/T030 待做，先读 `docs/15`） |

### 5.2 docs/ 索引

| 文档 | 内容 |
|---|---|
| [00](00-getting-started.md) | 接手指南：目录地图 / 主路径 / 怎么测（Makefile 用法） |
| [01](01-product-prototype.md) | 产品原型：场景 / 信息架构 / 视觉 |
| [02](02-architecture.md) | 架构：分层 / 工程结构 / 数据流（与代码对齐） |
| [03](03-tech-choices.md) | 技术选型 |
| [04](04-implementation-principles.md) | 实现原理与编码实践 |
| [05](05-roadmap.md) | 落地线路图：里程碑 / 优先级 / 真机清单 |
| [06](06-document-reconstruction.md) | 版面还原专题：IR / 管线 / 已知问题（§12.0 状态更新） |
| [07](07-reconstruct-r2-optimization.md) | R2 优化方案 |
| [08](08-reconstruct-v3-realworld-fix.md) | 真机回归根因链（R1~R6） |
| [09](09-project-handbook.md) | **接手手册**：一页讲全（§4 契约 / §6 卡点史 / §7 后续方向） |
| [10](10-project-summary.md) | 项目总结：架构 / 技术原理 / SDD 周期史 |
| [11](11-wps-parity-research.md) | WPS 对标调研：docx 取证 / 差距分析（L1~L7 / C1~C4）/ 周期规划 / §7 复测闭环 |
| [12](12-handover.md) | 本文 |
| [13](13-mcp-quickref.md) | MCP 使用速查：6 server 分工 / 配置落点 / 场景对照 / 项目铁律叠加 |
| [14](14-project-summary-and-roadmap.md) | **项目全面总结 + 完整优化路线图**（2026-10-21：取景稳定性 / 拍后裁切校准 / 竞品对标 / 工程债） |
| [15](15-capture-recovery-assessment.md) | **取景卡点复盘与引导框恢复计划**（2026-10-21：代码证据 / 10 天计划 / 验收指标 / 1 小时验证） |

### 5.3 提交锚点

- **C1 `c5a60ac`**「WYSIWYG 裁剪与 WPS 对标两周期改动」——wysiwyg-crop +
  wps-parity-layout 两周期产物入库点（46 文件），本文 §2 的卡点均对应此基线。
- **C2**（agent-handover 周期收尾提交）——复测记录 + AGENTS.md + Makefile + 文档同步 + 本文。
- 更早历史：`eb5a08b` 取景检测与整框渲染优化 · `c7acd3e` 优化项目 · `ed8d556` 初始版本。
