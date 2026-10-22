---
id: editable-word-fidelity
title: 可编辑排版 Word：消除底图原字与文本框叠字，双口径 SSIM ≥ 0.90
verify: make editable-fidelity SIM_NAME='iPhone 18 Pro' SIM_OS=27.0
protect: ZhixiaTests/WordFidelityExportTests.swift,Tools/word-fidelity/
domain: word-fidelity
---

当前仓库正在迭代「版面还原（可编辑）」的 Word 导出保真度。真实用户路径是：

扫描 → 相册收藏第一张（原文件名 `IMG_7544.jpg`）→ 图片还原 →
版面还原（可编辑）→ 导出 Word → Word 渲染成图片 → 与原图相似度 ≥ 0.90。

当前证据（2026-10-22）：

- App 侧导出模型（预览 == 导出模型）SSIM = 0.984；
- QuickLook 渲染 docx 后 SSIM(页面图) = 0.767、SSIM(原始照片) = 0.773；
- 导出层损失 = 0.218。坏在 OOXML 表达：净化遮罩是 `wps:wsp` 形状，部分渲染器
  不画 / 画成透明，原文字没有被真正擦掉，导致「底图原字 + 浮动文本框」叠字。

本轮任务（对应 `spec/word-fidelity/tasks.md` 的 T021 / R3）：

1. **把「擦除原文字」烘进底图**：在 App 导出 `.restored` docx 时，基于
   `LayoutMaskBuilder` 产出的净化矩形，把原文字区域用环带 median 底色直接刷到
   底图像素上，生成「净化底图」，作为 docx 的唯一底图 media 嵌入。
2. docx 中**不再发射 `name="Mask"` 的 mask shape**；保留 figure/barcode/artwork
   的 `srcRect` 裁剪（仍复用同一张净化底图）。
3. 浮动文本框（`wps:txbx`）和原生浮动表格保持原位、可编辑，不得退化成图片版。
4. 每页仍然恰好一张 image media（JPEG 可），不重复嵌图；DOCX 仍可被 Word 解析。
5. 同步更新因行为变化而过期的结构测试（`DocxRestoredLayoutTests`），但**不得**
   修改受保护的 `ZhixiaTests/WordFidelityExportTests.swift` 与
   `Tools/word-fidelity/`。既有测试语义不得削弱。

验收命令（受保护、不可改）：

```sh
make editable-fidelity SIM_NAME='iPhone 18 Pro' SIM_OS=27.0
```

它必须同时满足：

- `WordFidelityExportTests` 全部通过；
- QuickLook 渲染 `out-restored.docx` 后，SSIM(页面图) ≥ 0.90 且
  SSIM(原始照片) ≥ 0.90；
- 渲染图目视无「同一行字出现两份」的叠字。

实现提示：

- 底图 media 需要从「原文件字节」改为「烘焙后的 JPEG 字节」；模型真值预览
  `preview-restored.png` 仍走 `LayoutCanvas`，不需要为了宿主渲染器改预览。
- `LayoutMaskBuilder` 的 rect 是 Vision 归一化坐标（左下原点）；烘焙时注意 y 翻转。
- 现有 `registerImageMedia(path:)` 可扩展为 data + 扩展名版本；不要在 docx 里多注册
  未使用的原图。
- 失败时保留 `build/word-fidelity/` 的渲染图、`attribute.py` 分层结果和测试日志，
  不要删除证据。
