import Foundation

struct PageDraft: Identifiable, Equatable, Sendable, Hashable {
    var id: UUID
    var sessionID: UUID
    var quad: Quad
    var enhancement: Enhancement
    var rotationTurns: Int
    var userAdjustedQuad: Bool
    var userAdjustedFilter: Bool

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        quad: Quad,
        enhancement: Enhancement,
        rotationTurns: Int = 0,
        userAdjustedQuad: Bool = false,
        userAdjustedFilter: Bool = false
    ) {
        self.id = id
        self.sessionID = sessionID
        self.quad = quad
        self.enhancement = enhancement
        self.rotationTurns = rotationTurns
        self.userAdjustedQuad = userAdjustedQuad
        self.userAdjustedFilter = userAdjustedFilter
    }
}
