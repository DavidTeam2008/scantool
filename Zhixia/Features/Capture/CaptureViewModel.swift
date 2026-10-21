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
    var previewSize: CGSize = .zero
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
        // WYSIWYG 门禁呈现框快照（spec/wysiwyg-crop，plan D2 / FR-001）：入口
        // 读取 `imageQuad`——必须在任何复位段之前（capture() 末尾会清空）。
        // `imageQuad` 即 overlay 渲染源（照片空间：跟踪 = smoother 输出 /
        // 锁定 = 冻结框 / 搜索 = nil），与屏幕所见同源；`consume()` 的
        // `phase != .capturing` 闸在 capturing 期间冻结帧消费 → 快照 =
        // 快门时刻屏幕所见，瞬时检测缺口不会使其回退静帧自由检测。
        // spec/frame-truth FR-007：`closer`（太远/无效框）时呈现框不可拍摄，
        // 按搜索态处理（静帧自由检测兜底）——避免把屏幕上的局部小框裁成废片。
        let displayed = (mode == .idCard || directive != .closer) ? imageQuad : nil
        phase = .capturing
        isFlashVisible = true
        do {
            let photo = try await camera.capturePhoto()
            // 快门时刻复记几何（FR-007）：与 AVCameraSession 的 photoGeometry
            // 实测日志对读，验收时核对缓存照片宽高比是否被逐帧校正。
            ZhixiaLog.geometry(video: geometry.videoAspect, photo: geometry.photoAspect)
            let pageID = replacePageID ?? UUID()
            _ = try await fileStore.writeOriginal(session: sessionID, page: pageID, data: photo.jpegData)
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
                    idCardWindow: nil
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
        } catch let zhixia as ZhixiaError {
            error = zhixia
        } catch {
            self.error = .captureFailed
        }
        isFlashVisible = false
        smoother.reset()
        farHysteresis.reset()
        frozenQuad = nil
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
        // spec/frame-stability：文档形态 live **逐帧轻量贴边吸附**——每边吸到
        // 最近的亮度边缘（最近峰策略：左缘稳定命中折痕而不是更强的折脊轮廓），
        // 再交给 smoother 做时域稳定。1080p 帧 + 160 列栅格，单帧约 1–2ms；
        // 吸附后的四边持续贴在真实边缘上，是「框贴边 + 不抖」的供给侧修复。
        let snapped = mode == .document
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
        let track = smoother.ingest(photoDetected)
        // US6（FR-010）：四态引导与轨道态同帧推导（suspicious 优先级最高，
        // 太远经面积滞回去抖）；无 quad 帧自动复位滞回。
        directive = GuidanceDirective.evaluate(track: track, hysteresis: &farHysteresis)
        switch track {
        case .searching:
            frozenQuad = nil
            imageQuad = window
            if phase != .capturing {
                phase = .previewing
            }
            didAutoCaptureThisLock = false
            isAutoCaptureSuppressed = false
            // 确认窗（FR-006）：进入搜索 = 锁定解除，本次拍摄取消、计数清零。
            lockedFrameCount = 0
        case .tracking(let quad):
            frozenQuad = nil
            imageQuad = quad
            isAutoCaptureSuppressed = false
            if phase != .capturing {
                phase = .previewing
            }
            // 确认窗（FR-006）：进入跟踪 = 锁定解除，计数清零、重新计时。
            lockedFrameCount = 0
        case .locked(let quad):
            let wasLocked = phaseIsLocked
            // spec/frame-truth FR-005（锁定冻结 + 精修上屏）：锁定态**首次**
            // 进入时，用当前帧检测（视频空间）对当前帧图像做一次有界吸附，
            // 结果经 FOV 反算为照片空间后上屏并冻结——贴边修正只发生在
            // 快门前且用户可见；锁定期间 smoother 再插值也不再改变呈现框。
            // 冻结种子取当前帧 detected 而非 smoother 平滑框（红队：手在动
            // 时平滑框与画面有相位差，对着错位的边吸附）。
            if !wasLocked, frozenQuad == nil, directive != .closer, let detected {
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
                let snappedPhoto = clampedToPreview(FOVLayout.convert(
                    quad: snappedVideo,
                    fromAspect: geometry.videoAspect,
                    toAspect: geometry.photoAspect
                ))
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

    /// 锁定框包围盒到取景框四边的最小距离（诊断日志用，与
    /// `isSuspiciousForAutoCapture` 的边距规则同口径；越界为负）。
    private func minimumEdgeMargin(of quad: Quad) -> Double {
        let bbox = quad.boundingRect
        return min(bbox.minX, bbox.minY, 1 - bbox.maxX, 1 - bbox.maxY)
    }
}
