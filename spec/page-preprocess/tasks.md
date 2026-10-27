# Tasks: 页面预处理（page-preprocess）

**Input**: `spec.md` / `plan.md`
**当前优先级**: **P0.1 基础版已收口（2026-10-27）**；多条件样张/PP-T032/全量 flaky 清理暂停。当前主线切换到 `docs/21-capture-ux-stability.md` 的 P0.2 取景稳定性；本 spec 的 P1/P2/P3 保留为后续。
**测试基线**: `Makefile` 492 total / 481 passed / 1 expected（2026-10-27 全量；已知 10 个顺序/预览 flaky 失败见 `TODO.md`）

## P0 · 边界与页外裁切（当前）

- [~] **PP-T001** 取证基线：`IMG_7544` + 真机 `rendered` + 新 `IMG_7542`（木桌/左侧折页）已记录。`IMG_7542`：edge area 0.9499、文档分割 0.2455、textCoverage 否决 0.2455；after 仍带背景 → 需要纸张 mask/内容边界，而不是只信边缘 quad。
- [x] **PP-T002** `PageBoundaryDetector`：`VNDetectDocumentSegmentationRequest` + 墨迹包围盒否决 + 提议框回退，已接入 `ImagePipeline` / `preprocess.json`（`PageBoundaryDetectorTests` 通过）。
- [x] **PP-T003** `ImagePipeline` 接入 D1/D2：新增 `leftBrightFoldTrim`（亮折页条）、窄折条分支、文字损失门、斜右边界和纸张右缘；新增页级 quad 左缘内收（最多 1% 页宽，给页内最左文字留 0.3% 安全边）。模拟器全图 `IMG_7542`：cropApplied=true、foldTrimU=0.090、foldTrimSource=bright_fold、文字损失 5.06%、textCoverage=1、输出 1752×2200；左侧折页条/木桌去除，标题与页码保留。真机 iPhone 13：pageLeftInset=1%、pageTextLeft=0.1056、textCoverage=1、输出 1554×2200；`geometry_clear` 表格兜底后最终结构表 [[5,2]]、解析表格块 1、标题保留。证据 `build/page-preprocess/final-p0/`。
- [~] **PP-T004** 指标工具：`PagePreprocessReport` 已含 textCoverage/outsideAreaRatio/edgeAngles/parallelErrors/foldTrim*/paperRightEdge/pageTextLeft/pageLeftInset/tableSafety*；iPhone 13 实测 textCoverage 1.0、`outsideAreaRatio=0.1967`（原图内页面 quad 外面积，不是输出背景残留）、报告内耗时 179ms。汇总 `build/page-preprocess/final-p0/summary.json`。**待做**：背景像素级残留汇总与可视化。
- [~] **PP-T005** 真机/模拟器 A/B：WPS 0.906224 与基线一致（独立跑 `realUIBaseExportArtifact` + 新 WPS 渲染，`build/word-fidelity/realbase-wps-p0c-20261026b/`）；真机页级左缘/表格结构 A/B 已闭环；真机 WPS 全流程验收归入暂缓的 PP-T032。整类顺序跑会触发已知 Vision 表格抖动，不得把该类产物当 WPS 基线。

## P0.1 · 边框/背景单次收敛（2026-10-27 起，基础版已收口）

背景：`IMG_7544` 连续三次保存/重扫可逐步去掉右/下、上、左折页，最终 1575×2051；但这是 3 次重编码/降采样后的 coarse-to-fine，不是单次算法保证。评估见 `docs/20-border-crop-convergence.md`。

- [x] **PP-T050** 固定 `IMG_7544` + `myself-1/2/3` 证据：走实际 `renderPage` 链路，记录每轮裁切框、尺寸、OCR、表结构、页外背景；落 `build/page-preprocess/crop-convergence/T050-*`。原图整图 draft：`content_envelope`、cropApplied=true、textCoverage=1、输出 1694×2200（含白底画布）；再跑输出仍 1694×2200。
- [x] **PP-T051** 单次纸张/内容包络：新增 `PageContentEnvelopeDetector`，始终计算纸面边界 + 强内容包络（文字锚点上/左），整图 proposed 也参与；不再只在 fold/detection 变化时裁。原图去掉顶部/左侧页外背景，标题/页码/表格/照片保留；真机 round1 页级 draft 顶部/底部背景问题已改为自动 draft 也走包络、表格不安全时框外刷白。round1-3 出口再经 `PageEdgeCleaner` 清理右侧/顶部楔形背景，右上 `2` 保留；iPhone 13 round1-4（`IMG_7542`，1704×2200）一次保存/分享通过，右侧/顶部背景清、页码 `2` 保留。
- [~] **PP-T052** 可选 refine：已接 table-aware refine（表格 bbox 扩框后重试一次，仍不安全回退）；本样张未触发第二次，背景残留 refine 待后续；原图全分辨率、不重复 P1/JPEG 的约束已落实。
- [x] **PP-T053** 内容安全门：`textCoverage/envelopeTextCoverage`、表格安全门 + `tablesClear(of:)`（含 Vision y 翻轴）+ 表格 bbox retry；中间图/页面级 draft 表格结构不一致时 cropApplied=false 并改为候选框外背景刷白；页面级 draft 也走包络；输出再跑尺寸 1694×2200 不变，幂等性通过；真机全流程仍待 PP-T032。
- [x] **PP-T054** 扫描观感：裁切后白底画布（`scanCanvasBorderRatio=0.006`）；只影响 `renderPage`，WPS realbase 仍 0.906224 且 byte-identical。
- [x] **PP-T055** 出口边缘清理：`PageEdgeCleaner` 逐行/逐列纸面边界 + 受限红色背景清理；黑色页码中止顶部清理；单次全图遍历，不裁切/缩放。round1-3 回归图背景刷白、尺寸不变；round1-4 真机一次保存/分享通过；WPS realbase PNG byte-identical（0.906224）。

## P1 · 折痕/光照

- [x] **PP-T010** 背景场估计 + 压平：`PaperIlluminationFlattener`（320 分析图 / 4% tile p85 / p90 目标 0.86–0.95 / maxGain 1.5 / sRGB kernel）；合成折痕、渐变、彩色插图、平面白纸、深色图 **5/5**；真实页纸面覆盖 0.86–0.89。
- [x] **PP-T011** 与现有 `EnhancementRecipe` 隔离：只接 `ImagePipeline.renderPage`；`apply()` / Word 夹具路径零变化；`.original` 跳过；表格安全门表框内 `gain=1`（外扩 1.5%）。
- [x] **PP-T013** 扩展 P1 表格 guard 覆盖：未裁切页先用 `.enhance` 预览 + `VisionDocumentStructureRecognizer`（`vision_structure`）；漏表时 `TableContentGuard` 深色表头块 / `TableGridGuard` 网格兜底（`content_fallback` / `grid_fallback`）。P0 裁切路径继续用 `p0_crop_safety`。真机未裁切 `IMG_7542` 表 `5×2` 6/6；视觉漏检模拟下 content fallback 仍 `5×2` 6/6。模拟器 `IMG_7544` 结构漏表时 content fallback 保护 3 块、P1 applied。证据 `build/page-preprocess/p1-guard/final-summary.json`。
- [~] **PP-T012** 真实页 A/B：iPhone 13 裁切路径背景场方差 0.002832→0.0000293（−98.97%），表结构 off/on 各 6/6 次 `5×2`，OCR 归一化字符召回 99.93%；未裁切路径表结构 6/6、字符召回 99.73%。P1 236–288ms、暖机整页 1276–1395ms，首跑 1764ms（PP-T032 冷启动已暂缓）。WPS 独立 realbase PNG 与 P0 证据 byte-identical，仍 0.906224。**未闭环**：通用 guard 的 Vision 假阴性、ghost 可见性（G1）。证据 `build/page-preprocess/p1-device/final-summary.json`、`build/page-preprocess/p1-guard/final-summary.json`、`build/word-fidelity/realbase-wps-p1-20261026b/`。

## P2 · 页边拉直 / 文字行矫正

- [~] **PP-T020** 文字行 bbox → 局部倾斜/水平带：`PageTextLineAnalyzer` 已用 `VNDetectTextRectanglesRequest` 四角估计有符号角度并聚类水平带，接入 `renderPage` 报告；表格 bbox 融合待做。
- [~] **PP-T021** 第一版：局部垂直 shear 原型已测；设备表格页行角改善但表结构 1→0（6/6），无表页 p90 改善但 OCR 1807→1775；**未启用**，需 table-aware 校验与 OCR 调参。
- [~] **PP-T022** 页边直线度/平行度指标达标：已量测；iPhone 13 文字行中位 0.49°、p90 1.11°；模拟器 `IMG_7544` 中位 0°、p90 1.09°；未达 0.3°/0.8°。
- [ ] **PP-T023** 接入 OCR 前的 `rendered.jpg`；表格 2/3 列判定稳定性回归。

## P2.5 · 端侧视觉模型预研（不阻塞 P0~P2）

- [ ] **PP-T040** 候选调研：Core ML 文档分割/去弯/复原模型（开源或自训），明确 License、输入输出、模型体积、ANE 支持。
- [ ] **PP-T041** 基准对比：Vision + 经典几何 vs 模型方案（页边直线度、行角、OCR 召回、WPS SSIM、iPhone 13 耗时/内存）。
- [ ] **PP-T042** 仅当模型在 ≥3 项核心指标胜出且不劣化内容召回，才接 feature flag；默认仍关闭。
- [ ] **PP-T043** 生成式模型（diffusion/VLM）只做对照实验，不进入默认链路；禁止生成式改写文档像素。

## P3 · 曲面网格 / 规模化

- [ ] **PP-T030** 曲面薄板样条/网格重映射（仅在 P2 指标不足时启用）。
- [ ] **PP-T031** 10~20 张多条件样张（平放/弯页/折痕/阴影/桌面）回归。**2026-10-27 暂停**：round1-4 单张已验收，待 P0.2 取景稳定后恢复。
- [ ] **PP-T033** 更新 `docs/19`、`AGENTS.md` 当前周期指针、测试基线。

## 验收门

1. **Gate P0**：裁切后页外背景 <2%、墨迹召回 ≥99%、无页面内子框裁切；当前 WPS 分数不回退。
1b. **Gate P0.1**：单次/最多一次 refine 后页外背景 <2%；标题/页码/页脚/表格/插图 bbox 包含率 100%；OCR 归一化召回 ≥99.5%；表签名一致；幂等性裁切变化 <0.5%；P0 增量 ≤600ms；WPS 0.906224 不回退。
2. **Gate P1**：折痕区亮度方差下降 ≥30%，照片/插图不变形不变色；OCR 召回不降；表格结构不变。当前 iPhone 13 裁切路径：方差 −98.97%、表结构 6/6 `5×2`、字符召回 99.93%；未裁切路径表结构 6/6、字符召回 99.73%。
3. **Gate P2（当前）**：文字行中位 ≤0.3°、p90 ≤0.8°、页边直线/平行 ≤0.5% 短边；当前仅完成测量，iPhone 13 中位 0.49°/p90 1.11°，矫正未接。
4. **Gate P3**：真机 WPS SSIM ≥0.90，且多条件样张无内容丢失。

## 已知债务 / 暂缓

- **PP-T032（2026-10-27 暂停）** iPhone 13 真机全流程 + WPS/Word 渲染验收；冷启动 ≤1.5s/页暂不压（当前 P1 236ms、暖机整页 1388–1395ms、首跑 1764ms）。WPS realbase 仍 0.906224 且 PNG byte-identical；真机全流程复测待 P0.2 取景稳定后恢复。
- **G1** 可编辑字与背景字未完全重合造成的重影：等预处理把几何拉直后再优化；当前先记录，不在本周期解决。
- **P1 guard 残余假阴性**：无表头、无边框表格仍可能漏检；需要更强版面/线条模型。
- **G2** iOS 26.4.1 模拟器 `RecognizeDocumentsRequest` 对练习册表格返回 0 表（iOS 27 正常）：单独修结构化回退或标注环境限制，见 `TODO.md`。
- **G2c** `WordFidelityExportTests` 整类顺序运行时 `realOCRExportArtifact` 结构表为 0（单独运行通过）；按 iOS 27 模拟器 Vision 表格波动记录，不削弱断言。
- **G3** `preScaledFontSize` 的溢出估算仅对无 lines 旧块生效，需在 P2 回归中观察，不阻塞预处理。
