# 纸匣 Zhixia

把纸上的东西，干净地收进这台 iPhone。

对标全能扫描王的**主体能力**：拍照取景、自动框边、透视拉正、增强、连续多页、证件、OCR、版面还原（本机）、导出 PDF / Word / 分享。不做广告、不做账号墙——扫描与「文本」全程本机；「还原」也是本机（iOS 26 起用系统的结构化文档识别 `RecognizeDocumentsRequest`，仍是端侧），云解析（TextIn）只留了未接线的 stub。

| 项 | 值 |
| --- | --- |
| 工程 | [`Zhixia.xcodeproj`](Zhixia.xcodeproj) · Scheme `Zhixia` |
| Bundle ID | `com.david.Zhixia` |
| 系统 / 语言 | iOS 18+ · Swift 6 |
| 设备 | 仅 iPhone（竖屏） |
| 规模 | 141 个主工程 Swift 文件 / 69 个测试文件 / **547 个测试用例**（10 条既有债，5~10 条 flaky 命中；最近一次 536 passed + 10 failed + 1 expected） |
| 当前主线 | P0.3 取景包络跟踪（[`docs/22`](docs/22-capture-envelope-tracking.md)）；CF-T002~T011a 已交付；真机验收记录待补 |

---

## 新人怎么读

**第一读：[docs/12-handover.md](docs/12-handover.md)** —— 交接文档单入口（项目全貌 /
当前主线 / 卡点 / 路线图 / 上手路径，每项可下钻到证据）。
**第二读：[docs/22-capture-envelope-tracking.md](docs/22-capture-envelope-tracking.md)** ——
当前取景主线的事实源（包络跟踪 / CF-T001~T007 / 验收指标）。
**第三读：[TODO.md](TODO.md)** —— 当前任务勾选、暂停项、已知测试债。

完整文档分级（当前事实源 / 常读参考 / 历史归档）见
[`docs/README.md`](docs/README.md)；本 README 不再重复维护文档清单。
AI coding agent 从 [`AGENTS.md`](AGENTS.md) 进入。

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
ZhixiaTests/     69 个测试文件 / 547 个 @Test（含端到端断言 + 真实样张 + 金标准语法页；10 条既有债）
docs/            接手手册 + 交接文档 + 产品 / 架构 / 选型 / 原理 / 路线图 / 还原专题
spec/            SDD 周期工件（17 个周期：spec/plan/tasks/device-acceptance 四件套）
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

## 能力现状（2026-10-28）

### 已可用

| 能力 | 状态 |
| --- | --- |
| 取景 / 实时框边（三级检测兜底 + 连续实线整框）/ 连拍 / 相册导入 | ✅ |
| **取景：包络跟踪（CF-T002/CF-T003）** | ✅ 第一版：整摊/书/单页包络、hold/平滑、目标页缺失仍显示包络 |
| **取景：目标页显示（CF-T004）** | ✅ 第一版：左/右页目标实线主框 + 整摊包络虚线上下文；屏幕外框/fullImage 拒绝 |
| **拍后输出意图（CF-T005）** | ✅ 第一版：`outputIntent` + 1600px 书脊/折页拆分；高置信自动落地、低置信提案 |
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
| **取景：快门裁切门禁 + 候选粘滞（WYSIWYG 契约）** | ✅ 单测钉死（`CropConsistencyGate` / `CandidateSticky`）；真机验收并入 P0.3 |

### 未达可用标准 / 未完成

| 能力 | 状态 |
| --- | --- |
| **取景 P0.3 真机验收** | 🟠 **当前最大风险**：CF-T004/CF-T005 只在合成测试/模拟器验证；视频 5/7 的目标框可见性、左页右角、左右页成片正确率待真机确认 |
| **取景跟踪跟手性** | 🟠 CF-T003 第一版只有低频观测 + hold/平滑；光流/单应性传播未做 |
| **取景 UI/快门收口** | 🟠 CF-T006：置信度态、按下冻结、自动/手动快门待收口 |
| **还原：表格（iOS 18~25 几何兜底）** | ⚠️ 锚点命中才出表，**真机仍 `w:tbl = 0`**（known issue 钉住） |
| 还原：配图 / 条码裁切 | ⚠️ 能出图，真机质量差 |
| TextIn / 云版面解析 | ❌ stub：无密钥、无网络实现，`parse` 直接 throw |
| 手写 / 勾选识别 | ❌ 未实现（类型已预留，无产出） |

---

## 当前最大风险（2026-10-28）

### 1. P0.3 取景真机验收未做（🟠 头号风险）

CF-T002~CF-T005 第一版已交付，但**只在合成测试/模拟器验证**。需要在真机上按
视频 5/7 复核：

- 右页/左页目标框是否持续可见；
- 左页目标的右上/右下角是否落在书脊上；
- 00:55 屏幕外框是否不再被拍下；
- 01:15–01:25 左页输出是否最终落到左页；
- 彩色/黑白 × 左/右/整页成片是否正确、背景残留是否可接受。

验收指标与失败定位见 [docs/22 §六](docs/22-capture-envelope-tracking.md#六验收指标建议先量化再调参)；
真机失败先留日志/录屏，不要直接改阈值。

### 2. 跟踪跟手性（CF-T003 第一版，后续 CF-T008）

当前 tracker 是低频观测 + hold/平滑/候选切换确认，尚未接光流/单应性传播。
日常移动相机时可能仍有延迟/切换；先做离线回放，再接主路径。

### 3. L1 真机通路疑案（iOS 26 结构化识别疑似静默回退）

iPhone 13（iOS 26.7）真机导出的 docx 曾走几何回退通路，模拟器正常——真机接通性
从未验证。已加 `reconstructPath` 决策日志，取证步骤：
`spec/wps-parity-layout/device-acceptance.md` §A。

### 4. 真机表格（iOS 26 已解决，老系统仍未解决）

iOS 18~25 仍走几何兜底，真机 OCR 把整行单元格合并成一个 line，`TableGridV2Detector`
直接返回 nil → `w:tbl = 0`。`ReconstructEndToEndTests.realDeviceOcrStillLacksTable`
用 `withKnownIssue` 钉住；修复前不要回到阈值过拟合。

### 5. 历史记录

2026-09-08 ~ 10-21 的 Case A/B、frame-truth、guided-capture、page-preprocess、
word-fidelity 根因与修复见 [docs/12 §2](docs/12-handover.md) 与
[docs/09 §6](docs/09-project-handbook.md)；它们是历史背景，当前取景主线已转为
[docs/22](docs/22-capture-envelope-tracking.md)。

---

## 后续方向（摘要，2026-10-28）

| 优先级 | 内容 |
| --- | --- |
| **P0** | 真机视频 5/7 验收 CF-T004/CF-T005：目标框可见、左页右角在书脊、无 fullImage 误拍、左右页成片正确 |
| **P0** | CF-T007 真机 + 20+20+10+10 场景验收；CF-T008 光流/单应性传播；CF-T006 UI/快门收口；CF-T009 观测增强（按需） |
| **P1** | 恢复暂停项：PP-T032 全流程、多条件样张回归、flaky 清理；Word 可编辑档 0.785→目标；L1 真机取证 |
| **P2** | 工程债：Library N+1、Review 内存驻留、SwiftData 零测试/迁移；老系统表格降级阶梯 |
| **P3** | 云解析（TextIn）/手写/勾选：独立周期评审，纯离线是铁律 |

详细排期与任务拆解见 [docs/12-handover.md §3](docs/12-handover.md#3-路线图按优先级2026-10-28) 与
[docs/22](docs/22-capture-envelope-tracking.md)；当前勾选状态见 [TODO.md](TODO.md)。

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
