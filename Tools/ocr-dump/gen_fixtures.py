#!/usr/bin/env python3
"""
把 docs/fixtures/*.ocr.json 生成为 ZhixiaTests/ReconstructV2Fixtures.swift。

用法：
    python3 Tools/ocr-dump/gen_fixtures.py

前提：先用 main.swift 导出 OCR json：
    swift Tools/ocr-dump/main.swift docs/fixtures/images/*.jpg --out docs/fixtures

夹具是**真实样张的 OCR 输出**，不是合成的 CGRect。
合成 bbox 的单测全绿也挡不住真机样张崩，所以 R2 的所有版面 / 表格 / 配图断言
都必须建立在这份真实数据上。
"""

import json
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIX_DIR = os.path.join(REPO, "docs", "fixtures")
OUT = os.path.join(REPO, "ZhixiaTests", "ReconstructV2Fixtures.swift")

# json 文件名 -> (Swift 属性名, 中文名, 期望场景)
SAMPLES = [
    ("nutrition-mango.ocr.json", "nutritionMango", "营养成分表（小象超市芒果干）", "table"),
    ("workbook-test4.ocr.json", "workbookTest4", "练习册 Test 4 Questions 1~5", "exam"),
]


def esc(s: str) -> str:
    return (
        s.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\t", "\\t")
    )


def num(v: float) -> str:
    return f"{v:.6f}".rstrip("0").rstrip(".") or "0"


def camel(name: str) -> str:
    return name


def main() -> int:
    blocks = []
    members = []

    for filename, prop, label, scene in SAMPLES:
        path = os.path.join(FIX_DIR, filename)
        if not os.path.exists(path):
            print(f"!! missing {path}", file=sys.stderr)
            return 1
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)

        size = data["imageSize"]
        lines = []
        for l in data["lines"]:
            lines.append(
                '        OCRLine(text: "%s", boundingBox: CGRect(x: %s, y: %s, width: %s, height: %s))'
                % (
                    esc(l["text"]),
                    num(l["x"]),
                    num(l["y"]),
                    num(l["w"]),
                    num(l["h"]),
                )
            )

        blocks.append(
            '    /// %s\n'
            '    /// 原图：`docs/fixtures/images/%s`\n'
            '    /// 导出：%d 行 OCR（Vision accurate，中英，与 App 内 VisionTextRecognizer 同参）\n'
            '    static let %s = ReconstructSampleFixture(\n'
            '        name: "%s",\n'
            '        label: "%s",\n'
            '        sourceImage: "%s",\n'
            '        imageSize: CGSize(width: %d, height: %d),\n'
            '        expectedScene: .%s,\n'
            '        lines: [\n'
            '%s\n'
            '        ]\n'
            '    )'
            % (
                label,
                filename.replace(".ocr.json", ".jpg"),
                data["lineCount"],
                prop,
                prop,
                label,
                filename.replace(".ocr.json", ".jpg"),
                size["w"],
                size["h"],
                scene,
                ",\n".join(lines),
            )
        )
        members.append("        %s," % prop)

    header = '''import CoreGraphics
import Foundation
@testable import Zhixia

//  ⚠ 本文件由 Tools/ocr-dump/gen_fixtures.py 生成，请勿手改。
//  改法：改 docs/fixtures/images/ 下的样张 → 跑 main.swift 重新导出 json → 跑 gen_fixtures.py。
//
//  为什么需要它：
//  以前 ReconstructTests 用「拍脑袋合成的 CGRect」，全绿但真机样张照崩
//  （README §已知问题、docs/06 §12.4 都记了这笔账）。
//  R2 起，版面 / 表格 / 配图的断言一律建立在这份**真实样张 OCR**上。
//
//  坐标系：Vision 原生归一化，原点左下，与 OCRLine.boundingBox 一致。

/// 一张样张的真实 OCR 输出 + 人工标注的期望结构。
struct ReconstructSampleFixture: Sendable {
    var name: String
    var label: String
    var sourceImage: String
    var imageSize: CGSize
    var expectedScene: ReconstructScene
    var lines: [OCRLine]

    var joinedText: String { lines.map(\\.text).joined(separator: "\\n") }
}

enum ReconstructV2Fixtures {
'''

    nutrition_expected = '''
    // MARK: - 人工标注的期望结构（ground truth，来自原图肉眼核对）

    /// 营养表真实网格：6 行 × 3 列（1 行表头 + 5 行数据，不含「营养成分表」标题）。
    /// 这是 docs/07 §2.3「营养表 Word 必达」的判定基准。
    static let nutritionExpectedGrid: [[String]] = [
        ["项目", "每 100克", "NRV%"],
        ["能量", "1429 千焦", "17%"],
        ["蛋白质", "1.5克", "3%"],
        ["脂肪", "0.8克", "1%"],
        ["碳水化合物", "80.8克", "27%"],
        ["钠", "49毫克", "2%"]
    ]

    /// 营养表三列在版面中的真实中心 x（人工从原图量取，用于校验列聚类）。
    /// 当前 OnDeviceTableCluster 算出来是 [0.185, 0.378, 0.662] —— 被包装说明噪声带偏。
    static let nutritionColumnCenters: [CGFloat] = [0.175, 0.505, 0.815]

    /// 练习册里 A/B/C 三个选项字母（人工标注，用于校验「不被聚成假表」）。
    static let workbookOptionLetters: [String] = ["A", "B", "C"]

    /// 练习册底部署名/条码区（原图右下），用于校验配图候选不被漏掉。
    static let workbookExpectsFigures = true
'''

    footer = '''
    static var allSamples: [ReconstructSampleFixture] {
        [
%s
        ]
    }
}
''' % "\n".join(members)

    out = header + "\n".join(blocks) + "\n" + nutrition_expected + "\n" + footer
    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write(out)
    print("✓ wrote %s (%d samples, %d bytes)" % (OUT, len(blocks), len(out)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
