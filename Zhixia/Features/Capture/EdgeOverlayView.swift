import SwiftUI

struct EdgeOverlayView: View {
    var imageQuad: Quad?
    var imageSize: CGSize
    var isLocked: Bool
    var mode: ScanMode

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if mode == .idCard {
                    idMask(in: proxy.size)
                }
                if let imageQuad {
                    let viewQuad = FrameMapper.viewQuad(
                        from: imageQuad,
                        imageSize: imageSize,
                        viewSize: proxy.size
                    )
                    QuadShape(quad: viewQuad)
                        .stroke(isLocked ? Tokens.seal : Tokens.seal.opacity(0.45), style: StrokeStyle(
                            lineWidth: 2.5,
                            dash: isLocked ? [] : [8, 6]
                        ))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func idMask(in size: CGSize) -> some View {
        let window = FrameMapper.viewQuad(from: .idCardWindow, imageSize: size, viewSize: size)
        let rect = window.boundingRect
        return Rectangle()
            .fill(Color.black.opacity(0.45))
            .reverseMask {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .frame(width: rect.width * size.width, height: rect.height * size.height)
                    .position(x: rect.midX * size.width, y: rect.midY * size.height)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.7), lineWidth: 2)
                    .frame(width: rect.width * size.width, height: rect.height * size.height)
                    .position(x: rect.midX * size.width, y: rect.midY * size.height)
            }
    }
}

struct QuadShape: Shape {
    var quad: Quad

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(quad.topLeft, in: rect))
        path.addLine(to: point(quad.topRight, in: rect))
        path.addLine(to: point(quad.bottomRight, in: rect))
        path.addLine(to: point(quad.bottomLeft, in: rect))
        path.closeSubpath()
        return path
    }

    private func point(_ normalized: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + normalized.x * rect.width, y: rect.minY + normalized.y * rect.height)
    }
}

extension View {
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle()
                .overlay {
                    mask().blendMode(.destinationOut)
                }
                .compositingGroup()
        }
    }
}
