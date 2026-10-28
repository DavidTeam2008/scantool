import Foundation

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

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        quad: Quad,
        enhancement: Enhancement,
        rotationTurns: Int = 0,
        userAdjustedQuad: Bool = false,
        userAdjustedFilter: Bool = false,
        outputIntent: CaptureIntent? = nil,
    ) {
        self.id = id
        self.sessionID = sessionID
        self.quad = quad
        self.enhancement = enhancement
        self.rotationTurns = rotationTurns
        self.userAdjustedQuad = userAdjustedQuad
        self.userAdjustedFilter = userAdjustedFilter
        self.outputIntent = outputIntent
    }
}
