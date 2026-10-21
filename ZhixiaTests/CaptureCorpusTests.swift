import CoreGraphics
import Foundation
import Testing

@testable import Zhixia

/// T004（spec/guided-capture D6 / SC-005）：语料回放基线。
///
/// ## 语料现状（务必读）
/// 规格要求 12–20 个**真实标注**场景；仓库里目前没有真机采集的标注集
/// （真机取证属 T005/V1~V3，会话未做）。因此本文件先落地**可复现的合成语料**
/// + **生产同款纯函数链**（`DetectionStrategy.select` → `CandidateSticky.apply`
/// → `QuadSmoother.ingest` → `CaptureTraceAnalyzer`），把四项指标的口径与
/// 跑法钉死；真机标注集到位后按同一 JSON 格式补入即可（不改断言结构）。
///
/// ## 四类场景（对应折页书主场景的失效模式）
/// 1. `right-page-only`：池里**只有右页**——正对照（链路必须跟住右页）；
/// 2. `spread-plus-right`：整书与右页**同池**——评分偏向整书的主场景；
/// 3. `existence-alternation`：两候选**存在性交替**（spec/case-b-sticky-v2）；
/// 4. `crease-plus-right`：折痕带 + 右页（亚页面候选）。
///
/// 指标口径见 `CaptureTraceAnalyzer`；本文件只断言**结构性事实**与正对照，
/// 主场景的数字只打印（基线留档，不把「当前行为」钉成断言）。
struct CaptureCorpusTests {
    @Test("语料回放：12 个场景跑通纯函数链，四项指标齐备")
    func corpusRunsThroughProductionChain() {
        let scenes = Corpus.scenes()
        #expect(scenes.count >= 12, "规格要求 12–20 个场景")
        #expect(scenes.count <= 20)

        var summary: [String] = []
        for scene in scenes {
            let result = CorpusRunner.run(scene)
            let metrics = result.metrics
            #expect(metrics.frameCount == scene.frames.count)
            #expect(metrics.analyzedQuadCount > 0, "\(scene.name)：应有生效框帧")
            #expect(metrics.stateTransitions >= 0)
            if let rate = metrics.forbiddenContentRate {
                #expect((0...1).contains(rate), "\(scene.name)：入片率必须是 0~1")
            }
            if let error = metrics.meanCornerError {
                #expect(error >= 0, "\(scene.name)：角点误差非负")
            }
            summary.append(
                """
                \(scene.name): frames=\(metrics.frameCount) \
                cornerErr=\(Self.fmt(metrics.meanCornerError)) \
                maxErr=\(Self.fmt(metrics.maxCornerError)) \
                forbidden=\(Self.fmt(metrics.forbiddenContentRate)) \
                lockLatency=\(metrics.lockLatencyFrames.map { String($0) } ?? "-")帧 \
                transitions=\(metrics.stateTransitions)
                """
            )
        }
        // 基线留档：一次 `make test-only T=CaptureCorpusTests` 即可看到全部数字
        // （同时作为 xcresult 附件留档，便于真机会话后对比）。
        let baseline = (["=== CaptureCorpus 基线 ==="] + summary).joined(separator: "\n")
        print(baseline)
        Attachment.record(baseline, named: "capture-corpus-baseline")
    }

    @Test("正对照：池里只有右页时，链路跟住右页且零禁止内容入片")
    func controlSceneTracksRightPage() throws {
        let scenes = Corpus.scenes()
        let scene = try #require(scenes.first { $0.name.hasPrefix("right-page-only") })
        let result = CorpusRunner.run(scene)
        let metrics = result.metrics

        // 生效框必须收敛到右页（角点误差 ≈ 0，相对短边归一）。
        let meanError = try #require(metrics.meanCornerError)
        #expect(meanError < 0.05, "正对照必须跟住右页，实际 \(meanError)")
        // 左页不得入片。
        #expect(metrics.forbiddenFrames == 0)
        // 逐帧稳定 → 必须能锁定。
        #expect(metrics.lockLatencyFrames != nil, "正对照应当锁定")
    }

    /// 数字格式化（nil → "-"）。
    private static func fmt(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: "%.4f", value)
    }
}

// MARK: - 合成语料

/// 语料场景定义。
private struct CorpusScene {
    var name: String
    /// 目标（右页）标注。
    var expectedQuad: Quad
    /// 逐帧目标框（画面位移时随帧移动）。
    var expectedQuads: [Quad]
    /// 禁止入片区域（左页、折痕带）。
    var forbiddenRegions: [Quad]
    /// 逐帧禁止区域（相机移动 → 禁止区域在画面里的位置也移动）。
    var forbiddenRegionsByFrame: [[Quad]]
    /// 逐帧候选（模拟检测器输出）。
    var frames: [[Quad]]
}

/// 合成场景库（真实标注集到位后按同结构替换）。
private enum Corpus {
    /// 整书外框。
    static let spread = Quad(
        topLeft: CGPoint(x: 0.08, y: 0.10),
        topRight: CGPoint(x: 0.95, y: 0.10),
        bottomRight: CGPoint(x: 0.95, y: 0.92),
        bottomLeft: CGPoint(x: 0.08, y: 0.92)
    )
    /// 右页。
    static let rightPage = Quad(
        topLeft: CGPoint(x: 0.52, y: 0.12),
        topRight: CGPoint(x: 0.94, y: 0.12),
        bottomRight: CGPoint(x: 0.94, y: 0.90),
        bottomLeft: CGPoint(x: 0.52, y: 0.90)
    )
    /// 左页（禁止入片）。
    static let leftPage = Quad(
        topLeft: CGPoint(x: 0.09, y: 0.12),
        topRight: CGPoint(x: 0.48, y: 0.12),
        bottomRight: CGPoint(x: 0.48, y: 0.90),
        bottomLeft: CGPoint(x: 0.09, y: 0.90)
    )
    /// 折痕带（禁止入片；面积 0.031 < minArea → 不入 viable 池）。
    static let crease = Quad(
        topLeft: CGPoint(x: 0.49, y: 0.12),
        topRight: CGPoint(x: 0.53, y: 0.12),
        bottomRight: CGPoint(x: 0.53, y: 0.90),
        bottomLeft: CGPoint(x: 0.49, y: 0.90)
    )

    /// 场景库：4 类 × 3 个漂移方向 = 12 个。
    static func scenes() -> [CorpusScene] {
        var scenes: [CorpusScene] = []
        let frameCount = 14
        let directions: [Double] = [-1, 0, 1]

        for direction in directions {
            // ① 正对照：池里只有右页。
            let drift = driftSequence(count: frameCount, direction: direction)
            scenes.append(
                CorpusScene(
                    name: "right-page-only-\(direction)",
                    expectedQuad: rightPage,
                    expectedQuads: drift.map { rightPage.shifted(dx: $0) },
                    forbiddenRegions: [leftPage],
                    forbiddenRegionsByFrame: drift.map { [leftPage.shifted(dx: $0)] },
                    frames: drift.map { [rightPage.shifted(dx: $0)] }
                )
            )
        }

        for direction in directions {
            // ② 整书 + 右页同池（评分偏向整书 → 左页入片）。
            let drift = driftSequence(count: frameCount, direction: direction)
            scenes.append(
                CorpusScene(
                    name: "spread-plus-right-\(direction)",
                    expectedQuad: rightPage,
                    expectedQuads: drift.map { rightPage.shifted(dx: $0) },
                    forbiddenRegions: [leftPage],
                    forbiddenRegionsByFrame: drift.map { [leftPage.shifted(dx: $0)] },
                    frames: drift.map { d in
                        [spread.shifted(dx: d), rightPage.shifted(dx: d)]
                    }
                )
            )
        }

        for direction in directions {
            // ③ 存在性交替（一帧只有右页、一帧只有整书）。
            let drift = driftSequence(count: frameCount, direction: direction)
            scenes.append(
                CorpusScene(
                    name: "existence-alternation-\(direction)",
                    expectedQuad: rightPage,
                    expectedQuads: drift.map { rightPage.shifted(dx: $0) },
                    forbiddenRegions: [leftPage],
                    forbiddenRegionsByFrame: drift.map { [leftPage.shifted(dx: $0)] },
                    frames: drift.enumerated().map { index, d in
                        index % 2 == 0
                            ? [rightPage.shifted(dx: d)]
                            : [spread.shifted(dx: d)]
                    }
                )
            )
        }

        for direction in directions {
            // ④ 折痕带 + 右页（折痕带面积过小 → 不入池）。
            let drift = driftSequence(count: frameCount, direction: direction)
            scenes.append(
                CorpusScene(
                    name: "crease-plus-right-\(direction)",
                    expectedQuad: rightPage,
                    expectedQuads: drift.map { rightPage.shifted(dx: $0) },
                    forbiddenRegions: [leftPage, crease],
                    forbiddenRegionsByFrame: drift.map { d in
                        [leftPage.shifted(dx: d), crease.shifted(dx: d)]
                    },
                    frames: drift.map { d in
                        [crease.shifted(dx: d), rightPage.shifted(dx: d)]
                    }
                )
            )
        }

        return scenes
    }

    /// 逐帧位移（每帧 0.0015，远小于 smoother 的 epsilon 0.012 → 仍可锁定）。
    private static func driftSequence(count: Int, direction: Double) -> [Double] {
        (0..<count).map { index in direction * 0.0015 * Double(index) }
    }
}

/// 语料跑批器——**生产同款纯函数链**（参数与 `VisionEdgeDetector` 调用点一致）。
private enum CorpusRunner {
    static func run(_ scene: CorpusScene) -> (frames: [CaptureReplayFrame], metrics: CaptureReplayMetrics) {
        var sticky = CandidateSticky()
        var smoother = QuadSmoother(unlockEpsilon: 0.03)
        var frames: [CaptureReplayFrame] = []
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for (index, candidates) in scene.frames.enumerated() {
            let selection = DetectionStrategy.select(rawCandidates: candidates, idCardWindow: nil)
            let gated = sticky.apply(
                selection: selection,
                pool: DetectionStrategy.viablePool(candidates),
                similarityThreshold: 0.70,
                missLimit: 5,
                holdThroughMiss: true,
                anchorMinArea: 0.12,
                reanchorConfirmFrames: 3,
                followMinAreaRatio: 0.8
            )
            let track = smoother.ingest(gated?.quad)
            frames.append(
                CaptureReplayFrame(
                    timestamp: base.addingTimeInterval(Double(index) / 15.0),
                    quad: track.quad,
                    track: CaptureTrace.trackName(track)
                )
            )
        }

        let annotation = CaptureAnnotation(
            name: scene.name,
            expectedQuad: scene.expectedQuad,
            forbiddenRegions: scene.forbiddenRegions,
            expectedQuads: scene.expectedQuads,
            forbiddenRegionsByFrame: scene.forbiddenRegionsByFrame
        )
        let metrics = CaptureTraceAnalyzer.analyze(frames: frames, annotation: annotation)
        return (frames, metrics)
    }
}

/// 测试内的小工具：整体平移四边形。
private extension Quad {
    func shifted(dx: Double) -> Quad {
        Quad(
            topLeft: CGPoint(x: topLeft.x + dx, y: topLeft.y),
            topRight: CGPoint(x: topRight.x + dx, y: topRight.y),
            bottomRight: CGPoint(x: bottomRight.x + dx, y: bottomRight.y),
            bottomLeft: CGPoint(x: bottomLeft.x + dx, y: bottomLeft.y)
        )
    }
}
