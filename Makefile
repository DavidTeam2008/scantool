# 纸匣 Zhixia · 命令封装（agent-handover 周期）
#
# 目标受众：AI coding agent 与新工程师。把本项目的环境坑一次性固化：
#   ① DEVELOPER_DIR 必须指向本机 Xcode（默认值可覆盖：make test DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer）
#   ② Swift 宏沙箱在 macOS 26.x 上失效，必须加 OTHER_SWIFT_FLAGS="-disable-sandbox"（否则所有宏报错）
#   ③ 模拟器 Busy 不是代码问题，解决命令是 xcrun simctl erase all（本 Makefile 只提示、绝不自动执行）
#
# 用法：make help

# —— 环境（可覆盖）——
DEVELOPER_DIR ?= /Volumes/DevDisk/Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

# —— 固定参数 ——
PROJECT     := Zhixia.xcodeproj
SCHEME      := Zhixia
BUNDLE_ID   := com.david.Zhixia
SIM_NAME    ?= iPhone 18 Pro
SIM_OS      ?= 27.0
DEST_SIM    := platform=iOS Simulator,name=$(SIM_NAME),OS=$(SIM_OS)
DEST_DEVICE := generic/platform=iOS
BUILD_DIR   := build
RESULT_PATH := $(BUILD_DIR)/Zhixia.xcresult
TEST_LOG    := $(BUILD_DIR)/last-test.log
APP_PATH    := $(BUILD_DIR)/dd/Build/Products/Debug-iphonesimulator/Zhixia.app
XCODEBUILD  := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -skipPackagePluginValidation -skipMacroValidation
# 测试基线（**只增不减**）：新增测试后同步本值；计数低于本值 = 测试被删 → make 失败。
BASELINE_TOTAL ?= 492
BASELINE_PASSED ?= 481
BASELINE_EXPECTED_FAILURES ?= 1

.PHONY: help test test-only smoke word-fidelity editable-fidelity device-build doctor

help: ## 显示本帮助
	@echo "纸匣 Zhixia · 可用命令（DEVELOPER_DIR=$(DEVELOPER_DIR)）"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*##"} {printf "  make %-16s %s\n", $$1, $$2}'
	@echo ""
	@echo "  计数口径提醒：known issue 用例在 xcodebuild 日志里是 recorded an expected failure，"
	@echo "  按关键字 passed 搜会少 1 条——以 xcresulttool 计数（本 Makefile 自动输出）为准。"

test: ## 全量单测（默认 iPhone 18 Pro / iOS 27 + 自动 xcresulttool 计数）
	@mkdir -p $(BUILD_DIR)
	@rm -rf $(RESULT_PATH)
	@echo "▶ 全量测试开始（完整日志: $(TEST_LOG)）——首次跑约 3~6 分钟"
	@if ! $(XCODEBUILD) test -destination '$(DEST_SIM)' \
	    -resultBundlePath $(RESULT_PATH) \
	    OTHER_SWIFT_FLAGS="-disable-sandbox" > $(TEST_LOG) 2>&1; then \
	  echo "✗ 测试失败（退出码 $$?），日志尾部："; tail -40 $(TEST_LOG); \
	  echo "完整日志: $(TEST_LOG)"; exit 1; \
	fi
	@echo "✓ 测试命令执行完成"
	@$(MAKE) --no-print-directory count-full

# 内部目标：从 xcresult 提取计数并按基线口径解读
count:
	@echo "=== 测试计数（xcrun xcresulttool，权威口径）==="
	@xcrun xcresulttool get test-results summary --path $(RESULT_PATH) | \
	  python3 -c "import sys,json; d=json.load(sys.stdin); \
	    total=d.get('totalTestCount'); p=d.get('passedTests'); f=d.get('failedTests'); \
	    e=d.get('expectedFailures'); s=d.get('skippedTests'); \
	    print('total=%s  passed=%s  failed=%s  expectedFailures=%s  skipped=%s' % (total,p,f,e,s)); \
	    print('基线解读：$(BASELINE_TOTAL) total；本次 $(BASELINE_PASSED) passed + $(BASELINE_EXPECTED_FAILURES) expected failure + 10 known full-suite failures（Golden 4 / WordFidelity 1 / Review 4 / ReviewSplit 1；Reconstruct 本轮未失败；见 TODO）')"

# 全量守卫：总数低于基线 = 既有测试被删 → 失败（局部测试用 count，不套此守卫）
count-full: count
	@total=$$(xcrun xcresulttool get test-results summary --path $(RESULT_PATH) | \
	  python3 -c "import sys,json; print(json.load(sys.stdin).get('totalTestCount') or 0)"); \
	 if [ "$${total}" -lt "$(BASELINE_TOTAL)" ]; then \
	   echo "✗ 测试数低于基线 $(BASELINE_TOTAL)（实际 $${total}）——既有测试被删了？"; exit 1; \
	 fi

test-only: ## 局部单测：make test-only T=<测试类名>（例: T=GoldenWorksheetEndToEndTests）
	@test -n "$(T)" || { echo "用法: make test-only T=<测试类名>  例: make test-only T=GoldenWorksheetEndToEndTests"; exit 2; }
	@mkdir -p $(BUILD_DIR)
	@rm -rf $(RESULT_PATH)
	@echo "▶ 局部测试 ZhixiaTests/$(T)（日志: $(TEST_LOG)）"
	@if ! $(XCODEBUILD) test -destination '$(DEST_SIM)' \
	    -only-testing:ZhixiaTests/$(T) \
	    -resultBundlePath $(RESULT_PATH) \
	    OTHER_SWIFT_FLAGS="-disable-sandbox" > $(TEST_LOG) 2>&1; then \
	  echo "✗ 测试失败，日志尾部："; tail -40 $(TEST_LOG); \
	  echo "完整日志: $(TEST_LOG)"; exit 1; \
	fi
	@$(MAKE) --no-print-directory count

smoke: ## 装机冒烟：模拟器 build + boot + install + launch + 进程存活检查
	@mkdir -p $(BUILD_DIR)
	@echo "▶ 构建（模拟器目标）"
	@$(XCODEBUILD) build -destination '$(DEST_SIM)' -derivedDataPath $(BUILD_DIR)/dd \
	  OTHER_SWIFT_FLAGS="-disable-sandbox" > $(BUILD_DIR)/last-build.log 2>&1 \
	  || { echo "✗ 构建失败"; tail -30 $(BUILD_DIR)/last-build.log; exit 1; }
	@echo "✓ 构建完成"
	@echo "▶ 启动模拟器（已开机则跳过）"
	@xcrun simctl boot "$(SIM_NAME)" 2>/dev/null || echo "  （模拟器已开机或稍后自动开机）"
	@UDID=$$(xcrun simctl list devices | grep -m1 Booted | grep -oE '[0-9A-F-]{36}'); \
	 if [ -z "$$UDID" ]; then echo "✗ 找不到 Booted 模拟器（重试或见 make doctor）"; exit 1; fi; \
	 echo "▶ 安装到 $$UDID"; \
	 xcrun simctl install $$UDID $(APP_PATH) || { echo "✗ 安装失败"; exit 1; }; \
	 echo "▶ 启动 $(BUNDLE_ID)"; \
	 OUT=$$(xcrun simctl launch $$UDID $(BUNDLE_ID)) || { echo "✗ 启动失败"; exit 1; }; \
	 PID=$$(echo $$OUT | grep -oE '[0-9]+$$'); \
	 sleep 3; \
	 if ps -p "$${PID}" > /dev/null 2>&1; then \
	   echo "✓ 冒烟通过：App 已启动且进程存活（pid=$${PID}）"; \
	 else \
	   echo "✗ 进程 $${PID} 3 秒内退出（疑似启动崩溃）——用 Console/崩溃日志排查"; exit 1; \
	 fi

word-fidelity: ## Word 导出保真度（spec/word-fidelity）：导出 → 渲染 → SSIM 门限
	@echo "▶ 导出 Word 夹具产物（页面图 + 两种 docx）"
	@$(MAKE) --no-print-directory test-only T=WordFidelityExportTests
	@echo "▶ 渲染并比对（qlmanage + ffmpeg SSIM，门限 0.90）"
	@./Tools/word-fidelity/check.sh

editable-fidelity: ## 可编辑档（版面还原）真机同图夹具：导出 → 渲染 → 双口径 SSIM 门限
	@echo "▶ 导出 Word 夹具产物（页面图 + 两种 docx）"
	@$(MAKE) --no-print-directory test-only T=WordFidelityExportTests
	@echo "▶ 渲染可编辑档并比对（qlmanage + ffmpeg SSIM，页面图/原片双口径 ≥0.90）"
	@WORD_FIDELITY_GATE_TIER=restored ./Tools/word-fidelity/check.sh

device-build: ## 真机目标编译（generic/platform=iOS，免签名）
	@mkdir -p $(BUILD_DIR)
	@echo "▶ 真机目标编译（CODE_SIGNING_ALLOWED=NO）"
	@$(XCODEBUILD) build -destination '$(DEST_DEVICE)' CODE_SIGNING_ALLOWED=NO \
	  OTHER_SWIFT_FLAGS="-disable-sandbox" > $(BUILD_DIR)/last-device-build.log 2>&1 \
	  && echo "✓ BUILD SUCCEEDED（真机目标）" \
	  || { echo "✗ 真机目标编译失败"; tail -30 $(BUILD_DIR)/last-device-build.log; exit 1; }

doctor: ## 环境自检：Xcode / DEVELOPER_DIR / 模拟器 / Busy 提示
	@echo "=== 环境自检 ==="
	@echo "1) Xcode 版本（经 DEVELOPER_DIR=$(DEVELOPER_DIR)）"
	@xcodebuild -version || { echo "✗ xcodebuild 不可用——DEVELOPER_DIR 是否指向有效 Xcode？"; exit 1; }
	@echo ""
	@echo "2) 模拟器「$(SIM_NAME)」"
	@xcrun simctl list devices available | grep -q "$(SIM_NAME)" \
	  && echo "✓ 存在" \
	  || { echo "✗ 不存在——用 Xcode → Settings → Components 安装对应 runtime"; exit 1; }
	@echo ""
	@echo "3) 已开机（Booted）的模拟器"
	@BOOTED=$$(xcrun simctl list devices | grep Booted | grep -c . || true); \
	 if [ "$$BOOTED" = "0" ]; then echo "  （无，首次跑测试/冒烟时自动开机）"; \
	 elif [ "$$BOOTED" = "1" ]; then echo "  1 台已开机（正常）"; \
	 else echo "  ⚠️ $$BOOTED 台同时开机——若测试报 Busy/设备冲突，手动执行:"; \
	      echo "     xcrun simctl erase all   （⚠️ 会擦除所有模拟器数据，本 Makefile 不自动执行）"; fi
	@echo ""
	@echo "4) 计数工具链"
	@command -v python3 > /dev/null && echo "✓ python3 可用（xcresulttool 计数解析）" || echo "⚠️ python3 不可用——make test 的计数步骤会失败（测试本身不受影响）"
	@echo ""
	@echo "自检完成。若 xcodebuild test 报 'Busy'：xcrun simctl erase all 后重跑（破坏性，自行确认）。"
