# 18 · 用 h2oc 跑「可编辑版面还原 Word」迭代（2026-10-22）

> 状态：**已收尾（2026-10-25）**。h2oc 第一轮 T021 已完成；本文是执行日志 + 证据索引 + 跨任务经验。
> 真实 WPS 验收见 §七；0.961/0.965 是 QuickLook 代理，不是最终门限。
> 上游：[`docs/17-editable-tier-fidelity-iteration.md`](17-editable-tier-fidelity-iteration.md)、
> [`spec/word-fidelity/tasks.md`](../spec/word-fidelity/tasks.md)。

---

## 一、目标与验收口径

用户验收路径（iPhone 18 Pro 模拟器）：

```text
扫 → 相册 → 收藏第一张（IMG_7544.jpg）→ 图片还原
  → 版面还原（可编辑）→ 导出 Word
  → Word 渲染成图片 → 与原图相似度 ≥ 0.90
```

工程化落地分两层：

| 层 | 命令 / 路径 | 作用 |
|---|---|---|
| 可重复的自动闸门 | `make editable-fidelity SIM_NAME='iPhone 18 Pro' SIM_OS=27.0` | 用仓库内 `docs/media/IMG_7544.jpg` 走真实夹具链路，导出 `.restored` docx，QuickLook 渲染 + ffmpeg SSIM，双口径 ≥ 0.90 |
| 用户路径验收 | 模拟器 + WPS/Word 渲染 | 验证 App UI 全链路、分享/导出、跨渲染器观感；渲染图进入证据目录 |

自动闸门是**代理指标**（QuickLook 不能完全等价 WPS/Word），所以最终判定仍以用户路径
证据为主；自动闸门负责防止回归和给 h2oc 提供确定性信号。

---

## 二、基线（改动前，2026-10-22 12:57）

| 指标 | 数值 |
|---|---|
| App 导出模型 SSIM（`preview-restored.png` vs `page.jpg`） | **0.984** |
| QuickLook 渲染 docx SSIM（页面图） | **0.767** |
| QuickLook 渲染 docx SSIM（原始照片） | **0.773** |
| 导出层损失（模型 − docx） | **0.218** |
| 图片版对照（页面图 / 原片） | 0.914 / 0.919 |

归因：版面模型是好的，坏在 OOXML 导出层的**净化遮罩表达**——mask 是
`wps:wsp` 形状，本机渲染器画成透明/不画，底图原文字仍在，浮动文本框叠上去。

**本轮假设（T021）**：把擦除烘进底图像素，docx 不再依赖 mask shape 被渲染。

---

## 三、执行路径

### 3.1 真实模拟器路径（人工/自动混合）

1. iPhone 18 Pro 模拟器：`9165BAF7-0883-4EC7-BD1E-94CE7198FB1B`，iOS 27.0。
2. 相册收藏第一张：`IMG_0009.JPG`，其 `ZORIGINALFILENAME = IMG_7544.jpg`
   （Photos.sqlite 已核对）。
3. 当前 App 文档 `Writing Part 2 (An article)` 的 original 图与相册原图同尺寸
   （2939×3961），即目标样张；UI 已进入「版面还原（可编辑）」。
4. 导出按钮生成：
   `.../tmp/Zhixia/Zhixia-10月22日 扫描-20261022-1258.docx`；
   已复制到证据目录 `build/word-fidelity/acceptance-2026-10-22/export-editable.docx`。
5. 证据截图：
   - `01-reconstruct-editable.png`（UI 档位与预览）
   - `02-export-share-sheet.png`（导出后）
   - `ql/export-editable.docx.png`（QuickLook 基线渲染，可见叠字）

### 3.2 h2oc 自动迭代路径

- 项目内配置：`.harness2/config.json`
- 任务：`.harness2/tasks/editable-word-fidelity.md`
- 模型：`opencode/deepseek-v4.1-flash-free`
- 验证：`make editable-fidelity SIM_NAME='iPhone 18 Pro' SIM_OS=27.0`
- 保护：`ZhixiaTests/WordFidelityExportTests.swift`、`Tools/word-fidelity/`
- 运行：`h2oc run --tasks editable-word-fidelity --k 1 --require-verify`
- 证据（运行后填充）：
  - `.harness2/runs/.../editable-word-fidelity/`
  - `.harness2/library/...`
  - `h2oc report` / `h2oc diff`

### 3.3 宿主渲染器

| 渲染器 | 状态 | 结论 |
|---|---|---|
| QuickLook（`qlmanage`） | 可用，自动闸门 | 可渲染文本框/底图；但形状透明度与 Word 可能不同，只作代理 |
| LibreOffice headless | 本机转换挂起/不出文件 | 暂不作为门禁 |
| WPS Office 6.13.2 | 已安装，GUI | 作为最终跨渲染器人工抽样；需要 GUI 自动化或人工截图 |
| Microsoft Word | 未安装 | 不作门禁 |

---

## 四、运行日志（按时间追加）

### 2026-10-22 12:57 基线取证

- 模拟器当前文档与目标相册图核对：同尺寸；UI 档位已是「版面还原（可编辑）」。
- 导出 docx 并复制到证据目录。
- QuickLook 渲染 + SSIM：0.767 / 0.773；确认叠字。
- 新增 `make editable-fidelity` 与 `WORD_FIDELITY_GATE_TIER=restored`，基线门禁失败（预期）。

### 2026-10-22 13:00 h2oc 接入

- `h2oc init` 建立 `.harness2/base`。
- 落盘任务 `editable-word-fidelity`，验证超时 1800s。
- 待运行：`h2oc run --tasks editable-word-fidelity --k 1 --require-verify`。

---

## 五、证据索引

| 证据 | 路径 |
|---|---|
| UI 预览 | `build/word-fidelity/acceptance-2026-10-22/01-reconstruct-editable.png` |
| 导出后 UI | `build/word-fidelity/acceptance-2026-10-22/02-export-share-sheet.png` |
| App 导出 docx | `build/word-fidelity/acceptance-2026-10-22/export-editable.docx` |
| QuickLook 基线渲染 | `build/word-fidelity/acceptance-2026-10-22/ql/export-editable.docx.png` |
| 自动闸门产物 | `build/word-fidelity/out-restored.docx`、`page.jpg`、`reference.jpg`、`preview-restored.png` |
| h2oc 运行 | `.harness2/runs/...`（运行后补） |

---

## 六、判定规则

- **自动闸门通过**：双口径 SSIM ≥ 0.90，且 `WordFidelityExportTests` 全绿。
- **用户路径通过**：WPS/Word 实际打开 docx → 转图片 → 与原片比对 ≥ 0.90，且目视无叠字。
- **未通过**：记录失败层（模型 / OOXML / 渲染器），进入下一轮 R4（字号行距、遮罩瘦身）；
  连续 2 轮无进展则按 docs/17 止损线冻结可编辑档。

---

## 七、最终状态（2026-10-25）

### 7.1 h2oc 运行结果

- 第一轮 T021 的交付：内联净化底图、零 `name="Mask"` shape、保留 `wps:txbx` / 原生
  `w:tbl`；`make editable-fidelity` 的 QuickLook 代理 SSIM = **0.961 / 0.965**。
- 运行过程中 `agg1` 在 green gate 后的 `make test` 出现 6 个失败并超时；`inv1` 在
  848.5s 内完成 `DocxRestoredLayoutTests` 21/21 + gate + 全量 449。该差异被记录为
  **confounded**（多个组件同时变化）。
- 运行证据：`.harness2/runs/local-oc-agg1/editable-word-fidelity/`；
  harness 库：`.harness2/library/k1/agg/word-fidelity/`。

### 7.2 真实 WPS 收尾

h2oc 的 gate 用 QuickLook，不能替代 WPS。2026-10-24 用 WPS 真实渲染：

| 场景 | WPS SSIM |
|---|---:|
| 模拟器 `original-base.jpg` | **0.906224** |
| iPhone 13 rendered 页 | **0.907581** |

同时修掉真机 3 列×4 行表格过分割、题头行序反转、右栏续行拆块；详见 `docs/17` §八。
因此 h2oc 代理分数不再作为最终验收数字。

### 7.3 h2oc 对项目的帮助 / 跨任务经验

**帮助**：
1. 提供确定性 verify（`make editable-fidelity ...`）与 protected 边界（`WordFidelityExportTests`、`Tools/word-fidelity/`），让多轮 agent 改动用同一门限。
2. 运行隔离 + library：每轮 diff/trajectory/verify 落盘；被选 harness 与 `EXPERIENCE.md` 可被后续任务复用。
3. 暴露验证盲区：gate 只跑 `WordFidelityExportTests`，**`DocxRestoredLayoutTests` 必须单独跑**；这直接促成本轮测试清理。
4. 生成可迁移经验（`EXPERIENCE.md`）：

> **cue**：验收命令只执行测试子集，而任务允许/要求修改子集外的测试。
> **lesson**：在 verify 步骤要求执行本次改过的每个测试文件/类，给出具体命令
> （`make test-only T=<Class>`），并在最后一次编辑后检查该命令确实跑过。
> **confidence**：medium（多组件同时变化，无法完全隔离；但 2/2 带指令的 run 都执行了被改测试类，
> 未带指令的 base1 改了测试但从未运行）。

**局限**：
- `k=1` 只有一个被选 harness，跨任务泛化证据有限；
- 没有 WPS 真实渲染能力，0.961/0.965 只是代理；
- `.harness2` 是仓库内 h2oc 工具，不是 Google 依赖，也不进入 App 运行时。

### 7.4 下一阶段

Word 可编辑档暂告一段落；下一阶段按 [`docs/19-page-preprocess-plan.md`](19-page-preprocess-plan.md)
做页面预处理（页外裁切 → 折痕/光照 → 页边拉直），再回来处理重影。
