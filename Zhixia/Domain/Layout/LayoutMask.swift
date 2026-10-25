import CoreGraphics
import Foundation

/// 版面还原档的**净化覆盖**产物（spec/layout-restore plan D3）。
///
/// 一组覆盖矩形 + 各自的填充色：预览（LayoutCanvas 覆盖层）与 DOCX 导出
/// （浮动 shape 衬底）共用同一份。矩形为 Vision 归一化坐标（左下原点），
/// 已外扩并夹在页界内；颜色为环带逐通道 median RGB（白纸页 → 白，带色底 → 局部底色）。
struct LayoutMask: Sendable, Equatable {
    /// 覆盖方式：
    /// - `.solid`：整块刷底色（表格/无行几何的退化块）；
    /// - `.textPixels`：只把矩形内**与底色差异大的文字像素**刷成底色，保留矩形
    ///   内的边框/深色栏头/照片。混合模式 H2 的逐行擦字走这里，避免行框矩形
    ///   在纸面上留下可见色带，也避免行框跨到深色装饰时把装饰刷白。
    enum FillMode: Sendable, Equatable {
        case solid
        case textPixels
    }

    /// 单个覆盖矩形及其填充色（8bit/通道 —— DOCX 需要 hex 颜色串，画布需要 Color）。
    struct Fill: Sendable, Equatable {
        /// Vision 归一化框（左下原点），外扩后已夹页界。
        var rect: CGRect
        var red: UInt8
        var green: UInt8
        var blue: UInt8
        var mode: FillMode

        init(
            rect: CGRect,
            red: UInt8,
            green: UInt8,
            blue: UInt8,
            mode: FillMode = .solid
        ) {
            self.rect = rect
            self.red = red
            self.green = green
            self.blue = blue
            self.mode = mode
        }
    }

    var fills: [Fill]

    init(fills: [Fill] = []) {
        self.fills = fills
    }

    var isEmpty: Bool { fills.isEmpty }

    /// 某个文字区域下方的底色是否偏深，用于决定可编辑文字用白字还是黑字。
    ///
    /// 取**与文字区域覆盖率最高的 fill**，而不是「包含中心的最小 fill」：布局
    /// 引擎拆出的相邻块/行框会互相重叠，中心命中可能落到另一块的浅色 fill 上
    /// （顶部双栏深色表头中的白字因此被误判成黑字，WPS 里黑字压深底不可见）。
    /// 覆盖率高的 fill 才是这一段自己的擦除底色。没有覆盖（文字压在照片/图上）
    /// 时返回 `false`，保持墨字默认。
    func isDarkBackground(at rect: CGRect) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }
        let area = rect.width * rect.height
        let candidates = fills.compactMap { fill -> (LayoutMask.Fill, CGFloat)? in
            let intersection = fill.rect.intersection(rect)
            guard !intersection.isNull, !intersection.isEmpty else { return nil }
            let coverage = (intersection.width * intersection.height) / area
            return (fill, coverage)
        }
        guard let best = candidates.max(by: { $0.1 < $1.1 })?.0 else {
            return false
        }
        let luma = (Int(best.red) * 299 + Int(best.green) * 587 + Int(best.blue) * 114) / 1000
        return luma < 145
    }

    /// 与底色对比的可编辑文字颜色（RGB）。深底 → 白字，浅底 → 黑字。
    func contrastingTextColor(at rect: CGRect) -> (red: UInt8, green: UInt8, blue: UInt8) {
        isDarkBackground(at: rect) ? (255, 255, 255) : (0, 0, 0)
    }
}
