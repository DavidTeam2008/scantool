import CoreGraphics
import Foundation
import Testing
import UIKit

@testable import Zhixia

/// Phase 1 引导取景（spec/guided-capture T013 / T014 / T015 / FR-002、FR-004~006）。
///
/// 断言锚点（**构造性事实**，不是阈值）：
/// - 引导路径**零 detector 调用**（逐帧与快门静帧都不跑）——FR-005 / SC-002；
/// - 成片 = 引导框（`PageDraft.quad` 与引导框同一坐标），`userAdjustedQuad`
///   = true（复用既有字段 → Review 跳过自动重检/拆分）——FR-005；
/// - 没有合法框就不拍（不猜、不静默全幅）——spec 边界；
/// - 拍摄后框保持（连续拍摄用同一框）——FR-002；
/// - 自动对位只跑**一次** detector，无候选 no-op，可撤销一次——FR-006；
/// - 非法拖动（自交/过小）被拒绝，保留上一有效框——D3；
/// - 框生命周期：切模式 / 画布变化重置，证件模式不显示引导——D3 / T015。
@MainActor
struct GuidedCaptureTests {
    // MARK: - 辅助

    private func makeViewModel(
        detector: any EdgeDetecting,
        camera: any CameraCapturing = GuidedCamera(),
        preferences: PreferencesStore? = nil
    ) -> CaptureViewModel {
        let defaults = UserDefaults(suiteName: "zhixia.guided.\(UUID().uuidString)") ?? .standard
        return CaptureViewModel(
            launch: .fresh,
            camera: camera,
            detector: detector,
            fileStore: PageFileStore(
                root: FileManager.default.temporaryDirectory.appending(path: "guided-\(UUID().uuidString)")
            ),
            permissions: PreviewPermissions(),
            preferences: preferences ?? PreferencesStore(defaults: defaults)
        )
    }

    /// 进入引导模式并等到默认框就绪。
    private func enterGuided(_ viewModel: CaptureViewModel) async {
        await viewModel.start()
        viewModel.previewSize = CGSize(width: 390, height: 844)
        viewModel.setCaptureMode(.guided)
    }

    // MARK: - T014 引导拍摄

    @Test("引导拍摄：成片 = 引导框、零 detector 调用、userAdjustedQuad = true")
    func guidedCaptureUsesGuideQuad() async throws {
        let detector = CountingDetector(liveQuad: nil, stillQuad: nil)
        let viewModel = makeViewModel(detector: detector)
        await enterGuided(viewModel)

        let guide = try #require(viewModel.guidePhotoQuad)
        await viewModel.capture()

        #expect(viewModel.drafts.count == 1)
        #expect(viewModel.drafts.first?.quad == guide, "成片裁切框必须与引导框同源")
        #expect(viewModel.drafts.first?.userAdjustedQuad == true)
        #expect(await detector.liveCount == 0, "引导路径不得跑逐帧检测")
        #expect(await detector.stillCount == 0, "引导路径不得重检静帧")
    }

    @Test("引导拍摄后框保持（连续拍摄用同一个框）")
    func guideSurvivesCapture() async throws {
        let detector = CountingDetector(liveQuad: nil, stillQuad: nil)
        let viewModel = makeViewModel(detector: detector)
        await enterGuided(viewModel)

        let guide = try #require(viewModel.guidePhotoQuad)
        await viewModel.capture()
        await viewModel.capture()

        #expect(viewModel.drafts.count == 2)
        #expect(viewModel.drafts.allSatisfy { $0.quad == guide })
        #expect(viewModel.guidePhotoQuad == guide, "拍摄后不得重置引导框")
    }

    @Test("没有合法引导框就不拍（不猜、不静默全幅）")
    func guidedCaptureWithoutGuideDoesNothing() async {
        let detector = CountingDetector(liveQuad: nil, stillQuad: nil)
        let viewModel = makeViewModel(detector: detector)
        await viewModel.start()
        // 画布未就绪（previewSize 仍为 .zero）→ 没有默认框。
        viewModel.setCaptureMode(.guided)
        #expect(viewModel.guidePhotoQuad == nil)
        #expect(viewModel.isGuideReady == false)

        await viewModel.capture()
        #expect(viewModel.drafts.isEmpty)
    }

    @Test("引导模式不跑逐帧检测（帧只留作自动对位的输入）")
    func guidedModeSkipsPerFrameDetection() async throws {
        let camera = GuidedCamera()
        let detector = CountingDetector(liveQuad: Quad(
            topLeft: CGPoint(x: 0.1, y: 0.1),
            topRight: CGPoint(x: 0.9, y: 0.1),
            bottomRight: CGPoint(x: 0.9, y: 0.9),
            bottomLeft: CGPoint(x: 0.1, y: 0.9)
        ), stillQuad: nil)
        let viewModel = makeViewModel(detector: detector, camera: camera)
        await enterGuided(viewModel)

        for _ in 0..<3 { await camera.yieldFrame() }
        try? await Task.sleep(nanoseconds: 300_000_000)

        #expect(await detector.liveCount == 0, "引导模式不得逐帧检测")
        #expect(viewModel.imageQuad == nil, "引导模式不显示自动框")
    }

    // MARK: - T013 自动对位 / 撤销

    @Test("自动对位：只跑一次 detector，替换框后可撤销一次")
    func autoFitReplacesAndUndoes() async throws {
        let camera = GuidedCamera()
        let detected = Quad(
            topLeft: CGPoint(x: 0.1, y: 0.1),
            topRight: CGPoint(x: 0.9, y: 0.1),
            bottomRight: CGPoint(x: 0.9, y: 0.9),
            bottomLeft: CGPoint(x: 0.1, y: 0.9)
        )
        let detector = CountingDetector(liveQuad: detected, stillQuad: nil)
        let viewModel = makeViewModel(detector: detector, camera: camera)
        await enterGuided(viewModel)

        let before = try #require(viewModel.guidePhotoQuad)
        for _ in 0..<2 { await camera.yieldFrame() }
        try? await Task.sleep(nanoseconds: 300_000_000)

        await viewModel.autoFitGuide()
        #expect(await detector.liveCount == 1, "自动对位只跑一次 detector")
        let after = try #require(viewModel.guidePhotoQuad)
        #expect(after != before, "对位应替换框")

        #expect(viewModel.canUndoAutoFit)
        viewModel.undoAutoFit()
        #expect(viewModel.guidePhotoQuad == before, "撤销回到对位前")
        #expect(viewModel.canUndoAutoFit == false, "撤销只有一次")
    }

    @Test("自动对位：无候选时 no-op（框不变、不崩溃）")
    func autoFitWithoutCandidateIsNoop() async throws {
        let camera = GuidedCamera()
        let detector = CountingDetector(liveQuad: nil, stillQuad: nil)
        let viewModel = makeViewModel(detector: detector, camera: camera)
        await enterGuided(viewModel)

        let before = try #require(viewModel.guidePhotoQuad)
        await camera.yieldFrame()
        try? await Task.sleep(nanoseconds: 200_000_000)

        await viewModel.autoFitGuide()
        #expect(viewModel.guidePhotoQuad == before, "无候选不得改变框")
        #expect(viewModel.canUndoAutoFit == false)
    }

    @Test("非法拖动被拒绝：自交框与过小框都保留上一有效框")
    func invalidDragIsRejected() async throws {
        let detector = CountingDetector(liveQuad: nil, stillQuad: nil)
        let viewModel = makeViewModel(detector: detector)
        await enterGuided(viewModel)

        let before = try #require(viewModel.guidePhotoQuad)

        // ① 自交四边形（屏幕空间）。
        let crossed = Quad(
            topLeft: CGPoint(x: 100, y: 100),
            topRight: CGPoint(x: 300, y: 300),
            bottomRight: CGPoint(x: 100, y: 300),
            bottomLeft: CGPoint(x: 300, y: 100)
        )
        viewModel.updateGuide(fromScreenQuad: crossed)
        #expect(viewModel.guidePhotoQuad == before, "自交框必须被拒绝")

        // ② 过小框（短边 < 8%）。
        let tiny = Quad(
            topLeft: CGPoint(x: 180, y: 400),
            topRight: CGPoint(x: 190, y: 400),
            bottomRight: CGPoint(x: 190, y: 410),
            bottomLeft: CGPoint(x: 180, y: 410)
        )
        viewModel.updateGuide(fromScreenQuad: tiny)
        #expect(viewModel.guidePhotoQuad == before, "过小框必须被拒绝")
    }

    @Test("合法拖动生效（框跟随更新）")
    func validDragUpdatesGuide() async throws {
        let detector = CountingDetector(liveQuad: nil, stillQuad: nil)
        let viewModel = makeViewModel(detector: detector)
        await enterGuided(viewModel)

        let before = try #require(viewModel.guidePhotoQuad)
        // 把左上角往右下挪一点（保持凸性、面积仍够大）。
        let moved = Quad(
            topLeft: CGPoint(x: 200, y: 120),
            topRight: CGPoint(x: 380, y: 110),
            bottomRight: CGPoint(x: 380, y: 800),
            bottomLeft: CGPoint(x: 200, y: 810)
        )
        viewModel.updateGuide(fromScreenQuad: moved)
        let after = try #require(viewModel.guidePhotoQuad)
        #expect(after != before, "合法拖动必须更新框")
    }

    // MARK: - T015 框生命周期

    @Test("生命周期：证件模式不显示引导；切回文档恢复默认框；画布变化重置框")
    func guideLifecycle() async throws {
        let detector = CountingDetector(liveQuad: nil, stillQuad: nil)
        let viewModel = makeViewModel(detector: detector)
        await enterGuided(viewModel)

        let guide = try #require(viewModel.guidePhotoQuad)
        #expect(viewModel.isGuideReady)

        // 切证件模式 → 引导 UI 消失、框清空。
        viewModel.setMode(.idCard)
        #expect(viewModel.guidePhotoQuad == nil)
        #expect(viewModel.isGuideReady == false)

        // 切回文档 → 恢复默认框。
        viewModel.setMode(.document)
        #expect(viewModel.guidePhotoQuad != nil)

        // 画布几何变化 → 旧框失效（否则成片会裁到别处）。
        viewModel.previewSize = CGSize(width: 390, height: 700)
        #expect(viewModel.guidePhotoQuad != guide)
    }

    @Test("默认框按拍摄意图：右页 / 左页 / 整页位置不同")
    func defaultGuideFollowsIntent() async throws {
        let detector = CountingDetector(liveQuad: nil, stillQuad: nil)
        let viewModel = makeViewModel(detector: detector)
        await enterGuided(viewModel)

        let right = try #require(viewModel.guidePhotoQuad)
        viewModel.setCaptureIntent(.leftPage)
        let left = try #require(viewModel.guidePhotoQuad)
        #expect(left.topLeft.x < right.topLeft.x, "左页默认框应在更左侧")
        #expect(left != right)

        viewModel.setCaptureIntent(.wholePage)
        let whole = try #require(viewModel.guidePhotoQuad)
        #expect(whole.area > right.area, "整页默认框应更大")
    }
}

// MARK: - 替身

/// 可逐帧喂投的相机（引导模式用）：固定几何 + 平面图。
private final class GuidedCamera: CameraCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<VideoFrame>.Continuation?
    private var frameIndex = 0
    private let geometryValue: CaptureGeometry

    init(geometry: CaptureGeometry = CaptureGeometry(videoAspect: 0.5625, photoAspect: 0.75)) {
        self.geometryValue = geometry
    }

    func start() async throws {}
    func stop() async {}
    func capturePhoto() async throws -> CapturedPhoto {
        CapturedPhoto(jpegData: PreviewImages.jpeg(), pixelSize: CGSize(width: 810, height: 1080))
    }
    func setTorch(enabled: Bool) async throws {}
    func setFlashAuto(_ enabled: Bool) async {}

    var frames: AsyncStream<VideoFrame> {
        AsyncStream { continuation in
            self.lock.withLock { self.continuation = continuation }
        }
    }

    func geometry() async -> CaptureGeometry { geometryValue }

    func yieldFrame() async {
        let image = Self.plainImage
        while true {
            let continuation = lock.withLock { self.continuation }
            if let continuation {
                frameIndex += 1
                continuation.yield(VideoFrame(cgImage: image, timestamp: TimeInterval(frameIndex) / 15.0))
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private static let plainImage: CGImage = {
        let width = 8
        let height = 14
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }()
}

/// 计数检测器：记录 live/still 调用次数，返回可配置结果。
private actor CountingDetector: EdgeDetecting {
    private let liveQuad: Quad?
    private let stillQuad: Quad?
    private(set) var liveCount = 0
    private(set) var stillCount = 0

    init(liveQuad: Quad?, stillQuad: Quad?) {
        self.liveQuad = liveQuad
        self.stillQuad = stillQuad
    }

    func detect(frame: VideoFrame, idCardWindow: Quad?) async -> Quad? {
        liveCount += 1
        return liveQuad
    }

    func detect(imageData: Data, idCardWindow: Quad?) async -> Quad? {
        stillCount += 1
        return stillQuad
    }
}
