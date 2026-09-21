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
    private let fileStore: any PageFileStoring
    private let permissions: any PermissionGranting
    private let preferences: PreferencesStore
    private var smoother = QuadSmoother()
    private var frameTask: Task<Void, Never>?
    private var isDetecting = false
    private var didAutoCaptureThisLock = false
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
    private let impact = UIImpactFeedbackGenerator(style: .light)

    init(
        launch: CaptureLaunch,
        camera: any CameraCapturing,
        detector: any EdgeDetecting,
        fileStore: any PageFileStoring,
        permissions: any PermissionGranting,
        preferences: PreferencesStore,
        autoCaptureHoldFrames: Int = 6
    ) {
        self.sessionID = UUID()
        self.appendToDocumentID = launch.documentID
        self.camera = camera
        self.detector = detector
        self.fileStore = fileStore
        self.permissions = permissions
        self.preferences = preferences
        self.autoCaptureHoldFrames = autoCaptureHoldFrames
    }

    var canFinish: Bool { !drafts.isEmpty }
    var overlayIsLocked: Bool {
        if case .locked = phase { return true }
        return false
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
            phase = .previewing
            UIApplication.shared.isIdleTimerDisabled = true
            listenToFrames()
        } catch let zhixia as ZhixiaError {
            error = zhixia
        } catch {
            self.error = .cameraUnavailable
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
        phase = .previewing
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
        guard phase != .capturing else { return }
        phase = .capturing
        isFlashVisible = true
        do {
            let photo = try await camera.capturePhoto()
            // 快门时刻复记几何（FR-007）：与 AVCameraSession 的 photoGeometry
            // 实测日志对读，验收时核对缓存照片宽高比是否被逐帧校正。
            ZhixiaLog.geometry(video: geometry.videoAspect, photo: geometry.photoAspect)
            let pageID = replacePageID ?? UUID()
            _ = try await fileStore.writeOriginal(session: sessionID, page: pageID, data: photo.jpegData)
            let detected = await detector.detect(
                imageData: photo.jpegData,
                idCardWindow: mode == .idCard ? Quad.idCardWindow : nil
            )
            let quad = detected ?? imageQuad ?? .fullImage
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
        } catch let zhixia as ZhixiaError {
            error = zhixia
        } catch {
            self.error = .captureFailed
        }
        isFlashVisible = false
        smoother.reset()
        farHysteresis.reset()
        directive = .searching
        didAutoCaptureThisLock = false
        isAutoCaptureSuppressed = false
        // 确认窗复位点（plan D2 / FR-006）：手动或自动拍摄后窗口清空，
        // 下一锁定周期必须重新累计满窗才可能再次自动拍。
        lockedFrameCount = 0
        phase = .previewing
        imageQuad = mode == .idCard ? Quad.idCardWindow : nil
    }

    func importImageData(_ data: Data) async {
        let pageID = UUID()
        do {
            let jpeg = ImportedImage.jpeg(from: data) ?? data
            _ = try await fileStore.writeOriginal(session: sessionID, page: pageID, data: jpeg)
            let detected = await detector.detect(
                imageData: jpeg,
                idCardWindow: mode == .idCard ? Quad.idCardWindow : nil
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
        isDetecting = true
        defer { isDetecting = false }
        let window = mode == .idCard ? Quad.idCardWindow : nil
        let detected = await detector.detect(frame: frame, idCardWindow: window)
        // US3（plan D1）：live 检测结果是**视频 FOV** 的归一化坐标，而 PageDraft/
        // 裁剪/回放全链路消费**照片 FOV**——在摄入边界一次性换算（FR-011 单点收敛），
        // `imageQuad` 与快门回退 `detected ?? imageQuad ?? .fullImage` 天然空间一致。
        let photoDetected = detected.map {
            FOVLayout.convert(quad: $0, fromAspect: geometry.videoAspect, toAspect: geometry.photoAspect)
        }
        let track = smoother.ingest(photoDetected)
        // US6（FR-010）：四态引导与轨道态同帧推导（suspicious 优先级最高，
        // 太远经面积滞回去抖）；无 quad 帧自动复位滞回。
        directive = GuidanceDirective.evaluate(track: track, hysteresis: &farHysteresis)
        switch track {
        case .searching:
            imageQuad = window
            if phase != .capturing {
                phase = .previewing
            }
            didAutoCaptureThisLock = false
            isAutoCaptureSuppressed = false
            // 确认窗（FR-006）：进入搜索 = 锁定解除，本次拍摄取消、计数清零。
            lockedFrameCount = 0
        case .tracking(let quad):
            imageQuad = quad
            isAutoCaptureSuppressed = false
            if phase != .capturing {
                phase = .previewing
            }
            // 确认窗（FR-006）：进入跟踪 = 锁定解除，计数清零、重新计时。
            lockedFrameCount = 0
        case .locked(let quad):
            let wasLocked = overlayIsLocked
            imageQuad = quad
            if phase != .capturing {
                phase = .locked(quad)
            }
            if !wasLocked {
                impact.impactOccurred()
                // 确认窗（plan D2）：锁定周期首帧清零——重新锁定重新计时。
                lockedFrameCount = 0
            }
            // US4（plan D8）：可疑锁定门禁——照片空间 quad 近满幅/贴边时
            // 疑似书超出视场被裁切，自动快门只会拍下残页：抑制并提示后退。
            let suspicious = quad.isSuspiciousForAutoCapture()
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
            // 确认窗（FR-005~007）：连续非可疑锁定帧达阈值才自动快门——锁定
            // 视觉先呈现（默认 6 帧 ≈ 0.4s@15fps），窗内移开即取消；单锁定
            // 周期最多自动拍一次（didAutoCaptureThisLock 既有语义保持）；
            // 手动快门不受本窗限制（capture() 直调，无帧数门禁）。
            if preferences.autoCapture, !didAutoCaptureThisLock, !suspicious,
               lockedFrameCount >= autoCaptureHoldFrames {
                didAutoCaptureThisLock = true
                await capture()
            }
        }
    }

    /// 锁定框包围盒到取景框四边的最小距离（诊断日志用，与
    /// `isSuspiciousForAutoCapture` 的边距规则同口径；越界为负）。
    private func minimumEdgeMargin(of quad: Quad) -> Double {
        let bbox = quad.boundingRect
        return min(bbox.minX, bbox.minY, 1 - bbox.maxX, 1 - bbox.maxY)
    }
}
