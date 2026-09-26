# Feature Specification: AI 工程师交接与项目 Agent 化（agent-handover）

**Created**: 2026-09-26  
**Status**: Draft  
**Input**: User description: "在新的安装包上测试结果如下：case A 还是含折起部分；case B 实线框一直再跳，手动拍了一张，左边很大部分都近图片；『取景拍照和还原版面生成的word，要对标wps扫描功能达到的效果』也没有达到 wps 的效果。1、把这个结论记录一下 2、把项目改造成 AI coding Agent 优化项目 3、把项目总结一下，更新文档，让文档和代码保持一致，写一个交接文档，让新的 AI 工程师能快速了解项目的全貌，目前的卡点，项目的路线图，所有的东西都要落盘，我要给 AI 工程师看"

## Overview

真机复测证明 wysiwyg-crop 两项修复（R4 折起部分、R5 框跳动）在验收标准下未达效，整体仍未达 WPS 扫描效果。本周期不改应用代码，做三件事：把复测结论与当前卡点诚实落盘；把项目改造成 AI coding Agent 可高效接手的形态（AGENTS.md + 命令脚本）；同步全部过期文档并交付一份面向新 AI 工程师的交接文档（全貌 / 卡点 / 路线图 / 上手路径）。

## User Scenarios & Testing *(mandatory)*

### User Story 1 - 真机复测结论落盘（Priority: P1）

**故事**：项目所有者在含两周期全部改动的新安装包上复测：Case A 成片仍含折起部分；Case B 实线框仍持续跳动，且手动拍成片左侧很大部分是左页图片；「取景拍照和还原版面生成的 Word 要对标 WPS 扫描效果」总体未达。这些结论必须逐字记录、归因映射到既有根因编号（R4/R5），并同步到验收文档与卡点清单——失败也是资产，不许丢失。

**Why this priority**: 复测数据是后续路线图的决策依据；不落盘就会在交接中失真。

**Independent Test**: 检查 spec/agent-handover/ 工件含逐字记录与归因；spec/wysiwyg-crop/device-acceptance.md 结果表追加了复测行且保留历史记录。

**Acceptance Scenarios**:

1. **Given** 复测完成，**When** 落盘，**Then** 逐字原文 + 测试环境（新包含两周期改动）+ 归因映射（Case A→R4 修复未达效、Case B→R5 修复未达效）三要素齐备
2. **Given** 上轮验收已有 ✗ 记录，**When** 更新验收文档，**Then** 追加复测行标注「新包复测仍未修复」，不篡改历史记录
3. **Given** handbook 有卡点清单，**When** 同步，**Then** Case A/B 当前状态、WPS 对标差距、L1 真机通路疑案全部反映

---

### User Story 2 - Checkpoint Commit 交接基线（Priority: P1）

**故事**：wysiwyg-crop 与 wps-parity-layout 两周期改动已全部验证（357 测试全绿）但未提交。交接前提交为 checkpoint commit，让新 AI 工程师拿到干净基线，避免误覆盖。

**Why this priority**: 未提交改动是交接最大工程风险；干净基线是一切文档引用的前提。

**Independent Test**: git log 出现 checkpoint commit；交接文档引用其 hash。

**Acceptance Scenarios**:

1. **Given** 工作区含两周期已验证改动，**When** 提交，**Then** 生成符合仓库风格的 checkpoint commit，代码基线可追溯
2. **Given** 本周期自身产物（文档/脚本），**When** 周期收尾，**Then** 也已提交，最终工作区干净

---

### User Story 3 - AGENTS.md 与命令脚本（Priority: P1）

**故事**：新 AI 工程师（AI coding agent）冷启动时读根目录 AGENTS.md 即可知道：项目是什么、文档在哪、怎么跑测试、有哪些铁律；常用长命令（全量测试、局部测试、装机冒烟、真机目标编译）由脚本封装，一条命令执行——把本项目踩过的坑（DEVELOPER_DIR 必须导出、`-disable-sandbox` 必加、模拟器 Busy 先 erase）固化进脚本。

**Why this priority**: Agent 接手效率的瓶颈在命令试错成本与约束不知情。

**Independent Test**: 全新会话只读 AGENTS.md，按其指引一条命令跑通全量测试并报告正确计数。

**Acceptance Scenarios**:

1. **Given** 主流 AI coding agent 冷启动，**When** 读 AGENTS.md，**Then** 获得项目定位、文档索引、SDD 工作流说明、铁律清单
2. **Given** Agent 执行封装的测试命令，**When** 无任何额外环境知识，**Then** 得到与手工执行一致的结果（357 = 356 passed + 1 known issue + 0 failed）

---

### User Story 4 - 文档与代码一致性同步（Priority: P1）

**故事**：README 还写着 132 个测试、05-roadmap 停在 2026-09-12、8 个 SDD 周期未入册。全部过期陈述同步到当前真实状态。

**Why this priority**: 过期文档会直接误导新工程师的决策。

**Independent Test**: 抽查关键文档数字（测试数/文件数/能力状态/周期史）与实测一致。

**Acceptance Scenarios**:

1. **Given** README 写「132 测试（2026-09-12）」，**When** 同步，**Then** 更新为实测值与当前日期
2. **Given** 多处文档陈述矛盾，**When** 同步，**Then** 以代码与测试实测为准修正
3. **Given** 8 个 SDD 周期的成果未入册，**When** 同步，**Then** 周期史完整可检索

---

### User Story 5 - 交接文档 docs/12-handover.md（Priority: P2）

**故事**：新 AI 工程师只读 docs/12-handover.md 一份文档，就能建立项目全貌认知、了解当前全部卡点（含本次复测结论）、看懂优先级排序的路线图、知道从哪里下手。所有内容落盘，每项可下钻到证据。

**Why this priority**: 交付物核心；依赖 US1~US4 的产出（结论、基线、入口、同步后的事实）。

**Independent Test**: 单独阅读 docs/12-handover.md 回答四个问题：项目是什么 / 现在卡在哪 / 下一步做什么 / 我从哪开始。

**Acceptance Scenarios**:

1. **Given** 新 AI 工程师接手，**When** 只读交接文档，**Then** 全貌/卡点/路线图/上手路径四要素齐备且每项可下钻
2. **Given** 卡点章节，**When** 阅读，**Then** Case A/B 复测结论、L1 真机通路疑案、WPS 对标差距全部在列且有证据链接
3. **Given** 路线图章节，**When** 阅读，**Then** 事项按优先级排序且与卡点一一对应

---

### Edge Cases

- 文档相互矛盾（如 README 与 handbook 数字不一致）→ 以代码/测试实测为准修正
- commit 时发现构建产物或系统文件混入 → 检查 `.gitignore`，最小改动补漏
- 验收文档历史 ✗ 记录 → 追加复测行，不覆盖历史

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: 系统 MUST 将真机复测结论（逐字原文 + 测试环境 + 归因映射）落盘至 `spec/agent-handover/` 工件，并同步更新 `spec/wysiwyg-crop/device-acceptance.md` 复测结果与项目卡点清单
- **FR-002**: 两周期已验证改动 MUST 以 checkpoint commit 提交；本周期产物在收尾时 MUST 一并提交；交接文档 MUST 引用代码基线 commit
- **FR-003**: 仓库根目录 MUST 新增 `AGENTS.md`，内容覆盖：项目定位、文档索引、SDD 工作流、铁律约束（协议签名不变 / 纯离线 / 既有断言零修改 / 环境坑）、命令脚本用法
- **FR-004**: 仓库 MUST 提供命令脚本封装：全量单测（含计数）、局部单测、装机冒烟、真机目标编译——执行者无需知晓底层长命令细节
- **FR-005**: `docs/12-handover.md` MUST 覆盖四要素：项目全貌、当前卡点（含复测结论）、优先级路线图、AI 工程师上手路径；所有断言可下钻到证据
- **FR-006**: 过期文档（README、docs/05-roadmap、docs/09 相关节、docs/00/02/06/10 中与现状矛盾处）MUST 同步至与代码实测一致
- **FR-007**: 交接相关文档中的全部数字（测试数、文件数、周期数）MUST 可验证且相互一致
- **FR-008**: 本周期 MUST NOT 修改应用源代码与既有测试——357 测试基线不变（文档/脚本/配置/提交操作除外）

### Key Entities

- **复测结论记录**: 逐字原文 + 环境 + 归因（R4/R5 修复未达效）+ 与既有验收记录的对照
- **AGENTS.md**: AI coding agent 冷启动入口（定位 / 索引 / 铁律 / 命令）
- **命令脚本**: 全量测试 / 局部测试 / 装机冒烟 / 真机编译的封装
- **交接文档（docs/12-handover.md）**: 全貌 / 卡点 / 路线图 / 上手路径四要素单入口
- **Checkpoint commit**: 两周期代码基线 + 本周期产物，交接的 git 锚点

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 新 AI 工程师仅凭 AGENTS.md + 交接文档，在单次会话内跑通全量测试并报告正确计数（357 = 356 passed + 1 known issue + 0 failed）
- **SC-002**: 仓库内过期陈述清零——抽查 README / 05-roadmap / 09-handbook / 12-handover 的关键数字与能力状态全部与实测一致
- **SC-003**: 复测结论在三处（周期工件 / 验收文档 / 卡点清单）可检索且相互一致
- **SC-004**: 周期结束时 git 工作区干净，交接文档引用的基线 commit 可追溯
- **SC-005**: 交接文档四要素（全貌/卡点/路线图/上手路径）任意一项 ≤ 2 跳下钻到证据文档或代码

## Assumptions

- 「新的安装包」= 当前工作区构建（含 wysiwyg-crop + wps-parity-layout 全部改动）；Case A/B 复测失败 = 两周期修复在真机验收标准下未达效，非构建遗漏
- 「左边很大部分都近图片」按既有失败记录语义理解（Case B 跟踪态手动拍成片含左页大半）；逐字原文保留不受解释影响
- 本周期为纯文档/脚本/配置周期，不改应用源码；357 测试基线不变
- 文档语言为中文；commit message 遵循仓库既有风格
- L1 真机通路疑案（iOS 26.7 结构化通路疑似静默回退）仍未定案，交接文档记录为待办取证而非已结案

## Open Questions

（无——4 个关键决策点已在澄清阶段确认：周期目录 `spec/agent-handover`、Agent 化 = AGENTS.md + 命令脚本、交接文档 = `docs/12-handover.md`、先 checkpoint commit 再交接）
