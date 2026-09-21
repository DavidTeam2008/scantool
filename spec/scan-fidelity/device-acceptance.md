# 真机自验清单（scan-fidelity · device acceptance）

> 自动化已证明的（回归 #5，2026-09-20）：全量 **279 passed + 1 expected failure
> （known issue）+ 0 failed**（xcresult `Test-Zhixia-2026.09.20_16-49-52-+0800.xcresult`；
> 基线链 255 → 260 → 262 → 266 → 277 → 279，只增不减）。单测覆盖行级字号
> （`LineTypographyPerLineTests`）、行聚类与微扰稳定（`OnDeviceReadingOrderRowClusteringTests`）、
> 搜索回填（`ReconstructTests`）、解析式映射（`OverlaySpaceMapTests`）、引导判定
> （`GuidanceDirectiveTests`）与 OOXML 行级/分段断言（`DocxRestoredLayoutTests`）。
> 本清单只覆盖**必须真机 + 肉眼 + Word** 的部分：SC-001 ~ SC-006。
> 前置：版面还原链路本身按 `spec/layout-engine/device-acceptance.md` 已验收。

## 准备

- 真机一台（iOS 18+）。
- 电脑装有 **Microsoft Word 2016+ / Microsoft 365**（下划线空格 run、逐行 `w:sz`、
  `w:line` exact 以 Word 为准；WPS/Pages 仅作参考，不作为不通过的依据）。
- Console.app 连接真机（overlay 诊断日志抓取见文末，debug 级**必须**开
  Include Debug Messages）。
- 样张：**取证同款双栏英语练习册页**（上轮 SC-001/SC-002 不通过的取证页，最好
  同一页——对照上轮 `~/Downloads/Zhixia-9月19日 扫描 · 5/7/8` 三份 DOCX 的缺陷）。
  密集试卷页 / 简单页的加测（上轮 SC-003/SC-004 未测项）视方便选做，不阻塞本轮。

## SC-001 同款练习册页：0 叠字 / 0 碎片 / 0 乱序 + 下划线

**拍什么**：取证同款双栏英语练习册页（含对话填空行）。

**步骤**：扫描 → 整理 → 还原（版面还原档）→ 导出 DOCX → Word 打开，预览与 Word
并排对照原页。

**通过标准**：

1. **0 行叠字**——标题行与正文行同块混排不再互相压行（字号行级化：每行字号
   ≤ 该行行槽 × 1.05；上轮 ·8 标题块 19.5pt 字号 / 13.1pt 行槽 的 49% 叠字必须消失）；
2. **0 孤儿碎片块**——对话行同排分段（如 `A1 / A2`）聚合为同一文本行，
   不再出现 `x=340 "the maths problems?"` 这类漂移碎片（y 跨度重叠率聚类）；
3. **0 乱序拼接**——语序与原页一致（行内 minX 序 + 跨行不串接；上轮
   `"physics exercises for homework. three hours doing those"` 式拼接必须消失）；
4. **填空空隙以下划线呈现**——对话行段间空档在预览与 Word 中都显示为下划线
   占位（Word 中可编辑的带下划线空格 run），不再是「缺词」读感；
5. 预览与导出**行距视觉一致**（同一行几何推导源，双端同构）。

**不构成不通过**：OCR 字符级混淆（`I`/`l`/`1`、`O`/`0`、`rn`/`m`）——FR-012
已知限制，明确接受不纠错（记录于 `docs/09-project-handbook.md` §6.9）。

## SC-002 同页三扫：结构稳定

**拍什么**：与 SC-001 同一页，**连续扫描 3 次**（每次重新取景，允许手持微抖）。

**步骤**：三次独立走完 扫描 → 还原 → 导出，逐份检查。

**通过标准**：3 份导出**全部**满足 SC-001 的三项结构要求（0 叠字 / 0 碎片 / 0 乱序；
不要求字节级一致——块数允许小幅波动，但对话行不得重新拆散）。

**对照**：上轮同页三扫块数 6/5/11 且碎片漂移；本轮聚类判定带合取容差 +
±5% 微扰稳定测试（固定种子三组变体）已过，真机三扫是最终证据。

## SC-003 全文搜索命中 + 标题自动更新

**步骤**：任选一页完成**重建**（版面还原）→ 回到文档列表。

**通过标准**：

1. 在文档列表搜索该页**内容关键词**（选正文中出现的词，如练习册对话里的
   人名 / 短语）——文档**命中**（上轮 `ocrSearchBlob` 恒空、搜什么都不中）；
2. 文档标题自动更新为**首行摘要**，不再是「扫描 · N」（重建完成即回填，
   与手动 OCR 流程同路径；表格页搜表格里的数值也应命中——blob 取 `displayText`）。

## SC-004 取景边框可见 + 对齐（含 overlayProbe 诊断对照）

**步骤**：真机对准书本/练习册取景，移动手机观察边框；再切**暗光**（拉窗帘/关灯）
与**亮背景**（白墙/窗边）两种环境各看一次。

**通过标准**：

1. **角标可见**——四角 L 形粗括号（白 4pt + 暗底衬）始终可见，框外压暗
   （tracking 0.25 / locked 0.45）把书页区域从背景中分离出来；
2. **实时跟随**——移动手机时边框跟随书页边缘，无迟滞跳变；
3. **肉眼对齐**——边框四角与书页四角对齐（解析式映射：照片→视频→屏幕两步
   合成；上轮「框系统性偏窄/不可见」的探针失效路径已退役）；
4. 暗光与亮背景都可辨识（暗底衬描边就是为低对比背景准备的）；
5. **tracking 与 locked 有明确视觉区分**——检测中虚线整框 + 轻压暗，锁定后
   实线角标 + 加深压暗、虚线消失。

**诊断对照（SC-004 证据链，可选但建议做一次）**：Console.app 过滤
`subsystem:com.david.Zhixia category:capture`（开 Include Debug Messages）：

- `overlayProbeAnalytic viewSize=… scaleX=… scaleY=… offsetX=… offsetY=…`——
  解析式映射的**渲染真值**参数；
- `overlayProbeDelta dScaleX=… dScaleY=… dOffsetX=… dOffsetY=…`——退役探针
  （`layerRectConverted`）与解析值的逐轴偏差。

**判读**：肉眼对齐为准（探针已不参与渲染）；`overlayProbeDelta` 各轴 ≈ 0 →
两条路径互相印证；`overlayProbeDelta probe=unavailable` → 探针不可用，
**不是缺陷**（探针仅为诊断对照源，这正是它被退役的原因）；若肉眼不对齐，
记录当时的 `overlayProbeAnalytic` 参数与 `geometry videoAspect=… photoAspect=…`
行（会话实测宽高比），交回开发定位。

## SC-005 四情形提示方向

**步骤**：文档模式取景，依次制造四种情形，观察状态区文案：

| 情形 | 制造方法 | 期望文案（zh） |
|---|---|---|
| 太近 / 裁切 | 把书贴近视场，边框近满幅或贴边 | 「再往后移一点，把书拍完整」（backOff） |
| 太远 | 把书拿远，边框缩到很小 | 「靠近一点」（closer，新文案） |
| 偏移 / 丢失 | 把书移出取景框 | 「对准纸张」（searching） |
| 对准 | 正常距离持稳至锁定 | 「已对准，轻点快门」（locked） |

**通过标准**：

1. 四种情形文案**各不相同且方向正确**（提示的移动方向就是纠正该情形的方向）；
2. **临界不闪烁**——在「太远 ↔ 对准」临界距离附近缓慢前后移动，文案不快速
   抖动切换（面积滞回：进入 closer 需面积 < 0.07、退出需 > 0.09，中间保持）；
3. 提示**即时更新**——状态切换后文案立刻跟随（同帧推导，无残留）；
4. 证件模式提示仍为正/反面文案（FR-011：不参与四态引导，行为不变）。

## SC-006 基线核对（自动化）

```bash
export DEVELOPER_DIR=/Volumes/DevDisk/Applications/Xcode.app/Contents/Developer
OTHER_SWIFT_FLAGS="-disable-sandbox" xcodebuild test \
  -project Zhixia.xcodeproj -scheme Zhixia \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -skipPackagePluginValidation -skipMacroValidation
```

**通过标准**：**279 passed + 1 expected failure（known issue）+ 0 failed**，
不低于本轮交付基线（原始基线 255，只增不减）。FR-001~FR-011 自动化覆盖映射：

| FR | 自动化锚点 |
|---|---|
| FR-001 行级字号同源 | `LineTypographyPerLineTests`（逐行 字号 ≤ 行槽 × 1.05 性质）+ `DocxRestoredLayoutTests`（densePage / ratio / heterogeneousLines 逐行 w:sz） |
| FR-002 同视觉行聚合 | `OnDeviceReadingOrderRowClusteringTests`（同排异高合并 / 相邻行不合并） |
| FR-003 段序与不串行 | `OnDeviceReadingOrderRowClusteringTests`（行内 minX 序 / 无跨行串接） |
| FR-004 空隙下划线占位 | `LineTypographyPerLineTests`（gapPlaceholderSpaces 阈值两侧与换算）+ `OnDeviceReadingOrderRowClusteringTests`（segments 采集 / 空隙超阈值）+ `DocxRestoredLayoutTests.segmentGapsRenderUnderlinePlaceholderRuns`（导出下划线 run XML） |
| FR-005 多扫结构稳定 | `OnDeviceReadingOrderRowClusteringTests`（三组 ±5% 固定种子微扰变体） |
| FR-006 搜索回填 | `ReconstructTests`（blob 聚合 / 成功回调一次 / 失败静默） |
| FR-007 边框实时显示 | `OverlaySpaceMapTests` + `CaptureFallbackTests.overlayMapsAnalytically`（视觉部分由 SC-004 真机验收） |
| FR-008 屏幕位置对齐 | `OverlaySpaceMapTests`（宽高比全交叉 + y-down 不翻转 + 两种放置机制）+ SC-004 诊断对照 |
| FR-009 方向感知提示 | `GuidanceDirectiveTests`（四态穷举 + suspicious 优先级）+ SC-005 真机验收 |
| FR-010 滞回去抖 | `GuidanceDirectiveTests`（0.065→closer / 0.08 保持 / 0.095→locked 穿越 + searching 复位） |
| FR-011 证件模式不变 | `EdgeDetectionStrategyTests.idCardWindowUnchanged`（窗口语义）+ T020 idMask 渲染路径代码级保持 |
| FR-012 字符混淆不纠错 | 已知限制记录于 `docs/09-project-handbook.md` §6.9（明确接受，无自动化要求） |

## 日志抓取指引（ZhixiaLog.capture 类目）

拍摄侧日志走 os_log：subsystem `com.david.Zhixia`、category `capture`、级别
**debug**（默认不显示，必须开 debug）。SC-004 相关条目：`geometry`（会话实测
宽高比）、`overlayProbeAnalytic` / `overlayProbeDelta`（映射诊断对照）。

**Console.app**：

1. 真机连线 → Console.app 选中设备；
2. 搜索框输入：`subsystem:com.david.Zhixia category:capture`；
3. 菜单 **Action → Include Debug Messages** 勾上；
4. 进取景页复现，实时滚动；选中行可拷贝存档。

**命令行**：

```bash
log stream --debug --predicate 'subsystem == "com.david.Zhixia" AND category == "capture"' \
  | grep --line-buffered 'overlayProbe'
```

## 结果记录

每项验完打勾并注明环境：

| 项 | 结果 | 设备 / iOS / Word 版本 | 备注 |
|---|---|---|---|
| SC-001 | ☐ 未验 | | |
| SC-002 | ☐ 未验 | | |
| SC-003 | ☐ 未验 | | |
| SC-004 | ☐ 未验 | | |
| SC-005 | ☐ 未验 | | |
| SC-006 | ☑ 通过（回归 #5：279 passed + 1 known issue + 0 failed） | 模拟器 iPhone 17 Pro / - | xcresult Test-Zhixia-2026.09.20_16-49-52-+0800.xcresult |
