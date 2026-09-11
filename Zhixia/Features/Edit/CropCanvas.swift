import SwiftUI

struct CropCanvas: View {
    var image: UIImage
    @Binding var quad: Quad
    var onChanged: () -> Void
    var onEnded: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let fitted = fittedRect(for: image.size, in: proxy.size)
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .overlay {
                    QuadShape(quad: quad)
                        .stroke(Tokens.seal, lineWidth: 2)
                    ForEach(Corner.allCases, id: \.self) { corner in
                        handle(for: corner, in: fitted)
                    }
                }
        }
    }

    private func handle(for corner: Corner, in fitted: CGRect) -> some View {
        let point = corner.point(in: quad)
        return Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Tokens.seal, lineWidth: 2))
            .frame(width: Tokens.handleSize, height: Tokens.handleSize)
            .position(
                x: fitted.minX + point.x * fitted.width,
                y: fitted.minY + point.y * fitted.height
            )
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let normalized = CGPoint(
                            x: (value.location.x - fitted.minX) / max(fitted.width, 1),
                            y: (value.location.y - fitted.minY) / max(fitted.height, 1)
                        )
                        var next = quad
                        corner.set(normalized, on: &next)
                        quad = next.clamped()
                        onChanged()
                    }
                    .onEnded { _ in
                        onEnded()
                    }
            )
    }

    private func fittedRect(for imageSize: CGSize, in bounds: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

private enum Corner: CaseIterable {
    case topLeft, topRight, bottomRight, bottomLeft

    func point(in quad: Quad) -> CGPoint {
        switch self {
        case .topLeft: quad.topLeft
        case .topRight: quad.topRight
        case .bottomRight: quad.bottomRight
        case .bottomLeft: quad.bottomLeft
        }
    }

    func set(_ point: CGPoint, on quad: inout Quad) {
        switch self {
        case .topLeft: quad.topLeft = point
        case .topRight: quad.topRight = point
        case .bottomRight: quad.bottomRight = point
        case .bottomLeft: quad.bottomLeft = point
        }
    }
}
