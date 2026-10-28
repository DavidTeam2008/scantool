import CoreGraphics
import Foundation
import Testing

@testable import Zhixia

/// CF-T003：包络跟踪器的纯状态测试（不依赖相机/Vision）。
struct CaptureEnvelopeTrackerTests {
    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Quad {
        Quad(
            topLeft: CGPoint(x: x, y: y),
            topRight: CGPoint(x: x + w, y: y),
            bottomRight: CGPoint(x: x + w, y: y + h),
            bottomLeft: CGPoint(x: x, y: y + h)
        )
    }

    private func observation(_ quad: Quad, target: Quad? = nil) -> CaptureEnvelopeObservation {
        CaptureEnvelopeObservation(
            envelope: quad,
            target: target,
            confidence: 0.8,
            intentSatisfied: target != nil
        )
    }

    @Test("稳定包络在锁定时长内进入 locked")
    func locksStableEnvelope() {
        var tracker = CaptureEnvelopeTracker()
        let quad = rect(0.08, 0.1, 0.84, 0.8)
        var state = CaptureEnvelopeTracker.State.searching
        for index in 0..<24 {
            state = tracker.ingest(observation(quad), at: Double(index) / 30.0)
        }
        #expect(state.phase == .locked)
        #expect(state.envelope != nil)
        #expect(state.isHolding == false)
    }

    @Test("检测短暂缺失时保持包络，超过 holdDuration 才回搜索")
    func holdsThroughDetectionGap() {
        var tracker = CaptureEnvelopeTracker()
        let quad = rect(0.08, 0.1, 0.84, 0.8)
        _ = tracker.ingest(observation(quad), at: 0)
        let held = tracker.ingest(nil, at: 0.20)
        #expect(held.envelope == quad)
        #expect(held.isHolding)
        #expect(held.phase == .tracking)

        let expired = tracker.ingest(nil, at: 0.80)
        #expect(expired.phase == .searching)
        #expect(expired.envelope == nil)
    }

    @Test("观测跳到另一个页面时先保持旧包络，确认后才平滑切换")
    func doesNotJumpImmediatelyToDifferentCandidate() {
        var tracker = CaptureEnvelopeTracker()
        let spread = rect(0.02, 0.05, 0.96, 0.88)
        let page = rect(0.50, 0.08, 0.46, 0.82)
        _ = tracker.ingest(observation(spread), at: 0)
        _ = tracker.ingest(observation(spread), at: 0.10)

        // 第一帧看到完全不同的小页面：不能瞬移。
        let first = tracker.ingest(observation(page), at: 0.20)
        #expect(first.envelope == spread)
        #expect(first.isHolding == false)
        #expect(first.phase == .tracking)

        // 连续确认超过 switchConfirmDuration 后，开始向新包络平滑靠拢。
        let confirmed = tracker.ingest(observation(page), at: 0.55)
        #expect(confirmed.envelope != spread)
        #expect(confirmed.envelope != page, "切换必须经过平滑，不是瞬移")
    }

    @Test("目标页失联时回退到包络，不把旧目标当成输出")
    func clearsStaleTarget() {
        var tracker = CaptureEnvelopeTracker()
        let envelope = rect(0.02, 0.05, 0.96, 0.88)
        let target = rect(0.50, 0.08, 0.46, 0.82)
        let first = tracker.ingest(observation(envelope, target: target), at: 0)
        #expect(first.target == target)

        let missingTarget = CaptureEnvelopeObservation(
            envelope: envelope,
            target: nil,
            confidence: 0.7,
            intentSatisfied: false
        )
        let after = tracker.ingest(missingTarget, at: 0.10)
        #expect(after.target == nil)
        #expect(after.envelope == envelope)
    }

    @Test("reset 清空包络和目标")
    func resetClearsState() {
        var tracker = CaptureEnvelopeTracker()
        let quad = rect(0.08, 0.1, 0.84, 0.8)
        _ = tracker.ingest(observation(quad, target: quad), at: 0)
        tracker.reset()
        #expect(tracker.ingest(nil, at: 1.0) == .searching)
    }
}
