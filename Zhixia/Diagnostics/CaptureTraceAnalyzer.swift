import Foundation

/// 取景回放指标（spec/guided-capture T004 / SC-005）——诊断包与语料的**统一口径**。
///
/// 四项指标（FR-007 / SC-005）：
/// 1. **四角误差**：生效框与标注框的角点偏差（相对短边归一）——量「框得准不准」；
/// 2. **禁止内容入片率**：生效框把「左页/折痕/背景」等禁止区域框进来的比例
///    ——量「有没有拍到不该拍的东西」（折页书主场景的成败判据）；
/// 3. **锁定延迟**：从第一帧到首次进入 locked 的时间——量「多久能拍」；
/// 4. **状态转换次数**：轨道态切换次数——量「框稳不稳」（频繁互跳 = 不稳）。
///
/// 纯函数、无数值调参；所有判读字段与 `device-acceptance.md` 的字段名对齐。
struct CaptureReplayMetrics: Codable, Equatable, Sendable {
    /// 参与回放的帧数。
    var frameCount: Int
    /// 有效（有生效框）帧数。
    var analyzedQuadCount: Int
    /// 平均四角误差（相对短边；无标注时为 nil）。
    var meanCornerError: Double?
    /// 最大四角误差（相对短边；无标注时为 nil）。
    var maxCornerError: Double?
    /// 禁止内容入片率（0~1；无标注时为 nil）。
    var forbiddenContentRate: Double?
    /// 禁止内容入片的帧数。
    var forbiddenFrames: Int
    /// 锁定延迟（秒；从未锁定时为 nil）。
    var lockLatencySeconds: Double?
    /// 锁定延迟（帧数；从未锁定时为 nil）。
    var lockLatencyFrames: Int?
    /// 状态转换次数（相邻帧轨道态变化计数）。
    var stateTransitions: Int
}

/// 回放标注（人工标注：目标框 + 禁止区域）。
struct CaptureAnnotation: Codable, Equatable, Sendable {
    /// 场景名。
    var name: String
    /// 目标四边形（视频/照片归一化空间，y-down）。
    var expectedQuad: Quad
    /// 禁止入片区域（左页、折痕带、背景……）。
    var forbiddenRegions: [Quad]
    /// 禁止区域被框入的判定阈值（禁止区域被生效框覆盖的比例）。
    var forbiddenOverlapThreshold: Double
    /// 逐帧目标框（可选）：画面有位移时，标注随帧移动——否则「角点误差」
    /// 会把**场景自身运动**算成误差。按帧下标对齐；不足时沿用最后一帧。
    var expectedQuads: [Quad]?
    /// 逐帧禁止区域（可选）：同上——相机移动时，禁止区域在画面里的位置也移动。
    var forbiddenRegionsByFrame: [[Quad]]?

    init(
        name: String,
        expectedQuad: Quad,
        forbiddenRegions: [Quad],
        forbiddenOverlapThreshold: Double = 0.5,
        expectedQuads: [Quad]? = nil,
        forbiddenRegionsByFrame: [[Quad]]? = nil
    ) {
        self.name = name
        self.expectedQuad = expectedQuad
        self.forbiddenRegions = forbiddenRegions
        self.forbiddenOverlapThreshold = forbiddenOverlapThreshold
        self.expectedQuads = expectedQuads
        self.forbiddenRegionsByFrame = forbiddenRegionsByFrame
    }

    /// 第 `index` 帧的目标框。
    func expectedQuad(at index: Int) -> Quad {
        guard let expectedQuads, !expectedQuads.isEmpty else { return expectedQuad }
        return expectedQuads[min(index, expectedQuads.count - 1)]
    }

    /// 第 `index` 帧的禁止区域。
    func forbiddenRegions(at index: Int) -> [Quad] {
        guard let forbiddenRegionsByFrame, !forbiddenRegionsByFrame.isEmpty else {
            return forbiddenRegions
        }
        return forbiddenRegionsByFrame[min(index, forbiddenRegionsByFrame.count - 1)]
    }
}

/// 回放帧（与记录来源解耦：trace 与语料都归一到它）。
struct CaptureReplayFrame: Sendable, Equatable {
    /// 帧时刻。
    var timestamp: Date
    /// 生效框（照片空间归一化；nil = 该帧无框）。
    var quad: Quad?
    /// 轨道态（searching / tracking / locked / unknown）。
    var track: String
}

/// 取景回放分析（spec/guided-capture T004）——**纯函数**。
enum CaptureTraceAnalyzer {
    /// 把 trace 帧归一为回放帧（生效框取呈现框，其次裁切框）。
    static func replayFrames(from traces: [CaptureTrace]) -> [CaptureReplayFrame] {
        traces.map { trace in
            CaptureReplayFrame(
                timestamp: trace.timestamp,
                quad: trace.imageQuad ?? trace.cropQuad,
                track: trace.smoother?.track ?? "unknown"
            )
        }
    }

    /// 计算四项指标。
    static func analyze(
        frames: [CaptureReplayFrame],
        annotation: CaptureAnnotation?
    ) -> CaptureReplayMetrics {
        var cornerErrors: [Double] = []
        var forbiddenFrames = 0
        var analyzed = 0
        var lockLatencySeconds: Double?
        var lockLatencyFrames: Int?
        var transitions = 0

        for (index, frame) in frames.enumerated() {
            if index > 0, frames[index - 1].track != frame.track {
                transitions += 1
            }
            if frame.track == "locked", lockLatencyFrames == nil, let first = frames.first {
                lockLatencyFrames = index
                lockLatencySeconds = frame.timestamp.timeIntervalSince(first.timestamp)
            }
            guard let quad = frame.quad else { continue }
            analyzed += 1
            if let annotation {
                cornerErrors.append(
                    cornerError(quad: quad, expected: annotation.expectedQuad(at: index))
                )
                if annotation.forbiddenRegions(at: index).contains(where: { region in
                    region.containment(in: quad) >= annotation.forbiddenOverlapThreshold
                }) {
                    forbiddenFrames += 1
                }
            }
        }

        // 禁止内容入片率只在**有标注**时才有意义（无禁止区域 → 恒 0 会误导）。
        let rate: Double? = annotation == nil
            ? nil
            : (analyzed > 0 ? Double(forbiddenFrames) / Double(analyzed) : nil)
        return CaptureReplayMetrics(
            frameCount: frames.count,
            analyzedQuadCount: analyzed,
            meanCornerError: cornerErrors.isEmpty
                ? nil
                : cornerErrors.reduce(0, +) / Double(cornerErrors.count),
            maxCornerError: cornerErrors.max(),
            forbiddenContentRate: rate,
            forbiddenFrames: forbiddenFrames,
            lockLatencySeconds: lockLatencySeconds,
            lockLatencyFrames: lockLatencyFrames,
            stateTransitions: transitions
        )
    }

    /// 四角误差：四个角点欧氏距离的最大值，按**标注框短边**归一。
    /// 用短边归一是判读口径（SC-004「误差 ≤ 短边 0.5%」同源）。
    static func cornerError(quad: Quad, expected: Quad) -> Double {
        let pairs = [
            (quad.topLeft, expected.topLeft),
            (quad.topRight, expected.topRight),
            (quad.bottomRight, expected.bottomRight),
            (quad.bottomLeft, expected.bottomLeft)
        ]
        let maxDistance = pairs.map { pair in
            hypot(pair.0.x - pair.1.x, pair.0.y - pair.1.y)
        }.max() ?? 0
        let bbox = expected.boundingRect
        let shortSide = min(bbox.width, bbox.height)
        guard shortSide > 0 else { return maxDistance }
        return maxDistance / shortSide
    }
}
