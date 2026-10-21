import Foundation
import Testing
import UIKit

@testable import Zhixia

/// T002（spec/guided-capture FR-007 / plan D6）：全候选落盘。
///
/// 断言锚点：
/// - **载荷规则**：全部 viable + top 8，硬上限 16，超出记 `droppedCount`；
/// - **字段完整**：每条候选记四角/面积/score/containment/tier/viable；
/// - **回调顺序**：订阅后逐帧发出，顺序 = 检测顺序；
/// - **nil 默认零开销**：未订阅时不构造快照（`latestCandidateSnapshot` 为 nil）。
struct CandidateSnapshotTests {
    /// 矩形候选（四角按 TL,TR,BR,BL）。
    private func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Quad {
        Quad(
            topLeft: CGPoint(x: x0, y: y0),
            topRight: CGPoint(x: x1, y: y0),
            bottomRight: CGPoint(x: x1, y: y1),
            bottomLeft: CGPoint(x: x0, y: y1)
        )
    }

    @Test("全部 viable + top 8 落盘，硬上限 16，超出记 droppedCount")
    func keepsAllViableWithinHardLimit() {
        // 12 个 viable（面积 0.10~0.36）+ 8 个过小候选（面积 < minArea 0.08）。
        var raw: [Quad] = []
        for index in 0..<12 {
            let side = 0.32 + Double(index) * 0.01
            let inset = 0.5 - side / 2
            raw.append(rect(inset, inset, inset + side, inset + side))
        }
        for index in 0..<8 {
            let side = 0.05 + Double(index) * 0.005
            raw.append(rect(0.02, 0.02 + Double(index) * 0.05, 0.02 + side, 0.02 + Double(index) * 0.05 + side))
        }
        #expect(raw.count == 20)

        let snapshot = CandidateSnapshotBuilder.build(
            rawCandidates: raw,
            selection: nil,
            effective: nil,
            disposition: nil,
            path: .live,
            idCardMode: false,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(snapshot.rawCount == 20)
        #expect(snapshot.viableCount == 12)
        #expect(snapshot.candidates.count == 16, "硬上限 16")
        #expect(snapshot.droppedCount == 4, "丢弃必须可数")
        #expect(snapshot.candidates.filter(\.viable).count == 12, "全部 viable 必须保留")
        #expect(snapshot.maxArea == raw.filter { CandidateSnapshotBuilder.isViable($0) }.map(\.area).max())
    }

    @Test("候选不足上限时全部保留，droppedCount = 0")
    func keepsEverythingBelowLimit() {
        let raw = [rect(0.1, 0.1, 0.9, 0.9), rect(0.2, 0.2, 0.8, 0.8)]
        let snapshot = CandidateSnapshotBuilder.build(
            rawCandidates: raw,
            selection: nil,
            effective: nil,
            disposition: nil,
            path: .live,
            idCardMode: false,
            timestamp: Date()
        )
        #expect(snapshot.candidates.count == 2)
        #expect(snapshot.droppedCount == 0)
    }

    @Test("每条候选记四角/面积/score/containment/tier/viable")
    func candidateFieldsAreComplete() {
        let outer = rect(0.1, 0.1, 0.9, 0.9)
        let inner = rect(0.2, 0.2, 0.8, 0.8)
        let snapshot = CandidateSnapshotBuilder.build(
            rawCandidates: [outer, inner],
            selection: nil,
            effective: nil,
            disposition: nil,
            path: .live,
            idCardMode: false,
            timestamp: Date()
        )
        let innerCandidate = try? #require(snapshot.candidates.first { $0.quad == inner })
        let outerCandidate = try? #require(snapshot.candidates.first { $0.quad == outer })
        #expect((innerCandidate?.area ?? 0) > 0.35)
        #expect((innerCandidate?.score ?? 0) > 0)
        #expect((innerCandidate?.containment ?? 0) >= 0.9, "内框被外框包含 → containment ≥0.9")
        #expect((outerCandidate?.containment ?? 1) == 0, "外框不被包含")
        #expect(outerCandidate?.tier == 1)
        #expect(innerCandidate?.viable == true)
    }

    @Test("tier 映射：退化/过小 = 0，一级 <0.96，二级 ≤1.0")
    func tierMapping() {
        #expect(CandidateSnapshotBuilder.tier(of: rect(0.1, 0.1, 0.9, 0.9)) == 1)
        #expect(CandidateSnapshotBuilder.tier(of: rect(0.01, 0.01, 0.99, 0.99)) == 2)
        #expect(CandidateSnapshotBuilder.tier(of: rect(0.4, 0.4, 0.6, 0.6)) == 0, "面积 0.04 < minArea → 不入池")
    }

    @Test("回调顺序：订阅后逐帧发出，顺序 = 检测顺序")
    func detectorEmitsSnapshotsInOrder() async throws {
        let detector = VisionEdgeDetector()
        let collector = SnapshotCollector()
        await detector.setCandidateSnapshotHandler { collector.append($0) }

        let jpeg = Self.syntheticJPEG()
        _ = await detector.detect(imageData: jpeg, idCardWindow: nil)
        _ = await detector.detect(imageData: jpeg, idCardWindow: nil)

        let snapshots = collector.all
        #expect(snapshots.count == 2)
        #expect(snapshots[0].timestamp <= snapshots[1].timestamp)
        #expect(snapshots[0].path == .still)
        let latest = await detector.latestCandidateSnapshot()
        #expect(latest == snapshots.last)
    }

    @Test("nil 默认零开销：未订阅时不构造快照")
    func noHandlerMeansNoSnapshot() async throws {
        let detector = VisionEdgeDetector()
        _ = await detector.detect(imageData: Self.syntheticJPEG(), idCardWindow: nil)
        let latest = await detector.latestCandidateSnapshot()
        #expect(latest == nil)
    }

    /// 合成一张带亮块页面的 JPEG（供检测器跑一遍真实路径）。
    private static func syntheticJPEG() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240))
        let image = renderer.image { context in
            UIColor(white: 0.15, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
            UIColor(white: 0.95, alpha: 1).setFill()
            context.fill(CGRect(x: 60, y: 40, width: 200, height: 160))
        }
        return image.jpegData(compressionQuality: 0.9) ?? Data()
    }
}

/// 快照收集器（回调跨 actor，锁保护）。
private final class SnapshotCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CandidateSnapshot] = []

    func append(_ snapshot: CandidateSnapshot) {
        lock.withLock { storage.append(snapshot) }
    }

    var all: [CandidateSnapshot] {
        lock.withLock { storage }
    }
}
