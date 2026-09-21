import SwiftUI

struct CropCanvas: View {
    var image: UIImage
    @Binding var quad: Quad
    var onChanged: () -> Void
    var onEnded: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let fitted = Self.fittedRect(for: image.size, in: proxy.size)
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .overlay {
                    // US5（plan D9）：轮廓与手柄同在 aspect-fit 的 fitted 显示矩形
                    // 坐标系内绘制/定位——旧实现轮廓按全画布映射，图像宽高比 ≠ 画布
                    // 宽高比时轮廓与手柄错位，「所见」不等于「所裁」。
                    CanvasQuadShape(quad: Self.canvasQuad(quad, in: fitted))
                        .stroke(Tokens.seal, lineWidth: 2)
                    ForEach(Corner.allCases, id: \.self) { corner in
                        handle(for: corner, in: fitted)
                    }
                }
        }
    }

    // MARK: - 纯映射函数（US5 抽出，与手柄/轮廓共用，测试可直测）

    /// aspect-fit 的图像显示矩形：图像在画布内等比缩放并居中。
    static func fittedRect(for imageSize: CGSize, in bounds: CGSize) -> CGRect {
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

    /// 图像归一化点 → 画布坐标（fitted 矩形内）。
    static func canvasPoint(_ normalized: CGPoint, in fitted: CGRect) -> CGPoint {
        CGPoint(
            x: fitted.minX + normalized.x * fitted.width,
            y: fitted.minY + normalized.y * fitted.height
        )
    }

    /// 图像归一化 quad → 画布绝对坐标 quad（轮廓绘制用，与手柄定位同源）。
    static func canvasQuad(_ quad: Quad, in fitted: CGRect) -> Quad {
        Quad(
            topLeft: canvasPoint(quad.topLeft, in: fitted),
            topRight: canvasPoint(quad.topRight, in: fitted),
            bottomRight: canvasPoint(quad.bottomRight, in: fitted),
            bottomLeft: canvasPoint(quad.bottomLeft, in: fitted)
        )
    }

    // MARK: - 手柄

    private func handle(for corner: Corner, in fitted: CGRect) -> some View {
        let point = corner.point(in: quad)
        return Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Tokens.seal, lineWidth: 2))
            .frame(width: Tokens.handleSize, height: Tokens.handleSize)
            .position(Self.canvasPoint(point, in: fitted))
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
}

/// 画布绝对坐标的四边形轮廓（区别于归一化坐标的 `QuadShape`）。
private struct CanvasQuadShape: Shape {
    var quad: Quad

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: quad.topLeft)
        path.addLine(to: quad.topRight)
        path.addLine(to: quad.bottomRight)
        path.addLine(to: quad.bottomLeft)
        path.closeSubpath()
        return path
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
