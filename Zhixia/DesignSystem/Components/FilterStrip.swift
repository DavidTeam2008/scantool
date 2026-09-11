import SwiftUI

struct FilterStrip: View {
    var selected: Enhancement
    var onSelect: (Enhancement) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Enhancement.allCases, id: \.self) { enhancement in
                    Button {
                        onSelect(enhancement)
                    } label: {
                        Text(enhancement.title)
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                enhancement == selected ? Tokens.seal : Color.white.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .foregroundStyle(enhancement == selected ? Color.white : Color.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        .accessibilityElement(children: .contain)
    }
}

extension Enhancement {
    var title: LocalizedStringResource {
        switch self {
        case .original: "filter.original"
        case .enhance: "filter.enhance"
        case .deskewShadow: "filter.shadow"
        case .grayscale: "filter.gray"
        case .blackWhite: "filter.bw"
        }
    }
}
