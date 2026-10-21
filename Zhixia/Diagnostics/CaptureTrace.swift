import CoreGraphics
import Foundation

/// 取景诊断 trace（spec/guided-capture T001 / FR-007）——**每帧一行**的事实快照。
///
/// ## 为什么需要
/// 折页书主场景连续多个周期未达效，所有复盘都卡在同一个问题上：*框为什么
/// 锁在这里*。当时的证据只有 `detectionTier` / `candidateProvenance` 这类
/// **汇总量**（多少候选、多大面积），看不到「这一帧池里到底有哪些框、各自
/// 四角与评分、粘滞把它改成了谁、冻结框有没有动」。trace 把这些事实按帧
/// 固化，诊断包导出后即可离线回放（T004）。
///
/// ## 字段口径（FR-007）
/// - 每帧：`timestamp` / `phase` / `directive` / `previewSize` / `geometry`；
/// - 引导框（照片空间 + 屏幕空间）与 canvas round-trip 误差（`guide`）；
/// - 裁切四角（`cropQuad`，成片真正的裁切来源）；
/// - 呈现框（`imageQuad`）与冻结框（`frozenQuad`）；
/// - 粘滞输出（`sticky`：disposition + miss 计数）与平滑器输出（`smoother`）；
/// - 候选快照（`candidateSnapshot`：全部 viable + top 8，硬上限 16）。
///
/// 纯数据、`Codable`；release 构建不采集（见 `CaptureTraceRecorder`）。
struct CaptureTrace: Codable, Equatable, Sendable {
    /// 载荷版本（诊断包跨版本可读性的锚）。
    static let currentSchemaVersion = 1

    /// 运行时几何（视频/照片竖屏宽高比）。
    struct Geometry: Codable, Equatable, Sendable {
        var videoAspect: Double
        var photoAspect: Double
    }

    /// 视图尺寸（像素）。
    struct Size: Codable, Equatable, Sendable {
        var width: Double
        var height: Double
    }

    /// 引导框事实（照片空间为**真值**，屏幕空间为派生渲染值）。
    struct Guide: Codable, Equatable, Sendable {
        /// 照片空间四边形（裁切真值）。
        var photoQuad: Quad
        /// 屏幕空间四边形（用户看到的）。
        var screenQuad: Quad?
        /// 画布 round-trip 误差（相对短边；>0.005 即判失败，SC-004）。
        var roundTripError: Double?
    }

    /// 粘滞事实（`CandidateSticky` 的判定去向与 miss 计数）。
    struct Sticky: Codable, Equatable, Sendable {
        /// 判定去向（`Disposition` 的 raw value）。
        var disposition: String
        /// 连续 miss 计数。
        var missCount: Int
    }

    /// 平滑器事实（`QuadSmoother` 的轨道态与输出面积）。
    struct Smoother: Codable, Equatable, Sendable {
        /// 轨道态：searching / tracking / locked。
        var track: String
        /// 平滑后面积（无框 = nil）。
        var area: Double?
        /// 帧间隔（秒）——锁定判据是逐帧差，时间戳必须同源可读。
        var frameDt: Double
    }

    /// 载荷版本。
    var schemaVersion: Int = CaptureTrace.currentSchemaVersion
    /// 会话标识（同一会话的帧可归并）。
    var sessionID: UUID?
    /// 帧时刻。
    var timestamp: Date
    /// 取景相位（idle / previewing / locked / capturing）。
    var phase: String
    /// 引导判定（backOff / closer / locked / searching）。
    var directive: String
    /// 运行时几何。
    var geometry: Geometry
    /// 取景视图尺寸。
    var previewSize: Size
    /// 呈现框（屏幕所见的框，照片空间）。
    var imageQuad: Quad?
    /// 冻结框（锁定态的呈现框，照片空间）。
    var frozenQuad: Quad?
    /// 引导框（引导模式；自动模式为 nil）。
    var guide: Guide?
    /// 裁切四角（成片裁切真值，照片空间）。
    var cropQuad: Quad?
    /// 粘滞事实。
    var sticky: Sticky?
    /// 平滑器事实。
    var smoother: Smoother?
    /// 本帧候选快照。
    var candidateSnapshot: CandidateSnapshot?
}

/// 诊断包内的 trace 载荷（trace 帧 + 候选快照 + 环境信息）。
///
/// 导出结构固定：`frames`（逐帧事实）+ `candidates`（逐帧候选快照）——
/// 后者是 T002 的落盘主体（V2 验证「右页是否在池」直接读它）。
struct CaptureTracePayload: Codable, Equatable, Sendable {
    /// 载荷版本。
    var schemaVersion: Int = CaptureTrace.currentSchemaVersion
    /// 导出时刻。
    var generatedAt: Date
    /// App 版本（Bundle 版本号；缺省为空串）。
    var appVersion: String
    /// 设备型号。
    var deviceModel: String
    /// 系统版本。
    var osVersion: String
    /// 逐帧事实。
    var frames: [CaptureTrace]
    /// 逐帧候选快照。
    var candidates: [CandidateSnapshot]
}

// MARK: - 枚举名映射（诊断字段用稳定字符串，不泄漏 Swift 枚举布局）

extension CaptureTrace {
    /// 取景相位名（idle / previewing / locked / capturing）。
    static func phaseName(_ phase: CapturePhase) -> String {
        switch phase {
        case .idle: return "idle"
        case .previewing: return "previewing"
        case .locked: return "locked"
        case .capturing: return "capturing"
        }
    }

    /// 引导判定名（backOff / closer / locked / searching）。
    static func directiveName(_ directive: GuidanceDirective) -> String {
        switch directive {
        case .backOff: return "backOff"
        case .closer: return "closer"
        case .locked: return "locked"
        case .searching: return "searching"
        }
    }

    /// 平滑器轨道态名（searching / tracking / locked）。
    static func trackName(_ track: QuadTrackState) -> String {
        switch track {
        case .searching: return "searching"
        case .tracking: return "tracking"
        case .locked: return "locked"
        }
    }
}
