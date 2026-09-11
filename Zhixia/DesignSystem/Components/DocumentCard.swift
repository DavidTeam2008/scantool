import SwiftUI
import UIKit

struct DocumentCard: View {
    let title: String
    let subtitle: String
    let imageURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FileImageView(url: imageURL, contentMode: .fill)
                .frame(height: 128)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.coverRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.coverRadius, style: .continuous)
                        .stroke(Tokens.line, lineWidth: 1)
                }
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Tokens.ink)
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Tokens.muted)
                .lineLimit(1)
        }
        .padding(8)
        .background(Tokens.card, in: RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct FileImageView: View {
    let url: URL?
    var contentMode: ContentMode = .fit

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Tokens.line.opacity(0.35)
            }
        }
        .task(id: url) {
            image = await ImageMemoryCache.shared.image(at: url)
        }
    }
}

final class ImageMemoryCache: @unchecked Sendable {
    static let shared = ImageMemoryCache()
    private let cache = NSCache<NSURL, UIImage>()

    func image(at url: URL?) async -> UIImage? {
        guard let url else { return nil }
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }
        guard let data = try? await Task.detached(priority: .utility, operation: { try? Data(contentsOf: url) }).value,
              let image = UIImage(data: data)
        else {
            return nil
        }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    func store(_ image: UIImage, at url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}
