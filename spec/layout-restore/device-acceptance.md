# 真机自验清单（layout-restore · device acceptance）

> 自动化已证明的（SC-004）：全量 **212 passed + 1 expected failure（known issue）+ 0 failed**
> （T032 检查点，日志 `/tmp/layout-restore-logs/T032-checkpoint.log`）。
> 本清单只覆盖**必须真机 + 肉眼 + Word** 的部分：SC-001 / SC-002 / SC-003 / SC-005。
> SC-006（还原不阻塞 UI、切档瞬时）在下列每项操作中顺带观察，不单列。

## 准备

- 真机一台（iOS 18+；表格结构识别 iOS 26 走 `RecognizeDocumentsRequest`，18~25 走 `TableGridV2`）。
- 电脑装有 **Microsoft Word 2016+ / Microsoft 365**（OOXML 浮动对象渲染最标准；WPS/Pages 可作参考但以 Word 为准）。
- Console.app 连接真机（日志抓取见文末），或终端 `log stream`。
- 建议先跑内置样张热身：`docs/fixtures/images/nutrition-mango.jpg`（隔屏翻拍或打印后实拍均可）。

## SC-001 实拍「二维码 + 图片 + 艺术字」页

**拍什么**：一张同时含**二维码、图片、艺术字**（logo / 海报字 / 花体标题）的页面——
杂志页、包装盒、海报都行。

**步骤**：扫描 → 整理（拖角校正）→ 还原。预览默认即「版面还原」档。

**通过标准**：

1. 预览中二维码**恰好出现 1 个**——不多（figure↔barcode 交叉去重）、不少（码不丢）；
2. 图片位于原图位置，无漂移、无拉伸变形（保留区 srcRect 原像素透出）；
3. 艺术字区域**无乱码文本块**——原像素保留，OCR 乱码行已被剔除进 `.artwork`；
4. 正文干净重排：覆盖矩形盖住原字迹，无残影、无露馅。

**对照日志**：`dedup figures … barcodes …`（去重后 barcodes 应等于实际码数）、
`artwork candidateLines=… confirmed=…`（艺术字区域 confirmed ≥ 1）、
`mask rectCount=… fillRGB=…`。

## SC-002 Word 打开对比预览

**拍什么**：含**表格 + 正文**的页面（营养表 / 课表 / 价目表）。

**步骤**：版面还原档下导出 DOCX → AirDrop / 文件传到电脑 → Word 打开，与手机预览**并排对比**。

**通过标准**：

1. Word 页面宽高比 ≈ 原图（动态 sectPr），底图铺满整页、无白边；
2. 版面与预览一致：文字、图片、表格都在原位，目视无错位（同一 `PageLayoutMapper` 输出）；
3. 点击任意文字 → 光标进入**可编辑**段落（浮动文本框内是真实 `w:p`，FR-007）；
4. 表格位于原位（原生浮动表格 `w:tblpPr`），行列内容完整、可编辑单元格；
5. 文件正常打开——无「内容有问题」修复提示（控制字符清洗不回归）。

**对照日志**：`tier=…`、`baseImage=… pixels=…`。

## SC-003 双栏教材夹具对照

**拍什么**：**双栏排版**的教材 / 杂志内页（左右两栏、中间 gutter）。

**步骤**：版面还原档预览，与原页并排对照。

**通过标准**：

1. 元素位置与原页目视一致（偏差在容差内）；
2. **无竖排堆叠**——块不会全挤成一列；
3. **无跨栏错位**——左栏文本不会落到右栏位置；
4. 正文覆盖矩形不越过栏界盖到另一栏（mask 外扩仅 1.5%）。

说明：版面还原档按块 bbox 原位渲染，阅读序错误不再致命（位置固定），但分栏几何
正确性以本项为准。

## SC-005 纯文本页双档对比不劣化

**拍什么**：一页**纯文本**（无图无表——书页 / 打印文档）。

**步骤**：同一页在「版面还原」与「结构化」两档间**来回切换**对比。

**通过标准**：

1. 切档**瞬时**（复用同一次 parse 产物，无重新识别的转圈，顺带验 SC-006）；
2. 版面还原档**无多余图片块**（纯文本页不该出现 figure / artwork 块）；
3. 文本位置、字号观感**不劣于**结构化档（字号 = 页高 × 1.8% × relativeFontSize）；
4. 无版面劣化：无成片空白、无文字重叠、无覆盖矩形色差露馅。

**对照日志**：`baseImage=…`（应非 missing）、`mask rectCount=…`。

## 日志抓取指引（ZhixiaLog.reconstruct）

版面还原链路日志走 os_log：subsystem `com.david.Zhixia`、category `reconstruct`、
级别 **debug**（默认不显示，必须开 debug）。

**Console.app**：

1. 真机连线 → Console.app 选中设备；
2. 搜索框输入：`subsystem:com.david.Zhixia category:reconstruct`；
3. 菜单 **Action → Include Debug Messages** 勾上（否则一条都看不到）；
4. 复现操作，实时滚动；选中行可拷贝存档。

**命令行**：

```bash
# 实时跟踪
log stream --debug --predicate 'subsystem == "com.david.Zhixia" AND category == "reconstruct"'

# 复现后离线拉取最近 10 分钟
log collect --last 10m --output /tmp/zhixia.logarchive
log show /tmp/zhixia.logarchive --debug \
  --predicate 'subsystem == "com.david.Zhixia" AND category == "reconstruct"'
```

**关注字段**：

| 日志 | 含义 | 异常表现 |
|---|---|---|
| `tier=<档> isDefault=<bool>` | 当前档位 | 与界面选择不一致 |
| `baseImage=<路径> pixels=<W>x<H>` | 底座注入 | `baseImage=missing fallback=whiteCanvas` → 预览退化白底（查 PageFileStore rendered 图） |
| `mask rectCount=<N> fillRGB=<r>,<g>,<b>` | 覆盖矩形数 + 首个采样色 | `rectCount=0` 但预览有残影；fillRGB 与纸色差异大 → 环带采样异常 |
| `artwork candidateLines=<N> inkEvidence=<N> confirmed=<N> lowestConfidence=<x.xxx>` | 乱码判定双门控 | `confirmed=0` 但预览有明显乱码块（阈值过紧）；正常文本页 `confirmed` 应为 0（过松则误杀） |
| `dedup figures <前>→<后> barcodes <前>→<后>` | 条码单份去重 | 去重后 barcodes ≠ 实际码数（漏检或误删） |

## 结果记录

每项验完打勾并注明环境：

| 项 | 结果 | 设备 / iOS / Word 版本 | 备注 |
|---|---|---|---|
| SC-001 | ☐ 通过 / ☐ 不通过 | | |
| SC-002 | ☐ 通过 / ☐ 不通过 | | |
| SC-003 | ☐ 通过 / ☐ 不通过 | | |
| SC-005 | ☐ 通过 / ☐ 不通过 | | |
