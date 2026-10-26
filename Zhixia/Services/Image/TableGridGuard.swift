import CoreGraphics
import Foundation

/// P1 表格 guard 的廉价兜底：在增强预览上找“长横线 + 长竖线”组成的网格。
///
/// 触发场景：`VisionDocumentStructureRecognizer` 漏表（假阴性），但页面其实
/// 有带边框的表格。这里不依赖 OCR/文档模型，只做低分辨率投影，返回表格外框；
/// 宁可多保护一块区域，也不让 P1 无 mask 改到表格。
struct TableGridGuard: Sendable {
    struct Result: Codable, Equatable, Sendable {
        /// Vision 归一化坐标（原点左下），与 `DetectedTable.bbox` 同系。
        var normalizedRects: [CGRect]
        var horizontalLines: Int
        var verticalLines: Int
    }

    func detect(in image: CGImage, maxDimension: Int = 640) -> Result? {
        let scale = min(
            1,
            Double(max(16, maxDimension)) / Double(max(image.width, image.height))
        )
        let width = max(16, Int((Double(image.width) * scale).rounded()))
        let height = max(16, Int((Double(image.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        // 先按 CGContext 默认坐标绘制；方向由单测校准。
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var luma = [Double](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            let offset = index * 4
            let r = Double(pixels[offset]) / 255
            let g = Double(pixels[offset + 1]) / 255
            let b = Double(pixels[offset + 2]) / 255
            luma[index] = 0.299 * r + 0.587 * g + 0.114 * b
        }
        let paper = percentile(luma, 0.80)
        let threshold = min(0.66, max(0.22, paper * 0.72))
        var dark = [Bool](repeating: false, count: width * height)
        for index in luma.indices {
            dark[index] = luma[index] < threshold
        }

        let minHorizontalRun = max(8, Int(Double(width) * 0.10))
        let minVerticalRun = max(8, Int(Double(height) * 0.06))
        let horizontal = findRuns(
            dark: dark,
            width: width,
            height: height,
            horizontal: true,
            minLength: minHorizontalRun,
            maxGap: 2
        )
        let vertical = findRuns(
            dark: dark,
            width: width,
            height: height,
            horizontal: false,
            minLength: minVerticalRun,
            maxGap: 2
        )
        let mergedHorizontal = merge(
            horizontal,
            tolerance: 2,
            limit: width
        )
        let mergedVertical = merge(
            vertical,
            tolerance: 2,
            limit: height
        )
        guard mergedHorizontal.count >= 2, mergedVertical.count >= 2 else {
            return nil
        }

        let minX = mergedHorizontal.map(\.start).min() ?? 0
        let maxX = mergedHorizontal.map(\.end).max() ?? width
        let minY = mergedVertical.map(\.start).min() ?? 0
        let maxY = mergedVertical.map(\.end).max() ?? height
        guard maxX > minX, maxY > minY else { return nil }
        let box = CGRect(
            x: CGFloat(minX) / CGFloat(width),
            y: 1 - CGFloat(maxY) / CGFloat(height),
            width: CGFloat(maxX - minX) / CGFloat(width),
            height: CGFloat(maxY - minY) / CGFloat(height)
        )
        guard box.width >= 0.03, box.height >= 0.03 else { return nil }
        return Result(
            normalizedRects: [box],
            horizontalLines: mergedHorizontal.count,
            verticalLines: mergedVertical.count
        )
    }

    private struct Run {
        var position: Int
        var start: Int
        var end: Int
    }

    /// 找连续暗像素段；允许 1~2px 抗锯齿断点。
    private func findRuns(
        dark: [Bool],
        width: Int,
        height: Int,
        horizontal: Bool,
        minLength: Int,
        maxGap: Int
    ) -> [Run] {
        var result: [Run] = []
        let outer = horizontal ? height : width
        let inner = horizontal ? width : height
        for position in 0..<outer {
            var runStart: Int?
            var lastDark = -1
            for offset in 0..<inner {
                let x = horizontal ? offset : position
                let y = horizontal ? position : offset
                let isDark = dark[y * width + x]
                if isDark {
                    if let start = runStart {
                        if offset - lastDark > maxGap + 1 {
                            if lastDark - start + 1 >= minLength {
                                result.append(Run(position: position, start: start, end: lastDark))
                            }
                            runStart = offset
                        }
                    } else {
                        runStart = offset
                    }
                    lastDark = offset
                }
            }
            if let start = runStart, lastDark - start + 1 >= minLength {
                result.append(Run(position: position, start: start, end: lastDark))
            }
        }
        return result
    }

    private func merge(_ runs: [Run], tolerance: Int, limit: Int) -> [Run] {
        guard !runs.isEmpty else { return [] }
        let sorted = runs.sorted { $0.position < $1.position }
        var result: [Run] = []
        var current = sorted[0]
        for run in sorted.dropFirst() {
            if run.position - current.position <= tolerance {
                current.start = min(current.start, run.start)
                current.end = max(current.end, run.end)
                current.position = min(current.position, run.position)
            } else {
                result.append(current)
                current = run
            }
        }
        result.append(current)
        return result.filter {
            $0.start >= 0 && $0.end < limit && $0.end > $0.start
        }
    }
}

private func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = Int((Double(sorted.count - 1) * min(1, max(0, fraction))).rounded())
    return sorted[index]
}
