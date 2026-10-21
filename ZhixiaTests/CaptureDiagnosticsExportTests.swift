import Foundation
import Testing

@testable import Zhixia

/// T003（spec/guided-capture FR-007 / plan D6）：诊断包导出。
///
/// 断言锚点：
/// - 包内含 **trace.json + 低分辨率帧 + 原图 + 截图**（验收 §0-3 的清单）；
/// - zip 结构合法（local header 可解析、条目名与内容正确）——用测试内的最小
///   解析器逐条读回，避免「只写不读」的假绿；
/// - trace.json 是合法 JSON 且能还原成 `CaptureTracePayload`；
/// - **纯本地**：导出过程不触网（实现上零网络依赖——本用例只验证产物完整）。
struct CaptureDiagnosticsExportTests {
    @Test("导出诊断包：JSON + 帧 + 原图 + 截图齐备且结构可解析")
    func exportsCompletePackage() throws {
        let recorder = CaptureTraceRecorder()
        recorder.record(Self.sampleTrace(at: 0))
        recorder.record(Self.sampleTrace(at: 1))
        recorder.recordCandidate(Self.sampleCandidate(at: 0))
        recorder.recordFrameImage(Data([0xAA, 0xBB]), timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        recorder.recordFrameImage(Data([0xCC, 0xDD]), timestamp: Date(timeIntervalSince1970: 1_700_000_001))

        // 原图：临时文件（导出时随包附上）。
        let originalURL = FileManager.default.temporaryDirectory
            .appending(path: "diag-original-\(UUID().uuidString).jpg")
        try Data([0x01, 0x02, 0x03]).write(to: originalURL)
        defer { try? FileManager.default.removeItem(at: originalURL) }
        recorder.recordOriginal(originalURL)

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "diag-package-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let package = try CaptureDiagnosticsExporter.build(
            recorder: recorder,
            screenshot: Data([0x89, 0x50, 0x4E, 0x47]),
            appVersion: "1.2.3",
            deviceModel: "iPhone14,2",
            osVersion: "26.7",
            outputDirectory: directory
        )
        #expect(package.entryCount == 5, "trace.json + 2 帧 + 1 原图 + 1 截图")

        let data = try Data(contentsOf: package.url)
        let entries = try Self.parseLocalHeaders(data)
        #expect(entries["trace.json"] != nil)
        #expect(entries["frames/frame-0001.jpg"] == Data([0xAA, 0xBB]))
        #expect(entries["frames/frame-0002.jpg"] == Data([0xCC, 0xDD]))
        #expect(entries["screenshot.png"] == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(entries.keys.contains { $0.hasPrefix("originals/") })

        // trace.json 必须能还原成载荷（诊断包是 JSON 载体）。
        let json = try #require(entries["trace.json"])
        let decoder = CaptureTraceCoding.makeDecoder()
        let payload = try decoder.decode(CaptureTracePayload.self, from: json)
        #expect(payload.frames.count == 2)
        #expect(payload.candidates.count == 1)
        #expect(payload.appVersion == "1.2.3")
        #expect(payload.deviceModel == "iPhone14,2")
    }

    @Test("空缓冲也能导出（包内只有 trace.json，入口不因无数据而失败）")
    func exportsEmptyPackage() throws {
        let recorder = CaptureTraceRecorder()
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "diag-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = try CaptureDiagnosticsExporter.build(
            recorder: recorder,
            outputDirectory: directory
        )
        #expect(package.entryCount == 1)
        let data = try Data(contentsOf: package.url)
        let entries = try Self.parseLocalHeaders(data)
        #expect(entries.keys.sorted() == ["trace.json"])
    }

    @Test("zip 写入器：CRC32 与条目头合法")
    func zipWriterProducesValidHeader() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "zip-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        let payload = Data("hello".utf8)
        try ZipArchiveWriter.write(
            entries: [ZipArchiveWriter.Entry(path: "a.txt", data: payload)],
            to: url,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try Data(contentsOf: url)
        #expect(data.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]), "local file header 签名")
        let entries = try Self.parseLocalHeaders(data)
        #expect(entries["a.txt"] == payload)
        #expect(CRC32.checksum(payload) == 0x3610A686, "CRC32('hello') 已知值")
    }

    // MARK: - 辅助

    /// 最小 zip 解析器：逐条读 local header（校验签名 + 名称 + 内容）。
    private static func parseLocalHeaders(_ data: Data) throws -> [String: Data] {
        var entries: [String: Data] = [:]
        var offset = 0
        while offset + 30 <= data.count {
            let signature = data.uint32(at: offset)
            guard signature == 0x04034B50 else { break }
            let compressedSize = Int(data.uint32(at: offset + 18))
            let nameLength = Int(data.uint16(at: offset + 26))
            let extraLength = Int(data.uint16(at: offset + 28))
            let nameStart = offset + 30
            let name = String(decoding: data[nameStart..<(nameStart + nameLength)], as: UTF8.self)
            let contentStart = nameStart + nameLength + extraLength
            entries[name] = data.subdata(in: contentStart..<(contentStart + compressedSize))
            offset = contentStart + compressedSize
        }
        return entries
    }

    private static func sampleTrace(at seconds: TimeInterval) -> CaptureTrace {
        CaptureTrace(
            sessionID: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
            phase: "previewing",
            directive: "searching",
            geometry: .init(videoAspect: 0.5625, photoAspect: 0.75),
            previewSize: .init(width: 390, height: 844),
            imageQuad: nil,
            frozenQuad: nil,
            guide: nil,
            cropQuad: nil,
            sticky: nil,
            smoother: .init(track: "tracking", area: 0.4, frameDt: 1.0 / 15.0),
            candidateSnapshot: nil
        )
    }

    private static func sampleCandidate(at seconds: TimeInterval) -> CandidateSnapshot {
        CandidateSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
            path: .live,
            idCardMode: false,
            rawCount: 2,
            viableCount: 1,
            droppedCount: 0,
            maxArea: 0.4,
            selectionArea: 0.4,
            tier: 1,
            disposition: "follow",
            stickyMissCount: 0,
            candidates: []
        )
    }
}

// MARK: - Data 小端读取（zip 全为小端）

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
