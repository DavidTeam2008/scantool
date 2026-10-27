# 20 · 边框/背景单次收敛评估（2026-10-27）

> 状态：**P0.1 基础版已实现，真机全流程/多条件样张待补**。当前执行优先级见
> [`TODO.md`](../TODO.md) 的 **P0.1**；原 P0/P1/P2 结论仍以
> [`docs/19`](19-page-preprocess-plan.md) 为准。
>
> 触发样本：`docs/media/IMG_7544.jpg`，以及用户在 iPhone 13 上连续三次
> “扫 → 相册 → 保存 → 分享回手机 → 再扫”得到的三张图：
> `docs/media/optimize/myself-1-...rendered2.JPG`、
> `myself-2-...rendered2.JPG`、`myself-3-...jpg`。

## 一、观察结果

### 1.1 尺寸与收敛

| 输入 | 尺寸 | 宽×高比 | 备注 |
|---|---:|---:|---|
| `IMG_7544.jpg` | 2939×3961 | 0.742 | 原图，带顶部/左侧书脊和页外背景 |
| 第 1 次输出 | 1695×2200 | 0.770 | 去掉右侧、底部页外背景 |
| 第 2 次输出 | 1611×2097 | 0.768 | 去掉顶部页外背景 |
| 第 3 次输出 | 1575×2051 | 0.768 | 去掉左侧折页/书脊；目标页基本贴边 |

最终目标页的宽高比稳定在 **0.768** 左右，说明三次处理不是随机抖动，而是
逐步逼近同一个页面边界。三次输出的像素面积依次约为原图的 32.0%、29.0%、
27.8%；最终线性分辨率只剩原图的约 **53%**。这部分下降来自反复
裁切、缩放到 2200 长边和 JPEG 重编码，不是页面内容本身变少。

### 1.2 内容有没有被误伤

用 macOS Vision OCR 对四张图做粗筛（同一语言/精度设置）：

| 输入 | OCR 行数 | OCR 字符数 | 备注 |
|---|---:|---:|---|
| 原图 | 76 | 1752 | — |
| 第 1 次 | 80 | 1784 | 出现少量透印/噪声行 |
| 第 2 次 | 78 | 1822 | 同上 |
| 第 3 次 | 79 | 1777 | 标题、页码、页脚仍在 |

目测第 3 次输出仍保留：

- 标题 `Writing Part 2 (An article)`；
- 右上页码 `2`；
- 页脚 `2 At school` / 页码 `11`；
- 两个表（含深色表头）的完整边界；
- 底部乐队照片的完整矩形；
- 正文两栏和页边留白。

因此，**没有发现明显文字、表格或照片被裁掉**。但 OCR 字符数不是内容保真
证明：OCR 会把透印/噪声识别成行，也可能漏掉边缘字形。第 1 次输出中 OCR
曾把标题识别成 `An rticle`，后续又恢复，说明 OCR 计数只能作为粗筛，不能
替代像素/结构安全门。最终验收必须再加标题/页码/页脚/表格/插图 bbox 包含
检查和 OCR 归一化召回。

### 1.3 竞品目标形态

`docs/media/optimize/other-1-2026-10-26-23.33_1.JPG`（2204×3028，宽高比
0.728）是竞品/扫描类输出：页面四边有均匀留白、背景基本纯白、无书脊/桌面，
标题、页码、两个表、照片都保留。它说明用户要的“扫描感”不只是裁掉背景，
还包括**白底画布 + 页面归一化 + 纸面干净**。

但它的页面宽高比 0.728 与本页实际页面比例约 0.768 不同，可能做了 A4
归一化或轻微拉伸；我们不能直接照抄它的尺寸/比例，否则会改变正文几何。
正确目标是保留页面原始比例，在页面外补白底画布；不要为了“看起来像
扫描件”而强行拉成 A4。

## 二、为什么多步有效

### 2.1 单次链路确实欠裁

仓库里 `IMG_7544` 的 P0 报告（`build/page-preprocess/final-p0/report-base-regression.json`）
显示：

- `detectedArea = 0.978`，检测框几乎就是整图；
- `chosen` 四角就是 `[0,0]–[1,1]`，`fallbackReason = detected_near_proposed`；
- `cropApplied = false`，输出 1633×2200。

代码层面有两个相关约束：

1. `PageBoundaryDetector.choose` 在检测框与提议框几乎重合时保留提议框，
   避免无意义抖动；整图提议就会保留整图。
2. `ImagePipeline.pageBoundary` 只在 `foldTrim != nil`、检测框明显小于提议框、
   或检测框虽大但偏离提议等条件下才启用 `contentQuad`；正常整图提议不会
   自动走内容包络裁切。

另外，静帧 `VisionEdgeDetector.stillPageCandidate` 的设计是“宁可不裁”：
页面充满取景、候选铺满画面时返回 `nil`，调用方回退整图。这个策略防止把
页面里的表格/色块当页面裁掉，但也意味着 **单次链路本来就不保证贴边裁切**。

### 2.2 重复扫描实际做了什么

每次“保存 → 再扫”都会：

1. 对上一轮结果重新检测/透视/增强；
2. 以新的宽高比和更干净的页边重新给检测器一个“页面级”输入；
3. 再缩放到 2200 长边并 JPEG 重编码。

第二、三次之所以能继续去掉顶部/左侧，很大程度上是因为输入已经是
“页面占满画面”的图，检测器/内容框更容易把剩余背景识别成页外区域。
这是一个 **coarse-to-fine 的经验过程**，不是当前算法保证的收敛，也不是
高质量的单次解法。

## 三、可行性判断

**结论：目标可行，但不能把“整个 renderPage 连续跑三次”直接当正式方案。**

可行的做法是：

### 3.1 首选：单次纸张/内容包络（P0.1 / PP-T051）

在原图全分辨率上一次性计算：

```
paperQuad          // 文档分割 + 页面矩形/纸张边缘；允许贴边
contentEnvelope    // 文字框 ∪ 表格 ∪ 图片/插图 ∪ 页码/页脚 ∪ 装饰块
cropQuad           // contentEnvelope + 0.3–0.8% 纸张安全边，夹在 paperQuad 内
```

关键点：

- **即使 proposed 是整图，也计算 contentEnvelope 并参与候选**；
- 不再要求“折页被检测到”或“检测框明显小于 proposed”才裁；
- 表格/图片/页码/页脚必须并进包络，不能只看正文文字框；
- 页面边缘和桌面颜色接近时，宁可回退整图，不能硬裁；
- 透视矫正后再裁，避免矩形 bbox 留下四个背景角。

这比“循环检测”更确定，也避免重复 P1/增强/JPEG。它直接对应用户三次
操作最终逼近的页面矩形。

### 3.2 可选：一次 refine（P0.1 / PP-T052）

如果首轮裁切后仍有 >2% 的页外背景，再做一次精化，但必须：

- 最多 1 次 refine（总候选 ≤2）；
- 在原图全分辨率内存中做，不落中间 JPEG、不重复 P1/增强；
- 裁切变化 <0.3% 页宽/高就停止；
- 只允许缩小裁切框，不允许在两次之间来回跳；
- 记录每次候选和最终选择，便于回归。

refine 只是兜底，不应成为主路径。若首轮内容包络正确，refine 应无事可做；
这正是“幂等性”验收要证明的。

### 3.3 不建议：直接循环现有完整链路

不建议把 `renderPage` 连续调用 3 次作为产品逻辑：

- 每次都会重复 P1，纸面/颜色可能被反复修改；
- 每次 JPEG + 缩放，最终分辨率下降；
- 检测器可能在“裁/不裁”之间振荡；
- 耗时线性增加，iPhone 13 冷启动会更差；
- 结果依赖上一轮输出，难以复现和回归。

## 四、主要风险与规避

| 风险 | 具体表现 | 规避 |
|---|---|---|
| **误裁有效内容** | 标题首字、页码、页脚、表边、图片边缘被切 | 内容包络必须含文字/表格/图片/页码/装饰 bbox；保留 0.5–1% 纸内边；OCR 召回 + bbox 包含检查；失败回退上一轮/整图 |
| **表格/OCR 抖动** | 每次裁切都重跑结构识别，表数量/行列变化 | 结构 bbox 只从原图/首轮拿一次；裁切只改几何；表签名不一致立即回退；已知 iOS 27 模拟器表抖动不能当真实回归 |
| **重复编码/降采样** | 三次输出只剩原图 53% 线性分辨率 | 只在原图全分辨率内存中迭代；最终只编码一次；不要中间保存/重导入 |
| **检测振荡** | 裁切框左右/上下来回变，或越裁越小 | 最多 1 次 refine；变化 <0.3% 即停；选择“安全候选中最不激进”的一个；记录候选轨迹 |
| **页面贴边/背景同色** | 纸边与桌面颜色接近，检测不到外框，内容包络过紧 | 用纸张颜色/边缘双通道；不确定时回退整图；输出可加白底画布而不是硬裁 |
| **曲面/折页** | 矩形裁切去掉了折页，但正文仍有局部弯曲/倾斜 | 裁切后用 P2/P3 的透视/网格处理；折页走 `SpreadSplitter` 且保留文字损失门；不要用裁切代替拉直 |
| **“扫描观感”不足** | 裁完仍有灰纸、透印、页边阴影，不像扫描件 | 裁切只是第一步；后续加白底画布、P1 纸面归一化、G1 透印处理；分别验收，不混在一个任务 |
| **过拟合单一样张** | 只对 `IMG_7544` 有效，其他书/桌面失败 | 至少 10–20 张多条件样张；至少包含平放/弯页/深色桌面/白桌面/彩色封面；按 P3 回归 |
| **性能超预算** | 多次边界/结构识别让 iPhone 13 首跑 >2s | 首轮内容包络 + 最多一次 refine；低分辨率分析、全分辨率应用；P0 增量 ≤600ms；真机冷/热各测 |
| **不可复现** | 用户的操作序列、分享压缩影响结果 | 固定原图夹具；记录每一步裁切框/尺寸/OCR/表结构；用实际 `renderPage` 做回归，不只测检测器 |

## 五、建议验收门（P0.1）

1. **页外背景**：最终图四边可见页外背景 <2%；不要求把纸边裁成 0（保留
   0.5–1% 纸内边，避免切字）。
2. **内容安全**：
   - 标题/首字、页码、页脚、表格、插图 bbox 包含率 100%；
   - OCR 归一化字符召回 ≥99.5%（相对原图）；
   - 表格结构签名与不裁/首轮参照一致；
   - 折页文字损失不超过现有门限。
3. **幂等性**：对最终输出再跑一次预处理，裁切框变化 <0.5% 页宽/高；
   若明显继续收缩，说明首轮仍欠裁或算法不稳定。
4. **性能**：P0 增量 ≤600ms（iPhone 13，热机；冷启动另记）；超预算退回
   单次内容包络。
5. **兼容**：WPS 0.906224 不回退；OCR/P1/P2 既有指标不回退。

## 六、建议执行顺序

1. **PP-T050**：固定四张图，补齐实际 `renderPage` 的裁切框/OCR/表结构证据。
2. **PP-T051**：单次纸张/内容包络，优先解决“欠裁”；这是收益最大的一步。
3. **PP-T053**：先接安全门，再打开裁切，避免“看起来更干净但切了字”。
4. **PP-T052**：只有 T051 后仍 >2% 页外背景才做一次 refine。
5. **PP-T054**：白底/纸边扫描观感，与 P1 光照分开评估。
6. G1 透印按 `TODO.md` 的 G1-A/B/C 顺序，等 P0.1 稳定后再做。

**一句话**：多步收敛证明了“目标边界是稳定的”，但不能证明“循环是正确实现”。
最高收益是把“纸张边界 + 内容包络”一次算准，再用一次 refine 兜底；不要
把三次完整导出固化进产品。

## 七、实现结果（2026-10-27）

### 7.1 已接代码

- `Zhixia/Services/Image/PageContentEnvelopeDetector.swift`
  - 360px 缩略栅格估计纸面中心亮度；
  - 逐行/列纸面占比找上/左/右/下页边；
  - 纸内暗像素/高饱和像素取内容包络；
  - 返回 `paperRect/contentRect/rect/backgroundResidual`。
- `ImagePipeline.pageBoundary`
  - 整图/近整图 proposed 也计算包络候选；
  - 文字 bbox 作为上/左锚点，保留约 0.8% 纸内边；
  - 表格安全门通过后裁切，失败回退整图；
  - table mismatch 时用表格 bbox 扩框，最多 retry 一次。
- `PagePreprocessReport`
  - 新增 `cropSource/paperEnvelope/contentEnvelope/envelopeBackgroundResidual/
    envelopeTextCoverage/envelopeRefineApplied/envelopeSkipReason/
    tableSafetyOriginalRects`。
- `PagePreprocessRecipe.scanCanvasBorderRatio = 0.006`
  - 裁切成功后加白底画布；只影响 `renderPage`。

### 7.2 样张结果

| 指标 | 结果 |
|---|---|
| 原图整图 draft | `cropSource=content_envelope`、`cropApplied=true` |
| 裁切框 | 左 0.0162、上 0.0352、下 0.9870、右 1.0 |
| 文字覆盖 | `textCoverage=1`、`envelopeTextCoverage=1` |
| 输出 | 1694×2200（含 0.6% 白底画布） |
| 标题/页码/表格/照片 | 目测保留；OCR 回读标题/页码仍在 |
| 三张中间图 | 1 表格签名不一致时框外刷白；2/3 可裁 |
| 幂等性 | 对第一轮输出再跑整图 draft：1694×2200 → 1694×2200 |
| WPS realbase | **0.906224**，PNG SHA-256 与已接受基线 byte-identical |
| 单测 | `PageContentEnvelopeDetectorTests` 2/2、`PageCropSafetyTests` 5/5、`PageCropConvergenceTests` 3/3、`ImagePipelineTests` 2/2 |
| 全量（P0.1 后） | 492 total / 481 passed / 1 expected / 10 failed（已知顺序/预览抖动，见 TODO） |

证据：

- `build/page-preprocess/crop-convergence/T050-IMG_7544-rendered.jpg`
- `build/page-preprocess/crop-convergence/T050-IMG_7544.preprocess.json`
- `build/page-preprocess/crop-convergence/T050-intermediate-summary.json`
- `build/word-fidelity/p01-wps/`（WPS 独立复跑）
- `build/page-preprocess/crop-convergence/device-round1-2/`（真实设备原图、旧报告、修复后本地复现）

### 7.4 真机 round1 回归（2026-10-27）

用户在 iPhone 13 上用“扫 → 相册 → 原始图 → 保存 → 分享”得到：

`docs/media/optimize/round1-1-4AE6D8D-9473-47B4-8C7D-2F6258549514-rendered.jpg`（1561×2200）

现象：顶部仍有明显背景，底部也有一点背景。根因是**页面级 draft**
（自动边缘检测已给出页级 quad）此前不进入包络分支，只走旧的页级左缘
内缩；包络只在整图/近整图 proposed 时运行。

修复：

- `pageBoundary(allowEnvelope:)`：自动 page-level draft 也计算纸张/内容
  包络；只有用户手动拖角（`userAdjustedQuad=true`）才跳过。
- 包络增加上/下/左/右文字锚点；下缘按文字 +0.8% 收边，去掉底部背景。
- 表格安全门拒绝裁切时不再直接留原背景：保留原页几何，把候选框外刷白
  （`backgroundWhitened=true`），避免为了去背景破坏表格结构。
- 新增 `PageCropConvergenceTests/pageLevelDraftStillRefines` 回归。

随后用户在同一流程得到：

`docs/media/optimize/round1-2-BC0771BF-E8DC-4EB1-9C1E-9B875236D6AC-rendered.jpg`（1869×2200）

出现回归：左侧折页进入、右侧背景变多、顶部有效信息被裁、右上角 `2` 消失。
设备侧 `preprocess.json`（`build/device-round1-2/preprocess.json`）显示真实
页面级 draft：

- `proposed` 面积约 0.776；
- 旧 `chosen.topLeft.y=0.1098`；
- `textBounds.top=0.1178`，`paperEnvelope.top=0.0972`；
- 右上方页码 `2` 的 OCR 顶部约 **0.086**，落在文字锚点之外。

因此旧逻辑把 `2` 当页边背景裁掉；同时页级 draft 的左右范围已经包含
折页/背景，包络候选在部分条件下还会向外扩。

当前修复（未提交验收前）：

- 包络候选必须夹在 `chosen` 内，禁止扩回折页/右侧背景；
- 纸面有明显上边距（>3%）时保留纸面顶部 **1.5%** 页眉安全带，避免把
  页码/页眉当背景裁掉；
- 表格安全门拒绝裁切时保留原页几何、框外刷白；
- 编码前裁掉透视采样产生的右侧 1px 黑边。

用设备原图 + 真实 proposed 的本地复现：输出 **1562×2194**，
`backgroundWhitened=true`（表格结构保护回退），OCR 回读右上 `2` 存在，
目测无左侧折页/右侧背景。随后用户在 iPhone 13 上复测得到
`round1-3-2C35B62C-D12F-4E13-A2A3-7AA9702F552F-rendered.jpg`（1704×2200）：
整体已大幅改善，但**右上角仍有一条页外背景**（最右侧约 12px 非白条）。
当前代码的本地复现（同一设备原图 + DB 中的 proposed quad）已把右侧/顶部
多余条刷白；待用户重新安装这一版复测确认。

### 7.4.1 出口边缘清理（2026-10-27 落地）

真机 round1-3 的残留不是简单的竖直条，而是白底画布内侧的**楔形**：
越靠上页外背景越宽（顶部约 12–25px），靠下页面纸面已经贴到白边。
因此矩形裁切/固定右侧条会误伤下半页内容，改为 `PageEdgeCleaner`：

- 逐行从右侧白边向内找连续纸面像素，只把纸面右边界外侧刷白；
- 逐列从顶部白边向下找纸面顶边，只刷纸面以上；扫描遇到低饱和黑色
  像素（页码/文字）立即中止，避免把右上 `2` 当背景清掉；
- 右上角再对红色木纹、灰色页边做受限颜色清理；
- 全部在**一次全图位图遍历**里完成，不裁切、不缩放；`renderPage` 输出
  尺寸不变。

用 `round1-3-2C35B62C-D12F-4E13-A2A3-7AA9702F552F-rendered.jpg`
回归：右侧红色背景和顶部楔形已清，右上 `2` 保留；输出
`build/device-round1-3/edge-cleaned.jpg`。`PageContentEnvelopeDetectorTests`
4/4、`PageCropConvergenceTests` 3/3 通过。WPS realbase 重新渲染
`build/word-fidelity/p01-edge-wps-final/edge-final-realbase-wps.png` 与基线
`round2-realbase-wps.png` **SHA-256 完全一致**（`3faabfd0…`），仍
**0.906224**。

全量 `make test` 当前 **492 total / 481 passed / 1 expected / 10 failed**；
本轮 10 个失败为 Golden 4、WordFidelity 1、Review preview 4、ReviewSplit
1；`ReconstructEndToEndTests` 本轮未失败（曾在其他顺序下抖动），单独跑
ReviewViewModelTests、ReviewSplitProposalTests、ReconstructEndToEndTests
均通过。

真机重装后的实际复测（用户从相册选 `IMG_7542.JPG`，保存并分享）得到
`docs/media/optimize/round1-4-324DA051-5DB2-4586-86AF-B33CDCF1B426-rendered.jpg`
（**1704×2200**），与 `build/device-round1-4/rendered.jpg` 一致：

- 右侧红色/灰色页外背景已清，页面右缘之外为白底；右侧白边中位
  **12px**、最小 **11px**（`build/device-round1-4/summary.json`）；
- 顶部楔形背景已清，右上角页码 `2` 保留；macOS Vision OCR 读取到
  **82 行**文本，独立 `2` 位于右上（bbox x≈0.927、top≈0.032），说明
  清理没有把页码当背景；
- 左侧折页/桌面背景不可见，表格和照片完整，输出尺寸未变；
- 这次是用户一次“选原图 → 保存 → 分享”，不是多次重扫。

设备的 `default.store` 仍保存该页 proposed quad：
`topLeft=[0.0899,0.0412]`、`topRight=[0.9510,0.0334]`、
`bottomRight=[0.9861,0.9648]`、`bottomLeft=[0.0903,0.9570]`
（`build/device-round1-4/default.store`，page `324DA051-5DB2-4586-86AF-B33CDCF1B426`）。
右边缘背景已由出口清理处理，不再依赖再裁一刀。

### 7.5 设备数据获取

App 保存后会把临时的 `preprocess.json` 清掉，但 `Library/Application Support/
default.store` 的 `ZPAGEENTITY.ZQUADDATA` 仍保存页面级 proposed quad。
通过 `xcrun devicectl device info files` / `device copy from` 可取得：

- `Library/Application Support/Zhixia/files/.../<id>-original.jpg`
- `...-rendered.jpg`
- `Library/Application Support/default.store`（含 quad）

当前设备最新样本：`324DA051-5DB2-4586-86AF-B33CDCF1B426`，
`ZQUADDATA` 的 proposed quad 保存在 `build/device-round1-4/default.store`。
上一轮样本 `2C35B62C-D12F-4E13-A2A3-7AA9702F552F` 仍是 round1-3
回归测试夹具。

### 7.3 未闭环

1. **中间图 1/2 表格签名不一致**：当前安全门选择回退而不是接受结构变化；
   这是正确的内容优先策略，但意味着用户如果反复扫中间图，仍可能看到
   “第二/第三次才裁干净”。最终产品应从原图一次收敛，不依赖中间图。
2. **refine 未真正触发**：原图 `envelopeRefineApplied=false`；table-aware
   retry 已接线但本样张不触发，背景残留 refine 还需合成/真机样本验证。
3. **幂等性**：已对第一轮输出再跑一次实际 `renderPage`，输出尺寸
   1694×2200 → 1694×2200；白底画布通过四边白框检测避免重复裁切/加边。
4. **标题/字形安全边**：当前 0.8% 文字边来自 bbox，仍建议真机多字体复核；
   OCR 输出中标题曾出现 `An rticle` 的识别错误，目测字形未被裁，但不能
   只靠 OCR 证明。
5. **10–20 张多条件样张**：尚未跑；不能只凭 `IMG_7544` 宣称通用。
6. **真机 round1-2 仍未复测**：本地设备原图/真实 proposed 已复现修复；round1-4（`IMG_7542`）已完成一次原图→保存→分享验收，多张样张仍需回归。
