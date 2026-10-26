# TODO · Zhixia

> 更新时间：2026-10-26。当前周期：**page-preprocess**（`spec/page-preprocess/`）。
> 历史交接 `SESSION-HANDOFF.md` 已退役：仍有价值的条目已并入本文件；其余文档见 `docs/17`、`docs/18`、`docs/19`。

## P0/P1 · 页面预处理（当前执行）

- [x] PP-T001 取证基线：真机/模拟器页外背景、页边偏差、文字行角度（`build/page-preprocess/baseline/`）。
- [x] PP-T002 `PageBoundaryDetector`：文档分割 + 墨迹否决 + 四角回退已接 `ImagePipeline` / `preprocess.json`，单测通过。
- [x] PP-T003 页外裁切：亮折页条检测 + 内容框 + 斜右边界 + 页级左缘内收已接。模拟器全图路径 `IMG_7542`：cropApplied=true、foldTrimU=0.090、foldTrimSource=bright_fold、文字损失 5.06%、textCoverage=1、输出 1752×2200；左侧折页条与木桌已去除，标题/页码保留。真机 iPhone 13：页级 quad（area 0.808）左缘内收 1% 页宽，`pageTextLeft=0.1056`、标题保留 0.68% 安全边、textCoverage=1、输出 1554×2200；页级表格参照按正立页识别为 `[[5,3]]`，裁切 JPEG 偶发 0 表时以「表格 bbox 在裁切线右侧」几何兜底（`geometry_clear`），最终增强页结构表 `[[5,2]]`、解析表格块 1、标题保留。证据：`build/page-preprocess/final-p0/`。
- [~] PP-T004 预处理指标：`PagePreprocessReport` + `PageBoundaryMetrics` + iPhone 13 / IMG_7542 baseline 已落；新增 pageTextLeft/pageLeftInset/tableSafetyReference/tableSafetyDecision/tableSafety{Original,Cropped}Shapes，汇总见 `build/page-preprocess/final-p0/summary.json`。待补像素级页外背景残留与可视化。
- [~] PP-T005 真机/模拟器 A/B：WPS 0.906224（2026-10-26 独立跑 `realUIBaseExportArtifact` + 新 WPS 渲染，`build/word-fidelity/realbase-wps-p0c-20261026b/`）与基线一致，未回退；真机页级左缘/表格结构 A/B 已闭环；真机 WPS 全流程验收归入暂缓的 PP-T032。整类顺序跑会触发已知 Vision 表格抖动，不得把该类产物当 WPS 基线。

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

## 暂缓 · 导出层重影（不在本周期）

- [ ] **G1** 可编辑字与背景字未完全重合：**直接原因**是擦除 mask 未覆盖全部原字/边缘残留；拍摄几何是上游放大因素。等 page-preprocess 拉直后，仍需单独做「残留墨迹率」验收与 mask 扩边/实心擦除；不能假设预处理自动解决。当前 WPS 0.906/0.907 已过门限。
- [ ] **G2** iOS 26.4.1 模拟器 `RecognizeDocumentsRequest` 对练习册表返回 0 表（iOS 27 正常）：补结构化回退或环境限制说明；当前按用户决定暂缓 iOS 26，只保证 iOS 27。
- [ ] **G2b** iOS 27 `GoldenWorksheet` 4 项失败：OCR 113 行、`LayoutAnalyzer` anchors=0、`InkFigureDetector` 只给右侧整栏大图；金标准“漫画条”落在书脊/空白窄带，疑似 iOS 26 figure 检测器的伪 figure 被写进夹具。**先记为已知测试债务**；产品级“右侧大图存在”仍通过。后续单独校准夹具或窄条 figure 检测，不阻塞 page-preprocess。
- [ ] **G3** 粗体行（Articles wanted / FUN ACTIVITIES）目前仍为常规字重；像素墨量推断误判率高，暂缓。
- [ ] **G4** 表格单元格左/上内边距、右上题头顶部裁切、`Exam advice` 位置仍有小偏差；等预处理/重影阶段一起看。
- [ ] **PP-T032（暂缓）** iPhone 13 真机全流程 + WPS/Word 验收；冷启动 ≤1.5s/页暂不压（当前 P1 236ms、暖机整页 1388–1395ms、首跑 1764ms）。真机全流程复测仍见“验证与交付债”。

## 验证与交付债

- [x] 更新 `Makefile` 测试基线为全量实际值：**484 total / 474 passed / 1 expected failure**（全量旧基线 479 + `TableGridGuardTests` 3 + `PageTextLineAnalyzerTests` 2；2026-10-26 P1/P2 测量证据）。已知 9 个失败见下。
- [~] 重跑 `make test`（iPhone 18 Pro / iOS 27）：**仍不绿**，稳定 9 failed = Golden 4 + `WordFidelityExportTests/realOCRExportArtifact()` 顺序抖动 + 4 个 Review/ReviewSplit preview 超时。已用「全量跳过 P1 测试」复跑，同样 9 个失败，确认不是 P1 引入；P1 测试串行化后单独/组合均 31/31、19/19 通过。
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
