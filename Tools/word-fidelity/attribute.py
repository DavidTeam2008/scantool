#!/usr/bin/env python3
"""
可编辑档（版面还原）的**分层归因**（spec/word-fidelity T010 / docs/16 §七）。

把 `out-restored.docx` 的 `word/document.xml` 拆成层级变体，各自渲染后与页面图
比 SSIM，回答一个问题：**「样式乱掉」到底是谁造成的**？

| 层 | 含义 | 变体做法 |
|---|---|---|
| L0 | 底图 + 保留区裁剪（无遮罩、无文本框） | 去掉含 `wps:wsp` / `wps:txbx` 的 run |
| L1 | L0 + 净化遮罩（把原字迹盖成底色） | 去掉含 `wps:txbx` 的 run |
| L2 | 完整产物（+ 浮动文本框重排） | 原样 |

用法：python3 Tools/word-fidelity/attribute.py <docx> <页面图>
输出：每层的 SSIM（渲染图 vs 页面图）。
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

# 含浮动 shape（遮罩 wps:wsp / 文本框 wps:txbx）的 run
RUN_WITH_SHAPE = re.compile(r"<w:r>(?:(?!</w:r>).)*?<wps:(?:wsp|txbx)\b.*?</w:r>", re.S)
RUN_WITH_TEXTBOX = re.compile(r"<w:r>(?:(?!</w:r>).)*?<wps:txbx\b.*?</w:r>", re.S)


def variant(src_docx: str, out_docx: str, drop) -> None:
    """按 drop 规则（正则列表）派生一个 docx 变体。"""
    with zipfile.ZipFile(src_docx) as zin:
        names = zin.namelist()
        data = {n: zin.read(n) for n in names}
    xml = data["word/document.xml"].decode("utf-8")
    for pattern in drop:
        xml = pattern.sub("", xml)
    data["word/document.xml"] = xml.encode("utf-8")
    with zipfile.ZipFile(out_docx, "w", zipfile.ZIP_DEFLATED) as zout:
        for n in names:
            zout.writestr(n, data[n])


def render(docx: str) -> str:
    tmp = tempfile.mkdtemp()
    subprocess.run(["qlmanage", "-t", "-s", "1600", "-o", tmp, docx],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    pngs = [os.path.join(tmp, f) for f in os.listdir(tmp) if f.endswith(".png")]
    if not pngs:
        raise SystemExit(f"qlmanage 未能渲染 {docx}")
    return pngs[0]


def ssim(a: str, b: str) -> str:
    """SSIM（口径与 check.sh 一致：800×800 + 高斯模糊 sigma=3）。"""
    out = subprocess.run(
        ["ffmpeg", "-v", "info", "-i", a, "-i", b,
         "-lavfi",
         "[0:v]scale=800:800:flags=bicubic,gblur=sigma=3[a];"
         "[1:v]scale=800:800:flags=bicubic,gblur=sigma=3[b];[a][b]ssim",
         "-f", "null", "-"],
        capture_output=True, text=True).stderr
    m = re.findall(r"All:([0-9.]+)", out)
    return m[-1] if m else "n/a"


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    docx, page = sys.argv[1], sys.argv[2]
    work = tempfile.mkdtemp()
    layers = [
        ("L0 底图+保留区裁剪（无遮罩/无文本框）", [RUN_WITH_SHAPE]),
        ("L1 L0 + 净化遮罩（无文本框）", [RUN_WITH_TEXTBOX]),
        ("L2 完整产物（+ 浮动文本框）", []),
    ]
    print("=== 可编辑档分层归因（spec/word-fidelity T010）===")
    print(f"基准：页面图 {page}\n")
    for name, drop in layers:
        out = os.path.join(work, name.split()[0] + ".docx")
        variant(docx, out, drop)
        png = render(out)
        value = ssim(png, page)
        flag = "✓" if value != "n/a" and float(value) >= 0.90 else "✗"
        print(f"{name}\n  SSIM vs 页面图 = {value}  {flag}")
    print(f"\n产物：{work}")


if __name__ == "__main__":
    main()
