# 纸匣 Zhixia

把纸上的东西，干净地收进这台 iPhone。

对标全能扫描王的**主体能力**：拍照取景、自动框边、透视拉正、增强、连续多页、证件、OCR、版面还原（本机）、导出 PDF / Word / 分享。不做广告、不做账号墙——扫描与「文本」全程本机；「还原」也是本机（iOS 26 起用系统的结构化文档识别 `RecognizeDocumentsRequest`，仍是端侧），云解析（TextIn）只留了未接线的 stub。

| 项 | 值 |
| --- | --- |
| 工程 | [`Zhixia.xcodeproj`](Zhixia.xcodeproj) · Scheme `Zhixia` |
| Bundle ID | `com.david.Zhixia` |
| 系统 / 语言 | iOS 18+ · Swift 6 |
| 设备 | 仅 iPhone（竖屏） |
| 规模 | 90 个 Swift 文件 / 约 9.3k 行 / 132 个测试用例（全量 131 passed + 1 known issue + 0 failed） |

---

## 新人怎么读

**第一读：[docs/09-project-handbook.md](docs/09-project-handbook.md)** —— 一页讲全
（产品原型 / 架构 / 技术选型 / 实现原理 / 已实现功能 / 卡点 / 后续方向 / 上手操作）。

然后按需下钻：

| 文档 | 内容 |
| --- | --- |
| [docs/09-project-handbook.md](docs/09-project-handbook.md) | **接手手册（新人第一读）**：全貌 + 卡点 + 优化方向 |
| [docs/00-getting-started.md](docs/00-getting-started.md) | 实操：目录地图、主路径、改哪里、怎么测 |
| [docs/01-product-prototype.md](docs/01-product-prototype.md) | 产品原型：场景、信息架构、主路径、视觉 |
| [docs/02-architecture.md](docs/02-architecture.md) | 分层、模块、数据流、工程结构（与代码对齐） |
| [docs/03-tech-choices.md](docs/03-tech-choices.md) | 技术选型与取舍 |
| [docs/04-implementation-principles.md](docs/04-implementation-principles.md) | 几何 / 管线 / 并发 / 落盘 / 编码规矩 |
| [docs/05-roadmap.md](docs/05-roadmap.md) | 里程碑现状与后续 |
| [docs/06-document-reconstruction.md](docs/06-document-reconstruction.md) | 版面还原：IR、本机 R2、TextIn stub、**已知问题** |
| [docs/07-reconstruct-r2-optimization.md](docs/07-reconstruct-r2-optimization.md) | **R2 优化方案**：原型 / 架构 / 选型 / 原理 / 阻碍 / 计划 + 实测数据 |
| [docs/08-reconstruct-v3-realworld-fix.md](docs/08-reconstruct-v3-realworld-fix.md) | **真机回归**：反解方法、根因链、P0~P3 路线图 |
| [docs/fixtures/README.md](docs/fixtures/README.md) | 样张 OCR 夹具：怎么导、怎么生成、保真度说明 |
| [prototype/index.html](prototype/index.html) | 可交互界面原型 |
| [docs/reconstruct-r2-preview.html](docs/reconstruct-r2-preview.html) | 还原功能界面线框（8 屏） |

图：[分层](docs/diagrams/layers.svg) · [扫描管线](docs/diagrams/pipeline.svg) · [模块关系](docs/diagrams/modules.svg)

---

## 快速开始

```bash
open Zhixia.xcodeproj
```

> ⚠️ **macOS 26.6 + Xcode 26.4 必须加 `OTHER_SWIFT_FLAGS="-disable-sandbox"`**，否则所有 Swift 宏
> （SwiftData `@Model` / Observation `@Observable` / swift-testing `@Test`）都会报
> `swift-plugin-server produced malformed response` 而构建失败。
> 根因是编译器给宏插件套的 `sandbox-exec` 在本系统申请失败（`sandbox_apply: Operation not permitted`）。
> 与 Xcode 装在哪个卷无关，详见 [docs/00-getting-started.md §7](docs/00-getting-started.md#7-怎么测)。

```bash
OTHER_SWIFT_FLAGS="-disable-sandbox" xcodebuild test \
  -project Zhixia.xcodeproj -scheme Zhixia \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation -skipMacroValidation
```

模拟器偶发 `Simulator device failed to launch ... reason: Busy` —— 不是代码问题，
`xcrun simctl erase all` 后重跑即可。

```
Zhixia/          App · Features · Domain · Services · DesignSystem
ZhixiaTests/     17 个测试文件（含端到端断言 + 真实双栏样张）
docs/            接手手册 + 产品 / 架构 / 选型 / 原理 / 路线图 / 还原专题
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

## 能力现状（2026-09-12）

### 已可用

| 能力 | 状态 |
| --- | --- |
| 取景 / 实时框边 / 连拍 / 相册导入 | ✅ |
| 整理：拖角、五档滤镜、旋转、保存入库 | ✅ |
| 库：文件夹、搜索、收藏、加页 | ✅ |
| OCR「文本」、图片 PDF / 可检索 PDF / 分享 | ✅ |
| OCR：专用预处理档 + 质量不达标时自动重 OCR | ✅ 新增（V3.2） |
| 证件模式比例窗 | ✅ |
| 还原：段落阅读序 → DOCX / 可检索 PDF | ✅ |
| 还原：IR v2（PageLayout / 语义标签 / anchor） | ✅ |
| **还原：表格（iOS 26 结构化通路）** | ✅ **新增（V3.1）**：`RecognizeDocumentsRequest` 直接给行列结构 |
| 还原：A/B/C 三档导出 + 预览随档位切换 | ✅ 实现保留，但 **B/C 入口已下架**（见下） |
| **还原：左右分栏排阅读序** | ✅ **新增（V3.5）**：`PageColumnSplitter`，不再逐行交错 |
| **还原：正文里的照片** | ✅ **新增（V3.5）**：`InkFigureDetector` 像素墨块，几何通路会漏 |

### 未达可用标准 / 未完成

| 能力 | 状态 |
| --- | --- |
| **还原：表格（iOS 18~25 几何兜底）** | ⚠️ 样张能出表，**真机仍 `w:tbl = 0`**（见下） |
| **还原：B 重排版 / C 衬底图** | ❌ **已从 UI 下架**（V3.4）。实现保留，改 `R2OutputTier.selectable` 可恢复 |
| 还原：配图 / 条码裁切 | ⚠️ 能出图，真机质量差 |
| TextIn / 云版面解析 | ❌ stub：无密钥、无网络实现，`parse` 直接 throw |
| 手写 / 勾选识别 | ❌ 未实现（类型已预留，无产出） |

---

## 当前最大卡点

### 1. 真机表格（🔴 头号问题）—— iOS 26 已解决，老系统仍未解决

根因链（见 [docs/08](docs/08-reconstruct-v3-realworld-fix.md)）：Vision 老的
`VNRecognizeTextRequest` **只给 line 级 bbox**，真机把整行单元格合并成一个 line
（`项目每100克NRV%`），于是「按 OCR 行的 midX 聚类推列」这条假设**直接失效** ——
列聚类只剩 1 列、锚点「营养成分表」也丢，`TableGridV2Detector` 直接 `return nil`
→ **整表消失 → Word 里 `w:tbl = 0`**。算法再调也救不回来。

**✅ iOS 26 通路已解决（V3.1）**：`RecognizeDocumentsRequest` 直接返回二维 Cell 数组，
根本不需要那个假设。实测（iPhone 17 模拟器 + 样张 `nutrition-mango.jpg`）读出
**1 张 7 行 × 3 列**的表，行切分完全正确（`["能量", "1429千焦", "17%"]`），
连真机丢失的「营养成分表」表头都恢复了。端到端断言见
`ZhixiaTests/ReconstructEndToEndTests.structuredPathProducesTableInDocx`。

**⚠️ iOS 18~25 仍走几何兜底**，那条路在真机上依旧出不了表 ——
`ReconstructEndToEndTests.realDeviceOcrStillLacksTable` 用 `withKnownIssue` 把这件事
钉在测试里（修好时会**反向失败**提醒）。

### 2. 单张 fixture 过拟合（部分缓解）

M0~M2 的阈值全是用两张**摆正、干净**的样张调出来的：

| 指标 | fixture | 真机（用户实拍） |
| --- | --- | --- |
| 营养表 x 跨度 | 0.147~0.84（页宽 70%） | 0.082~0.25（**17%**） |
| 单元格粒度 | 18 个独立 cell | **7 个错位行**（`项目每100克NRV%`、`17%蛋白` 跨行粘连） |
| 「营养成分表」标题 | 完整一行 | 识别成「◎配料：…」+ 孤立「表」，**anchor 丢失** |

iOS 26 通路绕开了这些阈值；但**几何兜底仍然过拟合**，且阈值本身没有改。

### 3. 架构性天花板

| 维度 | 扫描王 / WPS | 纸匣 | 差距性质 |
| --- | --- | --- | --- |
| 图像预处理 | 自动裁边 + 去阴影 + 二值化 + 锐化 | ✅ 已补 OCR 专用预处理档（去阴影 + 灰度 + 锐化） | —— |
| OCR 引擎 | 自研/定制 + 云 | Apple Vision（端侧） | 端侧差一档，需云通路 |
| 版面分析 | 深度学习版面模型 | 几何启发式 → ✅ iOS 26 走系统结构化识别 | 老系统仍有差距 |
| 表格还原 | 深度学习表格结构识别 | ✅ iOS 26 用 `RecognizeDocumentsRequest` | 老系统仍有差距 |

**结论**：纯端侧几何算法追不平扫描王。iOS 26 把「版面分析 / 表格还原」这两格的差距
填上了（靠系统模型），但**老系统与云通路仍是缺口**。

### 已修（2026-09-12，本轮）

| 类别 | 内容 |
| --- | --- |
| 数据安全 🔴 | `PageFileStore.commit` 回滚会删掉**追加目标文档的既有全部页图**；DOCX 未过滤 XML 非法控制字符导致**产物损坏**；图片 PDF 越界插入 |
| 导出正确性 | B 档 anchor 误用 twips（比正确值小 **635 倍**，图片缩成左上角一点）；C 档多页衬底全堆第 1 页；补 `w:rFonts` 中文字体声明 |
| 还原能力 | 接入 iOS 26 `RecognizeDocumentsRequest`；OCR 专用预处理档 + 自动重 OCR |
| 产品决策 | B/C 档从 UI 下架（实现保留） |
| 测试闭环 | 新增端到端断言（图片 → parse → docx → `w:tbl`）、真机烂图 fixture、数据安全回归网 |

### 已修（2026-09-12 第二轮 · 真机反馈）

| 类别 | 内容 |
| --- | --- |
| **取景虚线框对不上书的边框** | 视频帧连接与 `CIImage.oriented` **转了两次**（预览只转一次）→ 帧变横向、`FrameMapper` 算出 3.86 倍水平拉伸、框被推到屏幕外。旋转收敛到 `emit` 一处 |
| **还原左右栏逐行交错** | `OnDeviceReadingOrder` 的段落聚类与最终全局排序都假设单栏。新增 `PageColumnSplitter` 按栏切分、栏内排序、栏间按栏序拼 |
| **正文里的照片整个丢失** | 几何的「空白连通域」**区分不了照片和白纸**（实测整页空白连成面积 0.905 的一整块）。新增 `InkFigureDetector` 读像素找墨块，用「是否被 OCR 文字盒覆盖」做主判据 |
| **练习册选项句被当成链接** | `"stopped / was stopping working."` 含 `.` 和 `/` → 被判成 URL 降级成条码块。真 URL 的判据改为**不含空白** |
| **短行被排到整段之后** | `readingOrder` 的「同一视觉行」容差 0.03 比教材行距还大 → 改成严格按 y 排 |

### 已修（2026-09-08）

- **OCR 跑在未矫正的原图上**：已改为 rendered 优先。指纹：关掉「保留原图」反而更好。
- **OCR 噪声过滤**：`Domain/OCRNoiseFilter.swift`（状态栏 / UI chrome 丢弃，QR URL 降级）。
- **配图把整块文字区当图**：`FigureRegionsV2` 重写为网格 flood fill + `maxArea` 闸门。
- **A/B/C 切换无反应**：`setTier()` 切档清 `docxURL`。

---

## 后续方向（摘要）

| 优先级 | 内容 |
| --- | --- |
| **P0** | 真机验证 iOS 26 通路的表格质量（模拟器已验证结构，真机未验） |
| **P1** | 几何兜底补降级阶梯（anchor → 通用数字列 → v1）：老系统仍出不了真机表 |
| **P2** | DOCX 表格样式（`w:tblPr` / 表头加粗 / 数值右对齐）；`w:tblGrid`；合并单元格 `gridSpan`/`vMerge` |
| **P3** | UI 线程与内存：`LibraryViewModel.reload` 全表加载 + N+1 + 全目录遍历；`ReviewViewModel.save` 全量驻留内存 |
| **P4** | 接通云解析（TextIn）；手写 / 勾选识别 |

详细排期与任务拆解见 [docs/09-project-handbook.md §7](docs/09-project-handbook.md#7-后续优化方向)。

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
