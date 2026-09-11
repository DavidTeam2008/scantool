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
            EdgeOverlayView(
                imageQuad: viewModel.imageQuad,
                imageSize: viewModel.frameSize,
                isLocked: viewModel.overlayIsLocked,
                mode: viewModel.mode
            )
            if viewModel.isFlashVisible {
                Color.white.opacity(0.7).ignoresSafeArea()
            }
            VStack {
                chromeTop
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

    private var hint: some View {
        Text(hintText)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color(hex: 0xF0D0C4))
            .padding(.bottom, 8)
            .accessibilityAddTraits(.updatesFrequently)
    }

    private var hintText: LocalizedStringResource {
        if viewModel.mode == .idCard {
            return viewModel.idFace == .front ? "capture.hint.front" : "capture.hint.back"
        }
        if viewModel.overlayIsLocked {
            return "capture.hint.locked"
        }
        return "capture.hint.search"
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
            ShutterButton(enabled: viewModel.phase != .capturing) {
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

    private var permissionBanner: some View {
        VStack(spacing: 12) {
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
