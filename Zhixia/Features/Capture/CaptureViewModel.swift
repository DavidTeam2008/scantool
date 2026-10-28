import Foundation
import UIKit

@MainActor
@Observable
final class CaptureViewModel {
    var phase: CapturePhase = .idle
    var imageQuad: Quad?
    var drafts: [PageDraft] = []
    var mode: ScanMode = .document
    var idFace: IDCardFace = .front
    var torchOn = false
    var error: ZhixiaError?
    var isFlashVisible = false
    var permission: CameraAuthorization = .notDetermined
    var replacePageID: UUID?
    /// US4（plan D8，FR-010）：可疑锁定提示状态——锁定框近满幅/贴边
    ///（疑似视场裁切）时置位，状态区提示用户后退；离开锁定即清除。
    var isAutoCaptureSuppressed = false
    /// US6（spec/scan-fidelity / FR-010）：「太远」面积滞回——进入 closer 需
    /// 面积 < 0.07、退出需 > 0.09，0.02 间隙保持上一判定，目标在边界附近
    /// 晃动时提示不闪跳。
    private var farHysteresis = FarHysteresis()
    /// US6：四态引导判定（backOff / closer / locked / searching），逐帧由
    /// `GuidanceDirective.evaluate` 与轨道态同帧推导，`CaptureView.hintText` 消费。
    private(set) var directive: GuidanceDirective = .searching

    let sessionID: UUID
    let appendToDocumentID: UUID?

    private let camera: any CameraCapturing
    private let detector: any EdgeDetecting
    /// CF-T002/CF-T003：真实检测器支持包络观测时，自动文档路径改走
    /// “包络 + 跟踪”；旧替身/旧路径保持原语义，既有测试不需要改。
    private let envelopeDetector: (any EnvelopeDetecting)?
    private var envelopeTracker = CaptureEnvelopeTracker()
    /// 当前左/右页输出目标（照片空间）；nil = 只能拍包络，拍后由 Review 拆分。
    private(set) var outputTargetQuad: Quad?
    /// 包络来自上一观测的 hold（不是新帧），自动快门/锁定提示必须保守。
    private(set) var envelopeIsHolding = false
    private(set) var envelopeIntentSatisfied = false
    private let fileStore: any PageFileStoring
    private let permissions: any PermissionGranting
    private let preferences: PreferencesStore
    // smoother 保持默认 missLimit 3（spec/folded-page-capture，plan D4）：
    // 刻意的非对齐——smoother 的 miss 保留只管「全帧无检出」的呈现框存留
    // （3 帧 ≈0.2s 消失语义不变，AutoCaptureHoldWindowTests 钉住）；折页书
    // 存在性交替场景下 sticky（missLimit 5）每帧都回传锚点择优，smoother
    // 的 miss 路径本就不触发，无需同步拉长。
    // spec/frame-stability 真机复测：平滑参数（alpha/epsilon/lockDuration）被
    // AutoCaptureHoldWindowTests 的逐帧轨迹精确钉住，**不得**为此改动——
    // 抖动改由「逐帧贴边吸附」在供给侧解决（吸附后边锚在真实边缘上）。
    // spec/scan-enhance：解锁迟滞 3%——锁定后（白线/冻结框）需要更大的
    // 移动才回到跟踪（红线），消除「红线↔白线高频互跳、已对准提示转瞬即逝」。
    private var smoother = QuadSmoother(unlockEpsilon: 0.03)
    private var frameTask: Task<Void, Never>?
    private var isDetecting = false
    private var didAutoCaptureThisLock = false
    /// 冻结框（spec/frame-truth FR-005：锁定冻结 + 精修上屏，照片空间）。
    /// 锁定态首次进入时对当前帧检测做一次有界吸附，结果上屏并冻结；锁定期间
    /// 即使 smoother 继续插值也不再改变呈现框——任何裁切变化都发生在快门
    /// 前且屏幕上可见。tracking/searching 转换与拍摄复位时清除。
    private var frozenQuad: Quad?
    /// P0.2 / CU-T004：跟踪态呈现去抖——相邻平滑框小于约 0.4% 的顶点位移
    /// 不刷新屏幕；候选/手势明显变化仍会更新。搜索/快门后复位。
    private var presentedQuad: Quad?
    /// US2（spec/overlay-frame-visibility，plan D2 / FR-005）：自动快门锁定
    /// 确认窗——当前锁定周期累计的**非可疑**锁定帧数。锁定周期首帧清零
    /// （重锁重新计时）；searching/tracking 转换、capture() 复位段、setMode()
    /// 全部清零；suspicious 锁定帧冻结（不增不清零）。达阈值才自动快门：
    /// 锁定视觉（白双线 + 压暗加深 + 震动）先呈现，用户来得及移开中止。
    private var lockedFrameCount = 0
    /// 确认窗阈值（帧数；默认 6 ≈ 0.4s@15fps，spec 假设已确认）。init 注入
    /// 供测试穷举边界；带默认值，既有调用点零破坏。
    private let autoCaptureHoldFrames: Int
    /// 运行时取景几何（plan D2 / T021）：`start()` 时测量缓存。摄入边界换算
    ///（视频→照片，`FOVLayout`）与 overlay 解析式映射（照片→屏幕，
    /// `OverlaySpaceMap`）共用这一份度量——单一真值源，透出供视图消费。
    private(set) var geometry: CaptureGeometry = .identity
    /// 取景视图尺寸（spec/scan-enhance：预览可见域钳制）。由视图
    /// `onGeometryChange` 写入；`.zero` = 尚未测量（不钳制，既有语义）。
    ///
    /// 画布几何变化 → **引导框失效**（spec/guided-capture D3：几何变化时重置）：
    /// 旧框的屏幕位置已不再对应同一片画面，继续沿用会把成片裁到别处。
    var previewSize: CGSize = .zero {
        didSet {
            guard previewSize != oldValue else { return }
            resetGuide()
        }
    }
    /// 取景模式（spec/guided-capture T010 / D1）——自动 / 引导；默认 `.auto`。
    private(set) var captureMode: CaptureMode
    /// 拍摄意图（spec/guided-capture T010 / D1）——右页 / 左页 / 整页。
    private(set) var captureIntent: CaptureIntent
    /// 引导框（**照片空间**，spec/guided-capture D3）——引导模式唯一的框状态；
    /// 屏幕上的框是它的派生渲染值（`OverlaySpaceMap.screenQuad`），不存第二份。
    private(set) var guidePhotoQuad: Quad?
    /// 自动对位前的框快照（一次撤销用）。
    private var guideUndoSnapshot: Quad?
    /// 最近一帧（引导模式的「自动对位」用；引导路径**不跑逐帧检测**）。
    private var latestFrame: VideoFrame?
    /// 诊断 trace 缓冲（spec/guided-capture T001 / FR-007）——**可选注入**：
    /// 默认 nil（既有测试零改动、release 不采集）。注入后逐帧记录事实 +
    /// 候选快照 + 低分辨率帧，供诊断包导出与离线回放。
    private let traceRecorder: CaptureTraceRecorder?
    /// 低分辨率帧采样计数（1/3 帧采一次 ≈10fps，控住诊断开销）。
    private var traceFrameCounter = 0
    private let impact = UIImpactFeedbackGenerator(style: .light)

    init(
        launch: CaptureLaunch,
        camera: any CameraCapturing,
        detector: any EdgeDetecting,
        fileStore: any PageFileStoring,
        permissions: any PermissionGranting,
        preferences: PreferencesStore,
        autoCaptureHoldFrames: Int = 6,
        traceRecorder: CaptureTraceRecorder? = nil
    ) {
        self.sessionID = UUID()
        self.appendToDocumentID = launch.documentID
        self.camera = camera
        self.detector = detector
        self.envelopeDetector = detector as? any EnvelopeDetecting
        self.fileStore = fileStore
        self.permissions = permissions
        self.preferences = preferences
        self.autoCaptureHoldFrames = autoCaptureHoldFrames
        self.traceRecorder = traceRecorder
        self.captureMode = preferences.captureMode
        self.captureIntent = preferences.captureIntent
    }

    var canFinish: Bool { !drafts.isEmpty }
    var overlayIsLocked: Bool {
        // spec/frame-truth FR-007 取景有效性契约：`closer`（太远）时不得显示
        // 可拍摄的锁定框/震动——上一周期真机「靠近一点 + 白色锁定框同屏」
        // 的语义矛盾由此消除。`.backOff`（可疑近满幅/贴边）不抑制：手动拍
        // 仍尊重用户意图，自动拍另由 suspicious 门禁拦截。
        if case .locked = phase { return directive != .closer }
        return false
    }

    /// 轨道相位本身是否锁定（不掺入引导有效性）——锁定震动/确认窗/冻结
    /// 转换等**状态机语义**用它；`overlayIsLocked` 是面向用户承诺的视觉态。
    private var phaseIsLocked: Bool {
        if case .locked = phase { return true }
        return false
    }

    /// 预览可见域（照片空间）：预览层是 aspectFill，取景框只能显示视频的
    /// 中心一部分；照片却覆盖整个传感器视野——**成片不得包含用户在预览里
    /// 看不到的内容**（spec/scan-enhance：折叠部分在"镜头外"却仍在照片里、
    /// 被裁进成片）。返回 nil = 尺寸未测量（不钳制）。
    private var visiblePhotoRect: CGRect? {
        guard previewSize.width > 0, previewSize.height > 0,
              geometry.videoAspect > 0, geometry.photoAspect > 0
        else { return nil }
        // aspectFill：scale = max(视图宽/视频宽比, 视图高)；显示尺寸 = (视频宽比×scale, scale)。
        let scale = max(
            Double(previewSize.width) / geometry.videoAspect,
            Double(previewSize.height)
        )
        let displayWidth = geometry.videoAspect * scale
        let displayHeight = scale
        let widthFraction = min(1, Double(previewSize.width) / displayWidth)
        let heightFraction = min(1, Double(previewSize.height) / displayHeight)
        let x0 = (1 - widthFraction) / 2
        let x1 = 1 - x0
        let y0 = (1 - heightFraction) / 2
        let y1 = 1 - y0
        // 视频空间 → 照片空间（x 线性映射；y 恒等）。
        let videoRect = Quad(
            topLeft: CGPoint(x: x0, y: y0),
            topRight: CGPoint(x: x1, y: y0),
            bottomRight: CGPoint(x: x1, y: y1),
            bottomLeft: CGPoint(x: x0, y: y1)
        )
        let photoRect = FOVLayout.convert(
            quad: videoRect,
            fromAspect: geometry.videoAspect,
            toAspect: geometry.photoAspect
        )
        let xs = [photoRect.topLeft.x, photoRect.topRight.x, photoRect.bottomRight.x, photoRect.bottomLeft.x]
        let ys = [photoRect.topLeft.y, photoRect.topRight.y, photoRect.bottomRight.y, photoRect.bottomLeft.y]
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
            return nil
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 四角钳制到预览可见域（逐顶点；越出可见区的边贴着屏幕边）。
    private func clampedToPreview(_ quad: Quad) -> Quad {
        guard let rect = visiblePhotoRect else { return quad }
        func clamp(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: min(max(point.x, rect.minX), rect.maxX),
                y: min(max(point.y, rect.minY), rect.maxY)
            )
        }
        return Quad(
            topLeft: clamp(quad.topLeft),
            topRight: clamp(quad.topRight),
            bottomRight: clamp(quad.bottomRight),
            bottomLeft: clamp(quad.bottomLeft)
        )
    }

    /// 四角展开（TL,TR,BR,BL）——遥测日志用。
    private func corners(of quad: Quad?) -> [Double] {
        guard let quad else { return [] }
        return [
            quad.topLeft.x, quad.topLeft.y,
            quad.topRight.x, quad.topRight.y,
            quad.bottomRight.x, quad.bottomRight.y,
            quad.bottomLeft.x, quad.bottomLeft.y
        ]
    }

    func start() async {
        permission = await permissions.cameraStatus()
        if permission == .notDetermined {
            permission = await permissions.requestCamera()
        }
        guard permission == .authorized else {
            if permission == .denied {
                error = .cameraDenied
            }
            return
        }
        do {
            try await camera.start()
            geometry = await camera.geometry()
            ZhixiaLog.geometry(video: geometry.videoAspect, photo: geometry.photoAspect)
            await subscribeToCandidateSnapshots()
            phase = .previewing
            UIApplication.shared.isIdleTimerDisabled = true
            listenToFrames()
        } catch let zhixia as ZhixiaError {
            error = zhixia
        } catch {
            self.error = .cameraUnavailable
        }
    }

    /// 订阅检测器的候选快照（spec/guided-capture T002 / FR-007）——
    /// **仅在注入诊断缓冲时订阅**：无缓冲 = 检测器零开销（默认 nil 回调），
    /// release 构建同理（缓冲的存储整段编译掉）。
    private func subscribeToCandidateSnapshots() async {
        guard let recorder = traceRecorder,
              let reporting = detector as? any CandidateSnapshotReporting
        else { return }
        await reporting.setCandidateSnapshotHandler { snapshot in
            recorder.recordCandidate(snapshot)
        }
    }

    func stop() async {
        frameTask?.cancel()
        frameTask = nil
        await camera.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        if case .capturing = phase {
            return
        }
        if !drafts.isEmpty {
            return
        }
        phase = .idle
        // spec/guided-capture D3：会话结束 → 引导框生命周期结束。
        guidePhotoQuad = nil
        guideUndoSnapshot = nil
    }

    func setMode(_ mode: ScanMode) {
        self.mode = mode
        idFace = .front
        smoother.reset()
        farHysteresis.reset()
        directive = .searching
        didAutoCaptureThisLock = false
        isAutoCaptureSuppressed = false
        // 确认窗复位点（plan D2）：切换模式 = 放弃当前锁定周期，重新计时。
        lockedFrameCount = 0
        imageQuad = mode == .idCard ? Quad.idCardWindow : nil
        presentedQuad = nil
        outputTargetQuad = nil
        envelopeIsHolding = false
        envelopeIntentSatisfied = false
        envelopeTracker.reset()
        Task {
            if let envelopeDetector = self.envelopeDetector {
                await envelopeDetector.resetEnvelopeTracking()
            }
        }
        phase = .previewing
        // spec/guided-capture D3：切模式 → 引导框重置（证件模式不显示引导 UI）。
        resetGuide()
        ensureGuide()
    }

    // MARK: - 引导取景（spec/guided-capture T012~T015 / plan D3、D4）

    /// 引导框最小面积（照片空间归一化）——D3：照片面积 ≥ 0.02。
    static let minimumGuideArea: Double = 0.02
    /// 引导框最小边长（相对屏幕短边）——D3：屏幕任一边 ≥ 8% 短边。
    static let minimumGuideSideRatio: Double = 0.08
    /// 贴边吸附限幅（相对框短边）——D3 / FR-006：≤ 3%。
    static let guideSnapMaxShiftRatio: Double = 0.03

    /// 引导框是否就绪（可拍摄）：模式 + 画布几何 + 合法框三者齐备。
    /// 几何未就绪（首帧 `previewSize == .zero`）时为 false → 快门置灰（D2）。
    var isGuideReady: Bool {
        guard captureMode == .guided, mode == .document else { return false }
        guard previewSize.width > 0, previewSize.height > 0 else { return false }
        guard let guide = guidePhotoQuad else { return false }
        return isValidGuide(photoQuad: guide, screenQuad: screenQuad(for: guide))
    }

    /// 引导框的屏幕空间派生值（屏幕框是照片框的派生，不存第二份——D3）。
    func screenQuad(for guide: Quad) -> Quad {
        OverlaySpaceMap.screenQuad(
            fromPhotoQuad: guide,
            geometry: geometry,
            viewSize: previewSize
        )
    }

    /// 切换取景模式（自动 ↔ 引导）。证件模式不提供引导（UI 不显示入口）。
    func setCaptureMode(_ mode: CaptureMode) {
        guard mode != captureMode else { return }
        captureMode = mode
        preferences.captureMode = mode
        if mode == .guided {
            ensureGuide()
        } else {
            guidePhotoQuad = nil
            guideUndoSnapshot = nil
            smoother.reset()
            farHysteresis.reset()
            frozenQuad = nil
            presentedQuad = nil
            outputTargetQuad = nil
            envelopeIsHolding = false
            envelopeIntentSatisfied = false
            envelopeTracker.reset()
            imageQuad = nil
            phase = .previewing
            Task {
                await detector.resetLiveTracking()
                if let envelopeDetector = self.envelopeDetector {
                    await envelopeDetector.resetEnvelopeTracking()
                }
            }
        }
    }

    /// 切换拍摄意图（右页 / 左页 / 整页）→ 默认框重算（用户可再拖）。
    func setCaptureIntent(_ intent: CaptureIntent) {
        guard intent != captureIntent else { return }
        captureIntent = intent
        preferences.captureIntent = intent
        // 意图切换 = 放弃上一页的锚点/平滑轨迹，避免 sticky 或 smoother
        // 把新意图拉回旧页；检测器侧的 sticky 也必须清锚。
        smoother.reset()
        farHysteresis.reset()
        directive = .searching
        frozenQuad = nil
        presentedQuad = nil
        outputTargetQuad = nil
        envelopeIsHolding = false
        envelopeIntentSatisfied = false
        envelopeTracker.reset()
        didAutoCaptureThisLock = false
        isAutoCaptureSuppressed = false
        lockedFrameCount = 0
        if captureMode == .auto {
            imageQuad = nil
            phase = .previewing
        }
        Task {
            await detector.resetLiveTracking()
            if let envelopeDetector = self.envelopeDetector {
                await envelopeDetector.resetEnvelopeTracking()
            }
        }
        guidePhotoQuad = nil
        ensureGuide()
    }

    /// 重置引导框（清空；随后按意图重建默认框）。
    func resetGuide() {
        guard captureMode == .guided else {
            guidePhotoQuad = nil
            guideUndoSnapshot = nil
            return
        }
        guidePhotoQuad = nil
        guideUndoSnapshot = nil
        ensureGuide()
    }

    /// 引导框缺失时按意图给出默认框（屏幕比例 → 逆映射到照片空间）。
    private func ensureGuide() {
        guard captureMode == .guided, mode == .document, guidePhotoQuad == nil else { return }
        guard previewSize.width > 0, previewSize.height > 0 else { return }
        let rect = captureIntent.defaultScreenRect
        let screenQuad = Quad(
            topLeft: CGPoint(x: rect.minX * previewSize.width, y: rect.minY * previewSize.height),
            topRight: CGPoint(x: rect.maxX * previewSize.width, y: rect.minY * previewSize.height),
            bottomRight: CGPoint(x: rect.maxX * previewSize.width, y: rect.maxY * previewSize.height),
            bottomLeft: CGPoint(x: rect.minX * previewSize.width, y: rect.maxY * previewSize.height)
        )
        let photoQuad = OverlaySpaceMap.photoQuad(
            fromScreenQuad: screenQuad,
            geometry: geometry,
            viewSize: previewSize
        )
        guard isValidGuide(photoQuad: photoQuad, screenQuad: screenQuad) else { return }
        guidePhotoQuad = photoQuad
    }

    /// 拖动中更新引导框（屏幕空间 → 照片空间）。
    /// 非法（自交/近退化/过小/越界）→ **拒绝该次更新**，保留上一有效框（D3）。
    func updateGuide(fromScreenQuad screenQuad: Quad) {
        guard captureMode == .guided, mode == .document else { return }
        let photoQuad = OverlaySpaceMap.photoQuad(
            fromScreenQuad: screenQuad,
            geometry: geometry,
            viewSize: previewSize
        )
        guard isValidGuide(photoQuad: photoQuad, screenQuad: screenQuad) else {
            let photoText = corners(of: photoQuad).map { String(format: "%.4f", $0) }.joined(separator: ",")
            let screenText = corners(of: screenQuad).map { String(format: "%.2f", $0) }.joined(separator: ",")
            let previewWidth = Double(previewSize.width)
            let previewHeight = Double(previewSize.height)
            let videoAspect = geometry.videoAspect
            let photoAspect = geometry.photoAspect
            ZhixiaLog.capture.debug(
                "guideAdjust invalid photo=[\(photoText, privacy: .public)] screen=[\(screenText, privacy: .public)] preview=\(previewWidth, format: .fixed(precision: 1), privacy: .public)x\(previewHeight, format: .fixed(precision: 1), privacy: .public) aspect=\(videoAspect, format: .fixed(precision: 3), privacy: .public)/\(photoAspect, format: .fixed(precision: 3), privacy: .public)"
            )
            ZhixiaLog.guideAdjust(before: [], after: [], shift: 0, rejected: "invalid-geometry")
            return
        }
        guidePhotoQuad = photoQuad
    }

    /// 松手提交：一次贴边吸附（限幅 3%）——先 photo→video，吸附，再 video→photo。
    /// 吸附失败/退化 → 保留用户框（宁可不修，不可错修——`EdgeSnapper` 契约）。
    func commitGuide() {
        guard captureMode == .guided, let guide = guidePhotoQuad else { return }
        guard let frame = latestFrame else {
            ZhixiaLog.guideAdjust(before: corners(of: guide), after: corners(of: guide), shift: 0, rejected: "no-frame")
            return
        }
        let videoQuad = FOVLayout.convert(
            quad: guide,
            fromAspect: geometry.photoAspect,
            toAspect: geometry.videoAspect
        )
        let snappedVideo = EdgeSnapper.snap(
            quad: videoQuad,
            image: frame.cgImage,
            maxShiftRatio: Self.guideSnapMaxShiftRatio
        )
        let snappedPhoto = FOVLayout.convert(
            quad: snappedVideo,
            fromAspect: geometry.videoAspect,
            toAspect: geometry.photoAspect
        )
        guard !snappedPhoto.isDegenerate,
              snappedPhoto.area >= Self.minimumGuideArea,
              isValidGuide(photoQuad: snappedPhoto, screenQuad: screenQuad(for: snappedPhoto))
        else {
            ZhixiaLog.guideAdjust(before: corners(of: guide), after: corners(of: guide), shift: 0, rejected: "snap-degenerate")
            return
        }
        guidePhotoQuad = snappedPhoto
        ZhixiaLog.guideAdjust(
            before: corners(of: guide),
            after: corners(of: snappedPhoto),
            shift: Self.maxCornerShift(before: guide, after: snappedPhoto)
        )
    }

    /// 自动对位：点一次跑**一次** detector（最近一帧），候选经视频→照片换算、
    /// 钳制到可见域后作为新引导框；无候选/退化 → no-op（不改变当前框）。
    func autoFitGuide() async {
        guard captureMode == .guided, mode == .document else { return }
        guard let frame = latestFrame else {
            ZhixiaLog.guideAdjust(before: [], after: [], shift: 0, rejected: "no-frame")
            return
        }
        let detected = await detector.detect(
            frame: frame,
            idCardWindow: nil,
            intent: captureIntent
        )
        guard let detected, !detected.isDegenerate else {
            ZhixiaLog.guideAdjust(before: [], after: [], shift: 0, rejected: "no-candidate")
            return
        }
        let photoQuad = clampedToPreview(
            FOVLayout.convert(
                quad: detected,
                fromAspect: geometry.videoAspect,
                toAspect: geometry.photoAspect
            )
        )
        guard photoQuad.area >= Self.minimumGuideArea,
              isValidGuide(photoQuad: photoQuad, screenQuad: screenQuad(for: photoQuad))
        else {
            ZhixiaLog.guideAdjust(before: [], after: [], shift: 0, rejected: "degenerate")
            return
        }
        let before = guidePhotoQuad
        guideUndoSnapshot = before
        guidePhotoQuad = photoQuad
        ZhixiaLog.guideAdjust(
            before: corners(of: before),
            after: corners(of: photoQuad),
            shift: Self.maxCornerShift(before: before, after: photoQuad)
        )
    }

    /// 撤销自动对位（一次，回到对位前的框）。
    func undoAutoFit() {
        guard captureMode == .guided else { return }
        guard let snapshot = guideUndoSnapshot else { return }
        guideUndoSnapshot = nil
        guidePhotoQuad = snapshot
        ZhixiaLog.guideAdjust(before: [], after: corners(of: snapshot), shift: 0, rejected: "undo")
    }

    /// 是否还有可撤销的对位。
    var canUndoAutoFit: Bool { guideUndoSnapshot != nil }

    /// 引导框合法性（照片空间 + 屏幕空间双口径，D3）：
    /// - 照片空间：非退化、面积 ≥ 0.02、四角落在照片域内；
    /// - 屏幕空间：任一边 ≥ 短边 8%（太小的框没法对位）。
    private func isValidGuide(photoQuad: Quad, screenQuad: Quad) -> Bool {
        guard !photoQuad.isDegenerate, photoQuad.area >= Self.minimumGuideArea else { return false }
        let corners = [
            photoQuad.topLeft, photoQuad.topRight,
            photoQuad.bottomRight, photoQuad.bottomLeft
        ]
        guard corners.allSatisfy({ $0.x >= -0.0001 && $0.x <= 1.0001 && $0.y >= -0.0001 && $0.y <= 1.0001 })
        else { return false }
        let bbox = screenQuad.boundingRect
        let shortSide = min(bbox.width, bbox.height)
        guard shortSide > 0 else { return false }
        let minimum = shortSide * Self.minimumGuideSideRatio
        return bbox.width >= minimum && bbox.height >= minimum
    }

    /// 两个框之间的最大角点位移（归一化；日志用）。
    private static func maxCornerShift(before: Quad?, after: Quad) -> Double {
        guard let before else { return 0 }
        let pairs = [
            (before.topLeft, after.topLeft),
            (before.topRight, after.topRight),
            (before.bottomRight, after.bottomRight),
            (before.bottomLeft, after.bottomLeft)
        ]
        return pairs.map { pair in
            hypot(pair.0.x - pair.1.x, pair.0.y - pair.1.y)
        }.max() ?? 0
    }

    func toggleTorch() async {
        do {
            try await camera.setTorch(enabled: !torchOn)
            torchOn.toggle()
        } catch {
            self.error = .cameraUnavailable
        }
    }

    func capture() async {
        // spec/guided-capture D4：引导路径**独立分支**——成片 = 引导框，
        // 不重检静帧、不走 CropConsistencyGate、不拆分。自动路径逐行保持现状。
        if captureMode == .guided, mode == .document {
            await captureGuided()
            return
        }
        guard phase != .capturing else { return }
        // WYSIWYG 门禁呈现框快照（spec/wysiwyg-crop，plan D2 / FR-001）：入口
        // 读取 `imageQuad`——必须在任何复位段之前（capture() 末尾会清空）。
        // `imageQuad` 即 overlay 渲染源（照片空间：跟踪 = smoother 输出 /
        // 锁定 = 冻结框 / 搜索 = nil），与屏幕所见同源；`consume()` 的
        // `phase != .capturing` 闸在 capturing 期间冻结帧消费 → 快照 =
        // 快门时刻屏幕所见，瞬时检测缺口不会使其回退静帧自由检测。
        // spec/frame-truth FR-007：`closer`（太远/无效框）时呈现框不可拍摄，
        // 按搜索态处理（静帧自由检测兜底）——避免把屏幕上的局部小框裁成废片。
        // CU-T005：呈现框与快门快照同一来源。实拍路径现在以包络为主：
        // - 整页意图：拍屏幕上的包络；
        // - 左/右页意图：优先拍 outputTargetQuad，目标不可靠时拍包络，
        //   交给 Review 做拍后拆页；
        // - 绝不再在“没有呈现框”时静默落 fullImage。
        let envelopePath = envelopeDetector != nil && mode == .document && captureMode == .auto
        let envelope = presentedQuad ?? imageQuad
        if envelopePath, envelope == nil {
            // 没有书/页面可拍：保持 previewing，不写 fullImage，也不闪快门。
            return
        }
        let displayed: Quad?
        if envelopePath {
            displayed = captureIntent == .wholePage
                ? envelope
                : (outputTargetQuad ?? envelope)
        } else {
            displayed = (mode == .idCard || directive != .closer)
                ? (mode == .document ? (presentedQuad ?? imageQuad) : imageQuad)
                : nil
        }
        phase = .capturing
        isFlashVisible = true
        do {
            let photo = try await camera.capturePhoto()
            // 快门时刻复记几何（FR-007）：与 AVCameraSession 的 photoGeometry
            // 实测日志对读，验收时核对缓存照片宽高比是否被逐帧校正。
            ZhixiaLog.geometry(video: geometry.videoAspect, photo: geometry.photoAspect)
            let pageID = replacePageID ?? UUID()
            let originalURL = try await fileStore.writeOriginal(
                session: sessionID,
                page: pageID,
                data: photo.jpegData
            )
            // 诊断 trace（spec/guided-capture T001）：原图 URL 记入缓冲，
            // 导出诊断包时随包附上（真机复现构图用）。
            traceRecorder?.recordOriginal(originalURL)
            let quad: Quad
            if mode == .idCard {
                // idCard 路径行为不变（FR-005）：固定窗口链保持现状，无门禁。
                let detected = await detector.detect(
                    imageData: photo.jpegData,
                    idCardWindow: Quad.idCardWindow
                )
                quad = detected ?? imageQuad ?? .fullImage
            } else if let displayed {
                // spec/frame-truth FR-006（呈现框唯一真值）：有呈现框时**不再
                // 重检静帧**——上一周期的 +6.5% 越界正是「静帧无身份锚全局
                // 重选 + 只在 still 发生的贴边外扩」在快门后的隐藏换框。
                // 裁切框 = 呈现框（锁定态 = 锁定瞬间上屏的冻结框），WYSIWYG
                // 从门禁仲裁变为构造不变量。`stillArea=-1 iou=-1` = 冻结直裁
                // （未重检），设备验收按此判读。
                ZhixiaLog.cropGate(
                    displayedArea: displayed.area,
                    stillArea: -1,
                    iou: -1,
                    acceptedStill: false
                )
                ZhixiaLog.cropQuad(tag: "displayed", quad: displayed)
                ZhixiaLog.cropQuad(tag: "still", quad: nil)
                quad = displayed
            } else {
                // 搜索态（无呈现框/无效框）：静帧自由检测照旧（wysiwyg-crop
                // FR-004 语义保留）；门禁 displayed=nil 直通静帧结果。
                let detected = await detector.detect(
                    imageData: photo.jpegData,
                    idCardWindow: nil,
                    intent: mode == .document ? captureIntent : .wholePage
                )
                ZhixiaLog.cropQuad(tag: "displayed", quad: nil)
                ZhixiaLog.cropQuad(tag: "still", quad: detected)
                let decision = CropConsistencyGate.resolve(displayed: nil, still: detected)
                ZhixiaLog.cropGate(
                    displayedArea: 0,
                    stillArea: detected?.area ?? 0,
                    iou: decision.consistency ?? -1,
                    acceptedStill: decision.usedStillRefinement
                )
                quad = decision.quad ?? .fullImage
            }
            // spec/scan-enhance（拍后增强）：快门框仍是拍摄时刻的契约；
            // 整理页会对静帧做一次**身份锚定**的全分辨率重检+书页拆分
            // （结果直接显示在预览里，可见可再调）——竞品的「拍后重新
            // 检测裁剪/去皱/清晰化」流程在整理页完成。
            let draft = PageDraft(
                id: pageID,
                sessionID: sessionID,
                quad: quad,
                enhancement: preferences.defaultEnhancement
            )
            if let replacePageID, let index = drafts.firstIndex(where: { $0.id == replacePageID }) {
                drafts[index] = draft
                self.replacePageID = nil
            } else {
                drafts.append(draft)
            }
            if mode == .idCard {
                idFace = drafts.count >= 1 ? .back : .front
            }
            impact.impactOccurred()
            // 诊断 trace（spec/guided-capture T001）：快门事实——裁切四角是
            // 成片真值，与 `cropQuad` 日志同源（引导路径将写 `tag=guide`）。
            recordCaptureTrace(quad: quad)
        } catch let zhixia as ZhixiaError {
            error = zhixia
        } catch {
            self.error = .captureFailed
        }
        isFlashVisible = false
        smoother.reset()
        farHysteresis.reset()
        frozenQuad = nil
        presentedQuad = nil
        outputTargetQuad = nil
        envelopeIsHolding = false
        envelopeIntentSatisfied = false
        envelopeTracker.reset()
        directive = .searching
        didAutoCaptureThisLock = false
        isAutoCaptureSuppressed = false
        // 确认窗复位点（plan D2 / FR-006）：手动或自动拍摄后窗口清空，
        // 下一锁定周期必须重新累计满窗才可能再次自动拍。
        lockedFrameCount = 0
        phase = .previewing
        imageQuad = mode == .idCard ? Quad.idCardWindow : nil
    }

    /// 引导拍摄（spec/guided-capture T014 / FR-005 / plan D4）。
    ///
    /// 顺序：**引导框 → 快门 → 原图落盘 → 成片**：
    /// 1. 读当前引导框（缺失/退化 → 不拍，提示重新对位）；
    /// 2. `camera.capturePhoto()`；
    /// 3. 写原图；
    /// 4. `quad = guidePhotoQuad`——**不调用** `detector.detect(imageData:)`，
    ///    **不调用** `CropConsistencyGate`；
    /// 5. `PageDraft(userAdjustedQuad: true)`（复用既有字段 → Review 跳过
    ///    自动重检/拆分；不新增持久化字段、不做数据迁移）；
    /// 6. 记 `guidedCapture` / `cropQuad(tag:"guide")` /
    ///    `cropGate(stillArea: -1, iou: -1, acceptedStill: false)`；
    /// 7. 复位相位/闪光，**保留引导框**（下一张继续用）。
    private func captureGuided() async {
        guard phase != .capturing else { return }
        guard let guide = guidePhotoQuad, !guide.isDegenerate else {
            ZhixiaLog.guidedCapture(
                intent: captureIntent.rawValue,
                guide: [],
                crop: [],
                canvasError: -1,
                durationMs: 0,
                rejected: "no-guide"
            )
            return
        }
        phase = .capturing
        isFlashVisible = true
        let started = Date()
        do {
            let photo = try await camera.capturePhoto()
            ZhixiaLog.geometry(video: geometry.videoAspect, photo: geometry.photoAspect)
            let pageID = replacePageID ?? UUID()
            let originalURL = try await fileStore.writeOriginal(
                session: sessionID,
                page: pageID,
                data: photo.jpegData
            )
            traceRecorder?.recordOriginal(originalURL)
            // 成片裁切框 = 引导框（WYSIWYG 由构造保证，不再依赖门禁仲裁）。
            ZhixiaLog.cropQuad(tag: "guide", quad: guide)
            ZhixiaLog.cropGate(
                displayedArea: guide.area,
                stillArea: -1,
                iou: -1,
                acceptedStill: false
            )
            ZhixiaLog.guidedCapture(
                intent: captureIntent.rawValue,
                guide: corners(of: guide),
                crop: corners(of: guide),
                canvasError: canvasRoundTripError(guide: guide),
                durationMs: Date().timeIntervalSince(started) * 1000
            )
            let draft = PageDraft(
                id: pageID,
                sessionID: sessionID,
                quad: guide,
                enhancement: preferences.defaultEnhancement,
                userAdjustedQuad: true
            )
            if let replacePageID, let index = drafts.firstIndex(where: { $0.id == replacePageID }) {
                drafts[index] = draft
                self.replacePageID = nil
            } else {
                drafts.append(draft)
            }
            impact.impactOccurred()
            recordCaptureTrace(quad: guide)
        } catch let zhixia as ZhixiaError {
            error = zhixia
        } catch {
            self.error = .captureFailed
        }
        isFlashVisible = false
        phase = .previewing
        // 引导框保持：连续拍摄用同一个框（FR-005：拍摄后保留框）。
    }

    /// 引导框的画布 round-trip 误差（相对短边；>0.005 即判失败，SC-004）。
    /// 几何未就绪时返回 -1（不可判读）。
    private func canvasRoundTripError(guide: Quad) -> Double {
        guard previewSize.width > 0, previewSize.height > 0 else { return -1 }
        let screen = screenQuad(for: guide)
        let back = OverlaySpaceMap.photoQuad(
            fromScreenQuad: screen,
            geometry: geometry,
            viewSize: previewSize
        )
        let pairs = [
            (back.topLeft, guide.topLeft),
            (back.topRight, guide.topRight),
            (back.bottomRight, guide.bottomRight),
            (back.bottomLeft, guide.bottomLeft)
        ]
        let maxDistance = pairs.map { pair in
            hypot(pair.0.x - pair.1.x, pair.0.y - pair.1.y)
        }.max() ?? 0
        let shortSide = min(guide.boundingRect.width, guide.boundingRect.height)
        guard shortSide > 0 else { return -1 }
        return maxDistance / shortSide
    }

    func importImageData(_ data: Data) async {
        let pageID = UUID()
        do {
            let jpeg = ImportedImage.jpeg(from: data) ?? data
            _ = try await fileStore.writeOriginal(session: sessionID, page: pageID, data: jpeg)
            let detected = await detector.detect(
                imageData: jpeg,
                idCardWindow: mode == .idCard ? Quad.idCardWindow : nil,
                intent: mode == .document ? captureIntent : .wholePage
            )
            drafts.append(
                PageDraft(
                    id: pageID,
                    sessionID: sessionID,
                    quad: detected ?? .fullImage,
                    enhancement: preferences.defaultEnhancement
                )
            )
        } catch {
            self.error = .storeFailed
        }
    }

    func deleteDraft(at index: Int) {
        guard drafts.indices.contains(index) else { return }
        drafts.remove(at: index)
        if mode == .idCard {
            idFace = drafts.isEmpty ? .front : .back
        }
    }

    func finish() -> [PageDraft]? {
        guard canFinish else { return nil }
        return drafts
    }

    func discardSession() async {
        await fileStore.removeSession(session: sessionID)
        drafts = []
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func listenToFrames() {
        frameTask?.cancel()
        frameTask = Task { [weak self] in
            guard let self else { return }
            for await frame in camera.frames {
                if Task.isCancelled { break }
                await self.consume(frame)
            }
        }
    }

    private func consume(_ frame: VideoFrame) async {
        guard phase != .capturing, !isDetecting else { return }
        // spec/guided-capture D1：引导模式下**提前返回**——不跑 detector、
        // 不跑粘滞/平滑/冻结状态机；只留最近一帧，供显式「自动对位」用一次。
        // 引导框是用户意图的载体，逐帧检测对它没有意义（还会把框拽走）。
        if captureMode == .guided, mode == .document {
            latestFrame = frame
            if phase != .capturing {
                phase = .previewing
            }
            return
        }
        // CF-T002/CF-T003：真实检测器走“整摊包络 + 跟踪”，不再让单页
        // 意图的 nil 直接清空 overlay。旧替身/旧路径保持原语义。
        if let envelopeDetector = envelopeDetector,
           mode == .document,
           captureMode == .auto {
            isDetecting = true
            defer { isDetecting = false }
            await consumeEnvelope(frame, detector: envelopeDetector)
            return
        }
        isDetecting = true
        defer { isDetecting = false }
        let window = mode == .idCard ? Quad.idCardWindow : nil
        let liveIntent: CaptureIntent = mode == .document ? captureIntent : .wholePage
        let detected = await detector.detect(
            frame: frame,
            idCardWindow: window,
            intent: liveIntent
        )
        // spec/guided-capture T003：低分辨率帧留样（1/3 帧采样 ≈10fps）——
        // 诊断包「最近 5s 帧」的来源；仅诊断缓冲存在时采集。
        if let recorder = traceRecorder {
            traceFrameCounter += 1
            if traceFrameCounter % 3 == 0, let data = CaptureFrameThumbnail.encode(frame.cgImage) {
                recorder.recordFrameImage(data)
            }
        }
        // spec/frame-stability：文档形态 live **逐帧轻量贴边吸附**——每边吸到
        // 最近的亮度边缘（最近峰策略：左缘稳定命中折痕而不是更强的折脊轮廓），
        // 再交给 smoother 做时域稳定。1080p 帧 + 160 列栅格，单帧约 1–2ms；
        // 吸附后的四边持续贴在真实边缘上，是「框贴边 + 不抖」的供给侧修复。
        //
        // CU-T003：左右页意图的框可能有一条边就是书脊。四边独立吸附会把
        // 书脊边吸到对页内容/折脊上（视频 4 的“越框越大”来源之一），因此
        // 页面意图路径不跑 live 吸附，只依赖已解析出的单页四边形。
        let snapped = mode == .document && liveIntent == .wholePage
            ? detected.map { EdgeSnapper.snap(quad: $0, image: frame.cgImage, maxShiftRatio: 0.06) }
            : detected
        // US3（plan D1）：live 检测结果是**视频 FOV** 的归一化坐标，而 PageDraft/
        // 裁剪/回放全链路消费**照片 FOV**——在摄入边界一次性换算（FR-011 单点收敛），
        // `imageQuad` 与快门回退 `detected ?? imageQuad ?? .fullImage` 天然空间一致。
        let photoDetected = snapped.map {
            clampedToPreview(FOVLayout.convert(
                quad: $0,
                fromAspect: geometry.videoAspect,
                toAspect: geometry.photoAspect
            ))
        }
        let track = smoother.ingest(photoDetected, at: frame.timestamp)
        // US6（FR-010）：四态引导与轨道态同帧推导（suspicious 优先级最高，
        // 太远经面积滞回去抖）；无 quad 帧自动复位滞回。
        directive = GuidanceDirective.evaluate(track: track, hysteresis: &farHysteresis)
        switch track {
        case .searching:
            frozenQuad = nil
            presentedQuad = nil
            imageQuad = window
            if phase != .capturing {
                phase = .previewing
            }
            didAutoCaptureThisLock = false
            isAutoCaptureSuppressed = false
            // 确认窗（FR-006）：进入搜索 = 锁定解除，本次拍摄取消、计数清零。
            lockedFrameCount = 0
            await recordTrace(track: track)
        case .tracking(let quad):
            frozenQuad = nil
            imageQuad = presented(quad)
            isAutoCaptureSuppressed = false
            if phase != .capturing {
                phase = .previewing
            }
            // 确认窗（FR-006）：进入跟踪 = 锁定解除，计数清零、重新计时。
            lockedFrameCount = 0
            await recordTrace(track: track)
        case .locked(let quad):
            let wasLocked = phaseIsLocked
            // spec/frame-truth FR-005（锁定冻结 + 精修上屏）：锁定态**首次**
            // 进入时，用当前帧检测（视频空间）对当前帧图像做一次有界吸附，
            // 结果经 FOV 反算为照片空间后上屏并冻结——贴边修正只发生在
            // 快门前且用户可见；锁定期间 smoother 再插值也不再改变呈现框。
            // 冻结种子取当前帧 detected 而非 smoother 平滑框（红队：手在动
            // 时平滑框与画面有相位差，对着错位的边吸附）。
            if !wasLocked, frozenQuad == nil, directive != .closer, let detected {
                // 整页/单页路径继续在锁定瞬间做一次有界吸附；左右页意图
                // 不吸附（书脊边必须保持在解析出的位置，不能被吸到对页）。
                let snappedPhoto: Quad
                if liveIntent == .wholePage {
                    // 预算 5%→8%（spec/frame-truth 真机复测）：检出框内缩可能
                    // 超过 5%×短边；真机证据是搜索窗内一片平坦纸面（梯度峰值
                    // 0.05–0.07 全部低于阈值）——加窗后才可能够到纸边。s=0 守卫
                    // 与「最强梯度」语义不变，倍率仅放大可达范围。
                    let snappedVideo = EdgeSnapper.snap(
                        quad: detected,
                        image: frame.cgImage,
                        maxShiftRatio: 0.08
                    ) { diagnostic in
                        ZhixiaLog.snapEdge(
                            edge: diagnostic.edge,
                            g0: diagnostic.g0,
                            outward: diagnostic.outward,
                            inward: diagnostic.inward,
                            shift: diagnostic.shift
                        )
                    }
                    snappedPhoto = clampedToPreview(FOVLayout.convert(
                        quad: snappedVideo,
                        fromAspect: geometry.videoAspect,
                        toAspect: geometry.photoAspect
                    ))
                } else {
                    snappedPhoto = clampedToPreview(FOVLayout.convert(
                        quad: detected,
                        fromAspect: geometry.videoAspect,
                        toAspect: geometry.photoAspect
                    ))
                }
                frozenQuad = snappedPhoto
                let seedPhoto = photoDetected
                ZhixiaLog.snapOnLock(
                    seedArea: seedPhoto?.area ?? 0,
                    postArea: snappedPhoto.area,
                    seed: corners(of: seedPhoto),
                    post: corners(of: snappedPhoto)
                )
            }
            let lockedQuad = frozenQuad ?? quad
            imageQuad = lockedQuad
            presentedQuad = lockedQuad
            if phase != .capturing {
                phase = .locked(lockedQuad)
            }
            if !wasLocked {
                impact.impactOccurred()
                // 确认窗（plan D2）：锁定周期首帧清零——重新锁定重新计时。
                lockedFrameCount = 0
            }
            // US4（plan D8）：可疑锁定门禁——照片空间 quad 近满幅/贴边时
            // 疑似书超出视场被裁切，自动快门只会拍下残页：抑制并提示后退。
            // spec/folded-page-capture（FR-002）：整段仅在自动拍开启时生效——
            // 默认不自动拍（FR-001）时没有可抑制的快门，置位提示与
            // `suspiciousLock` 日志（autocapture=suppressed 字样）都是误导。
            let suspicious = preferences.autoCapture && quad.isSuspiciousForAutoCapture()
            if suspicious, !isAutoCaptureSuppressed {
                isAutoCaptureSuppressed = true
                ZhixiaLog.suspiciousLock(area: quad.area, minMargin: minimumEdgeMargin(of: quad))
            } else if !suspicious {
                isAutoCaptureSuppressed = false
            }
            // 确认窗计数（plan D2 语义备注）：仅非可疑锁定帧累计；suspicious
            // 帧冻结（不增不清零）——可疑状态提示用户后退，后退引起 quad
            // 变化解锁后重锁，计数自然重新开始。
            if !suspicious {
                lockedFrameCount += 1
            }
            // 诊断 trace（spec/guided-capture T001）：锁定帧事实——**记在自动
            // 快门之前**，否则自动拍的复位段会把锁定态覆盖成搜索态。
            await recordTrace(track: track)
            // 确认窗（FR-005~007）：连续非可疑锁定帧达阈值才自动快门——锁定
            // 视觉先呈现（默认 6 帧 ≈ 0.4s@15fps），窗内移开即取消；单锁定
            // 周期最多自动拍一次（didAutoCaptureThisLock 既有语义保持）；
            // 手动快门不受本窗限制（capture() 直调，无帧数门禁）。
            // spec/frame-truth FR-007：`closer`（太远/无效框）不得自动拍——
            // 稳定的 0.06 小框此前也会在 6 帧后拍出局部废片（默认关闭掩盖）。
            if preferences.autoCapture, !didAutoCaptureThisLock, !suspicious,
               directive != .closer, lockedFrameCount >= autoCaptureHoldFrames {
                didAutoCaptureThisLock = true
                await capture()
            }
        }
    }

    /// CF-T002/CF-T003：真实包络路径。检测器只给 envelope/target 观测，
    /// tracker 负责 hold/平滑/锁定；overlay 始终显示 envelope，不再因
    /// 左/右页目标暂时缺失而清空。
    private func consumeEnvelope(
        _ frame: VideoFrame,
        detector: any EnvelopeDetecting
    ) async {
        let observation = await detector.observeEnvelope(
            frame: frame,
            idCardWindow: nil,
            intent: captureIntent
        )
        let photoObservation = observation.map { observation in
            CaptureEnvelopeObservation(
                envelope: clampedToPreview(FOVLayout.convert(
                    quad: observation.envelope,
                    fromAspect: geometry.videoAspect,
                    toAspect: geometry.photoAspect
                )),
                target: observation.target.map {
                    clampedToPreview(FOVLayout.convert(
                        quad: $0,
                        fromAspect: geometry.videoAspect,
                        toAspect: geometry.photoAspect
                    ))
                },
                confidence: observation.confidence,
                intentSatisfied: observation.intentSatisfied
            )
        }
        let state = envelopeTracker.ingest(photoObservation, at: frame.timestamp)
        envelopeIsHolding = state.isHolding
        envelopeIntentSatisfied = state.intentSatisfied
        outputTargetQuad = state.target

        if let envelope = state.envelope {
            imageQuad = envelope
            presentedQuad = envelope
            frozenQuad = nil
            phase = state.phase == .locked && !state.isHolding
                ? .locked(envelope)
                : .previewing
        } else {
            imageQuad = nil
            presentedQuad = nil
            phase = .previewing
        }
        directive = GuidanceDirective.evaluate(track: state.track, hysteresis: &farHysteresis)

        // 自动快门只在 tracker 真正 locked、仍收到新观测、且目标页可靠时
        // 触发；页面意图尚未满足时，用户仍可手动拍包络，由 Review 拆分。
        let suspicious = preferences.autoCapture
            && (state.envelope?.isSuspiciousForAutoCapture() ?? true)
        if suspicious, !isAutoCaptureSuppressed, let envelope = state.envelope {
            isAutoCaptureSuppressed = true
            ZhixiaLog.suspiciousLock(area: envelope.area, minMargin: minimumEdgeMargin(of: envelope))
        } else if !suspicious {
            isAutoCaptureSuppressed = false
        }
        let canAutoCapture = preferences.autoCapture
            && !state.isHolding
            && state.phase == .locked
            && !suspicious
            && directive != .closer
            && (captureIntent == .wholePage || state.intentSatisfied)
        if canAutoCapture {
            lockedFrameCount += 1
        } else {
            lockedFrameCount = 0
        }
        await recordTrace(track: state.track)
        if canAutoCapture,
           !didAutoCaptureThisLock,
           lockedFrameCount >= autoCaptureHoldFrames {
            didAutoCaptureThisLock = true
            await capture()
        }
    }

    /// 跟踪框显示去抖（CU-T004）：相邻帧/候选的微小位移不刷新屏幕。
    /// 锁定时不经过此函数（`frozenQuad` 已经是冻结真值）；搜索/快门后清空。
    private func presented(_ candidate: Quad) -> Quad {
        guard let previous = presentedQuad else {
            presentedQuad = candidate
            return candidate
        }
        if candidate.meanVertexDistance(to: previous) < 0.004 {
            return previous
        }
        presentedQuad = candidate
        return candidate
    }

    /// 锁定框包围盒到取景框四边的最小距离（诊断日志用，与
    /// `isSuspiciousForAutoCapture` 的边距规则同口径；越界为负）。
    private func minimumEdgeMargin(of quad: Quad) -> Double {
        let bbox = quad.boundingRect
        return min(bbox.minX, bbox.minY, 1 - bbox.maxX, 1 - bbox.maxY)
    }

    /// 记录一帧取景事实（spec/guided-capture T001 / FR-007）——诊断缓冲不存在
    /// 时立即返回（release 零开销）。候选快照取检测器**本帧**发出的那一份
    /// （`latestCandidateSnapshot`），因此 trace 行与候选行严格同帧。
    private func recordTrace(track: QuadTrackState) async {
        guard let recorder = traceRecorder else { return }
        let candidate = await latestCandidateSnapshot()
        let timestamp = Date()
        recorder.record(
            CaptureTrace(
                sessionID: sessionID,
                timestamp: timestamp,
                phase: CaptureTrace.phaseName(phase),
                directive: CaptureTrace.directiveName(directive),
                geometry: .init(
                    videoAspect: geometry.videoAspect,
                    photoAspect: geometry.photoAspect
                ),
                previewSize: .init(
                    width: Double(previewSize.width),
                    height: Double(previewSize.height)
                ),
                imageQuad: imageQuad,
                frozenQuad: frozenQuad,
                guide: nil,
                cropQuad: nil,
                sticky: candidate?.disposition.map { disposition in
                    CaptureTrace.Sticky(
                        disposition: disposition,
                        missCount: candidate?.stickyMissCount ?? 0
                    )
                },
                smoother: .init(
                    track: CaptureTrace.trackName(track),
                    area: track.quad?.area,
                    frameDt: smoother.frameDt
                ),
                candidateSnapshot: candidate
            )
        )
    }

    /// 检测器最近一次候选快照（未订阅检测器时为 nil）。
    private func latestCandidateSnapshot() async -> CandidateSnapshot? {
        guard let reporting = detector as? any CandidateSnapshotReporting else { return nil }
        return await reporting.latestCandidateSnapshot()
    }

    /// 记录快门事实（裁切四角 + 相位）。诊断缓冲不存在时立即返回。
    private func recordCaptureTrace(quad: Quad) {
        guard let recorder = traceRecorder else { return }
        recorder.record(
            CaptureTrace(
                sessionID: sessionID,
                timestamp: Date(),
                phase: CaptureTrace.phaseName(.capturing),
                directive: CaptureTrace.directiveName(directive),
                geometry: .init(
                    videoAspect: geometry.videoAspect,
                    photoAspect: geometry.photoAspect
                ),
                previewSize: .init(
                    width: Double(previewSize.width),
                    height: Double(previewSize.height)
                ),
                imageQuad: imageQuad,
                frozenQuad: nil,
                guide: nil,
                cropQuad: quad,
                sticky: nil,
                smoother: nil,
                candidateSnapshot: nil
            )
        )
    }
}
