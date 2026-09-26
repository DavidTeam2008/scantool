# 实施笔记：wps-parity-layout

周期实施过程中的取证结论与偏离记录（按任务追加）。

## T008 结构化通路 fixture 诊断（2026-09-22）

**结论：模拟器不复现回退，无需代码修复；真机取证留 Phase 5 真机验收（T023 清单）。**

### 取证方法（偏离记录：日志管道 → 行为探针）

原计划用统一日志检索 `reconstructPath` 判定通路，实测**模拟器上捕获不到自有子系统的 debug 级 os_log**：

- `log stream --debug`：能捕获苹果框架的 Db 级条目，`com.david.Zhixia` 子系统一条不出现；
- `log config --mode "level:debug" --subsystem com.david.Zhixia` 后 `log show` 仍为空。

改用**行为探针**：临时诊断 XCTest 直接调真实 `VisionDocumentStructureRecognizer.recognize()` + 生产接线 `OnDeviceDocumentParser.parse()`，dump 结构化产物与两条通路的块结构。决策线与行为的 1:1 映射已由 T007 `pathDecisionIsAssertableViaFakes` 钉死，行为证据等价于日志证据。

### 关键证据（iOS 26.4.1 模拟器，iPhone 17 Pro）

1. **结构化通路生效不回退**：真实识别器返回非 nil `StructuredDocumentPage`（109 lines / 0 tables / 0 barcodes，source=documentRequest），生产解析在 13:00:14 发出
   `reconstructPath page=… path=structured reason=structuredSuccess`。
   → 2026-09-21 真机丢 "wrong bus!" 的成因**不在通路回退**。
2. **"wrong bus!" 并未丢失**：几何 OCR 原始行 `wrong bus！`（**全角 ！**，y=0.137 x=0.533，conf=1.00）落在故事块 G#6 的 25 行内；默认通路 compact 文本含 `wrongbus!`（ASCII 形态）。
   此前「丢失」判定是**检索形态假阴性**（拿 ASCII `!` 检索全角 `！` 输出）。
   → **T015 断言必须做全角/半角感叹号归一**；另见 `butIwas wrong！`（y=0.446）同类。
3. **漫画条已检出**：默认通路块 #4 `figure (x:0.417 y:0.312 w:0.083 h:0.146)` = 140×321 px，与 WPS restored 档 srcRect 取证（1.40×3.21）数值精确对应 → T016 以验证为主。几何通路**未检出**该 figure（8 块无 figure #4 对应物，只有大 figure G#5）。
4. **嫌疑大 figure**：块 #7 / G#5 `figure (x:0.517 y:0.076 w:0.417 h:0.796)` **两条通路都存在**，大面积覆盖右栏故事文本区（故事块 #8/G#6 与之重叠共存，文本行未丢）。→ T016 需判定其是否为误检/是否影响流式档内联观感。
5. **段落过合并**（T018 目标）：默认通路 10 块（8 文本块 + 2 figure）vs 金标准 42 段量级；几何通路 8 块。大块 #3（41 行）/#8（25 行）整块合并，需 `clusterParagraphs` 收紧。

### 流入后续任务的结论

| 任务 | 流入结论 |
|---|---|
| T015 | "wrong bus!" 归一化断言（全角 ！/ASCII !、折叠空白）；故事其余文本完整性断言 |
| T016 | 漫画条 = 默认通路 #4；大 figure #7 两通路共有需判定；几何通路不检出漫画条（回退档无内联图，符合「宁缺毋假」预期） |
| T018 | 默认 10 块 → 42 段 ±30%；收紧而非放松 |
| T023 | debug 级 os_log 在模拟器不可捕获；真机验收必须用 Console.app「Include Debug Messages」实时抓取 `reconstructPath`/`textSentinel` |

### 清理

- 临时诊断文件 `ZhixiaTests/T008DiagnosticDumpTests.swift`（含 T008DiagnosticTests.swift）已于收尾删除，不进基线计数；证据留档 `/tmp/wps-parity-layout-logs/`（t008-dump.log 等）。
