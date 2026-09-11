# pdf-ocr-dump —— 从导出的 PDF 反解真机 OCR

## 为什么需要它

真机上「还原」跑出来的结果和你本地单测对不上时，你手上只有一份 PDF/Word，
拿不到 App 里 Vision 实际吐出的 `[(text, bbox)]`。

但 SearchablePDF 的文字层是**带坐标**的，可以逐字符取回矩形，
按 y 聚成行 —— 这就把真机 Vision 的输出完整还原出来了。

有了它，流程变成：

```
用户在真机导出 → 你拿 PDF → 反解出真机 OCR → 对比本地 fixture
→ 定位根因 → 固化成新的 fixture 档 → 修 → 回归
```

## 用法

```bash
cd Tools/pdf-ocr-dump
xcrun swiftc -O main.swift -target arm64-apple-macos14 -o ocrdump
./ocrdump "/path/to/Zhixia-xxx.pdf"
```

输出格式（Vision 归一化坐标，原点左下，y 向上）：

```
== page 0 size=595.0x842.0
  [0] y=0.4309 h=0.0103 x=0.0820 w=0.0254 | 7%
  [1] y=0.4023 h=0.0129 x=0.0813 w=0.1255 | 合物8.8克2
        chunks(3): '合'@0.081 '物8.8克'@0.121 '2'@0.201
```

有 `chunks(...)` 的行表示该行内有明显的 x 间隙（> 0.012），通常是表格列的分界。

## 两个坑（都踩过）

1. **y 聚类不能用链式比较**（`abs(midY - lastChar.midY) < tol`）。
   逐字符漂移会累积，把好几行粘成一行，解出来是 `SrsSe., aonnes ua Iboip_e` 这种乱码。
   必须与**本行首字符**比较硬切。

2. **`page.string` 的顺序是 content stream 顺序，不是视觉顺序**。
   一定要用 `characterBounds(at:)` 的坐标重新排序，不要信 `string` 的索引顺序。

## 局限

- 只能还原**被写进 PDF 文字层**的内容。被丢弃的行拿不到。
- 若同一段文字被重复绘制（曾经观察到过），会解出重叠行，需要人工甄别。
- 反解结果适合用来**定位根因**，固化成 fixture 前建议人工核一遍。
