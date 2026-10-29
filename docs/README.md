# docs 索引

> 只在这里维护**文档分级**；每篇文档的状态以其页首 banner 为准。
> 易变事实（提交号、测试计数、当前任务、下一步）只在
> [`12-handover.md`](12-handover.md) 与 [`../TODO.md`](../TODO.md) 维护，
> 其他文档不复述，避免多处漂移。

## 1. 当前事实源（做决策只看这些）

| 文档 | 内容 |
| --- | --- |
| [`../AGENTS.md`](../AGENTS.md) | Agent 入口：团队基线 / 铁律 / 命令 / 任务分级 |
| [`../references/`](../references/) | 按需细则：`contracts` / `verification` / `workflow` |
| [`12-handover.md`](12-handover.md) | **交接单入口**：现在做到哪 / 第一天怎么跑 / 下一步 / 不要做什么 |
| [`22-capture-envelope-tracking.md`](22-capture-envelope-tracking.md) | **P0.3 取景包络主线**：包络跟踪 + 拍后拆页 + 验收指标 |
| [`../TODO.md`](../TODO.md) | 任务勾选、暂停项、已知测试债 |
| [`../spec/capture-envelope-tracking/`](../spec/capture-envelope-tracking/) | 当前周期四件套（spec / plan / tasks / device-acceptance） |
| [`13-mcp-quickref.md`](13-mcp-quickref.md) | 本机 MCP server 分工与使用铁律 |

## 2. 常读参考（按任务下钻）

| 文档 | 内容 |
| --- | --- |
| [`00-getting-started.md`](00-getting-started.md) | 实操：目录地图、主路径、改哪里、怎么测 |
| [`01-product-prototype.md`](01-product-prototype.md) | 产品原型：场景、信息架构、主路径、视觉 |
| [`02-architecture.md`](02-architecture.md) | 分层、模块、数据流、工程结构（与代码对齐） |
| [`03-tech-choices.md`](03-tech-choices.md) | 技术选型与取舍 |
| [`04-implementation-principles.md`](04-implementation-principles.md) | 几何 / 管线 / 并发 / 落盘 / 编码规矩 |
| [`06-document-reconstruction.md`](06-document-reconstruction.md) | 版面还原：IR、本机 R2、TextIn stub、已知问题 |
| [`09-project-handbook.md`](09-project-handbook.md) | 接手手册：架构原理 + 卡点史 + 优化方向（§4 契约、§6 卡点最常引用） |
| [`11-wps-parity-research.md`](11-wps-parity-research.md) | WPS 扫描对标调研：docx 取证 / 差距分析 / 周期规划 |
| [`16-word-export-fidelity.md`](16-word-export-fidelity.md) | Word 导出保真度：图片版档 / 保真度闸门 |
| [`17-editable-tier-fidelity-iteration.md`](17-editable-tier-fidelity-iteration.md) | 可编辑 Word 档迭代（0.785 未达标，暂停） |

## 3. 历史归档（只作背景，不要按其中的“下一步”执行）

这些文档记录“为什么走到这里”，结论仍有效但计划已过期；需要根因/证据时再读。

| 文档 | 内容 | 被谁取代 |
| --- | --- | --- |
| [`05-roadmap.md`](05-roadmap.md) | 2026-09 落地线路图 | `12` / `22` |
| [`07-reconstruct-r2-optimization.md`](07-reconstruct-r2-optimization.md) | R2 优化方案 | `08` / `spec/word-fidelity` |
| [`08-reconstruct-v3-realworld-fix.md`](08-reconstruct-v3-realworld-fix.md) | v3 真机根因链 | `16` / `spec/word-fidelity` |
| [`10-project-summary.md`](10-project-summary.md) | 2026-09 项目总结（架构 / SDD 周期史） | `14` / `12` |
| [`14-project-summary-and-roadmap.md`](14-project-summary-and-roadmap.md) | 2026-10-21 完整复盘 | `12` / `22` |
| [`15-capture-recovery-assessment.md`](15-capture-recovery-assessment.md) | 取景卡点复盘与引导框计划 | `21` / `22` |
| [`18-h2oc-word-fidelity-run.md`](18-h2oc-word-fidelity-run.md) | h2oc 一次性运行记录 | `spec/word-fidelity` |
| [`19-page-preprocess-plan.md`](19-page-preprocess-plan.md) | 页面预处理计划（P0.1/P0.2 已收口；暂停项仍在 TODO） | `22` |
| [`20-border-crop-convergence.md`](20-border-crop-convergence.md) | 边框/背景单次收敛（P0.1） | `19` / `22` |
| [`21-capture-ux-stability.md`](21-capture-ux-stability.md) | 取景稳定性与拍摄意图复盘（P0.2） | `22` |

## 4. 资产与工具

| 路径 | 内容 |
| --- | --- |
| [`fixtures/`](fixtures/) | 样张 OCR 夹具：怎么导、怎么生成、保真度说明 |
| [`diagrams/`](diagrams/) | 分层 / 扫描管线 / 模块关系 SVG |
| [`media/`](media/) | 录屏与关键帧（`screenrecord/` 未入库） |
| [`reconstruct-r2-preview.html`](reconstruct-r2-preview.html) | 还原功能界面线框（8 屏） |
| [`../prototype/index.html`](../prototype/index.html) | 可交互界面原型 |
| [`../Tools/`](../Tools/) | OCR / PDF dump、Word 保真度评测脚本 |

## 维护约定

1. **新增文档**：页首写状态 banner（当前 / 参考 / 历史 + 取代关系），并在本索引登记。
2. **状态变化**：只改 [`12`](12-handover.md) / [`TODO`](../TODO.md) / 当前周期 `spec`；
   历史文档保留当时的计数与结论，不回填新数字。
3. **删除**：历史文档不删（证据与根因链）；确需删除时先在 `12` 记录替代来源。
4. **链接**：相对链接必须可解析；提交前跑 `make check-docs`（链接 + 围栏 + 本索引覆盖）。
