# 纸匣 Zhixia

把纸上的东西，干净地收进这台 iPhone。

对标全能扫描王的**主体能力**：拍照取景、自动框边、透视拉正、增强、连续多页、证件、OCR、版面还原（本机）、导出 PDF / Word / 分享。不做广告、不做账号墙——扫描与「文本」全程本机；「还原」当前也是本机启发式，云解析（TextIn）只留了未接线的 stub。

| 项 | 值 |
| --- | --- |
| 工程 | [`Zhixia.xcodeproj`](Zhixia.xcodeproj) · Scheme `Zhixia` |
| Bundle ID | `com.david.Zhixia` |
| 系统 / 语言 | iOS 18+ · Swift 6 |
| 设备 | 仅 iPhone（竖屏） |

---

## 新人 30 分钟接手

1. 读本文 + [docs/00-getting-started.md](docs/00-getting-started.md)
2. 按需深入：[01 产品](docs/01-product-prototype.md) → [02 架构](docs/02-architecture.md) → [06 版面还原](docs/06-document-reconstruction.md)
3. 打开工程，真机跑主路径；模拟器可用相册导入走「理 / 出 / 还原」

```bash
cd scantool
open Zhixia.xcodeproj
# 测试（示例模拟器 id 以本机为准）
xcodebuild -project Zhixia.xcodeproj -scheme Zhixia \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS="-disable-sandbox" test
```

> ⚠️ **macOS 26.6 + Xcode 26.4 必须加 `OTHER_SWIFT_FLAGS="-disable-sandbox"`**，否则所有 Swift 宏
> （SwiftData `@Model` / Observation `@Observable` / swift-testing `@Test`）都会报
> `swift-plugin-server produced malformed response` 而构建失败。
> 根因是编译器给宏插件套的 `sandbox-exec` 在本系统申请失败（`sandbox_apply: Operation not permitted`）。
> 与 Xcode 装在哪个卷无关，详见 [docs/00-getting-started.md §7](docs/00-getting-started.md#7-怎么测)。

```
Zhixia/          App · Features · Domain · Services · DesignSystem
ZhixiaTests/     Smoother · Store · Capture/Review/OCR VM · Reconstruct · 图像管线
docs/            产品 / 架构 / 选型 / 原理 / 路线图 / 版面还原 / 接手指南
prototype/       可交互界面原型
```

---

## 设计文档

| 文档 | 内容 |
| --- | --- |
| [docs/00-getting-started.md](docs/00-getting-started.md) | **接手指南**：目录地图、主路径、改哪里、怎么测 |
| [docs/01-product-prototype.md](docs/01-product-prototype.md) | 产品原型：场景、信息架构、主路径、视觉 |
| [docs/02-architecture.md](docs/02-architecture.md) | 分层、模块、数据流、工程结构（与代码对齐） |
| [docs/03-tech-choices.md](docs/03-tech-choices.md) | 技术选型与取舍 |
| [docs/04-implementation-principles.md](docs/04-implementation-principles.md) | 几何 / 管线 / 并发 / 落盘 / 编码规矩 |
| [docs/05-roadmap.md](docs/05-roadmap.md) | 里程碑现状与后续 |
| [docs/06-document-reconstruction.md](docs/06-document-reconstruction.md) | 版面还原：IR、本机 R2、TextIn stub、**已知问题** |
| [docs/07-reconstruct-r2-optimization.md](docs/07-reconstruct-r2-optimization.md) | **R2 优化方案**：原型 / 架构 / 选型 / 原理 / 阻碍 / 计划 / 路线图 + 实测数据 |
| [docs/fixtures/README.md](docs/fixtures/README.md) | 样张 OCR 夹具：怎么导、怎么生成、保真度说明 |
| [prototype/index.html](prototype/index.html) | 可交互界面原型 |

图：[分层](docs/diagrams/layers.svg) · [扫描管线](docs/diagrams/pipeline.svg) · [模块关系](docs/diagrams/modules.svg)

---

## 产品承诺

1. **操作简单**：主路径「对着纸 → 快门 → 完成 → 保存」。
2. **界面好看**：纸色画布 + 朱砂主操作。
3. **架构干净**：Feature 不碰 `AVCaptureSession` / `CIFilter`；图像处理进 actor；元数据与文件分离。
4. **双通路文字**：详情「文本」= 本机 OCR 复制；「还原」= 排版 IR → Word / 可检索 PDF（仍本机，不默认上传）。

详情底栏：`文本 | 还原 | 分享 | 加页`。

---

## 能力现状（2026-09）

| 能力 | 状态 |
| --- | --- |
| 取景 / 实时框 / 连拍 / 相册导入 | 已落地 |
| 整理：拖角、五档滤镜、保存入库 | 已落地 |
| 库：文件夹、搜索、收藏、加页 | 已落地 |
| OCR「文本」、图片 PDF 分享 | 已落地 |
| 证件模式比例窗 | 已落地 |
| 还原：段落阅读序 → DOCX / 可检索 PDF | 已落地（R1） |
| 还原：本机表聚类、配图空洞、条码裁切 | **已接线，样张未过关**（见下） |
| TextIn / 云版面解析 | stub，无密钥、无网络实现 |

---

## 已知问题（还原样张）

用练习册 + 营养成分表两张样张走「还原 → 导出 Word」：

- **生成的 Word 更像「重排文档」**，没有还原成接近原图的版式。
- **练习册**：配图大多缺失，往往只出二维码，且位置不对。
- **营养表**：真网格经常出不来，样式不对（仍偏竖排段落或结构错乱）。

根因与改法见 [docs/06-document-reconstruction.md §已知问题](docs/06-document-reconstruction.md#12-已知问题2026-09)。接手还原请先读该节，再改 `OnDeviceTableCluster` / `OnDeviceFigureRegions` / `DocxExportService`。

**已实测定位（2026-09-07，M0 夹具）**，详见 [docs/07 §1.4](docs/07-reconstruct-r2-optimization.md#14-实测数据m0-夹具2026-09-07)：

| 样张 | 场景路由 | 表格 | 配图 |
| --- | --- | --- | --- |
| 营养表 | `.table` ✓ | **`detect → nil`**（无 `w:tbl`）：包装说明短行混进 `isCell`，列中心被带偏到 `[0.185, 0.378, 0.662]`（真值 `[0.175, 0.505, 0.815]`） | **0 个** |
| 练习册 | **`.table`** ✗（应 `.exam`，被 `looksLikeGrid` 抢判） | **7×2 假表**（A/B/C 被聚类） | **0 个** |

夹具与测试：`docs/fixtures/` + `ZhixiaTests/ReconstructV2Fixtures.swift` / `ReconstructV2Tests.swift`，
工具链见 `Tools/ocr-dump/`。
