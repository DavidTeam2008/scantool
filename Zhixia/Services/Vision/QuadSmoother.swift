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
    /// 锁定起点（CU-T004）：锁定后比较**相对锁定起点的累计位移**，
    /// 而不是逐帧差；慢速漂移最终会解锁，正常手持小抖动仍被迟滞吸收。
    private var lockReference: Quad?
    /// 上一帧的真实时间戳（有则用于 dt；测试/旧调用仍可用 frameDt）。
    private var lastTimestamp: TimeInterval?

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
        lockReference = nil
        lastTimestamp = nil
    }

    /// - Parameter timestamp: 真实帧时间（`VideoFrame.timestamp`）。传入时按
    ///   相邻帧真实间隔累计 `stableTime`；nil = 使用 `frameDt`（既有单测语义）。
    mutating func ingest(_ incoming: Quad?, at timestamp: TimeInterval? = nil) -> QuadTrackState {
        // 真实帧率是 29–30fps，旧代码固定 1/15 会把 0.55s 的锁定窗拉成
        // 约 1.1s；这里以真机时间戳为准，并对长停顿做上限保护。
        let step: TimeInterval
        if let timestamp {
            if let lastTimestamp, timestamp > lastTimestamp {
                step = min(max(timestamp - lastTimestamp, 0.0), 0.20)
            } else {
                step = frameDt
            }
            self.lastTimestamp = timestamp
        } else {
            step = frameDt
        }

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
                    lockReference = nil
                    stableTime = 0
                }
            }
            // 累计位移门（CU-T004）：锁定后以锁定起点为参考；慢速漂移不再
            // 被“逐帧差小于阈值”永久粘住。正常抖动仍落在 unlockEpsilon 内。
            if isLocked, let lockReference,
               incoming.meanVertexDistance(to: lockReference) > unlockEpsilon {
                isLocked = false
                self.lockReference = nil
                stableTime = 0
            }
            smoothed = previous.interpolated(toward: incoming, alpha: alpha)
            let distance = previous.meanVertexDistance(to: incoming)
            // 锁定迟滞（spec/scan-enhance）：锁定态用更大的解锁阈值——
            // 小幅抖动不再把白线打回红线（真机「红线/白线高频互跳」）。
            let stableThreshold = isLocked ? max(epsilon, unlockEpsilon) : epsilon
            if distance < stableThreshold {
                stableTime += step
            } else {
                stableTime = 0
                isLocked = false
                lockReference = nil
            }
        } else {
            smoothed = incoming
            stableTime = 0
            isLocked = false
            lockReference = nil
        }

        lastArea = incoming.area
        guard let smoothed else { return .searching }
        if stableTime >= lockDuration {
            if !isLocked {
                lockReference = smoothed
            }
            isLocked = true
            return .locked(smoothed)
        }
        return .tracking(smoothed)
    }
}
