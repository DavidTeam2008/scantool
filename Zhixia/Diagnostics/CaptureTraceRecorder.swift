import Foundation

/// 取景 trace 环形缓冲（spec/guided-capture T001 / FR-007）——debug 采集容器。
///
/// ## 语义
/// - **默认保留最近 10s**（`retention`）：按帧自身时间戳淘汰，与墙钟无关
///   （回放时时间戳才是判读依据）；
/// - 另有条数硬上限（`maxFrames`）防内存无界；
/// - 候选快照、低分辨率帧、原图 URL 同缓冲管理（导出诊断包用）；
/// - **release 构建为编译期空实现**：`storage` 相关成员整段 `#if DEBUG`
///   编译掉 → release 既不持存储、也不产生任何逐帧分配（FR-007「trace 仅
///   debug 生效；release 不采集、不增加每帧分配」）。
///
/// 线程安全：写入方跨 actor（检测器 actor 发候选快照、MainActor 写帧），
/// 用一把 `NSLock` 串行化；读取返回拷贝。
final class CaptureTraceRecorder: @unchecked Sendable {
    /// 当前构建是否支持诊断采集（release = false）。
    static var isSupported: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// 帧保留窗口（秒）：默认最近 10s。
    static let defaultRetention: TimeInterval = 10
    /// 帧保留条数上限（环形缓冲硬上限）。
    static let defaultMaxFrames = 600
    /// 低分辨率帧保留窗口（秒）：诊断包要「最近 5s」。
    static let defaultFrameRetention: TimeInterval = 5
    /// 低分辨率帧保留条数上限。
    static let defaultMaxFrameImages = 90
    /// 原图 URL 保留条数上限（导出包附最近若干张原图）。
    static let defaultMaxOriginals = 8

    private let retention: TimeInterval
    private let maxFrames: Int
    private let frameRetention: TimeInterval
    private let maxFrameImages: Int
    private let maxOriginals: Int

    #if DEBUG
    private let lock = NSLock()
    private var frames: [CaptureTrace] = []
    private var candidates: [CandidateSnapshot] = []
    private var frameImages: [(timestamp: Date, data: Data)] = []
    private var originals: [URL] = []
    #endif

    init(
        retention: TimeInterval = CaptureTraceRecorder.defaultRetention,
        maxFrames: Int = CaptureTraceRecorder.defaultMaxFrames,
        frameRetention: TimeInterval = CaptureTraceRecorder.defaultFrameRetention,
        maxFrameImages: Int = CaptureTraceRecorder.defaultMaxFrameImages,
        maxOriginals: Int = CaptureTraceRecorder.defaultMaxOriginals
    ) {
        self.retention = retention
        self.maxFrames = maxFrames
        self.frameRetention = frameRetention
        self.maxFrameImages = maxFrameImages
        self.maxOriginals = maxOriginals
    }

    // MARK: - 写入（release 为 no-op）

    /// 记一帧事实。
    func record(_ trace: CaptureTrace) {
        #if DEBUG
        lock.withLock {
            frames.append(trace)
            pruneFramesLocked()
        }
        #endif
    }

    /// 记一帧候选快照（T002 的落盘主体）。
    func recordCandidate(_ snapshot: CandidateSnapshot) {
        #if DEBUG
        lock.withLock {
            candidates.append(snapshot)
            pruneCandidatesLocked()
        }
        #endif
    }

    /// 记一帧低分辨率预览（诊断包「最近 5s 帧」的来源）。
    func recordFrameImage(_ data: Data, timestamp: Date = Date()) {
        #if DEBUG
        lock.withLock {
            frameImages.append((timestamp: timestamp, data: data))
            pruneFrameImagesLocked()
        }
        #endif
    }

    /// 记一张原图（快门写盘后的文件 URL；诊断包随包附上）。
    func recordOriginal(_ url: URL) {
        #if DEBUG
        lock.withLock {
            originals.append(url)
            if originals.count > maxOriginals {
                originals.removeFirst(originals.count - maxOriginals)
            }
        }
        #endif
    }

    // MARK: - 读取

    /// 已记录的帧（按时间升序）。
    var recordedFrames: [CaptureTrace] {
        #if DEBUG
        return lock.withLock { frames }
        #else
        return []
        #endif
    }

    /// 已记录的候选快照（按时间升序）。
    var recordedCandidates: [CandidateSnapshot] {
        #if DEBUG
        return lock.withLock { candidates }
        #else
        return []
        #endif
    }

    /// 保留的低分辨率帧（按时间升序）。
    var recordedFrameImages: [Data] {
        #if DEBUG
        return lock.withLock { frameImages.map(\.data) }
        #else
        return []
        #endif
    }

    /// 记录的原图 URL。
    var recordedOriginals: [URL] {
        #if DEBUG
        return lock.withLock { originals }
        #else
        return []
        #endif
    }

    /// 导出载荷（JSON 化的输入）。
    func payload(
        appVersion: String = "",
        deviceModel: String = "",
        osVersion: String = ""
    ) -> CaptureTracePayload {
        #if DEBUG
        return lock.withLock {
            CaptureTracePayload(
                generatedAt: Date(),
                appVersion: appVersion,
                deviceModel: deviceModel,
                osVersion: osVersion,
                frames: frames,
                candidates: candidates
            )
        }
        #else
        return CaptureTracePayload(
            generatedAt: Date(),
            appVersion: appVersion,
            deviceModel: deviceModel,
            osVersion: osVersion,
            frames: [],
            candidates: []
        )
        #endif
    }

    /// 清空缓冲（会话结束 / 导出后）。
    func clear() {
        #if DEBUG
        lock.withLock {
            frames.removeAll()
            candidates.removeAll()
            frameImages.removeAll()
            originals.removeAll()
        }
        #endif
    }

    // MARK: - 淘汰（DEBUG 内部）

    #if DEBUG
    /// 按时间窗口 + 条数上限淘汰（保留窗口内最新的若干条）。
    private func pruneFramesLocked() {
        guard let newest = frames.last?.timestamp else { return }
        let cutoff = newest.addingTimeInterval(-retention)
        frames.removeAll { $0.timestamp < cutoff }
        if frames.count > maxFrames {
            frames.removeFirst(frames.count - maxFrames)
        }
    }

    private func pruneCandidatesLocked() {
        guard let newest = candidates.last?.timestamp else { return }
        let cutoff = newest.addingTimeInterval(-retention)
        candidates.removeAll { $0.timestamp < cutoff }
        if candidates.count > maxFrames {
            candidates.removeFirst(candidates.count - maxFrames)
        }
    }

    private func pruneFrameImagesLocked() {
        guard let newest = frameImages.last?.timestamp else { return }
        let cutoff = newest.addingTimeInterval(-frameRetention)
        frameImages.removeAll { $0.timestamp < cutoff }
        if frameImages.count > maxFrameImages {
            frameImages.removeFirst(frameImages.count - maxFrameImages)
        }
    }
    #endif
}
