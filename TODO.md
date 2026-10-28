# TODO · Zhixia

> 更新时间：2026-10-28。当前主线：**P0.3 取景包络跟踪**（[`docs/22`](docs/22-capture-envelope-tracking.md)；
> 四件套 [`spec/capture-envelope-tracking/`](spec/capture-envelope-tracking/)）。
> **交接入口：[`docs/12-handover.md`](docs/12-handover.md) §0**（当前状态 / 第一天怎么跑 / 下一步 / 不要做什么）。
> P0.2 的粉封面热修已通过；实时“单页意图”在 2026-10-28 真机复核中仍未达目标，保留实现但不再沿该方向调参。
> **page-preprocess P0.1 基础版已收口**：round1-4 单张真机成片验收通过；多条件样张、PP-T032 全流程和
> flaky 清理按用户要求暂停，记录在下方“暂停事项”。历史交接 `SESSION-HANDOFF.md` 已退役：
> 仍有价值的条目已并入本文件；其余文档见 `docs/17`、`docs/18`、`docs/19`。

## P0.3 · 取景包络跟踪（当前主线，2026-10-28 起）

**目标**：实时只维护一个稳定的“书/整摊/单页 envelope”，左右页意图作为**输出语义**；
拍后在高分辨率静帧上拆页/精修。**不再要求实时精确锁单页**。

- [x] **CF-T001 证据与竞品行为复核**：视频 5（彩色/黑白右/左/整页）和视频 6（WPS
  万能扫描）已抽帧；结论见 `docs/22-capture-envelope-tracking.md`，关键帧见
  `docs/media/capture-ux/video5-*`、`video6-*`。
- [~] **CF-T002 无框消失止血**：`PageIntentResolver` 拆出 `displayEnvelope` 与
  `outputIntent`；目标页不可靠时返回整摊/书包络供显示，绝不因左/右页找不到而清空
  取景框；快门不再静默回退 `.fullImage`。
  **代码已落**：`CaptureEnvelopeObservation` / `EnvelopeDetecting` /
  `CaptureEnvelopeTracker` / `VisionEdgeDetector.observeEnvelope` /
  `CaptureViewModel.consumeEnvelope`；新增 tracker/viewmodel 测试；最新全量
  **518 / 507 / 1 expected / 10 failed**（10 个既有 flaky），定向测试通过；
  真机录制验收待补。
- [~] **CF-T003 连续包络跟踪器**：新增 `CaptureEnvelopeTracker`——低频观测
  （文档分割/矩形/边缘）+ 高频光流/单应性传播 + 1€/Kalman + 候选滞回 + 状态机；
  离线回放视频 5/6 调参。
  **第一版已落**：hold/平滑/候选切换确认/目标失联回退；光流/单应性传播仍是
  下一子步，不能宣称已达 WPS 跟手性。
- [~] **CF-T004 意图输出化（2026-10-28 第一版）**：实时显示主框 = 左/右页输出
  目标（实线 + 压暗 + 四角括号），整摊/整书包络降为淡虚线上下文；左页右角落在
  书脊上，不再被超出屏幕的包络裁掉。`.fullImage` / 贴屏外框从包络与书脊拆分
  中彻底移除；无当前帧包络或 tracker hold 时快门置灰。模拟器/单测已过，真机
  视频 5/7 复测待补。
- [~] **CF-T005 拍后高分辨率拆分（2026-10-28 第一版）**：`PageDraft` 持久化
  `outputIntent`；Review 首轮精修对左/右页意图在原图 1600px 矫正图上找书脊，
  高置信（≥0.5）直接落目标页并压入撤销栈，低置信只给预选提案。彩色页面 mask、
  内容安全门、透视/去背景仍未做；真机成片回归待补。
- [ ] **CF-T006 UI/快门**：蓝色细实线/置信度态；锁定后自动/手动快门；按下一帧
  冻结包络；保留引导/手动框兜底。
- [ ] **CF-T007 真机与 WPS 对照验收**：视频 5/7 复核（目标框可见、左页右角、
  无 fullImage 误拍、左右页成片正确）；20 彩页 + 20 黑白 + 10 A4 + 10 曲面/折页；
  框可见率、切换率、锁定延迟、输出页正确率、禁止内容入片率；WPS 0.906224 不回退。
  清单见 `spec/capture-envelope-tracking/device-acceptance.md`。
- [ ] **CF-T008 光流/单应性传播**：每帧传播上一帧包络，低频观测融合；先离线回放
  视频 5/6，再接主路径；目标单帧跳变 p95 ≤短边 0.5%。
- [ ] **CF-T009 观测增强（按需）**：先测传统 Vision 失败率；不足再评估端侧分割
  mask（离线/ANE，只输出 mask/几何，不做生成式像素）。

## P0.2 · 取景稳定性与拍摄意图（历史主线，2026-10-27）

**证据**：`docs/21-capture-ux-stability.md`、`docs/media/capture-ux/`；录屏原文件在
`docs/media/screenrecord/`（本地，六段；视频 5 约 421MB）。四个现象分别对应粉封面误洗白、取景候选
跳动、快门取到跟踪框、自动模式没有左/右页意图；不是单一平滑阈值问题。

- [x] **CU-T001 取证收口**：六段真机/竞品录屏、联系表和关键成片已落
  `docs/media/capture-ux/`；设备侧粉封面 `1F59BD7A…`（1285×1775）、右页
  `885149C2…`（1401×2058）、整摊 `F67F06C6…`（1832×1930）与录屏对应。
- [x] **CU-T002 粉色封面热修**：`PageEdgeCleaner` 红色木纹清理当前在顶部 7% 全宽生效，
  粉色封面被误判为桌面而刷白。改为只在页面 mask 外/右边缘条生效，页面内高饱和像素
  受保护；彩色封面裁切走边缘/文档分割或引导框，不再硬套白纸包络。加
  `pink-cover` fixture，断言页面内粉带保留、WPS **0.906224** 与 PNG byte-identical。
  **已实现**：顶部全宽红色清理已移除；红色/灰色只在右缘且内侧必须是白纸时生效；
  合成回归通过；设备原图 + DB quad 本地重渲染见 `docs/media/capture-ux/pink-cover-fixed.jpg`。
- [~] **CU-T003 自动模式意图与左右页候选**：自动模式也显示“左页/右页/整页”；
  检测到整书/书脊时用 `SpreadSplitter` 生成 live 左右页候选，意图优先于整书容器；
  找不到目标页时提示，不拿整摊凑数。左页/右页各 10 张验收。
  **已实现**：`PageIntentResolver` + 自动模式意图条；`PageIntentResolverTests` 5 条通过。
  **2026-10-28 真机复核未达目标**：视频 5 中彩色/黑白右/左页框仍频繁不出现，整页框
  也会带入背景；转为 P0.3 包络方案，保留代码作为后续拆分/高亮基础。
- [~] **CU-T004 候选切换与锁定稳定**：候选级滞回（连续存在/更优才切换，建议 0.4–0.5s，
  不要每 5 帧 escape）；真实 `frame.timestamp` 计算 dt；窗口累计位移判定锁定/解锁；
  清晰单页 4–6 帧快速锁，候选交替时不显示“已对准”；跟踪框加显示死区/低通。
  **已实现**：真实 timestamp、锁定起点累计位移、页面意图 hold 15 帧、显示死区；
  `QuadSmootherTests` 2 条新增通过。
  **2026-10-28 复核**：单 quad 平滑无法补“根本没有目标候选”的帧；改为 P0.3 tracker。
- [~] **CU-T005 快门一致性**：手动按下第一帧冻结呈现框与候选；跟踪态要么提示等待
  稳定/引导，要么按当前框明确拍摄，不能把按下后切换的候选写进成片；修复自动模式
  `previewSize` 与全屏 overlay 尺寸口径（已知 T011 待办）。
  **已实现**：快门读取 `presentedQuad`；页面意图无目标时 detector 返回 nil。
  **2026-10-28 复核**：nil 会让 overlay 无框，快门回退 fullImage；P0.3 改为包络兜底。
- [~] **CU-T006 引导模式兜底与默认值**：书本/摊开书场景引导框静态、无候选抖动；先保证
  左/右页意图与默认框可用，再按 20 张 A/B 决定 `captureMode` 是否翻转为 guided。
- [x] **CU-T007 拍后安全网**：Review 对整摊成片默认展示“左页/右页/整页”拆分提案，
  用户确认才写 quad；不静默改。复用现有 `ReviewViewModel` 提案，不替代取景修复。
  **已实现**：`ReviewView.splitSuggestion` 第一屏确认条。
- [~] **CU-T008 录屏回归与验收**：粉封面 3 角度、右页 10、左页 10、A4 5；记录候选
  切换次数/s、锁定延迟、单帧跳变 p95、禁止内容入片率、修正次数；重跑全量测试与
  WPS 门限，文档回填 `docs/21`。
  **已完成（P0.2）**：全量 **509 / 498 / 1 expected / 10 failed**（既有 flaky）；新测试
  9 条通过；WordFidelity `realUIBase` 通过、QuickLook 代理 pageimage 0.914115 /
  restored 0.964710。**2026-10-28 新增视频 5/6**：左右页实时框仍不达目标，整体验收
  转入 P0.3 CF-T007。

## P0/P1 · 页面预处理（历史执行，已暂停新工作）

- [x] PP-T001 取证基线：真机/模拟器页外背景、页边偏差、文字行角度（`build/page-preprocess/baseline/`）。
- [x] PP-T002 `PageBoundaryDetector`：文档分割 + 墨迹否决 + 四角回退已接 `ImagePipeline` / `preprocess.json`，单测通过。
- [x] PP-T003 页外裁切：亮折页条检测 + 内容框 + 斜右边界 + 页级左缘内收已接。模拟器全图路径 `IMG_7542`：cropApplied=true、foldTrimU=0.090、foldTrimSource=bright_fold、文字损失 5.06%、textCoverage=1、输出 1752×2200；左侧折页条与木桌已去除，标题/页码保留。真机 iPhone 13：页级 quad（area 0.808）左缘内收 1% 页宽，`pageTextLeft=0.1056`、标题保留 0.68% 安全边、textCoverage=1、输出 1554×2200；页级表格参照按正立页识别为 `[[5,3]]`，裁切 JPEG 偶发 0 表时以「表格 bbox 在裁切线右侧」几何兜底（`geometry_clear`），最终增强页结构表 `[[5,2]]`、解析表格块 1、标题保留。证据：`build/page-preprocess/final-p0/`。
- [~] PP-T004 预处理指标：`PagePreprocessReport` + `PageBoundaryMetrics` + iPhone 13 / IMG_7542 baseline 已落；新增 pageTextLeft/pageLeftInset/tableSafetyReference/tableSafetyDecision/tableSafety{Original,Cropped}Shapes，汇总见 `build/page-preprocess/final-p0/summary.json`。待补像素级页外背景残留与可视化。
- [~] PP-T005 真机/模拟器 A/B：WPS 0.906224（2026-10-26 独立跑 `realUIBaseExportArtifact` + 新 WPS 渲染，`build/word-fidelity/realbase-wps-p0c-20261026b/`）与基线一致，未回退；真机页级左缘/表格结构 A/B 已闭环；真机 WPS 全流程验收归入暂缓的 PP-T032。整类顺序跑会触发已知 Vision 表格抖动，不得把该类产物当 WPS 基线。

## P0.1 · 边框/背景单次收敛（2026-10-27 起，基础版已收口）

> 单页 round1-4 真机一次保存/分享通过；多条件与全流程验收暂停，见文末“暂停事项”。
> 详细证据见 [`docs/20-border-crop-convergence.md`](docs/20-border-crop-convergence.md)。

**背景**：真机对 `docs/media/IMG_7544.jpg` 连续做三次“扫→保存→再扫”，依次去掉右/下、上、左折页，最终到 1575×2051；目测标题、页码、页脚、两个表、照片仍在，macOS Vision OCR 字符数 1752→1777（仅作粗筛）。这说明目标裁切区域存在且稳定，当前问题主要是**单次检测欠裁**，不是无法识别页面。多步方案以多次重编码/降采样（最终面积仅原图 27.8%）换取 coarse-to-fine，不能作为正式链路。评估见 `docs/20-border-crop-convergence.md`。

- [x] **PP-T050 复现与取证**：固定 `IMG_7544.jpg` 与 `myself-1/2/3` 三张中间图，走实际 `renderPage`（整图 draft）记录裁切框、尺寸、OCR、表格安全门；证据落 `build/page-preprocess/crop-convergence/T050-*`、`T050-intermediate-summary.json`、`build/page-preprocess/crop-convergence/device-round1-2/`（真实设备原图/旧报告/修复后本地复现）。原图整图 draft：`cropSource=content_envelope`、`cropApplied=true`、`textCoverage=1`、输出 **1694×2200**（含白底画布）；三张中间图 1 表格签名不一致时改为框外刷白、2/3 可裁；页面级 draft 也能裁掉顶部/底部背景；对第一轮输出再跑一次，输出尺寸仍 1694×2200，幂等性通过。
- [x] **PP-T051 单次纸张/内容包络**：新增 `PageContentEnvelopeDetector`，自动 page-level draft 也走包络；候选必须夹在现有页面框内部，不能再扩回折页/右侧背景；正文上/下/左/右留 0.8%，纸面上边距 >3% 时保留 1.5% 页眉安全带（真机 `2` 在 OCR 文本框外，旧版被裁）。设备真实报告：`proposed` 面积 0.776、旧 `chosen.top=0.1098`、`textBounds.top=0.1178`、`paperEnvelope.top=0.0972`、页码 `2` 顶部约 0.086；本地用设备原图+真实 proposed 复现，输出 1561×2193，右上 `2` 回读存在，目测无左折页/右侧背景。用户复测 round1-3（1704×2200）整体改善但右上仍残留约 12px 页外条；当前代码用 round1-3 回归样本可清掉右侧/顶部楔形背景，`2` 保留。**iPhone 13 重装后已实测**：从相册选 `IMG_7542.JPG`，一次保存/分享得到 round1-4（**1704×2200**），右侧/顶部背景已清、右上 `2` 保留、表格/照片完整，见 `docs/media/optimize/round1-4-324DA051-5DB2-4586-86AF-B33CDCF1B426-rendered.jpg` 与 `build/device-round1-4/`。设备保存后临时 `preprocess.json` 会清理，但 `default.store.ZPAGEENTITY.ZQUADDATA` 仍保存 proposed quad。
- [~] **PP-T052 可选 refine**：已接 **table-aware refine**（表格 bbox 扩框后重试一次，仍不安全回退）；本样张 `envelopeRefineApplied=false`，因为内容包络本身通过安全门，没有触发第二次。背景残留 refine 仍待后续；预算/不重复 P1/JPEG 的约束已落实。
- [x] **PP-T053 内容安全门**：`textCoverage/envelopeTextCoverage`、表格安全门 + `tablesClear(of:)`（含 Vision y 翻轴）+ 表格 bbox retry；中间图/页面级 draft 表格结构不一致时 `cropApplied=false`，改为“保留原页几何并把候选框外背景刷白”（`backgroundWhitened=true`），不把表格交给裁切后的结构识别重新解释。真机 round1-2 本地复现：表格安全门 `mismatch` → 白底回退，右上 `2` 保留。对第一轮输出再跑尺寸稳定；真机全流程仍待 PP-T032。
- [x] **PP-T054 扫描观感**：`PagePreprocessRecipe.scanCanvasBorderRatio=0.006`，裁切成功后加白底画布；单测/集成测试验证左上角近白；只影响 `renderPage`，`apply`/WPS 夹具不变。WPS realbase 仍 **0.906224** 且 PNG byte-identical。
- [x] **PP-T055 出口边缘清理**：新增 `PageEdgeCleaner`，逐行找纸面右边界、逐列找纸面顶边界，只在白底画布内侧刷白；顶部扫描遇到低饱和黑色页码/文字即中止，保留右上 `2`；另对右上角红色木纹/灰色页边做受限清理。单次全图像素遍历，不裁切、不缩放；round1-3 回归图右侧/顶部背景已清，输出尺寸不变；真机 round1-4 实测同样通过。证据：`build/device-round1-3/edge-cleaned.jpg`、`build/device-round1-4/rendered.jpg`、`docs/media/optimize/round1-3-2C35B62C-D12F-4E13-A2A3-7AA9702F552F-rendered.jpg`、`docs/media/optimize/round1-4-324DA051-5DB2-4586-86AF-B33CDCF1B426-rendered.jpg`；WPS realbase 仍 **0.906224** 且 PNG byte-identical。

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
- [ ] PP-T031 10~20 张多条件样张回归。**2026-10-27 暂停**：round1-4 单张已验收，多光照/纸张/封面样本待恢复。
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
- [ ] **PP-T032（2026-10-27 暂停）** iPhone 13 真机全流程 + WPS/Word 验收；冷启动 ≤1.5s/页暂不压（当前 P1 236ms、暖机整页 1388–1395ms、首跑 1764ms）。WPS realbase 当前 **0.906224** 且 PNG byte-identical；全流程复测仍见“验证与交付债”，待 P0.2 取景稳定后恢复。

## 验证与交付债

- [x] 更新 `Makefile` 测试基线为全量实际值：**518 total / 507 passed / 1 expected failure**（2026-10-28 CF-T004/CF-T005 新增 `PageIntentResolver` 2、`CaptureEnvelopeViewModelTests` 2、`CaptureOverlayQuadsTests` 2、`ReviewSplitProposalTests` 3）。全量 flaky 失败 10 个，见下。
- [~] 重跑 `make test`（iPhone 18 Pro / iOS 27）：**518 total / 507 passed / 1 expected / 10 failed**；10 个仍为 Golden 4、`WordFidelityExportTests/realOCRExportArtifact()` 1、Review preview 4、`ReviewSplitProposalTests/guidedPageSkipsProposal()` 1。CF-T004/CF-T005 新增用例全绿；全量不绿是既有债务，不是本轮引入。
- [ ] `WordFidelityExportTests` 整类顺序运行时 `realOCRExportArtifact` 出现 `structureTables=0`（单独跑通过）；按已知 iOS 27 模拟器 Vision 表格波动记录，不削弱断言。
- [ ] P1 guard 残余假阴性：无表头、无边框的表格仍可能漏检；需要更强的版面/线条模型。
- [ ] T004 真机/模拟器 OCR 表格回归在 iOS 26.4.1 的环境差异记录。
- [ ] Word 桌面版（Microsoft Word）渲染抽样；当前只有 WPS。
- [ ] 真机 App UI 全流程（相册→收藏→版面还原→Word）复测；当前真机测试是 parser/export 级。
- [ ] 提交前确认 `build/word-fidelity/` 证据不清理、`docs/media/Zhixia-20261024-1958.docx` 去留。

## 暂停事项（2026-10-27 阶段收口，不删除）

- [ ] **PP-T031 多条件样张**：10–20 张不同光照/纸张/封面回归，暂停。当前已有
  round1-4 单张通过；恢复时优先补粉色封面和打开书本左右页。
- [ ] **PP-T032 真机全流程**：iPhone 13 相册→收藏→版面还原→Word/WPS 验收，暂停。
  P0.1 图片链路已通过；WPS 仅验证到 **0.906224** realbase，不等于全流程通过。
- [ ] **全量 flaky 清理**：暂停。当前全量 **517 total / 506 passed / 1 expected /
  10 failed**；失败仍为 Golden/WordFidelity/Review/ReviewSplit 的既有顺序/预览抖动，
  定向测试通过。恢复时先修测试治理，不改业务断言。
- [ ] **真机 UI 全流程**：当前真机证据多为 parser/export 级，UI 全流程仍待补；
  与 P0.2 取景稳定性验收一起排期。

## h2oc 经验（跨任务）

- 参考 `.harness2/library/k1/agg/word-fidelity/harnesses/editable-word-fidelity/EXPERIENCE.md`。
- 可复用教训：**验收命令只跑子集时，必须额外执行本次改过的每个测试类**（`make test-only T=<Class>`），并在最后一次编辑后验证；仅“跑仓库验证命令”会漏掉被改测试。
- 另一条：`make editable-fidelity` 的 0.961/0.965 是 QuickLook 代理，**不是 WPS 验收**；最终必须用 WPS 真实渲染。
