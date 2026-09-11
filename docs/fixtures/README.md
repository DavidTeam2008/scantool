# 样张 OCR 夹具（docs/fixtures）

R2 的版面 / 表格 / 配图单测不允许再用「拍脑袋合成的 `CGRect`」——旧 `ReconstructTests`
全绿但两张真机样张照崩。这里放的是**真实样张跑出来的 Vision OCR 结果**，固化为测试夹具。

## 目录

```
docs/fixtures/
  images/
    nutrition-mango.jpg      营养表原图（小象超市芒果干）869×1024
    workbook-test4.jpg       练习册原图（Test 4 Questions 1~5）844×1076
  nutrition-mango.ocr.json   营养表 OCR 导出（34 行）
  workbook-test4.ocr.json    练习册 OCR 导出（48 行）
```

> 只归档了**原图**。用户给的 `IMG_7477/7479/7480/7481/7482/7483.PNG` 全是 App 截图
> （1170×2532，含「还原版面 / 导出 Word」等 UI 文字），不适合当 OCR 输入，故未采用。

## 三步：重新导出夹具

```bash
cd scantool

# 1. 用工程图片重跑 OCR，导出 json
swift Tools/ocr-dump/main.swift docs/fixtures/images/*.jpg --out docs/fixtures

# 2. 生成 Swift 夹具
python3 Tools/ocr-dump/gen_fixtures.py

# 3. 跑测试（本机需 -disable-sandbox，见 docs/00 §7）
xcodebuild -project Zhixia.xcodeproj -scheme Zhixia \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:ZhixiaTests/ReconstructV2Tests \
  CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS="-disable-sandbox" test
```

> `verify_tests.py` 是在**无法构建**时的临时替代品（免 Xcode、免宏）。
> Xcode 加 `-disable-sandbox` 能正常构建后，请以真实 `xcodebuild` 结果为准。

新增样张：把原图放进 `docs/fixtures/images/`，在 `gen_fixtures.py` 的 `SAMPLES` 里加一行，
再走一遍上面 1~2 步。

## 关于保真度

`Tools/ocr-dump/main.swift` **逐项复刻**了 `Zhixia/Services/OCR/VisionTextRecognizer.swift`：

| 项 | 值 |
| --- | --- |
| `recognitionLevel` | `.accurate` |
| `minimumTextHeight` | `0.012` |
| `recognitionLanguages` | `zh-Hans, zh-Hant, en-US`（同一套 `preferredLanguages()` 过滤） |
| `usesLanguageCorrection` | 先 `false` 后 `true`，与 App 同序 |
| 择优 | 同一套 `OCRTextQuality.score`，`cjkCount >= 12` 提前返回 |
| 排序 | `minY` 降序；同带（±0.02）内 `minX` 升序 |
| 坐标系 | Vision 原生归一化，原点左下 |

⚠️ 工具跑在 **macOS 的 Vision** 上（revision 3），iOS 上的 Vision 版本可能有细微差异。
夹具用于「锁定当前失败行为」和「结构回归」，**真实验收仍以真机样张为准**（与 README 的既有约定一致）。

## 当前实测（2026-09-07）

用工程里真实的 `OnDevice*` 算法跑这两份夹具的结果：

| 样张 | 场景路由 | `TableCluster.detect` | `FigureRegions.boxes` | 说明 |
| --- | --- | --- | --- | --- |
| 营养表 | `.table` ✓ | **`nil`** ✗ | **0 个** ✗ | 包装说明短行混进 `isCell`，列中心被带偏到 `[0.185, 0.378, 0.662]`（真值 ~`[0.175, 0.505, 0.815]`） |
| 练习册 | **`.table`** ✗（应 `.exam`） | **7×2 假表** ✗ | **0 个** ✗ | `looksLikeGrid` 抢先命中 → 误判 `table` → A/B/C 被聚成假表 |

对应的失败断言都写在 `ZhixiaTests/ReconstructV2Tests.swift`，用 `withKnownIssue` 包住：
套件保持绿色，一旦被修好该测试会**反向失败**，提醒移除包装。
