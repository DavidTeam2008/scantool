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
    /// 解除锁定的位移阈值（顶点平均距离）：锁定后需**更大**的移动才解锁
    /// （spec/scan-enhance：红线/白线高频互跳 = 锁定被小幅抖动反复打断）。
    /// 默认等于 epsilon（既有语义不变）。
    var unlockEpsilon: Double
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
        unlockEpsilon: Double = 0.012,
        lockDuration: TimeInterval = 0.55,
        frameDt: TimeInterval = 1.0 / 15.0,
        missLimit: Int = 3,
        areaJump: Double = 0.35
    ) {
        self.alpha = alpha
        self.epsilon = epsilon
        self.unlockEpsilon = unlockEpsilon
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
            // 锁定迟滞（spec/scan-enhance）：锁定态用更大的解锁阈值——
            // 小幅抖动不再把白线打回红线（真机「红线/白线高频互跳」）。
            let stableThreshold = isLocked ? max(epsilon, unlockEpsilon) : epsilon
            if distance < stableThreshold {
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
