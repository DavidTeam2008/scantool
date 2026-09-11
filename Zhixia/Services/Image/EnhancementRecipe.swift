import Foundation

struct EnhancementRecipe: Sendable, Equatable {
    var shadows: Double
    var highlights: Double
    var contrast: Double
    var saturation: Double
    var brightness: Double
    var sharpness: Double
    var temperature: Double

    static func recipe(for enhancement: Enhancement) -> EnhancementRecipe? {
        switch enhancement {
        case .original:
            nil
        case .enhance:
            EnhancementRecipe(
                shadows: 0.2,
                highlights: -0.1,
                contrast: 1.12,
                saturation: 0.9,
                brightness: 0.02,
                sharpness: 0.35,
                temperature: -0.08
            )
        case .deskewShadow:
            EnhancementRecipe(
                shadows: 0.55,
                highlights: -0.05,
                contrast: 1.08,
                saturation: 0.85,
                brightness: 0.04,
                sharpness: 0.2,
                temperature: -0.04
            )
        case .grayscale:
            EnhancementRecipe(
                shadows: 0.1,
                highlights: 0,
                contrast: 1.15,
                saturation: 0,
                brightness: 0.02,
                sharpness: 0.2,
                temperature: 0
            )
        case .blackWhite:
            EnhancementRecipe(
                shadows: 0.15,
                highlights: -0.05,
                contrast: 1.35,
                saturation: 0,
                brightness: 0.04,
                sharpness: 0.25,
                temperature: 0
            )
        }
    }
}
