import SwiftUI

enum Tokens {
    static let paper = Color(hex: 0xF6F3EC)
    static let ink = Color(hex: 0x1B1914)
    static let muted = Color(hex: 0x6E675C)
    static let line = Color(hex: 0xE4DDD2)
    static let card = Color(hex: 0xFFFDF8)
    static let seal = Color(hex: 0xC24A32)
    static let forest = Color(hex: 0x3D5A4C)
    static let wheat = Color(hex: 0xC4A46A)
    static let danger = Color(hex: 0xB42318)
    static let preview = Color(hex: 0x16140F)

    static let cardRadius: CGFloat = 16
    static let coverRadius: CGFloat = 12
    static let scanButtonSize: CGFloat = 64
    static let shutterSize: CGFloat = 72
    static let handleSize: CGFloat = 14
    static let horizontalPadding: CGFloat = 20
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
