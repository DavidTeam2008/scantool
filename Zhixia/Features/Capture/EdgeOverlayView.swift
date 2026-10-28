import SwiftUI

struct EdgeOverlayView: View {
    /// 照片空间的检测框（ViewModel 摄入边界已换算，plan D1）。
    var imageQuad: Quad?
    /// CF-T004：左/右页输出目标（照片空间）。非 nil 时它是**实线主框**，
    /// `imageQuad` 降级为虚线上下文包络——左页目标的右角落在书脊上，
    /// 不会因为整摊包络超出屏幕而消失。
    var targetQuad: Quad? = nil
    /// tracker 正在 hold 上一帧包络：只画淡虚线残影，不画可拍摄的实线。
    var isHolding: Bool = false
    /// 运行时取景几何（T019 / FR-007）：视频/照片竖屏宽高比 —— 解析式映射的
    /// 唯一输入（`OverlaySpaceMap`：照片→视频 `FOVLayout` 逆换算 ⊕ 视频→屏幕
    /// aspectFill 放置，y-down 全链不翻转）。渲染真值不再依赖运行时探针。
    var geometry: CaptureGeometry
    /// 诊断探针（T022）：**仅作日志对照**（探针值 vs 解析式值逐轴偏差，SC-004
    /// 证据链），不参与渲染；nil = 不对照。探针失效从此只影响对照行，不影响边框。
    var diagnosticProbe: ((CGSize) -> QuadSpaceTransform?)? = nil
    var isLocked: Bool
    var mode: ScanMode

    @State private var loggedAnalytic: QuadSpaceTransform?
    @State private var loggedProbe: QuadSpaceTransform?

    var body: some View {
        GeometryReader { proxy in
            let analytic = Self.analyticTransform(geometry: geometry, viewSize: proxy.size)
            let probe = diagnosticProbe?(proxy.size)
            let viewQuad = imageQuad.map {
                OverlaySpaceMap.screenQuad(fromPhotoQuad: $0, geometry: geometry, viewSize: proxy.size)
            }
            let targetViewQuad = targetQuad.map {
                OverlaySpaceMap.screenQuad(fromPhotoQuad: $0, geometry: geometry, viewSize: proxy.size)
            }
            let quads = CaptureOverlayQuads.resolve(envelope: viewQuad, target: targetViewQuad)
            ZStack {
                if mode == .idCard {
                    // 证件模式路径不变（T020）：idMask + 检测框描边保持现状。
                    idMask(in: proxy.size)
                    if let viewQuad {
                        QuadShape(quad: viewQuad)
                            .stroke(isLocked ? Tokens.seal : Tokens.seal.opacity(0.45), style: StrokeStyle(
                                lineWidth: 2.5,
                                dash: isLocked ? [] : [8, 6]
                            ))
                    }
                } else if let primary = quads.primary {
                    if isHolding {
                        holdingOverlay(primary: primary, context: quads.context)
                    } else {
                        documentEdgeOverlay(
                            primary: primary,
                            context: quads.context,
                            in: proxy.size
                        )
                    }
                }
            }
            .onAppear {
                // 初始对照一次（探针未就绪 = unavailable，与后续实测行共同构成
                // FR-007 / SC-004 验收证据链）。
                logDiagnostics(viewSize: proxy.size, analytic: analytic, probe: probe)
            }
            .onChange(of: analytic) { _, newAnalytic in
                // geometry / viewSize 变化 → 解析式参数变化，重记对照。
                logDiagnostics(
                    viewSize: proxy.size,
                    analytic: newAnalytic,
                    probe: diagnosticProbe?(proxy.size)
                )
            }
            .onChange(of: probe) { _, newProbe in
                // 探针状态变化（预览层就绪/失效）→ 重记对照。
                logDiagnostics(viewSize: proxy.size, analytic: analytic, probe: newProbe)
            }
        }
        .allowsHitTesting(false)
    }

    /// 解析式映射的仿射参数（诊断日志源，T019）：照片空间 [0,1]² → 屏幕的逐轴
    /// 缩放/偏移，即 `OverlaySpaceMap.videoFramePlacement`（视频帧 aspectFill 放置矩形）。
    static func analyticTransform(geometry: CaptureGeometry, viewSize: CGSize) -> QuadSpaceTransform {
        let placement = OverlaySpaceMap.videoFramePlacement(geometry: geometry, viewSize: viewSize)
        return QuadSpaceTransform(
            scaleX: placement.width,
            scaleY: placement.height,
            offsetX: placement.minX,
            offsetY: placement.minY
        )
    }

    /// 解析式值 + 探针值的对照日志：等值去重，不逐帧刷屏（与旧探针日志同策略）。
    private func logDiagnostics(viewSize: CGSize, analytic: QuadSpaceTransform, probe: QuadSpaceTransform?) {
        guard probe != loggedProbe || analytic != loggedAnalytic else { return }
        loggedProbe = probe
        loggedAnalytic = analytic
        ZhixiaLog.overlayProbeAnalytic(viewSize: viewSize, analytic: analytic, probe: probe)
    }

    /// T020（US5 / FR-008）+ live-edge-crop（US2 / FR-003）：文档模式边框视觉——
    /// ① 框外压暗（reverseMask 挖空**主框**；tracking 0.25 / locked 0.45）；
    /// ② 四角 L 形粗括号（臂长 ≈ min(viewSize)×3%，白 4pt + 暗描边——亮纸面上
    ///    纯白也保底可辨）；
    /// ③ 连续实线整框（`DocumentFrameStyle`）：跟踪 = 朱砂细实线（替换旧虚线
    ///    [8,6]）；锁定 = 白面线 + 暗描边粗实线。
    ///
    /// CF-T004：`primary` 是实际输出目标（左/右页），`context` 是整摊包络。
    /// 包络只画淡虚线，不参与压暗；这样左页的右角落在书脊上始终可见，不会
    /// 被超出屏幕的整摊包络裁掉。
    @ViewBuilder
    private func documentEdgeOverlay(primary: Quad, context: Quad?, in size: CGSize) -> some View {
        Color.black.opacity(isLocked ? 0.45 : 0.25)
            .reverseMask {
                QuadShape(quad: primary).fill(Color.white)
            }
        if let context {
            contextFrame(quad: context)
        }
        let armLength = min(size.width, size.height) * 0.03
        CornerBracketsShape(quad: primary, armLength: armLength)
            .stroke(
                Color.black.opacity(0.35),
                style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
            )
        CornerBracketsShape(quad: primary, armLength: armLength)
            .stroke(
                Color.white,
                style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
            )
        if let frameStyle = DocumentFrameStyle.resolve(isLocked: isLocked, mode: mode) {
            frameStroke(quad: primary, style: frameStyle)
        }
    }

    /// 上下文包络（整摊/整书外框）：细虚线 + 暗描边，只提供“框还在”的连续
    /// 视觉，不承诺裁切边界（CF-T004）。
    @ViewBuilder
    private func contextFrame(quad: Quad) -> some View {
        QuadShape(quad: quad)
            .stroke(
                Color.black.opacity(0.30),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [6, 6])
            )
        QuadShape(quad: quad)
            .stroke(
                Color.white.opacity(0.55),
                style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round, dash: [6, 6])
            )
    }

    /// hold 残影：检测缺口内保留上一帧包络，但明确画成虚线——它不是这一帧
    /// 的可拍摄真值（快门同时置灰）。
    @ViewBuilder
    private func holdingOverlay(primary: Quad, context: Quad?) -> some View {
        if let context {
            QuadShape(quad: context)
                .stroke(Color.white.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
        }
        QuadShape(quad: primary)
            .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
    }

    /// 整框实线描边：双线结构先画暗描边再画面线（面线叠在描边之上，与四角括号
    /// 同风格）；单线结构只画面线。dash 由 `DocumentFrameStyle` 类型保证恒空。
    @ViewBuilder
    private func frameStroke(quad: Quad, style: DocumentFrameStyle) -> some View {
        if let outlineColor = style.outlineColor {
            QuadShape(quad: quad)
                .stroke(outlineColor, style: style.outlineStyle)
        }
        QuadShape(quad: quad)
            .stroke(style.strokeColor, style: style.strokeStyle)
    }

    private func idMask(in size: CGSize) -> some View {
        // 证件窗是固定比例窗，与视图同空间：无需映射，直接按归一化矩形取外接框。
        let rect = Quad.idCardWindow.boundingRect
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

// MARK: - 文档模式整框样式（spec/live-edge-crop，plan D4 / FR-003）

/// 文档模式取景整框描边的纯数据配置——跟踪/锁定两态的线宽、单/双线结构与颜色。
///
/// **「实线」是类型不变量**：`strokeStyle` / `outlineStyle` 的 `dash` 恒为空，
/// 且本类型不提供任何配置虚线的入口——连续实线由类型本身保证（替换旧虚线
/// `[8, 6]`）。渲染消费见 `EdgeOverlayView.documentEdgeOverlay`；两态差异
/// （线宽/结构/颜色）全部落进可断言字段（`DocumentFrameStyleTests`），
/// 不依赖快照测试。
struct DocumentFrameStyle: Equatable {
    /// 面线（最上层的可见线条）：跟踪 = 朱砂细线；锁定 = 白色粗线。
    var strokeColor: Color
    var strokeWidth: CGFloat
    /// 暗描边（双线结构的外层，与四角括号同风格）；nil = 单线结构。
    var outlineColor: Color?
    var outlineWidth: CGFloat

    /// 双线结构（锁定态：暗描边 + 白面线）；跟踪态为单线。
    var isDoubleLine: Bool { outlineColor != nil }

    /// 跟随态：2.5pt 朱砂（seal 45%）细实线——替换旧虚线 [8, 6]。
    static let tracking = DocumentFrameStyle(
        strokeColor: Tokens.seal.opacity(0.45),
        strokeWidth: 2.5,
        outlineColor: nil,
        outlineWidth: 0
    )

    /// 锁定态：约 3pt 白面线 + 约 5pt 暗描边（与四角括号同风格）的粗实线整框
    ///（锁定态此前无整框——仅压暗加深 + 角括号）。
    static let locked = DocumentFrameStyle(
        strokeColor: .white,
        strokeWidth: 3,
        outlineColor: Color.black.opacity(0.35),
        outlineWidth: 5
    )

    /// 样式解析（FR-003 idCard 守卫）：仅文档模式有整框样式，证件模式恒 nil——
    /// idCard 走独立描边路径（idMask + 专用 stroke），不得消费本类型。
    /// 返回 nil = 调用方不渲染文档整框（可测锚点：两路径解耦）。
    static func resolve(isLocked: Bool, mode: ScanMode) -> DocumentFrameStyle? {
        guard mode == .document else { return nil }
        return isLocked ? .locked : .tracking
    }

    /// 面线描边样式——实线性质（类型不变量）：dash 恒为空。
    var strokeStyle: StrokeStyle {
        StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)
    }

    /// 暗描边样式（仅双线结构消费）——dash 恒为空（类型不变量）。
    var outlineStyle: StrokeStyle {
        StrokeStyle(lineWidth: outlineWidth, lineCap: .round, lineJoin: .round)
    }
}

// MARK: - 文档模式叠加层主框/上下文（CF-T004）

/// 叠加层要画的两个框：`primary` = 实际输出目标（实线、压暗、角括号），
/// `context` = 整摊/整书包络（淡虚线）。纯数据解析，便于单测钉住“目标优先”
/// 的显示契约——左/右页目标不得被更小的整页框或更大的包络覆盖。
struct CaptureOverlayQuads: Equatable {
    var primary: Quad?
    var context: Quad?

    static func resolve(envelope: Quad?, target: Quad?) -> CaptureOverlayQuads {
        guard let envelope else {
            return CaptureOverlayQuads(primary: target, context: nil)
        }
        guard let target, target != envelope else {
            return CaptureOverlayQuads(primary: envelope, context: nil)
        }
        return CaptureOverlayQuads(primary: target, context: envelope)
    }
}

/// 取景整框四边形（overlay-frame-visibility，plan D1 / FR-001）：`quad` 为
/// **屏幕点坐标**（`OverlaySpaceMap.screenQuad` 产物）——`path(in:)` 忽略
/// rect、输出点恒等于输入点，与 `CornerBracketsShape` 同约定（本视图铺满
/// overlay 区域时局部坐标即屏幕坐标）。
///
/// 契约背景：scan-fidelity T019 起本类型曾把输入当归一化 [0,1]² × rect 缩放，
/// 而调用方传入的一直是屏幕点——整框描边、压暗挖孔、idCard 检测框因此被画到
/// 屏幕外（真机「四角括号可见、整框从未出现」）。语义统一为屏幕点单点修复，
/// 调用点零改动。
struct QuadShape: Shape {
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

/// 四角 L 形粗括号（T020 / FR-008）：每个角沿两条邻边方向各伸出 `armLength`
/// 长的短臂，旋转书页时括号始终贴合边框走向。
///
/// `quad` 为**屏幕点坐标**（`OverlaySpaceMap.screenQuad` 产物）：`path(in:)`
/// 忽略 rect、直接使用绝对坐标——本视图铺满 overlay 区域时局部坐标即屏幕坐标。
struct CornerBracketsShape: Shape {
    var quad: Quad
    var armLength: CGFloat

    func path(in rect: CGRect) -> Path {
        let corners = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
        var path = Path()
        for (index, corner) in corners.enumerated() {
            let next = corners[(index + 1) % 4]
            let previous = corners[(index + 3) % 4]
            path.move(to: armEnd(from: corner, toward: next))
            path.addLine(to: corner)
            path.addLine(to: armEnd(from: corner, toward: previous))
        }
        return path
    }

    /// 沿 corner→neighbor 方向、距 corner 恰好 `armLength` 的端点
    ///（退化边长 0 时端点即角点本身）。
    private func armEnd(from corner: CGPoint, toward neighbor: CGPoint) -> CGPoint {
        let dx = neighbor.x - corner.x
        let dy = neighbor.y - corner.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return corner }
        let scale = armLength / length
        return CGPoint(x: corner.x + dx * scale, y: corner.y + dy * scale)
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
