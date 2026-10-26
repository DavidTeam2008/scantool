# 19 · 页面预处理与下一阶段优先级（2026-10-26）

> 状态：**当前周期**。执行清单见 [`TODO.md`](../TODO.md) 与
> [`spec/page-preprocess/tasks.md`](../spec/page-preprocess/tasks.md)。
> 上游：`docs/17`（Word 可编辑档迭代）、`docs/18`（h2oc 运行复盘）。

## 一、当前结论

- Word 可编辑档的真实 WPS 渲染已达标：
  - 模拟器（`original-base.jpg`）**0.906224**；
  - iPhone 13（真机 rendered 页）**0.907581**。
- 仍未解决的是**视觉重影**：背景图里的原字与可编辑文本没有严格重合。
- **直接原因**：按设计「可编辑文本区域的原字应被擦除」，所以只要画面上还能看到背景原字，
  就说明擦除覆盖失败（mask 未盖住全部墨迹/填充色错误/边缘残留），而不是设计允许两者共存。
- **上游原因**：拍摄纸张有折痕、页边不平行、文字行轻微弯曲；这些会让 OCR 行框和擦除 mask
  与真实墨迹错位，放大擦除失败。四角透视矫正不能拉直局部形变。
- 结论：预处理是合理优先项（同时提升识别准确率），但**不能假设预处理会自动消除重影**；
  重影需要在 mask 侧单独验收「残留墨迹率」，作为后续任务。
- 用户决定：**重影暂缓**；下一阶段先做照片预处理。

## 二、为什么先做预处理

当前链路：

```
相册/拍照 → 四角透视矫正 → 增强 → OCR → 可编辑版面还原 → Word
```

单应性矫正只把页面外框拉成矩形，不处理：

1. 纸张外的桌面/书脊/阴影；
2. 折痕/纸张弯曲导致的局部文字行倾斜；
3. 页边不直、上下/左右不平行；
4. 由此带来的 OCR 行切分、表格列边界、文本框定位误差。

这些问题同时影响**识别准确率**和**Word 重影**。先做预处理，后续再解决重影，收益更大。

## 二点五、P0 执行进展（2026-10-26）

- 模拟器全图路径已闭环：`IMG_7542.JPG` 亮折页条裁切 `foldTrimU=0.090`、文字损失 5.06%、`textCoverage=1.0`、输出 1752×2200；左侧漫画折条与木桌去除，标题/页码保留。
- 证据与汇总：`build/page-preprocess/final-p0/`。
- WPS（`original-base.jpg`）**0.906224**，与既有基线一致，未回退。
- 真机 iPhone 13 的边缘框已是页级 quad（area 0.808）。2026-10-26 完成页级左缘内收：去掉 1% 页宽左页边，`pageTextLeft=0.1056`，标题保留 0.68% 安全边，`textCoverage=1.0`，输出 **1554×2200**；标题、页码、表格全部保留。
- 真机表格安全门改为 EXIF/正立感知：页级 quad 先按同一 quad 正立矫正再识别，参照页表格 `[[5,3]]`；裁切 JPEG 偶发 0 表时，用「所有表 bbox 都在裁切线右侧」做几何兜底（`tableSafetyDecision=geometry_clear`）。最终增强页结构表 `[[5,2]]`、解析表格块 1、标题保留；输出 `build/page-preprocess/final-p0/device-after-inset.jpg`，报告 `device-report.json`、`device-page-inset.json`。
- 模拟器全图回归仍为 `fold_trim` / 1752×2200，`IMG_7544` 仍不回裁 1633×2200；WPS 基线独立重跑 **0.906224**（`build/word-fidelity/realbase-wps-p0c-20261026b/`）。P0 边界/裁切在本样张闭环；PP-T004 的像素级页外残留可视化仍待补，下一阶段转 P1 折痕/光照。

## 二点六、P1 执行进展（2026-10-26）

P1 已实现并与用户增强档隔离：

- `PaperIlluminationFlattener`：320px 分析图、4% tile 的 p85 背景场、p90 目标纸白（夹 0.86–0.95）、maxGain 1.5、sRGB `CIColorKernel`；只对浅色低饱和纸面做增益，彩色插图/深色墨迹保护。
- 只接在 `ImagePipeline.renderPage`：P0 裁切后、`EnhancementRecipe` 前；`ImagePipeline.apply()` 与 `WordFidelityExportTests` 的 `original-base.jpg` 路径零变化；`.original` 明确跳过。
- 表格保护：P0 裁切页复用表格安全门表框（`p0_crop_safety`）；未裁切页先用 `.enhance` 预览跑一次 `VisionDocumentStructureRecognizer` 拿表框（`vision_structure`）。若结构识别漏表，依次用 `TableContentGuard` 的深色表头块（向下扩 18% 页高）和 `TableGridGuard` 的长横/竖线网格兜底（`content_fallback` / `grid_fallback`）。gain map 对保护框（外扩 1.5%）强制 `gain=1`；仍无结果才跳过（`table_guard_unavailable`）。

**Gate 证据**

| 项 | 结果 |
|---|---|
| 合成单测 | 折痕/渐变/插图/平面/暗图 **5/5** |
| 模拟器 `IMG_7542` | P1 applied；背景场方差 0.002558→0.0000481；OCR 1812→1816；输出 1752×2200 |
| iPhone 13 `IMG_7542` | P1 applied、1 个表框保护；方差 0.002832→0.0000293（**−98.97%**）；输出 1554×2200 |
| 表结构（裁切） | off/on 各 **6/6** 次 `5×2`，不再复现 P1 直接丢表 |
| 表结构（未裁切） | iPhone 13 通用 guard 表 `5×2` off/on 各 **6/6**；guard 696ms、P1 288ms、整页 1276ms |
| 模拟器 `IMG_7544` | 通用 guard source `vision_structure`；P1 从跳过变为 applied，OCR 1807→1821，结构表 0→1 |
| OCR | 1797→1782；归一化字符召回 **99.93%**，仅 `21m/2lm` 数字/字母混淆；新增 2 条 ghost 垃圾行（G1 暂缓） |
| 性能 | P1 236ms；暖机整页 1388–1395ms；首跑 1764ms（PP-T032 冷启动优化暂缓） |
| WPS | 独立 realbase PNG 与 P0 证据 **byte-identical**，仍 **0.906224** |

证据：`build/page-preprocess/p1-device/final-summary.json`、
`build/page-preprocess/p1-device/final-p1-device-{off,on}.jpg`、
`build/page-preprocess/final-p0/summary.json`、
`build/word-fidelity/realbase-wps-p1-20261026b/`。

**已知限制**

- 通用 guard 已有深色内容块/网格二级兜底，但仍不能覆盖“无表头、无边框”的表格；识别/兜底全空时 P1 仍可能无 mask 执行。
- 未裁切页 guard 需要额外 `.enhance` 预览 + 结构识别；内容/网格兜底会增加耗时。真机 vision 路径 696ms；模拟器 content fallback 冷启动约 2.1s，整页 4.4s；PP-T032 已暂缓。
- P1 可能让纸面 show-through/ghost 更明显；G1 仍暂缓。
- 冷启动 `CIColorKernel` 编译在模拟器首跑可达 1438ms；真机最终 P1 236ms，整页首跑 1764ms；PP-T032 冷启动优化已暂缓。

## 二点七、P2 测量阶段（2026-10-26）

P2 先做**可量化、不可逆操作前的测量**，不直接上 warp：

- 新增 `PageTextLineAnalyzer`：`VNDetectTextRectanglesRequest` 四角 → 有符号行角、水平带；接入 `renderPage` 的 `preprocess.json`。
- iPhone 13 `IMG_7542` rendered：70 行、24 带，文字行中位 **0.49°**、p90 **1.11°**、max 2.01°。
- 模拟器 `IMG_7544` rendered：71 行、24 带，中位 **0°**、p90 **1.09°**、max 3.83°。
- 模拟器 `IMG_7542` rendered：70 行、24 带，中位 **0.62°**、p90 **1.12°**。
- 报告集成开销：约 **41ms/页**（模拟器），不改变像素。
- 结论：未达 Gate P2（中位 ≤0.3°、p90 ≤0.8°）；下一步是 T021 的局部水平带矫正，不能直接整页旋转（会破坏页边水平/垂直约束）。
- T021 原型（局部垂直 shear）结果：设备表格页中位 0.49°→0、p90 1.11°→1.00，但表结构 1→0（6/6）；无表 `IMG_7544` p90 1.09°→0.44°，但 OCR 1807→1775。两项都不可接受，原型**未启用**；需要 table-aware 校验和 OCR 调参后再接。
- 证据：`build/page-preprocess/p2-analysis.json`、`build/page-preprocess/p2-integration-summary.json`、`build/page-preprocess/p2-summary.json`。

## 三、优先级

### P0（当前，先做）

- 页面边界检测（文档分割优先，四角回退）。
- 页外裁切（1% 安全边；墨迹召回不足自动回退）。
- 指标与证据：页外背景占比、页边直线度/平行度、文字行角、墨迹召回、耗时。

**判定**：页外背景 <2%，墨迹召回 ≥99%，WPS 分数不低于 0.906/0.907。

### P1

- 折痕/光照压平：背景场估计 + 除法，排除 figure/artwork/表格；不改旧增强档；未裁切页走通用表格 guard，识别失败才跳过。
- 详细结果与限制见“二点六”。

### P2

- 测量阶段已落：文字行四角/水平带/行角写入报告（见二点七）。
- 下一步：水平带局部平移/轻微旋转；页边垂直约束；失败回退不矫正。
- 页边直线度/平行度 ≤0.5% 短边，行角中位 ≤0.3°；当前未达，矫正未接。

### P2.5（预研，不阻塞）

- 评估 Core ML / 开源端侧视觉模型：页面分割、文档去弯、折痕/阴影复原。
- 只接受输出 mask / 位移场 / 置信度的模型，后处理仍走确定性几何；默认 feature flag 关闭。
- LLM/VLM 不直接生成页面像素：不可逐像素对齐、可能改写文字/插图，延迟/内存也不适合 iPhone 13。
- 生成式 diffusion 只做对照，不进入默认链路。

### P3

- 曲面网格（仅 P2 不足时）、10~20 张多条件样张、真机 WPS/Word（PP-T032 暂缓）。

**暂缓**：导出层重影 G1（2026-10-26 mask 与全局 tone/contrast 实验均未过 WPS 门限；ghost 主要是 show-through；下一步需局部背景/透印复原并重定视觉保真指标）；粗体推断 G3；表格内边距/题头裁切 G4；iOS 27 Golden 窄条 figure 夹具债务 G2b。详见 `TODO.md` 与 `build/word-fidelity/g1-experiments/NOTE.md`。

## 四、h2oc（`.harness2`）在本任务中的作用

`h2oc` 是仓库内的 **agent harness 迭代工具**，不是 Google 依赖，也不进入 App 运行时。

它提供的帮助：

1. **确定性验收任务**：把 `make editable-fidelity ...` 写成可重复 verify，并保护
   `WordFidelityExportTests.swift` / `Tools/word-fidelity/`；让多轮 agent 改动有同一门限。
2. **运行隔离与经验库**：`.harness2/runs/...` 保存每轮 diff/trajectory/verify；被选中的 harness
   和 `EXPERIENCE.md` 存在 `.harness2/library/`，后续任务可复用。
3. **暴露验证盲区**：验收命令只跑 `WordFidelityExportTests`；h2oc 经验明确提醒
   **`DocxRestoredLayoutTests` 必须单独跑**，否则改了测试也不会在 gate 里暴露。
4. **跨任务经验**：`EXPERIENCE.md` 给出了可迁移教训——
   > 当验收命令只执行测试子集、而任务允许修改子集外的测试文件时，必须额外执行本次改过的每个测试类
   > （具体命令 `make test-only T=<Class>`），并在最后一次编辑后验证。
   证据：带该指令的 run 在改完测试后跑了对应类并修到 21/21；未带的 run 改了测试但从未运行。
   confidence = medium（多个组件同时变化，无法完全隔离，但行为对比直接且重复）。

它**没有**做到的：
- 0.961/0.965 是 QuickLook 代理分数，不是 WPS 真实验收；
- 最终 WPS 0.906/0.907 是本轮人工 WPS 渲染 + SSIM 得到，h2oc 未覆盖；
- 其 `k=1` 只有一个被选 harness，跨任务泛化证据仍有限。

## 五、交付顺序

1. P0 页面边界/裁切 + 指标；
2. P1 折痕/光照；
3. P2 页边拉直/行矫正；
4. P3 多条件样张 + 真机 WPS/Word；
5. 之后再评估 G1 重影。
