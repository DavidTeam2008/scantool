# 契约与铁律细则

> 触发：改 `Services/`、`Features/Capture/`、`Features/Edit/`、`Domain/`，或动测试基线时读。
> 速查：WYSIWYG 裁切 → `docs/09` §4.2；版面对标 → `docs/09` §4.5。

## 1. 协议签名冻结

`Services/ServiceProtocols.swift` 的全部协议签名不变。依赖经协议注入；签名一动，
所有替身测试连锁崩。新增能力优先加协议扩展/默认实现，不改既有方法。

## 2. 测试基线只增不减

- 全量总数 **547** 只增不减；既有断言零修改。
- 方向性翻转是唯一例外（先例：`ReconstructTierTests` 默认档），须在周期 `tasks.md` 逐条记录。
- 10 条既有债（Golden 4 / WordFidelity 1 / Review 4 / ReviewSplit 1）会 flaky 命中
  5~10 条，不是新回归；不要为“全绿”删测试/放宽断言。
- 团队 CI 用 `make test-ci`：失败集合必须 ⊆ `ci/known-failures.txt`；白名单只准缩。

## 3. 纯离线

不引网络依赖、不加云调用；TextIn 云解析是 stub（`parse` 直接 throw）。
云通路须独立立项评审。

## 4. 模拟器条码恒 0

`VNDetectBarcodesRequest` 在模拟器永远返回空；条码断言只能靠 `BarcodeDetecting`
协议注入替身 + 真机验收。模拟器绿 ≠ 真机绿。

## 5. expected failure 日志陷阱

`withKnownIssue` 在 xcodebuild 日志里是 `recorded an expected failure`，不是 `passed`。
按 `passed` 搜日志会少算；以 `make test` / `make test-gate` 的 xcresult 计数为准。

## 6. 动 capture / reconstruct 先读 spec

每轮修复钉在 `spec/<周期>/spec.md` 的 FR/SC 编号；跳过 spec 直接改代码是历次回归根因。

- 取景：`spec/frame-truth/`、`spec/guided-capture/`、当前 `spec/capture-envelope-tracking/`
- 还原：`spec/wps-parity-layout/`、`spec/word-fidelity/`

## 7. 无框不回退 `.fullImage`

屏幕外框/桌面最大矩形不是页面。无当前帧包络或 tracker hold 时保持搜索态、快门置灰；
左/右页目标缺失时可拍包络回退，由 Review 拆分（CF-T002/T004/T011a）。

## 8. frame-truth

成片 = 快门瞬间呈现框。拍后 refine 不得静默扩回用户没看见的内容；左/右页是输出意图，
不是实时精确单页门槛。CF-T010 后取景域 = 成片域（4:3 取景窗 + `.resizeAspect`）。
