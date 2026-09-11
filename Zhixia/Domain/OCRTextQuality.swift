import Foundation

enum OCRTextQuality {
    static func score(_ text: String) -> Int {
        var cjk = 0
        var letters = 0
        var digits = 0
        var symbols = 0
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                cjk += 1
            } else if CharacterSet.decimalDigits.contains(scalar) {
                digits += 1
            } else if CharacterSet.letters.contains(scalar) {
                letters += 1
            } else if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                symbols += 1
            }
        }
        return cjk * 8 + digits + letters - symbols * 3
    }

    static func cjkCount(_ text: String) -> Int {
        text.unicodeScalars.filter(isCJK).count
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x4E00...0x9FFF).contains(value)
            || (0x3400...0x4DBF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x3000...0x303F).contains(value)
            || (0xFF00...0xFFEF).contains(value)
    }
}

extension OCRPageText {
    var qualityScore: Int {
        OCRTextQuality.score(joinedText)
    }
}
