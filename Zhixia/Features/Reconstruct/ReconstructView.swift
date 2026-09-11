import SwiftUI
import UIKit

struct ReconstructView: View {
    @Bindable var viewModel: ReconstructViewModel

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
                ForEach(viewModel.blocks) { block in
                    blockView(block)
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

    /// M4 档位选择器：A 结构化 / B 重排版 / C 衬底图。
    /// 切档会走 `viewModel.setTier`，把已导出的 docx 作废，提示用户重新导出。
    private var tierPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("reconstruct.tier", selection: tierBinding) {
                ForEach(R2OutputTier.allCases, id: \.self) { tier in
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
