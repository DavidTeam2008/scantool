import Foundation

/// 拍摄时写入 `PageDraft.quad` 的框的角色（CF-T005 / 视频 8 回归修复）。
///
/// Review 的拍后拆分**不能**再用框的宽高比猜“这是目标页还是整摊包络”：
/// 被屏幕裁掉的整摊包络可能和单页一样窄（视频 8：成片 pixel aspect 0.81），
/// 用宽高比猜会把整摊当目标页、跳过拆分，右页就会漏进左页成片。
enum PageQuadRole: String, Codable, Sendable, Hashable {
    /// 快门用的是解析出的左/右页目标框——已经是目标页，Review 不再拆。
    case target
    /// 快门用的是整摊/整书包络（目标页没解析出来）——Review 必须尝试拆分。
    case envelope
}

struct PageDraft: Identifiable, Equatable, Sendable, Hashable {
    var id: UUID
    var sessionID: UUID
    var quad: Quad
    var enhancement: Enhancement
    var rotationTurns: Int
    var userAdjustedQuad: Bool
    var userAdjustedFilter: Bool
    /// CF-T005：拍摄时的左/右页输出意图。nil = 未指定（旧数据/导入/引导框），
    /// Review 保持原有的“整页或手动拆分”语义。整页意图也记 nil，因为包络
    /// 本身就是输出。
    var outputIntent: CaptureIntent?
    /// 拍摄时 `quad` 的角色（目标页 / 整摊包络）。nil = 旧数据或非包络路径，
    /// Review 退回原有的宽高比推断，保证旧草稿行为不变。
    var quadRole: PageQuadRole?

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        quad: Quad,
        enhancement: Enhancement,
        rotationTurns: Int = 0,
        userAdjustedQuad: Bool = false,
        userAdjustedFilter: Bool = false,
        outputIntent: CaptureIntent? = nil,
        quadRole: PageQuadRole? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.quad = quad
        self.enhancement = enhancement
        self.rotationTurns = rotationTurns
        self.userAdjustedQuad = userAdjustedQuad
        self.userAdjustedFilter = userAdjustedFilter
        self.outputIntent = outputIntent
        self.quadRole = quadRole
    }
}
