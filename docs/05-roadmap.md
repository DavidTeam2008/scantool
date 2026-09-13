# 05 落地线路图

原则：先拍下一张干净的纸，再连拍入库，再 OCR / 证件，再版面还原。
接手：[09 接手手册](09-project-handbook.md) · 上手：[00](00-getting-started.md) · 还原专项：[06](06-document-reconstruction.md)

更新：2026-09-12

---

## 现状总览

扫描主路径（拍 / 理 / 出）与库、OCR、证件、扫描件 PDF **已落地可用**。
版面还原：**iOS 26 已打通 —— `RecognizeDocumentsRequest` 直接给表格行列结构**
（模拟器实测样张读出 7 行 × 3 列，见 [09 §6.2](09-project-handbook.md)）。
**iOS 18~25 仍走几何兜底，真机出不了表** —— 这是当前剩下的卡点。TextIn **仍是 stub**。

```
已完成   扫描主链路 M1–M7；还原 R1 + R2 的 M0~M5；V3.0~V3.4（见下表）
卡住     iOS 18~25 的真机表格；真机验证（模拟器替代不了）
未开始   TextIn 真客户端、勾选/手写识别、VL 修补、云确认 UX
```

| 里程碑 | 状态 | 说明 |
| --- | --- | --- |
| M0 设计冻结 | ✅ 完成 | 01–05 + 原型；06 后续补入 |
| M1 工程壳 | ✅ 完成 | `Zhixia.xcodeproj`、Token、库壳 |
| M2 取景与框 | ✅ 完成 | 自建相机、Smoother、快门 |
| M3 拉正增强整理 | ✅ 完成 | 五档滤镜、拖角、保存 |
| M4 多页相册入库 | ✅ 完成 | 连拍、PhotosPicker、事务落盘 |
| M5 库文件夹搜索 | ✅ 完成 | 文件夹、收藏、标题+OCR 搜 |
| M6 OCR 与扫描 PDF | ✅ 完成 | 「文本」、ShareLink PDF |
| M7 证件与打磨 | ✅ 基本完成 | 证件窗、设置项、中英案 |
| R1 还原段落 Word | ✅ 完成 | 阅读序 → DOCX / 可检索 PDF |
| **R2-M0 样张夹具** | ✅ 完成 | 真实 OCR 固化 |
| **R2-M1 LayoutAnalyzer + IR v2** | ✅ 完成 | band / region / column / anchor / 语义标签 |
| **R2-M2 TableGridV2** | ✅ 样张通过 | 锚点驱动 + 营养表 profile + v1 兜底。**真机未过** |
| **R2-M3 FigureRegionsV2** | ✅ 完成 | 空白连通域 + barcode 通道 |
| **R2-M4 DOCX 三档** | ✅ 完成 | A `wp:inline` / B `wp:anchor` / C `behindDoc` |
| **R2-M5 UI 三档 + 预览分档** | ✅ 完成 | 2026-09-12 补：预览随档位切换 |
| **v3 真机修复** | ✅ 完成 | R1（OCR 吃图）已修 |
| **V3.0 数据安全** | ✅ 完成 | commit 回滚删库、DOCX 控制字符、PDF 越界；回归网 `ExportSafetyTests` |
| **V3.1 iOS 26 结构化识别** | ✅ 完成 | `RecognizeDocumentsRequest` 接进还原链路，几何管线保留为兜底 |
| **V3.2 OCR 预处理档** | ✅ 完成 | `OCRPreprocessor` + 质量不达标自动重跑 |
| **V3.3 端到端闭环** | ✅ 完成 | 图片 → parse → docx 断言 `w:tbl`；真机烂图 fixture 已固化 |
| **V3.4 导出修复 + B/C 下架** | ✅ 完成 | B 档 EMU 单位（差 635 倍）、C 档多页衬底、中文字体声明 |
| R2′ TextIn | ❌ 未开始 | stub only，`parse` 直接 throw |
| R3/R4 | ❌ 未开始 | 试卷模型、勾选、VL |

---

## 下一阶段（建议顺序）

> 完整任务拆解见 [09 接手手册 §7](09-project-handbook.md#7-后续优化方向)。
> 真机根因分析见 [08](08-reconstruct-v3-realworld-fix.md)。

### V3.0 ~ V3.4 — ✅ 已完成（2026-09-12）

| 阶段 | 内容 | 产物 |
| --- | --- | --- |
| **V3.0** | 三个数据安全级缺陷：`commit` 回滚删库 / DOCX 非法控制字符 / PDF 越界插入 | `ExportSafetyTests.swift` |
| **V3.1** | 接入 iOS 26 `RecognizeDocumentsRequest`，几何管线保留为兜底 | `VisionDocumentStructureRecognizer.swift` + `StructuredDocumentPage.swift` |
| **V3.2** | OCR 专用预处理档（`CIDocumentEnhancer` 去阴影 + 灰度 + 锐化）+ 质量不达标自动重跑 | `OCRPreprocessor.swift` |
| **V3.3** | 端到端断言（图片 → parse → docx → `w:tbl`）+ 真机烂图 fixture | `ReconstructEndToEndTests.swift` |
| **V3.4** | B 档 EMU 单位（差 635 倍）/ C 档多页衬底 / 中文字体声明；B/C 档下架 | `DocxExportService.swift`、`R2OutputTier.selectable` |
| **V3.5** | 真机第二轮反馈：取景框双重旋转 / 左右栏交错 / 照片丢失 / 选项句误判链接 | `PageColumnSplitter`、`InkFigureDetector`、`AVCameraSession`、`OCRNoiseFilter` |

> 完整任务拆解与新增内容见 [09 接手手册 §6.7 / §7](09-project-handbook.md#7-后续优化方向)。

---

## 下一阶段

### P0 · 真机验证（🔴 最优先，模拟器替代不了）

0. 取景虚线框（本轮改成「旋转只做一次」）—— 必须真机确认框与书边贴合。
1. iOS 26 结构化通路真机跑营养表 / 练习册，导出 Word 看 `w:tbl` 与单元格内容。
2. 拍一张**有阴影**的纸，对比开/关 OCR 预处理档的「文本」结果。
3. 条码裁图 —— 模拟器上 `VNDetectBarcodesRequest` 恒为 0，只能真机验。

### P1 · 老系统兜底

4. 表格降级阶梯：anchor → 通用数字列（≥3 行 × ≥2 列 + 数字密度）→ v1 兜底。
5. 列/行切分改 x/y 投影找 gutter，摆脱「每 cell 一个 OCR line」假设。
6. 文档区域二次分割（`DocumentMaskQuad` 已预埋但无调用者）。

### P2 · 导出层

7. A 档补 `w:tblPr` 样式（边框、表头底纹）+ 表头加粗 + 数值列右对齐。
8. `w:tblGrid`；合并单元格 `gridSpan` / `vMerge`（结构化通路已给出 `rowRange`/`columnRange`）。
9. C 档衬底改用**页面原图**（现在是「本页最大的 figure」，与预览不一致）。

### P3 · 工程债

10. `LibraryViewModel.reload` 全表加载 + 关系 N+1 + 全目录遍历。
11. `ReviewViewModel.save` 全量驻留内存；`PageFileStore.commit` 签名强制全量。
12. `SwiftDataDocumentStore` 零测试 + 无迁移方案。
13. Review「返回」泄漏 tmp 会话目录；建库失败静默降级内存库。

### P4 · 云与模型

14. **接通 TextIn**（低置信 block 走 `ReconstructRepairing`，禁止整页 LLM 重打表数字）。
15. 手写 / 勾选识别。

---

## 验收标准（还原）

用两张样张 + 真机实拍各走一遍「还原 → 导出 Word」：

| 项 | 当前 | 目标 |
| --- | --- | --- |
| 营养表 `w:tbl`（iOS 26） | 样张 1（模拟器实测 7×3）✅ / **真机未验** | 真机 ≥ 1 |
| 营养表 `w:tbl`（iOS 18~25） | 样张 1 / **真机 0**（`withKnownIssue` 钉住） | 也 ≥ 1 |
| 营养表 6×3 结构 | iOS 26 ✅（模拟器）/ 老系统仅样张 ✅ | 两档都对 |
| 练习册假表 | 无 ✅ | 保持 |
| 练习册配图 | 能出但质量差 | 题图出齐、不含满屏文字块 |
| OCR 预处理档 | 已接线，未真机验 | 阴影场景字准率明显提升 |
| B / C 档 | **已从 UI 下架** | 等检测层稳定再评估 |
| 状态栏 / UI chrome / QR URL | 已过滤 ✅ | 保持 |

---

## 历史周计划（归档）

原 M1–M7 约 6.5–7 周估算已执行完毕，细节保留作背景：

```
W1     工程 + Token + 空库
W2–W3  相机 + 实时框
W3–W4  透视、滤镜、整理
W4–W5  连拍、相册、SwiftData
W5     文件夹 / 搜索
W6     OCR + 扫描 PDF
W7     证件、无障碍、画质对照
之后   还原 R1 → 本机 R2 →（可选）云
```

---

## 本阶段仍不做

- 账号、默认云盘、广告、会员墙
- 微信 / 钉钉 SDK
- 签名、批注、水印
- 名片入通讯录、证照字段结构化
- 书籍跨页拼接、二维码主入口
- iPad 分栏、文档提供器
- TCA
- 点「文本」上传

v2 候选：批注签名、iCloud、Spotlight、小组件「继续扫」。

---

## 真机清单（持续）

| 场景 | 期望 | 当前 |
| --- | --- | --- |
| 日光 A4 | 框稳，增强可读 | ✅ |
| 台灯反光 | 可手拍，去阴影有改善 | ✅ |
| 连拍 10 页 | 不爆内存，扫描 PDF 可开 | ✅ |
| 身份证 | 窗对齐，两页 | ✅ |
| 相册导入 | 能检出或整张可裁 | ✅ |
| 中文合同 OCR | 「文本」可复制，库可搜 | ✅ |
| **练习册 / 营养表还原** | 结构正确、可读 | ❌ **未达可用** → V3.0~V3.2 |
| **B / C 档预览** | 位置对齐、视觉可用 | ❌ **效果差** → 依赖 V3.2 |
| 拒绝相机 | 去设置，不白屏 | ✅ |
