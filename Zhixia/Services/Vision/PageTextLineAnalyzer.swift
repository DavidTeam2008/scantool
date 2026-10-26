import CoreGraphics
import Foundation
import Vision

/// P2 前置测量：用轻量文字矩形（不跑 OCR）估计文字行倾角与水平带。
///
/// 这一步只输出几何指标，不改像素。P2 的局部平移/旋转矫正要在这些指标
/// 稳定后再接，避免在未量化的页面上直接做不可逆 warp。
struct PageTextLineAnalyzer: Sendable {
    struct Line: Sendable, Equatable {
        /// Vision 归一化 bbox（原点左下）。
        var boundingBox: CGRect
        /// 相对水平线的有符号角度（度）。
        var angleDegrees: Double
    }

    struct Band: Sendable, Equatable {
        /// 左上原点归一化 y 范围。
        var minY: Double
        var maxY: Double
        var lineCount: Int
        var medianAbsAngleDegrees: Double
    }

    struct Analysis: Sendable, Equatable {
        var lines: [Line]
        var bands: [Band]
        var medianAbsAngleDegrees: Double
        var p90AbsAngleDegrees: Double
        var maxAbsAngleDegrees: Double
    }

    static func analyze(in image: CGImage) -> Analysis {
        let request = VNDetectTextRectanglesRequest()
        request.reportCharacterBoxes = false
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        do {
            try handler.perform([request])
        } catch {
            return Analysis(
                lines: [],
                bands: [],
                medianAbsAngleDegrees: 0,
                p90AbsAngleDegrees: 0,
                maxAbsAngleDegrees: 0
            )
        }
        let lines = (request.results ?? []).compactMap { observation -> Line? in
            let box = observation.boundingBox
            guard box.width > 0.01,
                  box.height > 0.003,
                  box.height < 0.08,
                  box.width >= box.height * 1.2
            else { return nil }
            let angle = lineAngleDegrees(
                topLeft: observation.topLeft,
                topRight: observation.topRight
            )
            guard abs(angle) <= 10 else { return nil }
            return Line(boundingBox: box, angleDegrees: angle)
        }
        return summarize(lines)
    }

    /// 供单测/诊断使用的纯几何角度。
    static func lineAngleDegrees(topLeft: CGPoint, topRight: CGPoint) -> Double {
        let dx = Double(topRight.x - topLeft.x)
        let dy = Double(topRight.y - topLeft.y)
        guard abs(dx) + abs(dy) > 1e-12 else { return 0 }
        return atan2(dy, dx) * 180 / .pi
    }

    static func summarize(_ lines: [Line]) -> Analysis {
        let angles = lines.map { abs($0.angleDegrees) }.sorted()
        let median = percentile(angles, 0.50)
        let p90 = percentile(angles, 0.90)
        let maxAngle = angles.last ?? 0
        let bands = makeBands(lines)
        return Analysis(
            lines: lines,
            bands: bands,
            medianAbsAngleDegrees: median,
            p90AbsAngleDegrees: p90,
            maxAbsAngleDegrees: maxAngle
        )
    }

    private static func makeBands(_ lines: [Line]) -> [Band] {
        struct Row {
            var minY: Double
            var maxY: Double
            var angles: [Double]
        }
        var rows: [Row] = []
        let sorted = lines.map {
            (minY: 1 - Double($0.boundingBox.maxY),
             maxY: 1 - Double($0.boundingBox.minY),
             angle: abs($0.angleDegrees))
        }.sorted { $0.minY < $1.minY }
        for line in sorted {
            if let index = rows.firstIndex(where: {
                abs((($0.minY + $0.maxY) / 2) - ((line.minY + line.maxY) / 2)) < 0.02
            }) {
                rows[index].minY = min(rows[index].minY, line.minY)
                rows[index].maxY = max(rows[index].maxY, line.maxY)
                rows[index].angles.append(line.angle)
            } else {
                rows.append(Row(minY: line.minY, maxY: line.maxY, angles: [line.angle]))
            }
        }
        return rows.map {
            Band(
                minY: $0.minY,
                maxY: $0.maxY,
                lineCount: $0.angles.count,
                medianAbsAngleDegrees: percentile($0.angles.sorted(), 0.50)
            )
        }
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * min(1, max(0, fraction))).rounded())
        return sorted[index]
    }
}
