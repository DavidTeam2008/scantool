# AGENTS.md · 纸匣 Zhixia

> AI coding agent 冷启动入口。本文件只做「定位 + 索引 + 约束」，事实细节全部下钻到
> `docs/` 与 `spec/`——避免双真源漂移。人读版全貌见 `docs/12-handover.md`。

## 1. 项目是什么

**一句话**：把纸上的东西干净地收进 iPhone 的**纯离线**扫描工具——取景自动框边、透视
拉正、增强、OCR、版面还原、导出 PDF / Word；对标 WPS 扫描 / 全能扫描王的主体能力，
不做账号墙、不接云。

| 关键事实 | 值 |
|---|---|
| 语言 / 最低部署 | Swift 6 · iOS 18.0+（结构化识别用 iOS 26 `RecognizeDocumentsRequest`） |
| bundle id | `com.david.Zhixia` |
| 测试基线 | **456 = 455 passed + 1 expected failure + 0 failed**（`ZhixiaTests/`；iPhone 18 Pro / iOS 27；只增不减） |
| 网络依赖 | **零**（纯离线；TextIn 云解析是 stub，`parse` 直接 throw） |
| 架构 | App → Features(SwiftUI VM) → Domain(纯函数) → Services(actor 副作用)，依赖只向下 |
| 构建 | `Zhixia.xcodeproj`，Xcode 26.x，scheme `Zhixia`，PBXFileSystemSynchronizedRootGroup（新文件免改 pbxproj） |

## 2. 必读顺序（冷启动必读）

1. `docs/12-handover.md` —— 交接文档：全貌 / 当前卡点 / 路线图 / 上手路径（单入口）
2. `docs/09-project-handbook.md` —— 项目手册：架构、实现原理、卡点史（§4 契约、§6 卡点清单最常被引用）
3. `docs/00-getting-started.md` —— 实操细节
4. `docs/14-project-summary-and-roadmap.md` —— 全面复盘 + **完整优化路线图**（2026-10-21 最新）
5. `docs/15-capture-recovery-assessment.md` —— **取景卡点复核 + 引导框 10 天计划**（2026-10-21 新主线；与 `spec/guided-capture/` 配套）

改哪个模块前，先读对应专题：还原链 → `docs/06`/`07`/`08`；取景检测 → 对应 `spec/` 周期工件（见 §5）。

## 3. 命令速查（`Makefile`，DEVELOPER_DIR 默认值已内置、可覆盖）

| 命令 | 用途 |
|---|---|
| `make help` | 列出全部命令 |
| `make test` | 全量单测（iPhone 17 Pro 模拟器）+ 自动输出 xcresulttool 计数 |
| `make test-only T=<测试类名>` | 局部单测，例 `make test-only T=GoldenWorksheetEndToEndTests` |
| `make smoke` | 装机冒烟：模拟器 build + install + launch + 进程存活检查 |
| `make device-build` | 真机目标编译（`generic/platform=iOS`，免签名） |
| `make doctor` | 环境自检（Xcode / 模拟器 / Busy 提示） |

> **本机 destination**：`iPhone 17 Pro` 只有 iOS 26.4.1，未指定 OS 时可能被
> 解析到 27.0 并失败。T000 修好 `Makefile` 前用
> `make test DEST_SIM='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4.1'`。

> **MCP 工具**：本机已装 6 个 MCP server（mobilebuildmcp / xcode / agent-device / maestro /
> testflight / app-store-connect），分工、配置落点与使用铁律见
> [`docs/13-mcp-quickref.md`](docs/13-mcp-quickref.md)；其中 testflight /
> app-store-connect 待补 ASC 凭证。

**计数陷阱（必读）**：known issue 用例在 xcodebuild 日志里是 `recorded an expected
failure`，**不是** `passed`——按 `passed` 关键字搜日志会少算 1 条。以 `make test`
末尾自动打印的 xcresulttool 计数为准：`total=448 passed=447 failed=0
expectedFailures=1` 才是全绿。

**环境坑**（已固化进 Makefile，手工执行时别漏）：① `DEVELOPER_DIR` 必须指向本机
Xcode；② 必须加 `OTHER_SWIFT_FLAGS="-disable-sandbox"`（macOS 26.x 宏沙箱失效，
不加则所有宏报错）；③ 模拟器报 `Busy` 不是代码问题，`xcrun simctl erase all` 后重跑。

## 4. 铁律清单（违反任何一条都会破坏既有资产）

1. **`Services/ServiceProtocols.swift` 协议签名不变**——全部依赖经协议注入，签名一动
   全部替身测试连锁崩。
2. **既有测试断言零修改**——基线 449 只增不减；方向性翻转属唯一例外，须在周期
   tasks.md 逐条记录（先例：`ReconstructTierTests` 默认档翻转）。
3. **纯离线**——不引任何网络依赖、不加云调用；云通路是 P4 路线图，须独立周期评审。
4. **模拟器条码恒 0 是假绿**——`VNDetectBarcodesRequest` 在模拟器永远返回空，
   条码相关断言只能靠 `BarcodeDetecting` 协议注入替身 + 真机验收。
5. **`withKnownIssue` 日志陷阱**——expected failure ≠ failed ≠ passed（见 §3）。
6. **动 capture 侧 / reconstruct 侧前先读对应 spec**——每轮修复都钉在
   `spec/<周期>/spec.md`（FR/SC 编号）；跳过 spec 直接改代码是历次回归的根因。
   契约速查：WYSIWYG 裁切 → `docs/09` §4.2；版面对标 → `docs/09` §4.5。

## 5. SDD 工作流（本仓库的改动管理方式）

功能开发走 **spec-driven**：`spec/feature.json` 指向当前周期目录（如
`spec/agent-handover/`），周期内五阶段流水——

```
spec.md（需求+验收标准） → plan.md（技术决策 D1~Dn） → tasks.md（任务拆解）
  → 实施（逐任务勾选） → 验证（含 device-acceptance.md 真机清单）
```

既有周期（证据归档，改前必读对应目录）：`spec/layout-engine` · `spec/layout-restore`
· `spec/scan-fidelity` · `spec/scan-edge-accuracy` · `spec/live-edge-crop` ·
`spec/overlay-frame-visibility` · `spec/wysiwyg-crop` · `spec/wps-parity-layout` ·
`spec/agent-handover` · `spec/case-b-sticky-v2` · `spec/folded-page-capture` ·
`spec/frame-truth` · `spec/scan-enhance` · `spec/guided-capture` · **`spec/page-preprocess`（当前周期）**。
真机验收清单都在各周期 `device-acceptance.md`。

## 6. 当前状态指针（2026-10-26）

- **当前状态**：Case A（折页书）与 Case B（摊开书）的既有修复已交付
  （case-b-sticky-v2 + folded-page-capture + frame-truth 三周期；全量
  **449 = 448 passed + 1 expected failure + 0 failed**），真机验收仍待做
  （主清单 `spec/frame-truth/device-acceptance.md`；同会话合并 Case B 复测与
  `reconstructPath` L1 取证）。
- **2026-10-21 复核后新增主线**：`docs/15-capture-recovery-assessment.md` +
  `spec/guided-capture/`。结论：主场景缺“我要拍右页”的意图，继续调
  sticky/smoother 阈值不是优先项；先做引导框 MVP + 画布真值 + trace/replay。
  默认仍 `.auto`，引导模式经真机 A/B 后再决定是否翻转默认。
- **guided-capture 进度（2026-10-22）**：**Phase 0（T000~T004）+ Phase 1
  （T010~T016）+ Phase 2（T020~T023）代码已交付**（基线 417→436；模拟器走查
  通过：切引导 → 拖角 → 拍 → 切回自动；拆分语料 0 静默误裁 / 10-10 可修正 /
  10-10 u 误差 ≤2%）。**未做**：T005 真机 V1/V2/V3、真机 A/B（T030~T034）。
  **动 capture 侧前先读 `spec/guided-capture/plan.md` D1~D10**；引导路径与
  自动路径**互不影响**（自动路径本周期零改动）。
- **word-fidelity 周期（2026-10-22，已收尾）**：**Word 导出保真度**——用户实测
  「复杂页面的 Word 样式会乱」。评估见 [`docs/16`](docs/16-word-export-fidelity.md)，
  工件在 [`spec/word-fidelity/`](spec/word-fidelity/)。Phase 0 已交付：新增**图片版**
  导出档（整页图铺页，样式不可能乱）+ **静帧页面判定**（认不出页面就不裁，绝不裁到
  页面里的子框）+ **保真度闸门**（`make word-fidelity`：docx → 渲染 → SSIM ≥0.90，
  实测 0.914/0.919；可编辑的「版面还原」档对照 0.785 **未达标** → 迭代方案见
  [`docs/17`](docs/17-editable-tier-fidelity-iteration.md)（归因/口径分层/子目标 G1~G6/
  排期 R2~R5）。档位命名：**高保真 = 图片版**（默认），旧「高保真」= 可编辑版面还原
  （rawValue 迁移到 `layoutEditable`，老用户行为不变）。**真机收尾**：WPS 真实渲染
  0.906/0.907（docs/17 §八），真机表格 3×4→2×5 已修；背景字重影暂缓。
- **page-preprocess 周期（2026-10-25 起，当前周期）**：先做页面边界/页外裁切，
  再做折痕/光照与页边拉直；计划见 [`docs/19`](docs/19-page-preprocess-plan.md)，
  任务见 [`spec/page-preprocess/tasks.md`](spec/page-preprocess/tasks.md)、
  执行清单 [`TODO.md`](TODO.md)。**P0 本样张已闭环（2026-10-26）**：模拟器
  `IMG_7542` 亮折页条裁切 1752×2200；真机 iPhone 13 页级左缘内收 1% 后
  1554×2200，标题/页码/表格保留，最终结构表 5×2；WPS 基线仍 0.906224。
  下一步 P1 折痕/光照；像素级页外残留可视化仍待补。
- **WPS 参考录屏已评估（2026-10-21）**：49s 录屏显示手动快门 + 单实线自动跟随框 +
  拍后自动重裁/滤镜；框在右页/整页间切换，快门时也不紧。结论：我们的固定引导框
  是替代范式而非 WPS 同款；不照搬静默换框，WPS 式自动裁边/滤镜列为 `T040`/`T041`
  后续项。详见 `docs/15` §十一。
- **动刀前必须**：先读当周期 spec 四件套；取景/还原链修改前读
  `spec/guided-capture/plan.md`（D1~D10）与
  `spec/folded-page-capture/plan.md`、`spec/case-b-sticky-v2/plan.md`。
- **待定案疑案**：L1 真机通路（iOS 26.7 结构化识别疑似静默回退，模拟器不复现）——
  取证步骤 `spec/wps-parity-layout/device-acceptance.md` §A（已并入上述真机会话）。
- 路线图与优先级：`docs/12-handover.md` §3（以 `docs/15` 的执行顺序为准）。
