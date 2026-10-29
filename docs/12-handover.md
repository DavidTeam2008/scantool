# 12 交接文档（单入口）

> 面向**接手的 AI 工程师 / 新同事**：这一篇是全貌入口——项目是什么、质量现状、卡在哪、
> 下一步往哪走、上手怎么走。每项都可下钻到证据（spec/ 周期工件与 docs/ 专题）。
> AI agent 请从 [`AGENTS.md`](../AGENTS.md) 进入（铁律与命令速查）；人读细节下钻
> [`09 接手手册`](09-project-handbook.md)。
>
> **更新：2026-10-29 · 代码基线：`7a546b4`（工作区干净）**
> 当前主线：**P0.3 取景包络跟踪**（[`docs/22`](22-capture-envelope-tracking.md)）。
> 2026-10-29 视频 11/12 定位到新的 P0 根因：**取景域 ≠ 成片域**——预览只显示
> 4:3 帧的 61.6% 宽，检测/成片用整帧。CF-T010（4:3 取景窗 + 完整性门）已落；
> CF-T011a（近距单页）由用户确认修复。CF-T001~T011a 已交付，真机验收记录待补。
> 测试基线：**547 total；10 条既有债（5~10 条 flaky 命中），passed 以 `make test` 末尾计数为准**。
> 与当前 P0.3 冲突时，以本摘要 + `docs/22` + [`TODO.md`](../TODO.md) 为准；
> §2 的 Case A/B、guided-capture 等是历史背景，不要按旧路线继续调 sticky/smoother。

---

## 0. 2026-10-29 交接摘要（先读）

### 0.1 现在做到哪

- **产品主链路可用**：取景 → 快门 → 透视拉正/增强 → 整理 → 入库 → OCR →
  版面还原 → PDF / Word。纯离线，无账号墙、无云调用。
- **取景主线已切换为“包络优先”**：实时只维护一个整摊/书/单页包络；左/右页是
  **拍后输出意图**，不再要求实时精确锁定单页。
- **已交付（第一版）**：
  - `CaptureEnvelopeObservation` / `EnvelopeDetecting` / `CaptureEnvelopeTracker`；
  - 屏幕外框/`fullImage` 兜底移除；无当前帧包络或 tracker hold 时快门置灰；
  - 左/右页目标作为实线主框，整摊包络降为淡虚线上下文；
  - `PageDraft.outputIntent`；Review 在原图 1600px 矫正图上按书脊/折页高置信自动
    拆分，低置信只给预选提案。
  - **CF-T005b（视频 8）**：`PageDraft.quadRole`（target/envelope）+
    `SpreadSplitter.analyzeGutter` 亮缝模型；左页包络被预览裁掉时不再把整摊
    当目标页、跳过拆分；实时裁掉的整摊也能给出左页目标。
  - **CF-T005c（视频 9）**：亮缝搜索限中线 [0.30,0.70]；`acceptTarget`
    目标一致性（包络内/意图侧/宽高比/面积）；实时目标/包络日志。
  - **CF-T005d（视频 10）**：左右页并集包络（排除“墙 + 书”大矩形）；
    池内页候选优先于整摊拆分；目标面积门 6%。
  - **CF-T010（视频 11/12，2026-10-29 新根因，代码已落、真机复测待做）**：**取景域 ≠ 成片域**。
    预览 `.resizeAspectFill` 把 4:3 帧铺满 390×844 全屏，只显示 **61.6% 宽**
    （两侧各 19.2%）；检测/成片却用整帧，于是必须举高、框用屏幕外几何、
    成片横向范围是屏幕的 1.62 倍（多出 62%）。方案：4:3 取景窗 + `.resizeAspect` + 完整性门；
    **已落**：`ViewfinderLayout` + 4:3 取景窗 + `isClippedAtFrameEdge` 完整性门 +
    `frameClipped` 日志；新增 12 条测试；布局截图 `build/cf-t010/layout-sim.png`。
    **真机复测通过前不要再调目标面积/宽高比或 tracker 阈值。**
  - **CF-T011a（视频 14/13，2026-10-29 用户确认修复）**：近距单页
    被“贴边即未就绪”误伤（视频 14 虚线框准确但快门灰）。`isSinglePageForCapture`
    （归一化宽高比 <1.3）区分单页/整摊；整页单页贴画幅允许拍、整摊被裁仍置灰；
    左/右页目标缺失允许拍包络回退（视频 13 实线/虚线抖）；裁切框钳到 [0,1]。
- **真机验收记录待补**：视频 5/7/8/9/10 的目标框与成片；视频 11/12 的
  取景域（自然高度整本入屏、成片不超出屏幕、整页框不提前出现）；
  视频 13/14 已由用户复测确认修复，按 §0.3 与 `device-acceptance.md` §1.4 补记录。
- **已知测试债**：全量有 **10 个既有失败**（Golden 4、WordFidelity 1、Review preview 4、
  ReviewSplit/guidedPageSkipsProposal 1）。它们不是本轮引入；新增的 CF 用例全绿。
  细节见 §4.2。**不要为了让全量变绿去削弱断言**，先按测试治理单独处理。
- **WPS 图片链基线未回退**：realbase 导出 docx SHA-256
  `80903b1d…8cf4153`，与 `final-realbase.docx` / `g1-base.docx` byte-identical；
  **0.906224** 仍是门限。证据：`build/word-fidelity/realbase-cf45-20261028/`。

### 0.2 接手第一天怎么跑

```bash
cd /path/to/ios/scantool
make doctor          # Xcode / 模拟器 / Busy 自检
make test            # 全量；预期 547 total；10 条既有债随机命中，看末尾计数
make test-ci         # 团队 CI 全量：已知债不染红，只拦新增失败/总数下降
make test-gate       # 只校验最近一次全量结果（不重跑）
make test-only T=ReviewSplitProposalTests
make smoke           # 模拟器装机 + 启动存活
make device-build    # 真机目标编译（免签名）
```

- 默认模拟器：`iPhone 18 Pro` / iOS 27.0（见 `Makefile` 顶部）。
- 全量测试返回非零是**当前已知债务**，看 `build/last-test.log` 末尾的 xcresult 计数，
  不要直接判断为本轮回归。
- 真机调试需要在 Xcode 里给 `Zhixia` target 配 Development Team；模拟器相机画面
  不可信，取景/框/成片必须真机验证。
- 录屏原文件在 `docs/media/screenrecord/`，**未纳入 Git**（体积大，当前本地保留）；
  关键帧/联系表在 `docs/media/capture-ux/`。

### 0.2.1 真机验收操作卡（视频 5/7）

1. Xcode 打开 `Zhixia.xcodeproj`，`Zhixia` target → Signing & Capabilities 选自己的
   Development Team；连接 iPhone（iOS 18+），信任设备后 Run。
2. 首次启动允许相机；设置里取景模式保持 `.auto`（默认），拍摄意图切右页/左页/整页。
3. 按视频 5/7 的场景摆书：
   - 折页书右侧单页 / 左侧单页；摊开书；彩色封面与黑白内页；A4 单页；
   - 相机缓慢横移/靠近/远离，观察目标框是否持续可见、是否跳到整摊/桌面。
4. 每段操作录屏，并记录时间点；失败时在 Xcode Console 搜 `ZhixiaLog` 的
   `refineStage` / `reviewSplit` / `cropGate` / `envelope` 相关行。
5. 拍后进入 Review，确认左/右页最终成片；若高置信自动拆分错误，先用“拆分”工具
   撤销/重选，保留原图和日志，不要只截屏。
6. 验收结果按 `docs/22` §六表格记录，证据放 `build/capture-acceptance/<date>/`；
   **不要提交大录屏**。
7. 模拟器只用于构建/单测/相册导入；相机预览黑屏或框不可信是正常的，不能作为
   取景验收依据。

### 0.3 下一步做什么（按优先级）

1. **CF-T010 取景域 WYSIWYG（最高优先级，代码已落、真机复测待做）**
   - 视频 11/12 证明预览只显示 4:3 帧的 61.6% 宽，检测/成片用整帧；
   - 4:3 取景窗 + `.resizeAspect`；检测/成片/预览同域；`visiblePhotoRect`
     退化为全幅；
   - 整页意图：**整摊**贴帧边 → 未就绪（单页近距见第 2 条）；
   - 真机确认照片 FOV == 视频 FOV（取景窗四边贴标记物）；
   - 复测：自然高度整本入屏、成片不超出屏幕、整页框不提前出现。
2. **CF-T011a 近距单页（代码已落、真机复测待做）**
   - 视频 14：整页近距右页，虚线框准确但快门灰 → 单页贴画幅允许拍；
   - 视频 13：左/右页目标短暂缺失时实线/虚线抖 → 目标缺失允许拍包络回退；
   - 整摊被裁仍置灰；裁切框钳到 [0,1]；提示与快门一致。
3. **CF-T010b 拍后逐边包含**：`refineQuads` 面积门 → 逐边包含（+1% 容差），
   静帧不得把拍摄框外内容扩回成片。
4. **CF-T011 贴边合成**（T010/T011a 真机复测后）：左/右页意图、书脊侧边贴帧
   边界 ±1.5% 时合成目标；1.5% 引导线 + 徽标；整页禁用；成片不含对页。
5. **CF-T007 真机与 WPS 验收**
   - 先复测 T010 的视频 11/12 场景；再跑视频 5/7/8/9/10；
   - 视频 8：左页右角应落在亮缝 u≈0.547，成片不再含右页左栏；
     证据 `build/cf-t007/video8/`；
   - 视频 9：右/左实线框必须落在整页、在包络内、在意图侧；
     设备日志 `build/device-logs/video9/`；
   - 视频 10：包络不再含墙/脚，`target-rightPage` 不再给左页；
   - 20 彩页 + 20 黑白 + 10 A4 + 10 曲面/折页；按 `docs/22` §六量化；
   - 记录：框可见率、切换次数、锁定延迟、输出页正确率、禁止内容入片率、修正次数；
   - 清单：`spec/capture-envelope-tracking/device-acceptance.md`。失败先留现场日志/录屏。
6. **CF-T008 光流/单应性传播**：当前 tracker 是低频观测 + hold/平滑/候选切换确认，
   跟手性仍未达 WPS；先做离线回放，再接主路径。
7. **CF-T006 UI/快门收口**：置信度态、锁定后自动/手动快门、按下瞬间冻结包络、
   引导/手动框兜底（取景窗布局随 T010 收口）。
8. **CF-T009 观测增强（按需）**：先测传统 Vision 失败率；不足再评估端侧分割 mask
   （离线、ANE），只输出 mask/几何，禁止 LLM/VLM 生成文档像素。
9. **恢复暂停项**：PP-T032 全流程、多条件样张回归、flaky 清理（用户已同意暂停，
   不要在本轮擅自开工）。
10. **P0.3 之后**：再评审是否引入端侧分割模型 / 其他恢复路线。

### 0.4 不要做什么

- 不要把“全量 10 个已知失败”当成新回归，也不要通过删测试/放宽断言变绿。
- 不要把整幅画面外框、桌面最大矩形当成页面；不要在无框时回退 `.fullImage`。
- 不要把“实时精确单页四边形”重新变成拍摄门槛；左/右页是输出意图。
- 不要在未做真机 A/B 前改默认 `captureMode` 或宣称达到 WPS 跟手性。
- 不要让云端/LLM 进入扫描像素链路；分割/去畸变模型只能输出 mask/几何。
- 不要提交 `docs/media/screenrecord/` 大录像；保留 `build/` 证据，只提交代码/文档/测试。

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
| 代码规模 | 141 个主工程 Swift 文件 / 69 个测试文件；主工程约 25.5k 行 |
| 质量现状 | **547 total；10 条既有债（flaky 5~10 条），无新增失败**（Swift Testing；2026-10-29 实测；测试总数基线只增不减） |
| 当前主线 | P0.3 取景包络跟踪（`docs/22`）；CF-T002~T011a 已交付，真机验收记录待补 |

### 1.1 SDD 周期一览（截至 2026-10-21 的 15 个周期；P0.3 见 §0）

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
| 14 | `guided-capture`（**Phase 0~2 已交付**，真机验收待做） | 引导取景：用户框定右页 + 画布真值 + 取证/回放 + Review 拆分确认 | **Phase 0**：trace 环形缓冲 / 全候选落盘（全部 viable + top 8）/ 诊断包导出 / 回放基线；**Phase 1**：引导模式与意图、屏幕↔照片逆映射、引导框 UI（可拖）、自动对位 + 松手吸附、引导拍摄分支（成片 = 框）、框生命周期；**Phase 2**：拆分从「静默应用」改为「提案 + 用户确认 + 可撤销」；自动路径零改动 | 417→436（真机计数待 T030） | `spec/guided-capture/`（历史；先读 `docs/15`） |
| 15 | `word-fidelity`（**Phase 0 已交付**，Phase 1 迭代中） | Word 导出保真度：图片版档 + 裁切不丢页 + 保真度闸门 | 静帧页面判定（认不出页面就不裁）、图片版导出（整页图铺页，零文本框/零 mask）、默认档翻转为**高保真=图片版**（旧「高保真」=可编辑版面还原，rawValue 迁移到 `layoutEditable`）、`make word-fidelity` 闸门（SSIM 门限 0.90，实测 0.914/0.919）；**可编辑档 0.785 未达标 → 迭代见 [`docs/17`](17-editable-tier-fidelity-iteration.md)** | 444→449 | `spec/word-fidelity/`（评估见 [`docs/16`](16-word-export-fidelity.md)） |

> 基线说明：表中“377→386”等是各周期交付时的计数；**2026-10-29 当前总基线是
> 547 total；10 条既有债（5~10 条 flaky 命中，见 §0.1 / §4.2）**。
> 表中 449 是 2026-10-21 的历史快照，不要拿它当当前门禁。

---

## 2. 当前卡点（诚实清单，按优先级）

> **2026-10-28 当前结论**：取景主线已从“实时单页锁定 + sticky/smoother 调参”转为
> **整摊包络跟踪 + 拍后输出意图**。当前最大风险不是单测，而是**真机视频 5/7 尚未验收**；
> 在完成验收前，不要继续围绕 `containmentPenalty`、`epsilon`、`alpha` 或
> `CandidateSticky` 阈值微调。
>
> 当前真正的短板：
> 1. **真机验收空白**：CF-T004/CF-T005 的目标显示与拍后拆分只在合成测试/模拟器验证；
> 2. **跟踪跟手性**：CF-T003 第一版只有低频观测 + hold/平滑，缺少光流/单应性传播；
> 3. **抓拍一致性**：CF-T006 的置信度视觉、按下冻结、自动/手动快门仍未收口；
> 4. **测试债**：全量 10 个既有失败（见 §4.2），会掩盖真实回归；
> 5. **历史暂停项**：PP-T032、多条件样张、flaky 清理，用户已要求暂停。
>
> 下面 §2.1~§2.5 是 2026-10-21 前后的卡点记录，保留作**历史背景**：其中的
> frame-truth / Case A/B 修复仍在代码里，但当前主线已由 `docs/22` 接管。不要因为
> 旧文档写着“P0 先做引导框”就重新切回老路线；需要背景时再读。

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
> **修复（frame-truth，交付时 386 全绿；该周期交付基线 449，历史快照）**：`viablePool` 单一真源；页面先验门控 0.25；
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

> **2026-10-29 更新**：视频 11/12 证明还有一个更底层的原因——取景域只有
> 4:3 帧宽的 61.6%（见 §0.1 CF-T010）。先修取景域，再判断 Case B 的粘滞是否仍需调；
> 不要在 T010 之前继续按本节的 sticky/smoother 路线调参。

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

## 3. 路线图（按优先级，2026-10-28）

> 旧的 2026-10-21 路线（引导框 MVP / frame-truth 真机会话）已完成代码交付，
> 当前执行顺序以本节 + `docs/22` + `TODO.md` 为准。**先真机验收，再调参**。

| 阶段 | 内容 | 完成标准 / 前置 |
|---|---|---|
| **P0 · CF-T007 真机与 WPS 验收** | 视频 5/7 复核 + 20 彩页 + 20 黑白 + 10 A4 + 10 曲面/折页；WPS 视频 6 同场景对照 | 框可见率 ≥95%、无框连续 ≤150ms、右/左页输出正确率 ≥90%、禁止内容入片率 0；按 `docs/22` §六记录；WPS 0.906224 不回退 |
| **P0 · CF-T006 UI/快门** | 置信度态、锁定后自动/手动快门、按下瞬间冻结包络、引导/手动框兜底 | 视频 5/7 手动拍成片 = 快门瞬间呈现框；无效框不承诺可拍 |
| **P0 · CF-T008 跟踪跟手性** | 在现有 tracker 上加光流/单应性传播（每帧）+ 低频观测融合；离线回放视频 5/6 调参 | 单帧框跳变 p95 ≤短边 0.5%；锁定延迟 ≤0.6s；不引入云端/LLM |
| **P0 · CF-T009 观测增强** | 先测传统 Vision 失败率；不足再评估端侧分割 mask | 只输出 mask/几何；离线/ANE；不做生成式像素 |
| **P1 · 恢复暂停项** | PP-T032 全流程、多条件样张回归、flaky 清理；Word 可编辑档 0.785→目标、L1 真机取证 | 用户明确解除暂停后再开工；先修测试治理，不改业务断言 |
| **P1 · 工程债** | Library N+1、Review 全量内存驻留、SwiftData 零测试/迁移、Review tmp 泄漏；iOS 18~25 表格降级阶梯 | 与 P0 验收解耦，可并行但不要改 capture 契约 |
| **P2 · 云通路** | TextIn 低置信 block 修复；手写/勾选识别 | **独立周期评审**；纯离线是铁律，云通路须单独立项（隐私披露 + 用户确认 UX） |

### 3.1 关于 SDD 流程

- **P0.3 已正式纳入 SDD**：`spec/capture-envelope-tracking/`（spec / plan / tasks /
  device-acceptance 四件套），`spec/feature.json` 已指向它。
- 详细方案与历史证据仍在 [`docs/22`](22-capture-envelope-tracking.md)；任务勾选在
  [`TODO.md`](../TODO.md) 与 `spec/capture-envelope-tracking/tasks.md`。
- 下一任接手时先读 `spec/capture-envelope-tracking/device-acceptance.md`，按视频 5/7
  验收，再进入 CF-T008（光流）等后续任务。


---

## 4. AI 工程师上手路径

### 4.1 读什么（按序）

1. [`AGENTS.md`](../AGENTS.md) —— 定位 + 索引 + 铁律（冷启动第一篇）
2. 本文 —— 全貌 / 当前主线 / 卡点 / 路线图
3. [`22 取景包络跟踪`](22-capture-envelope-tracking.md) —— **当前主线事实源**：包络优先、CF-T001~T007、验收指标
4. [`TODO.md`](../TODO.md) —— 当前任务勾选、暂停项、已知测试债
5. [`09 接手手册`](09-project-handbook.md) —— 架构原理 + 卡点史（§4 契约、§6 卡点清单最常被引用；注意它是历史快照）
6. [`00 接手指南`](00-getting-started.md) —— 实操：目录地图 / 怎么测
7. 动 **capture 侧**前：`spec/guided-capture/`（历史引导框）+ `spec/frame-truth/`（框真相契约）+ [09 §4.2](09-project-handbook.md)（WYSIWYG 裁切 / overlay 屏幕点契约）
8. 动 **reconstruct 侧**前：`spec/wps-parity-layout/spec.md` + [09 §4.5](09-project-handbook.md)（版面对标契约）+ [`06`](06-document-reconstruction.md)
9. 需要历史背景时再读 [`15`](15-capture-recovery-assessment.md) / [`14`](14-project-summary-and-roadmap.md)；不要按它们的时间线继续调旧的 sticky/smoother。

### 4.2 跑什么

```bash
make doctor    # 环境自检（Xcode / 模拟器 / Busy 提示）
make test      # 全量单测 + 自动 xcresulttool 计数
make test-only T=ReviewSplitProposalTests   # 局部单测（当前 CF-T005）
make smoke     # 模拟器装机（build + install + launch + 存活检查）
make device-build   # 真机目标编译（generic/platform=iOS，免签名）
```

- **当前计数**：`total=547 passed=541 failed=5 expectedFailures=1`（本次）。既有测试债 10 条，本次命中 5 条；
  既有债务（Golden 4 / WordFidelity 1 / Review preview 4 / ReviewSplit 1），
  不是本轮 CF 改动引入；新增 CF 用例全绿。
- **默认 destination**：`iPhone 18 Pro` / iOS 27.0（见 `Makefile` 顶部）。若本机
  只有其他 runtime，用 `make test DEST_SIM='platform=iOS Simulator,name=...,OS=...'`
  覆盖，不要改 Makefile 默认值。
- 环境坑已固化进 Makefile：`DEVELOPER_DIR` 默认注入；`OTHER_SWIFT_FLAGS="-disable-sandbox"`
  必加（macOS 26.x 宏沙箱失效，不加所有宏报错）；模拟器 `Busy` 不是代码问题，
  `xcrun simctl erase all` 后重跑。
- **计数陷阱**：known issue 用例日志是 `recorded an expected failure`，不是 `passed`——
  按 `passed` 搜日志会少算 1 条；以 `make test` 末尾 xcresulttool 计数为准。
- **不要用全量绿作为本轮完成标准**：先看新增/相关定向套件，再看全量计数是否仍为
  547 total；10 条既有债会 flaky 命中。若总数变化，更新 `Makefile` 基线并在提交说明写清。

### 4.3 铁律（违反任何一条都会破坏既有资产）

1. **`Services/ServiceProtocols.swift` 协议签名不变**——全部依赖经协议注入，签名一动全部替身测试连锁崩。
2. **既有测试断言零修改**——总数基线 547 只增不减；方向性翻转属唯一例外，须在周期 tasks.md 逐条记录（先例：`ReconstructTierTests` 默认档翻转）。
3. **纯离线**——不引任何网络依赖、不加云调用；云通路是独立路线图，须单独立项评审。
4. **模拟器条码恒 0 是假绿**——`VNDetectBarcodesRequest` 模拟器永远返回空；条码断言只能靠 `BarcodeDetecting` 协议注入替身 + 真机验收。
5. **`withKnownIssue` ≠ failed ≠ passed**——见 4.2 计数陷阱。
6. **动 capture / reconstruct 侧前先读对应 spec**——每轮修复都钉在 `spec/<周期>/spec.md`（FR/SC 编号）；跳过 spec 直接改代码是历次回归的根因。
7. **取景不在无框时回退 `.fullImage`**——屏幕外框/桌面最大矩形不是页面；无当前帧包络时保持搜索态并禁用快门（CF-T002/CF-T004）。
8. **成片 = 快门瞬间呈现框**——frame-truth 契约；拍后 refine 不得静默扩回用户没看见的内容。

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

### 5.1 spec/ 周期工件（17 个周期；P0.3 已纳入）

| 周期 | 四件套位置 | 一句话 |
|---|---|---|
| **capture-envelope-tracking** | `spec/capture-envelope-tracking/` | **当前 P0.3 主线**：包络优先 + 拍后输出意图（CF-T001~T009；真机验收单 = `device-acceptance.md`） |
| scan-edge-accuracy | `spec/scan-edge-accuracy/` | 取景框/成片比书小 → 边缘吸附 + 择优修正 |
| layout-restore | `spec/layout-restore/` | 版面还原 v1 |
| layout-engine | `spec/layout-engine/` | 预览 = Word 布局引擎 |
| scan-fidelity | `spec/scan-fidelity/` | 扫描保真六缺陷（FR-001~012） |
| live-edge-crop | `spec/live-edge-crop/` | 三级检测兜底 + 实线整框 |
| overlay-frame-visibility | `spec/overlay-frame-visibility/` | 屏幕点契约 + 6 帧确认窗 |
| wysiwyg-crop | `spec/wysiwyg-crop/` | 裁切门禁 + 候选粘滞（**§0 = 日志取证步骤，下轮必读**） |
| wps-parity-layout | `spec/wps-parity-layout/` | 默认导出对标 WPS（**§A = L1 取证步骤**） |
| agent-handover | `spec/agent-handover/` | 复测落盘（`device-retest-20260926.md`）+ Agent 化 |
| case-b-sticky-v2 | `spec/case-b-sticky-v2/` | Case B 池交替根因定案 + 粘滞 v2 hold-through-miss（历史） |
| folded-page-capture | `spec/folded-page-capture/` | 第一轮：默认不自动拍 / 检测放宽 / 粘滞 0.70·5 / 双向吸附（历史，验收单已被 frame-truth 取代） |
| frame-truth | `spec/frame-truth/` | 第二轮框真相：候选供给 / 锚点治理 / s=0 守卫 / 冻结直裁 / 无效框承诺（历史契约仍有效） |
| scan-enhance | `spec/scan-enhance/` | 拍后重检 / 书脊与左折条拆分 / document 增强（T006 真机验收待做） |
| guided-capture | `spec/guided-capture/` | 引导框 MVP + 画布真值 + trace/replay + Review 拆分确认（Phase 0~2 代码已交付；真机 A/B 未做，P0.3 后按需重启） |
| page-preprocess | `spec/page-preprocess/` | 页面边界/页外裁切/折痕光照；P0.1/P1 基础版已交付，多条件/PP-T032 暂停 |
| word-fidelity | `spec/word-fidelity/` | 图片版 Word + 保真度闸门（Phase 0 已交付；可编辑档迭代暂停） |

> **P0.3 事实源**：`spec/capture-envelope-tracking/`（验收/任务）+ `docs/22`（方案与
> 指标）+ `TODO.md`（勾选状态）。`spec/feature.json` 已指向该目录；不要再到
> `spec/page-preprocess/` 里找取景任务。

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
| [14](14-project-summary-and-roadmap.md) | **项目全面总结 + 完整优化路线图**（2026-10-21 历史快照；当前看 22） |
| [15](15-capture-recovery-assessment.md) | **取景卡点复盘与引导框恢复计划**（2026-10-21 历史快照；P0.3 前身） |
| [16](16-word-export-fidelity.md) | Word 导出保真度：图片版档 / 裁切不丢页 / 保真度闸门 |
| [17](17-editable-tier-fidelity-iteration.md) | 可编辑 Word 档保真度迭代（0.785 未达标，暂停） |
| [18](18-h2oc-word-fidelity-run.md) | H2OC 可编辑档实验记录 |
| [19](19-page-preprocess-plan.md) | 页面预处理计划（边界/页外裁切/折痕光照；部分暂停） |
| [20](20-border-crop-convergence.md) | 边框/背景单次收敛（P0.1） |
| [21](21-capture-ux-stability.md) | 取景候选粘滞/显示去抖/快门快照（P0.2 历史） |
| [22](22-capture-envelope-tracking.md) | **当前主线事实源**：包络跟踪 + 拍后拆页；CF-T001~T011a、验收指标、WPS 证据 |

### 5.3 提交锚点

- **当前 `7a546b4`**「修复拍照时实线取景框不准，频繁跳动问题」——CF-T005b/c/d +
  CF-T010 取景域 + CF-T011a 近距单页；测试 547 total。
- **`b7ea065`**「feat(capture): land output target and intent split」——
  CF-T004 目标页显示 + CF-T005 `outputIntent`/高分辨率拍后拆分；测试 518/507/1/10。
- `eddb04d`「feat(capture): add envelope observation and stable tracker」——CF-T002/CF-T003
  第一版（包络观测 + tracker）。
- `f4aaba7`「docs(capture): evaluate WPS framing and plan envelope tracking」——
  `docs/22` 方案与视频 5 证据。
- `3a998eb`「feat(capture): stabilize page intent and shutter framing」——P0.2 的页面意图/快门收口。
- **历史 C1 `c5a60ac`**「WYSIWYG 裁剪与 WPS 对标两周期改动」——wysiwyg-crop +
  wps-parity-layout 两周期产物入库点（46 文件）。
- 更早历史：`eb5a08b` 取景检测与整框渲染优化 · `c7acd3e` 优化项目 · `ed8d556` 初始版本。
