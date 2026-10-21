import Foundation
import Testing

@testable import Zhixia

/// T001（spec/guided-capture FR-007 / plan D6）：trace 数据模型 + debug 环形缓冲。
///
/// 断言锚点：
/// - **环形覆盖**：默认只保留最近 10s（时间戳口径），旧帧必须被淘汰；
/// - **Codable round-trip**：诊断包是 JSON 载体，字段必须逐个还原（含候选快照）；
/// - **release 空实现**：采集开关按构建配置暴露，release 不采集（编译期开关）。
struct CaptureTraceTests {
    /// 构造一帧 trace（时间戳可控，便于测窗口淘汰）。
    private func trace(
        at seconds: TimeInterval,
        phase: String = "previewing",
        candidate: CandidateSnapshot? = nil
    ) -> CaptureTrace {
        CaptureTrace(
            sessionID: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
            phase: phase,
            directive: "searching",
            geometry: .init(videoAspect: 0.5625, photoAspect: 0.75),
            previewSize: .init(width: 390, height: 844),
            imageQuad: Quad(
                topLeft: CGPoint(x: 0.1, y: 0.1),
                topRight: CGPoint(x: 0.9, y: 0.1),
                bottomRight: CGPoint(x: 0.9, y: 0.9),
                bottomLeft: CGPoint(x: 0.1, y: 0.9)
            ),
            frozenQuad: nil,
            guide: nil,
            cropQuad: nil,
            sticky: .init(disposition: "follow", missCount: 2),
            smoother: .init(track: "tracking", area: 0.64, frameDt: 1.0 / 15.0),
            candidateSnapshot: candidate
        )
    }

    /// 候选快照（最小可用载荷）。
    private func candidate(at seconds: TimeInterval) -> CandidateSnapshot {
        CandidateSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
            path: .live,
            idCardMode: false,
            rawCount: 3,
            viableCount: 2,
            droppedCount: 0,
            maxArea: 0.64,
            selectionArea: 0.64,
            tier: 1,
            disposition: "follow",
            stickyMissCount: 2,
            candidates: [
                CandidateSnapshot.Candidate(
                    quad: Quad(
                        topLeft: CGPoint(x: 0.1, y: 0.1),
                        topRight: CGPoint(x: 0.9, y: 0.1),
                        bottomRight: CGPoint(x: 0.9, y: 0.9),
                        bottomLeft: CGPoint(x: 0.1, y: 0.9)
                    ),
                    area: 0.64,
                    score: 0.55,
                    containment: 0,
                    tier: 1,
                    viable: true
                )
            ]
        )
    }

    @Test("环形覆盖：超出保留窗口（10s）的旧帧被淘汰")
    func ringEvictsFramesOutsideWindow() {
        let recorder = CaptureTraceRecorder()
        for second in 0...15 {
            recorder.record(trace(at: TimeInterval(second)))
        }
        let frames = recorder.recordedFrames
        // 窗口 10s：最新帧 t=15 → 保留 t∈[5,15] 共 11 帧。
        #expect(frames.count == 11)
        #expect(frames.first?.timestamp == Date(timeIntervalSince1970: 1_700_000_005))
        #expect(frames.last?.timestamp == Date(timeIntervalSince1970: 1_700_000_015))
    }

    @Test("环形覆盖：条数上限生效（内存不无界）")
    func ringRespectsFrameCap() {
        let recorder = CaptureTraceRecorder(retention: 3600, maxFrames: 5)
        for second in 0...20 {
            recorder.record(trace(at: TimeInterval(second)))
        }
        let frames = recorder.recordedFrames
        #expect(frames.count == 5)
        #expect(frames.first?.timestamp == Date(timeIntervalSince1970: 1_700_000_016))
    }

    @Test("候选快照与低分辨率帧同窗口淘汰")
    func candidatesAndImagesEvict() {
        let recorder = CaptureTraceRecorder()
        for second in 0...12 {
            recorder.recordCandidate(candidate(at: TimeInterval(second)))
        }
        recorder.recordFrameImage(Data([0x01]), timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        recorder.recordFrameImage(
            Data([0x02]),
            timestamp: Date(timeIntervalSince1970: 1_700_000_012)
        )
        // 候选窗口 10s → 保留 t∈[2,12] 共 11 条。
        #expect(recorder.recordedCandidates.count == 11)
        // 低分辨率帧窗口 5s → 只剩最后一张。
        #expect(recorder.recordedFrameImages.count == 1)
        #expect(recorder.recordedFrameImages.first == Data([0x02]))
    }

    @Test("Codable round-trip：trace 与 payload 逐字段还原")
    func codableRoundTrip() throws {
        let original = trace(at: 1, phase: "locked", candidate: candidate(at: 1))
        let encoder = CaptureTraceCoding.makeEncoder()
        let data = try encoder.encode(original)
        let decoder = CaptureTraceCoding.makeDecoder()
        let decoded = try decoder.decode(CaptureTrace.self, from: data)
        #expect(decoded == original)
        #expect(decoded.candidateSnapshot == original.candidateSnapshot)
        #expect(decoded.sticky == original.sticky)
        #expect(decoded.smoother == original.smoother)

        let recorder = CaptureTraceRecorder()
        recorder.record(original)
        recorder.recordCandidate(candidate(at: 1))
        let payload = recorder.payload(appVersion: "1.0", deviceModel: "iPhone13,1", osVersion: "26.7")
        let payloadData = try encoder.encode(payload)
        let decodedPayload = try decoder.decode(CaptureTracePayload.self, from: payloadData)
        #expect(decodedPayload.frames == payload.frames)
        #expect(decodedPayload.candidates == payload.candidates)
        #expect(decodedPayload.deviceModel == "iPhone13,1")
    }

    @Test("采集开关：debug 构建支持，release 为编译期空实现")
    func supportFlagFollowsBuildConfiguration() {
        #if DEBUG
        #expect(CaptureTraceRecorder.isSupported)
        #else
        #expect(!CaptureTraceRecorder.isSupported)
        #endif
    }

    @Test("清空：会话结束/导出后可复位缓冲")
    func clearResetsBuffers() {
        let recorder = CaptureTraceRecorder()
        recorder.record(trace(at: 0))
        recorder.recordCandidate(candidate(at: 0))
        recorder.recordFrameImage(Data([0x00]))
        recorder.clear()
        #expect(recorder.recordedFrames.isEmpty)
        #expect(recorder.recordedCandidates.isEmpty)
        #expect(recorder.recordedFrameImages.isEmpty)
    }
}
