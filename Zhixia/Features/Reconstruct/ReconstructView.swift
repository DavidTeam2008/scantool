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

    /// 预览**随档位变化**（2026-09-12 修复）。
    /// 之前三档共用同一个块流渲染，用户切 A/B/C 画面纹丝不动，反馈「选了没反应」。
    /// 现在：
    /// - A 结构化：段落流（可编辑、可复制，Word 里是 inline）
    /// - B 重排版：白底 + 块按 bbox 落回原位（Word 里是 wp:anchor）
    /// - C 衬底图：页面原图作底 + 块浮在原位（Word 里是 behindDoc 衬底）
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
                case .structured:
                    ForEach(viewModel.blocks) { block in
                        blockView(block)
                    }
                case .anchored:
                    ForEach(viewModel.pages, id: \.pageID) { page in
                        LayoutCanvas(page: page, backgroundImageURL: nil)
                    }
                case .background:
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
    ///
    /// 2026-09-12：可选项收缩到 `R2OutputTier.selectable`（当前只有 A 档）。
    /// B/C 因效果不可用被下架，只剩一个选项时选择器本身没有意义，直接不渲染 ——
    /// 也让同屏的两个导出按钮上移，少占一行。恢复 B/C 只需改 `R2OutputTier.selectable`。
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

// MARK: - B / C 档版面预览

/// 把块按 `bbox` 落回原始视觉位置，用于 B（重排版）和 C（衬底图）。
///
/// 坐标换算要点：`ReconstructBlock.bbox` 是 **Vision 归一化坐标**（原点左下、y 向上），
/// SwiftUI 是原点左上、y 向下 —— y 必须翻转，否则整页上下颠倒。
private struct LayoutCanvas: View {
    let page: ReconstructPage
    /// C 档传入页面原图；B 档传 nil（用纸色底）。
    let backgroundImageURL: URL?

    private var aspect: CGFloat {
        guard page.size.width > 0, page.size.height > 0 else { return 3.0 / 4.0 }
        return page.size.width / page.size.height
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = width / aspect
            ZStack(alignment: .topLeading) {
                if let url = backgroundImageURL, let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width, height: height)
                        .clipped()
                } else {
                    Tokens.paper
                }
                ForEach(page.blocks) { block in
                    canvasBlock(block, width: width, height: height)
                }
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Tokens.line, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func canvasBlock(_ block: ReconstructBlock, width: CGFloat, height: CGFloat) -> some View {
        let box = block.bbox
        let x = box.minX * width
        let y = (1 - box.maxY) * height
        let boxWidth = max(box.width * width, 12)
        let boxHeight = max(box.height * height, 14)
        // 字号跟着块高走，视觉位置才对得上；再夹一层防止极端值炸掉
        let font = max(8, min(20, box.height * height * 0.78))
        let overImage = backgroundImageURL != nil
        let isImageBlock = block.kind == .figure || block.kind == .barcode

        Group {
            switch block.kind {
            case .figure, .barcode:
                if let path = block.figureRelativePath,
                   let image = UIImage(contentsOfFile: path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: boxWidth, height: boxHeight)
                }
            case .table:
                if let table = block.table, !table.rows.isEmpty {
                    canvasTable(table, fontSize: font)
                } else {
                    Text(block.displayText)
                        .font(.system(size: font))
                        .foregroundStyle(Tokens.ink)
                }
            case .heading:
                Text(block.text)
                    .font(.system(size: font, weight: .bold))
                    .foregroundStyle(Tokens.ink)
            default:
                Text(block.text)
                    .font(.system(size: font))
                    .foregroundStyle(Tokens.ink)
            }
        }
        .frame(width: boxWidth, height: boxHeight, alignment: .topLeading)
        // C 档文字压在扫描图上，不垫一层半透明纸底基本没法读
        .background {
            if overImage, !isImageBlock {
                Tokens.paper.opacity(0.72)
            }
        }
        .position(x: x + boxWidth / 2, y: y + boxHeight / 2)
    }

    private func canvasTable(_ table: ReconstructTable, fontSize: CGFloat) -> some View {
        let columns = max(table.columnCount, 1)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                let padded = row + Array(repeating: "", count: max(0, columns - row.count))
                HStack(spacing: 0) {
                    ForEach(0..<columns, id: \.self) { index in
                        Text(padded[index])
                            .font(.system(size: max(7, fontSize * 0.8)))
                            .foregroundStyle(Tokens.ink)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(2)
                            .border(Tokens.line, width: 0.5)
                    }
                }
            }
        }
    }
}
