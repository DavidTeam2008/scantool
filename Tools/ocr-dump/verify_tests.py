#!/usr/bin/env python3
"""
在无法使用 swift-testing 宏的环境里（如本机的 Xcode 插件服务异常），
把 ReconstructV2Tests.swift 转成普通可执行程序，校验断言逻辑与夹具数据。

只做临时校验，不产出到仓库。

    python3 Tools/ocr-dump/verify_tests.py
"""
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FW = ("/Volumes/DevDisk/Applications/Xcode.app/Contents/Developer/Platforms/"
      "MacOSX.platform/Developer/Library/Frameworks")
TMP = "/tmp/verify"


def transform(src: str) -> tuple[str, list[tuple[str, str]]]:
    """返回 (改写后的源码, [(结构体名, 方法名)])。测试函数是 struct 的实例方法。"""
    src = src.replace("import Testing\n", "")
    src = re.sub(r"@testable import Zhixia\n", "", src)
    # @Test("...") 整行删掉，保留 func
    src = re.sub(r'^\s*@Test\([^\n]*\)\s*$', "", src, flags=re.M)
    src = src.replace("#expect(", "expect(")

    cases: list[tuple[str, str]] = []
    owner = ""
    for line in src.splitlines():
        m = re.match(r"\s*struct\s+(\w+)", line)
        if m:
            owner = m.group(1)
            continue
        m = re.match(r"\s*func\s+(\w+)\(\)", line)
        if m and owner:
            cases.append((owner, m.group(1)))
    return src, cases


def main() -> int:
    os.makedirs(TMP, exist_ok=True)
    with open(os.path.join(REPO, "ZhixiaTests/ReconstructV2Tests.swift"), encoding="utf-8") as fh:
        tests_src, funcs = transform(fh.read())
    with open(os.path.join(REPO, "ZhixiaTests/ReconstructV2Fixtures.swift"), encoding="utf-8") as fh:
        fx_src = re.sub(r"@testable import Zhixia\n", "", fh.read())

    shim = '''
import CoreGraphics
import Foundation

// --- 最小 shim：替代 swift-testing 的 #expect / withKnownIssue ---
var failures: [String] = []
var knownReproduced: [String] = []
var cursor = ""

func expect(_ cond: Bool, _ msg: String = "") {
    if !cond { failures.append("\\(cursor): \\(msg)") }
}
func withKnownIssue(_ msg: String, _ body: () -> Void) {
    let before = failures.count
    body()
    if failures.count > before {
        failures.removeSubrange(before..<failures.count)
        knownReproduced.append(msg)
    } else {
        failures.append("\\(cursor): 已知问题未复现（可能已修复，请移除 withKnownIssue）— \\(msg)")
    }
}
func runCase(_ name: String, _ body: () -> Void) {
    cursor = name
    let before = failures.count
    body()
    let bad = failures.count > before
    print("\\(bad ? "  \\u{2717} FAIL" : "  \\u{2713} pass")  \\(name)")
}
'''

    main_src = shim + "\n" + fx_src + "\n" + tests_src + "\n" +     "\n".join(
        'runCase("%s.%s") { %s().%s() }' % (owner, fn, owner, fn)
        for owner, fn in funcs
    ) + '''

print("")
print("── 已复现的已知问题（withKnownIssue 命中，符合预期）──")
for k in knownReproduced { print("  • \\(k)") }
print("")
if failures.isEmpty {
    print("\\u{2705} 全部通过：夹具数据有效，断言行为符合预期（\\(knownReproduced.count) 处已知问题已记录）")
} else {
    print("\\u{274C} 有 \\(failures.count) 处非预期失败：")
    for f in failures { print("  - \\(f)") }
}
'''

    with open(f"{TMP}/main.swift", "w", encoding="utf-8") as fh:
        fh.write(main_src)

    cmd = [
        "xcrun", "swiftc", "-O",
        f"{TMP}/main.swift",
        f"{REPO}/Zhixia/Domain/Models/OCRPageText.swift",
        f"{REPO}/Zhixia/Domain/Models/ReconstructDocument.swift",
        f"{REPO}/Zhixia/Domain/OCRTextQuality.swift",
        f"{REPO}/Zhixia/Domain/OnDeviceTableCluster.swift",
        f"{REPO}/Zhixia/Domain/OnDeviceFigureRegions.swift",
        f"{REPO}/Zhixia/Domain/OnDeviceReadingOrder.swift",
        f"{REPO}/Zhixia/Domain/ReconstructSceneRouter.swift",
        "-F", FW, "-I", FW, "-o", f"{TMP}/run",
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stderr[-3000:])
        return 1
    subprocess.run([f"{TMP}/run"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
