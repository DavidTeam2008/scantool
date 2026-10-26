import CoreGraphics
import Foundation

/// P1 表格 guard 的“深色内容块”兜底。
///
/// 一些练习册表格只有深色表头、没有完整网格；结构识别漏表时，用低分辨率
/// 连通域找大面积深色块，向外扩一点作为保护框。照片/艺术字/深色标题也会被
/// 保护，属于安全侧误差：宁可少压平，也不让表格/插图被增益洗掉。
struct TableContentGuard: Sendable {
    func detect(in image: CGImage, maxDimension: Int = 640) -> [CGRect] {
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
        ) else { return [] }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var luma = [Double](repeating: 0, count: width * height)
        for index in luma.indices {
            let offset = index * 4
            let r = Double(pixels[offset]) / 255
            let g = Double(pixels[offset + 1]) / 255
            let b = Double(pixels[offset + 2]) / 255
            luma[index] = 0.299 * r + 0.587 * g + 0.114 * b
        }
        let paper = percentile(luma, 0.80)
        let threshold = min(0.58, max(0.20, paper * 0.55))
        var dark = [Bool](repeating: false, count: width * height)
        for index in luma.indices { dark[index] = luma[index] < threshold }

        let minimumArea = max(180, Int(Double(width * height) * 0.0025))
        let minimumWidth = max(8, Int(Double(width) * 0.02))
        let minimumHeight = max(4, Int(Double(height) * 0.008))
        var seen = [Bool](repeating: false, count: width * height)
        var boxes: [CGRect] = []
        var stack: [Int] = []
        for start in 0..<(width * height) {
            guard dark[start], !seen[start] else { continue }
            seen[start] = true
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            var minX = width
            var maxX = 0
            var minY = height
            var maxY = 0
            var area = 0
            while let index = stack.popLast() {
                let y = index / width
                let x = index % width
                area += 1
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
                let neighbors = [index - 1, index + 1, index - width, index + width]
                for neighbor in neighbors {
                    guard neighbor >= 0, neighbor < width * height else { continue }
                    let ny = neighbor / width
                    let nx = neighbor % width
                    guard abs(nx - x) + abs(ny - y) == 1 else { continue }
                    guard dark[neighbor], !seen[neighbor] else { continue }
                    seen[neighbor] = true
                    stack.append(neighbor)
                }
            }
            let boxWidth = maxX - minX + 1
            let boxHeight = maxY - minY + 1
            guard area >= minimumArea,
                  boxWidth >= minimumWidth,
                  boxHeight >= minimumHeight,
                  boxWidth <= Int(Double(width) * 0.80),
                  boxHeight <= Int(Double(height) * 0.60),
                  area <= width * height / 8 else { continue }
            boxes.append(CGRect(
                x: CGFloat(minX) / CGFloat(width),
                y: 1 - CGFloat(maxY + 1) / CGFloat(height),
                width: CGFloat(boxWidth) / CGFloat(width),
                height: CGFloat(boxHeight) / CGFloat(height)
            ))
        }
        guard !boxes.isEmpty else { return [] }

        // 表头/深色块下方常接空白表体；向下扩 18% 页高，左右各 2%。
        let expanded = boxes.map { box -> CGRect in
            var rect = box.insetBy(
                dx: -box.width * 0.10,
                dy: -box.height * 0.10
            )
            rect.origin.y -= 0.18
            rect.size.height += 0.18
            rect.origin.x = max(0, rect.origin.x)
            rect.origin.y = max(0, rect.origin.y)
            if rect.maxX > 1 { rect.size.width = 1 - rect.origin.x }
            if rect.maxY > 1 { rect.size.height = 1 - rect.origin.y }
            return rect
        }
        // 同一表头常拆成多个深色格；合并接近的框，避免 mask 碎片。
        var merged: [CGRect] = []
        for box in expanded {
            if let index = merged.firstIndex(where: { $0.insetBy(dx: -0.012, dy: -0.012).intersects(box) }) {
                merged[index] = merged[index].union(box)
            } else {
                merged.append(box)
            }
        }
        return merged.sorted {
            $0.width * $0.height > $1.width * $1.height
        }
    }
}

private func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = Int((Double(sorted.count - 1) * min(1, max(0, fraction))).rounded())
    return sorted[index]
}
