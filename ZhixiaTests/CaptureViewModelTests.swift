import CoreGraphics
import Foundation
import Testing
@testable import Zhixia

@MainActor
struct CaptureViewModelTests {
    @Test("Finish is blocked when there are no pages")
    func finishRequiresPages() async {
        let viewModel = makeViewModel()
        #expect(viewModel.finish() == nil)
        #expect(viewModel.canFinish == false)
    }

    @Test("A captured page allows finish")
    func captureThenFinish() async throws {
        let viewModel = makeViewModel()
        await viewModel.importImageData(PreviewImages.jpeg())
        #expect(viewModel.drafts.count == 1)
        #expect(viewModel.finish()?.count == 1)
    }

    private func makeViewModel() -> CaptureViewModel {
        let defaults = UserDefaults(suiteName: "zhixia.capture.\(UUID().uuidString)") ?? .standard
        return CaptureViewModel(
            launch: .fresh,
            camera: PreviewCamera(),
            detector: PreviewDetector(),
            fileStore: PageFileStore(root: FileManager.default.temporaryDirectory.appending(path: "cap-\(UUID().uuidString)")),
            permissions: PreviewPermissions(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }
}

@MainActor
struct ReviewViewModelTests {
    @Test("Save writes a document and clears tmp")
    func savePersists() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "rev-\(UUID().uuidString)")
        let files = PageFileStore(root: root)
        let store = InMemoryDocumentStore()
        let session = UUID()
        let page = UUID()
        let jpeg = PreviewImages.jpeg()
        _ = try await files.writeOriginal(session: session, page: page, data: jpeg)
        let defaults = UserDefaults(suiteName: "zhixia.review.\(UUID().uuidString)") ?? .standard
        let viewModel = ReviewViewModel(
            drafts: [PageDraft(id: page, sessionID: session, quad: .fullImage, enhancement: .original)],
            sessionID: session,
            appendToDocumentID: nil,
            renderer: ImagePipeline(),
            detector: PreviewDetector(),
            fileStore: files,
            documentStore: store,
            preferences: PreferencesStore(defaults: defaults)
        )
        let documentID = await viewModel.save()
        #expect(documentID != nil)
        let listed = try await store.documents(query: "", folderID: nil, favoritesOnly: false)
        #expect(listed.count == 1)
        #expect(!FileManager.default.fileExists(atPath: files.originalURL(session: session, page: page).path))
    }

    @Test("Empty drafts cannot save")
    func emptyCannotSave() async {
        let defaults = UserDefaults(suiteName: "zhixia.review.empty.\(UUID().uuidString)") ?? .standard
        let viewModel = ReviewViewModel(
            drafts: [],
            sessionID: UUID(),
            appendToDocumentID: nil,
            renderer: ImagePipeline(),
            detector: PreviewDetector(),
            fileStore: PageFileStore(root: FileManager.default.temporaryDirectory),
            documentStore: InMemoryDocumentStore(),
            preferences: PreferencesStore(defaults: defaults)
        )
        #expect(viewModel.canSave == false)
        let id = await viewModel.save()
        #expect(id == nil)
    }

    @Test("Filter and rotate leave crop mode so the preview can update")
    func filterLeavesCrop() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "rev-crop-\(UUID().uuidString)")
        let files = PageFileStore(root: root)
        let session = UUID()
        let page = UUID()
        _ = try await files.writeOriginal(session: session, page: page, data: PreviewImages.jpeg())
        let defaults = UserDefaults(suiteName: "zhixia.review.crop.\(UUID().uuidString)") ?? .standard
        let viewModel = ReviewViewModel(
            drafts: [PageDraft(id: page, sessionID: session, quad: .fullImage, enhancement: .original)],
            sessionID: session,
            appendToDocumentID: nil,
            renderer: ImagePipeline(),
            detector: PreviewDetector(),
            fileStore: files,
            documentStore: InMemoryDocumentStore(),
            preferences: PreferencesStore(defaults: defaults)
        )
        viewModel.beginCrop()
        #expect(viewModel.isAdjustingCrop)
        viewModel.setFilter(.grayscale)
        #expect(viewModel.isAdjustingCrop == false)
        viewModel.beginCrop()
        viewModel.rotate()
        #expect(viewModel.isAdjustingCrop == false)
    }

    @Test("Auto refine never overwrites a user-adjusted quad")
    func autoRefineSkipsUserAdjustedQuad() async throws {
        // US4（spec/live-edge-crop，FR-005）：用户拖过角的页语义不回退——
        // appear() 触发的自动 refine 必须跳过 userAdjustedQuad = true 的页。
        let root = FileManager.default.temporaryDirectory.appending(path: "rev-refine-\(UUID().uuidString)")
        let files = PageFileStore(root: root)
        let session = UUID()
        let userPage = UUID()
        let autoPage = UUID()
        _ = try await files.writeOriginal(session: session, page: userPage, data: PreviewImages.jpeg())
        _ = try await files.writeOriginal(session: session, page: autoPage, data: PreviewImages.jpeg())

        let userQuad = Quad(
            topLeft: CGPoint(x: 0.05, y: 0.06),
            topRight: CGPoint(x: 0.95, y: 0.04),
            bottomRight: CGPoint(x: 0.94, y: 0.96),
            bottomLeft: CGPoint(x: 0.06, y: 0.95)
        )
        // PreviewDetector 的 still 固定框（refine 会写入未手动调过的页）。
        let refinedQuad = Quad(
            topLeft: CGPoint(x: 0.1, y: 0.1),
            topRight: CGPoint(x: 0.9, y: 0.12),
            bottomRight: CGPoint(x: 0.88, y: 0.9),
            bottomLeft: CGPoint(x: 0.08, y: 0.88)
        )
        #expect(refinedQuad != userQuad)
        #expect(refinedQuad != Quad.fullImage)

        let defaults = UserDefaults(suiteName: "zhixia.review.refine.\(UUID().uuidString)") ?? .standard
        let viewModel = ReviewViewModel(
            drafts: [
                PageDraft(id: userPage, sessionID: session, quad: userQuad, enhancement: .original, userAdjustedQuad: true),
                PageDraft(id: autoPage, sessionID: session, quad: .fullImage, enhancement: .original)
            ],
            sessionID: session,
            appendToDocumentID: nil,
            renderer: ImagePipeline(),
            detector: PreviewDetector(),
            fileStore: files,
            documentStore: InMemoryDocumentStore(),
            preferences: PreferencesStore(defaults: defaults)
        )

        // appear() → refineQuads() → renderSelected()：以预览渲染完成为信号
        // 等待后台任务跑完（refine 在渲染之前同步执行）。
        viewModel.appear()
        #expect(await waitUntil { viewModel.previewImage != nil })

        // 用户调过的框原样保留（不被自动 refine 覆盖）。
        #expect(viewModel.drafts.first { $0.id == userPage }?.quad == userQuad)
        #expect(viewModel.drafts.first { $0.id == userPage }?.userAdjustedQuad == true)
        // 对照组：未手动调过的全幅页被 refine 更新——证明 refine 确实执行，
        // 上一条的「跳过」不是 refine 空转的假绿。
        #expect(viewModel.drafts.first { $0.id == autoPage }?.quad == refinedQuad)
    }

    private func waitUntil(
        _ condition: @escaping () -> Bool,
        timeout: TimeInterval = 3
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}

// MARK: - US3 快门回退链三分支（spec/live-edge-crop，plan D5 / FR-004）

/// `capture()` 的 `detected ?? imageQuad ?? .fullImage` 回退链以替身钉死三分支：
/// ① still 重检成功 → 成片用重检框（精度优先）；
/// ② still 失败、live 有框 → 成片用 live 框（三级兜底填上的中间层）；
/// ③ 双失败 → 全幅（US4 兜底：预览页手动调框接手）。
/// 本套件**零源码改动**——纯测试锚定既有语义，防未来回归（D5 设计意图）。
@MainActor
struct CaptureFallbackChainTests {
    @Test("Still re-detect success: the page is cropped with the re-detected quad")
    func stillRedetectWins() async throws {
        let detector = ChainDetector(liveQuad: ChainQuads.live, stillQuad: ChainQuads.still)
        let viewModel = makeViewModel(detector: detector)

        await viewModel.start()
        #expect(await waitUntil { viewModel.imageQuad != nil })
        await viewModel.capture()

        // 分支 ①：精度优先，still 重检框胜出（与 live 框的细微差异已被用户接受）。
        #expect(viewModel.drafts.count == 1)
        #expect(viewModel.drafts.first?.quad == ChainQuads.still)
    }

    @Test("Still re-detect failure: the page falls back to the live quad")
    func stillFailureFallsBackToLiveQuad() async throws {
        let detector = ChainDetector(liveQuad: ChainQuads.live, stillQuad: nil)
        let viewModel = makeViewModel(detector: detector)

        await viewModel.start()
        #expect(await waitUntil { viewModel.imageQuad != nil })
        let liveQuad = try #require(viewModel.imageQuad)
        await viewModel.capture()

        // 分支 ②：快门重检失败 → 回退 live 框（恒等几何下原样入库）。
        #expect(viewModel.drafts.count == 1)
        #expect(viewModel.drafts.first?.quad == liveQuad)
        #expect(viewModel.drafts.first?.quad == ChainQuads.live)
    }

    @Test("Both live and still detection fail: the page keeps the full image")
    func doubleFailureFallsBackToFullImage() async throws {
        let detector = ChainDetector(liveQuad: nil, stillQuad: nil)
        let viewModel = makeViewModel(detector: detector)

        await viewModel.start()
        try? await Task.sleep(nanoseconds: 150_000_000)
        // 三级检测后仍完全无框（极端曲面/光照场景）——live 中间层为空。
        #expect(viewModel.imageQuad == nil)
        await viewModel.capture()

        // 分支 ③：手动快门照拍全幅，预览页四角调框兜底（FR-005）。
        #expect(viewModel.drafts.count == 1)
        #expect(viewModel.drafts.first?.quad == .fullImage)
    }

    // MARK: - Helpers

    private func makeViewModel(detector: any EdgeDetecting) -> CaptureViewModel {
        let defaults = UserDefaults(suiteName: "zhixia.chain.\(UUID().uuidString)") ?? .standard
        let preferences = PreferencesStore(defaults: defaults)
        // 与自动快门解耦：回退链由手动快门触发（autoCapture 默认开，须显式关）。
        preferences.autoCapture = false
        return CaptureViewModel(
            launch: .fresh,
            camera: ChainCamera(),
            detector: detector,
            fileStore: PageFileStore(
                root: FileManager.default.temporaryDirectory.appending(path: "chain-\(UUID().uuidString)")
            ),
            permissions: PreviewPermissions(),
            preferences: preferences
        )
    }

    private func waitUntil(
        _ condition: @escaping () -> Bool,
        timeout: TimeInterval = 3
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}

// MARK: - 快门链替身（文件私有，与 CaptureFallbackTests 的脚手架互不影响）

/// 恒等几何 + 两帧脚本相机：live 帧驱动 `imageQuad`，快门返回固定 JPEG。
private final class ChainCamera: CameraCapturing, @unchecked Sendable {
    func start() async throws {}
    func stop() async {}

    func capturePhoto() async throws -> CapturedPhoto {
        CapturedPhoto(
            jpegData: PreviewImages.jpeg(),
            pixelSize: CGSize(width: 80, height: 100)
        )
    }

    func setTorch(enabled: Bool) async throws {}
    func setFlashAuto(_ enabled: Bool) async {}

    var frames: AsyncStream<VideoFrame> {
        AsyncStream { continuation in
            let image = ChainCamera.plainImage
            for index in 0..<2 {
                continuation.yield(VideoFrame(cgImage: image, timestamp: TimeInterval(index) / 15.0))
            }
            continuation.finish()
        }
    }

    func geometry() async -> CaptureGeometry { .identity }

    private static let plainImage: CGImage = {
        let width = 8
        let height = 14
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }()
}

/// 可注入 live/still 结果的快门链检测器替身。
private actor ChainDetector: EdgeDetecting {
    private let liveQuad: Quad?
    private let stillQuad: Quad?

    init(liveQuad: Quad?, stillQuad: Quad?) {
        self.liveQuad = liveQuad
        self.stillQuad = stillQuad
    }

    func detect(frame: VideoFrame, idCardWindow: Quad?) async -> Quad? { liveQuad }
    func detect(imageData: Data, idCardWindow: Quad?) async -> Quad? { stillQuad }
}

private enum ChainQuads {
    /// live 框（恒等几何下视频空间 = 照片空间）。
    static let live = Quad(
        topLeft: CGPoint(x: 0.15, y: 0.1),
        topRight: CGPoint(x: 0.85, y: 0.12),
        bottomRight: CGPoint(x: 0.83, y: 0.9),
        bottomLeft: CGPoint(x: 0.17, y: 0.88)
    )

    /// 快门 still 重检框（与 live 框刻意不同，暴露回退层级）。
    static let still = Quad(
        topLeft: CGPoint(x: 0.1, y: 0.08),
        topRight: CGPoint(x: 0.9, y: 0.1),
        bottomRight: CGPoint(x: 0.88, y: 0.92),
        bottomLeft: CGPoint(x: 0.12, y: 0.9)
    )
}

// MARK: - US2 自动快门锁定确认窗（spec/overlay-frame-visibility，plan D2 / FR-005~007）

/// 确认窗节奏行为穷举：fake camera/detector 逐帧驱动（锁定需 ~9 稳定帧——
/// QuadSmoother lockDuration 0.55s / frameDt 1/15：帧 1 初始化平滑框、帧 2~10
/// 累计 9×1/15s = 0.6s ≥ 0.55s → 第 10 帧锁定）；阈值经 init 注入小值穷举
/// 边界。以检测器 live 计数为帧消费同步点，相位之间断言钉死四条语义：
/// 阈值前不拍 / 窗内解锁取消且重锁重计 / suspicious 帧冻结 / 手动快门不受限。
@MainActor
struct AutoCaptureHoldWindowTests {
    @Test("Auto-capture waits for the full hold window of locked frames before firing")
    func autoCaptureWaitsForHoldFramesBeforeCapture() async throws {
        let (viewModel, camera, detector) = makeFixture(holdFrames: 3)

        await viewModel.start()
        // 恒定正常框 ×10 → 第 10 帧锁定，确认窗计数 1。
        await feed(10, camera: camera, detector: detector)
        #expect(viewModel.overlayIsLocked)
        #expect(viewModel.drafts.isEmpty)

        // 锁定后第 2 帧（累计 2 < 3）：确认窗未满——不得拍摄。
        await feed(1, camera: camera, detector: detector)
        #expect(viewModel.drafts.isEmpty)

        // 锁定后第 3 帧（累计 3 ≥ 阈值）：确认窗计满，自动拍摄。
        await feed(1, camera: camera, detector: detector)
        #expect(await waitUntil { viewModel.drafts.count == 1 })
    }

    @Test("Unlock inside the hold window cancels the shot; relocking restarts the window")
    func holdWindowResetsOnUnlock() async throws {
        let (viewModel, camera, detector) = makeFixture(holdFrames: 4)

        await viewModel.start()
        await feed(10, camera: camera, detector: detector)
        #expect(viewModel.overlayIsLocked)
        #expect(viewModel.drafts.isEmpty)

        // 失锁（3 帧无检测）：前 2 帧 smoother 仍报锁定（短暂遮挡保持语义），
        // 第 3 帧进入 searching——窗内解锁即取消本次拍摄；计数最高 3 < 4 未拍。
        await detector.setLiveQuad(nil)
        await feed(3, camera: camera, detector: detector)
        #expect(viewModel.overlayIsLocked == false)
        #expect(viewModel.drafts.isEmpty)

        // 重新锁定（10 帧后）+ 2 帧锁定：计数从 0 重新起算，累计 3 < 4——
        // 不得拍摄（若解锁时未清零，重锁首帧即 3+1=4 达阈而抢先拍摄）。
        await detector.setLiveQuad(HoldWindowQuads.document)
        await feed(12, camera: camera, detector: detector)
        #expect(viewModel.overlayIsLocked)
        #expect(viewModel.drafts.isEmpty)

        // 计满 4 帧非可疑锁定 → 自动拍摄（重新锁定重新计时后正常完成）。
        await feed(1, camera: camera, detector: detector)
        #expect(await waitUntil { viewModel.drafts.count == 1 })
    }

    @Test("Suspicious locked frames freeze the hold count instead of advancing it")
    func suspiciousLockFreezesHoldCount() async throws {
        // 门限附近微移对（HoldWindowQuads）：锁定态内翻转可疑性且**不解锁**
        //（均值顶点距离 0.01 < epsilon 0.012）——冻结语义唯一的可观测路径。
        let (viewModel, camera, detector) = makeFixture(
            holdFrames: 4,
            liveQuad: HoldWindowQuads.marginallyNormal
        )

        await viewModel.start()
        await feed(10, camera: camera, detector: detector)
        #expect(viewModel.overlayIsLocked)
        #expect(viewModel.drafts.isEmpty)

        // 切入可疑输入的第 1 帧：平滑框仍在门限内侧（非可疑），计数 +1 → 2。
        await detector.setLiveQuad(HoldWindowQuads.marginallySuspicious)
        await feed(1, camera: camera, detector: detector)
        #expect(viewModel.drafts.isEmpty)

        // 可疑锁定帧 ×3：计数冻结（不增不清零），抑制提示置位。
        await feed(3, camera: camera, detector: detector)
        #expect(viewModel.isAutoCaptureSuppressed)
        #expect(viewModel.drafts.isEmpty)

        // 切回正常输入的第 1 帧：平滑框仍可疑（左移余量 0.0147 < 0.015）→
        // 快门门禁拦截，计数维持冻结。
        await detector.setLiveQuad(HoldWindowQuads.marginallyNormal)
        await feed(1, camera: camera, detector: detector)
        #expect(viewModel.drafts.isEmpty)

        // 清除后的第 1 个非可疑锁定帧：计数 3 < 4，仍不拍——冻结语义锚点
        //（若可疑帧被错误计入，此处计数早已 ≥ 阈值而抢先拍摄）。
        await feed(1, camera: camera, detector: detector)
        #expect(viewModel.isAutoCaptureSuppressed == false)
        #expect(viewModel.drafts.isEmpty)

        // 满 4 帧非可疑锁定（锁定帧、切入帧、清除后 ×2）→ 自动拍摄。
        await feed(1, camera: camera, detector: detector)
        #expect(await waitUntil { viewModel.drafts.count == 1 })
    }

    @Test("Manual shutter works immediately inside the hold window and resets the count")
    func manualCaptureDuringHoldWindowWorks() async throws {
        let (viewModel, camera, detector) = makeFixture(holdFrames: 3)

        await viewModel.start()
        // 锁定 + 1 帧（累计 2 < 3）：确认窗开着，自动快门在等待。
        await feed(11, camera: camera, detector: detector)
        #expect(viewModel.overlayIsLocked)
        #expect(viewModel.drafts.isEmpty)

        // 窗内手动快门：立即拍摄，不受确认窗限制（FR-007）。
        await viewModel.capture()
        #expect(viewModel.drafts.count == 1)

        // 拍后复位：重新锁定（10 帧）+ 1 帧，窗口从 0 起算仅累计 2 < 3——
        // 不得自动补拍（若 capture() 未清零，重锁首帧即 2+1=3 达阈而补拍）。
        await feed(11, camera: camera, detector: detector)
        #expect(viewModel.drafts.count == 1)

        // 再累计满窗（第 3 帧非可疑锁定）→ 自动快门恢复正常。
        await feed(1, camera: camera, detector: detector)
        #expect(await waitUntil { viewModel.drafts.count == 2 })
    }

    // MARK: - Helpers

    private func makeFixture(
        holdFrames: Int,
        liveQuad: Quad? = HoldWindowQuads.document
    ) -> (viewModel: CaptureViewModel, camera: HoldWindowCamera, detector: HoldWindowDetector) {
        let defaults = UserDefaults(suiteName: "zhixia.holdwindow.\(UUID().uuidString)") ?? .standard
        let preferences = PreferencesStore(defaults: defaults)
        preferences.autoCapture = true
        let camera = HoldWindowCamera()
        let detector = HoldWindowDetector(liveQuad: liveQuad)
        let viewModel = CaptureViewModel(
            launch: .fresh,
            camera: camera,
            detector: detector,
            fileStore: PageFileStore(
                root: FileManager.default.temporaryDirectory.appending(path: "holdwindow-\(UUID().uuidString)")
            ),
            permissions: PreviewPermissions(),
            preferences: preferences,
            autoCaptureHoldFrames: holdFrames
        )
        return (viewModel, camera, detector)
    }

    /// 喂 N 帧并等待全部被 ViewModel 消费（以检测器 live 计数为同步点），
    /// 再留一小段稳定时间让 consume 的检测后段（计数/快门判定）跑完。
    private func feed(
        _ count: Int,
        camera: HoldWindowCamera,
        detector: HoldWindowDetector
    ) async {
        let before = await detector.liveDetectCount
        for _ in 0..<count {
            await camera.yieldFrame()
        }
        let target = before + count
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await detector.liveDetectCount >= target { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    private func waitUntil(
        _ condition: @escaping () -> Bool,
        timeout: TimeInterval = 3
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}

// MARK: - 确认窗替身（文件私有，与其他脚手架互不影响）

/// 可逐帧喂投的确认窗相机：测试按相位手动 `yieldFrame()`，帧流经
/// continuation 长驻供给——与 ScriptedCamera 的预载帧流不同，手动快门
/// 用例需要「先拍、后继续喂帧」的分段控制。
private final class HoldWindowCamera: CameraCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<VideoFrame>.Continuation?
    private var frameIndex = 0

    func start() async throws {}
    func stop() async {}

    func capturePhoto() async throws -> CapturedPhoto {
        CapturedPhoto(
            jpegData: PreviewImages.jpeg(),
            pixelSize: CGSize(width: 80, height: 100)
        )
    }

    func setTorch(enabled: Bool) async throws {}
    func setFlashAuto(_ enabled: Bool) async {}

    var frames: AsyncStream<VideoFrame> {
        AsyncStream { continuation in
            self.lock.withLock {
                self.continuation = continuation
            }
        }
    }

    func geometry() async -> CaptureGeometry { .identity }

    /// 喂一帧（时间戳按 1/15s 递增，与 fake 时钟口径一致）。帧流尚未被
    /// 消费端建立时（listenToFrames 的 Task 调度窗口）稍候重试。
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
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }()
}

/// 确认窗检测器：live 结果可切换（正常/可疑/失锁）；live 检测计数即
/// 「已被 ViewModel 消费的帧数」，用作喂帧同步点。still 恒失败 → 快门
/// 回退链走 live 框分支（与 CaptureFallbackChainTests 分支 ② 同语义）。
private actor HoldWindowDetector: EdgeDetecting {
    private var liveQuad: Quad?
    private(set) var liveDetectCount = 0

    init(liveQuad: Quad?) {
        self.liveQuad = liveQuad
    }

    func setLiveQuad(_ quad: Quad?) {
        liveQuad = quad
    }

    func detect(frame: VideoFrame, idCardWindow: Quad?) async -> Quad? {
        liveDetectCount += 1
        return liveQuad
    }

    func detect(imageData: Data, idCardWindow: Quad?) async -> Quad? { nil }
}

private enum HoldWindowQuads {
    /// 常规文档框（非可疑）：边距 ≥ 8%，面积 ≈ 0.65（与
    /// CaptureFallbackTests.TestQuads.document 同形态，恒等几何专用）。
    static let document = Quad(
        topLeft: CGPoint(x: 0.1, y: 0.12),
        topRight: CGPoint(x: 0.9, y: 0.1),
        bottomRight: CGPoint(x: 0.88, y: 0.9),
        bottomLeft: CGPoint(x: 0.08, y: 0.88)
    )

    /// 门限附近微移对（suspicious 冻结用例专用）：两者仅整体左移 1%，
    /// 均值顶点距离 0.01 < epsilon（0.012）——锁定态内切换**不解锁**；
    /// normal 左边距 2% > 1.5%（非可疑），suspicious 左边距 1% < 1.5%
    ///（可疑，minMargin 0.01 < edgeMargin 0.015）。可疑性作用于 smoother
    /// 输出的**平滑框**，切换有 1 帧收敛滞后——用例帧预算已按轨迹核算。
    static let marginallyNormal = Quad(
        topLeft: CGPoint(x: 0.02, y: 0.1),
        topRight: CGPoint(x: 0.98, y: 0.1),
        bottomRight: CGPoint(x: 0.98, y: 0.9),
        bottomLeft: CGPoint(x: 0.02, y: 0.9)
    )

    static let marginallySuspicious = Quad(
        topLeft: CGPoint(x: 0.01, y: 0.1),
        topRight: CGPoint(x: 0.97, y: 0.1),
        bottomRight: CGPoint(x: 0.97, y: 0.9),
        bottomLeft: CGPoint(x: 0.01, y: 0.9)
    )
}

// MARK: - US1/US2 快门裁切一致性门禁（spec/wysiwyg-crop，plan D1~D3 / FR-001~005）

/// 快门门禁集成：`capture()` 入口快照 `imageQuad`（呈现框），文档模式经
/// `CropConsistencyGate.resolve` 替换旧回退链。锁定组钉死 Case A 单测对应
/// （锁定右页 + 静帧检出整书 → 成片 = 锁定框）与 US4 语义（静帧一致 →
/// 精修保留）；跟踪/搜索/idCard 组（US2）钉死全状态统一与例外路径。
/// 替身与 HoldWindow* 同模式：手动喂帧相机 + live 序列/still 结果可注入
/// 检测器，live 检测计数即「已被 ViewModel 消费的帧数」同步点。
@MainActor
struct CropGateAtShutterTests {
    // MARK: - US1 锁定组：锁定框即裁切框

    @Test("锁定 + 静帧分歧（右页 vs 整书）→ 成片 = 锁定框（Case A 单测对应）")
    func lockedDivergingStillCropsLockedFrame() async throws {
        let (viewModel, camera, detector) = makeFixture(
            liveSequence: Array(repeating: CropGateQuads.rightPage, count: 12),
            stillQuad: CropGateQuads.wholeSpread
        )

        await viewModel.start()
        // 恒定右页框 ×12 → 第 10 帧锁定（帧 2~10 累计 9×1/15s = 0.6s ≥ 0.55s），
        // 恒等几何下呈现框 = 右页框本身（插值恒等）。
        await feed(12, camera: camera, detector: detector)
        #expect(viewModel.overlayIsLocked)
        #expect(viewModel.imageQuad == CropGateQuads.rightPage)

        // 手动快门：静帧重检出整书外轮廓（含左页，IoU ≈ 0.4262 < 0.70）→
        // 门禁弃用静帧，成片 = 屏幕所见的锁定右页框——不含左页/折起部分。
        await viewModel.capture()
        #expect(viewModel.drafts.count == 1)
        #expect(viewModel.drafts.last?.quad == CropGateQuads.rightPage)
        #expect(viewModel.drafts.last?.quad != CropGateQuads.wholeSpread)
    }

    @Test("锁定 + 静帧一致 → 静帧精修采纳（平整精度不回归，US4 语义）")
    func lockedConsistentStillRefines() async throws {
        let (viewModel, camera, detector) = makeFixture(
            liveSequence: Array(repeating: CropGateQuads.rightPage, count: 12),
            stillQuad: CropGateQuads.refined
        )

        await viewModel.start()
        await feed(12, camera: camera, detector: detector)
        #expect(viewModel.overlayIsLocked)

        // 手动快门：静帧精修框（贴边吸附级外扩，IoU ≈ 0.8746 ≥ 0.70）→
        // 采纳静帧精修——平整文档高分辨率裁切精度与修复前一致（SC-003）。
        await viewModel.capture()
        #expect(viewModel.drafts.count == 1)
        #expect(viewModel.drafts.last?.quad == CropGateQuads.refined)
    }

    // MARK: - US2 组：呈现框即裁切框·全状态统一

    @Test("跟踪态手动拍 → 成片 = 呈现框（末帧平滑输出，Case B 抢拍对应）")
    func trackingManualCaptureCropsDisplayedFrame() async throws {
        // 帧 1 右页 → smoother 初始化；帧 2 右页微移（顶点距离 0.028 > epsilon
        // 0.012 → 不锁定；面积不变 → 不触发 areaJump 复位）——呈现框 = 两帧间
        // 的平滑插值（≠ 原始末帧检测），证明门禁基准是 smoother 输出而非原始检测。
        let (viewModel, camera, detector) = makeFixture(
            liveSequence: [CropGateQuads.rightPage, CropGateQuads.trackingShifted],
            stillQuad: CropGateQuads.wholeSpread
        )

        await viewModel.start()
        await feed(2, camera: camera, detector: detector)
        #expect(viewModel.overlayIsLocked == false, "前置：仍在跟踪态（未满锁定时长）")
        let displayed = try #require(viewModel.imageQuad)
        #expect(displayed != CropGateQuads.trackingShifted, "呈现框 = 平滑插值，非原始末帧检测")

        // 跟随态手动快门：静帧检出整书外轮廓（IoU ≈ 0.43 < 0.70）→ 门禁弃用，
        // 成片 = 屏幕此刻呈现的平滑框——抢拍不再裁出整书（Case B 手动拍形态）。
        await viewModel.capture()
        #expect(viewModel.drafts.count == 1)
        #expect(viewModel.drafts.last?.quad == displayed)
        #expect(viewModel.drafts.last?.quad != CropGateQuads.wholeSpread)
    }

    @Test("搜索态（无呈现框）手动拍 → 静帧自由检测照旧")
    func searchingManualCaptureUsesStillDetection() async throws {
        // live 恒无检出 → smoother 连续 miss 复位 → searching，imageQuad = nil
        //（搜索态无「所见」可违背，FR-004：静帧检测维持现状自由择框）。
        let (viewModel, camera, detector) = makeFixture(
            liveSequence: [],
            stillQuad: CropGateQuads.wholeSpread
        )

        await viewModel.start()
        await feed(3, camera: camera, detector: detector)
        #expect(viewModel.imageQuad == nil, "前置：搜索态，屏幕无取景框")

        await viewModel.capture()
        #expect(viewModel.drafts.count == 1)
        #expect(viewModel.drafts.last?.quad == CropGateQuads.wholeSpread)
    }

    @Test("idCard 模式拍摄行为不变：静帧检测（即使与窗口分歧）照旧胜出")
    func idCardCaptureKeepsLegacyChain() async throws {
        // 旧链钉死（FR-005 例外路径）：`detected ?? imageQuad ?? .fullImage`，
        // 无门禁。静帧检出框与 idCardWindow 刻意分歧（IoU ≈ 0.29 < 0.70）——
        // 若门禁被误用于 idCard 模式，这里会退回窗口而假失败（最大判别度）。
        let (viewModel, camera, detector) = makeFixture(
            liveSequence: [],
            stillQuad: CropGateQuads.idCardDetected
        )

        await viewModel.start()
        viewModel.setMode(.idCard)
        #expect(viewModel.imageQuad == Quad.idCardWindow)
        // idCard 模式 live 无检出 → searching 分支 imageQuad = 窗口（既有语义）。
        await feed(2, camera: camera, detector: detector)
        #expect(viewModel.imageQuad == Quad.idCardWindow)

        await viewModel.capture()
        #expect(viewModel.drafts.count == 1)
        #expect(viewModel.drafts.last?.quad == CropGateQuads.idCardDetected)
        #expect(viewModel.drafts.last?.quad != Quad.idCardWindow)
    }

    // MARK: - Helpers

    private func makeFixture(
        liveSequence: [Quad?],
        stillQuad: Quad?
    ) -> (viewModel: CaptureViewModel, camera: CropGateCamera, detector: CropGateDetector) {
        let defaults = UserDefaults(suiteName: "zhixia.cropgate.\(UUID().uuidString)") ?? .standard
        let preferences = PreferencesStore(defaults: defaults)
        // 与自动快门解耦：门禁语义由手动快门触发（autoCapture 默认开，须显式关）。
        preferences.autoCapture = false
        let camera = CropGateCamera()
        let detector = CropGateDetector(liveSequence: liveSequence, stillQuad: stillQuad)
        let viewModel = CaptureViewModel(
            launch: .fresh,
            camera: camera,
            detector: detector,
            fileStore: PageFileStore(
                root: FileManager.default.temporaryDirectory.appending(path: "cropgate-\(UUID().uuidString)")
            ),
            permissions: PreviewPermissions(),
            preferences: preferences
        )
        return (viewModel, camera, detector)
    }

    /// 喂 N 帧并等待全部被 ViewModel 消费（以检测器 live 计数为同步点），
    /// 再留一小段稳定时间让 consume 的检测后段（相位/引导/计数）跑完。
    private func feed(
        _ count: Int,
        camera: CropGateCamera,
        detector: CropGateDetector
    ) async {
        let before = await detector.liveDetectCount
        for _ in 0..<count {
            await camera.yieldFrame()
        }
        let target = before + count
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await detector.liveDetectCount >= target { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
    }
}

// MARK: - 快门门禁替身（文件私有，与其他脚手架互不影响）

/// 可逐帧喂投的门禁相机：与 HoldWindowCamera 同模式（continuation 长驻供给，
/// 测试按相位手动 `yieldFrame()`——快门用例需要「先喂帧锁定、后快门」分段控制）。
private final class CropGateCamera: CameraCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<VideoFrame>.Continuation?
    private var frameIndex = 0

    func start() async throws {}
    func stop() async {}

    func capturePhoto() async throws -> CapturedPhoto {
        CapturedPhoto(
            jpegData: PreviewImages.jpeg(),
            pixelSize: CGSize(width: 80, height: 100)
        )
    }

    func setTorch(enabled: Bool) async throws {}
    func setFlashAuto(_ enabled: Bool) async {}

    var frames: AsyncStream<VideoFrame> {
        AsyncStream { continuation in
            self.lock.withLock {
                self.continuation = continuation
            }
        }
    }

    func geometry() async -> CaptureGeometry { .identity }

    /// 喂一帧（时间戳按 1/15s 递增，与 fake 时钟口径一致）。帧流尚未被
    /// 消费端建立时（listenToFrames 的 Task 调度窗口）稍候重试。
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
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }()
}

/// 快门门禁检测器：live 结果按注入序列逐帧取值（序列耗尽后保持末值，
/// 空序列恒 nil），still 结果固定注入——锁定/跟踪/搜索三态与静帧
/// 分歧/一致组合由此穷举。live 检测计数即「已被 ViewModel 消费的帧数」。
private actor CropGateDetector: EdgeDetecting {
    private var liveSequence: [Quad?]
    private var liveIndex = 0
    private let stillQuad: Quad?
    private(set) var liveDetectCount = 0

    init(liveSequence: [Quad?], stillQuad: Quad?) {
        self.liveSequence = liveSequence
        self.stillQuad = stillQuad
    }

    func detect(frame: VideoFrame, idCardWindow: Quad?) async -> Quad? {
        liveDetectCount += 1
        guard !liveSequence.isEmpty else { return nil }
        let quad = liveSequence[min(liveIndex, liveSequence.count - 1)]
        if liveIndex < liveSequence.count {
            liveIndex += 1
        }
        return quad
    }

    func detect(imageData: Data, idCardWindow: Quad?) async -> Quad? { stillQuad }
}

private enum CropGateQuads {
    /// 呈现框（右页，恒等几何）：0.45×0.8，面积 0.36——非可疑（边距 ≥ 5%）。
    static let rightPage = Quad(
        topLeft: CGPoint(x: 0.5, y: 0.1),
        topRight: CGPoint(x: 0.95, y: 0.1),
        bottomRight: CGPoint(x: 0.95, y: 0.9),
        bottomLeft: CGPoint(x: 0.5, y: 0.9)
    )

    /// 静帧分歧框（整书外轮廓，含左页）：0.96×0.88 = 0.8448；
    /// IoU(rightPage) = 0.36/0.8448 ≈ 0.4262 < 0.70（Case A 形态）。
    static let wholeSpread = Quad(
        topLeft: CGPoint(x: 0.02, y: 0.06),
        topRight: CGPoint(x: 0.98, y: 0.06),
        bottomRight: CGPoint(x: 0.98, y: 0.94),
        bottomLeft: CGPoint(x: 0.02, y: 0.94)
    )

    /// 静帧一致精修框（贴边吸附级外扩）：0.49×0.84 = 0.4116；
    /// IoU(rightPage) = 0.36/0.4116 ≈ 0.8746 ≥ 0.70（US4 形态）。
    static let refined = Quad(
        topLeft: CGPoint(x: 0.48, y: 0.08),
        topRight: CGPoint(x: 0.97, y: 0.08),
        bottomRight: CGPoint(x: 0.97, y: 0.92),
        bottomLeft: CGPoint(x: 0.48, y: 0.92)
    )

    /// 跟随态帧 2（右页微移 +0.02）：与 rightPage 顶点距离 ≈ 0.028 > epsilon
    /// 0.012（不锁定）、面积不变（不触发 areaJump 复位）→ smoother 输出为
    /// 两帧间的平滑插值（跟踪态呈现框 ≠ 原始末帧检测）。
    static let trackingShifted = Quad(
        topLeft: CGPoint(x: 0.52, y: 0.12),
        topRight: CGPoint(x: 0.97, y: 0.12),
        bottomRight: CGPoint(x: 0.97, y: 0.92),
        bottomLeft: CGPoint(x: 0.52, y: 0.92)
    )

    /// idCard 模式静帧检出框（与窗口刻意分歧）：0.4×0.2 = 0.08；
    /// IoU(idCardWindow) = 0.08/0.2736 ≈ 0.2924 < 0.70——若门禁被误用于
    /// idCard 路径会退回窗口，本框胜出即证明旧链保持（FR-005）。
    static let idCardDetected = Quad(
        topLeft: CGPoint(x: 0.3, y: 0.4),
        topRight: CGPoint(x: 0.7, y: 0.4),
        bottomRight: CGPoint(x: 0.7, y: 0.6),
        bottomLeft: CGPoint(x: 0.3, y: 0.6)
    )
}
