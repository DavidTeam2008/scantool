import SwiftUI

struct DocumentView: View {
    @Bindable var viewModel: DocumentViewModel
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    @State private var showOCR = false
    @State private var ocrViewModel: OCRViewModel?
    @State private var showReconstruct = false
    @State private var reconstructViewModel: ReconstructViewModel?
    @State private var showExport = false
    @State private var showMore = false
    @State private var renameText = ""
    @State private var isRenaming = false
    @State private var confirmDelete = false
    @State private var showReorder = false
    @State private var showFolderPicker = false
    @State private var folders: [Folder] = []

    var body: some View {
        VStack(spacing: 0) {
            pagePager
            if viewModel.pages.count > 1 {
                Text("document.pageIndex \(viewModel.selectedIndex + 1) \(viewModel.pages.count)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Tokens.muted)
                    .padding(.top, 8)
                PageFilmstrip(
                    urls: viewModel.pages.map { viewModel.thumbnailURL(for: $0) },
                    selectedIndex: viewModel.selectedIndex,
                    thumbSize: CGSize(width: 52, height: 70),
                    onSelect: { viewModel.selectedIndex = $0 }
                )
                .padding(.top, 4)
            }
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    toolButton("document.text") { openOCR() }
                    toolButton("document.reconstruct") { openReconstruct() }
                }
                HStack(spacing: 12) {
                    toolButton("document.share") { showExport = true }
                    toolButton("document.add") {
                        coordinator.startCapture(appending: viewModel.documentID)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(Tokens.paper.ignoresSafeArea())
        .navigationTitle(viewModel.document?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("document.more") { showMore = true }
            }
        }
        .task { await viewModel.load() }
        .confirmationDialog("document.more", isPresented: $showMore, titleVisibility: .hidden) {
            Button("library.rename") {
                renameText = viewModel.document?.title ?? ""
                isRenaming = true
            }
            Button("library.favorite") {
                Task { await viewModel.toggleFavorite() }
            }
            Button("library.move") {
                Task {
                    folders = (try? await environment.documentStore.folders()) ?? []
                    showFolderPicker = true
                }
            }
            Button("document.reorder") { showReorder = true }
            Button("common.delete", role: .destructive) { confirmDelete = true }
            Button("common.cancel", role: .cancel) {}
        }
        .alert("library.rename", isPresented: $isRenaming) {
            TextField("library.rename", text: $renameText)
            Button("common.save") {
                Task { await viewModel.rename(renameText) }
            }
            Button("common.cancel", role: .cancel) {}
        }
        .confirmationDialog("document.delete", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("common.delete", role: .destructive) {
                Task {
                    if await viewModel.deleteDocument() {
                        dismiss()
                    }
                }
            }
            Button("common.cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showExport) {
            if let document = viewModel.document {
                ExportSheet(document: document, imageURLs: viewModel.renderedURLs())
            }
        }
        .sheet(isPresented: $showFolderPicker) {
            FolderPicker(
                folders: folders,
                onSelect: { folderID in
                    Task { await viewModel.move(to: folderID) }
                    showFolderPicker = false
                },
                onCancel: { showFolderPicker = false }
            )
        }
        .sheet(isPresented: $showReorder) {
            NavigationStack {
                List {
                    ForEach(viewModel.pages) { page in
                        Text("document.page \(page.index + 1)")
                    }
                    .onMove { source, dest in
                        Task { await viewModel.reorder(from: source, to: dest) }
                    }
                }
                .navigationTitle("document.reorder")
                .toolbar { EditButton() }
            }
            .presentationDetents([.medium])
        }
        .navigationDestination(isPresented: $showOCR) {
            if let ocrViewModel {
                OCRView(viewModel: ocrViewModel) { blob in
                    Task { await viewModel.applyOCRBlob(blob) }
                }
            }
        }
        .navigationDestination(isPresented: $showReconstruct) {
            if let reconstructViewModel {
                // US4 / R3（spec/scan-fidelity plan D4）：重建成功即回填全文 blob ——
                // 与手动 OCR（openOCR）同走 `applyOCRBlob`，重建完成的文档立即可
                // 全文检索、标题自动更新；失败不触发（ReconstructViewModel 保证）。
                ReconstructView(viewModel: reconstructViewModel) { blob in
                    Task { await viewModel.applyOCRBlob(blob) }
                }
            }
        }
    }

    @ViewBuilder
    private var pagePager: some View {
        if viewModel.pages.isEmpty {
            ProgressView().frame(maxHeight: .infinity)
        } else {
            TabView(selection: $viewModel.selectedIndex) {
                ForEach(Array(viewModel.pages.enumerated()), id: \.element.id) { index, page in
                    FileImageView(url: viewModel.renderedURL(for: page), contentMode: .fit)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .tag(index)
                        .accessibilityLabel(Text("document.page \(index + 1)"))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(maxHeight: .infinity)
        }
    }

    private func openOCR() {
        guard let document = viewModel.document else { return }
        ocrViewModel = OCRViewModel(
            document: document,
            scanPages: viewModel.pages,
            selectedIndex: viewModel.selectedIndex,
            fileStore: environment.fileStore,
            recognizer: environment.recognizer
        )
        showOCR = true
    }

    private func openReconstruct() {
        guard let document = viewModel.document else { return }
        reconstructViewModel = ReconstructViewModel(
            document: document,
            scanPages: viewModel.pages,
            fileStore: environment.fileStore,
            // 文档作用域解析器：figure/barcode 裁图落文档持久目录（plan D2 / FR-010），
            // 避免系统清理 temporaryDirectory 后导出缺图。
            parser: environment.makeReconstructParser(documentID: document.id),
            docx: environment.docx,
            searchablePDF: environment.searchablePDF
        )
        showReconstruct = true
    }

    private func toolButton(_ key: LocalizedStringResource, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(key)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color(hex: 0xEFE8DC), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(Tokens.ink)
        }
        .buttonStyle(.plain)
    }
}
