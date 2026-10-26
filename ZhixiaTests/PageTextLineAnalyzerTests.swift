import CoreGraphics
import Foundation
import Testing

@testable import Zhixia

struct PageTextLineAnalyzerTests {
    @Test("文字行角度符号与大小正确")
    func computesLineAngle() {
        let rising = PageTextLineAnalyzer.lineAngleDegrees(
            topLeft: CGPoint(x: 0.1, y: 0.5),
            topRight: CGPoint(x: 0.9, y: 0.6)
        )
        let falling = PageTextLineAnalyzer.lineAngleDegrees(
            topLeft: CGPoint(x: 0.1, y: 0.5),
            topRight: CGPoint(x: 0.9, y: 0.4)
        )
        #expect(abs(rising - 7.125) < 0.01)
        #expect(abs(falling + 7.125) < 0.01)
    }

    @Test("倾角分位与水平带汇总")
    func summarizesLinesAndBands() {
        let lines = [
            PageTextLineAnalyzer.Line(
                boundingBox: CGRect(x: 0.1, y: 0.80, width: 0.4, height: 0.02),
                angleDegrees: 0.2
            ),
            PageTextLineAnalyzer.Line(
                boundingBox: CGRect(x: 0.1, y: 0.81, width: 0.4, height: 0.02),
                angleDegrees: -0.4
            ),
            PageTextLineAnalyzer.Line(
                boundingBox: CGRect(x: 0.1, y: 0.70, width: 0.4, height: 0.02),
                angleDegrees: 1.0
            ),
        ]
        let analysis = PageTextLineAnalyzer.summarize(lines)
        #expect(analysis.lines.count == 3)
        #expect(analysis.bands.count == 2)
        #expect(abs(analysis.medianAbsAngleDegrees - 0.4) < 0.0001)
        #expect(abs(analysis.p90AbsAngleDegrees - 1.0) < 0.0001)
        #expect(abs(analysis.maxAbsAngleDegrees - 1.0) < 0.0001)
    }
}
