import SwiftUI
import UIKit

struct ReconstructView: View {
    @Bindable var viewModel: ReconstructViewModel

    /// US4 / R3（spec/scan-fidelity plan D4）：重建成功后的全文回填回调，
    /// 透传给 `viewModel.onContentReady` —— `DocumentView` 用它把 blob 送进
    /// `DocumentViewModel.applyOCRBlob`（与手动 OCR 同一条落库路径）。
    /// 默认 nil：既有调用点 / SwiftUI 预览零破坏。
    var onContentReady: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("reconstruct.localHint")
                .font(.caption)
                .foregroundStyle(Tokens.muted)
                .padding(.horizontal, Tokens.horizontalPadding)

            if viewModel.isWorking {
                ProgressView("reconstruct.working")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !viewModel.hasContent {
                ContentUnavailableView {
                    Label("reconstruct.emptyTitle", systemImage: "doc.text.image")
                } description: {
                    Text(viewModel.error?.userMessage ?? String(localized: "error.reconstructFailed"))
                } actions: {
                    Button("reconstruct.retry") {
                        Task { await viewModel.reconstruct() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Tokens.seal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                preview
            }
        }
        .background(Tokens.paper.ignoresSafeArea())
        .navigationTitle("reconstruct.title")
        .safeAreaInset(edge: .bottom) {
            if viewModel.hasContent, !viewModel.isWorking {
                exportBar
            }
        }
        .task {
            // US4：先接线再重建 —— 回调必须在首次 `reconstruct()` 成功前就位；
            // 失败重试（reconstruct.retry）路径复用已接线的回调。
            viewModel.onContentReady = onContentReady
            if viewModel.reconstructed == nil, !viewModel.isWorking {
                await viewModel.reconstruct()
            }
        }
        .onDisappear {
            viewModel.cleanupExports()
        }
        .alert("error.exportFailed", isPresented: Binding(
            get: { viewModel.error == .exportFailed },
            set: { if !$0 { viewModel.error = nil } }
        )) {
            Button("common.ok", role: .cancel) {}
        }
    }

    /// 预览**随档位变化**。
    /// - `restored` 版面还原：`LayoutCanvas` 三层渲染 —— 整页底座（页面 rendered 图，
    ///   下采样 aspect-fit）→ LayoutMask 净化覆盖层 → 元素原位层（figure/barcode/artwork
    ///   不绘制，底座原像素透出）
    /// - `structured` 结构化：段落流（可编辑、可复制，Word 里是段落 + inline 图）
    private var preview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if viewModel.needsCloudHint {
                    Text("reconstruct.cloudHint")
                        .font(.footnote)
                        .foregroundStyle(Tokens.muted)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(hex: 0xEFE8DC), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                switch viewModel.outputTier {
                case .restored:
                    ForEach(viewModel.pages, id: \.pageID) { page in
                        LayoutCanvas(
                            page: page,
                            backgroundImageURL: viewModel.pageImageURL(for: page.pageID)
                        )
                    }
                    if viewModel.pages.contains(where: { viewModel.pageImageURL(for: $0.pageID) == nil }) {
                        Text("reconstruct.tierBackgroundMissingImage")
                            .font(.caption2)
                            .foregroundStyle(Tokens.muted)
                    }
                case .structured:
                    ForEach(viewModel.blocks) { block in
                        blockView(block)
                    }
                }
            }
            .padding(.horizontal, Tokens.horizontalPadding)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private func blockView(_ block: ReconstructBlock) -> some View {
        switch block.kind {
        case .heading:
            Text(block.text)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Tokens.ink)
        case .table:
            if let table = block.table, !table.rows.isEmpty {
                tableGrid(table)
            } else {
                Text(block.displayText)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(Tokens.ink)
            }
        case .figure, .barcode:
            VStack(alignment: .leading, spacing: 6) {
                if let path = block.figureRelativePath,
                    let image = UIImage(contentsOfFile: path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                let caption = block.kind == .barcode ? (block.barcodePayload ?? block.text) : block.text
                if !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(Tokens.muted)
                }
            }
        case .artwork:
            // 结构化档忽略 artwork 块（plan D9）：无独立裁图、无文本
            // （乱码行已在解析层剔除）；原像素只在版面还原档经底座呈现。
            EmptyView()
        default:
            Text(block.text)
                .font(.system(size: 16))
                .foregroundStyle(Tokens.ink)
        }
    }

    private func tableGrid(_ table: ReconstructTable) -> some View {
        let columns = max(table.columnCount, 1)
        return Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                let padded = row + Array(repeating: "", count: max(0, columns - row.count))
                GridRow {
                    ForEach(0..<columns, id: \.self) { index in
                        Text(padded[index])
                            .font(.system(size: 13))
                            .foregroundStyle(Tokens.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .border(Tokens.line, width: 0.5)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var exportBar: some View {
        VStack(spacing: 10) {
            tierPicker
            if viewModel.isExporting {
                ProgressView()
                    .padding(.vertical, 8)
            }
            exportButton(
                title: "reconstruct.exportDocx",
                url: viewModel.docxURL,
                prominent: true
            ) {
                Task { await viewModel.exportDocx() }
            }
            exportButton(
                title: "reconstruct.exportPDF",
                url: viewModel.pdfURL,
                prominent: false
            ) {
                Task { await viewModel.exportPDF() }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Tokens.paper)
    }

    /// 档位选择器：版面还原（默认）/ 结构化。
    /// 切档会走 `viewModel.setTier`，把已导出的 docx 作废，提示用户重新导出。
    ///
    /// 2026-09-18：`R2OutputTier.selectable` 恢复为两项（spec/layout-restore D1/FR-006），
    /// 选择器恢复渲染；旧 B/C 档（重排版/衬底图）已从枚举中删除。
    @ViewBuilder
    private var tierPicker: some View {
        if R2OutputTier.selectable.count > 1 {
            VStack(alignment: .leading, spacing: 4) {
                Picker("reconstruct.tier", selection: tierBinding) {
                    ForEach(R2OutputTier.selectable, id: \.self) { tier in
                        Text(tier.displayName).tag(tier)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("reconstruct.tier")
                Text("reconstruct.tierHint")
                    .font(.caption2)
                    .foregroundStyle(Tokens.muted)
            }
        }
    }

    private var tierBinding: Binding<R2OutputTier> {
        Binding(
            get: { viewModel.outputTier },
            set: { viewModel.setTier($0) }
        )
    }

    @ViewBuilder
    private func exportButton(
        title: LocalizedStringResource,
        url: URL?,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        if let url {
            ShareLink(item: url) {
                exportLabel(title, prominent: prominent)
            }
        } else {
            Button(action: action) {
                exportLabel(title, prominent: prominent)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isExporting)
        }
    }

    private func exportLabel(_ title: LocalizedStringResource, prominent: Bool) -> some View {
        Text(title)
            .font(.system(size: 16, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                prominent ? Tokens.seal : Color(hex: 0xEFE8DC),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .foregroundStyle(prominent ? Color.white : Tokens.ink)
    }
}

// 版面还原档的预览画布已重写为独立文件 `LayoutCanvas.swift`（三层渲染，
// spec/layout-restore plan D6）：底座下采样 aspect-fit → LayoutMask 覆盖层 →
// 元素原位层，坐标经 PageLayoutMapper；对外接口 `LayoutCanvas(page:backgroundImageURL:)` 不变。
