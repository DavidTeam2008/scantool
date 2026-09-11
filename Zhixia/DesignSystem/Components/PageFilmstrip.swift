import SwiftUI

struct PageFilmstrip: View {
    let urls: [URL]
    var selectedIndex: Int
    var thumbSize: CGSize = CGSize(width: 36, height: 48)
    var onSelect: (Int) -> Void
    var onDelete: ((Int) -> Void)?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                        Button {
                            onSelect(index)
                        } label: {
                            FileImageView(url: url, contentMode: .fill)
                                .frame(width: thumbSize.width, height: thumbSize.height)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(
                                            index == selectedIndex ? Tokens.seal : Tokens.line,
                                            lineWidth: index == selectedIndex ? 2.5 : 1
                                        )
                                }
                        }
                        .buttonStyle(.plain)
                        .frame(minWidth: 48, minHeight: 64)
                        .contentShape(Rectangle())
                        .id(index)
                        .accessibilityLabel(Text("document.page \(index + 1)"))
                        .contextMenu {
                            if let onDelete {
                                Button(role: .destructive) {
                                    onDelete(index)
                                } label: {
                                    Text("common.delete")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .onChange(of: selectedIndex) { _, index in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
        .frame(height: max(64, thumbSize.height + 16))
    }
}
