import Foundation

enum QuadTrackState: Equatable, Sendable {
    case searching
    case tracking(Quad)
    case locked(Quad)

    var quad: Quad? {
        switch self {
        case .searching: nil
        case .tracking(let quad), .locked(let quad): quad
        }
    }
}

struct QuadSmoother: Sendable {
    var alpha: Double
    var epsilon: Double
    var lockDuration: TimeInterval
    var frameDt: TimeInterval
    var missLimit: Int
    var areaJump: Double

    private var smoothed: Quad?
    private var stableTime: TimeInterval = 0
    private var missCount = 0
    private var lastArea: Double = 0
    private var isLocked = false

    init(
        alpha: Double = 0.35,
        epsilon: Double = 0.012,
        lockDuration: TimeInterval = 0.55,
        frameDt: TimeInterval = 1.0 / 15.0,
        missLimit: Int = 3,
        areaJump: Double = 0.35
    ) {
        self.alpha = alpha
        self.epsilon = epsilon
        self.lockDuration = lockDuration
        self.frameDt = frameDt
        self.missLimit = missLimit
        self.areaJump = areaJump
    }

    mutating func reset() {
        smoothed = nil
        stableTime = 0
        missCount = 0
        lastArea = 0
        isLocked = false
    }

    mutating func ingest(_ incoming: Quad?) -> QuadTrackState {
        guard let incoming, !incoming.isDegenerate else {
            missCount += 1
            if missCount >= missLimit {
                reset()
                return .searching
            }
            if let smoothed {
                return isLocked ? .locked(smoothed) : .tracking(smoothed)
            }
            return .searching
        }

        missCount = 0
        if let previous = smoothed {
            if lastArea > 0 {
                let change = abs(incoming.area - lastArea) / lastArea
                if change > areaJump {
                    isLocked = false
                    stableTime = 0
                }
            }
            smoothed = previous.interpolated(toward: incoming, alpha: alpha)
            let distance = previous.meanVertexDistance(to: incoming)
            if distance < epsilon {
                stableTime += frameDt
            } else {
                stableTime = 0
                isLocked = false
            }
        } else {
            smoothed = incoming
            stableTime = 0
            isLocked = false
        }

        lastArea = incoming.area
        guard let smoothed else { return .searching }
        if stableTime >= lockDuration {
            isLocked = true
            return .locked(smoothed)
        }
        return .tracking(smoothed)
    }
}
