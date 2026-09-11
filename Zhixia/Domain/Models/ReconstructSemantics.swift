import CoreGraphics
import Foundation

/// 块的语义标签。M1 由 LayoutAnalyzer 根据版面与文本特征给出；
/// 下游可据此做结构化抽取（如 M2 的表识别跳过非 tableTitle 块）。
enum ReconstructSemanticTag: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case pageHeader
    case pageFooter
    case tableTitle
    case tableHeaderCell
    case tableCell
    case questionStem
    case optionLetter
    case handwrittenBlank
    case unit
    case barcode
}

/// 关键版面锚点。M1 抽取：表标题、题号、选项字母、页眉、条码。
/// 锚点比行级 semantic 更稳定——它带 frame 与 text，能被 M2/M3 直接用作
/// 「在此下方/右侧/附近找」的几何种子。
enum LayoutAnchorKind: String, Sendable, Codable, Equatable, Hashable {
    case tableTitle
    case tableHeaderRow
    case questionStem
    case optionLetter
    case pageHeader
    case barcode
}

struct LayoutAnchor: Sendable, Equatable, Codable, Hashable {
    var kind: LayoutAnchorKind
    var frame: CGRect
    var text: String?
    var confidence: Double

    init(
        kind: LayoutAnchorKind,
        frame: CGRect,
        text: String? = nil,
        confidence: Double = 1
    ) {
        self.kind = kind
        self.frame = frame
        self.text = text
        self.confidence = confidence
    }
}
