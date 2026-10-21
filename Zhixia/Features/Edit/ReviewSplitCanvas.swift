import SwiftUI

/// 拆分画布（spec/guided-capture T021 / FR-008 / plan D5）。
///
/// 在**矫正前的原图**上画一条可见的竖分割线：
/// - 分割线可拖（改 `u`，只改提案，不改裁切框）；
/// - 置信度 ≥0.5 实线（可直接应用），<0.5 虚线 + 弱提示（仍可手动拖线后应用）；
/// - 底部三个选择：整页 / 左页 / 右页 + 「应用」/「取消」；
/// - 没有提案时（系统没找到书脊/折条）给出手动分割（默认 u=0.5）。
///
/// 关键约束：**预览不显示任何"已应用"的裁切**——分割只是建议，点了「应用」
/// 之后才改写 `draft.quad`，且可撤销。
struct ReviewSplitCanvas: View {
    /// 原图（矫正前）。
    let image: UIImage
    /// 当前提案（nil = 无建议 → 手动分割模式）。
    let proposal: SplitProposal?
    /// 分割线位置（拖动回调）。
    let onUChange: (Double) -> Void
    /// 选择回调（整页/左页/右页）——**只改高亮，不写 quad**。
    let onSelectOption: (SplitProposal.Selection) -> Void
    /// 应用回调（用户确认后才写 quad）。
    let onApply: () -> Void
    /// 取消（关闭拆分工具）。
    let onCancel: () -> Void
    /// 撤销上一次应用。
    var canUndo: Bool = false
    var onUndo: () -> Void = {}

    /// 手动模式下的分割线位置（无提案时由本地状态持有）。
    @State private var manualU: Double = 0.5

    private var currentU: Double {
        proposal?.u ?? manualU
    }

    private var isConfident: Bool {
        (proposal?.confidence ?? 0) >= SplitProposalConfidence.applyThreshold
    }

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { proxy in
                let size = proxy.size
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size.width, height: size.height)
                    splitLine(in: size)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let u = min(1, max(0, value.location.x / max(1, size.width)))
                            if proposal != nil {
                                onUChange(u)
                            } else {
                                manualU = u
                            }
                        }
                )
            }
            .frame(minHeight: 180)

            HStack(spacing: 12) {
                splitButton(.whole, "review.split.whole")
                splitButton(.left, "review.split.left")
                splitButton(.right, "review.split.right")
            }
            .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 12) {
                if canUndo {
                    Button("review.split.undo", action: onUndo)
                        .foregroundStyle(Tokens.seal)
                }
                Spacer()
                Button("common.cancel", action: onCancel)
                    .foregroundStyle(Color.white.opacity(0.8))
                Button("review.split.apply", action: onApply)
                    .foregroundStyle(Tokens.seal)
            }
            .font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 16)
    }

    /// 分割线（实线 = 高置信；虚线 = 低置信提示）。
    @ViewBuilder
    private func splitLine(in size: CGSize) -> some View {
        let x = currentU * size.width
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(isConfident ? Tokens.seal : Tokens.seal.opacity(0.45))
                .frame(width: isConfident ? 2 : 1)
                .frame(maxHeight: .infinity)
                .overlay {
                    if !isConfident {
                        Rectangle()
                            .stroke(
                                Tokens.seal.opacity(0.45),
                                style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                            )
                            .frame(width: 1)
                    }
                }
                .offset(x: x)
            Circle()
                .fill(Tokens.seal)
                .frame(width: 14, height: 14)
                .offset(x: x - 7)
        }
    }

    /// 选择按钮（当前选择高亮；点击只改选择，不写裁切框）。
    private func splitButton(_ selection: SplitProposal.Selection, _ title: LocalizedStringResource) -> some View {
        let isOn = (proposal?.selection ?? .right) == selection
        return Button(title) {
            onSelectOption(selection)
        }
        .foregroundStyle(isOn ? Tokens.seal : Color.white.opacity(0.75))
    }
}
