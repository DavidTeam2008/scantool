# TODO · Zhixia

> 更新时间：2026-10-27。当前周期：**page-preprocess**（`spec/page-preprocess/`），下一阶段重点：**P0.1 边框/背景单次收敛**。
> 历史交接 `SESSION-HANDOFF.md` 已退役：仍有价值的条目已并入本文件；其余文档见 `docs/17`、`docs/18`、`docs/19`。

## P0/P1 · 页面预处理（当前执行）

- [x] PP-T001 取证基线：真机/模拟器页外背景、页边偏差、文字行角度（`build/page-preprocess/baseline/`）。
- [x] PP-T002 `PageBoundaryDetector`：文档分割 + 墨迹否决 + 四角回退已接 `ImagePipeline` / `preprocess.json`，单测通过。
- [x] PP-T003 页外裁切：亮折页条检测 + 内容框 + 斜右边界 + 页级左缘内收已接。模拟器全图路径 `IMG_7542`：cropApplied=true、foldTrimU=0.090、foldTrimSource=bright_fold、文字损失 5.06%、textCoverage=1、输出 1752×2200；左侧折页条与木桌已去除，标题/页码保留。真机 iPhone 13：页级 quad（area 0.808）左缘内收 1% 页宽，`pageTextLeft=0.1056`、标题保留 0.68% 安全边、textCoverage=1、输出 1554×2200；页级表格参照按正立页识别为 `[[5,3]]`，裁切 JPEG 偶发 0 表时以「表格 bbox 在裁切线右侧」几何兜底（`geometry_clear`），最终增强页结构表 `[[5,2]]`、解析表格块 1、标题保留。证据：`build/page-preprocess/final-p0/`。
- [~] PP-T004 预处理指标：`PagePreprocessReport` + `PageBoundaryMetrics` + iPhone 13 / IMG_7542 baseline 已落；新增 pageTextLeft/pageLeftInset/tableSafetyReference/tableSafetyDecision/tableSafety{Original,Cropped}Shapes，汇总见 `build/page-preprocess/final-p0/summary.json`。待补像素级页外背景残留与可视化。
- [~] PP-T005 真机/模拟器 A/B：WPS 0.906224（2026-10-26 独立跑 `realUIBaseExportArtifact` + 新 WPS 渲染，`build/word-fidelity/realbase-wps-p0c-20261026b/`）与基线一致，未回退；真机页级左缘/表格结构 A/B 已闭环；真机 WPS 全流程验收归入暂缓的 PP-T032。整类顺序跑会触发已知 Vision 表格抖动，不得把该类产物当 WPS 基线。

## P0.1 · 边框/背景单次收敛（2026-10-27 起，下一阶段重点）

**背景**：真机对 `docs/media/IMG_7544.jpg` 连续做三次“扫→保存→再扫”，依次去掉右/下、上、左折页，最终到 1575×2051；目测标题、页码、页脚、两个表、照片仍在，macOS Vision OCR 字符数 1752→1777（仅作粗筛）。这说明目标裁切区域存在且稳定，当前问题主要是**单次检测欠裁**，不是无法识别页面。多步方案以多次重编码/降采样（最终面积仅原图 27.8%）换取 coarse-to-fine，不能作为正式链路。评估见 `docs/20-border-crop-convergence.md`。

- [x] **PP-T050 复现与取证**：固定 `IMG_7544.jpg` 与 `myself-1/2/3` 三张中间图，走实际 `renderPage`（整图 draft）记录裁切框、尺寸、OCR、表格安全门；证据落 `build/page-preprocess/crop-convergence/T050-*`、`T050-intermediate-summary.json`。原图整图 draft：`cropSource=content_envelope`、`cropApplied=true`、`textCoverage=1`、输出 **1694×2200**（含白底画布）；三张中间图 1 表格签名不一致时改为框外刷白、2/3 可裁；页面级 draft 也能裁掉顶部/底部背景；对第一轮输出再跑一次，输出尺寸仍 1694×2200，幂等性通过。
- [~] **PP-T051 单次纸张/内容包络**：新增 `PageContentEnvelopeDetector`，始终计算纸面边界 + 强内容包络（暗色/高饱和像素，文字锚点上/左），整图 proposed 也参与；不再只在 fold/detection 变化时裁。原图输出去掉顶部/左侧页外背景，同时保留标题/页码/表格/照片。实测细节：纸面顶部约 1.7%、文字上/左锚各 0.8%；下缘按文字 +0.8% 收边，页面级 draft 不再跳过包络。**真机 round1 回归**（`docs/media/optimize/round1-1-...rendered.jpg`，1561×2200）发现页级自动 quad 仍留顶部/底部背景；已改为自动 page-level draft 也走包络，表格不安全时框外刷白。**待用户重新安装当前构建后真机复测**。
- [~] **PP-T052 可选 refine**：已接 **table-aware refine**（表格 bbox 扩框后重试一次，仍不安全回退）；本样张 `envelopeRefineApplied=false`，因为内容包络本身通过安全门，没有触发第二次。背景残留 refine 仍待后续；预算/不重复 P1/JPEG 的约束已落实。
- [x] **PP-T053 内容安全门**：`textCoverage/envelopeTextCoverage`、表格安全门 + `tablesClear(of:)`（含 Vision y 翻轴）+ 表格 bbox retry；中间图/页面级 draft 表格结构不一致时 `cropApplied=false`，改为“保留原页几何并把候选框外背景刷白”（`backgroundWhitened=true`），不把表格交给裁切后的结构识别重新解释。标题/页码保留；对第一轮输出再跑：尺寸 1694×2200→1694×2200，幂等性通过；真机全流程仍待 PP-T032。
- [x] **PP-T054 扫描观感**：`PagePreprocessRecipe.scanCanvasBorderRatio=0.006`，裁切成功后加白底画布；单测/集成测试验证左上角近白；只影响 `renderPage`，`apply`/WPS 夹具不变。WPS realbase 仍 **0.906224** 且 PNG byte-identical。

## P1 · 折痕与光照

- [x] PP-T010 背景场估计 + 折痕阴影压平：`PaperIlluminationFlattener` 已接 `renderPage`；320 分析图、4% tile p85 背景场、p90 目标（0.86–0.95）、maxGain 1.5、sRGB `CIColorKernel`；合成折痕/渐变/插图/平面/暗图 5/5 通过，真实页覆盖 0.86–0.89。
- [x] PP-T011 与 `EnhancementRecipe` 隔离：只改 `renderPage`，`apply()` / Word 夹具路径不变；`.original` 跳过；P0 表格安全门给出的表框内增益强制为 1（外扩 1.5%）。
- [x] PP-T013 扩展 P1 表格 guard 覆盖：未裁切页用 `.enhance` 预览 + `VisionDocumentStructureRecognizer`（`vision_structure`）；漏表时 `TableContentGuard` 深色表头块 / `TableGridGuard` 网格兜底（`content_fallback` / `grid_fallback`）。真机未裁切 `IMG_7542` 表 `5×2` 6/6；视觉结构漏检模拟下 content fallback 仍 6/6。模拟器 `IMG_7544` 结构漏表时 content fallback 保护 3 块、P1 applied。证据：`build/page-preprocess/p1-guard/final-summary.json`。
- [~] PP-T012 真机/模拟器 A/B：iPhone 13 裁切路径背景场方差 0.002832→0.0000293（-98.97%），表结构 5×2 在 off/on 各 6/6 次稳定，OCR 归一化字符召回 99.93%；未裁切路径表结构 6/6、字符召回 99.73%。P1 236–288ms、暖机整页 1276–1395ms，首跑 1764ms（PP-T032 冷启动优化已暂缓）。WPS 独立 realbase PNG 与 P0 证据 **byte-identical**，仍 **0.906224**。**未闭环**：通用 guard 的 Vision 假阴性、ghost 可见性（G1）。证据：`build/page-preprocess/p1-device/final-summary.json`、`build/page-preprocess/p1-guard/final-summary.json`、`build/word-fidelity/realbase-wps-p1-20261026b/`。

## P2 · 页边拉直与文字行矫正

- [~] PP-T020 文字行 bbox → 局部倾斜/水平带：`PageTextLineAnalyzer`（`VNDetectTextRectanglesRequest` 四角，不跑 OCR）已接 `renderPage` 报告；表格 bbox 融合仍待做。
- [~] PP-T021 水平带平移 + 页边垂直约束：已做局部垂直 shear 原型；设备表格页行角中位 0.49°→0、p90 1.11°→1.00，但表结构 1→0（6/6）；无表页 p90 1.09°→0.44° 但 OCR 1807→1775。**未启用**，需 table-aware 校验 + OCR 调参。证据 `build/page-preprocess/p2-summary.json`。
- [~] PP-T022 页边直线度/平行度/行角达标：已量测；iPhone 13 文字行中位 **0.49°**、p90 **1.11°**，模拟器 `IMG_7544` 中位 0°、p90 1.09°，尚未达 0.3°/0.8° 门限。
- [ ] PP-T023 接入 OCR 前 rendered 图，表格 2/3 列稳定性回归。

## P2.5 · 端侧视觉模型预研（不阻塞 P0/P1/P2）

- [ ] **PP-T040** 评估 Core ML / 开源端侧视觉模型用于页面分割、文档去弯（dewarp）、折痕/阴影恢复：
  - 只考虑**像素/几何模型**（分割、光流、文档去弯、图像复原），不以 LLM/VLM 生成像素；
  - 必须纯离线、Core ML/ANE 可跑、iPhone 13 内存/时延/热约束内；
  - 模型体积、License、训练数据与可解释性先过审；
  - 与 Vision + 经典几何做 A/B：页边直线度、行角、OCR 召回、WPS SSIM、耗时；
  - **默认关闭 feature flag**，只有全面胜出才替换/并入默认链路。
- [ ] **PP-T041** 候选模型只做“密集位移场/分割 mask”，不直接生成最终页面；生成式修复（diffusion）仅用于对比，不进入默认链路（防止篡改/幻觉）。

## P3 · 规模化与真机

- [ ] PP-T030 曲面网格（仅在 P2 不足时）。
- [ ] PP-T031 10~20 张多条件样张回归。
- [ ] PP-T033 文档/AGENTS/基线最终同步。

## G1 · 验收与透印复原（建议顺序，暂缓执行，不抢 P0.1）

- [ ] **G1-A GhostMetrics**：新增 `residualInkRate`（OCR 行框内擦除后残留）、`showThroughContrast`（文本/表格/插图外背景透印局部对比度）、`ghostInkOutsideText`；输出 JSON + 前后 crop，现有 WPS 0.906224 仅作兼容门限，不作为唯一目标。
- [ ] **G1-B 干净参考**：至少一个 fixture 做人工/半自动清理，或用“干净页 + 合成背面透印”建立可计算真值；否则无法证明透印下降不是把纸面/表格一起洗白。
- [ ] **G1-C 局部复原**：只输出低频背景场或 mask，保护表格/照片/深色装饰，失败回退原图；验收要求 ghost 指标显著下降、WPS 不低于 0.906224、OCR/表格不回退。经典方法失败后再评估 P2.5 端侧模型。

## 暂缓 · 导出层重影（不在本周期）

- [ ] **G1** 可编辑字与背景字未完全重合：2026-10-26 的 mask 扩边/实心擦除实验（solid 0.904239、lineExpansion 0.008 0.903989、inkThreshold 35 0.905826）均低于 **0.906224**；对 baked base 做低饱和透印压制也只得 0.8987/0.8908，低于 0.90。结论：WPS 可见 ghost 主要是纸面 show-through/透印，位于 OCR 行框之外；全局 tone/contrast 会伤表格/照片，不能作为 G1 解。下一步按上面的 G1-A/B/C 顺序执行；证据：`build/word-fidelity/g1-experiments/NOTE.md`。
- [ ] **G2** iOS 26.4.1 模拟器 `RecognizeDocumentsRequest` 对练习册表返回 0 表（iOS 27 正常）：补结构化回退或环境限制说明；当前按用户决定暂缓 iOS 26，只保证 iOS 27。
- [ ] **G2b** iOS 27 `GoldenWorksheet` 4 项失败：OCR 113 行、`LayoutAnalyzer` anchors=0、`InkFigureDetector` 只给右侧整栏大图；金标准“漫画条”落在书脊/空白窄带，疑似 iOS 26 figure 检测器的伪 figure 被写进夹具。**先记为已知测试债务**；产品级“右侧大图存在”仍通过。后续单独校准夹具或窄条 figure 检测，不阻塞 page-preprocess。
- [ ] **G3** 粗体行（Articles wanted / FUN ACTIVITIES）目前仍为常规字重；像素墨量推断误判率高，暂缓。
- [ ] **G4** 表格单元格左/上内边距、右上题头顶部裁切、`Exam advice` 位置仍有小偏差；等预处理/重影阶段一起看。
- [ ] **PP-T032（暂缓）** iPhone 13 真机全流程 + WPS/Word 验收；冷启动 ≤1.5s/页暂不压（当前 P1 236ms、暖机整页 1388–1395ms、首跑 1764ms）。真机全流程复测仍见“验证与交付债”。

## 验证与交付债

- [x] 更新 `Makefile` 测试基线为全量实际值：**490 total / 481 passed / 1 expected failure**（2026-10-27 P0.1 新增 `PageContentEnvelopeDetectorTests` 2、`PageCropSafetyTests` +1、`PageCropConvergenceTests` 3）。已知 9 个失败见下。
- [~] 重跑 `make test`（iPhone 18 Pro / iOS 27）：**490 total / 481 passed / 1 expected / 8 failed**（已知 flaky 集合 7–9 个）；当前失败为 Golden 4 + `WordFidelityExportTests/realOCRExportArtifact()` 顺序抖动 + 2 个 Review/ReviewSplit preview 超时。新增 P0.1 测试均通过；全量不绿是既有债务，不是 P0.1 引入。
- [ ] `WordFidelityExportTests` 整类顺序运行时 `realOCRExportArtifact` 出现 `structureTables=0`（单独跑通过）；按已知 iOS 27 模拟器 Vision 表格波动记录，不削弱断言。
- [ ] P1 guard 残余假阴性：无表头、无边框的表格仍可能漏检；需要更强的版面/线条模型。
- [ ] T004 真机/模拟器 OCR 表格回归在 iOS 26.4.1 的环境差异记录。
- [ ] Word 桌面版（Microsoft Word）渲染抽样；当前只有 WPS。
- [ ] 真机 App UI 全流程（相册→收藏→版面还原→Word）复测；当前真机测试是 parser/export 级。
- [ ] 提交前确认 `build/word-fidelity/` 证据不清理、`docs/media/Zhixia-20261024-1958.docx` 去留。

## h2oc 经验（跨任务）

- 参考 `.harness2/library/k1/agg/word-fidelity/harnesses/editable-word-fidelity/EXPERIENCE.md`。
- 可复用教训：**验收命令只跑子集时，必须额外执行本次改过的每个测试类**（`make test-only T=<Class>`），并在最后一次编辑后验证；仅“跑仓库验证命令”会漏掉被改测试。
- 另一条：`make editable-fidelity` 的 0.961/0.965 是 QuickLook 代理，**不是 WPS 验收**；最终必须用 WPS 真实渲染。
