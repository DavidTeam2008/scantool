import Foundation
import Testing

@testable import Zhixia

/// T004（spec/guided-capture D6 / SC-005）：trace 回放基线。
///
/// 断言锚点（四项指标，统一口径见 `CaptureTraceAnalyzer`）：
/// - **四角误差**：按标注框短边归一；越接近 0 越准；
/// - **禁止内容入片率**：生效框把禁止区域（左页/折痕）框进来的帧占比；
/// - **锁定延迟**：首帧 → 首次 locked 的时间；
/// - **状态转换次数**：轨道态切换次数（越少越稳）。
///
/// 回放链路刻意走一遍真实路径：**JSON 落盘 → 读回 → 解码 → 指标**——
/// 诊断包是 JSON 载体，读写往返的字段丢失必须在这里暴露。
struct CaptureTraceReplayTests {
    /// 右页标注框（视频/照片归一化空间）。
    private static let expectedQuad = Quad(
        topLeft: CGPoint(x: 0.50, y: 0.10),
        topRight: CGPoint(x: 0.95, y: 0.10),
        bottomRight: CGPoint(x: 0.95, y: 0.90),
        bottomLeft: CGPoint(x: 0.50, y: 0.90)
    )
    /// 禁止区域：左页。
    private static let forbiddenQuad = Quad(
        topLeft: CGPoint(x: 0.05, y: 0.10),
        topRight: CGPoint(x: 0.48, y: 0.10),
        bottomRight: CGPoint(x: 0.48, y: 0.90),
        bottomLeft: CGPoint(x: 0.05, y: 0.90)
    )

    @Test("回放：JSON 往返后四项指标一致可算")
    func replayComputesFourMetrics() throws {
        let traces = Self.makeTraces()
        // 走一遍真实载体：编码 → 落盘 → 读回 → 解码。
        let url = FileManager.default.temporaryDirectory
            .appending(path: "trace-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let encoder = CaptureTraceCoding.makeEncoder()
        try encoder.encode(CaptureTracePayload(
            generatedAt: Date(),
            appVersion: "1.0",
            deviceModel: "test",
            osVersion: "test",
            frames: traces,
            candidates: []
        )).write(to: url)

        let decoder = CaptureTraceCoding.makeDecoder()
        let payload = try decoder.decode(
            CaptureTracePayload.self,
            from: try Data(contentsOf: url)
        )
        #expect(payload.frames.count == traces.count)

        let annotation = CaptureAnnotation(
            name: "spread-right-page",
            expectedQuad: Self.expectedQuad,
            forbiddenRegions: [Self.forbiddenQuad]
        )
        let metrics = CaptureTraceAnalyzer.analyze(
            frames: CaptureTraceAnalyzer.replayFrames(from: payload.frames),
            annotation: annotation
        )

        // 帧构成：0~2 搜索（无框）、3~7 跟踪（框偏 0.01）、8 锁定（偏 0.005）、
        // 9 锁定但框住整书（把左页框进来了）。
        #expect(metrics.frameCount == 10)
        #expect(metrics.analyzedQuadCount == 7)
        #expect(metrics.stateTransitions == 2, "searching→tracking→locked")
        #expect(metrics.lockLatencyFrames == 8)
        let latency = try #require(metrics.lockLatencySeconds)
        // JSON 时间戳精度 = 毫秒（诊断包判读口径），容差 1ms。
        #expect(abs(latency - 8.0 / 15.0) < 1e-3)
        #expect(metrics.forbiddenFrames == 1)
        let rate = try #require(metrics.forbiddenContentRate)
        #expect(abs(rate - 1.0 / 7.0) < 1e-9)
        let maxError = try #require(metrics.maxCornerError)
        #expect(maxError > 0.9, "整书框与右页标注的角点误差 ≈ 短边 1.0，实际 \(maxError)")
        let meanError = try #require(metrics.meanCornerError)
        #expect(meanError > 0 && meanError < maxError)
    }

    @Test("回放：无标注时只给可算的指标（不猜四角误差）")
    func replayWithoutAnnotation() {
        let metrics = CaptureTraceAnalyzer.analyze(
            frames: CaptureTraceAnalyzer.replayFrames(from: Self.makeTraces()),
            annotation: nil
        )
        #expect(metrics.meanCornerError == nil)
        #expect(metrics.maxCornerError == nil)
        #expect(metrics.forbiddenContentRate == nil)
        #expect(metrics.frameCount == 10)
        #expect(metrics.analyzedQuadCount == 7)
    }

    @Test("回放：四角误差按标注框短边归一")
    func cornerErrorUsesShortSide() {
        let quad = Quad(
            topLeft: CGPoint(x: 0.50, y: 0.10),
            topRight: CGPoint(x: 0.95, y: 0.10),
            bottomRight: CGPoint(x: 0.95, y: 0.90),
            bottomLeft: CGPoint(x: 0.50, y: 0.90)
        )
        // 标注框短边 = 0.45；角点偏差 0.045 → 归一误差 0.1。
        let shifted = Quad(
            topLeft: CGPoint(x: 0.455, y: 0.10),
            topRight: CGPoint(x: 0.905, y: 0.10),
            bottomRight: CGPoint(x: 0.905, y: 0.90),
            bottomLeft: CGPoint(x: 0.455, y: 0.90)
        )
        let error = CaptureTraceAnalyzer.cornerError(quad: shifted, expected: quad)
        #expect(abs(error - 0.1) < 1e-9)
    }

    // MARK: - 合成 trace 序列

    /// 10 帧合成序列：搜索 3 帧 → 跟踪 5 帧 → 锁定 2 帧（末帧框住整书）。
    private static func makeTraces() -> [CaptureTrace] {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        return (0..<10).map { index in
            let track: String
            let quad: Quad?
            switch index {
            case 0..<3:
                track = "searching"
                quad = nil
            case 3..<8:
                track = "tracking"
                quad = expectedQuad.shifted(dx: -0.01)
            case 8:
                track = "locked"
                quad = expectedQuad.shifted(dx: -0.005)
            default:
                track = "locked"
                quad = Quad(
                    topLeft: CGPoint(x: 0.05, y: 0.05),
                    topRight: CGPoint(x: 0.98, y: 0.05),
                    bottomRight: CGPoint(x: 0.98, y: 0.95),
                    bottomLeft: CGPoint(x: 0.05, y: 0.95)
                )
            }
            return CaptureTrace(
                sessionID: UUID(),
                timestamp: base.addingTimeInterval(Double(index) / 15.0),
                phase: track == "locked" ? "locked" : "previewing",
                directive: track == "locked" ? "locked" : "searching",
                geometry: .init(videoAspect: 0.5625, photoAspect: 0.75),
                previewSize: .init(width: 390, height: 844),
                imageQuad: quad,
                frozenQuad: nil,
                guide: nil,
                cropQuad: nil,
                sticky: nil,
                smoother: .init(track: track, area: quad?.area, frameDt: 1.0 / 15.0),
                candidateSnapshot: nil
            )
        }
    }
}

/// 测试内的小工具：整体平移四边形。
private extension Quad {
    func shifted(dx: Double) -> Quad {
        Quad(
            topLeft: CGPoint(x: topLeft.x + dx, y: topLeft.y),
            topRight: CGPoint(x: topRight.x + dx, y: topRight.y),
            bottomRight: CGPoint(x: bottomRight.x + dx, y: bottomRight.y),
            bottomLeft: CGPoint(x: bottomLeft.x + dx, y: bottomLeft.y)
        )
    }
}
