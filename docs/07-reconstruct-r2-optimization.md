# 纸匣 Zhixia · 「还原 → 导出 Word」R2 优化方案

> 目标：让练习册、营养成分表这一类样张在「还原 → 导出 Word」上的产物质感，从当前的「重排文档」跨到「结构正确、版式稳定、配图齐全、表格真实的可编辑 Word」。
> 适用范围：`$HOME/Documents/code/ios/scantool/`（Zhixia 工程）。
> 阅读对象：本工程接手还原的工程师 + 产品 + 设计。
> 更新：2026-09-07（基于现有实现与两张样张）
>
> **历史归档（2026-10-29 标注）**：R2 方案已由 [`08` v3 真机修复](08-reconstruct-v3-realworld-fix.md)
> 与 [`spec/word-fidelity/`](../spec/word-fidelity/) 取代；当前还原链现状以
> [`06`](06-document-reconstruction.md) + [`16` Word 保真](16-word-export-fidelity.md) 为准。

---

## 0. 阅读路径与摘要

| 你是 | 该读 |
| --- | --- |
| 第一次了解这件事 | §1 现状与失败现象 → §2 优化目标 → §10 路线图（只看头尾） |
| 工程师要改代码 | §1 → §3 架构 → §5 实现原理 → §6 阻碍点 → §7 落地计划 |
| 产品 / 设计 | §1 → §3 原型 → §2.3 三档产物 → §10 路线图 |
| 安全 / 隐私 | §3 选型 → §6 阻碍（合规）→ §7 落地（默认策略） |

**摘要一句话**：把当前的「文本+启发式」单管线，重构成「版面分析 → 块映射 → IR → 锚点式导出」的多阶段分层管线；本机为主、可选 ML / 云接口、产物分级，绝不靠整页截图冒充 Word。

---

## 1. 现状问题深度分析（基于样张与代码）

### 1.1 两张样张的逐条失败现象

#### A. 练习册 Test 4 Questions 1~5（IMG_7477 / 7483）

| # | 现象 | 用户能看出 | 真值 | 期望产物 |
| --- | --- | --- | --- | --- |
| A1 | 「20:14C」「`<1t or you 更多`」开头 | 行序乱 | 这是左下角小注释、页眉被提前抓取 | 排到末尾或丢弃 |
| A2 | 「Lemce」「1for you」「JWCessome CAKSS」 | OCR 错 | 手写体识别不到，文本被粘连 | 保留手写空为「笔迹占位」而不是塞错字 |
| A3 | 「A 口」「B 口」（A/B/C 选项字母被替换为「口」） | OCR 字符替换 | 选项字母 A/B/C 被识别成口字符 | 选项字母按 A/B/C 锚定，题图按相对位置插入 |
| A4 | 「https://qrcode.5rs.me/…」出现在文本流 | 把二维码当成文字 | 条码检测成功了，但 payload 字符串被 OCR 再认了一遍 | payload 只在图注显示，绝不进段落 |
| A5 | 配图几乎没有 | 看不到图 | 非文字空洞连通域被文字盒膨胀掩码切碎 | 每题（A/B/C 区域）至少能拿出 1 张图 |
| A6 | 阅读序按 Y 排序，多栏布局错位 | 段顺序乱 | 单栏 + 题下图的左右并行被打散 | 同一 Y 范围内的左右分别成段 |
| A7 | 没有识别「Question 1 / Question 2 / Question 3」分段 | 段落散 | 这是版面的语义结构 | 区块级标题 + 段 |

#### B. 营养成分表（IMG_7480 / 7481 / 7482）

| # | 现象 | 用户能看出 | 真值 | 期望产物 |
| --- | --- | --- | --- | --- |
| B1 | 「项目」「营养成分表」「每 100 克」三个表头单独一行 | 表头被拆 | 表头也在表里，但没识别为同一网格 | 三列同表，表头加粗、整行表头底纹 |
| B2 | 「能量」「1.5 克」「17%」被独立成段 | 单元格散 | 每个数字单独成行 | 「能量 \| 1429 千焦 \| 17%」三列 |
| B3 | 「脂肪」「0.8 克」「1%」相邻却是两条 | 单元格读错 | OCR 把一个数字串拆了 | 跨列错位合并 |
| B4 | 「碳水化合物」冒号被识别成「O」 | OCR 串入错 | 包装袋表面的「词:」式 printed 文本 | 容忍并归并 |
| B5 | 条码图变成纯文字 `6936832529010` | 识别到条码却没保留图 | barcode 已裁了图，但 DOCX 输出落到了另一处甚至丢了 | barcode 作为 figure，payload 作为题注 |
| B6 | 「营养成分表」标题被排进段落流 | 段头散 | 表的标题也算独立块 | 表格前加表头块、表整体独立 |
| B7 | 包装说明全段被一段话截断 | 包装混排 | 配料 / 营养 / 联系方式是不同语义块 | 拆 paragraph 块 |

### 1.2 当前管线失败根因溯源（基于代码）

> 代码位置：`Zhixia/Domain/OnDevice*.swift` 与 `Zhixia/Services/Reconstruct/OnDeviceDocumentParser.swift`。

| # | 文件 / 函数 | 当前行为 | 失败根因 |
| --- | --- | --- | --- |
| R1 | `OnDeviceDocumentParser.parse` | 文本 → 表 → 阅读序 → 图 → 条码 → 按 `maxY` 排序 | 排序是「整页自顶向下」，对多栏 / 图文左右并行的样张天然不友好；图与条码共用 `figure` 通道，顺序被混 |
| R2 | `OnDeviceTableCluster.detect` | `maxGap: 0.11` 列聚类，`maxGap: 0.032` 行聚类，要求 `2..5 × ≥3`，occupancy ≥ 0.45 | 阈值硬；营养表中多个短文本行间距可能 0.04，会跨列；列聚类 `maxGap` 过小，**同列稍偏就分两列** |
| R3 | `OnDeviceTableCluster.focus` | 找「营养成分表」/「NRV」锚点，取锚点下方 0.02 内的 cell | 实际样张中「营养成分表」一句话横跨 0.6 宽度，box 不一定在同一 Y；多页包装时锚点会找错位置 |
| R4 | `OnDeviceTableCluster.looksLikeDataTable` | 拒绝「单字母占比 > 0.45」 | 营养表行都是「汉字 + 数字 + 单位」，看起来 OK；但下列两类被拒：① 多列里单字符（如「钠」一行只有「钠」+「49」+「毫克」）② 列里有大段长文本 |
| R5 | `OnDeviceFigureRegions.boxes` | 36×48 栅格，文字 + 已占区 inset 0.018 取反 | 栅格粗，inset 把零碎文字连成大块，**把图压扁**；连通域易把「题间空白」识别为 figure；条码 box 也算 occupied，反而把 figure 切掉 |
| R6 | `OnDeviceFigureRegions.isUseful` | area ∈ [0.012, 0.42]，fill ≥ 0.55 | fill 阈值对狭长题图不友好；aspect 0.2 ~ 5 太宽，条形配图被拒 |
| R7 | `OnDeviceReadingOrder.makeBlocks` | 按 `minY` 聚类为行 → 段 | 单栏可用，但页眉、页脚、注释都按 Y 顺序进来了；不区分主栏和侧栏 |
| R8 | `DocxExportService` | 段落 + `w:tbl` + 图片 `wp:inline` | ① 列宽固定 `9000 / n`（缺列宽自适应）；② 图片只用原像素 EMU，**忽略原图 bbox 比例**；③ 没有 `w:positionH/V`，无法粗略对齐页心 |
| R9 | `ReconstructSceneRouter.route` | 用整页 `joinedText` 关键词判场景 | 把 QR / 包装 / 表格混进同一 joinedText，路由**易冲突**；同样键入「营养成分表」的题头练习册会被误判成 table |
| R10 | `CompositeDocumentParser` | 无 key 时直接本地，`cloud.parse` 抛 `reconstructCloudUnavailable` | 「云通路」只是协议 stub，没真正打通 → R2 阶段仍像本地单跑 |
| R11 | `OnDeviceDocumentParser` 出口用 `bbox.maxY` 排序 | 整页单列 | 跨栏样张（练习册 A/B/C 题下并排图）按 Y 排序会把图折断 |

### 1.3 现有架构的天花板

- **IR 字段不完整**：`ReconstructBlock` 只有 bbox/text/table/path，**没有「语义标签」**（题号、选项字母、表头单元格、图题），下游无法做基于语义的合并/重排。
- **OCR 假定行级别准确**：Vision 给出的是字符级 + 行级 box，**没有段落、区域、文本块**概念，重排完全靠几何重建。
- **图片来源单一**：裁配图只走 original + 文字 box 外侧空洞，**没考虑图像显著性 / 边缘密度**。
- **DOCX 只有流式 block**：缺锚点定位（`w:position*`、`w:framePr`）→ 无法实现粗略版面还原。
- **云通路协议占位**：协议有但实现零，R2 阶段没为「真接通」打好基础。
- **单测夹具是合成 bbox**：`ReconstructTests.swift` 用 `CGRect` 造数据，绿了不代表样张绿（项目自评）。

---

## 1.4 实测数据（M0 夹具，2026-09-07）

M0 已把两张样张的真实 OCR 固化为夹具，并用**工程里现役的 `OnDevice*` 算法**跑了一遍，
上面 R1–R11 的推断全部得到验证，且部分比文档描述更糟。

复现方式：

```bash
swift Tools/ocr-dump/main.swift docs/fixtures/images/*.jpg --out docs/fixtures
python3 Tools/ocr-dump/gen_fixtures.py
python3 Tools/ocr-dump/verify_tests.py     # 免 Xcode 的断言校验
```

### 样张

| 样张 | 原图 | 尺寸 | OCR 行数 |
| --- | --- | --- | --- |
| 营养成分表（小象超市芒果干） | `docs/fixtures/images/nutrition-mango.jpg` | 869×1024 | 34 |
| 练习册 Test 4 Questions 1~5 | `docs/fixtures/images/workbook-test4.jpg` | 844×1076 | 48 |

> 用户给的 `IMG_7477/7479/7480/7481/7482/7483.PNG` 全是 **App 截图**（1170×2532，
> 含「还原版面 / 导出 Word」等 UI 文字），不适合当 OCR 输入，M0 未采用，只作现象佐证。

### 实测结果

| 样张 | 场景路由 | `TableCluster.detect` | `FigureRegions.boxes` | `isCell` 通过 |
| --- | --- | --- | --- | --- |
| 营养表 | `.table` ✓ | **`nil`** ✗（→ 导出无 `w:tbl`） | **0 个** ✗ | 26/34 |
| 练习册 | **`.table`** ✗（应 `.exam`） | **7×2 假表** ✗ | **0 个** ✗ | 33/48 |

### 逐条溯源（含此前未记录的发现）

**营养表为什么 `detect` 返回 nil**

1. `isCell` 只挡「宽度 < 0.35 且长度 ≤ 28」，包装说明里的短行全部放行：
   `2026/07/15`、`小象超市`、`自有品牌`、`芒果干`、`产地：广西省南宁市`、
   `6 936832 529010` → 26/34 混入候选。
2. 这些噪声把列聚类带偏。实测列中心 = `[0.185, 0.378, 0.662]`，
   而真值（人工从原图量取）≈ `[0.175, 0.505, 0.815]` —— **第 2、3 列完全错位**。
3. 行聚类只得到 5 行（真值 6 行），`occupancy` 与 `looksLikeDataTable` 随后放弃 → `nil`。
4. 于是表格内容全落到 `ReadingOrder`，被拍成一段：
   `项目每 100克NRV% ⏎ 能量1429 千焦17% ⏎ 蛋白质1.5克3% …`
   与截图里「每 100 克 / 1429 千焦 / 17% 各占一段」完全吻合。

**练习册为什么被聚成假表**

1. `ReconstructSceneRouter.route` 里 `looksLikeGrid` 排在 `looksLikeExam` **之前**，
   练习册 48 行里数字行远超 6 行 → 抢先判成 `.table`（真值 `.exam`）。（R9）
2. 判成 table 后走表格启发式，A/B/C 三个单字母与 `£30/£55/£75` 被聚成 **7 行 × 2 列假表**，
   单元格形如 `A`、`B C`、`£30 A` —— 正是 docs/06 §12.4 点名「回归时不要破坏」的那条。
3. `FigureRegions` 返回 **0 个**候选 → 截图里「只出二维码、题图全丢」的直接原因。

**新发现：阅读序同带阈值 bug（此前文档未记录）**

- Section 1 `y=0.8337`、Section 2 `y=0.8160`，`minY` 差 **0.0176**，
  小于 `clusterRows` 的 ±0.02 同带阈值 → 被当成同一行 → 再按 `minX` 排序 →
  **Section 2（x=0.1047）排到了 Section 1（x=0.1097）前面**。
- 右上角页眉 `Test 4`（`y=0.962`）抢占了首个标题块，
  真正标题 `Test 4 Questions 1~5（LP1-T4:Q1~3）` 被挤到第二块。

> 这两条解释了截图 A1「20:14C 之类的页眉出现在正文之前」的成因，
> 根因是**同带阈值取绝对值而非相对行高**，与 A1 之前归给「排序」的粗判不同，M0 已定位到具体阈值。

### 夹具与测试

- `ZhixiaTests/ReconstructV2Fixtures.swift` —— 真实 OCR（82 行）+ 人工标注的 ground truth
  （营养表 6×3 网格、三列真实中心 x、A/B/C 选项字母）。
- `ZhixiaTests/ReconstructV2Tests.swift` —— 15 个测试，8 处已知失败用 `withKnownIssue` 包住：
  套件保持绿色，一旦 M1~M5 修好对应问题，该测试会**反向失败**，提醒移除包装。

---

## 2. 优化目标与产品定位

### 2.1 总目标

> 「还原」产物的用户体感从「能复制一份文本到 Word」升级为「导出的 Word 结构与原图版式高度接近、表格与配图齐整、手写可保留为占位、空错可见可补」。

### 2.2 三档产物（核心产品定位）

R2 不再追求「Word 等于打印级 WYSIWYG」，而是提供**三档可选产物**，用户按场景选：

| 档位 | 名称 | 实现 | 适用 | 用户入口 |
| --- | --- | --- | --- | --- |
| **R2-A** | 结构化文档 | IR → OCR 块 → 表格 → 段落流 → 嵌图（粗略锚点） | 90% 场景：练习册、营养表、合同、讲义 | 默认 |
| **R2-B** | 还原重排版 | IR → 段落 / 双栏 / 表格 / 块级锚点 DOCX（`w:position*` 近似） | 试卷、看板、表格密集 | 切换 |
| **R2-C** | 印刷级复刻 | 整页衬底图 + 文字层（透明 Word 框） | 设计稿、包装画、对版要求极高 | 切换 + 二次校对 |

**R2-A 是默认；R2-B 是优化；R2-C 是兜底**。一句话告诉用户：

> 「还原后的 Word 不是打印级复刻，但表格与图都齐了；需要更接近原图的可切到『重排版』或『衬底图』。」

### 2.3 验收硬性标准（两张样张上必须达到）

| 样张 | R2-A 必达 | R2-B 必达 | R2-C |
| --- | --- | --- | --- |
| 练习册 | A/B/C 题图至少各有 1 个 figure block；二维码 figure 不抢占名额；题号与题干对齐；阅读序不出现 20:14C 这种页眉 | 左右栏分清楚；图按 Y/X 锚点；段落 indent 正确 | 用户确认后出一页衬底图 + 文本层，**导出物明示是衬底方案** |
| 营养成分表 | 表格是 `w:tbl`，三列；「能量 \| 1429 千焦 \| 17%」同 row；表头加粗 | 整张表精确列宽，header 单独行底纹；包装说明独立段 | 同上 |

### 2.4 不做（明确）

- 还原的 IR 默认本机解析，**不上传**。
- 「文本」页与本机 OCR 行为不变。
- 整页截图改后缀冒充 Word（明确禁止，见 `docs/06-document-reconstruction.md §11`）。
- 默认强制接云。R2 让云可选，且**必须用户在该页主动确认**。
- 不做 OpenCV / 自训 LayoutLM 当 v1 主路径。

---

## 3. 原型设计（UI / UX）

> 这一节给设计稿的 wireframe 与交互流，覆盖「还原页」「场景识别预览」「修复提示」「导出档位切换」。

### 3.1 还原页信息架构改造

进入还原页（由详情底栏进）后的状态机：

```
         ┌──── 本机解析 ────┐ ok       ┌─────────────┐
 start ──┤                 ├─────────►│  预览 + 导出 │
         └──── 失败 ──────┘          └─────────────┘
                │                         │
                ▼ retry 仍失败            ▼ 用户改档 / 修复
        ┌──────────────────┐         ┌──────────────┐
        │ 失败空态 + 提示   │         │ 编辑修复面板  │
        │ - 建议重拍        │         │ - 改场景      │
        │ - 上传此页用云解析 │         │ - 改选择图    │
        └──────────────────┘         └──────────────┘
```

### 3.2 关键界面（线框图 + 重点说明）

#### 3.2.1 还原页（成功）

```
┌ 〈 文档 · 还原版                      … ┐
│  本机解析完成 · 未上传                       │
│  ┌───────────────────────────────┐  ┌───┐ │
│  │  原始图                       │  │ 切 │ │
│  │  （拇指缩放）                 │  │ 档 │ │
│  │                               │  └─┬─┘ │
│  │  [Question 1]                 │    │   │
│  │  Boy: Hi Becky. ...           │  ┌─▼─┐ │
│  │  Becky: Of course, and a ...  │  │ ▼ │ │
│  │  A:[pizza图] B:[lemonade图]   │  │ A │ │
│  │  C:[cups图]   [QR]            │  └─▲─┘ │
│  └───────────────────────────────┘    │   │
│  ┌───────────────────────────────┐  ┌─┴─┐ │
│  │  预览（block 流 · 不刷页面）  │  │重试│ │
│  │  Heading 表格 …               │  └───┘ │
│  └───────────────────────────────┘        │
│  导出档位：[A 结构化] [B 重排版] [C 衬底图] │
│  [导出 Word]        [可检索 PDF]           │
└───────────────────────────────────────────┘
```

#### 3.2.2 还原页（失败空态）

```
┌ 〈 还原                              … ┐
│  本机可能仍不准                     │
│                                    │
│  [icon] 没找到表 / 没找到配图     │
│                                    │
│  可能原因：                              │
│  - 纸面光照不足                │
│  - 字号过小 / 倾斜                │
│  - 表的列间距不均              │
│                                    │
│  可以试试：                              │
│  [重新拍一拍]                          │
│  [切换场景 / 手动指定]               │
│  [□ 本页上传到云解析（已加密）]   │
│                                    │
└───────────────────────────────────┘
```

### 3.3 「场景选择」面板

为了让 R2-B / C 档不靠纯几何，而允许用户/算法做出更准确选择：

```
┌ 识别到的场景                       [✕] ┐
│                                       │
│  看起来像  营养成分表  ▼              │
│                                       │
│  ○ 自动                                │
│  ● 营养成分表（表格）               │
│  ○ 试卷 / 练习                         │
│  ○ 包装说明                            │
│  ○ 普通文本                            │
│                                       │
│  提示：选择场景后用对应模板与启发式。 │
│                                       │
│  [ 重跑识别 ]    [ 关闭 ]              │
└───────────────────────────────────┘
```

### 3.4 「修复提示」交互（高级）

> v2 暂做被动提示，不开放手动编辑 IR；留接口 R3 开放。

```
┌ 检测出问题 ……                          ┐
│                                        │
│  - 题目 1 的图未识别                  │
│    [ 把这个区域指定成图 ][ 跳过 ]      │
│  - 表头「每 100 克」被拆               │
│    [ 合并 ][ 跳过 ]                    │
│  - 这段是页脚「20:14C」可丢弃         │
│    [ 丢掉 ][ 保留 ]                    │
│                                        │
│  [ 应用全部 ]                          │
└────────────────────────────────────┘
```

### 3.5 「导出档位」切换 UI

底栏改造为两段：档位 + 导出按钮。

```
[● A 结构化] [ B 重排版 ] [ C 衬底图 ]      ← 三选一
[导出 Word]            [可检索 PDF]        ← 操作行
```

- 选 C 给出免责声明：「导出含本页原图为底图」。
- 选 B 时若 IR 不充分（缺 anchor），提示「重排版可能仍不完美，是否回退 A？」。

### 3.6 文案改动（xcstrings 新增/改）

| Key | Value (zh-Hans) | 用途 |
| --- | --- | --- |
| `reconstruct.docLevel.structured` | 结构化文档 | 档位 A |
| `reconstruct.docLevel.repack` | 重排版（保留版心） | 档位 B |
| `reconstruct.docLevel.backdrop` | 衬底图 + 文字层 | 档位 C |
| `reconstruct.warning.backdrop` | 导出包含本页原图作为衬底，仅供对齐参考 | C 档提示 |
| `reconstruct.fix.detectedIssue` | 检测到 %d 处问题，可以修复或跳过 | 修复面板 |
| `reconstruct.cloud.perPageConfirm` | 本页上传到云解析（含原图），将临时存储。同意？ | 云开关 |

### 3.7 视觉与可达性

- 顶部区域放原图（缩放 / 拖动 / 双指缩放），底部放预览；分屏在 iPhone 竖屏以 tab 切换。
- 还原页顶部加「本机已解析，未上传」态。
- 全部按钮沿用朱砂 `Tokens.seal`；提示用 `Tokens.muted`；问题用 `Tokens.danger`。

---

## 4. 架构设计

### 4.1 总体：从「单管线流」升级为「多阶段分层管线」

```
┌─────────────────────── 还原总管线 v2 ────────────────────────┐
│                                                             │
│   OCR/Vision ─┐                                            │
│   Barcode ────┼─► LayoutAnalyzer ─► BlockIR ─► SceneResolver│
│   Signature ──┘        │                   │                │
│                        ▼                   ▼                │
│                  RegionMap (空/文/图/表) TableMap            │
│                        │                   │                │
│                        ▼                   ▼                │
│              FigureRegioner v2 + AnchorExt  TableFiller v2  │
│                        │                   │                │
│                        └─────► BlockIR ──► DocxRenderer v2 /│
│                                    │       PDFRenderer v2   │
│                                    ▼                        │
│                              Document                       │
└─────────────────────────────────────────────────────────────┘
```

**要点**：

- 「版面分析」与「块填充」分离。
- IR 必须稳定到 block 粒度（不是行），block 含语义标签（题号、选项、表头单元格）。
- 导出器只读 IR，不再各自搞识别。
- 所有识别器（OCR、Barcode、表头抽取、Figure 显著性）走同一个协议，结果合并。

### 4.2 模块图（与代码目录映射）

```
Zhixia/
  Domain/
    Models/
      ReconstructDocument.swift          // IR 含 Scene / Version
      ReconstructBlock.swift             // 新增 anchors、semanticTags
      LayoutAnchors.swift                // 新增：anchor 类型 + bbox 锚点
      SemanticTags.swift                 // 新增：题干/选项/表头/页眉页脚…
    Layout/                              // 新增目录
      LayoutAnalyzer.swift               // 文本 + 显著性 + 边缘密度 → 区域
      RegionMap.swift                    // 空/文/图/表四象
      ColumnResolver.swift               // 多栏感知
      ReadingOrderV2.swift               // 双栏 + 题下并排感知
    Table/
      TableGridDetectorV2.swift          // 投影 + 锚点 + 列对齐
      TableHeaderResolver.swift          // 表头底纹 / 加粗启发式
      NutritionTableProfile.swift        // 营养表专配模板
    Figure/
      FigureRegionSegmenter.swift        // 区域生长 + 显著性
      FigureAnchorAligner.swift          // figure 与题干锚定
    Text/
      HeadingDetector.swift              // 标题检测
      OptionDetector.swift               // A/B/C 选项
      HeaderFooterClassifier.swift       // 丢弃 / 弱化页眉页脚
  Services/Reconstruct/
    OnDeviceDocumentParserV2.swift       // 主路径，组装 Layout + Table + Figure
    CompositeDocumentParserV2.swift      // 本机 + 可选 ML/云（修复）
    LayoutMLRepairer.swift               // 可选：调用 Core ML / 云接口
    ML/
      LayoutFeatureProvider.swift        // 提供特征：边缘密度、显著性图
      (无 ONNX 部署，仅接口)
    DocxExportServiceV2.swift            // 三档产物
    SearchablePDFExportServiceV2.swift   // 三档（图片版可省）
    NormalizedImageCropV2.swift          // 多源裁切（rect/显著性 mask）
    TextInDocumentParser.swift           // 真接通（而不是抛错）
    PageBarcodeDetector.swift            // 沿用 + 区域过滤
    CloudContract.swift                  // 协议：上传单页 base64 / multipart
  Features/Reconstruct/
    ReconstructViewModel.swift           // 持 IR、调度修复、提供档位切换
    ReconstructView.swift                // 三段式布局
    Components/
      DocLevelSwitcher.swift             // 三档切换 UI
      ScenePickerSheet.swift             // 场景选择器
      BlockIssuePanel.swift              // 修复提示面板
      BackdropConfirmSheet.swift         // C 档免责
  App/
    AppEnvironment.swift                 // 注入 V2 服务
```

### 4.3 数据流（重新设计的 IR）

```
ReconstructDocument (v2, Codable 向后兼容)
 ├─ version: 2                              // IR 版本
 ├─ pages: [ReconstructPage v2]
ReconstructPage v2
 ├─ pageID, size, scene, usedCloud
 ├─ anchors: [LayoutAnchor]                 // 关键锚点：栏宽 / 题号点 / 表原点
 ├─ columns: [Column]                        // 主栏/侧栏，可选
 ├─ regions: [Region]                        // 页眉/正文/页脚（可选分类）
 └─ blocks: [ReconstructBlock v2]            // 仍按阅读序；新增 anchors/semantic
ReconstructBlock v2
 ├─ kind, bbox, text, style, table, figureRelativePath, barcodePayload
 ├─ semantic: SemanticTags?                 // [.question, .optionLetter, .tableHeader, .unit, .footer, .handwritingBlank]
 ├─ anchors: [BlockAnchor]                   // 块在版面中的相对锚点
 └─ confidence: Double                      // 块置信度（修补用）
```

### 4.4 关键新协议

```swift
protocol LayoutAnalyzing: Sendable {
    func analyze(imageURL: URL, ocr: OCRPageText, barcodes: [DetectedBarcode])
    async throws -> PageLayout
}

protocol TableGridDetecting: Sendable {
    func detectGrid(in lines: [OCRLine], in: PageLayout) async -> DetectedTable?
}

protocol FigureSegmenting: Sendable {
    func segments(image: CGImage, in: PageLayout) async -> [FigureSegment]
}

protocol DocxRenderingV2: Sendable {
    func makeDocx(_ document: ReconstructDocument,
                  level: DocLevel,
                  fileName: String) async throws -> URL
}

enum DocLevel { case structured, repack, backdrop }
```

### 4.5 与现架构的兼容策略

- 协议 `DocumentParsing` 升级为 V2，但保留旧 `OnDeviceDocumentParser`（标注 deprecated），方便单测期并存。
- IR `version` 字段，docx / pdf 导出器按 version 分支，避免一次升级全炸。
- 单测夹具加 `version: 2`，新 case。
- 详情页与设置页不变；只改 ReconstructViewModel 与 ReconstructView。

---

## 5. 技术选型

### 5.1 选型清单与理由

| 模块 | 选型 | 理由 | 不选 |
| --- | --- | --- | --- |
| OCR | 沿用 `VNRecognizeTextRequest`（accurate） | 本机、稳定、零依赖；本机文字结果仍可信 | 云 OCR 默认（隐私） |
| 条码 | `VNDetectBarcodesRequest` | 现成 | third-party SDK |
| 区域分割（figure） | Core Image `CIDetector`（人脸）+ 自写显著性启发式 | 系统内置，不打包 | OpenCV / SAM |
| 边缘密度 | Core Image `CIEdges` + `CIPercentile` | 系统内置 | Core ML 训练（过度） |
| 多栏感知 | 自写 column resolver | 简单、可解释、可测 | LayoutParser 完整模型（太大） |
| 表识别 | 自写 `TableGridDetectorV2` + 启发式 + 营养表 profile | 营养表专属规则收益大；样式化模板可行 | 端到端 ML |
| DOCX | 沿用自写 OOXML + 加 `w:position*` / `w:framePr` | 已有栈；可控 | 引入 Office SDK |
| 可检索 PDF | 沿用 `UIGraphicsPDFRenderer` + 表格线框 + DrawingML-style 锚点 | 已有栈 | Quartz 全量 |
| ML 接口预留 | Core ML 包装（`LayoutMLRepairer`），默认不开 | R2 接口先行，R3 可换 | 自训 / ONNX（隐私 + 体积） |
| 云解析（可选） | TextIn 真接通 / 自建（OAuth） / 暂缓 | 仅确认页可用；隐私披露改 | 默认上传 |
| 多模态 LLM | 仅 R3 修补低置信块；接口预留 | 数字不稳，不当主识别 | 整页重打 |

### 5.2 选型对比表

| 关键问题 | 选项 | 决定 | 关键原因 |
| --- | --- | --- | --- |
| 版面分析是本机还是云 | 本机启发式 | **本机** | 隐私、性能、零成本 |
| 营养表能否靠 ML 拿下 | 自训 vs 规则 | **规则优先** | 训练数据小，规则收益 ≥ 模型；模型 R3 再说 |
| DOCX 是否要绝对定位 | 流式 vs `w:position*` | **位置锚点（粗略）** | 流式实现最简但版式差；绝对定位需对齐页心，复杂度可控 |
| C 档（衬底图）是否做 | 做 vs 不做 | **做（兜底）** | 用户可接受度最高，工程成本最小 |
| TextIn 接不接 | 接 vs 仅接口 | **接（可不配置）** | 已有契约；只需补一个 HTTP Client + multipart 上传 |
| 视觉显著性 / 边缘 | Core Image vs Core ML | **Core Image** | 系统内置，复杂纸张场景够用 |
| 是否启用「OCR 后再做一次纠错」 | LLM 修补 | **仅低置信** | 整页 LLM 会把对的改错（如「能量 1429 千焦」） |

### 5.3 拒选理由（已讨论、不再走）

- **OpenCV**：体积、与 Swift 包管理、收益不明显。
- **整页 LayoutLM 微服务**：训练成本、隐私、依赖外网。
- **整页 LLM 改写数字**：识别的核心是数字，LLM 常常「圆滑化」错数字。
- **微信 / 钉钉 SDK**：产品不要（见 03 选型文档）。
- **TCA**：体量不够上框架（已写明）。

---

## 6. 实现原理（按模块）

### 6.1 版面分析（LayoutAnalyzer）

> 目标：在行级 OCR 之上，给出「区域归属（空/文/图/表/条码/手写）」与「栏结构（单/双栏/错位栏）」。

**输入**：`OCRPageText.lines` + `DetectedBarcode` + `CGImage`。
**输出**：`PageLayout { regions: [Region], columns: [Column], anchors: [LayoutAnchor] }`。

算法步骤：

1. **栅格化到 72×96**（密度比现有 36×48 翻一倍；OCR 像素尺寸按归一化坐标定位）。
2. **填文字掩码**：所有 OCR line 用 0.012 膨胀（**比 v1 的 0.018 更小**，避免合并邻近题注）。
3. **填条码掩码**：bbox inset `0.005`（更紧，**允许图从旁边溢出**）。
4. **填空白掩码的候选**：填一个全局显著性图（CIEdges + CIPercentile 80%）做参考。
5. **区域生长**：每个候选 seed（text 包围的空白 / 显著高且边缘密集）做 4 邻域 flood；要求 fill ≥ 0.45 且宽高比 ∈ [0.2, 5]。
6. **栏解析（ColumnResolver）**：把文字块投影到 X 轴，做 histogram，找主列（出现频率最高）+ 副列；若两侧中点距离 > 0.45 页宽且分布密度相近 ⇒ 双栏；否则单栏。
7. **页眉 / 页脚分类**：top 0.07 / bottom 0.07 内的文字若字号 < median × 0.85 ⇒ footer/header。
8. **手写空识别**：font > median × 1.1、长度 > 1.2×width、周围有横线 ⇒ handwriting blank（不写字符串）。

> 关键改动：栅格密度、文字膨胀、条码紧致。

### 6.2 多栏与阅读序（ReadingOrderV2）

> 替代 `OnDeviceReadingOrder`，处理练习册的左右并排题 + 单 / 双栏 / 多栏。

算法：

1. 根据 `ColumnResolver` 给的栏内点集合（不是所有文本块），对每个块打 `columnID`。
2. 在每个栏内：按 `minY` 排序，`sameRow` 阈值同比 v1。
3. **跨栏但同 Y** 的块：算水平距离 < 0.18 且 `similarHeight`，则**左右成对**作为一个双联块。
4. 题号、选项字母等用独立 Anchor 标注，不是简单按行叠加。
5. 输出仍是 `ReconstructBlock` 数组，但附加 `column` 与 `pairedWith`。

### 6.3 表格识别 v2

#### 6.3.1 列对齐策略（解决 R2）

1. **多尺度合并**：
   - 第一遍：列 `maxGap: 0.085`，行 `maxGap: 0.028`。
   - 第二遍：把过宽列按字间空白再切。
2. **锚点策略（针对营养表）**：
   - 关键词：「营养成分表」「NRV」「每 100 克」「Project」「Per 100g」。
   - 锚点行：第一个含 NRV/每 100g 的行。
   - 锚点下方 / 右侧 anchor 范围：left ∈ [anchor.left − 0.05, anchor.left + 0.5], top ∈ [anchor.bottom − 0.005, anchor.bottom + 0.4]。
   - 在范围内重新列聚类 `maxGap: 0.13`。
3. **宽松 occupancy**：`occupancy ≥ 0.30`（避免空文本列被拒）。
4. **`looksLikeDataTable`**：
   - 允许单元格含数字 + 单位 + 字母。
   - 拒绝条件：每行都是「英文长句」（>30 字符且字母占比 > 0.7）。
5. **表头检测**：
   - 第一行若含「项目」「每」「NRV」「Per」「项目」⇒ header。
   - 表头单元格加粗（DOCX 渲染）。

#### 6.3.2 数字-单位合并（解决 B3）

- 同一列、垂直距离 < 行高 × 1.1、相邻字符不含分句标点 ⇒ 合并。
- 例：`1429` + `千焦` ⇒ `1429 千焦`。

### 6.4 配图检测 v2（解决 A5 / A6）

#### 6.4.1 多源候选

| 来源 | 触发条件 | 优先级 |
| --- | --- | --- |
| 已检出条码 | bbox 直接 → barcode | 单独通道 |
| 文字盒外侧空洞 | 连通域 fill ≥ 0.45，宽高比合理 | 高 |
| 显著性图（CIEdges + CIPercentile）显著高 | 在文字盒外 | 高 |
| 题下 anchor 区域 | 题号下方 0.18~0.55 高度、题宽 × 0.9 | 高 |

> 题下 anchor 用于练习册 A/B/C 题图兜底。

#### 6.4.2 去重

- 候选 IoU > 0.6 只保留最大的那个。
- barcode 永远单独通道，**不抢 figure 名额**（图注独占 caption 字段）。
- figure 不超过 top-N（默认 12，按面积排序，避免「题间空白」凑数）。

#### 6.4.3 裁切

- 用 `CIContext` 渲染矩形裁切（不用 raw cg crop，避免颜色偏差）。
- 输出为 PNG（DOCX 嵌图）；可缓存 max(640, 原宽) 控制体积。

### 6.5 文字级修补（接口预留）

> 默认关闭；R2 仅暴露协议 `ReconstructRepairing`，由 `LayoutMLRepairer`（默认空实现）+ 可选 `CloudLayoutRepairer`（接 TextIn）来满足。

- 输入：`PageLayout + blocks` + 失败列表（用户标过 / 置信度阈值 < 0.6 的块）。
- 输出：被修补过的 `ReconstructPage`。
- 触发条件：用户在 UI 里点「修复」、或在 CI 自动跑。

### 6.6 DOCX 导出 v2（解决 A6 / B7 + 整体版式）

#### 6.6.1 三档实现

| 档位 | 段落流 | 表格 | 图 | 锚点 | 衬底图 |
| --- | --- | --- | --- | --- | --- |
| **A 结构化** | block 顺序段落 + 段标题 | `w:tbl`，列宽按 bbox 比例分配 | `wp:inline`，EMU 按真实像素 + 容差缩放 | 无 | 无 |
| **B 重排版** | block 流 + 按 `columnID` 分栏 | 表格按列宽实际像素，header 加粗 | `w:positionV/H` 近似锚点（DXA 像素换算） | 有 | 无 |
| **C 衬底图** | block 文字层叠在衬底上 | 同 A | 同 A；图片图层禁 | 有 | 原图 100% |

#### 6.6.2 列宽自适应（A 档）

- 用 OCR 推断列宽：在 grid 内取每列最宽 cell，按字符宽度 × 字符数估算；单元格 `w:tcW` 按此写。

#### 6.6.3 图片锚点（B 档）

```xml
<w:drawing>
  <wp:anchor distT="0" distB="0" distL="114300" distR="114300"
             simplePos="0" relativeHeight="1" behindDoc="0"
             locked="0" layoutInCell="1" allowOverlap="1">
    <wp:simplePos x="0" y="0"/>
    <wp:positionH relativeFrom="page"><wp:posOffset>...</wp:posOffset></wp:positionH>
    <wp:positionV relativeFrom="page"><wp:posOffset>...</wp:posOffset></wp:positionV>
    <wp:extent cx="..." cy="..."/>
    ...
  </wp:anchor>
</w:drawing>
```

- `cx`, `cy`：图 bbox 像素 × 9525 EMU/in。
- `positionH/V`：从 OCR 文本 bbox 推导的归一化坐标 × 页面像素化。
- 误差：半页尺度允许 ±15px；不在 IR 缺 anchor 时退化成 inline（B ⇒ A）。

#### 6.6.4 衬底图（C 档）

- 文档 head 注入一个 `wp:anchor behindDoc="1"` 全页占位图，EMUs = 页面尺寸。
- 文字层正常段落流。
- 段落文字与底图位置会偏，但语义可读 + 版式忠实。

### 6.7 可检索 PDF 导出 v2

- 沿用 `UIGraphicsPDFRenderer`。
- **新增表格线框**：用 `UIBezierPath` 画每行的横线、header 单独底纹。
- **新增图注**：文字层追加 caption。
- **CJK 支持**：用字体 fallback（已有代码）。
- **页宽自适应**：列宽与文字宽度匹配；自动断行。

### 6.8 性能与缓存

- 解析产物（IR）落 `tmp/Zhixia/reconstruct/{pageID}/ir-v2.json`，跨会话复用。
- 同一原图 + 同一档位二次导出 < 200 ms（从 IR 重新拼产物）。
- OCR + 显著性图缓存到 `tmp/Zhixia/reconstruct/{pageID}/aux/`。
- 缓存清理时机：删除文档时删 matching 目录；过 24h 的过期文件定期清理。

### 6.9 单测与样张差异

- 旧 `ReconstructTests`（合成 bbox）继续存在作为单元测试。
- 新增一组 `ReconstructV2Tests`：
  - 把样张 OCR `[(text, bbox)]` 的真实导出 dump 固化为夹具（不要整图，避免体积）。
  - 对每张样张：
    - `analyze_layout` 检「区域归属 / 栏」。
    - `detect_table_grid` 检「营养表 3 列、6 行」+ 表头命中。
    - `detect_figures` 检「练习册 ≥ 3 个 figure（题图 + QR）」。
    - `export_docx` 检「包含 `w:tbl`」、「包含至少 1 个 `wp:inline`」、「UTF-8 文本不丢字」。
- 真机端到端：CI 不跑（无设备），但每次发版前用两样张手验（项目自评「单测绿 ≠ 样张过关」）。

---

## 7. 项目阻碍点

### 7.1 技术阻碍

| 阻碍 | 描述 | 缓解 |
| --- | --- | --- |
| **OCR 错字连篇** | 练习册手写、空心字、连笔导致识别为乱码（如「Lemce」「20:14C」） | 在 OCR 阶段就拒这些垃圾 → 改为「handwritingBlank」，不写进段落；真实可补救的 cell 走 R3 的 LLM 修补 |
| **图像显著性失效** | 包装袋橙色 + 反光 + 弯折 → 显著图不显著 | 改用 CIEdges × CIPercentile 双通道，作为补充而非主信号；题下 anchor 兜底 |
| **多栏模型不可信** | 自写 column resolver 在变形页面易错 | 增加「主栏 + 副栏置信度」，低置信回退单栏；导出 R2-A 档对栏不敏感 |
| **表格未对齐** | OCR 行间距不均、字符粘连 | 加入数字-单位合并 + 双尺度列聚类 + 表头锚点 |
| **DOCX 锚点编辑后偏移** | Word 打开后用户拖动图片 → relativeFrom=page 还是 column？ | B 档用 page，固定坐标系；A 档 inline |
| **内存压力** | 4K 原图一次性解码会爆 | 始终缩放到 2200 长边（已有）；但 figure 显著性需要原图，分块处理 |
| **Core ML 部署与体积** | R3 用模型但包体上升 | R2 先不部署模型，协议预留即可；R3 再评估 |
| **真机测试限制** | 模拟器无相机、无 Vision 框 | 强制真机回归；CI 不跑 R2 套件 |

### 7.2 产品阻碍

| 阻碍 | 描述 | 缓解 |
| --- | --- | --- |
| **用户预期不明确** | 「能不能 100% 还原？」用户的预期高于本机能给 | UI 上三档 + 文案 + 失败空态引导 |
| **「自动」场景容易误会** | 自动场景有时路由到错的类 | 场景可手动改 + 显示识别路径 |
| **C 档的合法性** | 衬底图导出物 = 内含原图，超出「结构化文档」 | 显式免责 sheet 与显式「本导出含本页原图」标记 |
| **云开关的产品设计** | 「确认上传此页」UX 设计细节 | 默认关；只在该页点修复时弹一次；披露临时存储时长 |

### 7.3 工程阻碍

| 阻碍 | 描述 | 缓解 |
| --- | --- | --- |
| **现有协议 `DocumentParsing` 改了会牵动** | ViewModel/Composite/UI 都引用 | 引入 V2 并存，ViewModel 用 V2；UI 用 ViewModel |
| **DOCX 导出回归风险** | 改 XML 易破坏 Word 打开 | 维护一组「打开不报错」单测 + 桌面 Word 真实打开校验 |
| **资源体积上升** | Core ML 模型 100 MB+ | R2 不引入；R3 评估 |
| **缓存目录膨胀** | 解析器缓存未管理 | 加 sweep；删除文档时清理 |
| **Swift 6 严格并发** | 新 actor 之间共享 PageLayout | PageLayout 全部 Sendable；actor 隔离 |

### 7.4 资源 / 时间

- 原项目自评 R2 阶段 ≈ 2~4 周（个人项目估计）。
- 团队化开发：M2/M3 关键路径（版面分析、表格 v2、DOCX v2 三模块）需 1 人独立 + 0.5 人 review。
- 真机回归每天一次。

### 7.5 隐私 / 合规

- **默认本机**；云通路必须用户主动，且文案披露「本页将临时上传」。
- 新增数据收集项 → App Store 隐私标签 + 文案更新。
- `tmp/Zhixia/reconstruct/` 路径中无 PII 键名，但扫描件含用户内容；保留沙盒内。

---

## 8. 项目落地计划

### 8.1 里程碑（按 6 周计，估）

| 里程碑 | 时长 | 验收 |
| --- | --- | --- |
| **M0 现状样本化** | 3 天 | 两张样张 OCR line + bbox 提取脚本固化；新测试夹具 `ReconstructV2Fixtures.swift` |
| **M1 IR v2 与 LayoutAnalyzer** | 1.5 周 | `PageLayout` 类型；`LayoutAnalyzer` 跑两张样张，能分「栏 / 页眉 / 页脚 / 正区」 |
| **M2 TableGrid v2 + 营养表 profile** | 1 周 | 营养表稳出 3 列；表头加粗；数字-单位合并 |
| **M3 Figure v2 + 练习册题下 anchor** | 1 周 | 练习册 ≥ 3 个 figure；不与条码抢名额 |
| **M4 DOCX v2 + 三档产物** | 1 周 | R2-A 默认；R2-B 锚点版；R2-C 衬底图；可检索 PDF 表格版 |
| **M5 UI 改造 + 单测 + 真机回归** | 0.5 周 | 还原页新 UI；现有「文本」「分享」回归；两样张过 P0 验收 |

### 8.2 优先级与依赖

```
M0 (夹具) → M1 →┬─► M2 →┐
                 ├─► M3 ─┤
                 └────────┴─► M4 → M5
```

- M2 与 M3 可并行（独立模块）。
- M4 必须在 M1+M2+M3 都通过后才可开工。

### 8.3 验收机制

- **单元测试**：合成 bbox 旧夹具 + 真实 line bbox 新夹具。
- **真机手验**：每天一次两样张导出 → 桌面 Word 打开校验：
  - 营养表：行 / 列对齐、header 加粗、条码图、payload 题注。
  - 练习册：题图 ≥ 3、阅读序不再有页眉渗入、二维码作为 figure。
- **回归**：「文本」路径、扫描件 PDF 导出、R1 段落合同 Word。
- **性能**：单页还原 < 1.5 s（iPhone 14），二档导出 < 250 ms。

### 8.4 风险缓解（单列）

- **表格识别 v2 仍不过**：在 M2 末尾加一次评估；若失败，引入「营养表模板匹配」作为兜底（关键词全命中 → 强制三列）。
- **DOCX 锚点版 Word 不兼容**：B 档加 fallback 至 A 档（同上输出）。
- **缓存膨胀**：M5 加 sweep。

---

## 9. 路线图（v2 → v3 / v4）

### 9.1 短期（v2，~6 周）

- M0~M5 全部完成；R2-A 为主，R2-B / R2-C 可用。
- 「还原 → 导出 Word」练习册与营养表达到 P0 验收。
- 还原页 UI 改版（场景选择、档位切换、失败空态）。

### 9.2 中期（v3，~3 个月）

- R3 试卷模型：勾选 `checkbox`、手写填空 `handwrittenBlank`、合并单元格识别。
- LayoutMLRepairer 真接 Core ML 轻量模型（先评估 Page Layout Reader v2 / DiT-tiny）。
- 缓存与监控：解析时长、失败原因分布。

### 9.3 长期（v4，~6 个月）

- 云通路真接通：TextIn / Azure DI 二选一；UI 显式确认上传单页。
- 多模态 LLM 修补：仅对低置信块（数字为主、表格填空为次），不重打整页。
- 板式重排版（D 档）：表格与图以外的版心高保真（分栏 + indent + 行距）。

### 9.4 不做

- 默认云解析、整页 LLM 重打。
- 微信 / 钉钉 SDK、签名 / 批注 / 水印。
- 自训端到端 LayoutLM（除非数据 + 工程资源到位）。

---

## 10. 总结与对照表

### 10.1 新 vs 旧（一张表说清）

| 维度 | R1（现状） | R2 计划 |
| --- | --- | --- |
| IR 粒度 | 行 + block（无 anchor、无 semantic） | block + column + anchor + semantic tag |
| 表格识别 | 单尺度列聚类 + 严苛 occupancy | 双尺度列聚类 + 表头锚点 + 营养表 profile + 数字-单位合并 |
| 配图检测 | 36×48 栅格、文字 inset 0.018 | 72×96 栅格、文字 inset 0.012 + 显著性 + 题下 anchor + 去重 |
| 阅读序 | 单栏按 Y 排序 | 栏感知 + 左右双联 + 题下 anchor |
| DOCX | 流式段落 + 表格 + inline 图 | 三档产物；B 档带锚点；C 档衬底 |
| 可检索 PDF | 文字 + 图 | 文字 + 表格线框 + 图 + 图注 |
| 云通路 | 仅 stub | 真接通（可关）；披露文案 |
| UI | 还原页单列预览 + 两按钮 | 三段布局 + 档位切换 + 场景选择 + 失败空态 + 修复提示 |
| 单测 | 合成 bbox | 真实样张 OCR 夹具 + 真机手验 |

### 10.2 关键决策记录（ADR）

| 编号 | 决策 | 理由 |
| --- | --- | --- |
| ADR-R2-01 | 本机启发式为主，ML / 云接口预留 | 隐私与产品定位（默认本机） |
| ADR-R2-02 | 三档产物分级 | 用户预期与工程可达性折中 |
| ADR-R2-03 | 不接整页 LLM | LLM 圆滑化数字，害营养表 |
| ADR-R2-04 | 不接 OpenCV | 体积与可维护性 |
| ADR-R2-05 | 缓存产物于 tmp | 性能与可恢复 |

---

## 11. 附录 A · 失败现象 → 修复映射

| 现象 | 当前模块 | v2 修复 |
| --- | --- | --- |
| A1 行序乱 | `ReadingOrder.clusterRows` + Parser 出口排序 | 新 HeaderFooterClassifier；栏内排序；页眉页脚标注 |
| A2 OCR 错字进段 | `OnDeviceReadingOrder.makeBlocks` | 低置信度过滤；不确定字走 handwritingBlank |
| A3 A/B/C 显示成口 | OCR 字符被替换 | OptionDetector 锚：题目下方 `A` / `B` / `C` 单字符不参与段落，新增 `semantic: .optionLetter` |
| A4 QR URL 进文本流 | Vision OCR 重复认 | BarcodeDetector 已认的 box 半径内不再写文本（已做 inset 0.012，过紧调至 0.018） |
| A5 配图缺 | `FigureRegions` 失效 | Figure v2 + 题下 anchor + 显著性双通道 + IoU 去重 |
| A6 阅读序散 | 单列 Y 排序 | Column + 双联 |
| A7 缺题号段 | 段落散 | HeadingDetector + 题号锚点 |
| B1 表头散 | TableCluster 列数错 | 表头锚点 + 多尺度列聚类 |
| B2 单元格成段 | 列聚类失败 | 双尺度 + 锚点 + 数字-单位合并 |
| B4 `O` / `:` 混淆 | OCR 字符级 | 后处理正则 `O([0-9])` → `0$1`；只在数字密集上下文 |
| B5 条码成数字 | BarcodeDetector 成功但 OCR 又写 | textSkipInBarcodeRadius 调到 0.025 + barcode 通道独占 |
| B6 表标题进段落 | ReadingOrder | 「营养成分表」→ tableCaption 块 |
| B7 包装说明段落散 | ReadingOrder | 句间距离 + 字号双条件断段 |

---

## 12. 附录 B · 接口示意（草案）

```swift
// 协议 V2
protocol LayoutAnalyzing: Sendable {
    func analyze(imageURL: URL, ocr: OCRPageText, barcodes: [DetectedBarcode])
        async throws -> PageLayout
}

struct PageLayout: Sendable, Codable, Equatable {
    var size: CGSize
    var columns: [Column]               // 主栏 / 副栏
    var regions: [Region]               // header / footer / body
    var anchors: [LayoutAnchor]         // 题号、题干起点等
}

struct Column: Sendable, Codable, Equatable {
    var id: Int
    var frame: CGRect                   // 归一化
    var isPrimary: Bool
    var confidence: Double
}

struct Region: Sendable, Codable, Equatable {
    var kind: RegionKind                // .header, .footer, .body, .figure
    var frame: CGRect
}

enum RegionKind: String, Codable, Sendable {
    case header, footer, body, figure, table
}

struct LayoutAnchor: Sendable, Codable, Equatable {
    enum Kind: String, Codable { case questionStem, questionNumber, optionLetter, tableHeader, barcode }
    var kind: Kind
    var point: CGPoint                   // 归一化
    var text: String?                    // 选项字母、表头文
}
```

---

## 13. 附录 C · 工程清单（落地文件级别）

```
新增
──────────────────────────────────────────────────────────────
Domain/
  Layout/LayoutAnalyzer.swift               新建
  Layout/ColumnResolver.swift               新建
  Layout/HeaderFooterClassifier.swift       新建
  Layout/Region.swift                       新建
  Table/TableGridDetectorV2.swift           新建
  Table/TableHeaderResolver.swift           新建
  Table/NutritionTableProfile.swift         新建
  Figure/FigureRegionSegmenter.swift        新建
  Figure/FigureAnchorAligner.swift          新建
  Text/HeadingDetector.swift                新建
  Text/OptionDetector.swift                 新建
  Models/LayoutAnchors.swift                新建
  Models/SemanticTags.swift                 新建

Services/Reconstruct/
  OnDeviceDocumentParserV2.swift            新建（V2 主）
  LayoutMLRepairer.swift                    新建（接口预留）
  DocxExportServiceV2.swift                 新建
  SearchablePDFExportServiceV2.swift        新建
  NormalizedImageCropV2.swift               新建
  CloudContract.swift                       新建
  TextInDocumentParser.swift                改（真接通）

Features/Reconstruct/
  ReconstructViewModel.swift                改（V2 IR + 档位）
  ReconstructView.swift                     改（三段布局）
  Components/DocLevelSwitcher.swift         新建
  Components/ScenePickerSheet.swift         新建
  Components/BlockIssuePanel.swift          新建
  Components/BackdropConfirmSheet.swift     新建

ZhixiaTests/
  ReconstructV2Tests.swift                  新建
  ReconstructV2Fixtures.swift               新建

Localizable.xcstrings                       改（新增 §3.6 文案）

改动（接口并存版本升级）
──────────────────────────────────────────────────────────────
Domain/Models/ReconstructDocument.swift     + version, anchors, semanticTags
Services/Reconstruct/CompositeDocumentParser.swift     + V2 组合
App/AppEnvironment.swift                    + V2 注入

保留（标注 deprecated）
──────────────────────────────────────────────────────────────
Domain/OnDeviceTableCluster.swift           deprecated
Domain/OnDeviceFigureRegions.swift          deprecated
Domain/OnDeviceReadingOrder.swift           deprecated
Services/Reconstruct/OnDeviceDocumentParser.swift      deprecated
Services/Reconstruct/DocxExportService.swift           deprecated
Services/Reconstruct/SearchablePDFExportService.swift  deprecated
```

---

> 「R2 的核心：把对版式的赌注，从「靠 Vision 一把梭」分散到「版面分析 → 块映射 → 锚点式导出」三段独立可测的环节，并给用户三档可选产物。」

— 完 —
