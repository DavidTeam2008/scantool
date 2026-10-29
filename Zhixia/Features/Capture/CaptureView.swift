import PhotosUI
import SwiftUI

struct CaptureView: View {
    @Bindable var viewModel: CaptureViewModel
    @Environment(AppEnvironment.self) private var environment
    var onFinish: ([PageDraft]) -> Void
    var onCancel: () -> Void

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var confirmDiscard = false

    var body: some View {
        GeometryReader { proxy in
            let stage = stageSize(for: proxy.size)
            ZStack {
                VStack(spacing: 0) {
                    chromeTop
                    cameraStage(size: stage)
                    VStack(spacing: 0) {
                        guideControls
                        Spacer(minLength: 0)
                        hint
                        if !viewModel.drafts.isEmpty {
                            filmstrip
                        }
                        chromeBottom
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                if viewModel.permission == .denied {
                    permissionBanner
                }
            }
        }
        .background(Tokens.preview.ignoresSafeArea())
        .statusBarHidden()
        .task {
            await viewModel.start()
        }
        .onDisappear {
            Task { await viewModel.stop() }
        }
        .confirmationDialog("capture.discard", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("capture.discardConfirm", role: .destructive) {
                Task {
                    await viewModel.discardSession()
                    onCancel()
                }
            }
            Button("common.cancel", role: .cancel) {}
        }
        .onChange(of: photoItems) { _, items in
            Task { await importPhotos(items) }
        }
        .alert(viewModel.error?.userMessage ?? "", isPresented: cameraAlert) {
            Button("onboarding.settings") { viewModel.openSettings() }
            Button("common.cancel", role: .cancel) {}
        }
    }

    /// 取景窗尺寸（CF-T010 / FR-012）：保持运行时视频宽高比，扣除控制区
    /// 预算后取最大矩形。取景窗之外的空间留给模式/意图、提示、胶片与快门。
    ///
    /// 预算按控制区最坏情况（胶片可见 + 引导模式第二行按钮）估算；真机
    /// 截图后如有余量再收紧。取景窗比例不随预算变化——只缩小，不拉伸。
    private func stageSize(for available: CGSize) -> CGSize {
        let reserve: CGFloat = viewModel.captureMode == .guided ? 292 : 262
        let height = max(0, available.height - reserve)
        return ViewfinderLayout.fittedSize(
            in: CGSize(width: available.width, height: height),
            videoAspect: viewModel.viewfinderAspect
        )
    }

    /// 取景窗：预览、overlay、闪光共用同一容器（FR-012 的“同一域”）。
    ///
    /// 容器宽高比 == 视频宽高比时，`OverlaySpaceMap` 的 aspectFill 放置恰好
    /// 铺满容器（fill == fit），照片空间 [0,1] 就是屏幕所见画幅；`previewSize`
    /// 也由这个容器测量，因此 `visiblePhotoRect` 退化为全幅、顶点钳制不再
    /// 有实际作用（保留为防御）。
    private func cameraStage(size: CGSize) -> some View {
        ZStack {
            CameraPreviewRepresentable(attacher: environment.previewAttacher)
            overlayLayer
            if viewModel.isFlashVisible {
                Color.white.opacity(0.7)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .overlay {
            // 取景窗边界：WYSIWYG 后它就是成片边界，细线让用户看得见框沿。
            Rectangle()
                .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
        }
    }

    /// 取景叠加层（spec/guided-capture T012 / D1）——**互斥**两态：
    /// - 自动模式：既有 `EdgeOverlayView`（只读框，逐帧跟随检测结果）；
    /// - 引导模式：新的 `GuideOverlayView`（可拖动的静态框）。
    ///
    /// 两者不同时出现，也不共用交互状态——自动框 `allowsHitTesting(false)`，
    /// 引导框独立持有拖动状态（D1：避免状态语言互相污染）。
    ///
    /// ## 画布尺寸来源（CF-T010）
    /// 叠加层与预览层现在都**只铺满取景窗容器**（不再全屏 `.ignoresSafeArea()`）。
    /// 尺寸回调仍来自叠加层自己的 GeometryReader——`previewSize` 必须与
    /// 渲染空间是同一个矩形，否则屏幕↔照片换算会整体偏移（历史真机症状：
    /// 照片框 y 越界 → 引导框恒判非法）。容器宽高比 == 视频宽高比后，
    /// `previewSize` 不再需要按安全区/全屏差量修正。
    @ViewBuilder
    private var overlayLayer: some View {
        if viewModel.captureMode == .guided, viewModel.mode == .document {
            GuideOverlayView(
                guidePhotoQuad: viewModel.guidePhotoQuad,
                geometry: viewModel.geometry,
                onSizeChange: { viewModel.previewSize = $0 },
                onDrag: { viewModel.updateGuide(fromScreenQuad: $0) },
                onCommit: { quad in
                    viewModel.updateGuide(fromScreenQuad: quad)
                    viewModel.commitGuide()
                }
            )
        } else {
            EdgeOverlayView(
                imageQuad: viewModel.imageQuad,
                targetQuad: viewModel.outputTargetQuad,
                isHolding: viewModel.envelopeIsHolding,
                // CF-T010：书/页没完整进框时主框画虚线，不出白色实线。
                isFrameClipped: viewModel.isFrameClipped,
                geometry: viewModel.geometry,
                // T022：预览层探针降级为诊断对照（SC-004 证据链），不再参与渲染。
                diagnosticProbe: { size in
                    environment.previewAttacher.overlayTransform(forViewSize: size)
                },
                isLocked: viewModel.overlayIsLocked,
                mode: viewModel.mode
            )
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                viewModel.previewSize = size
            }
        }
    }

    private var chromeTop: some View {
        HStack {
            Button("common.close") { attemptCancel() }
                .foregroundStyle(Color.white.opacity(0.9))
            Spacer()
            HStack(spacing: 8) {
                modeButton(.document, title: "capture.mode.document")
                Text("·").foregroundStyle(Color.white.opacity(0.4))
                modeButton(.idCard, title: "capture.mode.id")
            }
            Spacer()
            Button(viewModel.torchOn ? "capture.torchOn" : "capture.torch") {
                Task { await viewModel.toggleTorch() }
            }
            .foregroundStyle(Color.white.opacity(0.9))
        }
        .font(.system(size: 15, weight: .semibold))
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    private func modeButton(_ mode: ScanMode, title: LocalizedStringResource) -> some View {
        Button(title) {
            viewModel.setMode(mode)
        }
        .foregroundStyle(viewModel.mode == mode ? Color.white : Color.white.opacity(0.45))
    }

    /// 取景控制条（spec/guided-capture T012 / CF-T010）——文档模式才出现：
    /// 取景模式（自动 / 引导）+ 拍摄意图（右页 / 左页 / 整页）合并为**一行**
    /// （4:3 取景窗让出纵向空间）；引导模式的对位/撤销操作作为第二行只在
    /// 引导模式出现。证件模式整行隐藏（D1）。
    @ViewBuilder
    private var guideControls: some View {
        if viewModel.mode == .document {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(CaptureMode.allCases, id: \.self) { mode in
                        guideChip(title: mode.title, isOn: viewModel.captureMode == mode) {
                            viewModel.setCaptureMode(mode)
                        }
                    }
                    Rectangle()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: 1, height: 18)
                    // CU-T003：意图不只属于引导模式。自动模式也必须能一眼选
                    // 左页/右页/整页；否则自动候选只能猜整书，左页永远定不住。
                    ForEach(CaptureIntent.allCases, id: \.self) { intent in
                        guideChip(title: intent.title, isOn: viewModel.captureIntent == intent) {
                            viewModel.setCaptureIntent(intent)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if viewModel.captureMode == .guided {
                    HStack(spacing: 12) {
                        Button("capture.guide.reset") {
                            viewModel.resetGuide()
                        }
                        Button("capture.guide.autoFit") {
                            Task { await viewModel.autoFitGuide() }
                        }
                        if viewModel.canUndoAutoFit {
                            Button("capture.guide.undo") {
                                viewModel.undoAutoFit()
                            }
                        }
                        Spacer()
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.top, 6)
            .padding(.horizontal, 16)
        }
    }

    /// 引导模式胶囊按钮（选中 = 白底黑字，未选中 = 半透明底白字）。
    private func guideChip(
        title: LocalizedStringResource,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isOn ? Color.white.opacity(0.85) : Color.black.opacity(0.25))
                .foregroundStyle(isOn ? Color.black.opacity(0.85) : Color.white.opacity(0.9))
                .clipShape(Capsule())
        }
    }

    private var hint: some View {
        Text(hintText)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color(hex: 0xF0D0C4))
            .padding(.bottom, 8)
            .accessibilityAddTraits(.updatesFrequently)
    }

    private var hintText: LocalizedStringResource {
        // 证件模式：正/反面提示优先（模式语义，不参与四态引导）。
        if viewModel.mode == .idCard {
            return viewModel.idFace == .front ? "capture.hint.front" : "capture.hint.back"
        }
        // 引导模式（spec/guided-capture T012）：隐藏自动四态提示（那是检测语义，
        // 与「用户框住什么就拍什么」冲突），改为固定对位提示。
        if viewModel.captureMode == .guided {
            return viewModel.isGuideReady ? "capture.hint.guided" : "capture.hint.guidedNotReady"
        }
        // CF-T011：近距单页允许拍摄时，directive 仍可能是 backOff（包络贴边）。
        // 快门已可用、白框已锁定 → 提示与快门一致，不再让用户后退。
        if viewModel.isCaptureReady, viewModel.overlayIsLocked {
            return "capture.hint.locked"
        }
        // US6（spec/scan-fidelity / FR-010）：文档模式四态方向引导——
        // 太近/可疑后退 · 太远靠近 · 对准 · 寻找；面积滞回防闪烁
        //（判定在 ViewModel 逐帧推导，可疑优先级最高）。
        switch viewModel.directive {
        case .backOff:
            return "capture.hint.suspicious"
        case .closer:
            return "capture.hint.tooFar"
        case .locked:
            return "capture.hint.locked"
        case .searching:
            return "capture.hint.search"
        }
    }

    private var filmstrip: some View {
        PageFilmstrip(
            urls: viewModel.drafts.map {
                environment.fileStore.originalURL(session: $0.sessionID, page: $0.id)
            },
            selectedIndex: viewModel.drafts.count - 1,
            onSelect: { _ in },
            onDelete: { index in
                viewModel.deleteDraft(at: index)
            }
        )
        .opacity(viewModel.drafts.isEmpty ? 0 : 1)
    }

    private var chromeBottom: some View {
        HStack {
            PhotosPicker(selection: $photoItems, maxSelectionCount: 12, matching: .images) {
                Text("capture.album")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xF0D0C4))
                    .frame(width: 52)
            }
            Spacer()
            ShutterButton(enabled: shutterEnabled) {
                Task { await viewModel.capture() }
            }
            Spacer()
            Button {
                if let drafts = viewModel.finish() {
                    onFinish(drafts)
                }
            } label: {
                Text(viewModel.canFinish ? "capture.done \(viewModel.drafts.count)" : "capture.done")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xF0D0C4))
                    .opacity(viewModel.canFinish ? 1 : 0.35)
                    .frame(width: 52)
            }
            .disabled(!viewModel.canFinish)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
    }

    /// 快门可用性（spec/guided-capture T012 / D2）：引导模式下**画布未就绪
    /// 或框非法时置灰**——「首次就绪前快门置灰」，不猜映射、不拍错片。
    private var shutterEnabled: Bool {
        guard viewModel.phase != .capturing else { return false }
        if viewModel.captureMode == .guided, viewModel.mode == .document {
            return viewModel.isGuideReady
        }
        // CF-T002 / CF-T004：自动包络路径没有找到书/页面时不假装能拍；
        // tracker hold 的上一帧残影也不是这一帧的裁切真值——两者都置灰，
        // 避免快门再回退 fullImage 或拍下过期框。
        if viewModel.captureMode == .auto, viewModel.mode == .document {
            return viewModel.isCaptureReady
        }
        return true
    }

    private var permissionBanner: some View {        VStack(spacing: 12) {
            Text("error.cameraDenied")
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.white)
            Button("onboarding.settings") {
                viewModel.openSettings()
            }
            .buttonStyle(.borderedProminent)
            .tint(Tokens.seal)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(24)
    }

    private var cameraAlert: Binding<Bool> {
        Binding(
            get: {
                viewModel.error == .cameraDenied || viewModel.error == .cameraUnavailable
            },
            set: { presented in
                if !presented { viewModel.error = nil }
            }
        )
    }

    private func attemptCancel() {
        if viewModel.drafts.isEmpty {
            onCancel()
        } else {
            confirmDiscard = true
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                await viewModel.importImageData(data)
            }
        }
        photoItems = []
    }
}

extension ZhixiaError: Identifiable {
    var id: String { userMessage }
}
