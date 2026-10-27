import SwiftUI

struct ReviewView: View {
    @Bindable var viewModel: ReviewViewModel
    var onSaved: (UUID) -> Void
    var onRetake: (UUID) -> Void
    var onCancel: () -> Void

    @State private var confirmDelete = false

    var body: some View {
        ZStack {
            Tokens.preview.ignoresSafeArea()
            VStack(spacing: 8) {
                header
                pageDots
                canvas
                splitSuggestion
                tools
                FilterStrip(selected: viewModel.current?.enhancement ?? .enhance) { enhancement in
                    viewModel.setFilter(enhancement)
                }
                .onLongPressGesture {
                    viewModel.applyFilterToAll()
                }
            }
            if viewModel.isSaving {
                ProgressView()
                    .tint(.white)
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .onAppear {
            viewModel.appear()
        }
        .confirmationDialog("review.deletePage", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("common.delete", role: .destructive) {
                viewModel.deleteCurrent()
            }
            Button("common.cancel", role: .cancel) {}
        }
        .alert("error.storeFailed", isPresented: storeAlert) {
            Button("common.ok", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack {
            Button("common.back", action: onCancel)
                .foregroundStyle(Color(hex: 0xF0A39A))
            Spacer()
            Text("review.title")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.white)
            Spacer()
            Button("common.save") {
                Task {
                    if let id = await viewModel.save() {
                        onSaved(id)
                    }
                }
            }
            .fontWeight(.semibold)
            .foregroundStyle(Color.white)
            .disabled(!viewModel.canSave)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(viewModel.drafts.indices, id: \.self) { index in
                Capsule()
                    .fill(index == viewModel.selectedIndex ? Tokens.seal : Color.white.opacity(0.25))
                    .frame(width: index == viewModel.selectedIndex ? 16 : 6, height: 6)
                    .onTapGesture { viewModel.select(index: index) }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var canvas: some View {
        if viewModel.isAdjustingSplit, let original = viewModel.originalImage {
            // 拆分工具（spec/guided-capture T021 / FR-008）：在**矫正前的原图**
            // 上画可见分割线；系统只给建议，用户点「应用」才改写裁切框。
            ReviewSplitCanvas(
                image: original,
                proposal: viewModel.splitProposal,
                onUChange: { viewModel.updateSplitU($0) },
                onSelectOption: { viewModel.selectSplitOption($0) },
                onApply: {
                    viewModel.applySplit(viewModel.splitProposal?.selection ?? .right)
                    viewModel.isAdjustingSplit = false
                },
                onCancel: { viewModel.isAdjustingSplit = false },
                canUndo: viewModel.canUndoSplit,
                onUndo: { viewModel.undoSplit() }
            )
        } else if viewModel.isAdjustingCrop, let original = viewModel.originalImage {
            CropCanvas(
                image: original,
                quad: Binding(
                    get: { viewModel.current?.quad ?? .fullImage },
                    set: { viewModel.updateQuad($0) }
                ),
                onChanged: {},
                onEnded: {}
            )
            .padding(.horizontal, 16)
        } else if let preview = viewModel.previewImage {
            Image(uiImage: preview)
                .resizable()
                .scaledToFit()
                .padding(.horizontal, 16)
                .shadow(radius: 16)
                .onTapGesture {
                    viewModel.beginCrop()
                }
        } else if let original = viewModel.originalImage {
            Image(uiImage: original)
                .resizable()
                .scaledToFit()
                .padding(.horizontal, 16)
                .opacity(0.92)
                .onTapGesture {
                    viewModel.beginCrop()
                }
        } else {
            ProgressView().tint(.white).frame(maxHeight: .infinity)
        }
    }

    /// CU-T007：拍后安全网——整理页第一屏显示拆分建议，用户点选才写框。
    /// 这里不自动应用、不改 quad；只是把已有的 `SplitProposal` 变成可见入口。
    @ViewBuilder
    private var splitSuggestion: some View {
        if let proposal = viewModel.splitProposal,
           !viewModel.isAdjustingSplit,
           !viewModel.isAdjustingCrop {
            HStack(spacing: 10) {
                Text("review.split")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.75))
                Spacer()
                ForEach(SplitProposal.Selection.allCases, id: \.self) { selection in
                    Button(title(for: selection)) {
                        viewModel.applySplit(selection)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(proposal.selection == selection ? Tokens.seal : Color.white.opacity(0.75))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private func title(for selection: SplitProposal.Selection) -> LocalizedStringResource {
        switch selection {
        case .whole: "review.split.whole"
        case .left: "review.split.left"
        case .right: "review.split.right"
        }
    }

    private var tools: some View {
        HStack(spacing: 24) {
            Button("review.rotate") { viewModel.rotate() }
                .foregroundStyle(Color.white.opacity(0.85))
            Button("review.crop") { viewModel.toggleCrop() }
                .foregroundStyle(viewModel.isAdjustingCrop ? Tokens.seal : Color.white.opacity(0.85))
            Button("review.split") { viewModel.toggleSplitTool() }
                .foregroundStyle(viewModel.isAdjustingSplit ? Tokens.seal : Color.white.opacity(0.85))
            Button("review.retake") {
                if let id = viewModel.current?.id {
                    onRetake(id)
                }
            }
            .foregroundStyle(Color.white.opacity(0.85))
            Button("common.delete") { confirmDelete = true }
                .foregroundStyle(Color(hex: 0xF0A39A))
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(.top, 4)
    }

    private var storeAlert: Binding<Bool> {
        Binding(
            get: { viewModel.error != nil },
            set: { if !$0 { viewModel.error = nil } }
        )
    }
}
