# Tasks: 页面预处理（page-preprocess）

**Input**: `spec.md` / `plan.md`
**当前优先级**: P0（边界 + 页外裁切 + 指标）→ P1（折痕/光照）→ P2（页边拉直/行矫正）→ P3（网格/真机）
**测试基线**: 待全量测试稳定后同步 `Makefile`

## P0 · 边界与页外裁切（当前）

- [~] **PP-T001** 取证基线：`IMG_7544` + 真机 `rendered` + 新 `IMG_7542`（木桌/左侧折页）已记录。`IMG_7542`：edge area 0.9499、文档分割 0.2455、textCoverage 否决 0.2455；after 仍带背景 → 需要纸张 mask/内容边界，而不是只信边缘 quad。
- [x] **PP-T002** `PageBoundaryDetector`：`VNDetectDocumentSegmentationRequest` + 墨迹包围盒否决 + 提议框回退，已接入 `ImagePipeline` / `preprocess.json`（`PageBoundaryDetectorTests` 通过）。
- [~] **PP-T003** `ImagePipeline` 接入 D1/D2：新增 `leftBrightFoldTrim`（亮折页条）、窄折条分支、文字损失门、斜右边界和纸张右缘。模拟器全图 `IMG_7542`：cropApplied=true、foldTrimU=0.090、foldTrimSource=bright_fold、文字损失 5.06%、textCoverage=1、输出 1752×2200；左侧折页条/木桌去除，标题与页码保留。真机 iPhone 13：边缘框已页级（area 0.808），cropApplied=false，残留约 1% 左页边；原图 tables=[]、裁切后 tables=[5]，表格同签名 A/B 不可用。证据 `build/page-preprocess/final-p0/`。
- [~] **PP-T004** 指标工具：`PagePreprocessReport` 已含 textCoverage/outsideAreaRatio/edgeAngles/parallelErrors/foldTrim*/paperRightEdge；iPhone 13 实测 textCoverage 1.0、页外面积 0.89%、上边角 1.02°、耗时 298ms。汇总 `build/page-preprocess/final-p0/summary.json`。**待做**：背景像素级残留汇总与可视化。
- [~] **PP-T005** 真机/模拟器 A/B：WPS 0.906224 与基线一致（`build/word-fidelity/realbase-wps-p0c/`），未回退；真机折页裁切与表格同签名 A/B 仍需下一轮。

## P1 · 折痕/光照

- [ ] **PP-T010** 背景场估计 + 压平（保留区排除）；合成折痕/渐变单测。
- [ ] **PP-T011** 与现有 `EnhancementRecipe` 隔离，新增预处理档；旧增强路径零行为变化。
- [ ] **PP-T012** 真实页 A/B：折痕阴影区亮度方差、OCR 字符召回、WPS SSIM。

## P2 · 页边拉直 / 文字行矫正

- [ ] **PP-T020** 文字行 bbox → 局部倾斜/水平带聚类；输出每带位移场。
- [ ] **PP-T021** 第一版：水平带平移 + 页边垂直约束；失败回退不矫正。
- [ ] **PP-T022** 页边直线度/平行度指标达标（SC-002/003/004）。
- [ ] **PP-T023** 接入 OCR 前的 `rendered.jpg`；表格 2/3 列判定稳定性回归。

## P2.5 · 端侧视觉模型预研（不阻塞 P0~P2）

- [ ] **PP-T040** 候选调研：Core ML 文档分割/去弯/复原模型（开源或自训），明确 License、输入输出、模型体积、ANE 支持。
- [ ] **PP-T041** 基准对比：Vision + 经典几何 vs 模型方案（页边直线度、行角、OCR 召回、WPS SSIM、iPhone 13 耗时/内存）。
- [ ] **PP-T042** 仅当模型在 ≥3 项核心指标胜出且不劣化内容召回，才接 feature flag；默认仍关闭。
- [ ] **PP-T043** 生成式模型（diffusion/VLM）只做对照实验，不进入默认链路；禁止生成式改写文档像素。

## P3 · 曲面网格 / 规模化

- [ ] **PP-T030** 曲面薄板样条/网格重映射（仅在 P2 指标不足时启用）。
- [ ] **PP-T031** 10~20 张多条件样张（平放/弯页/折痕/阴影/桌面）回归。
- [ ] **PP-T032** iPhone 13 真机全流程 + WPS/Word 渲染验收；性能 ≤1.5s/页。
- [ ] **PP-T033** 更新 `docs/19`、`AGENTS.md` 当前周期指针、测试基线。

## 验收门

1. **Gate P0**：裁切后页外背景 <2%、墨迹召回 ≥99%、无页面内子框裁切；当前 WPS 分数不回退。
2. **Gate P1**：折痕区亮度方差下降 ≥30%，照片/插图不变形不变色；OCR 召回不降。
3. **Gate P2**：页边直线度/平行度 ≤0.5% 短边、文字行中位倾角 ≤0.3°；表格判定稳定。
4. **Gate P3**：真机 WPS SSIM ≥0.90，且多条件样张无内容丢失。

## 已知债务 / 暂缓

- **G1** 可编辑字与背景字未完全重合造成的重影：等预处理把几何拉直后再优化；当前先记录，不在本周期解决。
- **G2** iOS 26.4.1 模拟器 `RecognizeDocumentsRequest` 对练习册表格返回 0 表（iOS 27 正常）：单独修结构化回退或标注环境限制，见 `TODO.md`。
- **G2c** `WordFidelityExportTests` 整类顺序运行时 `realOCRExportArtifact` 结构表为 0（单独运行通过）；按 iOS 27 模拟器 Vision 表格波动记录，不削弱断言。
- **G3** `preScaledFontSize` 的溢出估算仅对无 lines 旧块生效，需在 P2 回归中观察，不阻塞预处理。
