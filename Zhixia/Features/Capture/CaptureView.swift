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
        ZStack {
            Tokens.preview.ignoresSafeArea()
            CameraPreviewRepresentable(attacher: environment.previewAttacher)
                .ignoresSafeArea()
            overlayLayer
            if viewModel.isFlashVisible {
                Color.white.opacity(0.7).ignoresSafeArea()
            }
            VStack {
                chromeTop
                guideControls
                Spacer()
                hint
                filmstrip
                chromeBottom
            }
            if viewModel.permission == .denied {
                permissionBanner
            }
        }
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

    /// 取景叠加层（spec/guided-capture T012 / D1）——**互斥**两态：
    /// - 自动模式：既有 `EdgeOverlayView`（只读框，逐帧跟随检测结果）；
    /// - 引导模式：新的 `GuideOverlayView`（可拖动的静态框）。
    ///
    /// 两者不同时出现，也不共用交互状态——自动框 `allowsHitTesting(false)`，
    /// 引导框独立持有拖动状态（D1：避免状态语言互相污染）。
    ///
    /// ## 画布尺寸来源（spec/frame-truth 真机复测的延续）
    /// 叠加层**必须**与预览层共用同一全屏坐标系（`.ignoresSafeArea()`）。
    /// 但**尺寸回调必须来自叠加层自己的 GeometryReader**——父层的
    /// `onGeometryChange` 量到的是安全区尺寸（真机 402×778 vs 全屏 402×874），
    /// 用它做屏幕↔照片换算会让引导框整体偏移（照片框 y 越界 → 恒判非法）。
    /// 自动路径保持原有测量口径不变（FR-009：自动路径零改动）。
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
            .ignoresSafeArea()
        } else {
            EdgeOverlayView(
                imageQuad: viewModel.imageQuad,
                targetQuad: viewModel.outputTargetQuad,
                isHolding: viewModel.envelopeIsHolding,
                geometry: viewModel.geometry,
                // T022：预览层探针降级为诊断对照（SC-004 证据链），不再参与渲染。
                diagnosticProbe: { size in
                    environment.previewAttacher.overlayTransform(forViewSize: size)
                },
                isLocked: viewModel.overlayIsLocked,
                mode: viewModel.mode
            )
            .ignoresSafeArea()
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
        .padding(.top, 8)
    }

    private func modeButton(_ mode: ScanMode, title: LocalizedStringResource) -> some View {
        Button(title) {
            viewModel.setMode(mode)
        }
        .foregroundStyle(viewModel.mode == mode ? Color.white : Color.white.opacity(0.45))
    }

    /// 引导取景控制条（spec/guided-capture T012）——文档模式才出现：
    /// 取景模式（自动 / 引导）+ 拍摄意图（右页 / 左页 / 整页）+ 框操作
    /// （重置 / 自动对位 / 撤销）。证件模式整行隐藏（D1）。
    @ViewBuilder
    private var guideControls: some View {
        if viewModel.mode == .document {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(CaptureMode.allCases, id: \.self) { mode in
                        guideChip(title: mode.title, isOn: viewModel.captureMode == mode) {
                            viewModel.setCaptureMode(mode)
                        }
                    }
                    Spacer()
                }
                // CU-T003：意图不只属于引导模式。自动模式也必须能一眼选
                // 左页/右页/整页；否则自动候选只能猜整书，左页永远定不住。
                HStack(spacing: 6) {
                    ForEach(CaptureIntent.allCases, id: \.self) { intent in
                        guideChip(title: intent.title, isOn: viewModel.captureIntent == intent) {
                            viewModel.setCaptureIntent(intent)
                        }
                    }
                    Spacer()
                    if viewModel.captureMode == .guided {
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
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.9))
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.top, 6)
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
