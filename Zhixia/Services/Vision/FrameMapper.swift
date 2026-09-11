import Foundation

enum FrameMapper {
    /// Maps a quad in image-normalized space to view-normalized space for `.resizeAspectFill`.
    static func viewQuad(from imageQuad: Quad, imageSize: CGSize, viewSize: CGSize) -> Quad {
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            return imageQuad
        }
        return Quad(
            topLeft: map(imageQuad.topLeft, imageSize: imageSize, viewSize: viewSize),
            topRight: map(imageQuad.topRight, imageSize: imageSize, viewSize: viewSize),
            bottomRight: map(imageQuad.bottomRight, imageSize: imageSize, viewSize: viewSize),
            bottomLeft: map(imageQuad.bottomLeft, imageSize: imageSize, viewSize: viewSize)
        )
    }

    static func imageQuad(from viewQuad: Quad, imageSize: CGSize, viewSize: CGSize) -> Quad {
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            return viewQuad
        }
        return Quad(
            topLeft: unmap(viewQuad.topLeft, imageSize: imageSize, viewSize: viewSize),
            topRight: unmap(viewQuad.topRight, imageSize: imageSize, viewSize: viewSize),
            bottomRight: unmap(viewQuad.bottomRight, imageSize: imageSize, viewSize: viewSize),
            bottomLeft: unmap(viewQuad.bottomLeft, imageSize: imageSize, viewSize: viewSize)
        )
    }

    private static func map(_ point: CGPoint, imageSize: CGSize, viewSize: CGSize) -> CGPoint {
        let imageAspect = imageSize.width / imageSize.height
        let viewAspect = viewSize.width / viewSize.height
        if imageAspect > viewAspect {
            let scale = imageAspect / viewAspect
            return CGPoint(x: (point.x - 0.5) * scale + 0.5, y: point.y)
        }
        let scale = viewAspect / imageAspect
        return CGPoint(x: point.x, y: (point.y - 0.5) * scale + 0.5)
    }

    private static func unmap(_ point: CGPoint, imageSize: CGSize, viewSize: CGSize) -> CGPoint {
        let imageAspect = imageSize.width / imageSize.height
        let viewAspect = viewSize.width / viewSize.height
        if imageAspect > viewAspect {
            let scale = imageAspect / viewAspect
            return CGPoint(x: (point.x - 0.5) / scale + 0.5, y: point.y)
        }
        let scale = viewAspect / imageAspect
        return CGPoint(x: point.x, y: (point.y - 0.5) / scale + 0.5)
    }
}
