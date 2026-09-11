import UIKit

enum ImportedImage {
    static func jpeg(from data: Data) -> Data? {
        guard let image = UIImage(data: data), image.size.width > 1, image.size.height > 1 else {
            return nil
        }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let flattened = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return flattened.jpegData(compressionQuality: 0.92)
    }
}
