//  ocr-dump — 把样张的 Vision OCR 结果导出为 JSON 夹具数据。
//
//  目的：R2 的版面/表格/配图单测不能再用「拍脑袋合成的 CGRect」。
//  这个工具用与 App 内 `VisionTextRecognizer` 完全一致的 Vision 参数跑一遍样张，
//  把 (text, bbox) 固化下来，供 `ZhixiaTests/ReconstructV2Fixtures.swift` 使用。
//
//  用法：
//    swift Tools/ocr-dump/main.swift <图片路径...> [--out 目录]
//    swift Tools/ocr-dump/main.swift ~/Downloads/IMG_7480.PNG --out docs/fixtures
//
//  输出：每张图一个 <名字>.ocr.json，含 imageSize 与 lines [{text, x, y, w, h}]。
//  坐标系：Vision 原生归一化坐标，原点左下，与 App 内 OCRLine.boundingBox 一致。
//
//  注意：本工具跑在 macOS 的 Vision 上。iOS 与 macOS 的 Vision 版本可能存在细微差异，
//  夹具用于「锁定当前失败行为」与「回归结构」，真实验收仍以真机样张为准。

import CoreImage
import Foundation
import ImageIO
import Vision

// MARK: - 与 App 对齐的 OCR 参数

private let minimumTextHeight: Float = 0.012

private func preferredLanguages() -> [String] {
    let wanted = ["zh-Hans", "zh-Hant", "en-US"]
    let supported = (try? VNRecognizeTextRequest.supportedRecognitionLanguages(
        for: .accurate,
        revision: VNRecognizeTextRequest.currentRevision
    )) ?? []
    let matched = wanted.filter { language in
        supported.contains { $0.hasPrefix(language) || $0.hasPrefix(language.replacingOccurrences(of: "-", with: "_")) }
    }
    return matched.isEmpty ? wanted : matched
}

// 复制自 Domain/OCRTextQuality.swift，保证择优逻辑一致。
private func isCJK(_ scalar: Unicode.Scalar) -> Bool {
    let value = scalar.value
    return (0x4E00...0x9FFF).contains(value)
        || (0x3400...0x4DBF).contains(value)
        || (0xF900...0xFAFF).contains(value)
        || (0x3000...0x303F).contains(value)
        || (0xFF00...0xFFEF).contains(value)
}

private func qualityScore(_ text: String) -> Int {
    var cjk = 0, letters = 0, digits = 0, symbols = 0
    for scalar in text.unicodeScalars {
        if isCJK(scalar) { cjk += 1 }
        else if CharacterSet.decimalDigits.contains(scalar) { digits += 1 }
        else if CharacterSet.letters.contains(scalar) { letters += 1 }
        else if !CharacterSet.whitespacesAndNewlines.contains(scalar) { symbols += 1 }
    }
    return cjk * 8 + digits + letters - symbols * 3
}

private func cjkCount(_ text: String) -> Int {
    text.unicodeScalars.filter(isCJK).count
}

struct Line {
    var text: String
    var box: CGRect
}

private func recognizeLines(
    in image: CGImage,
    languages: [String],
    correction: Bool
) throws -> [Line] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = correction
    request.minimumTextHeight = minimumTextHeight
    request.revision = VNRecognizeTextRequest.currentRevision
    if !languages.isEmpty { request.recognitionLanguages = languages }

    let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
    try handler.perform([request])

    let lines = (request.results ?? []).compactMap { observation -> Line? in
        guard let text = observation.topCandidates(1).first?
            .string
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return nil }
        return Line(text: text, box: observation.boundingBox)
    }
    // 与 App 内排序一致：先按 minY 降序（自上而下），同带内按 minX 升序。
    return lines.sorted { lhs, rhs in
        if abs(lhs.box.minY - rhs.box.minY) > 0.02 {
            return lhs.box.minY > rhs.box.minY
        }
        return lhs.box.minX < rhs.box.minX
    }
}

/// 复刻 VisionTextRecognizer.recognize 的择优过程（不含反色分支，样张均为亮底）。
private func bestLines(in image: CGImage, languages: [String]) -> [Line] {
    let configs: [Bool] = [false, true] // usesLanguageCorrection
    var best: [Line] = []
    var bestScore = Int.min

    for correction in configs {
        guard let lines = try? recognizeLines(in: image, languages: languages, correction: correction),
              !lines.isEmpty
        else { continue }
        let text = lines.map(\.text).joined(separator: "\n")
        let score = qualityScore(text)
        if score > bestScore {
            best = lines
            bestScore = score
        }
        if cjkCount(text) >= 12 { return best } // App 内的提前返回条件
    }
    return best
}

// MARK: - IO

private func loadCGImage(at url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

private func json(for lines: [Line], image: CGImage, sourceName: String) -> String {
    func f(_ v: CGFloat) -> String { String(format: "%.6f", v) }
    func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
    var out = ""
    out += "{\n"
    out += "  \"source\": \"\(esc(sourceName))\",\n"
    out += "  \"imageSize\": {\"w\": \(image.width), \"h\": \(image.height)},\n"
    out += "  \"lineCount\": \(lines.count),\n"
    out += "  \"lines\": [\n"
    for (i, l) in lines.enumerated() {
        out += "    {\"text\": \"\(esc(l.text))\", \"x\": \(f(l.box.minX)), \"y\": \(f(l.box.minY)), \"w\": \(f(l.box.width)), \"h\": \(f(l.box.height))}"
        out += i == lines.count - 1 ? "\n" : ",\n"
    }
    out += "  ]\n"
    out += "}\n"
    return out
}

// MARK: - main

let args = Array(CommandLine.arguments.dropFirst())
var inputs: [String] = []
var outDir: String?
var i = 0
while i < args.count {
    if args[i] == "--out", i + 1 < args.count {
        outDir = args[i + 1]
        i += 2
    } else {
        inputs.append(args[i])
        i += 1
    }
}

guard !inputs.isEmpty else {
    FileHandle.standardError.write(Data("""
    usage: swift Tools/ocr-dump/main.swift <image...> [--out dir]

    example:
      swift Tools/ocr-dump/main.swift ~/Downloads/IMG_7480.PNG ~/Downloads/IMG_7481.PNG --out docs/fixtures

    """.utf8))
    exit(1)
}

let languages = preferredLanguages()
print("languages: \(languages.joined(separator: ", "))")
print("revision: \(VNRecognizeTextRequest.currentRevision)")

let fm = FileManager.default
if let outDir {
    try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
}

for path in inputs {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    guard let image = loadCGImage(at: url) else {
        print("!! cannot load \(path)")
        continue
    }
    let lines = bestLines(in: image, languages: languages)
    let name = url.deletingPathExtension().lastPathComponent
    let text = json(for: lines, image: image, sourceName: url.lastPathComponent)

    if let outDir {
        let out = URL(fileURLWithPath: outDir).appendingPathComponent("\(name).ocr.json")
        try? text.write(to: out, atomically: true, encoding: .utf8)
        print("✓ \(name): \(lines.count) lines -> \(out.path)")
    } else {
        print(text)
    }
}
