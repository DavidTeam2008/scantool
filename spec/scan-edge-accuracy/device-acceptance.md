# 真机自验清单 · 扫描框边与成片裁剪精度（scan-edge-accuracy）

> 模拟器全量单测已绿（165 passed + 1 已知问题）。本清单覆盖单测**无法**证明的部分：
> 真机相机的实际视野、预览层对齐、自动快门手感。逐项打勾，全过才算本特性收尾。
> 实现说明见 `plan.md` D1~D10，日志语义见 `docs/09-project-handbook.md` §4.2。

## 0. 日志抓取指引

所有验收点依赖 `ZhixiaLog.capture` 结构化日志（os_log）：

```bash
# 方式一：Console.app
#   左侧选中 iPhone 设备 → 搜索框输入 subsystem:com.david.Zhixia category:capture

# 方式二：CLI（手机连 Mac）
log stream --predicate 'subsystem == "com.david.Zhixia" AND category == "capture"' --style compact
```

四类日志的含义：

| 日志前缀 | 含义 | 验收看什么 |
|---|---|---|
| `geometry videoAspect=… photoAspect=…` | 取景启动与快门时刻缓存的视频/照片竖屏宽高比 | 真机应接近 `0.5625 / 0.75`（16:9 视频 + 4:3 照片）；快门时刻与 AVCameraSession 的 `photoGeometry capturedAspect=… estimated=… delta=…` 对读，delta 应 ≤ 0.01（逐帧自校正生效） |
| `overlayProbe … scaleX=… scaleY=… offsetX=… offsetY=…` | 预览层实测的照片空间→屏幕映射 | 出现实测值即探针生效；`fallback=frameMapper` 表示探针不可用走了回退（见 SC-003） |
| `detectionTier path=… tier=… candidates=… selectedArea=…` | 候选择优层级 | 近拍书满幅时应出现 `tier=2`（放宽兜底生效）；常规场景 `tier=1` |
| `suspiciousLock area=… minMargin=… autoCapture=suppressed` | 可疑锁定门禁抑制了自动快门 | SC-004 应出现本日志 |

## SC-001 近拍书本不裁边（两级兜底 + 贴边吸附）

**步骤**：一本书平放，手机凑近到书占满取景框（四边贴近屏幕边缘），等锁定后自动快门（或手动），连续 **10 次**（每拍一次可微调距离/角度）。

**通过标准**：**≥9 次**成片四边完整（书边即片边，不缺角、不裁文字）。

**日志佐证**：拍摄瞬间应看到 `detectionTier path=still tier=2`（近满幅走二级兜底）。

**失败时看**：仍被裁 → 查 `detectionTier` 是否始终 `tier=1`（检测层没给出近满幅候选）；
四边各裁一圈细边 → `EdgeSnapper` 吸附未生效（`gradientThreshold` 或背景亮度问题，记录当时桌面/背景）。

## SC-002 常规文档一次锁对（坐标链整体）

**步骤**：A4 文档放桌上，正常距离拍摄（文档占画面 60~80%），连续 **10 次**。

**通过标准**：**≥8 次**满足「虚线框稳定贴合纸边 → 约 0.55s 锁定变实线 → 成片完整」
一次锁对；overlay 与纸边**肉眼无左右错位**（照片 FOV 比视频宽，错位即坐标链缺陷复发）。

**日志佐证**：每次取景应有 `geometry videoAspect≈0.5625 photoAspect≈0.75`；
`overlayProbe` 出现实测 `scaleX/scaleY/offsetX/offsetY`。

**失败时看**：overlay 左右偏 → 记录 `overlayProbe` 数值与 `fallback` 状态；
成片裁边 → 对比 `detectionTier selectedArea` 与实际文档占比。

## SC-003 模拟器对齐说明（已知差异，不算失败）

模拟器 `PreviewCamera` 恒等几何、无真实预览层连接，`overlayProbe` 会显示
`fallback=frameMapper`、`geometry` 显示恒等值——**这是预期行为**（回退路径本身是
被测功能，`CaptureFallbackTests` 已覆盖）。真机才需要 SC-002 的对齐验证。
若真机也持续 `fallback=frameMapper`，说明预览层探针未就绪（`CameraPreviewBinder`
的 attach 时机问题），记录出现频率。

## SC-004 可疑锁定不自动拍（门禁）

**步骤**：打开设置确认「自动拍摄」开启；把书凑近到**超出取景框**（一角明显被屏幕边缘裁掉），
hold 住不动。

**通过标准**：锁定（实线框）后**不**自动快门；状态区显示「再往后移一点，把书拍完整」；
后退让书完整入框后，约 0.55s 自动快门恢复。

**日志佐证**：hold 期间出现 `suspiciousLock area=… minMargin=… autoCapture=suppressed`；
后退后正常 `detectionTier path=still tier=1` + 成片入库。

**失败时看**：仍自动拍 → 记录 `suspiciousLock` 是否出现及 `area/minMargin` 数值（阈值
`0.95 / 0.015` 可能需按真机视场调整）；提示文案未切换 → UI 绑定问题（模拟器已测，真机少见）。

## 汇总

| 场景 | 通过标准 | 结果 |
|---|---|---|
| SC-001 近拍 ×10 | ≥9 完整 | ☐ |
| SC-002 常规 ×10 | ≥8 一次锁对 | ☐ |
| SC-003 模拟器差异 | 已知，不判失败 | ☐ |
| SC-004 可疑不自动拍 | 不自动拍 + 提示 + 后退恢复 | ☐ |

全部通过后：在 `tasks.md` T041/T042 验证任务中引用本文件的执行结果。
