import CoreGraphics
import Foundation

/// 版面还原档的**净化覆盖**产物（spec/layout-restore plan D3）。
///
/// 一组覆盖矩形 + 各自的填充色：预览（LayoutCanvas 覆盖层）与 DOCX 导出
/// （浮动 shape 衬底）共用同一份。矩形为 Vision 归一化坐标（左下原点），
/// 已外扩并夹在页界内；颜色为环带逐通道 median RGB（白纸页 → 白，带色底 → 局部底色）。
struct LayoutMask: Sendable, Equatable {
    /// 单个覆盖矩形及其填充色（8bit/通道 —— DOCX 需要 hex 颜色串，画布需要 Color）。
    struct Fill: Sendable, Equatable {
        /// Vision 归一化框（左下原点），外扩后已夹页界。
        var rect: CGRect
        var red: UInt8
        var green: UInt8
        var blue: UInt8

        init(rect: CGRect, red: UInt8, green: UInt8, blue: UInt8) {
            self.rect = rect
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    var fills: [Fill]

    init(fills: [Fill] = []) {
        self.fills = fills
    }

    var isEmpty: Bool { fills.isEmpty }
}
