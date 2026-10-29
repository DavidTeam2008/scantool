# 验证与真机验收

## 命令

| 命令 | 用途 |
|---|---|
| `make test` | 全量；已知债未清时**仍非 0**（严格信号） |
| `make test-ci` | 团队 CI：只拦新增失败 / 总数下降，已知债不染红 |
| `make test-gate` | 只校验最近一次全量结果（不重跑） |
| `make test-only T=<类名>` | 局部测试 |
| `make check-docs` | 文档相对链接 / 代码围栏 / docs 索引 |
| `make doctor` | Xcode / 模拟器 / Busy 自检 |
| `make device-build` | 真机目标编译（免签名） |

## 计数口径

- 总数 **547**；10 条既有债（Golden 4 / WordFidelity 1 / Review 4 / ReviewSplit 1）
  会 flaky 命中 5~10 条，`passed` 随命中数浮动，不是新回归。
- 已知 issue 用例在日志里是 `recorded an expected failure`，不是 `passed`；
  以 xcresult 计数为准。
- 白名单 `ci/known-failures.txt` 只准缩；加行须在 PR / `tasks.md` 说明。

## 真机验收

- 模拟器相机画面不可信：取景框、成片、条码一律真机验证。
- 取景/还原改动按当前周期 `device-acceptance.md` 的清单执行，证据放
  `build/capture-acceptance/<date>/`；录屏原文件不入库。
- 失败先留现场：设备日志搜 `ZhixiaLog` 的 `cropQuad` / `frameClipped` / `envelope` /
  `refineStage` / `reviewSplit`。
- 不能实际操作设备时，写“未验证”+ 手动步骤，不声称已验证。

## 环境坑

1. `DEVELOPER_DIR` 必须指向本机 Xcode；与默认值不同时用 `make ... DEVELOPER_DIR=...`。
2. 必须加 `OTHER_SWIFT_FLAGS="-disable-sandbox"`（macOS 26.x 宏沙箱失效）；Makefile 已内置。
3. 模拟器报 `Busy` 不是代码问题；`xcrun simctl erase all` 会清空所有模拟器数据，手工执行。
4. 默认 `iPhone 18 Pro` / iOS 27.0；没有该 runtime 时用 `DEST_SIM` 覆盖，不要改默认值。
5. MCP server 用法见 `docs/13-mcp-quickref.md`。
