import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum NormalizedImageCrop {
    static func png(from image: CGImage, visionBox: CGRect, padding: CGFloat = 0.012) -> Data? {
        let padded = visionBox.insetBy(dx: -padding, dy: -padding)
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let x = max(0, padded.minX * width)
        let y = max(0, (1 - padded.maxY) * height)
        let crop = CGRect(
            x: x,
            y: y,
            width: max(0, min(width - x, padded.width * width)),
            height: max(0, min(height - y, padded.height * height))
        ).integral
        guard crop.width > 8, crop.height > 8,
              let sliced = image.cropping(to: crop)
        else {
            return nil
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, sliced, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
