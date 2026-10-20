# 12 交接文档（单入口）

> 面向**接手的 AI 工程师 / 新同事**：这一篇是全貌入口——项目是什么、质量现状、卡在哪、
> 下一步往哪走、上手怎么走。每项都可下钻到证据（spec/ 周期工件与 docs/ 专题）。
> AI agent 请从 [`AGENTS.md`](../AGENTS.md) 进入（铁律与命令速查）；人读细节下钻
> [`09 接手手册`](09-project-handbook.md)。
>
> 更新：2026-10-17 · 代码基线：C1 `c5a60ac`「WYSIWYG 裁剪与 WPS 对标两周期改动」
> （wysiwyg-crop + wps-parity-layout 两周期产物入库点）+ case-b-sticky-v2 周期
> 改动（§2.2 修复，待入库）

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
| 代码规模 | 148 个 Swift 文件（主工程 107 / 测试 41）/ 主工程约 14.5k 行 |
| 质量现状 | **368 用例 = 367 passed + 1 expected failure + 0 failed**（Swift Testing，39 个含用例文件 + 2 个纯 fixture；基线只增不减） |

### 1.1 SDD 周期一览（9 个已交付 + 1 个进行中）

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
| 10 | `case-b-sticky-v2`（进行中） | Case B 粘滞 v2 hold-through-miss | 池交替根因代码级定案、`CandidateSticky` v2 参数门控、`stickyHold`/`stickyEscape` 遥测补缺、存在性交替单测 ×11 | 357→368 | `spec/case-b-sticky-v2/`（真机复测待做） |

---

## 2. 当前卡点（诚实清单，按优先级）

### 2.1 🔴 P0 · Case A：折页书成片仍含折起部分（R4 修复未达效）

- **现象**：折页书翻中间、左侧折起拍右页，成片包含折起部分（2026-09-26 复测用户逐字：
  「case A，还是会有折起部分」）。
- **根因**：**未定案**。两个假设：**H1 显示侧**——呈现框本身锁定了含折起的整书外轮廓，
  门禁按契约工作、错在锁定对象；**H2 门禁侧**——快门静帧重检误纳 / 路径未命中。
  R4 修复（裁切门禁「呈现框 = 裁切基准」，IoU ≥ 0.70 才允许静帧精修胜出）在单测级
  全绿，但真机验收标准下未达效。
- **证据**：`spec/wysiwyg-crop/spec.md`（FR/SC 定义）· `spec/agent-handover/device-retest-20260926.md`
  （复测逐字记录与归因）· [09 §6.11/§6.13](09-project-handbook.md)。
- **复测状态**：2026-09-26 新包真机复测 ✗（与 2026-09-21 验收 ✗ 同因复发）；
  **`cropGate` 日志从未取得**——两轮修复都在无定案状态下动刀，这是共同短板。
- **建议方向**：真机实时抓 `cropGate` 日志定案 H1/H2（步骤：
  `spec/wysiwyg-crop/device-acceptance.md` §0）；若 H1 成立 → 修检测候选择优/锁定策略
  （门禁契约不动）；若 H2 成立 → 修门禁静帧纳入条件。**取证前不要再动刀。**

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
- **复测状态**：代码与单测交付（2026-10-17）；**真机复测待做**——按
  `spec/case-b-sticky-v2/device-acceptance.md`：≤5s 稳定不跳可锁定 / 手动拍
  成片=呈现框 / `stickyHold`+`cropGate` 日志归档，同会话顺带 `reconstructPath`
  （§2.4 L1 取证）。

### 2.3 🟠 P1 · WPS 对标剩余差距（总体观感未达）

- **现象**：复测用户逐字：「整体上感觉跟wps的扫描还是有差距」。
- **拆解**：**还原链已达标**（金标准级：流式档默认 / 零假表 / "wrong bus!" 未丢 /
  段落 32∈42±30% / 漫画条内联，`GoldenWorksheetEndToEndTests` ×10 真实 Vision 链路验证）；
  差距主缺口在**取景拍照环节**（= §2.1/§2.2）与 **L1 通路未定案**（= §2.4）。
- **证据**：[11 §7 周期 1 实施后真机复测](11-wps-parity-research.md)（W1~W6 交付核对表）。
- **复测状态**：还原侧金标准全绿、真机验收待做；取景侧见 §2.1/§2.2。
- **建议方向**：取景侧范式决策——调研报告已给出「常驻框范式」（WPS 式：框常驻 +
  用户对位 + 边缘吸附，结构性绕开候选振荡）作为周期 2（wps-parity-capture）的立项方向，
  但**先完成 §2.1/§2.2 的日志取证**再评审取舍（7 个周期范式内修补真机仍败 vs 切范式的迁移成本）。

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

| 阶段 | 内容 | 前置 |
|---|---|---|
| **P0 裁剪质量** | Case B：✅ 池交替代码级定案 + 粘滞 v2 已交付（case-b-sticky-v2，368 全绿）→ **真机复测**（`spec/case-b-sticky-v2/device-acceptance.md`，一趟抄齐 `stickyHold`/`stickyEscape`/`cropGate`）；Case A：真机 `cropGate` 取证定案 H1/H2（可与 Case B 复测同会话）→ 若 H1 修候选择优/锁定策略（门禁契约不动）→ 真机复测 | Case B 修复已入库待复测；Case A 步骤 `spec/wysiwyg-crop/device-acceptance.md` §0 |
| **P1 真机取证与对标收尾** | L1 通路取证（`reconstructPath`，可与 P0 同一会话）；iOS 26 表格真机验证；阴影场景 OCR 预处理档验证；条码真机验证（模拟器恒 0）；取证后评审「常驻框范式」周期 2（wps-parity-capture，需 WPS 取景录屏） | P0 日志会话顺带完成取证 |
| **P2 老系统兜底与工程债** | 表格降级阶梯（anchor → 通用数字列）；列/行切分改投影找 gutter；导出层表格样式（`w:tblPr`/表头加粗/数值右对齐）与 `gridSpan`/`vMerge`；Library/Review/SwiftData 工程债 | P0/P1 收尾后 |
| **P3 云通路** | 接通 TextIn（低置信 block 走 `ReconstructRepairing`，禁止整页 LLM 重打表数字）；手写 / 勾选识别 | **独立周期评审**——纯离线是铁律，云通路须单独立项（含隐私披露与用户确认 UX） |

---

## 4. AI 工程师上手路径

### 4.1 读什么（按序）

1. [`AGENTS.md`](../AGENTS.md) —— 定位 + 索引 + 铁律（冷启动第一篇）
2. 本文 —— 全貌 / 卡点 / 路线图
3. [`09 接手手册`](09-project-handbook.md) —— 架构原理 + 卡点史（§4 契约、§6 卡点清单最常被引用）
4. [`00 接手指南`](00-getting-started.md) —— 实操：目录地图 / 怎么测
5. 动 **capture 侧**前：`spec/wysiwyg-crop/spec.md` + [09 §4.2](09-project-handbook.md)（WYSIWYG 裁切契约 / overlay 屏幕点契约）
6. 动 **reconstruct 侧**前：`spec/wps-parity-layout/spec.md` + [09 §4.5](09-project-handbook.md)（版面对标契约）+ [`06`](06-document-reconstruction.md)

### 4.2 跑什么

```bash
make doctor    # 环境自检（Xcode / 模拟器 / Busy 提示）
make test      # 全量单测 + 自动 xcresulttool 计数（基线：total=357 passed=356 failed=0 expectedFailures=1）
make test-only T=GoldenWorksheetEndToEndTests   # 局部单测
make smoke     # 装机冒烟（build + install + launch + 存活检查）
make device-build   # 真机目标编译（generic/platform=iOS，免签名）
```

- 环境坑已固化进 Makefile：`DEVELOPER_DIR` 默认注入；`OTHER_SWIFT_FLAGS="-disable-sandbox"`
  必加（macOS 26.x 宏沙箱失效，不加所有宏报错）；模拟器 `Busy` 不是代码问题，
  `xcrun simctl erase all` 后重跑。
- **计数陷阱**：known issue 用例日志是 `recorded an expected failure`，不是 `passed`——
  按 `passed` 搜日志会数出 356 误判丢 1 条；以 `make test` 末尾 xcresulttool 计数为准。

### 4.3 铁律（违反任何一条都会破坏既有资产）

1. **`Services/ServiceProtocols.swift` 协议签名不变**——全部依赖经协议注入，签名一动全部替身测试连锁崩。
2. **既有测试断言零修改**——基线 357 只增不减；方向性翻转属唯一例外，须在周期 tasks.md 逐条记录（先例：`ReconstructTierTests` 默认档翻转）。
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

### 5.1 spec/ 周期工件（9 个已交付周期 + 当前周期）

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
| case-b-sticky-v2 | `spec/case-b-sticky-v2/` | Case B 池交替根因定案 + 粘滞 v2 hold-through-miss（真机复测待做） |

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

### 5.3 提交锚点

- **C1 `c5a60ac`**「WYSIWYG 裁剪与 WPS 对标两周期改动」——wysiwyg-crop +
  wps-parity-layout 两周期产物入库点（46 文件），本文 §2 的卡点均对应此基线。
- **C2**（agent-handover 周期收尾提交）——复测记录 + AGENTS.md + Makefile + 文档同步 + 本文。
- 更早历史：`eb5a08b` 取景检测与整框渲染优化 · `c7acd3e` 优化项目 · `ed8d556` 初始版本。
