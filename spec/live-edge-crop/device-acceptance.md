# 真机自验清单 · 取景实线边框与折页书可靠裁切（live-edge-crop）

> 模拟器全量单测已绿（294 passed + 1 known issue + 0 failed）。本清单覆盖单测**无法**证明的
> 部分：真机相机对折页厚书曲面的实际检出率、实线整框的肉眼可辨性、成片裁切手感。
> 逐项打勾，全过才算本特性收尾。实现说明见 `plan.md` D1~D6，日志语义见
> `docs/09-project-handbook.md` §4.2。
>
> 设备：iPhone 13（iOS 26 通路无关本轮；系统版本记录在验收结果里）。

## 0. 日志抓取指引

所有验收点依赖 `ZhixiaLog.capture` 结构化日志（os_log）：

```bash
# 方式一：Console.app
#   左侧选中 iPhone 设备 → 搜索框输入 subsystem:com.david.Zhixia category:capture
#   → 勾选「Include Debug Messages」（relaxedLiveProbe 是 debug 级）

# 方式二：CLI（手机连 Mac）
log stream --predicate 'subsystem == "com.david.Zhixia" AND category == "capture"' --style compact --level debug
```

本轮相关日志的含义：

| 日志前缀 | 含义 | 验收看什么 |
|---|---|---|
| `relaxedLiveProbe triggered=… candidates=…` | live 文档模式每帧一行：第三级放宽矩形是否触发（严格矩形 + 文档分割双落空）与命中候选数 | **触发率 = `triggered=true` 行数 ÷ 本日志总行数**；折页场景应显著 > 0 且 `candidates ≥ 1`；平整文档场景应 ≈ 0（SC-002 零回退） |
| `detectionTier path=live tier=… candidates=… selectedArea=…` | 候选择优层级（与放宽档语义正交：tier 是面积兜底档位） | 放宽档命中帧 `candidates` 应比严格-only 帧多；`selectedArea` 与书页实际占比量级一致 |
| `detectionTier path=still tier=…` | 快门重检结果 | SC-003 分支 ① 的证据（成片用重检框） |
| `suspiciousLock area=… minMargin=… autoCapture=suppressed` | 可疑锁定门禁抑制自动快门 | 放宽档命中的近满幅框同样受门禁管控（SC-002/SC-004 交叉验证） |

检索 `relaxedLiveProbe` 的具体步骤（SC-005 证据链）：

1. 手机连 Mac，Console.app 选中设备，过滤 `subsystem:com.david.Zhixia category:capture`，
   勾选 Include Debug Messages，点「开始」流式抓取；
2. 对折页厚书取景 10 秒左右，停止抓取；
3. 搜索框输入 `relaxedLiveProbe`——记录总行数（= live 文档模式检测帧数）与
   `triggered=true` 行数、其 `candidates` 分布；
4. 保留这份导出（`File → Save`），作为触发率与命中质量的验收证据。

## SC-001 折页厚书实时出框（三级兜底核心价值）

**步骤**：找一本厚书，把中间若干页向后折起（形成曲面/翘边，页面不再平整），平放桌面，
手机正常扫描距离取景，**故意不完全对准**（书页斜放、部分折起），观察取景器 **10 秒**。
换 2~3 种折页形态重复。

**通过标准**：每种形态下 **数秒内**（≤ 5s）出现**连续实线边框**（朱砂细实线，跟随态），
边框大致贴合书页可读区域边缘（曲边允许 1~3% 偏差，不要求逐像素贴合）；提示保持
「寻找/跟随」语义，**不误报「已对准」**（未达锁定条件时不震动、不自动拍）。

**日志佐证**：取景期间出现 `relaxedLiveProbe triggered=true candidates=1..N`
（三级兜底触发且放宽档命中）；`detectionTier path=live candidates≥1`。

**失败时看**：始终无框 → 检查 `relaxedLiveProbe triggered=` 是否全为 false（若全 false 且
`detectionTier candidates>0` 说明一级/二级已有候选，属平整场景而非折页失效；若 triggered=true
但 candidates=0，放宽档也未命中——极端曲面，走 SC-004 兜底，记录现场照片）；有框但位置
离谱 → 看 `detectionTier selectedArea` 是否被整幅误检带偏（两级面积兜底应已抑制）。

## SC-002 平整文档零回退（既有行为不回归）

**步骤**：A4 平整文档放桌上，正常距离拍摄，连续 **10 次**；另拍一次**近拍书占满画面**
（四边贴近屏幕边缘）。

**通过标准**：**≥ 8 次**满足「实线框稳定贴合纸边 → 约 0.55s 锁定（框变粗白双线 + 压暗加深
+ 震动）→ 自动快门 → 成片完整」一次锁对；四态提示（寻找/跟随/已对准/再后退一点）与上一版
一致；近拍书不被裁边。

**日志佐证**：平整场景 `relaxedLiveProbe triggered=false` 占绝对多数（一级严格矩形照旧命中，
零回退）；锁定与自动快门行为同上一版；近拍出现 `detectionTier tier=2`（与上版一致）。

**失败时看**：平整文档也频繁 triggered=true → 放宽档门控过松（核对 `needsRelaxedRectangles`
的判定链：严格候选是否被误判为无可信）；锁定表现变化 → 检查 DocumentFrameStyle 是否影响
锁定态渲染之外的路径（压暗/角括号/门禁应为零改动）。

## SC-003 所见即可裁（成片按书页边缘裁切）

**步骤**：折页书出框后（跟随态即可，无需锁定），**手动按快门**，拍 **5 次**（可含 1~2 次
框略有晃动的）；到预览页看成片。

**通过标准**：**≥ 4 次**成片按书页边缘裁切——折起翘起的部分被切除，成片就是取景时
边框内的图；若快门全分辨率重检成功，允许成片与所见框有 1~3% 细微差异（精度优先，
已被用户接受）。

**日志佐证**：拍摄瞬间 `detectionTier path=still` 有结果 → 成片用重检框（分支 ①）；
`path=still tier=0 candidates=0` → 回退 live 框（分支 ②，`relaxedLiveProbe` 此前应有
triggered=true 命中记录）。

**失败时看**：成片全幅不裁 → 确认取景时 `imageQuad` 是否为空（三级兜底未命中，回退链
落到第三层）；成片裁切与所见框差异明显（> 5%）→ 记录 `detectionTier path=still
selectedArea` 与取景时 live `selectedArea` 对照。

## SC-004 极端无框不阻塞（兜底路径）

**步骤**：找一个三级检测都难命中的场景（极端曲面/强反光/低对比度），确认取景器无框
（提示「寻找」）；手动按快门拍一张；进预览页，点裁切编辑，拖拽四角手动调框后确认。

**通过标准**：手动快门**照拍全幅**（不阻塞、不报错）；预览页可进入裁切编辑器，四角
手柄可拖拽，拖完成片随之更新；用户拖过的框在返回再进入后**不被自动 refine 覆盖**。

**日志佐证**：取景期间 `relaxedLiveProbe triggered=true candidates=0`（放宽档也落空）+
快门 `detectionTier path=still tier=0`（双失败 → 全幅，分支 ③）。

**失败时看**：快门无响应 → 记录当时 phase 状态（应为 UI 层问题，本链路手动快门无门禁）；
预览调框被覆盖 → 复查 `ReviewViewModel.refineQuads` 的 `userAdjustedQuad` 过滤
（模拟器 `autoRefineSkipsUserAdjustedQuad` 已钉死，真机若复现记录步骤）。

## SC-005 三级兜底可观测（日志对照）

**步骤**：按 §0 的抓取指引，分别在 SC-001（折页）与 SC-002（平整）场景导出两份日志。

**通过标准**：两份日志均可检索到 `relaxedLiveProbe` 行；折页份 triggered=true 占比显著，
平整份 ≈ 0；所有 triggered=true 行的 `candidates` 数值可读（无乱码/截断）。

**失败时看**：完全无 `relaxedLiveProbe` 行 → 确认 Console 勾选了 Include Debug Messages
（debug 级日志默认不显示）且 filter 的 category 正确；仍无 → 检查是否文档模式
（idCard 模式不记录本日志，属预期）。

## 汇总

| 场景 | 通过标准 | 结果 |
|---|---|---|
| SC-001 折页出框 ×3 形态 | 每形态 ≤5s 出实线框、跟随态不误报锁定 | ☐ |
| SC-002 平整 ×10 + 近拍 ×1 | ≥8 一次锁对、提示/震动/自动快门同上版、近拍不裁边 | ☐ |
| SC-003 所见即可裁 ×5 | ≥4 成片按书页边缘裁切、翘起部分切除 | ☐ |
| SC-004 极端无框 | 手动快门拍全幅 + 预览四角调框 + 不被 refine 覆盖 | ☐ |
| SC-005 日志对照 | relaxedLiveProbe 可检索、触发率与场景匹配 | ☐ |

全部通过后：在 `tasks.md` 验证任务中引用本文件的执行结果。
