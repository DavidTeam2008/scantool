# 纸匣 Zhixia

把纸上的东西，干净地收进这台 iPhone。

对标全能扫描王的**主体能力**：拍照取景、自动框边、透视拉正、增强、连续多页、证件、OCR、版面还原（本机）、导出 PDF / Word / 分享。不做广告、不做账号墙——扫描与「文本」全程本机；「还原」也是本机（iOS 26 起用系统的结构化文档识别 `RecognizeDocumentsRequest`，仍是端侧），云解析（TextIn）只留了未接线的 stub。

| 项 | 值 |
| --- | --- |
| 工程 | [`Zhixia.xcodeproj`](Zhixia.xcodeproj) · Scheme `Zhixia` |
| Bundle ID | `com.david.Zhixia` |
| 系统 / 语言 | iOS 18+ · Swift 6 |
| 设备 | 仅 iPhone（竖屏） |
| 规模 | 147 个 Swift 文件（主工程 107 / 测试 40）/ 主工程约 14.5k 行 / 357 个测试用例（全量 356 passed + 1 expected failure + 0 failed） |

---

## 新人怎么读

**第一读：[docs/12-handover.md](docs/12-handover.md)** —— 交接文档单入口（项目全貌 /
当前卡点 / 路线图 / AI 工程师上手路径，每项可下钻到证据）。
**第二读：[docs/09-project-handbook.md](docs/09-project-handbook.md)** —— 一页讲全
（产品原型 / 架构 / 技术选型 / 实现原理 / 已实现功能 / 卡点 / 后续方向 / 上手操作）。

然后按需下钻：

| 文档 | 内容 |
| --- | --- |
| [docs/12-handover.md](docs/12-handover.md) | **交接文档（新人第一读）**：全貌 / 卡点 / 路线图 / 上手路径 |
| [docs/09-project-handbook.md](docs/09-project-handbook.md) | **接手手册**：架构原理 + 卡点史 + 优化方向 |
| [AGENTS.md](AGENTS.md) | AI coding agent 冷启动入口：定位 / 铁律 / 命令速查 |
| [docs/00-getting-started.md](docs/00-getting-started.md) | 实操：目录地图、主路径、改哪里、怎么测 |
| [docs/01-product-prototype.md](docs/01-product-prototype.md) | 产品原型：场景、信息架构、主路径、视觉 |
| [docs/02-architecture.md](docs/02-architecture.md) | 分层、模块、数据流、工程结构（与代码对齐） |
| [docs/03-tech-choices.md](docs/03-tech-choices.md) | 技术选型与取舍 |
| [docs/04-implementation-principles.md](docs/04-implementation-principles.md) | 几何 / 管线 / 并发 / 落盘 / 编码规矩 |
| [docs/05-roadmap.md](docs/05-roadmap.md) | 里程碑现状与后续 |
| [docs/06-document-reconstruction.md](docs/06-document-reconstruction.md) | 版面还原：IR、本机 R2、TextIn stub、**已知问题** |
| [docs/07-reconstruct-r2-optimization.md](docs/07-reconstruct-r2-optimization.md) | **R2 优化方案**：原型 / 架构 / 选型 / 原理 / 阻碍 / 计划 + 实测数据 |
| [docs/08-reconstruct-v3-realworld-fix.md](docs/08-reconstruct-v3-realworld-fix.md) | **真机回归**：反解方法、根因链、P0~P3 路线图 |
| [docs/10-project-summary.md](docs/10-project-summary.md) | 项目总结：架构 / 技术原理 / SDD 周期史 |
| [docs/11-wps-parity-research.md](docs/11-wps-parity-research.md) | **WPS 扫描对标调研**：docx 取证 / 差距分析 / 周期规划 |
| [docs/fixtures/README.md](docs/fixtures/README.md) | 样张 OCR 夹具：怎么导、怎么生成、保真度说明 |
| [prototype/index.html](prototype/index.html) | 可交互界面原型 |
| [docs/reconstruct-r2-preview.html](docs/reconstruct-r2-preview.html) | 还原功能界面线框（8 屏） |

图：[分层](docs/diagrams/layers.svg) · [扫描管线](docs/diagrams/pipeline.svg) · [模块关系](docs/diagrams/modules.svg)

---

## 快速开始

```bash
open Zhixia.xcodeproj
```

**命令行一律走 [`Makefile`](Makefile)**（环境坑已固化：DEVELOPER_DIR 默认注入、
`-disable-sandbox` 必加、Busy 只提示不自动擦除）：

```bash
make help      # 全部命令
make test      # 全量单测 + 自动 xcresulttool 计数
make test-only T=GoldenWorksheetEndToEndTests   # 局部单测
make smoke     # 装机冒烟（build + install + launch + 存活检查）
make device-build   # 真机目标编译（免签名）
make doctor    # 环境自检
```

> ⚠️ **macOS 26.x + Xcode 26.x 必须加 `OTHER_SWIFT_FLAGS="-disable-sandbox"`**，否则所有 Swift 宏
> （SwiftData `@Model` / Observation `@Observable` / swift-testing `@Test`）都会报
> `swift-plugin-server produced malformed response` 而构建失败。
> 根因是编译器给宏插件套的 `sandbox-exec` 在本系统申请失败（`sandbox_apply: Operation not permitted`）。
> 与 Xcode 装在哪个卷无关，详见 [docs/00-getting-started.md §7](docs/00-getting-started.md#7-怎么测)。

模拟器偶发 `Simulator device failed to launch ... reason: Busy` —— 不是代码问题，
`xcrun simctl erase all` 后重跑即可。

```
Zhixia/          App · Features · Domain · Services · DesignSystem
ZhixiaTests/     40 个测试文件 / 357 个 @Test（含端到端断言 + 真实样张 + 金标准语法页）
docs/            接手手册 + 交接文档 + 产品 / 架构 / 选型 / 原理 / 路线图 / 还原专题
spec/            SDD 周期工件（9 个周期：spec/plan/tasks/device-acceptance 四件套）
Tools/           ocr-dump（造夹具）· pdf-ocr-dump（反解真机 OCR）
prototype/       可交互界面原型
```

---

## 产品承诺

1. **操作简单**：主路径「对着纸 → 快门 → 完成 → 保存」。
2. **界面好看**：纸色画布 + 朱砂主操作。
3. **架构干净**：Feature 不碰 `AVCaptureSession` / `CIFilter`；图像处理进 actor；元数据与文件分离。
4. **双通路文字**：详情「文本」= 本机 OCR 复制；「还原」= 排版 IR → Word / 可检索 PDF（仍本机，不默认上传）。

详情底栏：`文本 | 还原 | 分享 | 加页`。

---

## 能力现状（2026-09-26）

### 已可用

| 能力 | 状态 |
| --- | --- |
| 取景 / 实时框边（三级检测兜底 + 连续实线整框）/ 连拍 / 相册导入 | ✅ |
| 取景：自动快门确认窗 + 可疑锁定门禁 + 四态引导 | ✅ |
| 整理：拖角、五档滤镜、旋转、保存入库 | ✅ |
| 库：文件夹、搜索、收藏、加页 | ✅ |
| OCR「文本」、图片 PDF / 可检索 PDF / 分享 | ✅ |
| OCR：专用预处理档 + 质量不达标时自动重 OCR | ✅ |
| 证件模式比例窗 | ✅ |
| 还原：段落阅读序 → DOCX / 可检索 PDF | ✅ |
| 还原：IR v2（PageLayout / 语义标签 / anchor） | ✅ |
| **还原：表格（iOS 26 结构化通路）** | ✅：`RecognizeDocumentsRequest` 直接给行列结构（模拟器实测 7×3）；真机接通性待取证（L1 疑案） |
| **还原：流式档默认（WPS 对标）** | ✅ **新增（wps-parity-layout）**：flow 流式为默认档，`.restored` 降级可选「高保真」；档位选择器 + @AppStorage 持久化、预览/导出同源 |
| **还原：零假表** | ✅ **新增**：v1 表格聚类器退役（几何通路不再产表，宁缺毋假），表只来自结构化识别或锚点驱动 v2 |
| **还原：丢字防护** | ✅ **新增**：containment 不变量 + 页眉规则收紧 + 墨迹-文本对账哨兵 `textSentinel`（四分类，只记不阻断） |
| **还原：通路可观测** | ✅ **新增**：`reconstructPath` 每页一条决策线（五分类） |
| **还原：段落收敛** | ✅ **新增**：导出侧 `FlowParagraphSplitter` 切段，金标准 32 段 ∈ 42±30% |
| **还原：漫画条整块内联** | ✅ **新增**：细长大图形单张完整内联于阅读序原位（金标准验证） |
| 还原：左右分栏排阅读序（`PageColumnSplitter`） | ✅ |
| 还原：正文里的照片（`InkFigureDetector` 像素墨块） | ✅ |
| **取景：快门裁切门禁 + 候选粘滞（WYSIWYG 契约）** | ✅ 单测钉死（`CropConsistencyGate` / `CandidateSticky`）；⚠️ 真机 Case A/B 未达效，见下 |

### 未达可用标准 / 未完成

| 能力 | 状态 |
| --- | --- |
| **取景 WYSIWYG（真机验收标准）** | 🔴 **当前最大卡点**：折页书 Case A 成片仍含折起部分；摊开书 Case B 实线框仍跳、手动拍成片含左页大半——R4/R5 修复经 2026-09-26 新包复测未达效，待日志定案（见 [docs/09 §6.13](docs/09-project-handbook.md)） |
| **还原：表格（iOS 18~25 几何兜底）** | ⚠️ 锚点命中才出表，**真机仍 `w:tbl = 0`**（known issue 钉住） |
| 还原：配图 / 条码裁切 | ⚠️ 能出图，真机质量差 |
| TextIn / 云版面解析 | ❌ stub：无密钥、无网络实现，`parse` 直接 throw |
| 手写 / 勾选识别 | ❌ 未实现（类型已预留，无产出） |

---

## 当前最大卡点

### 1. 取景裁剪 WYSIWYG 未达（🔴 头号问题，2026-09-26 复测）

用户用含 wysiwyg-crop + wps-parity-layout 两周期全部改动的新包真机复测（iPhone 13 ·
iOS 26.7）：

- **Case A**（折页书翻中间、左侧折起拍右页）：成片**仍含折起部分**——R4 修复（快门裁切
  门禁「呈现框 = 裁切基准」）未达效。两个待定案假设：H1 显示侧（呈现框本身锁了含折起
  的整书外轮廓，门禁按契约工作、错在锁定对象）vs H2 门禁侧（误纳静帧/路径未命中）。
- **Case B**（摊开书从中线取景拍右页）：实线框**仍持续跳动**，手动拍成片**含左页大半**
  ——R5 修复（候选粘滞）未达效；高置信假设：粘滞 v1「池交替」盲区（候选池存在性逐帧
  交替时无相似帧可改写）。
- **总体**：WPS 扫描对标（取景拍照 + 还原版面 Word）未达。

**两轮修复的共同短板**：`cropGate` / `stickyOverride` 日志从未取得，根因至今未定案。
**下轮必须先实时抓日志定案再动刀**（步骤：`spec/wysiwyg-crop/device-acceptance.md` §0）。
逐字记录与归因：`spec/agent-handover/device-retest-20260926.md`。

### 2. L1 真机通路疑案（iOS 26 结构化识别疑似静默回退）

iPhone 13（iOS 26.7）2026-09-21 真机导出的 docx 走了几何回退通路，而模拟器（iOS 26.4.1）
结构化通路正常——真机接通性从未验证。已加 `reconstructPath` 决策日志（每页一条），
取证一步到位：`spec/wps-parity-layout/device-acceptance.md` §A。

### 3. 真机表格（iOS 26 已解决，老系统仍未解决）

根因链（见 [docs/08](docs/08-reconstruct-v3-realworld-fix.md)）：Vision 老的
`VNRecognizeTextRequest` **只给 line 级 bbox**，真机把整行单元格合并成一个 line
（`项目每100克NRV%`），于是「按 OCR 行的 midX 聚类推列」这条假设**直接失效** ——
`TableGridV2Detector` 直接 `return nil` → **整表消失 → Word 里 `w:tbl = 0`**。
iOS 26 的 `RecognizeDocumentsRequest` 直接返回二维 Cell 数组绕开该假设（模拟器实测
7×3）；iOS 18~25 仍走几何兜底 —— `ReconstructEndToEndTests.realDeviceOcrStillLacksTable`
用 `withKnownIssue` 钉在测试里。

### 4. 单张 fixture 过拟合（部分缓解）

iOS 26 通路绕开了旧阈值；但**几何兜底仍然过拟合**，且阈值本身没有改。

### 5. 架构性天花板

| 维度 | 扫描王 / WPS | 纸匣 | 差距性质 |
| --- | --- | --- | --- |
| 图像预处理 | 自动裁边 + 去阴影 + 二值化 + 锐化 | ✅ 已补 OCR 专用预处理档 | —— |
| OCR 引擎 | 自研/定制 + 云 | Apple Vision（端侧） | 端侧差一档，需云通路 |
| 版面分析 | 深度学习版面模型 | ✅ iOS 26 走系统结构化识别 | 老系统仍有差距 |
| 表格还原 | 深度学习表格结构识别 | ✅ iOS 26 用 `RecognizeDocumentsRequest` | 老系统仍有差距 |

### 已修历史（详录见 [docs/09 §6](docs/09-project-handbook.md)）

2026-09-08 ~ 09-24 共 8 个 SDD 周期修复了：数据安全三缺陷、导出六缺陷、真机第二轮
五缺陷、扫描保真六缺陷、取景框不可见两环、WYSIWYG 门禁与粘滞（单测级）、默认导出
对标 WPS（流式默认/零假表/丢字防护/段落收敛/漫画条内联）等——完整卡点史与回归网
见手册 §6.1~§6.12。

---

## 后续方向（摘要）

| 优先级 | 内容 |
| --- | --- |
| **P0** | 取景裁剪质量：实时抓 `cropGate` / `stickyOverride` 日志定案 Case A（H1/H2）与 Case B（池交替），再修复 |
| **P0** | L1 真机通路取证：真机解析语法页，抄录 `reconstructPath` 行定案（iOS 26.7 结构化通路疑案） |
| **P1** | 老系统兜底：表格降级阶梯（anchor → 通用数字列）；列/行切分改投影找 gutter |
| **P2** | 导出层：DOCX 表格样式（`w:tblPr` / 表头加粗 / 数值右对齐）；合并单元格 `gridSpan`/`vMerge` |
| **P3** | 工程债：`LibraryViewModel.reload` 全表加载 + N+1；`ReviewViewModel.save` 全量驻留内存 |
| **P4** | 接通云解析（TextIn）；手写 / 勾选识别 |

详细排期与任务拆解见 [docs/12-handover.md §3](docs/12-handover.md) 与
[docs/09-project-handbook.md §7](docs/09-project-handbook.md#7-后续优化方向)。

---

## 还原相关的工具与测试

- **样张夹具**：`docs/fixtures/`（营养表 + 练习册 + **真实双栏教材页**），`Tools/ocr-dump/` 生成，
  固化在 `ZhixiaTests/ReconstructV2Fixtures.swift`（**勿手改**，改原图后重跑生成脚本）。
- **真机反解**：`Tools/pdf-ocr-dump/` —— 从导出的 PDF 反解真机 OCR `[(text, bbox)]`。
  真机出问题时标准流程：**导出 PDF → 反解 → 对比 fixture → 定位 → 固化新 fixture → 修 → 回归**。
- ⚠️ `withKnownIssue` 命中时日志是 **recorded an expected failure**，不是 `passed`——grep 时别按 passed 找。
  当前 1 条：`ReconstructEndToEndTests.realDeviceOcrStillLacksTable`（真机几何通路仍出不了表）。
- ⚠️ **模拟器上 `VNDetectBarcodesRequest` 恒返回 0**（真实样张 + 全部 symbology 也验过）。
  任何依赖条码检测的断言在模拟器里都是假绿 —— 检测已抽成 `BarcodeDetecting` 协议，
  单测注入替身，真检测器只能真机验。
