# 04 实现原理与编码实践

怎么把纸变成文档：几何、管线、并发、落盘、还原启发式，以及编码规矩。  
产品 [01](01-product-prototype.md) · 架构 [02](02-architecture.md) · 选型 [03](03-tech-choices.md) · 还原 [06](06-document-reconstruction.md)

---

## 1. 从像素到四边形

```
视频帧 (≈720p, up)
  → VNDetectRectanglesRequest
  → 打分（面积 × 中心 × 方正度）
  → 归一化 Quad
  → FrameMapper（AspectFill）
  → Overlay
```

`QuadSmoother`：顶点 EMA（α≈0.35）+ 稳定约 0.55s → `locked`。失锁：连续无检测或面积骤变。必须单测。

证件：蒙版窗先验，IoU 不够则用窗本身。

**禁止**假设预览等于全帧。Vision / CI 坐标原点与 UIKit 不同，换算收进 Mapper / 拉正，不进 View。

---

## 2. 拍照与原图

Photo Output → `tmp/...-original.jpg` + 当前 Quad → `PageDraft`。

视频帧与照片 FOV 可能略差；整理打开时可对原图再静态检测（用户已拖角则不覆盖）。相册导入只走静态检测。

还原裁配图、条码：**优先 original**，不要用增强后的黑白图。

---

## 3. 透视拉正

四角 → `(0,0)-(W,0)-(W,H)-(0,H)`，`max(W,H)≤2200`。Core Image **左下原点**。失败则整图 + 全图 Quad。旋转在拉正后按 `rotationTurns` 做。

---

## 4. 增强滤镜

统一 `CIContext`，参数集中在 `EnhancementRecipe`。五档：原图 / 增强 / 去阴影 / 灰度 / 黑白。View 禁止拼 `CIFilter(name:)`。

滤镜 / 旋转操作应退出裁切编辑态并触发重渲染（见 `ReviewViewModel`）。

---

## 5. OCR

对图跑 `VNRecognizeTextRequest`（accurate，中英，语言校正）。行盒按 Vision 坐标排序。

质量：`OCRTextQuality` 提高 CJK 权重，拒绝「空语言列表先出 Latin 垃圾」。深色界面截图可反色比对。

库搜索只扫 `ocrSearchBlob`，不按键全库 Vision。

---

## 6. PDF（扫描件）

每页一张 rendered 图 → `PDFExportService`。Caches 临时文件，分享后删。这是「长得像扫描件」的分享，不是可检索 PDF。

---

## 7. 还原（本机）

### 7.1 解析顺序（`OnDeviceDocumentParser`）

1. OCR  
2. 场景路由 `ReconstructSceneRouter`（可参考条码数量）  
3. `OnDeviceTableCluster`：短文本盒按 midX/midY 聚类成 2–5 列 × ≥3 行；过滤 A/B/C 选项字母表  
4. 剩余行 → `OnDeviceReadingOrder`（行聚类 → 段落 / 标题）  
5. `OnDeviceFigureRegions`：文字+已占区栅格，连通空白 → 候选框 → `NormalizedImageCrop` PNG  
6. `PageBarcodeDetector` 裁条码图 + payload  
7. 按视觉 Y（maxY）排序 blocks  

### 7.2 导出

- DOCX：段落、`w:tbl`、DrawingML + `word/media/imageN.png`  
- 可检索 PDF：文字、表格线框、嵌图  

预览与导出共用 IR。改识别只改 Parser / Domain；改样式改 Export。

### 7.3 已知不足

聚类与空洞检测对两张验收样张仍失败或严重偏差——详见 [06 §12](06-document-reconstruction.md#12-已知问题2026-09)。改参数前先补失败样张的 OCR 盒 dump，避免盲调。

---

## 8. 落盘事务

```
1. 各页拉正+增强写入 files/{docID}/
2. SwiftData insert
3. 成功删 tmp；失败删已写 files，不 insert
```

删除：先文件后实体（或保证可扫孤儿）。ViewModel 禁止手写路径。

---

## 9. 内存

- `[PageDraft]` 不持全尺寸 `UIImage`  
- 页条缩略图缓存有上限  
- 整理只解码当前邻页  
- 拍照尽快落地 Data  

---

## 10. 并发纪律

```
主线程：View / ViewModel
相机 actor · Vision actor（丢帧）· Image actor · OCR/Parse actor
```

离开取景取消 Task + `camera.stop()`。快速滑页取消过期渲染。

---

## 11. Feature 写法

```
View → ViewModel → 协议
AppEnvironment 提供实现
```

状态用枚举（如 `LibraryLoadState`），避免多布尔打架。字符串进 xcstrings。每 Feature 尽量有 Preview。

合并前建议绿：Smoother、无页不能完成、保存清 tmp、删文档清文件、灰度饱和度、还原相关单测。

---

## 12. 安全与隐私

图在沙盒；分享用户主动。默认日志不dump帧。接云解析前必须改产品文案与权限披露。

---

## 13. 对标全能扫描王时怎么调

画质对照：边是否切手、白纸色、阴影、印章红、铅笔。调 `EnhancementRecipe` 与最长边，不堆入口。证件先保证窗，字段结构化不进 v1。
