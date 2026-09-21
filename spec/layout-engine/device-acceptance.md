# 真机自验清单（layout-engine · device acceptance）

> 自动化已证明的（T032 检查点）：全量 **255 passed + 1 expected failure（known issue）+ 0 failed**
> （日志 `/tmp/layout-engine-logs/T032-checkpoint.log`；掉行用例已单独复跑补证
> `T032-dropped-verify.log`）。单测覆盖了引擎几何（`RegionLayoutEngineTests`）、
> 共享度量（`LayoutTypographyTests`）与 OOXML 结构断言（`DocxRestoredLayoutTests`）。
> 本清单只覆盖**必须真机 + 肉眼 + Word** 的部分：SC-001 ~ SC-004。
> 前置：版面还原链路本身按 `spec/layout-restore/device-acceptance.md` 已验收。

## 准备

- 真机一台（iOS 18+；本清单与表格结构识别通路无关，两代系统都验）。
- 电脑装有 **Microsoft Word 2016+ / Microsoft 365**（`w:trHeight` hRule、`w:line`
  exact、浮动表格渲染以 Word 为准；WPS/Pages 仅作参考——QuickLook/Pages/WPS
  对部分 OOXML 特性支持不全，**不作为不通过的依据**）。
- Console.app 连接真机（layout 日志抓取见文末，debug 级**必须**开 Include Debug Messages）。
- 建议样张：`docs/fixtures/images/`（营养表 / 练习册）隔屏翻拍热身，再上实景。

## SC-001 复杂版面实拍（双栏教材 / 试卷）

**拍什么**：**双栏排版**的教材内页或试卷（左右两栏 + 中缝 gutter，最好带一张图或一个表）。

**步骤**：扫描 → 整理 → 还原，预览（默认版面还原档）与原页**并排对照**。

**通过标准**：

1. **无重叠**——任何两块文字不相交（碰撞消解：行序受让把下方块推开）；
2. **无压表格 / 无叠图双影**——文本块不会盖在表格或图片上出现「原字 + 重排字」
   双影（溢出阶梯扩块只吃下方**空白带**，遇任何块即止）；
3. **无跨栏宽行**——原本横跨两栏的大标题 / 长行被拆到正确栏位（宽行拆分），
   左栏内容不会整块漂到右栏；
4. 越页内容夹回页内，无出界截断（clampToPage）。

**对照日志**：`layout split count=…`（跨栏宽行 ≥ 1）、`layout yield count=… totalShift=…`
（有让位）、`layout overflowShrink / overflowExpand`（密集块触发阶梯）。

## SC-002 Word 打开对比预览

**拍什么**：**表格 + 密集正文**同页（营养表 / 带表试卷页）。

**步骤**：版面还原档导出 DOCX → 传电脑 → Word 打开，与手机预览**并排对比**。

**通过标准**：

1. **同构**：字号、行距、表格列宽、行高目视一致——双端共用 `LayoutTypography`
   与 `PageLayoutMapper`，「预览 ≈ Word 首屏」；
2. **可编辑**：点击正文 → 光标进入可编辑段落；逐行文本是**一行一个 `w:p`**
   （行距 = 实测行高 exact），改字不跳版；
3. **表格不压字、不截字**：表格行高与预览网格一致（`trHeight` exact 封顶）；
   单元格内容放不下时**表格向下增长**（atLeast）、文字完整（对照 Word 无「#」
   溢出标记、无截半行）；
4. 表格列宽贴合实测比例（首列窄列不再被均分撑宽 / 挤窄）；
5. 文件正常打开，无修复提示。

**对照日志**：`layout tableGrowthUpgrade block=… row=…`（放不下的表出现 ≥ 0 次；
出现 ≠ 异常，是「保文字」的正确降级）。

## SC-003 密集试卷页字号对比

**拍什么**：**行距密集**的试卷页（小字号、行间紧、整页 40+ 行）。

**步骤**：还原预览与原页并排；导出 Word 再看一眼。

**通过标准**：

1. 重排后的**字号与原页行高匹配**——密集行就是小字（实测行高 × 1.05，
   不再走页高 1.8% 常数把 5pt 小字放大约 1.7 倍）；
2. **行距保真**——重排行的间距与原页一致（逐行 `w:line` exact），行不叠行、
   不忽疏忽密；
3. Word 里字号观感与预览一致（同一推导入口，钳制 [7,28] 只在页 pt 发生一次）。

**对照日志**：密集页允许 `layout overflowShrink`（块内文字偏多时缩字号）；
`overflowExtreme` 应**很少**出现（出现即保文字完整，允许轻微溢出块框）。

## SC-004 简单页零扰动对比

**拍什么**：**版面简单**的页（单栏、块间宽松、无图无表——书页 / 打印文档）。

**步骤**：还原预览与原页并排；顺手在「结构化」档切一下再切回。

**通过标准**：

1. 块位置**逐位不动**——引擎对装得下的块零扰动（无让位、无拆分、无缩放）；
2. 字号 / 行距观感与升级前版本一致（无「变好看但不是原来位置」的漂移）；
3. **结构化档不受影响**——`restoredBlocks` 双档隔离：结构化档 / 可搜索 PDF
   仍读原始 `page.blocks`，切档后正文流无任何变化；
4. 预览无成片空白、无文字重叠。

**对照日志**：本项的**通过证据就是没有 layout 日志**——`layout yield count=0
totalShift=0.0000` 且无 `split / overflow* / tableGrowthUpgrade / figureShrink`
任何一条。出现任何一条都说明简单页被动了（对照 SC-004 失败处理）。

## 日志抓取指引（ZhixiaLog.layout 类目）

布局引擎日志走 os_log：subsystem `com.david.Zhixia`、category `reconstruct`、
级别 **debug**（默认不显示，必须开 debug）。所有 layout 条目以 `layout ` 前缀输出，
与既有 tier / baseImage / mask / artwork / dedup 并列——用前缀过滤即可。

**Console.app**：

1. 真机连线 → Console.app 选中设备；
2. 搜索框输入：`subsystem:com.david.Zhixia category:reconstruct`；
3. 菜单 **Action → Include Debug Messages** 勾上（否则一条都看不到）；
4. 复现操作，实时滚动；选中行可拷贝存档。

**命令行**：

```bash
# 实时跟踪（只看 layout 类目）
log stream --debug --predicate 'subsystem == "com.david.Zhixia" AND category == "reconstruct"' \
  | grep --line-buffered 'layout '

# 复现后离线拉取最近 10 分钟
log collect --last 10m --output /tmp/zhixia.logarchive
log show /tmp/zhixia.logarchive --debug \
  --predicate 'subsystem == "com.david.Zhixia" AND category == "reconstruct"' \
  | grep 'layout '
```

**关注字段（异常 → 处置）**：

| 日志 | 含义 | 异常表现 → 根因方向 |
|---|---|---|
| `layout yield count=<N> totalShift=<X>` | 碰撞让位次数 + 总平移量（归一化页高） | SC-004 简单页出现 → 检查上游块 bbox 是否异常膨胀 / 收缩 |
| `layout split count=<N>` | 宽行拆分块数 | SC-004 出现 → 0.63 阈值对大字号标题误判（查该块 blockWidth） |
| `layout overflowShrink block=<uuid> estimated=<X> available=<X>` | 缩字号降级（估算高 / 区域高，页 pt） | 大面积触发（整页过半块）→ 上游行高数据失真（查 measuredLineHeight） |
| `layout overflowExpand block=<uuid> expandBy=<X>` | 向下空带扩块（归一化） | expandBy 异常大 → 下方块缺失 / 阅读序断裂 |
| `layout overflowExtreme block=<uuid> estimated=<X> available=<X>` | 扩完仍放不下，保文字 intact | 频繁出现 → 版面数据与真实版面严重不符（先查 OCR / 底图对位） |
| `layout tableGrowthUpgrade block=<uuid> row=<N>` | 表格行高 exact → atLeast 升级（第 N 行触发） | 简单表也触发 → columnRatios / 表格 bbox 异常；正常复杂表触发属预期 |
| `layout figureShrink figure=<uuid> clipHeight=<X>` | 越界 figure 夹回页内 | 频繁出现 → 底图与块坐标系错位 |

> 注：条目里的 `block=<uuid>` 对应 `ReconstructBlock.id`，需要定位具体块时在
> 导出 docx 或调试器里按 id 检索。

## 结果记录

每项验完打勾并注明环境：

| 项 | 结果 | 设备 / iOS / Word 版本 | 备注 |
|---|---|---|---|
| SC-001 | ☒ 不通过 | iPhone 13 / iOS 18 / - | 双栏教材（相册导入）；预览截图用户提供（代理无法读图）。机制性缺陷与 Word 同源：块级字号 vs 行级行距源不一致→行叠字（见 SC-002 证据）；对话行碎片块漂移栏中 |
| SC-002 | ☒ 不通过 | iPhone 13 / iOS 18 / Word（用户实测） | 结构指标全过（11 文本框 0 重叠、lineRule 全 exact、normAutofit=0、列宽无表格页不适用）；但标题块字号 19.5pt/行距 13.1pt 叠字 49%、乱序拼接（"physics exercises for homework. three hours doing those"）、孤儿碎片块（"the maths problems?" x=340、"people from lots of different" x=287）、填空空隙缺词体感。同页三扫块结构不稳（6/5/11 块）。取证：~/Downloads/Zhixia-9月19日 扫描 · {5,7,8} 三份 DOCX 结构分析 + 本地 Vision 同参对照（108 行全捕获，OCR 未丢词——"缺词"为填空题空隙+乱序拼接） |
| SC-003 | ☐ 未验 | | 密集试卷页本轮未测 |
| SC-004 | ☐ 未验 | | 简单页本轮未测 |

**验收不通过根因清单（2026-09-20 真机取证）**：
- R1 填空对话行多段合并失败——Vision 把一条视觉行拆成 2~4 段（段间为空白下划线），行聚类未按视觉行合并 → 孤儿碎片块漂移
- R2 行内段乱序——sameRow 容差内按 x 排序把不同视觉行的段串接 → 文本乱序
- R3 填空空隙不可见（练习册固有）——文本读感"缺词"；可用下划线占位改善
- R4 I/l/1 误识（"Yesterday l"、"1 to a summer camp"）
- R5 **块级字号（中位行高×1.05）与行级行距（各行实测×1.05）推导源不一致** → 字号>行槽 → Word/预览行叠字（·5 巨块 17.5/12.2；·8 标题块 19.5/13.1）——D4/D7 设计缺陷，最重
- R6 行聚类对输入微扰敏感——同页三扫块数 6/5/11 不稳
- R7（顺带发现）`DocumentEntity.ocrSearchBlob` 为空（长度 0）——全文搜索 blob 未填充，独立 bug
