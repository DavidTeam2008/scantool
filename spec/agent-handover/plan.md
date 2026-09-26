# Implementation Plan: AI 工程师交接与项目 Agent 化（agent-handover）

**Input**: Feature specification from `/Users/tanwei/Documents/code/ios/scantool/spec/agent-handover/spec.md`

## Summary

纯文档/脚本/配置周期，**零应用代码改动**（`Zhixia/`、`ZhixiaTests/` 不触碰，357 测试基线不变）。四类工件：①真机复测结论落盘（周期工件 + wysiwyg-crop 验收文档追加 + handbook 卡点同步）；②两段 checkpoint commit（代码基线 / 本周期产物）；③`AGENTS.md` + `Makefile`（Agent 冷启动入口与命令封装）；④过期文档全量同步 + 交接文档 `docs/12-handover.md`（全貌/卡点/路线图/上手路径）。

## Technical Context

**Language/Version**: 项目本体 Swift 6 / iOS 18+（本周期不触碰）；本周期产物 = Markdown + Makefile + git 操作
**Primary Dependencies**: xcodebuild、xcrun simctl、xcrun xcresulttool（全部被 Makefile 封装）
**State Management**: N/A（无运行时状态）
**Storage**: git（两段 commit）；无新增持久化
**Testing**: 既有 Swift Testing 357 用例（基线不变，作为「周期未破坏代码」的回归证据）；本周期自身验证 = 脚本实跑 + 文档数字 grep 校验 + git 状态检查
**Target Platform**: macOS 开发机（Makefile）；iOS Simulator iPhone 17 Pro（测试命令）
**Project Type**: 既有 iOS mobile-app 的工程文档/工具改造周期
**Performance Goals**: N/A
**Constraints**: 不改应用源码与既有测试；纯离线；`DEVELOPER_DIR` 为机器特定路径，Makefile 内用 `?=` 默认值 + 可覆盖；`make` 目标不自动执行破坏性操作（如 `simctl erase all` 只提示不执行）
**Scale/Scope**: 新建 4 个文件、修改 9 个文档、2 个 commit

## Project Structure

### Documentation (this feature)

```text
/Users/tanwei/Documents/code/ios/scantool/spec/agent-handover/
├── spec.md                              # 需求（已批准）
├── plan.md                              # 本文件
├── tasks.md                             # Phase 3 产出
└── device-retest-20260926.md            # T1 产出：复测结论记录（逐字+归因+对照）
```

### Source Code (repository root)

```text
（新建）
AGENTS.md                                # Agent 冷启动入口（薄，≤150 行）
Makefile                                 # 命令封装（test/test-only/smoke/device-build/doctor/help）
docs/12-handover.md                      # 交接文档（四要素单入口）

（修改——文档同步）
README.md                                # 132→357、能力现状补两周期、后续方向表刷新
docs/00-getting-started.md               # §7 怎么测：加 Makefile 用法；过期陈述修正
docs/02-architecture.md                  # §2 工程结构对新文件对齐（FlowParagraphSplitter/InkTextReconciler/InkRegionProvider/OnDeviceTableCluster 休眠）
docs/05-roadmap.md                       # 更新日期、现状总览、周期史补 6 周期、真机清单加 Case A/B 复测行
docs/06-document-reconstruction.md       # §12 已知问题：wrong bus! 定案、段落收敛、流式默认档
docs/09-project-handbook.md              # §0 速览对齐、§5 补档位 UI/哨兵、§6 卡点加复测结论、§7 路线图重排
docs/10-project-summary.md               # §4 SDD 周期史补全
docs/11-wps-parity-research.md           # 追加「周期 1 实施后真机复测结论」闭环段
spec/wysiwyg-crop/device-acceptance.md   # 结果表追加复测行（不改历史 ✗ 记录）
```

**Structure Decision**: 遵循既有仓库结构（`docs/` 编号体系 + `spec/` 周期目录 + 根 README），不引入新目录层级。模板中的 HarmonyOS/ArkTS MVVM 结构指引不适用于本既有 iOS 项目的文档周期，按 Template Mismatch 规则做最小适配：沿用模板节结构，Source Code 节列本周期实际新建/修改文件。

## Complexity Tracking

（无违规项——本周期不新增代码结构，仅文档与构建脚本）

## Research & Decisions

### D1 命令封装形态：Makefile（而非 scripts/ 目录）

- **Decision**: 单文件 `Makefile`，6 个 target（`help`/`test`/`test-only`/`smoke`/`device-build`/`doctor`）
- **Rationale**: 零目录开销；target 列表即自文档（`make help`）；主流 AI coding agent 对 make 惯用；本项目全部环境坑（`DEVELOPER_DIR` 必须导出、`OTHER_SWIFT_FLAGS="-disable-sandbox"` 必加、模拟器 Busy）可一次性固化
- **Alternatives considered**: `scripts/*.sh` 目录（多文件维护成本高于收益，且 Agent 需先发现再阅读）；仅文档写命令（用户已在澄清阶段否决）
- **细节决策**: `DEVELOPER_DIR ?= /Volumes/DevDisk/Applications/Xcode.app/Contents/Developer`（默认可覆盖，异机环境改一行或环境变量注入）；Busy 不自动 erase（破坏性操作只提示解决命令，agent 不应默默擦模拟器）；`make test` 结束自动跑 xcresulttool 输出计数（省一步）

### D2 Commit 策略：两段式

- **Decision**: C1「代码基线」= wysiwyg-crop + wps-parity-layout 两周期全部产物（`Zhixia/`、`ZhixiaTests/`、两周期 `spec/` 目录、`docs/09` 既有更新、`docs/11`、fixtures、样张 docx）；C2「本周期产物」= `AGENTS.md`、`Makefile`、`docs/12-handover.md`、全量文档同步、`spec/agent-handover/`、`spec/feature.json`。交接文档引用 C1 hash 作为代码基线
- **Rationale**: 分文件暂存可行（两周期产物文件清单明确、`feature.json` 归 C2）；代码基线与交接产物分离，新工程师可独立 revert 交接层而不动代码
- **Alternatives considered**: 按 cycle 拆 3 个 commit（共享文件需 hunk 级拆分，脆弱）；单 commit 打包全部（基线与交接层耦合）
- **约束**: commit message 风格实施时以 `git log --oneline` 既有风格为准；提交前检查 `.gitignore` 覆盖（`.DS_Store` 已被忽略，复核即可）

### D3 AGENTS.md 结构：薄入口原则（≤150 行）

- **Decision**: 六节——①项目一句话 + 关键事实表（bundle id / 测试基线 357 / 纯离线 / iOS 18+ Swift 6）②必读顺序（`docs/12-handover.md` → `docs/09` → `docs/00`）③命令速查（make 6 target + 输出解读：`withKnownIssue` 计数陷阱）④铁律清单 ⑤SDD 工作流说明（`spec/` 目录 + `feature.json` + 五阶段）⑥当前状态指针（复测结论与卡点位置）
- **Rationale**: Agent 上下文有限，入口文档只做「定位 + 索引 + 约束」，事实细节全部下钻到 docs，避免双真源漂移
- **Alternatives considered**: 大而全 AGENTS.md（与 handbook 重复，必然漂移）；CLAUDE.md 双文件（AGENTS.md 已是通用标准，双份维护成本）
- **铁律清单内容**（从既有周期教训提炼）: `ServiceProtocols` 协议签名不变；既有测试断言零修改（例外须在 tasks.md 记录）；纯离线不接云；模拟器 `VNDetectBarcodesRequest` 恒 0 假绿；`withKnownIssue` 日志是 expected failure 不是 passed；capture 侧与 reconstruct 侧改动前先读对应 spec 周期工件

### D4 交接文档 docs/12-handover.md：四要素 + 证据索引

- **Decision**: 五节——①项目全貌（定位/分层一句话/质量现状/8 周期一览表）②当前卡点（P0 Case A R4、P0 Case B R5、P1 WPS 对标剩余差距、P1 L1 真机通路疑案、P2 几何兜底老系统与工程债——每项：现象/根因/证据链接/复测状态/建议方向）③路线图（从卡点导出按优先级排序：P0 裁剪质量 → P1 真机取证与对标收尾 → P2 老系统兜底与工程债 → P3 云通路）④AI 工程师上手路径（读什么/跑什么命令/改什么前看什么铁律/怎么开 SDD 周期）⑤证据索引（spec/ 周期表 + docs 索引）
- **Rationale**: spec US5 的四要素直接映射为节结构；「每项卡点 ≤2 跳下钻到证据」要求每条卡点附 `spec/` 工件与验收文档链接
- **Alternatives considered**: 多文件 handover/ 目录（用户已在澄清阶段选择单入口）

### D5 文档同步：逐篇漂移清单 + grep 一致性校验

- **Decision**: 已知漂移清单驱动（见 Project Structure 修改文件树的逐篇注释），同步后用 grep 校验关键数字（测试数 357、测试文件数、周期数）与实测一致；文档间矛盾以代码/测试实测为准
- **Rationale**: 盲改会漏；以已核实的漂移点（README 132、05-roadmap 停在 2026-09-12、8 周期未入册）为锚逐篇审计
- **Alternatives considered**: 只改 README 与 handbook（05/06/10/11 同样过期，会残留矛盾陈述）

### D6 复测结论工件：device-retest-20260926.md

- **Decision**: `spec/agent-handover/device-retest-20260926.md`——①逐字原文（用户三条反馈原文照录）②测试环境（新安装包 = 当前工作区构建，含两周期全部改动）③归因映射表（Case A→R4 折起部分修复未达效；Case B→R5 双候选振荡修复未达效 + 手动拍成片含左页大半；总体→WPS 对标未达）④与上轮验收记录对照（同因复发，非新问题）⑤定性结论与去向（进入交接文档卡点 P0、路线图 P0）
- **Rationale**: 失败也是资产：逐字保留用户观察（含错别字），解释层与原文分离
- **同步点**: `spec/wysiwyg-crop/device-acceptance.md` 结果表**追加**复测行（标注日期与「新包复测仍未修复」，不改历史 ✗）；`docs/09` §6 卡点同步；`docs/05` 真机清单同步

### D7 验证设计：build-only

- **Decision**: 验证内容 = ①`make test` 实跑全绿 357 = 356 + 1 + 0（证明脚本可用且文档周期未破坏代码）②文档数字一致性 grep 校验（文档中的测试数与 `@Test` 实测计数一致）③git 状态检查（C1/C2 落盘、工作区干净、交接文档引用的 hash 存在）④交接文档四要素结构检查（每节非空、卡点/路线图/证据链接可解析）
- **Rationale**: 纯文档周期无 UI 可验；脚本必须实跑才算交付
- **UI 验证**: 不适用（Phase 3 Choice Gate 中选 build-only）

## Data Model

本周期无运行时数据模型。工件与内容契约：

| 工件 | 关键内容 | 一致性要求 |
|---|---|---|
| `spec/agent-handover/device-retest-20260926.md` | 逐字原文/环境/归因/对照/去向 | 与 wysiwyg-crop 验收文档、09 §6 三处互链一致 |
| `AGENTS.md` | 定位/必读顺序/命令/铁律/SDD/状态指针 | ≤150 行；全部相对链接有效；测试数与实测一致 |
| `Makefile` | 6 target | 每个 target 实跑验证；默认 DEVELOPER_DIR 可覆盖 |
| `docs/12-handover.md` | 四要素 + 证据索引 | 关键数字与实测一致；卡点 ≤2 跳下钻 |
| 9 个同步文档 | 逐篇漂移修正 | grep 校验数字一致；无相互矛盾陈述 |

## Contracts & Interfaces

### Makefile target 契约

| Target | 参数 | 行为 | 成功判据 |
|---|---|---|---|
| `make help` | 无 | 列出全部 target 与一句话说明 | 输出 6 行目标清单 |
| `make test` | 无 | DEVELOPER_DIR 默认注入 + `-disable-sandbox` + iPhone 17 Pro 全量测试 + xcresulttool 计数 | 357 = 356 passed + 1 expected failure + 0 failed |
| `make test-only T=<类名>` | `T` | 同 `test` + `-only-testing:ZhixiaTests/<T>` | 指定类全绿并输出计数 |
| `make smoke` | 无 | build + 模拟器 boot/install/launch + 进程存活检查 | launch 返回 pid 且存活 |
| `make device-build` | 无 | `-destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |
| `make doctor` | 无 | 环境自检：Xcode 版本 / DEVELOPER_DIR 生效 / iPhone 17 Pro 模拟器存在 / Busy 提示（只提示 `xcrun simctl erase all`，不自动执行） | 自检清单全绿输出 |

### 文档内容契约

- **AGENTS.md**: 任何主流 AI coding agent 冷启动后，仅凭此文件 + `docs/12-handover.md` 能在单会话内跑通 `make test` 并报告正确计数（SC-001）
- **docs/12-handover.md**: 单独阅读可回答四问题（项目是什么/卡在哪/下一步/从哪开始）；每条卡点附 `spec/` 证据路径
- **README.md**: 与 `docs/09` §0 数字一致；「能力现状」含两周期新事实；「当前最大卡点」含 Case A/B 复测结论
