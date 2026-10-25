# TODO · Zhixia

> 更新时间：2026-10-25。当前周期：**page-preprocess**（`spec/page-preprocess/`）。
> 历史交接 `SESSION-HANDOFF.md` 已退役：仍有价值的条目已并入本文件；其余文档见 `docs/17`、`docs/18`、`docs/19`。

## P0 · 页面预处理（当前执行）

- [ ] PP-T001 取证基线：真机/模拟器页外背景、页边偏差、文字行角度（`build/page-preprocess/baseline/`）。
- [~] PP-T002 `PageBoundaryDetector`：文档分割 + 墨迹否决 + 四角回退已实现并有 3 项单测；待接 `ImagePipeline` / `preprocess.json`。
- [X] PP-T003 `ImagePipeline` 页外裁切：退化/近整图时接 `PageBoundaryDetector`，检测后外扩 1% 安全边并写 `*.preprocess.json`。iPhone 13 original 2939×3961 → 1647×2200、94ms、顶部裁 2.7%。待补墨迹召回回退。
- [~] PP-T004 预处理指标工具：`PagePreprocessReport` 已含 textCoverage/outsideAreaRatio/edgeAngles/parallelErrors；iPhone 13 textCoverage 1.0、页外 0.89%、上边角 1.02°、298ms。待补像素级背景残留汇总。
- [ ] PP-T005 真机/模拟器 A/B；WPS SSIM 不低于 0.906/0.907。

## P1 · 折痕与光照

- [ ] PP-T010 背景场估计 + 折痕阴影压平（排除 figure/artwork）。
- [ ] PP-T011 预处理档与 `EnhancementRecipe` 隔离，旧增强零行为变化。
- [ ] PP-T012 折痕区方差 / OCR 召回 / WPS A/B。

## P2 · 页边拉直与文字行矫正

- [ ] PP-T020 表格/文字行 bbox → 局部倾斜/水平带。
- [ ] PP-T021 水平带平移 + 页边垂直约束；失败回退。
- [ ] PP-T022 页边直线度/平行度/行角达标。
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
- [ ] PP-T032 iPhone 13 全流程 + WPS/Word 验收；≤1.5s/页。
- [ ] PP-T033 文档/AGENTS/基线最终同步。

## 暂缓 · 导出层重影（不在本周期）

- [ ] **G1** 可编辑字与背景字未完全重合：**直接原因**是擦除 mask 未覆盖全部原字/边缘残留；拍摄几何是上游放大因素。等 page-preprocess 拉直后，仍需单独做「残留墨迹率」验收与 mask 扩边/实心擦除；不能假设预处理自动解决。当前 WPS 0.906/0.907 已过门限。
- [ ] **G2** iOS 26.4.1 模拟器 `RecognizeDocumentsRequest` 对练习册表返回 0 表（iOS 27 正常）：补结构化回退或环境限制说明；当前按用户决定暂缓 iOS 26，只保证 iOS 27。
- [ ] **G2b** iOS 27 `GoldenWorksheet` 4 项失败：OCR 113 行、`LayoutAnalyzer` anchors=0、`InkFigureDetector` 只给右侧整栏大图；金标准“漫画条”落在书脊/空白窄带，疑似 iOS 26 figure 检测器的伪 figure 被写进夹具。**先记为已知测试债务**；产品级“右侧大图存在”仍通过。后续单独校准夹具或窄条 figure 检测，不阻塞 page-preprocess。
- [ ] **G3** 粗体行（Articles wanted / FUN ACTIVITIES）目前仍为常规字重；像素墨量推断误判率高，暂缓。
- [ ] **G4** 表格单元格左/上内边距、右上题头顶部裁切、`Exam advice` 位置仍有小偏差；等预处理/重影阶段一起看。

## 验证与交付债

- [ ] 更新 `Makefile` 测试基线为全量实际值（当前新增 TableStructureRepair / HeaderLineOrder 回归）。
- [ ] 重跑 `make test`（iPhone 18 Pro / iOS 27）全绿。
- [ ] T004 真机/模拟器 OCR 表格回归在 iOS 26.4.1 的环境差异记录。
- [ ] Word 桌面版（Microsoft Word）渲染抽样；当前只有 WPS。
- [ ] 真机 App UI 全流程（相册→收藏→版面还原→Word）复测；当前真机测试是 parser/export 级。
- [ ] 提交前确认 `build/word-fidelity/` 证据不清理、`docs/media/Zhixia-20261024-1958.docx` 去留。

## h2oc 经验（跨任务）

- 参考 `.harness2/library/k1/agg/word-fidelity/harnesses/editable-word-fidelity/EXPERIENCE.md`。
- 可复用教训：**验收命令只跑子集时，必须额外执行本次改过的每个测试类**（`make test-only T=<Class>`），并在最后一次编辑后验证；仅“跑仓库验证命令”会漏掉被改测试。
- 另一条：`make editable-fidelity` 的 0.961/0.965 是 QuickLook 代理，**不是 WPS 验收**；最终必须用 WPS 真实渲染。
