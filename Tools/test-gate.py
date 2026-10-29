#!/usr/bin/env python3
"""CI 测试门禁：总数不低于基线，且失败集合 ⊆ 已知债白名单。

背景：本仓库有 10 条既有测试债（Golden / WordFidelity / Review 等），
`make test` 在债未清前必然非 0；团队 CI 需要一个「只拦新增失败」的判据。
本脚本直接解析 xcresult（不依赖 xcodebuild 退出码），因此已知债不会把 CI 染红，
新增失败、总数下降（测试被删）仍会失败。

用法：
  python3 Tools/test-gate.py
  python3 Tools/test-gate.py --result build/Zhixia.xcresult --min-total 547
  python3 Tools/test-gate.py --allowlist /tmp/empty.txt   # 调试：任何失败都算新增
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_RESULT = ROOT / "build" / "Zhixia.xcresult"
DEFAULT_ALLOWLIST = ROOT / "ci" / "known-failures.txt"


def load_allowlist(path: Path) -> set[str]:
    entries: set[str] = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            entries.add(line)
    return entries


def collect(result: Path) -> list[tuple[str, str]]:
    proc = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(result)],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"xcresulttool 失败：{proc.stderr.strip()[:300]}")
    data = json.loads(proc.stdout)
    cases: list[tuple[str, str]] = []

    def walk(node: dict) -> None:
        if node.get("nodeType") == "Test Case":
            cases.append((node.get("nodeIdentifier", ""), node.get("result", "")))
        for child in node.get("children", []):
            walk(child)

    for node in data.get("testNodes", []):
        walk(node)
    return cases


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--result", default=str(DEFAULT_RESULT))
    parser.add_argument("--allowlist", default=str(DEFAULT_ALLOWLIST))
    parser.add_argument("--min-total", type=int, default=547)
    args = parser.parse_args()

    result = Path(args.result)
    allowlist_path = Path(args.allowlist)
    if not result.exists():
        print(f"[FAIL] 结果包不存在：{result}（先跑 make test 或 make test-ci）")
        return 2
    if not allowlist_path.exists():
        print(f"[FAIL] 白名单不存在：{allowlist_path}")
        return 2

    allowlist = load_allowlist(allowlist_path)
    try:
        cases = collect(result)
    except (RuntimeError, json.JSONDecodeError) as exc:
        print(f"[FAIL] 无法解析测试结果：{exc}")
        return 2

    total = len(cases)
    passed = sum(1 for _, r in cases if r == "Passed")
    failed = {identifier for identifier, r in cases if r == "Failed"}
    expected = sum(1 for _, r in cases if r == "Expected Failure")
    known = failed & allowlist
    new = sorted(failed - allowlist)
    stale = sorted(allowlist - failed)

    print(
        f"total={total} passed={passed} failed={len(failed)} "
        f"expectedFailures={expected} knownDebt={len(known)}"
    )
    if stale:
        print(f"[WARN] 白名单中 {len(stale)} 条本次通过（flaky 或已修复，可考虑删行）：")
        for identifier in stale:
            print(f"  - {identifier}")

    if total < args.min_total:
        print(f"[FAIL] 总数 {total} < 基线 {args.min_total}：既有测试被删？")
        return 1
    if new:
        print(f"[FAIL] {len(new)} 条新增失败（不在已知债白名单）：")
        for identifier in new:
            print(f"  - {identifier}")
        return 1
    print("[PASS] 无新增失败；失败均在已知债白名单内")
    return 0


if __name__ == "__main__":
    sys.exit(main())
