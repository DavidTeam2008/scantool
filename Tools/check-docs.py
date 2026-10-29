#!/usr/bin/env python3
"""文档自检：相对链接、代码围栏、docs 索引覆盖。

只扫「当前事实源」范围（根 README/AGENTS/TODO + docs/*.md + spec/**/*.md），
跳过 build/、.harness2/、docs/media/ 等大目录——避免把历史证据和录屏当成文档债。

用法：python3 Tools/check-docs.py
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

LINK_RE = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
FENCE_RE = re.compile(r"^\s*```", re.M)

errors: list[str] = []


def targets() -> list[Path]:
    files = [ROOT / "README.md", ROOT / "AGENTS.md", ROOT / "TODO.md"]
    files += sorted((ROOT / "docs").glob("*.md"))
    files += sorted((ROOT / "references").glob("*.md"))
    files += sorted((ROOT / "spec").rglob("*.md"))
    return [p for p in files if p.is_file()]


def strip_code(text: str) -> str:
    text = re.sub(r"```.*?```", "", text, flags=re.S)
    return re.sub(r"`[^`]*`", "", text)


def check_links(path: Path) -> int:
    text = strip_code(path.read_text(encoding="utf-8"))
    checked = 0
    for raw in LINK_RE.findall(text):
        target = raw.strip()
        if target.startswith(("http://", "https://", "mailto:", "#", "{{")):
            continue
        local = target.split("#", 1)[0].strip()
        if not local:
            continue
        checked += 1
        if not (path.parent / local).exists():
            errors.append(f"{path.relative_to(ROOT)} 链接不存在：{target}")
    return checked


def check_fences(path: Path) -> None:
    fences = len(FENCE_RE.findall(path.read_text(encoding="utf-8")))
    if fences % 2:
        errors.append(f"{path.relative_to(ROOT)} 代码围栏未闭合（{fences} 个 ```）")


def check_docs_index() -> None:
    index = ROOT / "docs" / "README.md"
    if not index.is_file():
        errors.append("缺少 docs/README.md（文档索引）")
        return
    indexed = {
        (index.parent / raw.split("#", 1)[0]).resolve()
        for raw in LINK_RE.findall(strip_code(index.read_text(encoding="utf-8")))
        if not raw.startswith(("http://", "https://", "#", "{{"))
    }
    for doc in sorted((ROOT / "docs").glob("*.md")):
        if doc.name == "README.md":
            continue
        if doc.resolve() not in indexed:
            errors.append(f"docs/{doc.name} 未登记到 docs/README.md")


def main() -> int:
    files = targets()
    links = sum(check_links(p) for p in files)
    for p in files:
        check_fences(p)
    check_docs_index()

    print(f"扫描 {len(files)} 篇文档，{links} 条相对链接")
    if errors:
        print(f"\n[FAIL] {len(errors)} 个问题：")
        for e in errors:
            print(f"- {e}")
        return 1
    print("[PASS] 链接 / 围栏 / docs 索引全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
