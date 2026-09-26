# 真机自验清单 · 版面还原对标 WPS（wps-parity-layout）

> 模拟器局部套件全绿（金标准端到端 ×10 / 墨迹对账 ×12 / 档位 ×11 / 行聚类 ×10 /
> 噪声过滤 ×12 / 结构 ×22 等，基线 317 → 357 只增不减）。本清单覆盖单测**无法**证明
> 的部分：**真机结构化通路接通性**（调研 L1 疑案）、三类样本的导出肉眼质量、
> 哨兵/通路日志与真机场景的对应关系。逐项打勾，全过才算本周期收尾。
> 契约语义见 `docs/09-project-handbook.md` §4.5「版面对标契约」，周期全貌见 §6.12。
>
> 设备：iPhone 13（菀墨，iPhone14,5，iOS 26.7）。部署目标 iOS 18.0 → **结构化通路
> 在该真机本应可用**；构建签名路径不变（`DEVELOPMENT_TEAM=VV865TW6B3`）。
>
> **背景（本清单最高杠杆项）**：用户 2026-09-21 真机导出的 docx 取证证明，该次解析
> 走的是**几何回退通路**（iOS 26.7 上结构化通路疑似静默回退）；模拟器 iOS 26.4.1
> 不复现（`structuredSuccess`）。本周期已加 `reconstructPath` 决策线（每页恰好一条），
> 真机取证一步到位——**无论过否，先把 §A 的 `reconstructPath` 行原样抄录进记录**。

## 0. 日志抓取指引（Console.app 实时抓取，全程保持开启）

> ⚠️ 只能这样抓：模拟器上捕获不到自有子系统的 debug 级 os_log（`log stream --debug`、
> `log config` + `log show` 均空，T008 实测）；`reconstructPath` / `textSentinel` /
> `containment` 全是 debug 级，**不勾 Include Debug Messages 一条都不会出现**。

1. 手机连 Mac，**Console.app 选中设备**，搜索框输入
   `subsystem:com.david.Zhixia category:reconstruct`，勾选 **Include Debug Messages**，
   点「开始」**开始流式抓取**；
2. 保持抓取开启，依次执行 §A/§B/§C；每个场景结束后立刻检索本场景日志（前缀见下表），
   确认可读后再进入下一场景；
3. 全部场景结束后 `File → Save` 导出留存，按场景分段命名。

| 日志前缀（可整段粘进搜索框） | 含义 | 发射时机 | 本轮验收看什么 |
|---|---|---|---|
| `reconstructPath page=<UUID> path=structured reason=structuredSuccess` | 每页解析的通路决策线，**每页恰好一条**；path ∈ {structured, geometric}，reason ∈ {structuredSuccess, apiUnavailable, requestFailed, invalidResult, lowVersionFallback} | 点「还原」解析每页时 | §A 核心：语法页应为 `path=structured reason=structuredSuccess`；若出现 `requestFailed` / `invalidResult` / `apiUnavailable`，**记下整行**——这就是 L1 回退定案证据 |
| `textSentinel page=<索引> gaps=<n> figureOverlap=<n> structureSwallow=<n> edgeBand=<n> likelyMissed=<n>` | 丢字哨兵：导出前墨迹-文本对账缺口四分类计数（只记不阻断） | 点「导出」时每页一条（docx 与 PDF 都发）；`page` 是**页索引**（与 `reconstructPath` 的 UUID 字段不同，别混着对账） | 有图的页预期 `figureOverlap ≥ 1`（图区墨迹属预期解释）；`likelyMissed > 0` 的每一条都要对照导出文本核实（真漏 → 记录；有文本 → 哨兵误报，记录）；表格页 `structureSwallow` 应为 0 |
| `containment removed=<n> rescued=<n>` | 解析期剔行去处：被表格/条码 bbox 剔除的行数与「结构未携带、保留回文字层」的救回数 | 仅 removed > 0 才发（事件驱动） | 出现时 `rescued` 逐条有文本可查（无静默吞行）；不出现属正常 |
| `reconstructTier tier=… isDefault=…` | 导出档位（既有前缀） | 导出时 | 回归对照：默认应为流式（structured / isDefault=true）；切高保真后 tier 变化 |

## A. 语法页（L1 通路疑案取证 + 周期主线验收）

**样本**：金标准同款语法练习页（past simple，含编号填空 + 漫画条 + 故事）。优先用
2026-09-21 同一张原纸**重新实拍**（走完整相机链路）；原纸不可得时，打印
`docs/fixtures/images/grammar-worksheet.jpg` 再拍。

**步骤**：

1. 文档模式实拍该页 → 整理保存 → 进入「还原」；
2. 确认档位显示**「流式（默认）」**（未选择过应是它；若显示高保真，先查
   @AppStorage 是否残留上次选择，记录后切回流式）；
3. 等解析完成 → Console 检索本页 `reconstructPath` 行，**原样抄录**；
4. 导出 Word（分享存到「文件」）→ 再导出一次 PDF → Console 检索 `textSentinel` 行；
5. 用 Word / WPS 打开导出的 docx 肉眼验收（对标产品就是 WPS，直接对照观感）。

**通过标准**：

- **通路**：`path=structured reason=structuredSuccess`（L1 定案：真机接通）。若回退，
  reason 必须明确（`requestFailed` / `invalidResult` / `apiUnavailable` 三者之一——
  iOS 26.7 上不应出现 `lowVersionFallback`），且导出仍满足下面全部回退质量项——
  此时本项记「回退原因定案 + 质量兜底成立」，原因转入修复周期；
- **零假表**：导出的 docx **无任何表格**（该页散排编号不得被聚成表；Word 里看不到
  表格框线）；
- **段落成段**："8 We decided…"、"Complete the text with…"、"A terrible trip!"、
  "2 At school" 等**各自成段**，不是一整块；段数与模拟器金标准同量级（约 32 段）；
- **漫画条**：单张完整内联图，落在编号 8 之后、"Complete the text with…" 之前
  （阅读序原位），不拆碎、不压正文；
- **丢字核对**：在导出 docx 里搜索 `wrong bus`（**不带叹号**——OCR 可能输出全角 ！，
  带符号检索会假阴性，2026-09-21 的教训）——必须能搜到；故事首行
  "On the day of the scho…" 与中段 "excursion" 也须在；
- **哨兵**：`textSentinel` 每页一条；`figureOverlap ≥ 1`（漫画条/大图墨迹被图解释）；
  `likelyMissed` 逐条对照导出文本核实（真漏记录位置；有文本则记「哨兵误报」）。

**失败时看**：

- `reason=requestFailed` → `RecognizeDocumentsRequest` 抛错：抄录 Console 中该行
  前后的系统错误（Vision 子系统条目），对照模拟器行为；检查设备存储/内存压力；
- `reason=invalidResult` → 识别返回但无可用 container：多为真机拍照质量/分辨率与
  模拟器 fixture 差异，保存当时照片转 fixture 复现（`Tools/ocr-dump` 链路）；
- `reason=apiUnavailable` → 识别器未注入（构建/装配问题，对照 `AppEnvironment`
  与 `DocumentStructureTests` 是否绿）；
- 零表但段落错乱 / 漫画条位置不对 → 转 `GoldenWorksheetEndToEndTests` 对照，
  真机照片固化新 fixture；
- 搜不到 "wrong bus" → 先确认检索词无全角/半角问题；确认后查 `textSentinel`
  `likelyMissed` 是否 ≥ 1（有证据 = Vision 漏识上限，按 FR-006 记录通过；
  无证据又无文本 = 真丢字，开修复）。

## B. 真表格页（防误伤 + iOS 26 真机首验 + 档位切换/持久化）

**样本**：真表格页——营养成分表类（带表头标题「营养成分表」字样的包装/打印表单）。

**步骤**：

1. 实拍该页 → 还原（流式档）→ Console 检索 `reconstructPath` → 导出 Word；
2. 肉眼验收表格（见下）；若出现 `containment` 行，抄录；
3. 在还原页**切换档位到「高保真」**→ 导出 Word → 肉眼验收浮动表格；
4. **杀掉 App 重开** → 进入同一文档的还原页 → 看档位是否仍为「高保真」
   （@AppStorage 持久化）；再切回「流式」导出一次（切档作废 docx 缓存、重新生成）。

**通过标准**：

- iOS 26.7 真机：`path=structured reason=structuredSuccess`，且导出 docx **含真表
  `w:tbl`**（Word 里出现表格框线与单元格文本，表头「营养成分表」类文字完整）——
  这是 §7 P0-1 的首次真机验证；
- 单元格文本逐格肉眼对照 ≥ 90% 可读、行列结构与原表一致（合并单元格按 Apple
  识别结果拉平属预期）；
- `containment` 行若出现：`rescued` 的行在导出文本中可查（无静默吞行）；
  `textSentinel` 的 `structureSwallow = 0`；
- 高保真档：表格以**原生浮动表格原位**呈现（不套文本框、不漂移）；
- 重开后档位保持「高保真」；切回流式后导出 = 段落流真表（作废旧缓存生效）；
- **防误伤边界**：真表必须出表；同页散排文字**不得**混进表格（v1 退役后假表根除、
  真表无损）。

**失败时看**：structuredSuccess 但 `w:tbl = 0` → 结构化表未传导到导出（对照
`DocumentStructureTests` / `ReconstructEndToEndTests`）；`invalidResult` → 同 §A
失败链固化 fixture；高保真丢表格/漂移 → 对照 `DocxRestoredLayoutTests`；重开后档位
丢失 → 对照 `ReconstructTierTests.persistedTierRoundTripsThroughUserDefaults`。

## C. 图文混排页（图形完整性 + 高保真底图透出）

**样本**：图文混排页——≥ 1 张大图 + 环绕文本；有漫画条类（细长竖图 + 密集文字）
最严苛，优先选这类。

**步骤**：实拍该页 → 还原（流式）→ 导出 Word 肉眼验收 → 切「高保真」再导出一次
肉眼验收 → Console 检索两次导出的 `textSentinel`。

**通过标准**：

- 流式档：图片**内联在阅读序原位**（不压正文、不漂到页首/页尾）；每张图**单张完整**
  （不拆碎、无黑边、无截半）；图文重叠区的正文完整；
- 高保真档：图片区域**底图原像素透出**（不进覆盖 mask、无净化色矩形盖图），
  文本框在 Word 中可直接点击编辑；
- `textSentinel`：图片墨迹主要落 `figureOverlap`（被图解释）；`likelyMissed` 逐条
  对照核实（同 §A 口径）。

**失败时看**：图拆碎/漏检 → 对照 `InkFigureDetectorTests` 与金标准漫画条用例，
真机照片固化 fixture；图压正文 → 阅读序问题（对照 `GoldenWorksheetEndToEndTests`
锚点链）；高保真盖图 → mask 通道问题（对照 `LayoutMaskBuilderTests`）。

## 汇总

| 场景 | 通过标准 | 结果（日期，iPhone 13 · iOS 26.7） |
|---|---|---|
| A 语法页 | structuredSuccess（或 reason 定案 + 回退质量兜底）、零假表、段落成段、漫画条单图原位、`wrong bus` 可搜（不带叹号）、哨兵不误报 | 待填 |
| B 真表格页 | 真表 `w:tbl`（iOS 26 真机首验）、containment 无静默、高保真浮动表格、档位持久化 + 切回流式生效、真表不误伤 | 待填 |
| C 图文混排页 | 图内联原位完整、高保真底图透出、哨兵以 figureOverlap 解释图墨迹 | 待填 |

**记录规则**：任一场景失败 → 按各节「失败时看」取证（Console 日志行原样抄录 +
导出 docx 留存），记录至下方「验收结果记录」，修复后本清单重验。**§A 的
`reconstructPath` 行是本周期最高杠杆取证——无论过否，先把该行抄进记录。**

## 验收结果记录（预留）

（按场景追加：日期 / 日志行抄录 / 肉眼结论 / 偏差与定案）
