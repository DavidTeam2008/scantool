import SwiftUI

/// 引导框（spec/guided-capture T012 / FR-002 / plan D3）——屏幕上**唯一可拖动**的框。
///
/// ## 契约
/// - **白实线 + 暗描边**：亮纸面上纯白不可辨，暗描边（5pt 黑 35%）保底可读；
/// - **四边 + 四角各 44pt 命中区**：角手柄 44pt 圆、边手柄 44pt 宽条
///   （`plan.md` D3 的「44pt 命中区」与风险表「角手柄遮挡/误触」对策）；
/// - **与自动框不共用交互状态**：自动框 `allowsHitTesting(false)`（只读），
///   引导框独立持有拖动状态——两者不同时出现（D1）；
/// - 拖动中本视图持有临时框（跟手），**合法性由 ViewModel 判定**（照片空间
///   自交/近退化/过小/越界 → 拒绝并保留上一有效框，D3）；
/// - 静止时**零自动移动**：没有逐帧吸附、没有跟随（SC-003）。
struct GuideOverlayView: View {
    /// 引导框（**照片空间**）——真值；屏幕框是它的派生渲染值。
    let guidePhotoQuad: Quad?
    /// 运行时取景几何（照片→屏幕解析映射的唯一输入）。
    let geometry: CaptureGeometry
    /// 画布尺寸回调（**本视图 GeometryReader 的真实尺寸**）。
    ///
    /// 为什么不用父层的 `onGeometryChange`：那个测量拿到的是**安全区尺寸**
    /// （真机 402×778），而本视图在 `.ignoresSafeArea()` 下的渲染空间是
    /// **全屏尺寸**（402×874）——两者不一致会让屏幕↔照片逆映射整体偏移
    /// （真机症状：照片框 y 越界 → 引导框恒被判非法）。引导路径必须用
    /// **渲染同一空间**的尺寸（spec/guided-capture D2 / SC-004）。
    let onSizeChange: (CGSize) -> Void
    /// 拖动中回调（屏幕空间四边形）。
    let onDrag: (Quad) -> Void
    /// 松手回调（屏幕空间四边形）。
    let onCommit: (Quad) -> Void

    /// 拖动中的临时框（屏幕空间）——跟手渲染；松手后清空。
    @State private var draggingQuad: Quad?
    /// 拖动起点（屏幕空间）——拖动期间以此为基准叠加位移。
    @State private var dragOrigin: Quad?

    var body: some View {
        GeometryReader { proxy in
            let base = draggingQuad ?? guidePhotoQuad.map {
                OverlaySpaceMap.screenQuad(fromPhotoQuad: $0, geometry: geometry, viewSize: proxy.size)
            }
            ZStack {
                if let base {
                    QuadShape(quad: base)
                        .stroke(
                            Color.black.opacity(0.35),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                        )
                        .allowsHitTesting(false)
                    QuadShape(quad: base)
                        .stroke(
                            Color.white,
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                        )
                        .allowsHitTesting(false)
                    handles(base: base)
                }
            }
            .onAppear { onSizeChange(proxy.size) }
            .onChange(of: proxy.size) { _, newSize in onSizeChange(newSize) }
        }
    }

    // MARK: - 手柄

    /// 八个手柄（四角 + 四边），每个 44pt 命中区。
    @ViewBuilder
    private func handles(base: Quad) -> some View {
        ForEach(GuideHandle.allCases, id: \.self) { handle in
            let anchor = handle.anchor(in: base)
            ZStack {
                Color.clear
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                // 起点在首次变更时锁定（后续位移都相对它叠加）。
                                let origin = dragOrigin ?? base
                                if dragOrigin == nil {
                                    dragOrigin = origin
                                }
                                let updated = handle.moved(base: origin, translation: value.translation)
                                draggingQuad = updated
                                onDrag(updated)
                            }
                            .onEnded { _ in
                                if let final = draggingQuad {
                                    onCommit(final)
                                }
                                dragOrigin = nil
                                draggingQuad = nil
                            }
                    )
                if handle.isCorner {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 2))
                } else {
                    Capsule()
                        .fill(Color.white)
                        .frame(width: 22, height: 6)
                        .overlay(Capsule().stroke(Color.black.opacity(0.4), lineWidth: 2))
                        .rotationEffect(handle.edgeAngle(in: base))
                }
            }
            .position(anchor)
        }
    }
}

// MARK: - 手柄几何

/// 引导框手柄（四角 + 四边）。
private enum GuideHandle: CaseIterable {
    case topLeft
    case topRight
    case bottomRight
    case bottomLeft
    case top
    case right
    case bottom
    case left

    var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomRight, .bottomLeft: true
        case .top, .right, .bottom, .left: false
        }
    }

    /// 手柄锚点（角点本身 / 边中点）。
    func anchor(in quad: Quad) -> CGPoint {
        switch self {
        case .topLeft: return quad.topLeft
        case .topRight: return quad.topRight
        case .bottomRight: return quad.bottomRight
        case .bottomLeft: return quad.bottomLeft
        case .top:
            return CGPoint(x: (quad.topLeft.x + quad.topRight.x) / 2, y: (quad.topLeft.y + quad.topRight.y) / 2)
        case .right:
            return CGPoint(x: (quad.topRight.x + quad.bottomRight.x) / 2, y: (quad.topRight.y + quad.bottomRight.y) / 2)
        case .bottom:
            return CGPoint(x: (quad.bottomLeft.x + quad.bottomRight.x) / 2, y: (quad.bottomLeft.y + quad.bottomRight.y) / 2)
        case .left:
            return CGPoint(x: (quad.topLeft.x + quad.bottomLeft.x) / 2, y: (quad.topLeft.y + quad.bottomLeft.y) / 2)
        }
    }

    /// 边手柄的视觉朝向（沿边方向）。
    func edgeAngle(in quad: Quad) -> Angle {
        let (from, to): (CGPoint, CGPoint)
        switch self {
        case .top: (from, to) = (quad.topLeft, quad.topRight)
        case .right: (from, to) = (quad.topRight, quad.bottomRight)
        case .bottom: (from, to) = (quad.bottomRight, quad.bottomLeft)
        case .left: (from, to) = (quad.bottomLeft, quad.topLeft)
        default: return .zero
        }
        return .radians(Double(atan2(to.y - from.y, to.x - from.x)))
    }

    /// 按手柄类型把位移作用到四边形上。
    func moved(base: Quad, translation: CGSize) -> Quad {
        let delta = CGPoint(x: translation.width, y: translation.height)
        switch self {
        case .topLeft:
            return Quad(topLeft: base.topLeft.offset(by: delta), topRight: base.topRight, bottomRight: base.bottomRight, bottomLeft: base.bottomLeft)
        case .topRight:
            return Quad(topLeft: base.topLeft, topRight: base.topRight.offset(by: delta), bottomRight: base.bottomRight, bottomLeft: base.bottomLeft)
        case .bottomRight:
            return Quad(topLeft: base.topLeft, topRight: base.topRight, bottomRight: base.bottomRight.offset(by: delta), bottomLeft: base.bottomLeft)
        case .bottomLeft:
            return Quad(topLeft: base.topLeft, topRight: base.topRight, bottomRight: base.bottomRight, bottomLeft: base.bottomLeft.offset(by: delta))
        case .top, .right, .bottom, .left:
            return movedEdge(base: base, translation: delta)
        }
    }

    /// 边拖动：只取位移在**边法线**上的分量（沿边滑动不改变形状）。
    private func movedEdge(base: Quad, translation: CGPoint) -> Quad {
        let (from, to): (CGPoint, CGPoint)
        switch self {
        case .top: (from, to) = (base.topLeft, base.topRight)
        case .right: (from, to) = (base.topRight, base.bottomRight)
        case .bottom: (from, to) = (base.bottomRight, base.bottomLeft)
        default: (from, to) = (base.bottomLeft, base.topLeft)
        }
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = hypot(dx, dy)
        guard length > 1e-9 else { return base }
        // 边的法线（垂直于边方向）。
        let nx = dy / length
        let ny = -dx / length
        let projected = translation.x * nx + translation.y * ny
        let offset = CGPoint(x: nx * projected, y: ny * projected)
        switch self {
        case .top:
            return Quad(
                topLeft: base.topLeft.offset(by: offset),
                topRight: base.topRight.offset(by: offset),
                bottomRight: base.bottomRight,
                bottomLeft: base.bottomLeft
            )
        case .right:
            return Quad(
                topLeft: base.topLeft,
                topRight: base.topRight.offset(by: offset),
                bottomRight: base.bottomRight.offset(by: offset),
                bottomLeft: base.bottomLeft
            )
        case .bottom:
            return Quad(
                topLeft: base.topLeft,
                topRight: base.topRight,
                bottomRight: base.bottomRight.offset(by: offset),
                bottomLeft: base.bottomLeft.offset(by: offset)
            )
        default:
            return Quad(
                topLeft: base.topLeft.offset(by: offset),
                topRight: base.topRight,
                bottomRight: base.bottomRight,
                bottomLeft: base.bottomLeft.offset(by: offset)
            )
        }
    }
}

/// CGPoint 位移小工具（CoreGraphics 未提供 `+` 运算符）。
private extension CGPoint {
    func offset(by delta: CGPoint) -> CGPoint {
        CGPoint(x: x + delta.x, y: y + delta.y)
    }
}
