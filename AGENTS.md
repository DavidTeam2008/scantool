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
| 测试基线 | **547 total / 541 passed / 5 failed（本次）+ 1 expected；既有测试债 10 条（flaky）**（`ZhixiaTests/`；iPhone 18 Pro / iOS 27；总数只增不减） |
| 网络依赖 | **零**（纯离线；TextIn 云解析是 stub，`parse` 直接 throw） |
| 架构 | App → Features(SwiftUI VM) → Domain(纯函数) → Services(actor 副作用)，依赖只向下 |
| 构建 | `Zhixia.xcodeproj`，Xcode 26.x，scheme `Zhixia`，PBXFileSystemSynchronizedRootGroup（新文件免改 pbxproj） |

## 2. 必读顺序（冷启动必读）

1. `docs/12-handover.md` —— 交接文档：全貌 / 当前主线 / 卡点 / 路线图 / 上手路径（单入口）
2. `docs/22-capture-envelope-tracking.md` —— **当前 P0.3 取景包络主线**：CF-T001~T009、验收指标、WPS 证据
3. `TODO.md` —— 当前任务勾选、暂停项、已知测试债
4. `docs/09-project-handbook.md` —— 项目手册：架构、实现原理、卡点史（§4 契约、§6 卡点清单最常被引用；历史快照）
5. `docs/00-getting-started.md` —— 实操细节
6. `docs/14` / `docs/15` —— 2026-10-21 历史复盘；需要背景时再读，不要按旧时间线继续调 sticky/smoother

改哪个模块前，先读对应专题：还原链 → `docs/06`/`07`/`08`；取景检测 → 对应 `spec/` 周期工件（见 §5）。

## 3. 命令速查（`Makefile`，DEVELOPER_DIR 默认值已内置、可覆盖）

| 命令 | 用途 |
|---|---|
| `make help` | 列出全部命令 |
| `make test` | 全量单测（iPhone 18 Pro / iOS 27.0 模拟器）+ 自动输出 xcresulttool 计数 |
| `make test-only T=<测试类名>` | 局部单测，例 `make test-only T=ReviewSplitProposalTests` |
| `make smoke` | 装机冒烟：模拟器 build + install + launch + 进程存活检查 |
| `make device-build` | 真机目标编译（`generic/platform=iOS`，免签名） |
| `make doctor` | 环境自检（Xcode / 模拟器 / Busy 提示） |

> **destination**：默认 `iPhone 18 Pro` / iOS 27.0（`Makefile` 顶部 `SIM_NAME`/`SIM_OS`）。
> 本机没有该 runtime 时用
> `make test DEST_SIM='platform=iOS Simulator,name=<机型>,OS=<版本>'` 覆盖；
> 不要直接改默认值。

> **MCP 工具**：本机已装 6 个 MCP server（mobilebuildmcp / xcode / agent-device / maestro /
> testflight / app-store-connect），分工、配置落点与使用铁律见
> [`docs/13-mcp-quickref.md`](docs/13-mcp-quickref.md)；其中 testflight /
> app-store-connect 待补 ASC 凭证。

**计数陷阱（必读）**：known issue 用例在 xcodebuild 日志里是 `recorded an expected
failure`，**不是** `passed`——按 `passed` 关键字搜日志会少算 1 条。以 `make test`
末尾自动打印的 xcresulttool 计数为准。当前全量预期：
`total=547 passed=541 failed=5 expectedFailures=1`（本次）；既有测试债共 10 条
（Golden 4 / WordFidelity 1 / Review preview 4 / ReviewSplit 1），不是新回归；本次命中 5 条，其余 flaky 通过。

**环境坑**（已固化进 Makefile，手工执行时别漏）：① `DEVELOPER_DIR` 必须指向本机
Xcode；② 必须加 `OTHER_SWIFT_FLAGS="-disable-sandbox"`（macOS 26.x 宏沙箱失效，
不加则所有宏报错）；③ 模拟器报 `Busy` 不是代码问题，`xcrun simctl erase all` 后重跑。

## 4. 铁律清单（违反任何一条都会破坏既有资产）

1. **`Services/ServiceProtocols.swift` 协议签名不变**——全部依赖经协议注入，签名一动
   全部替身测试连锁崩。
2. **既有测试断言零修改**——测试总数基线 547 只增不减；方向性翻转属唯一例外，须在周期
   tasks.md 逐条记录（先例：`ReconstructTierTests` 默认档翻转）。全量 10 个失败是既有
   测试债（本次命中 5 条，债务共 10 条），不要为了让全量变绿去删测试/放宽断言。
3. **纯离线**——不引任何网络依赖、不加云调用；云通路须独立立项评审。
4. **模拟器条码恒 0 是假绿**——`VNDetectBarcodesRequest` 在模拟器永远返回空，
   条码相关断言只能靠 `BarcodeDetecting` 协议注入替身 + 真机验收。
5. **`withKnownIssue` 日志陷阱**——expected failure ≠ failed ≠ passed（见 §3）。
6. **动 capture 侧 / reconstruct 侧前先读对应 spec**——每轮修复都钉在
   `spec/<周期>/spec.md`（FR/SC 编号）；跳过 spec 直接改代码是历次回归的根因。
   契约速查：WYSIWYG 裁切 → `docs/09` §4.2；版面对标 → `docs/09` §4.5。
7. **取景不在无框时回退 `.fullImage`**——屏幕外框/桌面最大矩形不是页面；
   无当前帧包络时保持搜索态并禁用快门（CF-T002/CF-T004）。
8. **成片 = 快门瞬间呈现框**——frame-truth 契约；拍后 refine 不得静默扩回用户
   没看见的内容；左/右页是输出意图，不是实时精确单页门槛。

## 5. SDD 工作流（本仓库的改动管理方式）

功能开发走 **spec-driven**：`spec/feature.json` 指向当前周期目录（当前为
`spec/capture-envelope-tracking/`），周期内五阶段流水——

```
spec.md（需求+验收标准） → plan.md（技术决策 D1~Dn） → tasks.md（任务拆解）
  → 实施（逐任务勾选） → 验证（含 device-acceptance.md 真机清单）
```

既有周期（证据归档，改前必读对应目录）：`spec/layout-engine` · `spec/layout-restore`
· `spec/scan-fidelity` · `spec/scan-edge-accuracy` · `spec/live-edge-crop` ·
`spec/overlay-frame-visibility` · `spec/wysiwyg-crop` · `spec/wps-parity-layout` ·
`spec/agent-handover` · `spec/case-b-sticky-v2` · `spec/folded-page-capture` ·
`spec/frame-truth` · `spec/scan-enhance` · `spec/guided-capture` ·
`spec/page-preprocess` · `spec/word-fidelity` · **`spec/capture-envelope-tracking`（当前 P0.3）**。
真机验收清单都在各周期 `device-acceptance.md`。

> **注意**：`spec/feature.json` 已指向 `spec/capture-envelope-tracking/`；P0.3 的
> 详细论证仍在 `docs/22`，任务勾选在 `TODO.md` 与 `spec/capture-envelope-tracking/tasks.md`。

## 6. 当前状态指针（2026-10-29）

- **代码基线**：`b7ea065`「feat(capture): land output target and intent split」。
- **当前主线**：P0.3 取景包络跟踪（[`docs/22`](docs/22-capture-envelope-tracking.md)）。
  - 已交付第一版：CF-T002 包络兜底、CF-T003 tracker、CF-T004 目标页显示、
    CF-T005 `outputIntent` + 1600px 拍后书脊/折页拆分。
  - **CF-T005b（视频 8）**：`PageDraft.quadRole`（target/envelope）+
    `SpreadSplitter.analyzeGutter` 亮缝模型；修复左页包络被裁后跳过拆分、
    右页漏入成片。
  - **CF-T005c（视频 9）**：亮缝搜索限 [0.30,0.70]；`acceptTarget` 目标
    一致性（包络包含/意图侧/宽高比 0.45~1.10/面积 ≥6%）；书脊暗谷宽度
    上限 20%；实时目标日志。
  - **CF-T005d（视频 10）**：左右页并集包络（`pagePairEnvelope`，排除
    “墙 + 书”大矩形）；池内页候选优先于整摊拆分；目标面积门 6%
    （边缘裁切左页 0.071）。
  - **CF-T010（视频 11/12，代码已落，真机复测待做）**：**取景域 ≠ 成片域**是新的根因——
    预览 `.resizeAspectFill` 把 4:3 帧铺满 390×844 全屏，只显示 **61.6% 宽**
    （两侧各 19.2%），检测/成片却用整帧。必须举高、框用屏幕外几何、
    成片横向范围是屏幕的 1.62 倍（多出 62%）——都由此而来。
    方案：4:3 取景窗 + `.resizeAspect`，检测/
    成片/预览同域；整页意图“贴帧边即未就绪”；照片/视频 FOV 真机复核。
    **真机复测通过前不要再调 `acceptTarget` 面积/宽高比或 tracker 阈值。**
  - **CF-T011a（视频 14/13，代码已落，真机复测待做）**：`isSinglePageForCapture`
    （归一化宽高比 <1.3）区分近距单页/整摊；整页单页贴画幅允许拍，整摊被裁
    仍置灰；左/右页目标缺失允许拍包络回退；裁切框钳到 [0,1]。
  - 已移除 `Quad.fullImage` 兜底；屏幕外框/贴边 frame 在包络、拆分、快门链路统一拒绝。
  - 无当前帧包络或 tracker hold 时快门置灰；左/右页目标缺失时仍可手动拍包络，
    由 Review 拆分。
- **测试**：全量 **547 total / 541 passed / 5 failed（本次）/ 1 expected**。
  既有测试债 10 条：Golden 4、WordFidelity 1、Review preview 4、ReviewSplit 1；
  本次命中 Golden 4 + WordFidelity 1，其余 5 条 flaky 通过；无新增失败。
  `Makefile` 基线总数 547（T010 +12、T011a +4），2026-10-29 全量已确认。
- **视频 8/9/10 修复（CF-T005b/c/d，工作区未提交）**：quadRole + 亮缝模型 +
  目标一致性 + 页对包络；证据 `build/cf-t007/video8/`、
  `build/device-logs/video9/`、`build/device-logs/video10/`；真机复测待做。
  视频 11/12 取证在 `build/cf-t005e/video11/`、`build/cf-t005e/video12/`。
- **WPS**：realbase 导出 docx SHA-256
  `80903b1d…8cf4153` 与 final/g1 基线 byte-identical，0.906224 不退；
  证据 `build/word-fidelity/realbase-cf45-20261028/`。
- **下一步（按顺序）**：
  1. **CF-T010 取景域 WYSIWYG**：4:3 取景窗 + `.resizeAspect` + 完整性门；
     真机复测视频 11/12（自然高度整本入屏、成片不超出屏幕、整页框不提前出现）；
  2. **CF-T011a 近距单页**：复测视频 14（近距右页，快门可用）和视频 13
     （左右页目标缺失时不再虚线/灰快门抖动）；
  3. **CF-T010b 拍后逐边包含**：`refineQuads` 面积门 → 逐边包含；
  4. **CF-T011 贴边合成**（T010/T011a 真机复测后）：书脊侧帧边合成 + 引导线；
  5. **CF-T007 真机与 WPS 验收**：视频 5/7/8/9/10/11/12 + 20+20+10+10 场景，
     按 `docs/22` §六量化；清单 `spec/capture-envelope-tracking/device-acceptance.md`；
  6. **CF-T008 光流/单应性传播**（当前只有低频观测 + hold/平滑）；
  7. **CF-T006 UI/快门收口**（置信度态、按下冻结、自动/手动快门；布局随 T010）；
  8. **CF-T009 观测增强**（按需，端侧 mask；只输出 mask/几何）；
  9. 恢复暂停项 PP-T032、多样张回归、flaky 清理（用户解除暂停后再做）。
- **历史背景**：Case A/B + frame-truth + guided-capture 的完整记录见
  `docs/12` §2 与 `docs/15`；这些修复仍在代码里，但不要按旧路线继续调
  sticky/smoother 阈值。
- **动刀前必须**：读 `docs/12` §0/§3/§4、`docs/22`、`TODO.md`；取景侧再读
  `spec/frame-truth/plan.md` 与 `spec/guided-capture/plan.md`（历史契约），
  还原侧读 `spec/wps-parity-layout/spec.md` 与 `docs/09` §4.5。
- **待定案疑案**：L1 真机通路（iOS 26.7 结构化识别疑似静默回退，模拟器不复现）——
  取证步骤 `spec/wps-parity-layout/device-acceptance.md` §A；与后续真机会话合并。
- 路线图与优先级：`docs/12-handover.md` §3（以 `docs/22` / `TODO.md` 为准）。
