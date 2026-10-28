# 13 MCP 使用速查

> 面向 **AI agent / 新同事**：本机 opencode 已装 6 个 MCP server，本文是它们在**本项目的
> 唯一权威用法来源**（分工 / 配置落点 / 场景对照 / 铁律叠加）。冷启动请先回到
> [`AGENTS.md`](../AGENTS.md)；环境细节下钻 [`00 接手指南`](00-getting-started.md)。
>
> 更新：2026-10-20 · 工具数按当日快照（会随版本浮动，以 `opencode mcp list` 为准）。

---

## 1. 总览：六个 server 的分工

| Server | 工具数 | 角色 | 什么时候用 |
|---|---|---|---|
| `mobilebuildmcp` | 33 | **构建/测试/截图主链路**（模拟器+真机） | 日常主力：build / install / run / 单测 / 截图 / 日志 |
| `xcode` | 54 | **Xcode IDE 控制**（苹果官方 `xcrun mcpbridge`） | 动 IDE：scheme / run destination / 断点调试 / 运行时验证 |
| `agent-device` | 59 | **交互式 UI 驱动**（语义元素操作） | 点/填/滑/读元素的手动 QA 自动化（iOS/安卓/macOS/web） |
| `maestro` | 10 | **声明式 E2E YAML 流** | 验证固化为可复跑 flow；Maestro Cloud 云真机 |
| `testflight` | 51 | **TestFlight 反馈深挖**（只读为主） | 测试员截图反馈+评论、崩溃日志、build 分布状态 |
| `app-store-connect` | 25 | **ASC 全量管理**（包已归档停更） | 增删 beta 测试员/群组、版本文案、设备/成员、销量 |

能力重叠时**在指令里点名 server**（例：「用 mobilebuildmcp 截图」），避免随机选择。

## 2. 配置落点（单真源位置）

| 位置 | 内容 |
|---|---|
| `~/.config/opencode/opencode.json` | 全局：六个 server 的 command / env。`opencode` 与 `opencode2` 同一 binary，共用此配置 |
| `.mobilebuildmcp/config.yaml`（本仓库根，已入库） | mobilebuildmcp：`enabledWorkflows: ["simulator","device","project-discovery"]`（默认只有 simulator）+ sessionDefaults |
| `~/.appstoreconnect/` | ASC 凭证目录：放 `AuthKey_XXXXXXXXXX.p8` |

**待补凭证**：`testflight` 与 `app-store-connect` 目前是占位 env（`FILL_ME_*`），拿到
ASC API Key（App Store Connect → Users and Access → Integrations → App Store Connect
API → Team Keys → Generate，角色 **App Manager**，`.p8` 只能下载一次）后，把
Key ID / Issuer ID / `.p8` 路径填进全局配置的以下变量即可：

- `testflight`：`ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_PRIVATE_KEY_PATH`
- `app-store-connect`：`APP_STORE_CONNECT_KEY_ID` / `APP_STORE_CONNECT_ISSUER_ID` / `APP_STORE_CONNECT_P8_PATH`（销量财报工具加 `APP_STORE_CONNECT_VENDOR_NUMBER`）

## 3. 各 server 速查

### 3.1 mobilebuildmcp（主链路）

- **会话默认已预置**（`.mobilebuildmcp/config.yaml`）：project `./Zhixia.xcodeproj`、
  scheme `Zhixia`、模拟器 `iPhone 18 Pro` / iOS 27.0。
- **规矩**：每个会话首次 build/run 前先调 `session_show_defaults` 确认三件套，然后
  **空参数**直接调 `build_run_sim`（模拟器）或 `build_run_device`（真机）——一步
  构建+装+启动+自动捕获日志。`discover_projs` 仅在 defaults 缺失/不符时才用。
- **测试基线口径**：真跑单测走 `make test`（518 total / 507 passed / 1 expected /
  10 known failures，xcresulttool 计数）。mobilebuildmcp 的 test 工具调的是 xcodebuild test，
  不带本项目的 known-issue 计数口径，可跑但别当基线依据。
- **真机门槛**：`build_run_device` 需开发者签名+设备信任证书；免签名只能到 `build_device`
  （等价 `make device-build` 的 `generic/platform=iOS`）。
- **改 `enabledWorkflows` / sessionDefaults 后**：MCP 侧需 `opencode service restart`
  才重读；CLI 每次冷启动现读，不受影响。
- 常用 CLI（CLI 不受 workflow 门禁，全量可用）：

```sh
npx -y mobilebuildmcp@latest simulator build-and-run      # 一步裸跑模拟器
npx -y mobilebuildmcp@latest simulator screenshot         # 截图（过对比可配 snapshot_ui）
npx -y mobilebuildmcp@latest simulator-management erase    # 模拟器 Busy 假死的解法
npx -y mobilebuildmcp@latest device list                  # 真机在线列表
npx -y mobilebuildmcp@latest device build                 # 免签名编译真机
npx -y mobilebuildmcp@latest tools                        # 全目录；<工作流> --help 看单组
```

### 3.2 xcode（IDE 控制）

- 每*会话*先 `XcodeOpenWorkspace`（传 `.xcodeproj` 的绝对路径）拿 **workspaceIdentifier**，
  后续工具都吃这个 id（会跨会话变化，别硬编码）。首次对新 agent / 新项目会触发一次
  Xcode 侧授权弹窗，本项目 agent 已批准过。
- **外部 agent 权限管理面**：`xcrun mcp-server status` 列 Permitted agents / folders 与
  开放工作区；待批请求用 `xcrun mcp-server approve <id>`（需 sudo），重置用 `reset-all`，
  活动日志 `show-logs`。opencode 于 2026-10-20 已注册并实证
  （`signed 5NZ4Q7NXJ4 opencode` + 项目目录授权；`BuildProject` 全绿）。
- 常用：`XcodeListSchemes` / `XcodeSwitchScheme` / `XcodeListTargets` / build / run /
  `StopProject`；运行时验证走 `DeviceInteractionStart{,Workspace}Session`（要装跑再用，
  用完 `DeviceInteractionEndSession` 释放）。
- 环境已钉 `DEVELOPER_DIR=/Volumes/DevDisk/Applications/Xcode.app/Contents/Developer`，
  与 `xcode-select` 状态解耦。

### 3.3 agent-device（UI 元素交互）

官方 workflow 摘要（server 自带 instructions，agent 须遵守）：

1. 已知 app：直接 `open {app, foreground: true}`，一次到位；未知 app：`devices` → `apps`
   → open，**别瞎编 id**。已有会话从现有状态续，不要重开。
2. 交互循环：`press / click / fill / longpress / scroll / back` 带 `settle: true`，响应即
   已结算的 UI diff，从 diff 里拿下一个目标；需要跳屏用
   `scroll {direction, until: "<selector>"}` 一步到位。
3. 目标引用：**逐字复制 refs**（`@e12` / `@e12~s4`）；mutation 后 refs 过期就得重 snapshot。
   出现 sparse/AX-unavailable 警告时 refs 全部失效：screenshot → 读图 → `press {x,y}` 坐标兜底。
4. 验证用 `wait / is / get / find`，裸 screenshot 不算验证；结束时 `close`。
5. 特殊姿势（手势/脚本/TV/macOS/web/远程）查 `help`，启动阶段不要乱调。

### 3.4 maestro（E2E YAML 流）

- 本地流：`list_devices` 拿 `device_id` → `inspect_screen`（看层级）→
  `run {yaml|files|dir, device_id}`（语法随调随校验）。先 `cheat_sheet` 再写不熟的命令。
- **零凭证可用本地**；云真机要 `maestro login` 或 `MAESTRO_CLOUD_API_KEY`。
- **Viewer 已关闭**（配置带 `--no-viewer`）：每个 `maestro mcp` 进程默认抢
  `127.0.0.1:10000`，多实例必崩一支（曾致 `opencode mcp list` 误报 failed）。想看
  Viewer embedded 界面就终端手动起 `maestro mcp`（不带参数），用完关，别和 MCP 并存。
- `JAVA_HOME` 已钉 `/Users/tanwei/Documents/tools/jdk-24.jdk/Contents/Home`
  （JDK 未注册进 `/usr/libexec/java_home`，不钉则服务拉起时找不到 java）。
- 关遥测（可选）：往 maestro env 加 `MAESTRO_CLI_NO_ANALYTICS=1`。

### 3.5 testflight（只读深挖，等凭证）

拉 beta 截图反馈（**含测试员评论与设备信息**）、崩溃反馈与日志、build 的 TestFlight
分布状态、tester/群组上下文。只走官方 ASC API（JWT 20 分钟短签），不越权不爬 internal 接口。

### 3.6 app-store-connect（全量管理，等凭证）

测试员/群组增删、App Store 版本与本地化文案（greeting `whats_new`/keywords/description）、
Bundle ID 与 capabilities、注册设备、团队成员、analytics（销量/财报另配 vendor number）。
⚠️ 上游仓库 2026-02-26 已归档（v1.1.3 终版）；活跃替代品是
`@orellbuehler/testflight-mcp`（本机已装为 `testflight`），覆盖不满时再找新替代。

## 4. 场景 → server 对照

| 场景 | 用谁 | 典型对话指令 |
|---|---|---|
| 装 Zhixia 跑模拟器并截图 | mobilebuildmcp | 「装到 iPhone 18 Pro 跑起来截图」 |
| 跑单测 | `make test`（基线）/ mobilebuildmcp（辅助） | 「跑测试并给 xcresulttool 计数」 |
| 免签名编译真机 | mobilebuildmcp `build_device` | 「跑一遍真机编译看有没有错」 |
| 真机装跑 | mobilebuildmcp `build_run_device` | 「装到菀墨跑起来，前后日志都要」 |
| 切 scheme / 打断点 / 调试 | xcode | 「切到 scheme Zhixia 在 X.swift:120 下断点跑」 |
| 点按钮填表单读控件 | agent-device | 「用 agent-device 打开 Zhixia，点开始扫描」 |
| 固化可复跑的 E2E 流 | maestro | 「把这条验证写成 flow 存 e2e/ 并跑」 |
| 测试员反馈/崩溃 | testflight | 「拉最近一版 TestFlight 截图反馈+评论」 |
| 运营性增删改 | app-store-connect | 「把 xxx@xx.com 加进 beta 群」 |

## 5. 项目铁律叠加（相对 §4 的强约束）

1. **模拟器条码恒 0 是假绿**（AGENTS.md 铁律 4）：条码相关验证必须真机在线（`device list`
   里取当前在线机）；agent 不得用模拟器结果宣称条码功能通过。
2. **基线 518 只增不减**：改用其他 runner 口径前先对齐 known-issue 计数（§3.1）。
3. **截图对比类验收**（Case A/B、框真相）：优先真机 + mobilebuildmcp 截图，按
   `spec/frame-truth/device-acceptance.md` 逐字记录。
4. 任何 server 报「待授权 / 找不到 workspace / defaults 为空」时，先走对应初始化步骤
   （§3 开头的规矩），不要硬猜参数。

## 6. 维护命令

```sh
opencode mcp list          # 状态：connected / pending / failed（连 failed 先查本文 §3 各坑）
opencode mcp add <name> --global [--env k=v] -- <command...>   # 增补 server（改配置后重启服务生效）
npx -y mobilebuildmcp@latest upgrade   # mobilebuildmcp 自升级
npx -y mobilebuildmcp@latest purge     # 清 mobilebuildmcp 工作区存储
maestro --version          # maestro CLI（brew 管理：brew upgrade mobile-dev-inc/tap/maestro）
```
