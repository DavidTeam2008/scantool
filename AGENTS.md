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
| 测试基线 | **386 = 385 passed + 1 expected failure + 0 failed**（`ZhixiaTests/` 41 个含 `@Test` 文件；只增不减） |
| 网络依赖 | **零**（纯离线；TextIn 云解析是 stub，`parse` 直接 throw） |
| 架构 | App → Features(SwiftUI VM) → Domain(纯函数) → Services(actor 副作用)，依赖只向下 |
| 构建 | `Zhixia.xcodeproj`，Xcode 26.x，scheme `Zhixia`，PBXFileSystemSynchronizedRootGroup（新文件免改 pbxproj） |

## 2. 必读顺序（冷启动前三份）

1. `docs/12-handover.md` —— 交接文档：全貌 / 当前卡点 / 路线图 / 上手路径（单入口）
2. `docs/09-project-handbook.md` —— 项目手册：架构、实现原理、卡点史（§4 契约、§6 卡点清单最常被引用）
3. `docs/00-getting-started.md` —— 实操细节
4. `docs/14-project-summary-and-roadmap.md` —— 全面复盘 + **完整优化路线图**（2026-10-21 最新）

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

> **MCP 工具**：本机已装 6 个 MCP server（mobilebuildmcp / xcode / agent-device / maestro /
> testflight / app-store-connect），分工、配置落点与使用铁律见
> [`docs/13-mcp-quickref.md`](docs/13-mcp-quickref.md)；其中 testflight /
> app-store-connect 待补 ASC 凭证。

**计数陷阱（必读）**：known issue 用例在 xcodebuild 日志里是 `recorded an expected
failure`，**不是** `passed`——按 `passed` 关键字搜日志会数出 356 然后误判丢了 1 条。
以 `make test` 末尾自动打印的 xcresulttool 计数为准：`total=386 passed=385
failed=0 expectedFailures=1` 才是全绿。

**环境坑**（已固化进 Makefile，手工执行时别漏）：① `DEVELOPER_DIR` 必须指向本机
Xcode；② 必须加 `OTHER_SWIFT_FLAGS="-disable-sandbox"`（macOS 26.x 宏沙箱失效，
不加则所有宏报错）；③ 模拟器报 `Busy` 不是代码问题，`xcrun simctl erase all` 后重跑。

## 4. 铁律清单（违反任何一条都会破坏既有资产）

1. **`Services/ServiceProtocols.swift` 协议签名不变**——全部依赖经协议注入，签名一动
   全部替身测试连锁崩。
2. **既有测试断言零修改**——基线 386 只增不减；方向性翻转属唯一例外，须在周期
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
`spec/frame-truth`。
真机验收清单都在各周期 `device-acceptance.md`。

## 6. 当前状态指针（2026-10-17）

- **当前状态**：Case A（折页书）与 Case B（摊开书）根因均已定案、修复均已交付
  （case-b-sticky-v2 + folded-page-capture + frame-truth 三周期，全量 386 =
  385 passed + 1 expected failure + 0 failed）。**下一步唯一待办：真机验收**——主清单
  `spec/frame-truth/device-acceptance.md`（框真相：候选供给/冻结直裁/无效框
  承诺，同会话合并 Case B 复测与 `reconstructPath` L1 取证）。
  逐字记录与归因历史：`spec/agent-handover/device-retest-20260926.md`；
  卡点全貌：`docs/09-project-handbook.md` §6.13 / `docs/12-handover.md` §2。
- **动刀前必须**：先读当周期 spec 四件套；取景/还原链修改前读
  `spec/folded-page-capture/plan.md`（D1~D7 决策与不变式）与
  `spec/case-b-sticky-v2/plan.md`。
- **待定案疑案**：L1 真机通路（iOS 26.7 结构化识别疑似静默回退，模拟器不复现）——
  取证步骤 `spec/wps-parity-layout/device-acceptance.md` §A（已并入上述真机会话）。
- 路线图与优先级：`docs/12-handover.md` §3。
