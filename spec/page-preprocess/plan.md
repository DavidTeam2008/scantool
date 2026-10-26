# Plan: 页面预处理（page-preprocess）

**Input**: `spec.md`（US1~US4 / FR-001~008 / SC-001~007）
**执行**: 先取证和可测门限，再做边界裁切，最后做折痕/网格矫正；不一次性重写 ImagePipeline。

## 证据锚点

| # | 事实 | 证据 |
|---|---|---|
| E1 | 当前只做单应性四角矫正，无页边/折痕/弯曲模型 | `ImagePipeline.perspectiveCorrect` |
| E2 | 真机导出仍有背景字重影；文字框与背景图未严格重合 | 用户 2026-10-25 反馈；`docs/17` 末尾 |
| E3 | 同一页真机 3 列 4 行、模拟器 2 列 5 行，说明输入几何差异会直接改变 Vision 结构 | `docs/17` 真机回归；`TableStructureRepair` |
| E4 | 4 角页面检测已有 `VisionEdgeDetector` + `Quad`，可复用 | `Zhixia/Services/Vision/VisionEdgeDetector.swift` |
| E5 | OCR 前已有 `CIDocumentEnhancer`（只用于 OCR 预处理，未用于 rendered 页） | `OCRPreprocessor.swift` |
| E6 | 预处理产物是 `rendered.jpg`，Word 底图/OCR 都消费它 | `ImagePipeline.renderPage`、`ReconstructViewModel` |

## 设计决策

### D1 页面边界：文档分割优先，四角检测回退

- 在 `ImagePipeline.correct` 前增加 `PageBoundaryDetector`：
  - 首选 `VNDetectDocumentSegmentationRequest`（纸张/文档区域）；
  - 若不可用/置信低/退化，沿用调用方 `quad`；
  - 若两者都退化，整图（不裁）。
- 选择规则不用“面积最大”单一指标：候选需同时满足
  `area ≥ 0.15`、四边长度比 ≤3、文本墨迹包围盒覆盖率 ≥0.9。
- 回退原因写入 `preprocess.json`，便于真机对比。

### D2 页外裁切：页面四边形 + 文本墨迹双门控

- 以 D1 四边形做透视裁切；外扩 1% 安全边，避免切掉页边文字。
- 用 OCR 行/墨迹包围盒校验：裁切后墨迹召回 <99% → 自动回退到不裁/更大框。
- 该步只做“去页外”，不做折痕矫正；先拿到可测量基线。

### D3 折痕/光照：背景场估计 + 保留区排除

- 对灰度图做大半径（页宽 8%~12%）背景场估计（盒式/高斯），目标纸白取背景场 p90 并夹到 0.86–0.95；maxGain 1.5，只提亮不压暗。
- 对 figure/artwork 区域用 mask 跳过；彩色/照片区不做强增益；表格区由 P0 表格安全门表框（外扩 1.5%）强制 `gain=1`。
- 与 `EnhancementRecipe` 分开：新增 `.paper` 预处理 recipe，只在 `ImagePipeline.renderPage` 执行，不改变现有增强档/`apply()` 行为。
- 未裁切页先用 `.enhance` 预览 + `VisionDocumentStructureRecognizer` 拿表框（`vision_structure`）；识别 nil/空页才跳过 P1（`table_guard_unavailable`）。后续可加横竖线/网格假阴性兜底。

### D4 边框拉直：文本行引导的分段矫正

- 在裁切页上跑一次轻量 OCR（或复用已有 `RecognizedTextObservation`）取文字行 bbox。
- 用同一行左右端点的 y 差估计局部倾斜；按行 y 聚类得到若干水平带。
- 对每个带估计**水平位移场**，再做页边垂直约束；用分段双线性/薄板样条重映射。
- 第一版只做**水平带平移 + 轻微旋转**，不引入复杂 mesh；达标后再上曲面网格。
- 不做整页旋转：页边必须保持水平/垂直；整页旋转只作为最后回退。

### D5 管线集成与缓存

- `ImagePipeline.renderPage` 顺序：`boundary → crop → dewarp → illumination → enhancement`。
- 预处理结果写回 `rendered.jpg`；`original.jpg` 不动；`PageDraft.quad` 仍记录原始四角。
- 对已有文档不自动重跑；新拍摄/重新还原时生效。

### D6 度量与门限

- 新增 `PagePreprocessMetrics`：页外占比、边直线度、平行度、行角、墨迹召回、耗时。
- 宿主侧脚本 `Tools/page-preprocess/measure.py`（或 Swift 测试）输出 JSON；真机/模拟器同一口径。
- 单测优先用合成页（矩形/梯形/波浪边/折痕渐变），真实样张做集成回归。

### D7 端侧视觉模型：只做几何/像素，不用 LLM 生成

- **适用**：页面分割、文档去弯（dense flow / mesh）、折痕/阴影复原、文字行检测。
- **不适用**：LLM/VLM 直接“生成一张平整页面”——输出不可逐像素对齐、可能篡改文字/插图，
  且 iPhone 13 上延迟/内存不可控。
- **接入形态**：模型只输出 mask / 位移场 / 置信度，后处理仍由确定性几何完成；
  默认 feature flag 关闭，A/B 胜出才启用。
- **候选**：开源文档去弯/分割模型（DocUNet/DewarpNet/UVDoc/DocTr++ 类）或自训轻量模型；
  必须 Core ML + ANE、离线、License 可商用、模型 ≤50MB 优先。
- **门限**：iPhone 13 单页 ≤1.5s、内存峰值可控、页边/行角/OCR 三项不低于经典链路；
  生成式方案只作对照，不进入默认。

## 实施顺序

1. **P0**：边界检测 + 页外裁切 + 指标/回退（不改 OCR/Word 链路）。
2. **P1**：折痕/光照压平 + 保留区排除。
3. **P2**：文字行水平带矫正 + 页边拉直；接入 OCR 前。
4. **P3**：曲面网格 / 10~20 张样张回归 / 真机 WPS 验收。

## 回退与止损

- 任一阶段指标回退（SC-001/002/005/006）→ 该阶段默认关闭，保留开关和证据。
- 页面检测不可靠 → 不裁；宁可保留背景，不裁字。
- 连续两轮无提升 → 冻结网格矫正，只保留裁切/光照。
