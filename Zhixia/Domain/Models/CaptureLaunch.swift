import Foundation

/// 拍摄入口：新开一页，或追加到已有文档。
///
/// 只承担路由身份；页面草稿与阶段状态由 `CaptureViewModel` 自己持有，
/// 不再维护第二份 `ScanSession` 快照（2026-10-29 清理，原类型无任何调用）。
enum CaptureLaunch: Identifiable, Hashable, Sendable {
    case fresh
    case append(UUID)

    var id: String {
        switch self {
        case .fresh: "fresh"
        case .append(let documentID): documentID.uuidString
        }
    }

    var documentID: UUID? {
        switch self {
        case .fresh: nil
        case .append(let documentID): documentID
        }
    }
}
